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

The owned field set is written only on `FullOwning`. Systems name the group:

```zig
movers: ecs.FullOwningGroup(Stores, Groups, .movers) = undefined,
// in init:
self.movers = world.groupView(.movers);
```

| Rule | Detail |
|------|--------|
| Membership | Immediate pack on structural insert when entity has all owned fields; unpack before remove |
| Exclusive ownership | A `Stores` field belongs to at most one group (comptime error on double-own) |
| Min fields | ≥2 field names per `FullOwning` |
| SparseSet only | Non-`SparseSet` members rejected at comptime |
| Hook wiring | In `World.init` only (live `*Self`) |
| Value-only insert | Updates value; does **not** fire hooks or change size |
| Views | `groupSlice` re-derives every call (one size read); never cache slices from `init` |
| Bulk clear | `world.clearGroup(.movers)` — not lone `SparseSet.clear` on owned fields |
| Address | `groupView` / `clearGroup` take the Groups field name (`.movers`) |

## Load order (mandatory)

`init` (wires hooks + binds systems) → `createEntity` + inserts. Inserts
before `init` are use-after-undefined.

## Iteration

```zig
const g = view.groupSlice(); // entities, pos, vel — same length
for (g.pos, g.vel) |*p, *v| { /* … */ }
```

`groupSlice` captures `size()` once. Do not zip `ComponentStore.denseSlice()`
of group-owned stores — that is the full dense array, including incomplete
members.

## Related

- Storage: [01-data-storage](01-data-storage.md)
- Systems: [03-systems](03-systems.md)
