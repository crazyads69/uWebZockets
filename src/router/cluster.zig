const std = @import("std");
const max_topic_length = @import("../ws/pubsub.zig").max_topic_length;
const worker_group = @import("worker_group.zig");

pub const queue_capacity = 64;

/// First worker error reported by a cluster after `run` returns.
pub const WorkerFailure = worker_group.WorkerFailure;
/// Startup phase that produced a worker failure.
pub const FailurePhase = worker_group.FailurePhase;
/// Lifecycle of a thread-per-core cluster.
pub const ClusterState = worker_group.Lifecycle;
/// Lifecycle-sensitive cluster call rejection.
pub const LifecycleError = worker_group.LifecycleError;
/// Release-claim failure.
pub const ReleaseError = worker_group.ReleaseError;

/// Startup policy for `App.cluster` worker groups.
pub const ClusterOptions = struct {
    /// Pins worker `i` to the `i`-th allowed physical core.
    ///
    /// Pinning is best effort: restricted cpusets and platforms without a
    /// hard-affinity API leave the worker unpinned instead of failing startup.
    cpu_affinity: bool = true,
    /// Selects fewer workers than the compiled capacity at startup.
    ///
    /// Null keeps the exact compile-time count. A value of zero or a value
    /// above the capacity fails before any worker slab is allocated.
    worker_count: ?usize = null,
};

/// Wakes one worker after its inbox accepted a message.
pub const NotifyCallback = *const fn (context: *anyopaque, index: usize) bool;

/// Per-worker outcome of one cluster publish.
pub const PublishReport = struct {
    /// Workers whose inbox accepted the message.
    queued: usize = 0,
    /// Workers whose bounded inbox was full.
    dropped: usize = 0,
    /// Accepted messages whose loop wakeup failed or was suppressed during
    /// shutdown.
    notify_failed: usize = 0,
    /// First worker whose inbox was full, when any.
    first_dropped_worker: ?usize = null,

    /// Total workers the message was offered to.
    pub fn attempted(self: PublishReport) usize {
        return self.queued + self.dropped;
    }

    /// True when every active worker accepted and every wakeup was posted.
    ///
    /// This is queue/wakeup delivery, not application-level subscriber
    /// delivery; a worker can still drop the message after dispatch.
    pub fn all_delivered(self: PublishReport) bool {
        return self.dropped == 0 and self.notify_failed == 0;
    }
};

/// Invalid message arguments shared by the queue and cluster publisher.
pub const MessageError = error{
    EmptyTopic,
    TopicTooLong,
    ClusterMessageTooLarge,
};

/// Bounded queue rejection, including a full inbox.
pub const QueueError = MessageError || error{ClusterQueueFull};

/// Cluster publish rejection, including message argument errors.
pub const PublishError = MessageError || worker_group.PublishLifecycleError;

/// Cluster run rejection and terminal worker failure.
pub const RunError = LifecycleError || std.Thread.SpawnError || error{
    InvalidWorkerCount,
    ClusterWorkerFailed,
};

/// Invalid worker-count selection.
pub const WorkerCountError = error{InvalidWorkerCount};

/// Validates worker count `count` against compiled `capacity`.
pub fn validate_worker_count(count: usize, capacity: usize) WorkerCountError!usize {
    if (capacity == 0 or count == 0 or count > capacity) {
        return error.InvalidWorkerCount;
    }
    return count;
}

/// Validates one cluster message before any inbox is mutated.
pub fn validate_message(
    max_message_size: usize,
    topic: []const u8,
    payload: []const u8,
) MessageError!void {
    if (topic.len == 0) return error.EmptyTopic;
    if (topic.len > max_topic_length) return error.TopicTooLong;
    if (payload.len > max_message_size) return error.ClusterMessageTooLarge;
}

/// Environment variable that overrides the active worker count at startup.
pub const workers_environment_variable = "UWEBZOCKETS_WORKERS";
/// Compile-time capacity used by the unbounded runtime worker dispatcher.
///
/// The active count is selected at startup; capacity only bounds the fixed
/// worker/inbox/thread arrays. It matches `CoreSelection`'s tracked CPU bound,
/// so no supported machine is truncated by a smaller project-defined cap.
pub const default_worker_capacity = 256;

/// Returns the platform CPU count as the default worker count.
pub fn default_worker_count() usize {
    return std.Thread.getCpuCount() catch 1;
}

/// Parses a positive worker count and validates it against `capacity`.
pub fn parse_worker_count(value: []const u8, capacity: usize) WorkerCountError!usize {
    const count = std.fmt.parseInt(usize, value, 10) catch
        return error.InvalidWorkerCount;
    return validate_worker_count(count, capacity);
}

/// Resolves the explicit option or the compiled capacity.
pub fn resolve_worker_count(
    capacity: usize,
    options: ClusterOptions,
) WorkerCountError!usize {
    return validate_worker_count(options.worker_count orelse capacity, capacity);
}

/// Resolves the active worker count from the environment, or the CPU count.
///
/// This is a startup boundary: environment access is explicit, bounded, and
/// never performed on a request path.
pub fn worker_count_from_environment(
    environ: *const std.process.Environ.Map,
    capacity: usize,
) WorkerCountError!usize {
    if (capacity == 0) return error.InvalidWorkerCount;
    const raw = environ.get(workers_environment_variable) orelse
        return validate_worker_count(@min(default_worker_count(), capacity), capacity);
    return parse_worker_count(raw, capacity);
}

/// Resolves the environment-aware worker count with explicit-option priority.
pub fn resolve_environment_worker_count(
    environ: *const std.process.Environ.Map,
    capacity: usize,
    options: ClusterOptions,
) WorkerCountError!usize {
    if (options.worker_count) |count| {
        return validate_worker_count(count, capacity);
    }
    return worker_count_from_environment(environ, capacity);
}

pub const Message = struct {
    topic: []const u8,
    payload: []const u8,
    is_text: bool,
};

/// Returns a bounded lock-free MPMC queue with structure-of-arrays storage.
///
/// The owning worker event loop is the only consumer; any worker thread may
/// publish. A Vyukov sequence ring removes the previous spinlock from the
/// cluster wakeup path, and the ring positions sit on separate cache lines so
/// producer and consumer never false-share. Payload cells stay plain arrays
/// because slot ownership is transferred through the sequence word.
pub fn message_queue(comptime max_message_size: usize) type {
    if (max_message_size == 0) @compileError("cluster message capacity must be greater than zero");

    return struct {
        const Self = @This();
        const cache_line = std.atomic.cache_line;

        topics: [queue_capacity][max_topic_length]u8 = undefined,
        payloads: [queue_capacity][max_message_size]u8 = undefined,
        scratch_topic: [max_topic_length]u8 = undefined,
        scratch_payload: [max_message_size]u8 = undefined,
        topic_lengths: [queue_capacity]u8 = .{0} ** queue_capacity,
        payload_lengths: [queue_capacity]usize = .{0} ** queue_capacity,
        text_flags: [queue_capacity]bool = .{false} ** queue_capacity,
        sequences: [queue_capacity]std.atomic.Value(usize) = initial_sequences(),
        enqueue_pos: std.atomic.Value(usize) align(cache_line) = std.atomic.Value(usize).init(0),
        dequeue_pos: std.atomic.Value(usize) align(cache_line) = std.atomic.Value(usize).init(0),

        fn initial_sequences() [queue_capacity]std.atomic.Value(usize) {
            var sequences: [queue_capacity]std.atomic.Value(usize) = undefined;
            for (&sequences, 0..) |*sequence, index| sequence.* = .init(index);
            return sequences;
        }

        /// Copies one message into the next free slot.
        ///
        /// Returns `error.ClusterQueueFull` without blocking when every slot is
        /// claimed by unread messages.
        pub fn push(
            self: *Self,
            topic: []const u8,
            payload: []const u8,
            is_text: bool,
        ) QueueError!void {
            try validate_message(max_message_size, topic, payload);
            return self.push_validated(topic, payload, is_text);
        }

        /// Broadcasts one validated message to every queue in `queues`.
        ///
        /// Validation runs once before any queue is mutated. A full queue is
        /// counted, and `notify` runs only for accepted messages. The callback
        /// returns false when the owning loop wakeup fails.
        pub fn broadcast(
            queues: []Self,
            topic: []const u8,
            payload: []const u8,
            is_text: bool,
            context: *anyopaque,
            notify: NotifyCallback,
        ) MessageError!PublishReport {
            try validate_message(max_message_size, topic, payload);

            var report: PublishReport = .{};
            for (queues, 0..) |*queue, index| {
                queue.push_validated(topic, payload, is_text) catch {
                    report.dropped += 1;
                    if (report.first_dropped_worker == null) {
                        report.first_dropped_worker = index;
                    }
                    continue;
                };
                if (!notify(context, index)) report.notify_failed += 1;
                report.queued += 1;
            }
            return report;
        }

        /// Pushes a message that already passed `validate_message`.
        ///
        /// Private to this module so no caller can bypass the bounds checks.
        fn push_validated(
            self: *Self,
            topic: []const u8,
            payload: []const u8,
            is_text: bool,
        ) error{ClusterQueueFull}!void {
            var pos = self.enqueue_pos.load(.monotonic);
            while (true) {
                const cell = &self.sequences[pos % queue_capacity];
                const sequence = cell.load(.acquire);
                const difference = @as(isize, @bitCast(sequence -% pos));
                if (difference == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    const index = pos % queue_capacity;
                    @memcpy(self.topics[index][0..topic.len], topic);
                    @memcpy(self.payloads[index][0..payload.len], payload);
                    self.topic_lengths[index] = @intCast(topic.len);
                    self.payload_lengths[index] = payload.len;
                    self.text_flags[index] = is_text;
                    cell.store(pos +% 1, .release);
                    return;
                }
                if (difference < 0) return error.ClusterQueueFull;
                pos = self.enqueue_pos.load(.monotonic);
            }
        }

        /// Copies the oldest message into queue-owned scratch, or returns null.
        ///
        /// The returned slices stay valid until the next `pop_scratch` call on
        /// this queue. The consumer uses them synchronously, so no connection
        /// buffer is borrowed and a fragmented WebSocket frame cannot be
        /// overwritten between reads.
        pub fn pop_scratch(self: *Self) ?Message {
            return self.pop_copy(&self.scratch_topic, &self.scratch_payload);
        }

        /// Copies the oldest message into caller buffers, or returns null.
        ///
        /// Returns null when the queue is empty or the oldest message does not
        /// fit the caller buffers. A message that does not fit stays queued,
        /// so a caller cannot cause an out-of-bounds copy or lose a message.
        pub fn pop_copy(
            self: *Self,
            topic_buffer: []u8,
            payload_buffer: []u8,
        ) ?Message {
            var pos = self.dequeue_pos.load(.monotonic);
            while (true) {
                const cell = &self.sequences[pos % queue_capacity];
                const sequence = cell.load(.acquire);
                const difference = @as(isize, @bitCast(sequence -% (pos +% 1)));
                if (difference == 0) {
                    const index = pos % queue_capacity;
                    const topic_length = self.topic_lengths[index];
                    const payload_length = self.payload_lengths[index];
                    if (topic_length > topic_buffer.len or
                        payload_length > payload_buffer.len)
                    {
                        return null;
                    }
                    if (self.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    // The slot is full until this consumer frees it, so the
                    // lengths read above remain valid across the claim.
                    @memcpy(topic_buffer[0..topic_length], self.topics[index][0..topic_length]);
                    @memcpy(payload_buffer[0..payload_length], self.payloads[index][0..payload_length]);
                    const is_text = self.text_flags[index];
                    cell.store(pos +% queue_capacity, .release);
                    return .{
                        .topic = topic_buffer[0..topic_length],
                        .payload = payload_buffer[0..payload_length],
                        .is_text = is_text,
                    };
                }
                if (difference < 0) return null;
                pos = self.dequeue_pos.load(.monotonic);
            }
        }
    };
}
