const intents = @import("intents");
const state = @import("state");
const std = @import("std");

const AppIntent = intents.AppIntent;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;
const flat_shortcuts = intents.actions.flat_shortcuts;

pub const KeyContext = enum {
    global,
    viewer_normal,
    viewer_zoomed,
    palette,
};

pub const PanDelta = struct {
    dx: f32,
    dy: f32,

    pub inline fn isZero(self: PanDelta) bool {
        return self.dx == 0.0 and self.dy == 0.0;
    }
};

pub const ZoomDelta = struct {
    ratio: f32,

    pub inline fn isIdentity(self: ZoomDelta) bool {
        return self.ratio == 1.0;
    }
};

pub const UnitVec2 = struct {
    x: f32,
    y: f32,
};

pub const DirectionMapping = struct {
    key: Key,
    direction: state.DirectionFlags,
};

pub const DIRECTION_KEY_MAP = [_]DirectionMapping{
    .{ .key = .up, .direction = .{ .up = true } },
    .{ .key = .char_k, .direction = .{ .up = true } },
    .{ .key = .down, .direction = .{ .down = true } },
    .{ .key = .char_j, .direction = .{ .down = true } },
    .{ .key = .left, .direction = .{ .left = true } },
    .{ .key = .char_h, .direction = .{ .left = true } },
    .{ .key = .right, .direction = .{ .right = true } },
    .{ .key = .char_l, .direction = .{ .right = true } },
};

/// 16-entry precomputed lookup table of normalized unit direction vectors.
/// Diagonals are pre-normalized by 1 / sqrt(2) to guarantee uniform
/// linear travel speed.
pub const DIRECTION_UNIT_LUT: [16]UnitVec2 = blk: {
    var lut: [16]UnitVec2 = undefined;
    const inv_sqrt2: f32 = 0.70710678;
    for (0..16) |i| {
        const flags = state.DirectionFlags.fromRaw(@intCast(i));
        var x: f32 = 0.0;
        var y: f32 = 0.0;
        if (flags.left) x += 1.0;
        if (flags.right) x -= 1.0;
        if (flags.up) y += 1.0;
        if (flags.down) y -= 1.0;
        if (x != 0.0 and y != 0.0) {
            x *= inv_sqrt2;
            y *= inv_sqrt2;
        }
        lut[i] = .{ .x = x, .y = y };
    }
    break :blk lut;
};

comptime {
    // Statically verify mappings and opposing cancellations
    for (DIRECTION_KEY_MAP) |entry| {
        std.debug.assert(@popCount(entry.direction.raw()) == 1);
    }
    const up_down = (state.DirectionFlags{ .up = true, .down = true }).raw();
    std.debug.assert(DIRECTION_UNIT_LUT[up_down].y == 0.0);

    const left_right = (state.DirectionFlags{
        .left = true,
        .right = true,
    }).raw();
    std.debug.assert(DIRECTION_UNIT_LUT[left_right].x == 0.0);

    const up_left = (state.DirectionFlags{ .up = true, .left = true }).raw();
    const inv_sqrt2: f32 = 0.70710678;
    std.debug.assert(DIRECTION_UNIT_LUT[up_left].x == inv_sqrt2);
    std.debug.assert(DIRECTION_UNIT_LUT[up_left].y == inv_sqrt2);

    const down_right = (state.DirectionFlags{
        .down = true,
        .right = true,
    }).raw();
    std.debug.assert(DIRECTION_UNIT_LUT[down_right].x == -inv_sqrt2);
    std.debug.assert(DIRECTION_UNIT_LUT[down_right].y == -inv_sqrt2);
}

pub inline fn getDirectionForMappedKey(key: Key) ?state.DirectionFlags {
    inline for (DIRECTION_KEY_MAP) |entry| {
        if (entry.key == key) return entry.direction;
    }
    return null;
}

pub inline fn isDirectionalKey(key: Key) bool {
    return getDirectionForMappedKey(key) != null;
}

/// Resolves directional panning from physical key state and frame delta time.
/// Provides consistent, smooth movement at GLIDE_SPEED for both taps and holds,
/// eliminating discrete jumps and typematic repeat stalls.
pub fn updateDirectionalPan(
    ctrl: *state.PanController,
    current_held: state.DirectionFlags,
    keys_pressed: []const Key,
    dt_ms: f32,
) ?PanDelta {
    // Numerical guard and delta clamping
    if (std.math.isNan(dt_ms) or dt_ms <= 0.0) return null;
    const dt_sec = @min(dt_ms, 50.0) / 1000.0;

    // 1. Update suppressed mask and detect newly pressed keys this frame
    var pressed_mask: u4 = 0;
    for (keys_pressed) |key| {
        if (getDirectionForMappedKey(key)) |dir| {
            pressed_mask |= dir.raw();
        }
    }
    ctrl.suppressed_held = state.DirectionFlags.fromRaw(
        (ctrl.suppressed_held.raw() & current_held.raw()) & ~pressed_mask,
    );
    const effective_held = state.DirectionFlags.fromRaw(
        current_held.raw() & ~ctrl.suppressed_held.raw(),
    );

    const newly_pressed_raw: u4 =
        (effective_held.raw() & ~ctrl.prev_held.raw()) | pressed_mask;
    const newly_pressed = state.DirectionFlags.fromRaw(newly_pressed_raw);

    // 2. If a new direction was pressed from rest, initiate smooth tap travel
    if (newly_pressed.hasAny() and !ctrl.prev_held.hasAny()) {
        ctrl.smooth_tap_remaining = state.PanController.TAP_DISTANCE;
        ctrl.tap_direction = newly_pressed;
    }

    // 3. Determine active directions: physically held keys take precedence;
    // if keys were released but smooth tap travel remains, use tap_direction.
    var active_flags = effective_held;
    if (!active_flags.hasAny()) {
        if (ctrl.smooth_tap_remaining > 0.001) {
            active_flags = ctrl.tap_direction;
        } else {
            ctrl.clearMotion();
            return null;
        }
    }

    // 4. Branchless unit vector lookup & cancellation check
    const dir = DIRECTION_UNIT_LUT[active_flags.raw()];
    if (dir.x == 0.0 and dir.y == 0.0) {
        ctrl.clearMotion();
        return null;
    }

    // 5. Calculate continuous displacement at constant GLIDE_SPEED
    var step_dist = state.PanController.GLIDE_SPEED * dt_sec;

    // If completing a smooth tap after key release, clamp step to remaining
    if (!effective_held.hasAny()) {
        step_dist = @min(step_dist, ctrl.smooth_tap_remaining);
    }
    ctrl.smooth_tap_remaining = @max(
        0.0,
        ctrl.smooth_tap_remaining - step_dist,
    );

    ctrl.prev_held = effective_held;

    const dx = dir.x * step_dist;
    const dy = dir.y * step_dist;
    if (dx == 0.0 and dy == 0.0) return null;

    return PanDelta{ .dx = dx, .dy = dy };
}

pub inline fn isZoomKey(key: Key) bool {
    return switch (key) {
        .char_i, .char_o, .equals, .minus => true,
        else => false,
    };
}

pub inline fn getZoomDirectionForMappedKey(key: Key) ?state.ZoomDirection {
    return switch (key) {
        .char_i, .equals => .in,
        .char_o, .minus => .out,
        else => null,
    };
}

/// Resolves smooth viewport zooming from physical key state and delta time.
/// Operates in log space (ln Z) to provide uniform perceptual magnification
/// velocity for both smooth taps and continuous holds, eliminating discrete
/// jumps and typematic repeat stalls.
pub fn updateZoomMotion(
    ctrl: *state.ZoomController,
    current_held: state.ZoomFlags,
    keys_pressed: []const Key,
    current_zoom: f32,
    dt_ms: f32,
) ?ZoomDelta {
    // Numerical guard and delta clamping
    if (std.math.isNan(dt_ms) or dt_ms <= 0.0) return null;
    const dt_sec = @min(dt_ms, 50.0) / 1000.0;

    var pressed_mask: u2 = 0;
    for (keys_pressed) |key| {
        if (getZoomDirectionForMappedKey(key)) |dir| {
            switch (dir) {
                .in => pressed_mask |= (state.ZoomFlags{ .in = true }).raw(),
                .out => pressed_mask |= (state.ZoomFlags{ .out = true }).raw(),
                .none => {},
            }
        }
    }
    ctrl.suppressed_held = state.ZoomFlags.fromRaw(
        (ctrl.suppressed_held.raw() & current_held.raw()) & ~pressed_mask,
    );
    const effective_held = state.ZoomFlags.fromRaw(
        current_held.raw() & ~ctrl.suppressed_held.raw(),
    );

    // 1. If currently paused at the 1.0x detent during a continuous hold,
    // countdown detent timer and hold zoom constant until it expires.
    if (ctrl.detent_pause_ms > 0.0) {
        ctrl.detent_pause_ms = @max(0.0, ctrl.detent_pause_ms - dt_ms);
        ctrl.prev_held = effective_held;
        if (effective_held.hasAny()) {
            return null;
        } else {
            ctrl.clearMotion();
            return null;
        }
    }

    // 2. Detect newly pressed keys from rest
    const pressed_flags = state.ZoomFlags.fromRaw(pressed_mask);
    var newly_pressed_in = effective_held.in and !ctrl.prev_held.in;
    var newly_pressed_out = effective_held.out and !ctrl.prev_held.out;
    if (!ctrl.prev_held.hasAny()) {
        if (pressed_flags.in) newly_pressed_in = true;
        if (pressed_flags.out) newly_pressed_out = true;
    }

    if (!ctrl.prev_held.hasAny()) {
        if (newly_pressed_in and !newly_pressed_out) {
            ctrl.triggerTap(.in, current_zoom);
        } else if (newly_pressed_out and !newly_pressed_in) {
            ctrl.triggerTap(.out, current_zoom);
        }
    }

    // 3. Opposing keys cancel out
    if (effective_held.in and effective_held.out) {
        ctrl.clearMotion();
        return null;
    }

    // 4. Determine active direction: physically held keys take precedence;
    // if keys released but smooth tap travel remains, use tap_direction.
    var active_dir: state.ZoomDirection = .none;
    if (effective_held.in) {
        active_dir = .in;
    } else if (effective_held.out) {
        active_dir = .out;
    } else if (ctrl.smooth_tap_remaining > 0.0001) {
        active_dir = ctrl.tap_direction;
    } else {
        ctrl.clearMotion();
        return null;
    }

    if (active_dir == .none) {
        ctrl.clearMotion();
        return null;
    }

    // 5. Calculate log-space displacement at constant GLIDE_RATE
    var step_log = state.ZoomController.GLIDE_RATE * dt_sec;

    // If completing a smooth tap after key release, clamp step to remaining
    if (!effective_held.hasAny()) {
        step_log = @min(step_log, ctrl.smooth_tap_remaining);
    }
    ctrl.smooth_tap_remaining = @max(
        0.0,
        ctrl.smooth_tap_remaining - step_log,
    );

    ctrl.prev_held = effective_held;

    if (step_log <= 0.0) return null;

    // 6. Calculate scale ratio this frame
    const sign: f32 = if (active_dir == .in) 1.0 else -1.0;
    var ratio = @exp(sign * step_log);
    var next_zoom = current_zoom * ratio;

    // 7. Check 1.0x detent crossing
    var hit_detent = false;
    if (ctrl.detent_target) |dt| {
        if (active_dir == .in and next_zoom >= dt) {
            next_zoom = dt;
            ratio = next_zoom / current_zoom;
            ctrl.smooth_tap_remaining = 0.0;
            ctrl.detent_target = null;
            hit_detent = true;
        } else if (active_dir == .out and next_zoom <= dt) {
            next_zoom = dt;
            ratio = next_zoom / current_zoom;
            ctrl.smooth_tap_remaining = 0.0;
            ctrl.detent_target = null;
            hit_detent = true;
        }
    } else {
        if (active_dir == .in and
            current_zoom < 1.0 and
            next_zoom >= 1.0)
        {
            next_zoom = 1.0;
            ratio = next_zoom / current_zoom;
            hit_detent = true;
        } else if (active_dir == .out and
            current_zoom > 1.0 and
            next_zoom <= 1.0)
        {
            next_zoom = 1.0;
            ratio = next_zoom / current_zoom;
            hit_detent = true;
        }
    }

    if (hit_detent and current_held.hasAny()) {
        ctrl.detent_pause_ms = state.ZoomController.DETENT_PAUSE_MS;
    }

    // 8. Clamping bounds
    const clamped_zoom = state.clampZoomFactor(next_zoom).get();
    if (clamped_zoom == current_zoom) {
        ctrl.reset();
        return null;
    }
    ratio = clamped_zoom / current_zoom;

    return ZoomDelta{ .ratio = ratio };
}

/// Performs data-driven key lookup returning a pure AppIntent variant or null.
pub fn mapKeyToAction(
    key: Key,
    mod: KeyModifiers,
    ctx: KeyContext,
) ?intents.AppIntent {
    // 1. Context-Sensitive Arrow Keys and Vim Keys when Viewport is Zoomed
    //    (Panning)
    if (ctx == .viewer_zoomed) {
        if (!mod.ctrl and !mod.shift and !mod.alt and !mod.gui) {
            if (getDirectionForMappedKey(key)) |dir| {
                const vec = DIRECTION_UNIT_LUT[dir.raw()];
                return .{ .pan_by = .{
                    .dx = vec.x * state.PanController.TAP_DISTANCE,
                    .dy = vec.y * state.PanController.TAP_DISTANCE,
                } };
            }
        }
    }

    // 2. Fine Zooming (Keyboard-specific step adjustments)
    if (!mod.ctrl and !mod.shift and !mod.alt and !mod.gui) {
        switch (key) {
            .equals, .char_i => return .zoom_in,
            .minus, .char_o => return .zoom_out,
            else => {},
        }
    }

    // 3. Command Palette Single Source of Truth Lookup (flat_shortcuts)
    for (flat_shortcuts) |shortcut| {
        if (key == shortcut.key and
            mod.ctrl == shortcut.mod.ctrl and
            mod.shift == shortcut.mod.shift and
            mod.alt == shortcut.mod.alt and
            mod.gui == shortcut.mod.gui)
        {
            return shortcut.intent;
        }
    }

    return null;
}

test "mapKeyToAction aligned with palette action items" {
    // Check next_image via Right Arrow, Space, 'n', and ']'
    const nav_right = mapKeyToAction(.right, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.next_image, nav_right.?);
    const nav_space = mapKeyToAction(.space, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.next_image, nav_space.?);
    const nav_n = mapKeyToAction(.char_n, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.next_image, nav_n.?);
    const nav_rbracket = mapKeyToAction(.right_bracket, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.next_image, nav_rbracket.?);

    // Check prev_image via Left Arrow, Backspace, 'p', and '['
    const nav_left = mapKeyToAction(.left, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.prev_image, nav_left.?);
    const nav_backspace = mapKeyToAction(.backspace, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.prev_image, nav_backspace.?);
    const nav_p = mapKeyToAction(.char_p, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.prev_image, nav_p.?);
    const nav_lbracket = mapKeyToAction(.left_bracket, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.prev_image, nav_lbracket.?);

    // Check reset_zoom via R key
    const reset_zoom = mapKeyToAction(.char_r, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.reset_zoom, reset_zoom.?);

    // Check reset_adjustments via Shift+R key
    const reset_adj = mapKeyToAction(
        .char_r,
        .{ .shift = true },
        .viewer_normal,
    );
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .reset_all },
        reset_adj.?,
    );

    // Check toggle_compare via Backslash key
    const toggle_cmp = mapKeyToAction(.backslash, .{}, .viewer_normal);
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .toggle_compare },
        toggle_cmp.?,
    );

    const edit_panel = mapKeyToAction(.char_e, .{}, .viewer_normal);
    try std.testing.expectEqual(
        intents.AppIntent.toggle_edit_panel,
        edit_panel.?,
    );

    // Check rotate_cw via > (Shift+.)
    const rot_cw = mapKeyToAction(.period, .{ .shift = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.rotate_cw, rot_cw.?);

    // Check rotate_ccw via < (Shift+,)
    const rot_ccw = mapKeyToAction(.comma, .{ .shift = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.rotate_ccw, rot_ccw.?);

    // Check brightness adjustments via B / Shift+B
    const bright_up = mapKeyToAction(.char_b, .{}, .viewer_normal);
    try std.testing.expectEqual(
        intents.AppIntent{
            .adjust = .{
                .step = .{ .param = .brightness, .direction = .up },
            },
        },
        bright_up.?,
    );
    const bright_down = mapKeyToAction(
        .char_b,
        .{ .shift = true },
        .viewer_normal,
    );
    try std.testing.expectEqual(
        intents.AppIntent{
            .adjust = .{
                .step = .{ .param = .brightness, .direction = .down },
            },
        },
        bright_down.?,
    );

    // Check contrast adjustments via C / Shift+C
    const contrast_up = mapKeyToAction(.char_c, .{}, .viewer_normal);
    try std.testing.expectEqual(
        intents.AppIntent{
            .adjust = .{
                .step = .{ .param = .contrast, .direction = .up },
            },
        },
        contrast_up.?,
    );
    const contrast_down = mapKeyToAction(
        .char_c,
        .{ .shift = true },
        .viewer_normal,
    );
    try std.testing.expectEqual(
        intents.AppIntent{
            .adjust = .{
                .step = .{ .param = .contrast, .direction = .down },
            },
        },
        contrast_down.?,
    );

    // Check zoom via I / O
    const zoom_in = mapKeyToAction(.char_i, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.zoom_in, zoom_in.?);
    const zoom_out = mapKeyToAction(.char_o, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.zoom_out, zoom_out.?);

    // Check actual size (1:1) via A
    const actual_size = mapKeyToAction(.char_a, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent{ .set_scale = .none }, actual_size.?);

    // Check cycle scale mode via S
    const cycle_scale = mapKeyToAction(.char_s, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.cycle_scale_mode, cycle_scale.?);

    // Check cycle filter via Shift+S
    const cycle_filter = mapKeyToAction(.char_s, .{ .shift = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.cycle_filter, cycle_filter.?);

    // Check cycle filter backward via Alt+Shift+S
    const cycle_filter_prev = mapKeyToAction(.char_s, .{ .shift = true, .alt = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.cycle_filter_prev, cycle_filter_prev.?);

    // Check refresh directory via F5 and Ctrl+R
    const refresh_f5 = mapKeyToAction(.f5, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.refresh_directory, refresh_f5.?);
    const refresh_ctrl_r = mapKeyToAction(.char_r, .{ .ctrl = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.refresh_directory, refresh_ctrl_r.?);

    // Check info toggle via D
    const toggle_info = mapKeyToAction(.char_d, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.toggle_info, toggle_info.?);

    // Check Vim-style panning when zoomed
    const pan_h = mapKeyToAction(.char_h, .{}, .viewer_zoomed);
    try std.testing.expectEqual(
        intents.AppIntent{ .pan_by = .{ .dx = 30.0, .dy = 0.0 } },
        pan_h.?,
    );
    const pan_j = mapKeyToAction(.char_j, .{}, .viewer_zoomed);
    try std.testing.expectEqual(
        intents.AppIntent{ .pan_by = .{ .dx = 0.0, .dy = -30.0 } },
        pan_j.?,
    );
    const pan_k = mapKeyToAction(.char_k, .{}, .viewer_zoomed);
    try std.testing.expectEqual(
        intents.AppIntent{ .pan_by = .{ .dx = 0.0, .dy = 30.0 } },
        pan_k.?,
    );
    const pan_l = mapKeyToAction(.char_l, .{}, .viewer_zoomed);
    try std.testing.expectEqual(
        intents.AppIntent{ .pan_by = .{ .dx = -30.0, .dy = 0.0 } },
        pan_l.?,
    );
}

test "DIRECTION_UNIT_LUT precomputed resolutions" {
    // 0: Neutral
    try std.testing.expectEqual(
        UnitVec2{ .x = 0.0, .y = 0.0 },
        DIRECTION_UNIT_LUT[0],
    );

    // Cardinal directions
    const up_flag = state.DirectionFlags{ .up = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = 0.0, .y = 1.0 },
        DIRECTION_UNIT_LUT[up_flag.raw()],
    );
    const down_flag = state.DirectionFlags{ .down = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = 0.0, .y = -1.0 },
        DIRECTION_UNIT_LUT[down_flag.raw()],
    );
    const left_flag = state.DirectionFlags{ .left = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = 1.0, .y = 0.0 },
        DIRECTION_UNIT_LUT[left_flag.raw()],
    );
    const right_flag = state.DirectionFlags{ .right = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = -1.0, .y = 0.0 },
        DIRECTION_UNIT_LUT[right_flag.raw()],
    );

    // Diagonal corner combinations
    const inv_sqrt2: f32 = 0.70710678;
    const up_left = state.DirectionFlags{ .up = true, .left = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = inv_sqrt2, .y = inv_sqrt2 },
        DIRECTION_UNIT_LUT[up_left.raw()],
    );
    const down_right = state.DirectionFlags{ .down = true, .right = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = -inv_sqrt2, .y = -inv_sqrt2 },
        DIRECTION_UNIT_LUT[down_right.raw()],
    );
    const up_right = state.DirectionFlags{ .up = true, .right = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = -inv_sqrt2, .y = inv_sqrt2 },
        DIRECTION_UNIT_LUT[up_right.raw()],
    );
    const down_left = state.DirectionFlags{ .down = true, .left = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = inv_sqrt2, .y = -inv_sqrt2 },
        DIRECTION_UNIT_LUT[down_left.raw()],
    );

    // Opposing cancellations
    const up_down = state.DirectionFlags{ .up = true, .down = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = 0.0, .y = 0.0 },
        DIRECTION_UNIT_LUT[up_down.raw()],
    );
    const left_right = state.DirectionFlags{ .left = true, .right = true };
    try std.testing.expectEqual(
        UnitVec2{ .x = 0.0, .y = 0.0 },
        DIRECTION_UNIT_LUT[left_right.raw()],
    );
    const all_four = state.DirectionFlags{
        .up = true,
        .down = true,
        .left = true,
        .right = true,
    };
    try std.testing.expectEqual(
        UnitVec2{ .x = 0.0, .y = 0.0 },
        DIRECTION_UNIT_LUT[all_four.raw()],
    );
}

test "updateDirectionalPan constant speed cardinal and diagonal motion" {
    var ctrl = state.PanController{};
    const empty_keys = [_]Key{};

    const inv_sqrt2: f32 = 0.70710678;
    const exp_cardinal = state.PanController.GLIDE_SPEED * (16.0 / 1000.0);
    const exp_diagonal = inv_sqrt2 * exp_cardinal;

    // 1. Up and Left (Diagonal)
    ctrl.reset();
    const res_ul = updateDirectionalPan(
        &ctrl,
        .{ .up = true, .left = true },
        &empty_keys,
        16.0,
    );
    try std.testing.expect(res_ul != null);
    try std.testing.expectApproxEqAbs(exp_diagonal, res_ul.?.dx, 0.01);
    try std.testing.expectApproxEqAbs(exp_diagonal, res_ul.?.dy, 0.01);

    // 2. Down and Right (Diagonal)
    ctrl.reset();
    const res_dr = updateDirectionalPan(
        &ctrl,
        .{ .down = true, .right = true },
        &empty_keys,
        16.0,
    );
    try std.testing.expect(res_dr != null);
    try std.testing.expectApproxEqAbs(-exp_diagonal, res_dr.?.dx, 0.01);
    try std.testing.expectApproxEqAbs(-exp_diagonal, res_dr.?.dy, 0.01);

    // 3. Up Cardinal
    ctrl.reset();
    const res_up = updateDirectionalPan(
        &ctrl,
        .{ .up = true },
        &empty_keys,
        16.0,
    );
    try std.testing.expect(res_up != null);
    try std.testing.expectEqual(@as(f32, 0.0), res_up.?.dx);
    try std.testing.expectApproxEqAbs(exp_cardinal, res_up.?.dy, 0.01);

    // 4. Opposing keys cancel out
    ctrl.reset();
    const res_opp = updateDirectionalPan(
        &ctrl,
        .{ .up = true, .down = true },
        &empty_keys,
        16.0,
    );
    try std.testing.expectEqual(@as(?PanDelta, null), res_opp);
}

test "updateDirectionalPan smooth tap completion after key release" {
    var ctrl = state.PanController{};
    const empty_keys = [_]Key{};

    const exp_cardinal = state.PanController.GLIDE_SPEED * (16.0 / 1000.0);

    // Frame 0: Key pressed for 1 frame
    const f0 = updateDirectionalPan(
        &ctrl,
        .{ .up = true },
        &empty_keys,
        16.0,
    );
    try std.testing.expect(f0 != null);
    try std.testing.expectApproxEqAbs(exp_cardinal, f0.?.dy, 0.01);
    try std.testing.expect(ctrl.isBusy());

    // Frame 1: Key released (current_held is empty), smooth tap continues
    const f1 = updateDirectionalPan(&ctrl, .{}, &empty_keys, 16.0);
    try std.testing.expect(f1 != null);
    try std.testing.expectApproxEqAbs(exp_cardinal, f1.?.dy, 0.01);
    try std.testing.expect(ctrl.isBusy());

    // Frame 2: Final frame of smooth tap completes remaining 4.4px
    const f2 = updateDirectionalPan(&ctrl, .{}, &empty_keys, 16.0);
    try std.testing.expect(f2 != null);
    const exp_rem = state.PanController.TAP_DISTANCE - (exp_cardinal * 2.0);
    try std.testing.expectApproxEqAbs(exp_rem, f2.?.dy, 0.01);
    try std.testing.expect(!ctrl.isBusy());

    // Frame 3: Tap finished, motion stops
    const f3 = updateDirectionalPan(&ctrl, .{}, &empty_keys, 16.0);
    try std.testing.expectEqual(@as(?PanDelta, null), f3);

    // Total distance is exactly TAP_DISTANCE
    const total = f0.?.dy + f1.?.dy + f2.?.dy;
    try std.testing.expectApproxEqAbs(
        state.PanController.TAP_DISTANCE,
        total,
        0.01,
    );
}

test "updateDirectionalPan continuous hold without pauses or jumps" {
    var ctrl = state.PanController{};
    const empty_keys = [_]Key{};
    const exp_cardinal = state.PanController.GLIDE_SPEED * (16.0 / 1000.0);

    // Every frame during hold moves at the exact same constant speed
    var frame: usize = 0;
    while (frame < 10) : (frame += 1) {
        const step = updateDirectionalPan(
            &ctrl,
            .{ .up = true },
            &empty_keys,
            16.0,
        );
        try std.testing.expect(step != null);
        try std.testing.expectApproxEqAbs(exp_cardinal, step.?.dy, 0.01);
        try std.testing.expectEqual(@as(f32, 0.0), step.?.dx);
    }
}

test "updateDirectionalPan seamless orthogonal transition without stutter" {
    var ctrl = state.PanController{};
    const empty_keys = [_]Key{};

    const inv_sqrt2: f32 = 0.70710678;
    const exp_cardinal = state.PanController.GLIDE_SPEED * (16.0 / 1000.0);
    const exp_diagonal = inv_sqrt2 * exp_cardinal;

    // 1. Moving Up
    const f_up = updateDirectionalPan(
        &ctrl,
        .{ .up = true },
        &empty_keys,
        16.0,
    );
    try std.testing.expect(f_up != null);
    try std.testing.expectApproxEqAbs(exp_cardinal, f_up.?.dy, 0.01);

    // 2. Press Left while holding Up: immediately produces diagonal motion
    const f_diag = updateDirectionalPan(
        &ctrl,
        .{ .up = true, .left = true },
        &empty_keys,
        16.0,
    );
    try std.testing.expect(f_diag != null);
    try std.testing.expectApproxEqAbs(exp_diagonal, f_diag.?.dx, 0.01);
    try std.testing.expectApproxEqAbs(exp_diagonal, f_diag.?.dy, 0.01);

    // 3. Release Up while holding Left: continues smoothly moving Left
    const f_left = updateDirectionalPan(
        &ctrl,
        .{ .left = true },
        &empty_keys,
        16.0,
    );
    try std.testing.expect(f_left != null);
    try std.testing.expectApproxEqAbs(exp_cardinal, f_left.?.dx, 0.01);
    try std.testing.expectEqual(@as(f32, 0.0), f_left.?.dy);

    // 4. Release all keys: stops immediately
    const f_stop = updateDirectionalPan(&ctrl, .{}, &empty_keys, 16.0);
    try std.testing.expectEqual(@as(?PanDelta, null), f_stop);
}

test "updateZoomMotion constant rate continuous hold" {
    var ctrl = state.ZoomController{};
    const empty_keys = [_]Key{};
    const dt_ms = 16.0;
    const exp_ratio = @exp(state.ZoomController.GLIDE_RATE * (dt_ms / 1000.0));

    var frame: usize = 0;
    var current_zoom: f32 = 2.0;
    while (frame < 5) : (frame += 1) {
        const step = updateZoomMotion(
            &ctrl,
            .{ .in = true },
            &empty_keys,
            current_zoom,
            dt_ms,
        );
        try std.testing.expect(step != null);
        try std.testing.expectApproxEqAbs(exp_ratio, step.?.ratio, 0.001);
        current_zoom *= step.?.ratio;
    }
}

test "updateZoomMotion smooth tap completion after key release" {
    var ctrl = state.ZoomController{};
    const empty_keys = [_]Key{};
    const dt_ms = 16.0;

    // Frame 0: Key pressed for 1 frame from 2.0x
    var current_zoom: f32 = 2.0;
    const start_zoom = current_zoom;
    const f0 = updateZoomMotion(
        &ctrl,
        .{ .in = true },
        &empty_keys,
        current_zoom,
        dt_ms,
    );
    try std.testing.expect(f0 != null);
    current_zoom *= f0.?.ratio;
    try std.testing.expect(ctrl.isBusy());

    // Subsequent frames: key released, tap motion completes
    while (ctrl.isBusy()) {
        const step = updateZoomMotion(
            &ctrl,
            .{},
            &empty_keys,
            current_zoom,
            dt_ms,
        );
        if (step) |s| {
            current_zoom *= s.ratio;
        }
    }

    // Total compound ratio equals TAP_STEP_RATIO (1.25x)
    const total_ratio = current_zoom / start_zoom;
    try std.testing.expectApproxEqAbs(
        state.ZoomController.TAP_STEP_RATIO,
        total_ratio,
        0.01,
    );

    // Frame after completion: stopped
    const f_end = updateZoomMotion(
        &ctrl,
        .{},
        &empty_keys,
        current_zoom,
        dt_ms,
    );
    try std.testing.expectEqual(@as(?ZoomDelta, null), f_end);
}

test "updateZoomMotion opposing keys cancel out" {
    var ctrl = state.ZoomController{};
    const empty_keys = [_]Key{};

    const res = updateZoomMotion(
        &ctrl,
        .{ .in = true, .out = true },
        &empty_keys,
        2.0,
        16.0,
    );
    try std.testing.expectEqual(@as(?ZoomDelta, null), res);
    try std.testing.expect(!ctrl.isBusy());
}

test "updateZoomMotion snap to 1.0 detent on tap" {
    var ctrl = state.ZoomController{};
    const empty_keys = [_]Key{};
    const dt_ms = 16.0;

    // 0.85 * 1.25 = 1.0625 >= 1.0 -> should snap to exactly 1.0
    var current_zoom: f32 = 0.85;
    const step0 = updateZoomMotion(
        &ctrl,
        .{ .in = true },
        &empty_keys,
        current_zoom,
        dt_ms,
    );
    if (step0) |s| {
        current_zoom *= s.ratio;
    }

    while (ctrl.isBusy()) {
        const step = updateZoomMotion(
            &ctrl,
            .{},
            &empty_keys,
            current_zoom,
            dt_ms,
        );
        if (step) |s| {
            current_zoom *= s.ratio;
        }
    }

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), current_zoom, 0.0001);
}

test "updateZoomMotion detent pause on continuous hold" {
    var ctrl = state.ZoomController{};
    const empty_keys = [_]Key{};

    // 0.999 approaching 1.0
    var current_zoom: f32 = 0.999;
    const step1 = updateZoomMotion(
        &ctrl,
        .{ .in = true },
        &empty_keys,
        current_zoom,
        16.0,
    );
    try std.testing.expect(step1 != null);
    current_zoom *= step1.?.ratio;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), current_zoom, 0.0001);
    try std.testing.expect(ctrl.detent_pause_ms > 0.0);

    // While holding during pause, returns null (held at 1.0)
    const step2 = updateZoomMotion(
        &ctrl,
        .{ .in = true },
        &empty_keys,
        current_zoom,
        16.0,
    );
    try std.testing.expectEqual(@as(?ZoomDelta, null), step2);
}

test "updateZoomMotion key release stops immediately after hold" {
    var ctrl = state.ZoomController{};
    const repeat_keys = [_]Key{.char_i};
    const empty_keys = [_]Key{};

    var current_zoom: f32 = 2.0;
    // Simulate holding 'i' for 20 frames (~320ms, well beyond tap duration)
    // with repeated key events coming from the OS every frame
    var frame: usize = 0;
    while (frame < 20) : (frame += 1) {
        const step = updateZoomMotion(
            &ctrl,
            .{ .in = true },
            &repeat_keys,
            current_zoom,
            16.0,
        );
        try std.testing.expect(step != null);
        current_zoom *= step.?.ratio;
        try std.testing.expect(ctrl.isBusy());
    }

    // User takes finger off key (release)
    const step_release = updateZoomMotion(
        &ctrl,
        .{},
        &empty_keys,
        current_zoom,
        16.0,
    );

    // Must stop immediately with no queued travel!
    try std.testing.expectEqual(@as(?ZoomDelta, null), step_release);
    try std.testing.expect(!ctrl.isBusy());
}
