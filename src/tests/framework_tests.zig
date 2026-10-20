const std = @import("std");
const support = @import("test_support");

const Request = support.http_request.Request;
const Response = support.http_response.Response;

const ResponseCapture = struct {
    status: []const u8 = "",
    headers: [4096]u8 = undefined,
    headers_len: usize = 0,
    body: [4096]u8 = undefined,
    body_len: usize = 0,
    finished: bool = false,

    fn target(self: *ResponseCapture) support.http_response.Http3Target {
        return .{
            .context = self,
            .end_fn = end,
            .begin_fn = begin,
            .write_fn = write,
            .finish_fn = finish,
        };
    }

    fn end(context: *anyopaque, status: []const u8, headers: []const u8, body: []const u8) !void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        try self.capture(status, headers, body);
        self.finished = true;
    }

    fn begin(context: *anyopaque, status: []const u8, headers: []const u8) !void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        try self.capture(status, headers, "");
    }

    fn write(context: *anyopaque, body: []const u8) !void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        if (body.len > self.body.len - self.body_len) return error.BufferOverflow;
        @memcpy(self.body[self.body_len..][0..body.len], body);
        self.body_len += body.len;
    }

    fn finish(context: *anyopaque) !void {
        const self: *ResponseCapture = @ptrCast(@alignCast(context));
        self.finished = true;
    }

    fn capture(
        self: *ResponseCapture,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        if (headers.len > self.headers.len or body.len > self.body.len) return error.BufferOverflow;
        self.status = status;
        @memcpy(self.headers[0..headers.len], headers);
        self.headers_len = headers.len;
        @memcpy(self.body[0..body.len], body);
        self.body_len = body.len;
    }
};

test "framework: SIMD search handles vector and scalar tails" {
    const input = "0123456789abcdef--needle--tail";
    try std.testing.expectEqual(@as(?usize, 16), support.simd.index_of_byte(input, '-'));
    try std.testing.expectEqual(@as(?usize, 18), support.simd.index_of(input, "needle"));
    try std.testing.expect(support.simd.index_of(input, "missing") == null);
}

test "framework: multipart parses chunks and ignores boundary prefixes" {
    const body = "--abc\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "first\r\n--abcX is payload\r\nsecond\r\n" ++
        "--abc--\r\n";
    var parser = try support.multipart.Parser.init(body, "abc");
    const part = (try parser.next_part()).?;
    try std.testing.expectEqualStrings("upload", part.name);
    try std.testing.expectEqualStrings("a.txt", part.filename.?);
    try std.testing.expectEqualStrings("text/plain", part.content_type.?);
    try std.testing.expectEqualStrings("first\r\n--abcX is payload\r\nsecond", part.data);

    var chunks = part.chunks(7);
    var bytes: usize = 0;
    while (chunks.next()) |chunk| bytes += chunk.len;
    try std.testing.expectEqual(part.data.len, bytes);
    try std.testing.expect((try parser.next_part()) == null);
}

test "framework: cookies format, sign, and reject tampering" {
    var field_buffer: [256]u8 = undefined;
    const field = try support.cookie.format(&field_buffer, "session", "abc", .{
        .http_only = true,
        .secure = true,
        .same_site = .strict,
        .max_age = 60,
    });
    try std.testing.expectEqualStrings(
        "Set-Cookie: session=abc; Path=/; Max-Age=60; HttpOnly; Secure; SameSite=Strict\r\n",
        field,
    );
    try std.testing.expectEqualStrings("abc", support.cookie.find("a=1; session=abc", "session").?);

    const secret = "0123456789abcdef0123456789abcdef";
    var signed_buffer: [128]u8 = undefined;
    const signed = try support.cookie.sign(&signed_buffer, "abc", secret);
    try std.testing.expectEqualStrings("abc", try support.cookie.verify_signed(signed, secret));
    var cookie_header_buffer: [256]u8 = undefined;
    var request = Request{};
    request.header_names[0] = "Cookie";
    request.header_values[0] = try std.fmt.bufPrint(&cookie_header_buffer, "session={s}", .{signed});
    request.header_count = 1;
    try std.testing.expectEqualStrings("abc", (try request.signed_cookie("session", secret)).?);
    signed_buffer[0] = 'x';
    try std.testing.expectError(error.InvalidCookieSignature, support.cookie.verify_signed(signed, secret));
}

test "framework: request clone owns every borrowed slice" {
    var request = Request{
        .method = "POST",
        .target = "/users?id=1",
        .path = "/users",
        .query = "id=1",
        .body = "payload",
    };
    request.header_names[0] = "Cookie";
    request.header_values[0] = "session=abc";
    request.header_count = 1;
    request.route_param_names[0] = "id";
    request.route_param_values[0] = "1";
    request.route_param_count = 1;

    var owned = try request.clone(std.testing.allocator);
    defer owned.deinit();
    const view = owned.view();
    try std.testing.expectEqualStrings("POST", view.method);
    try std.testing.expectEqualStrings("session=abc", view.get_header("cookie").?);
    try std.testing.expectEqualStrings("abc", view.cookie("session").?);
    try std.testing.expectEqualStrings("1", view.get_param("id").?);
}

test "framework: schema validates fields and reports the first issue" {
    const User = struct {
        name: []const u8,
        age: u8,

        pub const validation = .{
            .name = support.schema.Rule{ .min_length = 2, .max_length = 20 },
            .age = support.schema.Rule{ .min = 18, .max = 120 },
        };
    };

    var issue = support.schema.Issue{};
    try std.testing.expectError(
        error.ConstraintViolation,
        support.schema.validate_json_detailed(User, std.testing.allocator, "{\"name\":\"A\",\"age\":42}", &issue),
    );
    try std.testing.expectEqualStrings("name", issue.field);
    try std.testing.expectEqual(support.schema.IssueKind.too_short, issue.kind);

    var parsed = try support.schema.validate_json(
        User,
        std.testing.allocator,
        "{\"name\":\"Ziggy\",\"age\":42}",
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Ziggy", parsed.value.name);
}

test "framework: middleware and SSE compose queued headers" {
    var capture = ResponseCapture{};
    var response = Response{ .target = .{ .http3 = capture.target() } };
    var request = Request{ .method = "GET" };
    request.header_names[0] = "Origin";
    request.header_values[0] = "https://example.com";
    request.header_count = 1;
    var cors = support.middleware.cors(.{ .origins = &.{"https://example.com"} });
    try std.testing.expectEqual(
        support.radix.MiddlewareResult.continue_dispatch,
        support.middleware.Cors.handler(&cors, &request, &response),
    );
    try response.end("200 OK", "done");
    try std.testing.expect(std.mem.indexOf(u8, capture.headers[0..capture.headers_len], "Access-Control-Allow-Origin") != null);

    capture = .{};
    response = .{ .target = .{ .http3 = capture.target() } };
    var sse = try response.sse();
    try sse.send_event("update", "one\ntwo");
    try sse.heartbeat();
    try sse.close();
    try std.testing.expect(capture.finished);
    try std.testing.expect(std.mem.indexOf(u8, capture.body[0..capture.body_len], "data: one") != null);
}

test "framework: response set_cookie appends a validated field" {
    var capture = ResponseCapture{};
    var response = Response{ .target = .{ .http3 = capture.target() } };
    try response.set_cookie("session", "abc", .{ .http_only = true });
    try response.set_signed_cookie(
        "signed",
        "payload",
        "0123456789abcdef0123456789abcdef",
        .{ .secure = true },
    );
    try response.end("204 No Content", "");
    try std.testing.expect(std.mem.indexOf(u8, capture.headers[0..capture.headers_len], "Set-Cookie: session=abc") != null);
}

test "framework: OpenAPI reflects routes and path parameters" {
    const handler = struct {
        fn call(_: *Request, _: *Response) void {}
    }.call;
    var bundle = support.radix.DefaultBundle{};
    var router = try support.radix.Router.init(bundle.storage());
    try router.get("/users/:id", handler);
    try router.post("/users", handler);
    try router.trace("/probe", handler);
    try router.ws("/events", .{});

    var buffer: [4096]u8 = undefined;
    const document = try router.write_openapi(&buffer, .{});
    try std.testing.expect(std.mem.indexOf(u8, document, "\"openapi\":\"3.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "\"/users/{id}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "\"post\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "\"trace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "\"x-websocket\":true") != null);
}

test "framework: static files parse ranges and map MIME types" {
    const range = (try support.static_files.parse_range("bytes=10-19", 100)).?;
    try std.testing.expectEqual(@as(u64, 10), range.start);
    try std.testing.expectEqual(@as(u64, 19), range.end);
    try std.testing.expectEqual(@as(u64, 10), range.length());

    const suffix = (try support.static_files.parse_range("bytes=-8", 100)).?;
    try std.testing.expectEqual(@as(u64, 92), suffix.start);
    try std.testing.expectError(
        error.MultipleRangesUnsupported,
        support.static_files.parse_range("bytes=0-1,4-5", 100),
    );
    try std.testing.expectEqualStrings(
        "text/javascript; charset=utf-8",
        support.static_files.mime_type("app.js"),
    );
}

test "framework: static file handler serves a bounded range" {
    const StaticFiles = support.static_files.static_files(2048);
    var files = try StaticFiles.init(std.testing.io, ".", .{});
    defer files.deinit();

    var request = Request{ .method = "GET" };
    request.route_param_names[0] = "path";
    request.route_param_values[0] = "LICENSE";
    request.route_param_count = 1;
    request.header_names[0] = "Range";
    request.header_values[0] = "bytes=0-15";
    request.header_count = 1;

    var capture = ResponseCapture{};
    var response = Response{ .target = .{ .http3 = capture.target() } };
    try files.serve(&request, &response);
    try std.testing.expectEqualStrings("206 Partial Content", capture.status);
    try std.testing.expectEqual(@as(usize, 16), capture.body_len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.headers[0..capture.headers_len],
        "Content-Range: bytes 0-15/1063",
    ) != null);
}

test "framework: cluster queue preserves bounded message order" {
    const Queue = support.cluster.message_queue(64);
    var queue = Queue{};
    try queue.push("first", "one", true);
    try queue.push("second", "two", false);

    var topic_buffer: [127]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    const first = queue.pop_copy(&topic_buffer, &message_buffer).?;
    try std.testing.expectEqualStrings("first", first.topic);
    try std.testing.expectEqualStrings("one", first.payload);
    try std.testing.expect(first.is_text);

    const second = queue.pop_copy(&topic_buffer, &message_buffer).?;
    try std.testing.expectEqualStrings("second", second.topic);
    try std.testing.expectEqualStrings("two", second.payload);
    try std.testing.expect(!second.is_text);
    try std.testing.expect(queue.pop_copy(&topic_buffer, &message_buffer) == null);
}

test "framework: heartbeat configuration requires paired intervals" {
    try std.testing.expect(!support.radix.valid_ws_limits(
        .{ .ping_interval_ms = 1000 },
        16 * 1024,
    ));
    try std.testing.expect(support.radix.valid_ws_limits(
        .{ .ping_interval_ms = 1000, .pong_timeout_ms = 5000 },
        16 * 1024,
    ));
}
