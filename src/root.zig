//! zecs — comptime Zig ECS (sparse-set, EnTT-style full-owning groups).
//!
//! Import as `@import("ecs")`. Package name in `build.zig.zon` is `zecs`.
const std = @import("std");

pub const World = @import("world.zig").World;
pub const WorldWithGroups = @import("world.zig").WorldWithGroups;

pub const EntityIdType = @import("entity/constants.zig").EntityIdType;
pub const GenerationType = @import("entity/constants.zig").GenerationType;
pub const EntityRef = @import("entity/constants.zig").EntityRef;
pub const isAlive = @import("entity/constants.zig").isAlive;
pub const getComponent = @import("entity/constants.zig").getComponent;

pub const SparseSet = @import("store/sparse_set.zig").SparseSet;
pub const GroupHook = @import("store/sparse_set.zig").GroupHook;

pub const FullOwning = @import("group/group.zig").FullOwning;
pub const FullOwningGroup = @import("group/group.zig").FullOwningGroup;

pub const DenseSparseSet = @import("store/dense_sparse_set.zig").DenseSparseSet;
pub const RingBufferedSparseSet = @import("store/ring_buffered_sparse_set.zig").RingBufferedSparseSet;
pub const DoubleBufferedSparseSet = @import("store/double_buffer_sparse_set.zig").DoubleBufferedSparseSet;

pub const ComponentStore = @import("store/component_store.zig").ComponentStore;
pub const sparseSetStore = @import("store/component_store.zig").sparseSetStore;
pub const denseSparseSetStore = @import("store/component_store.zig").denseSparseSetStore;
pub const ringBufferedSparseSetStore = @import("store/component_store.zig").ringBufferedSparseSetStore;

pub const SingletonStore = @import("store/singleton_store.zig").SingletonStore;
pub const SlidingWindow = @import("store/sliding_window.zig").SlidingWindow;

pub const query = @import("query/query.zig").query;
pub const queryExclude = @import("query/query.zig").queryExclude;
pub const makeQueries = @import("query/query.zig").makeQueries;

pub const CommandQueues = @import("command/command_queues.zig").CommandQueues;

pub const InputState = @import("input/input_state.zig").InputState;
pub const Key = @import("input/input_state.zig").Key;
pub const MouseButton = @import("input/input_state.zig").MouseButton;
pub const Vec2 = @import("input/input_state.zig").Vec2;

pub const ThrottledSystem = @import("system/throttled_system.zig").ThrottledSystem;
pub const ThrottledSystemN = @import("system/throttled_system.zig").ThrottledSystemN;
pub const Metrics = @import("system/throttled_system.zig").Metrics;

test {
    std.testing.refAllDecls(@This());
    _ = @import("store/sparse_set_sort.zig");
    _ = @import("group/group.zig");
}
