const std = @import("std");
const max_topic_length = @import("../ws/pubsub.zig").max_topic_length;

pub const queue_capacity = 64;

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
pub fn parse_worker_count(value: []const u8, capacity: usize) !usize {
    if (capacity == 0) return error.InvalidWorkerCount;
    const count = std.fmt.parseInt(usize, value, 10) catch return error.InvalidWorkerCount;
    if (count == 0 or count > capacity) return error.InvalidWorkerCount;
    return count;
}

/// Resolves the active worker count from the environment, or the CPU count.
///
/// This is a startup boundary: environment access is explicit, bounded, and
/// never performed on a request path.
pub fn worker_count_from_environment(
    environ: *const std.process.Environ.Map,
    capacity: usize,
) !usize {
    if (capacity == 0) return error.InvalidWorkerCount;
    const raw = environ.get(workers_environment_variable) orelse
        return @min(default_worker_count(), capacity);
    return parse_worker_count(raw, capacity);
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
        pub fn push(self: *Self, topic: []const u8, payload: []const u8, is_text: bool) !void {
            if (topic.len == 0) return error.EmptyTopic;
            if (topic.len > max_topic_length) return error.TopicTooLong;
            if (payload.len > max_message_size) return error.ClusterMessageTooLarge;

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

        /// Copies the oldest message into caller buffers, or returns null.
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
                    if (self.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    const index = pos % queue_capacity;
                    const topic_length = self.topic_lengths[index];
                    const payload_length = self.payload_lengths[index];
                    std.debug.assert(topic_length <= topic_buffer.len);
                    std.debug.assert(payload_length <= payload_buffer.len);
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
