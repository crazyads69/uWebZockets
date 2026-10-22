const std = @import("std");
const xev = @import("xev");
const tcp = @import("tcp.zig");
const Loop = @import("loop.zig").Loop;

const log = std.log.scoped(.timer);

/// Invoked once per elapsed periodic timer interval.
pub const TickCallback = *const fn () void;

/// Repeating libxev timer with inline completion storage.
pub const TimerContext = struct {
    timer: xev.Timer,
    completion: xev.Completion = .{},
    cancel_completion: xev.Completion = .{},
    interval_ms: u64,
    tick_cb: TickCallback,
    active: bool = false,
    stopping: bool = false,
};

/// Initializes a recurring timer without arming it.
pub fn init_timer(interval_ms: u64, tick_callback: TickCallback) !TimerContext {
    const t = try xev.Timer.init();
    return TimerContext{
        .timer = t,
        .interval_ms = interval_ms,
        .tick_cb = tick_callback,
    };
}

/// Releases timer resources after the timer has stopped.
pub fn deinit_timer(ctx: *TimerContext) void {
    ctx.timer.deinit();
}

/// Arms an inactive timer on `loop`; repeated starts are ignored.
pub fn start_timer(ctx: *TimerContext, loop: *Loop) void {
    if (ctx.active or ctx.stopping) return;
    ctx.active = true;
    ctx.timer.run(
        loop.get_xev_loop(),
        &ctx.completion,
        ctx.interval_ms,
        TimerContext,
        ctx,
        on_timer_tick,
    );
}

/// Requests asynchronous cancellation of an active timer.
pub fn stop_timer(ctx: *TimerContext, loop: *Loop) void {
    if (ctx.stopping) return;
    ctx.stopping = true;
    // A tick callback runs with `active` cleared; recording `stopping` is
    // enough because the tick checks it before re-arming.
    if (!ctx.active) return;
    ctx.timer.cancel(
        loop.get_xev_loop(),
        &ctx.completion,
        &ctx.cancel_completion,
        TimerContext,
        ctx,
        on_timer_cancel,
    );
}

// callback triggered by libxev when the interval elapses.
fn on_timer_tick(
    user_data: ?*TimerContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: anyerror!void,
) xev.CallbackAction {
    const ctx = user_data.?;
    _ = result catch |err| {
        ctx.active = false;
        if (err == error.Canceled) return .disarm;
        log.err("timer error: {}", .{err});
        return .disarm;
    };

    ctx.active = false;
    if (ctx.stopping) return .disarm;
    ctx.tick_cb();

    // A tick callback may have requested shutdown or armed the timer itself.
    // Re-arming an already active completion would corrupt the backend queue.
    if (ctx.active or ctx.stopping) return .disarm;

    // io_uring rearms the original absolute timeout, which is already expired.
    ctx.timer.run(loop, completion, ctx.interval_ms, TimerContext, ctx, on_timer_tick);
    ctx.active = true;
    return .disarm;
}

fn on_timer_cancel(
    user_data: ?*TimerContext,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.CancelError!void,
) xev.CallbackAction {
    const ctx = user_data.?;
    _ = result catch |err| {
        if (err != error.NotFound) log.debug("timer cancel error: {}", .{err});
        return .disarm;
    };
    ctx.active = false;
    return .disarm;
}

/// Returns a five-second connection sweeper for a compatible fixed pool.
///
/// `PoolType` must expose contiguous `storage`, `is_active`, and connections
/// with `closing` and `last_active_ms` fields.
pub fn connection_sweeper(comptime PoolType: type, comptime idle_timeout_ms: u64) type {
    if (idle_timeout_ms > std.math.maxInt(i64)) {
        @compileError("idle timeout exceeds the monotonic clock representation");
    }

    return struct {
        const Self = @This();
        const timeout_ms: i64 = @intCast(idle_timeout_ms);

        timer: xev.Timer,
        completion: xev.Completion = .{},
        cancel_completion: xev.Completion = .{},
        pool: *PoolType,
        io: std.Io,
        active: bool = false,
        stopping: bool = false,

        /// Initializes an unarmed sweeper borrowing `pool` for its lifetime.
        pub fn init(io: std.Io, pool: *PoolType) !Self {
            return Self{
                .timer = try xev.Timer.init(),
                .pool = pool,
                .io = io,
            };
        }

        /// Releases timer resources after the sweeper has stopped.
        pub fn deinit(self: *Self) void {
            self.timer.deinit();
        }

        /// Starts periodic idle-connection scans; repeated starts are ignored.
        pub fn start(self: *Self, loop: *Loop) void {
            if (self.active or self.stopping) return;
            self.active = true;
            // run callback every 5000ms (5 seconds)
            self.timer.run(
                loop.get_xev_loop(),
                &self.completion,
                5000,
                Self,
                self,
                on_tick,
            );
        }

        /// Requests asynchronous cancellation of the periodic scan.
        pub fn stop(self: *Self, loop: *Loop) void {
            if (self.stopping) return;
            self.stopping = true;
            // A tick callback runs with `active` cleared; the tick observes
            // `stopping` and disarms instead of re-arming.
            if (!self.active) return;
            self.timer.cancel(
                loop.get_xev_loop(),
                &self.completion,
                &self.cancel_completion,
                Self,
                self,
                on_cancel,
            );
        }

        // callback triggered by libxev every 5 seconds
        fn on_tick(
            user_data: ?*Self,
            loop: *xev.Loop,
            completion: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                self.active = false;
                if (err == error.Canceled) return .disarm;
                log.err("sweeper timer error: {}", .{err});
                return .disarm;
            };

            self.active = false;
            if (self.stopping) return .disarm;
            const now = std.Io.Clock.now(.awake, self.io);
            const current_time: i64 = @intCast(@divTrunc(now.nanoseconds, 1000000));

            // sweep through contiguous storage array (data-oriented design)
            // contiguous memory ensures cpu cache processes all items in microseconds
            for (self.pool.storage, 0..) |*conn, index| {
                if (!self.pool.is_active(index) or conn.closing) continue;
                conn.ws.heartbeat_tick(current_time);
                if (conn.closing or timeout_ms == 0) continue;
                if (conn.last_active_ms <= 0) continue;

                const idle_time = current_time - conn.last_active_ms;
                if (idle_time <= timeout_ms) continue;

                conn.last_active_ms = 0;
                tcp.close_connection(conn);
            }

            // A close callback may have requested shutdown; never re-arm past it.
            if (self.stopping) return .disarm;

            // Schedule a new relative timeout instead of reusing an expired one.
            self.timer.run(loop, completion, 5000, Self, self, on_tick);
            self.active = true;
            return .disarm;
        }

        fn on_cancel(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.CancelError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                if (err != error.NotFound) log.debug("sweeper cancel error: {}", .{err});
                return .disarm;
            };
            self.active = false;
            return .disarm;
        }
    };
}
