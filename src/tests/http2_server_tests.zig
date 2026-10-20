const std = @import("std");
const support = @import("test_support");
const http2 = support.http2;
const http2_server = support.http2_server;
const hpack = support.http2_hpack;
const Request = support.http_request.Request;
const Response = support.http_response.Response;
const radix = support.radix;

const TestSession = http2_server.server_session(4);
const SingleStreamSession = http2_server.server_session(1);
const test_capacities = TestSession.Capacities{
    .header_block_size = 4096,
    .request_header_size = 4096,
    .body_size = 1024,
};
const single_capacities = SingleStreamSession.Capacities{
    .header_block_size = 4096,
    .request_header_size = 4096,
    .body_size = 1024,
};
const TestBundle = TestSession.Bundle(test_capacities);
const SingleBundle = SingleStreamSession.Bundle(single_capacities);

/// Owns one session's carved storage and hands out the bound session value.
const SessionFixture = struct {
    bundle: TestBundle = .{},
    session: TestSession = .{},

    fn init(self: *SessionFixture) !void {
        self.session = try TestSession.init(self.bundle.storage());
    }
};

/// Owns one single-stream session's carved storage.
const SingleFixture = struct {
    bundle: SingleBundle = .{},
    session: SingleStreamSession = .{},

    fn init(self: *SingleFixture) !void {
        self.session = try SingleStreamSession.init(self.bundle.storage());
    }
};

const TestState = struct {
    session: *TestSession,
    router_bundle: radix.DefaultBundle = .{},
    router: radix.Router = .{},
    output: [8192]u8 = undefined,
    output_length: usize = 0,
    dispatch_order: [4]u32 = undefined,
    dispatch_count: usize = 0,
    middleware_count: usize = 0,
    async_state: support.http_response.AsyncResponseState = .{},
    pending_response: ?support.http_response.AsyncResponse = null,
    async_stream_id: u32 = 0,
    wake_count: usize = 0,
    saw_dynamic_header: bool = false,

    /// Binds the embedded router storage once the state address is stable.
    fn init_router(self: *TestState) void {
        if (self.router.node_count != 0) return;
        // DefaultBundle capacities are comptime-validated, so init cannot fail.
        self.router = radix.Router.init(self.router_bundle.storage()) catch unreachable;
    }

    fn callbacks(self: *TestState) http2_server.Callbacks {
        return .{
            .context = self,
            .write_fn = write,
            .request_fn = dispatch,
            .stream_closed_fn = stream_closed,
        };
    }

    fn stream_closed(context: *anyopaque, stream_id: u32, _: u16) void {
        const self: *TestState = @ptrCast(@alignCast(context));
        if (self.async_stream_id != stream_id) return;
        if (self.async_state.is_pending()) self.async_state.cancel();
        self.async_stream_id = 0;
    }

    fn write(context: *anyopaque, parts: []const []const u8) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        for (parts) |part| {
            if (part.len > self.output.len - self.output_length) return error.OutputTooSmall;
            @memcpy(self.output[self.output_length .. self.output_length + part.len], part);
            self.output_length += part.len;
        }
    }

    fn dispatch(context: *anyopaque, request: *Request, stream_id: u32) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        self.dispatch_order[self.dispatch_count] = stream_id;
        self.dispatch_count += 1;

        var response = Response{ .target = .{ .http2 = .{
            .context = self,
            .router = &self.router,
            .stream_id = stream_id,
            .end_fn = response_end,
            .begin_fn = response_begin,
            .write_fn = response_write,
            .finish_fn = response_finish,
        } } };
        if (!request.valid_query_content_type()) {
            try response.end("400 Bad Request", "QUERY requires a valid Content-Type");
            return;
        }
        const method = radix.HttpMethod.parse(request.method);
        const route = self.router.match_request(request, method) orelse
            return error.RouteNotFound;
        if (self.router.run_middleware(request, &response) == .stop) return;
        const handler = route.handler orelse return error.RouteNotFound;
        switch (handler) {
            .synchronous => |callback| callback(request, &response),
            .contextual => |binding| binding.callback(binding.context, request, &response),
            .asynchronous => |callback| {
                self.async_stream_id = stream_id;
                const token = self.async_state.arm(.{
                    .context = self,
                    .complete_fn = async_complete,
                    .wake_fn = async_wake,
                });
                callback(request, token);
                return;
            },
            .contextual_async => |binding| {
                self.async_stream_id = stream_id;
                const token = self.async_state.arm(.{
                    .context = self,
                    .complete_fn = async_complete,
                    .wake_fn = async_wake,
                });
                binding.callback(binding.context, request, token);
                return;
            },
        }
        if (!response.is_complete()) return error.IncompleteResponse;
    }

    fn response_end(
        context: *anyopaque,
        stream_id: u32,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.send_response(
            stream_id,
            status,
            headers,
            body,
            self.callbacks(),
        );
    }

    fn response_begin(
        context: *anyopaque,
        stream_id: u32,
        status: []const u8,
        headers: []const u8,
    ) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.begin_response(stream_id, status, headers, self.callbacks());
    }

    fn response_write(context: *anyopaque, stream_id: u32, bytes: []const u8) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.write_response_data(stream_id, bytes, self.callbacks());
    }

    fn response_finish(context: *anyopaque, stream_id: u32) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.finish_response(stream_id, self.callbacks());
    }

    fn async_complete(
        context: *anyopaque,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.session.send_response(
            self.async_stream_id,
            status,
            headers,
            body,
            self.callbacks(),
        );
    }

    fn async_wake(context: *anyopaque) void {
        const self: *TestState = @ptrCast(@alignCast(context));
        self.wake_count += 1;
    }
};

const RefusalState = struct {
    output: [8192]u8 = undefined,
    output_length: usize = 0,
    dispatch_count: usize = 0,
    saw_dynamic_header: bool = false,

    fn callbacks(self: *RefusalState) http2_server.Callbacks {
        return .{
            .context = self,
            .write_fn = write,
            .request_fn = dispatch,
        };
    }

    fn write(context: *anyopaque, parts: []const []const u8) !void {
        const self: *RefusalState = @ptrCast(@alignCast(context));
        for (parts) |part| {
            if (part.len > self.output.len - self.output_length) return error.OutputTooSmall;
            @memcpy(self.output[self.output_length .. self.output_length + part.len], part);
            self.output_length += part.len;
        }
    }

    fn dispatch(context: *anyopaque, request: *Request, _: u32) !void {
        const self: *RefusalState = @ptrCast(@alignCast(context));
        self.dispatch_count += 1;
        const value = request.get_header("x-test") orelse return;
        self.saw_dynamic_header = std.mem.eql(u8, value, "value");
    }
};

const WriteBehavior = enum {
    accept,
    block_data,
    fail_data,
};

const FlowState = struct {
    output: [16 * 1024]u8 = undefined,
    output_length: usize = 0,
    dispatch_count: usize = 0,
    data_write_attempts: usize = 0,
    behavior: WriteBehavior = .accept,
    max_frame_payload: usize = http2.maximum_frame_size,
    write_capacity: usize = std.math.maxInt(usize),
    queued_length: usize = 0,

    fn callbacks(self: *FlowState) http2_server.Callbacks {
        return .{
            .context = self,
            .write_fn = write,
            .request_fn = dispatch,
            .max_frame_payload = self.max_frame_payload,
        };
    }

    fn write(context: *anyopaque, parts: []const []const u8) !void {
        const self: *FlowState = @ptrCast(@alignCast(context));
        if (parts.len == 0 or parts[0].len != 9) return error.InvalidFrame;
        const header = try http2.FrameHeader.parse(parts[0][0..9]);
        if ((header.frame_type == @intFromEnum(http2.FrameType.headers) or
            header.frame_type == @intFromEnum(http2.FrameType.data)) and
            header.payload_length > self.max_frame_payload)
        {
            return error.WouldBlock;
        }
        if (header.frame_type == @intFromEnum(http2.FrameType.data)) {
            self.data_write_attempts += 1;
            switch (self.behavior) {
                .accept => {},
                .block_data => return error.WouldBlock,
                .fail_data => return error.TestWriteFailure,
            }
        }

        var total_length: usize = 0;
        for (parts) |part| {
            if (part.len > self.write_capacity -| total_length) return error.WouldBlock;
            total_length += part.len;
        }
        if (total_length > self.write_capacity -| self.queued_length) {
            return error.WouldBlock;
        }
        for (parts) |part| {
            if (part.len > self.output.len - self.output_length) return error.OutputTooSmall;
            @memcpy(self.output[self.output_length .. self.output_length + part.len], part);
            self.output_length += part.len;
        }
        self.queued_length += total_length;
    }

    fn dispatch(context: *anyopaque, _: *Request, _: u32) !void {
        const self: *FlowState = @ptrCast(@alignCast(context));
        self.dispatch_count += 1;
    }

    fn drain(self: *FlowState) void {
        self.queued_length = 0;
    }
};

fn append_frame(
    output: []u8,
    offset: *usize,
    frame_type: http2.FrameType,
    flags: u8,
    stream_id: u32,
    payload: []const u8,
) !void {
    if (9 + payload.len > output.len - offset.*) return error.OutputTooSmall;
    var frame_header: [9]u8 = undefined;
    try (http2.FrameHeader{
        .payload_length = @intCast(payload.len),
        .frame_type = @intFromEnum(frame_type),
        .flags = flags,
        .stream_id = stream_id,
    }).encode(&frame_header);
    @memcpy(output[offset.* .. offset.* + 9], &frame_header);
    offset.* += 9;
    @memcpy(output[offset.* .. offset.* + payload.len], payload);
    offset.* += payload.len;
}

fn reset_count(
    output: []const u8,
    stream_id: u32,
    code: http2_server.ErrorCode,
) !usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < output.len) {
        if (output.len - offset < 9) return error.IncompleteFrame;
        const header = try http2.FrameHeader.parse(output[offset..][0..9]);
        const frame_length = 9 + header.payload_length;
        if (frame_length > output.len - offset) return error.IncompleteFrame;
        if (header.frame_type == @intFromEnum(http2.FrameType.rst_stream) and
            header.stream_id == stream_id)
        {
            if (header.payload_length != 4) return error.InvalidFrameSize;
            const payload = output[offset + 9 ..][0..4];
            if (std.mem.readInt(u32, payload, .big) == @intFromEnum(code)) count += 1;
        }
        offset += frame_length;
    }
    return count;
}

fn frame_count(
    output: []const u8,
    frame_type: http2.FrameType,
    stream_id: u32,
) !usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < output.len) {
        if (output.len - offset < 9) return error.IncompleteFrame;
        const header = try http2.FrameHeader.parse(output[offset..][0..9]);
        const frame_length = 9 + header.payload_length;
        if (frame_length > output.len - offset) return error.IncompleteFrame;
        if (header.frame_type == @intFromEnum(frame_type) and
            header.stream_id == stream_id)
        {
            count += 1;
        }
        offset += frame_length;
    }
    return count;
}

/// Returns the error code of the first GOAWAY frame, or null when absent.
fn goaway_code(output: []const u8) !?u32 {
    var offset: usize = 0;
    while (offset < output.len) {
        if (output.len - offset < 9) return error.IncompleteFrame;
        const header = try http2.FrameHeader.parse(output[offset..][0..9]);
        const frame_length = 9 + header.payload_length;
        if (frame_length > output.len - offset) return error.IncompleteFrame;
        if (header.frame_type == @intFromEnum(http2.FrameType.goaway)) {
            if (header.payload_length < 8) return error.InvalidFrameSize;
            return std.mem.readInt(u32, output[offset + 9 + 4 ..][0..4], .big);
        }
        offset += frame_length;
    }
    return null;
}

const DataFrames = struct {
    count: usize = 0,
    bytes_length: usize = 0,
    end_stream_count: usize = 0,
    final_end_stream: bool = false,
};

fn collect_data_frames(
    output: []const u8,
    stream_id: u32,
    bytes: []u8,
) !DataFrames {
    var result = DataFrames{};
    var offset: usize = 0;
    while (offset < output.len) {
        if (output.len - offset < 9) return error.IncompleteFrame;
        const header = try http2.FrameHeader.parse(output[offset..][0..9]);
        const frame_length = 9 + header.payload_length;
        if (frame_length > output.len - offset) return error.IncompleteFrame;
        if (header.frame_type == @intFromEnum(http2.FrameType.data) and
            header.stream_id == stream_id)
        {
            if (header.payload_length > bytes.len - result.bytes_length) {
                return error.OutputTooSmall;
            }
            const payload = output[offset + 9 .. offset + frame_length];
            @memcpy(bytes[result.bytes_length .. result.bytes_length + payload.len], payload);
            result.bytes_length += payload.len;
            result.count += 1;
            result.final_end_stream = header.flags & 0x1 != 0;
            if (result.final_end_stream) result.end_stream_count += 1;
        }
        offset += frame_length;
    }
    return result;
}

fn middleware(
    context: *anyopaque,
    _: *Request,
    _: *Response,
) radix.MiddlewareResult {
    const state: *TestState = @ptrCast(@alignCast(context));
    state.middleware_count += 1;
    return .continue_dispatch;
}

fn route_handler(context: *anyopaque, request: *Request, response: *Response) void {
    const state: *TestState = @ptrCast(@alignCast(context));
    _ = state;
    const id = request.get_param("id") orelse {
        response.end("500 Internal Server Error", "missing route parameter") catch
            @panic("test fixture response failed");
        return;
    };
    response.end_with_headers("200 OK", "Content-Type: text/plain\r\n", id) catch
        @panic("test fixture response failed");
}

fn async_route_handler(
    context: *anyopaque,
    _: *Request,
    response: support.http_response.AsyncResponse,
) void {
    const state: *TestState = @ptrCast(@alignCast(context));
    state.pending_response = response;
}

fn trailer_route_handler(
    context: *anyopaque,
    request: *Request,
    response: *Response,
) void {
    const state: *TestState = @ptrCast(@alignCast(context));
    if (request.get_header("x-test")) |value| {
        state.saw_dynamic_header = std.mem.eql(u8, value, "value");
    }
    response.end("200 OK", "ok") catch @panic("test fixture response failed");
}

test "http2 server: interleaved streams dispatch router and encode responses" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();
    try state.router.use(&state, middleware);
    try state.router.route_context(.get, "/items/:id", &state, route_handler);

    const first_headers = [_]u8{
        0x82, 0x86, 0x04, 0x0a,
        '/',  'i',  't',  'e',
        'm',  's',  '/',  'o',
        'n',  'e',
    };
    const third_headers = [_]u8{
        0x82, 0x86, 0x04, 0x0c,
        '/',  'i',  't',  'e',
        'm',  's',  '/',  't',
        'h',  'r',  'e',  'e',
    };
    var input: [256]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &first_headers);
    try append_frame(&input, &input_length, .headers, 0x4, 3, &third_headers);
    try append_frame(&input, &input_length, .data, 0x1, 3, "body-three");
    try append_frame(&input, &input_length, .data, 0x1, 1, "body-one");

    const callbacks = state.callbacks();
    try session.receive(input[0..7], callbacks);
    try session.receive(input[7..41], callbacks);
    try session.receive(input[41..input_length], callbacks);

    try std.testing.expectEqual(@as(usize, 2), state.dispatch_count);
    try std.testing.expectEqualSlices(u32, &.{ 3, 1 }, state.dispatch_order[0..2]);
    try std.testing.expectEqual(@as(usize, 2), state.middleware_count);
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expect(session.connection.streams.find(3) == null);

    var offset: usize = 0;
    var response_headers: usize = 0;
    var response_data: usize = 0;
    var saw_three = false;
    var saw_one = false;
    while (offset < state.output_length) {
        const header = try http2.FrameHeader.parse(state.output[offset..][0..9]);
        const payload = state.output[offset + 9 .. offset + 9 + header.payload_length];
        if (header.frame_type == @intFromEnum(http2.FrameType.headers) and
            header.stream_id != 0)
        {
            response_headers += 1;
        }
        if (header.frame_type == @intFromEnum(http2.FrameType.data)) {
            response_data += 1;
            if (header.stream_id == 3) saw_three = std.mem.eql(u8, payload, "three");
            if (header.stream_id == 1) saw_one = std.mem.eql(u8, payload, "one");
        }
        offset += 9 + header.payload_length;
    }
    try std.testing.expectEqual(@as(usize, 2), response_headers);
    try std.testing.expectEqual(@as(usize, 2), response_data);
    try std.testing.expect(saw_three and saw_one);
}

test "http2 server: invalid QUERY metadata bypasses middleware" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();
    try state.router.use(&state, middleware);

    const request_headers = [_]u8{
        0x02, 0x05, 'Q',  'U', 'E', 'R',  'Y',
        0x87, 0x01, 0x09, 'l', 'o', 'c',  'a',
        'l',  'h',  'o',  's', 't', 0x04, 0x06,
        '/',  'q',  'u',  'e', 'r', 'y',  0x0f,
        0x10, 0x14, 't',  'e', 'x', 't',  '/',
        'p',  'l',  'a',  'i', 'n', ';',  ' ',
        'c',  'h',  'a',  'r', 's', 'e',  't',
        '=',
    };
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqual(@as(usize, 0), state.middleware_count);
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output[0..state.output_length],
        "QUERY requires a valid Content-Type",
    ) != null);
}

test "http2 server: trailers preserve HPACK dynamic table synchronization" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();
    try state.router.route_context(.get, "/trail", &state, trailer_route_handler);

    const request_headers = [_]u8{
        0x82, 0x86, 0x04, 0x06, '/', 't', 'r', 'a', 'i', 'l',
    };
    const trailer = [_]u8{
        0x40, 0x06, 'x', '-', 't', 'e', 's', 't', 0x05, 'v', 'a', 'l', 'u', 'e',
    };
    const dynamic_request_headers = [_]u8{
        0x82, 0x86, 0x04, 0x06, '/', 't', 'r', 'a', 'i', 'l', 0xbe,
    };
    var input: [192]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &request_headers);
    try append_frame(&input, &input_length, .headers, 0x5, 1, &trailer);
    try append_frame(&input, &input_length, .headers, 0x5, 3, &dynamic_request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 2), state.dispatch_count);
    try std.testing.expect(state.saw_dynamic_header);
}

test "http2 server: refused END_HEADERS preserves HPACK dynamic table state" {
    var fixture: SingleFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = RefusalState{};

    const active_headers = [_]u8{ 0x82, 0x86, 0x84 };
    const refused_headers = [_]u8{
        0x82, 0x86, 0x84, 0x40, 0x06,
        'x',  '-',  't',  'e',  's',
        't',  0x05, 'v',  'a',  'l',
        'u',  'e',
    };
    var input: [160]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &active_headers);
    try append_frame(&input, &input_length, .headers, 0x5, 3, &refused_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqual(@as(u32, 3), session.connection.highest_peer_stream_id);
    try std.testing.expectEqual(@as(usize, 1), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(
            state.output[0..state.output_length],
            3,
            .refused_stream,
        ),
    );

    var late_headers_frame: [64]u8 = undefined;
    var late_headers_length: usize = 0;
    const late_headers = [_]u8{
        0x40, 0x06, 'x', '-', 'l', 'a', 't', 'e',
        0x05, 'l',  'a', 't', 'e', 'r',
    };
    try append_frame(
        &late_headers_frame,
        &late_headers_length,
        .headers,
        0x5,
        3,
        &late_headers,
    );
    try session.receive(late_headers_frame[0..late_headers_length], state.callbacks());
    try std.testing.expectEqual(@as(usize, 2), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(
            state.output[0..state.output_length],
            3,
            .refused_stream,
        ),
    );

    var follow_up: [64]u8 = undefined;
    var follow_up_length: usize = 0;
    const cancel = [_]u8{ 0, 0, 0, 8 };
    try append_frame(&follow_up, &follow_up_length, .rst_stream, 0, 1, &cancel);
    const indexed_headers = [_]u8{ 0x82, 0x86, 0x84, 0xbf };
    try append_frame(&follow_up, &follow_up_length, .headers, 0x5, 5, &indexed_headers);
    try session.receive(follow_up[0..follow_up_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 2), state.dispatch_count);
    try std.testing.expect(state.saw_dynamic_header);
}

test "http2 server: fragmented refused headers reset only after completion" {
    var fixture: SingleFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = RefusalState{};

    const active_headers = [_]u8{ 0x82, 0x86, 0x84 };
    const refused_headers = [_]u8{
        0x82, 0x86, 0x84, 0x40, 0x06,
        'x',  '-',  't',  'e',  's',
        't',  0x05, 'v',  'a',  'l',
        'u',  'e',
    };
    const split = 8;
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &active_headers);
    try append_frame(
        &input,
        &input_length,
        .headers,
        0x1,
        3,
        refused_headers[0..split],
    );
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 0), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 0),
        try reset_count(
            state.output[0..state.output_length],
            3,
            .refused_stream,
        ),
    );

    var continuation: [64]u8 = undefined;
    var continuation_length: usize = 0;
    try append_frame(
        &continuation,
        &continuation_length,
        .continuation,
        0x4,
        3,
        refused_headers[split..],
    );
    try session.receive(continuation[0..continuation_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(
            state.output[0..state.output_length],
            3,
            .refused_stream,
        ),
    );
}

test "http2 server: skipped lower stream id is a connection error" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = RefusalState{};

    const active_headers = [_]u8{ 0x82, 0x86, 0x84 };
    const skipped_headers = [_]u8{
        0x40, 0x06, 'x', '-', 't', 'e', 's', 't',
        0x05, 'v',  'a', 'l', 'u', 'e',
    };
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 3, &active_headers);
    try append_frame(&input, &input_length, .headers, 0x5, 1, &skipped_headers);
    try session.receive(input[0..input_length], state.callbacks());

    // h2spec 5.1.1: stream 1 was skipped by opening 3, so HEADERS on it is an
    // unexpected stream identifier; the connection fails before decoding.
    try std.testing.expect(session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqual(
        @as(?u32, @intFromEnum(http2_server.ErrorCode.protocol_error)),
        try goaway_code(state.output[0..state.output_length]),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try reset_count(state.output[0..state.output_length], 1, .stream_closed),
    );
}

test "http2 server: previously opened closed stream resets without dropping HPACK state" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = RefusalState{};

    const active_headers = [_]u8{ 0x82, 0x86, 0x84 };
    const repeated_headers = [_]u8{
        0x40, 0x06, 'x', '-', 't', 'e', 's', 't',
        0x05, 'v',  'a', 'l', 'u', 'e',
    };
    var input: [160]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 3, &active_headers);
    const cancel = [_]u8{ 0, 0, 0, 8 };
    try append_frame(&input, &input_length, .rst_stream, 0, 3, &cancel);
    try append_frame(&input, &input_length, .headers, 0x5, 3, &repeated_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqual(@as(usize, 1), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 3, .stream_closed),
    );
}

test "http2 server: half-closed fragmented headers reset after completion" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = RefusalState{};

    const active_headers = [_]u8{ 0x82, 0x86, 0x84 };
    const closed_headers = [_]u8{
        0x40, 0x06, 'x', '-', 't', 'e', 's', 't',
        0x05, 'v',  'a', 'l', 'u', 'e',
    };
    const split = 7;
    var input: [112]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &active_headers);
    try append_frame(
        &input,
        &input_length,
        .headers,
        0,
        1,
        closed_headers[0..split],
    );
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 0), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 0),
        try reset_count(state.output[0..state.output_length], 1, .stream_closed),
    );

    var continuation: [64]u8 = undefined;
    var continuation_length: usize = 0;
    try append_frame(
        &continuation,
        &continuation_length,
        .continuation,
        0x4,
        1,
        closed_headers[split..],
    );
    try session.receive(continuation[0..continuation_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), session.dynamic_table.?.count());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 1, .stream_closed),
    );
}

test "http2 server: duplicate Host and authority mismatch are stream errors" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();

    const duplicate_host = [_]u8{
        0x82, 0x86, 0x84,
        0x00, 0x04, 'h',
        'o',  's',  't',
        0x0b, 'e',  'x',
        'a',  'm',  'p',
        'l',  'e',  '.',
        'c',  'o',  'm',
        0x00, 0x04, 'h',
        'o',  's',  't',
        0x0b, 'e',  'x',
        'a',  'm',  'p',
        'l',  'e',  '.',
        'c',  'o',  'm',
    };
    const mismatched = [_]u8{
        0x82, 0x86, 0x01, 0x0b,
        'e',  'x',  'a',  'm',
        'p',  'l',  'e',  '.',
        'c',  'o',  'm',  0x84,
        0x00, 0x04, 'h',  'o',
        's',  't',  0x0b, 'e',
        'x',  'a',  'm',  'p',
        'l',  'e',  '.',  'n',
        'e',  't',
    };
    var input: [192]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &duplicate_host);
    try append_frame(&input, &input_length, .headers, 0x5, 3, &mismatched);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 0), state.dispatch_count);
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 1, .protocol_error),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 3, .protocol_error),
    );
}

test "http2 server: regular CONNECT receives an ordinary 501 response" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();

    const connect_headers = [_]u8{
        0x02, 0x07, 'C', 'O', 'N', 'N', 'E', 'C', 'T',
        0x01, 0x0b, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        '.',  'c',  'o', 'm',
    };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &connect_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 0), state.dispatch_count);
    try std.testing.expectEqual(
        @as(usize, 0),
        try frame_count(state.output[0..state.output_length], .rst_stream, 1),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(state.output[0..state.output_length], .headers, 1),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output[0..state.output_length],
        "CONNECT is not supported",
    ) != null);
}

test "http2 server: rejected CONNECT trailers never dispatch a stale stream" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();

    const connect_headers = [_]u8{
        0x02, 0x07, 'C', 'O', 'N', 'N', 'E', 'C', 'T',
        0x01, 0x0b, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        '.',  'c',  'o', 'm',
    };
    // Valid trailer fields, but no initial request was ever dispatched.
    const trailer = [_]u8{
        0x40, 0x06, 'x', '-', 't', 'e', 's', 't', 0x05, 'v', 'a', 'l', 'u', 'e',
    };
    var input: [160]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &connect_headers);
    try append_frame(&input, &input_length, .headers, 0x5, 1, &trailer);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 0), state.dispatch_count);
    // The stale-slot path must never emit RST_STREAM on stream 0.
    try std.testing.expectEqual(
        @as(usize, 0),
        try frame_count(state.output[0..state.output_length], .rst_stream, 0),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(state.output[0..state.output_length], .rst_stream, 1),
    );
    try std.testing.expect(session.connection.streams.find(1) == null);
}

test "http2 server: 205 responses reject a body" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = RefusalState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectError(
        error.BodyNotAllowed,
        session.send_response(
            1,
            "205 Reset Content",
            "",
            "forbidden",
            state.callbacks(),
        ),
    );
    try session.send_response(1, "205 Reset Content", "", "", state.callbacks());
}

test "http2 server: pending body resumes through partial stream credit" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = FlowState{};

    const zero_window = [_]u8{ 0x00, 0x04, 0, 0, 0, 0 };
    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, &zero_window);
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());
    try session.send_response(1, "200 OK", "", "abcdef", state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    try std.testing.expect(session.pending_response_active[index]);
    try std.testing.expectEqual(@as(usize, 0), session.pending_body_offsets[index]);
    try std.testing.expectEqual(
        @as(usize, 0),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    var update: [32]u8 = undefined;
    var update_length: usize = 0;
    try append_frame(&update, &update_length, .window_update, 0, 1, &.{ 0, 0, 0, 2 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expectEqual(@as(usize, 2), session.pending_body_offsets[index]);
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    update_length = 0;
    try append_frame(&update, &update_length, .window_update, 0, 1, &.{ 0, 0, 0, 4 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(
        @as(usize, 2),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );
}

test "http2 server: connection and stream response credit are independent" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());
    session.connection.connection_send_window = 0;
    try session.send_response(1, "200 OK", "", "abc", state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    var update: [32]u8 = undefined;
    var update_length: usize = 0;
    try append_frame(&update, &update_length, .window_update, 0, 1, &.{ 0, 0, 0, 5 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expectEqual(@as(usize, 0), session.pending_body_offsets[index]);

    update_length = 0;
    try append_frame(&update, &update_length, .window_update, 0, 0, &.{ 0, 0, 0, 2 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expectEqual(@as(usize, 2), session.pending_body_offsets[index]);

    update_length = 0;
    try append_frame(&update, &update_length, .window_update, 0, 0, &.{ 0, 0, 0, 1 });
    try session.receive(update[0..update_length], state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
}

test "http2 server: stream capacity refuses the next stream without GOAWAY" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = RefusalState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [160]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    for ([_]u32{ 1, 3, 5, 7 }) |stream_id| {
        try append_frame(&input, &input_length, .headers, 0x5, stream_id, &request_headers);
    }
    try session.receive(input[0..input_length], state.callbacks());
    try std.testing.expectEqual(@as(usize, 4), session.connection.streams.active_count);

    input_length = 0;
    try append_frame(&input, &input_length, .headers, 0x5, 9, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    // Capacity exhaustion is stream-scoped: the fifth stream is refused while
    // the connection and its four live streams remain usable.
    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 9, .refused_stream),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        try goaway_code(state.output[0..state.output_length]),
    );
}

test "http2 server: connection credit stacks above per-stream allowances" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try append_frame(&input, &input_length, .headers, 0x5, 3, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    const first = session.connection.streams.find(1) orelse return error.MissingStream;
    const second = session.connection.streams.find(3) orelse return error.MissingStream;
    session.connection.connection_send_window = 0;
    try session.send_response(1, "200 OK", "", "abc", state.callbacks());
    try session.send_response(3, "200 OK", "", "def", state.callbacks());
    try std.testing.expect(session.pending_response_active[first]);
    try std.testing.expect(session.pending_response_active[second]);

    var update: [32]u8 = undefined;
    var update_length: usize = 0;
    try append_frame(&update, &update_length, .window_update, 0, 0, &.{ 0, 0, 0, 3 });
    try session.receive(update[0..update_length], state.callbacks());

    var first_bytes: [16]u8 = undefined;
    var second_bytes: [16]u8 = undefined;
    const first_frames = try collect_data_frames(
        state.output[0..state.output_length],
        1,
        &first_bytes,
    );
    const second_frames = try collect_data_frames(
        state.output[0..state.output_length],
        3,
        &second_bytes,
    );
    try std.testing.expectEqual(@as(usize, 3), first_frames.bytes_length);
    try std.testing.expectEqual(@as(usize, 0), second_frames.bytes_length);

    update_length = 0;
    try append_frame(&update, &update_length, .window_update, 0, 0, &.{ 0, 0, 0, 3 });
    try session.receive(update[0..update_length], state.callbacks());
    const second_resumed = try collect_data_frames(
        state.output[0..state.output_length],
        3,
        &second_bytes,
    );
    try std.testing.expectEqual(@as(usize, 3), second_resumed.bytes_length);
}

test "http2 server: per-stream credit does not consume another stream's allowance" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try append_frame(&input, &input_length, .headers, 0x5, 3, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    const first = session.connection.streams.find(1) orelse return error.MissingStream;
    session.connection.streams.send_windows[first] = 0;
    try session.send_response(1, "200 OK", "", "abc", state.callbacks());
    try session.send_response(3, "200 OK", "", "def", state.callbacks());
    try std.testing.expect(session.pending_response_active[first]);

    var first_bytes: [16]u8 = undefined;
    var second_bytes: [16]u8 = undefined;
    const blocked = try collect_data_frames(
        state.output[0..state.output_length],
        1,
        &first_bytes,
    );
    const open = try collect_data_frames(
        state.output[0..state.output_length],
        3,
        &second_bytes,
    );
    try std.testing.expectEqual(@as(usize, 0), blocked.bytes_length);
    try std.testing.expectEqual(@as(usize, 3), open.bytes_length);

    var update: [32]u8 = undefined;
    var update_length: usize = 0;
    try append_frame(&update, &update_length, .window_update, 0, 1, &.{ 0, 0, 0, 3 });
    try session.receive(update[0..update_length], state.callbacks());
    const resumed = try collect_data_frames(
        state.output[0..state.output_length],
        1,
        &first_bytes,
    );
    try std.testing.expectEqual(@as(usize, 3), resumed.bytes_length);
}

test "http2 server: blocked and failed DATA writes retain offsets and credit" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    const connection_window = session.connection.connection_send_window;
    const stream_window = session.connection.streams.send_windows[index];
    state.behavior = .block_data;
    try session.send_response(1, "200 OK", "", "blocked", state.callbacks());
    try std.testing.expectEqual(@as(usize, 0), session.pending_body_offsets[index]);
    try std.testing.expectEqual(connection_window, session.connection.connection_send_window);
    try std.testing.expectEqual(stream_window, session.connection.streams.send_windows[index]);
    try std.testing.expectEqual(
        @as(usize, 0),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    state.behavior = .accept;
    try session.flush_pending(state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    var failed_fixture: SessionFixture = .{};
    try failed_fixture.init();
    var failed_session = failed_fixture.session;
    var failed_state = FlowState{};
    try failed_session.receive(input[0..input_length], failed_state.callbacks());
    const failed_index = failed_session.connection.streams.find(1) orelse
        return error.MissingStream;
    const failed_connection_window = failed_session.connection.connection_send_window;
    const failed_stream_window = failed_session.connection.streams.send_windows[failed_index];
    failed_state.behavior = .fail_data;
    try std.testing.expectError(
        error.TestWriteFailure,
        failed_session.send_response(
            1,
            "200 OK",
            "",
            "failed",
            failed_state.callbacks(),
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        failed_session.pending_body_offsets[failed_index],
    );
    try std.testing.expectEqual(
        failed_connection_window,
        failed_session.connection.connection_send_window,
    );
    try std.testing.expectEqual(
        failed_stream_window,
        failed_session.connection.streams.send_windows[failed_index],
    );

    failed_state.behavior = .accept;
    try failed_session.flush_pending(failed_state.callbacks());
    try std.testing.expect(failed_session.connection.streams.find(1) == null);
}

test "http2 server: small transport queues make bounded DATA progress" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    var body: [100]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    state.output_length = 0;
    state.write_capacity = 64;
    state.max_frame_payload = 55;
    state.drain();
    try session.send_response(1, "200 OK", "", &body, state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    try std.testing.expect(session.pending_response_active[index]);
    try std.testing.expectEqual(@as(usize, 0), session.pending_body_offsets[index]);

    state.drain();
    try session.flush_pending(state.callbacks());
    try std.testing.expectEqual(@as(usize, 55), session.pending_body_offsets[index]);

    state.drain();
    try session.flush_pending(state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(
        http2.default_window_size - body.len,
        session.connection.connection_send_window,
    );

    var received: [body.len]u8 = undefined;
    const frames = try collect_data_frames(
        state.output[0..state.output_length],
        1,
        &received,
    );
    try std.testing.expectEqual(@as(usize, 2), frames.count);
    try std.testing.expectEqual(body.len, frames.bytes_length);
    try std.testing.expectEqual(@as(usize, 1), frames.end_stream_count);
    try std.testing.expect(frames.final_end_stream);
    try std.testing.expectEqualSlices(u8, &body, &received);
}

test "http2 server: oversized response HEADERS fail before state commit" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    state.output_length = 0;
    state.max_frame_payload = 0;
    try std.testing.expectError(
        error.ResponseHeadersTooLarge,
        session.begin_response(1, "200 OK", "", state.callbacks()),
    );
    try std.testing.expect(!session.response_started[index]);
    try std.testing.expect(!session.pending_response_active[index]);
    try std.testing.expectEqual(@as(usize, 0), state.output_length);

    state.max_frame_payload = http2.maximum_frame_size;
    try session.send_response(1, "200 OK", "", "", state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(state.output[0..state.output_length], .headers, 1),
    );
}

test "http2 server: streaming DATA retry precedes END_STREAM" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = FlowState{};

    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());
    try session.begin_response(1, "200 OK", "", state.callbacks());

    const index = session.connection.streams.find(1) orelse return error.MissingStream;
    const connection_window = session.connection.connection_send_window;
    const stream_window = session.connection.streams.send_windows[index];
    state.output_length = 0;
    state.data_write_attempts = 0;
    session.connection.peer_settings.max_frame_size = 4;
    try std.testing.expectError(
        error.ResponseDataTooLarge,
        session.write_response_data(1, "abcdef", state.callbacks()),
    );
    try std.testing.expect(session.stream_write_retry_required[index]);
    try std.testing.expectEqual(@as(usize, 0), state.data_write_attempts);
    try std.testing.expectEqual(connection_window, session.connection.connection_send_window);
    try std.testing.expectEqual(stream_window, session.connection.streams.send_windows[index]);
    try std.testing.expectError(
        error.ResponseWritePending,
        session.finish_response(1, state.callbacks()),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try frame_count(state.output[0..state.output_length], .data, 1),
    );

    session.connection.peer_settings.max_frame_size = http2.default_max_frame_size;
    try session.write_response_data(1, "abcdef", state.callbacks());
    state.behavior = .block_data;
    try session.finish_response(1, state.callbacks());
    try std.testing.expect(session.pending_stream_end[index]);
    try std.testing.expect(session.connection.streams.find(1) != null);

    state.behavior = .accept;
    try session.flush_pending(state.callbacks());
    try std.testing.expect(session.connection.streams.find(1) == null);

    var received: [6]u8 = undefined;
    const frames = try collect_data_frames(
        state.output[0..state.output_length],
        1,
        &received,
    );
    try std.testing.expectEqual(@as(usize, 2), frames.count);
    try std.testing.expectEqual(@as(usize, 6), frames.bytes_length);
    try std.testing.expectEqual(@as(usize, 1), frames.end_stream_count);
    try std.testing.expect(frames.final_end_stream);
    try std.testing.expectEqualStrings("abcdef", &received);
}

test "http2 server: first peer frame must be non-ack settings" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();
    var input: [64]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .ping, 0, 0, "12345678");
    try session.receive(input[0..input_length], state.callbacks());
    try std.testing.expect(session.is_closed());

    const settings = try http2.FrameHeader.parse(state.output[0..9]);
    try std.testing.expectEqual(@intFromEnum(http2.FrameType.settings), settings.frame_type);
    var setting_offset: usize = 9;
    var found_connect_protocol = false;
    while (setting_offset < 9 + settings.payload_length) : (setting_offset += 6) {
        const id = std.mem.readInt(u16, state.output[setting_offset..][0..2], .big);
        if (id == 0x8) {
            found_connect_protocol = true;
            try std.testing.expectEqual(
                @as(u32, 1),
                std.mem.readInt(u32, state.output[setting_offset + 2 ..][0..4], .big),
            );
        }
    }
    try std.testing.expect(found_connect_protocol);
    const goaway_offset = 9 + settings.payload_length;
    const goaway = try http2.FrameHeader.parse(state.output[goaway_offset..][0..9]);
    try std.testing.expectEqual(@intFromEnum(http2.FrameType.goaway), goaway.frame_type);
    const code_offset = goaway_offset + 9 + 4;
    try std.testing.expectEqual(
        @intFromEnum(http2_server.ErrorCode.protocol_error),
        std.mem.readInt(u32, state.output[code_offset..][0..4], .big),
    );
}

test "http2 server: deferred response token retains one stream only" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();
    try state.router.route_async_context(.get, "/async", &state, async_route_handler);

    const headers = [_]u8{
        0x82, 0x86, 0x04, 0x06, '/', 'a', 's', 'y', 'n', 'c',
    };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &headers);
    try session.receive(input[0..input_length], state.callbacks());

    const token = state.pending_response orelse return error.MissingAsyncToken;
    try std.testing.expect(token.is_pending());
    try std.testing.expect(session.connection.streams.find(1) != null);
    try std.testing.expectError(
        error.InvalidHeaders,
        session.send_response(
            1,
            "200 OK",
            "Content-Length: 9\r\n",
            "later",
            state.callbacks(),
        ),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        session.send_response(
            1,
            "200 OK",
            "Content-Length: 5\r\nContent-Length: 5\r\n",
            "later",
            state.callbacks(),
        ),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        session.send_response(
            1,
            "200 OK",
            "Connection: close\r\n",
            "",
            state.callbacks(),
        ),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        token.complete_with_headers("200 OK", "Content-Length: 5\r\n", "later"),
    );
    try std.testing.expect(token.is_pending());
    try std.testing.expect(session.connection.streams.find(1) != null);
    try std.testing.expectEqual(@as(usize, 0), state.wake_count);
    try token.complete("200 OK", "later");
    try std.testing.expect(session.connection.streams.find(1) == null);
    try std.testing.expectEqual(@as(usize, 1), state.wake_count);
    try std.testing.expectError(
        error.AsyncResponseAlreadyCompleted,
        token.complete("200 OK", "again"),
    );
}

test "http2 server: peer reset expires a retained async response" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();
    try state.router.route_async_context(.get, "/async", &state, async_route_handler);

    const headers = [_]u8{
        0x82, 0x86, 0x04, 0x06, '/', 'a', 's', 'y', 'n', 'c',
    };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &headers);
    try session.receive(input[0..input_length], state.callbacks());
    const token = state.pending_response orelse return error.MissingAsyncToken;

    var reset: [16]u8 = undefined;
    var reset_length: usize = 0;
    const cancel = [_]u8{ 0, 0, 0, 8 };
    try append_frame(&reset, &reset_length, .rst_stream, 0, 1, &cancel);
    try session.receive(reset[0..reset_length], state.callbacks());
    try std.testing.expectError(
        error.AsyncResponseExpired,
        token.complete("200 OK", "too late"),
    );
}

test "http2 server: content length is unique numeric and exact" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();

    const length_five = [_]u8{ 0x82, 0x86, 0x84, 0x0f, 0x0d, 0x01, '5' };
    const duplicate = [_]u8{
        0x82, 0x86, 0x84,
        0x0f, 0x0d, 0x01,
        '0',  0x0f, 0x0d,
        0x01, '0',
    };
    const non_numeric = [_]u8{ 0x82, 0x86, 0x84, 0x0f, 0x0d, 0x01, 'x' };
    var input: [192]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &length_five);
    try append_frame(&input, &input_length, .data, 0x1, 1, "four");
    try append_frame(&input, &input_length, .headers, 0x5, 3, &duplicate);
    try append_frame(&input, &input_length, .headers, 0x5, 5, &non_numeric);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 0), state.dispatch_count);
    var output_offset: usize = 0;
    var reset_frame_count: usize = 0;
    while (output_offset < state.output_length) {
        const header = try http2.FrameHeader.parse(state.output[output_offset..][0..9]);
        if (header.frame_type == @intFromEnum(http2.FrameType.rst_stream)) {
            reset_frame_count += 1;
        }
        output_offset += 9 + header.payload_length;
    }
    try std.testing.expectEqual(@as(usize, 3), reset_frame_count);
}

test "http2 server: configured body limit rejects oversized content length" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    session.request_body_limit = 4;
    var state = TestState{ .session = &session };
    state.init_router();

    const length_five = [_]u8{ 0x82, 0x86, 0x84, 0x0f, 0x0d, 0x01, '5' };
    var input: [96]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &length_five);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 0), state.dispatch_count);
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 1, .enhance_your_calm),
    );
}

test "http2 server: configured body limit bounds streaming bodies" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    session.request_body_limit = 3;
    var state = TestState{ .session = &session };
    state.init_router();

    const headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &headers);
    try append_frame(&input, &input_length, .data, 0x0, 1, "ab");
    try append_frame(&input, &input_length, .data, 0x1, 1, "cd");
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 0), state.dispatch_count);
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 1, .enhance_your_calm),
    );
}

test "http2 server: extended CONNECT with :protocol websocket dispatches to handler" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();
    try state.router.route_context(.connect, "/ws", &state, route_handler);

    const connect_ws_headers = [_]u8{
        0x02, 0x07, 'C',  'O',  'N', 'N',  'E',  'C', 'T',
        0x87, 0x01, 0x0b, 'e',  'x', 'a',  'm',  'p', 'l',
        'e',  '.',  'c',  'o',  'm', 0x04, 0x03, '/', 'w',
        's',  0x00, 0x09, ':',  'p', 'r',  'o',  't', 'o',
        'c',  'o',  'l',  0x09, 'w', 'e',  'b',  's', 'o',
        'c',  'k',  'e',  't',
    };

    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &connect_ws_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqualStrings("websocket", session.requests[0].protocol);
    try std.testing.expectEqualStrings("/ws", session.requests[0].path);
    try std.testing.expectEqualStrings("CONNECT", session.requests[0].method);
}

test "http2 server: TRACE reaches the registered handler" {
    const Capture = struct {
        method: [8]u8 = undefined,
        method_len: usize = 0,
        path: [32]u8 = undefined,
        path_len: usize = 0,

        fn handle(context: *anyopaque, request: *Request, response: *Response) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.method_len = @min(request.method.len, self.method.len);
            @memcpy(self.method[0..self.method_len], request.method[0..self.method_len]);
            self.path_len = @min(request.path.len, self.path.len);
            @memcpy(self.path[0..self.path_len], request.path[0..self.path_len]);
            response.end("200 OK", "ok") catch {};
        }
    };

    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = TestState{ .session = &session };
    state.init_router();
    var capture = Capture{};
    try state.router.route_context(.trace, "/probe", &capture, Capture.handle);

    var block: [160]u8 = undefined;
    var block_length: usize = 0;
    block_length = try append_hpack_literal(&block, block_length, ":method", "TRACE");
    block_length = try append_hpack_literal(&block, block_length, ":scheme", "https");
    block_length = try append_hpack_literal(&block, block_length, ":path", "/probe");
    block_length = try append_hpack_literal(&block, block_length, ":authority", "example.com");

    var input: [256]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, block[0..block_length]);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqualStrings("TRACE", capture.method[0..capture.method_len]);
    try std.testing.expectEqualStrings("/probe", capture.path[0..capture.path_len]);
}

test "http2 server: extended CONNECT data requires an accepted tunnel" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = RefusalState{};

    const connect_ws_headers = [_]u8{
        0x02, 0x07, 'C',  'O',  'N', 'N',  'E',  'C', 'T',
        0x87, 0x01, 0x0b, 'e',  'x', 'a',  'm',  'p', 'l',
        'e',  '.',  'c',  'o',  'm', 0x04, 0x03, '/', 'w',
        's',  0x00, 0x09, ':',  'p', 'r',  'o',  't', 'o',
        'c',  'o',  'l',  0x09, 'w', 'e',  'b',  's', 'o',
        'c',  'k',  'e',  't',
    };

    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, 1, &connect_ws_headers);
    try session.receive(input[0..input_length], state.callbacks());

    var data_frame: [16]u8 = undefined;
    var data_length: usize = 0;
    try append_frame(&data_frame, &data_length, .data, 0, 1, "frame");
    try session.receive(data_frame[0..data_length], state.callbacks());

    var output_offset: usize = 0;
    var reset_seen = false;
    while (output_offset < state.output_length) {
        const header = try http2.FrameHeader.parse(state.output[output_offset..][0..9]);
        if (header.frame_type == @intFromEnum(http2.FrameType.rst_stream)) {
            reset_seen = true;
        }
        output_offset += 9 + header.payload_length;
    }
    try std.testing.expect(reset_seen);
}

test "tls: ALPN prefers h2 and falls back to http 1.1" {
    try std.testing.expectEqual(
        support.tls.ApplicationProtocol.http2,
        support.tls.select_http_protocol("\x08http/1.1\x02h2").?,
    );
    try std.testing.expectEqual(
        support.tls.ApplicationProtocol.http1,
        support.tls.select_http_protocol("\x08http/1.1").?,
    );
    try std.testing.expect(support.tls.select_http_protocol("\x03h2") == null);
}

/// Drain-driven producer whose chunk schedule is controlled by the test.
const StreamProducerState = struct {
    chunk: [8192]u8 = undefined,
    chunk_length: usize = 64,
    remaining_chunks: usize = 0,
    pending_once: bool = false,
    stall: bool = false,
    fail_immediately: bool = false,
    calls: usize = 0,
    would_block_count: usize = 0,
    saw_non_would_block: bool = false,
    begin_error: ?anyerror = null,

    fn produce(
        context: *anyopaque,
        response: *Response,
    ) anyerror!support.http_response.StreamStatus {
        const self: *StreamProducerState = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.fail_immediately) return error.ProducerFailure;
        if (self.stall) return .pending;
        if (self.pending_once) {
            self.pending_once = false;
            self.write_next(response) catch |err| return self.on_backpressure(err);
            return .pending;
        }
        while (self.remaining_chunks != 0) {
            self.write_next(response) catch |err| return self.on_backpressure(err);
        }
        response.end_chunks() catch |err| return self.on_backpressure(err);
        return .done;
    }

    /// Records why the producer parked; only `WouldBlock` is recoverable.
    fn on_backpressure(
        self: *StreamProducerState,
        err: anyerror,
    ) anyerror!support.http_response.StreamStatus {
        if (err == error.WouldBlock) {
            self.would_block_count += 1;
            return .pending;
        }
        self.saw_non_would_block = true;
        return err;
    }

    fn write_next(self: *StreamProducerState, response: *Response) !void {
        @memset(&self.chunk, 'a');
        try response.write_chunk(self.chunk[0..self.chunk_length]);
        self.remaining_chunks -= 1;
    }
};

fn stream_route_handler(context: *anyopaque, _: *Request, response: *Response) void {
    const producer: *StreamProducerState = @ptrCast(@alignCast(context));
    response.begin_stream("200 OK", "", producer, StreamProducerState.produce) catch |err| {
        producer.begin_error = err;
    };
}

/// Connection with no live socket whose write ring is the only output sink.
fn producer_connection(ring: []u8, router: *const radix.Router) support.tcp.TcpConnection {
    return .{
        .socket = undefined,
        .router = router,
        .write_queue = ring,
        .is_writing = true,
    };
}

fn producer_request_headers() [11]u8 {
    return .{ 0x82, 0x86, 0x04, 0x07, '/', 's', 't', 'r', 'e', 'a', 'm' };
}

test "http2: producer that fits the write ring completes synchronously" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{ .remaining_chunks = 1 };
    try router.route_context(.get, "/stream", &producer, stream_route_handler);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    try std.testing.expectEqual(@as(?anyerror, null), producer.begin_error);
    try std.testing.expectEqual(@as(usize, 1), producer.calls);
    try std.testing.expectEqual(@as(usize, 0), producer.remaining_chunks);
    try std.testing.expect(conn.h2.connection.streams.find(1) == null);

    var body: [128]u8 = undefined;
    const frames = try collect_data_frames(ring[0..conn.write_len], 1, &body);
    try std.testing.expectEqual(@as(usize, 64), frames.bytes_length);
    try std.testing.expectEqual(@as(usize, 1), frames.end_stream_count);
    try std.testing.expect(frames.final_end_stream);
}

test "http2: begin_stream fails closed without an arm callback" {
    var context: u8 = 0;
    var response = Response{ .target = .{ .http2 = .{
        .context = &context,
        .router = &context,
        .stream_id = 1,
        .end_fn = undefined,
        .begin_fn = undefined,
        .write_fn = undefined,
        .finish_fn = undefined,
    } } };
    try std.testing.expectError(
        error.ProducerStreamingUnsupported,
        response.begin_stream("200 OK", "", &context, undefined),
    );
    try std.testing.expect(!response.is_started());
}

test "http2: producer resumes when the write ring drains" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{ .remaining_chunks = 32 };
    try router.route_context(.get, "/stream", &producer, stream_route_handler);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    try std.testing.expectEqual(@as(?anyerror, null), producer.begin_error);
    try std.testing.expect(producer.remaining_chunks != 0);
    try std.testing.expect(conn.h2_stream_producers[0] != null);

    var first_body: [2048]u8 = undefined;
    const first = try collect_data_frames(ring[0..conn.write_len], 1, &first_body);
    try std.testing.expectEqual(@as(usize, 0), first.end_stream_count);

    var total_body: usize = first.bytes_length;
    var iterations: usize = 0;
    while (conn.h2_stream_producers[0] != null and iterations < 64) : (iterations += 1) {
        conn.write_len = 0;
        conn.write_head = 0;
        conn.pump_http2_streams();
        var drained_body: [2048]u8 = undefined;
        const drained = try collect_data_frames(ring[0..conn.write_len], 1, &drained_body);
        total_body += drained.bytes_length;
    }

    try std.testing.expectEqual(@as(usize, 32 * 64), total_body);
    try std.testing.expectEqual(@as(usize, 0), producer.remaining_chunks);
    try std.testing.expect(conn.h2_stream_producers[0] == null);
    try std.testing.expect(conn.h2.connection.streams.find(1) == null);
}

test "http2: producer failure resets the stream and clears the slot" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{ .fail_immediately = true };
    try router.route_context(.get, "/stream", &producer, stream_route_handler);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    try std.testing.expectEqual(@as(?anyerror, null), producer.begin_error);
    try std.testing.expectEqual(@as(usize, 1), producer.calls);
    try std.testing.expect(conn.h2_stream_producers[0] == null);
    try std.testing.expect(!conn.closing);
    try std.testing.expect(conn.h2.connection.streams.find(1) == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(ring[0..conn.write_len], 1, .internal_error),
    );
}

test "http2: pending producer keeps the dispatch from force-ending" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{ .remaining_chunks = 2, .pending_once = true };
    try router.route_context(.get, "/stream", &producer, stream_route_handler);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    try std.testing.expectEqual(@as(?anyerror, null), producer.begin_error);
    try std.testing.expect(conn.h2_stream_producers[0] != null);
    try std.testing.expectEqual(@as(usize, 1), producer.remaining_chunks);

    var first_body: [128]u8 = undefined;
    const first = try collect_data_frames(ring[0..conn.write_len], 1, &first_body);
    try std.testing.expectEqual(@as(usize, 64), first.bytes_length);
    try std.testing.expectEqual(@as(usize, 0), first.end_stream_count);
    try std.testing.expectEqual(
        @as(usize, 1),
        try frame_count(ring[0..conn.write_len], .data, 1),
    );

    conn.write_len = 0;
    conn.write_head = 0;
    conn.pump_http2_streams();

    try std.testing.expect(conn.h2_stream_producers[0] == null);
    try std.testing.expect(conn.h2.connection.streams.find(1) == null);
    var drained_body: [128]u8 = undefined;
    const drained = try collect_data_frames(ring[0..conn.write_len], 1, &drained_body);
    try std.testing.expectEqual(@as(usize, 64), drained.bytes_length);
    try std.testing.expectEqual(@as(usize, 1), drained.end_stream_count);
    try std.testing.expect(drained.final_end_stream);
}

test "http2: reset_protocol clears armed producer slots" {
    var conn = support.tcp.TcpConnection{ .socket = undefined };
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());
    conn.h2_stream_producers[0] = StreamProducerState.produce;
    conn.h2_stream_producer_close[0] = true;

    try conn.reset_protocol();

    try std.testing.expect(conn.h2_stream_producers[0] == null);
    try std.testing.expect(!conn.h2_stream_producer_close[0]);
}

/// Development-log sink bound to a temporary file for HTTP/2 log tests.
const HttpResponseLog = struct {
    tmp: std.testing.TmpDir,
    sink: support.dev_log.Sink = .{},
    file: std.Io.File,

    fn init(self: *HttpResponseLog) !void {
        self.sink = .{};
        self.tmp = std.testing.tmpDir(.{});
        self.file = try self.tmp.dir.createFile(std.testing.io, "dev_log.txt", .{});
        self.sink.enable(std.testing.io, self.file);
    }

    fn read(self: *HttpResponseLog) ![]u8 {
        return self.tmp.dir.readFileAlloc(
            std.testing.io,
            "dev_log.txt",
            std.testing.allocator,
            .limited(support.dev_log.capacity),
        );
    }

    fn deinit(self: *HttpResponseLog) void {
        self.file.close(std.testing.io);
        self.tmp.cleanup();
    }
};

fn sync_log_handler(_: *Request, response: *Response) void {
    response.end("200 OK", "hello") catch @panic("test fixture response failed");
}

/// Asserts exactly one rendered request line naming `method` and `path`.
fn expect_single_request_line(contents: []const u8, method: []const u8, path: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, contents, "\n"));
    var expected_buffer: [support.dev_log.max_line_bytes]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &expected_buffer,
        "{s}[{s}]{s} {s} : ",
        .{ support.dev_log.Ansi.cyan, method, support.dev_log.Ansi.reset, path },
    );
    try std.testing.expect(std.mem.find(u8, contents, prefix) != null);
}

test "http2: completed exchange emits one request record and counter" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.get("/stream", sync_log_handler);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    conn.io = std.testing.io;
    var capture: HttpResponseLog = undefined;
    try capture.init();
    defer capture.deinit();
    conn.dev_log = &capture.sink;
    var registry = support.metrics.Registry{};
    conn.metrics = &registry;
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    try std.testing.expectEqual(@as(u64, 1), registry.get(.http_requests));
    const contents = try capture.read();
    defer std.testing.allocator.free(contents);
    try expect_single_request_line(contents, "GET", "/stream");
    try std.testing.expect(std.mem.find(u8, contents, "200" ++ support.dev_log.Ansi.reset) != null);

    // Frames after the exchange completes must not add records or counters.
    input_length = 0;
    try append_frame(&input, &input_length, .ping, 0, 0, "12345678");
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());
    try std.testing.expectEqual(@as(u64, 1), registry.get(.http_requests));
    const after = try capture.read();
    defer std.testing.allocator.free(after);
    try expect_single_request_line(after, "GET", "/stream");
}

/// Deferred route context that retains the token for explicit completion.
const AsyncLogState = struct {
    pending: ?support.http_response.AsyncResponse = null,

    fn handle(context: *anyopaque, _: *Request, response: support.http_response.AsyncResponse) void {
        const self: *AsyncLogState = @ptrCast(@alignCast(context));
        self.pending = response;
    }
};

test "http2: async completion emits one request record" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var state = AsyncLogState{};
    try router.route_async_context(.get, "/stream", &state, AsyncLogState.handle);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    conn.io = std.testing.io;
    var capture: HttpResponseLog = undefined;
    try capture.init();
    defer capture.deinit();
    conn.dev_log = &capture.sink;
    var registry = support.metrics.Registry{};
    conn.metrics = &registry;
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    try std.testing.expectEqual(@as(u64, 1), registry.get(.http_requests));
    const before = try capture.read();
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(usize, 0), before.len);

    try state.pending.?.complete("200 OK", "async body");

    const after = try capture.read();
    defer std.testing.allocator.free(after);
    try expect_single_request_line(after, "GET", "/stream");
    try std.testing.expect(std.mem.find(u8, after, "200" ++ support.dev_log.Ansi.reset) != null);
}

test "http2: producer completion emits one request record" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{ .remaining_chunks = 1 };
    try router.route_context(.get, "/stream", &producer, stream_route_handler);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    conn.io = std.testing.io;
    var capture: HttpResponseLog = undefined;
    try capture.init();
    defer capture.deinit();
    conn.dev_log = &capture.sink;
    var registry = support.metrics.Registry{};
    conn.metrics = &registry;
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    try std.testing.expectEqual(@as(?anyerror, null), producer.begin_error);
    try std.testing.expectEqual(@as(u64, 1), registry.get(.http_requests));
    const contents = try capture.read();
    defer std.testing.allocator.free(contents);
    try expect_single_request_line(contents, "GET", "/stream");
    try std.testing.expect(std.mem.find(u8, contents, "200" ++ support.dev_log.Ansi.reset) != null);
}

test "http2: stream reset before completion emits no request record" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{ .remaining_chunks = 1, .stall = true };
    try router.route_context(.get, "/stream", &producer, stream_route_handler);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    conn.io = std.testing.io;
    var capture: HttpResponseLog = undefined;
    try capture.init();
    defer capture.deinit();
    conn.dev_log = &capture.sink;
    var registry = support.metrics.Registry{};
    conn.metrics = &registry;
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());
    try std.testing.expect(conn.h2_stream_producers[0] != null);

    var cancel: [4]u8 = undefined;
    std.mem.writeInt(u32, &cancel, @intFromEnum(http2_server.ErrorCode.cancel), .big);
    input_length = 0;
    try append_frame(&input, &input_length, .rst_stream, 0, 1, &cancel);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    try std.testing.expect(conn.h2_stream_producers[0] == null);
    try std.testing.expectEqual(@as(u64, 1), registry.get(.http_requests));
    const contents = try capture.read();
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 0), contents.len);
}

test "http2: thread sink receives records without a connection log field" {
    var capture: HttpResponseLog = undefined;
    try capture.init();
    defer capture.deinit();
    const previous_sink = support.dev_log.thread_sink().*;
    support.dev_log.thread_sink().* = .{};
    support.dev_log.thread_sink().enable(std.testing.io, capture.file);
    defer support.dev_log.thread_sink().* = previous_sink;

    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.get("/stream", sync_log_handler);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    conn.io = std.testing.io;
    conn.dev_log = null;
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    const contents = try capture.read();
    defer std.testing.allocator.free(contents);
    try expect_single_request_line(contents, "GET", "/stream");
}

/// Send credit granted per scope per flow-control test iteration.
const producer_window_increment: u32 = 16 * 1024;

fn append_window_update(
    output: []u8,
    offset: *usize,
    stream_id: u32,
    increment: u32,
) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, increment, .big);
    try append_frame(output, offset, .window_update, 0, stream_id, &payload);
}

/// Primes a producer connection with the preface, client settings, and a GET.
fn prime_stream_connection(
    conn: *support.tcp.TcpConnection,
    input: []u8,
) !void {
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(input, &input_length, .settings, 0, 0, "");
    const request_headers = producer_request_headers();
    try append_frame(input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());
    // Routing entry for later WINDOW_UPDATE delivery; the priming above keeps
    // the harness conventions of the existing producer tests.
    conn.protocol_state = .http2;
}

test "http2: producer completes across flow-control window updates" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{
        .chunk_length = 8192,
        .remaining_chunks = 12,
    };
    try router.route_context(.get, "/stream", &producer, stream_route_handler);

    var ring: [128 * 1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    var input: [128]u8 = undefined;
    try prime_stream_connection(&conn, &input);

    try std.testing.expectEqual(@as(?anyerror, null), producer.begin_error);
    try std.testing.expect(conn.h2_stream_producers[0] != null);
    try std.testing.expectEqual(@as(usize, 5), producer.remaining_chunks);

    // The default 65,535-byte window fits seven 8 KiB chunks plus 8,191 bytes.
    var first_body: [128 * 1024]u8 = undefined;
    const first = try collect_data_frames(ring[0..conn.write_len], 1, &first_body);
    try std.testing.expectEqual(@as(usize, 7 * 8192), first.bytes_length);
    try std.testing.expectEqual(@as(usize, 0), first.end_stream_count);

    var total_body: usize = first.bytes_length;
    var iterations: usize = 0;
    while (conn.h2_stream_producers[0] != null and iterations < 16) : (iterations += 1) {
        conn.write_len = 0;
        conn.write_head = 0;
        conn.pump_http2_streams();

        // Production WINDOW_UPDATE entry: receive frees credit, then the
        // transport pumps producers that parked on it.
        var update: [32]u8 = undefined;
        var update_length: usize = 0;
        try append_window_update(&update, &update_length, 0, producer_window_increment);
        try append_window_update(&update, &update_length, 1, producer_window_increment);
        conn.route_decrypted_data(update[0..update_length]);

        var drained_body: [128 * 1024]u8 = undefined;
        const drained = try collect_data_frames(ring[0..conn.write_len], 1, &drained_body);
        total_body += drained.bytes_length;
    }

    try std.testing.expectEqual(@as(usize, 96 * 1024), total_body);
    try std.testing.expectEqual(@as(usize, 0), producer.remaining_chunks);
    try std.testing.expect(!producer.saw_non_would_block);
    try std.testing.expect(conn.h2_stream_producers[0] == null);
    try std.testing.expect(conn.h2.connection.streams.find(1) == null);
}

test "http2: write_chunk maps window exhaustion to WouldBlock" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{
        .chunk_length = 8192,
        .remaining_chunks = 8,
    };
    try router.route_context(.get, "/stream", &producer, stream_route_handler);

    var ring: [128 * 1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    var input: [128]u8 = undefined;
    try prime_stream_connection(&conn, &input);

    // Seven chunks consume 57,344 bytes of the 65,535-byte window; the eighth
    // can only park on the window because the ring still has room.
    try std.testing.expectEqual(@as(?anyerror, null), producer.begin_error);
    try std.testing.expectEqual(@as(usize, 1), producer.remaining_chunks);
    try std.testing.expectEqual(@as(usize, 1), producer.would_block_count);
    try std.testing.expect(!producer.saw_non_would_block);
    try std.testing.expect(conn.h2_stream_producers[0] != null);

    // Ring room alone does not make progress while send credit is exhausted.
    conn.write_len = 0;
    conn.write_head = 0;
    conn.pump_http2_streams();

    try std.testing.expectEqual(@as(usize, 1), producer.remaining_chunks);
    try std.testing.expectEqual(@as(usize, 2), producer.would_block_count);
    try std.testing.expect(!producer.saw_non_would_block);
    try std.testing.expect(conn.h2_stream_producers[0] != null);
}

test "http2: stalled producer runs once per pump" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{ .remaining_chunks = 1, .stall = true };
    try router.route_context(.get, "/stream", &producer, stream_route_handler);

    var ring: [1024]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    var input: [128]u8 = undefined;
    try prime_stream_connection(&conn, &input);

    try std.testing.expectEqual(@as(usize, 1), producer.calls);
    try std.testing.expect(conn.h2_stream_producers[0] != null);

    conn.pump_http2_streams();
    try std.testing.expectEqual(@as(usize, 2), producer.calls);

    // An unrelated inbound frame pumps the stalled producer exactly once.
    var ping: [32]u8 = undefined;
    var ping_length: usize = 0;
    try append_frame(&ping, &ping_length, .ping, 0, 0, "12345678");
    conn.route_decrypted_data(ping[0..ping_length]);
    try std.testing.expectEqual(@as(usize, 3), producer.calls);

    try std.testing.expect(conn.h2_stream_producers[0] != null);
    try std.testing.expectEqual(
        @as(usize, 0),
        try reset_count(ring[0..conn.write_len], 1, .internal_error),
    );
}

test "http2: configured response header capacity accepts wide headers" {
    const WideSession = http2_server.server_session(2);
    const wide_capacities = WideSession.Capacities{
        .response_header_size = 8 * 1024,
        .response_header_count = 64,
    };
    var wide_bundle = WideSession.Bundle(wide_capacities){};
    var session = try WideSession.init(wide_bundle.storage());

    const WideState = struct {
        session: *WideSession,
        output: [32 * 1024]u8 = undefined,
        output_length: usize = 0,
        dispatch_count: usize = 0,

        fn callbacks(self: *@This()) http2_server.Callbacks {
            return .{ .context = self, .write_fn = write, .request_fn = dispatch };
        }

        fn write(context: *anyopaque, parts: []const []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (parts) |part| {
                if (part.len > self.output.len - self.output_length) return error.OutputTooSmall;
                @memcpy(self.output[self.output_length .. self.output_length + part.len], part);
                self.output_length += part.len;
            }
        }

        fn dispatch(context: *anyopaque, _: *Request, stream_id: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.dispatch_count += 1;
            var headers: [8 * 1024]u8 = undefined;
            var length: usize = 0;
            for (0..60) |index| {
                const line = try std.fmt.bufPrint(
                    headers[length..],
                    "X-Wide-{d:0>2}: " ++ ("v" ** 100) ++ "\r\n",
                    .{index},
                );
                length += line.len;
            }
            try self.session.send_response(
                stream_id,
                "200 OK",
                headers[0..length],
                "",
                self.callbacks(),
            );
        }
    };

    var state = WideState{ .session = &session };
    const request_headers = [_]u8{ 0x82, 0x86, 0x84 };
    var input: [80]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expect(!session.is_closed());
    try std.testing.expect(session.connection.streams.find(1) == null);

    var offset: usize = 0;
    var saw_wide_headers = false;
    while (offset < state.output_length) {
        const header = try http2.FrameHeader.parse(state.output[offset..][0..9]);
        if (header.frame_type == @intFromEnum(http2.FrameType.headers) and
            header.stream_id == 1)
        {
            try std.testing.expect(header.payload_length > 4 * 1024);
            saw_wide_headers = true;
        }
        offset += 9 + header.payload_length;
    }
    try std.testing.expect(saw_wide_headers);
}

test "http2: decoded request headers spill into extras" {
    const SpillSession = http2_server.server_session(2);
    const spill_capacities = SpillSession.Capacities{ .decoded_header_count = 96 };
    var spill_bundle = SpillSession.Bundle(spill_capacities){};
    var session = try SpillSession.init(spill_bundle.storage());

    const SpillState = struct {
        dispatch_count: usize = 0,
        inline_count: usize = 0,
        extra_count: usize = 0,
        first: ?[]const u8 = null,
        last: ?[]const u8 = null,
        entries: usize = 0,

        fn callbacks(self: *@This()) http2_server.Callbacks {
            return .{ .context = self, .write_fn = write, .request_fn = dispatch };
        }

        fn write(_: *anyopaque, _: []const []const u8) !void {}

        fn dispatch(context: *anyopaque, request: *Request, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.dispatch_count += 1;
            self.inline_count = request.header_count;
            self.extra_count = request.extra_header_count;
            self.first = request.get_header("x-spill-00");
            self.last = request.get_header("x-spill-69");
            var iterator = request.header_entries();
            while (iterator.next() != null) self.entries += 1;
        }
    };

    var state = SpillState{};
    var block: [1024]u8 = undefined;
    block[0] = 0x82;
    block[1] = 0x86;
    block[2] = 0x84;
    var block_length: usize = 3;
    var name_buffer: [16]u8 = undefined;
    for (0..70) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "x-spill-{d:0>2}", .{index});
        block[block_length] = 0x00;
        block[block_length + 1] = @intCast(name.len);
        @memcpy(block[block_length + 2 ..][0..name.len], name);
        block[block_length + 2 + name.len] = 0x01;
        block[block_length + 2 + name.len + 1] = 'v';
        block_length += 2 + name.len + 2;
    }

    var input: [1280]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, block[0..block_length]);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(@as(usize, 1), state.dispatch_count);
    try std.testing.expectEqual(@as(usize, 64), state.inline_count);
    try std.testing.expectEqual(@as(usize, 6), state.extra_count);
    try std.testing.expectEqualStrings("v", state.first.?);
    try std.testing.expectEqualStrings("v", state.last.?);
    try std.testing.expectEqual(@as(usize, 70), state.entries);
}

/// Encodes one literal HPACK field without indexing.
fn append_hpack_literal(
    buffer: []u8,
    offset: usize,
    name: []const u8,
    value: []const u8,
) !usize {
    const required = 2 + name.len + 1 + value.len;
    if (required > buffer.len - offset) return error.OutputTooSmall;
    var cursor = offset;
    buffer[cursor] = 0;
    cursor += 1;
    buffer[cursor] = @intCast(name.len);
    cursor += 1;
    @memcpy(buffer[cursor .. cursor + name.len], name);
    cursor += name.len;
    buffer[cursor] = @intCast(value.len);
    cursor += 1;
    @memcpy(buffer[cursor .. cursor + value.len], value);
    return cursor + value.len;
}

/// Encodes an RFC 8441 CONNECT request with zero or more handshake fields.
fn connect_ws_header_block(
    buffer: []u8,
    versions: []const []const u8,
    keys: []const []const u8,
) ![]const u8 {
    var offset: usize = 0;
    offset = try append_hpack_literal(buffer, offset, ":method", "CONNECT");
    offset = try append_hpack_literal(buffer, offset, ":scheme", "https");
    offset = try append_hpack_literal(buffer, offset, ":path", "/chat");
    offset = try append_hpack_literal(buffer, offset, ":authority", "example.com");
    offset = try append_hpack_literal(buffer, offset, ":protocol", "websocket");
    for (versions) |value| {
        offset = try append_hpack_literal(buffer, offset, "sec-websocket-version", value);
    }
    for (keys) |value| {
        offset = try append_hpack_literal(buffer, offset, "sec-websocket-key", value);
    }
    return buffer[0..offset];
}

/// Builds one masked client WebSocket frame with a short payload.
fn masked_ws_frame(buffer: []u8, opcode: u8, payload: []const u8, key: [4]u8) []u8 {
    buffer[0] = 0x80 | opcode;
    buffer[1] = 0x80 | @as(u8, @intCast(payload.len));
    @memcpy(buffer[2..6], &key);
    for (payload, 0..) |byte, index| {
        buffer[6 + index] = byte ^ key[index % 4];
    }
    return buffer[0 .. 6 + payload.len];
}

fn find_headers_block(output: []const u8, stream_id: u32) ![]const u8 {
    var offset: usize = 0;
    while (offset < output.len) {
        if (output.len - offset < 9) return error.IncompleteFrame;
        const header = try http2.FrameHeader.parse(output[offset..][0..9]);
        const frame_length = 9 + header.payload_length;
        if (frame_length > output.len - offset) return error.IncompleteFrame;
        if (header.frame_type == @intFromEnum(http2.FrameType.headers) and
            header.stream_id == stream_id)
        {
            return output[offset + 9 .. offset + frame_length];
        }
        offset += frame_length;
    }
    return error.HeadersNotFound;
}

/// Decodes one response header block into caller storage.
fn decode_response(
    output: []const u8,
    stream_id: u32,
    fields: []hpack.Header,
    storage: []u8,
) ![]const hpack.Header {
    var entries: [8]hpack.DynamicEntry = undefined;
    var dynamic_bytes: [256]u8 = undefined;
    var table = try hpack.DynamicTable.init(&entries, &dynamic_bytes, 256);
    var decoder = hpack.Decoder.init(&table, 1024);
    return decoder.decode_fields(
        try find_headers_block(output, stream_id),
        fields,
        storage,
    );
}

fn response_field(fields: []const hpack.Header, name: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

/// Connection with no live socket whose write ring is the only output sink.
fn tunnel_connection(
    ring: []u8,
    message_buffer: []u8,
    router: *const radix.Router,
) support.tcp.TcpConnection {
    return .{
        .socket = undefined,
        .router = router,
        .write_queue = ring,
        .ws_message_buffer = message_buffer,
        .is_writing = true,
    };
}

const tunnel_key = "dGhlIHNhbXBsZSBub25jZQ==";

fn terminate_on_close(ws: *support.ws_socket.WebSocket) void {
    ws.terminate();
}

/// Feeds one client HEADERS frame into an established session.
fn receive_headers_frame(
    conn: *support.tcp.TcpConnection,
    stream_id: u32,
    block: []const u8,
) !void {
    var input: [256]u8 = undefined;
    var input_length: usize = 0;
    try append_frame(&input, &input_length, .headers, 0x4, stream_id, block);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());
}

/// Feeds a client preface, SETTINGS, and one CONNECT header block.
fn receive_connect_request(
    conn: *support.tcp.TcpConnection,
    stream_id: u32,
    block: []const u8,
) !void {
    var input: [512]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x4, stream_id, block);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());
}

fn expect_response_status(
    output: []const u8,
    stream_id: u32,
    expected: []const u8,
) !void {
    var fields: [16]hpack.Header = undefined;
    var storage: [1024]u8 = undefined;
    const decoded = try decode_response(output, stream_id, &fields, &storage);
    try std.testing.expectEqualStrings(
        expected,
        response_field(decoded, ":status") orelse return error.MissingStatus,
    );
}

test "http2 websocket: CONNECT without version is rejected with 426" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.ws("/chat", .{ .max_frame_size = 64, .max_message_size = 64 });

    var ring: [1024]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var conn = tunnel_connection(&ring, &message_buffer, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    var block: [256]u8 = undefined;
    const headers = try connect_ws_header_block(&block, &.{}, &.{tunnel_key});
    try receive_connect_request(&conn, 1, headers);

    try std.testing.expect(!conn.ws.initialized);
    try expect_response_status(ring[0..conn.write_len], 1, "426");

    var fields: [16]hpack.Header = undefined;
    var storage: [1024]u8 = undefined;
    const decoded = try decode_response(ring[0..conn.write_len], 1, &fields, &storage);
    try std.testing.expectEqualStrings(
        "13",
        response_field(decoded, "sec-websocket-version") orelse return error.MissingHeader,
    );
}

test "http2 websocket: CONNECT with version 8 is rejected with 426" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.ws("/chat", .{ .max_frame_size = 64, .max_message_size = 64 });

    var ring: [1024]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var conn = tunnel_connection(&ring, &message_buffer, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    var block: [256]u8 = undefined;
    const headers = try connect_ws_header_block(&block, &.{"8"}, &.{tunnel_key});
    try receive_connect_request(&conn, 1, headers);

    try std.testing.expect(!conn.ws.initialized);
    try expect_response_status(ring[0..conn.write_len], 1, "426");
}

test "http2 websocket: duplicate version is rejected and the key is ignored" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.ws("/chat", .{ .max_frame_size = 64, .max_message_size = 64 });

    var ring: [1024]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var conn = tunnel_connection(&ring, &message_buffer, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    var block: [256]u8 = undefined;
    const duplicate_version = try connect_ws_header_block(&block, &.{ "13", "13" }, &.{tunnel_key});
    try receive_connect_request(&conn, 1, duplicate_version);
    try std.testing.expect(!conn.ws.initialized);
    try expect_response_status(ring[0..conn.write_len], 1, "426");

    // RFC 8441 Section 5 supersedes Sec-WebSocket-Key processing, so a
    // duplicated key neither rejects the request nor reaches the handshake.
    const duplicate_key = try connect_ws_header_block(&block, &.{"13"}, &.{ tunnel_key, tunnel_key });
    try receive_headers_frame(&conn, 3, duplicate_key);
    try std.testing.expect(conn.ws.initialized);
    try expect_response_status(ring[0..conn.write_len], 3, "200");
}

test "http2 websocket: CONNECT with version 13 opens a tunnel without a key" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.ws("/chat", .{ .max_frame_size = 64, .max_message_size = 64 });

    var ring: [1024]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var conn = tunnel_connection(&ring, &message_buffer, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    var block: [256]u8 = undefined;
    const headers = try connect_ws_header_block(&block, &.{"13"}, &.{});
    try receive_connect_request(&conn, 1, headers);

    try std.testing.expect(conn.ws.initialized);
    try expect_response_status(ring[0..conn.write_len], 1, "200");

    // Reset the sink so only the control reply is inspected.
    conn.write_len = 0;
    conn.write_head = 0;

    var ws_frame: [16]u8 = undefined;
    const frame = masked_ws_frame(&ws_frame, 0x9, "p", .{ 1, 2, 3, 4 });
    var data: [32]u8 = undefined;
    var data_length: usize = 0;
    try append_frame(&data, &data_length, .data, 0, 1, frame);
    try conn.h2.receive(data[0..data_length], conn.http2_callbacks());

    var body: [64]u8 = undefined;
    const frames = try collect_data_frames(ring[0..conn.write_len], 1, &body);
    // The WebSocket frame header and payload may arrive as separate DATA
    // frames; only the concatenated WebSocket bytes are contractual.
    try std.testing.expectEqual(@as(usize, 3), frames.bytes_length);
    try std.testing.expectEqualSlices(u8, &.{ 0x8a, 0x01, 'p' }, body[0..frames.bytes_length]);
    try std.testing.expect(!conn.closing);
}

test "http2 websocket: terminate in the close callback keeps the connection" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.ws("/chat", .{
        .close = terminate_on_close,
        .max_frame_size = 64,
        .max_message_size = 64,
    });

    var ring: [1024]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var conn = tunnel_connection(&ring, &message_buffer, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    var block: [256]u8 = undefined;
    const headers = try connect_ws_header_block(&block, &.{"13"}, &.{tunnel_key});
    try receive_connect_request(&conn, 1, headers);
    try std.testing.expect(conn.ws.initialized);

    conn.write_len = 0;
    conn.write_head = 0;

    var ws_frame: [16]u8 = undefined;
    const frame = masked_ws_frame(&ws_frame, 0x8, &.{ 0x03, 0xe8 }, .{ 1, 2, 3, 4 });
    var data: [32]u8 = undefined;
    var data_length: usize = 0;
    try append_frame(&data, &data_length, .data, 0, 1, frame);
    try conn.h2.receive(data[0..data_length], conn.http2_callbacks());

    // The close callback reset only the tunnel; the TCP connection survives.
    try std.testing.expect(!conn.ws.initialized);
    try std.testing.expect(!conn.close_when_drained);
    try std.testing.expect(!conn.closing);
}

/// Counts open and close callback deliveries for the pairing regression.
const PairingCapture = struct {
    var opens: usize = 0;
    var closes: usize = 0;

    fn on_open(_: *support.ws_socket.WebSocket) void {
        opens += 1;
    }

    fn on_close(_: *support.ws_socket.WebSocket) void {
        closes += 1;
    }
};

test "http2 websocket: failed 200 commit reports neither open nor close" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.ws("/chat", .{
        .open = PairingCapture.on_open,
        .close = PairingCapture.on_close,
        .max_frame_size = 64,
        .max_message_size = 64,
    });

    // A ring that fits the SETTINGS ack but not the committed 200 headers.
    var ring: [18]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var conn = tunnel_connection(&ring, &message_buffer, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    PairingCapture.opens = 0;
    PairingCapture.closes = 0;

    var block: [256]u8 = undefined;
    const headers = try connect_ws_header_block(&block, &.{"13"}, &.{tunnel_key});
    receive_connect_request(&conn, 1, headers) catch |err| {
        try std.testing.expectEqual(error.WouldBlock, err);
    };

    try std.testing.expect(!conn.ws.initialized);
    try std.testing.expectEqual(@as(usize, 0), PairingCapture.opens);
    try std.testing.expectEqual(@as(usize, 0), PairingCapture.closes);
}

test "http2 server: advertises the configured dynamic table capacity" {
    const SizedSession = http2_server.server_session(1);
    const sized_capacities = SizedSession.Capacities{
        .header_block_size = 4096,
        .request_header_size = 4096,
        .body_size = 1024,
        .dynamic_table_size = 8192,
    };
    const SizedBundle = SizedSession.Bundle(sized_capacities);
    var bundle: SizedBundle = .{};
    var session = try SizedSession.init(bundle.storage());
    var state = RefusalState{};
    try session.receive(http2.client_preface, state.callbacks());

    const settings = try http2.FrameHeader.parse(state.output[0..9]);
    try std.testing.expectEqual(
        @intFromEnum(http2.FrameType.settings),
        settings.frame_type,
    );
    var offset: usize = 9;
    var table_size: ?u32 = null;
    while (offset < 9 + settings.payload_length) : (offset += 6) {
        const id = std.mem.readInt(u16, state.output[offset..][0..2], .big);
        if (id == 0x1) {
            table_size = std.mem.readInt(u32, state.output[offset + 2 ..][0..4], .big);
        }
    }
    try std.testing.expectEqual(@as(?u32, 8192), table_size);
    try std.testing.expectEqual(@as(usize, 8192), session.dynamic_table.?.maximum_size());

    // The default capacity stays wire-compatible with the HTTP/2 default.
    var fixture: SessionFixture = .{};
    try fixture.init();
    var default_session = fixture.session;
    var default_state = RefusalState{};
    try default_session.receive(http2.client_preface, default_state.callbacks());
    const default_settings = try http2.FrameHeader.parse(default_state.output[0..9]);
    offset = 9;
    table_size = null;
    while (offset < 9 + default_settings.payload_length) : (offset += 6) {
        const id = std.mem.readInt(u16, default_state.output[offset..][0..2], .big);
        if (id == 0x1) {
            table_size = std.mem.readInt(
                u32,
                default_state.output[offset + 2 ..][0..4],
                .big,
            );
        }
    }
    try std.testing.expectEqual(@as(?u32, 4096), table_size);
}

test "http2 server: priority self-dependency resets only the stream" {
    var fixture: SessionFixture = .{};
    try fixture.init();
    var session = fixture.session;
    var state = RefusalState{};

    var input: [64]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    const self_dependency = [_]u8{ 0, 0, 0, 1, 16 };
    try append_frame(&input, &input_length, .priority, 0, 1, &self_dependency);
    try session.receive(input[0..input_length], state.callbacks());

    try std.testing.expect(!session.is_closed());
    try std.testing.expectEqual(
        @as(usize, 1),
        try reset_count(state.output[0..state.output_length], 1, .protocol_error),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        try goaway_code(state.output[0..state.output_length]),
    );
}

/// Streams one response after queueing a header through the response API.
fn queued_header_stream_route_handler(context: *anyopaque, _: *Request, response: *Response) void {
    const producer: *StreamProducerState = @ptrCast(@alignCast(context));
    response.append_header("X-Pending", "yes") catch |err| {
        producer.begin_error = err;
        return;
    };
    response.begin_stream(
        "200 OK",
        "Content-Type: text/plain\r\n",
        producer,
        StreamProducerState.produce,
    ) catch |err| {
        producer.begin_error = err;
    };
}

test "http2: begin_stream carries pending headers into the response block" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var producer = StreamProducerState{ .remaining_chunks = 0 };
    try router.route_context(.get, "/stream", &producer, queued_header_stream_route_handler);

    var ring: [2048]u8 = undefined;
    var conn = producer_connection(&ring, &router);
    var h2_bundle = support.tcp.Http2Session.Bundle(support.tcp.Http2Session.default_capacities){};
    conn.h2 = try support.tcp.Http2Session.init(h2_bundle.storage());

    const request_headers = producer_request_headers();
    var input: [128]u8 = undefined;
    @memcpy(input[0..http2.client_preface.len], http2.client_preface);
    var input_length: usize = http2.client_preface.len;
    try append_frame(&input, &input_length, .settings, 0, 0, "");
    try append_frame(&input, &input_length, .headers, 0x5, 1, &request_headers);
    try conn.h2.receive(input[0..input_length], conn.http2_callbacks());

    try std.testing.expectEqual(@as(?anyerror, null), producer.begin_error);
    var fields: [16]hpack.Header = undefined;
    var storage: [1024]u8 = undefined;
    const decoded = try decode_response(ring[0..conn.write_len], 1, &fields, &storage);
    try std.testing.expectEqualStrings(
        "yes",
        response_field(decoded, "x-pending") orelse return error.MissingPendingHeader,
    );
    try std.testing.expectEqualStrings(
        "text/plain",
        response_field(decoded, "content-type") orelse return error.MissingContentType,
    );
}
