const std = @import("std");
const support = @import("test_support");

const Request = support.http_request.Request;
const AsyncResponseState = support.http_response.AsyncResponseState;
const TcpConnection = support.tcp.TcpConnection;
const WebSocket = support.ws_socket.WebSocket;
const PubSubEngine = support.ws_pubsub.PubSubEngine;

const ok: c_int = 0;
const invalid_argument: c_int = -1;
const invalid_state: c_int = -3;
const already_exists: c_int = -4;
const capacity: c_int = -5;

const CSlice = extern struct {
    data: [*c]const u8,
    length: usize,
};

const CAsyncResponse = extern struct {
    state: ?*anyopaque,
    generation: u64,
};

const CAsyncHandler = *const fn (
    ?*const anyopaque,
    ?*CAsyncResponse,
    ?*anyopaque,
) callconv(.c) c_int;

const CHttpHandler = *const fn (
    ?*const anyopaque,
    ?*anyopaque,
    ?*anyopaque,
) callconv(.c) void;

const CMiddleware = *const fn (
    ?*const anyopaque,
    ?*anyopaque,
    ?*anyopaque,
) callconv(.c) c_int;

extern fn uwz_app_create(?*?*anyopaque) callconv(.c) c_int;
extern fn uwz_app_create_tls_ephemeral(?*?*anyopaque) callconv(.c) c_int;
extern fn uwz_app_create_http3_ephemeral(?*?*anyopaque) callconv(.c) c_int;
extern fn uwz_app_shutdown(?*anyopaque) callconv(.c) c_int;
extern fn uwz_app_destroy(?*?*anyopaque) callconv(.c) c_int;
extern fn uwz_app_listen(
    ?*anyopaque,
    [*c]const u8,
    usize,
    u16,
) callconv(.c) c_int;
extern fn uwz_app_route_async(
    ?*anyopaque,
    c_int,
    [*c]const u8,
    usize,
    ?CAsyncHandler,
    ?*anyopaque,
) callconv(.c) c_int;
extern fn uwz_app_route(
    ?*anyopaque,
    c_int,
    [*c]const u8,
    usize,
    ?CHttpHandler,
    ?*anyopaque,
) callconv(.c) c_int;
extern fn uwz_app_use(?*anyopaque, ?CMiddleware, ?*anyopaque) callconv(.c) c_int;
extern fn uwz_request_parameter(?*const anyopaque, CSlice) callconv(.c) CSlice;
extern fn uwz_request_parameter_count(?*const anyopaque) callconv(.c) usize;
extern fn uwz_async_response_end(?*CAsyncResponse, CSlice, CSlice) callconv(.c) c_int;
extern fn uwz_async_response_end_with_headers(
    ?*CAsyncResponse,
    CSlice,
    CSlice,
    CSlice,
) callconv(.c) c_int;
extern fn uwz_websocket_subscribe(?*anyopaque, CSlice) callconv(.c) c_int;

test "C request parameter access preserves borrowed captures" {
    var request = Request{};
    try request.add_param("id", "42");
    try request.add_param("tail", "one/two");

    try std.testing.expectEqual(@as(usize, 2), uwz_request_parameter_count(&request));
    try std.testing.expectEqualStrings(
        "42",
        bytes(uwz_request_parameter(&request, c_slice("id"))),
    );
    try std.testing.expectEqualStrings(
        "one/two",
        bytes(uwz_request_parameter(&request, c_slice("tail"))),
    );
    try std.testing.expectEqual(@as(usize, 0), uwz_request_parameter(
        &request,
        c_slice("missing"),
    ).length);
    try std.testing.expectEqual(@as(usize, 0), uwz_request_parameter_count(null));
}

test "C async token completes exactly once and rejects stale generations" {
    var capture = CompletionCapture{};
    var state = AsyncResponseState{};
    const target = support.http_response.AsyncTarget{
        .context = &capture,
        .complete_fn = capture_completion,
        .wake_fn = capture_wake,
    };

    const first = state.arm(target);
    var first_c = CAsyncResponse{
        .state = first.owner,
        .generation = first.generation,
    };
    try std.testing.expectEqual(ok, uwz_async_response_end(
        &first_c,
        c_slice("200 OK"),
        c_slice("ok"),
    ));
    try std.testing.expectEqual(@as(usize, 1), capture.completions);
    try std.testing.expectEqual(@as(usize, 1), capture.wakes);
    try std.testing.expectEqual(@as(usize, 6), capture.status_length);
    try std.testing.expectEqual(@as(usize, 2), capture.body_length);
    try std.testing.expectEqual(invalid_state, uwz_async_response_end(
        &first_c,
        c_slice("200 OK"),
        c_slice("again"),
    ));

    const stale = state.arm(target);
    var stale_c = CAsyncResponse{
        .state = stale.owner,
        .generation = stale.generation,
    };
    state.cancel();
    try std.testing.expectEqual(invalid_state, uwz_async_response_end(
        &stale_c,
        c_slice("200 OK"),
        c_slice("late"),
    ));

    const with_headers = state.arm(target);
    var headers_c = CAsyncResponse{
        .state = with_headers.owner,
        .generation = with_headers.generation,
    };
    try std.testing.expectEqual(invalid_argument, uwz_async_response_end(
        &headers_c,
        c_slice("205 Reset Content"),
        c_slice("not allowed"),
    ));
    try std.testing.expectEqual(ok, uwz_async_response_end_with_headers(
        &headers_c,
        c_slice("205 Reset Content"),
        c_slice("X-Test: yes\r\n"),
        c_slice(""),
    ));
    try std.testing.expectEqual(@as(usize, 2), capture.completions);
    try std.testing.expectEqual(@as(usize, 13), capture.header_length);

    try std.testing.expectEqual(invalid_argument, uwz_async_response_end(
        null,
        c_slice("200 OK"),
        c_slice(""),
    ));
}

test "C async QUERY registration and middleware use fixed capacities" {
    var app: ?*anyopaque = null;
    try std.testing.expectEqual(ok, uwz_app_create(&app));
    defer if (app != null) {
        _ = uwz_app_destroy(&app);
    };

    const path = "/lookup/:id";
    try std.testing.expectEqual(ok, uwz_app_route_async(
        app,
        8,
        path.ptr,
        path.len,
        pending_handler,
        null,
    ));
    try std.testing.expectEqual(already_exists, uwz_app_route_async(
        app,
        8,
        path.ptr,
        path.len,
        pending_handler,
        null,
    ));
    try std.testing.expectEqual(invalid_argument, uwz_app_route_async(
        app,
        10,
        path.ptr,
        path.len,
        pending_handler,
        null,
    ));
    const sync_path = "/sync-query";
    try std.testing.expectEqual(ok, uwz_app_route(
        app,
        8,
        sync_path.ptr,
        sync_path.len,
        sync_handler,
        null,
    ));

    for (0..32) |_| {
        try std.testing.expectEqual(ok, uwz_app_use(app, continue_middleware, null));
    }
    try std.testing.expectEqual(capacity, uwz_app_use(app, continue_middleware, null));

    try std.testing.expectEqual(ok, uwz_app_shutdown(app));
    try std.testing.expectEqual(ok, uwz_app_shutdown(app));
    try std.testing.expectEqual(ok, uwz_app_destroy(&app));
    try std.testing.expect(app == null);
}

test "C ephemeral TLS applications create and destroy" {
    var app_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ok, uwz_app_create_tls_ephemeral(&app_handle));
    defer _ = uwz_app_destroy(&app_handle);
    try std.testing.expect(app_handle != null);

    var http3_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ok, uwz_app_create_http3_ephemeral(&http3_handle));
    defer _ = uwz_app_destroy(&http3_handle);
    try std.testing.expect(http3_handle != null);
}

test "C errors classify invalid listener and pubsub input" {
    var app: ?*anyopaque = null;
    try std.testing.expectEqual(ok, uwz_app_create(&app));
    defer if (app != null) {
        _ = uwz_app_destroy(&app);
    };

    const bad_address = "not-an-ip-address";
    try std.testing.expectEqual(invalid_argument, uwz_app_listen(
        app,
        bad_address.ptr,
        bad_address.len,
        8080,
    ));

    const connection = try std.heap.page_allocator.create(TcpConnection);
    defer std.heap.page_allocator.destroy(connection);
    connection.* = .{ .socket = undefined };

    const engine = try std.heap.page_allocator.create(PubSubEngine);
    defer std.heap.page_allocator.destroy(engine);
    engine.* = .{};

    var socket = WebSocket{ .conn = connection, .pubsub = engine };
    try std.testing.expectEqual(
        invalid_argument,
        uwz_websocket_subscribe(&socket, c_slice("")),
    );

    var long_topic = [_]u8{'x'} ** (support.ws_pubsub.max_topic_length + 1);
    try std.testing.expectEqual(
        invalid_argument,
        uwz_websocket_subscribe(&socket, c_slice(&long_topic)),
    );

    socket.pubsub = null;
    try std.testing.expectEqual(
        invalid_state,
        uwz_websocket_subscribe(&socket, c_slice("events")),
    );
}

const CompletionCapture = struct {
    completions: usize = 0,
    wakes: usize = 0,
    status_length: usize = 0,
    header_length: usize = 0,
    body_length: usize = 0,
};

fn capture_completion(
    context: *anyopaque,
    status: []const u8,
    headers: []const u8,
    body: []const u8,
) !void {
    const capture: *CompletionCapture = @ptrCast(@alignCast(context));
    capture.completions += 1;
    capture.status_length = status.len;
    capture.header_length = headers.len;
    capture.body_length = body.len;
}

fn capture_wake(context: *anyopaque) void {
    const capture: *CompletionCapture = @ptrCast(@alignCast(context));
    capture.wakes += 1;
}

fn pending_handler(
    _: ?*const anyopaque,
    _: ?*CAsyncResponse,
    _: ?*anyopaque,
) callconv(.c) c_int {
    return 1;
}

fn sync_handler(
    _: ?*const anyopaque,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {}

fn continue_middleware(
    _: ?*const anyopaque,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) c_int {
    return 0;
}

fn c_slice(value: []const u8) CSlice {
    if (value.len == 0) return .{ .data = null, .length = 0 };
    return .{ .data = value.ptr, .length = value.len };
}

fn bytes(value: CSlice) []const u8 {
    if (value.length == 0) return "";
    return value.data[0..value.length];
}
