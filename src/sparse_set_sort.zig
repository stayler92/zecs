const std = @import("std");
const SparseSet = @import("./sparse_set.zig").SparseSet;
const EntityIdType = @import("constants.zig").EntityIdType;

/// Reorders a single SparseSet so that the entities in `entities` occupy
/// dense slots [0..entities.len] in the given order.
///
/// Entities in `store` but absent from `entities` fill the suffix in
/// unspecified order.
///
/// Panics if any entity in `entities` is not present in `store` — the caller
/// must ensure `entities` is a subset of the store's entities. Typically
/// `entities` is the entity_ids slice of another (primary) store that is a
/// subset of this one.
///
/// Typical use — sort pos by vel's ordering when vel ⊆ pos:
///   SparseSetGroupSorter(Pos).sort(&pos, vel.entity_ids.items);
///   // pos.entity_ids.items[0..vel.getCount()] == vel.entity_ids.items
///
/// Algorithm: for each entity in `entities` at target index i, look up its
/// current dense index j and swap it into slot i. O(N) where N = entities.len.
pub fn SparseSetGroupSorter(comptime T: type) type {
    const SparseSetType = SparseSet(T);

    return struct {
        /// Reorder `store` so that `entities[0..n]` occupies dense slots [0..n]
        /// in that exact order. Non-listed entities fill the suffix in unspecified order.
        /// `entities` must only contain entity IDs that are present in `store`.
        pub fn sort(store: *SparseSetType, entities: []const EntityIdType) void {
            for (entities, 0..) |entity, i| {
                const j: usize = @intCast(store.sparse.get(entity).?);
                store.swapDense(i, j);
            }
        }
    };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;

test "sort - sort pos by vel entity_ids, prefix aligns (core use-case)" {
    // vel has e2,e3. pos has e1,e2,e3. vel ⊆ pos.
    // Sort pos by vel.entity_ids — pos prefix aligns to vel's ordering.
    var pos = SparseSet(f32).init(testing.allocator);
    defer pos.deinit();
    var vel = SparseSet(f32).init(testing.allocator);
    defer vel.deinit();

    try pos.insert(1, 1.0);
    try pos.insert(2, 2.0);
    try pos.insert(3, 3.0);
    try vel.insert(3, 30.0); // inserted in reverse to test reordering
    try vel.insert(2, 20.0);

    // vel.entity_ids ⊆ pos — safe to pass directly
    SparseSetGroupSorter(f32).sort(&pos, vel.entity_ids.items);

    // pos prefix now matches vel's dense order: [e3, e2, ...]
    try testing.expectEqual(vel.entity_ids.items[0], pos.entity_ids.items[0]);
    try testing.expectEqual(vel.entity_ids.items[1], pos.entity_ids.items[1]);
    // values still correct
    try testing.expectEqual(@as(f32, 2.0), pos.getConst(2).?.*);
    try testing.expectEqual(@as(f32, 3.0), pos.getConst(3).?.*);
    try testing.expectEqual(@as(f32, 1.0), pos.getConst(1).?.*);
}

test "sort - three stores aligned by sorting larger stores by smallest" {
    // vel ⊆ pos, hp ⊆ pos. Sort pos and hp by vel (smallest store).
    var pos = SparseSet(f32).init(testing.allocator);
    defer pos.deinit();
    var vel = SparseSet(f32).init(testing.allocator);
    defer vel.deinit();
    var hp = SparseSet(i32).init(testing.allocator);
    defer hp.deinit();

    try pos.insert(1, 1.0);
    try pos.insert(2, 2.0);
    try pos.insert(3, 3.0);
    try vel.insert(3, 30.0);
    try vel.insert(2, 20.0); // vel ⊆ pos
    try hp.insert(3, 200);
    try hp.insert(2, 100); // hp ⊆ pos

    // vel.entity_ids ⊆ pos and ⊆ hp — safe
    SparseSetGroupSorter(f32).sort(&pos, vel.entity_ids.items);
    SparseSetGroupSorter(i32).sort(&hp, vel.entity_ids.items);

    // pos and hp prefixes now aligned to vel's order
    try testing.expectEqual(vel.entity_ids.items[0], pos.entity_ids.items[0]);
    try testing.expectEqual(vel.entity_ids.items[1], pos.entity_ids.items[1]);
    try testing.expectEqual(vel.entity_ids.items[0], hp.entity_ids.items[0]);
    try testing.expectEqual(vel.entity_ids.items[1], hp.entity_ids.items[1]);
}

test "sort - prefix order and sparse map consistent" {
    var store = SparseSet(i32).init(testing.allocator);
    defer store.deinit();
    try store.insert(1, 10);
    try store.insert(2, 20);
    try store.insert(3, 30);
    try store.insert(4, 40);

    // entities is a subset of store — no panic.
    SparseSetGroupSorter(i32).sort(&store, &.{ 3, 1 });

    try testing.expectEqual(@as(EntityIdType, 3), store.entity_ids.items[0]);
    try testing.expectEqual(@as(EntityIdType, 1), store.entity_ids.items[1]);
    // sparse map consistent for all entities
    try testing.expectEqual(@as(i32, 10), store.getConst(1).?.*);
    try testing.expectEqual(@as(i32, 20), store.getConst(2).?.*);
    try testing.expectEqual(@as(i32, 30), store.getConst(3).?.*);
    try testing.expectEqual(@as(i32, 40), store.getConst(4).?.*);
}

test "sort - suffix contains all non-group entities" {
    var store = SparseSet(i32).init(testing.allocator);
    defer store.deinit();
    try store.insert(1, 1);
    try store.insert(2, 2);
    try store.insert(3, 3);
    try store.insert(4, 4);
    try store.insert(5, 5);

    SparseSetGroupSorter(i32).sort(&store, &.{ 4, 2 });

    try testing.expectEqual(@as(EntityIdType, 4), store.entity_ids.items[0]);
    try testing.expectEqual(@as(EntityIdType, 2), store.entity_ids.items[1]);
    var found: u8 = 0;
    for (store.entity_ids.items[2..]) |eid| {
        if (eid == 1 or eid == 3 or eid == 5) found += 1;
    }
    try testing.expectEqual(@as(u8, 3), found);
}

test "sort - empty entity list is no-op" {
    var store = SparseSet(i32).init(testing.allocator);
    defer store.deinit();
    try store.insert(1, 10);
    try store.insert(2, 20);

    const before_0 = store.entity_ids.items[0];
    const before_1 = store.entity_ids.items[1];

    SparseSetGroupSorter(i32).sort(&store, &.{});

    try testing.expectEqual(before_0, store.entity_ids.items[0]);
    try testing.expectEqual(before_1, store.entity_ids.items[1]);
}

test "sort - full store reordered" {
    var store = SparseSet(i32).init(testing.allocator);
    defer store.deinit();
    try store.insert(1, 10);
    try store.insert(2, 20);
    try store.insert(3, 30);

    SparseSetGroupSorter(i32).sort(&store, &.{ 3, 2, 1 });

    try testing.expectEqual(@as(EntityIdType, 3), store.entity_ids.items[0]);
    try testing.expectEqual(@as(EntityIdType, 2), store.entity_ids.items[1]);
    try testing.expectEqual(@as(EntityIdType, 1), store.entity_ids.items[2]);
    try testing.expectEqual(@as(i32, 30), store.getConst(3).?.*);
    try testing.expectEqual(@as(i32, 20), store.getConst(2).?.*);
    try testing.expectEqual(@as(i32, 10), store.getConst(1).?.*);
}

test "sort - idempotent on already-sorted store" {
    var store = SparseSet(i32).init(testing.allocator);
    defer store.deinit();
    try store.insert(1, 10);
    try store.insert(2, 20);
    try store.insert(3, 30);

    SparseSetGroupSorter(i32).sort(&store, &.{ 1, 2 });
    SparseSetGroupSorter(i32).sort(&store, &.{ 1, 2 });

    try testing.expectEqual(@as(EntityIdType, 1), store.entity_ids.items[0]);
    try testing.expectEqual(@as(EntityIdType, 2), store.entity_ids.items[1]);
    try testing.expectEqual(@as(i32, 10), store.getConst(1).?.*);
    try testing.expectEqual(@as(i32, 20), store.getConst(2).?.*);
}
