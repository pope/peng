const intents = @import("intents");
const sdl = @import("sdl");
const state = @import("state");
const std = @import("std");

const FrameInput = state.FrameInput;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;

pub const MOUSE_WHEEL_SCROLL_MULTIPLIER: f32 = 6.0;

/// Translates an SDL3 keycode into the application's pure `Key` enum variant.
pub fn mapKeyFromSdl(key: sdl.keys.Keycode) Key {
    return switch (key) {
        sdl.keys.escape => .escape,
        sdl.keys.return_key, sdl.keys.kp_enter => .return_key,
        sdl.keys.backspace => .backspace,
        sdl.keys.tab => .tab,
        sdl.keys.space => .space,
        sdl.keys.left => .left,
        sdl.keys.right => .right,
        sdl.keys.up => .up,
        sdl.keys.down => .down,
        sdl.keys.equals, sdl.keys.kp_plus => .equals,
        sdl.keys.minus, sdl.keys.kp_minus => .minus,
        sdl.keys.left_bracket => .left_bracket,
        sdl.keys.right_bracket => .right_bracket,
        sdl.keys.home => .home,
        sdl.keys.end => .end,
        sdl.keys.page_up => .page_up,
        sdl.keys.page_down => .page_down,
        sdl.keys.f1 => .f1,
        sdl.keys.f5 => .f5,
        sdl.keys.f11 => .f11,
        sdl.keys.colon => .colon,
        sdl.keys.semicolon => .semicolon,
        sdl.keys.slash => .slash,
        sdl.keys.question => .question,
        sdl.keys.period => .period,
        sdl.keys.comma => .comma,
        sdl.keys.less => .less,
        sdl.keys.greater => .greater,
        sdl.keys.backslash => .backslash,
        sdl.keys.char_0, sdl.keys.kp_0 => .char_0,
        sdl.keys.char_1, sdl.keys.kp_1 => .char_1,
        sdl.keys.char_2, sdl.keys.kp_2 => .char_2,
        sdl.keys.char_3, sdl.keys.kp_3 => .char_3,
        sdl.keys.char_4, sdl.keys.kp_4 => .char_4,
        sdl.keys.char_5, sdl.keys.kp_5 => .char_5,
        sdl.keys.char_6, sdl.keys.kp_6 => .char_6,
        sdl.keys.char_7, sdl.keys.kp_7 => .char_7,
        sdl.keys.char_8, sdl.keys.kp_8 => .char_8,
        sdl.keys.char_9, sdl.keys.kp_9 => .char_9,
        sdl.keys.key_a => .char_a,
        sdl.keys.key_b => .char_b,
        sdl.keys.key_c => .char_c,
        sdl.keys.key_d => .char_d,
        sdl.keys.key_e => .char_e,
        sdl.keys.key_f => .char_f,
        sdl.keys.key_g => .char_g,
        sdl.keys.key_h => .char_h,
        sdl.keys.key_i => .char_i,
        sdl.keys.key_j => .char_j,
        sdl.keys.key_k => .char_k,
        sdl.keys.key_l => .char_l,
        sdl.keys.key_m => .char_m,
        sdl.keys.key_n => .char_n,
        sdl.keys.key_o => .char_o,
        sdl.keys.key_p => .char_p,
        sdl.keys.key_q => .char_q,
        sdl.keys.key_r => .char_r,
        sdl.keys.key_s => .char_s,
        sdl.keys.key_t => .char_t,
        sdl.keys.key_u => .char_u,
        sdl.keys.key_v => .char_v,
        sdl.keys.key_w => .char_w,
        sdl.keys.key_x => .char_x,
        sdl.keys.key_y => .char_y,
        sdl.keys.key_z => .char_z,
        else => .unknown,
    };
}

/// Maps an SDL keyboard modifier bitmask into a `KeyModifiers` record.
pub fn mapModFromSdl(mod: u16) KeyModifiers {
    return .{
        .ctrl = (mod & sdl.keys.mod.ctrl) != 0,
        .shift = (mod & sdl.keys.mod.shift) != 0,
        .alt = (mod & sdl.keys.mod.alt) != 0,
        .gui = (mod & sdl.keys.mod.gui) != 0,
    };
}

/// Temporary accumulator aggregating events drained during a single frame's
/// SDL polling pass.
pub const FrameInputState = struct {
    touch_tracker: state.TouchTracker = .{},
    frame_allocator: std.mem.Allocator,
    keys_pressed: std.ArrayList(Key),
    text_input_opt: ?[]const u8 = null,
    dropped_path_opt: ?[]const u8 = null,
    scroll_delta_x: f32 = 0,
    scroll_delta_y: f32 = 0,
    pinch_delta: f32 = 0,
    pinch_center_x: f32 = 0,
    pinch_center_y: f32 = 0,
    mouse_left_clicked: bool = false,
    mouse_inside: bool = false,
    window_minimized: ?bool = null,
    window_occluded: ?bool = null,
    quit_request: state.QuitRequest = .none,
    win_w: f32 = 0,
    win_h: f32 = 0,

    /// Converts accumulator state into a `FrameInput` record with default
    /// peripheral queries.
    pub fn toFrameInput(self: FrameInputState) state.FrameInput {
        return .{
            .win_w = self.win_w,
            .win_h = self.win_h,
            .scale_x = 1.0,
            .scale_y = 1.0,
            .mouse_x = 0.0,
            .mouse_y = 0.0,
            .mouse_left_down = false,
            .mouse_left_clicked = self.mouse_left_clicked,
            .mouse_inside = self.mouse_inside,
            .window_minimized = self.window_minimized,
            .window_occluded = self.window_occluded,
            .quit_request = self.quit_request,
            .scroll_delta_x = self.scroll_delta_x,
            .scroll_delta_y = self.scroll_delta_y,
            .pinch_delta = self.pinch_delta,
            .pinch_center_x = self.pinch_center_x,
            .pinch_center_y = self.pinch_center_y,
            .touch_tracker = self.touch_tracker,
            .keys_pressed = self.keys_pressed,
            .key_modifiers = .{},
            .text_input = self.text_input_opt,
            .dropped_path = self.dropped_path_opt,
            .delta_time_ms = 0.0,
            .now_ms = 0,
        };
    }
};

/// Processes a single SDL event and updates the frame input accumulator state.
pub fn processSDLEvent(event: sdl.Event, frame_input: *FrameInputState) !void {
    switch (event.type) {
        sdl.event_type.quit => frame_input.quit_request = .terminate,
        sdl.event_type.window_close_requested => {
            if (frame_input.quit_request == .none) {
                frame_input.quit_request = .window_close;
            }
        },
        sdl.event_type.window_minimized => {
            frame_input.window_minimized = true;
        },
        sdl.event_type.window_restored,
        sdl.event_type.window_maximized,
        sdl.event_type.window_enter_fullscreen,
        => {
            frame_input.window_minimized = false;
        },
        sdl.event_type.window_shown => {
            frame_input.window_minimized = false;
            frame_input.window_occluded = false;
        },
        sdl.event_type.window_occluded => {
            frame_input.window_occluded = true;
        },
        sdl.event_type.window_exposed => {
            frame_input.window_occluded = false;
        },
        sdl.event_type.mouse_enter => {
            frame_input.mouse_inside = true;
        },
        sdl.event_type.mouse_leave => {
            frame_input.mouse_inside = false;
        },
        sdl.event_type.key_down => {
            const mapped_key = mapKeyFromSdl(event.key.key);
            try frame_input.keys_pressed.append(frame_input.frame_allocator, mapped_key);
        },
        sdl.event_type.text_input => {
            if (event.text.text) |ptr| {
                const len = std.mem.len(ptr);
                if (len > 0) {
                    const slice = ptr[0..len];
                    if (frame_input.text_input_opt) |prev| {
                        const combined = try frame_input.frame_allocator.alloc(
                            u8,
                            prev.len + slice.len,
                        );
                        @memcpy(combined[0..prev.len], prev);
                        @memcpy(combined[prev.len..], slice);
                        frame_input.text_input_opt = combined;
                    } else {
                        frame_input.text_input_opt =
                            try frame_input.frame_allocator.dupe(u8, slice);
                    }
                }
            }
        },
        sdl.event_type.drop_file => {
            if (event.drop.data) |ptr| {
                const len = std.mem.len(ptr);
                const dup = try frame_input.frame_allocator.dupe(u8, ptr[0..len]);
                frame_input.dropped_path_opt = dup;
            }
        },
        sdl.event_type.mouse_button_down => {
            if (event.button.button == sdl.mouse.left) {
                frame_input.mouse_left_clicked = true;
            }
        },
        sdl.event_type.mouse_wheel => {
            const is_flipped = (event.wheel.direction == sdl.mouse.wheel_flipped);
            if (is_flipped) {
                // Flipped / Natural scrolling (Touchpads with Natural Scroll):
                // Swiping UP moves content UP; swiping LEFT moves content LEFT.
                frame_input.scroll_delta_x += event.wheel.x * MOUSE_WHEEL_SCROLL_MULTIPLIER;
                frame_input.scroll_delta_y -= event.wheel.y * MOUSE_WHEEL_SCROLL_MULTIPLIER;
            } else {
                // Normal / Traditional scrolling (Physical Mouse Wheels):
                // Rolling DOWN scrolls view DOWN; tilting RIGHT scrolls view RIGHT.
                frame_input.scroll_delta_x -= event.wheel.x * MOUSE_WHEEL_SCROLL_MULTIPLIER;
                frame_input.scroll_delta_y += event.wheel.y * MOUSE_WHEEL_SCROLL_MULTIPLIER;
            }
        },
        sdl.event_type.finger_down => {
            const tracker = &frame_input.touch_tracker;
            if (tracker.count < 8) {
                var found = false;
                const fid = event.tfinger.fingerID;
                for (0..tracker.count) |i| {
                    if (tracker.active_fingers[i].finger_id == fid) {
                        tracker.active_fingers[i].x = event.tfinger.x;
                        tracker.active_fingers[i].y = event.tfinger.y;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    tracker.active_fingers[tracker.count] = .{
                        .finger_id = fid,
                        .x = event.tfinger.x,
                        .y = event.tfinger.y,
                    };
                    tracker.count += 1;
                    tracker.last_dist = 0.0;
                }
            }
        },
        sdl.event_type.finger_up => {
            const tracker = &frame_input.touch_tracker;
            const fid = event.tfinger.fingerID;
            var i: usize = 0;
            while (i < tracker.count) {
                if (tracker.active_fingers[i].finger_id == fid) {
                    tracker.active_fingers[i] =
                        tracker.active_fingers[tracker.count - 1];
                    tracker.count -= 1;
                    break;
                }
                i += 1;
            }
            if (tracker.count < 2) {
                tracker.last_dist = 0.0;
            }
        },
        sdl.event_type.finger_motion => {
            const tracker = &frame_input.touch_tracker;
            const fid = event.tfinger.fingerID;
            for (0..tracker.count) |i| {
                if (tracker.active_fingers[i].finger_id == fid) {
                    tracker.active_fingers[i].x = event.tfinger.x;
                    tracker.active_fingers[i].y = event.tfinger.y;
                    break;
                }
            }
            if (tracker.count >= 2) {
                const win_w = frame_input.win_w;
                const win_h = frame_input.win_h;
                const f0 = tracker.active_fingers[0];
                const f1 = tracker.active_fingers[1];
                const dx = (f1.x - f0.x) * win_w;
                const dy = (f1.y - f0.y) * win_h;
                const dist = @sqrt(dx * dx + dy * dy);
                if (tracker.last_dist > 0.0 and dist > 0.0) {
                    const delta = (dist - tracker.last_dist) /
                        tracker.last_dist;
                    frame_input.pinch_delta += delta;
                    const mid_x = (f0.x + f1.x) * 0.5;
                    const mid_y = (f0.y + f1.y) * 0.5;
                    frame_input.pinch_center_x = mid_x * win_w;
                    frame_input.pinch_center_y = mid_y * win_h;
                }
                tracker.last_dist = dist;
            }
        },
        sdl.event_type.pinch_begin => {
            var mx: f32 = 0;
            var my: f32 = 0;
            _ = sdl.mouse.getState(&mx, &my);
            frame_input.pinch_center_x = mx;
            frame_input.pinch_center_y = my;
        },
        sdl.event_type.pinch_update => {
            if (event.pinch.scale > 0.0) {
                frame_input.pinch_delta += (event.pinch.scale - 1.0);
            }
            var mx: f32 = 0;
            var my: f32 = 0;
            _ = sdl.mouse.getState(&mx, &my);
            frame_input.pinch_center_x = mx;
            frame_input.pinch_center_y = my;
        },
        else => {},
    }
}

/// Computes delta time in milliseconds from ticks, clamping to a standard
/// frame slice (<= 33.33ms) to prevent animation and simulation leaps when
/// waking from blocking event wait (idle sleep) or OS stalls.
pub inline fn computeClampedDeltaTime(current_ticks: u64, last_time: *u64) f32 {
    const raw_delta = if (current_ticks >= last_time.*)
        @as(f32, @floatFromInt(current_ticks - last_time.*))
    else
        0.0;
    const delta_time_ms = @min(raw_delta, 33.333);
    last_time.* = current_ticks;
    return delta_time_ms;
}

/// Declarative mapping between SDL scancodes and directional bitflags.
pub const ScancodeDirection = struct {
    scancode: c_uint,
    direction: state.DirectionFlags,
};

pub const DIRECTION_SCANCODES = [_]ScancodeDirection{
    .{ .scancode = sdl.keys.scancode.up, .direction = .{ .up = true } },
    .{ .scancode = sdl.keys.scancode.k, .direction = .{ .up = true } },
    .{ .scancode = sdl.keys.scancode.down, .direction = .{ .down = true } },
    .{ .scancode = sdl.keys.scancode.j, .direction = .{ .down = true } },
    .{ .scancode = sdl.keys.scancode.left, .direction = .{ .left = true } },
    .{ .scancode = sdl.keys.scancode.h, .direction = .{ .left = true } },
    .{ .scancode = sdl.keys.scancode.right, .direction = .{ .right = true } },
    .{ .scancode = sdl.keys.scancode.l, .direction = .{ .right = true } },
};

pub fn sampleHeldDirections(
    kb_state: [*]const bool,
    num_keys: usize,
) state.DirectionFlags {
    var raw: u4 = 0;
    inline for (DIRECTION_SCANCODES) |entry| {
        const sc = @as(usize, @intCast(entry.scancode));
        if (sc < num_keys and kb_state[sc]) {
            raw |= entry.direction.raw();
        }
    }
    return .fromRaw(raw);
}

/// Declarative mapping between SDL scancodes and zoom direction flags.
pub const ScancodeZoom = struct {
    scancode: c_uint,
    direction: state.ZoomFlags,
};

pub const ZOOM_SCANCODES = [_]ScancodeZoom{
    .{ .scancode = sdl.keys.scancode.i, .direction = .{ .in = true } },
    .{ .scancode = sdl.keys.scancode.equals, .direction = .{ .in = true } },
    .{ .scancode = sdl.keys.scancode.kp_plus, .direction = .{ .in = true } },
    .{ .scancode = sdl.keys.scancode.o, .direction = .{ .out = true } },
    .{ .scancode = sdl.keys.scancode.minus, .direction = .{ .out = true } },
    .{ .scancode = sdl.keys.scancode.kp_minus, .direction = .{ .out = true } },
};

pub fn sampleHeldZoom(
    kb_state: [*]const bool,
    num_keys: usize,
) state.ZoomFlags {
    var raw: u2 = 0;
    inline for (ZOOM_SCANCODES) |entry| {
        const sc = @as(usize, @intCast(entry.scancode));
        if (sc < num_keys and kb_state[sc]) {
            raw |= entry.direction.raw();
        }
    }
    return .fromRaw(raw);
}

/// Strategy for pumping or waiting on the next SDL event at the start of a
/// frame.
pub const EventWaitStrategy = union(enum) {
    poll,
    wait_timeout_ms: i32,
    wait_indefinite,
};

/// Selects the SDL event wait strategy for the current frame.
pub fn selectEventWaitStrategy(
    non_blocking: bool,
    is_busy: bool,
    wait_timeout_ms: ?i32,
) EventWaitStrategy {
    if (non_blocking) return .poll;
    if (is_busy) return .{ .wait_timeout_ms = 8 };
    if (wait_timeout_ms) |timeout| {
        return .{ .wait_timeout_ms = @max(timeout, 1) };
    }
    return .wait_indefinite;
}

/// Pumps pending SDL events, queries cursor and keyboard states, and
/// constructs a new `FrameInput` snapshot.
pub fn pollFrameInput(
    window: sdl.Window,
    frame_allocator: std.mem.Allocator,
    last_time: *u64,
    prev_mouse_inside: bool,
    prev_touch_tracker: state.TouchTracker,
    wait_strategy: EventWaitStrategy,
) !FrameInput {
    // Get window sizes and scale
    const win_size = window.getSize();
    const pix_size = window.getSizeInPixels();

    const scale_x = if (win_size.w > 0)
        @as(f32, @floatFromInt(pix_size.w)) / @as(f32, @floatFromInt(win_size.w))
    else
        1.0;
    const scale_y = if (win_size.h > 0)
        @as(f32, @floatFromInt(pix_size.h)) / @as(f32, @floatFromInt(win_size.h))
    else
        1.0;

    var frame_input_state = FrameInputState{
        .touch_tracker = prev_touch_tracker,
        .frame_allocator = frame_allocator,
        .keys_pressed = .empty,
        .mouse_inside = prev_mouse_inside,
        .win_w = @as(f32, @floatFromInt(win_size.w)),
        .win_h = @as(f32, @floatFromInt(win_size.h)),
    };
    errdefer frame_input_state.keys_pressed.deinit(frame_allocator);

    const pre_wait_terminated = sdl.events.consumeTerminateSignal();
    if (pre_wait_terminated) {
        frame_input_state.quit_request = .terminate;
    }

    var event: sdl.Event = undefined;
    const wait_success = if (pre_wait_terminated)
        sdl.events.pollEvent(&event)
    else switch (wait_strategy) {
        .poll => sdl.events.pollEvent(&event),
        .wait_timeout_ms => |ms| sdl.events.waitEventTimeout(&event, ms),
        .wait_indefinite => sdl.events.waitEvent(&event),
    };

    if (!wait_success) {
        event.type = 0;
    }

    var has_event = wait_success;
    while (has_event) {
        try processSDLEvent(event, &frame_input_state);
        has_event = sdl.events.pollEvent(&event);
    }
    if (sdl.events.consumeTerminateSignal()) {
        frame_input_state.quit_request = .terminate;
    }

    var directional_held = state.DirectionFlags{};
    var zoom_held = state.ZoomFlags{};
    var num_keys: c_int = 0;
    if (sdl.keys.getKeyboardState(&num_keys)) |kb_state| {
        if (num_keys > 0) {
            const count = @as(usize, @intCast(num_keys));
            directional_held = sampleHeldDirections(kb_state, count);
            zoom_held = sampleHeldZoom(kb_state, count);
        }
    }

    const current_ticks = sdl.timer.getTicks();
    const delta_time_ms = computeClampedDeltaTime(current_ticks, last_time);

    var mouse_x_raw: f32 = 0;
    var mouse_y_raw: f32 = 0;
    const mouse_buttons = sdl.mouse.getState(&mouse_x_raw, &mouse_y_raw);
    const mouse_left_down = (mouse_buttons & sdl.mouse.mask(sdl.mouse.left)) != 0;

    return FrameInput{
        .win_w = @as(f32, @floatFromInt(win_size.w)),
        .win_h = @as(f32, @floatFromInt(win_size.h)),
        .scale_x = scale_x,
        .scale_y = scale_y,
        .mouse_x = mouse_x_raw,
        .mouse_y = mouse_y_raw,
        .mouse_left_down = mouse_left_down,
        .mouse_left_clicked = frame_input_state.mouse_left_clicked,
        .mouse_inside = frame_input_state.mouse_inside,
        .window_minimized = frame_input_state.window_minimized,
        .window_occluded = frame_input_state.window_occluded,
        .quit_request = frame_input_state.quit_request,
        .scroll_delta_x = frame_input_state.scroll_delta_x,
        .scroll_delta_y = frame_input_state.scroll_delta_y,
        .pinch_delta = frame_input_state.pinch_delta,
        .pinch_center_x = frame_input_state.pinch_center_x,
        .pinch_center_y = frame_input_state.pinch_center_y,
        .touch_tracker = frame_input_state.touch_tracker,
        .keys_pressed = frame_input_state.keys_pressed,
        .key_modifiers = mapModFromSdl(sdl.keys.getModState()),
        .directional_held = directional_held,
        .zoom_held = zoom_held,
        .text_input = frame_input_state.text_input_opt,
        .dropped_path = frame_input_state.dropped_path_opt,
        .delta_time_ms = delta_time_ms,
        .now_ms = current_ticks,
    };
}

test "computeClampedDeltaTime normal frame tick and idle wake clamp" {
    var last_time: u64 = 1000;

    // 1. Normal active frame tick (~8ms)
    const dt1 = computeClampedDeltaTime(1008, &last_time);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), dt1, 0.001);
    try std.testing.expectEqual(@as(u64, 1008), last_time);

    // 2. Normal 60fps frame tick (~16.6ms)
    const dt2 = computeClampedDeltaTime(1024, &last_time);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), dt2, 0.001);
    try std.testing.expectEqual(@as(u64, 1024), last_time);

    // 3. Waking from idle waitEvent after 5 seconds of sleep (5000ms)
    // Must be clamped to <= 33.333ms, and last_time updated to wake tick
    const dt3 = computeClampedDeltaTime(6024, &last_time);
    try std.testing.expectApproxEqAbs(@as(f32, 33.333), dt3, 0.001);
    try std.testing.expectEqual(@as(u64, 6024), last_time);

    // 4. Very next frame after wake is 8ms later
    const dt4 = computeClampedDeltaTime(6032, &last_time);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), dt4, 0.001);
    try std.testing.expectEqual(@as(u64, 6032), last_time);

    // 5. Clock rollback guard
    const dt5 = computeClampedDeltaTime(6000, &last_time);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dt5, 0.001);
    try std.testing.expectEqual(@as(u64, 6000), last_time);
}

test "processSDLEvent mouse_wheel normal and flipped directional axes" {
    const allocator = std.testing.allocator;
    var fis = FrameInputState{
        .frame_allocator = allocator,
        .keys_pressed = .empty,
    };
    defer fis.keys_pressed.deinit(allocator);

    // 1. Normal/traditional mouse wheel:
    // Rolling wheel DOWN (y = -1.0) -> scroll_delta_y negative (moves view down)
    // Tilting wheel RIGHT (x = 1.0) -> scroll_delta_x negative (moves view right)
    var evt_normal = std.mem.zeroes(sdl.Event);
    evt_normal.type = sdl.event_type.mouse_wheel;
    evt_normal.wheel.x = 1.0;
    evt_normal.wheel.y = -1.0;
    evt_normal.wheel.direction = 0;
    try processSDLEvent(evt_normal, &fis);

    try std.testing.expectApproxEqAbs(
        -MOUSE_WHEEL_SCROLL_MULTIPLIER,
        fis.scroll_delta_x,
        0.001,
    );
    try std.testing.expectApproxEqAbs(
        -MOUSE_WHEEL_SCROLL_MULTIPLIER,
        fis.scroll_delta_y,
        0.001,
    );

    // 2. Flipped/natural trackpad scroll:
    // Swiping UP (y = -1.0 in SDL flipped) -> scroll_delta_y positive (moves content up)
    // Swiping LEFT (x = 1.0 in SDL flipped) -> scroll_delta_x positive (moves content left)
    fis.scroll_delta_x = 0.0;
    fis.scroll_delta_y = 0.0;

    var evt_flipped = std.mem.zeroes(sdl.Event);
    evt_flipped.type = sdl.event_type.mouse_wheel;
    evt_flipped.wheel.x = 1.0;
    evt_flipped.wheel.y = -1.0;
    evt_flipped.wheel.direction = sdl.mouse.wheel_flipped;
    try processSDLEvent(evt_flipped, &fis);

    try std.testing.expectApproxEqAbs(
        MOUSE_WHEEL_SCROLL_MULTIPLIER,
        fis.scroll_delta_x,
        0.001,
    );
    try std.testing.expectApproxEqAbs(
        MOUSE_WHEEL_SCROLL_MULTIPLIER,
        fis.scroll_delta_y,
        0.001,
    );
}

test "mapKeyFromSdl maps backslash key" {
    try std.testing.expectEqual(Key.backslash, mapKeyFromSdl(sdl.keys.backslash));
}

test "sampleHeldDirections extracts arrow and vim directional flags" {
    var mock_state: [512]bool = @splat(false);

    // Initially neutral
    const neutral = sampleHeldDirections(&mock_state, mock_state.len);
    try std.testing.expect(!neutral.hasAny());

    // Up and Left held via arrow keys
    mock_state[sdl.keys.scancode.up] = true;
    mock_state[sdl.keys.scancode.left] = true;
    const up_left = sampleHeldDirections(&mock_state, mock_state.len);
    try std.testing.expect(up_left.up);
    try std.testing.expect(up_left.left);
    try std.testing.expect(!up_left.down);
    try std.testing.expect(!up_left.right);

    // Down and Right held via Vim keys (j + l)
    mock_state[sdl.keys.scancode.up] = false;
    mock_state[sdl.keys.scancode.left] = false;
    mock_state[sdl.keys.scancode.j] = true;
    mock_state[sdl.keys.scancode.l] = true;
    const down_right = sampleHeldDirections(&mock_state, mock_state.len);
    try std.testing.expect(down_right.down);
    try std.testing.expect(down_right.right);
    try std.testing.expect(!down_right.up);
    try std.testing.expect(!down_right.left);
}

test "sampleHeldZoom extracts zoom in and out flags" {
    var mock_state: [512]bool = @splat(false);

    // Initially neutral
    const neutral = sampleHeldZoom(&mock_state, mock_state.len);
    try std.testing.expect(!neutral.hasAny());

    // Zoom in via 'i' key
    mock_state[sdl.keys.scancode.i] = true;
    const zoom_in = sampleHeldZoom(&mock_state, mock_state.len);
    try std.testing.expect(zoom_in.in);
    try std.testing.expect(!zoom_in.out);

    // Zoom out via '-' key
    mock_state[sdl.keys.scancode.i] = false;
    mock_state[sdl.keys.scancode.minus] = true;
    const zoom_out = sampleHeldZoom(&mock_state, mock_state.len);
    try std.testing.expect(!zoom_out.in);
    try std.testing.expect(zoom_out.out);

    // Both held simultaneously
    mock_state[sdl.keys.scancode.equals] = true;
    const both = sampleHeldZoom(&mock_state, mock_state.len);
    try std.testing.expect(both.in);
    try std.testing.expect(both.out);
}

test "selectEventWaitStrategy sleeps indefinitely when idle" {
    try std.testing.expectEqual(
        EventWaitStrategy.poll,
        selectEventWaitStrategy(true, false, null),
    );
    try std.testing.expectEqual(
        EventWaitStrategy{ .wait_timeout_ms = 8 },
        selectEventWaitStrategy(false, true, 500),
    );
    try std.testing.expectEqual(
        EventWaitStrategy{ .wait_timeout_ms = 250 },
        selectEventWaitStrategy(false, false, 250),
    );
    try std.testing.expectEqual(
        EventWaitStrategy{ .wait_timeout_ms = 1 },
        selectEventWaitStrategy(false, false, 0),
    );
    try std.testing.expectEqual(
        EventWaitStrategy.wait_indefinite,
        selectEventWaitStrategy(false, false, null),
    );
}

test "processSDLEvent concatenates multiple text_input events per frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fis = FrameInputState{
        .frame_allocator = arena.allocator(),
        .keys_pressed = .empty,
    };

    var evt1 = std.mem.zeroes(sdl.Event);
    evt1.type = sdl.event_type.text_input;
    evt1.text.text = "ab";
    try processSDLEvent(evt1, &fis);

    var evt2 = std.mem.zeroes(sdl.Event);
    evt2.type = sdl.event_type.text_input;
    evt2.text.text = "cd";
    try processSDLEvent(evt2, &fis);

    try std.testing.expectEqualStrings("abcd", fis.text_input_opt.?);
}

test "processSDLEvent tracks window minimize and occlusion transitions" {
    const allocator = std.testing.allocator;
    var fis = FrameInputState{
        .frame_allocator = allocator,
        .keys_pressed = .empty,
    };
    defer fis.keys_pressed.deinit(allocator);

    try std.testing.expectEqual(@as(?bool, null), fis.window_minimized);
    try std.testing.expectEqual(@as(?bool, null), fis.window_occluded);

    try processSDLEvent(.{ .type = sdl.event_type.window_minimized }, &fis);
    try std.testing.expectEqual(@as(?bool, true), fis.window_minimized);

    try processSDLEvent(.{ .type = sdl.event_type.window_occluded }, &fis);
    try std.testing.expectEqual(@as(?bool, true), fis.window_occluded);

    // window_restored clears minimized without clearing occluded
    try processSDLEvent(.{ .type = sdl.event_type.window_restored }, &fis);
    try std.testing.expectEqual(@as(?bool, false), fis.window_minimized);
    try std.testing.expectEqual(@as(?bool, true), fis.window_occluded);

    try processSDLEvent(.{ .type = sdl.event_type.window_exposed }, &fis);
    try std.testing.expectEqual(@as(?bool, false), fis.window_occluded);
    try std.testing.expectEqual(@as(?bool, false), fis.window_minimized);
}

test "processSDLEvent pinch-to-zoom touch gesture lifecycle and hermeticity" {
    const allocator = std.testing.allocator;
    var fis = FrameInputState{
        .frame_allocator = allocator,
        .keys_pressed = .empty,
        .win_w = 800.0,
        .win_h = 600.0,
    };
    defer fis.keys_pressed.deinit(allocator);

    // 1. Finger 1 down at (0.2, 0.5)
    var evt1 = std.mem.zeroes(sdl.Event);
    evt1.type = sdl.event_type.finger_down;
    evt1.tfinger.fingerID = 101;
    evt1.tfinger.x = 0.2;
    evt1.tfinger.y = 0.5;
    try processSDLEvent(evt1, &fis);

    try std.testing.expectEqual(@as(u4, 1), fis.touch_tracker.count);
    try std.testing.expectEqual(
        @as(u64, 101),
        fis.touch_tracker.active_fingers[0].finger_id,
    );
    try std.testing.expectEqual(@as(f32, 0.0), fis.pinch_delta);

    // 2. Finger 2 down at (0.6, 0.5)
    var evt2 = std.mem.zeroes(sdl.Event);
    evt2.type = sdl.event_type.finger_down;
    evt2.tfinger.fingerID = 102;
    evt2.tfinger.x = 0.6;
    evt2.tfinger.y = 0.5;
    try processSDLEvent(evt2, &fis);

    try std.testing.expectEqual(@as(u4, 2), fis.touch_tracker.count);
    try std.testing.expectEqual(@as(f32, 0.0), fis.touch_tracker.last_dist);

    // 3. First finger_motion: establishes baseline last_dist = 320px
    var evt_m1 = std.mem.zeroes(sdl.Event);
    evt_m1.type = sdl.event_type.finger_motion;
    evt_m1.tfinger.fingerID = 102;
    evt_m1.tfinger.x = 0.6;
    evt_m1.tfinger.y = 0.5;
    try processSDLEvent(evt_m1, &fis);

    try std.testing.expectApproxEqAbs(
        @as(f32, 320.0),
        fis.touch_tracker.last_dist,
        0.001,
    );
    try std.testing.expectEqual(@as(f32, 0.0), fis.pinch_delta);

    // 4. Second finger_motion: finger 2 moves to (0.8, 0.5) -> dist = 480px
    // delta = (480 - 320) / 320 = 0.5 (zoom in)
    var evt_m2 = std.mem.zeroes(sdl.Event);
    evt_m2.type = sdl.event_type.finger_motion;
    evt_m2.tfinger.fingerID = 102;
    evt_m2.tfinger.x = 0.8;
    evt_m2.tfinger.y = 0.5;
    try processSDLEvent(evt_m2, &fis);

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fis.pinch_delta, 0.001);
    try std.testing.expectApproxEqAbs(
        @as(f32, 480.0),
        fis.touch_tracker.last_dist,
        0.001,
    );
    // Center should be mid-point ((0.2 + 0.8)/2 * 800 = 400, 0.5 * 600 = 300)
    try std.testing.expectApproxEqAbs(
        @as(f32, 400.0),
        fis.pinch_center_x,
        0.001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 300.0),
        fis.pinch_center_y,
        0.001,
    );

    // 5. Finger 1 up: drops count to 1, resets last_dist to 0
    var evt_u1 = std.mem.zeroes(sdl.Event);
    evt_u1.type = sdl.event_type.finger_up;
    evt_u1.tfinger.fingerID = 101;
    try processSDLEvent(evt_u1, &fis);

    try std.testing.expectEqual(@as(u4, 1), fis.touch_tracker.count);
    try std.testing.expectEqual(@as(f32, 0.0), fis.touch_tracker.last_dist);
    try std.testing.expectEqual(
        @as(u64, 102),
        fis.touch_tracker.active_fingers[0].finger_id,
    );

    // 6. Conversion via toFrameInput preserves touch_tracker by value
    const frame_input = fis.toFrameInput();
    try std.testing.expectEqual(@as(u4, 1), frame_input.touch_tracker.count);
    try std.testing.expectEqual(
        @as(f32, 0.0),
        frame_input.touch_tracker.last_dist,
    );
    try std.testing.expectEqual(
        @as(u64, 102),
        frame_input.touch_tracker.active_fingers[0].finger_id,
    );
}
