// Per-tick snapshot of raw input device state. Refreshed pre-tick by an
// input source (terminal, windowing library, test harness); read by systems
// and the input translator.
//
// Three key sets distinguish *edge* events (transitions this frame) from
// *level* state (currently held). Contract:
//   keys_down.contains(k)  ⇔  key k is held (backend best-effort)
// Release latency is backend-defined (sticky grace vs real key-up).
// Input sources own how hold is synthesized; sim systems only read the snapshot.

const std = @import("std");

pub const Key = enum(u8) {
    space,
    enter,
    escape,
    backspace,
    tab,

    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,

    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
};

pub const MouseButton = enum {
    left,
    right,
    middle,
};

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const InputState = struct {
    keys_pressed: std.EnumSet(Key) = .{},
    keys_down: std.EnumSet(Key) = .{},
    keys_released: std.EnumSet(Key) = .{},

    mouse_pos: Vec2 = .{},
    mouse_buttons_pressed: std.EnumSet(MouseButton) = .{},
    mouse_buttons_down: std.EnumSet(MouseButton) = .{},
    mouse_buttons_released: std.EnumSet(MouseButton) = .{},

    // Required by World's auto-init loop. Holds no allocator state today;
    // the allocator is accepted for shape symmetry with the sparse-set
    // stores so that `World.init` can construct any field uniformly.
    pub fn init(_: std.mem.Allocator) InputState {
        return .{};
    }

    pub fn deinit(_: *InputState) void {}

    // Clear only the edge sets, preserving `keys_down` / `mouse_buttons_down`
    // until the input source re-projects level on the next poll.
    //
    // Edge ownership (frame-scoped):
    //   1. Input source: clearEdges at start of each poll, then fill edges
    //   2. UI may clear again after routing (idempotent)
    //   3. The input translator clears after bindings
    // Lives here so every source resets edges identically and tests can
    // simulate a frame boundary without touching source internals.
    pub fn clearEdges(self: *InputState) void {
        self.keys_pressed = .{};
        self.keys_released = .{};
        self.mouse_buttons_pressed = .{};
        self.mouse_buttons_released = .{};
    }
};

// ====================================================================
// TESTS
// ====================================================================

const testing = std.testing;

test "InputState - default is empty" {
    const s: InputState = .{};
    try testing.expect(s.keys_pressed.count() == 0);
    try testing.expect(s.keys_down.count() == 0);
    try testing.expect(s.keys_released.count() == 0);
    try testing.expectEqual(@as(f32, 0), s.mouse_pos.x);
}

test "InputState - clearEdges leaves down state intact" {
    var s: InputState = .{};
    s.keys_pressed.insert(.space);
    s.keys_down.insert(.space);
    s.keys_released.insert(.escape);

    s.clearEdges();

    try testing.expect(!s.keys_pressed.contains(.space));
    try testing.expect(s.keys_down.contains(.space));
    try testing.expect(!s.keys_released.contains(.escape));
}

test "InputState - World-shaped init/deinit" {
    var s = InputState.init(testing.allocator);
    defer s.deinit();
    try testing.expect(s.keys_down.count() == 0);
}
