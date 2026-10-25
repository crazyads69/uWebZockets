//! Cluster lifecycle policy and borrowed thread-slice coordination.
//!
//! The group owns lifecycle transitions, release claiming, start/join
//! coordination, and first-failure capture. Thread storage, worker slabs, and
//! event loops stay with the cluster. A borrowed slice keeps the public
//! `Cluster.threads` field source-compatible.

const std = @import("std");
const builtin = @import("builtin");

/// Lifecycle of a thread-per-core cluster.
pub const Lifecycle = enum(u8) {
    /// Workers exist but no thread has been spawned.
    configured,
    /// Worker threads are running or draining.
    running,
    /// `run` returned after every worker joined.
    stopped,
    /// `deinit` claimed release and is freeing storage.
    releasing,
    /// `deinit` released every worker and thread handle.
    released,
};

/// Lifecycle-sensitive call rejection.
pub const LifecycleError = error{
    ClusterDeinitialized,
    ClusterRunning,
    ClusterStopped,
};

/// Release claiming failure.
pub const ReleaseError = error{ClusterRunning};

/// Publish lifecycle rejection; a running or configured group can publish.
pub const PublishLifecycleError = error{
    ClusterDeinitialized,
    ClusterStopped,
};

/// Phase that produced a worker failure.
pub const FailurePhase = enum(u8) {
    /// `std.Thread.spawn` failed on the supervisor thread.
    spawn,
    /// The worker's event-loop driver returned an error.
    run,
    /// Post-run cleanup failed to drain a worker loop or listener.
    cleanup,
};

/// First worker error observed by the supervisor.
pub const WorkerFailure = struct {
    /// Zero-based index of the worker that failed.
    index: usize,
    /// Phase that failed.
    phase: FailurePhase,
    /// Error returned by thread spawn, the worker loop, or cleanup.
    err: anyerror,
};

/// Thread-group start failure.
pub const StartError = error{
    InvalidWorkerCount,
    WorkerGroupAlreadyRunning,
    WorkerGroupNotRunning,
} || std.Thread.SpawnError;

/// Returns a type-safe group bound to a borrowed thread slice.
pub fn worker_group(comptime Context: type) type {
    return struct {
        const Self = @This();

        /// Worker entry point; runs on the spawned thread.
        pub const StartCallback = *const fn (context: *Context, index: usize) void;
        /// Test-only replacement for `std.Thread.spawn`.
        pub const SpawnOverride = *const fn (
            context: *Context,
            index: usize,
            callback: StartCallback,
        ) std.Thread.SpawnError!std.Thread;

        lifecycle: std.atomic.Value(Lifecycle) = .init(.configured),
        active: std.atomic.Value(usize) = .init(0),
        calls: std.atomic.Value(usize) = .init(0),
        started: std.atomic.Value(usize) = .init(0),
        running: std.atomic.Value(bool) = .init(false),
        failure_lock: std.atomic.Mutex = .unlocked,
        first_failure: ?WorkerFailure = null,
        failures: usize = 0,
        /// Test-only spawn replacement; compiled out of production builds.
        spawn_override: if (builtin.is_test) ?SpawnOverride else void =
            if (builtin.is_test) null else {},

        /// Current lifecycle state.
        pub fn state(self: *const Self) Lifecycle {
            return self.lifecycle.load(.acquire);
        }

        /// Number of worker threads started by the last `start` call.
        pub fn started_count(self: *const Self) usize {
            return self.started.load(.acquire);
        }

        /// Publishes the active worker count for lock-free supervisor reads.
        pub fn set_active(self: *Self, count: usize) void {
            self.active.store(count, .release);
        }

        /// Returns the active worker count without touching worker storage.
        pub fn active_count(self: *const Self) usize {
            return self.active.load(.acquire);
        }

        /// Registers an external call that may touch worker storage.
        ///
        /// A caller that races release either wins before the release claim,
        /// making release wait, or observes `releasing`/`released`
        /// and returns false without touching worker storage. The counter and
        /// the lifecycle live in the cluster object, which outlives the
        /// worker arrays, so the losing path is still memory-safe.
        pub fn enter(self: *Self) bool {
            // SeqCst pairs with begin_release/wait_idle. The store-load pair is
            // a Dekker handshake: acquire/release alone lets a weakly ordered
            // target observe neither the increment nor the release claim.
            _ = self.calls.fetchAdd(1, .seq_cst);
            return switch (self.lifecycle.load(.seq_cst)) {
                .configured, .running, .stopped => true,
                .releasing, .released => {
                    _ = self.calls.fetchSub(1, .acq_rel);
                    return false;
                },
            };
        }

        /// Ends an external call registered by `enter`.
        pub fn leave(self: *Self) void {
            _ = self.calls.fetchSub(1, .acq_rel);
        }

        /// Waits for every in-flight external call to leave.
        pub fn wait_idle(self: *Self) void {
            while (self.calls.load(.seq_cst) != 0) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }

        /// Waits until the winning release owner publishes `released`.
        pub fn wait_released(self: *Self) void {
            while (self.state() != .released) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }

        /// Requires a group that has not run and has not been released.
        pub fn require_configured(self: *const Self) LifecycleError!void {
            return switch (self.state()) {
                .configured => {},
                .running => error.ClusterRunning,
                .stopped => error.ClusterStopped,
                .releasing, .released => error.ClusterDeinitialized,
            };
        }

        /// Requires a group whose workers can still consume a publish.
        pub fn require_publishable(self: *const Self) PublishLifecycleError!void {
            return switch (self.state()) {
                .configured, .running => {},
                .stopped => error.ClusterStopped,
                .releasing, .released => error.ClusterDeinitialized,
            };
        }

        /// Claims the configured-to-running transition exactly once.
        pub fn begin_run(self: *Self) LifecycleError!void {
            while (true) {
                switch (self.state()) {
                    .configured => {
                        if (self.lifecycle.cmpxchgWeak(
                            .configured,
                            .running,
                            .acq_rel,
                            .acquire,
                        ) == null) return;
                    },
                    .running => return error.ClusterRunning,
                    .stopped => return error.ClusterStopped,
                    .releasing, .released => return error.ClusterDeinitialized,
                }
            }
        }

        /// Publishes the stopped state after every worker has joined.
        pub fn finish_run(self: *Self) void {
            std.debug.assert(self.state() == .running);
            std.debug.assert(!self.running.load(.acquire));
            self.lifecycle.store(.stopped, .release);
        }

        /// Claims release, or reports that another owner already holds it.
        ///
        /// A running group is rejected so release never frees a live loop.
        pub fn begin_release(self: *Self) ReleaseError!bool {
            while (true) {
                const current = self.state();
                switch (current) {
                    .releasing, .released => return false,
                    .running => return error.ClusterRunning,
                    .configured, .stopped => {
                        // Never release storage while a thread handle is
                        // still joinable, even if the lifecycle is stale.
                        if (self.running.load(.acquire)) return error.ClusterRunning;
                        if (self.lifecycle.cmpxchgWeak(
                            current,
                            .releasing,
                            .seq_cst,
                            .seq_cst,
                        ) == null) return true;
                    },
                }
            }
        }

        /// Publishes the released state after storage is freed.
        pub fn finish_release(self: *Self) void {
            std.debug.assert(self.state() == .releasing);
            std.debug.assert(!self.running.load(.acquire));
            std.debug.assert(self.started.load(.acquire) == 0);
            self.lifecycle.store(.released, .release);
        }

        /// Starts exactly `count` workers in the borrowed thread slice.
        ///
        /// A spawn failure records the failing index and phase. The caller
        /// must request shutdown for the started workers and call `join`
        /// before releasing the context or the thread slice.
        pub fn start(
            self: *Self,
            threads: []std.Thread,
            count: usize,
            context: *Context,
            callback: StartCallback,
        ) StartError!void {
            if (self.state() != .running) return error.WorkerGroupNotRunning;
            if (self.running.load(.acquire) or self.started.load(.acquire) != 0) {
                return error.WorkerGroupAlreadyRunning;
            }
            if (count == 0 or count > threads.len) return error.InvalidWorkerCount;

            self.clear_failure();
            self.running.store(true, .release);
            for (0..count) |index| {
                threads[index] = self.spawn_one(context, callback, index) catch |err| {
                    self.record_failure(index, .spawn, err);
                    return err;
                };
                self.started.store(index + 1, .release);
            }
        }

        fn spawn_one(
            self: *Self,
            context: *Context,
            callback: StartCallback,
            index: usize,
        ) std.Thread.SpawnError!std.Thread {
            if (comptime builtin.is_test) {
                if (self.spawn_override) |spawn| return spawn(context, index, callback);
            }
            return std.Thread.spawn(.{}, entry, .{ context, callback, index });
        }

        /// Joins every started worker and clears the running state.
        pub fn join(self: *Self, threads: []std.Thread) void {
            const started = self.started.load(.acquire);
            std.debug.assert(threads.len >= started);
            for (threads[0..started]) |thread| thread.join();
            self.started.store(0, .release);
            self.running.store(false, .release);
        }

        /// Records one failure; the first failure and the total count are kept.
        ///
        /// The lock is confined to this cold supervisor path.
        pub fn record_failure(
            self: *Self,
            index: usize,
            phase: FailurePhase,
            err: anyerror,
        ) void {
            self.lock_failure();
            defer self.failure_lock.unlock();
            self.failures += 1;
            if (self.first_failure == null) {
                self.first_failure = .{ .index = index, .phase = phase, .err = err };
            }
        }

        /// Returns the first failure, or null while every worker is healthy.
        pub fn failure(self: *Self) ?WorkerFailure {
            self.lock_failure();
            defer self.failure_lock.unlock();
            return self.first_failure;
        }

        /// Number of failures recorded since the last `start`.
        pub fn failure_count(self: *Self) usize {
            self.lock_failure();
            defer self.failure_lock.unlock();
            return self.failures;
        }

        fn clear_failure(self: *Self) void {
            self.lock_failure();
            defer self.failure_lock.unlock();
            self.first_failure = null;
            self.failures = 0;
        }

        fn lock_failure(self: *Self) void {
            while (!self.failure_lock.tryLock()) std.atomic.spinLoopHint();
        }

        fn entry(context: *Context, callback: StartCallback, index: usize) void {
            callback(context, index);
        }
    };
}
