# Command Pipeline

Typed, tick-scoped command queues — the structured cross-system message
channel. Not an event bus: commands are requests for this tick, then gone.

## Pipeline

```text
producers (same sim step, before handlers, by Systems field order)
        │
        ▼
  CommandQueues(Queues)     // one ArrayListUnmanaged per payload type
        │
        ▼
consumers (later Systems fields)
        │
        ▼
  World.tick end: clearTickScoped()
```

## Module

`src/command_queues.zig` — `CommandQueues(comptime Queues)`.

The consumer owns payload types:

```zig
pub const Jump = struct { entity: ecs.EntityRef };
pub const Queues = struct {
    jumps: std.ArrayListUnmanaged(Jump) = .empty,
};
pub const Commands = ecs.CommandQueues(Queues);

// Stores field:
//   commands: Commands,
```

Each `Queues` field must support `deinit(allocator)` and
`clearRetainingCapacity()` (`ArrayListUnmanaged` does).

World sweeps any store that declares `clearTickScoped` at the end of
`tick`. Capacity is retained.

## Staleness

If a command targets an entity, store an `EntityRef` captured at emit time.
Handlers skip when `world.isAlive(ref)` is false.

## Related

- Systems: [03-systems](03-systems.md)
- Entity refs: [02-entity-lifecycle](02-entity-lifecycle.md)
