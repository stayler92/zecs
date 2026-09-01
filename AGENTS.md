# zecs — agent gate

Comptime Zig ECS. Sparse-set storage, optional EnTT-style full-owning groups.
Package name `zecs`. Import module name `ecs`. Requires **Zig 0.16.0**.

## Read first (in this order)

1. This file
2. CONTEXT.md — vocabulary only
3. docs/00-overview.md then the topic file you are changing
4. src/ — source of truth if docs disagree
5. examples/movers.zig — runnable group + system pattern

## Do not read unless the human names the file

- docs/roadmap.md — planned Scene / Platform, not in 0.1.x

## Rules

- Code + docs/00–05 win over README pitch and roadmap.
- Do not invent synonyms (see CONTEXT.md).
- Do not add a component registry, system vtable, or scheduler.
- `Stores` / `Systems` field order is causality.
- Two-phase startup: `init` then `initSystems()` before inserts.
- After a coherent change: `zig fmt --check . && zig build test`
- Also run `zig build example` if you touched groups or World init.
- Do not add `std.debug.print` in tests (Zig 0.16 listen-runner false alarm).
- 0.x is unstable. Do not tell consumers to pin `main`.
