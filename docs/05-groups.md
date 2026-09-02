# Full-owning groups

EnTT-style packed prefixes. Entities that have *all* owned components occupy
dense slots `[0..size)` in the same order on every owned store.

## Declaration

```zig
const Groups = struct {
    movers: ecs.FullOwning(.{ .pos, .vel }),
};
const World = ecs.WorldWithGroups(Stores, Systems, Groups);
```

| Rule | Detail |
|------|--------|
| Membership | Immediate pack on structural insert when entity has all owned fields; unpack before remove |
| Exclusive ownership | A `Stores` field belongs to at most one group (comptime error on double-own) |
| Min fields | ≥2 field names per `FullOwning` |
| SparseSet only | Non-`SparseSet` members rejected at comptime |
| Hook wiring | In `World.init` only (live `*Self`) |
| Value-only insert | Updates value; does **not** fire hooks or change size |
| Views | `slice` / `entities` re-derive every call; never cache `[]T` from `init` |
| Bulk clear | `world.clearGroup(.movers)` — not lone `SparseSet.clear` on owned fields |

## Load order (mandatory)

`init` (wires hooks + binds systems) → `createEntity` + inserts. Inserts
before `init` are use-after-undefined.

## Iteration

```zig
const view = world.groupView(.{ .pos, .vel }); // field-name set; order independent
const n = view.size();
const pos = view.slice(.pos); // []Position, len n — re-derived each call
for (0..n) |i| { /* … */ }
```

`World.GroupView(.{ .pos, .vel })` is the type alias systems store after bind.

## Related

- Storage: [01-data-storage](01-data-storage.md)
- Systems: [03-systems](03-systems.md)
