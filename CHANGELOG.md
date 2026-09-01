# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [SemVer](https://semver.org/). **0.x is unstable**: the
public API may change without a major bump. Pin consumers to a tag.

## [0.1.0] — 2026-09-01

Initial extract of the raw ECS from
[IdleGenerator](https://github.com/stayler92/IdleGenerator) (`f35aa86`).

### Added

- `World(Stores, Systems)` and `WorldWithGroups(Stores, Systems, Groups)`
- Generational `EntityRef` (`createEntity` / `destroyEntity` / `isAlive`)
- Store backends: `SparseSet`, `DenseSparseSet`, `RingBufferedSparseSet`,
  `DoubleBufferedSparseSet`, `SingletonStore`, `SlidingWindow`
- EnTT-style full-owning groups (`FullOwning`, `groupView`, `clearGroup`)
- `ComponentStore(T)` vtable + adapters
- `query` / `queryExclude`
- Engine companions: `CommandQueues`, `InputState`, `ThrottledSystem`
- Unit tests pulled in via `src/root.zig`
- `examples/movers.zig`

### Extract deltas vs IdleGenerator `src/ecs/`

- `scene.zig` excluded (renderer-coupled; see 0.2 roadmap)
- `std.debug.print` stripped from `world.zig` tests (Zig 0.16 test runner treats stderr as failure)
- `SparseSetGroupSorter.sort` now calls `SparseSet.swapDense` (the old copy assigned `usize` into a `u32` sparse index and did not compile once exported)

### Not in 0.1.0

- `Scene` / `Platform` — engine-shaped, but IdleGenerator's copy depends on
  an ANSI renderer. Planned for 0.2; see [docs/roadmap.md](docs/roadmap.md).
- Renderer, game systems, templates, HUD.

[0.1.0]: https://github.com/stayler92/zecs/releases/tag/0.1.0
