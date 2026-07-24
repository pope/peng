const std = @import("std");
const c = @import("../app/c.zig").c;
const clay = @import("zclay");
const app_state = @import("../app/state.zig");
const app_types = @import("../app/types.zig");
const Key = app_types.Key;
const KeyModifiers = app_types.KeyModifiers;
const ViewerState = app_state.ViewerState;
const startTextInput = app_state.startTextInput;

pub const AppActionId = enum {
    next_image,
    prev_image,
    toggle_stats,
    toggle_fullscreen,
    open_file_finder,
    toggle_debug_mode,
    toggle_debug_thumb,
    exit,
    first_image,
    last_image,
    zoom_in,
    zoom_out,
    reset_zoom,
    set_scale_none,
    set_scale_shrink,
    set_scale_full,
    set_scale_crop,
    rotate_cw,
    rotate_ccw,
    reset_rotation,
    set_filter_nearest,
    set_filter_linear,
    set_filter_pixel_art,
    set_filter_mitchell,
    set_filter_lanczos3,
    increase_brightness,
    decrease_brightness,
    increase_contrast,
    decrease_contrast,
    reset_adjustments,
    set_brightness_value,
    set_contrast_value,
    go_to_image,
    open_action_palette,
};

pub const KeyboardShortcut = struct {
    key: Key,
    mod: KeyModifiers = .{},
};

pub const ActionMetadata = struct {
    name: []const u8,
    shortcut_text: []const u8,
    show_in_palette: bool,
    shortcuts: []const KeyboardShortcut,
};

pub fn getActionMetadata(action_id: AppActionId) ActionMetadata {
    return switch (action_id) {
        .next_image => .{
            .name = "Next Image",
            .shortcut_text = "Space / Right",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .space },
                .{ .key = .right },
            },
        },
        .prev_image => .{
            .name = "Previous Image",
            .shortcut_text = "Backspace / Left",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .backspace },
                .{ .key = .left },
            },
        },
        .toggle_stats => .{
            .name = "Toggle Stats for Nerds",
            .shortcut_text = "I",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_i },
            },
        },
        .toggle_fullscreen => .{
            .name = "Toggle Fullscreen",
            .shortcut_text = "F / F11",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_f },
                .{ .key = .f11 },
            },
        },
        .open_file_finder => .{
            .name = "Search Files (Go to File)",
            .shortcut_text = "Ctrl+P",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_p, .mod = .{ .ctrl = true } },
                .{ .key = .char_p, .mod = .{ .gui = true } },
            },
        },
        .toggle_debug_mode => .{
            .name = "Toggle Clay Debug Mode",
            .shortcut_text = "D",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_d },
            },
        },
        .toggle_debug_thumb => .{
            .name = "Toggle EXIF Thumbnail Debug View",
            .shortcut_text = "T",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_t },
            },
        },
        .exit => .{
            .name = "Exit Application",
            .shortcut_text = "Esc",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .escape },
            },
        },
        .first_image => .{
            .name = "First Image",
            .shortcut_text = "Home",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .home },
            },
        },
        .last_image => .{
            .name = "Last Image",
            .shortcut_text = "End",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .end },
            },
        },
        .zoom_in => .{
            .name = "Zoom In",
            .shortcut_text = "= / +",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .equals },
            },
        },
        .zoom_out => .{
            .name = "Zoom Out",
            .shortcut_text = "-",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .minus },
            },
        },
        .reset_zoom => .{
            .name = "Reset Zoom & Pan",
            .shortcut_text = "R / 0",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_r },
                .{ .key = .char_0 },
            },
        },
        .set_scale_none => .{
            .name = "Set Scale Mode: 100% (Actual Size)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_scale_shrink => .{
            .name = "Set Scale Mode: Fit if Larger (Shrink)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_scale_full => .{
            .name = "Set Scale Mode: Fit Window (Full)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_scale_crop => .{
            .name = "Set Scale Mode: Fill Window (Crop)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .rotate_cw => .{
            .name = "Rotate Clockwise (90°)",
            .shortcut_text = "]",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .right_bracket },
            },
        },
        .rotate_ccw => .{
            .name = "Rotate Counter-Clockwise (90°)",
            .shortcut_text = "[",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .left_bracket },
            },
        },
        .reset_rotation => .{
            .name = "Reset Rotation",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_nearest => .{
            .name = "Set Scaling Filter: Nearest Neighbor",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_linear => .{
            .name = "Set Scaling Filter: Bilinear (Smooth)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_pixel_art => .{
            .name = "Set Scaling Filter: Pixel Art (Crisp)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_mitchell => .{
            .name = "Set Scaling Filter: Mitchell-Netravali (HQ Bicubic)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_lanczos3 => .{
            .name = "Set Scaling Filter: Lanczos3 (Ultra HQ Resampler)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .increase_brightness => .{
            .name = "Increase Brightness (+10%)",
            .shortcut_text = "P",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_p },
            },
        },
        .decrease_brightness => .{
            .name = "Decrease Brightness (-10%)",
            .shortcut_text = "O",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_o },
            },
        },
        .increase_contrast => .{
            .name = "Increase Contrast (+10%)",
            .shortcut_text = "L",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_l },
            },
        },
        .decrease_contrast => .{
            .name = "Decrease Contrast (-10%)",
            .shortcut_text = "K",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_k },
            },
        },
        .reset_adjustments => .{
            .name = "Reset Brightness & Contrast",
            .shortcut_text = "Shift+R",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_r, .mod = .{ .shift = true } },
            },
        },
        .set_brightness_value => .{
            .name = "Set Brightness (Type Value)...",
            .shortcut_text = "Shift+B",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_b, .mod = .{ .shift = true } },
            },
        },
        .set_contrast_value => .{
            .name = "Set Contrast (Type Value)...",
            .shortcut_text = "Shift+C",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_c, .mod = .{ .shift = true } },
            },
        },
        .go_to_image => .{
            .name = "Go to Image...",
            .shortcut_text = "Shift+G",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_g, .mod = .{ .shift = true } },
            },
        },
        .open_action_palette => .{
            .name = "Search Actions (Command Palette)",
            .shortcut_text = "F1 / Ctrl+Shift+P",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .f1 },
                .{ .key = .char_p, .mod = .{ .ctrl = true, .shift = true } },
                .{ .key = .char_p, .mod = .{ .gui = true, .shift = true } },
            },
        },
    };
}

pub const app_actions = std.enums.values(AppActionId);

pub const FlatShortcut = struct {
    key: Key,
    mod: KeyModifiers,
    action_id: AppActionId,
};

pub const flat_shortcuts = blk: {
    var count: usize = 0;
    for (app_actions) |action_id| {
        count += getActionMetadata(action_id).shortcuts.len;
    }
    var arr: [count]FlatShortcut = undefined;
    var idx: usize = 0;
    for (app_actions) |action_id| {
        const meta = getActionMetadata(action_id);
        for (meta.shortcuts) |shortcut| {
            arr[idx] = .{
                .key = shortcut.key,
                .mod = shortcut.mod,
                .action_id = action_id,
            };
            idx += 1;
        }
    }
    break :blk arr;
};

pub fn triggerAction(self: *ViewerState, action_id: AppActionId) !void {
    switch (action_id) {
        .next_image => try self.next(),
        .prev_image => try self.prev(),
        .toggle_stats => self.show_stats_overlay = !self.show_stats_overlay,
        .toggle_fullscreen => {
            self.is_fullscreen = !self.is_fullscreen;
            if (!c.SDL_SetWindowFullscreen(self.window, self.is_fullscreen)) {
                std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
            }
        },
        .open_file_finder => {
            try self.openPalette(.files);
        },
        .toggle_debug_mode => clay.setDebugModeEnabled(!clay.isDebugModeEnabled()),
        .toggle_debug_thumb => try self.setDebugShowThumb(!self.debug_show_thumb),
        .exit => {
            if (self.is_fullscreen) {
                self.is_fullscreen = false;
                if (!c.SDL_SetWindowFullscreen(self.window, false)) {
                    std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
                }
            } else {
                self.running = false;
            }
        },
        .first_image => {
            if (self.image_list.items.len > 0) {
                self.current_index = 0;
                try self.updateCache();
            }
        },
        .last_image => {
            if (self.image_list.items.len > 0) {
                self.current_index = self.image_list.items.len - 1;
                try self.updateCache();
            }
        },
        .zoom_in => {
            const old_zoom = self.zoom_factor;
            self.zoom_factor = self.clampZoomFactor(self.zoom_factor + 0.5);
            self.pan_x *= (self.zoom_factor / old_zoom);
            self.pan_y *= (self.zoom_factor / old_zoom);
        },
        .zoom_out => {
            const old_zoom = self.zoom_factor;
            self.zoom_factor = self.clampZoomFactor(self.zoom_factor - 0.5);
            self.pan_x *= (self.zoom_factor / old_zoom);
            self.pan_y *= (self.zoom_factor / old_zoom);
        },
        .reset_zoom => {
            self.resetZoomPan();
        },
        .set_scale_none => {
            self.scale_mode = .none;
            self.resetZoomPan();
        },
        .set_scale_shrink => {
            self.scale_mode = .shrink;
            self.resetZoomPan();
        },
        .set_scale_full => {
            self.scale_mode = .full;
            self.resetZoomPan();
        },
        .set_scale_crop => {
            self.scale_mode = .crop;
            self.resetZoomPan();
        },
        .rotate_cw => {
            var val = self.rotation_angle + 90.0;
            if (val >= 360.0) val -= 360.0;
            self.rotation_angle = val;
            if (self.current_index) |idx| {
                if (idx < self.image_list.items.len) {
                    const path = self.image_list.items[idx];
                    try self.rotation_map.put(path, self.rotation_angle);
                }
            }
        },
        .rotate_ccw => {
            var val = self.rotation_angle - 90.0;
            if (val < 0.0) val += 360.0;
            self.rotation_angle = val;
            if (self.current_index) |idx| {
                if (idx < self.image_list.items.len) {
                    const path = self.image_list.items[idx];
                    try self.rotation_map.put(path, self.rotation_angle);
                }
            }
        },
        .reset_rotation => {
            if (self.current_index) |idx| {
                if (idx < self.image_list.items.len) {
                    const path = self.image_list.items[idx];
                    const exif_rot = self.readJpegExifOrientation(path) orelse 0.0;
                    self.rotation_angle = exif_rot;
                    try self.rotation_map.put(path, self.rotation_angle);
                } else {
                    self.rotation_angle = 0.0;
                }
            } else {
                self.rotation_angle = 0.0;
            }
        },
        .set_filter_nearest => {
            self.texture_scale_mode = .nearest;
            self.applyTextureScaleMode();
        },
        .set_filter_linear => {
            self.texture_scale_mode = .linear;
            self.applyTextureScaleMode();
        },
        .set_filter_pixel_art => {
            self.texture_scale_mode = .pixel_art;
            self.applyTextureScaleMode();
        },
        .set_filter_mitchell => {
            self.texture_scale_mode = .mitchell;
            self.applyTextureScaleMode();
        },
        .set_filter_lanczos3 => {
            self.texture_scale_mode = .lanczos3;
            self.applyTextureScaleMode();
        },
        .increase_brightness => {
            self.brightness = std.math.clamp(self.brightness + 0.1, -1.0, 1.0);
            self.adjustments_dirty = true;
        },
        .decrease_brightness => {
            self.brightness = std.math.clamp(self.brightness - 0.1, -1.0, 1.0);
            self.adjustments_dirty = true;
        },
        .increase_contrast => {
            self.contrast = std.math.clamp(self.contrast + 0.1, 0.0, 5.0);
            self.adjustments_dirty = true;
        },
        .decrease_contrast => {
            self.contrast = std.math.clamp(self.contrast - 0.1, 0.0, 5.0);
            self.adjustments_dirty = true;
        },
        .reset_adjustments => {
            self.brightness = 0.0;
            self.contrast = 1.0;
            self.adjustments_dirty = true;
        },
        .set_brightness_value => {
            try self.openPalette(.set_brightness);
        },
        .set_contrast_value => {
            try self.openPalette(.set_contrast);
        },
        .go_to_image => {
            try self.openPalette(.go_to_image);
        },
        .open_action_palette => {
            try self.openPalette(.actions);
        },
    }
}
