const std = @import("std");
const SparseSet = @import("./sparse_set.zig").SparseSet;
const DenseSparseSet = @import("./dense_sparse_set.zig").DenseSparseSet;
const constants = @import("./constants.zig");
const EntityIdType = constants.EntityIdType;

/// Free entry point — runs a query against any Stores struct.
pub fn query(stores: anytype, comptime Components: []const type) makeQueries(@typeInfo(@TypeOf(stores.*)).@"struct".fields).Query(Components) {
    const Stores = @TypeOf(stores.*);
    const store_fields = @typeInfo(Stores).@"struct".fields;
    const QMod = makeQueries(store_fields);
    const Q = QMod.Query(Components);
    var q: Q = undefined;

    inline for (Components, 0..) |C, i| {
        const fi = comptime QMod.storeFieldIndexFor(C);
        const fname = store_fields[fi].name;
        const sptr = &@field(stores, fname);
        @field(q.store_ptrs, std.fmt.comptimePrint("{d}", .{i})) = sptr;
    }

    var min_count: usize = std.math.maxInt(usize);
    var driver_idx: usize = 0;
    inline for (Components, 0..) |C, i| {
        const fi = comptime QMod.storeFieldIndexFor(C);
        const sptr = &@field(stores, store_fields[fi].name);
        const cnt = sptr.getCount();
        if (cnt < min_count) {
            min_count = cnt;
            driver_idx = i;
        }
    }
    q.driver_index = 0;
    inline for (Components, 0..) |C, i| {
        if (i == driver_idx) {
            const fi = comptime QMod.storeFieldIndexFor(C);
            const sptr = &@field(stores, store_fields[fi].name);
            q.driver_ids = sptr.entity_ids.items;
        }
    }
    return q;
}

/// Free entry point — query with exclusion filter.
pub fn queryExclude(
    stores: anytype,
    comptime Include: []const type,
    comptime Exclude: []const type,
) makeQueries(@typeInfo(@TypeOf(stores.*)).@"struct".fields).QueryExclude(Include, Exclude) {
    const Stores = @TypeOf(stores.*);
    const store_fields = @typeInfo(Stores).@"struct".fields;
    const QMod = makeQueries(store_fields);
    const Q = QMod.QueryExclude(Include, Exclude);
    var q: Q = undefined;

    inline for (Include, 0..) |C, i| {
        const fi = comptime QMod.storeFieldIndexFor(C);
        const fname = store_fields[fi].name;
        const sptr = &@field(stores, fname);
        @field(q.store_ptrs, std.fmt.comptimePrint("{d}", .{i})) = sptr;
    }
    inline for (Exclude, 0..) |E, i| {
        const fi = comptime QMod.storeFieldIndexFor(E);
        const fname = store_fields[fi].name;
        const sptr = &@field(stores, fname);
        @field(q.exclude_ptrs, std.fmt.comptimePrint("{d}", .{i})) = sptr;
    }

    var min_count: usize = std.math.maxInt(usize);
    var driver_idx: usize = 0;
    inline for (Include, 0..) |C, i| {
        const fi = comptime QMod.storeFieldIndexFor(C);
        const sptr = &@field(stores, store_fields[fi].name);
        const cnt = sptr.getCount();
        if (cnt < min_count) {
            min_count = cnt;
            driver_idx = i;
        }
    }
    q.driver_index = 0;
    inline for (Include, 0..) |C, i| {
        if (i == driver_idx) {
            const fi = comptime QMod.storeFieldIndexFor(C);
            const sptr = &@field(stores, store_fields[fi].name);
            q.driver_ids = sptr.entity_ids.items;
        }
    }
    return q;
}

/// Returns a namespace containing Query, QueryExclude, and storeFieldIndexFor,
/// all parameterised on the store fields of a specific World instantiation.
pub fn makeQueries(comptime store_fields: []const std.builtin.Type.StructField) type {
    return struct {
        pub inline fn storeFieldIndexFor(comptime C: type) usize {
            comptime {
                for (store_fields, 0..) |f, j| {
                    if (f.type == SparseSet(C) or f.type == DenseSparseSet(C)) return j;
                }
                @compileError("Component " ++ @typeName(C) ++ " not registered in Stores");
            }
        }

        pub fn Query(comptime Components: []const type) type {
            if (Components.len == 0) @compileError("Query requires at least one component type");

            const field_indices: [Components.len]usize = comptime blk: {
                var inds: [Components.len]usize = undefined;
                for (Components, 0..) |C, i| inds[i] = storeFieldIndexFor(C);
                break :blk inds;
            };

            const StorePtrs = comptime blk: {
                var ts: [Components.len]type = undefined;
                for (0..Components.len) |i| ts[i] = *store_fields[field_indices[i]].type;
                break :blk std.meta.Tuple(&ts);
            };

            const Result = blk: {
                var names: [Components.len + 1][]const u8 = undefined;
                var result_types: [Components.len + 1]type = undefined;
                var result_attrs: [Components.len + 1]std.builtin.Type.StructField.Attributes = undefined;
                names[0] = "entity";
                result_types[0] = EntityIdType;
                result_attrs[0] = .{};
                inline for (Components, 0..) |C, i| {
                    names[i + 1] = std.fmt.comptimePrint("c{d}", .{i});
                    result_types[i + 1] = *C;
                    result_attrs[i + 1] = .{};
                }
                break :blk @Struct(.auto, null, &names, &result_types, &result_attrs);
            };

            return struct {
                const Q = @This();

                store_ptrs: StorePtrs,
                driver_ids: []const EntityIdType,
                driver_index: usize,

                pub fn next(self: *Q) ?Result {
                    while (self.driver_index < self.driver_ids.len) {
                        const eid = self.driver_ids[self.driver_index];
                        self.driver_index += 1;

                        var all_present = true;
                        probe: inline for (0..Components.len) |i| {
                            const store = @field(self.store_ptrs, std.fmt.comptimePrint("{d}", .{i}));
                            if (!store.has(eid)) {
                                all_present = false;
                                break :probe;
                            }
                        }
                        if (!all_present) continue;

                        var res: Result = undefined;
                        res.entity = eid;
                        inline for (Components, 0..) |_, i| {
                            const store = @field(self.store_ptrs, std.fmt.comptimePrint("{d}", .{i}));
                            const ptr = store.get(eid).?;
                            @field(res, std.fmt.comptimePrint("c{d}", .{i})) = ptr;
                        }
                        return res;
                    }
                    return null;
                }
            };
        }

        /// Iterator that yields entities with ALL of `Include` and NONE of `Exclude`.
        /// Unregistered type or include/exclude overlap → @compileError.
        pub fn QueryExclude(comptime Include: []const type, comptime Exclude: []const type) type {
            if (Include.len == 0) @compileError("QueryExclude requires at least one include component type");

            comptime {
                for (Include) |I| {
                    for (Exclude) |E| {
                        if (I == E) @compileError("Component " ++ @typeName(I) ++ " appears in both Include and Exclude");
                    }
                }
            }

            const include_field_indices: [Include.len]usize = comptime blk: {
                var inds: [Include.len]usize = undefined;
                for (Include, 0..) |C, i| inds[i] = storeFieldIndexFor(C);
                break :blk inds;
            };

            const exclude_field_indices: [Exclude.len]usize = comptime blk: {
                var inds: [Exclude.len]usize = undefined;
                for (Exclude, 0..) |C, i| inds[i] = storeFieldIndexFor(C);
                break :blk inds;
            };

            const IncludeStorePtrs = comptime blk: {
                var ts: [Include.len]type = undefined;
                for (0..Include.len) |i| ts[i] = *store_fields[include_field_indices[i]].type;
                break :blk std.meta.Tuple(&ts);
            };

            const ExcludeStorePtrs = comptime blk: {
                var ts: [Exclude.len]type = undefined;
                for (0..Exclude.len) |i| ts[i] = *store_fields[exclude_field_indices[i]].type;
                break :blk std.meta.Tuple(&ts);
            };

            const Result = blk: {
                var names: [Include.len + 1][]const u8 = undefined;
                var result_types: [Include.len + 1]type = undefined;
                var result_attrs: [Include.len + 1]std.builtin.Type.StructField.Attributes = undefined;
                names[0] = "entity";
                result_types[0] = EntityIdType;
                result_attrs[0] = .{};
                inline for (Include, 0..) |C, i| {
                    names[i + 1] = std.fmt.comptimePrint("c{d}", .{i});
                    result_types[i + 1] = *C;
                    result_attrs[i + 1] = .{};
                }
                break :blk @Struct(.auto, null, &names, &result_types, &result_attrs);
            };

            return struct {
                const Q = @This();

                store_ptrs: IncludeStorePtrs,
                exclude_ptrs: ExcludeStorePtrs,
                driver_ids: []const EntityIdType,
                driver_index: usize,

                pub fn next(self: *Q) ?Result {
                    while (self.driver_index < self.driver_ids.len) {
                        const eid = self.driver_ids[self.driver_index];
                        self.driver_index += 1;

                        var all_present = true;
                        probe: inline for (0..Include.len) |i| {
                            const store = @field(self.store_ptrs, std.fmt.comptimePrint("{d}", .{i}));
                            if (!store.has(eid)) {
                                all_present = false;
                                break :probe;
                            }
                        }
                        if (!all_present) continue;

                        var excluded = false;
                        exclude_probe: inline for (0..Exclude.len) |i| {
                            const store = @field(self.exclude_ptrs, std.fmt.comptimePrint("{d}", .{i}));
                            if (store.has(eid)) {
                                excluded = true;
                                break :exclude_probe;
                            }
                        }
                        if (excluded) continue;

                        var res: Result = undefined;
                        res.entity = eid;
                        inline for (Include, 0..) |_, i| {
                            const store = @field(self.store_ptrs, std.fmt.comptimePrint("{d}", .{i}));
                            const ptr = store.get(eid).?;
                            @field(res, std.fmt.comptimePrint("c{d}", .{i})) = ptr;
                        }
                        return res;
                    }
                    return null;
                }
            };
        }
    };
}
