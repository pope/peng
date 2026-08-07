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

/// Central intent dispatcher. Maps an AppIntent variant to domain state mutations.
fn executeIntent(self: *AppState, intent: intents.AppIntent) !void {
    const vp = &self.viewer.viewport;
    const nav = &self.viewer.navigation;
    const ui = &self.viewer.ui;

    switch (intent) {
        .set_zoom => |factor| vp.zoom_factor = self.clampZoomFactor(factor),
        .zoom_in => {
            const old_zoom = vp.zoom_factor;
            vp.zoom_factor = self.clampZoomFactor(old_zoom.get() + 0.5);
            const ratio = old_zoom.ratioTo(vp.zoom_factor);
            vp.pan_x *= ratio;
            vp.pan_y *= ratio;
        },
        .zoom_out => {
            const old_zoom = vp.zoom_factor;
            vp.zoom_factor = self.clampZoomFactor(old_zoom.get() - 0.5);
            const ratio = old_zoom.ratioTo(vp.zoom_factor);
            vp.pan_x *= ratio;
            vp.pan_y *= ratio;
        },
        .set_pan => |p| vp.setPan(p.x, p.y),
        .pan_by => |p| vp.panBy(p.dx, p.dy),
        .reset_zoom => vp.reset(),
        .set_scale => |mode| {
            vp.fit_mode = mode;
            vp.reset();
        },
        .set_filter => |mode| vp.scale_filter = mode,
        .set_brightness => |val| vp.setAdjustments(val, vp.contrast),
        .increase_brightness => vp.adjustBrightness(0.1),
        .decrease_brightness => vp.adjustBrightness(-0.1),
        .set_contrast => |val| vp.setAdjustments(vp.brightness, val),
        .increase_contrast => vp.adjustContrast(0.1),
        .decrease_contrast => vp.adjustContrast(-0.1),
        .reset_adjustments => vp.setAdjustments(0.0, 1.0),
        .rotate_cw => {
            vp.rotateCw();
            if (nav.getCurrentImageEntry()) |entry| {
                try self.putRotation(entry.getPath(), vp.rotation_angle);
            }
        },
        .rotate_ccw => {
            vp.rotateCcw();
            if (nav.getCurrentImageEntry()) |entry| {
                try self.putRotation(entry.getPath(), vp.rotation_angle);
            }
        },
        .reset_rotation => {
            if (nav.getCurrentImageEntry()) |entry| {
                const path = entry.getPath();
                const exif_rot = self.readJpegExifOrientation(path) orelse 0.0;
                vp.rotation_angle = exif_rot;
                try self.putRotation(path, vp.rotation_angle);
            } else {
                vp.rotation_angle = 0.0;
            }
        },

        .next_image => {
            vp.reset();
            if (nav.manga_mode) {
                _ = nav.prevIndex();
            } else {
                _ = nav.nextIndex();
            }
        },
        .prev_image => {
            vp.reset();
            if (nav.manga_mode) {
                _ = nav.nextIndex();
            } else {
                _ = nav.prevIndex();
            }
        },
        .first_image => {
            if (nav.goToIndex(0) != null) {
                vp.reset();
            }
        },
        .last_image => {
            if (nav.image_list.items.len > 0) {
                _ = nav.goToIndex(nav.image_list.items.len - 1);
                vp.reset();
            }
        },
        .go_to_image => |idx| {
            if (nav.goToIndex(idx) != null) {
                vp.reset();
            }
        },
        .set_palette => |p| {
            if (p.mode == .inactive) {
                ui.palette.mode = .inactive;
            } else {
                if (p.mode == .directory_navigator and p.query != null) {
                    try palette_module.loadDirectoryEntries(&ui.palette, self.io, p.query.?);
                    ui.palette.mode = .directory_navigator;
                } else {
                    try self.openPalette(p.mode);
                    if (p.query) |q| {
                        ui.palette.query.clearRetainingCapacity();
                        try ui.palette.query.appendSlice(self.allocator, q);
                        ui.palette.selected_idx = 0;
                        ui.palette.selection_dirty = true;
                        if (ui.palette.mode == .actions) {
                            try self.rebuildActionMatches();
                        } else if (ui.palette.mode == .files) {
                            try self.rebuildPaletteMatches();
                        }
                    }
                }
            }
        },
        .toggle_info => ui.overlays.show_info = !ui.overlays.show_info,
        .set_info => |val| ui.overlays.show_info = val,
        .toggle_stats => ui.overlays.show_stats = !ui.overlays.show_stats,
        .set_stats => |val| ui.overlays.show_stats = val,
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
        .toggle_debug_thumb => try self.setDebugShowThumb(!ui.overlays.debug_show_thumb),
        .set_debug_thumb => |val| try self.setDebugShowThumb(val),
        .start_slideshow => try self.openPalette(.set_slideshow_interval),
        .stop_slideshow => nav.slideshow = .inactive,
        .toggle_manga_mode => nav.manga_mode = !nav.manga_mode,
        .set_manga_mode => |val| nav.manga_mode = val,
        .quit => self.viewer.running = false,
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

test "Manga Mode toggles Right-to-Left image navigation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try app_st.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "page1.png" } });
    try app_st.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "page2.png" } });
    try app_st.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "page3.png" } });
    app_st.viewer.navigation.current_index = 0;

    // Normal mode: next_image moves 0 -> 1
    try executeIntent(&app_st, .next_image);
    try std.testing.expectEqual(@as(usize, 1), app_st.viewer.navigation.current_index.?);

    // Toggle Manga Mode
    try executeIntent(&app_st, .toggle_manga_mode);
    try std.testing.expect(app_st.viewer.navigation.manga_mode);

    // Manga mode (RTL): next_image moves 1 -> 0
    try executeIntent(&app_st, .next_image);
    try std.testing.expectEqual(@as(usize, 0), app_st.viewer.navigation.current_index.?);

    // Manga mode (RTL): prev_image moves 0 -> 1
    try executeIntent(&app_st, .prev_image);
    try std.testing.expectEqual(@as(usize, 1), app_st.viewer.navigation.current_index.?);
}

test "palette_action_items metadata" {
    const nav_item = state.palette_action_items[7];
    try std.testing.expectEqualStrings("Navigate Directories...", nav_item.name);
    try std.testing.expectEqualStrings("Ctrl+O", nav_item.shortcut_text);
    try std.testing.expect(nav_item.show_in_palette);
}
