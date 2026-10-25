const std = @import("std");
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;
const wheel = @import("timer_wheel.zig");

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

/// One persistent libxev timer driving a per-loop hierarchical wheel.
///
/// The driving timer uses a bounded tick so a deadline scheduled after the
/// current arm is noticed without resetting or canceling a live completion.
/// Each tick disarms the completed completion and arms a fresh relative timer.
/// It is loop-confined: every method except `current_time_ms` must run on the
/// loop that owns the underlying completion.
pub const Scheduler = struct {
    wheel: wheel.Wheel,
    timer: xev.Timer,
    completion: xev.Completion = .{},
    io: std.Io,
    loop: ?*xev.Loop = null,
    active: bool = false,
    stopping: bool = false,

    /// Creates a scheduler anchored to the current monotonic millisecond.
    pub fn init(io: std.Io) !Scheduler {
        const now = current_ms(io);
        return .{
            .wheel = wheel.Wheel.init(now),
            .timer = try xev.Timer.init(),
            .io = io,
        };
    }

    /// Releases the libxev timer after `stop` has drained the loop.
    pub fn deinit(self: *Scheduler) void {
        std.debug.assert(!self.active);
        self.timer.deinit();
    }

    /// Returns the wall-independent millisecond clock used by this scheduler.
    pub fn current_time_ms(self: *const Scheduler) u64 {
        return current_ms(self.io);
    }

    /// Binds the owning loop and arms the first deadline.
    pub fn start(self: *Scheduler, loop: *Loop) void {
        self.loop = loop.get_xev_loop();
        self.stopping = false;
        self.arm();
    }

    /// Schedules `node` at an absolute monotonic deadline.
    pub fn schedule(
        self: *Scheduler,
        node: *wheel.TimerNode,
        deadline_ms: u64,
        callback: wheel.TimerCallback,
        ctx: *anyopaque,
    ) void {
        self.wheel.insert(node, deadline_ms, callback, ctx);
        self.arm();
    }

    /// Schedules `node` after a relative delay.
    pub fn schedule_after(
        self: *Scheduler,
        node: *wheel.TimerNode,
        delay_ms: u64,
        callback: wheel.TimerCallback,
        ctx: *anyopaque,
    ) void {
        const deadline = self.current_time_ms() +| delay_ms;
        self.schedule(node, deadline, callback, ctx);
    }

    /// Removes `node` if this scheduler owns it.
    pub fn cancel(self: *Scheduler, node: *wheel.TimerNode) bool {
        const removed = self.wheel.remove(node);
        if (removed) self.arm();
        return removed;
    }

    /// Stops the driving timer and prevents any later re-arm.
    pub fn stop(self: *Scheduler, loop: *Loop) void {
        self.stopping = true;
        self.loop = loop.get_xev_loop();
        // The driving timer is not canceled. It wakes on its bounded tick and
        // disarms after observing `stopping`; shutdown waits at most one tick.
        // This avoids IOCP's queued-cancel completion race.
    }

    /// Arms the one driving timer when deadlines exist.
    fn arm(self: *Scheduler) void {
        const loop = self.loop orelse return;
        self.arm_on(loop, &self.completion);
    }

    fn arm_on(self: *Scheduler, loop: *xev.Loop, completion: *xev.Completion) void {
        std.debug.assert(completion == &self.completion);
        if (self.stopping or self.active) return;
        if (self.wheel.next_deadline() == null) return;
        self.active = true;
        const now_ns: u64 = @intCast(@max(
            std.Io.Clock.now(.awake, self.io).nanoseconds,
            0,
        ));
        self.timer.run(loop, completion, tick_delay_ms(now_ns), Scheduler, self, on_tick);
    }

    fn on_tick(
        user_data: ?*Scheduler,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: anyerror!void,
    ) xev.CallbackAction {
        const self = user_data.?;
        result catch |err| {
            self.active = false;
            if (err != error.Canceled) log.err("timer wheel error: {}", .{err});
            return .disarm;
        };
        if (self.stopping) {
            self.active = false;
            return .disarm;
        }
        self.wheel.advance(self.current_time_ms());
        // The timer completion is dead when its callback runs. Clear the active
        // guard before reuse so a deadline scheduled during advance cannot arm
        // a second completion, then arm the next relative tick once.
        self.active = false;
        if (self.stopping or self.wheel.next_deadline() == null) return .disarm;
        self.arm_on(loop, completion);
        return .disarm;
    }
};

/// Arms `node` on `scheduler` to invoke `resume` after `delay_ms`.
pub fn sleep(
    scheduler: *Scheduler,
    node: *wheel.TimerNode,
    delay_ms: u64,
    ctx: *anyopaque,
    resume_fn: wheel.TimerCallback,
) void {
    scheduler.schedule_after(node, delay_ms, resume_fn, ctx);
}

/// Maximum time between wheel advances while deadlines exist.
///
/// Five milliseconds keeps the idle timer cheap enough on IOCP, where a 1 ms
/// re-arm can outrun the submission queue, while staying below a scheduler
/// quantum for connection deadlines and parked `/delay` responses.
pub const tick_ms: u64 = 5;

/// Returns a tick delay that does not cross a libxev timespec second.
///
/// libxev adds the delay to the cached nanosecond field without carrying into
/// seconds. An arm in the last five milliseconds of a second can therefore
/// become a roughly one-second wait. Keep each arm inside the current second;
/// the next tick resumes the normal cadence. Remove this when the maintained
/// fork normalizes the timer timespec.
pub fn tick_delay_ms(now_ns: u64) u64 {
    const nsec = now_ns % std.time.ns_per_s;
    const remaining_ms = (std.time.ns_per_s - nsec) / std.time.ns_per_ms;
    if (remaining_ms <= 1) return 0;
    return @min(tick_ms, remaining_ms - 1);
}

fn current_ms(io: std.Io) u64 {
    const now = std.Io.Clock.now(.awake, io);
    return @intCast(@max(@divTrunc(now.nanoseconds, std.time.ns_per_ms), 0));
}
