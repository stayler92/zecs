//! Minimal zecs program: a packed pos+vel group and one move system.
const std = @import("std");
const ecs = @import("ecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };

const Stores = struct {
    pos: ecs.SparseSet(Position),
    vel: ecs.SparseSet(Velocity),
};

const Groups = struct {
    movers: ecs.FullOwning(.{ .pos, .vel }),
};

const MoveSystem = struct {
    movers: ecs.FullOwningGroup(Stores, Groups, .movers) = undefined,

    pub fn init(self: *@This(), world: anytype) void {
        self.movers = world.groupView(.movers);
    }

    pub fn update(self: *@This(), dt: f32) void {
        const g = self.movers.groupSlice();
        for (g.pos, g.vel) |*p, *v| {
            p.x += v.dx * dt;
            p.y += v.dy * dt;
        }
    }
};

const Systems = struct { move: MoveSystem };
const MoversWorld = ecs.WorldWithGroups(Stores, Systems, Groups);

pub fn main() !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    var world: MoversWorld = undefined;
    world.init(allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.pos.insert(e.id, .{ .x = 0, .y = 0 });
    try world.stores.vel.insert(e.id, .{ .dx = 10, .dy = 20 });

    try world.tick(0.5);

    const p = world.getComponent(e, &world.stores.pos).?;
    std.debug.print("pos = ({d:.1}, {d:.1})\n", .{ p.x, p.y });
}
