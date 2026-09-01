# Overview

As-is description of **zecs 0.1.1**, grounded in `src/` and `build.zig`.
These docs describe what the code does today, not design aspirations.

## Layout

| Path | Role |
|------|------|
| `src/root.zig` | Public exports + `refAllDecls` test pull-in |
| `src/world.zig` | `World` / `WorldWithGroups` |
| `src/constants.zig` | `EntityIdType`, `GenerationType`, `EntityRef` |
| `src/sparse_set.zig` | Default per-entity store + `GroupHook` |
| `src/group.zig` | Full-owning groups |
| `src/component_store.zig` | `ComponentStore(T)` vtable + adapters |
| `src/query.zig` | `query` / `queryExclude` |
| `src/singleton_store.zig` | Optional global value |
| `src/command_queues.zig` | Tick-scoped command bag |
| `src/input_state.zig` | Device snapshot |
| `src/throttled_system.zig` | Accumulator wrapper |
| `src/sliding_window.zig` | Chronological ring |
| `src/dense_sparse_set.zig` | Flat-sparse backend |
| `src/ring_buffered_sparse_set.zig` | N-buffer history backend |
| `src/double_buffer_sparse_set.zig` | Ping-pong + deferred commands |
| `src/sparse_set_sort.zig` | Dense-prefix reorder helper |
| `examples/movers.zig` | Runnable group + system |
| `build.zig` | Module `ecs`, `zig build test`, `zig build example` |

`Scene` / `Platform` are **not** in this package. See [roadmap](roadmap.md).

## Mental model

```text
orchestrator (your main)
  poll input source → InputState          // optional, pre-tick
  world.tick(dt)
    memory pressure pass
    systems.update(dt) in declaration order
    clearTickScoped (command queues)
  observers read stores                    // renderer, network, tests
  world.advanceRingBuffers()               // no-op unless a store has advance()
```

The World does not own input, rendering, or a scene stack.

## Topic index

| Doc | Covers |
|-----|--------|
| [01-data-storage](01-data-storage.md) | Stores bag, sparse sets, singletons, ComponentStore |
| [02-entity-lifecycle](02-entity-lifecycle.md) | Entity ids, generations, create/destroy |
| [03-systems](03-systems.md) | System contract, order, throttling |
| [04-commands](04-commands.md) | Tick-scoped command queues |
| [05-groups](05-groups.md) | Full-owning groups |
| [appendix-store-backends](appendix-store-backends.md) | Live vs available store types |
| [roadmap](roadmap.md) | Scene / Platform 0.2 |

## Reading order

1. This overview
2. Data storage → Entity lifecycle → Systems → Commands → Groups
3. Appendix as needed; roadmap for what is deliberately out
