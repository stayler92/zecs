# zecs vocabulary

A data-oriented entity-component-system library written in Zig. Entities are
numeric IDs paired with generation counters; components are plain data stored
in typed, contiguous arrays; systems iterate those arrays each tick.

## Core model

**Entity**:
A game object with no data of its own — identified by a numeric ID and a
generation counter that detects use-after-free.
_Avoid_: object, actor, game object

**Component**:
A single piece of plain data attached to an entity. Has no behaviour.
_Avoid_: property, attribute

**Store**:
A container that maps entities to components of exactly one type. Owns the
memory. Holds a sparse index and a contiguous dense array.
_Avoid_: pool, registry, repository

**System**:
A struct with an `update(dt)` method. Reads and writes components through
store references. Has no state beyond those references.
_Avoid_: manager, service, processor

**World**:
The top-level owner of all stores and systems. Wires them at init and drives
the tick loop.
_Avoid_: scene (scene is a planned engine primitive, not part of 0.1.0), engine

## Storage

**Dense array**:
The contiguous block of component values inside a store. Safe to slice and
iterate directly; the hot-loop target.
_Avoid_: buffer, backing array

**Sparse index**:
Maps an entity ID to its position in the dense array. Hash map (`SparseSet`)
or flat array (`DenseSparseSet`) depending on the backend.
_Avoid_: lookup table, index

**ComponentStore(T)**:
A fat-pointer runtime interface (data pointer + vtable) over a concrete store
for component type `T`. Decouples systems from the storage implementation. `T`
is always known at comptime; only the implementation is erased.
_Avoid_: interface, trait, virtual store

**Memory pressure pass**:
A pre-tick phase in which the World calls `tickPressurePass(entity_budget)` on
each concrete store. Each store owns its own growth policy. Runs on concrete
store types, never through `ComponentStore(T)`.
_Avoid_: resize pass, allocation phase

**Full-owning group**:
EnTT-style packed prefix across a set of `SparseSet` fields. Entities that
have *all* owned components occupy dense slots `[0..size)` in the same order
on every owned store.
_Avoid_: archetype, query cache

**RingBufferedSparseSet(T, N)**:
A store that holds N value arrays behind a single sparse index and entity-ID
list. Systems write the current buffer via `ComponentStore(T)`; a renderer
(or other observer) may read `currentSlice()` / `previousSlice()` for
interpolation. `advance()` — called by the orchestrator after the observer
and before the next tick — seeds the next write buffer and rotates
`write_idx`.
_Avoid_: double buffer, triple buffer, ring buffer store

**Input source**:
An external component that polls raw device state once per frame and writes
it into the `InputState` store before `world.tick()`. Not part of the World;
swappable without changing systems.
_Avoid_: input system, input handler, input provider

**InputState**:
A singleton-shaped store holding the raw key/mouse snapshot for the current
tick. Populated by the input source pre-tick. Not entity-keyed; has no vtable.
_Avoid_: input component, input buffer

**Command**:
A typed, tick-scoped request to mutate simulation state. Emitted by producers
(bindings, UI); consumed by a handler system in the same tick. Not an entity
component.
_Avoid_: event (something already happened), intent (informal English only), message

**CommandQueues(Queues)**:
Engine bag holding one `ArrayList` per command type listed in the consumer's
`Queues` struct. Implements `clearTickScoped` so World can sweep all queues
post-tick via duck typing. The consumer owns payload types; zecs owns the bag
mechanics.
_Avoid_: event bus, intent registry

## Entity lifecycle

**Generation**:
A counter bumped each time an entity ID is recycled. A reference holding a
stale generation is dead and must not be used.
_Avoid_: version, epoch

## Relationships

- An **Entity** may have zero or more **Components**, one per **Store**
- A **Store** owns the **Dense array** and **Sparse index** for exactly one component type
- A **System** holds one `ComponentStore(T)` (or a `FullOwningGroup` view) per component type it touches
- The **World** owns all concrete **Stores** and all **Systems**; it performs the **Memory pressure pass** before each tick
- `ComponentStore(T)` is a view into a concrete **Store** — it does not own data
- The game-loop orchestrator owns the **Input source** (and any renderer); the **World** is unaware of both
- The **Input source** writes into the **InputState** store; systems read it via a direct pointer — no vtable
- Producers push **Commands** into **CommandQueues**; handlers consume them same tick; World calls `clearTickScoped` after systems
