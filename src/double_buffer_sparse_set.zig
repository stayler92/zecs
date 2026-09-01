const std = @import("std");
const SparseSet = @import("sparse_set.zig").SparseSet;
const EntityIdType = @import("constants.zig").EntityIdType;

// A double-buffered wrapper around SparseSet.
//
// Systems read and write directly to the back buffer each tick.
// The front buffer is a stable snapshot for observers (render, net, tests).
// At the end of each tick the World calls advance() on each store,
// which advances back_idx (ping-pong). Systems and observers
// obtain the current buffer via backBuffer()/frontBuffer().
pub fn DoubleBufferedSparseSet(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Store = SparseSet(T);

        pub const Command = union(enum) {
            add: struct { entity_id: EntityIdType, data: T },
            remove: EntityIdType,
        };

        stores: [2]Store,
        back_idx: u1,

        allocator: std.mem.Allocator,
        // Deferred mutations applied in order during swap().
        // ArrayListUnmanaged makes the no-stored-allocator contract explicit.
        pending: std.ArrayListUnmanaged(Command),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .stores = .{ Store.init(allocator), Store.init(allocator) },
                .back_idx = 0,
                .pending = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.stores[0].deinit();
            self.stores[1].deinit();
            self.pending.deinit(self.allocator);
        }

        pub fn tickPressurePass(self: *Self, entity_budget: EntityIdType) !void {
            try self.stores[0].tickPressurePass(entity_budget);
            try self.stores[1].tickPressurePass(entity_budget);
        }

        pub fn backBuffer(self: *Self) *Store {
            return &self.stores[self.back_idx];
        }

        pub fn frontBuffer(self: *Self) *Store {
            return &self.stores[self.back_idx ^ 1];
        }

        // Drains the pending command queue into both buffers, then advances
        // back_idx. Commands are applied in submission order before the flip
        // so that the new front (visible to observers) and new back
        // (visible to systems next tick) are both up to date.
        pub fn swap(self: *Self) void {
            for (self.pending.items) |cmd| {
                switch (cmd) {
                    .add => |a| self.insert(a.entity_id, a.data) catch @panic("DoubleBufferedSparseSet.swap: insert failed (OOM)"),
                    .remove => |eid| self.remove(eid),
                }
            }
            self.pending.clearRetainingCapacity();
            self.back_idx ^= 1;
        }

        /// Duck-typed by World.advanceRingBuffers. Same as swap().
        pub fn advance(self: *Self) void {
            self.swap();
        }

        // Queue an add command. The value is copied immediately; the insert
        // happens on the next swap().
        pub fn queueAdd(self: *Self, entity_id: EntityIdType, value: T) !void {
            try self.pending.append(self.allocator, .{ .add = .{ .entity_id = entity_id, .data = value } });
        }

        // Queue a remove command. The removal happens on the next swap().
        pub fn queueRemove(self: *Self, entity_id: EntityIdType) !void {
            try self.pending.append(self.allocator, .{ .remove = entity_id });
        }

        // Inserts into both buffers so the entity is visible immediately
        // without waiting for a swap.
        pub fn insert(self: *Self, id: EntityIdType, value: T) !void {
            try self.stores[0].insert(id, value);
            errdefer _ = self.stores[0].remove(id);
            try self.stores[1].insert(id, value);
        }

        // Removes from both buffers so the entity is gone immediately
        // without waiting for a swap. Symmetric to insert.
        pub fn remove(self: *Self, id: EntityIdType) void {
            _ = self.stores[0].remove(id);
            _ = self.stores[1].remove(id);
        }
    };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;
const TestValue = i32;

test "queueAdd - entity absent before swap, present in both buffers after" {
    var db = DoubleBufferedSparseSet(TestValue).init(testing.allocator);
    defer db.deinit();

    try db.queueAdd(1, 100);

    try testing.expect(!db.frontBuffer().has(1));
    try testing.expect(!db.backBuffer().has(1));

    db.swap();

    try testing.expectEqual(@as(TestValue, 100), db.frontBuffer().getConst(1).?.*);
    try testing.expectEqual(@as(TestValue, 100), db.backBuffer().getConst(1).?.*);
}

test "queueRemove - entity removed from both buffers after swap" {
    var db = DoubleBufferedSparseSet(TestValue).init(testing.allocator);
    defer db.deinit();

    const v: TestValue = 100;
    try db.insert(1, v);
    try testing.expect(db.frontBuffer().has(1));
    try testing.expect(db.backBuffer().has(1));

    try db.queueRemove(1);
    try testing.expect(db.frontBuffer().has(1)); // still present before swap
    try testing.expect(db.backBuffer().has(1));

    db.swap();

    try testing.expect(!db.frontBuffer().has(1));
    try testing.expect(!db.backBuffer().has(1));
}

test "command ordering - add then remove yields absent entity" {
    var db = DoubleBufferedSparseSet(TestValue).init(testing.allocator);
    defer db.deinit();

    try db.queueAdd(1, 100);
    try db.queueRemove(1);
    db.swap();

    try testing.expect(!db.frontBuffer().has(1));
    try testing.expect(!db.backBuffer().has(1));
}

test "command ordering - remove then add yields updated value" {
    var db = DoubleBufferedSparseSet(TestValue).init(testing.allocator);
    defer db.deinit();

    const v: TestValue = 100;
    try db.insert(1, v);
    try db.queueRemove(1);
    try db.queueAdd(1, 200);
    db.swap();

    try testing.expectEqual(@as(TestValue, 200), db.frontBuffer().getConst(1).?.*);
    try testing.expectEqual(@as(TestValue, 200), db.backBuffer().getConst(1).?.*);
}

test "system mutates components in-place via dense slice" {
    var db = DoubleBufferedSparseSet(TestValue).init(testing.allocator);
    defer db.deinit();

    var v: TestValue = 10;
    try db.insert(1, v);
    v = 20;
    try db.insert(2, v);

    // System doubles every value in the back buffer directly — no insert needed.
    for (db.backBuffer().values.items) |*p| p.* *= 2;

    // Front buffer is still the original snapshot.
    try testing.expectEqual(@as(TestValue, 10), db.frontBuffer().getConst(1).?.*);
    try testing.expectEqual(@as(TestValue, 20), db.frontBuffer().getConst(2).?.*);

    db.swap();

    try testing.expectEqual(@as(TestValue, 20), db.frontBuffer().getConst(1).?.*);
    try testing.expectEqual(@as(TestValue, 40), db.frontBuffer().getConst(2).?.*);
}
