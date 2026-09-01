# Entity Identity and Lifecycle

How entity ids are allocated, referenced, and destroyed.

## Lifecycle

```text
createEntity()
  ├─ pop recycled id  → keep current gen for that slot
  └─ else next_entity → gen 0, pressure pass
       │
       ▼
  EntityRef { id, gen }     // external handle (commands, UI)
       │
       │  stores key by raw id only
       │  gen checked at World / helper boundary
       ▼
destroyEntity(ref)
  ├─ no-op if !isAlive(ref)
  ├─ clearEntityComponents(id)   // every store with remove(id)
  ├─ generations[id] +%= 1       // invalidates old refs
  └─ push id → recycled
```

## Types

Defined in `src/constants.zig`:

| Type | Backing | Role |
|------|---------|------|
| `EntityIdType` | `u32` | Dense id slot |
| `GenerationType` | `u32` | Bumped on destroy to invalidate old refs |
| `EntityRef` | `{ id, gen }` | Cross-tick handle |

`EntityRef.invalid` is the sentinel for “no entity.”

## World ownership

`World` owns:

- `next_entity` — high-water id counter
- `recycled` — free list of destroyed ids
- `generations` — per-id generation counters (index = id)

Stores are keyed by **raw id only**. Generation checks happen at the World /
helper boundary before mutation via refs.

## Create

`createEntity()`:

1. Pop a recycled id if available (keep current generation for that slot), or
2. Allocate `next_entity`, append generation `0`, run memory pressure pass so
   dense-id stores cover the new range.

Returns `EntityRef { .id, .gen }`.

## Destroy

`destroyEntity(ref)`:

1. No-op if ref is already stale (`!isAlive`)
2. `clearEntityComponents(id)` — every store field that declares `remove(id)`
   drops that entity
3. Bump generation (`+%=`)
4. Push id onto `recycled`

Stores without `remove` (singletons, commands, input state) are skipped at
comptime.

## Liveness checks

| API | Behavior |
|-----|----------|
| `world.isAlive(ref)` | gen matches and id in range |
| `world.deref(ref)` | live raw id or null |
| `world.getComponent(ref, store)` | gen check then `store.get(id)` |
| `ecs.isAlive(generations, ref)` | free helper for systems |
| `ecs.getComponent(T, generations, ref, ComponentStore)` | free helper |

When a command targets an entity, capture `EntityRef` at emit time and skip
in the handler if `isAlive` fails.

## Clearing vs generations

Generations protect **external** refs. The destroy sweep still eagerly removes
components so dense iteration does not walk dead data and storage does not
grow unbounded across destroy/create cycles.

## Related

- Store layout: [01-data-storage](01-data-storage.md)
- Command targets: [04-commands](04-commands.md)
