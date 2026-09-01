//! zecs — comptime Zig ECS (sparse-set, EnTT-style full-owning groups).
//!
//! Import as `@import("ecs")`. Package name in `build.zig.zon` is `zecs`.
const std = @import("std");

pub const World = @import("world.zig").World;
pub const WorldWithGroups = @import("world.zig").WorldWithGroups;

pub const EntityIdType = @import("constants.zig").EntityIdType;
pub const GenerationType = @import("constants.zig").GenerationType;
pub const EntityRef = @import("constants.zig").EntityRef;
pub const isAlive = @import("constants.zig").isAlive;
pub const getComponent = @import("constants.zig").getComponent;

pub const SparseSet = @import("sparse_set.zig").SparseSet;
pub const GroupHook = @import("sparse_set.zig").GroupHook;

pub const FullOwning = @import("group.zig").FullOwning;
pub const FullOwningGroup = @import("group.zig").FullOwningGroup;
pub const GroupRuntime = @import("group.zig").GroupRuntime;
pub const validateGroups = @import("group.zig").validateGroups;
pub const validateGroupsMessage = @import("group.zig").validateGroupsMessage;
pub const findGroupIndex = @import("group.zig").findGroupIndex;

pub const DenseSparseSet = @import("dense_sparse_set.zig").DenseSparseSet;
pub const RingBufferedSparseSet = @import("ring_buffered_sparse_set.zig").RingBufferedSparseSet;
pub const DoubleBufferedSparseSet = @import("double_buffer_sparse_set.zig").DoubleBufferedSparseSet;
pub const SparseSetGroupSorter = @import("sparse_set_sort.zig").SparseSetGroupSorter;

pub const ComponentStore = @import("component_store.zig").ComponentStore;
pub const sparseSetStore = @import("component_store.zig").sparseSetStore;
pub const denseSparseSetStore = @import("component_store.zig").denseSparseSetStore;
pub const ringBufferedSparseSetStore = @import("component_store.zig").ringBufferedSparseSetStore;

pub const SingletonStore = @import("singleton_store.zig").SingletonStore;
pub const SlidingWindow = @import("sliding_window.zig").SlidingWindow;

pub const query = @import("query.zig").query;
pub const queryExclude = @import("query.zig").queryExclude;
pub const makeQueries = @import("query.zig").makeQueries;

pub const CommandQueues = @import("command_queues.zig").CommandQueues;

pub const InputState = @import("input_state.zig").InputState;
pub const Key = @import("input_state.zig").Key;
pub const MouseButton = @import("input_state.zig").MouseButton;
pub const Vec2 = @import("input_state.zig").Vec2;

pub const ThrottledSystem = @import("throttled_system.zig").ThrottledSystem;
pub const ThrottledSystemN = @import("throttled_system.zig").ThrottledSystemN;
pub const Metrics = @import("throttled_system.zig").Metrics;

test {
    std.testing.refAllDecls(@This());
}
