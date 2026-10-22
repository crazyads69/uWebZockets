const std = @import("std");
const WebSocket = @import("socket.zig").WebSocket;
const zslay = @import("zslay");

/// Maximum number of active topic names.
pub const max_topics = 1024;
/// Maximum number of socket-to-topic subscriptions.
pub const max_subscriptions = 8192;
/// Maximum topic name length in bytes.
pub const max_topic_length = 127;

/// Allocation-free WebSocket topic registry with fixed SoA storage.
pub const PubSubEngine = struct {
    topic_names: [max_topics][max_topic_length]u8 = undefined,
    topic_name_lengths: [max_topics]u8 = .{0} ** max_topics,
    topic_subscriber_counts: [max_topics]u16 = .{0} ** max_topics,
    sub_sockets: [max_subscriptions]?*WebSocket = undefined,
    sub_topic_ids: [max_subscriptions]u16 = undefined,
    topic_count: usize = 0,
    sub_count: usize = 0,
    /// Active publish frames; nested publishes keep tombstones until the outermost ends.
    publish_depth: usize = 0,
    retired_subscriptions: usize = 0,
    empty_topic_pending: bool = false,

    fn topic_name(self: *const PubSubEngine, topic_id: usize) []const u8 {
        return self.topic_names[topic_id][0..self.topic_name_lengths[topic_id]];
    }

    fn find_topic(self: *const PubSubEngine, name: []const u8) ?usize {
        for (0..self.topic_count) |topic_id| {
            if (std.mem.eql(u8, self.topic_name(topic_id), name)) return topic_id;
        }
        return null;
    }

    fn get_or_create_topic(self: *PubSubEngine, name: []const u8) !usize {
        if (self.find_topic(name)) |topic_id| return topic_id;
        if (name.len == 0) return error.EmptyTopic;
        if (name.len > max_topic_length) return error.TopicTooLong;
        if (self.topic_count >= max_topics) return error.TopicCapacityReached;

        const topic_id = self.topic_count;
        @memcpy(self.topic_names[topic_id][0..name.len], name);
        self.topic_name_lengths[topic_id] = @intCast(name.len);
        self.topic_subscriber_counts[topic_id] = 0;
        self.topic_count += 1;
        return topic_id;
    }

    /// Adds an idempotent socket subscription, copying the topic name if new.
    ///
    /// While a publish frame is active, retired rows stay tombstones until the
    /// outermost fan-out returns. A subscribe in that window can transiently
    /// report `SubscriptionCapacityReached` even though the rows will be
    /// reclaimed at the frame boundary.
    pub fn subscribe(self: *PubSubEngine, socket: *WebSocket, topic: []const u8) !void {
        const existing_topic_id = self.find_topic(topic);

        if (existing_topic_id) |topic_id| {
            for (0..self.sub_count) |subscription_id| {
                const subscribed_socket = self.sub_sockets[subscription_id] orelse continue;
                if (subscribed_socket == socket and
                    self.sub_topic_ids[subscription_id] == topic_id)
                {
                    return;
                }
            }
        }

        if (self.sub_count >= max_subscriptions) return error.SubscriptionCapacityReached;
        const topic_id = existing_topic_id orelse try self.get_or_create_topic(topic);
        if (self.topic_subscriber_counts[topic_id] == std.math.maxInt(u16)) {
            return error.TopicSubscriberCapacityReached;
        }

        self.sub_sockets[self.sub_count] = socket;
        self.sub_topic_ids[self.sub_count] = @intCast(topic_id);
        self.sub_count += 1;
        self.topic_subscriber_counts[topic_id] += 1;
    }

    /// Removes one socket subscription and reports whether it existed.
    pub fn unsubscribe(self: *PubSubEngine, socket: *WebSocket, topic: []const u8) bool {
        const topic_id = self.find_topic(topic) orelse return false;

        for (0..self.sub_count) |subscription_id| {
            const subscribed_socket = self.sub_sockets[subscription_id] orelse continue;
            if (subscribed_socket != socket) continue;
            if (self.sub_topic_ids[subscription_id] != topic_id) continue;

            if (self.publish_depth > 0) {
                self.retire_subscription(subscription_id);
                return true;
            }

            self.remove_subscription(subscription_id);
            if (self.topic_subscriber_counts[topic_id] == 0) self.remove_topic(topic_id);
            return true;
        }
        return false;
    }

    /// Removes every subscription owned by `socket`.
    pub fn unsubscribe_all(self: *PubSubEngine, socket: *WebSocket) void {
        var subscription_id: usize = 0;
        while (subscription_id < self.sub_count) {
            const subscribed_socket = self.sub_sockets[subscription_id] orelse {
                subscription_id += 1;
                continue;
            };
            if (subscribed_socket != socket) {
                subscription_id += 1;
                continue;
            }
            if (self.publish_depth > 0) {
                self.retire_subscription(subscription_id);
                subscription_id += 1;
                continue;
            }
            self.remove_subscription(subscription_id);
        }

        // In a publish frame, empty topics stay addressable so a later
        // subscribe cannot be remapped to a different topic.
        if (self.publish_depth > 0) return;
        self.sweep_empty_topics();
    }

    /// Sends to current subscribers and returns the successful delivery count.
    pub fn publish(self: *PubSubEngine, topic: []const u8, message: []const u8, is_text: bool) usize {
        const topic_id = self.find_topic(topic) orelse return 0;
        const opcode: zslay.Opcode = if (is_text) .text else .binary;
        // Rows after this bound are subscriptions made by the in-flight send;
        // they must not observe a message published before they existed.
        const bound = self.sub_count;
        self.publish_depth += 1;
        defer self.end_publish();

        var delivered: usize = 0;
        for (0..bound) |subscription_id| {
            const subscribed_socket = self.sub_sockets[subscription_id] orelse continue;
            if (self.sub_topic_ids[subscription_id] != topic_id) continue;
            // A slow subscriber must not block delivery to bounded peers.
            subscribed_socket.send(message, opcode) catch continue;
            delivered += 1;
        }
        return delivered;
    }

    fn end_publish(self: *PubSubEngine) void {
        std.debug.assert(self.publish_depth > 0);
        self.publish_depth -= 1;
        if (self.publish_depth != 0) return;

        if (self.retired_subscriptions != 0) self.compact_subscriptions();
        if (self.empty_topic_pending) self.sweep_empty_topics();
    }

    fn retire_subscription(self: *PubSubEngine, subscription_id: usize) void {
        const topic_id = self.sub_topic_ids[subscription_id];
        self.sub_sockets[subscription_id] = null;
        self.topic_subscriber_counts[topic_id] -= 1;
        self.retired_subscriptions += 1;
        if (self.topic_subscriber_counts[topic_id] == 0) self.empty_topic_pending = true;
    }

    fn compact_subscriptions(self: *PubSubEngine) void {
        var write_index: usize = 0;
        for (0..self.sub_count) |read_index| {
            const subscribed_socket = self.sub_sockets[read_index] orelse continue;
            if (write_index != read_index) {
                self.sub_sockets[write_index] = subscribed_socket;
                self.sub_topic_ids[write_index] = self.sub_topic_ids[read_index];
            }
            write_index += 1;
        }

        std.debug.assert(self.sub_count - write_index == self.retired_subscriptions);
        for (write_index..self.sub_count) |index| self.sub_sockets[index] = null;
        self.sub_count = write_index;
        self.retired_subscriptions = 0;
    }

    fn sweep_empty_topics(self: *PubSubEngine) void {
        self.empty_topic_pending = false;
        var topic_id: usize = 0;
        while (topic_id < self.topic_count) {
            if (self.topic_subscriber_counts[topic_id] != 0) {
                topic_id += 1;
                continue;
            }
            self.remove_topic(topic_id);
        }
    }

    fn remove_subscription(self: *PubSubEngine, subscription_id: usize) void {
        const topic_id = self.sub_topic_ids[subscription_id];
        self.topic_subscriber_counts[topic_id] -= 1;

        self.sub_count -= 1;
        if (subscription_id == self.sub_count) {
            self.sub_sockets[subscription_id] = null;
            return;
        }
        self.sub_sockets[subscription_id] = self.sub_sockets[self.sub_count];
        self.sub_topic_ids[subscription_id] = self.sub_topic_ids[self.sub_count];
        self.sub_sockets[self.sub_count] = null;
    }

    fn remove_topic(self: *PubSubEngine, topic_id: usize) void {
        std.debug.assert(self.topic_subscriber_counts[topic_id] == 0);

        self.topic_count -= 1;
        if (topic_id == self.topic_count) {
            self.topic_name_lengths[topic_id] = 0;
            return;
        }

        const moved_topic_id = self.topic_count;
        const moved_name = self.topic_name(moved_topic_id);
        @memcpy(self.topic_names[topic_id][0..moved_name.len], moved_name);
        self.topic_name_lengths[topic_id] = self.topic_name_lengths[moved_topic_id];
        self.topic_subscriber_counts[topic_id] = self.topic_subscriber_counts[moved_topic_id];
        self.topic_name_lengths[moved_topic_id] = 0;

        for (self.sub_topic_ids[0..self.sub_count]) |*subscription_topic_id| {
            if (subscription_topic_id.* == moved_topic_id) {
                subscription_topic_id.* = @intCast(topic_id);
            }
        }
    }
};
