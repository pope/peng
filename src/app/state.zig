const clay = @import("zclay");
const core_fs = @import("core/fs.zig");
const events = @import("core/events.zig");
const exif = @import("core/exif.zig");
const image = @import("core/image.zig");
const intents = @import("intents");
const ipc = @import("ipc");
const palette_module = @import("core/palette.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const workers_mod = @import("workers/root.zig");

const AppIntent = intents.AppIntent;
const CacheEntry = state_pkg.CacheEntry;
const CacheKey = image.CacheKey;
const CacheSlotMap = image.CacheSlotMap;
const CacheStatus = state_pkg.CacheStatus;
const DisplayState = state_pkg.DisplayState;
const FrameInput = types.FrameInput;
const PaletteMode = intents.PaletteMode;
const types = state_pkg.types;
const view_transform = state_pkg.view_transform;
const ViewerState = state_pkg.ViewerState;

/// Enables SDL text input events if the current display mode is windowed GUI.
/// No-op when in headless rendering mode.
pub fn startTextInput(display: DisplayState) void {
    switch (display) {
        .headless => {},
        .windowed => |win| {
            if (!win.handle.startTextInput()) {
                std.log.err("SDL_StartTextInput failed: {s}", .{sdl.getError()});
            }
        },
    }
}

/// Disables SDL text input events if the current display mode is windowed GUI.
/// No-op when in headless rendering mode.
pub fn stopTextInput(display: DisplayState) void {
    switch (display) {
        .headless => {},
        .windowed => |win| {
            if (!win.handle.stopTextInput()) {
                std.log.err("SDL_StopTextInput failed: {s}", .{sdl.getError()});
            }
        },
    }
}

/// Cohesive GPU context and render resources initialized for GPU-accelerated rendering.
/// Main Application State Architecture
///
/// Single-Threaded ViewerState Model:
/// - `ViewerState` lives 100% on the main thread and contains ZERO mutexes.
/// - Background workers (decode, scan, IPC) run as isolated tasks that receive plain
///   value copies of parameters (paths, generation counters) and touch zero shared state.
/// - Workers communicate exclusively by pushing event messages into `event_queue` (MpscQueue).
/// - The main thread consumes background events during frame updates and updates `ViewerState` safely.
/// Main Top-Level Application State & Engine Container.
///
/// Owns the visual model (`viewer: ViewerState`), hardware contexts (`gpu_device`),
/// memory allocators (`allocator`), async I/O (`io`), worker task pools (`workers`),
/// texture slot caches (`cache`), and event/command queues.
pub const AppState = struct {
    /// Pure Visual & UI State Model
    viewer: ViewerState,

    /// Hardware & Pipeline Resources
    gpu_device: ?sdl.gpu.Device = null,
    unpack_compute_pipeline: ?sdl.gpu.ComputePipeline = null,

    /// Memory & Async I/O Context
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Subsystems
    cache: CacheSlotMap,
    workers: workers_mod.WorkerManager = .{},
    upload_staging: image.UploadStagingBuffer = .{},

    /// Queues
    event_batch: std.ArrayList(events.BackgroundEvent) = .empty,
    pending_ipc_commands: std.ArrayList(*ipc.IpcCommandData) = .empty,
    pending_intents: std.ArrayList(AppIntent) = .empty,

    /// Initializes top-level `AppState` in headless mode without creating an SDL window, suitable for tests.
    pub fn initHeadless(allocator: std.mem.Allocator, io: std.Io) !AppState {
        var state = AppState{
            .viewer = try ViewerState.initHeadless(allocator),
            .cache = .{},
            .workers = .init(),
            .allocator = allocator,
            .io = io,
        };
        errdefer state.viewer.deinit(allocator, io);
        try state.ensureInitialCapacities();
        return state;
    }

    /// Pre-allocates initial buffer capacities for intent, event, and IPC command queues.
    pub fn ensureInitialCapacities(self: *AppState) !void {
        if (self.workers.cached_cpu_count == 0) {
            self.workers.cached_cpu_count = std.Thread.getCpuCount() catch |err| blk: {
                std.log.warn("Failed to query CPU core count: {}, defaulting to 4", .{err});
                break :blk 4;
            };
        }
        // 16 intents: accommodates worst-case enqueued IPC, keyboard, palette, and slideshow intents in a single tick
        try self.pending_intents.ensureTotalCapacity(self.allocator, 16);
        errdefer self.pending_intents.deinit(self.allocator);
        // 16 events: accommodates concurrent worker background events (decodes, EXIF, path scans) processed per tick
        try self.event_batch.ensureTotalCapacity(self.allocator, 16);
        errdefer self.event_batch.deinit(self.allocator);
        // 8 commands: accommodates queued socket IPC command buffers
        try self.pending_ipc_commands.ensureTotalCapacity(self.allocator, 8);
    }

    /// Enqueues an application intent to be dispatched and executed during the next frame pass.
    pub fn pushIntent(self: *AppState, intent: AppIntent) !void {
        try self.pending_intents.append(self.allocator, intent);
    }

    /// Clears all queued application intents while retaining array capacity.
    pub fn clearIntents(self: *AppState) void {
        self.pending_intents.clearRetainingCapacity();
    }

    /// Returns `true` if files are currently loading, background workers are active, active unpaused slideshow is running, or animations are active.
    pub inline fn isBusy(self: *const AppState) bool {
        return self.viewer.hasActiveAnimation() or
            self.viewer.navigation.is_loading_files.load(.acquire) or
            self.workers.isBusy() or
            (self.viewer.isSlideshowActive() and !self.isSlideshowPaused());
    }

    /// Returns `true` if the currently active slide is still decoding or awaiting GPU texture upload.
    /// Note: Terminal states (.failed and headless .loaded_cpu) return false to avoid deadlock.
    pub fn isCurrentSlideLoading(self: *const AppState) bool {
        const cur_idx = self.viewer.navigation.current_index orelse return false;
        const entry = self.cache.getEntry(self.cache.activeKey(cur_idx)) orelse return false;
        return switch (entry.status) {
            .decoding, .uploading => true,
            .loaded_cpu => self.gpu_device != null,
            .loaded_gpu, .failed => false,
        };
    }

    /// Returns `true` if slideshow mode is active but paused due to explicit pause, active modal, user dragging, or slide loading.
    pub fn isSlideshowPaused(self: *const AppState) bool {
        if (!self.viewer.isSlideshowActive()) return false;
        return self.viewer.navigation.slideshow.isPaused() or
            self.viewer.ui.palette.isOpen() or
            self.viewer.drag_state != .none or
            self.isCurrentSlideLoading();
    }

    /// Returns the CacheEntry corresponding to the previous slide in an active crossfade, if available.
    pub fn getTransitionPrevEntry(self: *const AppState) ?CacheEntry {
        const prev_idx = self.viewer.getTransitionPrevIndex() orelse return null;
        return self.cache.getEntry(self.cache.activeKey(prev_idx));
    }

    /// Returns the override or EXIF rotation in degrees for the previous slide in an active crossfade.
    pub fn getTransitionPrevRotation(self: *const AppState) f32 {
        return switch (self.viewer.image_transition) {
            .none => 0.0,
            .active => |t| t.prev_rotation,
        };
    }

    /// Returns the remaining millisecond deadline for transient holding timers (e.g. title auto-hide, snackbar), or null if none active.
    pub fn getWaitTimeoutMs(self: *const AppState, now: u64) ?i32 {
        var min_rem: ?u64 = null;
        if (!self.viewer.ui.overlays.show_title and self.viewer.ui.title_auto_hide_timeout_ms > 0) {
            min_rem = self.viewer.ui.title_auto_hide_timeout_ms -| now;
        }
        if (self.viewer.ui.snackbar.timeout_ms > 0) {
            const rem = self.viewer.ui.snackbar.timeout_ms -| now;
            min_rem = if (min_rem) |cur| @min(cur, rem) else rem;
        }
        if (min_rem) |rem| {
            return @intCast(@min(rem, 2000));
        }
        return null;
    }

    /// Reads EXIF orientation from a JPEG file header on disk, returning `null` if unparseable.
    pub fn readJpegExifOrientation(self: *const AppState, path: []const u8) ?state_pkg.Orientation {
        return exif.readJpegExifOrientation(self.io, path);
    }

    /// Releases all engine resources, cancels background worker tasks, and frees GPU textures and queues.
    pub fn deinit(self: *AppState) void {
        self.workers.drainAndQuiesce(self.io);

        if (self.gpu_device) |dev| {
            self.upload_staging.deinit(dev);

            switch (self.viewer.display) {
                .headless => {},
                .windowed => |*w| {
                    if (w.claimed) {
                        w.handle.releaseFromGpu(dev);
                    }
                },
            }

            self.cache.deinit(self.allocator, dev);
        } else {
            self.cache.deinit(self.allocator, null);
        }

        for (self.pending_ipc_commands.items) |cmd_data| {
            cmd_data.client_stream.close(self.io);
            self.allocator.free(cmd_data.command);
            self.allocator.destroy(cmd_data);
        }
        self.viewer.deinit(self.allocator, self.io);
        self.pending_ipc_commands.deinit(self.allocator);
        self.pending_intents.deinit(self.allocator);
        self.event_batch.deinit(self.allocator);
        self.workers.event_queue.deinit(self.allocator, self.io);
    }

    /// Stores a user-overridden rotation angle for the given media path in the persistent rotation map.
    pub fn putRotation(self: *AppState, path: []const u8, angle: f32) !void {
        try self.viewer.putRotation(self.allocator, path, angle);
    }

    /// Clears all user rotation overrides and frees associated path memory.
    pub fn clearRotationMap(self: *AppState) void {
        self.viewer.clearRotationMap(self.allocator);
    }

    /// Resets current viewport zoom and pan offsets to default fit values.
    pub fn resetZoomPan(self: *AppState) void {
        self.viewer.resetZoomPan();
    }

    /// Computes the unzoomed base scale factor fitting the current image to the viewport according to fit_mode.
    fn getBaseScale(self: *AppState) f32 {
        const entry = self.getCurrentEntry() orelse return 1.0;
        const raw_w: f32 = switch (entry.status) {
            .loaded_gpu => |gpu| gpu.w,
            .loaded_cpu => |cpu| cpu.w,
            else => if (entry.full_w > 0) entry.full_w else if (entry.thumbnail.getInfo()) |info| info.w else 0.0,
        };
        const raw_h: f32 = switch (entry.status) {
            .loaded_gpu => |gpu| gpu.h,
            .loaded_cpu => |cpu| cpu.h,
            else => if (entry.full_h > 0) entry.full_h else if (entry.thumbnail.getInfo()) |info| info.h else 0.0,
        };
        if (raw_w <= 0.0 or raw_h <= 0.0) return 1.0;

        var pix_w: i32 = 1024;
        var pix_h: i32 = 768;
        var win_w: f32 = 1024.0;
        var win_h: f32 = 768.0;

        switch (self.viewer.display) {
            .headless => {},
            .windowed => |win| {
                const pix_size = win.handle.getSizeInPixels();
                if (pix_size.w > 0 and pix_size.h > 0) {
                    pix_w = pix_size.w;
                    pix_h = pix_size.h;
                }
                const win_size = win.handle.getSize();
                if (win_size.w > 0 and win_size.h > 0) {
                    win_w = @floatFromInt(win_size.w);
                    win_h = @floatFromInt(win_size.h);
                }
            },
        }

        var available_width = win_w;
        if (clay.isDebugModeEnabled()) {
            available_width = @max(available_width - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0);
        }
        const view_w = @max(available_width, 1.0);
        const view_h = @max(win_h, 1.0);

        const dims = view_transform.computeViewDims(raw_w, raw_h, self.viewer.viewport.rotation_angle, view_w, view_h, self.viewer.viewport.fit_mode);
        return dims.base_scale;
    }

    /// Returns true if the pointer position in input is currently within the Clay debug UI hierarchy panel.
    pub fn isPointerInDebugPanel(self: *const AppState, input: FrameInput) bool {
        _ = self;
        return input.isPointerInDebugPanel();
    }

    /// Clamps a requested zoom factor to the safe min/max bounds determined by base scale.
    pub fn clampZoomFactor(self: *AppState, new_factor: f32) types.ZoomFactor {
        const base_scale = self.getBaseScale();
        return view_transform.clampZoomFactor(base_scale, new_factor);
    }

    /// Rebuilds fuzzy search matches for the command palette image file list.
    pub fn rebuildPaletteMatches(self: *AppState) !void {
        try self.viewer.ui.palette.rebuildFileMatches(self.viewer.navigation.image_list.items);
    }

    /// Rebuilds fuzzy search matches for command palette action items.
    pub fn rebuildActionMatches(self: *AppState) !void {
        try self.viewer.ui.palette.rebuildActionMatches();
    }

    /// Returns a mutable pointer to the CacheEntry corresponding to the currently active image, or null.
    pub fn getCurrentEntryPtr(self: *AppState) ?*CacheEntry {
        const idx = self.viewer.navigation.current_index orelse return null;
        return self.cache.get(self.cache.activeKey(idx));
    }

    /// Returns a copy of the CacheEntry corresponding to the currently active image, or null.
    pub fn getCurrentEntry(self: *AppState) ?CacheEntry {
        if (self.getCurrentEntryPtr()) |entry| {
            return entry.*;
        }
        return null;
    }

    /// Releases all GPU textures and resets status across all cache slots.
    pub fn clearCache(self: *AppState) void {
        const dev_opt = self.gpu_device;
        self.cache.clear(dev_opt);
    }

    /// Synchronizes viewport rotation angle with active user rotation override, parsed EXIF orientation, or zero.
    pub fn updateCurrentRotation(self: *AppState) void {
        const media_opt = blk: {
            const len = self.viewer.navigation.image_list.items.len;
            const current_idx = self.viewer.navigation.current_index orelse break :blk null;
            if (current_idx >= len) break :blk null;
            break :blk self.viewer.navigation.image_list.items[current_idx];
        };

        const media = media_opt orelse {
            self.viewer.viewport.rotation_angle = 0.0;
            return;
        };

        if (self.viewer.rotation_map.get(media.getPath())) |user_rot| {
            self.viewer.viewport.rotation_angle = user_rot;
        } else if (self.getCurrentEntry()) |entry| {
            self.viewer.viewport.rotation_angle = entry.orientation.toDegrees();
        } else {
            self.viewer.viewport.rotation_angle = 0.0;
        }
    }

    /// Completes a pending IPC screenshot capture request after frame rendering, sending reply to client.
    pub fn handleScreenshotPostRender(self: *AppState, render_err: ?anyerror) void {
        switch (self.viewer.ui.screenshot_mode) {
            .idle => {},
            .capturing => |*s| {
                if (render_err) |err| {
                    s.respondErr(self.io, self.allocator, err);
                } else {
                    s.respondOk(self.io, self.allocator);
                }
                self.viewer.ui.screenshot_mode = .idle;
            },
        }
    }

    /// Initiates animated closing of the command palette, stopping text input.
    pub fn closePalette(self: *AppState) void {
        stopTextInput(self.viewer.display);
        self.viewer.ui.palette.is_closing = true;
        const progress = self.viewer.animations.get(.palette_reveal);
        const duration = @max(state_pkg.DURATION_PALETTE_CLOSE_MS * progress, 30.0);
        self.viewer.animations.start(.palette_reveal, 0.0, duration, .ease_out_quad);
    }

    /// Immediately closes and resets the command palette without animation.
    pub fn closePaletteImmediately(self: *AppState) void {
        stopTextInput(self.viewer.display);
        self.viewer.ui.palette.reset();
        self.viewer.animations.setImmediate(.palette_reveal, 0.0);
    }

    /// Loads directory items into the command palette directory navigator and spawns
    /// a background worker task to asynchronously count images and subdirectories.
    pub fn loadPaletteDirectory(self: *AppState, dir_path: []const u8) !void {
        try palette_module.loadDirectoryEntries(&self.viewer.ui.palette, self.io, dir_path);
        try workers_mod.spawnPaletteScanForItems(
            &self.workers,
            self.allocator,
            self.io,
            &self.viewer.ui.palette.dir_scan_generation,
            self.viewer.ui.palette.dir_items.items,
        );
    }

    /// Activates the command palette in the specified PaletteMode, resetting queries and starting text input.
    pub fn openPalette(self: *AppState, active_type: PaletteMode) !void {
        self.viewer.ui.palette.reset();
        self.viewer.ui.palette.mode = active_type;
        self.viewer.animations.start(.palette_reveal, 1.0, state_pkg.DURATION_PALETTE_OPEN_MS, .ease_out_cubic);
        self.viewer.ui.palette.selected_idx = switch (active_type) {
            .files => self.viewer.navigation.current_index orelse 0,
            else => 0,
        };
        self.viewer.ui.palette.selection_dirty = true;

        switch (active_type) {
            .files => try self.rebuildPaletteMatches(),
            .actions => try self.rebuildActionMatches(),
            .directory_navigator => {
                var preselect_child: ?[]const u8 = null;
                const start_dir = blk: {
                    if (self.viewer.navigation.current_index) |idx| {
                        if (idx < self.viewer.navigation.image_list.items.len) {
                            const media = self.viewer.navigation.image_list.items[idx];
                            switch (media) {
                                .archive_entry => |a| {
                                    preselect_child = std.fs.path.basename(a.archive_path);
                                    break :blk std.fs.path.dirname(a.archive_path) orelse ".";
                                },
                                .filesystem => |f| {
                                    if (std.fs.path.dirname(f.path)) |parent| {
                                        preselect_child = std.fs.path.basename(f.path);
                                        break :blk parent;
                                    } else {
                                        preselect_child = f.path;
                                        break :blk ".";
                                    }
                                },
                            }
                        }
                    }
                    if (self.viewer.navigation.last_scanned_dir.items.len > 0) {
                        break :blk self.viewer.navigation.last_scanned_dir.items;
                    }
                    if (self.viewer.ui.palette.last_nav_dir.items.len > 0) {
                        break :blk self.viewer.ui.palette.last_nav_dir.items;
                    }
                    break :blk ".";
                };
                if (preselect_child) |child| {
                    self.viewer.ui.palette.last_child_dir.clearRetainingCapacity();
                    try self.viewer.ui.palette.last_child_dir.appendSlice(self.allocator, child);
                }
                try self.loadPaletteDirectory(start_dir);
                while (self.viewer.ui.palette.dir_items.items.len == 0) {
                    const curr = self.viewer.ui.palette.current_nav_dir.items;
                    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                    if (core_fs.getParentDirBuf(curr, &parent_buf)) |parent_dir| {
                        if (!std.mem.eql(u8, parent_dir, curr)) {
                            try self.loadPaletteDirectory(parent_dir);
                            continue;
                        }
                    }
                    break;
                }
            },
            .set_slideshow_interval => {
                var buf: [32]u8 = undefined;
                const dur_secs = switch (self.viewer.navigation.slideshow) {
                    .active => |s| s.interval_s,
                    .inactive => 3.0,
                };
                const formatted = std.fmt.bufPrint(&buf, "{d:.1}", .{dur_secs}) catch |err| blk: {
                    std.log.warn("Failed to format slideshow interval string: {}, defaulting to 3.0", .{err});
                    break :blk "3.0";
                };
                try self.viewer.ui.palette.query.appendSlice(self.allocator, formatted);
            },
            .set_brightness, .set_contrast, .go_to_image, .inactive => {},
        }
        startTextInput(self.viewer.display);
    }

    /// Initiates loading a new target path (file or directory). Cancels in-flight tasks,
    /// clears cache, resets navigation, and starts background discovery workers.
    pub fn openPath(self: *AppState, path: []const u8) !void {
        var stat: std.Io.File.Stat = undefined;
        var has_stat = true;
        if (std.Io.Dir.statFile(std.Io.Dir.cwd(), self.io, path, .{})) |s| {
            stat = s;
        } else |err| {
            std.log.err("Failed to access path '{s}': {}", .{ path, err });
            has_stat = false;
        }

        const dir_target = if (has_stat and stat.kind == .directory)
            path
        else
            std.fs.path.dirname(path) orelse ".";

        self.viewer.navigation.last_scanned_dir.clearRetainingCapacity();
        try self.viewer.navigation.last_scanned_dir.appendSlice(self.allocator, dir_target);

        _ = self.cache.advanceGeneration();
        self.clearCache();
        self.clearRotationMap();
        self.viewer.navigation.image_list.clearRetainingCapacity();
        _ = self.viewer.navigation.directory_arena.reset(.retain_capacity);
        self.viewer.navigation.current_index = null;
        self.viewer.image_transition = .none;
        self.viewer.animations.setImmediate(.image_crossfade, 1.0);

        if (has_stat) {
            if (stat.kind == .directory) {
                try workers_mod.startAsyncPathScan(&self.workers, &self.viewer.navigation.is_loading_files, self.allocator, self.io, path, true);
            } else if (core_fs.isCbzFile(path)) {
                self.viewer.navigation.is_loading_files.store(true, .release);
                errdefer self.viewer.navigation.is_loading_files.store(false, .release);
                try workers_mod.startAsyncPathScan(&self.workers, &self.viewer.navigation.is_loading_files, self.allocator, self.io, path, false);
            } else {
                const dup = try self.viewer.navigation.directory_arena.allocator().dupe(u8, path);
                try self.viewer.navigation.image_list.append(self.allocator, .{ .filesystem = .{ .path = dup } });
                self.viewer.navigation.current_index = 0;

                try workers_mod.startAsyncPathScan(&self.workers, &self.viewer.navigation.is_loading_files, self.allocator, self.io, path, false);
            }
        }
        try self.rebuildPaletteMatches();
    }

    /// Ensures that the thumbnail GPU texture is loaded for the current entry.
    pub fn ensureCurrentThumbnailLoaded(self: *AppState) void {
        const e = self.getCurrentEntryPtr() orelse return;
        if (e.thumbnail == .loaded or e.thumbnail == .not_available) return;

        const idx = self.viewer.navigation.current_index orelse return;
        if (idx >= self.viewer.navigation.image_list.items.len) return;

        const media = self.viewer.navigation.image_list.items[idx];
        const extracted = image.loadThumbnailSurface(self.io, self.allocator, media) orelse {
            e.thumbnail = .not_available;
            return;
        };
        defer extracted.surface.destroy();

        const dev = self.gpu_device orelse return;
        const upload_res = image.uploadSurfaceToGpu(dev, extracted.surface, self.unpack_compute_pipeline, &self.upload_staging) orelse {
            e.thumbnail = .not_available;
            return;
        };

        switch (e.thumbnail) {
            .loaded => |thumb| dev.releaseTexture(thumb.texture),
            else => {},
        }

        if (extracted.orientation != .normal or e.orientation == .normal) {
            e.orientation = extracted.orientation;
        }
        if (extracted.full_w > 0 and extracted.full_h > 0 and (e.full_w <= 0 or e.full_h <= 0)) {
            e.full_w = extracted.full_w;
            e.full_h = extracted.full_h;
        }
        if (extracted.raw_metadata.isRaw()) {
            e.raw_metadata = extracted.raw_metadata;
        }

        e.thumbnail = .{
            .loaded = .{
                .texture = upload_res.gpu_texture,
                .info = .{
                    .w = upload_res.w,
                    .h = upload_res.h,
                    .upload_time_ms = upload_res.upload_time_ms,
                    .dct_snapped = extracted.dct_snapped,
                },
            },
        };
        self.updateCurrentRotation();
    }

    /// Scans cache slots around the current navigation index, evicting distant textures and uploading ready surfaces to the GPU.
    pub fn prepareCacheTextures(self: *AppState) void {
        if (self.gpu_device == null) return;

        var upload_target: ?struct {
            key: CacheKey,
            cpu: @TypeOf(@as(CacheStatus, undefined).loaded_cpu),
        } = null;

        const entries = self.cache.slots.items(.entry);
        const keys = self.cache.slots.items(.key);

        for (entries, keys) |*entry, key| {
            const is_crossfading = self.viewer.animations.isActive(.thumb_crossfade) and
                (if (self.viewer.navigation.current_index) |cur| self.cache.activeKey(cur).index == key.index else false);
            if (!is_crossfading and entry.status == .loaded_gpu and !self.viewer.ui.overlays.debug_show_thumb) {
                switch (entry.thumbnail) {
                    .loaded => |thumb| {
                        if (self.gpu_device) |gpu_dev| {
                            gpu_dev.releaseTexture(thumb.texture);
                        }
                        entry.thumbnail = .{ .unloaded = thumb.info };
                    },
                    else => {},
                }
            }
        }

        if (self.viewer.ui.overlays.debug_show_thumb) {
            if (self.getCurrentEntryPtr()) |cur_e| {
                if (cur_e.thumbnail != .loaded and cur_e.thumbnail != .not_available) {
                    self.ensureCurrentThumbnailLoaded();
                }
            }
        }

        const cur_idx_opt = self.viewer.navigation.current_index;
        const cur_key_opt = if (cur_idx_opt) |ci| self.cache.activeKey(ci) else null;
        const cur_entry_opt = if (cur_key_opt) |ck| self.cache.get(ck) else null;

        var can_upload_neighbors = true;
        if (cur_entry_opt) |cur_entry| {
            switch (cur_entry.status) {
                .loaded_gpu, .failed => {
                    can_upload_neighbors = true;
                },
                .loaded_cpu => |cpu| {
                    cur_entry.status = .uploading;
                    upload_target = .{
                        .key = cur_key_opt.?,
                        .cpu = cpu,
                    };
                    can_upload_neighbors = false;
                },
                .decoding, .uploading => {
                    can_upload_neighbors = false;
                },
            }
        }

        if (upload_target == null and can_upload_neighbors) {
            const total_items = self.viewer.navigation.image_list.items.len;
            var best_idx: ?usize = null;
            var min_dist: usize = std.math.maxInt(usize);

            for (entries, keys, 0..) |entry, key, i| {
                switch (entry.status) {
                    .loaded_cpu => {
                        const dist = if (cur_idx_opt) |cur| blk: {
                            const linear_dist = if (key.index > cur) key.index - cur else cur - key.index;
                            break :blk if (total_items > 0 and linear_dist <= total_items) @min(linear_dist, total_items - linear_dist) else linear_dist;
                        } else i;

                        if (dist < min_dist) {
                            min_dist = dist;
                            best_idx = i;
                        }
                    },
                    else => {},
                }
            }

            if (best_idx) |bi| {
                const entry = &entries[bi];
                switch (entry.status) {
                    .loaded_cpu => |cpu| {
                        entry.status = .uploading;
                        upload_target = .{
                            .key = keys[bi],
                            .cpu = cpu,
                        };
                    },
                    else => {},
                }
            }
        }

        if (upload_target) |target| {
            defer target.cpu.surface.destroy();
            if (self.gpu_device) |gpu_dev| {
                if (image.uploadSurfaceToGpu(gpu_dev, target.cpu.surface, self.unpack_compute_pipeline, &self.upload_staging)) |res| {
                    const loaded_gpu_status = CacheStatus{
                        .loaded_gpu = .{
                            .gpu_texture = res.gpu_texture,
                            .w = target.cpu.w,
                            .h = target.cpu.h,
                            .size_bytes = target.cpu.size_bytes,
                            .mime_type = target.cpu.mime_type,
                            .read_time_ms = target.cpu.read_time_ms,
                            .decode_time_ms = target.cpu.decode_time_ms,
                            .conversion_time_ms = res.conversion_time_ms,
                            .upload_time_ms = res.upload_time_ms,
                            .memory_size_bytes = res.memory_size_bytes,
                            .num_mip_levels = res.num_mip_levels,
                            .mipmap_time_ms = res.mipmap_time_ms,
                            .was_fallback = res.was_fallback,
                            .fallback_time_ms = res.fallback_time_ms,
                            .cbz_decompress_time_ms = target.cpu.cbz_decompress_time_ms,
                            .compressed_size_bytes = target.cpu.compressed_size_bytes,
                        },
                    };
                    const updated = self.cache.updateStatus(target.key, loaded_gpu_status);

                    if (!updated) {
                        gpu_dev.releaseTexture(res.gpu_texture);
                    } else {
                        self.cache.enforceVramBudget(gpu_dev, self.viewer.navigation.current_index, self.viewer.getTransitionPrevIndex(), self.viewer.navigation.image_list.items.len, image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES);
                        if (self.viewer.navigation.current_index) |cur_idx| {
                            if (self.cache.activeKey(cur_idx).index == target.key.index) {
                                if (self.cache.get(target.key)) |entry| {
                                    if (entry.thumbnail == .loaded and !self.viewer.ui.overlays.debug_show_thumb and !self.viewer.isSlideshowActive() and self.viewer.image_transition == .none) {
                                        self.viewer.animations.startFrom(.thumb_crossfade, 0.0, 1.0, state_pkg.DURATION_THUMB_CROSSFADE_MS, .ease_out_quad);
                                    }
                                    if (self.viewer.image_transition != .none) {
                                        if (self.viewer.animations.get(.image_crossfade) < 0.001) {
                                            self.viewer.animations.startFrom(
                                                .image_crossfade,
                                                0.0,
                                                1.0,
                                                state_pkg.DURATION_IMAGE_DISSOLVE_MS,
                                                .ease_in_out_cubic,
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    _ = self.cache.updateStatus(target.key, .failed);
                    if (self.viewer.navigation.current_index) |cur_idx| {
                        if (self.cache.activeKey(cur_idx).index == target.key.index) {
                            self.viewer.image_transition = .none;
                            self.viewer.animations.setImmediate(.image_crossfade, 1.0);
                        }
                    }
                }
            }
        }
    }
};

var test_clay_memory: [1024 * 1024]u8 = undefined;

test "AppState.clampZoomFactor bounds based on image dimensions" {
    _ = clay.initialize(clay.Arena.init(&test_clay_memory), .{ .w = 1024, .h = 768 }, .{});

    var state = try AppState.initHeadless(std.testing.allocator, std.Io.Threaded.global_single_threaded.io());
    defer state.deinit();

    // Default base_scale without loaded image is 1.0
    try std.testing.expectEqual(@as(f32, 1.0), state.getBaseScale());
    try std.testing.expectEqual(@as(f32, 10.0), state.clampZoomFactor(15.0).get());
    try std.testing.expectEqual(@as(f32, 0.1), state.clampZoomFactor(0.05).get());

    // Test with loaded CPU image entry
    const surf = sdl.Surface.create(4000, 3000, sdl.PixelFormat.rgba32) orelse unreachable;
    try state.cache.appendWithKey(std.testing.allocator, .{ .index = 0, .generation = 0 }, .{
        .status = .{
            .loaded_cpu = .{
                .surface = surf,
                .w = 4000.0,
                .h = 3000.0,
                .mime_type = "image/png",
                .size_bytes = 1000,
                .decode_time_ms = 0.0,
                .conversion_time_ms = 0.0,
            },
        },
    });
    state.viewer.navigation.current_index = 0;

    // In .none mode on 4000x3000 image, base_scale is 1.0
    state.viewer.viewport.fit_mode = .none;
    const base_none = state.getBaseScale();
    try std.testing.expectEqual(@as(f32, 1.0), base_none);
    const clamped_max_none = state.clampZoomFactor(15.0);
    try std.testing.expectEqual(@as(f32, 10.0), base_none * clamped_max_none.get());

    // In .full mode in default 1024x708 viewport
    state.viewer.viewport.fit_mode = .full;
    const base_full = state.getBaseScale();
    try std.testing.expect(base_full < 1.0);
    const clamped_max_full = state.clampZoomFactor(100.0);
    // Effective max zoom level (base_scale * zoom_factor) must be 10.0x of actual image size
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), base_full * clamped_max_full.get(), 0.001);
    const clamped_min_full = state.clampZoomFactor(0.001);
    // Effective min zoom level (base_scale * zoom_factor) must be 0.1x of actual image size
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), base_full * clamped_min_full.get(), 0.001);
}

test "AppState.updateCurrentRotation syncs EXIF orientation" {
    var state = try AppState.initHeadless(std.testing.allocator, std.Io.Threaded.global_single_threaded.io());
    defer state.deinit();

    try state.viewer.navigation.image_list.append(std.testing.allocator, .{ .filesystem = .{ .path = "test_photo_1.jpg" } });
    state.viewer.navigation.current_index = 0;

    // Initially uncached -> rotation_angle should be 0.0
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.viewer.viewport.rotation_angle);

    // Simulate worker thread caching EXIF orientation of 90.0
    try state.cache.appendWithKey(std.testing.allocator, .{ .index = 0, .generation = 0 }, .{
        .status = .{ .decoding = .{} },
        .orientation = .rotate_90,
    });

    // Calling updateCurrentRotation updates rotation_angle from entry
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 90.0), state.viewer.viewport.rotation_angle);

    // Test out of bounds index
    state.viewer.navigation.current_index = 99;
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.viewer.viewport.rotation_angle);

    // Test null index
    state.viewer.navigation.current_index = null;
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.viewer.viewport.rotation_angle);
}

test "AppState.isPointerInDebugPanel and click localization" {
    _ = clay.initialize(clay.Arena.init(&test_clay_memory), .{ .w = 1000, .h = 800 }, .{});

    clay.setDebugModeEnabled(true);
    defer clay.setDebugModeEnabled(false);

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const debug_w = @as(f32, @floatFromInt(clay.Clay__debugViewWidth));
    const win_w: f32 = 1000.0;
    const win_h: f32 = 800.0;

    const input_inside = types.FrameInput{
        .win_w = win_w,
        .win_h = win_h,
        .pix_w = win_w,
        .pix_h = win_h,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .dpi_scale = 1.0,
        .mouse_x = win_w - debug_w + 10.0,
        .mouse_y = 100.0,
        .mouse_left_down = false,
        .mouse_left_clicked = true,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
        .is_pointer_in_debug_panel = true,
    };
    try std.testing.expect(state.isPointerInDebugPanel(input_inside));

    const input_outside = types.FrameInput{
        .win_w = win_w,
        .win_h = win_h,
        .pix_w = win_w,
        .pix_h = win_h,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .dpi_scale = 1.0,
        .mouse_x = 100.0,
        .mouse_y = 100.0,
        .mouse_left_down = false,
        .mouse_left_clicked = true,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };
    try std.testing.expect(!state.isPointerInDebugPanel(input_outside));
}
