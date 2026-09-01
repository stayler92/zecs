# Roadmap

## 0.1.0 — raw ECS (this release)

The 15 game-agnostic files extracted from IdleGenerator. No Scene, no
renderer, no game systems. IdleGenerator is **not** switched over; dual-copy
until a later consume PR.

## 0.2 — Scene + Platform (planned)

IdleGenerator already has `src/ecs/scene.zig`, but it is **not** extractable
as-is: `Platform` holds a concrete ANSI `Renderer`. The live game also
bypasses the Scene vtable (`IdleGenerator` ticks `GameScene` directly).

### Design (not implemented here)

`Platform` should be generic over a services bag, not a renderer type:

```zig
pub fn Platform(comptime Services: type) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        services: Services,
    };
}
```

`Services` is the consumer's struct: a renderer, audio, save filesystem,
nothing — whatever the app wants. zecs never names those types.

Scene stays a vtable of function pointers so apps can swap scenes without
the World knowing:

```zig
pub fn Scene(comptime P: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,
        pub const VTable = struct {
            load: *const fn (ptr: *anyopaque, platform: *P) anyerror!void,
            unload: *const fn (ptr: *anyopaque) void,
            enter: *const fn (ptr: *anyopaque) void,
            exit: *const fn (ptr: *anyopaque) void,
            tick: *const fn (ptr: *anyopaque, dt: f32) anyerror!SceneCommand,
            render: *const fn (ptr: *anyopaque, platform: *P) anyerror!void,
            save: *const fn (ptr: *anyopaque) anyerror!void,
        };
    };
}
```

- `tick` returns a `SceneCommand` (`none` / `quit` / `replace` / `push` /
  `pop`) so a stack can exist without the World knowing.
- `render` takes `Platform` so a scene can reach whatever is in `Services`.
- Optional `SceneStack` lives next to this, not inside World.

### Explicitly out of 0.2

- Extracting IdleGenerator's `src/renderer/renderer.zig`
- A built-in ANSI or raylib backend
- Forcing every app to have a renderer field

## Later

- Consume PR: IdleGenerator depends on `zecs` and deletes its vendored copy
- Archetype / sparse-set hybrid is **not** planned; groups cover the packed
  multi-component case
