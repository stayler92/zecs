# zecs

A comptime [entity-component-system](https://en.wikipedia.org/wiki/Entity_component_system)
library for [Zig](https://ziglang.org/) 0.16.

Entities are numeric IDs with generation counters. Components are plain data
in typed, contiguous arrays. Systems are concrete structs whose `update(dt)`
is called in declaration order. Storage is a sparse set; optional EnTT-style
**full-owning groups** pack the intersection of several stores into an
aligned dense prefix.

Extracted from [IdleGenerator](https://github.com/stayler92/IdleGenerator).
IdleGenerator still vendors its own copy; a consume PR is a follow-up.

**0.x is unstable.** Pin consumers to a tag, never a branch.

## Install

```zig
// build.zig.zon — after:
//   zig fetch --save git+https://github.com/stayler92/zecs#0.1.1
```

```zig
// build.zig
const zecs_dep = b.dependency("zecs", .{
    .target = target,
    .optimize = optimize,
});
mod.addImport("ecs", zecs_dep.module("ecs"));
```

```zig
const ecs = @import("ecs");
```

The package name is `zecs`. The module you import is `ecs`.

Requires **Zig 0.16.0**.

## Quick start

```zig
const Stores = struct {
    pos: ecs.SparseSet(Position),
    vel: ecs.SparseSet(Velocity),
};
const Systems = struct { move: MoveSystem };
const World = ecs.World(Stores, Systems);

var world = World.init(allocator);
world.initSystems(); // bind after the world value is at its final address
defer world.deinit();

const e = try world.createEntity();
try world.stores.pos.insert(e.id, .{ .x = 0, .y = 0 });
try world.stores.vel.insert(e.id, .{ .dx = 1, .dy = 0 });
try world.tick(dt);
```

Two-phase startup is mandatory: `init` constructs stores; `initSystems` wires
group hooks and calls each system's `init(world)` so pointers into `self.stores`
are stable.

A runnable group-based version lives in [`examples/movers.zig`](examples/movers.zig):

```sh
zig build example
```

## What you get

| Piece | Role |
|-------|------|
| `World` / `WorldWithGroups` | Owns stores + systems; tick, entity alloc, destroy sweep |
| `EntityRef` | `{ id, gen }` handle; stale after destroy |
| `SparseSet(T)` | Default per-entity store (hash sparse + SoA dense) |
| `FullOwning` groups | Packed aligned prefix across ≥2 SparseSet fields |
| `ComponentStore(T)` | Fat-pointer vtable so systems do not hard-code a backend |
| `SingletonStore(T)` | Optional global value (resources) |
| `query` / `queryExclude` | Intersection iterators over SparseSet / DenseSparseSet |
| `CommandQueues(Queues)` | Tick-scoped typed command bag (`clearTickScoped`) |
| `InputState` | Pre-tick device snapshot (not entity-keyed) |
| `ThrottledSystem(T, interval)` | Accumulator wrapper around any system |
| `SlidingWindow(T, N)` | Fixed-capacity chronological ring |
| `Dense` / `Ring` / `DoubleBuffered` sparse sets | Alternate backends; same store contract |

World discovers optional store behaviour with `@hasDecl`:

| Decl | When |
|------|------|
| `init(allocator)` / `deinit()` | Always |
| `tickPressurePass(entity_budget)` | Start of every `World.tick` |
| `remove(id)` | `destroyEntity` / `clearEntityComponents` |
| `advance()` | `World.advanceRingBuffers` (orchestrator, after observers) |
| `clearTickScoped()` | End of every `World.tick` |

There is **no** component registry, system vtable, or scheduler. `Stores` and
`Systems` are plain structs; field declaration order **is** causality.

## Groups

```zig
const Groups = struct {
    movers: ecs.FullOwning(.{ .pos, .vel }),
};
const World = ecs.WorldWithGroups(Stores, Systems, Groups);

// in system init:
self.movers = world.groupView(.{ .pos, .vel });

// in update — re-derive every tick, never cache the slice:
const n = self.movers.size();
const pos = self.movers.slice(.pos);
const vel = self.movers.slice(.vel);
```

Load order: `init` → `initSystems()` (hooks) → `createEntity` + inserts.
Inserts before hooks leave group sizes at 0 forever.

A `Stores` field belongs to at most one group. `SparseSet.clear` on a hooked
store panics in safe builds; use `world.clearGroup(.movers)`.

## Versioning

- Tags are `MAJOR.MINOR.PATCH` with **no `v` prefix** (`0.1.0`).
- `zig fetch --save git+https://github.com/stayler92/zecs#0.1.0`
- Do not pin `main` / `develop`.

## Docs

| Doc | Covers |
|-----|--------|
| [CONTEXT.md](CONTEXT.md) | Vocabulary |
| [docs/00-overview.md](docs/00-overview.md) | Layout and mental model |
| [docs/01-data-storage.md](docs/01-data-storage.md) | Stores, ComponentStore, pressure pass |
| [docs/02-entity-lifecycle.md](docs/02-entity-lifecycle.md) | Ids, generations, create/destroy |
| [docs/03-systems.md](docs/03-systems.md) | System contract, throttling, order |
| [docs/04-commands.md](docs/04-commands.md) | Tick-scoped command queues |
| [docs/05-groups.md](docs/05-groups.md) | Full-owning groups |
| [docs/appendix-store-backends.md](docs/appendix-store-backends.md) | Alternate sparse-set backends |
| [docs/roadmap.md](docs/roadmap.md) | Scene / Platform (0.2) |

## License

[MIT](LICENSE) © Samuel Tayler 2026
