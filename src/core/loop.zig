const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");

const selection_pending: u8 = 0;
const selection_established: u8 = 1;

/// io_uring setup charges its rings to RLIMIT_MEMLOCK and the kernel uncharges
/// a closed ring asynchronously, so rapid loop churn can report a transient
/// `error.SystemResources`. Retry the same backend a bounded number of times;
/// falling back to another backend after selection is never allowed.
const ring_init_attempts: u8 = 32;

/// libxev's dynamic API keeps the selected backend in one process-global
/// variable and dispatches every loop operation through it, so every loop in
/// the process must be created against the same backend. This is the
/// documented process-wide OS singleton exception to the container-level var
/// rule: the lock serializes the one-time selection and the atomic publishes
/// the result to later initializers without contention.
const Selection = if (xev.dynamic) struct {
    var state = std.atomic.Value(u8).init(selection_pending);
    /// Written before `state` becomes established and immutable afterwards.
    var backend: xev.Backend = undefined;
    /// std.Thread.Mutex is not part of Zig 0.16 and std.Io.Mutex needs an Io
    /// that `init` does not receive; selection is a one-time cold path, so a
    /// test-and-set lock is enough.
    var lock: std.atomic.Mutex = .unlocked;
} else struct {};

/// Completion-driven event loop backed by libxev.
pub const Loop = struct {
    xev_loop: xev.Loop,
    /// Owned thread pool for backends that offload blocking file operations
    /// (epoll, kqueue, IOCP). Null on io_uring, which runs them in the ring.
    thread_pool: ?*xev.ThreadPool = null,

    /// Returns the borrowed libxev loop handle used by transport integrations.
    pub inline fn get_xev_loop(self: *Loop) *xev.Loop {
        return &self.xev_loop;
    }
};

/// Cancels a completion across libxev backends.
pub fn cancel(
    loop: *xev.Loop,
    completion: *xev.Completion,
    cancel_completion: *xev.Completion,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime callback: xev.cancel_callback(Userdata),
) void {
    xev.cancel(loop, completion, cancel_completion, Userdata, userdata, callback);
}

fn create_thread_pool() !*xev.ThreadPool {
    const pool = try std.heap.page_allocator.create(xev.ThreadPool);
    pool.* = xev.ThreadPool.init(.{});
    return pool;
}

fn destroy_thread_pool(pool: *xev.ThreadPool) void {
    pool.shutdown();
    pool.deinit();
    std.heap.page_allocator.destroy(pool);
}

/// Initializes an event loop sized for 4096 completion entries.
///
/// The first call selects the process backend exactly once: it probes for an
/// available backend and falls back to epoll if an available io_uring still
/// cannot create its ring. Later calls never re-detect or switch backends.
pub fn init() !Loop {
    return if (comptime xev.dynamic) init_dynamic() else create_loop(false);
}

fn init_dynamic() !Loop {
    if (Selection.state.load(.acquire) == selection_established) return init_established();

    while (!Selection.lock.tryLock()) std.atomic.spinLoopHint();
    defer Selection.lock.unlock();

    if (Selection.state.load(.acquire) == selection_established) return init_established();

    // No loop exists yet, so this is the only safe point to fall back.
    try xev.detect();
    const loop = try create_loop(true);
    // Publish only after the first loop exists: another thread must not build
    // a loop against a backend that fallback can still change.
    Selection.backend = xev.backend();
    Selection.state.store(selection_established, .release);
    return loop;
}

fn init_established() !Loop {
    // A caller that runs xev.detect or xev.prefer after the first loop would
    // otherwise make this loop dispatch to a different backend than the ones
    // already running.
    if (xev.backend() != Selection.backend) return error.BackendChanged;

    var attempts: u8 = 0;
    while (true) : (attempts += 1) {
        return create_loop(false) catch |err| {
            if (err != error.SystemResources) return err;
            if (xev.backend() != .io_uring) return err;
            if (attempts + 1 >= ring_init_attempts) return err;
            wait_for_ring_release();
            continue;
        };
    }
}

fn wait_for_ring_release() void {
    if (comptime xev.dynamic and builtin.os.tag == .linux) {
        const request: std.os.linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        // Best-effort delay: an interrupted sleep only reaches the retry
        // bound sooner, and the bound still returns the original error.
        _ = std.os.linux.nanosleep(&request, null);
    }
}

fn create_loop(comptime allow_fallback: bool) !Loop {
    var thread_pool: ?*xev.ThreadPool = null;
    errdefer if (thread_pool) |pool| destroy_thread_pool(pool);

    const needs_pool = xev.backend() != .io_uring;
    if (needs_pool) thread_pool = try create_thread_pool();

    if (comptime xev.dynamic) {
        const handle = xev.Loop.init(.{
            .entries = 4096,
            .thread_pool = thread_pool,
        }) catch |err| {
            if (comptime !allow_fallback) return err;
            if (xev.backend() != .io_uring or !xev.prefer(.epoll)) return err;
            // io_uring probed as available but ring creation failed; degrade
            // to epoll while the process backend is still unestablished.
            if (thread_pool == null) thread_pool = try create_thread_pool();
            return .{
                .xev_loop = try xev.Loop.init(.{
                    .entries = 4096,
                    .thread_pool = thread_pool,
                }),
                .thread_pool = thread_pool,
            };
        };
        return .{ .xev_loop = handle, .thread_pool = thread_pool };
    }

    return .{
        .xev_loop = try xev.Loop.init(.{
            .entries = 4096,
            .thread_pool = thread_pool,
        }),
        .thread_pool = thread_pool,
    };
}

/// Releases operating-system resources after all operations have stopped.
pub fn deinit(l: *Loop) void {
    // libxev requires the thread pool to stop before the loop's storage is
    // released, since a worker may still deliver a completion into it.
    if (l.thread_pool) |pool| destroy_thread_pool(pool);
    l.thread_pool = null;
    l.xev_loop.deinit();
}

/// Runs until no active connection, timer, or cancellation remains.
pub fn run(l: *Loop) !void {
    // .until_done forces the loop to run continuously until all
    // completions (i/o, timer) are fully canceled or processed
    try l.xev_loop.run(.until_done);
}
