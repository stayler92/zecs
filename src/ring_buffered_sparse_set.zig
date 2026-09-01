const std = @import("std");
const EntityIdType = @import("constants.zig").EntityIdType;
const component_store = @import("component_store.zig");

pub fn RingBufferedSparseSet(comptime T: type, comptime N: usize) type {
    comptime std.debug.assert(N >= 2);

    return struct {
        const Self = @This();

        pub fn componentStore(self: *Self) component_store.ComponentStore(T) {
            return component_store.ringBufferedSparseSetStore(T, N, self);
        }

        allocator: std.mem.Allocator,
        sparse: std.AutoHashMapUnmanaged(EntityIdType, EntityIdType),
        entity_ids: std.ArrayListUnmanaged(EntityIdType),
        // N parallel value arrays — all kept at equal length.
        // values[write_idx] is the current write target for update systems.
        values: [N]std.ArrayListUnmanaged(T),
        write_idx: usize,

        pub fn init(allocator: std.mem.Allocator) Self {
            var vals: [N]std.ArrayListUnmanaged(T) = undefined;
            for (&vals) |*v| v.* = .empty;
            return .{
                .allocator = allocator,
                .sparse = .empty,
                .entity_ids = .empty,
                .values = vals,
                .write_idx = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.sparse.deinit(self.allocator);
            self.entity_ids.deinit(self.allocator);
            for (&self.values) |*v| v.deinit(self.allocator);
        }

        pub fn ensureTotalCapacity(self: *Self, capacity: usize) !void {
            try self.sparse.ensureTotalCapacity(self.allocator, @intCast(capacity));
            try self.entity_ids.ensureTotalCapacity(self.allocator, capacity);
            for (&self.values) |*v| try v.ensureTotalCapacity(self.allocator, capacity);
        }

        // Called by World.runMemoryPressurePass at the start of each tick.
        // Doubles all dense buffers (entity_ids + all N value arrays) when population
        // exceeds 80% of current capacity. Sparse index self-manages via insert.
        pub fn tickPressurePass(self: *Self, entity_budget: EntityIdType) !void {
            _ = entity_budget;
            const cap = self.entity_ids.capacity;
            const len = self.entity_ids.items.len;
            if (cap == 0 or len * 10 >= cap * 8) {
                const new_cap = if (cap == 0) 8 else cap * 2;
                try self.ensureTotalCapacity(new_cap);
            }
        }

        // Inserts entity with value. If entity already exists, overwrites all N
        // buffers with the new value — authoritative set, avoids lerp artifact on
        // forced repositions (e.g. teleport).
        pub fn insert(self: *Self, entity_id: EntityIdType, value: T) !void {
            if (self.sparse.get(entity_id)) |idx| {
                for (&self.values) |*v| v.items[idx] = value;
                return;
            }
            const idx: EntityIdType = @intCast(self.entity_ids.items.len);
            // Reserve all capacity before any mutation so failure leaves state clean.
            try self.entity_ids.ensureUnusedCapacity(self.allocator, 1);
            for (&self.values) |*v| try v.ensureUnusedCapacity(self.allocator, 1);
            try self.sparse.ensureUnusedCapacity(self.allocator, 1);
            // All capacity guaranteed — these cannot fail.
            self.entity_ids.appendAssumeCapacity(entity_id);
            for (&self.values) |*v| v.appendAssumeCapacity(value);
            self.sparse.putAssumeCapacity(entity_id, idx);
        }

        pub fn remove(self: *Self, entity_id: EntityIdType) bool {
            const idx = self.sparse.get(entity_id) orelse return false;
            _ = self.sparse.remove(entity_id);

            const last = self.entity_ids.items.len - 1;
            if (idx != last) {
                const last_eid = self.entity_ids.items[last];
                self.entity_ids.items[idx] = last_eid;
                for (&self.values) |*v| v.items[idx] = v.items[last];
                self.sparse.getPtr(last_eid).?.* = idx;
            }
            _ = self.entity_ids.pop();
            for (&self.values) |*v| _ = v.pop();
            return true;
        }

        pub fn has(self: *const Self, entity_id: EntityIdType) bool {
            return self.sparse.contains(entity_id);
        }

        pub fn get(self: *Self, entity_id: EntityIdType) ?*T {
            const idx = self.sparse.get(entity_id) orelse return null;
            return &self.values[self.write_idx].items[idx];
        }

        pub fn getCount(self: *const Self) usize {
            return self.entity_ids.items.len;
        }

        // Advances the ring: seeds the next write buffer from the current one
        // (so systems can read-modify-write without stale starting state), then
        // rotates write_idx. Call after render and before the next sim tick.
        pub fn advance(self: *Self) void {
            const next = (self.write_idx + 1) % N;
            const src = self.values[self.write_idx].items;
            const dst = self.values[next].items;
            std.debug.assert(src.len == dst.len);
            @memcpy(dst, src);
            self.write_idx = next;
        }

        // Renderer reads: values from the most recently completed tick.
        pub fn currentSlice(self: *const Self) []const T {
            return self.values[self.write_idx].items;
        }

        // Renderer reads: values from the tick before current — lerp target.
        pub fn previousSlice(self: *const Self) []const T {
            return self.values[(self.write_idx + N - 1) % N].items;
        }

        pub fn entitySlice(self: *const Self) []const EntityIdType {
            return self.entity_ids.items;
        }

        // Mutable slice into the write buffer — for ComponentStore(T) adapter.
        pub fn writeSlice(self: *Self) []T {
            return self.values[self.write_idx].items;
        }
    };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;

test "RingBufferedSparseSet - insert, has, get, getCount" {
    var s = RingBufferedSparseSet(i32, 2).init(testing.allocator);
    defer s.deinit();

    try s.insert(1, 10);
    try s.insert(2, 20);

    try testing.expect(s.has(1));
    try testing.expect(s.has(2));
    try testing.expect(!s.has(99));
    try testing.expectEqual(@as(usize, 2), s.getCount());
    try testing.expectEqual(@as(i32, 10), s.get(1).?.*);
}

test "RingBufferedSparseSet - insert writes initial value to all N buffers" {
    var s = RingBufferedSparseSet(i32, 3).init(testing.allocator);
    defer s.deinit();

    try s.insert(5, 42);

    for (s.values) |v| {
        try testing.expectEqual(@as(i32, 42), v.items[0]);
    }
}

test "RingBufferedSparseSet - insert existing overwrites all N buffers" {
    var s = RingBufferedSparseSet(i32, 2).init(testing.allocator);
    defer s.deinit();

    try s.insert(1, 10);
    // Simulate advance so buffers diverge
    s.values[1].items[0] = 99;
    // Authoritative update must reset both
    try s.insert(1, 55);
    try testing.expectEqual(@as(i32, 55), s.values[0].items[0]);
    try testing.expectEqual(@as(i32, 55), s.values[1].items[0]);
}

test "RingBufferedSparseSet - remove with swap-remove" {
    var s = RingBufferedSparseSet(i32, 2).init(testing.allocator);
    defer s.deinit();

    try s.insert(1, 10);
    try s.insert(2, 20);
    try s.insert(3, 30);

    try testing.expect(s.remove(2));
    try testing.expect(!s.has(2));
    try testing.expectEqual(@as(usize, 2), s.getCount());
    // entity 3 swap-moved to slot 1
    try testing.expectEqual(@as(i32, 30), s.get(3).?.*);
}

test "RingBufferedSparseSet - advance seeds next buffer and rotates write_idx" {
    var s = RingBufferedSparseSet(i32, 2).init(testing.allocator);
    defer s.deinit();

    try s.insert(1, 0);

    // Tick 0: system writes to write_idx=0
    s.values[0].items[0] = 100;

    // advance: seed buffer 1 from buffer 0, rotate
    s.advance();

    try testing.expectEqual(@as(usize, 1), s.write_idx);
    try testing.expectEqual(@as(i32, 100), s.values[1].items[0]);
}

test "RingBufferedSparseSet - currentSlice and previousSlice" {
    var s = RingBufferedSparseSet(i32, 2).init(testing.allocator);
    defer s.deinit();

    try s.insert(1, 0);

    // Tick 0: write to buffer 0
    s.values[0].items[0] = 10;
    // Render before advance: current=10, previous=initial value (0)
    try testing.expectEqual(@as(i32, 10), s.currentSlice()[0]);
    try testing.expectEqual(@as(i32, 0), s.previousSlice()[0]);

    s.advance();

    // Tick 1: write to buffer 1
    s.values[1].items[0] = 20;
    // Render: current=20, previous=10
    try testing.expectEqual(@as(i32, 20), s.currentSlice()[0]);
    try testing.expectEqual(@as(i32, 10), s.previousSlice()[0]);
}

test "RingBufferedSparseSet - N=3 ring wraps correctly" {
    var s = RingBufferedSparseSet(i32, 3).init(testing.allocator);
    defer s.deinit();

    try s.insert(1, 0);

    s.values[0].items[0] = 1;
    s.advance(); // write_idx=1, buf1=1
    s.values[1].items[0] = 2;
    s.advance(); // write_idx=2, buf2=2
    s.values[2].items[0] = 3;

    try testing.expectEqual(@as(usize, 2), s.write_idx);
    try testing.expectEqual(@as(i32, 3), s.currentSlice()[0]);
    try testing.expectEqual(@as(i32, 2), s.previousSlice()[0]);

    s.advance(); // write_idx=0 (wraps)
    try testing.expectEqual(@as(usize, 0), s.write_idx);
}

test "RingBufferedSparseSet - remove keeps all value buffers in sync" {
    var s = RingBufferedSparseSet(i32, 2).init(testing.allocator);
    defer s.deinit();

    try s.insert(1, 10);
    try s.insert(2, 20);
    try s.insert(3, 30);

    _ = s.remove(1);

    // All value buffers must have same length
    try testing.expectEqual(s.values[0].items.len, s.values[1].items.len);
    try testing.expectEqual(@as(usize, 2), s.getCount());
}
