const intents = @import("intents");
const state = @import("state");
const std = @import("std");

const AppIntent = intents.AppIntent;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;

pub const KeyContext = enum {
    global,
    viewer_normal,
    viewer_zoomed,
    palette,
};

/// Performs data-driven key lookup returning a pure AppIntent variant or null.
pub fn mapKeyToAction(key: Key, mod: KeyModifiers, ctx: KeyContext) ?intents.AppIntent {
    // 1. Context-Sensitive Arrow Keys and Vim Keys when Viewport is Zoomed (Panning)
    if (ctx == .viewer_zoomed) {
        if (!mod.ctrl and !mod.shift and !mod.alt and !mod.gui) {
            switch (key) {
                .left, .char_h => return .{ .pan_by = .{ .dx = 30.0, .dy = 0.0 } },
                .right, .char_l => return .{ .pan_by = .{ .dx = -30.0, .dy = 0.0 } },
                .up, .char_k => return .{ .pan_by = .{ .dx = 0.0, .dy = 30.0 } },
                .down, .char_j => return .{ .pan_by = .{ .dx = 0.0, .dy = -30.0 } },
                else => {},
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

    // 3. Command Palette Single Source of Truth Lookup (state.flat_shortcuts)
    for (state.flat_shortcuts) |shortcut| {
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
    const reset_adj = mapKeyToAction(.char_r, .{ .shift = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.reset_adjustments, reset_adj.?);

    // Check rotate_cw via E key
    const rot_cw = mapKeyToAction(.char_e, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.rotate_cw, rot_cw.?);

    // Check rotate_ccw via Shift+E key
    const rot_ccw = mapKeyToAction(.char_e, .{ .shift = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.rotate_ccw, rot_ccw.?);

    // Check brightness adjustments via B / Shift+B
    const bright_up = mapKeyToAction(.char_b, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.increase_brightness, bright_up.?);
    const bright_down = mapKeyToAction(.char_b, .{ .shift = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.decrease_brightness, bright_down.?);

    // Check contrast adjustments via C / Shift+C
    const contrast_up = mapKeyToAction(.char_c, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.increase_contrast, contrast_up.?);
    const contrast_down = mapKeyToAction(.char_c, .{ .shift = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.decrease_contrast, contrast_down.?);

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
