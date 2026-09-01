const std = @import("std");
const EntityIdType = @import("constants.zig").EntityIdType;
const component_store = @import("component_store.zig");

const EMPTY: EntityIdType = std.math.maxInt(EntityIdType);

// Sparse set backed by a flat array instead of a HashMap.
//
// sparse[entity_id] = dense index (or EMPTY if absent).
// Lookups are a single array read — no hashing, no probing.
//
// Trade-off: sparse array must cover the full entity ID range, so it allocates
// proportional to max_entity_id, not population count. Ideal when IDs are
// sequential (0..N) and the set is nearly full — exactly the game's case.
pub fn DenseSparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn componentStore(self: *Self) component_store.ComponentStore(T) {
            return component_store.denseSparseSetStore(T, self);
        }

        allocator: std.mem.Allocator,
        sparse: std.ArrayListUnmanaged(EntityIdType), // sparse[entity_id] -> dense index
        entity_ids: std.ArrayListUnmanaged(EntityIdType),
        values: std.ArrayListUnmanaged(T),
        mutation_count: usize,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .sparse = .empty,
                .entity_ids = .empty,
                .values = .empty,
                .mutation_count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.sparse.deinit(self.allocator);
            self.entity_ids.deinit(self.allocator);
            self.values.deinit(self.allocator);
        }

        // Pre-allocates for `capacity` entities with IDs in 0..capacity.
        // Fills the sparse array with EMPTY so membership checks are valid immediately.
        pub fn ensureTotalCapacity(self: *Self, capacity: usize) !void {
            try self.entity_ids.ensureTotalCapacity(self.allocator, capacity);
            try self.values.ensureTotalCapacity(self.allocator, capacity);
            const old_len = self.sparse.items.len;
            if (capacity > old_len) {
                try self.sparse.ensureTotalCapacity(self.allocator, capacity);
                self.sparse.items.len = capacity;
                @memset(self.sparse.items[old_len..capacity], EMPTY);
            }
        }

        // Called by World.runMemoryPressurePass at the start of each tick.
        // Two independent growth policies:
        //   1. Sparse array: always covers entity_budget (hard invariant — insert asserts this).
        //   2. Dense arrays: doubles when component population exceeds 80% of capacity,
        //      independent of entity_budget, since most entities won't carry every component.
        pub fn tickPressurePass(self: *Self, entity_budget: EntityIdType) !void {
            const old_len = self.sparse.items.len;
            if (entity_budget > old_len) {
                const new_len = @min(entity_budget * 2, @as(usize, std.math.maxInt(EntityIdType)));
                try self.sparse.ensureTotalCapacity(self.allocator, new_len);
                self.sparse.items.len = new_len;
                @memset(self.sparse.items[old_len..new_len], EMPTY);
            }
            const cap = self.entity_ids.capacity;
            const len = self.entity_ids.items.len;
            if (cap == 0 or len * 10 >= cap * 8) {
                const new_cap = if (cap == 0) 8 else cap * 2;
                try self.entity_ids.ensureTotalCapacity(self.allocator, new_cap);
                try self.values.ensureTotalCapacity(self.allocator, new_cap);
            }
        }

        pub fn insert(self: *Self, entity_id: EntityIdType, value: T) !void {
            // Sparse coverage must be pre-grown by the world's memory-pressure pass.
            std.debug.assert(entity_id < self.sparse.items.len);
            const idx = self.sparse.items[entity_id];
            if (idx != EMPTY) {
                self.values.items[idx] = value;
                return;
            }
            self.mutation_count += 1;
            const new_idx: EntityIdType = @intCast(self.entity_ids.items.len);
            try self.entity_ids.append(self.allocator, entity_id);
            errdefer _ = self.entity_ids.pop();
            try self.values.append(self.allocator, value);
            errdefer _ = self.values.pop();
            self.sparse.items[entity_id] = new_idx;
        }

        pub fn remove(self: *Self, entity_id: EntityIdType) bool {
            if (entity_id >= self.sparse.items.len) return false;
            const idx = self.sparse.items[entity_id];
            if (idx == EMPTY) return false;
            self.mutation_count += 1;
            self.sparse.items[entity_id] = EMPTY;
            const last = self.entity_ids.items.len - 1;
            if (idx != last) {
                const last_eid = self.entity_ids.items[last];
                self.entity_ids.items[idx] = last_eid;
                self.values.items[idx] = self.values.items[last];
                self.sparse.items[last_eid] = idx;
            }
            _ = self.entity_ids.pop();
            _ = self.values.pop();
            return true;
        }

        pub fn clear(self: *Self) void {
            self.mutation_count += 1;
            for (self.entity_ids.items) |eid| {
                self.sparse.items[eid] = EMPTY;
            }
            self.entity_ids.clearRetainingCapacity();
            self.values.clearRetainingCapacity();
        }

        pub fn has(self: *const Self, entity_id: EntityIdType) bool {
            if (entity_id >= self.sparse.items.len) return false;
            return self.sparse.items[entity_id] != EMPTY;
        }

        pub fn get(self: *Self, entity_id: EntityIdType) ?*T {
            if (entity_id >= self.sparse.items.len) return null;
            const idx = self.sparse.items[entity_id];
            if (idx == EMPTY) return null;
            return &self.values.items[idx];
        }

        pub fn getConst(self: *const Self, entity_id: EntityIdType) ?*const T {
            if (entity_id >= self.sparse.items.len) return null;
            const idx = self.sparse.items[entity_id];
            if (idx == EMPTY) return null;
            return &self.values.items[idx];
        }

        pub fn getCount(self: *const Self) usize {
            return self.entity_ids.items.len;
        }
    };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;
const TestValue = i32;

test "DenseSparseSet - basic insert, has, getConst, count" {
    var set = DenseSparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    try set.ensureTotalCapacity(11);
    try set.insert(5, 100);
    try set.insert(10, 200);

    try testing.expect(set.has(5));
    try testing.expect(set.has(10));
    try testing.expect(!set.has(999));
    try testing.expectEqual(@as(usize, 2), set.getCount());
    try testing.expectEqual(@as(TestValue, 100), set.getConst(5).?.*);

    try set.insert(5, 999);
    try testing.expectEqual(@as(TestValue, 999), set.getConst(5).?.*);
    try testing.expectEqual(@as(usize, 2), set.getCount());
}

test "DenseSparseSet - remove with swap-remove" {
    var set = DenseSparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    try set.ensureTotalCapacity(4);
    try set.insert(1, 10);
    try set.insert(2, 20);
    try set.insert(3, 30);

    try testing.expect(set.remove(2));
    try testing.expect(!set.has(2));
    try testing.expectEqual(@as(usize, 2), set.getCount());
    try testing.expectEqual(@as(TestValue, 30), set.getConst(3).?.*);
}

test "DenseSparseSet - clear resets membership" {
    var set = DenseSparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    try set.ensureTotalCapacity(3);
    try set.insert(1, 10);
    try set.insert(2, 20);
    set.clear();

    try testing.expectEqual(@as(usize, 0), set.getCount());
    try testing.expect(!set.has(1));
    try testing.expect(!set.has(2));
}

test "DenseSparseSet - ensureTotalCapacity then insert" {
    var set = DenseSparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    try set.ensureTotalCapacity(1000);
    for (0..1000) |i| try set.insert(@intCast(i), @intCast(i * 2));

    try testing.expectEqual(@as(usize, 1000), set.getCount());
    try testing.expectEqual(@as(TestValue, 42), set.getConst(21).?.*);
}

test "DenseSparseSet - dense slice mutation visible via getConst" {
    var set = DenseSparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    try set.ensureTotalCapacity(3);
    try set.insert(1, 10);
    try set.insert(2, 20);

    for (set.values.items) |*p| p.* *= 2;

    try testing.expectEqual(@as(TestValue, 20), set.getConst(1).?.*);
    try testing.expectEqual(@as(TestValue, 40), set.getConst(2).?.*);
}

test "tickPressurePass - DenseSparseSet sparse doubles to 2x entity_budget" {
    var set = DenseSparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    try set.tickPressurePass(5);
    // sparse must cover at least 2x the budget for headroom
    try testing.expect(set.sparse.items.len >= 10);
    // all slots must be EMPTY so has() is correct without insert
    try testing.expect(!set.has(0));
    try testing.expect(!set.has(4));
}

test "tickPressurePass - DenseSparseSet skips sparse grow when already covered" {
    var set = DenseSparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    try set.tickPressurePass(5); // grows sparse to >= 10
    const len_after_first = set.sparse.items.len;

    try set.tickPressurePass(6); // 6 <= len_after_first, no grow
    try testing.expectEqual(len_after_first, set.sparse.items.len);
}

test "tickPressurePass - DenseSparseSet dense doubles when population >= 80%" {
    var set = DenseSparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    // Establish initial dense capacity via first tickPressurePass (cap==0 branch).
    // Sparse must cover entity IDs we will insert; grow it independently.
    try set.tickPressurePass(20);
    const initial_cap = set.entity_ids.capacity;
    try testing.expect(initial_cap > 0);

    // Fill to 75% of initial_cap — below threshold, capacity must not grow.
    const below_threshold = initial_cap * 3 / 4;
    for (0..below_threshold) |i| try set.insert(@intCast(i), @intCast(i));
    try set.tickPressurePass(20);
    try testing.expectEqual(initial_cap, set.entity_ids.capacity);

    // Fill past 80% — capacity must at least double.
    const above_threshold = initial_cap * 9 / 10;
    for (below_threshold..above_threshold) |i| try set.insert(@intCast(i), @intCast(i));
    try set.tickPressurePass(20);
    try testing.expect(set.entity_ids.capacity >= initial_cap * 2);
}
