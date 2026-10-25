const std = @import("std");
const builtin = @import("builtin");
const support = @import("test_support");

const affinity = support.affinity;

fn dummy_handler(_: *support.http_request.Request, _: *support.http_response.Response) void {}

test "cluster queue: FIFO order survives wraparound" {
    const Queue = support.cluster.message_queue(32);
    var queue = Queue{};

    var topic_buffer: [support.ws_pubsub.max_topic_length]u8 = undefined;
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

    var topic_buffer: [support.ws_pubsub.max_topic_length]u8 = undefined;
    var payload_buffer: [64]u8 = undefined;
    try std.testing.expect(queue.pop_copy(&topic_buffer, &payload_buffer) != null);
    try queue.push("t", "m", true);
}

test "cluster queue: short messages fit a 64-byte caller buffer" {
    const Queue = support.cluster.message_queue(16);
    var queue = Queue{};

    try queue.push("t", "m", true);
    var topic_buffer: [64]u8 = undefined;
    var payload_buffer: [64]u8 = undefined;
    const message = queue.pop_copy(&topic_buffer, &payload_buffer).?;
    try std.testing.expectEqualStrings("t", message.topic);
    try std.testing.expectEqualStrings("m", message.payload);
}

test "cluster queue: undersized buffers leave the message queued" {
    const Queue = support.cluster.message_queue(16);
    var queue = Queue{};

    try queue.push("long-topic-name", "payload", true);
    var small_topic: [8]u8 = undefined;
    var small_payload: [4]u8 = undefined;
    var payload_buffer: [64]u8 = undefined;
    try std.testing.expect(queue.pop_copy(&small_topic, &payload_buffer) == null);

    var topic_buffer: [support.ws_pubsub.max_topic_length]u8 = undefined;
    try std.testing.expect(queue.pop_copy(&topic_buffer, &small_payload) == null);
    const message = queue.pop_copy(&topic_buffer, &payload_buffer).?;
    try std.testing.expectEqualStrings("long-topic-name", message.topic);
    try std.testing.expectEqualStrings("payload", message.payload);
}

test "cluster queue: scratch pop borrows queue storage" {
    const Queue = support.cluster.message_queue(16);
    var queue = Queue{};

    try queue.push("topic", "payload", true);
    const message = queue.pop_scratch().?;
    try std.testing.expectEqualStrings("topic", message.topic);
    try std.testing.expectEqualStrings("payload", message.payload);
    try std.testing.expect(message.is_text);
    try std.testing.expect(queue.pop_scratch() == null);
}

test "cluster queue: broadcast counts drops and wakeup failures" {
    const Queue = support.cluster.message_queue(16);
    var queues: [2]Queue = .{ .{}, .{} };
    for (0..support.cluster.queue_capacity) |_| try queues[0].push("t", "m", true);

    const Notify = struct {
        fn call(_: *anyopaque, index: usize) bool {
            return index != 1;
        }
    };
    const report = try Queue.broadcast(
        &queues,
        "t",
        "m",
        true,
        undefined,
        Notify.call,
    );
    try std.testing.expectEqual(@as(usize, 1), report.queued);
    try std.testing.expectEqual(@as(usize, 1), report.dropped);
    try std.testing.expectEqual(@as(usize, 1), report.notify_failed);
    try std.testing.expectEqual(@as(usize, 0), report.first_dropped_worker.?);
    try std.testing.expectEqual(@as(usize, 2), report.attempted());
    try std.testing.expect(!report.all_delivered());
    try std.testing.expect(queues[1].pop_scratch() != null);
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

    var topic_buffer: [support.ws_pubsub.max_topic_length]u8 = undefined;
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

test "worker group: starts bounded workers and joins" {
    const Counter = struct {
        seen: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn run(self: *@This(), _: usize) void {
            _ = self.seen.fetchAdd(1, .monotonic);
        }
    };
    const Group = support.worker_group.worker_group(Counter);

    var group: Group = .{};
    var threads: [4]std.Thread = undefined;
    var counter = Counter{};
    try group.begin_run();

    try std.testing.expectError(
        error.InvalidWorkerCount,
        group.start(&threads, 0, &counter, Counter.run),
    );
    try std.testing.expectError(
        error.InvalidWorkerCount,
        group.start(&threads, 5, &counter, Counter.run),
    );

    try group.start(&threads, 3, &counter, Counter.run);
    try std.testing.expectEqual(@as(usize, 3), group.started_count());
    try std.testing.expectError(
        error.WorkerGroupAlreadyRunning,
        group.start(&threads, 1, &counter, Counter.run),
    );

    group.join(&threads);
    group.finish_run();
    try std.testing.expectEqual(@as(usize, 0), group.started_count());
    try std.testing.expectEqual(@as(usize, 3), counter.seen.load(.acquire));
    try std.testing.expect(group.failure() == null);
    try std.testing.expectEqual(support.worker_group.Lifecycle.stopped, group.state());
}

test "worker group: partial spawn records phase and index" {
    const Context = struct {};
    const Group = support.worker_group.worker_group(Context);
    const Spawner = struct {
        fn spawn(_: *Context, index: usize, _: Group.StartCallback) std.Thread.SpawnError!std.Thread {
            if (index == 0) return std.Thread.spawn(.{}, noop, .{});
            return error.SystemResources;
        }

        fn noop() void {}
    };
    const Callback = struct {
        fn run(_: *Context, _: usize) void {}
    };

    var group: Group = .{};
    var threads: [2]std.Thread = undefined;
    var context = Context{};
    group.spawn_override = Spawner.spawn;
    try group.begin_run();

    try std.testing.expectError(
        error.SystemResources,
        group.start(&threads, 2, &context, Callback.run),
    );
    try std.testing.expectEqual(@as(usize, 1), group.started_count());
    const failure = group.failure().?;
    try std.testing.expectEqual(@as(usize, 1), failure.index);
    try std.testing.expectEqual(support.worker_group.FailurePhase.spawn, failure.phase);
    try std.testing.expect(failure.err == error.SystemResources);

    group.join(&threads);
    group.finish_run();
}

test "worker group: first failure is retained" {
    const Context = struct {};
    const Group = support.worker_group.worker_group(Context);

    var group: Group = .{};

    group.record_failure(3, .run, error.Exploded);
    group.record_failure(4, .spawn, error.OtherFailure);
    group.record_failure(5, .cleanup, error.CleanupFailure);

    const failure = group.failure().?;
    try std.testing.expectEqual(@as(usize, 3), failure.index);
    try std.testing.expectEqual(support.worker_group.FailurePhase.run, failure.phase);
    try std.testing.expect(failure.err == error.Exploded);
    try std.testing.expectEqual(@as(usize, 3), group.failure_count());
}

test "worker group: lifecycle transitions claim once" {
    const Context = struct {};
    const Group = support.worker_group.worker_group(Context);
    var group: Group = .{};

    try group.require_configured();
    try group.begin_run();
    try std.testing.expectError(error.ClusterRunning, group.begin_run());
    try std.testing.expectError(error.ClusterRunning, group.begin_release());
    group.finish_run();
    try std.testing.expectEqual(support.worker_group.Lifecycle.stopped, group.state());
    try std.testing.expectError(error.ClusterStopped, group.require_configured());
    try std.testing.expectError(error.ClusterStopped, group.begin_run());

    try std.testing.expect(group.enter());
    group.leave();
    group.wait_idle();

    try std.testing.expect(try group.begin_release());
    try std.testing.expectEqual(support.worker_group.Lifecycle.releasing, group.state());
    try std.testing.expect(!group.enter());
    try std.testing.expect(!try group.begin_release());
    group.finish_release();
    try std.testing.expectEqual(support.worker_group.Lifecycle.released, group.state());
    try std.testing.expectError(error.ClusterDeinitialized, group.require_publishable());
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

    try std.testing.expectEqual(
        @as(usize, 4),
        try support.cluster.resolve_worker_count(4, .{}),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try support.cluster.resolve_worker_count(4, .{ .worker_count = 2 }),
    );
    try std.testing.expectError(
        error.InvalidWorkerCount,
        support.cluster.resolve_worker_count(4, .{ .worker_count = 5 }),
    );
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
        try support.cluster.resolve_environment_worker_count(&environ, 8, .{
            .worker_count = 3,
        }),
    );
    try std.testing.expectError(
        error.InvalidWorkerCount,
        support.cluster.resolve_environment_worker_count(&environ, 8, .{
            .worker_count = 9,
        }),
    );
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
    try std.testing.expectEqual(@as(usize, 1), group.threads.len);
    try std.testing.expectEqual(@as(usize, 1), group.active_workers);
    try std.testing.expectEqual(@as(usize, 0), group.thread_count);
    try std.testing.expect(!group.worker_failed.load(.acquire));
    try std.testing.expect(!group.deinitialized);
    group.deinit();
    try group.deinit_checked();

    try std.testing.expectEqual(support.cluster.ClusterState.released, group.state());
    try std.testing.expectEqual(@as(usize, 0), group.worker_count());
    try std.testing.expectEqual(@as(usize, 0), group.active_workers);
    try std.testing.expectEqual(@as(usize, 0), group.threads.len);
    try std.testing.expect(group.deinitialized);
    try std.testing.expectError(
        error.ClusterDeinitialized,
        group.publish("topic", "message", true),
    );
    try std.testing.expectError(error.ClusterDeinitialized, group.run());
    try std.testing.expectError(
        error.ClusterDeinitialized,
        group.listen("127.0.0.1", 0),
    );
    try std.testing.expectError(
        error.ClusterDeinitialized,
        group.catch_shutdown_signals(),
    );
    try std.testing.expectError(
        error.ClusterDeinitialized,
        group.enable_https_ephemeral(),
    );
    try std.testing.expectError(
        error.ClusterDeinitialized,
        group.configure(struct {
            fn noop(_: *TestApp, _: usize) !void {}
        }.noop),
    );
    try std.testing.expect(group.worker(0) == null);

    // Deinit releases the worker slice. A late supervisor or signal callback
    // must not walk released storage or panic.
    group.request_shutdown();
}

test "cluster: concurrent deinit_checked releases once" {
    const TestApp = support.app.configured_app_with_timeout(1, 1024, 4096, 0);
    const Cluster = TestApp.cluster(1);
    var group = try Cluster.init_with_options(
        std.testing.allocator,
        std.testing.io,
        .{
            .max_connections = 1,
            .max_ws_message_size = 1024,
            .write_queue_size = 4096,
            .idle_timeout_ms = 0,
            .max_route_nodes = 8,
            .max_pattern_routes = 4,
            .max_middleware = 2,
        },
        .{ .cpu_affinity = false },
    );
    defer group.deinit();

    const Releaser = struct {
        group: *Cluster,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.group.deinit_checked() catch |err| {
                self.result = err;
            };
        }
    };
    var first = Releaser{ .group = &group };
    var second = Releaser{ .group = &group };
    const first_thread = try std.Thread.spawn(.{}, Releaser.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Releaser.run, .{&second});
    first_thread.join();
    second_thread.join();

    try std.testing.expect(first.result == null);
    try std.testing.expect(second.result == null);
    try std.testing.expectEqual(support.cluster.ClusterState.released, group.state());
    try std.testing.expectEqual(@as(usize, 0), group.worker_count());
}

test "worker group: release waits for a call held on another thread" {
    const Context = struct {};
    const Group = support.worker_group.worker_group(Context);
    const Holder = struct {
        group: *Group,
        entered: *std.atomic.Value(bool),
        release: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            if (!self.group.enter()) return;
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
            self.group.leave();
        }
    };
    const Releaser = struct {
        group: *Group,
        claimed: *std.atomic.Value(bool),
        idle: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            const claimed = self.group.begin_release() catch return;
            self.claimed.store(claimed, .release);
            if (!claimed) return;
            self.group.wait_idle();
            self.idle.store(true, .release);
        }
    };

    var group: Group = .{};
    var entered = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var claimed = std.atomic.Value(bool).init(false);
    var idle = std.atomic.Value(bool).init(false);
    var holder = Holder{ .group = &group, .entered = &entered, .release = &release };
    var releaser = Releaser{ .group = &group, .claimed = &claimed, .idle = &idle };

    const holder_thread = try std.Thread.spawn(.{}, Holder.run, .{&holder});
    while (!entered.load(.acquire)) std.atomic.spinLoopHint();
    const releaser_thread = try std.Thread.spawn(.{}, Releaser.run, .{&releaser});
    while (!claimed.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expect(claimed.load(.acquire));
    try std.testing.expect(!idle.load(.acquire));

    release.store(true, .release);
    while (!idle.load(.acquire)) std.atomic.spinLoopHint();
    holder_thread.join();
    releaser_thread.join();
    group.finish_release();

    try std.testing.expectEqual(support.worker_group.Lifecycle.released, group.state());
}

test "worker group: a second release waiter blocks until released" {
    const Context = struct {};
    const Group = support.worker_group.worker_group(Context);
    const Owner = struct {
        group: *Group,
        claimed: *std.atomic.Value(bool),
        finish: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            const claimed = self.group.begin_release() catch return;
            self.claimed.store(claimed, .release);
            while (!self.finish.load(.acquire)) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
            self.group.finish_release();
        }
    };
    const Waiter = struct {
        group: *Group,
        done: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            const claimed = self.group.begin_release() catch return;
            if (claimed) return;
            self.group.wait_released();
            self.done.store(true, .release);
        }
    };

    var group: Group = .{};
    var claimed = std.atomic.Value(bool).init(false);
    var finish = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var owner = Owner{ .group = &group, .claimed = &claimed, .finish = &finish };
    var waiter = Waiter{ .group = &group, .done = &done };

    const owner_thread = try std.Thread.spawn(.{}, Owner.run, .{&owner});
    while (!claimed.load(.acquire)) std.atomic.spinLoopHint();
    const waiter_thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    std.Thread.yield() catch {};
    try std.testing.expect(!done.load(.acquire));

    finish.store(true, .release);
    owner_thread.join();
    waiter_thread.join();
    try std.testing.expect(done.load(.acquire));
    try std.testing.expectEqual(support.worker_group.Lifecycle.released, group.state());
}

test "cluster: publish report treats failed wakeups as undelivered" {
    const report = support.cluster.PublishReport{
        .queued = 2,
        .notify_failed = 1,
    };
    try std.testing.expectEqual(@as(usize, 2), report.attempted());
    try std.testing.expect(!report.all_delivered());
}

test "cluster: programmatic shutdown drains the signal watcher" {
    const TestApp = support.app.configured_app_with_timeout(1, 1024, 4096, 0);
    const Cluster = TestApp.cluster(1);
    var group = try Cluster.init_with_options(
        std.testing.allocator,
        std.testing.io,
        .{
            .max_connections = 1,
            .max_ws_message_size = 1024,
            .write_queue_size = 4096,
            .idle_timeout_ms = 0,
            .max_route_nodes = 8,
            .max_pattern_routes = 4,
            .max_middleware = 2,
        },
        .{ .cpu_affinity = false },
    );
    defer group.deinit();

    try group.listen("127.0.0.1", 0);
    try group.catch_shutdown_signals();

    const Runner = struct {
        group: *Cluster,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.group.run() catch |err| {
                self.result = err;
            };
        }
    };
    var runner = Runner{ .group = &group };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    while (group.state() != support.cluster.ClusterState.running) {
        std.atomic.spinLoopHint();
    }

    try std.testing.expectError(error.ClusterRunning, group.deinit_checked());
    group.request_shutdown();
    thread.join();
    try std.testing.expect(runner.result == null);
    try std.testing.expectEqual(support.cluster.ClusterState.stopped, group.state());
}

test "cluster: deinit drains a configured listened watcher" {
    const TestApp = support.app.configured_app_with_timeout(1, 1024, 4096, 0);
    var group = try TestApp.cluster(1).init_with_options(
        std.testing.allocator,
        std.testing.io,
        .{
            .max_connections = 1,
            .max_ws_message_size = 1024,
            .write_queue_size = 4096,
            .idle_timeout_ms = 0,
            .max_route_nodes = 8,
            .max_pattern_routes = 4,
            .max_middleware = 2,
        },
        .{ .cpu_affinity = false },
    );
    defer group.deinit();

    try group.listen("127.0.0.1", 0);
    try group.catch_shutdown_signals();

    // Release must stop the watcher and drain worker 0's armed listener
    // instead of calling run(.until_done) forever.
    group.deinit();
    try std.testing.expectEqual(support.cluster.ClusterState.released, group.state());
}

test "cluster: publish report names the first full worker" {
    const TestApp = support.app.configured_app_with_timeout(2, 1024, 4096, 0);
    var group = try TestApp.cluster(2).init_with_options(
        std.testing.allocator,
        std.testing.io,
        .{
            .max_connections = 2,
            .max_ws_message_size = 1024,
            .write_queue_size = 4096,
            .idle_timeout_ms = 0,
            .max_route_nodes = 8,
            .max_pattern_routes = 4,
            .max_middleware = 2,
        },
        .{ .cpu_affinity = false },
    );
    defer group.deinit();

    for (0..support.cluster.queue_capacity) |_| {
        try group.inboxes[1].push("t", "m", true);
    }
    const report = try group.publish_report("t", "m", true);
    try std.testing.expectEqual(@as(usize, 1), report.queued);
    try std.testing.expectEqual(@as(usize, 1), report.dropped);
    try std.testing.expectEqual(@as(usize, 1), report.first_dropped_worker.?);
    try std.testing.expectEqual(@as(usize, 0), report.notify_failed);
    try std.testing.expect(!report.all_delivered());
}

test "cluster: publish after shutdown request is not reported delivered" {
    const TestApp = support.app.configured_app_with_timeout(1, 1024, 4096, 0);
    var group = try TestApp.cluster(1).init_with_options(
        std.testing.allocator,
        std.testing.io,
        .{
            .max_connections = 1,
            .max_ws_message_size = 1024,
            .write_queue_size = 4096,
            .idle_timeout_ms = 0,
            .max_route_nodes = 8,
            .max_pattern_routes = 4,
            .max_middleware = 2,
        },
        .{ .cpu_affinity = false },
    );
    defer group.deinit();

    group.request_shutdown();
    const report = try group.publish_report("topic", "message", true);
    try std.testing.expectEqual(@as(usize, 1), report.queued);
    try std.testing.expectEqual(@as(usize, 1), report.notify_failed);
    try std.testing.expect(!report.all_delivered());
}

test "cluster: lifecycle state and publish report stay typed" {
    const TestApp = support.app.configured_app_with_timeout(1, 1024, 4096, 0);
    const test_config = support.config.ServerConfig{
        .max_connections = 1,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
        .max_route_nodes = 8,
        .max_pattern_routes = 4,
        .max_middleware = 2,
    };
    var group = try TestApp.cluster(2).init_with_options(
        std.testing.allocator,
        std.testing.io,
        test_config,
        .{ .cpu_affinity = false, .worker_count = 1 },
    );
    defer group.deinit();

    try std.testing.expectEqual(support.cluster.ClusterState.configured, group.state());
    try std.testing.expectEqual(@as(usize, 1), group.worker_count());
    try std.testing.expectEqual(@as(usize, 2), group.worker_capacity());
    try std.testing.expect(group.first_failure() == null);
    try std.testing.expectEqual(@as(usize, 0), group.failure_count());

    try std.testing.expectError(
        error.EmptyTopic,
        group.publish_report("", "message", true),
    );
    var topic_buffer: [support.ws_pubsub.max_topic_length]u8 = undefined;
    var payload_buffer: [1024]u8 = undefined;
    try std.testing.expect(
        group.inboxes[0].pop_copy(&topic_buffer, &payload_buffer) == null,
    );

    var report = try group.publish_report("topic", "message", true);
    try std.testing.expectEqual(@as(usize, 1), report.queued);
    try std.testing.expectEqual(@as(usize, 0), report.dropped);
    try std.testing.expectEqual(@as(usize, 0), report.notify_failed);
    try std.testing.expectEqual(@as(usize, 1), report.attempted());
    try std.testing.expect(report.first_dropped_worker == null);
    try std.testing.expect(report.all_delivered());

    for (1..support.cluster.queue_capacity) |_| {
        try std.testing.expectEqual(
            @as(usize, 1),
            try group.publish("topic", "message", true),
        );
    }
    report = try group.publish_report("topic", "message", true);
    try std.testing.expectEqual(@as(usize, 0), report.queued);
    try std.testing.expectEqual(@as(usize, 1), report.dropped);
    try std.testing.expectEqual(@as(usize, 1), report.attempted());
    try std.testing.expectEqual(@as(usize, 0), report.first_dropped_worker.?);
    try std.testing.expect(!report.all_delivered());

    try std.testing.expectError(
        error.EmptyTopic,
        group.publish_report("", "message", true),
    );
    var oversized: [1025]u8 = undefined;
    @memset(&oversized, 0);
    try std.testing.expectError(
        error.ClusterMessageTooLarge,
        group.publish_report("topic", &oversized, true),
    );
}

test "cluster: run returns a partial spawn failure and cleans up" {
    const TestApp = support.app.configured_app_with_timeout(2, 1024, 4096, 0);
    const Cluster = TestApp.cluster(2);
    const Spawner = struct {
        fn spawn(
            _: *Cluster,
            index: usize,
            _: *const fn (*Cluster, usize) void,
        ) std.Thread.SpawnError!std.Thread {
            if (index == 0) return std.Thread.spawn(.{}, noop, .{});
            return error.SystemResources;
        }

        fn noop() void {}
    };

    var group = try Cluster.init_with_options(
        std.testing.allocator,
        std.testing.io,
        .{
            .max_connections = 2,
            .max_ws_message_size = 1024,
            .write_queue_size = 4096,
            .idle_timeout_ms = 0,
            .max_route_nodes = 8,
            .max_pattern_routes = 4,
            .max_middleware = 2,
        },
        .{ .cpu_affinity = false },
    );
    defer group.deinit();
    group.group.spawn_override = Spawner.spawn;

    try std.testing.expectError(error.SystemResources, group.run());
    try std.testing.expectEqual(support.cluster.ClusterState.stopped, group.state());
    const failure = group.first_failure().?;
    try std.testing.expectEqual(@as(usize, 1), failure.index);
    try std.testing.expectEqual(support.worker_group.FailurePhase.spawn, failure.phase);
    try std.testing.expect(failure.err == error.SystemResources);
    try std.testing.expect(group.worker_failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), group.thread_count);
}

test "cluster: run reports the failing worker phase and error" {
    const TestApp = support.app.configured_app_with_timeout(2, 1024, 4096, 0);
    const test_config = support.config.ServerConfig{
        .max_connections = 2,
        .max_ws_message_size = 1024,
        .write_queue_size = 4096,
        .idle_timeout_ms = 0,
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

    // A pre-shutdown worker fails its event-loop driver immediately, while
    // worker 0 drains the shutdown request normally.
    try group.worker(1).?.shutdown();
    try std.testing.expectError(error.ClusterWorkerFailed, group.run());

    try std.testing.expectEqual(support.cluster.ClusterState.stopped, group.state());
    const failure = group.first_failure().?;
    try std.testing.expectEqual(@as(usize, 1), failure.index);
    try std.testing.expectEqual(support.worker_group.FailurePhase.run, failure.phase);
    try std.testing.expect(failure.err == error.ApplicationUnavailable);
    try std.testing.expect(group.worker_failed.load(.acquire));
    try std.testing.expect(group.failure_count() >= 1);
    try std.testing.expectError(
        error.ClusterStopped,
        group.publish("topic", "message", true),
    );
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
