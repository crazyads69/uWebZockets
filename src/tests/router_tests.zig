const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const support = @import("test_support");
const app = support.app;
const config_module = support.config;
const radix = support.radix;
const Request = support.http_request.Request;
const Response = support.http_response.Response;
const AsyncResponseState = support.http_response.AsyncResponseState;

// dummy handler to verify route routing
fn dummy_handler(req: *Request, res: *Response) void {
    _ = req;
    _ = res;
}

fn exact_handler(_: *Request, _: *Response) void {}

/// Counts open descriptors through /proc; null when the platform has no procfs.
fn open_fd_count() ?usize {
    var dir = std.Io.Dir.openDirAbsolute(
        std.testing.io,
        "/proc/self/fd",
        .{ .iterate = true },
    ) catch return null;
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (iterator.next(std.testing.io) catch return null) |_| count += 1;
    return count;
}

const ResponseSink = struct {
    end_count: usize = 0,
    wake_count: usize = 0,

    fn end(
        context: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) !void {
        const self: *ResponseSink = @ptrCast(@alignCast(context));
        self.end_count += 1;
    }

    fn begin(_: *anyopaque, _: []const u8, _: []const u8) !void {}
    fn write(_: *anyopaque, _: []const u8) !void {}
    fn finish(_: *anyopaque) !void {}

    fn wake(context: *anyopaque) void {
        const self: *ResponseSink = @ptrCast(@alignCast(context));
        self.wake_count += 1;
    }

    fn response(self: *ResponseSink) Response {
        return .{ .target = .{ .http3 = .{
            .context = self,
            .end_fn = end,
            .begin_fn = begin,
            .write_fn = write,
            .finish_fn = finish,
        } } };
    }
};

const MiddlewareContext = struct {
    order: *[4]u8,
    count: *usize,
    id: u8,
    stop: bool = false,

    fn run(context: *anyopaque, _: *Request, response: *Response) radix.MiddlewareResult {
        const self: *MiddlewareContext = @ptrCast(@alignCast(context));
        self.order[self.count.*] = self.id;
        self.count.* += 1;
        if (!self.stop) return .continue_dispatch;
        response.end("204 No Content", "") catch @panic("test fixture response failed");
        return .stop;
    }
};

const HandlerContext = struct {
    called: bool = false,

    fn handle(context: *anyopaque, _: *Request, _: *Response) void {
        const self: *HandlerContext = @ptrCast(@alignCast(context));
        self.called = true;
    }
};

fn deferred_handler(_: *Request, _: support.http_response.AsyncResponse) void {}

// tests radix trie insertion and exact matching
test "router: radix trie exact match" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());

    try router.get("/api/v1/users", dummy_handler);
    try router.post("/api/v1/users", dummy_handler);
    try router.get("/api/v1/posts", dummy_handler);
    try router.ws("/chat", .{});

    const r1 = router.match("/api/v1/users", .get);
    try std.testing.expect(r1 != null);
    try std.testing.expect(r1.?.http_handler != null);

    const r2 = router.match("/api/v1/posts", .get);
    try std.testing.expect(r2 != null);

    const r3 = router.match("/chat", .get);
    try std.testing.expect(r3 != null);
    try std.testing.expect(r3.?.ws_behavior != null);

    const r4 = router.match("/notfound", .get);
    try std.testing.expect(r4 == null);

    const method_mismatch = router.match("/api/v1/posts", .post).?;
    try std.testing.expect(method_mismatch.http_handler == null);

    var allow_buffer: [64]u8 = undefined;
    const allow = try radix.format_allowed_methods(method_mismatch.allowed_methods, &allow_buffer);
    try std.testing.expectEqualStrings("GET, HEAD", allow);
}

test "router: RFC 10008 QUERY is routed as a safe body-bearing method" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.query("/search", dummy_handler);

    try std.testing.expectEqual(radix.HttpMethod.query, radix.HttpMethod.parse("QUERY").?);
    try std.testing.expectEqualStrings("QUERY", radix.HttpMethod.query.name());

    const match = router.match("/search", .query).?;
    try std.testing.expect(match.http_handler != null);
    var allow_buffer: [96]u8 = undefined;
    const allow = try radix.format_allowed_methods(match.allowed_methods, &allow_buffer);
    try std.testing.expectEqualStrings("QUERY", allow);
}

test "router: ANY advertises every concrete method including QUERY" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.any("/resource", dummy_handler);

    const match = router.match("/resource", .query).?;
    var allow_buffer: [96]u8 = undefined;
    const allow = try radix.format_allowed_methods(match.allowed_methods, &allow_buffer);
    try std.testing.expectEqualStrings(
        "GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, QUERY",
        allow,
    );
}

test "router: registration copies exact and parameterized paths" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var exact_path = "/owned".*;
    var pattern_path = "/users/:id".*;
    try router.get(&exact_path, dummy_handler);
    try router.get(&pattern_path, dummy_handler);

    @memset(&exact_path, 'x');
    @memset(&pattern_path, 'x');

    try std.testing.expect(router.match("/owned", .get).?.http_handler != null);
    var request = Request{ .path = "/users/42" };
    try std.testing.expect(router.match_request(&request, .get).?.http_handler != null);
    try std.testing.expectEqualStrings("42", request.get_param("id").?);
}

test "router: application timeout policy is compile-time configurable" {
    const WithoutIdleTimeout = app.configured_app_with_timeout(1, 1024, 4096, 0);
    const WithShortIdleTimeout = app.configured_app_with_timeout(1, 1024, 4096, 1000);

    _ = WithoutIdleTimeout;
    _ = WithShortIdleTimeout;
    try std.testing.expectEqual(@as(u64, 120_000), app.default_idle_timeout_ms);
}

test "router: websocket limits must fit the configured slab" {
    try std.testing.expect(radix.valid_ws_limits(.{}, 16 * 1024));
    try std.testing.expect(!radix.valid_ws_limits(.{ .max_frame_size = 0 }, 16 * 1024));
    try std.testing.expect(!radix.valid_ws_limits(.{ .max_message_size = 32 * 1024 }, 16 * 1024));
    try std.testing.expect(!radix.valid_ws_limits(.{
        .max_frame_size = 1024,
        .max_message_size = 512,
    }, 16 * 1024));
}

test "router: compression scratch separates receive and send state" {
    var storage = [_]u8{0} ** 32;
    const buffers = app.compression_buffers(&storage, 8, 1) orelse {
        return error.TestUnexpectedResult;
    };

    @memset(buffers.incoming, 0xa5);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 8), buffers.incoming);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), buffers.outgoing);
    try std.testing.expect(app.compression_buffers(&storage, 8, 2) == null);
}

test "router: route registration locks before callbacks can observe mutation" {
    const TestApp = app.app(1);
    var server = try TestApp.init(std.testing.io);
    defer server.deinit();
    server.routes_locked = true;

    try std.testing.expectError(error.RoutesLocked, server.get("/", dummy_handler));
}

test "router: application route capacities follow the configuration" {
    const TestApp = app.app(1);
    const raised = comptime config_module.default_config.with(.{
        .max_connections = 1,
        .max_route_nodes = 320,
        .max_pattern_routes = 70,
        .max_middleware = 40,
        .max_route_path_size = 4096,
    });
    var server = try TestApp.init_configured(std.testing.io, std.testing.allocator, raised);
    defer server.deinit();

    try std.testing.expectEqual(@as(usize, 320), server.router_storage.segment_offsets.len);
    try std.testing.expectEqual(@as(usize, 70), server.router_storage.pattern_routes.len);
    try std.testing.expectEqual(@as(usize, 40), server.router_storage.middleware.len);
    try std.testing.expectEqual(@as(usize, 4096), server.router_storage.max_route_path_size);

    var middleware_context: u8 = 0;
    for (0..40) |_| _ = try server.use(&middleware_context, MiddlewareContext.run);
    try std.testing.expectEqual(@as(u8, 40), server.router.middleware_count);

    var pattern_name: [32]u8 = undefined;
    for (0..70) |index| {
        const path = try std.fmt.bufPrint(&pattern_name, "/p{d}/:id", .{index});
        _ = try server.get(path, dummy_handler);
    }
    try std.testing.expectEqual(@as(u8, 70), server.router.pattern_count);

    // The default node cap is 256; 300 exact routes exceed it.
    var exact_name: [32]u8 = undefined;
    for (0..300) |index| {
        const path = try std.fmt.bufPrint(&exact_name, "/r{d}", .{index});
        _ = try server.get(path, dummy_handler);
    }
    try std.testing.expect(server.router.node_count > 256);

    // 2049 bytes exceeds the default route path cap of 2048.
    var long_path: [2049]u8 = undefined;
    @memset(&long_path, 'a');
    long_path[0] = '/';
    _ = try server.get(&long_path, dummy_handler);

    const limited_config = comptime config_module.default_config.with(.{
        .max_connections = 1,
        .max_route_nodes = 4,
        .max_pattern_routes = 1,
        .max_middleware = 2,
        .max_route_path_size = 16,
        .max_route_registry_size = 16,
    });
    var limited = try TestApp.init_configured(std.testing.io, std.testing.allocator, limited_config);
    defer limited.deinit();

    var limited_context: u8 = 0;
    _ = try limited.use(&limited_context, MiddlewareContext.run);
    _ = try limited.use(&limited_context, MiddlewareContext.run);
    try std.testing.expectError(
        error.MiddlewareCapacityReached,
        limited.use(&limited_context, MiddlewareContext.run),
    );

    _ = try limited.get("/p/:id", dummy_handler);
    try std.testing.expectError(
        error.RouteCapacityReached,
        limited.get("/q/:id", dummy_handler),
    );

    // Root plus the shared slash segment and two leaves fill four nodes.
    _ = try limited.get("/a", dummy_handler);
    _ = try limited.get("/b", dummy_handler);
    try std.testing.expectError(
        error.RouteCapacityReached,
        limited.get("/c", dummy_handler),
    );

    var fits: [16]u8 = undefined;
    @memset(&fits, 'x');
    fits[0] = '/';
    var over: [17]u8 = undefined;
    @memcpy(over[0..16], &fits);
    over[16] = 'x';
    try std.testing.expectError(error.InvalidRoutePath, limited.get(&over, dummy_handler));
}

test "router: ephemeral TLS applications size their contexts" {
    const TestApp = app.app(1);
    var server = try TestApp.init_https_ephemeral(std.testing.io);
    defer server.deinit();
    try std.testing.expect(server.tls_ctx != null);
}

test "router: callback shutdown is drained by the active outer run" {
    const TestApp = app.configured_app_with_timeout(1, 1024, 4096, 0);
    const Probe = struct {
        server: *TestApp,
        timer: xev.Timer,
        completion: xev.Completion = .{},
        callback_called: bool = false,
        observed_running: bool = false,
        shutdown_error: ?anyerror = null,

        fn route(context: *anyopaque, _: *Request, _: *Response) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.callback_called = true;
            self.observed_running = self.server.is_running();
            self.server.shutdown() catch |err| {
                self.shutdown_error = err;
            };
        }

        fn fire(
            user_data: ?*@This(),
            _: *xev.Loop,
            _: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                self.shutdown_error = err;
                return .disarm;
            };

            var request = Request{ .path = "/shutdown" };
            const matched = self.server.router.match_request(&request, .get) orelse {
                self.shutdown_error = error.RouteMissing;
                return .disarm;
            };
            var sink = ResponseSink{};
            var response = sink.response();
            switch (matched.handler orelse {
                self.shutdown_error = error.HandlerMissing;
                return .disarm;
            }) {
                .contextual => |binding| binding.callback(binding.context, &request, &response),
                else => self.shutdown_error = error.UnexpectedHandler,
            }
            return .disarm;
        }
    };

    var server = try TestApp.init(std.testing.io);
    defer server.deinit();
    var probe = Probe{
        .server = &server,
        .timer = try xev.Timer.init(),
    };
    defer probe.timer.deinit();

    _ = try server.route_context(.get, "/shutdown", &probe, Probe.route);
    probe.timer.run(
        server.loop.get_xev_loop(),
        &probe.completion,
        1,
        Probe,
        &probe,
        Probe.fire,
    );

    try server.run();
    try std.testing.expect(probe.callback_called);
    try std.testing.expect(probe.observed_running);
    try std.testing.expect(probe.shutdown_error == null);
    try std.testing.expect(server.shutting_down);
    try std.testing.expect(!server.is_running());
}

test "router: request_shutdown wakes a foreign-thread run" {
    const TestApp = app.configured_app_with_timeout(1, 1024, 4096, 0);
    var server = try TestApp.init(std.testing.io);
    defer server.deinit();

    const Latch = struct {
        fired: std.atomic.Value(bool) = .init(false),
        error_code: ?anyerror = null,

        fn timer(
            user_data: ?*@This(),
            _: *xev.Loop,
            _: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;
            user_data.?.fired.store(true, .release);
            return .disarm;
        }

        fn run(self: *@This(), application: *TestApp) void {
            application.run() catch |err| {
                self.error_code = err;
            };
        }
    };

    var latch = Latch{};
    var timer = try xev.Timer.init();
    defer timer.deinit();
    var completion: xev.Completion = .{};
    timer.run(
        server.loop.get_xev_loop(),
        &completion,
        1,
        Latch,
        &latch,
        Latch.timer,
    );

    const thread = try std.Thread.spawn(.{}, Latch.run, .{ &latch, &server });
    var spins: usize = 0;
    while (!latch.fired.load(.acquire) and spins < 5_000) : (spins += 1) {
        try std.Io.sleep(std.testing.io, .{ .nanoseconds = std.time.ns_per_ms }, .awake);
    }

    server.request_shutdown();
    thread.join();

    try std.testing.expect(latch.fired.load(.acquire));
    try std.testing.expect(latch.error_code == null);
    try std.testing.expect(server.shutting_down);
    try std.testing.expect(!server.is_running());
}

test "router: failed metrics install leaves no listener resources" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const TestApp = app.configured_app_with_timeout(1, 1024, 4096, 120_000);
    const metrics_config = comptime config_module.default_config.with(.{
        .max_connections = 1,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 120_000,
        .observability = true,
        .enable_dev_log = false,
    });
    var server = try TestApp.init_configured(std.testing.io, std.testing.allocator, metrics_config);
    defer server.deinit();

    _ = try server.get("/metrics", dummy_handler);
    const before = open_fd_count() orelse return error.SkipZigTest;
    for (0..16) |_| {
        try std.testing.expectError(
            error.RouteAlreadyRegistered,
            server.listen("127.0.0.1", 0),
        );
    }
    const after = open_fd_count() orelse return error.SkipZigTest;

    // The failed install must not strand the listener or sweeper timer.
    try std.testing.expectEqual(before, after);
    try std.testing.expect(server.server == null);
    try std.testing.expect(server.sweeper == null);
    try std.testing.expect(!server.routes_locked);
}

test "router: cluster workers install the observability route" {
    const TestApp = app.configured_app_with_timeout(2, 1024, 4096, 0);
    const cluster_config = comptime config_module.default_config.with(.{
        .max_connections = 2,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
        .observability = true,
        .enable_dev_log = false,
    });
    var group = try TestApp.cluster(2).init_with_options(
        std.testing.allocator,
        std.testing.io,
        cluster_config,
        .{ .cpu_affinity = false },
    );
    defer group.deinit();

    try group.listen("127.0.0.1", 0);
    for (0..2) |index| {
        const worker = group.worker(index) orelse return error.TestUnexpectedResult;
        try std.testing.expect(worker.metrics() != null);
        try std.testing.expect(worker.metrics_installed);
        try std.testing.expect(worker.router.match("/metrics", .get) != null);
    }
}

test "router: exact route wins before bounded parameter patterns" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.get("/users/:id", dummy_handler);
    try router.get("/users/new", exact_handler);
    try router.get("/assets/*path", dummy_handler);

    var request = Request{ .path = "/users/42" };
    const parameterized = router.match_request(&request, .get).?;
    try std.testing.expect(parameterized.http_handler != null);
    try std.testing.expectEqualStrings("42", request.get_param("id").?);

    request.path = "/users/new";
    const exact = router.match_request(&request, .get).?;
    try std.testing.expectEqual(@intFromPtr(&exact_handler), @intFromPtr(exact.http_handler.?));
    try std.testing.expectEqual(@as(usize, 0), request.route_param_count);

    request.path = "/assets/css/site.css";
    _ = router.match_request(&request, .get).?;
    try std.testing.expectEqualStrings("css/site.css", request.get_param("path").?);

    request.path = "/assets";
    _ = router.match_request(&request, .get).?;
    try std.testing.expectEqualStrings("", request.get_param("path").?);
}

test "router: static index resolves exact routes with identical match data" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.get("/httpz", dummy_handler);
    try router.get("/api/users", exact_handler);
    try router.ws("/socket", .{});

    // The default index rounds twice the 256-node capacity to 512 slots.
    try std.testing.expectEqual(@as(usize, 512), router.static_nodes.len);

    var allow_buffer: [64]u8 = undefined;
    const page = router.match("/httpz", .get).?;
    try std.testing.expectEqual(@intFromPtr(&dummy_handler), @intFromPtr(page.http_handler.?));
    try std.testing.expect(page.has_http);
    try std.testing.expect(page.ws_behavior == null);
    try std.testing.expectEqualStrings(
        "GET, HEAD",
        try radix.format_allowed_methods(page.allowed_methods, &allow_buffer),
    );

    // A method mismatch still resolves the node so the caller can answer 405.
    const users = router.match("/api/users", .post).?;
    try std.testing.expect(users.http_handler == null);
    try std.testing.expect(users.has_http);

    const socket = router.match("/socket", .get).?;
    try std.testing.expect(socket.ws_behavior != null);
    try std.testing.expect(!socket.has_http);
    try std.testing.expectEqualStrings(
        "GET",
        try radix.format_allowed_methods(socket.allowed_methods, &allow_buffer),
    );
}

test "router: static index follows a route moved by a split" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.get("/alpha", dummy_handler);
    // Inserting a shorter shared prefix splits "/alpha" and moves its route
    // to the new leaf, which must keep resolving through the index.
    try router.get("/alp", exact_handler);

    const alpha = router.match("/alpha", .get).?;
    try std.testing.expectEqual(@intFromPtr(&dummy_handler), @intFromPtr(alpha.http_handler.?));
    const alp = router.match("/alp", .get).?;
    try std.testing.expectEqual(@intFromPtr(&exact_handler), @intFromPtr(alp.http_handler.?));

    // A deeper registration after the split must not disturb either route.
    try router.get("/alpine", exact_handler);
    const alpine = router.match("/alpine", .get).?;
    try std.testing.expectEqual(@intFromPtr(&exact_handler), @intFromPtr(alpine.http_handler.?));
    const alpha_again = router.match("/alpha", .get).?;
    try std.testing.expectEqual(@intFromPtr(&dummy_handler), @intFromPtr(alpha_again.http_handler.?));
}

test "router: static index preserves duplicate registration errors" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.get("/dup", dummy_handler);
    try std.testing.expectError(
        error.RouteAlreadyRegistered,
        router.get("/dup", exact_handler),
    );
    try router.ws("/dup", .{});
    try std.testing.expectError(
        error.RouteAlreadyRegistered,
        router.ws("/dup", .{}),
    );

    const match = router.match("/dup", .get).?;
    try std.testing.expectEqual(@intFromPtr(&dummy_handler), @intFromPtr(match.http_handler.?));
    try std.testing.expect(match.ws_behavior != null);

    // Both methods share one indexed terminal node, so the table holds one
    // entry and the failed duplicates did not grow it.
    var entries: usize = 0;
    for (router.static_nodes) |node| {
        if (node != std.math.maxInt(u16)) entries += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
}

test "router: static index probes slot collisions without false matches" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    const mask = router.static_nodes.len - 1;

    var hashes: [256]u64 = undefined;
    var path_buffer: [32]u8 = undefined;
    for (0..hashes.len) |candidate| {
        const path = try std.fmt.bufPrint(&path_buffer, "/collide/{d}", .{candidate});
        hashes[candidate] = radix.hash_path(path);
    }

    // Find two distinct paths that share a first probe slot.
    var first: usize = 0;
    var second: usize = 0;
    var found = false;
    outer: for (0..hashes.len) |left| {
        for (left + 1..hashes.len) |right| {
            if (hashes[left] & mask != hashes[right] & mask) continue;
            first = left;
            second = right;
            found = true;
            break :outer;
        }
    }
    try std.testing.expect(found);

    var first_path: [32]u8 = undefined;
    var second_path: [32]u8 = undefined;
    const first_bytes = try std.fmt.bufPrint(&first_path, "/collide/{d}", .{first});
    const second_bytes = try std.fmt.bufPrint(&second_path, "/collide/{d}", .{second});
    try router.get(first_bytes, dummy_handler);
    try router.get(second_bytes, exact_handler);

    const first_match = router.match(first_bytes, .get).?;
    try std.testing.expectEqual(
        @intFromPtr(&dummy_handler),
        @intFromPtr(first_match.http_handler.?),
    );
    const second_match = router.match(second_bytes, .get).?;
    try std.testing.expectEqual(
        @intFromPtr(&exact_handler),
        @intFromPtr(second_match.http_handler.?),
    );
}

test "router: static index size derives from the node capacity" {
    const capacities = radix.Capacities{
        .max_nodes = 5,
        .max_pattern_routes = 1,
        .max_middleware = 2,
        .max_route_path_size = 64,
        .registry_storage_size = 256,
    };
    var bundle = radix.Bundle(capacities){};
    var router = try radix.Router.init(bundle.storage());
    // Twice five rounds up to the sixteen-slot floor.
    try std.testing.expectEqual(@as(usize, 16), router.static_hashes.len);
    try std.testing.expectEqual(@as(usize, 16), router.static_nodes.len);
    try std.testing.expectEqual(@as(usize, 5), router.parents.len);

    try router.get("/a", dummy_handler);
    try router.get("/b", dummy_handler);
    try router.get("/c", dummy_handler);
    try std.testing.expectError(
        error.RouteCapacityReached,
        router.get("/d", dummy_handler),
    );
}

test "router: route patterns fail closed when malformed or over capacity" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try std.testing.expectError(
        error.InvalidRoutePattern,
        router.get("/files/*path/more", dummy_handler),
    );
    try std.testing.expectError(
        error.InvalidRoutePattern,
        router.get("/users/:id/posts/:id", dummy_handler),
    );
    try std.testing.expectError(
        error.RouteParameterCapacityReached,
        router.get(
            "/:a/:b/:c/:d/:e/:f/:g/:h/:i/:j/:k/:l/:m/:n/:o/:p/:q",
            dummy_handler,
        ),
    );
}

test "router: conflicting parameterized patterns fail registration" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    try router.get("/users/:id", dummy_handler);
    try std.testing.expectError(
        error.RoutePatternConflicts,
        router.post("/users/:name", dummy_handler),
    );
    // The original pattern stays reachable and still accepts new methods.
    try router.post("/users/:id", dummy_handler);
    var request = Request{ .path = "/users/42" };
    const match = router.match_request(&request, .post) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(match.http_handler != null);

    // Shapes that differ at any literal position remain distinct.
    try router.get("/a/:x/b", dummy_handler);
    try router.get("/a/b/:x", dummy_handler);
    try std.testing.expectEqual(@as(u8, 3), router.pattern_count);
}

test "router: wide patterns register and match with configured captures" {
    const wide_pattern = "/:p0/:p1/:p2/:p3/:p4/:p5/:p6/:p7/:p8/:p9/:p10/:p11/:p12/:p13/:p14/:p15/:p16/:p17/:p18/:p19";
    const wide_path = "/a0/a1/a2/a3/a4/a5/a6/a7/a8/a9/a10/a11/a12/a13/a14/a15/a16/a17/a18/a19";

    const capacities = radix.Capacities{ .max_route_params = 20 };
    var bundle = radix.Bundle(capacities){};
    var router = try radix.Router.init(bundle.storage());
    try router.get(wide_pattern, dummy_handler);

    var request = Request{ .path = wide_path };
    var extra_names: [4][]const u8 = undefined;
    var extra_values: [4][]const u8 = undefined;
    request.extra_param_names = &extra_names;
    request.extra_param_values = &extra_values;
    try std.testing.expect(router.match_request(&request, .get) != null);
    try std.testing.expectEqual(@as(usize, 16), request.route_param_count);
    try std.testing.expectEqual(@as(usize, 4), request.extra_param_count);
    for (0..20) |index| {
        var name_buffer: [8]u8 = undefined;
        var value_buffer: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "p{d}", .{index});
        const value = try std.fmt.bufPrint(&value_buffer, "a{d}", .{index});
        try std.testing.expectEqualStrings(value, request.get_param(name).?);
    }

    // The default router rejects the same pattern at registration.
    var default_bundle = radix.DefaultBundle{};
    var default_router = try radix.Router.init(default_bundle.storage());
    try std.testing.expectError(
        error.RouteParameterCapacityReached,
        default_router.get(wide_pattern, dummy_handler),
    );

    // A second match after clearing must not leak the first match's captures.
    try router.get("/:only", dummy_handler);
    request.path = "/z";
    try std.testing.expect(router.match_request(&request, .get) != null);
    try std.testing.expectEqual(@as(usize, 0), request.extra_param_count);
    try std.testing.expect(request.get_param("p19") == null);
    try std.testing.expectEqualStrings("z", request.get_param("only").?);
}

test "router: middleware runs in order and stops after a response" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var order = [_]u8{0} ** 4;
    var count: usize = 0;
    var first = MiddlewareContext{ .order = &order, .count = &count, .id = 1 };
    var second = MiddlewareContext{ .order = &order, .count = &count, .id = 2, .stop = true };
    var third = MiddlewareContext{ .order = &order, .count = &count, .id = 3 };
    try router.use(&first, MiddlewareContext.run);
    try router.use(&second, MiddlewareContext.run);
    try router.use(&third, MiddlewareContext.run);

    var sink = ResponseSink{};
    var response = sink.response();
    var request = Request{};
    try std.testing.expectEqual(
        radix.MiddlewareResult.stop,
        router.run_middleware(&request, &response),
    );
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, order[0..count]);
    try std.testing.expectEqual(@as(usize, 1), sink.end_count);
}

test "router: middleware and route tables enforce configured capacities" {
    const capacities = radix.Capacities{ .max_middleware = 2 };
    var bundle = radix.Bundle(capacities){};
    var router = try radix.Router.init(bundle.storage());
    var context: u8 = 0;
    for (0..capacities.max_middleware) |_| {
        try router.use(&context, MiddlewareContext.run);
    }
    try std.testing.expectError(
        error.MiddlewareCapacityReached,
        router.use(&context, MiddlewareContext.run),
    );
    // The compatibility alias still states the default cap.
    try std.testing.expectEqual(@as(usize, 32), radix.max_middleware);
}

test "router: contextual and async handlers preserve legacy sync ABI" {
    var bundle = radix.DefaultBundle{};
    var router = try radix.Router.init(bundle.storage());
    var context = HandlerContext{};
    try router.route_context(.get, "/context", &context, HandlerContext.handle);
    try router.route_async(.get, "/deferred/:id", deferred_handler);
    try router.get("/sync", dummy_handler);

    var request = Request{ .path = "/context" };
    const contextual = router.match_request(&request, .get).?;
    try std.testing.expect(contextual.http_handler == null);
    switch (contextual.handler.?) {
        .contextual => |binding| {
            var sink = ResponseSink{};
            var response = sink.response();
            binding.callback(binding.context, &request, &response);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(context.called);

    request.path = "/deferred/7";
    const deferred = router.match_request(&request, .get).?;
    try std.testing.expect(deferred.http_handler == null);
    try std.testing.expect(deferred.handler.? == .asynchronous);

    request.path = "/sync";
    const synchronous = router.match_request(&request, .get).?;
    try std.testing.expect(synchronous.http_handler != null);
}

fn expect_aligned(comptime T: type, slice: []const T) !void {
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(slice.ptr) % @alignOf(T));
}

test "router: configured capacities size storage and route counts" {
    const capacities = radix.Capacities{
        .max_nodes = 5,
        .max_pattern_routes = 1,
        .max_middleware = 2,
        .max_route_path_size = 64,
        .registry_storage_size = 256,
    };
    try std.testing.expectEqual(@as(usize, 6), capacities.max_registered_routes());

    const bytes = try capacities.storage_bytes();
    const region = try std.testing.allocator.alloc(u8, bytes + 8);
    defer std.testing.allocator.free(region);
    const storage = try radix.carve_storage(region, capacities);
    var router = try radix.Router.init(storage);

    try std.testing.expectEqual(@as(usize, 5), router.segment_offsets.len);
    try std.testing.expectEqual(@as(usize, 1), router.pattern_routes.len);
    try std.testing.expectEqual(@as(usize, 2), router.middleware.len);
    try std.testing.expectEqual(@as(usize, 6), router.route_records.len);
    try std.testing.expectEqual(@as(usize, 64), router.max_route_path_size);
    // Twice five nodes rounds up to the sixteen-slot index floor.
    try std.testing.expectEqual(@as(usize, 16), router.static_nodes.len);
    try std.testing.expectEqual(@as(usize, 5), router.parents.len);

    var context: u8 = 0;
    try router.use(&context, MiddlewareContext.run);
    try router.use(&context, MiddlewareContext.run);
    try std.testing.expectError(
        error.MiddlewareCapacityReached,
        router.use(&context, MiddlewareContext.run),
    );

    try router.get("/p/:id", dummy_handler);
    try std.testing.expectError(
        error.RouteCapacityReached,
        router.get("/q/:id", dummy_handler),
    );

    // Three exact routes fill the five configured nodes (root, the shared
    // slash segment, and one leaf per route).
    try router.get("/a", dummy_handler);
    try router.get("/b", dummy_handler);
    try router.get("/c", dummy_handler);
    try std.testing.expectError(
        error.RouteCapacityReached,
        router.get("/d", dummy_handler),
    );
    try std.testing.expectEqual(@as(u16, 4), router.route_record_count);

    try std.testing.expectError(
        error.InvalidRouterCapacity,
        (radix.Capacities{ .max_nodes = 0 }).storage_bytes(),
    );
    try std.testing.expectError(
        error.InvalidRouterCapacity,
        (radix.Capacities{ .max_route_path_size = 0 }).storage_bytes(),
    );
    try std.testing.expectError(
        error.InvalidRouterCapacity,
        (radix.Capacities{ .registry_storage_size = 0 }).storage_bytes(),
    );
}

test "router: carve_storage honors alignment and storage_bytes" {
    const cases = [_]radix.Capacities{
        .{
            .max_nodes = 4,
            .max_pattern_routes = 1,
            .max_middleware = 2,
            .max_route_path_size = 64,
            .registry_storage_size = 64,
        },
        .{
            .max_nodes = 17,
            .max_pattern_routes = 3,
            .max_middleware = 5,
            .max_route_path_size = 32,
            .registry_storage_size = 128,
        },
        .{
            .max_nodes = 128,
            .max_pattern_routes = 16,
            .max_middleware = 8,
            .max_route_path_size = 16,
            .registry_storage_size = 256,
        },
    };
    const method_slots = @typeInfo(radix.HttpMethod).@"enum".fields.len;
    for (cases) |capacities| {
        const bytes = try capacities.storage_bytes();
        var backing: [68 * 1024]u8 align(@alignOf(radix.Storage)) = undefined;
        try std.testing.expect(bytes + 16 <= backing.len);

        // Carving starts at an odd base; carve_storage pads to alignment.
        const region = backing[1 .. 1 + bytes + 8];
        const storage = try radix.carve_storage(region, capacities);
        try std.testing.expectEqual(capacities.max_route_path_size, storage.max_route_path_size);

        try expect_aligned(u32, storage.segment_offsets);
        try expect_aligned(u16, storage.segment_lengths);
        try expect_aligned(u16, storage.first_child);
        try expect_aligned(u16, storage.next_sibling);
        try expect_aligned(bool, storage.has_route);
        try expect_aligned([method_slots]?radix.RouteHandler, storage.http_handlers);
        try expect_aligned(?radix.WsBehavior, storage.ws_behaviors);
        try expect_aligned(radix.PatternRoute, storage.pattern_routes);
        try expect_aligned(u32, storage.pattern_offsets);
        try expect_aligned(u16, storage.pattern_lengths);
        try expect_aligned(radix.MiddlewareEntry, storage.middleware);
        try expect_aligned(radix.RouteRecord, storage.route_records);
        try expect_aligned(u64, storage.static_hashes);
        try expect_aligned(u16, storage.static_nodes);
        try expect_aligned(u16, storage.parents);

        const aligned_base = std.mem.alignForward(usize, @intFromPtr(region.ptr), @alignOf(radix.Storage));
        try std.testing.expectEqual(aligned_base, @intFromPtr(storage.route_storage.ptr));
        const consumed = @intFromPtr(storage.static_hashes.ptr) +
            storage.static_hashes.len * @sizeOf(u64) - aligned_base;
        try std.testing.expectEqual(bytes, consumed);

        // An aligned region of exactly storage_bytes carves without padding.
        const exact = try radix.carve_storage(backing[0..bytes], capacities);
        try expect_aligned(u32, exact.segment_offsets);
        try std.testing.expectEqual(@intFromPtr(&backing), @intFromPtr(exact.route_storage.ptr));
    }
}

test "router: route path capacity is enforced per router" {
    var fits: [16]u8 = undefined;
    @memset(&fits, 'x');
    fits[0] = '/';
    var over: [17]u8 = undefined;
    @memcpy(over[0..16], &fits);
    over[16] = 'x';

    var small_bundle = radix.Bundle(.{
        .max_route_path_size = 16,
        .registry_storage_size = 16,
    }){};
    var small = try radix.Router.init(small_bundle.storage());
    try small.get(&fits, dummy_handler);
    try std.testing.expectError(error.InvalidRoutePath, small.get(&over, dummy_handler));

    var large_bundle = radix.DefaultBundle{};
    var large = try radix.Router.init(large_bundle.storage());
    try large.get(&over, dummy_handler);
}

test "router: async response token is generation checked and one shot" {
    var sink = ResponseSink{};
    var state = AsyncResponseState{};
    const target = support.http_response.AsyncTarget{
        .context = &sink,
        .complete_fn = ResponseSink.end,
        .wake_fn = ResponseSink.wake,
    };

    const first = state.arm(target);
    try first.complete("200 OK", "done");
    try std.testing.expectEqual(@as(usize, 1), sink.end_count);
    try std.testing.expectEqual(@as(usize, 1), sink.wake_count);
    try std.testing.expectError(
        error.AsyncResponseAlreadyCompleted,
        first.complete("200 OK", "again"),
    );

    const second = state.arm(target);
    try std.testing.expectError(
        error.AsyncResponseExpired,
        first.complete("200 OK", "stale"),
    );
    state.cancel();
    try std.testing.expectError(
        error.AsyncResponseExpired,
        second.complete("200 OK", "closed"),
    );
}
