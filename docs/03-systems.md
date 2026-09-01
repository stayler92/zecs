# Systems

How simulation logic is structured and ordered.

## Mental model

```text
World.init → World.initSystems()   // bind after world address is stable
       │
World.tick(dt):
  runMemoryPressurePass()
  inline for Systems fields (declaration order = causality):
    system.update(dt)
  stores with clearTickScoped: clear
```

No system vtables — concrete structs, comptime field walk.

## Contract

A system is a concrete struct with:

| Member | Required? | Role |
|--------|-----------|------|
| `init(self, world: anytype)` | Optional | Bind store views / pointers after world is at its final address |
| `update(self, dt: f32)` | Yes | Per-step work |

World does **not** dispatch via vtables for systems. `Systems` is a comptime
struct of concrete instances; `World.tick` calls `update` with an `inline for`
over fields **in declaration order**.

Two-phase startup:

```zig
var world = MyWorld.init(allocator); // stores only
world.initSystems();                     // bind systems to self.stores
defer world.deinit();
```

`initSystems` must run only after the world value is stable in memory (no
further moves).

## Binding conventions

| Data kind | How systems hold it |
|-----------|---------------------|
| Multi-field packed set | `FullOwningGroup` via `world.groupView(.{…})` |
| Ungrouped per-entity | `ComponentStore(T)` from `store.componentStore()` |
| Singletons | `*SingletonStore(T)` into `world.stores` |
| Commands / input | `*CommandQueues` / `*InputState` |
| Generations / entity alloc | pointers into `World` fields |

Hot paths re-derive `size` + `slice` every `update` (never cache dense slices
from `init`). Do not zip independent `denseSlice()` lengths with `@min` for
co-owned group fields — use the group prefix.

Producer-before-handler is enforced only by field order.

## ThrottledSystem

`src/throttled_system.zig` wraps any system `T`:

```zig
ThrottledSystem(T, interval_seconds)
// interval == 0.0 → always-tick
// interval  > 0.0 → fixed-step when accumulator crosses
ThrottledSystemN(T, interval, max_debt_multiplier)
```

Debt is clamped to `max_debt_multiplier * interval` (default 5) before
draining. Each drain step passes `interval` as dt. Debug builds expose
`.metrics`; release compiles that field to `void`.

## Queries

`query` / `queryExclude` walk SparseSet / DenseSparseSet intersections and
yield `{ entity, c0, c1, ... }` records. They are implemented and tested;
hot paths that already have a full-owning group should use the group prefix
instead.

## Related

- Commands: [04-commands](04-commands.md)
- Groups: [05-groups](05-groups.md)
