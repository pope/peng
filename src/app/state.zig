const clay = @import("zclay");
const core_fs = @import("core/fs.zig");
const events = @import("core/events.zig");
const exif = @import("core/exif.zig");
const image = @import("core/image.zig");
const input = @import("input");
const intents = @import("intents");
const ipc = @import("ipc");
const palette_module = @import("core/palette.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const workers_mod = @import("workers/root.zig");

const AppIntent = intents.AppIntent;
const CacheEntry = state_pkg.CacheEntry;
const CacheStatus = state_pkg.CacheStatus;
const DisplayState = state_pkg.DisplayState;
const FrameInput = types.FrameInput;
const ImageCache = image.ImageCache;
const ImageCacheKey = image.ImageCacheKey;
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
/// - The main thread consumes background events during frame updates and
///   updates `ViewerState` safely.
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
    gpu_enabled: bool = true,
    unpack_compute_pipeline: ?sdl.gpu.ComputePipeline = null,

    /// Memory & Async I/O Context
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Subsystems
    cache: ImageCache,
    workers: workers_mod.WorkerManager = .{},
    upload_staging: image.UploadStagingBuffer = .{},

    /// Queues
    event_batch: std.ArrayList(events.BackgroundEvent) = .empty,
    pending_ipc_commands: std.ArrayList(*ipc.IpcCommandData) = .empty,
    pending_intents: std.ArrayList(AppIntent) = .empty,

    /// Initializes top-level `AppState` in headless mode without creating an SDL
    /// window, suitable for tests.
    pub fn initHeadless(allocator: std.mem.Allocator, io: std.Io) !AppState {
        var state = AppState{
            .viewer = try ViewerState.initHeadless(allocator),
            .cache = .{},
            .workers = .init(),
            .allocator = allocator,
            .io = io,
            .gpu_enabled = false,
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
        // 16 intents: accommodates worst-case enqueued IPC, keyboard, palette,
        // and slideshow intents in a single tick
        try self.pending_intents.ensureTotalCapacity(self.allocator, 16);
        errdefer self.pending_intents.deinit(self.allocator);
        // 16 events: accommodates concurrent worker background events
        // (decodes, EXIF, path scans) processed per tick
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

    /// Returns `true` if files are currently loading, background workers are
    /// active, active unpaused slideshow is running, or animations are active.
    pub inline fn isBusy(self: *const AppState) bool {
        return self.viewer.hasActiveAnimation() or
            self.viewer.navigation.isLoadingFiles() or
            self.workers.isBusy() or
            (self.viewer.isSlideshowActive() and !self.isSlideshowPaused());
    }

    /// Returns `true` if the currently active slide is still decoding or awaiting
    /// GPU texture upload.
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

    /// Returns `true` if slideshow mode is active but paused due to explicit
    /// pause, active modal, user dragging, or slide loading.
    pub fn isSlideshowPaused(self: *const AppState) bool {
        if (!self.viewer.isSlideshowActive()) return false;
        return self.viewer.navigation.slideshow.isPaused() or
            self.viewer.ui.palette.isOpen() or
            self.viewer.drag_state != .none or
            self.isCurrentSlideLoading();
    }

    /// Returns the CacheEntry corresponding to the previous slide in an active
    /// crossfade, if available.
    pub fn getTransitionPrevEntry(self: *const AppState) ?CacheEntry {
        const prev_idx = self.viewer.getTransitionPrevIndex() orelse return null;
        return self.cache.getEntry(self.cache.activeKey(prev_idx));
    }

    /// Returns the remaining millisecond deadline for transient holding timers
    /// (e.g. title auto-hide, snackbar), or null if none active.
    pub fn getWaitTimeoutMs(self: *const AppState, now: u64) ?i32 {
        var min_rem: ?u64 = null;
        switch (self.viewer.ui.overlays.title_display) {
            .transient => |t| {
                min_rem = t.timeout_ms -| now;
            },
            .hidden, .pinned => {},
        }
        switch (self.viewer.ui.snackbar.notification) {
            .active => |active| {
                if (active.timeout_ms > 0) {
                    const rem = active.timeout_ms -| now;
                    min_rem = if (min_rem) |cur| @min(cur, rem) else rem;
                }
            },
            .none => {},
        }
        if (min_rem) |rem| {
            return @intCast(@min(rem, 2000));
        }
        return null;
    }

    /// Computes the event-loop wait strategy for `pollFrameInput`.
    /// When `bg_events_processed` is true, returns `.poll` so events drained
    /// before `pollFrameInput` are rendered immediately without an 8ms
    /// `waitEventTimeout` delay.
    pub fn computeFrameWaitStrategy(
        self: *const AppState,
        cur_win_w: f32,
        cur_win_h: f32,
        bg_events_processed: bool,
        force_non_blocking: bool,
        now_ticks: u64,
    ) input.EventWaitStrategy {
        if (force_non_blocking or bg_events_processed) {
            return .poll;
        }
        const is_current_loading = blk: {
            if (self.getCurrentEntry()) |entry| {
                break :blk (entry.status == .decoding or
                    entry.status == .uploading);
            }
            break :blk (self.viewer.navigation.current_index != null);
        };
        const has_unpopulated_cache = blk: {
            if (self.viewer.navigation.getVisibleCount() <= 1) {
                break :blk false;
            }
            const neighbors =
                self.viewer.navigation.getVisibleNeighbors() orelse
                break :blk false;
            const has_gpu = self.gpu_device != null;
            break :blk self.cache.hasUnreadyPrefetchSlots(neighbors, has_gpu);
        };
        const last_w = self.viewer.last_win_w;
        const last_h = self.viewer.last_win_h;
        const window_resized =
            (last_w != 0 and (last_w != cur_win_w or last_h != cur_win_h));
        const is_busy = self.isBusy() or
            is_current_loading or
            (self.viewer.drag_state != .none) or
            (self.viewer.viewport.isZoomed() and
                self.viewer.pan_controller.isBusy()) or
            self.viewer.zoom_controller.isBusy() or
            has_unpopulated_cache or
            window_resized;
        const wait_timeout_ms =
            if (!is_busy) self.getWaitTimeoutMs(now_ticks) else null;

        return input.selectEventWaitStrategy(false, is_busy, wait_timeout_ms);
    }

    /// Reads EXIF orientation from a JPEG file header on disk, returning `null` if unparseable.
    pub fn readJpegExifOrientation(self: *const AppState, path: []const u8) ?state_pkg.Orientation {
        return exif.readJpegExifOrientation(self.io, path);
    }

    /// Releases all engine resources, cancels background worker tasks, and
    /// frees GPU textures and queues.
    pub fn deinit(self: *AppState) void {
        self.workers.deinit(self.allocator, self.io);

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
    }

    /// Stores a user-overridden rotation angle for the given media path in the
    /// persistent rotation map.
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

    /// Computes available viewport dimensions in physical framebuffer pixels,
    /// scaling for display DPI, Clay debug view, and docked edit panel.
    pub fn getViewportPixelDims(self: *AppState) state_pkg.PhysicalDims {
        var win_w: f32 = 1024.0;
        var win_h: f32 = 768.0;
        var scale_x: f32 = 1.0;

        switch (self.viewer.display) {
            .headless => {},
            .windowed => |win| {
                const win_size = win.handle.getSize();
                const pix_size = win.handle.getSizeInPixels();
                if (pix_size.w > 0 and pix_size.h > 0) {
                    win_w = @floatFromInt(pix_size.w);
                    win_h = @floatFromInt(pix_size.h);
                }
                if (win_size.w > 0 and win_size.h > 0) {
                    scale_x = win_w / @as(f32, @floatFromInt(win_size.w));
                }
            },
        }

        var available_width = win_w;
        if (clay.isDebugModeEnabled()) {
            const dbg_w =
                @as(f32, @floatFromInt(clay.Clay__debugViewWidth)) * scale_x;
            available_width = @max(available_width - dbg_w, 1.0);
        }
        const edit_progress = self.viewer.animations.get(.edit_panel);
        const edit_open = self.viewer.ui.overlays.edit_panel.visible;
        if (edit_open or edit_progress > 0.001) {
            const docked_w =
                state_pkg.EDIT_PANEL_WIDTH * edit_progress * scale_x;
            available_width = @max(available_width - docked_w, 1.0);
        }
        const view_w = @max(available_width, 1.0);
        const view_h = @max(win_h, 1.0);

        return .{ .w = view_w, .h = view_h };
    }

    /// Computes the unzoomed base scale factor fitting the current image to the
    /// viewport in physical framebuffer pixels according to fit_mode.
    pub fn getBaseScale(self: *AppState) f32 {
        const entry = self.getCurrentEntry() orelse return 1.0;
        const auth = entry.getAuthoritativeDims();
        const raw_w = auth.w;
        const raw_h = auth.h;
        if (raw_w <= 0.0 or raw_h <= 0.0) return 1.0;

        const dims = self.getViewportPixelDims();
        return view_transform.computePresetZoom(
            raw_w,
            raw_h,
            self.viewer.viewport.rotation_angle,
            dims.w,
            dims.h,
            self.viewer.viewport.fit_mode,
        );
    }

    /// Returns true if current image content overflows the viewport bounds.
    pub fn isImageOverflowing(self: *AppState) bool {
        const entry = self.getCurrentEntry() orelse return false;
        const auth = entry.getAuthoritativeDims();
        if (auth.w <= 0.0 or auth.h <= 0.0) return false;

        const dims = self.getViewportPixelDims();
        return self.viewer.viewport.isOverflowing(
            auth.w,
            auth.h,
            dims.w,
            dims.h,
        );
    }

    /// Rebuilds fuzzy search matches for the command palette image file list.
    pub fn rebuildPaletteMatches(self: *AppState) !void {
        try self.viewer.ui.palette.rebuildFileMatches(self.viewer.navigation.getEntries());
    }

    /// Rebuilds fuzzy search matches for command palette action items.
    pub fn rebuildActionMatches(self: *AppState) !void {
        try self.viewer.ui.palette.rebuildActionMatches();
    }

    /// Returns a mutable pointer to the CacheEntry corresponding to the
    /// currently active image, or null.
    pub fn getCurrentEntryPtr(self: *AppState) ?*CacheEntry {
        const idx = self.viewer.navigation.current_index orelse return null;
        return self.cache.get(self.cache.activeKey(idx));
    }

    /// Returns a copy of the CacheEntry corresponding to the currently active
    /// image, or null.
    pub fn getCurrentEntry(self: *const AppState) ?CacheEntry {
        const idx = self.viewer.navigation.current_index orelse return null;
        return self.cache.getEntry(self.cache.activeKey(idx));
    }

    /// Releases all GPU textures and resets status across all cache slots.
    pub fn clearCache(self: *AppState) void {
        const dev_opt = self.gpu_device;
        self.cache.clear(dev_opt);
    }

    /// Synchronizes viewport rotation angle with active user rotation override,
    /// parsed EXIF orientation, or zero.
    pub fn updateCurrentRotation(self: *AppState) void {
        const media = self.viewer.navigation.getCurrentImageEntry() orelse {
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

    /// Completes a pending IPC screenshot capture request after frame
    /// rendering, sending reply to client.
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

    pub const NavigatorInitialPath = struct {
        start_dir: []const u8,
        preselect_child: ?[]const u8,
    };

    /// Resolves the starting directory and optional child pre-selection for
    /// `.directory_navigator` palette mode.
    pub fn resolveNavigatorInitialPath(
        self: *const AppState,
    ) NavigatorInitialPath {
        if (self.viewer.navigation.getCurrentImageEntry()) |media| {
            const file_path = media.getSourcePath();
            if (std.fs.path.dirname(file_path)) |parent| {
                return .{
                    .start_dir = parent,
                    .preselect_child = std.fs.path.basename(file_path),
                };
            } else {
                return .{
                    .start_dir = ".",
                    .preselect_child = file_path,
                };
            }
        }

        if (self.viewer.navigation.last_scanned_dir.items.len > 0) {
            return .{
                .start_dir = self.viewer.navigation.last_scanned_dir.items,
                .preselect_child = null,
            };
        }
        if (self.viewer.ui.palette.last_nav_dir.items.len > 0) {
            return .{
                .start_dir = self.viewer.ui.palette.last_nav_dir.items,
                .preselect_child = null,
            };
        }
        return .{
            .start_dir = ".",
            .preselect_child = null,
        };
    }

    /// Activates the command palette in the specified PaletteMode, resetting
    /// queries and starting text input.
    pub fn openPalette(self: *AppState, active_type: PaletteMode) !void {
        self.viewer.ui.palette.reset();
        self.viewer.ui.palette.mode = active_type;
        self.viewer.animations.start(
            .palette_reveal,
            1.0,
            state_pkg.DURATION_PALETTE_OPEN_MS,
            .ease_out_cubic,
        );
        self.viewer.ui.palette.selected_idx = switch (active_type) {
            .files => self.viewer.navigation.current_index orelse 0,
            .inactive,
            .actions,
            .set_brightness,
            .set_contrast,
            .set_contrast_blend,
            .set_highlights,
            .set_shadows,
            .set_whites,
            .set_blacks,
            .set_temperature,
            .set_tint,
            .set_vibrance,
            .set_saturation,
            .set_clarity,
            .set_texture,
            .go_to_image,
            .directory_navigator,
            .set_slideshow_interval,
            => 0,
        };
        self.viewer.ui.palette.selection_dirty = true;

        switch (active_type) {
            .files => try self.rebuildPaletteMatches(),
            .actions => try self.rebuildActionMatches(),
            .directory_navigator => {
                const nav_path = resolveNavigatorInitialPath(self);
                if (nav_path.preselect_child) |child| {
                    self.viewer.ui.palette.last_child_dir.clearRetainingCapacity();
                    try self.viewer.ui.palette.last_child_dir.appendSlice(self.allocator, child);
                }
                try self.loadPaletteDirectory(nav_path.start_dir);
                if (self.viewer.ui.palette.dir_items.items.len == 0) {
                    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                    while (self.viewer.ui.palette.dir_items.items.len == 0) {
                        const curr =
                            self.viewer.ui.palette.current_nav_dir.items;
                        const parent = core_fs.getParentDirBuf(
                            curr,
                            &parent_buf,
                        ) orelse break;
                        if (std.mem.eql(u8, parent, curr)) break;
                        try self.loadPaletteDirectory(parent);
                    }
                }
            },
            .set_slideshow_interval => {
                var buf: [32]u8 = undefined;
                const dur_secs = switch (self.viewer.navigation.slideshow) {
                    .active => |s| s.interval_s,
                    .inactive => 3.0,
                };
                const formatted = std.fmt.bufPrint(&buf, "{d:.1}", .{dur_secs}) catch |err| blk: {
                    std.log.warn(
                        "Failed to format slideshow interval string: {}, defaulting to 3.0",
                        .{err},
                    );
                    break :blk "3.0";
                };
                try self.viewer.ui.palette.query.appendSlice(self.allocator, formatted);
            },
            .inactive,
            .set_brightness,
            .set_contrast,
            .set_contrast_blend,
            .set_highlights,
            .set_shadows,
            .set_whites,
            .set_blacks,
            .set_temperature,
            .set_tint,
            .set_vibrance,
            .set_saturation,
            .set_clarity,
            .set_texture,
            .go_to_image,
            => {},
        }
        startTextInput(self.viewer.display);
    }

    /// Initiates loading a new target path (file or directory). Cancels in-flight tasks,
    /// clears cache, resets navigation, and starts background discovery workers.
    pub fn openPath(self: *AppState, path: []const u8) !void {
        // Copy `path` upfront because callers may pass a slice backed by
        // `directory_arena` (reset below) or `last_scanned_dir.items`
        // (cleared and written below).
        var path_sfa = std.heap.stackFallback(
            std.fs.max_path_bytes,
            self.allocator,
        );
        const path_alloc = path_sfa.get();
        const owned_path = try path_alloc.dupe(u8, path);
        defer path_alloc.free(owned_path);

        var stat: std.Io.File.Stat = undefined;
        var has_stat = true;
        if (std.Io.Dir.statFile(
            std.Io.Dir.cwd(),
            self.io,
            owned_path,
            .{},
        )) |s| {
            stat = s;
        } else |err| {
            std.log.err(
                "Failed to access path '{s}': {}",
                .{ owned_path, err },
            );
            has_stat = false;
        }

        const dir_target = if (has_stat and stat.kind == .directory)
            owned_path
        else
            std.fs.path.dirname(owned_path) orelse ".";

        self.viewer.navigation.last_scanned_dir.clearRetainingCapacity();
        try self.viewer.navigation.last_scanned_dir.appendSlice(
            self.allocator,
            dir_target,
        );

        _ = self.cache.advanceGeneration();
        self.clearCache();
        self.clearRotationMap();
        self.viewer.navigation.clearEntries();
        _ = self.viewer.navigation.directory_arena.reset(.retain_capacity);
        self.viewer.image_transition = .none;
        self.viewer.animations.setImmediate(.image_crossfade, 1.0);
        self.viewer.animations.setImmediate(.thumb_crossfade, 1.0);

        if (has_stat) {
            const stack_raw = self.viewer.navigation.stack_raw_jpeg;
            if (stat.kind == .directory) {
                try workers_mod.startAsyncPathScan(
                    &self.workers,
                    &self.viewer.navigation.active_file_scans,
                    &self.cache.generation,
                    self.allocator,
                    self.io,
                    owned_path,
                    true,
                    stack_raw,
                );
            } else if (core_fs.isCbzFile(owned_path)) {
                try workers_mod.startAsyncPathScan(
                    &self.workers,
                    &self.viewer.navigation.active_file_scans,
                    &self.cache.generation,
                    self.allocator,
                    self.io,
                    owned_path,
                    false,
                    stack_raw,
                );
            } else {
                const arena_alloc =
                    self.viewer.navigation.directory_arena.allocator();
                const dup = try arena_alloc.dupe(u8, owned_path);
                try self.viewer.navigation.appendEntry(
                    self.allocator,
                    .{ .filesystem = .{ .path = dup } },
                );
                _ = self.viewer.navigation.adjustIndexForVisibility();

                try workers_mod.startAsyncPathScan(
                    &self.workers,
                    &self.viewer.navigation.active_file_scans,
                    &self.cache.generation,
                    self.allocator,
                    self.io,
                    owned_path,
                    false,
                    stack_raw,
                );

                // Spawn immediate decode for slot 0 to overlap with graphics/GPU init
                const key0 = try self.cache.appendSlot(self.allocator, 0, .{
                    .decoding = .{ .has_thread = true },
                });
                errdefer {
                    if (self.cache.get(key0)) |entry| {
                        switch (entry.status) {
                            .decoding => |*dec| dec.has_thread = false,
                            .loaded_cpu, .loaded_gpu, .uploading, .failed => {},
                        }
                    }
                }
                const dup_entry = try (state_pkg.MediaEntry{
                    .filesystem = .{ .path = owned_path },
                }).dupe(self.allocator);
                errdefer dup_entry.deinit(self.allocator);

                const args = try self.allocator.create(workers_mod.DecodeArgs);
                errdefer self.allocator.destroy(args);
                args.* = workers_mod.DecodeArgs{
                    .workers = &self.workers,
                    .allocator = self.allocator,
                    .io = self.io,
                    .key = key0,
                    .entry = dup_entry,
                    .has_gpu_device = (self.gpu_device != null) or self.gpu_enabled,
                    .pixel_format = self.viewer.display.getPixelFormat(),
                    .thumb_only = false,
                    .pair_target = if (self.viewer.navigation.stack_raw_jpeg) .adaptive else .standalone_jpeg,
                    .current_generation = &self.cache.generation,
                };
                try workers_mod.spawnDecode(args);
            }
        }
        if (self.viewer.ui.palette.mode == .files and
            !self.viewer.ui.palette.is_closing)
        {
            try self.rebuildPaletteMatches();
        }
    }

    /// Ensures that the thumbnail GPU texture is loaded for the current entry.
    pub fn ensureCurrentThumbnailLoaded(self: *AppState) void {
        const e = self.getCurrentEntryPtr() orelse return;
        if (e.thumbnail == .loaded or e.thumbnail == .not_available) return;

        const media = self.viewer.navigation.getCurrentImageEntry() orelse {
            e.thumbnail = .not_available;
            return;
        };
        const extracted = image.loadThumbnailSurface(self.io, self.allocator, media) orelse {
            e.thumbnail = .not_available;
            return;
        };
        defer extracted.surface.destroy();

        const dev = self.gpu_device orelse return;
        const upload_res = image.uploadSurfaceToGpu(
            dev,
            extracted.surface,
            self.unpack_compute_pipeline,
            &self.upload_staging,
        ) orelse {
            e.thumbnail = .not_available;
            return;
        };

        switch (e.thumbnail) {
            .loaded => |thumb| dev.releaseTexture(thumb.texture),
            .none, .pending, .not_available, .unloaded => {},
        }

        e.applyProbedMetadata(
            extracted.full_w,
            extracted.full_h,
            extracted.orientation,
            extracted.raw_metadata,
        );

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

    /// Scans cache slots around the current navigation index, evicting distant
    /// textures and uploading ready surfaces to the GPU.
    pub fn prepareCacheTextures(self: *AppState) void {
        const entries = self.cache.slots.items(.entry);
        const keys = self.cache.slots.items(.key);

        for (entries, keys) |*entry, key| {
            const is_cur = if (self.viewer.navigation.current_index) |cur|
                self.cache.activeKey(cur).index == key.index
            else
                false;
            const is_crossfading = self.viewer.animations.isActive(.thumb_crossfade) and is_cur;
            if (!is_crossfading and entry.status == .loaded_gpu and
                !self.viewer.ui.overlays.debug_show_thumb)
            {
                switch (entry.thumbnail) {
                    .loaded => |thumb| {
                        if (self.gpu_device) |gpu_dev| {
                            gpu_dev.releaseTexture(thumb.texture);
                        }
                        entry.thumbnail = .{ .unloaded = thumb.info };
                    },
                    .none, .pending, .not_available, .unloaded => {},
                }
            }
        }

        if (self.gpu_device == null) return;

        var upload_target: ?struct {
            key: ImageCacheKey,
            cpu: @TypeOf(@as(CacheStatus, undefined).loaded_cpu),
        } = null;

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
            const total_items = self.viewer.navigation.count();
            const neighbors_opt = self.viewer.navigation.getVisibleNeighbors();
            var best_idx: ?usize = null;
            var min_dist: usize = std.math.maxInt(usize);

            for (entries, keys, 0..) |entry, key, i| {
                if (entry.status != .loaded_cpu) continue;
                const dist = if (neighbors_opt) |neighbors|
                    neighbors.stepDistance(key.index) orelse
                        (3 + image.calcCyclicDistance(
                            key.index,
                            neighbors.current,
                            total_items,
                        ))
                else if (cur_idx_opt) |cur|
                    image.calcCyclicDistance(key.index, cur, total_items)
                else
                    i;

                if (dist < min_dist) {
                    min_dist = dist;
                    best_idx = i;
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
                    .loaded_gpu, .decoding, .uploading, .failed => {},
                }
            }
        }

        if (upload_target) |target| {
            defer target.cpu.surface.destroy();
            if (self.gpu_device) |gpu_dev| {
                if (image.uploadSurfaceToGpu(
                    gpu_dev,
                    target.cpu.surface,
                    self.unpack_compute_pipeline,
                    &self.upload_staging,
                )) |res| {
                    const loaded_gpu_status = CacheStatus{
                        .loaded_gpu = .{
                            .gpu_texture = res.gpu_texture,
                            .w = res.w,
                            .h = res.h,
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
                        self.cache.enforceVramBudget(
                            gpu_dev,
                            self.viewer.navigation.getVisibleNeighbors(),
                            self.viewer.getTransitionPrevIndex(),
                            self.viewer.navigation.count(),
                            image.ImageCache.DEFAULT_MAX_VRAM_BYTES,
                        );
                        checkLoadedGpuCrossfade(self, target.key);
                    }
                } else {
                    handleGpuUploadFailure(self, target.key);
                }
            }
        }
    }

    fn checkLoadedGpuCrossfade(
        self: *AppState,
        target_key: ImageCacheKey,
    ) void {
        const cur_idx = self.viewer.navigation.current_index orelse return;
        if (self.cache.activeKey(cur_idx).index != target_key.index) return;
        const entry = self.cache.get(target_key) orelse return;

        const can_crossfade = entry.thumbnail == .loaded and
            !self.viewer.ui.overlays.debug_show_thumb and
            !self.viewer.isSlideshowActive() and
            self.viewer.image_transition == .none;
        if (can_crossfade) {
            self.viewer.animations.startFrom(
                .thumb_crossfade,
                0.0,
                1.0,
                state_pkg.DURATION_THUMB_CROSSFADE_MS,
                .ease_out_quad,
            );
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

    fn handleGpuUploadFailure(self: *AppState, target_key: ImageCacheKey) void {
        _ = self.cache.updateStatus(target_key, .failed);
        const cur_idx = self.viewer.navigation.current_index orelse return;
        if (self.cache.activeKey(cur_idx).index == target_key.index) {
            self.viewer.image_transition = .none;
            self.viewer.animations.setImmediate(.image_crossfade, 1.0);
        }
    }
};

var test_clay_memory: [1024 * 1024]u8 = undefined;

test "AppState.getBaseScale based on image dimensions" {
    _ = clay.initialize(clay.Arena.init(&test_clay_memory), .{ .w = 1024, .h = 768 }, .{});

    var state = try AppState.initHeadless(
        std.testing.allocator,
        std.Io.Threaded.global_single_threaded.io(),
    );
    defer state.deinit();

    // Default base_scale without loaded image is 1.0
    try std.testing.expectEqual(@as(f32, 1.0), state.getBaseScale());
    try std.testing.expectEqual(
        @as(f32, 100.0),
        types.ZoomFactor.init(150.0).get(),
    );
    try std.testing.expectEqual(
        @as(f32, 0.001),
        types.ZoomFactor.init(0.0001).get(),
    );

    // Test with loaded CPU image entry
    const surf = sdl.Surface.create(4000, 3000, sdl.PixelFormat.rgba32) orelse unreachable;
    _ = try state.cache.appendSlot(std.testing.allocator, 0, .{
        .loaded_cpu = .{
            .surface = surf,
            .w = 4000.0,
            .h = 3000.0,
            .mime_type = "image/png",
            .size_bytes = 1000,
            .decode_time_ms = 0.0,
            .conversion_time_ms = 0.0,
        },
    });
    state.viewer.navigation.current_index = 0;

    // In .none mode on 4000x3000 image, base_scale is 1.0
    state.viewer.viewport.fit_mode = .none;
    const base_none = state.getBaseScale();
    try std.testing.expectEqual(@as(f32, 1.0), base_none);
    const clamped_max_none = types.ZoomFactor.init(15.0);
    try std.testing.expectEqual(@as(f32, 15.0), clamped_max_none.get());

    // In .full mode in default 1024x768 viewport (768 / 3000 = 0.256)
    state.viewer.viewport.fit_mode = .full;
    const base_full = state.getBaseScale();
    try std.testing.expect(base_full < 1.0);
    try std.testing.expectApproxEqAbs(
        @as(f32, 768.0 / 3000.0),
        base_full,
        0.001,
    );
}

test "AppState.getViewportPixelDims and isImageOverflowing" {
    _ = clay.initialize(
        clay.Arena.init(&test_clay_memory),
        .{ .w = 1024, .h = 768 },
        .{},
    );

    var state = try AppState.initHeadless(
        std.testing.allocator,
        std.Io.Threaded.global_single_threaded.io(),
    );
    defer state.deinit();

    const dims = state.getViewportPixelDims();
    try std.testing.expectEqual(@as(f32, 1024.0), dims.w);
    try std.testing.expectEqual(@as(f32, 768.0), dims.h);

    const surf = sdl.Surface.create(
        4000,
        3000,
        sdl.PixelFormat.rgba32,
    ) orelse unreachable;
    _ = try state.cache.appendSlot(std.testing.allocator, 0, .{
        .loaded_cpu = .{
            .surface = surf,
            .w = 4000.0,
            .h = 3000.0,
            .mime_type = "image/png",
            .size_bytes = 1000,
            .decode_time_ms = 0.0,
            .conversion_time_ms = 0.0,
        },
    });
    state.viewer.navigation.current_index = 0;

    // In .full mode, 4000x3000 image fits within 1024x768 -> not overflowing
    state.viewer.viewport.fit_mode = .full;
    state.viewer.viewport.mode = .fit;
    try std.testing.expect(!state.isImageOverflowing());

    // In .manual mode with zoom 1.0 (4000x3000 > 1024x768) -> overflowing
    state.viewer.viewport.mode = .manual;
    state.viewer.viewport.zoom_factor = types.ZoomFactor.init(1.0);
    try std.testing.expect(state.isImageOverflowing());
}

test "AppState.updateCurrentRotation syncs EXIF orientation" {
    var state = try AppState.initHeadless(
        std.testing.allocator,
        std.Io.Threaded.global_single_threaded.io(),
    );
    defer state.deinit();

    try state.viewer.navigation.appendEntry(
        std.testing.allocator,
        .{ .filesystem = .{ .path = "test_photo_1.jpg" } },
    );
    state.viewer.navigation.current_index = 0;

    // Initially uncached -> rotation_angle should be 0.0
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.viewer.viewport.rotation_angle);

    // Simulate worker thread caching EXIF orientation of 90.0
    const key = try state.cache.appendSlot(std.testing.allocator, 0, .{ .decoding = .{} });
    state.cache.get(key).?.orientation = .rotate_90;

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

test "FrameInput.isPointerInDebugPanel and click localization" {
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
        .scale_x = 1.0,
        .scale_y = 1.0,
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
    try std.testing.expect(input_inside.isPointerInDebugPanel());

    const input_outside = types.FrameInput{
        .win_w = win_w,
        .win_h = win_h,
        .scale_x = 1.0,
        .scale_y = 1.0,
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
    try std.testing.expect(!input_outside.isPointerInDebugPanel());
}

test "AppState.isBusy is false once open palette animation settles" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try std.testing.expect(!state.isBusy());

    try state.openPalette(.actions);
    try std.testing.expect(state.viewer.ui.palette.isOpen());
    try std.testing.expect(state.isBusy());

    state.viewer.animations.settleAll();
    try std.testing.expect(state.viewer.ui.palette.isOpen());
    try std.testing.expect(!state.isBusy());
}

test "AppState.computeFrameWaitStrategy returns poll when bg events drained" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try std.testing.expectEqual(
        input.EventWaitStrategy.wait_indefinite,
        state.computeFrameWaitStrategy(1024.0, 768.0, false, false, 1000),
    );
    try std.testing.expectEqual(
        input.EventWaitStrategy.poll,
        state.computeFrameWaitStrategy(1024.0, 768.0, true, false, 1000),
    );
}

test "AppState.openPath preserves closing palette matches" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..len];

    try state.openPalette(.actions);
    const initial_matches = state.viewer.ui.palette.matches.items.len;
    try std.testing.expect(initial_matches > 0);

    state.closePalette();
    try state.openPath(tmp_path);

    // Matches must remain intact during the closing dissolve animation
    try std.testing.expectEqual(
        initial_matches,
        state.viewer.ui.palette.matches.items.len,
    );
}

test "AppState.openPath spawns immediate decode for single image file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const sample_jpg = "testfiles/images/000_0_1024x682.jpg";
    try state.openPath(sample_jpg);

    // Slot 0 must be appended immediately with .decoding and .has_thread = true
    const entry0 = state.cache.get(state.cache.activeKey(0));
    try std.testing.expect(entry0 != null);
    try std.testing.expect(entry0.?.status == .decoding);
    try std.testing.expect(entry0.?.status.decoding.has_thread);
}
