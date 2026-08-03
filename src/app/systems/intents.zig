const std = @import("std");
const sdl = @import("sdl");
const clay = @import("zclay");
const state = @import("state");
const app_state = @import("../state.zig");
const palette_module = @import("../core/palette.zig");
const intents = @import("intents");
const FrameContext = @import("root.zig").FrameContext;
const Key = state.Key;
const KeyModifiers = state.KeyModifiers;
const AppState = app_state.AppState;
const startTextInput = app_state.startTextInput;

/// Central intent dispatcher. Maps an AppIntent variant to application state mutations
/// and marks the application state dirty for re-rendering.
fn executeIntent(self: *AppState, intent: intents.AppIntent) !void {
    switch (intent) {
        .set_zoom => |factor| self.setZoom(factor),
        .zoom_in => {
            const old_zoom = self.viewer.viewport.zoom_factor;
            self.viewer.viewport.zoom_factor = self.clampZoomFactor(old_zoom.get() + 0.5);
            const ratio = old_zoom.ratioTo(self.viewer.viewport.zoom_factor);
            self.viewer.viewport.pan_x *= ratio;
            self.viewer.viewport.pan_y *= ratio;
        },
        .zoom_out => {
            const old_zoom = self.viewer.viewport.zoom_factor;
            self.viewer.viewport.zoom_factor = self.clampZoomFactor(old_zoom.get() - 0.5);
            const ratio = old_zoom.ratioTo(self.viewer.viewport.zoom_factor);
            self.viewer.viewport.pan_x *= ratio;
            self.viewer.viewport.pan_y *= ratio;
        },
        .set_pan => |p| self.setPan(p.x, p.y),
        .pan_by => |p| {
            self.viewer.viewport.pan_x += p.dx;
            self.viewer.viewport.pan_y += p.dy;
        },
        .reset_zoom => self.resetZoomPan(),
        .set_scale => |mode| {
            self.viewer.viewport.fit_mode = mode;
            self.resetZoomPan();
        },
        .set_filter => |mode| self.viewer.viewport.scale_filter = mode,
        .set_brightness => |val| self.setAdjustments(val, self.viewer.viewport.contrast),
        .increase_brightness => self.viewer.viewport.brightness = std.math.clamp(self.viewer.viewport.brightness + 0.1, -1.0, 1.0),
        .decrease_brightness => self.viewer.viewport.brightness = std.math.clamp(self.viewer.viewport.brightness - 0.1, -1.0, 1.0),
        .set_contrast => |val| self.setAdjustments(self.viewer.viewport.brightness, val),
        .increase_contrast => self.viewer.viewport.contrast = std.math.clamp(self.viewer.viewport.contrast + 0.1, 0.0, 5.0),
        .decrease_contrast => self.viewer.viewport.contrast = std.math.clamp(self.viewer.viewport.contrast - 0.1, 0.0, 5.0),
        .reset_adjustments => self.setAdjustments(0.0, 1.0),
        .rotate_cw => {
            var val = self.viewer.viewport.rotation_angle + 90.0;
            if (val >= 360.0) val -= 360.0;
            self.viewer.viewport.rotation_angle = val;
            if (self.viewer.navigation.getCurrentImagePath()) |path| {
                try self.putRotation(path, self.viewer.viewport.rotation_angle);
            }
        },
        .rotate_ccw => {
            var val = self.viewer.viewport.rotation_angle - 90.0;
            if (val < 0.0) val += 360.0;
            self.viewer.viewport.rotation_angle = val;
            if (self.viewer.navigation.getCurrentImagePath()) |path| {
                try self.putRotation(path, self.viewer.viewport.rotation_angle);
            }
        },
        .reset_rotation => {
            if (self.viewer.navigation.getCurrentImagePath()) |path| {
                const exif_rot = self.readJpegExifOrientation(path) orelse 0.0;
                self.viewer.viewport.rotation_angle = exif_rot;
                try self.putRotation(path, self.viewer.viewport.rotation_angle);
            } else {
                self.viewer.viewport.rotation_angle = 0.0;
            }
        },

        .next_image => {
            self.resetZoomPan();
            try self.next();
        },
        .prev_image => {
            self.resetZoomPan();
            try self.prev();
        },
        .first_image => {
            if (self.viewer.navigation.goToIndex(0) != null) {
                self.resetZoomPan();
            }
        },
        .last_image => {
            if (self.viewer.navigation.image_list.items.len > 0) {
                _ = self.viewer.navigation.goToIndex(self.viewer.navigation.image_list.items.len - 1);
                self.resetZoomPan();
            }
        },
        .go_to_image => |idx| {
            if (self.viewer.navigation.goToIndex(idx) != null) {
                self.resetZoomPan();
            }
        },
        .set_palette => |p| {
            if (p.mode == .inactive) {
                self.setPaletteMode(.inactive);
            } else {
                if (p.mode == .directory_navigator and p.query != null) {
                    try palette_module.loadDirectoryEntries(&self.viewer.ui.palette, self.io, p.query.?);
                    self.setPaletteMode(.directory_navigator);
                } else {
                    try self.openPalette(p.mode);
                    if (p.query) |q| {
                        self.viewer.ui.palette.query.clearRetainingCapacity();
                        try self.viewer.ui.palette.query.appendSlice(self.allocator, q);
                        self.viewer.ui.palette.selected_idx = 0;
                        self.viewer.ui.palette.selection_dirty = true;
                        if (self.viewer.ui.palette.mode == .actions) {
                            try self.rebuildActionMatches();
                        } else if (self.viewer.ui.palette.mode == .files) {
                            try self.rebuildPaletteMatches();
                        }
                    }
                }
            }
        },
        .toggle_info => self.viewer.ui.overlays.show_info = !self.viewer.ui.overlays.show_info,
        .set_info => |val| self.viewer.ui.overlays.show_info = val,
        .toggle_stats => self.viewer.ui.overlays.show_stats = !self.viewer.ui.overlays.show_stats,
        .set_stats => |val| self.viewer.ui.overlays.show_stats = val,
        .toggle_fullscreen => {
            switch (self.viewer.display) {
                .headless => {},
                .windowed => |*win| {
                    win.is_fullscreen = !win.is_fullscreen;
                    win.handle.setFullscreen(win.is_fullscreen) catch |err| std.log.err("setFullscreen failed: {}", .{err});
                },
            }
        },
        .set_fullscreen => |val| {
            switch (self.viewer.display) {
                .headless => {},
                .windowed => |*win| {
                    win.is_fullscreen = val;
                    win.handle.setFullscreen(val) catch |err| std.log.err("setFullscreen failed: {}", .{err});
                },
            }
        },
        .toggle_debug_mode => clay.setDebugModeEnabled(!clay.isDebugModeEnabled()),
        .set_debug_mode => |val| clay.setDebugModeEnabled(val),
        .toggle_debug_thumb => try self.setDebugShowThumb(!self.viewer.ui.overlays.debug_show_thumb),
        .set_debug_thumb => |val| try self.setDebugShowThumb(val),
        .start_slideshow => try self.openPalette(.set_slideshow_interval),
        .stop_slideshow => self.viewer.navigation.slideshow = .inactive,
        .quit => self.requestQuit(),
    }
}

/// System Pass: Execute queued discrete intents
pub fn sysExecuteIntents(ctx: FrameContext) !void {
    const self = ctx.state;
    if (self.pending_intents.items.len == 0) return;
    for (self.pending_intents.items) |intent| {
        try executeIntent(self, intent);
    }
    self.clearIntents();
}

test "palette_action_items metadata" {
    const nav_item = state.palette_action_items[6];
    try std.testing.expectEqualStrings("Navigate Directories...", nav_item.name);
    try std.testing.expectEqualStrings("Ctrl+O", nav_item.shortcut_text);
    try std.testing.expect(nav_item.show_in_palette);
}
