# Appendix: Store Backends

Which store types exist and what they are for.

## Shared duck-typed contracts

World discovers optional behaviour with `@hasDecl`:

| Decl | When World calls it |
|------|---------------------|
| `init(allocator)` / `deinit()` | Always (all store fields) |
| `tickPressurePass(entity_budget)` | Start of every `World.tick` |
| `remove(id)` | `destroyEntity` / `clearEntityComponents` |
| `advance()` | `World.advanceRingBuffers` (orchestrator, after observers) |
| `clearTickScoped()` | End of every `World.tick` |

All per-entity backends that support it expose `componentStore()` into the
same `ComponentStore(T)` vtable.

## Backends

| Type | File | Characteristics |
|------|------|-----------------|
| `SparseSet(T)` | `sparse_set.zig` | Hash sparse; default. Optional group hook. |
| `DenseSparseSet(T)` | `dense_sparse_set.zig` | Flat sparse array; O(1) index; grows with entity id range via pressure pass |
| `RingBufferedSparseSet(T, N)` | `ring_buffered_sparse_set.zig` | N parallel value arrays; `advance()` rotates write index |
| `DoubleBufferedSparseSet(T)` | `double_buffer_sparse_set.zig` | Ping-pong + deferred commands; `advance()` aliases `swap()` |
| `SingletonStore(T)` | `singleton_store.zig` | Optional single value; no `remove` |
| `InputState` | `input_state.zig` | Device snapshot; World-shaped `init`/`deinit` |
| `CommandQueues(Q)` | `command_queues.zig` | Tick-scoped lists; `clearTickScoped` |

## Query support

`query` / `queryExclude` resolve component types to store fields that are
`SparseSet(C)` or `DenseSparseSet(C)`. Ring-buffered stores are not in that
match list.

## Group sort

`sparse_set_sort.zig` can reorder dense prefixes for multi-component
alignment. Live group membership uses hooks + `swapDense`, not this sorter.

## Practical guidance

- Default new per-entity data: `SparseSet`
- Use dense/ring/double only with an explicit reason and wire pressure /
  `advance` correctly
- `advanceRingBuffers` is a no-op when no store declares `advance`
