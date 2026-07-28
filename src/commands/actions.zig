const std = @import("std");
const clay = @import("zclay");
const app_state = @import("app").state;
const app_types = @import("app").types;
const Key = app_types.Key;
const KeyModifiers = app_types.KeyModifiers;
const ViewerState = app_state.ViewerState;
const startTextInput = app_state.startTextInput;

pub const AppActionId = app_types.AppActionId;
pub const KeyboardShortcut = app_types.KeyboardShortcut;
pub const ActionMetadata = app_types.ActionMetadata;
pub const getActionMetadata = app_types.getActionMetadata;
pub const app_actions = app_types.app_actions;
pub const FlatShortcut = app_types.FlatShortcut;

pub const flat_shortcuts = app_types.flat_shortcuts;

pub fn triggerAction(self: *ViewerState, action_id: AppActionId) !void {
    switch (action_id) {
        .next_image => try self.next(),
        .prev_image => try self.prev(),
        .toggle_info => self.overlays.show_info = !self.overlays.show_info,
        .toggle_stats => self.overlays.show_stats = !self.overlays.show_stats,
        .toggle_fullscreen => {
            switch (self.display) {
                .headless => {},
                .windowed => |*win| {
                    win.is_fullscreen = !win.is_fullscreen;
                    win.handle.setFullscreen(win.is_fullscreen) catch |err| std.log.err("setFullscreen failed: {}", .{err});
                },
            }
        },
        .open_file_finder => {
            try self.openPalette(.files);
        },
        .open_directory_navigator => {
            try self.openPalette(.directory_navigator);
        },
        .toggle_debug_mode => clay.setDebugModeEnabled(!clay.isDebugModeEnabled()),
        .toggle_debug_thumb => try self.setDebugShowThumb(!self.overlays.debug_show_thumb),
        .exit => {
            switch (self.display) {
                .headless => self.running = false,
                .windowed => |*win| {
                    if (win.is_fullscreen) {
                        win.is_fullscreen = false;
                        win.handle.setFullscreen(false) catch |err| std.log.err("setFullscreen failed: {}", .{err});
                    } else {
                        self.running = false;
                    }
                },
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
            const old_zoom = self.viewport.zoom_factor;
            self.viewport.zoom_factor = self.clampZoomFactor(self.viewport.zoom_factor + 0.5);
            self.viewport.pan_x *= (self.viewport.zoom_factor / old_zoom);
            self.viewport.pan_y *= (self.viewport.zoom_factor / old_zoom);
        },
        .zoom_out => {
            const old_zoom = self.viewport.zoom_factor;
            self.viewport.zoom_factor = self.clampZoomFactor(self.viewport.zoom_factor - 0.5);
            self.viewport.pan_x *= (self.viewport.zoom_factor / old_zoom);
            self.viewport.pan_y *= (self.viewport.zoom_factor / old_zoom);
        },
        .reset_zoom => {
            self.resetZoomPan();
        },
        .set_scale_none => {
            self.viewport.scale_mode = .none;
            self.resetZoomPan();
        },
        .set_scale_shrink => {
            self.viewport.scale_mode = .shrink;
            self.resetZoomPan();
        },
        .set_scale_full => {
            self.viewport.scale_mode = .full;
            self.resetZoomPan();
        },
        .set_scale_crop => {
            self.viewport.scale_mode = .crop;
            self.resetZoomPan();
        },
        .rotate_cw => {
            var val = self.viewport.rotation_angle + 90.0;
            if (val >= 360.0) val -= 360.0;
            self.viewport.rotation_angle = val;
            if (self.current_index) |idx| {
                if (idx < self.image_list.items.len) {
                    const path = self.image_list.items[idx];
                    try self.rotation_map.put(path, self.viewport.rotation_angle);
                }
            }
        },
        .rotate_ccw => {
            var val = self.viewport.rotation_angle - 90.0;
            if (val < 0.0) val += 360.0;
            self.viewport.rotation_angle = val;
            if (self.current_index) |idx| {
                if (idx < self.image_list.items.len) {
                    const path = self.image_list.items[idx];
                    try self.rotation_map.put(path, self.viewport.rotation_angle);
                }
            }
        },
        .reset_rotation => {
            if (self.current_index) |idx| {
                if (idx < self.image_list.items.len) {
                    const path = self.image_list.items[idx];
                    const exif_rot = self.readJpegExifOrientation(path) orelse 0.0;
                    self.viewport.rotation_angle = exif_rot;
                    try self.rotation_map.put(path, self.viewport.rotation_angle);
                } else {
                    self.viewport.rotation_angle = 0.0;
                }
            } else {
                self.viewport.rotation_angle = 0.0;
            }
        },
        .set_filter_nearest => {
            self.adjustments.texture_scale_mode = .nearest;
            self.applyTextureScaleMode();
        },
        .set_filter_linear => {
            self.adjustments.texture_scale_mode = .linear;
            self.applyTextureScaleMode();
        },
        .set_filter_pixel_art => {
            self.adjustments.texture_scale_mode = .pixel_art;
            self.applyTextureScaleMode();
        },
        .set_filter_mitchell => {
            self.adjustments.texture_scale_mode = .mitchell;
            self.applyTextureScaleMode();
        },
        .set_filter_lanczos3 => {
            self.adjustments.texture_scale_mode = .lanczos3;
            self.applyTextureScaleMode();
        },
        .increase_brightness => {
            self.adjustments.brightness = std.math.clamp(self.adjustments.brightness + 0.1, -1.0, 1.0);
            self.adjustments.dirty = true;
        },
        .decrease_brightness => {
            self.adjustments.brightness = std.math.clamp(self.adjustments.brightness - 0.1, -1.0, 1.0);
            self.adjustments.dirty = true;
        },
        .increase_contrast => {
            self.adjustments.contrast = std.math.clamp(self.adjustments.contrast + 0.1, 0.0, 5.0);
            self.adjustments.dirty = true;
        },
        .decrease_contrast => {
            self.adjustments.contrast = std.math.clamp(self.adjustments.contrast - 0.1, 0.0, 5.0);
            self.adjustments.dirty = true;
        },
        .reset_adjustments => {
            self.adjustments.brightness = 0.0;
            self.adjustments.contrast = 1.0;
            self.adjustments.dirty = true;
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
        .start_slideshow => {
            try self.openPalette(.set_slideshow_interval);
        },
        .stop_slideshow => {
            self.slideshow = .inactive;
        },
    }
}

pub const AppAction = union(enum) {
    next_image,
    prev_image,
    toggle_info,
    toggle_stats,
    toggle_fullscreen,
    open_file_finder,
    open_directory_navigator,
    toggle_debug_mode,
    toggle_debug_thumb,
    exit,
    first_image,
    last_image,
    zoom_in,
    zoom_out,
    reset_zoom,
    set_scale: app_types.ScaleMode,
    rotate_cw,
    rotate_ccw,
    reset_rotation,
    set_filter: app_types.TextureScaleMode,
    increase_brightness,
    decrease_brightness,
    increase_contrast,
    decrease_contrast,
    reset_adjustments,
    set_brightness: f32,
    set_contrast: f32,
    go_to_image: usize,
    open_action_palette,
    start_slideshow,
    stop_slideshow,
    action_id: AppActionId,
};

pub fn executeAction(self: *ViewerState, action: AppAction) !void {
    switch (action) {
        .set_brightness => |val| self.setAdjustments(val, self.adjustments.contrast),
        .set_contrast => |val| self.setAdjustments(self.adjustments.brightness, val),
        .go_to_image => |idx| {
            if (self.image_list.items.len > 0) {
                self.current_index = @min(idx, self.image_list.items.len - 1);
                try self.updateCache();
            }
        },
        .set_scale => |mode| {
            self.viewport.scale_mode = mode;
            self.resetZoomPan();
        },
        .set_filter => |mode| {
            self.adjustments.texture_scale_mode = mode;
            self.applyTextureScaleMode();
        },
        .action_id => |id| try triggerAction(self, id),
        else => {
            if (std.meta.stringToEnum(AppActionId, @tagName(action))) |id| {
                try triggerAction(self, id);
            }
        },
    }
}

test "open_directory_navigator metadata" {
    const meta = getActionMetadata(.open_directory_navigator);
    try std.testing.expectEqualStrings("Navigate Directories...", meta.name);
    try std.testing.expectEqualStrings("Ctrl+O", meta.shortcut_text);
    try std.testing.expect(meta.show_in_palette);
    try std.testing.expectEqual(@as(usize, 1), meta.shortcuts.len);
    try std.testing.expectEqual(Key.char_o, meta.shortcuts[0].key);
    try std.testing.expect(meta.shortcuts[0].mod.ctrl);
}

test "start_slideshow metadata" {
    const meta = getActionMetadata(.start_slideshow);
    try std.testing.expectEqualStrings("Start Slide Show...", meta.name);
    try std.testing.expect(meta.show_in_palette);
}
