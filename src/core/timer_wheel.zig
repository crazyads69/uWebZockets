//! Allocation-free hierarchical timing wheel.
//!
//! Four levels cover fine to multi-hour deadlines without a heap:
//! level 0 has 256 one-millisecond slots, level 1 has 64 256-ms slots,
//! level 2 has 64 16.4-second slots, and level 3 has 64 17.5-minute slots.
//! Nodes are embedded by the owner (for example inside a pooled connection)
//! and linked intrusively, so scheduling, cancellation, and expiry do not
//! allocate.
//!
//! Expiry runs at the deadline's slot boundary. A node whose deadline is
//! still in the future is re-inserted, which handles deadlines beyond the
//! level-3 range without ever firing early.

const std = @import("std");

/// Largest delay covered exactly by the four levels (18.64 hours).
pub const max_exact_delay_ms: u64 = (@as(u64, 1) << 26) - 1;

const level_count = 4;
const level_sizes = [level_count]usize{ 256, 64, 64, 64 };
const level_shifts = [level_count]u6{ 0, 8, 14, 20 };
const level_offsets = [level_count]usize{ 0, 256, 320, 384 };
const level_span_shifts = [level_count]u6{ 8, 14, 20, 26 };

/// Total slot count across every level.
pub const slot_count: usize = 448;

/// Invoked once when a node's deadline has elapsed.
pub const TimerCallback = *const fn (ctx: *anyopaque) void;

fn noop_callback(_: *anyopaque) void {}

/// Where a node currently lives. Only `queued` and `processing` are owned by
/// a wheel; `idle` nodes may be re-used for a later deadline.
pub const TimerState = enum(u8) {
    idle,
    queued,
    processing,
    overflow,
};

/// Intrusive timer entry embedded in a connection or application context.
pub const TimerNode = struct {
    deadline_ms: u64 = 0,
    callback: TimerCallback = noop_callback,
    ctx: *anyopaque = undefined,
    next: ?*TimerNode = null,
    prev: ?*TimerNode = null,
    state: TimerState = .idle,
    level: u3 = 0,
    index: u8 = 0,
    owner: ?*Wheel = null,
};

const Slot = struct {
    head: ?*TimerNode = null,
    tail: ?*TimerNode = null,
};

/// Per-worker timing wheel. Not thread-safe: one wheel belongs to one loop.
pub const Wheel = struct {
    slots: [slot_count]Slot = [_]Slot{.{}} ** slot_count,
    /// Slot lists currently being dispatched. Nodes removed here are skipped.
    processing_head: ?*TimerNode = null,
    processing_tail: ?*TimerNode = null,
    /// Deadlines beyond the level-3 range wait here until they enter range.
    overflow_head: ?*TimerNode = null,
    overflow_tail: ?*TimerNode = null,
    now_ms: u64 = 0,
    /// Number of nodes owned by the wheel (queued or processing).
    count: usize = 0,

    /// Creates an empty wheel anchored to the monotonic millisecond clock.
    pub fn init(now_ms: u64) Wheel {
        return .{ .now_ms = now_ms };
    }

    /// Schedules `node` at an absolute monotonic deadline.
    ///
    /// Re-arming an already scheduled or processing node first removes it
    /// from its current list. The callback runs on the owning loop.
    pub fn insert(
        self: *Wheel,
        node: *TimerNode,
        deadline_ms: u64,
        callback: TimerCallback,
        ctx: *anyopaque,
    ) void {
        _ = self.remove(node);
        node.deadline_ms = deadline_ms;
        node.callback = callback;
        node.ctx = ctx;
        node.owner = self;

        const now = self.now_ms;
        const delta = if (deadline_ms > now) deadline_ms - now else 0;
        if (delta > max_exact_delay_ms) {
            node.state = .overflow;
            node.prev = self.overflow_tail;
            node.next = null;
            if (self.overflow_tail) |tail| {
                tail.next = node;
            } else {
                self.overflow_head = node;
            }
            self.overflow_tail = node;
            self.count += 1;
            return;
        }
        const level = level_for_delta(delta);
        // An already-due node belongs to the current level-0 slot so the next
        // advance dispatches it instead of waiting for a later window.
        const slot_time = if (delta == 0) now else deadline_ms;
        const index: u8 = @intCast((slot_time >> level_shifts[level]) &
            (level_sizes[level] - 1));
        node.level = level;
        node.index = index;
        node.state = .queued;

        const slot = &self.slots[level_offsets[level] + index];
        node.prev = slot.tail;
        node.next = null;
        if (slot.tail) |tail| {
            tail.next = node;
        } else {
            slot.head = node;
        }
        slot.tail = node;
        self.count += 1;
    }

    /// Schedules `node` after a relative delay of `delay_ms`.
    pub fn insert_after(
        self: *Wheel,
        node: *TimerNode,
        delay_ms: u64,
        callback: TimerCallback,
        ctx: *anyopaque,
    ) void {
        const deadline = self.now_ms +| delay_ms;
        self.insert(node, deadline, callback, ctx);
    }

    /// Removes `node` without invoking its callback.
    ///
    /// Returns true only when the node was owned by this wheel. Canceling the
    /// currently dispatching node is a no-op because its callback is already
    /// running.
    pub fn remove(self: *Wheel, node: *TimerNode) bool {
        if (node.owner != self) return false;
        switch (node.state) {
            .idle => return false,
            .queued => {
                const slot = &self.slots[level_offsets[node.level] + node.index];
                self.unlink_slot(slot, node);
            },
            .processing => self.unlink_processing(node),
            .overflow => self.unlink_overflow(node),
        }
        node.state = .idle;
        node.next = null;
        node.prev = null;
        node.owner = null;
        if (self.count != 0) self.count -= 1;
        return true;
    }

    /// Returns the next slot boundary at which work exists.
    ///
    /// The result is the window start, which may precede a node's actual
    /// deadline for coarse levels; `advance` re-inserts such nodes.
    pub fn next_deadline(self: *const Wheel) ?u64 {
        var earliest: ?u64 = null;
        for (0..level_count) |level| {
            const offset = level_offsets[level];
            const size = level_sizes[level];
            for (0..size) |index| {
                if (self.slots[offset + index].head == null) continue;
                const due = slot_due(@intCast(level), @intCast(index), self.now_ms);
                if (earliest == null or due < earliest.?) earliest = due;
            }
        }
        var overflow = self.overflow_head;
        while (overflow) |node| : (overflow = node.next) {
            const due = node.deadline_ms -| max_exact_delay_ms;
            if (earliest == null or due < earliest.?) earliest = due;
        }
        return earliest;
    }

    /// Moves far-future nodes into the wheel once they are within range.
    pub fn migrate_overflow(self: *Wheel) void {
        var current = self.overflow_head;
        while (current) |node| {
            const next = node.next;
            if (node.deadline_ms <= self.now_ms or
                node.deadline_ms - self.now_ms <= max_exact_delay_ms)
            {
                self.unlink_overflow(node);
                node.state = .idle;
                node.next = null;
                node.prev = null;
                node.owner = null;
                if (self.count != 0) self.count -= 1;
                self.insert(node, node.deadline_ms, node.callback, node.ctx);
            }
            current = next;
        }
    }

    /// Advances the wheel to `to_ms`, firing every callback whose deadline is
    /// due. Time never moves backwards.
    pub fn advance(self: *Wheel, to_ms: u64) void {
        self.migrate_overflow();
        while (true) {
            const event = self.next_event() orelse break;
            if (event.due_ms > to_ms) break;
            if (event.due_ms > self.now_ms) self.now_ms = event.due_ms;
            if (event.overflow) {
                self.migrate_overflow();
                continue;
            }
            self.expire_slot(@intCast(event.level), @intCast(event.index));
            self.migrate_overflow();
        }

        if (to_ms > self.now_ms) self.now_ms = to_ms;
    }

    const Event = struct {
        due_ms: u64,
        level: u3 = 0,
        index: u8 = 0,
        overflow: bool = false,
    };

    fn next_event(self: *const Wheel) ?Event {
        var earliest: ?Event = null;
        for (0..level_count) |level| {
            const offset = level_offsets[level];
            const size = level_sizes[level];
            for (0..size) |index| {
                if (self.slots[offset + index].head == null) continue;
                const due = slot_due(@intCast(level), @intCast(index), self.now_ms);
                if (earliest == null or due < earliest.?.due_ms) {
                    earliest = .{
                        .due_ms = due,
                        .level = @intCast(level),
                        .index = @intCast(index),
                    };
                }
            }
        }
        if (self.overflow_head) |node| {
            const due = node.deadline_ms -| max_exact_delay_ms;
            if (earliest == null or due < earliest.?.due_ms) {
                earliest = .{ .due_ms = due, .overflow = true };
            }
        }
        return earliest;
    }

    fn expire_slot(self: *Wheel, level: u3, index: u8) void {
        const slot = &self.slots[level_offsets[level] + index];
        const head = slot.head orelse return;
        const tail = slot.tail orelse unreachable;
        slot.head = null;
        slot.tail = null;

        // Join the whole slot to the processing list in O(1).
        head.prev = self.processing_tail;
        if (self.processing_tail) |previous_tail| {
            previous_tail.next = head;
        } else {
            self.processing_head = head;
        }
        self.processing_tail = tail;
        var current: ?*TimerNode = head;
        while (current) |node| {
            node.state = .processing;
            current = node.next;
        }

        while (self.processing_head) |node| {
            self.unlink_processing(node);
            node.state = .idle;
            node.next = null;
            node.prev = null;
            node.owner = null;
            self.count -= 1;
            if (node.deadline_ms > self.now_ms) {
                // The slot boundary arrived before the exact deadline.
                self.insert(node, node.deadline_ms, node.callback, node.ctx);
                continue;
            }
            node.callback(node.ctx);
        }
    }

    fn unlink_slot(self: *Wheel, slot: *Slot, node: *TimerNode) void {
        _ = self;
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            slot.head = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            slot.tail = node.prev;
        }
    }

    fn unlink_overflow(self: *Wheel, node: *TimerNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.overflow_head = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.overflow_tail = node.prev;
        }
    }

    fn unlink_processing(self: *Wheel, node: *TimerNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.processing_head = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.processing_tail = node.prev;
        }
    }
};

fn level_for_delta(delta_ms: u64) u3 {
    if (delta_ms < 256) return 0;
    if (delta_ms < 16_384) return 1;
    if (delta_ms < 1_048_576) return 2;
    return 3;
}

fn slot_due(level: u3, index: u8, now_ms: u64) u64 {
    const span_shift = level_span_shifts[level];
    const span = @as(u64, 1) << span_shift;
    const base = (now_ms >> span_shift) << span_shift;
    const due = base +| (@as(u64, index) << level_shifts[level]);
    return if (due < now_ms) due +| span else due;
}

/// Fires one callback and counts it in a test-owned counter.
fn test_callback(ctx: *anyopaque) void {
    const counter: *u32 = @ptrCast(@alignCast(ctx));
    counter.* += 1;
}

test "timer wheel: deadlines map to the expected levels" {
    var wheel = Wheel.init(1000);
    var nodes: [6]TimerNode = [_]TimerNode{.{}} ** 6;
    var counter: u32 = 0;

    wheel.insert(&nodes[0], 1200, test_callback, &counter); // level 0
    wheel.insert(&nodes[1], 3000, test_callback, &counter); // level 1
    wheel.insert(&nodes[2], 20_000, test_callback, &counter); // level 2
    wheel.insert(&nodes[3], 2_000_000, test_callback, &counter); // level 3
    wheel.insert(&nodes[4], 1200, test_callback, &counter);
    wheel.insert(&nodes[5], 1250, test_callback, &counter);

    try std.testing.expectEqual(@as(u3, 0), nodes[0].level);
    try std.testing.expectEqual(@as(u3, 1), nodes[1].level);
    try std.testing.expectEqual(@as(u3, 2), nodes[2].level);
    try std.testing.expectEqual(@as(u3, 3), nodes[3].level);
    try std.testing.expectEqual(@as(usize, 6), wheel.count);
}

test "timer wheel: advance fires only elapsed deadlines" {
    var wheel = Wheel.init(0);
    var nodes: [3]TimerNode = [_]TimerNode{.{}} ** 3;
    var counter: u32 = 0;

    wheel.insert(&nodes[0], 1, test_callback, &counter);
    wheel.insert(&nodes[1], 256, test_callback, &counter);
    wheel.insert(&nodes[2], 70_000, test_callback, &counter);

    wheel.advance(255);
    try std.testing.expectEqual(@as(u32, 1), counter);
    try std.testing.expectEqual(@as(usize, 2), wheel.count);

    wheel.advance(255);
    try std.testing.expectEqual(@as(u32, 1), counter);

    wheel.advance(256);
    try std.testing.expectEqual(@as(u32, 2), counter);

    wheel.advance(70_000);
    try std.testing.expectEqual(@as(u32, 3), counter);
    try std.testing.expectEqual(@as(usize, 0), wheel.count);
}

test "timer wheel: cancel, rearm, and exact oldest timestamps" {
    var wheel = Wheel.init(500);
    var node: TimerNode = .{};
    var counter: u32 = 0;

    wheel.insert(&node, 600, test_callback, &counter);
    try std.testing.expectEqual(@as(usize, 1), wheel.count);
    try std.testing.expect(wheel.remove(&node));
    try std.testing.expectEqual(@as(usize, 0), wheel.count);
    try std.testing.expect(!wheel.remove(&node));

    wheel.insert(&node, 800, test_callback, &counter);
    wheel.insert(&node, 700, test_callback, &counter);
    try std.testing.expectEqual(@as(usize, 1), wheel.count);
    try std.testing.expectEqual(@as(u64, 700), node.deadline_ms);

    wheel.advance(700);
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "timer wheel: callback may cancel a sibling in the same slot" {
    const Context = struct {
        wheel: *Wheel,
        sibling: *TimerNode,
        fired: u32 = 0,

        fn callback(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired += 1;
            _ = self.wheel.remove(self.sibling);
        }
    };

    var wheel = Wheel.init(0);
    var first: TimerNode = .{};
    var second: TimerNode = .{};
    var ctx = Context{ .wheel = &wheel, .sibling = &second };

    wheel.insert(&first, 10, Context.callback, &ctx);
    wheel.insert(&second, 10, Context.callback, &ctx);
    wheel.advance(10);
    try std.testing.expectEqual(@as(u32, 1), ctx.fired);
    try std.testing.expectEqual(@as(usize, 0), wheel.count);
}

test "timer wheel: far deadline re-inserts without firing early" {
    var wheel = Wheel.init(0);
    var node: TimerNode = .{};
    var counter: u32 = 0;

    const far = max_exact_delay_ms * 3;
    wheel.insert(&node, far, test_callback, &counter);

    wheel.advance(far - 1);
    try std.testing.expectEqual(@as(u32, 0), counter);
    try std.testing.expectEqual(@as(usize, 1), wheel.count);

    wheel.advance(far);
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "timer wheel: rearming the dispatching node does not double fire" {
    const Context = struct {
        wheel: *Wheel,
        node: *TimerNode,
        fired: u32 = 0,
        rearmed: bool = false,

        fn callback(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired += 1;
            if (self.rearmed) return;
            self.rearmed = true;
            self.wheel.insert_after(self.node, 5, callback, self);
        }
    };

    var wheel = Wheel.init(0);
    var node: TimerNode = .{};
    var ctx = Context{ .wheel = &wheel, .node = &node };

    wheel.insert(&node, 1, Context.callback, &ctx);
    wheel.advance(1);
    try std.testing.expectEqual(@as(u32, 1), ctx.fired);
    wheel.advance(6);
    try std.testing.expectEqual(@as(u32, 2), ctx.fired);
    try std.testing.expectEqual(@as(usize, 0), wheel.count);
}
