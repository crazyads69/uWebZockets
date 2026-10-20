const std = @import("std");
const builtin = @import("builtin");
const support = @import("test_support");

const affinity = support.affinity;

fn dummy_handler(_: *support.http_request.Request, _: *support.http_response.Response) void {}

test "cluster queue: FIFO order survives wraparound" {
    const Queue = support.cluster.message_queue(32);
    var queue = Queue{};

    var topic_buffer: [64]u8 = undefined;
    var payload_buffer: [64]u8 = undefined;

    for (0..3) |round| {
        for (0..support.cluster.queue_capacity) |index| {
            var payload: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&payload, "round{d}-{d}", .{ round, index }) catch unreachable;
            try queue.push("topic", text, index % 2 == 0);
        }
        for (0..support.cluster.queue_capacity) |index| {
            const message = queue.pop_copy(&topic_buffer, &payload_buffer) orelse
                return error.TestUnexpectedResult;
            var expected: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&expected, "round{d}-{d}", .{ round, index }) catch unreachable;
            try std.testing.expectEqualStrings(text, message.payload);
            try std.testing.expectEqualStrings("topic", message.topic);
            try std.testing.expectEqual(index % 2 == 0, message.is_text);
        }
        try std.testing.expect(queue.pop_copy(&topic_buffer, &payload_buffer) == null);
    }
}

test "cluster queue: bounded producers receive ClusterQueueFull" {
    const Queue = support.cluster.message_queue(16);
    var queue = Queue{};

    for (0..support.cluster.queue_capacity) |_| try queue.push("t", "m", true);
    try std.testing.expectError(error.ClusterQueueFull, queue.push("t", "m", true));
    try std.testing.expectError(error.EmptyTopic, queue.push("", "m", true));
    try std.testing.expectError(error.ClusterMessageTooLarge, queue.push("t", "0123456789abcdefg", false));

    var topic_buffer: [64]u8 = undefined;
    var payload_buffer: [64]u8 = undefined;
    try std.testing.expect(queue.pop_copy(&topic_buffer, &payload_buffer) != null);
    try queue.push("t", "m", true);
}

test "cluster queue: many producers feed one consumer without a lock" {
    const Queue = support.cluster.message_queue(32);
    var queue = Queue{};

    const producers = 4;
    const per_producer = 500;
    const total = producers * per_producer;

    const Producer = struct {
        queue: *Queue,
        index: usize,

        fn run(self: *@This()) void {
            var sequence: usize = 0;
            while (sequence < per_producer) : (sequence += 1) {
                var payload_buffer: [24]u8 = undefined;
                const payload = std.fmt.bufPrint(
                    &payload_buffer,
                    "{d}:{d}",
                    .{ self.index, sequence },
                ) catch unreachable;
                while (true) {
                    self.queue.push("stress", payload, true) catch {
                        std.atomic.spinLoopHint();
                        continue;
                    };
                    break;
                }
            }
        }
    };

    var contexts: [producers]Producer = undefined;
    var threads: [producers]std.Thread = undefined;
    for (&contexts, 0..) |*context, index| {
        context.* = .{ .queue = &queue, .index = index };
        threads[index] = try std.Thread.spawn(.{}, Producer.run, .{context});
    }

    var topic_buffer: [64]u8 = undefined;
    var payload_buffer: [64]u8 = undefined;
    var received: usize = 0;
    while (received < total) {
        if (queue.pop_copy(&topic_buffer, &payload_buffer) != null) {
            received += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }
    for (&threads) |*thread| thread.join();
    try std.testing.expect(queue.pop_copy(&topic_buffer, &payload_buffer) == null);
}

test "affinity: physical cores are discoverable and pinning is best effort" {
    const selection = affinity.CoreSelection.init();
    if (builtin.os.tag == .linux or builtin.os.tag == .windows) {
        try std.testing.expect(selection.len > 0);
        try std.testing.expect(selection.cpu(0) != null);
        try std.testing.expect(selection.cpu(selection.len) != null);
    }

    const PinProbe = struct {
        cpu: usize,
        result: ?affinity.Error = null,

        fn run(self: *@This()) void {
            affinity.pin_current_thread(self.cpu) catch |err| {
                self.result = err;
            };
        }
    };

    var probe = PinProbe{ .cpu = selection.cpu(0) orelse return };
    const thread = try std.Thread.spawn(.{}, PinProbe.run, .{&probe});
    thread.join();
    if (probe.result) |err| {
        try std.testing.expect(err == error.AffinityFailed or err == error.UnsupportedPlatform);
    }
}

test "cluster: runtime worker count stays inside compiled capacity" {
    const TestApp = support.app.configured_app_with_timeout(4, 1024, 4096, 0);
    const test_config = support.config.ServerConfig{
        .max_connections = 4,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
        .max_route_nodes = 8,
        .max_pattern_routes = 4,
        .max_middleware = 2,
    };
    var group = try TestApp.cluster(4).init_with_worker_count(
        std.testing.allocator,
        std.testing.io,
        test_config,
        .{ .cpu_affinity = false },
        2,
    );
    defer group.deinit();

    try std.testing.expect(group.worker(0) != null);
    try std.testing.expect(group.worker(1) != null);
    try std.testing.expect(group.worker(2) == null);
    try std.testing.expectEqual(@as(usize, 2), group.workers.len);
    try std.testing.expectEqual(@as(usize, 2), group.inboxes.len);

    try std.testing.expectEqual(@as(usize, 6), try support.cluster.parse_worker_count("6", 8));
    try std.testing.expectError(
        error.InvalidWorkerCount,
        support.cluster.parse_worker_count("0", 8),
    );
    try std.testing.expectError(
        error.InvalidWorkerCount,
        support.cluster.parse_worker_count("9", 8),
    );
    try std.testing.expectError(
        error.InvalidWorkerCount,
        support.cluster.parse_worker_count("many", 8),
    );
    try std.testing.expect(support.cluster.default_worker_count() > 0);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("UWEBZOCKETS_WORKERS", "3");
    try std.testing.expectEqual(
        @as(usize, 3),
        try support.cluster.worker_count_from_environment(&environ, 8),
    );

    var overflow = std.process.Environ.Map.init(std.testing.allocator);
    defer overflow.deinit();
    try overflow.put("UWEBZOCKETS_WORKERS", "9");
    try std.testing.expectError(
        error.InvalidWorkerCount,
        support.cluster.worker_count_from_environment(&overflow, 8),
    );
}

test "cluster: request_shutdown after deinit is a documented no-op" {
    const TestApp = support.app.configured_app_with_timeout(1, 1024, 4096, 0);
    var group = try TestApp.cluster(1).init(std.testing.allocator, std.testing.io);
    group.deinit();

    // Deinit releases the worker slice. A late supervisor or signal callback
    // must not walk released storage or panic.
    group.request_shutdown();
}

test "cluster: workers own disjoint slabs and configure independently" {
    const TestApp = support.app.configured_app_with_timeout(2, 1024, 4096, 0);
    const test_config = support.config.ServerConfig{
        .max_connections = 2,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
        .max_body_size = 8192,
        .max_route_nodes = 8,
        .max_pattern_routes = 4,
        .max_middleware = 2,
    };
    var group = try TestApp.cluster(2).init_with_options(
        std.testing.allocator,
        std.testing.io,
        test_config,
        .{ .cpu_affinity = false },
    );
    defer group.deinit();

    const first = group.worker(0).?;
    const second = group.worker(1).?;
    try std.testing.expect(first.pool.storage.ptr != second.pool.storage.ptr);
    try std.testing.expect(first.request_buffers.ptr != second.request_buffers.ptr);
    try std.testing.expect(first.write_queue_storage.ptr != second.write_queue_storage.ptr);
    try std.testing.expect(first.loop.get_xev_loop() != second.loop.get_xev_loop());
    // Runtime config reaches every worker, not just the type-level capacities.
    try std.testing.expectEqual(@as(usize, 8192), first.max_body_size);
    try std.testing.expectEqual(@as(usize, 8192), second.max_body_size);

    try group.configure(struct {
        fn routes(worker: *TestApp, index: usize) !void {
            if (index == 0) _ = try worker.get("/first", dummy_handler);
            if (index == 1) _ = try worker.get("/second", dummy_handler);
        }
    }.routes);

    // Configuring routes binds the slab-carved router with the configured capacities.
    try std.testing.expectEqual(@as(usize, 8), first.router.segment_offsets.len);
    try std.testing.expectEqual(@as(usize, 4), first.router.pattern_routes.len);
    try std.testing.expectEqual(@as(usize, 2), first.router.middleware.len);

    try std.testing.expect(group.worker(2) == null);
}
