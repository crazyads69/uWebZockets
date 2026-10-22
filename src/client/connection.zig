//! Bounded client connection state machine for one in-flight HTTP/1.1 request.
//!
//! Completions are inline members of the connection, storage is fixed at
//! client construction, and a slot returns to its owner only after connect,
//! read, write, timer, cancellation, and socket-close completions have all
//! drained. The flow mirrors the server transport in `src/core/tcp.zig`; that
//! module remains the reference for the memory-BIO TLS model.

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const c = @import("c");
const core_loop = @import("../core/loop.zig");
const tcp = @import("../core/tcp.zig");
const handshake = @import("../crypto/handshake.zig");
const tls_client = @import("../crypto/tls_client.zig");
const types = @import("types.zig");
const http1 = @import("http1.zig");
const request_builder = @import("request.zig");

const log = std.log.scoped(.client);

const Request = types.Request;
const FetchOptions = types.FetchOptions;
const FailureKind = types.FailureKind;
const FetchOutcome = types.FetchOutcome;
const FetchCallback = types.FetchCallback;

/// Bytes read from the socket per completion.
pub const socket_read_capacity = 8192;
/// Plaintext bytes fed to one `SSL_write`.
pub const tls_plaintext_chunk = 16 * 1024;
/// Ciphertext staged for one socket write.
pub const tls_out_capacity = 8192;
/// Raw accumulator: head, decoded body, and chunk framing slack.
pub const response_buffer_capacity = types.max_response_head_bytes +
    types.default_response_body_capacity +
    types.response_framing_slack;

/// Lifecycle position of one client slot.
pub const Phase = enum {
    idle,
    connecting,
    handshaking,
    sending,
    receiving,
    teardown,
};

/// Returns a fully drained slot to its owning client.
pub const ReleaseCallback = *const fn (context: *anyopaque, conn: *ClientConnection) void;

/// Inputs required to arm one fetch; every borrowed slice must stay valid
/// until the fetch callback runs.
pub const StartParams = struct {
    loop: *xev.Loop,
    io: std.Io,
    request: Request,
    options: FetchOptions,
    ssl_ctx: ?*c.SSL_CTX,
    context: *anyopaque,
    callback: FetchCallback,
    release_callback: ReleaseCallback,
    release_context: *anyopaque,
    slot_index: usize,
};

/// Event-loop-confined state for exactly one in-flight request.
pub const ClientConnection = struct {
    response_buffer: [response_buffer_capacity]u8 = undefined,
    request_head: [types.max_request_head_bytes]u8 = undefined,
    read_buffer: [socket_read_capacity]u8 = undefined,
    tls_out_buffer: [tls_out_capacity]u8 = undefined,

    parser: http1.Parser = .{},
    session: tls_client.Session = .{},
    socket: xev.TCP = undefined,
    loop: ?*xev.Loop = null,
    io: std.Io = undefined,
    request: Request = .{ .host = "" },
    options: FetchOptions = .{ .port = 0 },
    context: *anyopaque = undefined,
    callback: ?FetchCallback = null,
    release_callback: ?ReleaseCallback = null,
    release_context: *anyopaque = undefined,
    outcome: FetchOutcome = .{ .failure = .{ .kind = .closed, .message = "request was never started" } },

    connect_completion: xev.Completion = .{},
    read_completion: xev.Completion = .{},
    write_completion: xev.Completion = .{},
    close_completion: xev.Completion = .{},
    connect_cancel_completion: xev.Completion = .{},
    read_cancel_completion: xev.Completion = .{},
    write_cancel_completion: xev.Completion = .{},
    timer_completion: xev.Completion = .{},
    timer_cancel_completion: xev.Completion = .{},
    timer: xev.Timer = undefined,

    phase: Phase = .idle,
    slot_index: usize = 0,
    request_head_len: usize = 0,
    head_sent: usize = 0,
    body_sent: usize = 0,
    write_requested_len: usize = 0,
    raw_len: usize = 0,
    tls_out_len: usize = 0,
    tls_out_sent: usize = 0,
    deadline_ms: i64 = 0,

    active: bool = false,
    connect_active: bool = false,
    read_active: bool = false,
    write_active: bool = false,
    close_complete: bool = false,
    connect_cancel_active: bool = false,
    read_cancel_active: bool = false,
    write_cancel_active: bool = false,
    timer_active: bool = false,
    timer_cancel_active: bool = false,
    handshake_done: bool = false,

    /// Resets the slot, builds the request, connects, and arms the deadline.
    pub fn start(self: *ClientConnection, params: StartParams) !void {
        const timer = self.timer;
        self.* = .{ .timer = timer, .slot_index = params.slot_index };
        self.loop = params.loop;
        self.io = params.io;
        self.request = params.request;
        self.options = params.options;
        self.context = params.context;
        self.callback = params.callback;
        self.release_callback = params.release_callback;
        self.release_context = params.release_context;
        self.parser = http1.Parser.init(
            @min(params.options.response_body_capacity, types.default_response_body_capacity),
            params.request.method == .head,
        );

        const head = request_builder.write_head(params.request, .{
            .port = params.options.port,
            .tls = params.options.tls != null,
        }, &self.request_head) catch |err| return err;
        self.request_head_len = head.len;

        const address = std.Io.net.IpAddress.parse(params.request.host, params.options.port) catch {
            return error.InvalidHostAddress;
        };
        errdefer self.session.deinit();
        if (params.options.tls) |tls_options| {
            const ssl_ctx = params.ssl_ctx orelse return error.TlsUnavailable;
            try self.session.init(ssl_ctx, tls_options.server_name, tls_options.verify);
        }

        self.socket = try xev.TCP.init(address);
        errdefer tcp.close_socket(xev.tcp_fd(self.socket));

        self.active = true;
        self.phase = .connecting;
        self.connect_active = true;
        self.socket.connect(
            params.loop,
            &self.connect_completion,
            address,
            ClientConnection,
            self,
            on_connect,
        );
        self.deadline_ms = now_ms(self.io) + @as(i64, params.options.connect_timeout_ms);
        self.arm_deadline();
    }

    /// Reports whether this slot is between fetch and callback.
    pub fn is_active(self: *const ClientConnection) bool {
        return self.active;
    }

    /// Force-releases an active slot without delivering an outcome.
    ///
    /// Only valid after a terminal event-loop failure: the loop will not run
    /// again, so no completion can fire and no callback may be invoked. Closes
    /// the socket directly and frees the TLS session.
    pub fn abandon(self: *ClientConnection) void {
        if (!self.active) return;
        self.callback = null;
        self.release_callback = null;
        self.active = false;
        self.phase = .idle;
        tcp.close_socket(xev.tcp_fd(self.socket));
        self.session.deinit();
    }

    fn fail(self: *ClientConnection, kind: FailureKind, message: []const u8) void {
        if (self.phase == .teardown) return;
        self.outcome = .{ .failure = .{ .kind = kind, .message = message } };
        self.teardown();
    }

    fn fail_parse(self: *ClientConnection, failure: http1.ParseFailure) void {
        switch (failure) {
            .head_too_large => self.fail(.capacity, "response head exceeded the 16 KiB bound"),
            .too_many_headers => self.fail(.capacity, "response exceeded the 64 header field bound"),
            .body_too_large => self.fail(.capacity, "response body exceeded the configured capacity"),
            .trailer_too_large => self.fail(.capacity, "response trailers exceeded the client bound"),
            .malformed => self.fail(.protocol, "malformed HTTP/1.1 response"),
            .conflicting_framing => self.fail(.protocol, "conflicting response framing"),
            .unsupported_transfer_encoding => self.fail(.protocol, "unsupported response transfer coding"),
            .unexpected_interim => self.fail(.protocol, "unexpected interim response"),
        }
    }

    /// Cancels every armed completion and closes the socket once.
    fn teardown(self: *ClientConnection) void {
        if (self.phase == .teardown) return;
        self.phase = .teardown;
        const loop = self.loop.?;

        if ((self.connect_active or self.read_active or self.write_active) and
            (builtin.os.tag == .windows or xev.submit_before_cancel()))
        {
            // IOCP and kqueue drop the callback of a completion canceled before
            // it starts. Flush queued work so the target callback owns its flag.
            xev.submit(loop) catch |err| {
                // Keep the target flags set: reusing a slot whose queued
                // callback may still fire would corrupt a new client request.
                log.err("client submit before teardown failed: {}", .{err});
            };
        }

        // Cancel every armed completion so each backend drops its active count
        // before the descriptor closes. The target and cancel callbacks each
        // own their flags, so release waits until both have run.
        if (self.connect_active) {
            self.connect_cancel_active = true;
            core_loop.cancel(
                loop,
                &self.connect_completion,
                &self.connect_cancel_completion,
                ClientConnection,
                self,
                on_connect_cancel_complete,
            );
        }
        if (self.read_active) {
            self.read_cancel_active = true;
            core_loop.cancel(
                loop,
                &self.read_completion,
                &self.read_cancel_completion,
                ClientConnection,
                self,
                on_read_cancel_complete,
            );
        }
        if (self.write_active) {
            self.write_cancel_active = true;
            core_loop.cancel(
                loop,
                &self.write_completion,
                &self.write_cancel_completion,
                ClientConnection,
                self,
                on_write_cancel_complete,
            );
        }

        if (self.timer_active and !self.timer_cancel_active) {
            self.timer_cancel_active = true;
            self.timer.cancel(
                loop,
                &self.timer_completion,
                &self.timer_cancel_completion,
                ClientConnection,
                self,
                on_timeout_cancel_complete,
            );
        }

        if (builtin.os.tag == .windows) {
            tcp.close_socket(xev.tcp_fd(self.socket));
            self.close_complete = true;
            if (self.connect_completion.state() != .active) self.connect_active = false;
            if (self.read_completion.state() != .active) self.read_active = false;
            if (self.write_completion.state() != .active) self.write_active = false;
            if (self.timer_completion.state() != .active) self.timer_active = false;
            self.maybe_release();
            return;
        }

        self.socket.close(loop, &self.close_completion, ClientConnection, self, on_close);
    }

    /// Delivers the outcome and returns the slot once no completion can fire.
    fn maybe_release(self: *ClientConnection) void {
        if (!self.active or self.phase != .teardown) return;
        if (!self.close_complete) return;
        if (self.connect_active or self.read_active or self.write_active) return;
        if (self.connect_cancel_active or self.read_cancel_active or self.write_cancel_active) return;
        if (self.timer_active or self.timer_cancel_active) return;

        const callback = self.callback orelse return;
        const release_callback = self.release_callback orelse return;
        const context = self.context;
        const release_context = self.release_context;

        // Deliver before the slot can be reacquired so the borrowed response
        // view stays untouched for the whole callback.
        callback(context, self.outcome);

        self.active = false;
        self.phase = .idle;
        self.callback = null;
        self.release_callback = null;
        self.session.deinit();
        release_callback(release_context, self);
    }

    /// Arms the deadline timer unless one is already pending.
    ///
    /// The sleep is capped by the read timeout so a timer armed before the
    /// connect deadline can never outlive a shorter deadline installed when
    /// the connection completes.
    fn arm_deadline(self: *ClientConnection) void {
        if (self.phase == .teardown or self.timer_active) return;
        const remaining = self.deadline_ms - now_ms(self.io);
        if (remaining <= 0) {
            self.fail(.timeout, "request deadline expired");
            return;
        }

        var sleep_ms: u64 = @intCast(@min(remaining, @as(i64, self.options.read_timeout_ms)));
        if (sleep_ms == 0) sleep_ms = 1;
        self.timer_active = true;
        self.timer.run(self.loop.?, &self.timer_completion, sleep_ms, ClientConnection, self, on_timeout);
    }

    /// Installs the post-connect deadline and arms the timer if idle.
    ///
    /// An already-armed timer wakes on its capped sleep, observes the new
    /// deadline, and re-arms with the exact remainder.
    fn enter_read_phase(self: *ClientConnection) void {
        self.deadline_ms = now_ms(self.io) + @as(i64, self.options.read_timeout_ms);
        self.arm_deadline();
    }

    fn arm_read(self: *ClientConnection) void {
        if (self.read_active or self.phase == .teardown) return;
        self.read_active = true;
        self.socket.read(
            self.loop.?,
            &self.read_completion,
            .{ .slice = &self.read_buffer },
            ClientConnection,
            self,
            on_read,
        );
    }

    fn arm_plain_write(self: *ClientConnection, bytes: []const u8) void {
        self.write_requested_len = bytes.len;
        self.write_active = true;
        self.socket.write(
            self.loop.?,
            &self.write_completion,
            .{ .slice = bytes },
            ClientConnection,
            self,
            on_write,
        );
    }

    fn arm_tls_write(self: *ClientConnection) void {
        if (self.write_active or self.phase == .teardown) return;
        self.write_requested_len = self.tls_out_len - self.tls_out_sent;
        self.write_active = true;
        self.socket.write(
            self.loop.?,
            &self.write_completion,
            .{ .slice = self.tls_out_buffer[self.tls_out_sent..self.tls_out_len] },
            ClientConnection,
            self,
            on_write,
        );
    }

    /// Advances whichever protocol path owns the socket.
    fn pump(self: *ClientConnection) void {
        if (self.phase == .teardown) return;
        if (self.session.ssl != null) {
            if (!self.handshake_done and !self.drive_handshake()) return;
            if (self.phase == .sending) self.send_tls_request();
            // Staged ciphertext must drain even after the request is queued.
            _ = self.flush_tls_out();
            return;
        }
        self.send_plain_request();
    }

    fn send_plain_request(self: *ClientConnection) void {
        while (self.phase == .sending and !self.write_active) {
            if (self.head_sent < self.request_head_len) {
                self.arm_plain_write(self.request_head[self.head_sent..self.request_head_len]);
                return;
            }
            if (self.body_sent < self.request.body.len) {
                self.arm_plain_write(self.request.body[self.body_sent..]);
                return;
            }
            self.phase = .receiving;
        }
    }

    fn send_tls_request(self: *ClientConnection) void {
        const ssl = self.session.ssl orelse {
            self.fail(.tls, "TLS session unavailable");
            return;
        };
        while (self.phase == .sending and !self.write_active) {
            const chunk = self.next_plaintext_chunk() orelse return;
            const write_len: c_int = @intCast(@min(chunk.len, tls_plaintext_chunk));
            const written = c.SSL_write(ssl, chunk.ptr, write_len);
            if (written <= 0) {
                const ssl_error = c.SSL_get_error(ssl, written);
                if (ssl_error == c.SSL_ERROR_WANT_WRITE) {
                    _ = self.flush_tls_out();
                    return;
                }
                self.fail(.tls, "TLS request write failed");
                return;
            }
            if (self.head_sent < self.request_head_len) {
                self.head_sent += @intCast(written);
            } else {
                self.body_sent += @intCast(written);
            }
            if (!self.flush_tls_out()) return;
        }
    }

    fn next_plaintext_chunk(self: *ClientConnection) ?[]const u8 {
        if (self.head_sent < self.request_head_len) {
            return self.request_head[self.head_sent..self.request_head_len];
        }
        if (self.body_sent < self.request.body.len) {
            return self.request.body[self.body_sent..];
        }
        self.phase = .receiving;
        return null;
    }

    fn drive_handshake(self: *ClientConnection) bool {
        const ssl = self.session.ssl orelse {
            self.fail(.tls, "TLS session unavailable");
            return false;
        };
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const status = handshake.step(ssl);
            if (!self.flush_tls_out()) return false;

            switch (status) {
                .success => {
                    self.handshake_done = true;
                    self.phase = .sending;
                    return true;
                },
                .want_read => return false,
                .want_write => {
                    const network_bio = self.session.network_bio orelse return false;
                    if (c.BIO_ctrl_pending(network_bio) != 0) return false;
                },
                .failed => {
                    self.fail(.tls, "TLS handshake failed");
                    return false;
                },
            }
        }
        self.fail(.tls, "TLS handshake stalled");
        return false;
    }

    /// Drains BoringSSL ciphertext into the socket staging buffer.
    fn flush_tls_out(self: *ClientConnection) bool {
        const network_bio = self.session.network_bio orelse {
            self.fail(.tls, "TLS session unavailable");
            return false;
        };
        if (self.tls_out_sent == self.tls_out_len) {
            self.tls_out_sent = 0;
            self.tls_out_len = 0;
        }
        while (c.BIO_ctrl_pending(network_bio) > 0 and self.tls_out_len < self.tls_out_buffer.len) {
            const pending: usize = @intCast(c.BIO_ctrl_pending(network_bio));
            const read_len = @min(pending, self.tls_out_buffer.len - self.tls_out_len);
            const read_bytes = c.BIO_read(
                network_bio,
                self.tls_out_buffer[self.tls_out_len..].ptr,
                @intCast(read_len),
            );
            if (read_bytes <= 0) {
                self.fail(.tls, "TLS output buffering failed");
                return false;
            }
            self.tls_out_len += @intCast(read_bytes);
        }
        if (self.tls_out_sent < self.tls_out_len) self.arm_tls_write();
        return true;
    }

    fn process_tls_data(self: *ClientConnection, encrypted: []const u8) void {
        const network_bio = self.session.network_bio orelse {
            self.fail(.tls, "TLS session unavailable");
            return;
        };
        var offset: usize = 0;
        while (offset < encrypted.len) {
            const remaining = encrypted.len - offset;
            const write_len: c_int = @intCast(@min(remaining, std.math.maxInt(c_int)));
            const written = c.BIO_write(network_bio, encrypted[offset..].ptr, write_len);
            if (written <= 0) {
                self.fail(.tls, "TLS record buffering failed");
                return;
            }
            offset += @intCast(written);
        }

        if (!self.handshake_done and !self.drive_handshake()) return;
        // A handshake that completes on a read callback must still queue the
        // request plaintext; no write completion is guaranteed to follow.
        self.pump();
        if (self.phase == .teardown) return;
        self.drain_tls_plaintext();
    }

    fn drain_tls_plaintext(self: *ClientConnection) void {
        const ssl = self.session.ssl orelse return;
        var plain_buffer: [socket_read_capacity]u8 = undefined;
        while (self.phase != .teardown) {
            const read_bytes = c.SSL_read(ssl, &plain_buffer, plain_buffer.len);
            if (read_bytes > 0) {
                self.consume_response(plain_buffer[0..@intCast(read_bytes)]);
                continue;
            }

            const ssl_error = c.SSL_get_error(ssl, read_bytes);
            switch (ssl_error) {
                c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => {},
                c.SSL_ERROR_ZERO_RETURN => self.handle_eof(),
                else => self.fail(.tls, "TLS record processing failed"),
            }
            break;
        }
        if (self.phase == .teardown) return;
        _ = self.flush_tls_out();
    }

    /// Appends plaintext and advances the response parser.
    fn consume_response(self: *ClientConnection, data: []const u8) void {
        if (self.phase == .teardown) return;

        const available = self.response_buffer.len - self.raw_len;
        const take = @min(data.len, available);
        @memcpy(self.response_buffer[self.raw_len..][0..take], data[0..take]);
        self.raw_len += take;

        switch (self.parser.consume(&self.response_buffer, self.raw_len)) {
            .need_more => {
                self.raw_len = self.parser.compact(&self.response_buffer, self.raw_len);
                if (take == data.len) return;
                if (self.parser.head_parsed()) {
                    self.fail(.capacity, "response body exceeded the configured capacity");
                    return;
                }
                self.fail(.protocol, "response head exceeded the client bound");
            },
            .complete => |view| {
                self.outcome = .{ .response = view };
                self.teardown();
            },
            .failed => |failure| self.fail_parse(failure),
        }
    }

    fn handle_eof(self: *ClientConnection) void {
        if (self.session.ssl != null and !self.handshake_done) {
            self.fail(.tls, "TLS handshake failed");
            return;
        }
        if (self.parser.state != .eof_body) {
            self.fail(.closed, "connection closed before the response completed");
            return;
        }
        switch (self.parser.finish_eof(&self.response_buffer, self.raw_len)) {
            .complete => |view| {
                self.outcome = .{ .response = view };
                self.teardown();
            },
            .failed => |failure| self.fail_parse(failure),
            .need_more => self.fail_parse(.malformed),
        }
    }

    fn handle_read_failure(self: *ClientConnection, err: anyerror) void {
        if (err == error.Canceled) {
            self.maybe_release();
            return;
        }
        if (err == error.EOF) {
            self.handle_eof();
            return;
        }
        log.debug("client read failed: {}", .{err});
        if (self.session.ssl != null and !self.handshake_done) {
            self.fail(.tls, "TLS handshake failed");
            return;
        }
        self.fail(.closed, "connection closed before the response completed");
    }

    fn on_connect(
        user_data: ?*ClientConnection,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        result: xev.ConnectError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.connect_active = false;
        if (self.phase == .teardown) {
            self.maybe_release();
            return .disarm;
        }

        result catch |err| {
            log.debug("client connect failed: {}", .{err});
            self.fail(.connect, "TCP connect failed");
            return .disarm;
        };

        self.arm_read();
        self.phase = if (self.session.ssl != null) .handshaking else .sending;
        self.enter_read_phase();
        if (self.phase == .teardown) return .disarm;
        self.pump();
        return .disarm;
    }

    fn on_read(
        user_data: ?*ClientConnection,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.read_active = false;
        if (self.phase == .teardown) {
            self.maybe_release();
            return .disarm;
        }

        const bytes_read = result catch |err| {
            self.handle_read_failure(err);
            return .disarm;
        };
        if (bytes_read == 0 or bytes_read > self.read_buffer.len) {
            if (bytes_read == 0) self.handle_eof() else self.fail(.closed, "read overflow");
            return .disarm;
        }

        const data = self.read_buffer[0..bytes_read];
        if (self.session.ssl != null) {
            self.process_tls_data(data);
        } else {
            self.consume_response(data);
        }

        if (self.phase == .teardown) return .disarm;
        self.read_active = true;
        return .rearm;
    }

    fn on_write(
        user_data: ?*ClientConnection,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.WriteBuffer,
        result: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.write_active = false;
        if (self.phase == .teardown) {
            self.maybe_release();
            return .disarm;
        }

        const written = result catch |err| {
            log.debug("client write failed: {}", .{err});
            self.fail(.closed, "request write failed");
            return .disarm;
        };
        if (written == 0 or written > self.write_requested_len) {
            self.fail(.closed, "request write failed");
            return .disarm;
        }

        if (self.session.ssl != null) {
            self.tls_out_sent += written;
            if (self.tls_out_sent == self.tls_out_len) {
                self.tls_out_len = 0;
                self.tls_out_sent = 0;
            }
        } else if (self.head_sent < self.request_head_len) {
            self.head_sent += written;
        } else {
            self.body_sent += written;
        }
        self.write_requested_len = 0;
        self.pump();
        return .disarm;
    }

    fn on_close(
        user_data: ?*ClientConnection,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        result: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        _ = result catch |err| log.debug("client socket close failed: {}", .{err});

        self.close_complete = true;
        if (xev.cancel_abandons_target()) {
            // epoll drops the target callback; clear the target flags. kqueue
            // and io_uring deliver it, so their callbacks own these flags.
            self.connect_active = false;
            self.read_active = false;
            self.write_active = false;
        }
        self.maybe_release();
        return .disarm;
    }

    fn on_timeout(
        user_data: ?*ClientConnection,
        _: *xev.Loop,
        _: *xev.Completion,
        result: anyerror!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.timer_active = false;

        _ = result catch |err| {
            if (err == error.Canceled) {
                self.maybe_release();
                return .disarm;
            }
            self.fail(.timeout, "request deadline expired");
            return .disarm;
        };

        if (self.phase == .teardown) {
            self.maybe_release();
            return .disarm;
        }
        if (now_ms(self.io) >= self.deadline_ms) {
            self.fail(.timeout, "request deadline expired");
            return .disarm;
        }
        self.arm_deadline();
        return .disarm;
    }

    fn on_timeout_cancel_complete(
        user_data: ?*ClientConnection,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.CancelError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.timer_active = false;
        self.timer_cancel_active = false;
        _ = result catch |err| {
            if (err != error.NotFound) log.debug("client timer cancel failed: {}", .{err});
        };
        self.maybe_release();
        return .disarm;
    }

    fn on_connect_cancel_complete(
        user_data: ?*ClientConnection,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.CancelError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.connect_cancel_active = false;
        _ = result catch |err| {
            if (err != error.NotFound) log.debug("client connect cancel failed: {}", .{err});
        };
        self.maybe_release();
        return .disarm;
    }

    fn on_read_cancel_complete(
        user_data: ?*ClientConnection,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.CancelError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.read_cancel_active = false;
        _ = result catch |err| {
            if (err != error.NotFound) log.debug("client read cancel failed: {}", .{err});
        };
        self.maybe_release();
        return .disarm;
    }

    fn on_write_cancel_complete(
        user_data: ?*ClientConnection,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.CancelError!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        self.write_cancel_active = false;
        _ = result catch |err| {
            if (err != error.NotFound) log.debug("client write cancel failed: {}", .{err});
        };
        self.maybe_release();
        return .disarm;
    }
};

fn now_ms(io: std.Io) i64 {
    const now = std.Io.Clock.now(.awake, io);
    return @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
}
