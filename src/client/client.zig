//! Bounded HTTP/1.1 client built on libxev.
//!
//! The public surface is documented in docs/client.md. One `client(N)` value
//! owns a fixed slab of `N` in-flight request slots and one event loop. The
//! plaintext request path allocates nothing; a TLS fetch allocates its
//! BoringSSL session once per connection, like the server's `init_tls`. A
//! request either fits the slab or fails with `error.InflightCapacityReached`.

const std = @import("std");
const c = @import("c");
const xev = @import("xev");
const core_loop = @import("../core/loop.zig");
const tls_client = @import("../crypto/tls_client.zig");
const types = @import("types.zig");
const connection = @import("connection.zig");
/// Pure response parser, exposed for direct tests.
pub const http1 = @import("http1.zig");
/// Pure request head builder, exposed for direct tests.
pub const request_writer = @import("request.zig");

/// HTTP method selector accepted by the client request builder.
pub const Method = types.Method;
/// One borrowed request or response header field.
pub const Header = types.Header;
/// Borrowed request description.
pub const Request = types.Request;
/// TLS trust and server-name policy for one fetch.
pub const TlsOptions = types.TlsOptions;
/// Timeouts and bounded response capacity for one fetch.
pub const FetchOptions = types.FetchOptions;
/// Borrowed view of a completed response.
pub const ResponseView = types.ResponseView;
/// Failure category reported through `FetchOutcome.failure`.
pub const FailureKind = types.FailureKind;
/// Terminal failure with a static explanatory message.
pub const Failure = types.Failure;
/// Result of one fetch attempt.
pub const FetchOutcome = types.FetchOutcome;
/// Receives exactly one fetch outcome on the client's event loop.
pub const FetchCallback = types.FetchCallback;

/// Maximum accepted response head.
pub const max_response_head_bytes = types.max_response_head_bytes;
/// Maximum accepted response header fields.
pub const max_response_header_fields = types.max_response_header_fields;
/// Default decoded response body bound.
pub const default_response_body_capacity = types.default_response_body_capacity;
/// Maximum generated request head.
pub const max_request_head_bytes = types.max_request_head_bytes;

/// One event-loop-confined request slot.
pub const ClientConnection = connection.ClientConnection;

/// Caller-owned storage for a `fetch_blocking` response view.
pub const FetchStorage = struct {
    headers: [types.max_response_header_fields]Header = undefined,
    head: [types.max_response_head_bytes]u8 = undefined,
    body: [types.default_response_body_capacity]u8 = undefined,
};

/// Returns a bounded client type with `max_inflight` request slots.
///
/// The value owns its event loop and every slot buffer, so it must not be
/// copied after `init`; keep it at a stable address for its lifetime.
pub fn client(comptime max_inflight: usize) type {
    if (max_inflight == 0) @compileError("client inflight capacity must be greater than zero");

    return struct {
        const Self = @This();

        loop: core_loop.Loop,
        io: std.Io,
        slots: [max_inflight]ClientConnection = undefined,
        free_indices: [max_inflight]usize = undefined,
        free_count: usize = max_inflight,
        inflight: usize = 0,
        tls_context: ?tls_client.ClientContext = null,
        tls_ca_path: [tls_client.max_ca_path_bytes]u8 = undefined,
        tls_ca_len: usize = 0,

        /// Initializes the loop, timers, and slot free list; no request state
        /// exists until `fetch`.
        pub fn init(io: std.Io) !Self {
            var self = Self{ .loop = try core_loop.init(), .io = io };
            errdefer core_loop.deinit(&self.loop);

            var initialized: usize = 0;
            errdefer for (self.slots[0..initialized]) |*slot| slot.timer.deinit();
            for (&self.slots, 0..) |*slot, index| {
                // The slab is undefined storage; establish every default
                // (notably `active`) before the first `is_active` query.
                slot.* = .{};
                slot.timer = try xev.Timer.init();
                slot.slot_index = index;
                initialized += 1;
            }
            for (&self.free_indices, 0..) |*free_index, index| free_index.* = index;
            return self;
        }

        /// Releases the loop and any cached TLS context after every fetch has
        /// completed.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.inflight == 0);
            for (&self.slots) |*slot| {
                std.debug.assert(!slot.is_active());
                slot.timer.deinit();
            }
            if (self.tls_context) |*context| context.deinit();
            core_loop.deinit(&self.loop);
        }

        /// Arms one request and returns before any I/O completion runs.
        ///
        /// `request` and `options.tls.server_name` are borrowed until the
        /// callback runs. The callback receives the outcome on this loop and
        /// must not call `run` recursively.
        pub fn fetch(
            self: *Self,
            request: Request,
            options: FetchOptions,
            context: *anyopaque,
            callback: FetchCallback,
        ) !void {
            if (options.response_body_capacity > types.default_response_body_capacity) {
                return error.ResponseBodyCapacityExceeded;
            }
            var ssl_ctx: ?*c.SSL_CTX = null;
            if (options.tls) |tls_options| {
                try self.ensure_tls_context(tls_options);
                ssl_ctx = self.tls_context.?.ctx;
            }

            const index = self.acquire() orelse return error.InflightCapacityReached;
            const slot = &self.slots[index];
            slot.start(.{
                .loop = self.loop.get_xev_loop(),
                .io = self.io,
                .request = request,
                .options = options,
                .ssl_ctx = ssl_ctx,
                .context = context,
                .callback = callback,
                .release_callback = on_slot_released,
                .release_context = self,
                .slot_index = index,
            }) catch |err| {
                self.release_unstarted(index);
                return err;
            };
            self.inflight += 1;
        }

        /// Drives the loop until every in-flight request has completed.
        ///
        /// A loop failure is terminal: every remaining slot is abandoned so
        /// `deinit` stays valid and no callback is delivered after the loop
        /// has stopped.
        pub fn run(self: *Self) !void {
            while (self.inflight > 0) {
                core_loop.run(&self.loop) catch |err| {
                    self.abandon_inflight();
                    return err;
                };
            }
        }

        /// Force-releases every active slot after a terminal loop failure.
        fn abandon_inflight(self: *Self) void {
            for (&self.slots) |*slot| {
                if (slot.is_active()) slot.abandon();
            }
            self.inflight = 0;
            self.free_count = max_inflight;
            for (&self.free_indices, 0..) |*free_index, index| free_index.* = index;
        }

        fn acquire(self: *Self) ?usize {
            if (self.free_count == 0) return null;
            self.free_count -= 1;
            return self.free_indices[self.free_count];
        }

        fn release_unstarted(self: *Self, index: usize) void {
            std.debug.assert(self.free_count < max_inflight);
            self.free_indices[self.free_count] = index;
            self.free_count += 1;
        }

        fn on_slot_released(release_context: *anyopaque, slot: *ClientConnection) void {
            const self: *Self = @ptrCast(@alignCast(release_context));
            std.debug.assert(self.inflight > 0);
            self.inflight -= 1;
            self.release_unstarted(slot.slot_index);
        }

        /// Builds or reuses the single cached TLS context.
        ///
        /// Mixing trust policies on one client is rejected so a verification
        /// result can never be reused under different options.
        fn ensure_tls_context(self: *Self, options: TlsOptions) !void {
            if (options.verify and options.ca_path == null) return error.CaPathRequired;
            const ca_path: []const u8 = if (options.ca_path) |path| path else "";
            if (ca_path.len > self.tls_ca_path.len) return error.CaPathTooLong;

            if (self.tls_context) |context| {
                const same_policy = context.verify == options.verify and
                    ca_path.len == self.tls_ca_len and
                    std.mem.eql(u8, self.tls_ca_path[0..ca_path.len], ca_path);
                if (!same_policy) return error.TlsConfigurationMismatch;
                return;
            }

            self.tls_context = try tls_client.ClientContext.init(.{
                .verify = options.verify,
                .ca_path = options.ca_path,
            });
            @memcpy(self.tls_ca_path[0..ca_path.len], ca_path);
            self.tls_ca_len = ca_path.len;
        }
    };
}

/// Callback capture used by `fetch_blocking`.
const ResultCapture = struct {
    outcome: FetchOutcome,
    completed: bool,

    fn on_outcome(context: *anyopaque, outcome: FetchOutcome) void {
        const self: *ResultCapture = @ptrCast(@alignCast(context));
        self.outcome = outcome;
        self.completed = true;
    }
};

/// Runs one request to completion on a temporary single-slot client.
///
/// The returned view borrows `storage` and stays valid while it does. Setup
/// failures that `fetch` reports as errors become `failure` outcomes with a
/// mapped `kind`; parse, transport, and timeout failures pass through.
pub fn fetch_blocking(
    io: std.Io,
    request: Request,
    options: FetchOptions,
    storage: *FetchStorage,
) !FetchOutcome {
    var instance = try client(1).init(io);
    defer instance.deinit();

    var capture = ResultCapture{
        .outcome = .{ .failure = .{ .kind = .closed, .message = "request did not run" } },
        .completed = false,
    };
    instance.fetch(request, options, &capture, ResultCapture.on_outcome) catch |err| {
        return .{ .failure = .{ .kind = setup_failure_kind(err), .message = setup_failure_message(err) } };
    };
    try instance.run();
    if (!capture.completed) {
        return .{ .failure = .{ .kind = .closed, .message = "client finished without an outcome" } };
    }

    switch (capture.outcome) {
        .response => |view| {
            const copied = http1.copy_view(view, &storage.headers, &storage.head, &storage.body) catch {
                return .{ .failure = .{ .kind = .capacity, .message = "response exceeded fetch storage" } };
            };
            return .{ .response = copied };
        },
        .failure => |failure| return .{ .failure = failure },
    }
}

fn setup_failure_kind(err: anyerror) FailureKind {
    return switch (err) {
        error.CaPathRequired,
        error.CaPathTooLong,
        error.CertificateLoadFailed,
        error.TlsContextCreationFailed,
        error.TlsConfigurationMismatch,
        error.TlsUnavailable,
        error.ServerNameEmpty,
        error.ServerNameTooLong,
        error.SslAllocationFailed,
        error.BioAllocationFailed,
        error.SniConfigurationFailed,
        error.AlpnConfigurationFailed,
        error.HostnameVerificationFailed,
        error.TlsHandshakeStalled,
        => .tls,

        error.InflightCapacityReached,
        error.ResponseBodyCapacityExceeded,
        => .capacity,

        error.InvalidHostAddress => .connect,

        error.InvalidPath,
        error.InvalidHost,
        error.InvalidHeaderName,
        error.InvalidHeaderValue,
        error.ReservedHeader,
        error.HeadTooLarge,
        => .protocol,

        else => .protocol,
    };
}

fn setup_failure_message(err: anyerror) []const u8 {
    return switch (err) {
        error.CaPathRequired => "TLS verification requires a CA path",
        error.CaPathTooLong => "CA path exceeds the client bound",
        error.CertificateLoadFailed => "CA bundle could not be loaded",
        error.TlsContextCreationFailed => "TLS context creation failed",
        error.TlsConfigurationMismatch => "TLS options differ from the cached client context",
        error.TlsUnavailable => "TLS context unavailable",
        error.ServerNameEmpty => "TLS server name is empty",
        error.ServerNameTooLong => "TLS server name exceeds the client bound",
        error.SslAllocationFailed => "TLS session allocation failed",
        error.BioAllocationFailed => "TLS memory BIO allocation failed",
        error.SniConfigurationFailed => "TLS SNI configuration failed",
        error.AlpnConfigurationFailed => "TLS ALPN configuration failed",
        error.HostnameVerificationFailed => "TLS hostname verification setup failed",
        error.TlsHandshakeStalled => "TLS handshake stalled",
        error.InvalidHostAddress => "host is not a numeric address",
        error.InflightCapacityReached => "client inflight capacity reached",
        error.ResponseBodyCapacityExceeded => "response body capacity exceeds the client bound",
        error.InvalidPath => "invalid request target",
        error.InvalidHost => "invalid host header value",
        error.InvalidHeaderName => "invalid request header name",
        error.InvalidHeaderValue => "invalid request header value",
        error.ReservedHeader => "request header is reserved by the builder",
        error.HeadTooLarge => "request head exceeds the client bound",
        else => "request setup failed",
    };
}
