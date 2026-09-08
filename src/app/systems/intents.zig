const app_state = @import("../state.zig");
const clay = @import("zclay");
const context = @import("context.zig");
const intents = @import("intents");
const sdl = @import("sdl");
const state = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;

/// Central intent dispatcher. Maps an AppIntent variant to domain state mutations.
fn executeIntent(self: *AppState, intent: intents.AppIntent) !void {
    const vp = &self.viewer.viewport;
    const nav = &self.viewer.navigation;
    const ui = &self.viewer.ui;

    switch (intent) {
        .open_path => |p| try self.openPath(p),
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
                const exif_rot = if (self.getCurrentEntry()) |e| e.orientation else (self.readJpegExifOrientation(path) orelse .normal);
                vp.rotation_angle = exif_rot.toDegrees();
                try self.putRotation(path, vp.rotation_angle);
            } else {
                vp.rotation_angle = 0.0;
            }
        },

        .next_image, .prev_image, .first_image, .last_image, .go_to_image => {
            const now = sdl.timer.getTicks();
            const elapsed = now -| nav.last_nav_time_ms;
            if (nav.image_list.items.len > 0 and nav.last_nav_time_ms > 0 and elapsed < 200) {
                if (!ui.overlays.show_title) {
                    ui.title_auto_hide_timeout_ms = now + 1500;
                    const progress = self.viewer.animations.get(.title_overlay);
                    const dur = @max(state.DURATION_TITLE_OVERLAY_OPEN_MS * (1.0 - progress), 30.0);
                    self.viewer.animations.start(.title_overlay, 1.0, dur, .ease_out_quad);
                }
            }
            vp.reset();
            _ = switch (intent) {
                .next_image => if (nav.manga_mode) nav.prevIndex() else nav.nextIndex(),
                .prev_image => if (nav.manga_mode) nav.nextIndex() else nav.prevIndex(),
                .first_image => blk: {
                    const res = nav.goToIndex(0);
                    nav.direction = .forward;
                    break :blk res;
                },
                .last_image => blk: {
                    const res = nav.goToIndex(if (nav.image_list.items.len > 0) nav.image_list.items.len - 1 else 0);
                    nav.direction = .backward;
                    break :blk res;
                },
                .go_to_image => |idx| nav.goToIndex(idx),
                else => unreachable,
            };
            self.viewer.animations.setImmediate(.thumb_crossfade, 1.0);
        },
        .set_palette => |p| {
            if (p.mode == .inactive) {
                self.closePaletteImmediately();
            } else {
                if (p.mode == .directory_navigator and p.query != null) {
                    try self.loadPaletteDirectory(p.query.?);
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
        .toggle_title => {
            ui.overlays.show_title = !ui.overlays.show_title;
            ui.title_auto_hide_timeout_ms = 0;
            const target: f32 = if (ui.overlays.show_title) 1.0 else 0.0;
            const progress = self.viewer.animations.get(.title_overlay);
            const dur: f32 = if (ui.overlays.show_title)
                @max(state.DURATION_TITLE_OVERLAY_OPEN_MS * (1.0 - progress), 30.0)
            else
                @max(state.DURATION_TITLE_OVERLAY_CLOSE_MS * progress, 30.0);
            self.viewer.animations.start(.title_overlay, target, dur, .ease_out_quad);
        },
        .set_title => |val| {
            ui.overlays.show_title = val;
            ui.title_auto_hide_timeout_ms = 0;
            const target: f32 = if (val) 1.0 else 0.0;
            const progress = self.viewer.animations.get(.title_overlay);
            const dur: f32 = if (val)
                @max(state.DURATION_TITLE_OVERLAY_OPEN_MS * (1.0 - progress), 30.0)
            else
                @max(state.DURATION_TITLE_OVERLAY_CLOSE_MS * progress, 30.0);
            self.viewer.animations.start(.title_overlay, target, dur, .ease_out_quad);
        },
        .toggle_blur => ui.overlays.enable_blur = !ui.overlays.enable_blur,
        .set_blur => |val| ui.overlays.enable_blur = val,
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
        .toggle_debug_thumb => {
            ui.overlays.debug_show_thumb = !ui.overlays.debug_show_thumb;
        },
        .set_debug_thumb => |val| {
            ui.overlays.debug_show_thumb = val;
        },
        .start_slideshow => try self.openPalette(.set_slideshow_interval),
        .stop_slideshow => nav.slideshow = .inactive,
        .toggle_manga_mode => nav.manga_mode = !nav.manga_mode,
        .set_manga_mode => |val| nav.manga_mode = val,
        .quit => self.viewer.running = false,
    }
}

/// System Pass: Dispatches all queued application intents in FIFO order to update domain and visual state,
/// clearing the intent buffer once execution completes.
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

test "Navigation intents cleanly advance image index" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try app_st.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "img1.png" } });
    try app_st.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "img2.png" } });
    try app_st.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "img3.png" } });
    app_st.viewer.navigation.current_index = 0;

    try executeIntent(&app_st, .next_image);
    try std.testing.expectEqual(@as(usize, 1), app_st.viewer.navigation.current_index.?);

    try executeIntent(&app_st, .next_image);
    try std.testing.expectEqual(@as(usize, 2), app_st.viewer.navigation.current_index.?);

    try executeIntent(&app_st, .prev_image);
    try std.testing.expectEqual(@as(usize, 1), app_st.viewer.navigation.current_index.?);
}

test "palette_action_items metadata" {
    const nav_item = state.palette_action_items[7];
    try std.testing.expectEqualStrings("Navigate Directories...", nav_item.name);
    try std.testing.expectEqualStrings("Ctrl+O", nav_item.shortcut_text);
    try std.testing.expect(nav_item.show_in_palette);
}

test "toggle_blur and set_blur intents" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var threaded = std.Threaded{};
    const io = threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // Default enable_blur should be true
    try testing.expect(app_st.viewer.ui.overlays.enable_blur);

    // Toggle blur off
    try executeIntent(&app_st, .toggle_blur);
    try testing.expect(!app_st.viewer.ui.overlays.enable_blur);

    // Toggle blur on
    try executeIntent(&app_st, .toggle_blur);
    try testing.expect(app_st.viewer.ui.overlays.enable_blur);

    // Explicit set_blur
    try executeIntent(&app_st, .{ .set_blur = false });
    try testing.expect(!app_st.viewer.ui.overlays.enable_blur);

    try executeIntent(&app_st, .{ .set_blur = true });
    try testing.expect(app_st.viewer.ui.overlays.enable_blur);
}

test "rotate_cw, rotate_ccw, and reset_rotation intents" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var threaded = std.Threaded{};
    const io = threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const media_item = state.MediaEntry{
        .filesystem = .{ .path = "Capture/20191103-Emiray Natural Light-0002.RAF" },
    };
    try app_st.viewer.navigation.image_list.append(allocator, media_item);
    app_st.viewer.navigation.current_index = 0;

    const key = app_st.cache.activeKey(0);
    try app_st.cache.appendWithKey(allocator, key, .{
        .status = .{ .decoding = .{} },
        .orientation = .rotate_270,
    });

    // Rotate CW
    try executeIntent(&app_st, .rotate_cw);
    try testing.expectEqual(@as(f32, 90.0), app_st.viewer.viewport.rotation_angle);

    // Rotate CCW
    try executeIntent(&app_st, .rotate_ccw);
    try testing.expectEqual(@as(f32, 0.0), app_st.viewer.viewport.rotation_angle);

    // Reset rotation should restore entry orientation (270 degrees)
    try executeIntent(&app_st, .reset_rotation);
    try testing.expectEqual(@as(f32, 270.0), app_st.viewer.viewport.rotation_angle);
}

test "toggle_title and set_title intents" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var threaded = std.Threaded{};
    const io = threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // Default show_title should be false
    try testing.expect(!app_st.viewer.ui.overlays.show_title);
    try testing.expectEqual(@as(f32, 0.0), app_st.viewer.animations.get(.title_overlay));

    // Toggle title on
    try executeIntent(&app_st, .toggle_title);
    try testing.expect(app_st.viewer.ui.overlays.show_title);
    try testing.expect(app_st.viewer.animations.isActive(.title_overlay));
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(@as(f32, 1.0), app_st.viewer.animations.get(.title_overlay), 0.001);

    // Toggle title off
    try executeIntent(&app_st, .toggle_title);
    try testing.expect(!app_st.viewer.ui.overlays.show_title);
    try testing.expect(app_st.viewer.animations.isActive(.title_overlay));
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(@as(f32, 0.0), app_st.viewer.animations.get(.title_overlay), 0.001);

    // Explicit set_title
    try executeIntent(&app_st, .{ .set_title = true });
    try testing.expect(app_st.viewer.ui.overlays.show_title);
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(@as(f32, 1.0), app_st.viewer.animations.get(.title_overlay), 0.001);

    try executeIntent(&app_st, .{ .set_title = false });
    try testing.expect(!app_st.viewer.ui.overlays.show_title);
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(@as(f32, 0.0), app_st.viewer.animations.get(.title_overlay), 0.001);
}

test "fast scrubbing triggers title overlay auto-hide" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var threaded = std.Threaded{};
    const io = threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const media_item = state.MediaEntry{
        .filesystem = .{ .path = "test.jpg" },
    };
    try app_st.viewer.navigation.image_list.append(allocator, media_item);
    try app_st.viewer.navigation.image_list.append(allocator, media_item);
    app_st.viewer.navigation.current_index = 0;

    // Simulate recent navigation within 200ms
    const now = sdl.timer.getTicks();
    app_st.viewer.navigation.last_nav_time_ms = now -| 50;

    try executeIntent(&app_st, .next_image);

    // Should have triggered title auto-hide timeout and started animation
    try testing.expect(app_st.viewer.ui.title_auto_hide_timeout_ms >= now + 1400);
    try testing.expect(app_st.viewer.animations.isActive(.title_overlay));
}
