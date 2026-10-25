const std = @import("std");
const c = @import("c");
const http_parser = @import("../http/parser.zig");
const Request = @import("../http/request.zig").Request;
const http_response = @import("../http/response.zig");
const Response = http_response.Response;
const Http3Target = http_response.Http3Target;
const Router = @import("../router/radix.zig").Router;
const radix = @import("../router/radix.zig");
const validation = @import("validation.zig");
const dev_log_module = @import("../observability/dev_log.zig");

/// Reports that HTTP/3 stream support is compiled in.
pub const available = true;

/// Per-stream HTTP/3 storage and field capacities.
///
/// `decoded_header_count` caps the regular request fields accepted from one
/// field section; pseudo-fields are validated into named slots and do not
/// consume it. `header_extra_capacity` reserves the request-field pointer slots
/// the engine lends beyond the inline `Request` arrays.
pub const Capacities = struct {
    request_header_size: usize = http_parser.max_header_size,
    request_body_size: usize = http_parser.default_max_body_size,
    response_header_size: usize = 4096,
    response_header_count: usize = 64,
    decoded_header_count: usize = 64,
    header_extra_capacity: usize = 0,
};

/// Default per-stream capacity record; the production stream is specialized
/// with these values.
pub const default_capacities: Capacities = .{};

/// Per-stream decoded request-header storage capacity of the default record.
pub const header_capacity = default_capacities.request_header_size;
/// Per-stream request body capacity of the default record.
pub const request_body_capacity = default_capacities.request_body_size;
/// Per-stream encoded response-header storage capacity of the default record.
pub const response_header_capacity = default_capacities.response_header_size;

/// Returns a header set to the owner that lent it storage.
const HeaderReleaseFn = *const fn (*anyopaque, *HeaderSet) void;

/// Bounded lsquic header decoder state for one HTTP/3 request.
pub const HeaderSet = struct {
    owner: *anyopaque = undefined,
    release_fn: ?HeaderReleaseFn = null,
    storage: []u8 = &.{},
    /// Per-stream capacities the engine specialized the owning stream with.
    capacities: Capacities = default_capacities,
    decoded: c.struct_uz_lsxpack_header = std.mem.zeroes(c.struct_uz_lsxpack_header),
    request: Request = .{},
    method: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    content_length: ?usize = null,
    write_offset: usize = 0,
    /// Regular fields accepted from this field section so far.
    decoded_field_count: usize = 0,
    regular_headers_seen: bool = false,
    host_seen: bool = false,
    is_trailer: bool = false,
    finished: bool = false,
    claimed: bool = false,

    /// Reinitializes the header set with borrowed owner, decode storage, and
    /// engine-provided request-field capacity slices.
    ///
    /// `header_extra_names` and `header_extra_values` are equal-length
    /// caller-owned capacity slices; pass empty slices when the inline
    /// `Request` arrays must cover every accepted field.
    pub fn reset(
        self: *HeaderSet,
        owner: *anyopaque,
        release_fn: HeaderReleaseFn,
        storage: []u8,
        header_extra_names: [][]const u8,
        header_extra_values: [][]const u8,
        capacities: Capacities,
    ) void {
        self.* = .{
            .owner = owner,
            .release_fn = release_fn,
            .storage = storage,
            .capacities = capacities,
        };
        self.request.extra_header_names = header_extra_names;
        self.request.extra_header_values = header_extra_values;
        self.request.extra_header_count = 0;
    }

    /// Reinitializes the header set for a trailing field section.
    pub fn reset_trailer(
        self: *HeaderSet,
        owner: *anyopaque,
        release_fn: HeaderReleaseFn,
        storage: []u8,
        header_extra_names: [][]const u8,
        header_extra_values: [][]const u8,
        capacities: Capacities,
    ) void {
        self.reset(
            owner,
            release_fn,
            storage,
            header_extra_names,
            header_extra_values,
            capacities,
        );
        self.is_trailer = true;
    }

    /// Prepares inline storage for one lsquic-decoded field.
    pub fn prepare_decode(
        self: *HeaderSet,
        existing: ?*c.lsxpack_header,
        required: usize,
    ) ?*c.lsxpack_header {
        if (self.finished or required > self.storage.len -| self.write_offset) return null;
        if (existing) |header| {
            if (@intFromPtr(header) != @intFromPtr(&self.decoded)) return null;
            self.decoded.val_len = @intCast(self.storage.len - self.write_offset);
            return @ptrCast(&self.decoded);
        }

        self.decoded = std.mem.zeroes(c.struct_uz_lsxpack_header);
        self.decoded.buf = @ptrCast(self.storage.ptr);
        self.decoded.name_offset = @intCast(self.write_offset);
        self.decoded.val_len = @intCast(self.storage.len - self.write_offset);
        return @ptrCast(&self.decoded);
    }

    /// Validates and records a decoded field, or finalizes on null.
    pub fn process_header(self: *HeaderSet, decoded: ?*c.lsxpack_header) bool {
        const raw_header = decoded orelse return self.finish();
        if (@intFromPtr(raw_header) != @intFromPtr(&self.decoded)) return false;
        const header: *c.struct_uz_lsxpack_header = @ptrCast(@alignCast(raw_header));
        if (header.buf == null) return false;
        if (@intFromPtr(header.buf) != @intFromPtr(self.storage.ptr)) return false;
        if (header.name_offset < 0 or header.val_offset < 0) return false;

        const name_offset: usize = @intCast(header.name_offset);
        const value_offset: usize = @intCast(header.val_offset);
        const name_length: usize = @intCast(header.name_len);
        const value_length: usize = @intCast(header.val_len);
        const name_end = std.math.add(usize, name_offset, name_length) catch return false;
        const value_end = std.math.add(usize, value_offset, value_length) catch return false;
        const next_offset = @max(name_end, value_end);
        if (name_offset < self.write_offset or value_offset < self.write_offset) return false;
        if (next_offset > self.storage.len or name_length == 0) return false;

        const name = self.storage[name_offset..name_end];
        const value = self.storage[value_offset..value_end];
        if (!validation.valid_header_value(value)) return false;

        const accepted = if (name[0] == ':')
            self.process_pseudo_header(name, value)
        else
            self.process_regular_header(name, value);
        if (!accepted) return false;

        self.write_offset = next_offset;
        return true;
    }

    /// Returns this header set to its owner at most once.
    pub fn release(self: *HeaderSet) void {
        const callback = self.release_fn orelse return;
        self.release_fn = null;
        callback(self.owner, self);
    }

    fn process_pseudo_header(self: *HeaderSet, name: []const u8, value: []const u8) bool {
        if (self.is_trailer or self.regular_headers_seen) return false;

        if (std.mem.eql(u8, name, ":method")) {
            if (self.method != null or !validation.valid_method(value)) return false;
            self.method = value;
            return true;
        }
        if (std.mem.eql(u8, name, ":scheme")) {
            if (self.scheme != null or !std.mem.eql(u8, value, "https")) return false;
            self.scheme = value;
            return true;
        }
        if (std.mem.eql(u8, name, ":authority")) {
            if (self.authority != null or !validation.valid_authority(value)) return false;
            self.authority = value;
            return true;
        }
        if (std.mem.eql(u8, name, ":path")) {
            if (self.path != null or !validation.valid_target(value)) return false;
            self.path = value;
            return true;
        }
        if (std.mem.eql(u8, name, ":protocol")) {
            if (self.protocol != null or !validation.valid_method(value)) return false;
            self.protocol = value;
            return true;
        }
        return false;
    }

    fn process_regular_header(self: *HeaderSet, name: []const u8, value: []const u8) bool {
        if (!validation.valid_http3_name(name)) return false;
        if (validation.connection_specific_header(name)) return false;
        if (self.is_trailer and forbidden_trailer_field(name)) return false;
        if (std.mem.eql(u8, name, "te") and !std.ascii.eqlIgnoreCase(value, "trailers")) {
            return false;
        }

        if (std.mem.eql(u8, name, "content-length")) {
            if (self.content_length != null) return false;
            const length = validation.parse_decimal(value) orelse return false;
            if (length > self.capacities.request_body_size) return false;
            self.content_length = length;
        }
        if (std.mem.eql(u8, name, "host")) {
            if (self.host_seen or !validation.valid_authority(value)) return false;
            self.host_seen = true;
            if (self.authority) |authority| {
                if (!std.ascii.eqlIgnoreCase(authority, value)) return false;
            }
        }

        if (self.decoded_field_count >= self.capacities.decoded_header_count) return false;
        // Both inline and engine-provided slots are exhausted past capacity;
        // either way the field section fails closed on this stream.
        self.request.add_header(name, value) catch return false;
        self.decoded_field_count += 1;
        self.regular_headers_seen = true;
        return true;
    }

    fn finish(self: *HeaderSet) bool {
        if (self.finished) return false;
        if (self.is_trailer) {
            self.finished = true;
            return true;
        }
        const method = self.method orelse return false;
        const is_connect = std.mem.eql(u8, method, "CONNECT");
        // RFC 9220 defines :protocol only for extended CONNECT requests.
        if (self.protocol != null and !is_connect) return false;
        const target = if (is_connect) blk: {
            if (self.protocol != null) {
                _ = self.scheme orelse return false;
                const path = self.path orelse return false;
                // Extended CONNECT keeps the authority-form target and so
                // requires :authority (RFC 8441 section 4).
                _ = self.authority orelse return false;
                break :blk path;
            }
            if (self.scheme != null or self.path != null) return false;
            break :blk self.authority orelse return false;
        } else blk: {
            _ = self.scheme orelse return false;
            const path = self.path orelse return false;
            if (std.mem.eql(u8, path, "*") and !std.mem.eql(u8, method, "OPTIONS")) {
                return false;
            }
            break :blk path;
        };

        if (!self.host_seen) {
            const authority = self.authority orelse return false;
            self.request.add_header("host", authority) catch return false;
        }

        self.request.method = method;
        self.request.target = target;
        if (is_connect and self.protocol == null) {
            self.request.path = "";
            self.request.query = "";
            self.finished = true;
            return true;
        }
        if (std.mem.indexOfScalar(u8, target, '?')) |query_start| {
            self.request.path = target[0..query_start];
            self.request.query = target[query_start + 1 ..];
        } else {
            self.request.path = target;
            self.request.query = "";
        }
        self.finished = true;
        return true;
    }
};

const ResponsePhase = enum(u8) {
    idle,
    streaming,
    ready,
    sending,
    done,
};

const RequestPhase = enum(u8) {
    waiting_headers,
    body,
    trailers,
    complete,
};

/// lsquic stream entry points the response state machine calls.
///
/// Production binds `lsquic_stream_io`; tests substitute a fake so producer
/// resumption and drain accounting run without a live QUIC connection.
pub const StreamIo = struct {
    wantread: *const fn (?*c.lsquic_stream, c_int) callconv(.c) c_int,
    read: *const fn (?*c.lsquic_stream, ?*anyopaque, usize) callconv(.c) isize,
    wantwrite: *const fn (?*c.lsquic_stream, c_int) callconv(.c) c_int,
    write: *const fn (?*c.lsquic_stream, ?*const anyopaque, usize) callconv(.c) isize,
    send_headers: *const fn (
        ?*c.lsquic_stream,
        [*c]const c.lsquic_http_headers_t,
        c_int,
    ) callconv(.c) c_int,
    shutdown: *const fn (?*c.lsquic_stream, c_int) callconv(.c) c_int,
    close: *const fn (?*c.lsquic_stream) callconv(.c) c_int,
};

/// Production lsquic stream entry points for one HTTP/3 stream.
pub const lsquic_stream_io: StreamIo = .{
    .wantread = c.lsquic_stream_wantread,
    .read = c.lsquic_stream_read,
    .wantwrite = c.lsquic_stream_wantwrite,
    .write = c.lsquic_stream_write,
    .send_headers = c.lsquic_stream_send_headers,
    .shutdown = c.lsquic_stream_shutdown,
    .close = c.lsquic_stream_close,
};

/// Returns connection-owned, fixed-buffer HTTP/3 stream state bound to the
/// given lsquic stream entry points and per-stream capacity record.
pub fn stream_with(comptime io: StreamIo, comptime capacities: Capacities) type {
    if (capacities.response_header_size == 0 or
        capacities.response_header_size > std.math.maxInt(u16))
    {
        @compileError("HTTP/3 response header size must fit u16 offsets");
    }
    if (capacities.response_header_count == 0) {
        @compileError("HTTP/3 response header count must be greater than zero");
    }

    return struct {
        const Self = @This();
        /// Returns a stream to the owner that lent it storage.
        const StreamReleaseFn = *const fn (*anyopaque, *Self) void;

        owner: *anyopaque = undefined,
        release_fn: ?StreamReleaseFn = null,
        stream: *c.lsquic_stream = undefined,
        router: *const Router = undefined,
        header_set: ?*HeaderSet = null,
        body_storage: []u8 = &.{},
        response_body_storage: []u8 = &.{},
        response_header_storage: []u8 = &.{},
        // Engine-owned capture capacity slices, reused by every request this
        // stream dispatches; empty when captures stay inline.
        extra_param_names: [][]const u8 = &.{},
        extra_param_values: [][]const u8 = &.{},
        // Engine-owned request-field capacity slices, reused by every header
        // set this stream presents; empty when request fields stay inline.
        header_extra_names: [][]const u8 = &.{},
        header_extra_values: [][]const u8 = &.{},
        response_name_offsets: [capacities.response_header_count]u16 = .{0} ** capacities.response_header_count,
        response_name_lengths: [capacities.response_header_count]u16 = .{0} ** capacities.response_header_count,
        response_value_offsets: [capacities.response_header_count]u16 = .{0} ** capacities.response_header_count,
        response_value_lengths: [capacities.response_header_count]u16 = .{0} ** capacities.response_header_count,
        response_status: [10]u8 = undefined,
        /// Numeric status of the prepared response, recorded on completion.
        response_status_code: u16 = 0,
        body_length: usize = 0,
        response_body_length: usize = 0,
        response_body_offset: usize = 0,
        response_header_length: usize = 0,
        response_header_count: usize = 0,
        response_phase: ResponsePhase = .idle,
        request_phase: RequestPhase = .waiting_headers,
        headers_sent: bool = false,
        suppress_body: bool = false,
        dispatched: bool = false,
        stream_producer_context: ?*anyopaque = null,
        stream_producer: ?http_response.StreamProducer = null,
        async_response_state: http_response.AsyncResponseState = .{},

        /// Reinitializes a pooled stream with borrowed transport and storage.
        ///
        /// `extra_param_names`, `extra_param_values`, `header_extra_names`,
        /// and `header_extra_values` are equal-length caller-owned capacity
        /// slices; pass empty slices when the inline `Request` arrays cover
        /// every configured capture and request field.
        pub fn reset(
            self: *Self,
            owner: *anyopaque,
            release_fn: StreamReleaseFn,
            stream: *c.lsquic_stream,
            router: *const Router,
            body_storage: []u8,
            response_body_storage: []u8,
            response_header_storage: []u8,
            extra_param_names: [][]const u8,
            extra_param_values: [][]const u8,
            header_extra_names: [][]const u8,
            header_extra_values: [][]const u8,
        ) void {
            var next_generation = self.async_response_state.generation +% 1;
            if (next_generation == 0) next_generation = 1;
            self.* = .{
                .owner = owner,
                .release_fn = release_fn,
                .stream = stream,
                .router = router,
                .body_storage = body_storage,
                .response_body_storage = response_body_storage,
                .response_header_storage = response_header_storage,
                .extra_param_names = extra_param_names,
                .extra_param_values = extra_param_values,
                .header_extra_names = header_extra_names,
                .header_extra_values = header_extra_values,
            };
            self.async_response_state.generation = next_generation;
            self.async_response_state.state = .cancelled;
        }

        /// Claims a finished header set or closes on invalid ownership state.
        pub fn attach_headers(self: *Self, header_set: *HeaderSet) void {
            if (!header_set.finished or header_set.claimed) {
                header_set.release();
                _ = io.close(self.stream);
                return;
            }

            if (header_set.is_trailer) {
                if (self.header_set == null or self.request_phase != .body) {
                    header_set.release();
                    _ = io.close(self.stream);
                    return;
                }
                header_set.claimed = true;
                self.request_phase = .trailers;
                header_set.release();
                return;
            }

            if (self.header_set != null or self.request_phase != .waiting_headers) {
                header_set.release();
                _ = io.close(self.stream);
                return;
            }
            header_set.claimed = true;
            self.header_set = header_set;
            self.request_phase = .body;
        }

        /// Drains readable request bytes and dispatches a complete request.
        pub fn on_read(self: *Self) void {
            if (self.header_set == null or self.dispatched) {
                _ = io.close(self.stream);
                return;
            }

            while (true) {
                if (self.body_length == self.body_storage.len) {
                    var overflow_probe: [1]u8 = undefined;
                    const read_length = io.read(self.stream, &overflow_probe, overflow_probe.len);
                    if (read_length > 0) {
                        self.queue_error("413 Payload Too Large", "Payload Too Large");
                    } else if (read_length == 0) {
                        self.dispatch();
                    } else if (std.c.errno(read_length) != .AGAIN) {
                        self.close_now();
                    }
                    return;
                }

                const destination = self.body_storage[self.body_length..];
                const read_length = io.read(self.stream, destination.ptr, destination.len);
                if (read_length < 0) {
                    if (std.c.errno(read_length) != .AGAIN) self.close_now();
                    return;
                }
                if (read_length == 0) {
                    self.dispatch();
                    return;
                }
                self.body_length += @intCast(read_length);

                if (self.header_set.?.content_length) |expected| {
                    if (self.body_length > expected) {
                        self.queue_error("400 Bad Request", "Content-Length mismatch");
                        return;
                    }
                }
            }
        }

        /// Flushes queued response fields and body bytes without blocking.
        ///
        /// An armed producer is stepped at most once per write event plus the
        /// drain loop, so a producer that returns `.pending` without yielding
        /// bytes cannot spin. The stream stays armed until the producer finishes
        /// and the final storage drains.
        pub fn on_write(self: *Self) void {
            if (!self.response_pumpable()) {
                _ = io.wantwrite(self.stream, 0);
                return;
            }

            if (!self.headers_sent) {
                if (!self.send_headers()) {
                    _ = io.close(self.stream);
                    return;
                }
                self.headers_sent = true;
                // A producer keeps `.streaming` so its write_chunk calls stay
                // valid until it calls end_chunks; a prepared body moves on.
                if (self.stream_producer == null) self.response_phase = .sending;
            }

            if (!self.flush_response_body()) return;

            if (self.stream_producer != null and self.response_phase == .streaming) {
                self.response_body_offset = 0;
                self.response_body_length = 0;
                _ = self.step_stream_producer();
                if (self.response_phase == .done) return;
                if (!self.flush_response_body()) return;
            }

            if (self.stream_producer != null) return;

            _ = io.wantwrite(self.stream, 0);
            _ = io.shutdown(self.stream, 1);
            self.response_phase = .done;
            self.log_http_request();
        }

        /// Reports whether the response state machine may advance on a write event.
        fn response_pumpable(self: *const Self) bool {
            return switch (self.response_phase) {
                .ready, .sending => true,
                .streaming => self.stream_producer != null,
                .idle, .done => false,
            };
        }

        /// Moves queued body bytes into the stream; false when closed or blocked.
        fn flush_response_body(self: *Self) bool {
            while (self.response_body_offset < self.response_body_length) {
                const body = self.response_body_storage[self.response_body_offset..self.response_body_length];
                const written = io.write(self.stream, body.ptr, body.len);
                if (written < 0) {
                    _ = io.close(self.stream);
                    return false;
                }
                if (written == 0) return false;
                self.response_body_offset += @intCast(written);
            }
            return true;
        }

        /// Advances the armed producer once into the bounded body storage.
        ///
        /// The producer writes through `write_response`, so a full storage region
        /// surfaces as `error.WouldBlock`; the producer turns that into `.pending`
        /// and the next write event retries it. A producer fault clears the state
        /// and either queues a 500 while the head is still buffered or resets the
        /// stream once the head is on the wire.
        fn step_stream_producer(self: *Self) http_response.StreamStatus {
            const producer = self.stream_producer orelse return .done;
            const producer_context = self.stream_producer_context orelse {
                self.clear_stream_producer();
                return .done;
            };

            var response = Response{
                .target = .{ .http3 = self.target() },
                .state = .streaming,
            };
            const status = producer(producer_context, &response) catch {
                self.fail_stream_producer();
                return .done;
            };
            if (status == .done) {
                self.clear_stream_producer();
                // A producer that returns `.done` without end_chunks still
                // terminates the body; finish_response arms the final drain.
                if (self.response_phase == .streaming) {
                    finish_response(self) catch self.close_now();
                }
                return .done;
            }
            // end_chunks moved the phase out of `.streaming`; a later `.pending`
            // must not leave wantwrite armed forever.
            if (self.response_phase != .streaming) {
                self.clear_stream_producer();
                return .done;
            }
            return status;
        }

        /// Reports a producer fault through the normal response error path.
        fn fail_stream_producer(self: *Self) void {
            self.clear_stream_producer();
            if (self.headers_sent or self.response_phase != .streaming) {
                self.close_now();
                self.response_phase = .done;
                return;
            }
            self.response_phase = .idle;
            end_response(self, "500 Internal Server Error", "", "") catch self.close_now();
        }

        /// Disarms the response producer without altering the response phase.
        fn clear_stream_producer(self: *Self) void {
            self.stream_producer = null;
            self.stream_producer_context = null;
        }

        /// Cancels deferred dispatch and returns pooled state to its owner.
        pub fn on_close(self: *Self) void {
            self.async_response_state.cancel();
            self.clear_stream_producer();
            if (self.header_set) |header_set| header_set.release();
            self.header_set = null;

            const callback = self.release_fn orelse return;
            self.release_fn = null;
            callback(self.owner, self);
        }

        fn dispatch(self: *Self) void {
            if (self.dispatched) return;
            self.dispatched = true;
            self.request_phase = .complete;
            _ = io.wantread(self.stream, 0);

            const header_set = self.header_set.?;
            if (header_set.content_length) |expected| {
                if (expected != self.body_length) {
                    self.queue_error("400 Bad Request", "Content-Length mismatch");
                    return;
                }
            }
            header_set.request.body = self.body_storage[0..self.body_length];

            const method = radix.HttpMethod.parse(header_set.request.method);
            self.suppress_body = method == .head;
            var response = Response{ .target = .{ .http3 = self.target() } };
            if (std.mem.eql(u8, header_set.request.method, "CONNECT")) {
                response.end("501 Not Implemented", "HTTP/3 CONNECT is not supported") catch
                    self.close_now();
                return;
            }
            if (!header_set.request.valid_query_content_type()) {
                response.end("400 Bad Request", "QUERY requires a valid Content-Type") catch
                    self.close_now();
                return;
            }
            // The header set owns the request view; wire this stream's
            // engine-owned capture slices before the capture pass so wide
            // patterns can spill past the inline array.
            header_set.request.extra_param_names = self.extra_param_names;
            header_set.request.extra_param_values = self.extra_param_values;
            header_set.request.extra_param_count = 0;
            const route = self.router.match_request(&header_set.request, method);
            if (self.router.run_middleware(&header_set.request, &response) == .stop) {
                self.finish_sync_dispatch(&response);
                return;
            }

            if (method == .options and std.mem.eql(u8, header_set.request.path, "*")) {
                response.end("204 No Content", "") catch self.close_now();
                return;
            }

            const matched_route = route orelse {
                response.end("404 Not Found", "Route not found") catch self.close_now();
                return;
            };

            if (matched_route.handler) |handler| {
                self.invoke_handler(handler, &header_set.request, &response);
                return;
            }

            if (method == .options) {
                self.send_method_response(&response, matched_route.allowed_methods, "204 No Content", "");
                return;
            }
            if (matched_route.ws_behavior != null and method == .get) {
                response.end("426 Upgrade Required", "WebSocket over HTTP/3 is not supported") catch self.close_now();
                return;
            }
            self.send_method_response(&response, matched_route.allowed_methods, "405 Method Not Allowed", "Method Not Allowed");
        }

        fn invoke_handler(
            self: *Self,
            handler: radix.RouteHandler,
            request: *Request,
            response: *Response,
        ) void {
            switch (handler) {
                .synchronous => |callback| {
                    callback(request, response);
                    self.finish_sync_dispatch(response);
                },
                .contextual => |binding| {
                    binding.callback(binding.context, request, response);
                    self.finish_sync_dispatch(response);
                },
                .asynchronous => |callback| {
                    const token = self.async_response_state.arm(self.async_target());
                    callback(request, token);
                },
                .contextual_async => |binding| {
                    const token = self.async_response_state.arm(self.async_target());
                    binding.callback(binding.context, request, token);
                },
            }
        }

        fn finish_sync_dispatch(self: *Self, response: *Response) void {
            if (response.is_complete()) return;
            // A pending producer owns completion and resumes on write events.
            if (self.stream_producer != null) return;
            if (response.is_started()) {
                self.close_now();
                return;
            }
            response.end("500 Internal Server Error", "Handler did not complete response") catch
                self.close_now();
        }

        fn async_target(self: *Self) http_response.AsyncTarget {
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
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.release_fn == null) return error.StreamClosed;
            end_response(self, status, headers, body) catch |err| {
                self.close_now();
                return err;
            };
        }

        /// QUIC completions arm the response directly, so the transport-level
        /// wake hook has no queued dispatch to resume.
        fn wake_async_dispatch(_: *anyopaque) void {}

        fn send_method_response(
            self: *Self,
            response: *Response,
            allowed_methods: u16,
            status: []const u8,
            body: []const u8,
        ) void {
            var allow_value_buffer: [64]u8 = undefined;
            const allow_value = radix.format_allowed_methods(allowed_methods, &allow_value_buffer) catch {
                self.close_now();
                return;
            };
            var allow_header_buffer: [80]u8 = undefined;
            const allow_header = std.fmt.bufPrint(
                &allow_header_buffer,
                "Allow: {s}\r\n",
                .{allow_value},
            ) catch {
                self.close_now();
                return;
            };
            response.end_with_headers(status, allow_header, body) catch self.close_now();
        }

        /// Returns the response callbacks bound to this stream.
        pub fn target(self: *Self) Http3Target {
            return .{
                .context = self,
                .end_fn = end_response,
                .begin_fn = begin_response,
                .write_fn = write_response,
                .finish_fn = finish_response,
                .abort_fn = abort_response,
                .begin_stream_fn = begin_stream_response,
            };
        }

        fn end_response(context: *anyopaque, status: []const u8, headers: []const u8, body: []const u8) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.response_phase != .idle) return error.ResponseAlreadyStarted;
            try self.prepare_response(status, headers);

            if (!self.suppress_body) {
                if (body.len > self.response_body_storage.len) return error.WouldBlock;
                @memcpy(self.response_body_storage[0..body.len], body);
                self.response_body_length = body.len;
            }
            self.response_phase = .ready;
            _ = io.wantwrite(self.stream, 1);
        }

        fn begin_response(context: *anyopaque, status: []const u8, headers: []const u8) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.response_phase != .idle) return error.ResponseAlreadyStarted;
            if (self.suppress_body) return error.BodyNotAllowed;
            try self.prepare_response(status, headers);
            self.response_phase = .streaming;
        }

        fn begin_stream_response(
            context: *anyopaque,
            status: []const u8,
            headers: []const u8,
            producer_context: *anyopaque,
            producer: http_response.StreamProducer,
        ) anyerror!bool {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.response_phase != .idle) return error.ResponseAlreadyStarted;
            if (self.suppress_body) return error.BodyNotAllowed;

            try self.prepare_response(status, headers);
            self.response_phase = .streaming;
            self.response_body_offset = 0;
            self.response_body_length = 0;
            self.stream_producer = producer;
            self.stream_producer_context = producer_context;

            if (self.step_stream_producer() != .done) {
                _ = io.wantwrite(self.stream, 1);
                return false;
            }
            return true;
        }

        fn write_response(context: *anyopaque, body: []const u8) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.response_phase != .streaming) return error.ResponseNotStreaming;
            if (body.len > self.response_body_storage.len - self.response_body_length) {
                return error.WouldBlock;
            }
            @memcpy(
                self.response_body_storage[self.response_body_length .. self.response_body_length + body.len],
                body,
            );
            self.response_body_length += body.len;
        }

        fn finish_response(context: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.response_phase != .streaming) return error.ResponseNotStreaming;
            // end_chunks is terminal for a producer-fed body: whether the
            // producer or the application called it, nothing may re-arm.
            self.clear_stream_producer();
            self.response_phase = .ready;
            _ = io.wantwrite(self.stream, 1);
        }

        fn prepare_response(self: *Self, status: []const u8, headers: []const u8) !void {
            self.response_status_code = http_response.status_code(status) orelse
                return error.InvalidStatus;
            @memcpy(self.response_status[0..7], ":status");
            @memcpy(self.response_status[7..10], status[0..3]);
            self.response_header_length = 0;
            self.response_header_count = 0;

            var lines = std.mem.splitSequence(u8, headers, "\r\n");
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (self.response_header_count >= capacities.response_header_count) {
                    return error.BufferOverflow;
                }
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeaders;
                const name = line[0..colon];
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (validation.connection_specific_header(name) or
                    std.ascii.eqlIgnoreCase(name, "te"))
                {
                    return error.InvalidHeaders;
                }

                const required = std.math.add(usize, name.len, value.len) catch return error.BufferOverflow;
                if (required > self.response_header_storage.len - self.response_header_length) {
                    return error.BufferOverflow;
                }

                const index = self.response_header_count;
                const name_offset = self.response_header_length;
                for (name, 0..) |byte, offset| {
                    self.response_header_storage[name_offset + offset] = std.ascii.toLower(byte);
                }
                self.response_header_length += name.len;
                const value_offset = self.response_header_length;
                @memcpy(
                    self.response_header_storage[value_offset .. value_offset + value.len],
                    value,
                );
                self.response_header_length += value.len;

                self.response_name_offsets[index] = @intCast(name_offset);
                self.response_name_lengths[index] = @intCast(name.len);
                self.response_value_offsets[index] = @intCast(value_offset);
                self.response_value_lengths[index] = @intCast(value.len);
                self.response_header_count += 1;
            }
        }

        /// Records one completed request/response cycle in this thread's log.
        ///
        /// The record borrows the attached header set's method and path, which
        /// the stream keeps alive until `on_close`. Recording is best effort:
        /// a silent sink is skipped before any clock read, and a full sink
        /// counts the line as dropped.
        fn log_http_request(self: *Self) void {
            const sink = dev_log_module.thread_sink();
            if (!sink.enabled) return;
            const header_set = self.header_set orelse return;
            sink.record(.{
                .timestamp_ms = dev_log_module.now_ms(sink.io),
                .level = .info,
                .direction = .data_out,
                .event = .{ .http_request = .{
                    .method = header_set.request.method,
                    .path = header_set.request.path,
                    .status = self.response_status_code,
                } },
            });
        }

        fn send_headers(self: *Self) bool {
            var header_array: [capacities.response_header_count + 1]c.struct_uz_lsxpack_header = undefined;
            set_xpack_header(&header_array[0], &self.response_status, 0, 7, 7, 3);

            var index: usize = 0;
            while (index < self.response_header_count) : (index += 1) {
                set_xpack_header(
                    &header_array[index + 1],
                    self.response_header_storage,
                    self.response_name_offsets[index],
                    self.response_name_lengths[index],
                    self.response_value_offsets[index],
                    self.response_value_lengths[index],
                );
            }

            var headers = c.lsquic_http_headers_t{
                .count = @intCast(self.response_header_count + 1),
                .headers = @ptrCast(&header_array[0]),
            };
            return io.send_headers(self.stream, &headers, 0) == 0;
        }

        fn queue_error(self: *Self, status: []const u8, body: []const u8) void {
            if (self.response_phase != .idle) {
                self.close_now();
                return;
            }
            self.dispatched = true;
            _ = io.wantread(self.stream, 0);
            _ = io.shutdown(self.stream, 0);
            end_response(self, status, "", body) catch self.close_now();
        }

        fn abort_response(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.close_now();
            self.response_phase = .done;
        }

        fn close_now(self: *Self) void {
            self.async_response_state.cancel();
            self.clear_stream_producer();
            _ = io.close(self.stream);
        }
    };
}

/// Production HTTP/3 stream state bound to the lsquic stream API.
pub const QuicStream = stream_with(lsquic_stream_io, default_capacities);

fn forbidden_trailer_field(name: []const u8) bool {
    return std.mem.eql(u8, name, "content-length") or
        std.mem.eql(u8, name, "host") or
        std.mem.eql(u8, name, "te") or
        std.mem.eql(u8, name, "trailer") or
        std.mem.eql(u8, name, "transfer-encoding");
}

fn set_xpack_header(
    header: *c.struct_uz_lsxpack_header,
    buffer: []const u8,
    name_offset: usize,
    name_length: usize,
    value_offset: usize,
    value_length: usize,
) void {
    header.* = std.mem.zeroes(c.struct_uz_lsxpack_header);
    header.buf = @ptrCast(@constCast(buffer.ptr));
    header.name_offset = @intCast(name_offset);
    header.name_len = @intCast(name_length);
    header.val_offset = @intCast(value_offset);
    header.val_len = @intCast(value_length);
}
