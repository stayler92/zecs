const std = @import("std");
const SparseSet = @import("./sparse_set.zig").SparseSet;
const constants = @import("./constants.zig");
const EntityIdType = constants.EntityIdType;
const GenerationType = constants.GenerationType;
pub const EntityRef = constants.EntityRef;
const query_mod = @import("./query.zig");
const group_mod = @import("./group.zig");

// World(Stores, Systems) — empty Groups (default; no hooks).
// WorldWithGroups(Stores, Systems, Groups) — full-owning groups (EnTT-style).
//
// Zig 0.16 has no default type parameters, so the empty-Groups path stays
// `World(S, Sy)` and group worlds use `WorldWithGroups(S, Sy, G)`.
//
//   Stores  - struct whose fields are component stores (SparseSet,
//             DenseSparseSet, RingBufferedSparseSet, singleton stores).
//   Systems - struct whose fields are concrete system instances.
//   Groups  - struct of FullOwning(.{ .field, ... }) markers (default empty).
//             Both are fully known at comptime; no vtables, no allocator.
//
// Startup (in-place — systems take refs into self.stores):
//
//   var world: MyWorld = undefined;
//   world.init(allocator);  // stores + wireGroupHooks + system init
//   defer world.deinit();
//
// Do not copy World after init.
//
// Systems declare ComponentStore(T) fields for per-entity component stores
// and bind them via the concrete store's `.componentStore()` method in
// `init`. Singleton / InputState / CommandQueues stay as concrete pointers
// (not vtable-erased). Full-owning groups bind via
// `world.groupView(.{ .pos, .vel })` in the same phase.
//
//   pub const MySystem = struct {
//       things: ComponentStore(Thing) = undefined,
//       pub fn init(self: *@This(), world: anytype) void {
//           self.things = world.stores.things.componentStore();
//       }
//       pub fn update(self: *@This(), dt: f32) void { ... }
//   };
//
// Typical frame (the orchestrator owns input and any observers; World does not):
//
//   try input_src.poll(&world.stores.input_state); // optional
//   try world.tick(dt);              // memory-pressure pass + systems.update(dt)
//   observer.read(&world.stores);    // renderer, tests, etc. — reads stores directly
//   world.advanceRingBuffers();      // no-op unless a store declares advance()
//
pub fn World(
    comptime Stores: type,
    comptime Systems: type,
) type {
    return WorldWithGroups(Stores, Systems, struct {});
}

pub fn WorldWithGroups(
    comptime Stores: type,
    comptime Systems: type,
    comptime Groups: type,
) type {
    comptime group_mod.validateGroups(Stores, Groups);

    const store_fields = @typeInfo(Stores).@"struct".fields;
    const sys_fields = @typeInfo(Systems).@"struct".fields;
    const Runtime = group_mod.GroupRuntime(Stores, Groups);

    return struct {
        const Self = @This();
        pub const GroupsType = Groups;
        pub const StoresType = Stores;

        stores: Stores,
        systems: Systems,
        groups: Runtime,
        allocator: std.mem.Allocator,
        next_entity: EntityIdType,
        recycled: std.ArrayListUnmanaged(EntityIdType),
        // Per-id generation counter. Index aligns with entity id.
        // Length grows monotonically with `next_entity`. Bumped on
        // destroyEntity to invalidate any pre-capture EntityRef.
        generations: std.ArrayListUnmanaged(GenerationType),

        // Construct stores into this live Self, then bind hooks + system
        // pointers. Do not copy World after init.
        pub fn init(self: *Self, allocator: std.mem.Allocator) void {
            var stores: Stores = undefined;
            inline for (store_fields) |field| {
                @field(stores, field.name) = field.type.init(allocator);
            }
            var systems: Systems = undefined;
            inline for (sys_fields) |field| {
                @field(systems, field.name) = .{};
            }
            self.* = .{
                .allocator = allocator,
                .stores = stores,
                .systems = systems,
                .groups = .{},
                .next_entity = 0,
                .recycled = .empty,
                .generations = .empty,
            };
            self.bind();
        }

        // Bind group hooks + system store pointers to self.stores. Only after
        // self.* is the caller's live World (no further moves).
        //
        // Each system receives the world pointer (anytype) so it can access
        // both world.stores and world-level fields (generations, etc.) in one call.
        fn bind(self: *Self) void {
            self.groups.stores = &self.stores;
            self.groups.wireHooks();
            inline for (sys_fields) |field| {
                if (@hasDecl(field.type, "init")) {
                    @field(self.systems, field.name).init(self);
                }
            }
        }

        /// View over a declared full-owning group. Field set must match a
        /// Groups entry by owned field-name set (order independent).
        pub fn groupView(self: *Self, comptime fields: anytype) group_mod.FullOwningGroup(Stores, fields) {
            const gi = comptime group_mod.findGroupIndex(Groups, fields) orelse {
                @compileError("groupView: no declared FullOwning group matches the given field set");
            };
            return .{
                .stores = &self.stores,
                .size_ptr = self.groups.groupSizePtr(gi),
            };
        }

        /// Clear every owned store of a named group and reset its size to 0.
        /// Safe alternative to SparseSet.clear on a hooked store.
        pub fn clearGroup(self: *Self, comptime group_name: anytype) void {
            const name = @tagName(group_name);
            const g_fields = @typeInfo(Groups).@"struct".fields;
            inline for (g_fields, 0..) |gfield, gi| {
                if (comptime std.mem.eql(u8, gfield.name, name)) {
                    self.groups.clearGroupByIndex(gi);
                    return;
                }
            }
            @compileError("clearGroup: unknown group name '" ++ name ++ "'");
        }

        /// Typed group view helper for systems that know Stores + field set.
        pub fn GroupView(comptime fields: anytype) type {
            return group_mod.FullOwningGroup(Stores, fields);
        }

        pub fn deinit(self: *Self) void {
            self.recycled.deinit(self.allocator);
            self.generations.deinit(self.allocator);
            inline for (store_fields) |field| {
                @field(self.stores, field.name).deinit();
            }
        }

        // Rotate the write index on every store that declares `advance`
        // (RingBufferedSparseSet, DoubleBufferedSparseSet). The orchestrator
        // calls this after observers and before the next tick. Stores without
        // an `advance` method are skipped at comptime.
        pub fn advanceRingBuffers(self: *Self) void {
            inline for (store_fields) |field| {
                if (comptime @hasDecl(field.type, "advance")) {
                    @field(self.stores, field.name).advance();
                }
            }
        }

        // Pre-tick growth pass. Each store implements its own policy via
        // tickPressurePass(entity_budget). Stores without it (singletons,
        // command queues, input state) are skipped at comptime.
        //
        // entity_budget = next_entity: the count of allocated entity IDs. Stores
        // that must cover the full ID range (DenseSparseSet) use this to extend
        // their sparse array; stores that self-manage their sparse index ignore it.
        pub fn runMemoryPressurePass(self: *Self) !void {
            const budget: EntityIdType = self.next_entity;
            inline for (store_fields) |field| {
                if (comptime @hasDecl(field.type, "tickPressurePass")) {
                    try @field(self.stores, field.name).tickPressurePass(budget);
                }
            }
        }

        // Call each system's update(dt) in declaration order, then clear
        // tick-scoped command queues. Producers emit before handlers (by
        // declaration order in the user's Systems struct); the post-tick
        // sweep guarantees no command leaks to the next tick.
        //
        // Any store with `clearTickScoped` is swept (duck-typed, same
        // pattern as tickPressurePass / advance). CommandQueues implements
        // this; other stores skip at comptime.
        pub fn tick(self: *Self, dt: f32) !void {
            try self.runMemoryPressurePass();
            inline for (sys_fields) |field| {
                @field(self.systems, field.name).update(dt);
            }
            inline for (store_fields) |field| {
                if (comptime @hasDecl(field.type, "clearTickScoped")) {
                    @field(self.stores, field.name).clearTickScoped();
                }
            }
        }

        // Allocate a new entity, reusing recycled ids when available. The
        // returned EntityRef carries the current generation for the id;
        // callers can pass it across ticks/systems and validate via
        // isAlive / getComponent before mutation.
        pub fn createEntity(self: *Self) !EntityRef {
            if (self.recycled.items.len > 0) {
                const id = self.recycled.pop().?;
                return .{ .id = id, .gen = self.generations.items[id] };
            }
            if (self.next_entity >= std.math.maxInt(EntityIdType)) return error.TooManyEntities;
            const id = self.next_entity;
            self.next_entity += 1;
            try self.generations.append(self.allocator, 0);
            // Grow stores to cover the new id range so subsequent inserts
            // don't trip DenseSparseSet's sparse-coverage assert.
            try self.runMemoryPressurePass();
            return .{ .id = id, .gen = 0 };
        }

        // Atomic destroy: clear components, bump generation, recycle id.
        // No-op for refs that are already stale (double-destroy is safe).
        pub fn destroyEntity(self: *Self, ref: EntityRef) !void {
            if (!self.isAlive(ref)) return;
            self.clearEntityComponents(ref.id);
            // `+%=` wraps the GenerationType (u32 today) silently. 4B
            // destroys per id slot is impractical at this scale; if a
            // future workload approaches that volume, switch to a
            // saturating add or promote to u64.
            self.generations.items[ref.id] +%= 1;
            try self.recycled.append(self.allocator, ref.id);
        }

        // True iff `ref` still describes the entity that produced it.
        // False once the id has been destroyed (gen mismatch) or if the
        // ref's id is outside the world's allocated range.
        pub fn isAlive(self: *const Self, ref: EntityRef) bool {
            if (ref.id >= self.generations.items.len) return false;
            return self.generations.items[ref.id] == ref.gen;
        }

        // Returns the live raw id behind `ref`, or null if stale. Use this
        // when a system needs to pass the id to a sparse-set API after
        // verifying the ref is still valid.
        pub fn deref(self: *const Self, ref: EntityRef) ?EntityIdType {
            return if (self.isAlive(ref)) ref.id else null;
        }

        // Stale-checked component lookup. The store is any sparse-set-like
        // container with a `get(id) ?*T` method; the gen check happens
        // at the World boundary so the store stays purely id-keyed.
        pub fn getComponent(
            self: *const Self,
            ref: EntityRef,
            store: anytype,
        ) @TypeOf(store.get(ref.id)) {
            if (!self.isAlive(ref)) return null;
            return store.get(ref.id);
        }

        // Add a single component to an entity.
        //   try world.addComponent(id, &world.stores.health, value);
        pub fn addComponent(
            _: *Self,
            id: EntityIdType,
            store: anytype,
            value: anytype,
        ) !void {
            try store.insert(id, value);
        }

        // Remove a single component from an entity.
        //   world.removeComponent(id, &world.stores.health);
        pub fn removeComponent(
            _: *Self,
            id: EntityIdType,
            store: anytype,
        ) void {
            _ = store.remove(id);
        }

        // Remove the entity from every per-id store. Stores that aren't
        // keyed by entity id (command queues, input state, etc.) declare
        // no `remove` method and are skipped at comptime.
        //
        // Contract for store types in `Stores`: declare `remove(id)` to
        // opt into per-entity cleanup; omit it to be skipped here. This
        // is duck-typed via `@hasDecl` so future entity-keyed stores
        // auto-walk without changes here.
        //
        // Even with generations, we still eagerly clear here so that
        // sparse-set iteration doesn't walk dead components and storage
        // doesn't grow unbounded across destroys. Generations only
        // protect *external* references; the stores themselves stay
        // tight via this sweep.
        pub fn clearEntityComponents(self: *Self, id: EntityIdType) void {
            inline for (store_fields) |field| {
                if (comptime @hasDecl(field.type, "remove")) {
                    _ = @field(self.stores, field.name).remove(id);
                }
            }
        }
    };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;

// Component types
const Health = i32;
const Speed = f32;
const Armor = bool;

// A system that records how many times it was called and the last dt received.
// All fields have defaults so it can be zero-initialized with .{}.
const TrackingSystem = struct {
    call_count: usize = 0,
    last_dt: f32 = 0,

    pub fn update(self: *TrackingSystem, dt: f32) void {
        self.call_count += 1;
        self.last_dt = dt;
    }
};

// Shared component/system/world types used across most tests.
const TestComponentsStores = struct {
    health: SparseSet(Health),
    speed: SparseSet(Speed),
    armor: SparseSet(Armor),
};
const TestSystems = struct { tracker: TrackingSystem };
const TestWorld = World(TestComponentsStores, TestSystems);

test "World - tick calls each system with the correct dt" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    try world.tick(0.016);
    try world.tick(0.033);

    try testing.expectEqual(@as(usize, 2), world.systems.tracker.call_count);
    try testing.expectEqual(@as(f32, 0.033), world.systems.tracker.last_dt);
}

test "World - system writes to store, visible after tick" {
    const DoubleHealthSystem = struct {
        health: *SparseSet(Health) = undefined,
        pub fn init(self: *@This(), world: anytype) void {
            self.health = &world.stores.health;
        }
        pub fn update(self: *@This(), dt: f32) void {
            _ = dt;
            for (self.health.values.items) |*v| v.* *= 2;
        }
    };
    const Systems = struct { doubler: DoubleHealthSystem };
    const W = World(TestComponentsStores, Systems);

    var world: W = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const h1: Health = 10;
    const h2: Health = 20;
    try world.stores.health.insert(1, h1);
    try world.stores.health.insert(2, h2);

    try world.tick(0.016);

    try testing.expectEqual(@as(Health, 20), world.stores.health.getConst(1).?.*);
    try testing.expectEqual(@as(Health, 40), world.stores.health.getConst(2).?.*);
}

test "World - system ordering: earlier system writes are visible to later system" {
    // System A: adds 1 to each value. System B: multiplies by 10.
    // A first -> (val+1)*10. B first -> val*10+1.
    const AddOneSystem = struct {
        health: *SparseSet(Health) = undefined,
        pub fn init(self: *@This(), world: anytype) void {
            self.health = &world.stores.health;
        }
        pub fn update(self: *@This(), dt: f32) void {
            _ = dt;
            for (self.health.values.items) |*v| v.* += 1;
        }
    };
    const MulTenSystem = struct {
        health: *SparseSet(Health) = undefined,
        pub fn init(self: *@This(), world: anytype) void {
            self.health = &world.stores.health;
        }
        pub fn update(self: *@This(), dt: f32) void {
            _ = dt;
            for (self.health.values.items) |*v| v.* *= 10;
        }
    };

    const Stores = struct { health: SparseSet(Health) };
    // Declaration order: add_one runs before mul_ten.
    const Systems = struct { add_one: AddOneSystem, mul_ten: MulTenSystem };
    const W = World(Stores, Systems);

    var world: W = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const h5: Health = 5;
    try world.stores.health.insert(1, h5);

    try world.tick(0); // add_one: 5->6, then mul_ten: 6->60

    try testing.expectEqual(@as(Health, 60), world.stores.health.getConst(1).?.*);
}

test "World - createEntity returns sequential IDs at generation 0" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e0 = try world.createEntity();
    const e1 = try world.createEntity();
    const e2 = try world.createEntity();

    try testing.expectEqual(@as(EntityIdType, 0), e0.id);
    try testing.expectEqual(@as(EntityIdType, 1), e1.id);
    try testing.expectEqual(@as(EntityIdType, 2), e2.id);
    try testing.expectEqual(@as(GenerationType, 0), e0.gen);
    try testing.expectEqual(@as(GenerationType, 0), e1.gen);
    try testing.expectEqual(@as(GenerationType, 0), e2.gen);
}

test "World - destroyEntity recycles id and bumps generation" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e0 = try world.createEntity();
    _ = try world.createEntity();

    try world.destroyEntity(e0);
    const recycled = try world.createEntity();

    try testing.expectEqual(e0.id, recycled.id);
    try testing.expect(recycled.gen != e0.gen);
}

test "World - isAlive: fresh ref true, post-destroy false" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try testing.expect(world.isAlive(e));

    try world.destroyEntity(e);
    try testing.expect(!world.isAlive(e));
}

test "World - isAlive: out-of-range id is false" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const stale: EntityRef = .{ .id = 999, .gen = 0 };
    try testing.expect(!world.isAlive(stale));
}

test "World - destroyEntity is idempotent on stale ref" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.destroyEntity(e);
    try world.destroyEntity(e); // no panic, no double-recycle
}

test "World - destroyEntity clears components atomically" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.health.insert(e.id, 100);
    try world.stores.speed.insert(e.id, 2.5);

    try world.destroyEntity(e);
    try testing.expect(!world.stores.health.has(e.id));
    try testing.expect(!world.stores.speed.has(e.id));
}

test "World - getComponent returns the live value, null for stale ref" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.health.insert(e.id, 42);

    const live = world.getComponent(e, &world.stores.health);
    try testing.expect(live != null);
    try testing.expectEqual(@as(Health, 42), live.?.*);

    try world.destroyEntity(e);
    try testing.expect(world.getComponent(e, &world.stores.health) == null);
}

test "World - recycled id with new generation does not see prior components" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e0 = try world.createEntity();
    try world.stores.health.insert(e0.id, 100);
    try world.destroyEntity(e0);

    const e1 = try world.createEntity();
    try testing.expectEqual(e0.id, e1.id);
    try testing.expect(e1.gen != e0.gen);

    // Old ref must not see anything via the gen-checked path.
    try testing.expect(world.getComponent(e0, &world.stores.health) == null);
    // New ref must see no leftover components.
    try testing.expect(world.getComponent(e1, &world.stores.health) == null);
}

test "World - clearEntityComponents removes from all stores (raw id path)" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.health.insert(e.id, 100);
    try world.stores.speed.insert(e.id, 2.5);

    world.clearEntityComponents(e.id);

    try testing.expect(!world.stores.health.has(e.id));
    try testing.expect(!world.stores.speed.has(e.id));
}

test "query: one-component yields every entity with that component" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();
    try world.stores.health.insert(1, 100);
    try world.stores.health.insert(2, 200);

    var q = query_mod.query(&world.stores, &.{Health});
    var seen: usize = 0;
    var sum: Health = 0;
    while (q.next()) |r| {
        seen += 1;
        try testing.expect(r.entity == 1 or r.entity == 2);
        sum += r.c0.*; // exercises the *Health pointer write path
    }
    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqual(@as(Health, 300), sum);
}

test "query: two-component yields only the intersection, with both pointers" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();
    try world.stores.health.insert(1, 10);
    try world.stores.speed.insert(1, 1.5);
    try world.stores.health.insert(2, 20); // entity 2 has no speed

    var q = query_mod.query(&world.stores, &.{ Health, Speed });
    const r = q.next() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(EntityIdType, 1), r.entity);
    try testing.expectEqual(@as(Health, 10), r.c0.*);
    try testing.expectEqual(@as(f32, 1.5), r.c1.*);
    try testing.expect(q.next() == null);
}

test "queryExclude: one include one exclude yields entities with include only if they lack exclude" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();
    try world.stores.health.insert(1, 100);
    try world.stores.speed.insert(1, 1.5); // excluded
    try world.stores.health.insert(2, 200); // included

    var q = query_mod.queryExclude(&world.stores, &.{Health}, &.{Speed});
    const r = q.next() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(EntityIdType, 2), r.entity);
    try testing.expectEqual(@as(Health, 200), r.c0.*);
    try testing.expect(q.next() == null);
}

test "queryExclude: one include two excludes requires entity lacks both" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();
    try world.stores.health.insert(1, 10);
    try world.stores.speed.insert(1, 1.5);
    try world.stores.armor.insert(1, true);
    try world.stores.health.insert(2, 20);
    try world.stores.speed.insert(2, 2.5); // has speed exclude
    try world.stores.health.insert(3, 30); // lacks speed+armor

    var q = query_mod.queryExclude(&world.stores, &.{Health}, &.{ Speed, Armor });
    const r = q.next() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(EntityIdType, 3), r.entity);
    try testing.expectEqual(@as(Health, 30), r.c0.*);
    try testing.expect(q.next() == null);
}

test "queryExclude: empty exclude list yields identical result to query" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();
    try world.stores.health.insert(1, 42);
    try world.stores.health.insert(2, 99);

    var qe = query_mod.queryExclude(&world.stores, &.{Health}, &.{});
    var seen: usize = 0;
    while (qe.next()) |r| {
        seen += 1;
        try testing.expect(r.entity == 1 or r.entity == 2);
    }
    try testing.expectEqual(@as(usize, 2), seen);

    var q = query_mod.query(&world.stores, &.{Health});
    seen = 0;
    while (q.next()) |_| {
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);
}

test "queryExclude: all included entities filtered by exclude yields empty result" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();
    try world.stores.health.insert(1, 100);
    try world.stores.speed.insert(1, 1.5);
    try world.stores.health.insert(2, 200);
    try world.stores.speed.insert(2, 2.5);

    var q = query_mod.queryExclude(&world.stores, &.{Health}, &.{Speed});
    try testing.expect(q.next() == null);
}

test "query: empty world yields null immediately" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    var q = query_mod.query(&world.stores, &.{Health});
    try testing.expect(q.next() == null);
}

test "query: components in non-declaration order map correctly" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();
    try world.stores.health.insert(1, 42);
    try world.stores.speed.insert(1, 2.5);

    var q = query_mod.query(&world.stores, &.{ Speed, Health }); // reversed vs Stores declaration
    const r = q.next() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(EntityIdType, 1), r.entity);
    try testing.expectEqual(@as(f32, 2.5), r.c0.*); // c0 is Speed
    try testing.expectEqual(@as(Health, 42), r.c1.*); // c1 is Health
    try testing.expect(q.next() == null);
}

test "query: smallest-set chosen as driver" {
    var world: TestWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();
    try world.stores.health.insert(1, 1);
    try world.stores.health.insert(2, 2);
    try world.stores.health.insert(3, 3);
    try world.stores.health.insert(4, 4);
    try world.stores.speed.insert(3, 9.0); // only entity 3 has both

    var q = query_mod.query(&world.stores, &.{ Health, Speed });
    const r = q.next() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(EntityIdType, 3), r.entity);
    try testing.expectEqual(@as(Health, 3), r.c0.*);
    try testing.expectEqual(@as(f32, 9.0), r.c1.*);
    try testing.expect(q.next() == null);
}

// ====================================================================
// Full-owning group tests (WorldWithGroups)
// ====================================================================

const FullOwning = group_mod.FullOwning;

const Pos = struct { x: f32, y: f32 };
const Vel = struct { dx: f32, dy: f32 };

const GroupStores = struct {
    pos: SparseSet(Pos),
    vel: SparseSet(Vel),
    orphan: SparseSet(i32), // ungrouped store
};

const MoverGroups = struct {
    movers: FullOwning(.{ .pos, .vel }),
};

const EmptySystems = struct {};

const GroupWorld = WorldWithGroups(GroupStores, EmptySystems, MoverGroups);
const EmptyGroupWorld = World(GroupStores, EmptySystems);

fn assertPrefixAligned(world: *GroupWorld, expect_size: usize) !void {
    const view = world.groupView(.{ .pos, .vel });
    try testing.expectEqual(expect_size, view.size());
    const e_pos = view.entitiesOf(.pos);
    const e_vel = view.entitiesOf(.vel);
    try testing.expectEqual(expect_size, e_pos.len);
    try testing.expectEqual(expect_size, e_vel.len);
    for (0..expect_size) |i| {
        try testing.expectEqual(e_pos[i], e_vel[i]);
    }
}

test "group: empty Groups world leaves hooks null and dense insert order unchanged" {
    var world: EmptyGroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    try testing.expect(world.stores.pos.group_hook == null);
    try testing.expect(world.stores.vel.group_hook == null);

    try world.stores.pos.insert(1, .{ .x = 1, .y = 0 });
    try world.stores.pos.insert(2, .{ .x = 2, .y = 0 });
    try world.stores.pos.insert(3, .{ .x = 3, .y = 0 });
    try testing.expectEqual(@as(EntityIdType, 1), world.stores.pos.entity_ids.items[0]);
    try testing.expectEqual(@as(EntityIdType, 2), world.stores.pos.entity_ids.items[1]);
    try testing.expectEqual(@as(EntityIdType, 3), world.stores.pos.entity_ids.items[2]);

    _ = world.stores.pos.remove(1);
    // swap-remove: last moves into slot 0
    try testing.expectEqual(@as(EntityIdType, 3), world.stores.pos.entity_ids.items[0]);
    try testing.expectEqual(@as(EntityIdType, 2), world.stores.pos.entity_ids.items[1]);
}

test "group: insert A then B packs; insert only A stays size 0" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    try testing.expect(world.stores.pos.group_hook != null);
    try testing.expect(world.stores.vel.group_hook != null);
    try testing.expect(world.stores.orphan.group_hook == null);

    const e = try world.createEntity();
    try world.stores.pos.insert(e.id, .{ .x = 1, .y = 2 });
    try assertPrefixAligned(&world, 0);

    try world.stores.vel.insert(e.id, .{ .dx = 3, .dy = 4 });
    try assertPrefixAligned(&world, 1);
    try testing.expectEqual(e.id, world.groupView(.{ .pos, .vel }).entities()[0]);
}

test "group: insert B then A packs the same" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.vel.insert(e.id, .{ .dx = 1, .dy = 0 });
    try assertPrefixAligned(&world, 0);
    try world.stores.pos.insert(e.id, .{ .x = 5, .y = 6 });
    try assertPrefixAligned(&world, 1);
    try testing.expectEqual(e.id, world.stores.pos.entity_ids.items[0]);
    try testing.expectEqual(e.id, world.stores.vel.entity_ids.items[0]);
}

test "group: value update on member does not change size or order" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e0 = try world.createEntity();
    const e1 = try world.createEntity();
    try world.stores.pos.insert(e0.id, .{ .x = 0, .y = 0 });
    try world.stores.vel.insert(e0.id, .{ .dx = 0, .dy = 0 });
    try world.stores.pos.insert(e1.id, .{ .x = 1, .y = 1 });
    try world.stores.vel.insert(e1.id, .{ .dx = 1, .dy = 1 });
    try assertPrefixAligned(&world, 2);

    const before0 = world.stores.pos.entity_ids.items[0];
    const before1 = world.stores.pos.entity_ids.items[1];
    try world.stores.pos.insert(e0.id, .{ .x = 99, .y = 99 });
    try assertPrefixAligned(&world, 2);
    try testing.expectEqual(before0, world.stores.pos.entity_ids.items[0]);
    try testing.expectEqual(before1, world.stores.pos.entity_ids.items[1]);
    try testing.expectEqual(@as(f32, 99), world.stores.pos.getConst(e0.id).?.x);
}

test "group: remove one owned component unpacks; sibling remains outside prefix" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.pos.insert(e.id, .{ .x = 1, .y = 0 });
    try world.stores.vel.insert(e.id, .{ .dx = 2, .dy = 0 });
    try assertPrefixAligned(&world, 1);

    _ = world.stores.pos.remove(e.id);
    try assertPrefixAligned(&world, 0);
    try testing.expect(!world.stores.pos.has(e.id));
    try testing.expect(world.stores.vel.has(e.id));
    // vel still holds entity outside the (empty) prefix
    try testing.expectEqual(@as(usize, 1), world.stores.vel.getCount());
}

test "group: two complete members aligned; third incomplete stays outside" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e0 = try world.createEntity();
    const e1 = try world.createEntity();
    const e2 = try world.createEntity();

    try world.stores.pos.insert(e0.id, .{ .x = 0, .y = 0 });
    try world.stores.vel.insert(e0.id, .{ .dx = 0, .dy = 0 });
    try world.stores.pos.insert(e1.id, .{ .x = 1, .y = 1 });
    try world.stores.vel.insert(e1.id, .{ .dx = 1, .dy = 1 });
    try world.stores.pos.insert(e2.id, .{ .x = 2, .y = 2 }); // incomplete
    try assertPrefixAligned(&world, 2);
    try testing.expectEqual(@as(usize, 3), world.stores.pos.getCount());
    try testing.expectEqual(@as(usize, 2), world.stores.vel.getCount());
    // e2 not in prefix
    const ents = world.groupView(.{ .pos, .vel }).entities();
    try testing.expect(ents[0] != e2.id and ents[1] != e2.id);
}

test "group: unpack member at index 0 when size>1 moves partner on all stores" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e0 = try world.createEntity();
    const e1 = try world.createEntity();
    const e2 = try world.createEntity();
    try world.stores.pos.insert(e0.id, .{ .x = 0, .y = 0 });
    try world.stores.vel.insert(e0.id, .{ .dx = 0, .dy = 0 });
    try world.stores.pos.insert(e1.id, .{ .x = 1, .y = 1 });
    try world.stores.vel.insert(e1.id, .{ .dx = 1, .dy = 1 });
    try world.stores.pos.insert(e2.id, .{ .x = 2, .y = 2 });
    try world.stores.vel.insert(e2.id, .{ .dx = 2, .dy = 2 });
    try assertPrefixAligned(&world, 3);

    // Remove e0 (likely at index 0 if packed in insert order).
    // After unpack, size=2 and remaining members stay aligned.
    _ = world.stores.pos.remove(e0.id);
    try assertPrefixAligned(&world, 2);
    try testing.expect(!world.stores.pos.has(e0.id));
    try testing.expect(world.stores.vel.has(e0.id)); // sibling outside prefix
    try testing.expect(world.stores.pos.has(e1.id));
    try testing.expect(world.stores.pos.has(e2.id));
    try testing.expect(world.stores.vel.has(e1.id));
    try testing.expect(world.stores.vel.has(e2.id));

    const ents = world.groupView(.{ .pos, .vel }).entities();
    try testing.expectEqual(@as(usize, 2), ents.len);
    for (ents) |id| {
        try testing.expect(id == e1.id or id == e2.id);
    }
}

test "group: destroyEntity mid-membership fixes size; no ghost ids in prefix" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e0 = try world.createEntity();
    const e1 = try world.createEntity();
    try world.stores.pos.insert(e0.id, .{ .x = 0, .y = 0 });
    try world.stores.vel.insert(e0.id, .{ .dx = 0, .dy = 0 });
    try world.stores.pos.insert(e1.id, .{ .x = 1, .y = 1 });
    try world.stores.vel.insert(e1.id, .{ .dx = 1, .dy = 1 });
    try assertPrefixAligned(&world, 2);

    try world.destroyEntity(e0);
    try assertPrefixAligned(&world, 1);
    try testing.expect(!world.stores.pos.has(e0.id));
    try testing.expect(!world.stores.vel.has(e0.id));
    try testing.expectEqual(e1.id, world.groupView(.{ .pos, .vel }).entities()[0]);
}

test "group: system-shaped bind iterates and mutates via slices" {
    const MoveSystem = struct {
        movers: GroupWorld.GroupView(.{ .pos, .vel }) = undefined,
        pub fn init(self: *@This(), world: anytype) void {
            self.movers = world.groupView(.{ .pos, .vel });
        }
        pub fn update(self: *@This(), dt: f32) void {
            const n = self.movers.size();
            const pos = self.movers.slice(.pos);
            const vel = self.movers.slice(.vel);
            std.debug.assert(pos.len == n and vel.len == n);
            for (0..n) |i| {
                pos[i].x += vel[i].dx * dt;
                pos[i].y += vel[i].dy * dt;
            }
        }
    };
    const Systems = struct { move: MoveSystem };
    const W = WorldWithGroups(GroupStores, Systems, MoverGroups);

    var world: W = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.pos.insert(e.id, .{ .x = 0, .y = 0 });
    try world.stores.vel.insert(e.id, .{ .dx = 10, .dy = 20 });
    try world.tick(0.5);
    try testing.expectEqual(@as(f32, 5), world.stores.pos.getConst(e.id).?.x);
    try testing.expectEqual(@as(f32, 10), world.stores.pos.getConst(e.id).?.y);
}

test "group: re-derive slices after dense reallocation" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    // Force multiple capacity growths by inserting many complete members.
    var ids: [64]EntityIdType = undefined;
    for (0..64) |i| {
        const e = try world.createEntity();
        ids[i] = e.id;
        try world.stores.pos.insert(e.id, .{ .x = @floatFromInt(i), .y = 0 });
        try world.stores.vel.insert(e.id, .{ .dx = 1, .dy = 0 });
    }
    try assertPrefixAligned(&world, 64);

    const view = world.groupView(.{ .pos, .vel });
    try testing.expectEqual(@as(usize, 64), view.size());
    try testing.expectEqual(@as(usize, 64), view.slice(.pos).len);
    try testing.expectEqual(@as(usize, 64), view.slice(.vel).len);
    try testing.expectEqual(@as(usize, 64), view.entities().len);
    // Spot-check values still correct after growth
    try testing.expectEqual(@as(f32, 0), view.slice(.pos)[0].x);
    // Find entity 63 in prefix and check
    var found63 = false;
    for (view.entities(), view.slice(.pos)) |eid, p| {
        if (eid == ids[63]) {
            try testing.expectEqual(@as(f32, 63), p.x);
            found63 = true;
        }
    }
    try testing.expect(found63);
}

test "group: pack thrash keeps size and prefix entity ids aligned" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    var entities: [16]EntityRef = undefined;
    for (0..16) |i| {
        entities[i] = try world.createEntity();
        try world.stores.pos.insert(entities[i].id, .{ .x = @floatFromInt(i), .y = 0 });
        try world.stores.vel.insert(entities[i].id, .{ .dx = 1, .dy = 0 });
    }
    try assertPrefixAligned(&world, 16);

    // Repeatedly remove and re-add the last component of half the members.
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        for (0..16) |i| {
            if (i % 2 == 0) {
                _ = world.stores.vel.remove(entities[i].id);
            }
        }
        try assertPrefixAligned(&world, 8);
        for (0..16) |i| {
            if (i % 2 == 0) {
                try world.stores.vel.insert(entities[i].id, .{ .dx = 2, .dy = 0 });
            }
        }
        try assertPrefixAligned(&world, 16);
    }
}

test "group: clearGroup resets size and clears owned stores" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.pos.insert(e.id, .{ .x = 1, .y = 0 });
    try world.stores.vel.insert(e.id, .{ .dx = 1, .dy = 0 });
    try world.stores.orphan.insert(e.id, 42);
    try assertPrefixAligned(&world, 1);

    world.clearGroup(.movers);
    try assertPrefixAligned(&world, 0);
    try testing.expectEqual(@as(usize, 0), world.stores.pos.getCount());
    try testing.expectEqual(@as(usize, 0), world.stores.vel.getCount());
    // Ungrouped store untouched
    try testing.expect(world.stores.orphan.has(e.id));
}

test "group: hooked store has non-null hook so lone clear would panic" {
    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    try testing.expect(world.stores.pos.group_hook != null);
    try testing.expect(world.stores.vel.group_hook != null);
    // Policy: SparseSet.clear panics when group_hook != null (R5).
    // clearGroup is the supported bulk path.
}

test "group: OOM on second component insert leaves size 0" {
    // Allocator that always fails alloc — second store insert OOMs after pos is
    // present; group must not partially pack.
    const FailAlloc = struct {
        fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            return null;
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
        const vtable = std.mem.Allocator.VTable{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
        fn allocator() std.mem.Allocator {
            return .{ .ptr = undefined, .vtable = &vtable };
        }
    };

    var world: GroupWorld = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.pos.insert(e.id, .{ .x = 1, .y = 0 });
    try assertPrefixAligned(&world, 0);

    // createEntity's pressure pass pre-grows vel capacity; drop it so the next
    // insert must allocate and can OOM. Re-init with the failing allocator.
    world.stores.vel.deinit();
    world.stores.vel = SparseSet(Vel).init(FailAlloc.allocator());
    // Re-wire hook (deinit/re-init cleared group_hook).
    world.groups.wireHooks();

    const insert_result = world.stores.vel.insert(e.id, .{ .dx = 1, .dy = 0 });
    try testing.expectError(error.OutOfMemory, insert_result);
    try assertPrefixAligned(&world, 0);
    try testing.expect(world.stores.pos.has(e.id));
    try testing.expect(!world.stores.vel.has(e.id));

    // Restore a clean testing-allocator store for world.deinit.
    world.stores.vel.deinit();
    world.stores.vel = SparseSet(Vel).init(testing.allocator);
    world.groups.wireHooks();
}

test "group: World two-arg form is empty Groups (existing call sites)" {
    // World(S, Sy) is the empty-Groups alias — compiles and installs no hooks.
    var world: World(GroupStores, EmptySystems) = undefined;
    world.init(testing.allocator);
    defer world.deinit();
    try testing.expect(world.stores.pos.group_hook == null);
    try testing.expect(world.stores.vel.group_hook == null);
    try world.stores.pos.insert(1, .{ .x = 1, .y = 0 });
    try testing.expectEqual(@as(usize, 1), world.stores.pos.getCount());
}

test "World.advanceRingBuffers rotates ring and double-buffered stores" {
    const Ring = @import("./ring_buffered_sparse_set.zig").RingBufferedSparseSet;
    const Dbl = @import("./double_buffer_sparse_set.zig").DoubleBufferedSparseSet;
    const Stores = struct {
        ring: Ring(i32, 2),
        dbl: Dbl(i32),
        plain: SparseSet(i32),
    };
    const W = World(Stores, struct {});
    var world: W = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.stores.ring.insert(e.id, 1);
    try world.stores.dbl.insert(e.id, 7);
    try world.stores.plain.insert(e.id, 9);

    const ring_idx0 = world.stores.ring.write_idx;
    const dbl_idx0 = world.stores.dbl.back_idx;

    world.advanceRingBuffers();

    try testing.expectEqual((ring_idx0 + 1) % 2, world.stores.ring.write_idx);
    try testing.expectEqual(dbl_idx0 ^ 1, world.stores.dbl.back_idx);
    try testing.expectEqual(@as(i32, 1), world.stores.ring.getConst(e.id).?.*);
    try testing.expectEqual(@as(i32, 7), world.stores.dbl.backBuffer().getConst(e.id).?.*);
    try testing.expectEqual(@as(i32, 9), world.stores.plain.getConst(e.id).?.*);
}
