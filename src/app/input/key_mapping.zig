const std = @import("std");
const types = @import("../types.zig");
const intents = @import("intents");
const Key = types.Key;
const KeyModifiers = types.KeyModifiers;

pub const KeyContext = enum {
    global,
    viewer_normal,
    viewer_zoomed,
    palette,
};

pub const InputAction = union(enum) {
    none,
    pan: struct { dx: f32, dy: f32 },
    zoom: struct { factor_delta: f32 },
    trigger_intent: intents.AppIntent,
};

/// Performs data-driven key lookup using palette_action_items (flat_shortcuts) as the source of truth
pub fn mapKeyToAction(key: Key, mod: KeyModifiers, ctx: KeyContext) InputAction {
    // 1. Context-Sensitive Arrow Keys when Viewport is Zoomed (Panning)
    if (ctx == .viewer_zoomed) {
        if (!mod.ctrl and !mod.shift and !mod.alt and !mod.gui) {
            switch (key) {
                .left => return .{ .pan = .{ .dx = 30.0, .dy = 0.0 } },
                .right => return .{ .pan = .{ .dx = -30.0, .dy = 0.0 } },
                .up => return .{ .pan = .{ .dx = 0.0, .dy = 30.0 } },
                .down => return .{ .pan = .{ .dx = 0.0, .dy = -30.0 } },
                else => {},
            }
        }
    }

    // 2. Fine Zooming (Keyboard-specific step adjustments)
    if (!mod.ctrl and !mod.shift and !mod.alt and !mod.gui) {
        switch (key) {
            .equals => return .{ .zoom = .{ .factor_delta = 0.1 } },
            .minus => return .{ .zoom = .{ .factor_delta = -0.1 } },
            else => {},
        }
    }

    // 3. Command Palette Single Source of Truth Lookup (types.flat_shortcuts)
    for (types.flat_shortcuts) |shortcut| {
        if (key == shortcut.key and
            mod.ctrl == shortcut.mod.ctrl and
            mod.shift == shortcut.mod.shift and
            mod.alt == shortcut.mod.alt and
            mod.gui == shortcut.mod.gui)
        {
            return .{ .trigger_intent = shortcut.intent };
        }
    }

    return .none;
}

test "mapKeyToAction aligned with palette action items" {
    // Check next_image via Right Arrow in normal mode
    const nav_right = mapKeyToAction(.right, .{}, .viewer_normal);
    try std.testing.expect(nav_right == .trigger_intent);
    try std.testing.expectEqual(intents.AppIntent.next_image, nav_right.trigger_intent);

    // Check next_image via Space in normal mode
    const nav_space = mapKeyToAction(.space, .{}, .viewer_normal);
    try std.testing.expect(nav_space == .trigger_intent);
    try std.testing.expectEqual(intents.AppIntent.next_image, nav_space.trigger_intent);

    // Check reset_zoom via R key
    const reset_zoom = mapKeyToAction(.char_r, .{}, .viewer_normal);
    try std.testing.expect(reset_zoom == .trigger_intent);
    try std.testing.expectEqual(intents.AppIntent.reset_zoom, reset_zoom.trigger_intent);

    // Check reset_adjustments via Shift+R key
    const reset_adj = mapKeyToAction(.char_r, .{ .shift = true }, .viewer_normal);
    try std.testing.expect(reset_adj == .trigger_intent);
    try std.testing.expectEqual(intents.AppIntent.reset_adjustments, reset_adj.trigger_intent);

    // Check rotate_cw via ] key
    const rot_cw = mapKeyToAction(.right_bracket, .{}, .viewer_normal);
    try std.testing.expect(rot_cw == .trigger_intent);
    try std.testing.expectEqual(intents.AppIntent.rotate_cw, rot_cw.trigger_intent);

    // Check brightness increase via P key
    const bright_up = mapKeyToAction(.char_p, .{}, .viewer_normal);
    try std.testing.expect(bright_up == .trigger_intent);
    try std.testing.expectEqual(intents.AppIntent.increase_brightness, bright_up.trigger_intent);
}
