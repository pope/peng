const animation = @import("animation.zig");
const app_state = @import("../state.zig");
const cache = @import("cache");
const context = @import("context.zig");
const events = @import("../events.zig");
const intents = @import("intents");
const probe = @import("probe");
const sdl = @import("sdl");
const state = @import("state");
const std = @import("std");
const triage = @import("triage");
const vfs = @import("vfs");

const AppState = app_state.AppState;
const CacheEntry = cache.CacheEntry;
const Classification = triage.Classification;
const EditParam = intents.EditParam;
const FrameContext = context.FrameContext;
const MediaEntry = vfs.MediaEntry;
const PairStreamTarget = vfs.PairStreamTarget;
const RawMetadata = probe.RawMetadata;
const sysUpdateAnimations = animation.sysUpdateAnimations;

fn showCustomSnackbar(self: *AppState, msg: []const u8, now_ms: u64) void {
    if (!self.viewer.ui.snackbar.enabled or self.display.isHidden()) return;
    self.viewer.ui.snackbar.show(msg, now_ms +| 1500);
    const progress = self.viewer.animations.get(.snackbar);
    const dur = @max(state.DURATION_SNACKBAR_OPEN_MS * (1.0 - progress), 30.0);
    self.viewer.animations.start(.snackbar, 1.0, dur, .ease_out_quad);
}

fn togglePairStream(self: *AppState, now_ms: u64) void {
    const nav = &self.viewer.navigation;
    const cur_id = nav.getCurrentMediaId() orelse return;
    const entry_item = nav.getCurrentImageEntry() orelse return;
    if (!entry_item.isPair()) return;

    const key = self.cache.activeKey(cur_id);
    const entry = self.cache.get(key) orelse return;
    if (!entry.resident.asset.isLoaded()) return;
    switch (entry.inflight) {
        .decoding => |dec| self.cache.cancelJob(dec.ticket.job_id),
        .idle, .queued_decode, .uploading => {},
    }
    switch (entry.resident.asset) {
        .promoting_gpu => |*promo| {
            promo.staged.deinit();
            entry.resident.asset = .{ .loaded_gpu = promo.active };
        },
        .loaded_gpu, .loaded_cpu, .none, .failed => {},
    }

    const target: PairStreamTarget =
        if (entry.metadata.raw_metadata.isRaw())
            .standalone_jpeg
        else
            .raw_preview;
    const msg = switch (target) {
        .standalone_jpeg => "Stream: Standalone JPEG",
        .raw_preview => "Stream: RAW Embedded Preview",
        .adaptive => "Stream: Adaptive",
    };
    showCustomSnackbar(self, msg, now_ms);
    entry.inflight = .{
        .queued_decode = .{
            .start_time_ms = now_ms,
            .target = target,
        },
    };
}

fn precacheCurrentDirectory(self: *AppState, now_ms: u64) !void {
    if (self.workers.thumb_cache_config == .disabled) {
        showCustomSnackbar(self, "Thumbnail cache is disabled", now_ms);
        return;
    }

    const entries = self.viewer.navigation.getEntries();
    if (entries.len == 0) {
        showCustomSnackbar(self, "No images in current directory", now_ms);
        return;
    }

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    try paths.ensureTotalCapacity(arena_alloc, entries.len);

    for (entries) |entry| {
        switch (entry) {
            .archive_entry => {},
            .filesystem => |f| {
                try paths.append(arena_alloc, try arena_alloc.dupe(u8, f.path));
            },
            .pair => |p| {
                try paths.append(
                    arena_alloc,
                    try arena_alloc.dupe(u8, p.raw_path),
                );
                try paths.append(
                    arena_alloc,
                    try arena_alloc.dupe(u8, p.jpeg_path),
                );
            },
        }
    }

    if (paths.items.len == 0) {
        arena.deinit();
        showCustomSnackbar(self, "No filesystem images to pre-cache", now_ms);
        return;
    }

    const count = paths.items.len;
    if (self.workers.startDirectoryPrecache(
        self.allocator,
        self.io,
        .{ .arena = arena, .paths = paths.items },
    )) {
        var buf: [state.snackbar.MAX_SNACKBAR_LEN]u8 = undefined;
        if (std.mem.print(
            &buf,
            "Pre-caching {d} thumbnails in background...",
            .{count},
        )) |msg| {
            showCustomSnackbar(self, msg, now_ms);
        } else |_| {
            showCustomSnackbar(
                self,
                "Pre-caching thumbnails in background...",
                now_ms,
            );
        }
    }
}

fn handleSetPaletteIntent(self: *AppState, p: anytype) !void {
    const active_mode = p.mode.toActive() orelse {
        self.closePaletteImmediately();
        return;
    };
    const ui = &self.viewer.ui;
    switch (active_mode) {
        .directory_navigator => if (p.query) |q| {
            if (ui.palette.openMode()) |cur_mode| {
                switch (cur_mode) {
                    .directory_navigator => {
                        ui.palette.query.clearRetainingCapacity();
                        try self.loadPaletteDirectory(q, null, false);
                        return;
                    },
                    .files, .actions, .prompt => {},
                }
            }
            try self.openDirectoryPalette(q);
            return;
        },
        .files, .actions, .prompt => {},
    }
    try self.openPalette(active_mode);
    const q = p.query orelse return;
    ui.palette.query.clearRetainingCapacity();
    try ui.palette.query.appendSlice(self.allocator, q);
    ui.palette.selected_idx = 0;
    ui.palette.selection_dirty = true;
    switch (active_mode) {
        .actions => try self.viewer.ui.palette.rebuildActionMatches(
            self.allocator,
        ),
        .files => try self.viewer.ui.palette.rebuildFileMatches(
            self.allocator,
            self.viewer.navigation.getEntries(),
        ),
        .directory_navigator, .prompt => {},
    }
}

fn syncNavIndexChange(self: *AppState, old_idx: ?usize) void {
    if (old_idx != self.viewer.navigation.current_index) {
        self.resetViewportAndTransitions();
    }
}

/// Central intent dispatcher. Maps an AppIntent variant to domain state mutations.
fn executeIntent(
    self: *AppState,
    intent: intents.AppIntent,
    now_ms: u64,
) !void {
    const vp = &self.viewer.viewport;
    const nav = &self.viewer.navigation;
    const ui = &self.viewer.ui;

    switch (intent) {
        .open_path => |p| try self.openPath(p, now_ms),
        .open_window => {
            self.showAndRaiseWindow();
            if (nav.count() == 0 and !ui.palette.isOpen()) {
                try self.openPalette(.directory_navigator);
            }
        },
        .set_zoom => |factor| {
            vp.mode = .manual;
            const old_zoom = vp.zoom_factor;
            vp.zoom_factor = state.clampZoomFactor(factor);
            const ratio = old_zoom.ratioTo(vp.zoom_factor);
            vp.pan_x *= ratio;
            vp.pan_y *= ratio;
        },
        .zoom_by => |zb| {
            if (zb.ratio <= 0.0 or !std.math.isFinite(zb.ratio)) return;
            if (zb.snap_zoom) |snap| {
                if (snap <= 0.0 or !std.math.isFinite(snap)) return;
            }
            vp.mode = .manual;
            const old_zoom = vp.zoom_factor.get();
            const target = zb.snap_zoom orelse @max(
                state.ZoomFactor.MIN,
                old_zoom * zb.ratio,
            );
            const new_zoom = state.clampZoomFactor(target).get();
            vp.zoom_factor = state.ZoomFactor.init(new_zoom);
            const ratio = new_zoom / old_zoom;
            vp.pan_x *= ratio;
            vp.pan_y *= ratio;
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
            self.viewer.pan_controller.reset();
            self.viewer.zoom_controller.reset();
            vp.fit_mode = .full;
            vp.reset();
            vp.zoom_factor = state.ZoomFactor.init(self.getBaseScale());
        },
        .set_scale => |mode| {
            self.viewer.pan_controller.reset();
            self.viewer.zoom_controller.reset();
            vp.fit_mode = mode;
            vp.reset();
            vp.zoom_factor = state.ZoomFactor.init(self.getBaseScale());
        },
        .cycle_scale_mode => {
            self.viewer.pan_controller.reset();
            self.viewer.zoom_controller.reset();
            vp.fit_mode = switch (vp.fit_mode) {
                .shrink => .full,
                .full => .crop,
                .crop => .none,
                .none => .fit_width,
                .fit_width => .fit_height,
                .fit_height => .shrink,
            };
            vp.reset();
            vp.zoom_factor = state.ZoomFactor.init(self.getBaseScale());
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
                const spec = intents.getSpec(s.param);
                const dir_f: f32 = @floatFromInt(@backingInt(s.direction));
                const delta = spec.step * dir_f;
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
            if (vp.mode != .manual) {
                vp.zoom_factor = state.ZoomFactor.init(self.getBaseScale());
            }
            if (nav.getCurrentImageEntry()) |entry| {
                try self.putRotation(entry.getPath(), vp.rotation_angle);
            }
        },
        .rotate_ccw => {
            vp.rotateCcw();
            if (vp.mode != .manual) {
                vp.zoom_factor = state.ZoomFactor.init(self.getBaseScale());
            }
            if (nav.getCurrentImageEntry()) |entry| {
                try self.putRotation(entry.getPath(), vp.rotation_angle);
            }
        },
        .reset_rotation => {
            if (nav.getCurrentImageEntry()) |entry| {
                const path = entry.getPath();
                const exif_rot = if (self.getCurrentEntry()) |e|
                    e.metadata.orientation
                else
                    .normal;
                vp.rotation_angle = exif_rot.toDegrees();
                if (vp.mode != .manual) {
                    vp.zoom_factor = state.ZoomFactor.init(self.getBaseScale());
                }
                try self.putRotation(path, vp.rotation_angle);
            } else {
                vp.rotation_angle = 0.0;
                if (vp.mode != .manual) {
                    vp.zoom_factor = state.ZoomFactor.init(self.getBaseScale());
                }
            }
        },

        .next_image, .prev_image, .first_image, .last_image, .go_to_image => {
            const prev_cadence = nav.cadence;
            const should_show_auto_title = ui.overlays.auto_title and
                nav.count() > 0 and
                prev_cadence.shouldBypassCrossfade(now_ms);
            if (should_show_auto_title) {
                if (!ui.overlays.title_display.isPinned()) {
                    ui.overlays.title_display = .{
                        .transient = .{ .timeout_ms = now_ms +| 1500 },
                    };
                    const progress = self.viewer.animations.get(.title_overlay);
                    const dur = @max(
                        state.DURATION_TITLE_OVERLAY_OPEN_MS * (1.0 - progress),
                        30.0,
                    );
                    self.viewer.animations.start(
                        .title_overlay,
                        1.0,
                        dur,
                        .ease_out_quad,
                    );
                }
            }
            const is_slideshow = nav.isSlideshowActive();
            const old_index = nav.current_index;
            const old_id = nav.getCurrentMediaId();
            const old_rot = self.viewer.viewport.rotation_angle;
            const old_zoom = vp.zoom_factor.get();
            const old_pan_x = vp.pan_x;
            const old_pan_y = vp.pan_y;

            self.viewer.pan_controller.reset();
            self.viewer.zoom_controller.reset();
            vp.reset();
            _ = switch (intent) {
                .next_image => if (nav.manga_mode)
                    nav.prevIndex(now_ms)
                else
                    nav.nextIndex(now_ms),
                .prev_image => if (nav.manga_mode)
                    nav.nextIndex(now_ms)
                else
                    nav.prevIndex(now_ms),
                .first_image => blk: {
                    const res = nav.goToIndex(0, now_ms);
                    nav.direction = .forward;
                    break :blk res;
                },
                .last_image => blk: {
                    const last_idx = if (nav.count() > 0)
                        nav.count() - 1
                    else
                        0;
                    const res = nav.goToIndex(last_idx, now_ms);
                    nav.direction = .backward;
                    break :blk res;
                },
                .go_to_image => |idx| nav.goToIndex(idx, now_ms),
                else => unreachable,
            };
            self.updateCurrentRotation();

            if (vp.mode != .manual) {
                vp.zoom_factor = state.ZoomFactor.init(self.getBaseScale());
            }

            const changed_image = old_index != null and
                nav.current_index != null and
                old_index.? != nav.current_index.?;
            if (changed_image) {
                const old_key = self.cache.activeKey(old_id.?);
                const old_entry_loaded = if (self.cache.getEntry(old_key)) |e|
                    switch (e.resident.asset) {
                        .loaded_gpu, .promoting_gpu => true,
                        .loaded_cpu, .none => self.gpu_device == null,
                        .failed => false,
                    }
                else
                    self.gpu_device == null;
                const cur_entry = self.getCurrentEntry();
                const target_failed = if (cur_entry) |e|
                    e.resident.asset.isFailed()
                else
                    false;
                const target_decoded = if (cur_entry) |e|
                    e.resident.asset.isLoaded()
                else
                    self.gpu_device == null;
                const is_animating =
                    self.viewer.animations.isActive(.image_crossfade) or
                    self.viewer.image_transition != .none;
                const should_crossfade = !target_failed and if (is_slideshow)
                    switch (nav.slideshow) {
                        .active => |s| s.interval_s >=
                            state.MIN_SLIDESHOW_DISSOLVE_INTERVAL_S and
                            old_entry_loaded,
                        .inactive => false,
                    }
                else
                    (nav.crossfade and
                        !prev_cadence.shouldBypassCrossfade(now_ms) and
                        !is_animating and old_entry_loaded and target_decoded);

                if (should_crossfade) {
                    self.viewer.image_transition = .{
                        .active = .{
                            .prev_index = old_index.?,
                            .prev_rotation = old_rot,
                            .prev_zoom = old_zoom,
                            .prev_pan_x = old_pan_x,
                            .prev_pan_y = old_pan_y,
                        },
                    };
                    const is_ready = if (cur_entry) |e|
                        e.resident.asset.hasGpuTexture()
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
                try self.reloadPath(entry.getSourcePath(), now_ms);
            } else if (nav.last_scanned_dir.items.len > 0) {
                try self.reloadPath(nav.last_scanned_dir.items, now_ms);
            }
        },
        .mark_pick => {
            const old_idx = nav.current_index;
            _ = try nav.markCurrentPick(self.allocator);
            _ = nav.adjustIndexForVisibility();
            syncNavIndexChange(self, old_idx);
        },
        .mark_reject => {
            const old_idx = nav.current_index;
            _ = try nav.markCurrentReject(self.allocator);
            _ = nav.adjustIndexForVisibility();
            syncNavIndexChange(self, old_idx);
        },
        .unflag => {
            const old_idx = nav.current_index;
            _ = try nav.unflagCurrent(self.allocator);
            _ = nav.adjustIndexForVisibility();
            syncNavIndexChange(self, old_idx);
        },
        .clear_classifications => {
            const old_idx = nav.current_index;
            const had_flags = nav.clearAllClassifications();
            _ = nav.adjustIndexForVisibility();
            syncNavIndexChange(self, old_idx);
            const msg = if (had_flags)
                "Cleared all picks and rejects"
            else
                "No classifications to clear";
            showCustomSnackbar(self, msg, now_ms);
            if (ui.palette.openMode()) |mode| switch (mode) {
                .files => try self.viewer.ui.palette.rebuildFileMatches(
                    self.allocator,
                    self.viewer.navigation.getEntries(),
                ),
                .actions, .directory_navigator, .prompt => {},
            };
        },
        .cycle_view_mode => {
            const old_idx = nav.current_index;
            _ = nav.cycleViewMode();
            syncNavIndexChange(self, old_idx);
        },
        .set_view_mode => |mode| {
            const old_idx = nav.current_index;
            _ = nav.setViewMode(mode);
            syncNavIndexChange(self, old_idx);
        },
        .toggle_raw_jpeg_stacking => {
            nav.stack_raw_jpeg = !nav.stack_raw_jpeg;
            const msg = if (nav.stack_raw_jpeg)
                "RAW+JPEG stacking enabled"
            else
                "RAW+JPEG stacking disabled";
            showCustomSnackbar(self, msg, now_ms);
            _ = self.cache.advanceGeneration();
            if (nav.getCurrentImageEntry()) |entry| {
                try self.reloadPath(entry.getSourcePath(), now_ms);
            } else if (nav.last_scanned_dir.items.len > 0) {
                try self.reloadPath(nav.last_scanned_dir.items, now_ms);
            }
        },
        .set_raw_jpeg_stacking => |enable| {
            if (nav.stack_raw_jpeg != enable) {
                nav.stack_raw_jpeg = enable;
                const msg = if (enable)
                    "RAW+JPEG stacking enabled"
                else
                    "RAW+JPEG stacking disabled";
                showCustomSnackbar(self, msg, now_ms);
                _ = self.cache.advanceGeneration();
                if (nav.getCurrentImageEntry()) |entry| {
                    try self.reloadPath(entry.getSourcePath(), now_ms);
                } else if (nav.last_scanned_dir.items.len > 0) {
                    try self.reloadPath(nav.last_scanned_dir.items, now_ms);
                }
            }
        },
        .toggle_pair_stream => togglePairStream(self, now_ms),
        .precache_directory => try precacheCurrentDirectory(self, now_ms),
        .set_palette => |p| try handleSetPaletteIntent(self, p),
        .toggle_info => ui.overlays.info_panel.visible = !ui.overlays.info_panel.visible,
        .set_info => |val| ui.overlays.info_panel.visible = val,
        .toggle_stats => ui.overlays.stats_panel.visible = !ui.overlays.stats_panel.visible,
        .set_stats => |val| ui.overlays.stats_panel.visible = val,
        .toggle_atlas => {
            ui.overlays.atlas_panel.visible = !ui.overlays.atlas_panel.visible;
        },
        .set_atlas => |val| ui.overlays.atlas_panel.visible = val,
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
            switch (self.display.backendPtr().*) {
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
            switch (self.display.backendPtr().*) {
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
            switch (self.display.backendPtr().*) {
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
            switch (self.display.backendPtr().*) {
                .headless => {},
                .windowed => |*win| {
                    win.is_borderless = val;
                    if (!win.handle.setBordered(!win.is_borderless)) {
                        std.log.err("SDL_SetWindowBordered failed: {s}", .{sdl.getError()});
                    }
                },
            }
        },
        .toggle_debug_thumb => {
            ui.overlays.debug_show_thumb = !ui.overlays.debug_show_thumb;
        },
        .set_debug_thumb => |val| {
            ui.overlays.debug_show_thumb = val;
        },
        .start_slideshow => {
            try self.openPalette(.{ .prompt = .slideshow_interval });
        },
        .start_slideshow_interval => |interval| {
            if (!std.math.isFinite(interval)) return;
            const clamped = std.math.clamp(
                interval,
                state.SlideshowMode.MIN_INTERVAL_S,
                state.SlideshowMode.MAX_INTERVAL_S,
            );
            nav.slideshow = .{
                .active = .{
                    .interval_s = clamped,
                    .timer_ms = 0.0,
                },
            };
        },
        .stop_slideshow => {
            nav.slideshow = .inactive;
            self.viewer.image_transition = .none;
            self.viewer.animations.setImmediate(.image_crossfade, 1.0);
        },
        .toggle_crossfade => nav.crossfade = !nav.crossfade,
        .set_crossfade => |val| nav.crossfade = val,
        .toggle_manga_mode => nav.manga_mode = !nav.manga_mode,
        .set_manga_mode => |val| nav.manga_mode = val,
        .quit => {
            if (self.viewer.server_mode) {
                self.hideWindow();
            } else {
                self.viewer.running = false;
            }
        },
        .quit_server => self.viewer.running = false,
    }
}

/// Dispatches declarative notification trigger matching for an executed intent.
fn triggerSnackbarForIntent(
    self: *AppState,
    intent: intents.AppIntent,
    advanced: bool,
    has_target: bool,
    now_ms: u64,
) void {
    if (!self.viewer.ui.snackbar.enabled or self.display.isHidden()) return;
    const rule = state.snackbar.findRule(intent) orelse return;
    if (!self.viewer.ui.snackbar.isTriggerEnabled(rule.trigger)) return;

    const target_class: Classification = switch (intent) {
        .mark_pick => .pick,
        .mark_reject => .reject,
        .unflag => .unflagged,
        else => self.viewer.navigation.getCurrentClassification(),
    };

    const last_param: ?EditParam = switch (intent) {
        .adjust => |adj| switch (adj) {
            .set => |s| s.param,
            .step => |s| s.param,
            .reset_param => |p| p,
            .batch_tone,
            .batch_color,
            .batch_presence,
            .reset_all,
            .toggle_compare,
            .set_compare,
            => null,
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
        .view_mode = self.viewer.navigation.getViewMode(),
        .last_param = last_param,
    }, &buf);

    if (msg.len > 0) {
        self.viewer.ui.snackbar.show(msg, now_ms +| rule.duration_ms);
        const progress = self.viewer.animations.get(.snackbar);
        const dur = @max(
            state.DURATION_SNACKBAR_OPEN_MS * (1.0 - progress),
            30.0,
        );
        self.viewer.animations.start(.snackbar, 1.0, dur, .ease_out_quad);
    }
}

/// System Pass: Dispatches all queued application intents in FIFO order to
/// update domain and visual state, clearing the intent buffer once execution
/// completes.
pub fn sysExecuteIntents(ctx: FrameContext) !void {
    const self = ctx.state;
    defer self.flushPendingSelectionStreams();
    if (self.pending_intents.items.len == 0) return;
    defer self.clearIntents();
    for (self.pending_intents.items) |intent| {
        if (!self.viewer.running) break;
        const old_idx = self.viewer.navigation.current_index;
        try executeIntent(self, intent, ctx.now_ms);
        const advanced = (old_idx != null and
            self.viewer.navigation.current_index != old_idx);
        triggerSnackbarForIntent(
            self,
            intent,
            advanced,
            old_idx != null,
            ctx.now_ms,
        );
    }
}

test "Manga Mode toggles Right-to-Left image navigation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "page1.png" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "page2.png" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "page3.png" } },
    );
    app_st.viewer.navigation.current_index = 0;

    // Normal mode: next_image moves 0 -> 1
    try executeIntent(&app_st, .next_image, 1000);
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.viewer.navigation.current_index.?,
    );

    // Toggle Manga Mode
    try executeIntent(&app_st, .toggle_manga_mode, 1000);
    try std.testing.expect(app_st.viewer.navigation.manga_mode);

    // Manga mode (RTL): next_image moves 1 -> 0
    try executeIntent(&app_st, .next_image, 1000);
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.viewer.navigation.current_index.?,
    );

    // Manga mode (RTL): prev_image moves 0 -> 1
    try executeIntent(&app_st, .prev_image, 1000);
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.viewer.navigation.current_index.?,
    );
}

test "Navigation intents cleanly advance image index" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img1.png" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img2.png" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img3.png" } },
    );
    app_st.viewer.navigation.current_index = 0;

    try executeIntent(&app_st, .next_image, 1000);
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.viewer.navigation.current_index.?,
    );

    try executeIntent(&app_st, .next_image, 1000);
    try std.testing.expectEqual(
        @as(usize, 2),
        app_st.viewer.navigation.current_index.?,
    );

    try executeIntent(&app_st, .prev_image, 1000);
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.viewer.navigation.current_index.?,
    );
}

test "palette_action_items metadata" {
    const nav_item = intents.actions.palette_action_items[7];
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
    try executeIntent(&app_st, .toggle_blur, 1000);
    try testing.expect(!app_st.viewer.ui.overlays.enable_blur);

    // Toggle blur on
    try executeIntent(&app_st, .toggle_blur, 1000);
    try testing.expect(app_st.viewer.ui.overlays.enable_blur);

    // Explicit set_blur
    try executeIntent(&app_st, .{ .set_blur = false }, 1000);
    try testing.expect(!app_st.viewer.ui.overlays.enable_blur);

    try executeIntent(&app_st, .{ .set_blur = true }, 1000);
    try testing.expect(app_st.viewer.ui.overlays.enable_blur);
}

test "rotate_cw, rotate_ccw, and reset_rotation intents" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const media_item = MediaEntry{
        .filesystem = .{ .path = "test_image.raf" },
    };
    _ = try app_st.viewer.navigation.appendEntry(allocator, media_item);
    app_st.viewer.navigation.current_index = 0;
    const id0 = app_st.viewer.navigation.getIdAt(0).?;

    const key = try app_st.cache.appendSlot(
        allocator,
        id0,
        .{},
    );
    app_st.cache.get(key).?.metadata.orientation = .rotate_270;

    // Rotate CW
    try executeIntent(&app_st, .rotate_cw, 1000);
    try testing.expectEqual(
        @as(f32, 90.0),
        app_st.viewer.viewport.rotation_angle,
    );

    // Rotate CCW
    try executeIntent(&app_st, .rotate_ccw, 1000);
    try testing.expectEqual(
        @as(f32, 0.0),
        app_st.viewer.viewport.rotation_angle,
    );

    // Reset rotation should restore entry orientation (270 degrees)
    try executeIntent(&app_st, .reset_rotation, 1000);
    try testing.expectEqual(
        @as(f32, 270.0),
        app_st.viewer.viewport.rotation_angle,
    );
}

test "toggle_title and set_title intents" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // Default title_display should be .hidden
    try testing.expectEqual(
        state.TitleDisplay.hidden,
        app_st.viewer.ui.overlays.title_display,
    );
    try testing.expectEqual(
        @as(f32, 0.0),
        app_st.viewer.animations.get(.title_overlay),
    );

    // Toggle title on
    try executeIntent(&app_st, .toggle_title, 1000);
    try testing.expectEqual(
        state.TitleDisplay.pinned,
        app_st.viewer.ui.overlays.title_display,
    );
    try testing.expect(app_st.viewer.animations.isActive(.title_overlay));
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.title_overlay),
        0.001,
    );

    // Toggle title off
    try executeIntent(&app_st, .toggle_title, 1000);
    try testing.expectEqual(
        state.TitleDisplay.hidden,
        app_st.viewer.ui.overlays.title_display,
    );
    try testing.expect(app_st.viewer.animations.isActive(.title_overlay));
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(
        @as(f32, 0.0),
        app_st.viewer.animations.get(.title_overlay),
        0.001,
    );

    // Explicit set_title
    try executeIntent(&app_st, .{ .set_title = true }, 1000);
    try testing.expectEqual(
        state.TitleDisplay.pinned,
        app_st.viewer.ui.overlays.title_display,
    );
    app_st.viewer.animations.settleAll();
    try testing.expectApproxEqAbs(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.title_overlay),
        0.001,
    );

    try executeIntent(&app_st, .{ .set_title = false }, 1000);
    try testing.expectEqual(
        state.TitleDisplay.hidden,
        app_st.viewer.ui.overlays.title_display,
    );
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

    const media_item = MediaEntry{
        .filesystem = .{ .path = "test.jpg" },
    };
    _ = try app_st.viewer.navigation.appendEntry(allocator, media_item);
    _ = try app_st.viewer.navigation.appendEntry(allocator, media_item);
    app_st.viewer.navigation.current_index = 0;

    // Simulate recent navigation within 200ms
    const now: u64 = 5000;
    app_st.viewer.navigation.cadence.recordNavigation(now -| 50);

    try executeIntent(&app_st, .next_image, now);

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
        .now_ms = 2000,
    });

    try testing.expectEqualStrings(
        "Filter: Mitchell-Netravali",
        app_st.viewer.ui.snackbar.getMessage(),
    );
    try testing.expect(app_st.viewer.animations.isActive(.snackbar));
    try testing.expectEqual(
        @as(u64, 2000 + 1800),
        app_st.viewer.ui.snackbar.getTimeoutMs(),
    );

    // Push scale intent
    try app_st.pushIntent(.{ .set_scale = .crop });
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
        .now_ms = 4000,
    });

    try testing.expectEqualStrings(
        "Scale: Fill Window (Crop)",
        app_st.viewer.ui.snackbar.getMessage(),
    );
    try testing.expectEqual(
        @as(u64, 4000 + 1800),
        app_st.viewer.ui.snackbar.getTimeoutMs(),
    );

    // Toggle snackbar off disables notifications
    try app_st.pushIntent(.toggle_snackbar);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
        .now_ms = 6000,
    });
    try testing.expect(!app_st.viewer.ui.snackbar.enabled);
    try testing.expectEqual(
        @as(usize, 0),
        app_st.viewer.ui.snackbar.getMessage().len,
    );
}

test "sysExecuteIntents slideshow dissolve transitions and interval threshold" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s1.jpg" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s2.jpg" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
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

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s1.jpg" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s2.jpg" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "s3.jpg" } },
    );
    app_st.viewer.navigation.current_index = 0;
    app_st.viewer.navigation.crossfade = true;
    app_st.viewer.navigation.cadence = .idle;

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

    // 2. Navigation while previous transition is still pending at 0.0
    // (isActive(.image_crossfade) == false, image_transition != .none),
    // even when settled: cuts immediately to .none / 1.0
    app_st.viewer.navigation.cadence = .idle;
    try testing.expect(!app_st.viewer.animations.isActive(.image_crossfade));
    try testing.expect(app_st.viewer.image_transition != .none);
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

    // 4. Manual navigation to a .decoding slide (e.g. thumbnail loaded after
    // fast scroll, full image still decoding) must not arm image_transition,
    // preventing a flash of the previous slide when full decode completes.
    app_st.viewer.navigation.crossfade = true;
    app_st.viewer.navigation.current_index = 0;
    app_st.viewer.navigation.cadence = .idle;
    const id0 = app_st.viewer.navigation.getIdAt(0).?;
    const id1 = app_st.viewer.navigation.getIdAt(1).?;
    const key0 = try app_st.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_gpu = .{
                    .gpu_texture = undefined,
                    .w = 100,
                    .h = 100,
                    .size_bytes = 1000,
                    .ingest = .{ .memory_size_bytes = 40_000 },
                },
            },
        },
    });
    defer {
        if (app_st.cache.get(key0)) |e| {
            e.resident.asset = .none;
            e.inflight = .idle;
        }
    }
    const ticket1 = app_st.cache.allocJob().?;
    _ = try app_st.cache.appendSlot(allocator, id1, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket1 },
        },
    });

    try app_st.pushIntent(.next_image);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expectEqual(
        @as(usize, 1),
        app_st.viewer.navigation.current_index.?,
    );
    try testing.expectEqual(
        state.ImageTransition.none,
        app_st.viewer.image_transition,
    );
    try testing.expectEqual(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.image_crossfade),
    );
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
    try app_st.pushIntent(.{ .adjust = .toggle_compare });
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
    try app_st.pushIntent(.{
        .adjust = .{ .step = .{ .param = .brightness, .direction = .up } },
    });
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try testing.expect(app_st.viewer.viewport.hasAdjustments());

    try app_st.pushIntent(.{ .adjust = .toggle_compare });
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
    try app_st.pushIntent(.{ .adjust = .toggle_compare });
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
    try app_st.pushIntent(.{ .adjust = .{ .set_compare = true } });
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

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img1.jpg" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img2.jpg" } },
    );
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
    app_st.viewer.navigation.triage.view_mode = .all;
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
    app_st.viewer.navigation.triage.view_mode = .picks;
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
        "testfiles/golden-screenshots/init.png",
    );
    const jpg_p = try app_st.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p } },
    );
    app_st.viewer.navigation.current_index = 0;
    const id0 = app_st.viewer.navigation.getIdAt(0).?;

    const surf = sdl.Surface.create(10, 10, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    const key = try app_st.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 1616.0,
                        .h = 1080.0,
                        .size_bytes = 500_000,
                    },
                },
            },
        },
    });
    if (app_st.cache.get(key)) |entry| {
        entry.metadata.raw_metadata = RawMetadata.init(6000.0, 4000.0);
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
    switch (app_st.cache.get(key).?.inflight) {
        .queued_decode => |q| try testing.expectEqual(
            PairStreamTarget.standalone_jpeg,
            q.target,
        ),
        .idle, .decoding, .uploading => {
            return error.TestExpectedQueuedDecode;
        },
    }
}

test "sysExecuteIntents - refresh avoids aliasing and uses archive source" {
    const allocator = std.testing.allocator;
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.createDirPath(io, "comics");

    const empty_zip = [_]u8{ 'P', 'K', 5, 6 } ++ @as([18]u8, @splat(0));
    var cbz_file = try tmp.dir.createFile(io, "comics/vol1.cbz", .{});
    var wr_slices = [_][]const u8{&empty_zip};
    _ = try cbz_file.writePositional(io, &wr_slices, 0);
    cbz_file.close(io);

    var sub_buf: [128]u8 = undefined;
    const sub_dir = try std.mem.print(
        &sub_buf,
        ".zig-cache/tmp/{s}/sub",
        .{tmp.sub_path},
    );
    var cbz_buf: [128]u8 = undefined;
    const cbz_path = try std.mem.print(
        &cbz_buf,
        ".zig-cache/tmp/{s}/comics/vol1.cbz",
        .{tmp.sub_path},
    );
    var comics_buf: [128]u8 = undefined;
    const comics_dir = try std.mem.print(
        &comics_buf,
        ".zig-cache/tmp/{s}/comics",
        .{tmp.sub_path},
    );

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // 1. Refresh when current_index is null and last_scanned_dir is populated
    // must not trigger a self-aliasing @memcpy panic in openPath.
    try app_st.viewer.navigation.last_scanned_dir.appendSlice(
        allocator,
        sub_dir,
    );
    try app_st.pushIntent(.refresh_directory);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    app_st.workers.group.await(io) catch {};
    try testing.expectEqualStrings(
        sub_dir,
        app_st.viewer.navigation.last_scanned_dir.items,
    );

    // 2. Refresh on an .archive_entry allocated in directory_arena must use
    // archive_path (not entry_name) and survive directory_arena.reset.
    const arena_alloc = app_st.viewer.navigation.directory_arena.allocator();
    const arch_p = try arena_alloc.dupe(u8, cbz_path);
    const entry_n = try arena_alloc.dupe(u8, "inner_pages/page01.jpg");
    _ = try app_st.viewer.navigation.appendEntry(allocator, .{
        .archive_entry = .{
            .archive_path = arch_p,
            .entry_name = entry_n,
            .seek_info = .unindexed,
        },
    });
    app_st.viewer.navigation.current_index = 0;

    try app_st.pushIntent(.refresh_directory);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    app_st.workers.group.await(io) catch {};
    try testing.expectEqualStrings(
        comics_dir,
        app_st.viewer.navigation.last_scanned_dir.items,
    );
}

test "togglePairStream - requires loaded status before requesting target" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const dir_alloc = app_st.viewer.navigation.directory_arena.allocator();
    const raw_p = try dir_alloc.dupe(u8, "photo.ARW");
    const jpg_p = try dir_alloc.dupe(u8, "photo.JPG");
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p } },
    );
    app_st.viewer.navigation.current_index = 0;
    const id0 = app_st.viewer.navigation.getIdAt(0).?;

    const ticket0 = app_st.cache.allocJob().?;
    const key0 = try app_st.cache.appendSlot(allocator, id0, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket0 },
        },
    });
    const entry0 = app_st.cache.get(key0).?;
    entry0.metadata.raw_metadata = RawMetadata.init(6000, 4000);

    // 1. While inflight, toggle_pair_stream must be ignored.
    try executeIntent(&app_st, .toggle_pair_stream, 1000);
    switch (entry0.inflight) {
        .decoding => |d| try std.testing.expectEqual(
            PairStreamTarget.adaptive,
            d.target,
        ),
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }

    // 2. Once .loaded_gpu, toggle_pair_stream sets inflight target.
    app_st.cache.setInFlight(key0, .idle);
    entry0.resident.asset = .{
        .loaded_gpu = .{
            .gpu_texture = undefined,
            .w = 1616,
            .h = 1080,
            .size_bytes = 500_000,
            .ingest = .{ .memory_size_bytes = 7_000_000 },
        },
    };
    try executeIntent(&app_st, .toggle_pair_stream, 1000);
    switch (entry0.inflight) {
        .queued_decode => |q| try std.testing.expectEqual(
            PairStreamTarget.standalone_jpeg,
            q.target,
        ),
        .idle, .decoding, .uploading => {
            return error.TestExpectedQueuedDecode;
        },
    }
}

test "executeIntent - navigating onto failed slide skips crossfade" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const dir_alloc = app_st.viewer.navigation.directory_arena.allocator();
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, "a.jpg") } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, "b.jpg") } },
    );
    app_st.viewer.navigation.current_index = 0;
    app_st.viewer.navigation.crossfade = true;
    const id0_failed = app_st.viewer.navigation.getIdAt(0).?;
    const id1_failed = app_st.viewer.navigation.getIdAt(1).?;

    _ = try app_st.cache.appendSlot(allocator, id0_failed, .{
        .inflight = .{ .queued_decode = .{} },
    });
    _ = try app_st.cache.appendSlot(allocator, id1_failed, .{
        .resident = .{ .asset = .failed },
    });

    try executeIntent(&app_st, .next_image, 1000);
    try std.testing.expectEqual(
        @as(?usize, 1),
        app_st.viewer.navigation.current_index,
    );
    try std.testing.expectEqual(
        state.ImageTransition.none,
        app_st.viewer.image_transition,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.image_crossfade),
        0.001,
    );
}

fn waitAndDrainPaletteScan(app_st: *AppState, io: std.Io) !void {
    try app_st.workers.group.await(io);
    _ = events.drainWorkerEvents(app_st, 1000);
}

test "executeIntent - set_palette directory_navigator clears previous query" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "alpha_dir", .default_dir);
    try tmp.dir.createDir(io, "beta_dir", .default_dir);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..len];

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.ui.palette.lifecycle = .{ .open = .directory_navigator };
    app_st.viewer.animations.setImmediate(.palette_reveal, 1.0);
    try app_st.viewer.ui.palette.query.appendSlice(allocator, "nonmatching");

    try executeIntent(&app_st, .{
        .set_palette = .{
            .mode = .directory_navigator,
            .query = tmp_path,
        },
    }, 1000);
    try waitAndDrainPaletteScan(&app_st, io);

    const open_mode = app_st.viewer.ui.palette.openMode() orelse {
        return error.TestUnexpectedResult;
    };
    switch (open_mode) {
        .directory_navigator => {},
        .files, .actions, .prompt => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.viewer.ui.palette.query.items.len,
    );
    try std.testing.expectEqualStrings(
        tmp_path,
        app_st.viewer.ui.palette.current_nav_dir.items,
    );
    try std.testing.expect(app_st.viewer.ui.palette.matches.items.len >= 2);
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.palette_reveal),
        0.001,
    );
}

test "executeIntent - set_palette directory_navigator with query from closed" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "alpha_dir", .default_dir);
    try tmp.dir.createDir(io, "beta_dir", .default_dir);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..len];

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try executeIntent(&app_st, .{
        .set_palette = .{
            .mode = .directory_navigator,
            .query = tmp_path,
        },
    }, 1000);
    try waitAndDrainPaletteScan(&app_st, io);

    const open_mode = app_st.viewer.ui.palette.openMode() orelse {
        return error.TestUnexpectedResult;
    };
    switch (open_mode) {
        .directory_navigator => {},
        .files, .actions, .prompt => return error.TestUnexpectedResult,
    }
    try std.testing.expect(app_st.viewer.animations.isActive(.palette_reveal));
    try std.testing.expectEqualStrings(
        tmp_path,
        app_st.viewer.ui.palette.current_nav_dir.items,
    );
    try std.testing.expect(app_st.viewer.ui.palette.matches.items.len >= 2);

    sysUpdateAnimations(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = state.DURATION_PALETTE_OPEN_MS,
    });
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.palette_reveal),
        0.001,
    );
}

test "executeIntent - set_palette directory_navigator from closing" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "alpha_dir", .default_dir);
    try tmp.dir.createDir(io, "beta_dir", .default_dir);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..len];

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try app_st.openPalette(.actions);
    sysUpdateAnimations(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = state.DURATION_PALETTE_OPEN_MS,
    });
    try app_st.viewer.ui.palette.query.appendSlice(allocator, "stale");
    try app_st.viewer.ui.palette.last_child_dir.appendSlice(
        allocator,
        "stale_child",
    );
    app_st.closePalette();
    sysUpdateAnimations(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = state.DURATION_PALETTE_CLOSE_MS * 0.5,
    });
    switch (app_st.viewer.ui.palette.lifecycle) {
        .closing => |m| switch (m) {
            .actions => {},
            .files, .directory_navigator, .prompt => {
                return error.TestUnexpectedResult;
            },
        },
        .closed, .open => return error.TestUnexpectedResult,
    }
    try std.testing.expect(
        app_st.viewer.animations.get(.palette_reveal) < 0.8,
    );

    try executeIntent(&app_st, .{
        .set_palette = .{
            .mode = .directory_navigator,
            .query = tmp_path,
        },
    }, 1000);
    try waitAndDrainPaletteScan(&app_st, io);

    const open_mode = app_st.viewer.ui.palette.openMode() orelse {
        return error.TestUnexpectedResult;
    };
    switch (open_mode) {
        .directory_navigator => {},
        .files, .actions, .prompt => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.viewer.ui.palette.query.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.viewer.ui.palette.last_child_dir.items.len,
    );
    try std.testing.expectEqualStrings(
        tmp_path,
        app_st.viewer.ui.palette.current_nav_dir.items,
    );
    try std.testing.expect(app_st.viewer.ui.palette.matches.items.len >= 2);
    try std.testing.expect(app_st.viewer.animations.isActive(.palette_reveal));

    sysUpdateAnimations(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = state.DURATION_PALETTE_OPEN_MS,
    });
    const settled_mode = app_st.viewer.ui.palette.openMode() orelse {
        return error.TestUnexpectedResult;
    };
    switch (settled_mode) {
        .directory_navigator => {},
        .files, .actions, .prompt => return error.TestUnexpectedResult,
    }
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.palette_reveal),
        0.001,
    );
}

test "executeIntent - set_palette directory_navigator from open actions" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "alpha_dir", .default_dir);
    try tmp.dir.createDir(io, "beta_dir", .default_dir);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..len];

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try app_st.openPalette(.actions);
    sysUpdateAnimations(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = state.DURATION_PALETTE_OPEN_MS,
    });
    try app_st.viewer.ui.palette.query.appendSlice(allocator, "zoom");

    try executeIntent(&app_st, .{
        .set_palette = .{
            .mode = .directory_navigator,
            .query = tmp_path,
        },
    }, 1000);
    try waitAndDrainPaletteScan(&app_st, io);

    const open_mode = app_st.viewer.ui.palette.openMode() orelse {
        return error.TestUnexpectedResult;
    };
    switch (open_mode) {
        .directory_navigator => {},
        .files, .actions, .prompt => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.viewer.ui.palette.query.items.len,
    );
    try std.testing.expectEqualStrings(
        tmp_path,
        app_st.viewer.ui.palette.current_nav_dir.items,
    );
    try std.testing.expect(app_st.viewer.ui.palette.matches.items.len >= 2);
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.palette_reveal),
        0.001,
    );
}

test "executeIntent - syncs rotation and zoom on nav, rotate, and set_zoom" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const dir_alloc = app_st.viewer.navigation.directory_arena.allocator();
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, "slide0.jpg") } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, "slide1.jpg") } },
    );
    app_st.viewer.navigation.current_index = 0;
    const id0 = app_st.viewer.navigation.getIdAt(0).?;
    const id1 = app_st.viewer.navigation.getIdAt(1).?;

    // Slide 0: 4000x2000 unrotated -> in 1024x768 headless viewport,
    // base scale is 1024/4000 = 0.256
    const key0 = try app_st.cache.appendSlot(allocator, id0, .{
        .inflight = .{ .queued_decode = .{} },
    });
    const entry0 = app_st.cache.get(key0).?;
    entry0.metadata.full_dims = .{ .w = 4000, .h = 2000 };
    entry0.metadata.orientation = .normal;

    // Slide 1: 4000x2000 with EXIF 90 deg rotation -> rotated dims 2000x4000,
    // base scale is 768/4000 = 0.192
    const key1 = try app_st.cache.appendSlot(allocator, id1, .{
        .inflight = .{ .queued_decode = .{} },
    });
    const entry1 = app_st.cache.get(key1).?;
    entry1.metadata.full_dims = .{ .w = 4000, .h = 2000 };
    entry1.metadata.orientation = .rotate_90;

    // 1. Navigating from slide 0 to slide 1 must update rotation_angle
    // BEFORE getBaseScale()
    app_st.viewer.pan_controller.tap = .{
        .active = .{
            .direction = .{ .right = true },
            .remaining_px = 15.0,
        },
    };
    try executeIntent(&app_st, .next_image, 1000);
    try std.testing.expectEqual(
        @as(?usize, 1),
        app_st.viewer.navigation.current_index,
    );
    try std.testing.expectEqual(
        @as(f32, 90.0),
        app_st.viewer.viewport.rotation_angle,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 768.0 / 4000.0),
        app_st.viewer.viewport.zoom_factor.get(),
        0.0001,
    );
    try std.testing.expectEqual(
        state.PanTap.idle,
        app_st.viewer.pan_controller.tap,
    );

    // 2. Rotating CW (90 -> 180) while in fit mode must resync zoom_factor
    // to unswapped 1024/4000
    try executeIntent(&app_st, .rotate_cw, 1000);
    try std.testing.expectEqual(
        @as(f32, 180.0),
        app_st.viewer.viewport.rotation_angle,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 1024.0 / 4000.0),
        app_st.viewer.viewport.zoom_factor.get(),
        0.0001,
    );

    // 3. Resetting rotation restores EXIF 90 deg and resyncs zoom_factor
    try executeIntent(&app_st, .reset_rotation, 1000);
    try std.testing.expectEqual(
        @as(f32, 90.0),
        app_st.viewer.viewport.rotation_angle,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 768.0 / 4000.0),
        app_st.viewer.viewport.zoom_factor.get(),
        0.0001,
    );

    // 4. set_zoom scales pan_x and pan_y proportionally
    try executeIntent(&app_st, .{ .set_zoom = 1.0 }, 1000);
    app_st.viewer.viewport.setPan(100.0, -40.0);
    try executeIntent(&app_st, .{ .set_zoom = 2.5 }, 1000);
    try std.testing.expectApproxEqAbs(
        @as(f32, 250.0),
        app_st.viewer.viewport.pan_x,
        0.001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, -100.0),
        app_st.viewer.viewport.pan_y,
        0.001,
    );
}

test "executeIntent - precache_directory handles disabled cache and empty playlist" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // When thumbnail cache is disabled (default in initHeadless), shows snackbar message
    app_st.viewer.ui.snackbar.enabled = true;
    try executeIntent(&app_st, .precache_directory, 1000);
    try std.testing.expectEqualStrings(
        "Thumbnail cache is disabled",
        app_st.viewer.ui.snackbar.getMessage(),
    );
}

test "executeIntent - server_mode hides on quit and exits on quit_server" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.server_mode = true;
    app_st.viewer.defaults = .{
        .default_scale = .shrink,
        .enable_blur = false,
        .show_title = true,
        .stack_raw_jpeg = false,
    };
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img0.jpg" } },
    );
    app_st.viewer.navigation.current_index = 0;
    const id0 = app_st.viewer.navigation.getIdAt(0).?;
    _ = try app_st.viewer.navigation.markCurrentPick(allocator);
    _ = try app_st.cache.appendSlot(allocator, id0, .{
        .resident = .{ .asset = .failed },
    });
    app_st.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 2.0 } };

    // Mutate session settings (adjustments, filter, scale, overlays, nav modes)
    app_st.viewer.viewport.setAdjustments(0.35, 1.5);
    app_st.viewer.viewport.scale_filter = .mitchell;
    app_st.viewer.viewport.fit_mode = .crop;
    app_st.viewer.ui.overlays.enable_blur = true;
    app_st.viewer.ui.overlays.title_display = .hidden;
    app_st.viewer.ui.overlays.edit_panel.visible = true;
    app_st.viewer.animations.setImmediate(.edit_panel, 1.0);
    app_st.viewer.navigation.manga_mode = true;
    app_st.viewer.navigation.crossfade = false;
    app_st.viewer.navigation.stack_raw_jpeg = true;
    app_st.viewer.navigation.triage.view_mode = .picks;

    app_st.viewer.ui.interaction.palette_scroll_y = 120.0;

    // .quit in server_mode hides the window, stops slideshow, resets all
    // session settings back to startup defaults, and unloads cache and
    // directory playlist while preserving picks/rejects selections.
    try app_st.pushIntent(.quit);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
        .now_ms = 1000,
    });
    try std.testing.expect(app_st.viewer.running);
    try std.testing.expect(app_st.display.isHidden());
    try std.testing.expect(!app_st.viewer.isSlideshowActive());
    try std.testing.expect(!app_st.viewer.viewport.hasAdjustments());
    try std.testing.expectEqual(
        intents.TextureScaleMode.linear,
        app_st.viewer.viewport.scale_filter,
    );
    try std.testing.expectEqual(
        intents.ZoomPreset.shrink,
        app_st.viewer.viewport.fit_mode,
    );
    try std.testing.expect(!app_st.viewer.ui.overlays.enable_blur);
    try std.testing.expectEqual(
        state.TitleDisplay.pinned,
        app_st.viewer.ui.overlays.title_display,
    );
    try std.testing.expect(!app_st.viewer.ui.overlays.edit_panel.visible);
    try std.testing.expectEqual(
        @as(f32, 0.0),
        app_st.viewer.animations.get(.edit_panel),
    );
    try std.testing.expectEqual(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.title_overlay),
    );
    try std.testing.expectEqual(
        @as(f32, 0.0),
        app_st.viewer.ui.interaction.palette_scroll_y,
    );
    try std.testing.expect(!app_st.viewer.navigation.manga_mode);
    try std.testing.expect(app_st.viewer.navigation.crossfade);
    try std.testing.expect(!app_st.viewer.navigation.stack_raw_jpeg);
    try std.testing.expectEqual(
        triage.ViewMode.default,
        app_st.viewer.navigation.triage.view_mode,
    );
    try std.testing.expectEqual(@as(usize, 0), app_st.cache.count());
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.viewer.navigation.count(),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.viewer.navigation.triage.count(),
    );

    // clear_classifications while hidden clears selections without starting a
    // snackbar animation
    try app_st.pushIntent(.clear_classifications);
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
        .now_ms = 1000,
    });
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.viewer.navigation.triage.count(),
    );
    try std.testing.expect(!app_st.viewer.animations.isActive(.snackbar));
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.viewer.ui.snackbar.getMessage().len,
    );

    // .quit_server unconditionally terminates the server
    try executeIntent(&app_st, .quit_server, 1000);
    try std.testing.expect(!app_st.viewer.running);
}

test "togglePairStream - Cancels existing job epoch on stream switch" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{
            .pair = .{
                .raw_path = "img0.raf",
                .jpeg_path = "img0.jpg",
            },
        },
    );
    app_st.viewer.navigation.current_index = 0;
    const id0 = app_st.viewer.navigation.getIdAt(0).?;

    const ticket = app_st.cache.allocJob().?;
    const surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32).?;
    const key = try app_st.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 16.0,
                        .h = 16.0,
                        .size_bytes = 1024,
                        .mime_type = "image/jpeg",
                        .decode = .{},
                    },
                },
            },
        },
        .inflight = .{
            .decoding = .{
                .target = .raw_preview,
                .ticket = ticket,
            },
        },
        .metadata = .{
            .raw_metadata = RawMetadata.init(6000, 4000),
        },
    });

    try std.testing.expectEqual(@as(u32, 1), ticket.epoch);
    try std.testing.expect(app_st.cache.job_alloc_mask != 0);

    togglePairStream(&app_st, 1000);

    // Job ticket epoch must have advanced to signal cancellation
    try std.testing.expectEqual(
        @as(u32, 2),
        app_st.cache.job_epochs[ticket.job_id].load(.acquire),
    );
    // Ticket slot was released
    try std.testing.expectEqual(@as(u16, 0), app_st.cache.job_alloc_mask);

    // New inflight task is queued with opposite stream target
    switch (app_st.cache.get(key).?.inflight) {
        .queued_decode => |q| {
            try std.testing.expectEqual(
                PairStreamTarget.standalone_jpeg,
                q.target,
            );
            try std.testing.expectEqual(@as(u64, 1000), q.start_time_ms);
        },
        .idle, .decoding, .uploading => {
            return error.TestExpectedQueuedDecode;
        },
    }
}

test "togglePairStream - clears staged promoting_gpu without blanking" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{
            .pair = .{
                .raw_path = "img0.raf",
                .jpeg_path = "img0.jpg",
            },
        },
    );
    app_st.viewer.navigation.current_index = 0;
    const id0 = app_st.viewer.navigation.getIdAt(0).?;

    const pending_surf = sdl.Surface.create(
        32,
        32,
        sdl.PixelFormat.rgba32,
    ) orelse return;
    const stub = CacheEntry.stubLoadedGpuForTest(
        .{ .w = 16.0, .h = 16.0 },
        .{ .w = 0.0, .h = 0.0 },
    );
    const active_gpu = switch (stub.resident.asset) {
        .loaded_gpu => |g| g,
        .none, .loaded_cpu, .promoting_gpu, .failed => unreachable,
    };
    const key = try app_st.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .promoting_gpu = .{
                    .active = active_gpu,
                    .staged = .{
                        .cpu = .{
                            .surface = pending_surf,
                            .w = 32.0,
                            .h = 32.0,
                            .size_bytes = 4096,
                        },
                    },
                },
            },
        },
        .metadata = .{
            .raw_metadata = RawMetadata.init(6000, 4000),
        },
    });

    togglePairStream(&app_st, 2000);

    const entry = app_st.cache.get(key).?;
    switch (entry.resident.asset) {
        .loaded_gpu => {},
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }
    switch (entry.inflight) {
        .queued_decode => |q| {
            try std.testing.expectEqual(
                PairStreamTarget.standalone_jpeg,
                q.target,
            );
            try std.testing.expectEqual(@as(u64, 2000), q.start_time_ms);
        },
        .idle, .decoding, .uploading => {
            return error.TestExpectedQueuedDecode;
        },
    }
}

test "executeIntent - start_slideshow opens prompt and clamps interval" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try executeIntent(&app_st, .start_slideshow, 1000);
    try std.testing.expectEqual(
        @as(?intents.ActivePaletteMode, .{ .prompt = .slideshow_interval }),
        app_st.viewer.ui.palette.openMode(),
    );
    try std.testing.expectEqualStrings(
        "3.0",
        app_st.viewer.ui.palette.query.items,
    );

    // Clamps below minimum to MIN_INTERVAL_S
    try executeIntent(&app_st, .{ .start_slideshow_interval = 0.005 }, 1000);
    try std.testing.expectEqual(
        state.SlideshowMode.MIN_INTERVAL_S,
        app_st.viewer.navigation.slideshow.active.interval_s,
    );

    // Clamps above maximum to MAX_INTERVAL_S
    try executeIntent(&app_st, .{ .start_slideshow_interval = 99999.0 }, 1000);
    try std.testing.expectEqual(
        state.SlideshowMode.MAX_INTERVAL_S,
        app_st.viewer.navigation.slideshow.active.interval_s,
    );

    // Sets valid interval and ignores NaN
    try executeIntent(&app_st, .{ .start_slideshow_interval = 7.5 }, 1000);
    try executeIntent(
        &app_st,
        .{ .start_slideshow_interval = std.math.nan(f32) },
        1000,
    );
    try std.testing.expectEqual(
        @as(f32, 7.5),
        app_st.viewer.navigation.slideshow.active.interval_s,
    );
}

test "executeIntent - zoom_by clamps f32 underflow to ZoomFactor.MIN" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.viewport.mode = .manual;
    app_st.viewer.viewport.zoom_factor = state.ZoomFactor.init(
        state.ZoomFactor.MIN,
    );
    app_st.viewer.viewport.pan_x = 10.0;
    app_st.viewer.viewport.pan_y = -10.0;

    try executeIntent(
        &app_st,
        .{
            .zoom_by = .{
                .ratio = 1e-43,
                .snap_zoom = null,
            },
        },
        1000,
    );

    try std.testing.expectEqual(
        state.ZoomFactor.MIN,
        app_st.viewer.viewport.zoom_factor.get(),
    );
    try std.testing.expectEqual(@as(f32, 10.0), app_st.viewer.viewport.pan_x);
    try std.testing.expectEqual(@as(f32, -10.0), app_st.viewer.viewport.pan_y);
}

test "executeIntent - saturates snackbar and title deadlines near max u64" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const near_max = std.math.maxInt(u64) - 10;

    // 1. Declarative intent snackbar deadline (applyIntentSnackbar)
    try app_st.pushIntent(.{ .set_filter = .mitchell });
    try sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
        .now_ms = near_max,
    });
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        app_st.viewer.ui.snackbar.getTimeoutMs(),
    );

    // 2. Custom snackbar deadline (showCustomSnackbar)
    app_st.workers.thumb_cache_config = .disabled;
    try executeIntent(&app_st, .precache_directory, near_max);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        app_st.viewer.ui.snackbar.getTimeoutMs(),
    );

    // 3. Auto-title overlay deadline (title_display.transient)
    const item = MediaEntry{ .filesystem = .{ .path = "test.jpg" } };
    _ = try app_st.viewer.navigation.appendEntry(allocator, item);
    _ = try app_st.viewer.navigation.appendEntry(allocator, item);
    app_st.viewer.navigation.current_index = 0;
    app_st.viewer.navigation.cadence.recordNavigation(near_max - 50);
    try executeIntent(&app_st, .next_image, near_max);
    switch (app_st.viewer.ui.overlays.title_display) {
        .transient => |t| try std.testing.expectEqual(
            std.math.maxInt(u64),
            t.timeout_ms,
        ),
        .hidden, .pinned => return error.TestExpectedTransientTitle,
    }
}
