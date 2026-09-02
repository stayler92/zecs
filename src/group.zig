const std = @import("std");
const EntityIdType = @import("constants.zig").EntityIdType;
const SparseSet = @import("sparse_set.zig").SparseSet;
const GroupHook = @import("sparse_set.zig").GroupHook;

// ---------------------------------------------------------------------------
// FullOwning — comptime marker for Groups declaration fields
// ---------------------------------------------------------------------------

/// Comptime marker listing Stores field names owned by one full-owning group.
/// Used as the type of a field on a World's `Groups` struct:
///
///   const Groups = struct {
///       movers: FullOwning(.{ .pos, .vel }),
///   };
///
/// Requires ≥2 field names. Exclusive ownership is validated by World.
pub fn FullOwning(comptime field_tuple: anytype) type {
    const names = extractFieldNames(field_tuple);
    if (names.len < 2) {
        @compileError("FullOwning requires at least 2 Stores field names");
    }
    return struct {
        pub const owned_fields: []const []const u8 = names;
        pub const is_full_owning_group = true;
    };
}

fn extractFieldNames(comptime field_tuple: anytype) []const []const u8 {
    const info = @typeInfo(@TypeOf(field_tuple));
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("FullOwning expects a tuple of enum literals, e.g. .{ .pos, .vel }");
    }
    var names: [info.@"struct".fields.len][]const u8 = undefined;
    inline for (info.@"struct".fields, 0..) |f, i| {
        const val = @field(field_tuple, f.name);
        names[i] = @tagName(val);
    }
    // Dedup check within one group
    inline for (0..names.len) |i| {
        inline for (i + 1..names.len) |j| {
            if (std.mem.eql(u8, names[i], names[j])) {
                @compileError("FullOwning: duplicate field name '" ++ names[i] ++ "'");
            }
        }
    }
    const frozen = names;
    return &frozen;
}

// ---------------------------------------------------------------------------
// Groups validation (comptime)
// ---------------------------------------------------------------------------

/// Returns an error message if Groups is invalid for Stores, else null.
/// World uses this via `@compileError`; unit tests assert the message text.
pub fn validateGroupsMessage(comptime Stores: type, comptime Groups: type) ?[]const u8 {
    const g_info = @typeInfo(Groups);
    if (g_info != .@"struct") return "Groups must be a struct";

    // Collect owned field → group name for exclusivity.
    // Max: number of Stores fields.
    const store_fields = @typeInfo(Stores).@"struct".fields;
    const max_owned = store_fields.len;
    var owned_names: [max_owned][]const u8 = undefined;
    var owned_by: [max_owned][]const u8 = undefined;
    var owned_count: usize = 0;

    inline for (g_info.@"struct".fields) |gfield| {
        const GType = gfield.type;
        if (!@hasDecl(GType, "is_full_owning_group") or !@hasDecl(GType, "owned_fields")) {
            return "Groups field '" ++ gfield.name ++ "' must be FullOwning(...)";
        }
        const owned = GType.owned_fields;
        if (owned.len < 2) {
            return "FullOwning group '" ++ gfield.name ++ "' requires at least 2 fields";
        }
        inline for (owned) |fname| {
            // Exists on Stores?
            if (!@hasField(Stores, fname)) {
                return "Group '" ++ gfield.name ++ "' owns unknown Stores field '" ++ fname ++ "'";
            }
            // Must be SparseSet(T)
            const StoreType = @FieldType(Stores, fname);
            if (!isSparseSetType(StoreType)) {
                return "Group '" ++ gfield.name ++ "' field '" ++ fname ++ "' must be SparseSet(T)";
            }
            // Exclusive ownership
            var dup = false;
            for (owned_names[0..owned_count], owned_by[0..owned_count]) |oname, ogroup| {
                if (std.mem.eql(u8, oname, fname)) {
                    _ = ogroup;
                    dup = true;
                    break;
                }
            }
            if (dup) {
                return "Stores field '" ++ fname ++ "' owned by more than one group (double-own)";
            }
            if (owned_count >= max_owned) {
                return "internal: owned field count exceeds Stores fields";
            }
            owned_names[owned_count] = fname;
            owned_by[owned_count] = gfield.name;
            owned_count += 1;
        }
    }
    return null;
}

pub fn validateGroups(comptime Stores: type, comptime Groups: type) void {
    if (comptime validateGroupsMessage(Stores, Groups)) |msg| {
        @compileError(msg);
    }
}

fn isSparseSetType(comptime StoreType: type) bool {
    // SparseSet(T) always exports Elem and has sparse/entity_ids/values/group_hook.
    if (!@hasDecl(StoreType, "Elem")) return false;
    if (!@hasField(StoreType, "group_hook")) return false;
    if (!@hasField(StoreType, "entity_ids")) return false;
    if (!@hasField(StoreType, "values")) return false;
    if (!@hasDecl(StoreType, "swapDense")) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Group name lookup (for groupView)
// ---------------------------------------------------------------------------

/// Index of the declared Groups field named `name`, or null.
pub fn findGroupIndexByName(comptime Groups: type, comptime name: []const u8) ?usize {
    const g_fields = @typeInfo(Groups).@"struct".fields;
    inline for (g_fields, 0..) |gfield, i| {
        if (comptime std.mem.eql(u8, gfield.name, name)) return i;
    }
    return null;
}

fn ownedFieldsCollideWithEntities(comptime names: []const []const u8) bool {
    inline for (names) |fname| {
        if (comptime std.mem.eql(u8, fname, "entities")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// FullOwningGroup view — groupSlice re-derives all prefixes in one size read
// ---------------------------------------------------------------------------

/// System-facing view over a full-owning group. Holds non-owning `*Stores` and
/// a pointer to the runtime size. `groupSlice` captures size once so every
/// returned dense prefix has the same length.
pub fn FullOwningGroup(comptime Stores: type, comptime Groups: type, comptime group: anytype) type {
    const group_name = @tagName(group);
    if (!@hasField(Groups, group_name)) {
        @compileError("FullOwningGroup: Groups has no field '" ++ group_name ++ "'");
    }
    const Marker = @FieldType(Groups, group_name);
    if (!@hasDecl(Marker, "is_full_owning_group") or !@hasDecl(Marker, "owned_fields")) {
        @compileError("FullOwningGroup: '" ++ group_name ++ "' must be FullOwning(...)");
    }
    const names = Marker.owned_fields;
    if (comptime ownedFieldsCollideWithEntities(names)) {
        @compileError("FullOwningGroup: owned field name 'entities' collides with groupSlice().entities");
    }
    inline for (names) |fname| {
        if (!@hasField(Stores, fname)) {
            @compileError("FullOwningGroup: Stores has no field '" ++ fname ++ "'");
        }
    }

    const Slice = blk: {
        const n_fields = names.len + 1;
        var field_names: [n_fields][]const u8 = undefined;
        var field_types: [n_fields]type = undefined;
        var field_attrs: [n_fields]std.builtin.Type.StructField.Attributes = undefined;
        field_names[0] = "entities";
        field_types[0] = []EntityIdType;
        field_attrs[0] = .{};
        for (names, 0..) |fname, i| {
            field_names[i + 1] = fname;
            field_types[i + 1] = []@FieldType(Stores, fname).Elem;
            field_attrs[i + 1] = .{};
        }
        break :blk @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    };

    return struct {
        const Self = @This();
        pub const field_names: []const []const u8 = names;

        stores: *Stores,
        size_ptr: *const usize,

        pub fn size(self: Self) usize {
            return self.size_ptr.*;
        }

        /// Packed prefix of every owned store plus entity ids. Size is read
        /// once; all slices have that length. Re-derived each call.
        pub fn groupSlice(self: Self) Slice {
            const n = self.size();
            var out: Slice = undefined;
            const first = &@field(self.stores.*, names[0]);
            std.debug.assert(n <= first.entity_ids.items.len);
            out.entities = first.entity_ids.items[0..n];
            inline for (names) |fname| {
                const store = &@field(self.stores.*, fname);
                std.debug.assert(n <= store.values.items.len);
                @field(out, fname) = store.values.items[0..n];
            }
            return out;
        }
    };
}

// ---------------------------------------------------------------------------
// GroupRuntime — sizes + pack/unpack handlers
// ---------------------------------------------------------------------------

pub fn GroupRuntime(comptime Stores: type, comptime Groups: type) type {
    const g_fields = @typeInfo(Groups).@"struct".fields;
    const num_groups = g_fields.len;

    if (num_groups == 0) {
        return struct {
            const Self = @This();
            /// Present so World can always take `&self.groups` uniformly.
            stores: *Stores = undefined,

            pub fn wireHooks(self: *Self) void {
                _ = self;
            }

            pub fn groupSizePtr(self: *Self, comptime _: usize) *usize {
                _ = self;
                // Empty Groups has no sizes; unreachable if groupView validates.
                unreachable;
            }
        };
    }

    return struct {
        const Self = @This();

        sizes: [num_groups]usize = .{0} ** num_groups,
        stores: *Stores = undefined,

        pub fn wireHooks(self: *Self) void {
            inline for (g_fields, 0..) |gfield, gi| {
                const owned = gfield.type.owned_fields;
                inline for (owned, 0..) |fname, fi| {
                    const field_id: u32 = @intCast(gi * 64 + fi); // unique enough
                    const store = &@field(self.stores.*, fname);
                    store.group_hook = GroupHook{
                        .ctx = self,
                        .field_id = field_id,
                        .on_after_insert = makeAfterInsert(gi, fname),
                        .on_before_remove = makeBeforeRemove(gi, fname),
                    };
                }
            }
        }

        pub fn groupSizePtr(self: *Self, comptime group_idx: usize) *usize {
            return &self.sizes[group_idx];
        }

        pub fn clearGroupByIndex(self: *Self, comptime group_idx: usize) void {
            const owned = g_fields[group_idx].type.owned_fields;
            inline for (owned) |fname| {
                @field(self.stores.*, fname).clearUnchecked();
            }
            self.sizes[group_idx] = 0;
        }

        fn makeAfterInsert(
            comptime group_idx: usize,
            comptime field_name: []const u8,
        ) *const fn (*anyopaque, u32, EntityIdType) void {
            return struct {
                fn f(ctx: *anyopaque, field_id: u32, entity_id: EntityIdType) void {
                    _ = field_id;
                    const rt: *Self = @ptrCast(@alignCast(ctx));
                    rt.afterInsert(group_idx, field_name, entity_id);
                }
            }.f;
        }

        fn makeBeforeRemove(
            comptime group_idx: usize,
            comptime field_name: []const u8,
        ) *const fn (*anyopaque, u32, EntityIdType) void {
            return struct {
                fn f(ctx: *anyopaque, field_id: u32, entity_id: EntityIdType) void {
                    _ = field_id;
                    const rt: *Self = @ptrCast(@alignCast(ctx));
                    rt.beforeRemove(group_idx, field_name, entity_id);
                }
            }.f;
        }

        fn afterInsert(
            self: *Self,
            comptime group_idx: usize,
            comptime field_name: []const u8,
            entity_id: EntityIdType,
        ) void {
            const owned = g_fields[group_idx].type.owned_fields;
            const size = self.sizes[group_idx];

            const primary = &@field(self.stores.*, field_name);
            const idx = primary.indexOf(entity_id) orelse return;
            if (idx < size) return; // already a member

            // Incomplete membership → leave outside prefix.
            inline for (owned) |fname| {
                if (comptime std.mem.eql(u8, fname, field_name)) continue;
                if (!@field(self.stores.*, fname).has(entity_id)) return;
            }

            // Pack: swap entity into dense slot `size` on every owned store.
            inline for (owned) |fname| {
                const store = &@field(self.stores.*, fname);
                const eidx = store.indexOf(entity_id).?;
                store.swapDense(eidx, size);
            }
            self.sizes[group_idx] = size + 1;

            if (std.debug.runtime_safety) {
                self.debugAssertMember(group_idx, entity_id);
            }
        }

        fn beforeRemove(
            self: *Self,
            comptime group_idx: usize,
            comptime field_name: []const u8,
            entity_id: EntityIdType,
        ) void {
            const owned = g_fields[group_idx].type.owned_fields;
            const size = self.sizes[group_idx];
            if (size == 0) return;

            const primary = &@field(self.stores.*, field_name);
            const idx = primary.indexOf(entity_id) orelse return;
            if (idx >= size) return; // not a member of the packed prefix

            if (std.debug.runtime_safety) {
                self.debugAssertMember(group_idx, entity_id);
            }

            const s = size - 1;
            // Unpack: swap with last packed slot on all owned stores.
            inline for (owned) |fname| {
                const store = &@field(self.stores.*, fname);
                const eidx = store.indexOf(entity_id).?;
                store.swapDense(eidx, s);
            }
            self.sizes[group_idx] = s;
        }

        fn debugAssertMember(self: *Self, comptime group_idx: usize, entity_id: EntityIdType) void {
            const owned = g_fields[group_idx].type.owned_fields;
            const size = self.sizes[group_idx];
            var first_idx: ?usize = null;
            inline for (owned) |fname| {
                const store = &@field(self.stores.*, fname);
                const eidx = store.indexOf(entity_id) orelse {
                    std.debug.panic("group member missing from store '{s}'", .{fname});
                };
                if (eidx >= size) {
                    std.debug.panic("group member index {d} >= size {d} on '{s}'", .{ eidx, size, fname });
                }
                if (first_idx) |fi| {
                    if (eidx != fi) {
                        std.debug.panic("group member index mismatch: {d} vs {d} on '{s}'", .{ fi, eidx, fname });
                    }
                } else {
                    first_idx = eidx;
                }
            }
            // Prefix entity ids must match across stores.
            var i: usize = 0;
            while (i < size) : (i += 1) {
                const first_store = &@field(self.stores.*, owned[0]);
                const eid = first_store.entity_ids.items[i];
                inline for (owned) |fname| {
                    const store = &@field(self.stores.*, fname);
                    if (store.entity_ids.items[i] != eid) {
                        std.debug.panic("group prefix entity mismatch at {d} on '{s}'", .{ i, fname });
                    }
                }
            }
        }
    };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;

const Pos = struct { x: f32, y: f32 };
const Vel = struct { dx: f32, dy: f32 };
const Sprite = struct { id: u32 };

const TestStores = struct {
    pos: SparseSet(Pos),
    vel: SparseSet(Vel),
    sprite: SparseSet(Sprite),
};

test "FullOwning - extract owned_fields" {
    const M = FullOwning(.{ .pos, .vel });
    try testing.expectEqual(@as(usize, 2), M.owned_fields.len);
    try testing.expectEqualStrings("pos", M.owned_fields[0]);
    try testing.expectEqualStrings("vel", M.owned_fields[1]);
}

test "validateGroupsMessage - empty Groups ok" {
    const msg = comptime validateGroupsMessage(TestStores, struct {});
    try testing.expect(msg == null);
}

test "validateGroupsMessage - valid full-owning group" {
    const Groups = struct {
        movers: FullOwning(.{ .pos, .vel }),
    };
    const msg = comptime validateGroupsMessage(TestStores, Groups);
    try testing.expect(msg == null);
}

test "validateGroupsMessage - double-own rejected" {
    const Groups = struct {
        movers: FullOwning(.{ .pos, .vel }),
        renderables: FullOwning(.{ .pos, .sprite }),
    };
    const msg = comptime validateGroupsMessage(TestStores, Groups);
    try testing.expect(msg != null);
    try testing.expect(std.mem.indexOf(u8, msg.?, "double-own") != null);
}

test "validateGroupsMessage - single-field group rejected by FullOwning" {
    // FullOwning itself @compileError on <2 fields. Validation path that
    // receives a hand-rolled 1-field marker still rejects.
    const OneField = struct {
        pub const owned_fields: []const []const u8 = &.{"pos"};
        pub const is_full_owning_group = true;
    };
    const Groups = struct {
        bad: OneField,
    };
    const msg = comptime validateGroupsMessage(TestStores, Groups);
    try testing.expect(msg != null);
    try testing.expect(std.mem.indexOf(u8, msg.?, "at least 2") != null);
}

test "validateGroupsMessage - unknown field rejected" {
    const Groups = struct {
        movers: FullOwning(.{ .pos, .nope }),
    };
    const msg = comptime validateGroupsMessage(TestStores, Groups);
    try testing.expect(msg != null);
    try testing.expect(std.mem.indexOf(u8, msg.?, "unknown") != null);
}

test "ownedFieldsCollideWithEntities - rejects entities store name" {
    try testing.expect(ownedFieldsCollideWithEntities(&.{ "pos", "entities" }));
    try testing.expect(!ownedFieldsCollideWithEntities(&.{ "pos", "vel" }));
}

test "findGroupIndexByName - matches Groups field name" {
    const Groups = struct {
        movers: FullOwning(.{ .pos, .vel }),
    };
    const idx = comptime findGroupIndexByName(Groups, "movers");
    try testing.expectEqual(@as(?usize, 0), idx);
    const miss = comptime findGroupIndexByName(Groups, "renderables");
    try testing.expect(miss == null);
}

test "FullOwningGroup - groupSlice lengths equal size and re-derive" {
    const Groups = struct {
        movers: FullOwning(.{ .pos, .vel }),
    };
    var stores: TestStores = .{
        .pos = SparseSet(Pos).init(testing.allocator),
        .vel = SparseSet(Vel).init(testing.allocator),
        .sprite = SparseSet(Sprite).init(testing.allocator),
    };
    defer {
        stores.pos.deinit();
        stores.vel.deinit();
        stores.sprite.deinit();
    }

    var size: usize = 0;
    const View = FullOwningGroup(TestStores, Groups, .movers);
    const view: View = .{ .stores = &stores, .size_ptr = &size };

    try stores.pos.insert(1, .{ .x = 1, .y = 2 });
    try stores.vel.insert(1, .{ .dx = 3, .dy = 4 });
    // Manually pack for unit test of the view only.
    size = 1;

    const g = view.groupSlice();
    try testing.expectEqual(@as(usize, 1), view.size());
    try testing.expectEqual(@as(usize, 1), g.pos.len);
    try testing.expectEqual(@as(usize, 1), g.vel.len);
    try testing.expectEqual(@as(usize, 1), g.entities.len);
    try testing.expectEqual(@as(f32, 1), g.pos[0].x);
    try testing.expectEqual(@as(f32, 3), g.vel[0].dx);

    view.groupSlice().pos[0].x = 99;
    try testing.expectEqual(@as(f32, 99), stores.pos.getConst(1).?.x);
}
