# Systems

How simulation logic is structured and ordered.

## Mental model

```text
World.init                         // stores + hooks + system bind (live *Self)
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
| `init(self, world: anytype)` | Optional | Bind store views / pointers; called from `World.init` |
| `update(self, dt: f32)` | Yes | Per-step work |

World does **not** dispatch via vtables for systems. `Systems` is a comptime
struct of concrete instances; `World.tick` calls `update` with an `inline for`
over fields **in declaration order**.

In-place startup:

```zig
var world: MyWorld = undefined;
world.init(allocator); // stores + hooks + system bind
defer world.deinit();
```

Do not copy World after `init`.

## Binding conventions

| Data kind | How systems hold it |
|-----------|---------------------|
| Multi-field packed set | `FullOwningGroup(Stores, Groups, .name)` via `world.groupView(.name)` |
| Ungrouped per-entity | `ComponentStore(T)` from `store.componentStore()` |
| Singletons | `*SingletonStore(T)` into `world.stores` |
| Commands / input | `*CommandQueues` / `*InputState` |
| Generations / entity alloc | pointers into `World` fields |

Hot paths call `groupSlice()` every `update` (never cache those slices from
`init`). Do not zip `denseSlice()` of group-owned stores — that is the full
dense array, suffix included. Use `groupSlice()` for the packed prefix.

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
hot paths that already have a full-owning group should use `groupSlice()`.

## Related

- Commands: [04-commands](04-commands.md)
- Groups: [05-groups](05-groups.md)
