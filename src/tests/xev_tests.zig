//! Runtime backend selection and the allocation-free HTTP/1.1 framing writer.

const std = @import("std");
const support = @import("test_support");
const status = support.status;
const core_loop = support.loop;
const xev = @import("xev");

test "xev: detect selects an available backend" {
    const previous = xev.backend();
    try xev.detect();
    try std.testing.expect(@tagName(xev.backend()).len != 0);
    // The first loop fixes libxev's process-global backend; probing detection
    // must not leave later loops on a backend the established one cannot use.
    if (xev.backend() != previous) try std.testing.expect(xev.prefer(previous));
}

test "xev: ring retry policy bounds transient io_uring resource failures" {
    if (comptime !@hasField(xev.Backend, "io_uring")) return error.SkipZigTest;

    const backend = xev.Backend.io_uring;
    try std.testing.expectEqual(
        core_loop.RingRetryDecision.retry,
        core_loop.ring_retry_decision(0, error.SystemResources, backend),
    );
    try std.testing.expectEqual(
        core_loop.RingRetryDecision.retry,
        core_loop.ring_retry_decision(core_loop.ring_init_attempts - 2, error.SystemResources, backend),
    );
    // The last attempt index gives up instead of starting another retry.
    try std.testing.expectEqual(
        core_loop.RingRetryDecision.give_up,
        core_loop.ring_retry_decision(core_loop.ring_init_attempts - 1, error.SystemResources, backend),
    );
    try std.testing.expectEqual(
        core_loop.RingRetryDecision.give_up,
        core_loop.ring_retry_decision(core_loop.ring_init_attempts, error.SystemResources, backend),
    );
    // Only the transient resource error retries; every other error is terminal.
    try std.testing.expectEqual(
        core_loop.RingRetryDecision.give_up,
        core_loop.ring_retry_decision(0, error.AccessDenied, backend),
    );
}

test "xev: ring retry policy never retries a non-io_uring backend" {
    if (comptime !@hasField(xev.Backend, "io_uring")) return error.SkipZigTest;
    if (comptime !@hasField(xev.Backend, "epoll")) return error.SkipZigTest;

    try std.testing.expectEqual(
        core_loop.RingRetryDecision.give_up,
        core_loop.ring_retry_decision(0, error.SystemResources, .epoll),
    );
}

test "status: format_http1_framing does not reserve the worst-case digit count" {
    // A 78-byte reason phrase plus a one-digit length fits the 128-byte
    // response framing buffer, so the bound must count actual digits.
    const long_status = "200 " ++ "x" ** 74;
    var buffer: [128]u8 = undefined;
    const head = try status.format_http1_framing(&buffer, long_status, 5);
    try std.testing.expectEqual(@as(usize, 108), head.len);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\r\nContent-Length: 5\r\n",
        head,
    );
}

test "status: format_http1_framing writes the largest length" {
    var buffer: [128]u8 = undefined;
    const head = try status.format_http1_framing(&buffer, "200 OK", std.math.maxInt(u64));
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Length: 18446744073709551615\r\n",
        head,
    );
}

/// Callback state for the backend consistency test's timer and wake cycle.
const BackendCycle = struct {
    ticks: usize = 0,
    woke: bool = false,

    fn on_timer(
        userdata: ?*BackendCycle,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        result catch return .disarm;
        userdata.?.ticks += 1;
        return .disarm;
    }

    fn on_wake(
        userdata: ?*BackendCycle,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        result catch return .disarm;
        userdata.?.woke = true;
        return .disarm;
    }
};

test "xev: every loop in one process uses the same backend" {
    if (comptime !xev.dynamic) return error.SkipZigTest;

    var loops: [4]core_loop.Loop = undefined;
    var loop_count: usize = 0;
    defer {
        for (loops[0..loop_count]) |*l| core_loop.deinit(l);
    }

    loops[0] = try core_loop.init();
    loop_count = 1;
    const selected = xev.backend();

    // libxev dispatches every operation through its process-global backend.
    // Re-running detection after the first loop must not make the next init
    // build a loop for a different backend.
    if (comptime @hasField(xev.Backend, "epoll") and @hasField(xev.Backend, "io_uring")) {
        if (selected == .io_uring) {
            try std.testing.expect(xev.prefer(.epoll));
            if (core_loop.init()) |extra_value| {
                var extra = extra_value;
                core_loop.deinit(&extra);
                return error.MixedBackendLoop;
            } else |err| {
                try std.testing.expectEqual(error.BackendChanged, err);
            }
            try std.testing.expect(xev.prefer(selected));
        }
    }

    while (loop_count < loops.len) : (loop_count += 1) {
        loops[loop_count] = try core_loop.init();
        try std.testing.expectEqual(selected, xev.backend());
    }

    var timer = try xev.Timer.init();
    defer timer.deinit();
    var notifier = try xev.Async.init();
    defer notifier.deinit();

    var cycle = BackendCycle{};
    var timer_completion: xev.Completion = .{};
    var wake_completion: xev.Completion = .{};
    const event_loop = loops[0].get_xev_loop();
    timer.run(event_loop, &timer_completion, 0, BackendCycle, &cycle, BackendCycle.on_timer);
    notifier.wait(event_loop, &wake_completion, BackendCycle, &cycle, BackendCycle.on_wake);
    try notifier.notify();
    try core_loop.run(&loops[0]);
    try std.testing.expectEqual(@as(usize, 1), cycle.ticks);
    try std.testing.expect(cycle.woke);
}
