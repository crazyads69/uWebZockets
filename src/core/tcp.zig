const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const c = @import("c");
const Loop = @import("loop.zig").Loop;
const core_loop = @import("loop.zig");
const http_parser = @import("../http/parser.zig");
const HttpParser = http_parser.HttpParser;
const http_status = @import("../http/status.zig");
const Request = @import("../http/request.zig").Request;
const http_response = @import("../http/response.zig");
const Response = http_response.Response;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const ws_handshake = @import("../ws/handshake.zig");
const radix = @import("../router/radix.zig");
const Router = radix.Router;
const handshake = @import("../crypto/handshake.zig");
const tls = @import("../crypto/tls.zig");
const abort = @import("../http/abort.zig");
const DeflateContext = @import("../ws/deflate.zig").Context;
const http2_server = @import("../http2/server.zig");
const http_rejection = @import("../http/rejection.zig");
const http_compression_pool = @import("../http/compression_pool.zig");
const zero_copy = @import("zero_copy.zig");
const tcp_file = @import("tcp_file.zig");
const dev_log = @import("../observability/dev_log.zig");
const metrics = @import("../observability/metrics.zig");
const zslay = @import("zslay");

const log = std.log.scoped(.tcp);

/// Bytes read from one POSIX socket completion at a time.
pub const socket_read_capacity = 8192;
/// Seconds a completed handshake waits for data before reporting an accept.
pub const defer_accept_seconds: c_int = 1;
/// Default maximum buffered HTTP/1 request bytes per TCP connection.
pub const request_buffer_capacity = http_parser.max_request_line_size +
    http_parser.max_header_size + http_parser.default_max_body_size + 1024;
/// Default bounded pending-output capacity per TCP connection.
pub const default_write_queue_capacity = 64 * 1024;
/// Maximum simultaneous HTTP/2 request streams per TCP connection.
pub const max_http2_streams = 8;
/// Kernel-streamed bytes one connection may push in a single loop tick.
pub const file_tick_budget: usize = 4 * zero_copy.max_chunk;
/// First delayed accept retry after a repeated listener failure.
pub const accept_retry_initial_ms: u64 = 1;
/// Upper bound on the accept retry delay.
pub const accept_retry_max_ms: u64 = 1000;
/// Consecutive failures tolerated before any delay is applied.
///
/// libxev erases the errno for POSIX accept failures, so EMFILE, EAGAIN, and
/// ECONNABORTED are indistinguishable here. A single transient abort must not
/// throttle the listener.
pub const accept_failure_grace: u8 = 1;

const tls_bio_capacity = 32 * 1024;
const tls_plaintext_record_capacity = 16 * 1024;
const tls_record_overhead = 64;
/// HTTP/2 session type sized for one TCP connection's stream capacity.
pub const Http2Session = http2_server.server_session(max_http2_streams);

/// Per-stream context for one asynchronous HTTP/2 response.
const Http2AsyncContext = struct {
    connection: *TcpConnection = undefined,
    stream_id: u32 = 0,
};

/// Returns a fully closed connection to its owning fixed-capacity pool.
pub const CloseCallback = *const fn (pool_ptr: *anyopaque, conn: *TcpConnection) void;

/// Plaintext protocol selected for one TCP connection.
pub const ProtocolState = enum(u8) {
    detect,
    http,
    http2,
    websocket,
};

/// Event-loop-confined TCP/TLS connection with bounded protocol storage.
pub const TcpConnection = struct {
    router: *const Router = undefined,
    pubsub: ?*@import("../ws/pubsub.zig").PubSubEngine = null,
    pool_ptr: ?*anyopaque = null,
    on_close_cb: ?CloseCallback = null,
    // Thread-owned development-log batch, or null when the feature is off.
    dev_log: ?*dev_log.Sink = null,
    // Hidden counter registry, or null when observability is off.
    metrics: ?*metrics.Registry = null,
    reject_policy: *const http_rejection.RejectionPolicy = &http_rejection.RejectionPolicy.default,
    loop: *xev.Loop = undefined,
    io: std.Io = undefined,
    socket: xev.TCP,
    ws_message_buffer: []u8 = &.{},
    ws_compression_buffer: []u8 = &.{},
    ws_compression_output_buffer: []u8 = &.{},
    ws_deflate: ?*DeflateContext = null,
    abort_controller: abort.AbortController = .{},

    read_completion: xev.Completion = .{},
    write_completion: xev.Completion = .{},
    close_completion: xev.Completion = .{},
    read_cancel_completion: xev.Completion = .{},
    write_cancel_completion: xev.Completion = .{},

    req: Request = .{},
    parser: HttpParser = .{},
    ws: WebSocket = .{},
    h2: Http2Session = .{},
    h2_async_states: [max_http2_streams]http_response.AsyncResponseState =
        .{http_response.AsyncResponseState{}} ** max_http2_streams,
    h2_async_contexts: [max_http2_streams]Http2AsyncContext = undefined,
    // Drain-driven HTTP/2 bodies, parallel to the async slots. The producer
    // owns its stream until it reports done or the stream is reset.
    h2_stream_producers: [max_http2_streams]?http_response.StreamProducer =
        .{null} ** max_http2_streams,
    h2_stream_producer_contexts: [max_http2_streams]*anyopaque = undefined,
    h2_stream_producer_close: [max_http2_streams]bool = .{false} ** max_http2_streams,
    // Status of the streaming response head committed per stream slot; zero
    // until `begin_response` succeeds. Completion logs read it before the
    // terminal frame releases the slot.
    h2_response_status: [max_http2_streams]u16 = .{0} ** max_http2_streams,

    last_active_ms: i64 = 0,
    request_len: usize = 0,
    write_head: usize = 0,
    write_len: usize = 0,
    write_in_flight_len: usize = 0,

    // Kernel-streamed response body. The connection owns the handle whenever
    // `file_body` is set and closes it when the body drains or the peer dies.
    file_body: ?std.Io.File = null,
    file_offset: u64 = 0,
    file_remaining: u64 = 0,
    file_close_after: bool = false,

    // Drain-driven response producer. Set while a `begin_stream` body still has
    // bytes to pull; cleared when the producer finishes or the connection dies.
    stream_context: ?*anyopaque = null,
    stream_producer: ?http_response.StreamProducer = null,
    stream_close_after: bool = false,

    ssl: ?*c.SSL = null,
    network_bio: ?*c.BIO = null,
    protocol_state: ProtocolState = .detect,
    is_tls_handshake_done: bool = false,
    tls_shutdown_started: bool = false,
    read_active: bool = false,
    is_writing: bool = false,
    read_cancel_active: bool = false,
    write_cancel_active: bool = false,
    close_complete: bool = false,
    was_backpressured: bool = false,
    close_when_drained: bool = false,
    closing: bool = false,
    expect_continue_sent: bool = false,
    suppress_response_body: bool = false,
    dispatch_suspended: bool = false,
    pending_close_requested: bool = false,
    // Depth of the current read-dispatch write batch. Nested protocol entry
    // points increment the counter; only the outermost decrement flushes.
    write_batch_depth: u8 = 0,

    pending_request_consumed: usize = 0,
    protocol_probe_len: usize = 0,
    async_response_state: http_response.AsyncResponseState = .{},

    read_buffer: [socket_read_capacity]u8 = undefined,
    // Carved by the owning application from its contiguous request slab; the
    // stride must hold the request line, headers, and the configured body cap.
    request_buffer: []u8 = &.{},
    tls_write_buffer: [8192]u8 = undefined,
    protocol_probe: [@import("../http2/connection.zig").client_preface.len]u8 = undefined,
    /// Per-worker gzip pool borrowed from the owning application.
    http_compression: ?*http_compression_pool.Pool = null,
    write_queue: []u8 = &.{},
    // Per-connection route-capture capacity slices, set once by the owning
    // application and reused by every request dispatched on this connection.
    route_param_names: [][]const u8 = &.{},
    route_param_values: [][]const u8 = &.{},

    /// Resets protocol detection and bounded HTTP/2 state after pool acquire.
    pub fn reset_protocol(self: *TcpConnection) !void {
        self.abort_controller.reset();
        self.protocol_state = .detect;
        self.protocol_probe_len = 0;
        self.clear_stream();
        try self.h2.reset();
        for (&self.h2_async_states, &self.h2_async_contexts) |*state, *context| {
            state.cancel();
            context.* = .{ .connection = self };
        }
        for (0..max_http2_streams) |index| self.clear_http2_producer(@intCast(index));
        @memset(&self.h2_response_status, 0);
    }

    /// Returns a cancellation signal scoped to the current pooled connection.
    pub fn abort_signal(self: *const TcpConnection) abort.AbortSignal {
        return self.abort_controller.signal();
    }

    /// Allocates BoringSSL state and attaches bounded paired memory BIOs.
    pub fn init_tls(self: *TcpConnection, ssl_ctx: *c.SSL_CTX) !void {
        if (self.ssl != null or self.network_bio != null) return error.TlsAlreadyInitialized;

        const ssl = c.SSL_new(ssl_ctx) orelse return error.SslAllocationFailed;
        errdefer c.SSL_free(ssl);

        var ssl_bio: ?*c.BIO = null;
        var network_bio: ?*c.BIO = null;
        if (c.BIO_new_bio_pair(
            &ssl_bio,
            tls_bio_capacity,
            &network_bio,
            tls_bio_capacity,
        ) != 1) return error.BioAllocationFailed;
        errdefer {
            if (ssl_bio) |bio| _ = c.BIO_free(bio);
        }
        errdefer {
            if (network_bio) |bio| _ = c.BIO_free(bio);
        }

        c.SSL_set_bio(ssl, ssl_bio.?, ssl_bio.?);
        ssl_bio = null;
        c.SSL_set_accept_state(ssl);
        self.ssl = ssl;
        self.network_bio = network_bio;
        network_bio = null;
        self.tls_shutdown_started = false;
    }

    /// Releases BoringSSL and network BIO state when present.
    pub fn deinit_tls(self: *TcpConnection) void {
        const ssl = self.ssl orelse return;
        c.SSL_free(ssl);
        self.ssl = null;
        if (self.network_bio) |bio| _ = c.BIO_free(bio);
        self.network_bio = null;
        self.is_tls_handshake_done = false;
        self.tls_shutdown_started = false;
    }

    /// Feeds encrypted bytes through the handshake and plaintext dispatcher.
    pub fn process_tls_data(self: *TcpConnection, ssl: *c.SSL, encrypted_data: []const u8) void {
        const network_bio = self.network_bio orelse {
            close_connection(self);
            return;
        };
        var offset: usize = 0;

        while (offset < encrypted_data.len) {
            const remaining = encrypted_data.len - offset;
            const write_len: c_int = @intCast(@min(remaining, std.math.maxInt(c_int)));
            const written = c.BIO_write(network_bio, encrypted_data[offset..].ptr, write_len);
            if (written <= 0) {
                close_connection(self);
                return;
            }
            offset += @intCast(written);
        }

        if (!self.is_tls_handshake_done) {
            self.drive_tls_handshake(ssl) catch {
                close_connection(self);
                return;
            };
            if (!self.is_tls_handshake_done) return;
        }

        self.drain_tls_plaintext(ssl);
    }

    fn drive_tls_handshake(self: *TcpConnection, ssl: *c.SSL) !void {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const status = handshake.step(ssl);
            try self.flush_tls_out();

            switch (status) {
                .success => {
                    self.is_tls_handshake_done = true;
                    self.protocol_probe_len = 0;
                    switch (tls.negotiated_protocol(ssl)) {
                        .http2 => {
                            try self.h2.reset();
                            self.protocol_state = .http2;
                        },
                        .http1, .none => self.protocol_state = .http,
                    }
                    return;
                },
                .want_read => return,
                .want_write => {
                    const network_bio = self.network_bio orelse return error.TlsUnavailable;
                    if (c.BIO_ctrl_pending(network_bio) != 0) return;
                },
                .failed => return error.TlsHandshakeFailed,
            }
        }
        return error.TlsHandshakeStalled;
    }

    fn drain_tls_plaintext(self: *TcpConnection, ssl: *c.SSL) void {
        var plain_buffer: [socket_read_capacity]u8 = undefined;
        // Keep decrypted chunks inside one write batch until the BIO drains.
        begin_write_batch(self);
        defer end_write_batch(self);
        // A rejection or keep-alive drain already decided to close; do not keep
        // decrypting and dispatching buffered pipelined bytes after that point.
        while (!self.closing and !self.close_when_drained and !self.dispatch_suspended) {
            const read_bytes = c.SSL_read(ssl, &plain_buffer, plain_buffer.len);
            if (read_bytes > 0) {
                self.route_decrypted_data(plain_buffer[0..@intCast(read_bytes)]);
                continue;
            }

            const ssl_error = c.SSL_get_error(ssl, read_bytes);
            switch (ssl_error) {
                c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => break,
                c.SSL_ERROR_ZERO_RETURN => close_after_flush(self),
                // A server never observes EARLY_DATA_REJECTED: BoringSSL drops
                // unaccepted 0-RTT bytes and completes the handshake in place.
                else => close_connection(self),
            }
            break;
        }

        self.flush_tls_out() catch close_connection(self);
    }

    /// Routes mutable plaintext to HTTP/1, HTTP/2, or WebSocket state.
    pub fn route_decrypted_data(self: *TcpConnection, data: []u8) void {
        switch (self.protocol_state) {
            .detect => self.route_detect_data(data),
            .http => self.route_http_data(data),
            .http2 => self.route_http2_data(data),
            .websocket => {
                // Consecutive echo frames from one read share one write.
                begin_write_batch(self);
                defer end_write_batch(self);
                self.ws.on_data(data);
            },
        }
    }

    fn route_detect_data(self: *TcpConnection, data: []const u8) void {
        const preface = @import("../http2/connection.zig").client_preface;
        var offset: usize = 0;
        while (offset < data.len and self.protocol_probe_len < preface.len) {
            self.protocol_probe[self.protocol_probe_len] = data[offset];
            self.protocol_probe_len += 1;
            offset += 1;

            const probe = self.protocol_probe[0..self.protocol_probe_len];
            if (std.mem.eql(u8, probe, preface[0..probe.len])) continue;

            self.protocol_state = .http;
            self.route_http_data(probe);
            self.protocol_probe_len = 0;
            if (offset < data.len and !self.closing) self.route_http_data(data[offset..]);
            return;
        }

        if (self.protocol_probe_len != preface.len) return;
        self.protocol_state = .http2;
        self.route_http2_data(self.protocol_probe[0..self.protocol_probe_len]);
        self.protocol_probe_len = 0;
        if (offset < data.len and !self.closing) self.route_http2_data(data[offset..]);
    }

    fn route_http2_data(self: *TcpConnection, data: []const u8) void {
        const callbacks = self.http2_callbacks();
        self.h2.receive(data, callbacks) catch {
            close_connection(self);
            return;
        };
        if (self.h2.is_closed()) {
            close_after_flush(self);
            return;
        }
        if (self.closing or self.close_when_drained) return;
        // WINDOW_UPDATE frames processed above may have freed send credit for
        // producers parked on flow control.
        self.pump_http2_streams();
    }

    pub fn http2_callbacks(self: *TcpConnection) http2_server.Callbacks {
        return .{
            .context = self,
            .write_fn = write_http2_parts,
            .request_fn = dispatch_http2_request,
            .ws_data_fn = ws_http2_data,
            .stream_closed_fn = close_http2_stream,
            .max_frame_payload = http2_frame_payload_capacity(
                self.write_queue.len,
                self.ssl != null,
            ),
        };
    }

    fn close_http2_stream(context: *anyopaque, stream_id: u32, index: u16) void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        if (self.ws.initialized and self.ws.h2_stream_id == stream_id) self.ws.deinit();
        if (index >= self.h2_async_states.len) return;
        self.h2_response_status[index] = 0;
        // Producers have no stream-id mirror; a close notification is exact for
        // its slot, so the bounds check is the only guard the slot needs.
        self.clear_http2_producer(index);
        if (self.h2_async_contexts[index].stream_id != stream_id) return;
        if (self.h2_async_states[index].is_pending()) self.h2_async_states[index].cancel();
        self.h2_async_contexts[index].stream_id = 0;
    }

    fn write_http2_parts(context: *anyopaque, parts: []const []const u8) !void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        try tcp_file.write_data_parts(self, parts);
    }

    fn ws_http2_data(
        context: *anyopaque,
        stream_id: u32,
        data: []u8,
        end_stream: bool,
    ) bool {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        if (!self.ws.initialized or self.ws.h2_stream_id != stream_id) return false;
        self.ws.on_data(data);
        if (end_stream and self.ws.initialized and self.ws.h2_stream_id == stream_id) {
            self.ws.terminate();
        }
        return true;
    }

    /// Borrowed request identity and committed status for one HTTP/2 stream.
    const Http2ResponseTarget = struct {
        method: []const u8,
        path: []const u8,
        /// Zero when no response head is committed.
        status: u16,
    };

    /// Returns the request identity of an active HTTP/2 stream; null once the
    /// stream slot is released. The slices stay valid until the slot is reused.
    fn http2_response_target(
        self: *const TcpConnection,
        stream_id: u32,
    ) ?Http2ResponseTarget {
        const index = self.h2.connection.streams.find(stream_id) orelse return null;
        return .{
            .method = self.h2.requests[index].method,
            .path = self.h2.requests[index].path,
            .status = self.h2_response_status[index],
        };
    }

    /// Records one completed HTTP/2 request/response cycle in the log.
    pub fn log_request(
        self: *TcpConnection,
        method: []const u8,
        path: []const u8,
        status: u16,
    ) void {
        const sink = self.dev_log orelse dev_log.thread_sink();
        if (!sink.enabled) return;
        sink.record(.{
            .timestamp_ms = dev_log.now_ms(self.io),
            .level = .info,
            .direction = .data_out,
            .event = .{ .http_request = .{
                .method = method,
                .path = path,
                .status = status,
            } },
        });
    }

    fn dispatch_http2_request(
        context: *anyopaque,
        request: *Request,
        stream_id: u32,
    ) !void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        if (self.metrics) |registry| registry.add(.http_requests, 1);
        var response = Response{ .target = .{ .http2 = .{
            .context = self,
            .router = self.router,
            .stream_id = stream_id,
            .end_fn = end_http2_response,
            .begin_fn = begin_http2_response,
            .write_fn = write_http2_response,
            .finish_fn = finish_http2_response,
            .begin_stream_fn = begin_http2_stream,
            .compression_pool = self.http_compression,
        } } };
        const method = radix.HttpMethod.parse(request.method);
        if (self.early_data_forbids(method)) {
            // RFC 8470: the stream retries once the handshake is confirmed.
            try response.end("425 Too Early", "Early data is limited to safe methods");
            return;
        }
        if (!request.valid_query_content_type()) {
            try response.end("400 Bad Request", "QUERY requires a valid Content-Type");
            return;
        }
        // Dispatch is serialized on this loop, so wiring the connection's
        // reusable capture slices onto the request is race-free.
        request.extra_param_names = self.route_param_names;
        request.extra_param_values = self.route_param_values;
        request.extra_param_count = 0;
        const route = self.router.match_request(request, method);
        if (self.router.run_middleware(request, &response) == .stop) {
            try self.finish_http2_dispatch(&response);
            return;
        }
        if (method == .options and std.mem.eql(u8, request.path, "*")) {
            try response.end("204 No Content", "");
            return;
        }

        const matched_route = route orelse {
            try response.end("404 Not Found", "Route not found");
            return;
        };
        const handler = matched_route.handler orelse {
            if (method == .options) {
                self.send_method_response(
                    &response,
                    matched_route.allowed_methods,
                    "204 No Content",
                    "",
                );
                return;
            }
            if (matched_route.ws_behavior) |ws_behavior| {
                if (std.mem.eql(u8, request.method, "CONNECT") and std.mem.eql(u8, request.protocol, "websocket")) {
                    if (self.ws.initialized) {
                        try response.end("503 Service Unavailable", "WebSocket tunnel capacity reached");
                        return;
                    }
                    if (!radix.valid_ws_limits(ws_behavior, self.ws_message_buffer.len)) {
                        try response.end("500 Internal Server Error", "Invalid WebSocket limits");
                        return;
                    }
                    // RFC 8441 Section 5 supersedes Sec-WebSocket-Key
                    // processing with the `:protocol` pseudo-header, so only
                    // the version field participates in the handshake.
                    ws_handshake.validate_extended_connect(
                        request.get_unique_header("sec-websocket-version"),
                    ) catch |err| {
                        switch (err) {
                            error.MissingVersion, error.UnsupportedVersion => try response.end_with_headers(
                                "426 Upgrade Required",
                                "Sec-WebSocket-Version: 13\r\n",
                                "WebSocket version 13 required",
                            ),
                        }
                        return;
                    };
                    if (ws_behavior.upgrade) |authorize| {
                        if (!authorize(request)) {
                            try response.end("403 Forbidden", "WebSocket upgrade rejected");
                            return;
                        }
                    }

                    self.ws = WebSocket{
                        .conn = self,
                        .pubsub = self.pubsub,
                        .h2_stream_id = stream_id,
                        .behavior = ws_behavior,
                    };

                    self.ws.z_conn = zslay.Conn.init(&self.ws.tx_nodes, .{
                        .role = .server,
                        .max_frame_len = ws_behavior.max_frame_size,
                        .max_message_len = ws_behavior.max_message_size,
                    }) catch {
                        try response.end("500 Internal Server Error", "Invalid WebSocket limits");
                        return;
                    };

                    try response.begin_chunked("200 OK", "");
                    // The tunnel only becomes live after the 200 commits, so a
                    // failed commit cannot fire close without a preceding open.
                    self.ws.initialized = true;
                    self.log_request(request.method, request.path, 200);
                    if (self.ws.behavior.open) |callback| callback(&self.ws);
                    return;
                }
                try response.end("501 Not Implemented", "HTTP/2 WebSocket dispatch is unavailable");
                return;
            }
            self.send_method_response(
                &response,
                matched_route.allowed_methods,
                "405 Method Not Allowed",
                "Method Not Allowed",
            );
            return;
        };

        switch (handler) {
            .synchronous => |callback| callback(request, &response),
            .contextual => |binding| binding.callback(binding.context, request, &response),
            .asynchronous => |callback| {
                const token = try self.arm_http2_async(stream_id);
                callback(request, token);
                return;
            },
            .contextual_async => |binding| {
                const token = try self.arm_http2_async(stream_id);
                binding.callback(binding.context, request, token);
                return;
            },
        }
        try self.finish_http2_dispatch(&response);
    }

    fn finish_http2_dispatch(self: *TcpConnection, response: *Response) !void {
        if (response.is_complete()) return;
        if (response.is_started()) {
            // An armed producer owns completion; ending here would emit a
            // second terminal frame when the producer later calls end_chunks.
            switch (response.target) {
                .http2 => |target| {
                    if (self.h2.connection.streams.find(target.stream_id)) |index| {
                        if (self.h2_stream_producers[index] != null) return;
                    }
                },
                .tcp, .http3 => {},
            }
            try response.end_chunks();
            return;
        }
        try response.end("500 Internal Server Error", "Handler did not complete the response");
    }

    fn end_http2_response(
        context: *anyopaque,
        stream_id: u32,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        const callbacks = self.http2_callbacks();
        const target = self.http2_response_target(stream_id);
        const code = http_response.status_code(status) orelse return error.InvalidStatus;
        try self.h2.send_response(stream_id, status, headers, body, callbacks);
        if (target) |view| log_request(self, view.method, view.path, code);
    }

    fn begin_http2_response(
        context: *anyopaque,
        stream_id: u32,
        status: []const u8,
        headers: []const u8,
    ) !void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        const index = self.h2.connection.streams.find(stream_id) orelse
            return error.StreamClosed;
        const code = http_response.status_code(status) orelse return error.InvalidStatus;
        const callbacks = self.http2_callbacks();
        try self.h2.begin_response(stream_id, status, headers, callbacks);
        self.h2_response_status[index] = code;
    }

    fn write_http2_response(
        context: *anyopaque,
        stream_id: u32,
        bytes: []const u8,
    ) !void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        const callbacks = self.http2_callbacks();
        self.h2.write_response_data(stream_id, bytes, callbacks) catch |err| switch (err) {
            // Flow-control exhaustion is retryable: the reservation is atomic,
            // so no bytes or credit were consumed.
            error.SendWindowExhausted => return error.WouldBlock,
            else => |write_error| return write_error,
        };
    }

    fn finish_http2_response(context: *anyopaque, stream_id: u32) !void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        const callbacks = self.http2_callbacks();
        const target = self.http2_response_target(stream_id);
        self.h2.finish_response(stream_id, callbacks) catch |err| switch (err) {
            // The producer must retry its failed chunk before the terminal
            // frame can be written.
            error.ResponseWritePending => return error.WouldBlock,
            else => |finish_error| return finish_error,
        };
        if (target) |view| {
            if (view.status != 0) log_request(self, view.method, view.path, view.status);
        }
    }

    /// Arms one drain-driven HTTP/2 body and runs its first producer step.
    fn begin_http2_stream(
        context: *anyopaque,
        stream_id: u32,
        status: []const u8,
        headers: []const u8,
        producer_context: *anyopaque,
        producer: http_response.StreamProducer,
    ) anyerror!bool {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        const index = self.h2.connection.streams.find(stream_id) orelse
            return error.StreamClosed;
        const code = http_response.status_code(status) orelse return error.InvalidStatus;
        const callbacks = self.http2_callbacks();
        try self.h2.begin_response(stream_id, status, headers, callbacks);
        self.h2_response_status[index] = code;
        self.h2_stream_producers[index] = producer;
        self.h2_stream_producer_contexts[index] = producer_context;
        self.h2_stream_producer_close[index] = false;
        return self.step_http2_stream(index) == .done;
    }

    /// Advances one armed HTTP/2 producer; a producer error resets its stream.
    fn step_http2_stream(self: *TcpConnection, index: u16) http_response.StreamStatus {
        const producer = self.h2_stream_producers[index] orelse return .done;
        if (!self.h2.connection.streams.active[index]) {
            self.clear_http2_producer(index);
            return .done;
        }
        const producer_context = self.h2_stream_producer_contexts[index];
        const stream_id = self.h2.connection.streams.stream_ids[index];
        if (self.closing or self.close_when_drained) {
            self.clear_http2_producer(index);
            return .done;
        }

        var response = Response{
            .target = .{ .http2 = .{
                .context = self,
                .router = self.router,
                .stream_id = stream_id,
                .end_fn = end_http2_response,
                .begin_fn = begin_http2_response,
                .write_fn = write_http2_response,
                .finish_fn = finish_http2_response,
                .compression_pool = self.http_compression,
            } },
            .state = .streaming,
            .close_after_end = self.h2_stream_producer_close[index],
        };
        const status = producer(producer_context, &response) catch {
            const callbacks = self.http2_callbacks();
            self.h2.reset_stream(stream_id, .internal_error, callbacks) catch
                close_connection(self);
            self.clear_http2_producer(index);
            return .done;
        };
        if (status == .done) self.clear_http2_producer(index);
        return status;
    }

    /// Resumes every armed HTTP/2 producer after queued output drains.
    pub fn pump_http2_streams(self: *TcpConnection) void {
        for (0..self.h2_stream_producers.len) |slot| {
            if (self.closing or self.close_when_drained) return;
            if (self.h2_stream_producers[slot] == null) continue;
            _ = self.step_http2_stream(@intCast(slot));
        }
    }

    fn clear_http2_producer(self: *TcpConnection, index: u16) void {
        self.h2_stream_producers[index] = null;
        self.h2_stream_producer_contexts[index] = undefined;
        self.h2_stream_producer_close[index] = false;
    }

    fn arm_http2_async(
        self: *TcpConnection,
        stream_id: u32,
    ) !http_response.AsyncResponse {
        const index = self.h2.connection.streams.find(stream_id) orelse
            return error.StreamClosed;
        self.h2_async_contexts[index] = .{
            .connection = self,
            .stream_id = stream_id,
        };
        return self.h2_async_states[index].arm(.{
            .context = &self.h2_async_contexts[index],
            .complete_fn = complete_http2_async_response,
            .wake_fn = wake_http2_async_response,
        });
    }

    fn complete_http2_async_response(
        context: *anyopaque,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        const async_context: *Http2AsyncContext = @ptrCast(@alignCast(context));
        const self = async_context.connection;
        if (self.closing or self.close_complete) return error.ConnectionClosed;
        const callbacks = self.http2_callbacks();
        const target = self.http2_response_target(async_context.stream_id);
        const code = http_response.status_code(status) orelse return error.InvalidStatus;
        self.h2.send_response(
            async_context.stream_id,
            status,
            headers,
            body,
            callbacks,
        ) catch |err| {
            self.h2.reset_stream(
                async_context.stream_id,
                .internal_error,
                callbacks,
            ) catch close_connection(self);
            return err;
        };
        if (target) |view| log_request(self, view.method, view.path, code);
    }

    fn wake_http2_async_response(_: *anyopaque) void {
        // HTTP/2 reads remain armed while other streams await completion.
    }

    fn route_http_data(self: *TcpConnection, data: []const u8) void {
        // The outer TLS drain may already own a batch. Otherwise begin one
        // only when the parser proves another request follows, preserving the
        // single-request direct-send fast path.
        var batching = self.write_batch_depth != 0;
        if (batching) begin_write_batch(self);
        defer {
            if (batching) end_write_batch(self);
        }

        if (self.dispatch_suspended) {
            close_connection(self);
            return;
        }
        const available = self.request_buffer.len - self.request_len;
        if (data.len > available) {
            switch (self.parser.state) {
                .body, .chunk_size, .chunk_ext, .chunk_data, .chunk_crlf, .chunk_trailer => {
                    self.reject_payload_too_large();
                },
                else => self.reject_headers_too_large(),
            }
            return;
        }

        @memcpy(self.request_buffer[self.request_len .. self.request_len + data.len], data);
        self.request_len += data.len;

        while (self.request_len > 0 and !self.closing) {
            const consumed = http_parser.consume(
                &self.parser,
                &self.req,
                self.request_buffer[0..self.request_len],
            );

            if (self.parser.state == .error_invalid) {
                self.reject_http("400 Bad Request", "Bad Request");
                return;
            }
            if (self.parser.state == .error_headers_too_large) {
                self.reject_headers_too_large();
                return;
            }
            if (self.parser.state == .error_too_large) {
                self.reject_payload_too_large();
                return;
            }
            if (self.parser.state != .done) {
                self.handle_expect_continue();
                return;
            }

            const close_requested = self.req.header_has_token("Connection", "close");
            if (!batching and consumed < self.request_len) {
                begin_write_batch(self);
                batching = true;
            }
            self.dispatch_request();
            if (self.closing or self.close_when_drained) return;
            if (self.dispatch_suspended) {
                self.pending_request_consumed = consumed;
                self.pending_close_requested = close_requested;
                return;
            }

            if (self.protocol_state == .websocket) {
                if (consumed < self.request_len) {
                    self.ws.on_data(self.request_buffer[consumed..self.request_len]);
                }
                self.request_len = 0;
                return;
            }

            if (close_requested) {
                close_after_flush(self);
                return;
            }

            const remaining = self.request_len - consumed;
            std.mem.copyForwards(
                u8,
                self.request_buffer[0..remaining],
                self.request_buffer[consumed..self.request_len],
            );
            self.request_len = remaining;
            self.req = .{};
            http_parser.reset(&self.parser);
            self.expect_continue_sent = false;
            self.suppress_response_body = false;
        }
    }

    fn dispatch_request(self: *TcpConnection) void {
        var response = Response{ .target = .{ .tcp = self } };
        const method = radix.HttpMethod.parse(self.req.method);
        self.suppress_response_body = method == .head;

        if (self.metrics) |registry| registry.add(.http_requests, 1);

        if (self.early_data_forbids(method)) {
            // RFC 8470: tell the client to retry once the handshake confirms.
            response.end_with_headers(
                "425 Too Early",
                "Connection: close\r\n",
                "Early data is limited to safe methods",
            ) catch close_connection(self);
            return;
        }

        if (!self.req.valid_query_content_type()) {
            response.end("400 Bad Request", "QUERY requires a valid Content-Type") catch
                close_connection(self);
            return;
        }
        self.req.extra_param_names = self.route_param_names;
        self.req.extra_param_values = self.route_param_values;
        self.req.extra_param_count = 0;
        const route = self.router.match_request(&self.req, method);
        if (self.router.run_middleware(&self.req, &response) == .stop) {
            self.finish_sync_dispatch(&response);
            return;
        }

        if (method == .options and std.mem.eql(u8, self.req.path, "*")) {
            response.end("204 No Content", "") catch close_connection(self);
            return;
        }

        const matched_route = route orelse {
            response.end("404 Not Found", "Route not found") catch close_connection(self);
            return;
        };

        const websocket_intent = matched_route.ws_behavior != null and method == .get and
            (self.req.get_header("Upgrade") != null or self.req.header_has_token("Connection", "upgrade"));
        if (websocket_intent) {
            self.ws = WebSocket{ .conn = self, .pubsub = self.pubsub };
            self.ws.upgrade(&self.req, &response, matched_route.ws_behavior.?);
            return;
        }

        if (matched_route.handler) |handler| {
            self.invoke_handler(handler, &response);
            return;
        }

        if (method == .options) {
            self.send_method_response(&response, matched_route.allowed_methods, "204 No Content", "");
            return;
        }

        if (matched_route.ws_behavior != null and method == .get) {
            response.end_with_headers(
                "426 Upgrade Required",
                "Connection: close\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n",
                "WebSocket upgrade required",
            ) catch {
                close_connection(self);
                return;
            };
            close_after_flush(self);
            return;
        }

        self.send_method_response(&response, matched_route.allowed_methods, "405 Method Not Allowed", "Method Not Allowed");
    }

    fn invoke_handler(self: *TcpConnection, handler: radix.RouteHandler, response: *Response) void {
        switch (handler) {
            .synchronous => |callback| {
                callback(&self.req, response);
                self.finish_sync_dispatch(response);
            },
            .contextual => |binding| {
                binding.callback(binding.context, &self.req, response);
                self.finish_sync_dispatch(response);
            },
            .asynchronous => |callback| {
                const token = self.async_response_state.arm(self.async_target());
                callback(&self.req, token);
                self.dispatch_suspended = token.is_pending();
            },
            .contextual_async => |binding| {
                const token = self.async_response_state.arm(self.async_target());
                binding.callback(binding.context, &self.req, token);
                self.dispatch_suspended = token.is_pending();
            },
        }
    }

    fn finish_sync_dispatch(self: *TcpConnection, response: *Response) void {
        if (response.is_complete()) {
            // A handler that ended its own streaming response leaves no
            // producer behind; clear any armed one defensively.
            self.clear_stream();
            return;
        }
        if (self.stream_producer != null) {
            // The producer owns completion and resumes dispatch on finish.
            self.dispatch_suspended = true;
            return;
        }
        if (response.is_started()) {
            close_after_flush(self);
            return;
        }
        response.end("500 Internal Server Error", "Handler did not complete the response") catch
            close_connection(self);
    }

    /// Arms a drained chunked body and pumps it once; true when finished.
    pub fn start_stream(
        self: *TcpConnection,
        context: *anyopaque,
        producer: http_response.StreamProducer,
        close_after: bool,
    ) bool {
        self.stream_context = context;
        self.stream_producer = producer;
        self.stream_close_after = close_after;
        return self.step_stream() == .done;
    }

    /// Advances the active producer once, clearing it when it finishes.
    fn step_stream(self: *TcpConnection) http_response.StreamStatus {
        const producer = self.stream_producer orelse return .done;
        const context = self.stream_context.?;
        if (self.closing or self.close_when_drained) {
            self.clear_stream();
            return .done;
        }

        var response = Response{
            .target = .{ .tcp = self },
            .state = .streaming,
            .close_after_end = self.stream_close_after,
        };
        const status = producer(context, &response) catch {
            self.clear_stream();
            close_connection(self);
            return .done;
        };
        if (status == .done) self.clear_stream();
        return status;
    }

    /// Re-invokes the active producer after queued output drained.
    pub fn pump_stream_body(self: *TcpConnection) void {
        if (self.stream_producer == null or self.closing) return;
        if (self.step_stream() == .done) self.resume_async_dispatch();
    }

    fn clear_stream(self: *TcpConnection) void {
        self.stream_producer = null;
        self.stream_context = null;
        self.stream_close_after = false;
    }

    fn async_target(self: *TcpConnection) http_response.AsyncTarget {
        return .{
            .context = self,
            .complete_fn = complete_async_response,
            .wake_fn = wake_async_dispatch,
        };
    }

    fn complete_async_response(
        context: *anyopaque,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        if (self.closing or self.close_complete) return error.ConnectionClosed;
        var response = Response{ .target = .{ .tcp = self } };
        response.end_with_headers(status, headers, body) catch |err| {
            close_connection(self);
            return err;
        };
    }

    fn wake_async_dispatch(context: *anyopaque) void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        if (!self.dispatch_suspended or self.closing) return;
        self.resume_async_dispatch();
    }

    pub fn resume_async_dispatch(self: *TcpConnection) void {
        self.dispatch_suspended = false;
        const consumed = self.pending_request_consumed;
        self.pending_request_consumed = 0;
        if (self.close_when_drained) {
            self.pending_close_requested = false;
            return;
        }
        if (consumed > self.request_len) {
            close_connection(self);
            return;
        }
        if (self.pending_close_requested) {
            self.pending_close_requested = false;
            close_after_flush(self);
            return;
        }

        const remaining = self.request_len - consumed;
        std.mem.copyForwards(
            u8,
            self.request_buffer[0..remaining],
            self.request_buffer[consumed..self.request_len],
        );
        self.request_len = remaining;
        self.req = .{};
        http_parser.reset(&self.parser);
        self.expect_continue_sent = false;
        self.suppress_response_body = false;
        self.route_http_data(&.{});

        if (!self.dispatch_suspended and !self.closing and !self.close_when_drained) {
            if (self.ssl) |ssl| self.drain_tls_plaintext(ssl);
        }

        if (!self.dispatch_suspended and !self.closing and !self.close_when_drained and
            !self.read_active)
        {
            self.arm_read();
        }
    }

    fn arm_read(self: *TcpConnection) void {
        if (self.read_active or self.dispatch_suspended or self.closing) return;
        self.read_active = true;
        self.socket.read(
            self.loop,
            &self.read_completion,
            .{ .slice = &self.read_buffer },
            TcpConnection,
            self,
            on_read_complete,
        );
    }

    fn send_method_response(
        self: *TcpConnection,
        response: *Response,
        allowed_methods: u16,
        status: []const u8,
        body: []const u8,
    ) void {
        var allow_value_buffer: [64]u8 = undefined;
        const allow_value = radix.format_allowed_methods(allowed_methods, &allow_value_buffer) catch {
            close_connection(self);
            return;
        };
        var allow_header_buffer: [80]u8 = undefined;
        const allow_header = std.fmt.bufPrint(
            &allow_header_buffer,
            "Allow: {s}\r\n",
            .{allow_value},
        ) catch {
            close_connection(self);
            return;
        };
        response.end_with_headers(status, allow_header, body) catch close_connection(self);
    }

    fn handle_expect_continue(self: *TcpConnection) void {
        if (self.expect_continue_sent or self.closing) return;

        switch (self.parser.state) {
            .body, .chunk_size, .chunk_ext, .chunk_data, .chunk_crlf, .chunk_trailer => {},
            else => return,
        }

        const expect_count = self.req.count_headers("Expect");
        if (expect_count == 0) return;
        const expect = self.req.get_unique_header("Expect") orelse {
            self.reject_http("417 Expectation Failed", "Expectation Failed");
            return;
        };
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, expect, " \t"), "100-continue")) {
            self.reject_http("417 Expectation Failed", "Expectation Failed");
            return;
        }

        self.write_data("HTTP/1.1 100 Continue\r\n\r\n") catch {
            close_connection(self);
            return;
        };
        self.expect_continue_sent = true;
    }

    fn reject_http(self: *TcpConnection, status: []const u8, body: []const u8) void {
        var response = Response{ .target = .{ .tcp = self } };
        response.end_with_headers(status, "Connection: close\r\n", body) catch {
            close_connection(self);
            return;
        };
        close_after_flush(self);
    }

    /// Sends the structured 413 document describing the configured body limit.
    fn reject_payload_too_large(self: *TcpConnection) void {
        var buffer: [http_rejection.max_document_bytes]u8 = undefined;
        const body = self.reject_policy.payload_too_large(&buffer);
        self.reject_http_json("413 Payload Too Large", body);
    }

    /// Sends the structured 431 document describing the configured header limit.
    fn reject_headers_too_large(self: *TcpConnection) void {
        var buffer: [http_rejection.max_document_bytes]u8 = undefined;
        const body = self.reject_policy.headers_too_large(&buffer);
        self.reject_http_json("431 Request Header Fields Too Large", body);
    }

    fn reject_http_json(self: *TcpConnection, status: []const u8, body: []const u8) void {
        var response = Response{ .target = .{ .tcp = self } };
        response.end_with_headers(
            status,
            "Content-Type: application/json; charset=utf-8\r\nConnection: close\r\n",
            body,
        ) catch {
            close_connection(self);
            return;
        };
        close_after_flush(self);
    }

    fn flush_tls_out(self: *TcpConnection) !void {
        if (self.ssl == null) return;
        const network_bio = self.network_bio orelse return error.TlsUnavailable;

        while (c.BIO_ctrl_pending(network_bio) > 0) {
            const available = self.write_queue.len - self.write_len;
            if (available == 0) return;

            const pending: usize = @intCast(c.BIO_ctrl_pending(network_bio));
            const read_len = @min(pending, @min(self.tls_write_buffer.len, available));
            const read_bytes = c.BIO_read(network_bio, &self.tls_write_buffer, @intCast(read_len));
            if (read_bytes <= 0) return error.TlsWriteFailed;

            const encrypted = self.tls_write_buffer[0..@intCast(read_bytes)];
            try tcp_file.enqueue_plain_parts(self, &.{encrypted});
        }
    }

    pub fn write_tls_parts(self: *TcpConnection, parts: []const []const u8) !void {
        const ssl = self.ssl orelse return error.TlsUnavailable;
        const network_bio = self.network_bio orelse return error.TlsUnavailable;

        var plain_len: usize = 0;
        var record_count: usize = 0;
        for (parts) |part| {
            if (part.len > self.write_queue.len - plain_len) return error.WouldBlock;
            plain_len += part.len;

            const part_records = std.math.divCeil(
                usize,
                part.len,
                tls_plaintext_record_capacity,
            ) catch return error.WouldBlock;
            if (part_records > std.math.maxInt(usize) - record_count) return error.WouldBlock;
            record_count += part_records;
        }

        const pending: usize = @intCast(c.BIO_ctrl_pending(network_bio));
        if (record_count > self.write_queue.len / tls_record_overhead) return error.WouldBlock;
        const overhead = tls_record_overhead * record_count;
        if (overhead > self.write_queue.len - plain_len) return error.WouldBlock;
        const required = plain_len + overhead;
        if (pending > self.write_queue.len - required) return error.WouldBlock;
        if (self.write_batch_depth != 0 and
            required + pending > self.write_queue.len - self.write_len)
        {
            tcp_file.flush_batched(self);
            if (self.closing) return error.ConnectionClosed;
        }
        if (required + pending > self.write_queue.len - self.write_len) return error.WouldBlock;

        for (parts) |part| {
            var offset: usize = 0;
            while (offset < part.len) {
                const remaining = part.len - offset;
                const chunk_len: c_int = @intCast(@min(remaining, tls_plaintext_record_capacity));
                const written = c.SSL_write(ssl, part[offset..].ptr, chunk_len);
                if (written <= 0) {
                    const ssl_error = c.SSL_get_error(ssl, written);
                    if (ssl_error != c.SSL_ERROR_WANT_WRITE) return error.TlsWriteFailed;
                    try self.flush_tls_out();
                    continue;
                }
                offset += @intCast(written);
                try self.flush_tls_out();
            }
        }
    }

    fn begin_tls_shutdown(self: *TcpConnection) !void {
        if (self.tls_shutdown_started or !self.is_tls_handshake_done) return;
        const ssl = self.ssl orelse return;
        self.tls_shutdown_started = true;

        const result = c.SSL_shutdown(ssl);
        if (result < 0) {
            const ssl_error = c.SSL_get_error(ssl, result);
            if (ssl_error != c.SSL_ERROR_WANT_READ and ssl_error != c.SSL_ERROR_WANT_WRITE) {
                return error.TlsShutdownFailed;
            }
        }
        try self.flush_tls_out();
    }

    pub fn start_write(self: *TcpConnection) void {
        if (self.write_batch_depth != 0) return;
        self.arm_write();
    }

    /// Arms the current ring without consulting the batch depth.
    ///
    /// Only the batch flusher uses this on the fallback path after a partial
    /// direct send, so the completion can drain the remainder.
    pub fn arm_write(self: *TcpConnection) void {
        if (self.is_writing or self.write_len == 0 or self.closing) return;

        const contiguous_len = @min(self.write_len, self.write_queue.len - self.write_head);
        self.write_in_flight_len = contiguous_len;
        self.is_writing = true;
        self.socket.write(
            self.loop,
            &self.write_completion,
            .{ .slice = self.write_queue[self.write_head .. self.write_head + contiguous_len] },
            TcpConnection,
            self,
            on_write_complete,
        );
    }

    /// Starts a write batch for one read completion.
    ///
    /// Pipelined HTTP/1 responses and consecutive WebSocket frames append to
    /// the bounded send ring without arming a completion per frame; the
    /// outermost `end_write_batch` flushes them with one socket write.
    pub fn begin_write_batch(conn: *TcpConnection) void {
        if (conn.write_batch_depth != std.math.maxInt(u8)) conn.write_batch_depth += 1;
    }

    /// Ends one write batch and flushes when no enclosing batch remains.
    pub fn end_write_batch(conn: *TcpConnection) void {
        if (conn.write_batch_depth == 0) return;
        conn.write_batch_depth -= 1;
        if (conn.write_batch_depth != 0) return;
        tcp_file.flush_batched(conn);
        // A direct batch flush can empty the ring without running the write
        // completion, so settle backpressure here after handlers have returned.
        if (!conn.closing) settle_backpressure(conn);
    }

    /// Copies one plaintext slice into the bounded transport write path.
    pub fn write_data(self: *TcpConnection, data: []const u8) !void {
        try tcp_file.write_data_parts(self, &.{data});
    }

    /// Streams an owned regular file as the response body at the kernel boundary.
    ///
    /// Returns `error.ZeroCopyUnavailable` without taking ownership when TLS
    /// owns the stream, when the peer only expects headers, or on a platform
    /// whose completion port the transport cannot observe. On success the
    /// connection owns `file` and closes it when the body drains. The caller
    /// must not retain or close `file` after a successful call. `pending` and
    /// `headers` are queued-scratch and caller fields; they are copied into the
    /// write ring as scatter parts.
    pub fn begin_file_response(
        self: *TcpConnection,
        status: []const u8,
        pending: []const u8,
        headers: []const u8,
        file: std.Io.File,
        offset: u64,
        length: u64,
        close_after: bool,
    ) !void {
        if (comptime !zero_copy.kernel_send_supported) return error.ZeroCopyUnavailable;
        if (self.ssl != null) return error.ZeroCopyUnavailable;
        if (self.file_body != null) return error.FileBodyAlreadyActive;

        var framing_buffer: [128]u8 = undefined;
        const framing = try http_status.format_http1_framing(&framing_buffer, status, length);

        // HEAD keeps the transfer length but never streams body bytes.
        if (length == 0 or self.suppress_response_body) {
            try tcp_file.write_data_parts(self, &.{ framing, pending, headers, "\r\n" });
            file.close(self.io);
            if (close_after) close_after_flush(self);
            return;
        }

        // Ownership precedes the head write so neither the direct-send path nor
        // a batched direct flush can finish the head without arming the
        // completion that pumps the body.
        self.file_body = file;
        self.file_offset = offset;
        self.file_remaining = length;
        self.file_close_after = close_after;
        // HTTP/1 responses are ordered: hold pipelined dispatch until the body
        // drains so no later response can interleave with the file bytes.
        self.dispatch_suspended = true;
        tcp_file.write_data_parts(self, &.{ framing, pending, headers, "\r\n" }) catch |err| {
            // The transfer never started, so the caller still owns `file`.
            self.file_body = null;
            self.file_remaining = 0;
            self.file_close_after = false;
            self.dispatch_suspended = false;
            return err;
        };
    }

    /// Releases a pending response file without touching queued socket bytes.
    fn release_file_body(self: *TcpConnection) void {
        const file = self.file_body orelse return;
        self.file_body = null;
        self.file_remaining = 0;
        file.close(self.io);
    }

    /// Reports whether an unconfirmed handshake forbids this method.
    ///
    /// Early data is replayable, so only safe methods are dispatched before the
    /// handshake is confirmed.
    fn early_data_forbids(self: *const TcpConnection, method: ?radix.HttpMethod) bool {
        const ssl = self.ssl orelse return false;
        if (c.SSL_in_early_data(ssl) == 0) return false;
        const parsed = method orelse return true;
        return !radix.HttpMethod.early_data_safe(parsed);
    }

    /// Returns encrypted or plaintext bytes queued for the socket.
    pub fn buffered_amount(self: *const TcpConnection) usize {
        return self.write_len;
    }
};

/// Copies ordered parts into a caller-owned ring and returns the new tail.
///
/// `initial_tail` must be in range and the aggregate parts must fit `buffer`.
pub fn copy_parts_to_ring(buffer: []u8, initial_tail: usize, parts: []const []const u8) usize {
    std.debug.assert(buffer.len > 0);
    var tail = initial_tail;

    for (parts) |part| {
        const first_len = @min(part.len, buffer.len - tail);
        @memcpy(buffer[tail .. tail + first_len], part[0..first_len]);

        const second_len = part.len - first_len;
        if (second_len > 0) @memcpy(buffer[0..second_len], part[first_len..]);
        tail = (tail + part.len) % buffer.len;
    }
    return tail;
}

/// Copies the parts after the first `skip` bytes into a caller-owned ring and
/// returns the new tail.
///
/// The direct-send fast path queues exactly the suffix a partial `sendmsg`
/// left unsent; `skip` must not exceed the aggregate parts length.
pub fn copy_parts_suffix_to_ring(
    buffer: []u8,
    initial_tail: usize,
    parts: []const []const u8,
    skip: usize,
) usize {
    std.debug.assert(buffer.len > 0);
    var tail = initial_tail;
    var to_skip = skip;

    for (parts) |part| {
        if (to_skip >= part.len) {
            to_skip -= part.len;
            continue;
        }
        tail = copy_parts_to_ring(buffer, tail, &.{part[to_skip..]});
        to_skip = 0;
    }
    std.debug.assert(to_skip == 0);
    return tail;
}

/// Returns the largest nonempty HTTP/2 payload that always fits an empty queue.
pub fn http2_frame_payload_capacity(queue_capacity: usize, encrypted: bool) usize {
    const frame_header_size = 9;
    if (!encrypted) return queue_capacity -| frame_header_size;

    const record_overhead = 2 * tls_record_overhead;
    const fixed_cost = frame_header_size + record_overhead;
    return @min(
        queue_capacity -| fixed_cost,
        tls_plaintext_record_capacity,
    );
}

/// Arms the first asynchronous socket read for a prepared connection.
pub fn read_start(conn: *TcpConnection, loop: *Loop) void {
    conn.loop = loop.get_xev_loop();
    conn.arm_read();
}

fn on_read_complete(
    user_data: ?*TcpConnection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    buffer: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = completion;
    _ = socket;
    _ = buffer;

    const conn = user_data.?;
    conn.loop = loop;
    conn.read_active = false;

    if (conn.closing) {
        release_closed_connection(conn);
        return .disarm;
    }

    const bytes_read = result catch |err| {
        if (err != error.EOF and err != error.ConnectionResetByPeer) {
            log.warn("read error: {}", .{err});
        }
        close_connection(conn);
        release_closed_connection(conn);
        return .disarm;
    };

    if (bytes_read == 0) {
        close_connection(conn);
        release_closed_connection(conn);
        return .disarm;
    }

    const now = std.Io.Clock.now(.awake, conn.io);
    conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    const data = conn.read_buffer[0..bytes_read];
    if (conn.ssl) |ssl| {
        conn.process_tls_data(ssl, data);
    } else {
        conn.route_decrypted_data(data);
    }

    if (conn.closing or conn.close_when_drained) {
        release_closed_connection(conn);
        return .disarm;
    }
    if (conn.dispatch_suspended) return .disarm;
    conn.read_active = true;
    return .rearm;
}

fn on_write_complete(
    user_data: ?*TcpConnection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    buffer: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = socket;
    _ = buffer;

    const conn = user_data.?;
    conn.is_writing = false;

    if (conn.closing) {
        conn.write_in_flight_len = 0;
        release_closed_connection(conn);
        return .disarm;
    }

    const written = result catch |err| {
        log.warn("write error: {}", .{err});
        close_connection(conn);
        release_closed_connection(conn);
        return .disarm;
    };

    if (written == 0 or written > conn.write_in_flight_len) {
        close_connection(conn);
        release_closed_connection(conn);
        return .disarm;
    }

    const now = std.Io.Clock.now(.awake, conn.io);
    conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    conn.write_len -= written;
    conn.write_head = advance_write_head(
        conn.write_head,
        written,
        conn.write_len,
        conn.write_queue.len,
    );
    conn.write_in_flight_len = 0;

    conn.flush_tls_out() catch {
        close_connection(conn);
        return .disarm;
    };
    if (conn.ssl) |ssl| {
        if (!conn.is_tls_handshake_done and !conn.close_when_drained) {
            conn.drive_tls_handshake(ssl) catch {
                close_connection(conn);
                return .disarm;
            };
        }
    }
    if (conn.protocol_state == .http2 and !conn.close_when_drained) {
        conn.h2.flush_pending(conn.http2_callbacks()) catch {
            close_connection(conn);
            return .disarm;
        };
    }
    // Buffered frames and WINDOW credit freed by the flush can now resume
    // producers that stopped at transport backpressure.
    conn.pump_http2_streams();

    settle_backpressure(conn);

    if (conn.stream_producer != null) conn.pump_stream_body();

    if (conn.write_len == 0 and conn.close_when_drained) {
        close_connection(conn);
        return .disarm;
    }

    tcp_file.pump_file_body(conn);
    conn.start_write();
    return .disarm;
}

/// Clears transport backpressure and wakes a paused WebSocket producer.
///
/// The caller must be outside a user send callback: `notify_drain` may call
/// `ws.send` again, and re-entering the ring while a batch is still open would
/// reorder frames.
fn settle_backpressure(conn: *TcpConnection) void {
    if (!conn.was_backpressured) return;
    if (conn.write_len >= conn.write_queue.len / 2) return;
    conn.was_backpressured = false;
    if (conn.ws.initialized) conn.ws.notify_drain();
}

/// Advances a ring head after a completed partial or full write.
pub fn advance_write_head(
    current_head: usize,
    written: usize,
    remaining: usize,
    capacity: usize,
) usize {
    std.debug.assert(capacity != 0);
    if (remaining == 0) return 0;
    return (current_head + written) % capacity;
}

/// Closes plaintext or gracefully shuts down TLS after queued bytes drain.
pub fn close_after_flush(conn: *TcpConnection) void {
    if (conn.closing) return;
    conn.begin_tls_shutdown() catch {
        close_connection(conn);
        return;
    };
    conn.flush_tls_out() catch {
        close_connection(conn);
        return;
    };
    conn.close_when_drained = true;
    if (conn.write_len == 0 and !conn.is_writing) close_connection(conn);
}

/// Cancels active completions and begins idempotent socket teardown.
pub fn close_connection(conn: *TcpConnection) void {
    if (conn.closing) return;
    conn.closing = true;
    _ = conn.abort_controller.abort(.connection_closed);
    conn.close_when_drained = false;
    conn.dispatch_suspended = false;
    conn.pending_request_consumed = 0;
    conn.pending_close_requested = false;
    conn.write_batch_depth = 0;
    conn.clear_stream();
    conn.protocol_probe_len = 0;
    conn.async_response_state.cancel();
    for (&conn.h2_async_states) |*state| state.cancel();

    if (conn.ws.initialized) conn.ws.deinit();
    conn.release_file_body();
    conn.deinit_tls();

    if ((conn.read_active or conn.is_writing) and
        (builtin.os.tag == .windows or xev.submit_before_cancel()))
    {
        // A completion canceled before it starts may never deliver its own
        // callback: IOCP marks it dead, and kqueue drops it while it is still
        // in the submission queue. Flush first so every cancel observes an
        // active target whose callback clears the target flag.
        xev.submit(conn.loop) catch |err| {
            // Keep the target flags set: the backend cannot dispatch the
            // queued completions, so reusing the slot could fire a stale
            // callback into a new connection. Shutdown fails closed instead.
            log.err("queued completion submit failed before close: {}", .{err});
        };
    }

    // Cancel every armed completion so each backend drops its active count
    // before the descriptor closes. kqueue abandons the target callback but
    // still completes the cancel, so the close path waits for both.
    if (conn.read_active) {
        conn.read_cancel_active = true;
        core_loop.cancel(
            conn.loop,
            &conn.read_completion,
            &conn.read_cancel_completion,
            TcpConnection,
            conn,
            on_read_cancel_complete,
        );
    }
    if (conn.is_writing) {
        conn.write_cancel_active = true;
        core_loop.cancel(
            conn.loop,
            &conn.write_completion,
            &conn.write_cancel_completion,
            TcpConnection,
            conn,
            on_write_cancel_complete,
        );
    }

    if (builtin.os.tag == .windows) {
        close_socket(xev.tcp_fd(conn.socket));
        conn.close_complete = true;
        // IOCP drops callbacks for completions canceled before submission;
        // those flags would otherwise keep the slot out of the pool forever.
        if (conn.read_completion.state() != .active) conn.read_active = false;
        if (conn.write_completion.state() != .active) conn.is_writing = false;
        release_closed_connection(conn);
        return;
    }

    conn.socket.close(
        conn.loop,
        &conn.close_completion,
        TcpConnection,
        conn,
        (struct {
            fn cb(
                user_data: ?*TcpConnection,
                loop: *xev.Loop,
                completion: *xev.Completion,
                socket: xev.TCP,
                result: xev.CloseError!void,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion;
                _ = socket;
                // The descriptor is already closed regardless of the reported close status.
                _ = result catch |err| {
                    log.debug("socket close error: {}", .{err});
                };

                const connection = user_data orelse return .disarm;
                connection.close_complete = true;
                if (xev.cancel_abandons_target()) {
                    // epoll drops the target callback; clear the target flags.
                    // kqueue and io_uring deliver it, so their callbacks own
                    // these flags and the release gate waits for them.
                    connection.read_active = false;
                    connection.is_writing = false;
                }
                release_closed_connection(connection);
                return .disarm;
            }
        }).cb,
    );
}

fn on_read_cancel_complete(
    user_data: ?*TcpConnection,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.CancelError!void,
) xev.CallbackAction {
    const conn = user_data.?;
    _ = result catch |err| {
        if (err != error.NotFound) log.debug("read cancel error: {}", .{err});
    };
    conn.read_cancel_active = false;
    release_closed_connection(conn);
    return .disarm;
}

fn on_write_cancel_complete(
    user_data: ?*TcpConnection,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.CancelError!void,
) xev.CallbackAction {
    const conn = user_data.?;
    _ = result catch |err| {
        if (err != error.NotFound) log.debug("write cancel error: {}", .{err});
    };
    conn.write_cancel_active = false;
    release_closed_connection(conn);
    return .disarm;
}

/// Returns a fully closed connection to its owning fixed-capacity pool.
pub fn release_closed_connection(conn: *TcpConnection) void {
    if (!conn.closing or !conn.close_complete) return;
    if (conn.read_active or conn.is_writing) return;
    if (conn.read_cancel_active or conn.write_cancel_active) return;

    const callback = conn.on_close_cb orelse return;
    const pool = conn.pool_ptr orelse return;

    conn.last_active_ms = 0;
    conn.request_len = 0;
    conn.write_head = 0;
    conn.write_len = 0;
    conn.write_in_flight_len = 0;
    conn.release_file_body();
    conn.file_offset = 0;
    conn.file_close_after = false;
    conn.was_backpressured = false;
    conn.dispatch_suspended = false;
    conn.pending_request_consumed = 0;
    conn.pending_close_requested = false;
    conn.write_batch_depth = 0;
    conn.on_close_cb = null;
    conn.pool_ptr = null;
    callback(pool, conn);
}

/// Callback invoked for each accepted POSIX TCP descriptor.
pub const AcceptCallback = *const fn (socket: xev.TCP, user_data: ?*anyopaque) void;

/// Completion state for one bounded asynchronous TCP listener.
pub const TcpServer = struct {
    accept_completion: xev.Completion = .{},
    close_completion: xev.Completion = .{},
    accept_cancel_completion: xev.Completion = .{},
    /// One-shot delay armed only while the listener keeps failing to accept.
    accept_retry_completion: xev.Completion = .{},
    accept_retry_cancel_completion: xev.Completion = .{},
    accept_retry_timer: xev.Timer,
    listener: xev.TCP,
    on_connection: AcceptCallback,
    user_data: ?*anyopaque,
    /// Consecutive accept failures since the last successful accept.
    accept_fail_streak: u8 = 0,
    closing: bool = false,
    close_complete: bool = false,
    accept_retry_active: bool = false,
    accept_retry_cancel_active: bool = false,
};

/// Binds a non-blocking TCP listener without starting accept completions.
pub fn init_server(address: []const u8, port: u16, callback: AcceptCallback, user_data: ?*anyopaque) !TcpServer {
    return init_server_options(address, port, callback, user_data, false);
}

/// Binds a listener with kernel port sharing for thread-per-core clusters.
pub fn init_reuse_port_server(
    address: []const u8,
    port: u16,
    callback: AcceptCallback,
    user_data: ?*anyopaque,
) !TcpServer {
    return init_server_options(address, port, callback, user_data, true);
}

fn init_server_options(
    address: []const u8,
    port: u16,
    callback: AcceptCallback,
    user_data: ?*anyopaque,
    reuse_port: bool,
) !TcpServer {
    const parsed_address = try std.Io.net.IpAddress.parse(address, port);
    var listener = try xev.TCP.init(parsed_address);
    errdefer close_unregistered_socket(listener);
    if (reuse_port) {
        if (builtin.os.tag == .windows) {
            // Windows has no SO_REUSEPORT. SO_REUSEADDR permits every worker to
            // bind the address, and each accepted connection stays wholly inside
            // the accepting worker's slab; kernel distribution is unspecified.
            try set_reuse_address_windows(xev.tcp_fd(listener));
        } else {
            try std.posix.setsockopt(
                xev.tcp_fd(listener),
                std.posix.SOL.SOCKET,
                std.posix.SO.REUSEPORT,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        }
    }
    apply_listener_tuning(xev.tcp_fd(listener));
    try listener.bind(parsed_address);
    try listener.listen(128);

    return .{
        .accept_retry_timer = try xev.Timer.init(),
        .listener = listener,
        .on_connection = callback,
        .user_data = user_data,
    };
}

/// Returns the delay before the next accept attempt for a failure streak.
///
/// Zero means retry through the normal `.rearm` path immediately.
pub fn accept_retry_delay_ms(consecutive_failures: u8) u64 {
    if (consecutive_failures <= accept_failure_grace) return 0;
    const shift: u6 = @intCast(@min(consecutive_failures - accept_failure_grace - 1, 10));
    return @min(accept_retry_initial_ms << shift, accept_retry_max_ms);
}

/// Winsock `setsockopt` signature; referenced only by the Windows branch.
const WinsockSetsockoptFn = *const fn (
    usize,
    c_int,
    c_int,
    [*]const u8,
    c_int,
) callconv(.winapi) c_int;

/// Enables address reuse on an IOCP socket handle.
///
/// Zig's `std.posix` has no socket-option entry point for Windows, so the
/// winsock symbol is bound here and only referenced by the Windows branch.
const winsock_setsockopt = @extern(WinsockSetsockoptFn, .{
    .name = "setsockopt",
    .library_name = "ws2_32",
});

fn set_reuse_address_windows(fd: std.os.windows.HANDLE) !void {
    var value: c_int = 1;
    const result = winsock_setsockopt(
        @intFromPtr(fd),
        std.os.windows.ws2_32.SOL.SOCKET,
        std.os.windows.ws2_32.SO.REUSEADDR,
        @ptrCast(&value),
        @sizeOf(c_int),
    );
    if (result != 0) return error.SocketOptionFailed;
}

/// Winsock `getsockname` signature; referenced only by the Windows branch.
const WinsockGetsocknameFn = *const fn (
    usize,
    *std.os.windows.ws2_32.sockaddr,
    *c_int,
) callconv(.winapi) c_int;

const winsock_getsockname = @extern(WinsockGetsocknameFn, .{
    .name = "getsockname",
    .library_name = "ws2_32",
});

/// Returns the port a bound listener is accepting on.
///
/// `std.posix.system` exposes no sockname entry point with a usable Windows
/// descriptor, so the winsock symbol is bound here like the other options.
pub fn listener_port(server: *const TcpServer) !u16 {
    var storage: std.posix.sockaddr.storage = undefined;
    var length: if (builtin.os.tag == .windows) c_int else std.posix.socklen_t =
        @sizeOf(std.posix.sockaddr.storage);
    if (builtin.os.tag == .windows) {
        if (winsock_getsockname(
            @intFromPtr(xev.tcp_fd(server.listener)),
            @ptrCast(&storage),
            &length,
        ) != 0) return error.ListenerAddressUnavailable;
    } else {
        switch (std.posix.errno(std.posix.system.getsockname(
            xev.tcp_fd(server.listener),
            @ptrCast(&storage),
            &length,
        ))) {
            .SUCCESS => {},
            else => return error.ListenerAddressUnavailable,
        }
    }

    const family: *const std.posix.sockaddr = @ptrCast(&storage);
    return switch (family.family) {
        std.posix.AF.INET => std.mem.bigToNative(
            u16,
            @as(*const std.posix.sockaddr.in, @ptrCast(&storage)).port,
        ),
        std.posix.AF.INET6 => std.mem.bigToNative(
            u16,
            @as(*const std.posix.sockaddr.in6, @ptrCast(&storage)).port,
        ),
        else => error.ListenerAddressUnavailable,
    };
}

/// Bounds one blocking receive so a stalled peer fails a read instead of
/// hanging the caller. Windows receives a millisecond `DWORD`; POSIX receives
/// a `timeval`.
pub fn set_receive_timeout(fd: SocketFd, milliseconds: u32) !void {
    if (builtin.os.tag == .windows) {
        var value = milliseconds;
        const result = winsock_setsockopt(
            @intFromPtr(fd),
            std.os.windows.ws2_32.SOL.SOCKET,
            std.os.windows.ws2_32.SO.RCVTIMEO,
            @ptrCast(&value),
            @sizeOf(u32),
        );
        if (result != 0) return error.SocketOptionFailed;
        return;
    }

    var timeout = std.posix.timeval{
        .sec = @intCast(milliseconds / std.time.ms_per_s),
        .usec = @intCast((milliseconds % std.time.ms_per_s) * std.time.us_per_ms),
    };
    try std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    );
}

/// Descriptor type libxev exposes for TCP and UDP handles on this platform.
pub const SocketFd = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t;

/// Defers accepts until the first application byte arrives.
///
/// Linux-only; other kernels keep their default accept policy, so a handshake
/// that stalls still occupies a kernel backlog entry instead of a worker slot.
fn apply_listener_tuning(fd: SocketFd) void {
    if (builtin.os.tag == .linux) {
        // Best effort: a kernel without TCP_DEFER_ACCEPT keeps the default policy.
        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            std.os.linux.TCP.DEFER_ACCEPT,
            &std.mem.toBytes(defer_accept_seconds),
        ) catch {};
    }
}

/// Requests immediate ACKs once per accepted connection.
///
/// Linux treats quickack as one-shot connection state. Re-arming it on every
/// read would add a syscall to the hot path and measurably reduce throughput,
/// so the flag is requested at accept where it still removes the initial
/// delayed-ACK stall. Other kernels keep their default ACK policy.
pub fn request_quickack(fd: SocketFd) void {
    if (builtin.os.tag == .linux) {
        // Best effort: a kernel without TCP_QUICKACK keeps delayed ACKs.
        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            std.os.linux.TCP.QUICKACK,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch {};
    }
}

/// Disables Nagle batching once per accepted connection.
///
/// The write path already coalesces response parts, so Nagle only adds a
/// delayed-ACK round trip to small responses. Best effort: POSIX kernels
/// without the option keep their default batching.
pub fn set_nodelay(fd: SocketFd) void {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos or
        builtin.os.tag == .ios)
    {
        // Best effort: a kernel without TCP_NODELAY keeps Nagle enabled.
        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch {};
    }
}

/// Arms the listener's recurring accept completion.
pub fn accept_start(server: *TcpServer, loop: *Loop) void {
    if (server.closing or server.accept_retry_active) return;
    arm_accept(server, loop.get_xev_loop());
}

fn arm_accept(server: *TcpServer, loop: *xev.Loop) void {
    if (server.closing) return;
    server.listener.accept(
        loop,
        &server.accept_completion,
        TcpServer,
        server,
        on_accept_complete,
    );
}

/// Cancels accept and asynchronously closes the listener once.
pub fn close_server(server: *TcpServer, loop: *Loop) void {
    if (server.closing) return;
    server.closing = true;

    if (server.accept_retry_active and !server.accept_retry_cancel_active) {
        server.accept_retry_cancel_active = true;
        server.accept_retry_timer.cancel(
            loop.get_xev_loop(),
            &server.accept_retry_completion,
            &server.accept_retry_cancel_completion,
            TcpServer,
            server,
            on_accept_retry_cancel_complete,
        );
    }

    // kqueue and IOCP defer an armed accept until submit. Flush first so the
    // cancel observes an active target instead of dropping its callback.
    if (xev.submit_before_cancel()) {
        xev.submit(loop.get_xev_loop()) catch |err| {
            log.err("accept submit before close failed: {}", .{err});
        };
    }

    if (server.accept_completion.state() == .active) {
        core_loop.cancel(
            loop.get_xev_loop(),
            &server.accept_completion,
            &server.accept_cancel_completion,
            void,
            null,
            on_accept_cancel_complete,
        );
    }
    if (builtin.os.tag == .windows) {
        close_socket(xev.tcp_fd(server.listener));
        server.close_complete = true;
        return;
    }
    server.listener.close(
        loop.get_xev_loop(),
        &server.close_completion,
        TcpServer,
        server,
        on_server_close_complete,
    );
}

/// Releases the retry timer after `close_server` has drained.
pub fn deinit_server(server: *TcpServer) void {
    std.debug.assert(!server.accept_retry_active);
    std.debug.assert(!server.accept_retry_cancel_active);
    server.accept_retry_timer.deinit();
}

fn on_accept_cancel_complete(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.CancelError!void,
) xev.CallbackAction {
    _ = result catch |err| {
        if (err != error.NotFound) log.debug("accept cancel error: {}", .{err});
    };
    return .disarm;
}

fn on_accept_complete(
    user_data: ?*TcpServer,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    _ = completion;

    const server = user_data.?;
    const accepted_socket = result catch |err| {
        if (server.closing) return .disarm;
        return accept_failed(server, loop, err);
    };

    server.accept_fail_streak = 0;

    if (server.closing) {
        close_unregistered_socket(accepted_socket);
        return .disarm;
    }

    request_quickack(xev.tcp_fd(accepted_socket));
    set_nodelay(xev.tcp_fd(accepted_socket));
    server.on_connection(accepted_socket, server.user_data);
    return .rearm;
}

/// Defers the next accept after a listener error without sleeping the loop.
fn accept_failed(server: *TcpServer, loop: *xev.Loop, err: anyerror) xev.CallbackAction {
    if (server.accept_retry_active) return .disarm;
    server.accept_fail_streak +|= 1;
    const delay_ms = accept_retry_delay_ms(server.accept_fail_streak);
    if (delay_ms == 0) {
        log.warn("accept error: {}; retrying", .{err});
        return .rearm;
    }

    log.debug("accept error: {}; retrying in {d} ms", .{ err, delay_ms });
    server.accept_retry_active = true;
    server.accept_retry_timer.run(
        loop,
        &server.accept_retry_completion,
        delay_ms,
        TcpServer,
        server,
        on_accept_retry,
    );
    return .disarm;
}

fn on_accept_retry(
    user_data: ?*TcpServer,
    loop: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    const server = user_data.?;
    server.accept_retry_active = false;
    _ = result catch |err| {
        if (err != error.Canceled) log.debug("accept retry timer error: {}", .{err});
        return .disarm;
    };
    arm_accept(server, loop);
    return .disarm;
}

fn on_accept_retry_cancel_complete(
    user_data: ?*TcpServer,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.CancelError!void,
) xev.CallbackAction {
    const server = user_data.?;
    server.accept_retry_cancel_active = false;
    _ = result catch |err| {
        if (err != error.NotFound) log.debug("accept retry cancel error: {}", .{err});
    };
    return .disarm;
}

fn on_server_close_complete(
    user_data: ?*TcpServer,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    result: xev.CloseError!void,
) xev.CallbackAction {
    const server = user_data.?;
    _ = result catch |err| {
        log.warn("listener close error: {}", .{err});
    };
    server.close_complete = true;
    return .disarm;
}

pub fn close_socket(fd: SocketFd) void {
    if (builtin.os.tag == .windows) {
        _ = c.closesocket(@intCast(@intFromPtr(fd)));
    } else {
        _ = std.posix.system.close(fd);
    }
}

fn close_unregistered_socket(socket: xev.TCP) void {
    close_socket(xev.tcp_fd(socket));
}
