const std = @import("std");
const EntityIdType = @import("constants.zig").EntityIdType;
const component_store = @import("component_store.zig");

/// Optional structural-change hook installed by GroupRuntime on full-owning
/// group member stores. Value-only insert must not invoke these callbacks.
/// `swapDense` never invokes them (R1).
pub const GroupHook = struct {
    ctx: *anyopaque,
    field_id: u32,
    on_after_insert: *const fn (ctx: *anyopaque, field_id: u32, entity_id: EntityIdType) void,
    on_before_remove: *const fn (ctx: *anyopaque, field_id: u32, entity_id: EntityIdType) void,
};

pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Elem = T;

        pub fn componentStore(self: *Self) component_store.ComponentStore(T) {
            return component_store.sparseSetStore(T, self);
        }

        allocator: std.mem.Allocator,
        // entity_id -> index into dense arrays
        sparse: std.AutoHashMapUnmanaged(EntityIdType, EntityIdType),
        // SoA dense arrays (cache-friendly iteration)
        entity_ids: std.ArrayListUnmanaged(EntityIdType),
        values: std.ArrayListUnmanaged(T),
        // Incremented on structural changes (insert new, remove, clear).
        // Captured by iterators to detect mutation during iteration in debug builds.
        mutation_count: usize,
        /// Set by GroupRuntime after World is at its final address. Null for
        /// ungrouped stores (default).
        group_hook: ?GroupHook,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .sparse = .empty,
                .entity_ids = .empty,
                .values = .empty,
                .mutation_count = 0,
                .group_hook = null,
            };
        }

        pub fn ensureTotalCapacity(self: *Self, capacity: usize) !void {
            try self.entity_ids.ensureTotalCapacity(self.allocator, capacity);
            try self.values.ensureTotalCapacity(self.allocator, capacity);
            try self.sparse.ensureTotalCapacity(self.allocator, @intCast(capacity));
        }

        // Called by World.runMemoryPressurePass at the start of each tick.
        // Doubles dense capacity when population exceeds 80% of current capacity,
        // giving systems headroom to insert without triggering mid-tick reallocation.
        // entity_budget is unused — SparseSet's sparse index self-manages via insert.
        pub fn tickPressurePass(self: *Self, entity_budget: EntityIdType) !void {
            _ = entity_budget;
            const cap = self.entity_ids.capacity;
            const len = self.entity_ids.items.len;
            if (cap == 0 or len * 10 >= cap * 8) {
                const new_cap = if (cap == 0) 8 else cap * 2;
                try self.ensureTotalCapacity(new_cap);
            }
        }

        pub fn deinit(self: *Self) void {
            self.sparse.deinit(self.allocator);
            self.entity_ids.deinit(self.allocator);
            self.values.deinit(self.allocator);
        }

        /// Bulk clear. Panics in safe builds when a group hook is installed —
        /// clearing a single owned store would desync group size (R5). Use
        /// `World.clearGroup` or per-entity `remove` / `destroyEntity`.
        pub fn clear(self: *Self) void {
            if (self.group_hook != null) {
                @panic("SparseSet.clear on group-owned store; use World.clearGroup or per-entity remove/destroyEntity");
            }
            self.mutation_count += 1;
            self.sparse.clearRetainingCapacity();
            self.entity_ids.clearRetainingCapacity();
            self.values.clearRetainingCapacity();
        }

        /// Clear dense + sparse without the group-hook guard. Only for
        /// GroupRuntime / World multi-store clear paths that keep size in sync.
        pub fn clearUnchecked(self: *Self) void {
            self.mutation_count += 1;
            self.sparse.clearRetainingCapacity();
            self.entity_ids.clearRetainingCapacity();
            self.values.clearRetainingCapacity();
        }

        /// Pure dense-slot permute: swaps entity_ids, values, and sparse indices.
        /// Does **not** invoke group_hook or go through insert/remove (R1).
        pub fn swapDense(self: *Self, i: usize, j: usize) void {
            if (i == j) return;
            std.debug.assert(i < self.entity_ids.items.len);
            std.debug.assert(j < self.entity_ids.items.len);

            const eid_i = self.entity_ids.items[i];
            const eid_j = self.entity_ids.items[j];

            self.entity_ids.items[i] = eid_j;
            self.entity_ids.items[j] = eid_i;

            const tmp_v = self.values.items[i];
            self.values.items[i] = self.values.items[j];
            self.values.items[j] = tmp_v;

            self.sparse.getPtr(eid_i).?.* = @intCast(j);
            self.sparse.getPtr(eid_j).?.* = @intCast(i);
        }

        /// Dense index of `entity_id`, or null if absent.
        pub fn indexOf(self: *const Self, entity_id: EntityIdType) ?usize {
            const idx = self.sparse.get(entity_id) orelse return null;
            return @intCast(idx);
        }

        pub fn insert(self: *Self, entity_id: EntityIdType, value: T) !void {
            if (self.sparse.get(entity_id)) |idx| {
                // Value-only update: no structural change, no reallocation risk, no hook.
                self.values.items[idx] = value;
                return;
            }
            self.mutation_count += 1;
            const idx: u32 = @intCast(self.entity_ids.items.len);
            // Reserve all capacity before any mutation so failure leaves state clean.
            try self.entity_ids.ensureUnusedCapacity(self.allocator, 1);
            try self.values.ensureUnusedCapacity(self.allocator, 1);
            try self.sparse.ensureUnusedCapacity(self.allocator, 1);
            // All capacity guaranteed — these cannot fail.
            self.entity_ids.appendAssumeCapacity(entity_id);
            self.values.appendAssumeCapacity(value);
            self.sparse.putAssumeCapacity(entity_id, idx);

            if (self.group_hook) |hook| {
                hook.on_after_insert(hook.ctx, hook.field_id, entity_id);
            }
        }

        pub fn remove(self: *Self, entity_id: EntityIdType) bool {
            if (!self.sparse.contains(entity_id)) return false;

            // Hook first while sparse index is still valid (R6). Unpack may
            // swapDense the entity to a new dense slot; re-fetch index after.
            if (self.group_hook) |hook| {
                hook.on_before_remove(hook.ctx, hook.field_id, entity_id);
            }

            const idx = self.sparse.get(entity_id) orelse return false;
            self.mutation_count += 1;
            _ = self.sparse.remove(entity_id);

            const last = self.entity_ids.items.len - 1;
            if (idx != last) {
                const last_eid = self.entity_ids.items[last];
                self.entity_ids.items[idx] = last_eid;
                self.values.items[idx] = self.values.items[last];
                // Update the moved entity's dense index in-place.
                self.sparse.getPtr(last_eid).?.* = idx;
            }
            _ = self.entity_ids.pop();
            _ = self.values.pop();
            return true;
        }

        pub fn has(self: *const Self, entity_id: EntityIdType) bool {
            return self.sparse.contains(entity_id);
        }

        pub fn get(self: *Self, entity_id: EntityIdType) ?*T {
            const idx = self.sparse.get(entity_id) orelse return null;
            return &self.values.items[idx];
        }

        pub fn getConst(self: *const Self, entity_id: EntityIdType) ?*const T {
            const idx = self.sparse.get(entity_id) orelse return null;
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

test "SparseSet - basic insert, has, getConst, count" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    var v: TestValue = 100;
    try set.insert(5, v);
    v = 200;
    try set.insert(10, v);

    try testing.expect(set.has(5));
    try testing.expect(set.has(10));
    try testing.expect(!set.has(999));

    try testing.expectEqual(@as(usize, 2), set.getCount());

    try testing.expectEqual(@as(TestValue, 100), set.getConst(5).?.*);
    v = 999;
    try set.insert(5, v);
    try testing.expectEqual(@as(TestValue, 999), set.getConst(5).?.*);
}

test "SparseSet - update existing entity" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    var v: TestValue = 123;
    try set.insert(42, v);
    try testing.expectEqual(@as(usize, 1), set.getCount());

    v = 999;
    try set.insert(42, v);
    try testing.expectEqual(@as(usize, 1), set.getCount());
    try testing.expectEqual(@as(TestValue, 999), set.getConst(42).?.*);
}

test "SparseSet - remove with swap-remove" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    var v: TestValue = 10;
    try set.insert(1, v);
    v = 20;
    try set.insert(2, v);
    v = 30;
    try set.insert(3, v);

    _ = set.remove(2);

    try testing.expect(!set.has(2));
    try testing.expectEqual(@as(usize, 2), set.getCount());

    // entity 3 was swap-moved into dense slot 1
    try testing.expectEqual(@as(TestValue, 30), set.getConst(3).?.*);
}

test "SparseSet - slice iteration sums values" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    var v: TestValue = 100;
    try set.insert(10, v);
    v = 200;
    try set.insert(20, v);

    var sum: i32 = 0;
    for (set.values.items) |x| sum += x;

    try testing.expectEqual(@as(i32, 300), sum);
}

test "SparseSet - slice iteration preserves insertion order" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    var v: TestValue = 100;
    try set.insert(10, v);
    v = 200;
    try set.insert(20, v);
    v = 50;
    try set.insert(5, v);

    const ids = set.entity_ids.items;
    const vals = set.values.items;
    try testing.expectEqual(@as(EntityIdType, 10), ids[0]);
    try testing.expectEqual(@as(TestValue, 100), vals[0]);
    try testing.expectEqual(@as(EntityIdType, 20), ids[1]);
    try testing.expectEqual(@as(TestValue, 200), vals[1]);
    try testing.expectEqual(@as(EntityIdType, 5), ids[2]);
    try testing.expectEqual(@as(TestValue, 50), vals[2]);
}

test "SparseSet - clear resets everything" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    var v: TestValue = 10;
    try set.insert(1, v);
    v = 20;
    try set.insert(2, v);

    set.clear();

    try testing.expectEqual(@as(usize, 0), set.getCount());
    try testing.expect(!set.has(1));
    try testing.expect(!set.has(2));
}

test "SparseSet - insert remove insert reuses slot correctly" {
    // Exercises the swap-remove + sparse update path.
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    var v: TestValue = 10;
    try set.insert(1, v);
    v = 20;
    try set.insert(2, v);
    v = 30;
    try set.insert(3, v);

    _ = set.remove(2);
    try testing.expect(!set.has(2));
    try testing.expect(set.has(1));
    try testing.expect(set.has(3));

    v = 25;
    try set.insert(2, v);
    try testing.expect(set.has(2));
    try testing.expectEqual(@as(TestValue, 25), set.getConst(2).?.*);
    try testing.expectEqual(@as(usize, 3), set.getCount());
}

test "SparseSet - dense slice mutation visible via getConst" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    var v: TestValue = 10;
    try set.insert(1, v);
    v = 20;
    try set.insert(2, v);
    v = 30;
    try set.insert(3, v);

    for (set.values.items) |*p| p.* *= 2;

    try testing.expectEqual(@as(TestValue, 20), set.getConst(1).?.*);
    try testing.expectEqual(@as(TestValue, 40), set.getConst(2).?.*);
    try testing.expectEqual(@as(TestValue, 60), set.getConst(3).?.*);
}

test "SparseSet - many insert/remove cycles" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    var i: EntityIdType = 0;
    while (i < 32) : (i += 1) {
        const v: TestValue = @intCast(i * 10);
        try set.insert(i, v);
    }
    try testing.expectEqual(@as(usize, 32), set.getCount());

    // Remove all even-numbered entities
    i = 0;
    while (i < 32) : (i += 2) {
        try testing.expect(set.remove(i));
    }
    try testing.expectEqual(@as(usize, 16), set.getCount());

    // Odd entities must still be present with correct values
    i = 1;
    while (i < 32) : (i += 2) {
        try testing.expect(set.has(i));
        try testing.expectEqual(@as(TestValue, @intCast(i * 10)), set.getConst(i).?.*);
    }

    // Even entities must be gone
    i = 0;
    while (i < 32) : (i += 2) {
        try testing.expect(!set.has(i));
    }
}

test "tickPressurePass - SparseSet dense doubles when population >= 80%" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    // Establish initial dense capacity via the cap==0 branch.
    try set.tickPressurePass(0);
    const initial_cap = set.entity_ids.capacity;
    try testing.expect(initial_cap > 0);

    // Fill to 75% of initial_cap — below threshold, capacity must not grow.
    const below_threshold = initial_cap * 3 / 4;
    for (0..below_threshold) |i| try set.insert(@intCast(i), @intCast(i));
    try set.tickPressurePass(0);
    try testing.expectEqual(initial_cap, set.entity_ids.capacity);

    // Fill past 80% — capacity must at least double.
    const above_threshold = initial_cap * 9 / 10;
    for (below_threshold..above_threshold) |i| try set.insert(@intCast(i), @intCast(i));
    try set.tickPressurePass(0);
    try testing.expect(set.entity_ids.capacity >= initial_cap * 2);
}

test "SparseSet.swapDense - permutes entity_ids, values, and sparse" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();

    try set.insert(10, 100);
    try set.insert(20, 200);
    try set.insert(30, 300);

    set.swapDense(0, 2);

    try testing.expectEqual(@as(EntityIdType, 30), set.entity_ids.items[0]);
    try testing.expectEqual(@as(EntityIdType, 20), set.entity_ids.items[1]);
    try testing.expectEqual(@as(EntityIdType, 10), set.entity_ids.items[2]);
    try testing.expectEqual(@as(TestValue, 300), set.values.items[0]);
    try testing.expectEqual(@as(TestValue, 200), set.values.items[1]);
    try testing.expectEqual(@as(TestValue, 100), set.values.items[2]);
    try testing.expectEqual(@as(usize, 2), set.indexOf(10).?);
    try testing.expectEqual(@as(usize, 1), set.indexOf(20).?);
    try testing.expectEqual(@as(usize, 0), set.indexOf(30).?);
    // get still works after permute
    try testing.expectEqual(@as(TestValue, 100), set.getConst(10).?.*);
    try testing.expectEqual(@as(TestValue, 300), set.getConst(30).?.*);
}

test "SparseSet.swapDense - no-op when i == j" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();
    try set.insert(1, 10);
    try set.insert(2, 20);
    set.swapDense(1, 1);
    try testing.expectEqual(@as(EntityIdType, 1), set.entity_ids.items[0]);
    try testing.expectEqual(@as(EntityIdType, 2), set.entity_ids.items[1]);
}

const HookCounter = struct {
    after_insert: usize = 0,
    before_remove: usize = 0,
    last_entity: EntityIdType = 0,
    last_field_id: u32 = 0,

    fn onAfter(ctx: *anyopaque, field_id: u32, entity_id: EntityIdType) void {
        const self: *HookCounter = @ptrCast(@alignCast(ctx));
        self.after_insert += 1;
        self.last_entity = entity_id;
        self.last_field_id = field_id;
    }
    fn onBefore(ctx: *anyopaque, field_id: u32, entity_id: EntityIdType) void {
        const self: *HookCounter = @ptrCast(@alignCast(ctx));
        self.before_remove += 1;
        self.last_entity = entity_id;
        self.last_field_id = field_id;
    }
};

test "SparseSet group_hook - structural insert fires on_after_insert" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();
    var counter: HookCounter = .{};
    set.group_hook = .{
        .ctx = &counter,
        .field_id = 7,
        .on_after_insert = HookCounter.onAfter,
        .on_before_remove = HookCounter.onBefore,
    };

    try set.insert(5, 50);
    try testing.expectEqual(@as(usize, 1), counter.after_insert);
    try testing.expectEqual(@as(usize, 0), counter.before_remove);
    try testing.expectEqual(@as(EntityIdType, 5), counter.last_entity);
    try testing.expectEqual(@as(u32, 7), counter.last_field_id);
}

test "SparseSet group_hook - value-only insert does not fire" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();
    var counter: HookCounter = .{};
    set.group_hook = .{
        .ctx = &counter,
        .field_id = 1,
        .on_after_insert = HookCounter.onAfter,
        .on_before_remove = HookCounter.onBefore,
    };

    try set.insert(5, 50);
    try testing.expectEqual(@as(usize, 1), counter.after_insert);

    try set.insert(5, 99); // value update
    try testing.expectEqual(@as(usize, 1), counter.after_insert);
    try testing.expectEqual(@as(usize, 0), counter.before_remove);
    try testing.expectEqual(@as(TestValue, 99), set.getConst(5).?.*);
}

test "SparseSet group_hook - remove fires on_before_remove while still present" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();
    var counter: HookCounter = .{};

    const Watcher = struct {
        set: *SparseSet(TestValue),
        counter: *HookCounter,
        saw_entity: bool = false,
        had_index: bool = false,

        fn onBefore(ctx: *anyopaque, field_id: u32, entity_id: EntityIdType) void {
            _ = field_id;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.counter.before_remove += 1;
            self.counter.last_entity = entity_id;
            // Entity must still be queryable during the hook (R6).
            self.saw_entity = self.set.has(entity_id);
            self.had_index = self.set.indexOf(entity_id) != null;
        }
        fn onAfter(ctx: *anyopaque, field_id: u32, entity_id: EntityIdType) void {
            _ = ctx;
            _ = field_id;
            _ = entity_id;
        }
    };
    var watcher: Watcher = .{ .set = &set, .counter = &counter };
    set.group_hook = .{
        .ctx = &watcher,
        .field_id = 3,
        .on_after_insert = Watcher.onAfter,
        .on_before_remove = Watcher.onBefore,
    };

    try set.insert(9, 90);
    try testing.expect(set.remove(9));
    try testing.expectEqual(@as(usize, 1), counter.before_remove);
    try testing.expectEqual(@as(EntityIdType, 9), counter.last_entity);
    try testing.expect(watcher.saw_entity);
    try testing.expect(watcher.had_index);
    try testing.expect(!set.has(9));
}

test "SparseSet.swapDense - does not invoke group_hook" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();
    var counter: HookCounter = .{};
    set.group_hook = .{
        .ctx = &counter,
        .field_id = 0,
        .on_after_insert = HookCounter.onAfter,
        .on_before_remove = HookCounter.onBefore,
    };

    try set.insert(1, 10);
    try set.insert(2, 20);
    const inserts = counter.after_insert;
    set.swapDense(0, 1);
    try testing.expectEqual(inserts, counter.after_insert);
    try testing.expectEqual(@as(usize, 0), counter.before_remove);
}

test "SparseSet.clearUnchecked - clears while hooked without panic" {
    var set = SparseSet(TestValue).init(testing.allocator);
    defer set.deinit();
    var counter: HookCounter = .{};
    set.group_hook = .{
        .ctx = &counter,
        .field_id = 0,
        .on_after_insert = HookCounter.onAfter,
        .on_before_remove = HookCounter.onBefore,
    };
    try set.insert(1, 10);
    set.clearUnchecked();
    try testing.expectEqual(@as(usize, 0), set.getCount());
    try testing.expect(!set.has(1));
}
