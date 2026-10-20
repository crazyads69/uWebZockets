const std = @import("std");
const tcp = @import("../core/tcp.zig");
const tcp_file = @import("../core/tcp_file.zig");
const streams = @import("streams.zig");
const cookie_module = @import("cookie.zig");
const http_status = @import("status.zig");
const dev_log = @import("../observability/dev_log.zig");
const CompressionPool = @import("compression_pool.zig").Pool;
const TcpConnection = tcp.TcpConnection;

/// HTTP/3 end callback: status, response fields, and body bytes.
pub const Http3EndFn = *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void;
/// HTTP/3 begin callback: status and response fields.
pub const Http3BeginFn = *const fn (*anyopaque, []const u8, []const u8) anyerror!void;
/// HTTP/3 write callback for one body chunk.
pub const Http3WriteFn = *const fn (*anyopaque, []const u8) anyerror!void;
/// HTTP/3 finish callback for a completed streaming response.
pub const Http3FinishFn = *const fn (*anyopaque) anyerror!void;

/// HTTP/2 end callback: stream id, status, response fields, and body bytes.
pub const Http2EndFn = *const fn (*anyopaque, u32, []const u8, []const u8, []const u8) anyerror!void;
/// HTTP/2 begin callback: stream id, status, and response fields.
pub const Http2BeginFn = *const fn (*anyopaque, u32, []const u8, []const u8) anyerror!void;
/// HTTP/2 write callback for one body chunk.
pub const Http2WriteFn = *const fn (*anyopaque, u32, []const u8) anyerror!void;
/// HTTP/2 finish callback for a completed streaming response.
pub const Http2FinishFn = *const fn (*anyopaque, u32) anyerror!void;

/// Deferred completion callback: status, response fields, and body bytes.
pub const AsyncCompleteFn = *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void;
/// Wakes the suspended transport dispatch after deferred completion.
pub const AsyncWakeFn = *const fn (*anyopaque) void;

/// Outcome of one drain-driven producer invocation.
pub const StreamStatus = enum {
    /// The transport accepted all bytes it can hold; the producer runs again
    /// when output space frees.
    pending,
    /// The producer called `end_chunks`; the response is complete.
    done,
};

/// Pull-based chunked response body producer.
///
/// The callback writes through `response.write_chunk` as much as fits and
/// returns `.pending` when the transport backpressures, or `.done` after it
/// calls `response.end_chunks`. It is re-invoked on the owning event loop
/// whenever output space frees, so arbitrarily large bodies need no queue
/// sizing.
pub const StreamProducer = *const fn (*anyopaque, *Response) anyerror!StreamStatus;

/// HTTP/3 producer arming callback: context, status, headers, producer
/// context, producer. Returns true when the producer already finished.
pub const Http3StreamBeginFn = *const fn (
    *anyopaque,
    []const u8,
    []const u8,
    *anyopaque,
    StreamProducer,
) anyerror!bool;
/// HTTP/2 producer arming callback: context, stream id, status, headers,
/// producer context, producer. Returns true when the producer already
/// finished.
pub const Http2StreamBeginFn = *const fn (
    *anyopaque,
    u32,
    []const u8,
    []const u8,
    *anyopaque,
    StreamProducer,
) anyerror!bool;

/// HTTP/3 stream callbacks used by the transport-neutral response writer.
pub const Http3Target = struct {
    context: *anyopaque,
    end_fn: Http3EndFn,
    begin_fn: Http3BeginFn,
    write_fn: Http3WriteFn,
    finish_fn: Http3FinishFn,
    /// Optional drain-driven producer arming; null reports unsupported.
    begin_stream_fn: ?Http3StreamBeginFn = null,
};

/// HTTP/2 stream callbacks backed by a connection-owned bounded session.
pub const Http2Target = struct {
    context: *anyopaque,
    router: *const anyopaque,
    stream_id: u32,
    end_fn: Http2EndFn,
    begin_fn: Http2BeginFn,
    write_fn: Http2WriteFn,
    finish_fn: Http2FinishFn,
    /// Optional drain-driven producer arming; null reports unsupported.
    begin_stream_fn: ?Http2StreamBeginFn = null,
    /// Optional per-worker gzip pool for `Response.end_gzip`.
    compression_pool: ?*CompressionPool = null,
};

/// Active transport receiving response bytes.
pub const ConnectionTarget = union(enum) {
    tcp: *TcpConnection,
    http2: Http2Target,
    http3: Http3Target,
};

/// Synchronous response lifecycle enforced across every transport.
pub const ResponseState = enum(u8) {
    idle,
    streaming,
    ended,
};

/// Transport callbacks retained by a connection-owned async response state.
pub const AsyncTarget = struct {
    context: *anyopaque,
    complete_fn: AsyncCompleteFn,
    wake_fn: AsyncWakeFn,
};

/// Lifecycle of one connection-owned async response slot.
pub const AsyncState = enum(u8) {
    idle,
    pending,
    completing,
    completed,
    cancelled,
};

/// Stable state embedded in an HTTP/1 connection, HTTP/2 stream, or HTTP/3 stream.
///
/// Re-arming increments a generation so tokens retained past transport reuse
/// fail closed. Methods are event-loop confined; cross-thread completion must
/// first be marshalled onto the owning loop.
pub const AsyncResponseState = struct {
    target: ?AsyncTarget = null,
    generation: u64 = 0,
    state: AsyncState = .idle,

    /// Arms the slot and returns a copyable one-shot token.
    pub fn arm(self: *AsyncResponseState, target: AsyncTarget) AsyncResponse {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.target = target;
        self.state = .pending;
        return .{ .owner = self, .generation = self.generation };
    }

    /// Invalidates every outstanding token without touching the transport.
    pub fn cancel(self: *AsyncResponseState) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.target = null;
        self.state = .cancelled;
    }

    /// Reports whether the current generation still awaits completion.
    pub fn is_pending(self: *const AsyncResponseState) bool {
        return self.state == .pending;
    }
};

/// Copyable generation-checked token for exactly one deferred response.
///
/// The token borrows transport-owned state that remains stable until the
/// connection or stream closes. Completion must run on that transport's event
/// loop. A second completion or a completion after reuse returns an error.
pub const AsyncResponse = struct {
    owner: *AsyncResponseState,
    generation: u64,

    /// Completes with no additional response fields.
    pub fn complete(
        self: AsyncResponse,
        status: []const u8,
        body: []const u8,
    ) !void {
        return self.complete_with_headers(status, "", body);
    }

    /// Completes once and wakes the suspended transport dispatch.
    pub fn complete_with_headers(
        self: AsyncResponse,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        if (self.generation != self.owner.generation) return error.AsyncResponseExpired;
        if (self.owner.state != .pending) return error.AsyncResponseAlreadyCompleted;
        const target = self.owner.target orelse return error.AsyncResponseExpired;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code) and body.len != 0) return error.BodyNotAllowed;

        self.owner.state = .completing;
        target.complete_fn(target.context, status, headers, body) catch |err| {
            self.owner.state = .completed;
            self.owner.target = null;
            target.wake_fn(target.context);
            return err;
        };
        self.owner.state = .completed;
        self.owner.target = null;
        target.wake_fn(target.context);
    }

    /// Reports whether this exact generation can still complete.
    pub fn is_pending(self: AsyncResponse) bool {
        return self.generation == self.owner.generation and self.owner.state == .pending;
    }
};

/// Records one completed HTTP request/response cycle in the connection log.
fn log_http_request(conn: *TcpConnection, status: u16) void {
    const sink = conn.dev_log orelse return;
    sink.record(.{
        .timestamp_ms = dev_log.now_ms(conn.io),
        .level = .info,
        .direction = .data_out,
        .event = .{ .http_request = .{
            .method = conn.req.method,
            .path = conn.req.path,
            .status = status,
        } },
    });
}

/// Transport-neutral synchronous response writer.
pub const Response = struct {
    const pending_header_capacity = 2048;

    target: ConnectionTarget,
    state: ResponseState = .idle,
    close_after_end: bool = false,
    pending_headers: [pending_header_capacity]u8 = undefined,
    pending_header_length: usize = 0,

    /// Sends a complete response with no additional fields.
    pub fn end(self: *Response, status: []const u8, body: []const u8) !void {
        return self.end_with_headers(status, "", body);
    }

    /// Sends a complete response with validated raw response fields.
    pub fn end_with_headers(
        self: *Response,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code) and body.len != 0) return error.BodyNotAllowed;

        switch (self.target) {
            .tcp => |conn| {
                const pending = self.pending_headers[0..self.pending_header_length];
                const close_requested = headers_have_token(pending, "Connection", "close") or
                    headers_have_token(headers, "Connection", "close");
                var framing_buffer: [128]u8 = undefined;
                const framing = try http_status.format_http1_framing(
                    &framing_buffer,
                    status,
                    if (status_forbids_body(code)) null else body.len,
                );

                // Write the head as scatter parts so header size is bounded by
                // the write ring, not by a fixed concatenation buffer.
                if (conn.suppress_response_body or status_forbids_body(code)) {
                    try tcp_file.write_data_parts(conn, &.{ framing, pending, headers, "\r\n" });
                } else {
                    try tcp_file.write_data_parts(conn, &.{ framing, pending, headers, "\r\n", body });
                }
                log_http_request(conn, code);
                if (close_requested) tcp.close_after_flush(conn);
            },
            .http3 => |target| {
                var combined_buffer: [pending_header_capacity * 2]u8 = undefined;
                const complete_headers = try self.combine_headers(headers, &combined_buffer);
                try target.end_fn(target.context, status, complete_headers, body);
            },
            .http2 => |target| {
                var combined_buffer: [pending_header_capacity * 2]u8 = undefined;
                const complete_headers = try self.combine_headers(headers, &combined_buffer);
                try target.end_fn(target.context, target.stream_id, status, complete_headers, body);
            },
        }
        self.state = .ended;
    }

    /// Sends a gzip-compressed response from the per-worker codec pool.
    ///
    /// The pool must be enabled with `with_http_compression(true)`. HTTP/1 and
    /// HTTP/2 use the borrowed worker pool; HTTP/3 reports unsupported until a
    /// pool is threaded through the QUIC stream context.
    pub fn end_gzip(
        self: *Response,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (headers_have_field(headers, "Content-Encoding") or
            headers_have_field(self.pending_headers[0..self.pending_header_length], "Content-Encoding"))
        {
            return error.DuplicateContentEncoding;
        }
        if (status_forbids_body(code)) return self.end_with_headers(status, headers, "");

        const pool = switch (self.target) {
            .tcp => |conn| conn.http_compression,
            .http2 => |target| target.compression_pool,
            .http3 => return error.CompressionUnsupported,
        } orelse return error.CompressionUnavailable;

        const compressed = try pool.gzip(body);
        var merged_buffer: [pending_header_capacity]u8 = undefined;
        const merged = std.fmt.bufPrint(
            &merged_buffer,
            "Content-Encoding: gzip\r\nVary: Accept-Encoding\r\n{s}",
            .{headers},
        ) catch return error.HeadersTooLarge;
        return self.end_with_headers(status, merged, compressed);
    }

    /// Streams an opened regular file as the response body at the kernel boundary.
    ///
    /// On success the plaintext connection owns `file` and closes it when the
    /// body drains; on any error the caller retains ownership. TLS-framed and
    /// HTTP/2 and HTTP/3 streams fail with `error.ZeroCopyUnavailable` so the
    /// caller can fall back to a bounded buffered body.
    pub fn send_file(
        self: *Response,
        status: []const u8,
        headers: []const u8,
        file: std.Io.File,
        offset: u64,
        length: u64,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code)) return error.BodyNotAllowed;

        switch (self.target) {
            .tcp => |conn| {
                const pending = self.pending_headers[0..self.pending_header_length];
                const close_requested = headers_have_token(pending, "Connection", "close") or
                    headers_have_token(headers, "Connection", "close");
                try conn.begin_file_response(
                    status,
                    pending,
                    headers,
                    file,
                    offset,
                    length,
                    close_requested,
                );
                log_http_request(conn, code);
            },
            .http2, .http3 => return error.ZeroCopyUnavailable,
        }
        self.state = .ended;
    }

    /// Starts a bounded streaming response.
    pub fn begin_chunked(
        self: *Response,
        status: []const u8,
        headers: []const u8,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code)) return error.BodyNotAllowed;

        switch (self.target) {
            .tcp => |conn| {
                const pending = self.pending_headers[0..self.pending_header_length];
                self.close_after_end = headers_have_token(pending, "Connection", "close") or
                    headers_have_token(headers, "Connection", "close");
                if (conn.suppress_response_body) return error.BodyNotAllowed;

                var framing_buffer: [128]u8 = undefined;
                const framing = try http_status.format_http1_chunked_framing(&framing_buffer, status);
                try tcp_file.write_data_parts(conn, &.{ framing, pending, headers, "\r\n" });
                log_http_request(conn, code);
            },
            .http3 => |target| {
                var combined_buffer: [pending_header_capacity * 2]u8 = undefined;
                const complete_headers = try self.combine_headers(headers, &combined_buffer);
                try target.begin_fn(target.context, status, complete_headers);
            },
            .http2 => |target| {
                var combined_buffer: [pending_header_capacity * 2]u8 = undefined;
                const complete_headers = try self.combine_headers(headers, &combined_buffer);
                try target.begin_fn(target.context, target.stream_id, status, complete_headers);
            },
        }
        self.state = .streaming;
    }

    /// Starts a chunked response fed by `producer` as the transport drains.
    ///
    /// The producer runs immediately and again whenever output space frees, so
    /// arbitrarily large bodies never require sizing the write queue. Return
    /// `.pending` whenever `write_chunk` backpressures and `.done` after
    /// calling `end_chunks`. All transports resume producers; a target whose
    /// callback is absent fails closed with `error.ProducerStreamingUnsupported`
    /// before any bytes are written.
    pub fn begin_stream(
        self: *Response,
        status: []const u8,
        headers: []const u8,
        context: *anyopaque,
        producer: StreamProducer,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code)) return error.BodyNotAllowed;

        switch (self.target) {
            .tcp => |conn| {
                try self.begin_chunked(status, headers);
                const finished = conn.start_stream(context, producer, self.close_after_end);
                self.state = if (finished) .ended else .streaming;
            },
            .http2 => |target| {
                const arm = target.begin_stream_fn orelse return error.ProducerStreamingUnsupported;
                var combined_buffer: [pending_header_capacity * 2]u8 = undefined;
                const complete_headers = try self.combine_headers(headers, &combined_buffer);
                const finished = try arm(
                    target.context,
                    target.stream_id,
                    status,
                    complete_headers,
                    context,
                    producer,
                );
                self.state = if (finished) .ended else .streaming;
            },
            .http3 => |target| {
                const arm = target.begin_stream_fn orelse return error.ProducerStreamingUnsupported;
                var combined_buffer: [pending_header_capacity * 2]u8 = undefined;
                const complete_headers = try self.combine_headers(headers, &combined_buffer);
                const finished = try arm(target.context, status, complete_headers, context, producer);
                self.state = if (finished) .ended else .streaming;
            },
        }
    }

    /// Appends one chunk to a streaming response.
    pub fn write_chunk(self: *Response, chunk: []const u8) !void {
        if (self.state != .streaming) return error.ResponseNotStreaming;

        switch (self.target) {
            .tcp => |conn| try @import("chunked.zig").send_chunk(conn, chunk),
            .http3 => |target| try target.write_fn(target.context, chunk),
            .http2 => |target| try target.write_fn(target.context, target.stream_id, chunk),
        }
    }

    /// Finishes a streaming response.
    pub fn end_chunks(self: *Response) !void {
        if (self.state != .streaming) return error.ResponseNotStreaming;

        switch (self.target) {
            .tcp => |conn| {
                try @import("chunked.zig").end(conn);
                if (self.close_after_end) tcp.close_after_flush(conn);
            },
            .http3 => |target| try target.finish_fn(target.context),
            .http2 => |target| try target.finish_fn(target.context, target.stream_id),
        }
        self.state = .ended;
    }

    /// Reports whether the response ended successfully.
    pub fn is_complete(self: *const Response) bool {
        return self.state == .ended;
    }

    /// Reports whether any response bytes were started.
    pub fn is_started(self: *const Response) bool {
        return self.state != .idle;
    }

    /// Starts a `200 OK` chunked JSON response and returns a streaming writer.
    ///
    /// The stream coalesces into a fixed stack buffer and emits response
    /// chunks, so arbitrary-size JSON needs no allocation. Through
    /// `JsonStream.writer`/`stringify`, transport backpressure surfaces as
    /// `std.Io.Writer`'s `error.WriteFailed`; `JsonStream.write_chunk`
    /// propagates the real transport error. Call `JsonStream.end` to flush and
    /// terminate the chunked body.
    pub fn begin_json(self: *Response) !JsonStream {
        try self.begin_chunked(
            "200 OK",
            "Content-Type: application/json; charset=utf-8\r\n",
        );
        return .{ .response = self };
    }

    /// Queues one validated response field before the response starts.
    pub fn append_header(self: *Response, name: []const u8, value: []const u8) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        // `valid_headers` validates field syntax, but a CR/LF inside one value
        // would parse as an extra well-formed field; reject the split here so
        // every singular header helper stays injection-safe.
        if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidHeaders;
        var line_buffer: [1024]u8 = undefined;
        // Bound each slice first so the concatenated length cannot wrap.
        if (name.len > line_buffer.len or value.len > line_buffer.len) return error.BufferOverflow;
        const line_length = name.len + ": ".len + value.len + "\r\n".len;
        if (line_length > line_buffer.len) return error.BufferOverflow;
        @memcpy(line_buffer[0..name.len], name);
        @memcpy(line_buffer[name.len..][0..": ".len], ": ");
        @memcpy(line_buffer[name.len + ": ".len ..][0..value.len], value);
        @memcpy(line_buffer[line_length - "\r\n".len ..][0.."\r\n".len], "\r\n");
        const line = line_buffer[0..line_length];
        if (!valid_headers(line)) return error.InvalidHeaders;
        if (line.len > self.pending_headers.len - self.pending_header_length) {
            return error.BufferOverflow;
        }
        @memcpy(self.pending_headers[self.pending_header_length..][0..line.len], line);
        self.pending_header_length += line.len;
    }

    /// Queues one validated RFC 6265 Set-Cookie field.
    pub fn set_cookie(
        self: *Response,
        name: []const u8,
        value: []const u8,
        options: cookie_module.Options,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        var buffer: [1024]u8 = undefined;
        const field = cookie_module.format(&buffer, name, value, options) catch |err| switch (err) {
            error.WriteFailed => return error.BufferOverflow,
            else => |cookie_error| return cookie_error,
        };
        if (field.len > self.pending_headers.len - self.pending_header_length) {
            return error.BufferOverflow;
        }
        @memcpy(self.pending_headers[self.pending_header_length..][0..field.len], field);
        self.pending_header_length += field.len;
    }

    /// Signs and queues one tamper-evident session cookie.
    pub fn set_signed_cookie(
        self: *Response,
        name: []const u8,
        value: []const u8,
        secret: []const u8,
        options: cookie_module.Options,
    ) !void {
        var signed_buffer: [1024]u8 = undefined;
        const signed = try cookie_module.sign(&signed_buffer, value, secret);
        return self.set_cookie(name, signed, options);
    }

    /// Starts a Server-Sent Events stream with safe cache and proxy defaults.
    pub fn sse(self: *Response) !ServerSentEvents {
        try self.begin_chunked(
            "200 OK",
            "Content-Type: text/event-stream\r\nCache-Control: no-cache\r\nX-Accel-Buffering: no\r\n",
        );
        return .{ .response = self };
    }

    /// Sends a 200 OK plain text response (Web Standards Response.text).
    pub fn text(self: *Response, content: []const u8) !void {
        return self.end_with_headers("200 OK", "Content-Type: text/plain; charset=utf-8\r\n", content);
    }

    /// Sends a 200 OK HTML response.
    pub fn html(self: *Response, content: []const u8) !void {
        return self.end_with_headers("200 OK", "Content-Type: text/html; charset=utf-8\r\n", content);
    }

    /// Sends a 200 OK binary response (Web Standards Response.bytes).
    pub fn bytes(self: *Response, content: []const u8) !void {
        return self.end_with_headers("200 OK", "Content-Type: application/octet-stream\r\n", content);
    }

    /// Sends a 200 OK JSON response formatted using caller-owned buffer (zero-allocation).
    ///
    /// Polymorphic entry point: `value` is any type `std.json.Stringify`
    /// supports, including `std.json.Value`. Callers that prefer a named type
    /// use `json_value_buf`.
    pub fn json_buf(self: *Response, value: anytype, buffer: []u8) !void {
        const payload = std.fmt.bufPrint(buffer, "{f}", .{std.json.fmt(value, .{})}) catch return error.BufferOverflow;
        return self.end_with_headers("200 OK", "Content-Type: application/json; charset=utf-8\r\n", payload);
    }

    /// Sends a 200 OK JSON response formatted using an allocator (Web Standards Response.json).
    ///
    /// Polymorphic entry point with the same contract as `json_buf`; the
    /// allocator only backs the temporary rendering, which is released before
    /// the response returns. Callers that prefer a named type use `json_value`.
    pub fn json(self: *Response, value: anytype, allocator: std.mem.Allocator) !void {
        const payload = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
        defer allocator.free(payload);
        return self.end_with_headers("200 OK", "Content-Type: application/json; charset=utf-8\r\n", payload);
    }

    /// Sends a 200 OK JSON response for a dynamic `std.json.Value`.
    ///
    /// Named-type alternative to `json_buf` for callers that assemble JSON at
    /// runtime instead of through a Zig value.
    pub fn json_value_buf(self: *Response, value: std.json.Value, buffer: []u8) !void {
        return self.json_buf(value, buffer);
    }

    /// Sends a 200 OK JSON response for a dynamic `std.json.Value`.
    ///
    /// Named-type alternative to `json` with the same allocation contract.
    pub fn json_value(self: *Response, value: std.json.Value, allocator: std.mem.Allocator) !void {
        return self.json(value, allocator);
    }

    /// Sends a redirection response (Web Standards Response.redirect).
    pub fn redirect(self: *Response, location: []const u8, code: ?u16) !void {
        for (location) |byte| {
            if (byte == '\r' or byte == '\n') return error.InvalidHeaders;
        }
        const status_str = switch (code orelse 302) {
            301 => "301 Moved Permanently",
            302 => "302 Found",
            303 => "303 See Other",
            307 => "307 Temporary Redirect",
            308 => "308 Permanent Redirect",
            else => "302 Found",
        };
        var buf: [512]u8 = undefined;
        // Bound the slice first so the concatenated length cannot wrap.
        if (location.len > buf.len) return error.BufferOverflow;
        const required = "Location: ".len + location.len + "\r\n".len;
        if (required > buf.len) return error.BufferOverflow;
        @memcpy(buf[0.."Location: ".len], "Location: ");
        @memcpy(buf["Location: ".len..][0..location.len], location);
        @memcpy(buf[required - "\r\n".len ..][0.."\r\n".len], "\r\n");
        return self.end_with_headers(status_str, buf[0..required], "");
    }

    const StreamWriterAdapter = struct {
        fn write(context: *anyopaque, chunk: []const u8) anyerror!void {
            const res: *Response = @ptrCast(@alignCast(context));
            if (res.state == .idle) {
                try res.begin_chunked("200 OK", "");
            }
            try res.write_chunk(chunk);
        }

        fn close(context: *anyopaque) anyerror!void {
            const res: *Response = @ptrCast(@alignCast(context));
            if (res.state == .streaming) {
                try res.end_chunks();
            }
        }
    };

    /// Returns a WHATWG WritableByteStream connected directly to this response.
    pub fn writable_stream(self: *Response) streams.WritableByteStream {
        return .{
            .context = self,
            .write_fn = StreamWriterAdapter.write,
            .close_fn = StreamWriterAdapter.close,
        };
    }

    fn combine_headers(
        self: *const Response,
        headers: []const u8,
        buffer: []u8,
    ) ![]const u8 {
        const total = std.math.add(usize, self.pending_header_length, headers.len) catch {
            return error.BufferOverflow;
        };
        if (total > buffer.len) return error.BufferOverflow;
        @memcpy(buffer[0..self.pending_header_length], self.pending_headers[0..self.pending_header_length]);
        @memcpy(buffer[self.pending_header_length..total], headers);
        return buffer[0..total];
    }
};

/// Fixed buffer used by `JsonStream` to coalesce small JSON writes into
/// fewer response chunks.
const json_stream_buffer_size = 4096;

/// Streaming JSON body writer returned by `Response.begin_json`.
///
/// Writes pass through a fixed stack buffer and leave as chunked response
/// parts, so no allocation is needed for any body size that the configured
/// write queue can hold. Keep the value at a stable address while streaming;
/// do not copy it after the first write.
pub const JsonStream = struct {
    response: *Response,
    initialized: bool = false,
    buffer: [json_stream_buffer_size]u8 = undefined,
    sink: std.Io.Writer = undefined,

    /// Returns the buffered writer accepted by `std.json.Stringify`/`std.fmt`.
    pub fn writer(self: *JsonStream) *std.Io.Writer {
        if (!self.initialized) {
            self.sink = .{ .buffer = &self.buffer, .vtable = &stream_vtable };
            self.initialized = true;
        }
        return &self.sink;
    }

    /// Returns a `std.json.Stringify` bound to this stream.
    pub fn stringify(self: *JsonStream) std.json.Stringify {
        return .{ .writer = self.writer() };
    }

    /// Writes raw JSON bytes through the coalescing buffer.
    pub fn write(self: *JsonStream, bytes: []const u8) !void {
        self.writer().writeAll(bytes) catch return error.WriteFailed;
    }

    /// Flushes buffered bytes as response chunks.
    pub fn flush(self: *JsonStream) !void {
        self.writer().flush() catch return error.WriteFailed;
    }

    /// Flushes the buffer, then writes one chunk with transport errors intact.
    ///
    /// Unlike the `std.Io.Writer` path, `error.WouldBlock` reaches the caller
    /// so an application can size the write queue or abort deliberately.
    pub fn write_chunk(self: *JsonStream, bytes: []const u8) !void {
        const sink = self.writer();
        if (sink.end != 0) {
            try self.response.write_chunk(sink.buffered());
            sink.end = 0;
        }
        return self.response.write_chunk(bytes);
    }

    /// Flushes and finishes the chunked response.
    pub fn end(self: *JsonStream) !void {
        try self.flush();
        return self.response.end_chunks();
    }

    const stream_vtable = std.Io.Writer.VTable{ .drain = stream_drain };

    fn stream_drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *JsonStream = @alignCast(@fieldParentPtr("sink", w));
        if (w.end != 0) {
            self.response.write_chunk(w.buffered()) catch return error.WriteFailed;
            w.end = 0;
        }

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            if (slice.len == 0) continue;
            self.response.write_chunk(slice) catch return error.WriteFailed;
            consumed += slice.len;
        }
        const pattern = data[data.len - 1];
        if (pattern.len != 0 and splat != 0) {
            for (0..splat) |_| {
                self.response.write_chunk(pattern) catch return error.WriteFailed;
            }
            consumed += pattern.len * splat;
        }
        return consumed;
    }
};

/// Allocation-free writer for one active text/event-stream response.
pub const ServerSentEvents = struct {
    response: *Response,

    pub fn send_event(self: *ServerSentEvents, event: []const u8, data: []const u8) !void {
        if (std.mem.indexOfAny(u8, event, "\r\n") != null) return error.InvalidEventName;
        if (event.len != 0) {
            try self.response.write_chunk("event: ");
            try self.response.write_chunk(event);
            try self.response.write_chunk("\n");
        }

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
            try self.response.write_chunk("data: ");
            try self.response.write_chunk(line);
            try self.response.write_chunk("\n");
        }
        try self.response.write_chunk("\n");
    }

    pub fn heartbeat(self: *ServerSentEvents) !void {
        return self.response.write_chunk(": keep-alive\n\n");
    }

    pub fn close(self: *ServerSentEvents) !void {
        return self.response.end_chunks();
    }
};

/// Parses a validated `NNN` or `NNN reason` status in the supported range.
pub fn status_code(status: []const u8) ?u16 {
    if (status.len < 3) return null;
    for (status[0..3]) |c| {
        if (c < '0' or c > '9') return null;
    }
    if (status.len > 3 and status[3] != ' ') return null;

    if (status.len > 4) {
        for (status[4..]) |c| {
            if ((c < 32 and c != '\t') or c == 127) return null;
        }
    }

    const code = std.fmt.parseInt(u16, status[0..3], 10) catch return null;
    if (code < 200 or code > 599) return null;
    return code;
}

/// Reports whether a final response status forbids payload bytes.
pub fn status_forbids_body(code: u16) bool {
    return code == 204 or code == 205 or code == 304;
}

/// Validates raw HTTP/1-style response fields without allocating.
pub fn valid_headers(headers: []const u8) bool {
    if (headers.len == 0) return true;
    if (!std.mem.endsWith(u8, headers, "\r\n")) return false;

    var lines = std.mem.splitSequence(u8, headers[0 .. headers.len - 2], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) return false;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        const name = line[0..colon];
        if (name.len == 0) return false;

        for (name) |c| {
            if (!is_tchar(c)) return false;
        }
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) return false;
        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) return false;

        for (line[colon + 1 ..]) |c| {
            if ((c < 32 and c != '\t') or c == 127) return false;
        }
    }
    return true;
}

/// Finds one case-insensitive field name in raw response fields.
pub fn headers_have_field(headers: []const u8, name: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return true;
    }
    return false;
}

/// Finds a case-insensitive token in comma-delimited raw response fields.
pub fn headers_have_token(headers: []const u8, name: []const u8, token: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;

        var values = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
        while (values.next()) |value| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), token)) return true;
        }
    }
    return false;
}

fn is_tchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}
