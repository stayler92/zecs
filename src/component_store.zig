const std = @import("std");
const EntityIdType = @import("constants.zig").EntityIdType;
const SparseSet = @import("sparse_set.zig").SparseSet;
const DenseSparseSet = @import("dense_sparse_set.zig").DenseSparseSet;
const RingBufferedSparseSet = @import("ring_buffered_sparse_set.zig").RingBufferedSparseSet;

pub fn ComponentStore(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            get: *const fn (ptr: *anyopaque, id: EntityIdType) ?*T,
            denseSlice: *const fn (ptr: *anyopaque) []T,
            entitySlice: *const fn (ptr: *anyopaque) []EntityIdType,
            insert: *const fn (ptr: *anyopaque, id: EntityIdType, v: T) anyerror!void,
            remove: *const fn (ptr: *anyopaque, id: EntityIdType) void,
        };

        pub fn get(self: Self, id: EntityIdType) ?*T {
            return self.vtable.get(self.ptr, id);
        }

        pub fn denseSlice(self: Self) []T {
            return self.vtable.denseSlice(self.ptr);
        }

        pub fn entitySlice(self: Self) []EntityIdType {
            return self.vtable.entitySlice(self.ptr);
        }

        pub fn insert(self: Self, id: EntityIdType, v: T) !void {
            return self.vtable.insert(self.ptr, id, v);
        }

        pub fn remove(self: Self, id: EntityIdType) void {
            self.vtable.remove(self.ptr, id);
        }
    };
}

pub fn sparseSetStore(comptime T: type, store: *SparseSet(T)) ComponentStore(T) {
    const Adapter = struct {
        fn get(ptr: *anyopaque, id: EntityIdType) ?*T {
            const s: *SparseSet(T) = @ptrCast(@alignCast(ptr));
            return s.get(id);
        }
        fn denseSlice(ptr: *anyopaque) []T {
            const s: *SparseSet(T) = @ptrCast(@alignCast(ptr));
            return s.values.items;
        }
        fn entitySlice(ptr: *anyopaque) []EntityIdType {
            const s: *SparseSet(T) = @ptrCast(@alignCast(ptr));
            return s.entity_ids.items;
        }
        fn insert(ptr: *anyopaque, id: EntityIdType, v: T) anyerror!void {
            const s: *SparseSet(T) = @ptrCast(@alignCast(ptr));
            return s.insert(id, v);
        }
        fn remove(ptr: *anyopaque, id: EntityIdType) void {
            const s: *SparseSet(T) = @ptrCast(@alignCast(ptr));
            _ = s.remove(id);
        }

        const vtable = ComponentStore(T).VTable{
            .get = get,
            .denseSlice = denseSlice,
            .entitySlice = entitySlice,
            .insert = insert,
            .remove = remove,
        };
    };
    return .{ .ptr = store, .vtable = &Adapter.vtable };
}

pub fn denseSparseSetStore(comptime T: type, store: *DenseSparseSet(T)) ComponentStore(T) {
    const Adapter = struct {
        fn get(ptr: *anyopaque, id: EntityIdType) ?*T {
            const s: *DenseSparseSet(T) = @ptrCast(@alignCast(ptr));
            return s.get(id);
        }
        fn denseSlice(ptr: *anyopaque) []T {
            const s: *DenseSparseSet(T) = @ptrCast(@alignCast(ptr));
            return s.values.items;
        }
        fn entitySlice(ptr: *anyopaque) []EntityIdType {
            const s: *DenseSparseSet(T) = @ptrCast(@alignCast(ptr));
            return s.entity_ids.items;
        }
        fn insert(ptr: *anyopaque, id: EntityIdType, v: T) anyerror!void {
            const s: *DenseSparseSet(T) = @ptrCast(@alignCast(ptr));
            return s.insert(id, v);
        }
        fn remove(ptr: *anyopaque, id: EntityIdType) void {
            const s: *DenseSparseSet(T) = @ptrCast(@alignCast(ptr));
            _ = s.remove(id);
        }

        const vtable = ComponentStore(T).VTable{
            .get = get,
            .denseSlice = denseSlice,
            .entitySlice = entitySlice,
            .insert = insert,
            .remove = remove,
        };
    };
    return .{ .ptr = store, .vtable = &Adapter.vtable };
}

// Adapter for RingBufferedSparseSet — exposes the current write buffer to
// update systems. The renderer bypasses this and calls currentSlice() /
// previousSlice() directly on the concrete type.
pub fn ringBufferedSparseSetStore(comptime T: type, comptime N: usize, store: *RingBufferedSparseSet(T, N)) ComponentStore(T) {
    const Adapter = struct {
        fn get(ptr: *anyopaque, id: EntityIdType) ?*T {
            const s: *RingBufferedSparseSet(T, N) = @ptrCast(@alignCast(ptr));
            return s.get(id);
        }
        fn denseSlice(ptr: *anyopaque) []T {
            const s: *RingBufferedSparseSet(T, N) = @ptrCast(@alignCast(ptr));
            return s.writeSlice();
        }
        fn entitySlice(ptr: *anyopaque) []EntityIdType {
            const s: *RingBufferedSparseSet(T, N) = @ptrCast(@alignCast(ptr));
            return @constCast(s.entitySlice());
        }
        fn insert(ptr: *anyopaque, id: EntityIdType, v: T) anyerror!void {
            const s: *RingBufferedSparseSet(T, N) = @ptrCast(@alignCast(ptr));
            return s.insert(id, v);
        }
        fn remove(ptr: *anyopaque, id: EntityIdType) void {
            const s: *RingBufferedSparseSet(T, N) = @ptrCast(@alignCast(ptr));
            _ = s.remove(id);
        }

        const vtable = ComponentStore(T).VTable{
            .get = get,
            .denseSlice = denseSlice,
            .entitySlice = entitySlice,
            .insert = insert,
            .remove = remove,
        };
    };
    return .{ .ptr = store, .vtable = &Adapter.vtable };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;

test "ComponentStore(SparseSet) - denseSlice and entitySlice are parallel" {
    var store = SparseSet(i32).init(testing.allocator);
    defer store.deinit();

    const cs = sparseSetStore(i32, &store);
    try cs.insert(10, 100);
    try cs.insert(20, 200);
    try cs.insert(30, 300);

    const values = cs.denseSlice();
    const ids = cs.entitySlice();

    try testing.expectEqual(@as(usize, 3), values.len);
    try testing.expectEqual(@as(usize, 3), ids.len);
    for (ids, values) |id, v| {
        try testing.expectEqual(v, @as(i32, @intCast(id)) * 10);
    }
}

test "ComponentStore(SparseSet) - remove drops component" {
    var store = SparseSet(i32).init(testing.allocator);
    defer store.deinit();

    const cs = sparseSetStore(i32, &store);
    try cs.insert(5, 99);
    cs.remove(5);

    try testing.expectEqual(@as(usize, 0), cs.denseSlice().len);
    try testing.expect(cs.get(5) == null);
}

test "ComponentStore(DenseSparseSet) - get, slices, remove all work" {
    var store = DenseSparseSet(i32).init(testing.allocator);
    defer store.deinit();

    try store.ensureTotalCapacity(21);
    const cs = denseSparseSetStore(i32, &store);
    try cs.insert(10, 100);
    try cs.insert(20, 200);

    // get
    try testing.expectEqual(@as(i32, 100), cs.get(10).?.*);
    try testing.expect(cs.get(99) == null);

    // slices parallel
    try testing.expectEqual(@as(usize, 2), cs.denseSlice().len);
    try testing.expectEqual(@as(usize, 2), cs.entitySlice().len);

    // remove
    cs.remove(10);
    try testing.expect(cs.get(10) == null);
    try testing.expectEqual(@as(usize, 1), cs.denseSlice().len);
}

test "ComponentStore - swap backing store, behavior identical" {
    var sparse = SparseSet(i32).init(testing.allocator);
    defer sparse.deinit();
    var dense = DenseSparseSet(i32).init(testing.allocator);
    defer dense.deinit();

    // Same data inserted into both
    try dense.ensureTotalCapacity(8);
    try sparse.insert(7, 77);
    try dense.insert(7, 77);

    // System field is ComponentStore(i32) — swappable at wiring time
    var cs: ComponentStore(i32) = sparseSetStore(i32, &sparse);
    try testing.expectEqual(@as(i32, 77), cs.get(7).?.*);

    cs = denseSparseSetStore(i32, &dense);
    try testing.expectEqual(@as(i32, 77), cs.get(7).?.*);
}

test "ComponentStore(SparseSet) - get returns value after insert" {
    var store = SparseSet(i32).init(testing.allocator);
    defer store.deinit();

    const cs = sparseSetStore(i32, &store);
    try cs.insert(1, 42);

    const v = cs.get(1);
    try testing.expect(v != null);
    try testing.expectEqual(@as(i32, 42), v.?.*);
}
