//! C ABI application lifecycle, route and middleware registration, listener
//! startup, publish, and the static callback trampolines.
//!
//! Route strings are copied into fixed CApp storage; callback user_data stays
//! borrowed and must outlive the application. Trampolines recover the owning
//! CApp from the router embedded at a fixed offset, so registration order and
//! index mapping must not change.

const std = @import("std");
const radix = @import("../router/radix.zig");
const Request = @import("../http/request.zig").Request;
const http_response = @import("../http/response.zig");
const AsyncResponse = http_response.AsyncResponse;
const Response = http_response.Response;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const TcpConnection = @import("../core/tcp.zig").TcpConnection;
const QuicStream = @import("../quic/stream.zig").QuicStream;
const zslay = @import("zslay");
const types = @import("types.zig");
const errors = @import("errors.zig");
const response_module = @import("response.zig");

const App = types.App;
const CApp = types.CApp;
const CRoute = types.CRoute;
const CMiddlewareEntry = types.CMiddlewareEntry;
const CAsyncResponse = types.CAsyncResponse;
const CHttpHandler = types.CHttpHandler;
const CAsyncHandler = types.CAsyncHandler;
const CMiddleware = types.CMiddleware;
const CWebSocketBehavior = types.CWebSocketBehavior;
const CreateMode = types.CreateMode;
const CSlice = types.CSlice;
const WsUpgradeSlot = types.WsUpgradeSlot;
const WsEventSlot = types.WsEventSlot;
const WsMessageSlot = types.WsMessageSlot;
const HttpHandlerTable = types.HttpHandlerTable;
const WsUpgradeTable = types.WsUpgradeTable;
const WsEventTable = types.WsEventTable;
const WsMessageTable = types.WsMessageTable;

const max_c_routes = types.max_c_routes;
const max_c_middleware = types.max_c_middleware;
const max_route_path_size = types.max_route_path_size;

const ok = types.ok;
const invalid_argument = types.invalid_argument;
const out_of_memory = types.out_of_memory;
const invalid_state = types.invalid_state;
const capacity = types.capacity;

/// Creates a plaintext application with fixed ABI capacities.
pub export fn uwz_app_create(out_app: ?*?*anyopaque) c_int {
    return create_app(.plain, null, null, out_app);
}

/// Creates a TLS application from NUL-terminated certificate paths.
pub export fn uwz_app_create_tls(
    certificate_path: [*c]const u8,
    private_key_path: [*c]const u8,
    out_app: ?*?*anyopaque,
) c_int {
    return create_app(.tls, certificate_path, private_key_path, out_app);
}

/// Creates a dual HTTP/1.1 and HTTP/3 TLS application.
pub export fn uwz_app_create_http3(
    certificate_path: [*c]const u8,
    private_key_path: [*c]const u8,
    out_app: ?*?*anyopaque,
) c_int {
    return create_app(.http3, certificate_path, private_key_path, out_app);
}

/// Creates a TLS application with an in-memory self-signed localhost certificate.
pub export fn uwz_app_create_tls_ephemeral(out_app: ?*?*anyopaque) c_int {
    return create_app(.tls_ephemeral, null, null, out_app);
}

/// Creates a dual HTTP/1.1 and HTTP/3 application with in-memory self-signed localhost certificates.
pub export fn uwz_app_create_http3_ephemeral(out_app: ?*?*anyopaque) c_int {
    return create_app(.http3_ephemeral, null, null, out_app);
}

/// Stops new work and drains every completion that owns application storage.
pub export fn uwz_app_shutdown(app_pointer: ?*anyopaque) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    app.app.shutdown() catch |err| return errors.map_error(err);
    return ok;
}

/// Drains, releases, and nulls an opaque application handle.
pub export fn uwz_app_destroy(app_pointer: ?*?*anyopaque) c_int {
    const handle = app_pointer orelse return invalid_argument;
    const app = cast_app(handle.*) orelse return invalid_argument;
    if (app.app.is_running()) return invalid_state;
    app.app.shutdown() catch |err| return errors.map_error(err);
    app.app.deinit();
    app.threaded.deinit();
    std.heap.page_allocator.destroy(app);
    handle.* = null;
    return ok;
}

/// Registers a synchronous HTTP route and caller context.
pub export fn uwz_app_route(
    app_pointer: ?*anyopaque,
    method: c_int,
    path_pointer: [*c]const u8,
    path_length: usize,
    handler: ?CHttpHandler,
    user_data: ?*anyopaque,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const callback = handler orelse return invalid_argument;
    const path = errors.required_bytes(path_pointer, path_length) orelse return invalid_argument;
    if (path.len > max_route_path_size or std.mem.indexOfScalar(u8, path, 0) != null) {
        return invalid_argument;
    }
    if (app.route_count >= max_c_routes) return capacity;

    const index = app.route_count;
    const route = &app.routes[index];
    @memcpy(route.path[0..path.len], path);
    route.path_length = path.len;
    route.http_handler = callback;
    route.user_data = user_data;

    register_http_route(
        &app.app,
        method,
        route.path[0..route.path_length],
        http_handlers[index],
    ) catch |err| {
        route.* = .{};
        return errors.map_error(err);
    };
    app.route_count += 1;
    return ok;
}

/// Registers a deferred HTTP route and caller context.
pub export fn uwz_app_route_async(
    app_pointer: ?*anyopaque,
    method: c_int,
    path_pointer: [*c]const u8,
    path_length: usize,
    handler: ?CAsyncHandler,
    user_data: ?*anyopaque,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const callback = handler orelse return invalid_argument;
    const path = errors.required_bytes(path_pointer, path_length) orelse return invalid_argument;
    if (path.len > max_route_path_size or std.mem.indexOfScalar(u8, path, 0) != null) {
        return invalid_argument;
    }
    if (app.route_count >= max_c_routes) return capacity;

    const method_value = http_method(method) orelse return invalid_argument;
    const route = &app.routes[app.route_count];
    @memcpy(route.path[0..path.len], path);
    route.path_length = path.len;
    route.async_handler = callback;
    route.user_data = user_data;

    _ = app.app.route_async_context(
        method_value,
        route.path[0..route.path_length],
        route,
        async_http_handler,
    ) catch |err| {
        route.* = .{};
        return errors.map_error(err);
    };
    app.route_count += 1;
    return ok;
}

/// Appends one ordered middleware callback and caller context.
pub export fn uwz_app_use(
    app_pointer: ?*anyopaque,
    middleware: ?CMiddleware,
    user_data: ?*anyopaque,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const callback = middleware orelse return invalid_argument;
    if (app.middleware_count >= max_c_middleware) return capacity;

    const entry = &app.middleware[app.middleware_count];
    entry.* = .{ .callback = callback, .user_data = user_data };
    _ = app.app.use(entry, c_middleware_handler) catch |err| {
        entry.* = .{};
        return errors.map_error(err);
    };
    app.middleware_count += 1;
    return ok;
}

/// Registers a WebSocket route with fixed-capacity callback storage.
pub export fn uwz_app_ws(
    app_pointer: ?*anyopaque,
    path_pointer: [*c]const u8,
    path_length: usize,
    behavior_pointer: ?*const CWebSocketBehavior,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const source = behavior_pointer orelse return invalid_argument;
    const path = errors.required_bytes(path_pointer, path_length) orelse return invalid_argument;
    if (path.len > max_route_path_size or std.mem.indexOfScalar(u8, path, 0) != null) {
        return invalid_argument;
    }
    if (app.route_count >= max_c_routes) return capacity;

    const compression: radix.WsCompression = switch (source.compression) {
        0 => .disabled,
        1 => .permessage_deflate,
        else => return invalid_argument,
    };
    const index = app.route_count;
    const route = &app.routes[index];
    @memcpy(route.path[0..path.len], path);
    route.path_length = path.len;
    route.ws_upgrade = source.upgrade;
    route.ws_open = source.open;
    route.ws_message = source.message;
    route.ws_drain = source.drain;
    route.ws_close = source.close;
    route.user_data = source.user_data;

    _ = app.app.ws(route.path[0..route.path_length], .{
        .upgrade = ws_upgrade_handlers[index],
        .open = ws_open_handlers[index],
        .message = ws_message_handlers[index],
        .drain = ws_drain_handlers[index],
        .close = ws_close_handlers[index],
        .compression = compression,
        .max_frame_size = source.max_frame_size,
        .max_message_size = source.max_message_size,
    }) catch |err| {
        route.* = .{};
        return errors.map_error(err);
    };
    app.route_count += 1;
    return ok;
}

/// Starts the TCP listener on a borrowed address string.
pub export fn uwz_app_listen(
    app_pointer: ?*anyopaque,
    address_pointer: [*c]const u8,
    address_length: usize,
    port: u16,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const address = errors.required_bytes(address_pointer, address_length) orelse return invalid_argument;
    app.app.listen(address, port) catch |err| return errors.map_error(err);
    return ok;
}

/// Starts the QUIC UDP listener on a borrowed address string.
pub export fn uwz_app_listen_udp(
    app_pointer: ?*anyopaque,
    address_pointer: [*c]const u8,
    address_length: usize,
    port: u16,
) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    const address = errors.required_bytes(address_pointer, address_length) orelse return invalid_argument;
    app.app.listen_udp(address, port) catch |err| return errors.map_error(err);
    return ok;
}

/// Runs the application event loop until it becomes idle.
pub export fn uwz_app_run(app_pointer: ?*anyopaque) c_int {
    const app = cast_app(app_pointer) orelse return invalid_argument;
    app.app.run() catch |err| return errors.map_error(err);
    return ok;
}

/// Publishes one message to matching subscribers.
pub export fn uwz_app_publish(
    app_pointer: ?*anyopaque,
    topic: CSlice,
    message: CSlice,
    is_text: bool,
) usize {
    const app = cast_app(app_pointer) orelse return 0;
    const topic_bytes = errors.slice_bytes(topic) orelse return 0;
    const message_bytes = errors.slice_bytes(message) orelse return 0;
    return app.app.publish(topic_bytes, message_bytes, is_text);
}

fn create_app(
    mode: CreateMode,
    certificate_path: [*c]const u8,
    private_key_path: [*c]const u8,
    out_app: ?*?*anyopaque,
) c_int {
    const output = out_app orelse return invalid_argument;
    if (output.* != null) return invalid_argument;

    const app = std.heap.page_allocator.create(CApp) catch return out_of_memory;
    app.threaded = .init(std.heap.c_allocator, .{});
    app.routes = [_]CRoute{.{}} ** max_c_routes;
    app.route_count = 0;
    app.middleware = [_]CMiddlewareEntry{.{}} ** max_c_middleware;
    app.middleware_count = 0;

    app.app = switch (mode) {
        .plain => App.init(app.threaded.io()),
        .tls_ephemeral => App.init_https_ephemeral(app.threaded.io()),
        .http3_ephemeral => App.init_http3_ephemeral(app.threaded.io()),
        .tls, .http3 => init: {
            if (certificate_path == null or private_key_path == null) {
                app.threaded.deinit();
                std.heap.page_allocator.destroy(app);
                return invalid_argument;
            }
            const certificate: [*:0]const u8 = @ptrCast(certificate_path);
            const private_key: [*:0]const u8 = @ptrCast(private_key_path);
            break :init if (mode == .tls)
                App.init_https(app.threaded.io(), std.mem.span(certificate), std.mem.span(private_key))
            else
                App.init_http3(app.threaded.io(), std.mem.span(certificate), std.mem.span(private_key));
        },
    } catch |err| {
        app.threaded.deinit();
        std.heap.page_allocator.destroy(app);
        return errors.map_error(err);
    };

    output.* = app;
    return ok;
}

fn register_http_route(
    app: *App,
    method: c_int,
    path: []const u8,
    handler: radix.Handler,
) !void {
    _ = switch (method) {
        0 => try app.get(path, handler),
        1 => try app.head(path, handler),
        2 => try app.post(path, handler),
        3 => try app.put(path, handler),
        4 => try app.delete(path, handler),
        5 => try app.patch(path, handler),
        6 => try app.options(path, handler),
        7 => try app.any(path, handler),
        8 => try app.query(path, handler),
        9 => try app.trace(path, handler),
        else => return error.InvalidMethod,
    };
}

fn http_method(method: c_int) ?radix.HttpMethod {
    return switch (method) {
        0 => .get,
        1 => .head,
        2 => .post,
        3 => .put,
        4 => .delete,
        5 => .patch,
        6 => .options,
        7 => .any,
        8 => .query,
        9 => .trace,
        else => null,
    };
}

fn async_http_handler(
    context: *anyopaque,
    request: *Request,
    response: AsyncResponse,
) void {
    const route: *CRoute = @ptrCast(@alignCast(context));
    const callback = route.async_handler orelse {
        response_module.fail_pending_response(response);
        return;
    };
    var c_response = CAsyncResponse{
        .state = response.owner,
        .generation = response.generation,
    };

    const result = callback(request, &c_response, route.user_data);
    switch (result) {
        0 => if (response.is_pending()) response_module.fail_pending_response(response),
        1 => {},
        else => response_module.fail_pending_response(response),
    }
}

fn c_middleware_handler(
    context: *anyopaque,
    request: *Request,
    response: *Response,
) radix.MiddlewareResult {
    const entry: *CMiddlewareEntry = @ptrCast(@alignCast(context));
    const callback = entry.callback orelse return .stop;
    return switch (callback(request, response, entry.user_data)) {
        0 => .continue_dispatch,
        1, 2 => .stop,
        else => .stop,
    };
}

fn http_handler(comptime index: usize) radix.Handler {
    return struct {
        fn call(request: *Request, response: *Response) void {
            const owner = owner_from_response(response);
            const route = &owner.routes[index];
            const callback = route.http_handler orelse return;
            callback(request, response, route.user_data);
        }
    }.call;
}

const http_handlers = handlers: {
    var values: HttpHandlerTable = undefined;
    for (0..max_c_routes) |index| values[index] = http_handler(index);
    break :handlers values;
};

fn ws_upgrade_handler(comptime index: usize) WsUpgradeSlot {
    return struct {
        fn call(request: *const Request) bool {
            const connection: *TcpConnection = @fieldParentPtr("req", @constCast(request));
            const owner = owner_from_router(connection.router);
            const route = &owner.routes[index];
            const callback = route.ws_upgrade orelse return true;
            return callback(request, route.user_data);
        }
    }.call;
}

fn ws_open_handler(comptime index: usize) WsEventSlot {
    return struct {
        fn call(socket: *WebSocket) void {
            const owner = owner_from_router(socket.conn.router);
            const route = &owner.routes[index];
            const callback = route.ws_open orelse return;
            callback(socket, route.user_data);
        }
    }.call;
}

fn ws_message_handler(comptime index: usize) WsMessageSlot {
    return struct {
        fn call(socket: *WebSocket, message: []const u8, opcode: zslay.Opcode) void {
            const owner = owner_from_router(socket.conn.router);
            const route = &owner.routes[index];
            const callback = route.ws_message orelse return;
            callback(socket, errors.make_slice(message), @intFromEnum(opcode), route.user_data);
        }
    }.call;
}

fn ws_drain_handler(comptime index: usize) WsEventSlot {
    return struct {
        fn call(socket: *WebSocket) void {
            const owner = owner_from_router(socket.conn.router);
            const route = &owner.routes[index];
            const callback = route.ws_drain orelse return;
            callback(socket, route.user_data);
        }
    }.call;
}

fn ws_close_handler(comptime index: usize) WsEventSlot {
    return struct {
        fn call(socket: *WebSocket) void {
            const owner = owner_from_router(socket.conn.router);
            const route = &owner.routes[index];
            const callback = route.ws_close orelse return;
            callback(socket, route.user_data);
        }
    }.call;
}

const ws_upgrade_handlers = handlers: {
    var values: WsUpgradeTable = undefined;
    for (0..max_c_routes) |index| values[index] = ws_upgrade_handler(index);
    break :handlers values;
};

const ws_open_handlers = handlers: {
    var values: WsEventTable = undefined;
    for (0..max_c_routes) |index| values[index] = ws_open_handler(index);
    break :handlers values;
};

const ws_message_handlers = handlers: {
    var values: WsMessageTable = undefined;
    for (0..max_c_routes) |index| values[index] = ws_message_handler(index);
    break :handlers values;
};

const ws_drain_handlers = handlers: {
    var values: WsEventTable = undefined;
    for (0..max_c_routes) |index| values[index] = ws_drain_handler(index);
    break :handlers values;
};

const ws_close_handlers = handlers: {
    var values: WsEventTable = undefined;
    for (0..max_c_routes) |index| values[index] = ws_close_handler(index);
    break :handlers values;
};

fn owner_from_response(response: *Response) *CApp {
    const router = switch (response.target) {
        .tcp => |connection| connection.router,
        .http2 => |target| @as(
            *const radix.Router,
            @ptrCast(@alignCast(target.router)),
        ),
        .http3 => |target| blk: {
            const stream: *QuicStream = @ptrCast(@alignCast(target.context));
            break :blk stream.router;
        },
    };
    return owner_from_router(router);
}

fn owner_from_router(router: *const radix.Router) *CApp {
    const app: *App = @fieldParentPtr("router", @constCast(router));
    return @fieldParentPtr("app", app);
}

fn cast_app(pointer: ?*anyopaque) ?*CApp {
    return @ptrCast(@alignCast(pointer orelse return null));
}
