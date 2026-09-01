const std = @import("std");
const ComponentStore = @import("component_store.zig").ComponentStore;

/// Entity ID type — change to u64 if you need more than 4 billion entities
pub const EntityIdType = u32;

/// Generation counter type. Bumped each time an entity id is destroyed so
/// that references captured before destruction (e.g. across ticks, in input
/// intent payloads, in UI selection state) can be detected as stale before
/// being applied to a recycled id.
pub const GenerationType = u32;

/// Stable reference to an entity that survives id recycling. Pair the raw
/// id with the generation observed at capture time; the World's generations
/// table is the source of truth and any ref whose `gen` mismatches the
/// current value is stale.
pub const EntityRef = struct {
    id: EntityIdType,
    gen: GenerationType,

    pub const invalid: EntityRef = .{
        .id = std.math.maxInt(EntityIdType),
        .gen = std.math.maxInt(GenerationType),
    };

    pub fn eql(a: EntityRef, b: EntityRef) bool {
        return a.id == b.id and a.gen == b.gen;
    }
};

pub fn isAlive(generations: *const std.ArrayListUnmanaged(GenerationType), ref: EntityRef) bool {
    if (ref.id >= generations.items.len) return false;
    return generations.items[ref.id] == ref.gen;
}

pub fn getComponent(comptime T: type, generations: *const std.ArrayListUnmanaged(GenerationType), ref: EntityRef, store: ComponentStore(T)) ?*T {
    if (!isAlive(generations, ref)) return null;
    return store.get(ref.id);
}
