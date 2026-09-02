const std = @import("std");
const builtin = @import("builtin");

fn nanoTimestamp() i128 {
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return @intCast(std.Io.Timestamp.now(S.threaded.io(), .awake).nanoseconds);
}

/// Wraps system `T` so `update` only fires when the accumulator crosses
/// `interval` seconds. Debt is clamped to `max_debt_multiplier * interval`
/// before draining (mirrors a typical outer fixed-step sim loop).
/// Each drain step passes `interval` as dt — fixed-step semantics.
///
/// interval == 0.0  →  always-tick sentinel: accumulator is compiled away,
///                     inner.update(dt) is called on every tick with zero overhead.
///
///   ThrottledSystem(SlowSystem, 1.0)        // ~once per second, max 5 fires/tick
///   ThrottledSystemN(SlowSystem, 1.0, 3)    // custom max-debt multiplier
///   ThrottledSystem(FastSystem, 0.0)        // always-tick sentinel
///
/// .metrics is populated in Debug builds and compiled to void in all release modes.
/// Guard reads with `if (builtin.mode == .Debug) { ... }` in code that must compile
/// in both modes.
///
/// Inner system is accessible via `.inner` for metrics reads etc.
/// `init` is unconditionally declared and forwards to inner when inner declares it —
/// the inner @hasDecl is the real gate, not the wrapper.
const metrics_enabled = builtin.mode == .Debug;

/// Per-system timing metrics. Present only in Debug builds; void in release.
pub const Metrics = struct {
    /// Number of times inner.update was called (actual simulation steps).
    fire_count: u64 = 0,
    /// Number of times the outer update was called (frame ticks received).
    tick_count: u64 = 0,
    /// Total accumulated debt discarded by the clamp (thundering-herd indicator).
    debt_dropped: f32 = 0.0,
    /// EMA of inner.update() wall-clock time per call (nanoseconds).
    update_ns: f64 = 0.0,

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }
};

pub fn ThrottledSystem(comptime T: type, comptime interval: f32) type {
    return ThrottledSystemCore(T, interval, 5);
}

pub fn ThrottledSystemN(comptime T: type, comptime interval: f32, comptime max_debt_multiplier: u32) type {
    return ThrottledSystemCore(T, interval, max_debt_multiplier);
}

fn ThrottledSystemCore(
    comptime T: type,
    comptime interval: f32,
    comptime max_debt_multiplier: u32,
) type {
    if (interval < 0.0) @compileError("ThrottledSystem: interval must be >= 0");

    if (interval == 0.0) {
        return struct {
            inner: T = .{},
            metrics: if (metrics_enabled) Metrics else void = if (metrics_enabled) .{} else {},

            pub fn init(self: *@This(), world: anytype) void {
                if (comptime @hasDecl(T, "init")) self.inner.init(world);
            }

            pub fn update(self: *@This(), dt: f32) void {
                if (metrics_enabled) {
                    self.metrics.tick_count += 1;
                    self.metrics.fire_count += 1;
                    const t0 = nanoTimestamp();
                    self.inner.update(dt);
                    const elapsed: f64 = @floatFromInt(nanoTimestamp() - t0);
                    self.metrics.update_ns = if (self.metrics.update_ns == 0) elapsed else 0.05 * elapsed + 0.95 * self.metrics.update_ns;
                } else {
                    self.inner.update(dt);
                }
            }
        };
    }

    const max_debt: f32 = interval * @as(f32, @floatFromInt(max_debt_multiplier));

    return struct {
        inner: T = .{},
        accumulator: f32 = interval,
        metrics: if (metrics_enabled) Metrics else void = if (metrics_enabled) .{} else {},

        pub fn init(self: *@This(), world: anytype) void {
            if (comptime @hasDecl(T, "init")) self.inner.init(world);
        }

        pub fn update(self: *@This(), dt: f32) void {
            if (metrics_enabled) self.metrics.tick_count += 1;

            self.accumulator += dt;

            if (self.accumulator > max_debt) {
                if (metrics_enabled) self.metrics.debt_dropped += self.accumulator - max_debt;
                self.accumulator = max_debt;
            }

            while (self.accumulator >= interval) {
                self.accumulator -= interval;
                if (metrics_enabled) {
                    self.metrics.fire_count += 1;
                    const t0 = nanoTimestamp();
                    self.inner.update(interval);
                    const elapsed: f64 = @floatFromInt(nanoTimestamp() - t0);
                    self.metrics.update_ns = if (self.metrics.update_ns == 0) elapsed else 0.05 * elapsed + 0.95 * self.metrics.update_ns;
                } else {
                    self.inner.update(interval);
                }
            }
        }
    };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;
const World = @import("./world.zig").World;
const SparseSet = @import("./sparse_set.zig").SparseSet;

const CountSystem = struct {
    calls: u32 = 0,
    last_dt: f32 = 0.0,

    pub fn update(self: *@This(), dt: f32) void {
        self.calls += 1;
        self.last_dt = dt;
    }
};

const InitSystem = struct {
    initialised: bool = false,

    pub fn init(self: *@This(), world: anytype) void {
        _ = world;
        self.initialised = true;
    }

    pub fn update(_: *@This(), _: f32) void {}
};

test "ThrottledSystem(0.0) calls inner every tick with real dt" {
    var s = ThrottledSystem(CountSystem, 0.0){};
    s.update(0.016);
    s.update(0.016);
    s.update(0.016);
    try testing.expectEqual(@as(u32, 3), s.inner.calls);
    try testing.expectApproxEqAbs(@as(f32, 0.016), s.inner.last_dt, 1e-6);
}

test "ThrottledSystem fires immediately on first update, then follows interval" {
    var s = ThrottledSystem(CountSystem, 1.0){};
    s.update(0.1); // accumulator was at interval → fires immediately, remainder 0.1
    try testing.expectEqual(@as(u32, 1), s.inner.calls);
    s.update(0.8); // 0.1 + 0.8 = 0.9 < 1.0 → no fire
    try testing.expectEqual(@as(u32, 1), s.inner.calls);
    s.update(0.2); // 0.9 + 0.2 = 1.1 → fires once
    try testing.expectEqual(@as(u32, 2), s.inner.calls);
}

test "ThrottledSystem passes interval as dt per step" {
    var s = ThrottledSystem(CountSystem, 1.0){};
    // accumulator starts at interval; first update fires immediately then again if enough dt
    s.update(0.5); // 1.0 + 0.5 = 1.5 → fires once, remainder 0.5
    try testing.expectEqual(@as(u32, 1), s.inner.calls);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.inner.last_dt, 1e-6);
}

test "ThrottledSystem drain loop fires multiple times" {
    var s = ThrottledSystem(CountSystem, 1.0){};
    s.update(2.9); // 1.0 + 2.9 = 3.9 → fires 3 times, remainder 0.9
    try testing.expectEqual(@as(u32, 3), s.inner.calls);
    try testing.expectApproxEqAbs(@as(f32, 0.9), s.accumulator, 1e-5);
}

test "ThrottledSystem clamps debt to 5 * interval by default" {
    var s = ThrottledSystem(CountSystem, 1.0){};
    s.update(100.0); // would be 100 fires without clamp
    try testing.expectEqual(@as(u32, 5), s.inner.calls);
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.accumulator, 1e-5);
}

test "ThrottledSystemN respects custom max_debt_multiplier" {
    var s = ThrottledSystemN(CountSystem, 1.0, 2){};
    s.update(100.0);
    try testing.expectEqual(@as(u32, 2), s.inner.calls);
}

test "ThrottledSystem remainder carries to next tick" {
    var s = ThrottledSystem(CountSystem, 1.0){};
    s.update(0.1); // fires immediately, remainder 0.1
    try testing.expectEqual(@as(u32, 1), s.inner.calls);
    s.update(0.8); // 0.1 + 0.8 = 0.9 < 1.0 → no fire
    try testing.expectEqual(@as(u32, 1), s.inner.calls);
    s.update(0.2); // 0.9 + 0.2 = 1.1 → fires once, remainder 0.1
    try testing.expectEqual(@as(u32, 2), s.inner.calls);
    try testing.expectApproxEqAbs(@as(f32, 0.1), s.accumulator, 1e-6);
}

test "ThrottledSystem forwards init to inner" {
    var s = ThrottledSystem(InitSystem, 1.0){};
    const FakeWorld = struct {};
    var w = FakeWorld{};
    s.init(&w);
    try testing.expect(s.inner.initialised);
}

test "ThrottledSystem(0.0) forwards init to inner" {
    var s = ThrottledSystem(InitSystem, 0.0){};
    const FakeWorld = struct {};
    var w = FakeWorld{};
    s.init(&w);
    try testing.expect(s.inner.initialised);
}

test "ThrottledSystem compiles for system with no init or setWorld" {
    comptime {
        _ = ThrottledSystem(CountSystem, 1.0);
        _ = ThrottledSystem(CountSystem, 0.0);
    }
}

test "ThrottledSystem integrates with World" {
    const Stores = struct {
        values: SparseSet(i32),
    };
    const Systems = struct {
        throttled: ThrottledSystem(CountSystem, 1.0),
    };
    const W = World(Stores, Systems);

    var world: W = undefined;
    world.init(testing.allocator);
    defer world.deinit();

    // accumulator starts at interval=1.0; each tick of 0.6 crosses the threshold
    try world.tick(0.6); // 1.0+0.6=1.6 → fires once, remainder 0.6
    try world.tick(0.6); // 0.6+0.6=1.2 → fires once, remainder 0.2
    try testing.expectEqual(@as(u32, 2), world.systems.throttled.inner.calls);
}

// ---- Metrics tests (only meaningful in Debug; zig test runs Debug by default) ----

test "metrics: tick_count and fire_count" {
    if (!metrics_enabled) return;
    var s = ThrottledSystem(CountSystem, 1.0){};
    s.update(0.6); // 1.0+0.6=1.6 → 1 fire
    s.update(0.6); // 0.6+0.6=1.2 → 1 fire; 2 fires total
    try testing.expectEqual(@as(u64, 2), s.metrics.tick_count);
    try testing.expectEqual(@as(u64, 2), s.metrics.fire_count);
}

test "metrics: debt_dropped on clamp" {
    if (!metrics_enabled) return;
    var s = ThrottledSystem(CountSystem, 1.0){};
    s.update(100.0); // 1.0+100.0=101.0, clamped to max_debt=5.0, dropped=96.0
    try testing.expectEqual(@as(u64, 5), s.metrics.fire_count);
    try testing.expectApproxEqAbs(@as(f32, 96.0), s.metrics.debt_dropped, 1e-3);
}

test "metrics: no debt_dropped when within budget" {
    if (!metrics_enabled) return;
    var s = ThrottledSystem(CountSystem, 1.0){};
    s.update(3.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.metrics.debt_dropped, 1e-6);
}

test "metrics: reset clears all fields" {
    if (!metrics_enabled) return;
    var s = ThrottledSystem(CountSystem, 1.0){};
    s.update(100.0);
    s.metrics.reset();
    try testing.expectEqual(@as(u64, 0), s.metrics.tick_count);
    try testing.expectEqual(@as(u64, 0), s.metrics.fire_count);
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.metrics.debt_dropped, 1e-6);
}

test "metrics: always-tick tick_count == fire_count" {
    if (!metrics_enabled) return;
    var s = ThrottledSystem(CountSystem, 0.0){};
    s.update(0.016);
    s.update(0.016);
    s.update(0.016);
    try testing.expectEqual(@as(u64, 3), s.metrics.tick_count);
    try testing.expectEqual(@as(u64, 3), s.metrics.fire_count);
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.metrics.debt_dropped, 1e-6);
}

test "metrics: ThrottledSystemN tracks debt_dropped" {
    if (!metrics_enabled) return;
    var s = ThrottledSystemN(CountSystem, 1.0, 2){};
    s.update(100.0); // 1.0+100.0=101.0, clamped to max_debt=2.0, dropped=99.0
    try testing.expectEqual(@as(u64, 2), s.metrics.fire_count);
    try testing.expectApproxEqAbs(@as(f32, 99.0), s.metrics.debt_dropped, 1e-2);
}

test "metrics field is void in release builds" {
    // In debug this is Metrics (non-zero); in release it is void (zero).
    const S = ThrottledSystem(CountSystem, 1.0);
    const expected_size: usize = if (metrics_enabled) @sizeOf(Metrics) else 0;
    try testing.expectEqual(expected_size, @sizeOf(@TypeOf(@as(S, .{}).metrics)));
}
