//! Fixed-capacity chronological ring buffer (sliding window).
//! Generic engine primitive — wrap this for domain-specific sampling.

const std = @import("std");

/// Ring of up to `capacity` values of type `T`.
/// When full, `push` overwrites the oldest sample.
/// Chronological order is always oldest → newest.
pub fn SlidingWindow(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (capacity == 0) @compileError("SlidingWindow capacity must be > 0");
    }

    return struct {
        const Self = @This();
        pub const Capacity = capacity;
        pub const Elem = T;

        samples: [capacity]T = undefined,
        /// Next write index (also the oldest sample index when full).
        head: usize = 0,
        /// Valid sample count in `0..capacity`.
        count: usize = 0,

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.count = 0;
        }

        pub fn len(self: Self) usize {
            return self.count;
        }

        pub fn isEmpty(self: Self) bool {
            return self.count == 0;
        }

        pub fn isFull(self: Self) bool {
            return self.count == capacity;
        }

        /// Append `value`, dropping the oldest sample if the window is full.
        pub fn push(self: *Self, value: T) void {
            self.samples[self.head] = value;
            self.head = (self.head + 1) % capacity;
            if (self.count < capacity) self.count += 1;
        }

        /// Overwrite the newest sample. No-op if empty.
        pub fn setLatest(self: *Self, value: T) void {
            if (self.count == 0) return;
            self.samples[self.latestIndex()] = value;
        }

        /// Newest sample, if any.
        pub fn latest(self: *const Self) ?T {
            if (self.count == 0) return null;
            return self.samples[self.latestIndex()];
        }

        fn latestIndex(self: Self) usize {
            if (self.count < capacity) return self.count - 1;
            return (self.head + capacity - 1) % capacity;
        }

        /// Sample at chronological index `i` (0 = oldest). Returns null if out of range.
        pub fn get(self: Self, i: usize) ?T {
            if (i >= self.count) return null;
            if (self.count < capacity) return self.samples[i];
            return self.samples[(self.head + i) % capacity];
        }

        /// Copy oldest → newest into `out`. Returns number of samples written.
        pub fn copyChronological(self: Self, out: *[capacity]T) usize {
            if (self.count == 0) return 0;
            if (self.count < capacity) {
                @memcpy(out[0..self.count], self.samples[0..self.count]);
                return self.count;
            }
            for (0..capacity) |i| {
                out[i] = self.samples[(self.head + i) % capacity];
            }
            return capacity;
        }
    };
}

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;

test "SlidingWindow - push grows until capacity" {
    var w = SlidingWindow(f32, 4){};
    try testing.expect(w.isEmpty());
    w.push(1);
    w.push(2);
    try testing.expectEqual(@as(usize, 2), w.len());
    try testing.expectApproxEqAbs(@as(f32, 1), w.get(0).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), w.get(1).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), w.latest().?, 1e-6);
}

test "SlidingWindow - setLatest updates newest only" {
    var w = SlidingWindow(i32, 3){};
    w.push(10);
    w.push(20);
    w.setLatest(25);
    try testing.expectEqual(@as(usize, 2), w.len());
    try testing.expectEqual(@as(i32, 10), w.get(0).?);
    try testing.expectEqual(@as(i32, 25), w.get(1).?);
}

test "SlidingWindow - full ring drops oldest" {
    var w = SlidingWindow(u32, 3){};
    w.push(1);
    w.push(2);
    w.push(3);
    w.push(4);
    try testing.expect(w.isFull());
    try testing.expectEqual(@as(usize, 3), w.len());
    try testing.expectEqual(@as(u32, 2), w.get(0).?);
    try testing.expectEqual(@as(u32, 3), w.get(1).?);
    try testing.expectEqual(@as(u32, 4), w.get(2).?);
}

test "SlidingWindow - copyChronological order" {
    var w = SlidingWindow(f32, 4){};
    w.push(10);
    w.push(20);
    w.push(30);
    w.push(40);
    w.push(50); // drops 10
    var out: [4]f32 = undefined;
    const n = w.copyChronological(&out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectApproxEqAbs(@as(f32, 20), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 50), out[3], 1e-6);
}

test "SlidingWindow - clear" {
    var w = SlidingWindow(u8, 2){};
    w.push(1);
    w.clear();
    try testing.expect(w.isEmpty());
    try testing.expect(w.latest() == null);
}
