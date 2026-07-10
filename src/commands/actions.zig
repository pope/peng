const std = @import("std");
const main = @import("../main.zig");
const c = main.c;
const clay = @import("zclay");
const app_state = @import("../app/state.zig");
const ViewerState = app_state.ViewerState;
const startTextInput = app_state.startTextInput;

pub const AppActionId = enum {
    next_image,
    prev_image,
    toggle_stats,
    toggle_fullscreen,
    open_file_finder,
    toggle_debug_mode,
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
    key: c.SDL_Keycode,
    mod: c.SDL_Keymod = 0,
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
                .{ .key = c.SDLK_SPACE },
                .{ .key = c.SDLK_RIGHT },
            },
        },
        .prev_image => .{
            .name = "Previous Image",
            .shortcut_text = "Backspace / Left",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_BACKSPACE },
                .{ .key = c.SDLK_LEFT },
            },
        },
        .toggle_stats => .{
            .name = "Toggle Stats for Nerds",
            .shortcut_text = "I",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_I },
            },
        },
        .toggle_fullscreen => .{
            .name = "Toggle Fullscreen",
            .shortcut_text = "F / F11",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_F },
                .{ .key = c.SDLK_F11 },
            },
        },
        .open_file_finder => .{
            .name = "Search Files (Go to File)",
            .shortcut_text = "Ctrl+P",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_P, .mod = c.SDL_KMOD_CTRL },
                .{ .key = c.SDLK_P, .mod = c.SDL_KMOD_GUI },
            },
        },
        .toggle_debug_mode => .{
            .name = "Toggle Clay Debug Mode",
            .shortcut_text = "D",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_D },
            },
        },
        .exit => .{
            .name = "Exit Application",
            .shortcut_text = "Esc",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_ESCAPE },
            },
        },
        .first_image => .{
            .name = "First Image",
            .shortcut_text = "Home",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_HOME },
            },
        },
        .last_image => .{
            .name = "Last Image",
            .shortcut_text = "End",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_END },
            },
        },
        .zoom_in => .{
            .name = "Zoom In",
            .shortcut_text = "= / +",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_EQUALS },
                .{ .key = c.SDLK_KP_PLUS },
            },
        },
        .zoom_out => .{
            .name = "Zoom Out",
            .shortcut_text = "-",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_MINUS },
                .{ .key = c.SDLK_KP_MINUS },
            },
        },
        .reset_zoom => .{
            .name = "Reset Zoom & Pan",
            .shortcut_text = "R / 0",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_R },
                .{ .key = c.SDLK_0 },
                .{ .key = c.SDLK_KP_0 },
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
                .{ .key = c.SDLK_RIGHTBRACKET },
            },
        },
        .rotate_ccw => .{
            .name = "Rotate Counter-Clockwise (90°)",
            .shortcut_text = "[",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_LEFTBRACKET },
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
                .{ .key = c.SDLK_P },
            },
        },
        .decrease_brightness => .{
            .name = "Decrease Brightness (-10%)",
            .shortcut_text = "O",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_O },
            },
        },
        .increase_contrast => .{
            .name = "Increase Contrast (+10%)",
            .shortcut_text = "L",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_L },
            },
        },
        .decrease_contrast => .{
            .name = "Decrease Contrast (-10%)",
            .shortcut_text = "K",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_K },
            },
        },
        .reset_adjustments => .{
            .name = "Reset Brightness & Contrast",
            .shortcut_text = "Shift+R",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_R, .mod = c.SDL_KMOD_SHIFT },
            },
        },
        .set_brightness_value => .{
            .name = "Set Brightness (Type Value)...",
            .shortcut_text = "Shift+B",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_B, .mod = c.SDL_KMOD_SHIFT },
            },
        },
        .set_contrast_value => .{
            .name = "Set Contrast (Type Value)...",
            .shortcut_text = "Shift+C",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_C, .mod = c.SDL_KMOD_SHIFT },
            },
        },
        .go_to_image => .{
            .name = "Go to Image...",
            .shortcut_text = "Shift+G",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_G, .mod = c.SDL_KMOD_SHIFT },
            },
        },
        .open_action_palette => .{
            .name = "Search Actions (Command Palette)",
            .shortcut_text = "F1 / Ctrl+Shift+P",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = c.SDLK_F1 },
                .{ .key = c.SDLK_P, .mod = c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT },
                .{ .key = c.SDLK_P, .mod = c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT },
            },
        },
    };
}

pub const app_actions = std.enums.values(AppActionId);

pub const FlatShortcut = struct {
    key: c.SDL_Keycode,
    mod: c.SDL_Keymod,
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
            self.palette.show = true;
            self.palette.active_type = .files;
            self.palette.query.clearRetainingCapacity();
            self.palette.selected_idx = self.current_index orelse 0;
            self.palette.selection_dirty = true;
            try self.rebuildPaletteMatches();
            startTextInput(self.window);
        },
        .toggle_debug_mode => clay.setDebugModeEnabled(!clay.isDebugModeEnabled()),
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
            self.zoom_factor = std.math.clamp(self.zoom_factor + 0.5, 0.1, 10.0);
            self.pan_x *= (self.zoom_factor / old_zoom);
            self.pan_y *= (self.zoom_factor / old_zoom);
        },
        .zoom_out => {
            const old_zoom = self.zoom_factor;
            self.zoom_factor = std.math.clamp(self.zoom_factor - 0.5, 0.1, 10.0);
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
            self.rotation_angle = 0.0;
            if (self.current_index) |idx| {
                if (idx < self.image_list.items.len) {
                    const path = self.image_list.items[idx];
                    try self.rotation_map.put(path, self.rotation_angle);
                }
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
            self.palette.show = true;
            self.palette.active_type = .set_brightness;
            self.palette.query.clearRetainingCapacity();
            self.palette.selected_idx = 0;
            self.palette.selection_dirty = true;
            startTextInput(self.window);
        },
        .set_contrast_value => {
            self.palette.show = true;
            self.palette.active_type = .set_contrast;
            self.palette.query.clearRetainingCapacity();
            self.palette.selected_idx = 0;
            self.palette.selection_dirty = true;
            startTextInput(self.window);
        },
        .go_to_image => {
            self.palette.show = true;
            self.palette.active_type = .go_to_image;
            self.palette.query.clearRetainingCapacity();
            self.palette.selected_idx = 0;
            self.palette.selection_dirty = true;
            startTextInput(self.window);
        },
        .open_action_palette => {
            self.palette.show = true;
            self.palette.active_type = .actions;
            self.palette.query.clearRetainingCapacity();
            self.palette.selected_idx = 0;
            self.palette.selection_dirty = true;
            try self.rebuildActionMatches();
            startTextInput(self.window);
        },
    }
}
