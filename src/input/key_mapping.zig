const std = @import("std");
const state = @import("state");
const intents = @import("intents");
const Key = state.Key;
const KeyModifiers = state.KeyModifiers;

pub const KeyContext = enum {
    global,
    viewer_normal,
    viewer_zoomed,
    palette,
};

/// Performs data-driven key lookup returning a pure AppIntent variant or null.
pub fn mapKeyToAction(key: Key, mod: KeyModifiers, ctx: KeyContext) ?intents.AppIntent {
    // 1. Context-Sensitive Arrow Keys when Viewport is Zoomed (Panning)
    if (ctx == .viewer_zoomed) {
        if (!mod.ctrl and !mod.shift and !mod.alt and !mod.gui) {
            switch (key) {
                .left => return .{ .pan_by = .{ .dx = 30.0, .dy = 0.0 } },
                .right => return .{ .pan_by = .{ .dx = -30.0, .dy = 0.0 } },
                .up => return .{ .pan_by = .{ .dx = 0.0, .dy = 30.0 } },
                .down => return .{ .pan_by = .{ .dx = 0.0, .dy = -30.0 } },
                else => {},
            }
        }
    }

    // 2. Fine Zooming (Keyboard-specific step adjustments)
    if (!mod.ctrl and !mod.shift and !mod.alt and !mod.gui) {
        switch (key) {
            .equals => return .zoom_in,
            .minus => return .zoom_out,
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
    // Check next_image via Right Arrow in normal mode
    const nav_right = mapKeyToAction(.right, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.next_image, nav_right.?);

    // Check next_image via Space in normal mode
    const nav_space = mapKeyToAction(.space, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.next_image, nav_space.?);

    // Check reset_zoom via R key
    const reset_zoom = mapKeyToAction(.char_r, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.reset_zoom, reset_zoom.?);

    // Check reset_adjustments via Shift+R key
    const reset_adj = mapKeyToAction(.char_r, .{ .shift = true }, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.reset_adjustments, reset_adj.?);

    // Check rotate_cw via ] key
    const rot_cw = mapKeyToAction(.right_bracket, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.rotate_cw, rot_cw.?);

    // Check brightness increase via P key
    const bright_up = mapKeyToAction(.char_p, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.increase_brightness, bright_up.?);
}
