const app_state = @import("../state.zig");
const clay = @import("zclay");
const context = @import("context.zig");
const intents = @import("intents");
const sdl = @import("sdl");
const state = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;

fn showCustomSnackbar(self: *AppState, msg: []const u8) void {
    if (!self.viewer.ui.snackbar.enabled) return;
    const now = sdl.timer.getTicks();
    self.viewer.ui.snackbar.show(msg, now + 1500);
    const progress = self.viewer.animations.get(.snackbar);
    const dur = @max(state.DURATION_SNACKBAR_OPEN_MS * (1.0 - progress), 30.0);
    self.viewer.animations.start(.snackbar, 1.0, dur, .ease_out_quad);
}

/// Central intent dispatcher. Maps an AppIntent variant to domain state mutations.
fn executeIntent(self: *AppState, intent: intents.AppIntent) !void {
    const vp = &self.viewer.viewport;
    const nav = &self.viewer.navigation;
    const ui = &self.viewer.ui;

    switch (intent) {
        .open_path => |p| try self.openPath(p),
        .set_zoom => |factor| {
            vp.mode = .manual;
            vp.zoom_factor = state.clampZoomFactor(factor);
        },
        .zoom_in => {
            vp.mode = .manual;
            const old_zoom = vp.zoom_factor;
            var target = old_zoom.get() * 1.25;
            if (old_zoom.get() < 1.0 and target >= 1.0) {
                target = 1.0;
            }
            vp.zoom_factor = state.clampZoomFactor(target);
            const ratio = old_zoom.ratioTo(vp.zoom_factor);
            vp.pan_x *= ratio;
            vp.pan_y *= ratio;
        },
        .zoom_out => {
            vp.mode = .manual;
            const old_zoom = vp.zoom_factor;
            var target = old_zoom.get() / 1.25;
            if (old_zoom.get() > 1.0 and target <= 1.0) {
                target = 1.0;
            }
            vp.zoom_factor = state.clampZoomFactor(target);
            const ratio = old_zoom.ratioTo(vp.zoom_factor);
            vp.pan_x *= ratio;
            vp.pan_y *= ratio;
        },
        .set_pan => |p| vp.setPan(p.x, p.y),
        .pan_by => |p| vp.panBy(p.dx, p.dy),
        .reset_zoom => {
            vp.fit_mode = .full;
            vp.reset();
            vp.zoom_factor = state.UniversalZoom.init(self.getBaseScale());
        },
        .set_scale => |mode| {
            vp.fit_mode = mode;
            vp.reset();
            vp.zoom_factor = state.UniversalZoom.init(self.getBaseScale());
        },
        .cycle_scale_mode => {
            vp.fit_mode = switch (vp.fit_mode) {
                .shrink => .full,
                .full => .crop,
                .crop => .none,
                .none => .fit_width,
                .fit_width => .fit_height,
                .fit_height => .shrink,
            };
            vp.reset();
            vp.zoom_factor = state.UniversalZoom.init(self.getBaseScale());
        },
        .set_filter => |mode| vp.scale_filter = mode,
        .cycle_filter => {
            vp.scale_filter = switch (vp.scale_filter) {
                .nearest => .linear,
                .linear => .mitchell,
                .mitchell => .lanczos3,
                .lanczos3 => .fsr,
                .fsr => .tiny_cnn,
                .tiny_cnn => .pixel_art,
                .pixel_art => .nearest,
            };
        },
        .cycle_filter_prev => {
            vp.scale_filter = switch (vp.scale_filter) {
                .nearest => .pixel_art,
                .pixel_art => .tiny_cnn,
                .tiny_cnn => .fsr,
                .fsr => .lanczos3,
                .lanczos3 => .mitchell,
                .mitchell => .linear,
                .linear => .nearest,
            };
        },
        .adjust => |adj| switch (adj) {
            .set => |s| {
                vp.edits.set(s.param, s.value);
                vp.compare_original = false;
            },
            .step => |s| {
                const desc = state.getDescriptor(s.param);
                const dir_f: f32 = @floatFromInt(@intFromEnum(s.direction));
                const delta = desc.step * dir_f;
                vp.edits.set(s.param, vp.edits.get(s.param) + delta);
                vp.compare_original = false;
            },
            .batch_tone => |bt| {
                vp.edits.set(.highlights, bt.highlights);
                vp.edits.set(.shadows, bt.shadows);
                vp.edits.set(.whites, bt.whites);
                vp.edits.set(.blacks, bt.blacks);
                vp.compare_original = false;
            },
            .batch_color => |bc| {
                vp.edits.set(.temperature, bc.temperature);
                vp.edits.set(.tint, bc.tint);
                vp.edits.set(.vibrance, bc.vibrance);
                vp.edits.set(.saturation, bc.saturation);
                vp.compare_original = false;
            },
            .batch_presence => |bp| {
                vp.edits.set(.clarity, bp.clarity);
                vp.edits.set(.texture, bp.texture);
                vp.compare_original = false;
            },
            .reset_param => |p| {
                vp.edits.resetParam(p);
                vp.compare_original = false;
            },
            .reset_all => {
                vp.edits.reset();
                vp.compare_original = false;
            },
            .toggle_compare => vp.toggleCompare(),
            .set_compare => |val| {
                if (vp.hasAdjustments()) {
                    vp.compare_original = val;
                } else {
                    vp.compare_original = false;
                }
            },
        },

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
                const exif_rot = if (self.getCurrentEntry()) |e|
                    e.orientation
                else
                    (self.readJpegExifOrientation(path) orelse .normal);
                vp.rotation_angle = exif_rot.toDegrees();
                try self.putRotation(path, vp.rotation_angle);
            } else {
                vp.rotation_angle = 0.0;
            }
        },

        .next_image, .prev_image, .first_image, .last_image, .go_to_image => {
            const now = sdl.timer.getTicks();
            const elapsed = now -| nav.last_nav_time_ms;
            const should_show_auto_title = ui.overlays.auto_title and
                nav.count() > 0 and
                nav.last_nav_time_ms > 0 and
                elapsed < 200;
            if (should_show_auto_title) {
                if (!ui.overlays.title_display.isPinned()) {
                    ui.overlays.title_display = .{ .transient = .{ .timeout_ms = now + 1500 } };
                    const progress = self.viewer.animations.get(.title_overlay);
                    const dur = @max(state.DURATION_TITLE_OVERLAY_OPEN_MS * (1.0 - progress), 30.0);
                    self.viewer.animations.start(.title_overlay, 1.0, dur, .ease_out_quad);
                }
            }
            const is_slideshow = nav.isSlideshowActive();
            const old_index = nav.current_index;
            const old_rot = self.viewer.viewport.rotation_angle;
            const old_zoom = vp.zoom_factor.get();
            const old_pan_x = vp.pan_x;
            const old_pan_y = vp.pan_y;

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
                    const last_idx = if (nav.count() > 0)
                        nav.count() - 1
                    else
                        0;
                    const res = nav.goToIndex(last_idx);
                    nav.direction = .backward;
                    break :blk res;
                },
                .go_to_image => |idx| nav.goToIndex(idx),
                else => unreachable,
            };

            const changed_image = old_index != null and
                nav.current_index != null and
                old_index.? != nav.current_index.?;
            if (changed_image) {
                const old_entry_loaded = if (self.cache.get(self.cache.activeKey(old_index.?))) |e|
                    (e.status == .loaded_gpu or (self.gpu_device == null and e.status != .failed))
                else
                    self.gpu_device == null;
                const is_animating = self.viewer.animations.isActive(.image_crossfade);
                const should_crossfade = if (is_slideshow)
                    switch (nav.slideshow) {
                        .active => |s| s.interval_s >=
                            state.MIN_SLIDESHOW_DISSOLVE_INTERVAL_S and
                            old_entry_loaded,
                        .inactive => false,
                    }
                else
                    (nav.crossfade and elapsed >= 200 and !is_animating and old_entry_loaded);

                if (should_crossfade) {
                    self.viewer.image_transition = .{ .active = .{
                        .prev_index = old_index.?,
                        .prev_rotation = old_rot,
                        .prev_zoom = old_zoom,
                        .prev_pan_x = old_pan_x,
                        .prev_pan_y = old_pan_y,
                    } };
                    const is_ready = if (self.getCurrentEntry()) |e|
                        e.status == .loaded_gpu
                    else
                        false;
                    if (is_ready) {
                        self.viewer.animations.startFrom(
                            .image_crossfade,
                            0.0,
                            1.0,
                            state.DURATION_IMAGE_DISSOLVE_MS,
                            .ease_in_out_cubic,
                        );
                    } else {
                        self.viewer.animations.setImmediate(.image_crossfade, 0.0);
                    }
                } else {
                    self.viewer.image_transition = .none;
                    self.viewer.animations.setImmediate(.image_crossfade, 1.0);
                }
            } else {
                self.viewer.image_transition = .none;
                self.viewer.animations.setImmediate(.image_crossfade, 1.0);
            }

            self.viewer.animations.setImmediate(.thumb_crossfade, 1.0);
        },
        .refresh_directory => {
            if (nav.getCurrentImageEntry()) |entry| {
                try self.openPath(entry.getPath());
            } else if (nav.last_scanned_dir.items.len > 0) {
                try self.openPath(nav.last_scanned_dir.items);
            }
        },
        .mark_pick => {
            const old_idx = nav.current_index;
            _ = try nav.markCurrentPick(self.allocator);
            _ = nav.adjustIndexForVisibility();
            if (old_idx != nav.current_index) {
                vp.reset();
                self.viewer.image_transition = .none;
                self.viewer.animations.setImmediate(.image_crossfade, 1.0);
            }
        },
        .mark_reject => {
            const old_idx = nav.current_index;
            _ = try nav.markCurrentReject(self.allocator);
            _ = nav.adjustIndexForVisibility();
            if (old_idx != nav.current_index) {
                vp.reset();
                self.viewer.image_transition = .none;
                self.viewer.animations.setImmediate(.image_crossfade, 1.0);
            }
        },
        .unflag => {
            const old_idx = nav.current_index;
            _ = try nav.unflagCurrent(self.allocator);
            _ = nav.adjustIndexForVisibility();
            if (old_idx != nav.current_index) {
                vp.reset();
                self.viewer.image_transition = .none;
                self.viewer.animations.setImmediate(.image_crossfade, 1.0);
            }
        },
        .cycle_view_mode => {
            const old_idx = nav.current_index;
            _ = nav.cycleViewMode();
            if (old_idx != nav.current_index) {
                vp.reset();
                self.viewer.image_transition = .none;
                self.viewer.animations.setImmediate(.image_crossfade, 1.0);
            }
        },
        .set_view_mode => |mode| {
            const old_idx = nav.current_index;
            _ = nav.setViewMode(mode);
            if (old_idx != nav.current_index) {
                vp.reset();
                self.viewer.image_transition = .none;
                self.viewer.animations.setImmediate(.image_crossfade, 1.0);
            }
        },
        .toggle_raw_jpeg_stacking => {
            nav.stack_raw_jpeg = !nav.stack_raw_jpeg;
            const msg = if (nav.stack_raw_jpeg)
                "RAW+JPEG stacking enabled"
            else
                "RAW+JPEG stacking disabled";
            showCustomSnackbar(self, msg);
            _ = self.cache.advanceGeneration();
            if (nav.getCurrentImageEntry()) |entry| {
                try self.openPath(entry.getPath());
            } else if (nav.last_scanned_dir.items.len > 0) {
                try self.openPath(nav.last_scanned_dir.items);
            }
        },
        .set_raw_jpeg_stacking => |enable| {
            if (nav.stack_raw_jpeg != enable) {
                nav.stack_raw_jpeg = enable;
                const msg = if (enable)
                    "RAW+JPEG stacking enabled"
                else
                    "RAW+JPEG stacking disabled";
                showCustomSnackbar(self, msg);
                _ = self.cache.advanceGeneration();
                if (nav.getCurrentImageEntry()) |entry| {
                    try self.openPath(entry.getPath());
                } else if (nav.last_scanned_dir.items.len > 0) {
                    try self.openPath(nav.last_scanned_dir.items);
                }
            }
        },
        .toggle_pair_stream => {
            if (nav.current_index) |cur_idx| {
                if (nav.getCurrentImageEntry()) |entry_item| {
                    if (entry_item.isPair()) {
                        const key = self.cache.activeKey(cur_idx);
                        if (self.cache.get(key)) |entry| {
                            if (!entry.is_promoting and self.workers.canSpawnDecode()) {
                                const target: state.PairStreamTarget =
                                    if (entry.raw_metadata.isRaw())
                                        .standalone_jpeg
                                    else
                                        .raw_preview;
                                const msg = switch (target) {
                                    .standalone_jpeg => "Stream: Standalone JPEG",
                                    .raw_preview => "Stream: RAW Embedded Preview",
                                    .adaptive => "Stream: Adaptive",
                                };
                                showCustomSnackbar(self, msg);
                                entry.requested_target = target;
                            }
                        }
                    }
                }
            }
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
        .toggle_info => ui.overlays.info_panel.visible = !ui.overlays.info_panel.visible,
        .set_info => |val| ui.overlays.info_panel.visible = val,
        .toggle_stats => ui.overlays.stats_panel.visible = !ui.overlays.stats_panel.visible,
        .set_stats => |val| ui.overlays.stats_panel.visible = val,
        .toggle_edit_panel => {
            const new_vis = !ui.overlays.edit_panel.visible;
            ui.overlays.edit_panel.visible = new_vis;
            const target: f32 = if (new_vis) 1.0 else 0.0;
            const progress = self.viewer.animations.get(.edit_panel);
            const dur: f32 = if (new_vis)
                @max(state.DURATION_EDIT_PANEL_OPEN_MS * (1.0 - progress), 30.0)
            else
                @max(state.DURATION_EDIT_PANEL_CLOSE_MS * progress, 30.0);
            self.viewer.animations.start(
                .edit_panel,
                target,
                dur,
                if (new_vis) .ease_out_cubic else .ease_out_quad,
            );
        },
        .set_edit_panel => |val| {
            ui.overlays.edit_panel.visible = val;
            const target: f32 = if (val) 1.0 else 0.0;
            const progress = self.viewer.animations.get(.edit_panel);
            const dur: f32 = if (val)
                @max(state.DURATION_EDIT_PANEL_OPEN_MS * (1.0 - progress), 30.0)
            else
                @max(state.DURATION_EDIT_PANEL_CLOSE_MS * progress, 30.0);
            self.viewer.animations.start(
                .edit_panel,
                target,
                dur,
                if (val) .ease_out_cubic else .ease_out_quad,
            );
        },
        .dismiss_overlays => {
            _ = ui.overlays.dismissFloatingPanels();
            if (ui.overlays.edit_panel.visible) {
                ui.overlays.edit_panel.visible = false;
                const progress = self.viewer.animations.get(.edit_panel);
                const close_dur = state.DURATION_EDIT_PANEL_CLOSE_MS;
                const dur = @max(close_dur * progress, 30.0);
                self.viewer.animations.start(
                    .edit_panel,
                    0.0,
                    dur,
                    .ease_out_quad,
                );
            }
        },
        .toggle_title => {
            const new_pinned = !ui.overlays.title_display.isPinned();
            ui.overlays.title_display = if (new_pinned) .pinned else .hidden;
            const target: f32 = if (new_pinned) 1.0 else 0.0;
            const progress = self.viewer.animations.get(.title_overlay);
            const dur: f32 = if (new_pinned)
                @max(state.DURATION_TITLE_OVERLAY_OPEN_MS * (1.0 - progress), 30.0)
            else
                @max(state.DURATION_TITLE_OVERLAY_CLOSE_MS * progress, 30.0);
            self.viewer.animations.start(.title_overlay, target, dur, .ease_out_quad);
        },
        .set_title => |val| {
            ui.overlays.title_display = if (val) .pinned else .hidden;
            const target: f32 = if (val) 1.0 else 0.0;
            const progress = self.viewer.animations.get(.title_overlay);
            const dur: f32 = if (val)
                @max(state.DURATION_TITLE_OVERLAY_OPEN_MS * (1.0 - progress), 30.0)
            else
                @max(state.DURATION_TITLE_OVERLAY_CLOSE_MS * progress, 30.0);
            self.viewer.animations.start(.title_overlay, target, dur, .ease_out_quad);
        },
        .toggle_snackbar => {
            ui.snackbar.enabled = !ui.snackbar.enabled;
            if (!ui.snackbar.enabled) {
                ui.snackbar.clear();
                const progress = self.viewer.animations.get(.snackbar);
                const dur = @max(state.DURATION_SNACKBAR_CLOSE_MS * progress, 30.0);
                self.viewer.animations.start(.snackbar, 0.0, dur, .ease_out_quad);
            }
        },
        .set_snackbar => |val| {
            ui.snackbar.enabled = val;
            if (!val) {
                ui.snackbar.clear();
                const progress = self.viewer.animations.get(.snackbar);
                const dur = @max(state.DURATION_SNACKBAR_CLOSE_MS * progress, 30.0);
                self.viewer.animations.start(.snackbar, 0.0, dur, .ease_out_quad);
            }
        },
        .toggle_blur => ui.overlays.enable_blur = !ui.overlays.enable_blur,
        .set_blur => |val| ui.overlays.enable_blur = val,
        .toggle_fullscreen => {
            switch (self.viewer.display) {
                .headless => {},
                .windowed => |*win| {
                    win.is_fullscreen = !win.is_fullscreen;
                    win.handle.setFullscreen(win.is_fullscreen) catch |err| {
                        std.log.err("setFullscreen failed: {}", .{err});
                    };
                },
            }
        },
        .set_fullscreen => |val| {
            switch (self.viewer.display) {
                .headless => {},
                .windowed => |*win| {
                    win.is_fullscreen = val;
                    win.handle.setFullscreen(val) catch |err| {
                        std.log.err("setFullscreen failed: {}", .{err});
                    };
                },
            }
        },
        .toggle_windowless => {
            switch (self.viewer.display) {
                .headless => {},
                .windowed => |*win| {
                    win.is_borderless = !win.is_borderless;
                    if (!win.handle.setBordered(!win.is_borderless)) {
                        std.log.err("SDL_SetWindowBordered failed: {s}", .{sdl.getError()});
                    }
                },
            }
        },
        .set_windowless => |val| {
            switch (self.viewer.display) {
                .headless => {},
                .windowed => |*win| {
                    win.is_borderless = val;
                    if (!win.handle.setBordered(!win.is_borderless)) {
                        std.log.err("SDL_SetWindowBordered failed: {s}", .{sdl.getError()});
                    }
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
        .stop_slideshow => {
            nav.slideshow = .inactive;
            self.viewer.image_transition = .none;
            self.viewer.animations.setImmediate(.image_crossfade, 1.0);
        },
        .toggle_crossfade => nav.crossfade = !nav.crossfade,
        .set_crossfade => |val| nav.crossfade = val,
        .toggle_manga_mode => nav.manga_mode = !nav.manga_mode,
        .set_manga_mode => |val| nav.manga_mode = val,
        .quit => self.viewer.running = false,
    }
}

/// Dispatches declarative notification trigger matching for an executed intent.
fn triggerSnackbarForIntent(
    self: *AppState,
    intent: intents.AppIntent,
    advanced: bool,
    has_target: bool,
) void {
    if (!self.viewer.ui.snackbar.enabled) return;
    const rule = state.snackbar.findRule(intent) orelse return;
    if (!self.viewer.ui.snackbar.isTriggerEnabled(rule.trigger)) return;

    const target_class: state.Classification = switch (intent) {
        .mark_pick => .pick,
        .mark_reject => .reject,
        .unflag => .unflagged,
        else => self.viewer.navigation.getCurrentClassification(),
    };

    const last_param: ?state.EditParam = switch (intent) {
        .adjust => |adj| switch (adj) {
            .set => |s| s.param,
            .step => |s| s.param,
            .reset_param => |p| p,
            else => null,
        },
        else => null,
    };

    var buf: [state.snackbar.MAX_SNACKBAR_LEN]u8 = undefined;
    const msg = rule.format_fn(.{
        .viewport = &self.viewer.viewport,
        .manga_mode = self.viewer.navigation.manga_mode,
        .crossfade = self.viewer.navigation.crossfade,
        .snackbar_enabled = self.viewer.ui.snackbar.enabled,
        .classification = target_class,
        .classification_advanced = advanced,
        .has_target_image = has_target,
        .view_mode = self.viewer.navigation.view_mode,
        .last_param = last_param,
    }, &buf);

    if (msg.len > 0) {
        const now = sdl.timer.getTicks();
        self.viewer.ui.snackbar.show(msg, now + rule.duration_ms);
        const progress = self.viewer.animations.get(.snackbar);
        const dur = @max(state.DURATION_SNACKBAR_OPEN_MS * (1.0 - progress), 30.0);
        self.viewer.animations.start(.snackbar, 1.0, dur, .ease_out_quad);
    }
}

/// System Pass: Dispatches all queued application intents in FIFO order to
/// update domain and visual state, clearing the intent buffer once execution
/// completes.
pub fn sysExecuteIntents(ctx: FrameContext) !void {
    const self = ctx.state;
    if (self.pending_intents.items.len == 0) return;
    for (self.pending_intents.items) |intent| {
        const old_idx = self.viewer.navigation.current_index;
        try executeIntent(self, intent);
        const advanced = (old_idx != null and self.viewer.navigation.current_index != old_idx);
        triggerSnackbarForIntent(self, intent, advanced, old_idx != null);
    }
    self.clearIntents();
}

test "Manga Mode toggles Right-to-Left image navigation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "page1.png" } },
    );
    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "page2.png" } },
    );
    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "page3.png" } },
    );
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

    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img1.png" } },
    );
    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img2.png" } },
    );
    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img3.png" } },
    );
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
    const io = std.Io.Threaded.global_single_threaded.io();

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
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const media_item = state.MediaEntry{
        .filesystem = .{ .path = "test_image.raf" },
    };
    try app_st.viewer.navigation.appendEntry(allocator, media_item);
    app_st.viewer.navigation.current_index = 0;

    const key = try app_st.cache.appendSlot(allocator, 0, .{ .decoding = .{} });
    app_st.cache.get(key).?.orientation = .rotate_270;

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
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // Default title_display should be .hidden
    try testing.expectEqual(state.TitleDisplay.hidden, app_st.viewer.ui.overlays.title_display);
    try testing.expectEqual(@as(f32, 0.0), app_st.viewer.animations.get(.title_overlay));

    // Toggle title on
    try executeIntent(&app_st, .toggle_title);
    try testing.expectEqual(state.TitleDisplay.pinned, app_st.viewer.ui.overlays.title_display);
    try testing.expect(app_st.viewer.animations.isActive(.title_overlay));
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.title_overlay),
        0.001,
    );

    // Toggle title off
    try executeIntent(&app_st, .toggle_title);
    try testing.expectEqual(state.TitleDisplay.hidden, app_st.viewer.ui.overlays.title_display);
    try testing.expect(app_st.viewer.animations.isActive(.title_overlay));
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(
        @as(f32, 0.0),
        app_st.viewer.animations.get(.title_overlay),
        0.001,
    );

    // Explicit set_title
    try executeIntent(&app_st, .{ .set_title = true });
    try testing.expectEqual(state.TitleDisplay.pinned, app_st.viewer.ui.overlays.title_display);
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.title_overlay),
        0.001,
    );

    try executeIntent(&app_st, .{ .set_title = false });
    try testing.expectEqual(state.TitleDisplay.hidden, app_st.viewer.ui.overlays.title_display);
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(
        @as(f32, 0.0),
        app_st.viewer.animations.get(.title_overlay),
        0.001,
    );
}

test "fast scrubbing triggers title overlay auto-hide" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const media_item = state.MediaEntry{
        .filesystem = .{ .path = "test.jpg" },
    };
    try app_st.viewer.navigation.appendEntry(allocator, media_item);
    try app_st.viewer.navigation.appendEntry(allocator, media_item);
    app_st.viewer.navigation.current_index = 0;

    // Simulate recent navigation within 200ms
    const now = sdl.timer.getTicks();
    app_st.viewer.navigation.last_nav_time_ms = now -| 50;

    try executeIntent(&app_st, .next_image);

    // Should have triggered title auto-hide timeout and started animation
    switch (app_st.viewer.ui.overlays.title_display) {
        .transient => |t| try testing.expect(t.timeout_ms >= now + 1400),
        else => try testing.expect(false),
    }
    try testing.expect(app_st.viewer.animations.isActive(.title_overlay));
}

test "sysExecuteIntents triggers snackbar on filter and scale changes" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.ui.snackbar.enabled = true;

    // Push filter intent
    try app_st.pushIntent(.{ .set_filter = .mitchell });
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });

    try testing.expectEqualStrings(
        "Filter: Mitchell-Netravali",
        app_st.viewer.ui.snackbar.getMessage(),
    );
    try testing.expect(app_st.viewer.animations.isActive(.snackbar));
    try testing.expect(app_st.viewer.ui.snackbar.getTimeoutMs() > 0);

    // Push scale intent
    try app_st.pushIntent(.{ .set_scale = .crop });
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });

    try testing.expectEqualStrings(
        "Scale: Fill Window (Crop)",
        app_st.viewer.ui.snackbar.getMessage(),
    );

    // Toggle snackbar off disables notifications
    try app_st.pushIntent(.toggle_snackbar);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expect(!app_st.viewer.ui.snackbar.enabled);
    try testing.expectEqual(@as(usize, 0), app_st.viewer.ui.snackbar.getMessage().len);
}

test "sysExecuteIntents slideshow dissolve transitions and interval threshold" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s1.jpg" } },
    );
    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s2.jpg" } },
    );
    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s3.jpg" } },
    );
    app_st.viewer.navigation.current_index = 0;

    // 1. Slideshow with normal interval (>= 0.5s): triggers crossfade
    app_st.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 2.0 } };
    try app_st.pushIntent(.next_image);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });

    try testing.expectEqual(@as(usize, 1), app_st.viewer.navigation.current_index.?);
    try testing.expectEqual(@as(?usize, 0), app_st.viewer.getTransitionPrevIndex());
    // In headless test without loaded_gpu status, it holds at 0.0 ready to start once loaded
    try testing.expectEqual(@as(f32, 0.0), app_st.viewer.animations.get(.image_crossfade));

    // 2. Slideshow with tiny interval (< 0.5s): immediate cut, no crossfade
    app_st.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 0.2 } };
    try app_st.pushIntent(.next_image);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });

    try testing.expectEqual(@as(usize, 2), app_st.viewer.navigation.current_index.?);
    try testing.expectEqual(state.ImageTransition.none, app_st.viewer.image_transition);
    try testing.expectEqual(@as(f32, 1.0), app_st.viewer.animations.get(.image_crossfade));

    // 3. Stop slideshow: clears previous slide and settles crossfade
    app_st.viewer.image_transition = .{ .active = .{ .prev_index = 1, .prev_rotation = 0.0 } };
    try app_st.pushIntent(.stop_slideshow);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqual(state.ImageTransition.none, app_st.viewer.image_transition);
    try testing.expectEqual(@as(f32, 1.0), app_st.viewer.animations.get(.image_crossfade));
}

test "sysExecuteIntents - manual navigation crossfade and rapid navigation cut" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s1.jpg" } },
    );
    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s2.jpg" } },
    );
    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s3.jpg" } },
    );
    app_st.viewer.navigation.current_index = 0;
    app_st.viewer.navigation.crossfade = true;
    app_st.viewer.navigation.last_nav_time_ms = 0; // elapsed >= 200

    // 1. Normal manual navigation with crossfade enabled
    try app_st.pushIntent(.next_image);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqual(@as(usize, 1), app_st.viewer.navigation.current_index.?);
    try testing.expectEqual(@as(?usize, 0), app_st.viewer.getTransitionPrevIndex());
    try testing.expectEqual(@as(f32, 0.0), app_st.viewer.animations.get(.image_crossfade));

    // 2. Rapid scrub (elapsed < 200ms or animation in flight): cuts immediately
    try app_st.pushIntent(.next_image);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqual(@as(usize, 2), app_st.viewer.navigation.current_index.?);
    try testing.expectEqual(state.ImageTransition.none, app_st.viewer.image_transition);
    try testing.expectEqual(@as(f32, 1.0), app_st.viewer.animations.get(.image_crossfade));

    // 3. Toggle crossfade intent
    try app_st.pushIntent(.toggle_crossfade);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqual(false, app_st.viewer.navigation.crossfade);
}

test "Before/After comparison intents mutate viewport and trigger snackbar" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // Enable snackbar to verify notification dispatch
    app_st.viewer.ui.snackbar.enabled = true;

    // 1. Toggling without adjustments remains false and shows no adjustments snackbar
    try app_st.pushIntent(.toggle_compare);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqual(false, app_st.viewer.viewport.compare_original);
    try testing.expectEqualStrings(
        "Before / After: No Adjustments",
        app_st.viewer.ui.snackbar.getMessage(),
    );

    // 2. Set adjustments then toggle compare on
    try app_st.pushIntent(.increase_brightness);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expect(app_st.viewer.viewport.hasAdjustments());

    try app_st.pushIntent(.toggle_compare);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqual(true, app_st.viewer.viewport.compare_original);
    try testing.expectEqualStrings(
        "Before (Original)",
        app_st.viewer.ui.snackbar.getMessage(),
    );

    // 3. Toggle compare off
    try app_st.pushIntent(.toggle_compare);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqual(false, app_st.viewer.viewport.compare_original);
    try testing.expectEqualStrings(
        "After (Adjusted)",
        app_st.viewer.ui.snackbar.getMessage(),
    );

    // 4. Test set_compare explicit intent
    try app_st.pushIntent(.{ .set_compare = true });
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqual(true, app_st.viewer.viewport.compare_original);
    try testing.expectEqualStrings(
        "Before (Original)",
        app_st.viewer.ui.snackbar.getMessage(),
    );
}

test "sysExecuteIntents classification snackbar confirms action and advance" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.ui.snackbar.enabled = true;

    try app_st.viewer.navigation.appendEntry(allocator, .{ .filesystem = .{ .path = "img1.jpg" } });
    try app_st.viewer.navigation.appendEntry(allocator, .{ .filesystem = .{ .path = "img2.jpg" } });
    app_st.viewer.navigation.current_index = 0;

    // 1. In default view, mark Pick: image remains visible, does not advance
    try app_st.pushIntent(.mark_pick);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqualStrings(
        "Flagged as Pick",
        app_st.viewer.ui.snackbar.getMessage(),
    );
    try testing.expectEqual(@as(?usize, 0), app_st.viewer.navigation.current_index);

    // 2. In default view, mark Reject: image is hidden, advances to next visible image
    try app_st.pushIntent(.mark_reject);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqualStrings(
        "Previous image flagged as rejected",
        app_st.viewer.ui.snackbar.getMessage(),
    );
    try testing.expectEqual(@as(?usize, 1), app_st.viewer.navigation.current_index);

    // 3. In all view, mark Reject: image remains visible, does not advance
    app_st.viewer.navigation.view_mode = .all;
    try app_st.pushIntent(.mark_reject);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqualStrings(
        "Flagged as Reject",
        app_st.viewer.ui.snackbar.getMessage(),
    );
    try testing.expectEqual(@as(?usize, 1), app_st.viewer.navigation.current_index);

    // 4. In picks view where 0 images match, try marking pick or reject: confirms "No image to classify"
    app_st.viewer.navigation.view_mode = .picks;
    _ = app_st.viewer.navigation.adjustIndexForVisibility();
    try testing.expectEqual(@as(?usize, null), app_st.viewer.navigation.current_index);

    try app_st.pushIntent(.mark_pick);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqualStrings(
        "No image to classify",
        app_st.viewer.ui.snackbar.getMessage(),
    );

    try app_st.pushIntent(.mark_reject);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqualStrings(
        "No image to classify",
        app_st.viewer.ui.snackbar.getMessage(),
    );
}

test "sysExecuteIntents - raw jpeg stacking and stream toggle" {
    const allocator = std.testing.allocator;
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.ui.snackbar.enabled = true;

    // 1. Initial stacking state is true
    try testing.expect(app_st.viewer.navigation.stack_raw_jpeg);

    // 2. Toggle stacking -> becomes false, snackbar says disabled
    try app_st.pushIntent(.toggle_raw_jpeg_stacking);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expect(!app_st.viewer.navigation.stack_raw_jpeg);
    try testing.expectEqualStrings(
        "RAW+JPEG stacking disabled",
        app_st.viewer.ui.snackbar.getMessage(),
    );

    // 3. Set stacking true -> becomes true, snackbar says enabled
    try app_st.pushIntent(.{ .set_raw_jpeg_stacking = true });
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expect(app_st.viewer.navigation.stack_raw_jpeg);
    try testing.expectEqualStrings(
        "RAW+JPEG stacking enabled",
        app_st.viewer.ui.snackbar.getMessage(),
    );

    // 4. Toggle pair stream on a pair
    const raw_p = try app_st.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "DSC00941.ARW",
    );
    const jpg_p = try app_st.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "DSC00941.JPG",
    );
    try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p } },
    );
    app_st.viewer.navigation.current_index = 0;

    const key = try app_st.cache.appendSlot(allocator, 0, .{
        .loaded_cpu = .{
            .surface = undefined,
            .w = 1616.0,
            .h = 1080.0,
            .size_bytes = 500_000,
        },
    });
    if (app_st.cache.get(key)) |entry| {
        entry.raw_metadata = state.RawMetadata.init(6000.0, 4000.0);
    }

    try app_st.pushIntent(.toggle_pair_stream);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqualStrings(
        "Stream: Standalone JPEG",
        app_st.viewer.ui.snackbar.getMessage(),
    );
    try testing.expect(app_st.cache.get(key).?.is_promoting);
}
