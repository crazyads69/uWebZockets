const std = @import("std");
const WebSocket = @import("socket.zig").WebSocket;
const zslay = @import("zslay");

/// Maximum number of active topic names.
pub const max_topics = 1024;
/// Maximum number of socket-to-topic subscriptions.
pub const max_subscriptions = 8192;
/// Maximum topic name length in bytes.
pub const max_topic_length = 127;

const no_link = std.math.maxInt(u16);
const topic_index_capacity = max_topics * 2;
const sub_index_capacity = max_subscriptions * 2;

const TopicIndexSlot = struct {
    hash: u64 = 0,
    topic: u16 = no_link,
    used: bool = false,
    tombstone: bool = false,
};

const SubIndexSlot = struct {
    socket: usize = 0,
    topic: u16 = no_link,
    row: u16 = no_link,
    used: bool = false,
    tombstone: bool = false,
};

/// Allocation-free WebSocket topic registry with fixed SoA storage.
///
/// Topic ids and subscription rows are stable for their lifetime. Each topic
/// owns an intrusive doubly-linked subscriber list, and open-addressed indexes
/// make subscribe, unsubscribe, and lookup O(1) expected. Publish work is
/// proportional to the live subscribers of the published topic, not the global
/// subscription count.
pub const PubSubEngine = struct {
    topic_names: [max_topics][max_topic_length]u8 = undefined,
    topic_name_lengths: [max_topics]u8 = .{0} ** max_topics,
    topic_subscriber_counts: [max_topics]u16 = .{0} ** max_topics,
    topic_heads: [max_topics]u16 = .{no_link} ** max_topics,
    topic_tails: [max_topics]u16 = .{no_link} ** max_topics,
    topic_active: [max_topics]bool = .{false} ** max_topics,
    topic_free: [max_topics]u16 = undefined,
    topic_free_count: usize = 0,
    topic_high_water: usize = 0,
    topic_count: usize = 0,

    sub_sockets: [max_subscriptions]?*WebSocket = undefined,
    sub_topic_ids: [max_subscriptions]u16 = undefined,
    sub_next: [max_subscriptions]u16 = .{no_link} ** max_subscriptions,
    sub_prev: [max_subscriptions]u16 = .{no_link} ** max_subscriptions,
    sub_count: usize = 0,
    retired_subscriptions: usize = 0,

    topic_index: [topic_index_capacity]TopicIndexSlot = [_]TopicIndexSlot{.{}} ** topic_index_capacity,
    topic_index_live: usize = 0,
    topic_index_tombstones: usize = 0,
    sub_index: [sub_index_capacity]SubIndexSlot = [_]SubIndexSlot{.{}} ** sub_index_capacity,
    sub_index_live: usize = 0,
    sub_index_tombstones: usize = 0,

    /// Active publish frames; nested publishes keep tombstones until the outermost ends.
    publish_depth: usize = 0,
    empty_topic_pending: bool = false,
    /// Test/diagnostic count of subscription rows visited by publish.
    publish_visits: usize = 0,

    fn topic_name(self: *const PubSubEngine, topic_id: usize) []const u8 {
        return self.topic_names[topic_id][0..self.topic_name_lengths[topic_id]];
    }

    fn find_topic(self: *PubSubEngine, name: []const u8) ?usize {
        if (self.topic_index_live == 0 and self.topic_count != 0) self.rebuild_topic_index();
        const hash = fnv1a_64(name);
        var index = @as(usize, @intCast(hash % topic_index_capacity));
        var probes: usize = 0;
        while (probes < topic_index_capacity) : (probes += 1) {
            const slot = self.topic_index[index];
            if (!slot.used and !slot.tombstone) return null;
            if (slot.used and slot.hash == hash and
                std.mem.eql(u8, self.topic_name(slot.topic), name))
            {
                return slot.topic;
            }
            index = if (index + 1 == topic_index_capacity) 0 else index + 1;
        }
        return null;
    }

    fn get_or_create_topic(self: *PubSubEngine, name: []const u8) !usize {
        if (self.find_topic(name)) |topic_id| return topic_id;
        if (name.len == 0) return error.EmptyTopic;
        if (name.len > max_topic_length) return error.TopicTooLong;
        if (self.topic_count >= max_topics) return error.TopicCapacityReached;

        const topic_id = if (self.topic_free_count != 0) blk: {
            self.topic_free_count -= 1;
            break :blk self.topic_free[self.topic_free_count];
        } else blk: {
            if (self.topic_high_water >= max_topics) return error.TopicCapacityReached;
            const id = self.topic_high_water;
            self.topic_high_water += 1;
            break :blk @as(u16, @intCast(id));
        };

        @memcpy(self.topic_names[topic_id][0..name.len], name);
        self.topic_name_lengths[topic_id] = @intCast(name.len);
        self.topic_subscriber_counts[topic_id] = 0;
        self.topic_heads[topic_id] = no_link;
        self.topic_tails[topic_id] = no_link;
        self.topic_active[topic_id] = true;
        self.topic_count += 1;
        self.insert_topic_index(fnv1a_64(name), topic_id);
        return topic_id;
    }

    /// Adds an idempotent socket subscription, copying the topic name if new.
    ///
    /// While a publish frame is active, retired rows stay tombstones until the
    /// outermost fan-out returns. A subscribe in that window can transiently
    /// report `SubscriptionCapacityReached` even though the rows will be
    /// reclaimed at the frame boundary.
    pub fn subscribe(self: *PubSubEngine, socket: *WebSocket, topic: []const u8) !void {
        const existing_topic = self.find_topic(topic);
        if (existing_topic) |topic_id| {
            if (self.find_subscription(socket, @intCast(topic_id))) |_| return;
        }
        if (self.sub_count >= max_subscriptions) return error.SubscriptionCapacityReached;
        const topic_id = existing_topic orelse try self.get_or_create_topic(topic);
        if (self.topic_subscriber_counts[topic_id] == std.math.maxInt(u16)) {
            return error.TopicSubscriberCapacityReached;
        }

        const row: u16 = @intCast(self.sub_count);
        self.sub_sockets[row] = socket;
        self.sub_topic_ids[row] = @intCast(topic_id);
        self.sub_next[row] = no_link;
        self.sub_prev[row] = self.topic_tails[topic_id];
        if (self.topic_tails[topic_id] != no_link) {
            self.sub_next[self.topic_tails[topic_id]] = row;
        } else {
            self.topic_heads[topic_id] = row;
        }
        self.topic_tails[topic_id] = row;
        self.sub_count += 1;
        self.topic_subscriber_counts[topic_id] += 1;
        self.insert_sub_index(socket, @intCast(topic_id), row);
    }

    /// Removes one socket subscription and reports whether it existed.
    pub fn unsubscribe(self: *PubSubEngine, socket: *WebSocket, topic: []const u8) bool {
        const topic_id = self.find_topic(topic) orelse return false;
        const row = self.find_subscription(socket, @intCast(topic_id)) orelse return false;
        if (self.publish_depth > 0) {
            self.retire_subscription(row);
            return true;
        }
        self.remove_subscription(row);
        if (self.topic_subscriber_counts[topic_id] == 0) self.remove_topic(topic_id);
        return true;
    }

    /// Removes every subscription owned by `socket`.
    pub fn unsubscribe_all(self: *PubSubEngine, socket: *WebSocket) void {
        var row: usize = 0;
        while (row < self.sub_count) {
            const subscribed_socket = self.sub_sockets[row] orelse {
                row += 1;
                continue;
            };
            if (subscribed_socket != socket) {
                row += 1;
                continue;
            }
            if (self.publish_depth > 0) {
                self.retire_subscription(@intCast(row));
                row += 1;
                continue;
            }
            self.remove_subscription(@intCast(row));
        }

        // In a publish frame, empty topics stay addressable so a later
        // subscribe cannot be remapped to a different topic.
        if (self.publish_depth > 0) return;
        self.sweep_empty_topics();
    }

    /// Sends to current subscribers and returns the successful delivery count.
    pub fn publish(self: *PubSubEngine, topic: []const u8, message: []const u8, is_text: bool) usize {
        const topic_id = self.find_topic(topic) orelse return 0;
        const head = self.topic_heads[topic_id];
        if (head == no_link) return 0;
        const last = self.topic_tails[topic_id];
        const opcode: zslay.Opcode = if (is_text) .text else .binary;

        self.publish_depth += 1;
        defer self.end_publish();

        var delivered: usize = 0;
        var row = head;
        while (row != no_link) {
            self.publish_visits += 1;
            const next = self.sub_next[row];
            if (self.sub_sockets[row]) |subscribed_socket| {
                // A slow subscriber must not block delivery to bounded peers.
                subscribed_socket.send(message, opcode) catch continue;
                delivered += 1;
            }
            if (row == last) break;
            row = next;
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

    fn retire_subscription(self: *PubSubEngine, row: u16) void {
        const topic_id = self.sub_topic_ids[row];
        const socket = self.sub_sockets[row] orelse return;
        self.remove_sub_index(socket, topic_id);
        self.sub_sockets[row] = null;
        self.topic_subscriber_counts[topic_id] -= 1;
        self.retired_subscriptions += 1;
        if (self.topic_subscriber_counts[topic_id] == 0) self.empty_topic_pending = true;
    }

    fn compact_subscriptions(self: *PubSubEngine) void {
        @memset(&self.topic_heads, no_link);
        @memset(&self.topic_tails, no_link);
        var write_index: usize = 0;
        for (0..self.sub_count) |read_index| {
            const socket = self.sub_sockets[read_index] orelse continue;
            const topic_id = self.sub_topic_ids[read_index];
            if (write_index != read_index) {
                self.sub_sockets[write_index] = socket;
                self.sub_topic_ids[write_index] = topic_id;
            }
            const row: u16 = @intCast(write_index);
            self.sub_next[write_index] = no_link;
            self.sub_prev[write_index] = self.topic_tails[topic_id];
            if (self.topic_tails[topic_id] != no_link) {
                self.sub_next[self.topic_tails[topic_id]] = row;
            } else {
                self.topic_heads[topic_id] = row;
            }
            self.topic_tails[topic_id] = row;
            write_index += 1;
        }

        std.debug.assert(self.sub_count - write_index == self.retired_subscriptions);
        for (write_index..self.sub_count) |index| {
            self.sub_sockets[index] = null;
            self.sub_next[index] = no_link;
            self.sub_prev[index] = no_link;
        }
        self.sub_count = write_index;
        self.retired_subscriptions = 0;
        self.rebuild_sub_index();
    }

    fn sweep_empty_topics(self: *PubSubEngine) void {
        self.empty_topic_pending = false;
        var topic_id: usize = 0;
        while (topic_id < self.topic_high_water) : (topic_id += 1) {
            if (!self.topic_active[topic_id]) continue;
            if (self.topic_subscriber_counts[topic_id] != 0) continue;
            self.remove_topic(topic_id);
        }
    }

    fn remove_subscription(self: *PubSubEngine, row: u16) void {
        const topic_id = self.sub_topic_ids[row];
        const socket = self.sub_sockets[row] orelse return;
        self.unlink_subscription(row);
        self.topic_subscriber_counts[topic_id] -= 1;
        self.remove_sub_index(socket, topic_id);

        const last = self.sub_count - 1;
        if (row != last) {
            const moved_socket = self.sub_sockets[last] orelse unreachable;
            const moved_topic = self.sub_topic_ids[last];
            const moved_next = self.sub_next[last];
            const moved_prev = self.sub_prev[last];

            self.sub_sockets[row] = moved_socket;
            self.sub_topic_ids[row] = moved_topic;
            self.sub_next[row] = moved_next;
            self.sub_prev[row] = moved_prev;
            if (moved_prev != no_link) {
                self.sub_next[moved_prev] = row;
            } else {
                self.topic_heads[moved_topic] = row;
            }
            if (moved_next != no_link) {
                self.sub_prev[moved_next] = row;
            } else {
                self.topic_tails[moved_topic] = row;
            }
            self.update_sub_index_row(moved_socket, moved_topic, row);
        }

        self.sub_sockets[last] = null;
        self.sub_next[last] = no_link;
        self.sub_prev[last] = no_link;
        self.sub_count -= 1;
    }

    fn unlink_subscription(self: *PubSubEngine, row: u16) void {
        const topic_id = self.sub_topic_ids[row];
        const prev = self.sub_prev[row];
        const next = self.sub_next[row];
        if (prev != no_link) {
            self.sub_next[prev] = next;
        } else {
            self.topic_heads[topic_id] = next;
        }
        if (next != no_link) {
            self.sub_prev[next] = prev;
        } else {
            self.topic_tails[topic_id] = prev;
        }
    }

    fn remove_topic(self: *PubSubEngine, topic_id: usize) void {
        std.debug.assert(self.topic_subscriber_counts[topic_id] == 0);
        self.remove_topic_index(fnv1a_64(self.topic_name(topic_id)), @intCast(topic_id));
        self.topic_active[topic_id] = false;
        self.topic_name_lengths[topic_id] = 0;
        self.topic_heads[topic_id] = no_link;
        self.topic_tails[topic_id] = no_link;
        std.debug.assert(self.topic_count > 0);
        self.topic_count -= 1;
        self.topic_free[self.topic_free_count] = @intCast(topic_id);
        self.topic_free_count += 1;
    }

    fn fnv1a_64(bytes: []const u8) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        for (bytes) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3;
        }
        return hash;
    }

    fn insert_topic_index(self: *PubSubEngine, hash: u64, topic_id: u16) void {
        // A threshold rebuild scans every active topic, including the one just
        // created, so it must not be followed by a second insertion.
        if (self.topic_index_tombstones > topic_index_capacity / 4) {
            self.rebuild_topic_index();
            return;
        }
        const position = self.find_topic_insert_slot(hash) orelse {
            self.rebuild_topic_index();
            return;
        };
        self.topic_index[position] = .{ .hash = hash, .topic = topic_id, .used = true };
        self.topic_index_live += 1;
    }

    fn find_topic_insert_slot(self: *PubSubEngine, hash: u64) ?usize {
        var index = @as(usize, @intCast(hash % topic_index_capacity));
        var first_tombstone: ?usize = null;
        var probes: usize = 0;
        while (probes < topic_index_capacity) : (probes += 1) {
            const slot = self.topic_index[index];
            if (slot.used) {
                // A duplicate is rejected by find_topic before insertion.
            } else if (slot.tombstone) {
                if (first_tombstone == null) first_tombstone = index;
            } else {
                return first_tombstone orelse index;
            }
            index = if (index + 1 == topic_index_capacity) 0 else index + 1;
        }
        return first_tombstone;
    }

    fn remove_topic_index(self: *PubSubEngine, hash: u64, topic_id: u16) void {
        var index = @as(usize, @intCast(hash % topic_index_capacity));
        var probes: usize = 0;
        while (probes < topic_index_capacity) : (probes += 1) {
            const slot = &self.topic_index[index];
            if (!slot.used and !slot.tombstone) return;
            if (slot.used and slot.topic == topic_id) {
                slot.used = false;
                slot.tombstone = true;
                slot.topic = no_link;
                if (self.topic_index_live != 0) self.topic_index_live -= 1;
                self.topic_index_tombstones += 1;
                return;
            }
            index = if (index + 1 == topic_index_capacity) 0 else index + 1;
        }
    }

    fn rebuild_topic_index(self: *PubSubEngine) void {
        @memset(&self.topic_index, TopicIndexSlot{});
        self.topic_index_live = 0;
        self.topic_index_tombstones = 0;
        for (0..self.topic_high_water) |topic_id| {
            if (!self.topic_active[topic_id]) continue;
            const hash = fnv1a_64(self.topic_name(topic_id));
            const position = self.find_topic_insert_slot(hash) orelse continue;
            self.topic_index[position] = .{
                .hash = hash,
                .topic = @intCast(topic_id),
                .used = true,
            };
            self.topic_index_live += 1;
        }
    }

    fn sub_hash(socket: *WebSocket, topic_id: u16) u64 {
        var value: u64 = @intFromPtr(socket);
        value ^= @as(u64, topic_id) *% 0x9e3779b97f4a7c15;
        value ^= value >> 30;
        value *%= 0xbf58476d1ce4e5b9;
        value ^= value >> 27;
        value *%= 0x94d049bb133111eb;
        value ^= value >> 31;
        return value;
    }

    fn find_subscription(self: *PubSubEngine, socket: *WebSocket, topic_id: u16) ?u16 {
        if (self.sub_index_live == 0 and self.sub_count != 0) self.rebuild_sub_index();
        const hash = sub_hash(socket, topic_id);
        var index = @as(usize, @intCast(hash % sub_index_capacity));
        var probes: usize = 0;
        while (probes < sub_index_capacity) : (probes += 1) {
            const slot = self.sub_index[index];
            if (!slot.used and !slot.tombstone) return null;
            if (slot.used and slot.socket == @intFromPtr(socket) and slot.topic == topic_id) {
                return slot.row;
            }
            index = if (index + 1 == sub_index_capacity) 0 else index + 1;
        }
        return null;
    }

    fn insert_sub_index(self: *PubSubEngine, socket: *WebSocket, topic_id: u16, row: u16) void {
        // Rebuild already indexes the row that was just appended to sub_count.
        if (self.sub_index_tombstones > sub_index_capacity / 4) {
            self.rebuild_sub_index();
            return;
        }
        const hash = sub_hash(socket, topic_id);
        const position = self.find_sub_insert_slot(hash) orelse {
            self.rebuild_sub_index();
            return;
        };
        self.sub_index[position] = .{
            .socket = @intFromPtr(socket),
            .topic = topic_id,
            .row = row,
            .used = true,
        };
        self.sub_index_live += 1;
    }

    fn find_sub_insert_slot(self: *PubSubEngine, hash: u64) ?usize {
        var index = @as(usize, @intCast(hash % sub_index_capacity));
        var first_tombstone: ?usize = null;
        var probes: usize = 0;
        while (probes < sub_index_capacity) : (probes += 1) {
            const slot = self.sub_index[index];
            if (slot.used) {
                // Duplicates are rejected by find_subscription.
            } else if (slot.tombstone) {
                if (first_tombstone == null) first_tombstone = index;
            } else {
                return first_tombstone orelse index;
            }
            index = if (index + 1 == sub_index_capacity) 0 else index + 1;
        }
        return first_tombstone;
    }

    fn remove_sub_index(self: *PubSubEngine, socket: *WebSocket, topic_id: u16) void {
        const hash = sub_hash(socket, topic_id);
        var index = @as(usize, @intCast(hash % sub_index_capacity));
        var probes: usize = 0;
        while (probes < sub_index_capacity) : (probes += 1) {
            const slot = &self.sub_index[index];
            if (!slot.used and !slot.tombstone) return;
            if (slot.used and slot.socket == @intFromPtr(socket) and slot.topic == topic_id) {
                slot.used = false;
                slot.tombstone = true;
                slot.row = no_link;
                if (self.sub_index_live != 0) self.sub_index_live -= 1;
                self.sub_index_tombstones += 1;
                return;
            }
            index = if (index + 1 == sub_index_capacity) 0 else index + 1;
        }
    }

    fn update_sub_index_row(self: *PubSubEngine, socket: *WebSocket, topic_id: u16, row: u16) void {
        const hash = sub_hash(socket, topic_id);
        var index = @as(usize, @intCast(hash % sub_index_capacity));
        var probes: usize = 0;
        while (probes < sub_index_capacity) : (probes += 1) {
            const slot = &self.sub_index[index];
            if (!slot.used and !slot.tombstone) return;
            if (slot.used and slot.socket == @intFromPtr(socket) and slot.topic == topic_id) {
                slot.row = row;
                return;
            }
            index = if (index + 1 == sub_index_capacity) 0 else index + 1;
        }
    }

    fn rebuild_sub_index(self: *PubSubEngine) void {
        @memset(&self.sub_index, SubIndexSlot{});
        self.sub_index_live = 0;
        self.sub_index_tombstones = 0;
        for (0..self.sub_count) |row| {
            const socket = self.sub_sockets[row] orelse continue;
            const topic_id = self.sub_topic_ids[row];
            const hash = sub_hash(socket, topic_id);
            const position = self.find_sub_insert_slot(hash) orelse continue;
            self.sub_index[position] = .{
                .socket = @intFromPtr(socket),
                .topic = topic_id,
                .row = @intCast(row),
                .used = true,
            };
            self.sub_index_live += 1;
        }
    }
};
