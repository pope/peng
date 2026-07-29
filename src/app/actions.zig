const std = @import("std");
const clay = @import("zclay");
const app_state = @import("state.zig");
const intents = @import("intents");
const app_types = @import("types.zig");
const ipc = @import("ipc.zig");
const Key = app_types.Key;
const KeyModifiers = app_types.KeyModifiers;
const ViewerState = app_state.ViewerState;
const startTextInput = app_state.startTextInput;

pub fn executeIntent(self: *ViewerState, intent: intents.AppIntent) !void {
    switch (intent) {
        .set_zoom => |factor| self.setZoom(factor),
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
        .set_pan => |p| self.setPan(p.x, p.y),
        .reset_zoom => self.resetZoomPan(),
        .set_scale => |mode| {
            self.viewport.fit_mode = mode;
            self.resetZoomPan();
        },
        .set_filter => |mode| {
            self.viewport.texture_scale_mode = mode;
            self.applyTextureScaleMode();
        },
        .set_brightness => |val| self.setAdjustments(val, self.viewport.contrast),
        .increase_brightness => self.viewport.brightness = std.math.clamp(self.viewport.brightness + 0.1, -1.0, 1.0),
        .decrease_brightness => self.viewport.brightness = std.math.clamp(self.viewport.brightness - 0.1, -1.0, 1.0),
        .set_contrast => |val| self.setAdjustments(self.viewport.brightness, val),
        .increase_contrast => self.viewport.contrast = std.math.clamp(self.viewport.contrast + 0.1, 0.0, 5.0),
        .decrease_contrast => self.viewport.contrast = std.math.clamp(self.viewport.contrast - 0.1, 0.0, 5.0),
        .reset_adjustments => self.setAdjustments(0.0, 1.0),
        .rotate_cw => {
            var val = self.viewport.rotation_angle + 90.0;
            if (val >= 360.0) val -= 360.0;
            self.viewport.rotation_angle = val;
            if (self.navigation.getCurrentImagePath()) |path| {
                try self.rotation_map.put(path, self.viewport.rotation_angle);
            }
        },
        .rotate_ccw => {
            var val = self.viewport.rotation_angle - 90.0;
            if (val < 0.0) val += 360.0;
            self.viewport.rotation_angle = val;
            if (self.navigation.getCurrentImagePath()) |path| {
                try self.rotation_map.put(path, self.viewport.rotation_angle);
            }
        },
        .reset_rotation => {
            if (self.navigation.getCurrentImagePath()) |path| {
                const exif_rot = self.readJpegExifOrientation(path) orelse 0.0;
                self.viewport.rotation_angle = exif_rot;
                try self.rotation_map.put(path, self.viewport.rotation_angle);
            } else {
                self.viewport.rotation_angle = 0.0;
            }
        },
        .next_image => try self.next(),
        .prev_image => try self.prev(),
        .first_image => {
            if (self.navigation.goToIndex(0) != null) {
                try self.updateCache();
            }
        },
        .last_image => {
            if (self.navigation.image_list.items.len > 0) {
                _ = self.navigation.goToIndex(self.navigation.image_list.items.len - 1);
                try self.updateCache();
            }
        },
        .go_to_image => |idx| {
            if (self.navigation.goToIndex(idx) != null) {
                try self.updateCache();
            }
        },
        .set_palette => |p| {
            if (p.mode == .inactive) {
                self.setPaletteMode(.inactive);
            } else {
                try self.openPalette(p.mode);
                if (p.query) |q| {
                    self.ui.palette.query.clearRetainingCapacity();
                    try self.ui.palette.query.appendSlice(self.allocator, q);
                    self.ui.palette.selected_idx = 0;
                    self.ui.palette.selection_dirty = true;
                    if (self.ui.palette.mode == .actions) {
                        try self.rebuildActionMatches();
                    } else if (self.ui.palette.mode == .files) {
                        try self.rebuildPaletteMatches();
                    }
                }
            }
        },
        .toggle_info => self.ui.overlays.show_info = !self.ui.overlays.show_info,
        .toggle_stats => self.ui.overlays.show_stats = !self.ui.overlays.show_stats,
        .toggle_fullscreen => {
            switch (self.display) {
                .headless => {},
                .windowed => |*win| {
                    win.is_fullscreen = !win.is_fullscreen;
                    win.handle.setFullscreen(win.is_fullscreen) catch |err| std.log.err("setFullscreen failed: {}", .{err});
                },
            }
        },
        .toggle_debug_mode => clay.setDebugModeEnabled(!clay.isDebugModeEnabled()),
        .toggle_debug_thumb => try self.setDebugShowThumb(!self.ui.overlays.debug_show_thumb),
        .start_slideshow => try self.openPalette(.set_slideshow_interval),
        .stop_slideshow => self.navigation.slideshow = .inactive,
        .quit => self.requestQuit(),
    }
}

pub fn handleIpcCommand(self: *ViewerState, command: []const u8, stream: std.Io.net.Stream) !void {
    const parsed = try ipc.IpcCommand.parse(command);
    switch (parsed) {
        .wait_load => {
            const sdl = @import("sdl");
            var attempts: u32 = 0;
            while (attempts < 1000) : (attempts += 1) {
                _ = self.processBackgroundEvents();
                self.prepareCacheTextures();
                if (self.getCurrentEntry()) |entry| {
                    if (entry.status != .decoding) break;
                }
                sdl.timer.delay(10);
            }
            try ipc.respondOk(self.io, stream);
        },
        .adjust => |adj| {
            try executeIntent(self, .{ .set_brightness = adj.brightness });
            try executeIntent(self, .{ .set_contrast = adj.contrast });
            try ipc.respondOk(self.io, stream);
        },
        else => {
            if (parsed.toIntent(self)) |intent| {
                try executeIntent(self, intent);
            }
            try ipc.respondOk(self.io, stream);
        },
    }
}

test "palette_action_items metadata" {
    const nav_item = app_types.palette_action_items[6];
    try std.testing.expectEqualStrings("Navigate Directories...", nav_item.name);
    try std.testing.expectEqualStrings("Ctrl+d", nav_item.shortcut_text);
    try std.testing.expect(nav_item.show_in_palette);
}
