// Tick-scoped command queues — typed records emitted by producers (input
// translator, UI, future AI / network) and consumed by per-type handlers
// in the same World.tick.
//
// `CommandQueues(Queues)` is the engine bag: allocator + a pure value-typed
// `Queues` registry. Each field of `Queues` must be an
// `ArrayListUnmanaged(T)` (or compatible: deinit/clearRetainingCapacity).
// Adding a command type is one field on the consumer's Queues struct.
//
// World.tick sweeps any store with `clearTickScoped` via comptime duck
// typing (same pattern as tickPressurePass / advance).

const std = @import("std");

pub fn CommandQueues(comptime Queues: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        queues: Queues = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            inline for (@typeInfo(Queues).@"struct".fields) |f| {
                @field(self.queues, f.name).deinit(self.allocator);
            }
        }

        /// Clear every queue length, retaining capacity. Called by World at
        /// the end of each tick so no command leaks into the next step.
        pub fn clearTickScoped(self: *Self) void {
            inline for (@typeInfo(Queues).@"struct".fields) |f| {
                @field(self.queues, f.name).clearRetainingCapacity();
            }
        }
    };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;

test "CommandQueues - empty registry init/deinit is a no-op" {
    const Empty = CommandQueues(struct {});
    var q = Empty.init(testing.allocator);
    defer q.deinit();
    q.clearTickScoped();
}

test "CommandQueues - append then clearTickScoped retains capacity" {
    const Payload = struct { n: u32 };
    const Q = CommandQueues(struct {
        items: std.ArrayListUnmanaged(Payload) = .empty,
    });
    var bag = Q.init(testing.allocator);
    defer bag.deinit();

    try bag.queues.items.append(bag.allocator, .{ .n = 1 });
    try bag.queues.items.append(bag.allocator, .{ .n = 2 });
    try testing.expectEqual(@as(usize, 2), bag.queues.items.items.len);

    bag.clearTickScoped();
    try testing.expectEqual(@as(usize, 0), bag.queues.items.items.len);
    try testing.expect(bag.queues.items.capacity >= 2);
}
