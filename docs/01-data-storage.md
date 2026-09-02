# Data Storage

How data is held.

## Mental model

```text
World(Stores, Systems)                    // empty Groups (default)
WorldWithGroups(Stores, Systems, Groups)  // full-owning groups
  │
  ├─ stores: Stores             // plain struct of containers
  │    ├─ per-entity            SparseSet / Dense / Ring / DoubleBuffered
  │    ├─ singletons            SingletonStore(T)
  │    ├─ input_state           InputState (optional)
  │    └─ commands              CommandQueues(Queues) (optional)
  │
  ├─ groups: GroupRuntime       // sizes + hooks
  │
  └─ systems: Systems           // ComponentStore / FullOwningGroup / concrete pointers
```

## Stores bag

A world is parameterized at comptime by two or three structs:

```zig
pub fn World(comptime Stores: type, comptime Systems: type) type
// alias of WorldWithGroups(Stores, Systems, struct {})

pub fn WorldWithGroups(
    comptime Stores: type,
    comptime Systems: type,
    comptime Groups: type,
) type
```

Zig 0.16 has no default type parameters, so empty Groups stays `World(S, Sy)`
and group worlds use `WorldWithGroups(S, Sy, G)`.

`Stores` is a plain struct whose fields **are** the containers. There is no
runtime component registry.

### World init of stores

`World.init` is in-place (`fn init(self: *Self, allocator)`). It loops store
fields at comptime and calls each field’s `init(allocator)`, then binds group
hooks and each system’s `init(world)` into that live World. Every store-shaped
field (including `InputState` and `CommandQueues`) implements that shape so
construction is uniform. `deinit` mirrors the store loop. Do not copy World
after `init`.

## SparseSet (default backend)

`src/sparse_set.zig`

- Sparse index: `AutoHashMapUnmanaged(EntityIdType, dense_index)`
- Dense SoA: parallel `entity_ids` + `values` arrays
- `componentStore()` → type-erased `ComponentStore(T)` for systems
- `tickPressurePass`: grow dense capacity when length ≥ 80% of capacity
- `remove` present → World destroy sweeps this store
- Optional `group_hook` (null by default)
- `swapDense(i, j)`: pure dense permute; **never** calls hooks
- `clear` on a hooked store **panics in safe builds**; use `World.clearGroup`

Ungrouped stores keep ordinary insert-order / swap-remove semantics. Owned
group fields may have their dense order rewritten so the packed prefix stays
aligned across stores.

## ComponentStore vtable

`src/component_store.zig` — systems hold `ComponentStore(T)`, not concrete
sparse-set types:

```zig
pub fn ComponentStore(comptime T: type) type {
    // get, denseSlice, entitySlice, insert, remove via vtable
}
```

Adapters: `sparseSetStore`, `denseSparseSetStore`, `ringBufferedSparseSetStore`.
Concrete stores also expose `.componentStore()`.

**Exceptions (concrete pointers, not ComponentStore):** singletons,
`CommandQueues`, `InputState`, and World-level fields (`generations`).

## Memory pressure

At the start of every `World.tick`, `runMemoryPressurePass` calls
`tickPressurePass(entity_budget)` on stores that declare it. `entity_budget`
is `next_entity` (allocated id range). SparseSet ignores the budget and grows
on dense population; dense-array backends use the budget to cover the id range.

Systems assume capacity exists after the pass; mid-tick growth is a bug.

## Other store types

Dense, ring-buffered, and double-buffered sparse sets exist with the same
store contracts (`init`/`deinit`, optional `tickPressurePass` / `remove` /
`advance` / `componentStore`). Details:
[appendix-store-backends](appendix-store-backends.md).

## Related

- Entity ids and generations: [02-entity-lifecycle](02-entity-lifecycle.md)
- How systems bind stores: [03-systems](03-systems.md)
- Groups: [05-groups](05-groups.md)
