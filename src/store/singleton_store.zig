const std = @import("std");

pub fn SingletonStore(comptime T: type) type {
    return struct {
        const Self = @This();

        value: ?T = null,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }

        pub fn deinit(_: *Self) void {}

        pub fn select(self: *Self, value: *const T) void {
            self.value = value.*;
        }

        pub fn deselect(self: *Self) void {
            self.value = null;
        }

        pub fn getItem(self: *const Self) ?*const T {
            if (self.value) |*v| return v;
            return null;
        }

        pub fn getMutableItem(self: *Self) ?*T {
            if (self.value) |*v| return v;
            return null;
        }

        pub fn hasSelection(self: *const Self) bool {
            return self.value != null;
        }
    };
}

test "empty store has no selection" {
    const Store = SingletonStore(u32);
    const store: Store = .{};
    try std.testing.expect(!store.hasSelection());
    try std.testing.expectEqual(@as(?*const u32, null), store.getItem());
}

test "select stores value and getItem returns pointer into store" {
    const Store = SingletonStore(u32);
    var store: Store = .{};
    const val: u32 = 42;
    store.select(&val);
    try std.testing.expect(store.hasSelection());
    try std.testing.expectEqual(@as(u32, 42), store.getItem().?.*);
}

test "deselect clears selection" {
    const Store = SingletonStore(u32);
    var store: Store = .{};
    const val: u32 = 7;
    store.select(&val);
    store.deselect();
    try std.testing.expect(!store.hasSelection());
    try std.testing.expectEqual(@as(?*const u32, null), store.getItem());
}

test "select overwrites previous selection" {
    const Store = SingletonStore(u32);
    var store: Store = .{};
    const a: u32 = 1;
    const b: u32 = 2;
    store.select(&a);
    store.select(&b);
    try std.testing.expectEqual(@as(u32, 2), store.getItem().?.*);
}

test "getMutableItem allows mutation of stored value" {
    const Store = SingletonStore(u32);
    var store: Store = .{};
    const val: u32 = 10;
    store.select(&val);
    store.getMutableItem().?.* = 99;
    try std.testing.expectEqual(@as(u32, 99), store.getItem().?.*);
}

test "works with struct type" {
    const Point = struct { x: f32, y: f32 };
    const Store = SingletonStore(Point);
    var store: Store = .{};
    const p = Point{ .x = 1.0, .y = 2.0 };
    store.select(&p);
    const got = store.getItem().?;
    try std.testing.expectEqual(@as(f32, 1.0), got.x);
    try std.testing.expectEqual(@as(f32, 2.0), got.y);
}

test "select copies value — original change does not affect store" {
    const Store = SingletonStore(u32);
    var store: Store = .{};
    var val: u32 = 5;
    store.select(&val);
    val = 999;
    try std.testing.expectEqual(@as(u32, 5), store.getItem().?.*);
}
