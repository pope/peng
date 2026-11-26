const intents = @import("intents");
const state = @import("state");
const std = @import("std");

const AppIntent = intents.AppIntent;
const flat_shortcuts = intents.actions.flat_shortcuts;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;
const PanController = state.PanController;
const ZoomController = state.ZoomController;

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

/// Per-frame smooth zoom adjustment produced by `updateZoomMotion`.
/// Carries `snap_zoom` when hitting a `1.0` detent so callers assign exact
/// `1.0` without IEEE-754 `old_zoom * (1.0 / old_zoom)` drift.
pub const ZoomDelta = struct {
    ratio: f32,
    snap_zoom: ?f32 = null,

    /// Returns true if this zoom delta represents no magnification change.
    pub inline fn isIdentity(self: ZoomDelta) bool {
        return self.ratio == 1.0 and self.snap_zoom == null;
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
/// Provides consistent, smooth movement at `metrics.glide_speed_px_per_sec`
/// for both taps and holds, eliminating discrete jumps and typematic repeat
/// stalls.
pub fn updateDirectionalPan(
    ctrl: *state.PanController,
    current_held: state.DirectionFlags,
    keys_pressed: []const Key,
    metrics: state.PanMetrics,
    dt_ms: f32,
) ?PanDelta {
    // Numerical guard and delta clamping
    if (!std.math.isFinite(dt_ms) or dt_ms <= 0.0) return null;
    const dt_sec = @min(dt_ms, 50.0) / 1000.0;
    const tap_dist = if (std.math.isFinite(metrics.tap_distance_px) and
        metrics.tap_distance_px > 0.0)
        metrics.tap_distance_px
    else
        state.PanController.TAP_DISTANCE;
    const raw_glide = metrics.glide_speed_px_per_sec;
    const glide_speed = if (std.math.isFinite(raw_glide) and raw_glide > 0.0)
        raw_glide
    else
        state.PanController.GLIDE_SPEED;

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
        ctrl.tap = .{
            .active = .{
                .direction = newly_pressed,
                .remaining_px = tap_dist,
            },
        };
    }

    // Clear stale tap when held keys switch to a non-overlapping direction
    // (preserving orthogonal transitions like .up -> .up + .left).
    if (effective_held.hasAny()) {
        switch (ctrl.tap) {
            .active => |t| {
                if ((effective_held.raw() & t.direction.raw()) == 0) {
                    ctrl.tap = .idle;
                }
            },
            .idle => {},
        }
    }

    // 3. Determine active directions: physically held keys take precedence;
    // if keys were released but smooth tap travel remains, use tap direction.
    const active_flags = if (effective_held.hasAny())
        effective_held
    else switch (ctrl.tap) {
        .idle => {
            ctrl.clearMotion();
            return null;
        },
        .active => |t| blk: {
            if (t.remaining_px > state.PanController.TAP_EPSILON_PX) {
                break :blk t.direction;
            }
            ctrl.clearMotion();
            return null;
        },
    };

    // 4. Branchless unit vector lookup & cancellation check
    const dir = DIRECTION_UNIT_LUT[active_flags.raw()];
    if (dir.x == 0.0 and dir.y == 0.0) {
        ctrl.clearMotion();
        return null;
    }

    // 5. Calculate continuous displacement at resolved glide speed
    var step_dist = glide_speed * dt_sec;

    switch (ctrl.tap) {
        .idle => {},
        .active => |t| {
            if (!effective_held.hasAny()) {
                step_dist = @min(step_dist, t.remaining_px);
            }
            const next_rem = t.remaining_px - step_dist;
            if (next_rem > state.PanController.TAP_EPSILON_PX) {
                ctrl.tap = .{
                    .active = .{
                        .direction = t.direction,
                        .remaining_px = next_rem,
                    },
                };
            } else {
                ctrl.tap = .idle;
            }
        },
    }

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
    if (!std.math.isFinite(dt_ms) or dt_ms <= 0.0) return null;
    const dt_sec = @min(dt_ms, 50.0) / 1000.0;

    var pressed_mask: u2 = 0;
    for (keys_pressed) |key| {
        if (getZoomDirectionForMappedKey(key)) |dir| {
            switch (dir) {
                .in => pressed_mask |= (state.ZoomFlags{ .in = true }).raw(),
                .out => pressed_mask |= (state.ZoomFlags{ .out = true }).raw(),
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
    switch (ctrl.phase) {
        .detent_pause_ms => |pause_ms| {
            if (pause_ms > state.ZoomController.DETENT_EPSILON_MS) {
                const rem_ms = @max(0.0, pause_ms - dt_ms);
                ctrl.prev_held = effective_held;
                if (effective_held.hasAny()) {
                    const eps = state.ZoomController.DETENT_EPSILON_MS;
                    ctrl.phase = if (rem_ms > eps)
                        .{ .detent_pause_ms = rem_ms }
                    else
                        .idle;
                } else {
                    ctrl.clearMotion();
                }
                return null;
            }
            ctrl.phase = .idle;
        },
        .idle, .tap => {},
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
    // if keys released but smooth tap travel remains, use tap direction.
    const active_dir: state.ZoomDirection = if (effective_held.in)
        .in
    else if (effective_held.out)
        .out
    else switch (ctrl.phase) {
        .idle, .detent_pause_ms => {
            ctrl.clearMotion();
            return null;
        },
        .tap => |t| blk: {
            if (t.remaining_log > state.ZoomController.TAP_EPSILON_LOG) {
                break :blk t.direction;
            }
            ctrl.clearMotion();
            return null;
        },
    };

    // Clear stale tap if held direction switched directly (.in <-> .out).
    if (effective_held.hasAny()) {
        switch (ctrl.phase) {
            .tap => |t| if (t.direction != active_dir) {
                ctrl.phase = .idle;
            },
            .idle, .detent_pause_ms => {},
        }
    }

    // Preserve detent_target for Step 7 before Step 5 settles .tap to .idle.
    const tap_detent_target: ?f32 = switch (ctrl.phase) {
        .tap => |t| if (t.direction == active_dir)
            t.detent_target
        else
            null,
        .idle, .detent_pause_ms => null,
    };

    // 5. Calculate log-space displacement at constant GLIDE_RATE
    var step_log = state.ZoomController.GLIDE_RATE * dt_sec;
    var tap_completed_idle = false;

    switch (ctrl.phase) {
        .tap => |t| {
            if (!effective_held.hasAny()) {
                step_log = @min(step_log, t.remaining_log);
            }
            const next_rem = t.remaining_log - step_log;
            if (next_rem > state.ZoomController.TAP_EPSILON_LOG) {
                ctrl.phase = .{
                    .tap = .{
                        .direction = t.direction,
                        .remaining_log = next_rem,
                        .detent_target = t.detent_target,
                    },
                };
            } else {
                if (!effective_held.hasAny()) {
                    step_log = t.remaining_log;
                    tap_completed_idle = true;
                }
                ctrl.phase = .idle;
            }
        },
        .idle, .detent_pause_ms => {},
    }

    ctrl.prev_held = effective_held;

    if (step_log <= 0.0) return null;

    // 6. Calculate scale ratio this frame
    const sign: f32 = switch (active_dir) {
        .in => 1.0,
        .out => -1.0,
    };
    var ratio = @exp(sign * step_log);
    var next_zoom = current_zoom * ratio;

    // 7. Check 1.0x detent crossing
    var hit_detent = false;
    if (tap_detent_target) |dt| {
        switch (active_dir) {
            .in => if (next_zoom >= dt) {
                next_zoom = dt;
                ratio = next_zoom / current_zoom;
                ctrl.phase = .idle;
                hit_detent = true;
            },
            .out => if (next_zoom <= dt) {
                next_zoom = dt;
                ratio = next_zoom / current_zoom;
                ctrl.phase = .idle;
                hit_detent = true;
            },
        }
        if (!hit_detent and tap_completed_idle) {
            next_zoom = dt;
            ratio = next_zoom / current_zoom;
            hit_detent = true;
        }
    } else {
        switch (active_dir) {
            .in => if (current_zoom < 1.0 and next_zoom >= 1.0) {
                next_zoom = 1.0;
                ratio = next_zoom / current_zoom;
                hit_detent = true;
            },
            .out => if (current_zoom > 1.0 and next_zoom <= 1.0) {
                next_zoom = 1.0;
                ratio = next_zoom / current_zoom;
                hit_detent = true;
            },
        }
    }

    if (hit_detent and effective_held.hasAny()) {
        ctrl.phase = .{
            .detent_pause_ms = state.ZoomController.DETENT_PAUSE_MS,
        };
    }

    // 8. Clamping bounds
    const clamped_zoom = state.clampZoomFactor(next_zoom).get();
    if (clamped_zoom == current_zoom) {
        ctrl.phase = .idle;
        ctrl.prev_held = effective_held;
        return null;
    }
    ratio = clamped_zoom / current_zoom;

    return ZoomDelta{
        .ratio = ratio,
        .snap_zoom = if (hit_detent) clamped_zoom else null,
    };
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
    var ctrl: PanController = .{};
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
        .{},
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
        .{},
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
        .{},
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
        .{},
        16.0,
    );
    try std.testing.expectEqual(@as(?PanDelta, null), res_opp);
}

test "updateDirectionalPan smooth tap completion after key release" {
    var ctrl: PanController = .{};
    const empty_keys = [_]Key{};

    const exp_cardinal = state.PanController.GLIDE_SPEED * (16.0 / 1000.0);

    // Frame 0: Key pressed for 1 frame
    const f0 = updateDirectionalPan(
        &ctrl,
        .{ .up = true },
        &empty_keys,
        .{},
        16.0,
    );
    try std.testing.expect(f0 != null);
    try std.testing.expectApproxEqAbs(exp_cardinal, f0.?.dy, 0.01);
    try std.testing.expect(ctrl.isBusy());

    // Frame 1: Key released (current_held is empty), smooth tap continues
    const f1 = updateDirectionalPan(&ctrl, .{}, &empty_keys, .{}, 16.0);
    try std.testing.expect(f1 != null);
    try std.testing.expectApproxEqAbs(exp_cardinal, f1.?.dy, 0.01);
    try std.testing.expect(ctrl.isBusy());

    // Frame 2: Final frame of smooth tap completes remaining 4.4px
    const f2 = updateDirectionalPan(&ctrl, .{}, &empty_keys, .{}, 16.0);
    try std.testing.expect(f2 != null);
    const exp_rem = state.PanController.TAP_DISTANCE - (exp_cardinal * 2.0);
    try std.testing.expectApproxEqAbs(exp_rem, f2.?.dy, 0.01);
    try std.testing.expect(!ctrl.isBusy());

    // Frame 3: Tap finished, motion stops
    const f3 = updateDirectionalPan(&ctrl, .{}, &empty_keys, .{}, 16.0);
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
    var ctrl: PanController = .{};
    const empty_keys = [_]Key{};
    const exp_cardinal = state.PanController.GLIDE_SPEED * (16.0 / 1000.0);

    // Every frame during hold moves at the exact same constant speed
    var frame: usize = 0;
    while (frame < 10) : (frame += 1) {
        const step = updateDirectionalPan(
            &ctrl,
            .{ .up = true },
            &empty_keys,
            .{},
            16.0,
        );
        try std.testing.expect(step != null);
        try std.testing.expectApproxEqAbs(exp_cardinal, step.?.dy, 0.01);
        try std.testing.expectEqual(@as(f32, 0.0), step.?.dx);
    }
}

test "updateDirectionalPan seamless orthogonal transition without stutter" {
    var ctrl: PanController = .{};
    const empty_keys = [_]Key{};

    const inv_sqrt2: f32 = 0.70710678;
    const exp_cardinal = state.PanController.GLIDE_SPEED * (16.0 / 1000.0);
    const exp_diagonal = inv_sqrt2 * exp_cardinal;

    // 1. Moving Up
    const f_up = updateDirectionalPan(
        &ctrl,
        .{ .up = true },
        &empty_keys,
        .{},
        16.0,
    );
    try std.testing.expect(f_up != null);
    try std.testing.expectApproxEqAbs(exp_cardinal, f_up.?.dy, 0.01);

    // 2. Press Left while holding Up: immediately produces diagonal motion
    const f_diag = updateDirectionalPan(
        &ctrl,
        .{ .up = true, .left = true },
        &empty_keys,
        .{},
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
        .{},
        16.0,
    );
    try std.testing.expect(f_left != null);
    try std.testing.expectApproxEqAbs(exp_cardinal, f_left.?.dx, 0.01);
    try std.testing.expectEqual(@as(f32, 0.0), f_left.?.dy);

    // 4. Release all keys: stops immediately
    const f_stop = updateDirectionalPan(&ctrl, .{}, &empty_keys, .{}, 16.0);
    try std.testing.expectEqual(@as(?PanDelta, null), f_stop);
}

test "updateDirectionalPan custom PanMetrics and invalid-input fallbacks" {
    var ctrl: PanController = .{};
    const empty_keys = [_]Key{};

    const custom = state.PanMetrics{
        .tap_distance_px = 60.0,
        .glide_speed_px_per_sec = 1600.0,
    };

    // Tap completes exact custom tap_distance_px at custom glide speed
    const f0 = updateDirectionalPan(
        &ctrl,
        .{ .right = true },
        &empty_keys,
        custom,
        16.0,
    );
    try std.testing.expect(f0 != null);
    try std.testing.expectApproxEqAbs(@as(f32, -25.6), f0.?.dx, 0.01);

    var total: f32 = -f0.?.dx;
    var guard: usize = 0;
    while (ctrl.isBusy() and guard < 20) : (guard += 1) {
        const step = updateDirectionalPan(
            &ctrl,
            .{},
            &empty_keys,
            custom,
            16.0,
        );
        if (step) |s| total += -s.dx;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), total, 0.01);

    // Non-finite/non-positive metrics fall back to PanController defaults
    ctrl.reset();
    const bad = state.PanMetrics{
        .tap_distance_px = std.math.nan(f32),
        .glide_speed_px_per_sec = -10.0,
    };
    const fallback = updateDirectionalPan(
        &ctrl,
        .{ .up = true },
        &empty_keys,
        bad,
        16.0,
    );
    try std.testing.expect(fallback != null);
    try std.testing.expectApproxEqAbs(
        state.PanController.GLIDE_SPEED * (16.0 / 1000.0),
        fallback.?.dy,
        0.01,
    );

    // +Inf dt_ms returns null safely
    ctrl.reset();
    try std.testing.expectEqual(
        @as(?PanDelta, null),
        updateDirectionalPan(
            &ctrl,
            .{ .up = true },
            &empty_keys,
            custom,
            std.math.inf(f32),
        ),
    );
}

test "updateZoomMotion constant rate continuous hold" {
    var ctrl: ZoomController = .{};
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
    var ctrl: ZoomController = .{};
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
    var ctrl: ZoomController = .{};
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
    var ctrl: ZoomController = .{};
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
    var ctrl: ZoomController = .{};
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
    switch (ctrl.phase) {
        .detent_pause_ms => |ms| try std.testing.expect(ms > 0.0),
        .idle, .tap => return error.TestUnexpectedResult,
    }

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

test "updateZoomMotion key release during detent pause settles to idle" {
    var ctrl: ZoomController = .{};
    const empty_keys = [_]Key{};

    var current_zoom: f32 = 0.999;
    const hit = updateZoomMotion(
        &ctrl,
        .{ .in = true },
        &empty_keys,
        current_zoom,
        16.0,
    );
    try std.testing.expect(hit != null);
    current_zoom *= hit.?.ratio;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), current_zoom, 0.0001);

    // Releasing held key during detent pause clears phase immediately
    const released = updateZoomMotion(
        &ctrl,
        .{},
        &empty_keys,
        current_zoom,
        16.0,
    );
    try std.testing.expectEqual(@as(?ZoomDelta, null), released);
    try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);
    try std.testing.expect(!ctrl.isBusy());
}

test "updateZoomMotion final-step tap crossing 1.0 snaps to detent" {
    var ctrl: ZoomController = .{};
    const empty_keys = [_]Key{};
    const dt_ms = 16.0;

    // 0.805 * 1.25 = 1.00625 >= 1.0: crosses 1.0 only on the final frame
    // when remaining_log drains to idle in Step 5.
    var current_zoom: f32 = 0.805;
    const step0 = updateZoomMotion(
        &ctrl,
        .{},
        &[_]Key{.char_i},
        current_zoom,
        dt_ms,
    );
    try std.testing.expect(step0 != null);
    current_zoom *= step0.?.ratio;

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

    try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), current_zoom, 0.0001);
}

test "updateZoomMotion released tap crossing 1.0 with suppressed key" {
    var ctrl: ZoomController = .{};
    ctrl.suppress(.{ .in = true });
    const empty_keys = [_]Key{};

    // Tap 'o' across 1.0 while '.in' remains physically held in
    // suppressed_held (e.g. from modal open). Must stay .idle on crossing.
    var current_zoom: f32 = 1.1;
    const step0 = updateZoomMotion(
        &ctrl,
        .{ .in = true },
        &[_]Key{.char_o},
        current_zoom,
        16.0,
    );
    try std.testing.expect(step0 != null);
    current_zoom = step0.?.snap_zoom orelse (current_zoom * step0.?.ratio);

    var frames: usize = 0;
    while (ctrl.isBusy() and frames < 40) : (frames += 1) {
        switch (ctrl.phase) {
            .idle, .tap => {},
            .detent_pause_ms => return error.TestUnexpectedResult,
        }
        const step = updateZoomMotion(
            &ctrl,
            .{ .in = true },
            &empty_keys,
            current_zoom,
            16.0,
        );
        if (step) |s| {
            current_zoom = s.snap_zoom orelse (current_zoom * s.ratio);
        }
    }

    try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);
    try std.testing.expect(!ctrl.isBusy());
    try std.testing.expectEqual(@as(f32, 1.0), current_zoom);
}

test "updateZoomMotion key release stops immediately after hold" {
    var ctrl: ZoomController = .{};
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

test "updateZoomMotion held direction reversal clears stale tap" {
    const empty_keys = [_]Key{};

    // 1. zoom = 0.95: Frame 0 .in held -> Frame 1 .out held
    var ctrl_in_out: ZoomController = .{};
    const f0 = updateZoomMotion(
        &ctrl_in_out,
        .{ .in = true },
        &empty_keys,
        0.95,
        16.0,
    );
    try std.testing.expect(f0 != null);
    const z_f0 = f0.?.snap_zoom orelse (0.95 * f0.?.ratio);
    try std.testing.expect(z_f0 > 0.95);

    const f1 = updateZoomMotion(
        &ctrl_in_out,
        .{ .out = true },
        &empty_keys,
        z_f0,
        16.0,
    );
    try std.testing.expect(f1 != null);
    const z_f1 = f1.?.snap_zoom orelse (z_f0 * f1.?.ratio);
    try std.testing.expect(z_f1 < z_f0);
    try std.testing.expectEqual(@as(?f32, null), f1.?.snap_zoom);
    try std.testing.expectEqual(state.ZoomPhase.idle, ctrl_in_out.phase);

    const f2 = updateZoomMotion(&ctrl_in_out, .{}, &empty_keys, z_f1, 16.0);
    try std.testing.expectEqual(@as(?ZoomDelta, null), f2);
    try std.testing.expect(!ctrl_in_out.isBusy());

    // 2. zoom = 1.05: Frame 0 .out held -> Frame 1 .in held
    var ctrl_out_in: ZoomController = .{};
    const g0 = updateZoomMotion(
        &ctrl_out_in,
        .{ .out = true },
        &empty_keys,
        1.05,
        16.0,
    );
    try std.testing.expect(g0 != null);
    const z_g0 = g0.?.snap_zoom orelse (1.05 * g0.?.ratio);
    try std.testing.expect(z_g0 < 1.05);

    const g1 = updateZoomMotion(
        &ctrl_out_in,
        .{ .in = true },
        &empty_keys,
        z_g0,
        16.0,
    );
    try std.testing.expect(g1 != null);
    const z_g1 = g1.?.snap_zoom orelse (z_g0 * g1.?.ratio);
    try std.testing.expect(z_g1 > z_g0);
    try std.testing.expectEqual(@as(?f32, null), g1.?.snap_zoom);
    try std.testing.expectEqual(state.ZoomPhase.idle, ctrl_out_in.phase);

    const g2 = updateZoomMotion(&ctrl_out_in, .{}, &empty_keys, z_g1, 16.0);
    try std.testing.expectEqual(@as(?ZoomDelta, null), g2);
    try std.testing.expect(!ctrl_out_in.isBusy());
}

test "updateDirectionalPan held direction reversal clears stale tap" {
    const empty_keys = [_]Key{};

    // 1. Frame 0 .up held -> Frame 1 .down held -> Frame 2 released
    var ctrl: PanController = .{};
    const f0 = updateDirectionalPan(
        &ctrl,
        .{ .up = true },
        &empty_keys,
        .{},
        16.0,
    );
    try std.testing.expect(f0 != null);
    try std.testing.expect(f0.?.dy > 0.0);

    const f1 = updateDirectionalPan(
        &ctrl,
        .{ .down = true },
        &empty_keys,
        .{},
        16.0,
    );
    try std.testing.expect(f1 != null);
    try std.testing.expect(f1.?.dy < 0.0);

    const f2 = updateDirectionalPan(&ctrl, .{}, &empty_keys, .{}, 16.0);
    try std.testing.expectEqual(@as(?PanDelta, null), f2);
    try std.testing.expect(!ctrl.isBusy());

    // 2. Non-overlapping 90-degree switch at small dt clears stale .up tap
    ctrl.reset();
    const s0 = updateDirectionalPan(
        &ctrl,
        .{ .up = true },
        &empty_keys,
        .{},
        4.0,
    );
    try std.testing.expect(s0 != null);
    try std.testing.expect(s0.?.dy > 0.0);

    const s1 = updateDirectionalPan(
        &ctrl,
        .{ .left = true },
        &empty_keys,
        .{},
        4.0,
    );
    try std.testing.expect(s1 != null);
    try std.testing.expect(s1.?.dx > 0.0);
    try std.testing.expectEqual(@as(f32, 0.0), s1.?.dy);

    const s2 = updateDirectionalPan(&ctrl, .{}, &empty_keys, .{}, 4.0);
    try std.testing.expectEqual(@as(?PanDelta, null), s2);
    try std.testing.expect(!ctrl.isBusy());

    // 3. Overlapping orthogonal transition (.up -> .up + .left -> release)
    // preserves the remaining .up tap travel.
    ctrl.reset();
    const o0 = updateDirectionalPan(
        &ctrl,
        .{ .up = true },
        &empty_keys,
        .{},
        16.0,
    );
    try std.testing.expect(o0 != null);
    const o1 = updateDirectionalPan(
        &ctrl,
        .{
            .up = true,
            .left = true,
        },
        &empty_keys,
        .{},
        16.0,
    );
    try std.testing.expect(o1 != null);
    const o2 = updateDirectionalPan(&ctrl, .{}, &empty_keys, .{}, 16.0);
    try std.testing.expect(o2 != null);
    try std.testing.expect(o2.?.dy > 0.0);
    try std.testing.expectEqual(@as(f32, 0.0), o2.?.dx);
}

fn runZoomTapForTest(
    ctrl: *ZoomController,
    key: Key,
    start_zoom: f32,
    dt_ms: f32,
) struct { zoom: f32, snap_zoom: ?f32 } {
    const empty_keys = [_]Key{};
    const pressed = [_]Key{key};
    var zoom = start_zoom;
    var snap_zoom: ?f32 = null;

    const first = updateZoomMotion(ctrl, .{}, &pressed, zoom, dt_ms);
    if (first) |s| {
        if (s.snap_zoom) |sz| snap_zoom = sz;
        zoom = s.snap_zoom orelse (zoom * s.ratio);
    }

    var guard: usize = 0;
    while (ctrl.isBusy() and guard < 500) : (guard += 1) {
        const step = updateZoomMotion(ctrl, .{}, &empty_keys, zoom, dt_ms);
        if (step) |s| {
            if (s.snap_zoom) |sz| snap_zoom = sz;
            zoom = s.snap_zoom orelse (zoom * s.ratio);
        }
    }
    return .{
        .zoom = zoom,
        .snap_zoom = snap_zoom,
    };
}

test "updateZoomMotion released tap detent snap and roundtrips" {
    const dt_cases = [_]f32{ 1.0, 16.666666, 33.333333, 50.0 };
    for (dt_cases) |dt_ms| {
        var ctrl: ZoomController = .{};

        // 0.8 -> .in snaps cleanly to 1.0
        const r_in = runZoomTapForTest(&ctrl, .char_i, 0.8, dt_ms);
        try std.testing.expectEqual(@as(?f32, 1.0), r_in.snap_zoom);
        try std.testing.expectEqual(@as(f32, 1.0), r_in.zoom);
        try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);
        try std.testing.expect(!ctrl.isBusy());

        // 1.25 -> .out snaps cleanly to 1.0
        ctrl.reset();
        const r_out = runZoomTapForTest(&ctrl, .char_o, 1.25, dt_ms);
        try std.testing.expectEqual(@as(?f32, 1.0), r_out.snap_zoom);
        try std.testing.expectEqual(@as(f32, 1.0), r_out.zoom);
        try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);
        try std.testing.expect(!ctrl.isBusy());

        // Roundtrip: 1.0 -> .in -> .out -> .out
        ctrl.reset();
        const a1 = runZoomTapForTest(&ctrl, .char_i, 1.0, dt_ms);
        try std.testing.expectEqual(@as(?f32, null), a1.snap_zoom);
        try std.testing.expectApproxEqAbs(@as(f32, 1.25), a1.zoom, 0.001);

        const a2 = runZoomTapForTest(&ctrl, .char_o, a1.zoom, dt_ms);
        try std.testing.expectEqual(@as(?f32, 1.0), a2.snap_zoom);
        try std.testing.expectEqual(@as(f32, 1.0), a2.zoom);
        try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);

        const a3 = runZoomTapForTest(&ctrl, .char_o, a2.zoom, dt_ms);
        try std.testing.expectEqual(@as(?f32, null), a3.snap_zoom);
        try std.testing.expectApproxEqAbs(@as(f32, 0.8), a3.zoom, 0.001);

        // Roundtrip: 1.0 -> .out -> .in -> .in
        ctrl.reset();
        const b1 = runZoomTapForTest(&ctrl, .char_o, 1.0, dt_ms);
        try std.testing.expectEqual(@as(?f32, null), b1.snap_zoom);
        try std.testing.expectApproxEqAbs(@as(f32, 0.8), b1.zoom, 0.001);

        const b2 = runZoomTapForTest(&ctrl, .char_i, b1.zoom, dt_ms);
        try std.testing.expectEqual(@as(?f32, 1.0), b2.snap_zoom);
        try std.testing.expectEqual(@as(f32, 1.0), b2.zoom);
        try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);

        const b3 = runZoomTapForTest(&ctrl, .char_i, b2.zoom, dt_ms);
        try std.testing.expectEqual(@as(?f32, null), b3.snap_zoom);
        try std.testing.expectApproxEqAbs(@as(f32, 1.25), b3.zoom, 0.001);
    }
}

test "updateZoomMotion clamping at bounds preserves suppressed_held" {
    const empty_keys = [_]Key{};
    const out_keys = [_]Key{.char_o};
    const in_keys = [_]Key{.char_i};

    // 1. At ZoomFactor.MIN with .in suppressed: tap .char_o keeps .in
    // suppressed and does not trigger an uncommanded zoom on the next frame.
    var ctrl: ZoomController = .{};
    ctrl.suppress(.{ .in = true });
    const min_z = state.ZoomFactor.MIN;
    const min_f0 = updateZoomMotion(
        &ctrl,
        .{ .in = true },
        &out_keys,
        min_z,
        16.0,
    );
    try std.testing.expectEqual(@as(?ZoomDelta, null), min_f0);
    try std.testing.expect(ctrl.suppressed_held.in);
    try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);
    try std.testing.expect(!ctrl.isBusy());

    const min_f1 = updateZoomMotion(
        &ctrl,
        .{ .in = true },
        &empty_keys,
        min_z,
        16.0,
    );
    try std.testing.expectEqual(@as(?ZoomDelta, null), min_f1);
    try std.testing.expect(ctrl.suppressed_held.in);
    try std.testing.expect(!ctrl.isBusy());

    const min_f2 = updateZoomMotion(&ctrl, .{}, &empty_keys, min_z, 16.0);
    try std.testing.expectEqual(@as(?ZoomDelta, null), min_f2);
    try std.testing.expect(!ctrl.suppressed_held.in);
    try std.testing.expect(!ctrl.isBusy());

    // 2. At ZoomFactor.MAX with .out suppressed: tap .char_i keeps .out
    // suppressed and does not trigger an uncommanded zoom on the next frame.
    ctrl.reset();
    ctrl.suppress(.{ .out = true });
    const max_z = state.ZoomFactor.MAX;
    const max_f0 = updateZoomMotion(
        &ctrl,
        .{ .out = true },
        &in_keys,
        max_z,
        16.0,
    );
    try std.testing.expectEqual(@as(?ZoomDelta, null), max_f0);
    try std.testing.expect(ctrl.suppressed_held.out);
    try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);
    try std.testing.expect(!ctrl.isBusy());

    const max_f1 = updateZoomMotion(
        &ctrl,
        .{ .out = true },
        &empty_keys,
        max_z,
        16.0,
    );
    try std.testing.expectEqual(@as(?ZoomDelta, null), max_f1);
    try std.testing.expect(ctrl.suppressed_held.out);
    try std.testing.expect(!ctrl.isBusy());

    const max_f2 = updateZoomMotion(&ctrl, .{}, &empty_keys, max_z, 16.0);
    try std.testing.expectEqual(@as(?ZoomDelta, null), max_f2);
    try std.testing.expect(!ctrl.suppressed_held.out);
    try std.testing.expect(!ctrl.isBusy());

    // 3. Holding .out at MIN tracks prev_held and settles cleanly on release.
    ctrl.reset();
    const hold_f0 = updateZoomMotion(
        &ctrl,
        .{ .out = true },
        &out_keys,
        min_z,
        16.0,
    );
    try std.testing.expectEqual(@as(?ZoomDelta, null), hold_f0);
    try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);
    try std.testing.expect(ctrl.prev_held.out);
    try std.testing.expect(ctrl.isBusy());

    const rel_f1 = updateZoomMotion(&ctrl, .{}, &empty_keys, min_z, 16.0);
    try std.testing.expectEqual(@as(?ZoomDelta, null), rel_f1);
    try std.testing.expectEqual(state.ZoomPhase.idle, ctrl.phase);
    try std.testing.expect(!ctrl.prev_held.hasAny());
    try std.testing.expect(!ctrl.isBusy());
}
