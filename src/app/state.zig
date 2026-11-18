const cache = @import("cache");
const core = @import("core");
const geom = @import("geom");
const gpu = @import("gpu");
const input = @import("input");
const intents = @import("intents");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const thumbcache = @import("thumbcache");
const vfs = @import("vfs");
const workers_mod = @import("workers/root.zig");

const ActivePaletteMode = intents.ActivePaletteMode;
const AppIntent = intents.AppIntent;
const ArchiveTelemetry = state_pkg.ArchiveTelemetry;
const BackgroundEvent = workers_mod.BackgroundEvent;
const CacheEntry = cache.CacheEntry;
const DecodeMode = workers_mod.DecodeMode;
const DisplayState = core.display.DisplayState;
const ImageCache = cache.ImageCache;
const InFlightState = cache.InFlightState;
const isCbzFile = vfs.isCbzFile;
const MediaEntry = vfs.MediaEntry;
const MediaId = vfs.MediaId;
const MipmapTelemetry = state_pkg.MipmapTelemetry;
const PairStreamTarget = vfs.PairStreamTarget;
const PhysicalDims = geom.PhysicalDims;
const startTextInput = core.display.startTextInput;
const stopTextInput = core.display.stopTextInput;
const ThumbCacheConfig = thumbcache.ThumbCacheConfig;
const ThumbCacheMode = thumbcache.ThumbCacheMode;
const ThumbnailSource = state_pkg.ThumbnailSource;
const UploadMode = state_pkg.UploadMode;
const UploadStagingBuffer = gpu.UploadStagingBuffer;
const ViewerState = state_pkg.ViewerState;
const ViewerStats = state_pkg.ViewerStats;
const view_transform = state_pkg.view_transform;
const ZoomFactor = state_pkg.ZoomFactor;

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
    display: DisplayState = .default_headless,
    gpu_device: ?sdl.gpu.Device = null,
    gpu_enabled: bool = true,
    unpack_compute_pipeline: ?sdl.gpu.ComputePipeline = null,

    /// Memory & Async I/O Context
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Subsystems
    cache: ImageCache,
    workers: workers_mod.WorkerManager = .{},
    upload_staging: UploadStagingBuffer = .{},

    /// Queues
    event_batch: std.ArrayList(BackgroundEvent) = .empty,
    pending_ipc_commands: std.ArrayList(*ipc.IpcCommandData) = .empty,
    pending_selection_streams: std.ArrayList(std.Io.net.Stream) = .empty,
    pending_wait_load_streams: std.ArrayList(std.Io.net.Stream) = .empty,
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
        errdefer self.pending_ipc_commands.deinit(self.allocator);
        // 4 streams: accommodates concurrent IPC barrier/query streams
        try self.pending_selection_streams.ensureTotalCapacity(
            self.allocator,
            4,
        );
        errdefer self.pending_selection_streams.deinit(self.allocator);
        try self.pending_wait_load_streams.ensureTotalCapacity(
            self.allocator,
            4,
        );
    }

    /// Initializes the Freedesktop Shared Thumbnail Cache configuration from
    /// the process environment map (`proc_init.environ_map`) and `mode`.
    pub fn initThumbCache(
        self: *AppState,
        environ_map: *const std.process.Environ.Map,
        mode: ThumbCacheMode,
    ) void {
        self.workers.thumb_cache_config.deinit(self.allocator);
        self.workers.thumb_cache_config =
            ThumbCacheConfig.initFromEnviron(
                self.allocator,
                environ_map,
                mode.toWritePolicy(),
            );
    }

    /// Enqueues an application intent to be dispatched and executed during the next frame pass.
    pub fn pushIntent(self: *AppState, intent: AppIntent) !void {
        try self.pending_intents.append(self.allocator, intent);
    }

    /// Clears all queued application intents while retaining array capacity.
    pub fn clearIntents(self: *AppState) void {
        self.pending_intents.clearRetainingCapacity();
    }

    /// Streams the active JSON selections payload to each queued IPC stream in
    /// `pending_selection_streams` and closes the stream.
    pub fn flushPendingSelectionStreams(self: *AppState) void {
        if (self.pending_selection_streams.items.len == 0) return;
        defer self.pending_selection_streams.clearRetainingCapacity();

        for (self.pending_selection_streams.items) |stream| {
            defer stream.close(self.io);
            var write_buf: [4 * 1024]u8 = undefined;
            var writer = stream.writer(self.io, &write_buf);
            self.viewer.navigation.writeSelectionsJson(
                &writer.interface,
            ) catch |err| {
                std.log.warn("IPC selections write failed: {}", .{err});
                continue;
            };
            writer.interface.flush() catch |err| {
                std.log.warn("IPC selections flush failed: {}", .{err});
            };
        }
    }

    /// Returns `true` when all queued intents and background file scans have
    /// completed and the active slide (if any) has finished decoding and
    /// uploading.
    pub fn isWaitLoadReady(self: *const AppState) bool {
        if (self.pending_intents.items.len > 0 or
            self.viewer.navigation.isLoadingFiles() or
            self.workers.event_queue.hasPending())
        {
            return false;
        }
        if (self.viewer.ui.palette.openMode()) |mode| {
            switch (mode) {
                .directory_navigator => {
                    const active = &self.viewer.ui.palette.active_dir_scans;
                    if (active.load(.acquire) > 0) {
                        return false;
                    }
                },
                .files, .actions, .prompt => {},
            }
        }
        if (self.getCurrentEntry()) |entry| {
            if (!entry.inflight.isIdle()) {
                return false;
            }
            return switch (entry.resident.asset) {
                .none, .promoting_gpu => false,
                .loaded_cpu => self.gpu_device == null,
                .loaded_gpu, .failed => true,
            };
        }
        return self.viewer.navigation.current_index == null;
    }

    /// Replies `{"ok":true}` and closes all queued `wait_load` IPC streams
    /// once `isWaitLoadReady()` is satisfied.
    pub fn flushPendingWaitLoadStreams(self: *AppState) void {
        if (self.pending_wait_load_streams.items.len == 0 or
            !self.isWaitLoadReady())
        {
            return;
        }
        defer self.pending_wait_load_streams.clearRetainingCapacity();

        for (self.pending_wait_load_streams.items) |stream| {
            ipc.respondOk(self.io, stream) catch |err| {
                std.log.err(
                    "Failed to respond OK for wait_load command: {}",
                    .{err},
                );
            };
        }
    }

    /// Replies with a JSON error `err_name` and closes all queued `wait_load`
    /// IPC streams when the window is hidden or the application shuts down.
    pub fn abortPendingWaitLoadStreams(
        self: *AppState,
        err_name: []const u8,
    ) void {
        if (self.pending_wait_load_streams.items.len == 0) return;
        defer self.pending_wait_load_streams.clearRetainingCapacity();

        for (self.pending_wait_load_streams.items) |stream| {
            ipc.respondErrorName(self.io, stream, err_name);
        }
    }

    /// Returns `true` if the window display is currently in fullscreen mode.
    pub inline fn isFullscreen(self: *const AppState) bool {
        return self.display.isFullscreen();
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
        const cur_id = self.viewer.navigation.getCurrentMediaId() orelse
            return false;
        const entry = self.cache.getEntry(self.cache.activeKey(cur_id)) orelse
            return false;
        if (!entry.inflight.isIdle()) {
            return true;
        }
        return switch (entry.resident.asset) {
            .none, .promoting_gpu => true,
            .loaded_cpu => self.gpu_device != null,
            .loaded_gpu, .failed => false,
        };
    }

    /// Returns `true` if slideshow mode is active but paused due to explicit
    /// pause, hidden/suspended window, active modal, user dragging, or slide
    /// loading.
    pub fn isSlideshowPaused(self: *const AppState) bool {
        if (!self.viewer.isSlideshowActive()) return false;
        return self.display.isHidden() or
            self.display.isSuspended() or
            self.viewer.navigation.slideshow.isPaused() or
            self.viewer.ui.palette.isOpen() or
            self.viewer.drag_state != .none or
            self.isCurrentSlideLoading();
    }

    /// Returns the CacheEntry corresponding to the previous slide in an active
    /// crossfade, if available.
    pub fn getTransitionPrevEntry(self: *const AppState) ?CacheEntry {
        const prev_idx = self.viewer.getTransitionPrevIndex() orelse
            return null;
        const prev_id = self.viewer.navigation.getIdAt(prev_idx) orelse
            return null;
        return self.cache.getEntry(self.cache.activeKey(prev_id));
    }

    /// Returns the remaining millisecond deadline for transient holding timers
    /// (e.g. title auto-hide, snackbar, navigation settle, staging decay),
    /// or null if none active.
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
        if (self.viewer.navigation.cadence.settleTimeoutMs(now)) |cadence_rem| {
            const rem: u64 = cadence_rem;
            min_rem = if (min_rem) |cur| @min(cur, rem) else rem;
        }
        if (self.upload_staging.decayTimeoutMs(now)) |decay_rem| {
            const rem: u64 = decay_rem;
            min_rem = if (min_rem) |cur| @min(cur, rem) else rem;
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
        if (force_non_blocking or
            bg_events_processed or
            self.workers.event_queue.hasPending())
        {
            return .poll;
        }
        switch (self.display) {
            .hidden => return .wait_indefinite,
            .visible => {},
        }
        const is_current_loading = self.isCurrentSlideLoading();
        const has_gpu = self.gpu_device != null;
        if (self.display.isSuspended()) {
            const has_pending_work = is_current_loading or
                self.cache.hasPendingCpuUploads(has_gpu) or
                self.viewer.navigation.isLoadingFiles() or
                self.workers.isBusy() or
                (self.pending_wait_load_streams.items.len > 0) or
                (self.viewer.ui.screenshot_mode == .capturing);
            return if (has_pending_work)
                .{ .wait_timeout_ms = 8 }
            else
                .wait_indefinite;
        }
        const has_unpopulated_cache = blk: {
            if (self.viewer.navigation.getVisibleCount() <= 1) {
                break :blk false;
            }
            const neighbors =
                self.viewer.navigation.getVisibleNeighbors() orelse
                break :blk false;
            break :blk self.cache.hasUnreadyPrefetchSlots(
                &self.viewer.navigation,
                neighbors,
                has_gpu,
            );
        };
        const last_w = self.viewer.last_win_dims.w;
        const last_h = self.viewer.last_win_dims.h;
        const window_resized = last_w != 0 and
            (last_w != cur_win_w or last_h != cur_win_h);
        const is_busy = self.isBusy() or
            is_current_loading or
            (self.pending_wait_load_streams.items.len > 0) or
            (self.viewer.drag_state != .none) or
            (self.viewer.viewport.isZoomed() and
                self.viewer.pan_controller.isBusy()) or
            self.viewer.zoom_controller.isBusy() or
            has_unpopulated_cache or
            window_resized;
        const wait_timeout_ms = if (!is_busy)
            self.getWaitTimeoutMs(now_ticks)
        else
            null;

        return input.selectEventWaitStrategy(false, is_busy, wait_timeout_ms);
    }

    /// Releases all engine resources, cancels background worker tasks, and
    /// frees GPU textures and queues.
    pub fn deinit(self: *AppState) void {
        self.workers.deinit(self.allocator, self.io);

        if (self.gpu_device) |dev| {
            self.upload_staging.deinit(dev);

            switch (self.display.backend()) {
                .headless => {},
                .windowed => |w| w.handle.releaseFromGpu(dev),
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
        for (self.pending_selection_streams.items) |stream| {
            stream.close(self.io);
        }
        self.abortPendingWaitLoadStreams("ShuttingDown");
        self.viewer.deinit(self.allocator, self.io);
        self.display.deinit(self.allocator);
        self.pending_ipc_commands.deinit(self.allocator);
        self.pending_selection_streams.deinit(self.allocator);
        self.pending_wait_load_streams.deinit(self.allocator);
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
    /// scaling for display DPI and docked edit panel.
    pub fn getViewportPixelDims(self: *AppState) PhysicalDims {
        var win_w: f32 = 1024.0;
        var win_h: f32 = 768.0;
        var scale_x: f32 = 1.0;

        switch (self.display.backend()) {
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
            auth,
            self.viewer.viewport.rotation_angle,
            dims,
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
            auth,
            dims,
        );
    }

    /// Returns a copy of the CacheEntry corresponding to the currently active
    /// image, or null.
    pub fn getCurrentEntry(self: *const AppState) ?CacheEntry {
        const cur_id = self.viewer.navigation.getCurrentMediaId() orelse
            return null;
        return self.cache.getEntry(self.cache.activeKey(cur_id));
    }

    /// Snapshots live worker atomics, cache status, and active image
    /// decode/ingest telemetry into a read-only `ViewerStats` value.
    pub fn snapshotStats(self: *const AppState) ViewerStats {
        const active_threads =
            self.workers.active_decode_threads.load(.acquire);
        var stats = ViewerStats{
            .thumbs = self.workers.snapshotThumbStats(),
            .current_image_cache_hit = self.cache.current_image_cache_hit,
            .cached_slot_count = self.cache.count(),
            .total_vram_bytes = self.cache.getTotalVramBytes(),
            .active_decode_threads = active_threads,
            .max_decode_threads = self.workers.getMaxConcurrentDecodes(),
        };

        if (self.getCurrentEntry()) |entry| {
            const thumb_info = entry.resident.thumbnail.getInfo();
            const has_thumb = thumb_info != null;
            const thumb_upload_time_ms: f64 =
                if (thumb_info) |info| info.upload_time_ms else 0.0;
            const thumb_source: ThumbnailSource =
                if (thumb_info) |info| info.source else .embedded_header;

            stats.active_image = switch (entry.resident.asset) {
                .loaded_gpu => |gpu_comp| .{
                    .decode = gpu_comp.decode,
                    .ingest = gpu_comp.ingest,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                    .thumb_source = thumb_source,
                },
                .promoting_gpu => |promo| .{
                    .decode = promo.active.decode,
                    .ingest = promo.active.ingest,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                    .thumb_source = thumb_source,
                },
                .loaded_cpu => |asset| .{
                    .decode = asset.cpu.decode,
                    .ingest = null,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                    .thumb_source = thumb_source,
                },
                .none, .failed => .{
                    .decode = null,
                    .ingest = null,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                    .thumb_source = thumb_source,
                },
            };
        }

        return stats;
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
            self.viewer.viewport.rotation_angle =
                entry.metadata.orientation.toDegrees();
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
        stopTextInput(self.display);
        self.viewer.ui.palette.beginClose();
        const progress = self.viewer.animations.get(.palette_reveal);
        const duration = @max(state_pkg.DURATION_PALETTE_CLOSE_MS * progress, 30.0);
        self.viewer.animations.start(.palette_reveal, 0.0, duration, .ease_out_quad);
    }

    /// Immediately closes and resets the command palette without animation.
    pub fn closePaletteImmediately(self: *AppState) void {
        stopTextInput(self.display);
        self.viewer.ui.palette.reset();
        self.viewer.animations.setImmediate(.palette_reveal, 0.0);
    }

    /// Ensures the application window is visible and raises it to the
    /// foreground.
    pub fn showAndRaiseWindow(self: *AppState) void {
        const was_hidden = self.display.isHidden();
        if (was_hidden) {
            self.display = .{ .visible = self.display.backend() };
        }
        switch (self.display) {
            .hidden => unreachable,
            .visible => |*b| switch (b.*) {
                .headless => {},
                .windowed => |*win| {
                    if (was_hidden) {
                        if (!win.handle.show()) {
                            std.log.err(
                                "SDL_ShowWindow failed: {s}",
                                .{sdl.getError()},
                            );
                        }
                    }
                    win.is_occluded = false;
                    if (win.is_minimized) {
                        win.is_minimized = false;
                        if (!win.handle.restore()) {
                            std.log.warn(
                                "SDL_RestoreWindow failed: {s}",
                                .{sdl.getError()},
                            );
                        }
                    }
                    if (!win.handle.raise()) {
                        std.log.warn(
                            "SDL_RaiseWindow failed: {s}",
                            .{sdl.getError()},
                        );
                    }
                },
            },
        }
    }

    /// Hides the application window in resident server mode, resetting all
    /// viewport, adjustment, filter, overlay, navigation, and window settings
    /// back to startup defaults and unloading the active image cache and
    /// directory playlist while preserving the warm GPU device, compiled
    /// shaders, and picks/rejects selections.
    pub fn hideWindow(self: *AppState) void {
        switch (self.viewer.ui.screenshot_mode) {
            .idle => {},
            .capturing => |*s| {
                s.respondErrName(self.io, self.allocator, "WindowHidden");
                self.viewer.ui.screenshot_mode = .idle;
            },
        }
        self.abortPendingWaitLoadStreams("WindowHidden");
        self.closePaletteImmediately();
        self.viewer.ui.palette.last_nav_dir.clearRetainingCapacity();
        self.viewer.ui.palette.current_dir_image_count = 0;
        self.viewer.ui.palette.shrinkToWarmCapacity(self.allocator);
        self.viewer.resetToDefaults();
        self.viewer.ui.interaction.reset();

        _ = self.cache.advanceGeneration();
        _ = self.workers.precache_generation.fetchAdd(1, .acq_rel);
        self.workers.clearThumbWriteQueue(self.allocator, self.io);
        self.clearCache();
        if (self.cache.slots.capacity > 16) {
            self.cache.slots.shrinkAndFree(self.allocator, 0);
        }
        if (self.gpu_device) |dev| {
            self.upload_staging.deinit(dev);
        }
        self.clearRotationMap();
        self.viewer.navigation.clearEntries();
        self.viewer.navigation.trimExcessCapacity(self.allocator);
        self.viewer.navigation.last_scanned_dir.clearRetainingCapacity();
        _ = self.viewer.navigation.directory_arena.reset(.free_all);

        switch (self.display.backendPtr().*) {
            .headless => {},
            .windowed => |*win| {
                if (win.is_fullscreen) {
                    win.is_fullscreen = false;
                    win.handle.setFullscreen(false) catch |err| {
                        std.log.err("setFullscreen failed: {}", .{err});
                    };
                }
                if (win.is_borderless != self.viewer.defaults.windowless) {
                    win.is_borderless = self.viewer.defaults.windowless;
                    if (!win.handle.setBordered(!win.is_borderless)) {
                        std.log.err(
                            "SDL_SetWindowBordered failed: {s}",
                            .{sdl.getError()},
                        );
                    }
                }
                win.is_minimized = false;
                win.is_occluded = false;
                if (win.screensaver_inhibited) {
                    win.screensaver_inhibited = false;
                    if (!sdl.enableScreenSaver()) {
                        std.log.warn(
                            "SDL_EnableScreenSaver failed: {s}",
                            .{sdl.getError()},
                        );
                    }
                }
                win.handle.setTitle("Peng Image Viewer");
                if (win.cached_title) |cached| {
                    self.allocator.free(cached);
                    win.cached_title = null;
                }
            },
        }

        switch (self.display) {
            .visible => |b| {
                switch (b) {
                    .headless => {},
                    .windowed => |win| {
                        if (!win.handle.hide()) {
                            std.log.err(
                                "SDL_HideWindow failed: {s}",
                                .{sdl.getError()},
                            );
                        }
                    },
                }
                self.display = .{ .hidden = b };
                sdl.reclaimProcessHeap();
            },
            .hidden => {},
        }
    }

    /// Begins an asynchronous directory load in the Command Palette navigator
    /// and spawns the two-stage `paletteScanWorker` to list subdirectories and
    /// count folder contents off the render thread.
    pub fn loadPaletteDirectory(
        self: *AppState,
        dir_path: []const u8,
        preselect_child: ?[]const u8,
        walk_up_if_empty: bool,
    ) !void {
        const cur_nav = self.viewer.ui.palette.current_nav_dir.items;
        var prev_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var prev_dir_sfa: std.heap.BufferFirstAllocator = .init(
            &prev_dir_buf,
            self.allocator,
        );
        const temp_alloc = prev_dir_sfa.allocator();
        const prev_dir: ?[]const u8 = if (cur_nav.len > 0)
            try temp_alloc.dupe(u8, cur_nav)
        else
            null;
        defer if (prev_dir) |p| temp_alloc.free(p);

        const spec = try self.viewer.ui.palette.beginDirectoryLoad(
            self.allocator,
            dir_path,
            preselect_child,
        );
        try workers_mod.spawnPaletteScan(
            &self.workers,
            self.allocator,
            self.io,
            spec.generation,
            &self.viewer.ui.palette.dir_scan_generation,
            &self.viewer.ui.palette.active_dir_scans,
            spec.target_dir,
            if (spec.needs_child_resolve) prev_dir else null,
            walk_up_if_empty,
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
            if (std.Io.Dir.path.dirname(file_path)) |parent| {
                return .{
                    .start_dir = parent,
                    .preselect_child = std.Io.Dir.path.basename(file_path),
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

    fn beginOpenPalette(
        self: *AppState,
        active_type: ActivePaletteMode,
    ) void {
        self.viewer.ui.palette.reset();
        self.viewer.ui.palette.lifecycle = .{ .open = active_type };
        self.viewer.animations.start(
            .palette_reveal,
            1.0,
            state_pkg.DURATION_PALETTE_OPEN_MS,
            .ease_out_cubic,
        );
        self.viewer.ui.palette.selected_idx = switch (active_type) {
            .files => self.viewer.navigation.current_index orelse 0,
            .actions, .directory_navigator, .prompt => 0,
        };
        self.viewer.ui.palette.selection_dirty = true;
    }

    /// Activates the command palette in `.directory_navigator` mode at
    /// `dir_path`, resetting stale state, starting the reveal animation,
    /// loading directory entries, and enabling text input.
    pub fn openDirectoryPalette(
        self: *AppState,
        dir_path: []const u8,
    ) !void {
        self.beginOpenPalette(.directory_navigator);
        try self.loadPaletteDirectory(dir_path, null, false);
        startTextInput(self.display);
    }

    /// Activates the command palette in the specified `ActivePaletteMode`,
    /// resetting queries and starting text input.
    pub fn openPalette(
        self: *AppState,
        active_type: ActivePaletteMode,
    ) !void {
        self.beginOpenPalette(active_type);

        switch (active_type) {
            .files => try self.viewer.ui.palette.rebuildFileMatches(
                self.allocator,
                self.viewer.navigation.getEntries(),
            ),
            .actions => try self.viewer.ui.palette.rebuildActionMatches(
                self.allocator,
            ),
            .directory_navigator => {
                const nav_path = resolveNavigatorInitialPath(self);
                try self.loadPaletteDirectory(
                    nav_path.start_dir,
                    nav_path.preselect_child,
                    true,
                );
            },
            .prompt => |kind| switch (kind) {
                .slideshow_interval => {
                    var buf: [32]u8 = undefined;
                    const dur_secs = switch (self.viewer.navigation.slideshow) {
                        .active => |s| s.interval_s,
                        .inactive => 3.0,
                    };
                    const formatted = std.mem.print(
                        &buf,
                        "{d:.1}",
                        .{dur_secs},
                    ) catch |err| blk: {
                        std.log.warn(
                            "Failed to format slideshow interval: {}, " ++
                                "defaulting to 3.0",
                            .{err},
                        );
                        break :blk "3.0";
                    };
                    try self.viewer.ui.palette.query.appendSlice(
                        self.allocator,
                        formatted,
                    );
                },
                .go_to_image, .edit_param => {},
            },
        }
        startTextInput(self.display);
    }

    /// Resets pan/zoom controllers, viewport state, rotation angle, base scale,
    /// and active image/thumbnail crossfade transitions.
    pub fn resetViewportAndTransitions(self: *AppState) void {
        self.viewer.pan_controller.reset();
        self.viewer.zoom_controller.reset();
        self.viewer.viewport.reset();
        self.updateCurrentRotation();
        if (self.viewer.viewport.mode != .manual) {
            self.viewer.viewport.zoom_factor = .init(self.getBaseScale());
        }
        self.viewer.image_transition = .none;
        self.viewer.animations.setImmediate(.image_crossfade, 1.0);
        self.viewer.animations.setImmediate(.thumb_crossfade, 1.0);
    }

    /// Allocates a cache job ticket (`job_id`, `job_epoch`), duplicates
    /// `entry_item`, updates the slot's `inflight` state, and spawns a
    /// background decode worker for `id` with `errdefer` rollback.
    pub fn spawnSlotDecode(
        self: *AppState,
        id: MediaId,
        entry_item: MediaEntry,
        mode: DecodeMode,
        pair_target: PairStreamTarget,
        now_ms: u64,
    ) !void {
        const key = self.cache.activeKey(id);
        if (self.cache.getEntry(key)) |entry| {
            switch (entry.inflight) {
                .idle, .queued_decode => {},
                .decoding, .uploading => return error.SlotBusy,
            }
        }

        const ticket = self.cache.allocJob() orelse return error.OutOfMemory;
        errdefer self.cache.cancelJob(ticket.job_id);

        const dup_entry = entry_item.dupe(self.allocator) catch |err| {
            std.log.err(
                "Failed to dupe MediaEntry for decode worker: {}",
                .{err},
            );
            return err;
        };
        errdefer dup_entry.deinit(self.allocator);

        const args = try self.allocator.create(workers_mod.DecodeArgs);
        errdefer self.allocator.destroy(args);

        const prev_inflight: ?InFlightState =
            if (self.cache.get(key)) |entry| blk: {
                const prev = entry.inflight;
                const start_ms = switch (prev) {
                    .idle => now_ms,
                    .queued_decode => |q| q.start_time_ms,
                    .decoding, .uploading => unreachable,
                };
                entry.inflight = .{
                    .decoding = .{
                        .start_time_ms = start_ms,
                        .target = pair_target,
                        .ticket = ticket,
                    },
                };
                break :blk prev;
            } else null;
        errdefer {
            if (prev_inflight) |prev| {
                if (self.cache.get(key)) |entry| {
                    entry.inflight = prev;
                }
            }
        }

        const has_gpu_device = (self.gpu_device != null) or self.gpu_enabled;
        args.* = workers_mod.DecodeArgs{
            .workers = &self.workers,
            .allocator = self.allocator,
            .io = self.io,
            .key = key,
            .job_id = ticket.job_id,
            .job_epoch = ticket.epoch,
            .current_job_epoch = &self.cache.job_epochs[ticket.job_id],
            .entry = dup_entry,
            .has_gpu_device = has_gpu_device,
            .pixel_format = self.display.getPixelFormat(),
            .mode = mode,
            .pair_target = pair_target,
            .current_generation = &self.cache.generation,
        };

        try workers_mod.spawnDecode(args);
    }

    /// Initiates loading a target path (file or directory). When opening a
    /// regular image file that already resides in the active, fully scanned
    /// directory playlist, jumps directly to that entry while preserving the
    /// warm VRAM cache and classifications; otherwise performs a full reload.
    pub fn openPath(self: *AppState, path: []const u8) !void {
        return self.openPathInternal(path, true);
    }

    /// Forces a full directory re-scan and cache reload for `path` (used by
    /// directory refresh and RAW+JPEG stacking toggles).
    pub fn reloadPath(self: *AppState, path: []const u8) !void {
        return self.openPathInternal(path, false);
    }

    fn openPathInternal(
        self: *AppState,
        path: []const u8,
        reuse_loaded_dir: bool,
    ) !void {
        // Copy `path` upfront because callers may pass a slice backed by
        // `directory_arena` (reset below) or `last_scanned_dir.items`
        // (cleared and written below).
        var stack_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var path_sfa: std.heap.BufferFirstAllocator = .init(
            &stack_buf,
            self.allocator,
        );
        const path_alloc = path_sfa.allocator();
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

        if (has_stat) {
            self.showAndRaiseWindow();
        }

        const dir_target = if (has_stat and stat.kind == .directory)
            owned_path
        else
            std.Io.Dir.path.dirname(owned_path) orelse ".";

        if (reuse_loaded_dir and
            has_stat and
            stat.kind == .file and
            !isCbzFile(owned_path) and
            !self.viewer.navigation.isLoadingFiles() and
            MediaEntry.pathsMatch(
                self.viewer.navigation.last_scanned_dir.items,
                dir_target,
            ))
        {
            if (self.viewer.navigation.findMatchingIndex(owned_path)) |idx| {
                if (!self.viewer.navigation.isIndexVisible(idx)) {
                    const target_class =
                        self.viewer.navigation.getClassification(idx);
                    self.viewer.navigation.triage.view_mode =
                        if (target_class == .reject) .all else .default;
                }
                _ = self.viewer.navigation.goToIndex(
                    idx,
                    sdl.timer.getTicks(),
                );
                self.resetViewportAndTransitions();
                if (self.viewer.ui.palette.openMode()) |mode| switch (mode) {
                    .files => try self.viewer.ui.palette.rebuildFileMatches(
                        self.allocator,
                        self.viewer.navigation.getEntries(),
                    ),
                    .actions, .directory_navigator, .prompt => {},
                };
                return;
            }
        }

        self.viewer.navigation.last_scanned_dir.clearRetainingCapacity();
        try self.viewer.navigation.last_scanned_dir.appendSlice(
            self.allocator,
            dir_target,
        );

        _ = self.cache.advanceGeneration();
        _ = self.workers.precache_generation.fetchAdd(1, .acq_rel);
        self.clearCache();
        self.clearRotationMap();
        self.viewer.navigation.clearEntries();
        self.viewer.navigation.resetDirectoryArena();
        self.viewer.navigation.trimExcessCapacity(self.allocator);

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
            } else if (isCbzFile(owned_path)) {
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
                const initial_id = try self.viewer.navigation.appendEntry(
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

                // Spawn immediate decode for slot 0 to overlap with
                // graphics/GPU init
                _ = try self.cache.appendSlot(self.allocator, initial_id, .{});
                const pair_target: PairStreamTarget =
                    if (stack_raw) .adaptive else .standalone_jpeg;
                try self.spawnSlotDecode(
                    initial_id,
                    .{ .filesystem = .{ .path = dup } },
                    .full,
                    pair_target,
                    sdl.timer.getTicks(),
                );
            }
        }
        self.resetViewportAndTransitions();
        if (self.viewer.ui.palette.openMode()) |mode| switch (mode) {
            .files => try self.viewer.ui.palette.rebuildFileMatches(
                self.allocator,
                self.viewer.navigation.getEntries(),
            ),
            .actions, .directory_navigator, .prompt => {},
        };
    }
};

test "AppState.getBaseScale based on image dimensions" {
    var state = try AppState.initHeadless(
        std.testing.allocator,
        std.Io.Threaded.global_single_threaded.io(),
    );
    defer state.deinit();

    // Default base_scale without loaded image is 1.0
    try std.testing.expectEqual(@as(f32, 1.0), state.getBaseScale());
    try std.testing.expectEqual(
        @as(f32, 100.0),
        ZoomFactor.init(150.0).get(),
    );
    try std.testing.expectEqual(
        @as(f32, 0.001),
        ZoomFactor.init(0.0001).get(),
    );

    // Test with loaded CPU image entry
    _ = try state.viewer.navigation.appendEntry(
        std.testing.allocator,
        .{ .filesystem = .{ .path = "test.png" } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const surf = sdl.Surface.create(
        4000,
        3000,
        sdl.PixelFormat.rgba32,
    ) orelse unreachable;
    _ = try state.cache.appendSlot(std.testing.allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 4000.0,
                        .h = 3000.0,
                        .mime_type = "image/png",
                        .size_bytes = 1000,
                    },
                },
            },
        },
    });

    // In .none mode on 4000x3000 image, base_scale is 1.0
    state.viewer.viewport.fit_mode = .none;
    const base_none = state.getBaseScale();
    try std.testing.expectEqual(@as(f32, 1.0), base_none);
    const clamped_max_none = ZoomFactor.init(15.0);
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
    var state = try AppState.initHeadless(
        std.testing.allocator,
        std.Io.Threaded.global_single_threaded.io(),
    );
    defer state.deinit();

    const dims = state.getViewportPixelDims();
    try std.testing.expectEqual(@as(f32, 1024.0), dims.w);
    try std.testing.expectEqual(@as(f32, 768.0), dims.h);

    _ = try state.viewer.navigation.appendEntry(
        std.testing.allocator,
        .{ .filesystem = .{ .path = "test.png" } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const surf = sdl.Surface.create(
        4000,
        3000,
        sdl.PixelFormat.rgba32,
    ) orelse unreachable;
    _ = try state.cache.appendSlot(std.testing.allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 4000.0,
                        .h = 3000.0,
                        .mime_type = "image/png",
                        .size_bytes = 1000,
                    },
                },
            },
        },
    });

    // In .full mode, 4000x3000 image fits within 1024x768 -> not overflowing
    state.viewer.viewport.fit_mode = .full;
    state.viewer.viewport.mode = .fit;
    try std.testing.expect(!state.isImageOverflowing());

    // In .manual mode with zoom 1.0 (4000x3000 > 1024x768) -> overflowing
    state.viewer.viewport.mode = .manual;
    state.viewer.viewport.zoom_factor = ZoomFactor.init(1.0);
    try std.testing.expect(state.isImageOverflowing());
}

test "AppState.updateCurrentRotation syncs EXIF orientation" {
    var state = try AppState.initHeadless(
        std.testing.allocator,
        std.Io.Threaded.global_single_threaded.io(),
    );
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(
        std.testing.allocator,
        .{ .filesystem = .{ .path = "test_photo_1.jpg" } },
    );
    state.viewer.navigation.current_index = 0;

    // Initially uncached -> rotation_angle should be 0.0
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.viewer.viewport.rotation_angle);

    // Simulate worker thread caching EXIF orientation of 90.0
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const key = try state.cache.appendSlot(
        std.testing.allocator,
        id0,
        .{},
    );
    state.cache.get(key).?.metadata.orientation = .rotate_90;

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

test "AppState.computeFrameWaitStrategy schedules cadence settle timeout" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Idle cadence enters indefinite 0% CPU wait
    try std.testing.expectEqual(
        input.EventWaitStrategy.wait_indefinite,
        state.computeFrameWaitStrategy(1024.0, 768.0, false, false, 1000),
    );

    // Within 35ms fast-scroll window -> wakes at 35ms settle boundary
    state.viewer.navigation.cadence.recordNavigation(1000);
    try std.testing.expectEqual(
        input.EventWaitStrategy{ .wait_timeout_ms = 25 },
        state.computeFrameWaitStrategy(1024.0, 768.0, false, false, 1010),
    );

    // Between 35ms and 250ms -> wakes after 250ms promotion settle window
    try std.testing.expectEqual(
        input.EventWaitStrategy{ .wait_timeout_ms = 151 },
        state.computeFrameWaitStrategy(1024.0, 768.0, false, false, 1100),
    );

    // Past 250ms -> settled, enters indefinite 0% CPU wait
    try std.testing.expectEqual(
        input.EventWaitStrategy.wait_indefinite,
        state.computeFrameWaitStrategy(1024.0, 768.0, false, false, 1251),
    );
}

test "AppState.openPath preserves closing palette matches" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

    // Slot 0 must be appended immediately in .decoding state
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const entry0 = state.cache.get(state.cache.activeKey(id0));
    try std.testing.expect(entry0 != null);
    switch (entry0.?.inflight) {
        .decoding => {},
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }
}

test "AppState.openPath acquires job ticket and epoch for single image" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const sample_jpg = "testfiles/images/000_0_1024x682.jpg";
    try state.openPath(sample_jpg);

    const id0 = state.viewer.navigation.getIdAt(0).?;
    const entry0 = state.cache.get(state.cache.activeKey(id0)).?;
    const dec = switch (entry0.inflight) {
        .decoding => |d| d,
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    };

    try std.testing.expect(dec.ticket.job_id < cache.MAX_DECODE_JOBS);
    try std.testing.expect(dec.ticket.epoch >= 1);

    const job_bit = @as(u16, 1) << @as(u4, @truncate(dec.ticket.job_id));
    try std.testing.expect((state.cache.job_alloc_mask & job_bit) != 0);
    try std.testing.expectEqual(
        dec.ticket.epoch,
        state.cache.job_epochs[dec.ticket.job_id].load(.acquire),
    );
    try std.testing.expect(state.cache.validateJobEpoch(0, dec.ticket.epoch));

    // Cancelling the slot 0 job advances its pinned epoch and frees the bit
    state.cache.cancelJob(dec.ticket.job_id);
    try std.testing.expect((state.cache.job_alloc_mask & job_bit) == 0);
    try std.testing.expectEqual(
        dec.ticket.epoch + 1,
        state.cache.job_epochs[dec.ticket.job_id].load(.acquire),
    );

    const reused = state.cache.allocJob().?;
    try std.testing.expectEqual(dec.ticket.job_id, reused.job_id);
    try std.testing.expectEqual(dec.ticket.epoch + 1, reused.epoch);
    state.cache.releaseJob(reused.job_id);
}

test "AppState.openPath reuses warm directory playlist and resets viewport" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const img0 = "testfiles/images/000_0_1024x682.jpg";
    const img1 = "testfiles/images/001_1_1024x682.jpg";
    try state.viewer.navigation.last_scanned_dir.appendSlice(
        allocator,
        "testfiles/images",
    );
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, img0) } },
    );
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, img1) } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{ .asset = .failed },
    });
    const gen_before = state.cache.generation.load(.acquire);

    // Mutate viewport before calling openPath on img1 in same directory
    state.viewer.viewport.mode = .manual;
    state.viewer.viewport.setPan(120.0, -80.0);

    try state.openPath(img1);

    // Must reuse the existing generation & cache and jump to index 1
    try std.testing.expectEqual(
        gen_before,
        state.cache.generation.load(.acquire),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        state.viewer.navigation.current_index,
    );
    try std.testing.expectEqual(@as(usize, 1), state.cache.count());
    try std.testing.expectEqual(@as(f32, 0.0), state.viewer.viewport.pan_x);
    try std.testing.expectEqual(@as(f32, 0.0), state.viewer.viewport.pan_y);
}

test "AppState - promoting_gpu marks slide loading and hideWindow clears it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, "a.jpg") } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const up_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
        return;
    const th_surf = sdl.Surface.create(8, 8, sdl.PixelFormat.rgba32) orelse {
        up_surf.destroy();
        return;
    };
    const stub = CacheEntry.stubLoadedGpuForTest(
        .{ .w = 16.0, .h = 16.0 },
        .{ .w = 0.0, .h = 0.0 },
    );
    const active_gpu = switch (stub.resident.asset) {
        .loaded_gpu => |g| g,
        .none, .loaded_cpu, .promoting_gpu, .failed => unreachable,
    };
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .promoting_gpu = .{
                    .active = active_gpu,
                    .staged = .{
                        .cpu = .{
                            .surface = up_surf,
                            .w = 16.0,
                            .h = 16.0,
                            .size_bytes = 1024,
                        },
                    },
                },
            },
            .thumbnail = .{ .staged_cpu = .{ .surface = th_surf } },
        },
    });

    try std.testing.expect(state.isCurrentSlideLoading());
    try std.testing.expect(!state.isWaitLoadReady());

    // Settling back to .loaded_gpu returns to ready
    switch (state.cache.get(key0).?.resident.asset) {
        .promoting_gpu => |*promo| {
            promo.staged.deinit();
            state.cache.get(key0).?.resident.asset = .{
                .loaded_gpu = promo.active,
            };
        },
        .none, .loaded_cpu, .loaded_gpu, .failed => unreachable,
    }
    try std.testing.expect(!state.isCurrentSlideLoading());
    try std.testing.expect(state.isWaitLoadReady());

    // Re-stage .promoting_gpu and verify hideWindow frees all staged surfaces
    const up_surf2 = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
        return;
    state.cache.get(key0).?.resident.asset = .{
        .promoting_gpu = .{
            .active = active_gpu,
            .staged = .{
                .cpu = .{
                    .surface = up_surf2,
                    .w = 16.0,
                    .h = 16.0,
                    .size_bytes = 1024,
                },
            },
        },
    };
    state.hideWindow();
    try std.testing.expectEqual(@as(usize, 0), state.cache.count());
}

test "AppState.getWaitTimeoutMs schedules staging decay and clears when null" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Unallocated / warm staging sleeps indefinitely at 0% CPU
    try std.testing.expectEqual(@as(?i32, null), state.getWaitTimeoutMs(1000));
    try std.testing.expectEqual(
        input.EventWaitStrategy.wait_indefinite,
        state.computeFrameWaitStrategy(1024.0, 768.0, false, false, 1000),
    );

    // Oversized staging stamped at 1000ms schedules capped 2000ms wakeup
    state.upload_staging.oversized_since_ms = 1000;
    try std.testing.expectEqual(@as(?i32, 2000), state.getWaitTimeoutMs(1000));
    try std.testing.expectEqual(
        input.EventWaitStrategy{ .wait_timeout_ms = 2000 },
        state.computeFrameWaitStrategy(1024.0, 768.0, false, false, 1000),
    );

    // Near 5s deadline (4500ms elapsed -> 500ms remaining)
    try std.testing.expectEqual(@as(?i32, 500), state.getWaitTimeoutMs(5500));
    try std.testing.expectEqual(
        input.EventWaitStrategy{ .wait_timeout_ms = 500 },
        state.computeFrameWaitStrategy(1024.0, 768.0, false, false, 5500),
    );

    // Shorter transient title timeout wins via @min
    state.viewer.ui.overlays.title_display = .{
        .transient = .{ .timeout_ms = 5650 },
    };
    try std.testing.expectEqual(@as(?i32, 150), state.getWaitTimeoutMs(5500));

    // Once decayed (oversized_since_ms == null) and title hidden -> indefinite
    state.viewer.ui.overlays.title_display = .hidden;
    state.upload_staging.oversized_since_ms = null;
    try std.testing.expectEqual(@as(?i32, null), state.getWaitTimeoutMs(6000));
    try std.testing.expectEqual(
        input.EventWaitStrategy.wait_indefinite,
        state.computeFrameWaitStrategy(1024.0, 768.0, false, false, 6000),
    );
}

test "AppState.isWaitLoadReady blocks during directory_navigator scan" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.ui.palette.lifecycle = .{ .open = .directory_navigator };
    state.viewer.ui.palette.active_dir_scans.store(1, .release);
    try std.testing.expect(!state.isWaitLoadReady());

    // Closing palette unblocks wait_load immediately even if stale scan runs
    state.viewer.ui.palette.beginClose();
    try std.testing.expect(state.isWaitLoadReady());

    state.viewer.ui.palette.lifecycle = .{ .open = .directory_navigator };
    try std.testing.expect(!state.isWaitLoadReady());

    state.viewer.ui.palette.active_dir_scans.store(0, .release);
    try std.testing.expect(state.isWaitLoadReady());
}

test "AppState.snapshotStats maps CPU, GPU, and promoting_gpu telemetry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "test.jpg" },
    });
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const surf = sdl.Surface.create(10, 10, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;

    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 10.0,
                        .h = 10.0,
                        .size_bytes = 400,
                        .decode = .{
                            .read_time_ms = 1.25,
                            .decode_time_ms = 3.5,
                            .conversion_time_ms = 0.5,
                            .archive = .none,
                        },
                    },
                },
            },
        },
    });

    const cpu_snap = state.snapshotStats();
    try std.testing.expect(!cpu_snap.current_image_cache_hit);
    try std.testing.expect(cpu_snap.active_image.decode != null);
    try std.testing.expect(cpu_snap.active_image.ingest == null);
    const dec = cpu_snap.active_image.decode.?;
    try std.testing.expectEqual(@as(f64, 1.25), dec.read_time_ms);
    try std.testing.expectEqual(@as(f64, 3.5), dec.decode_time_ms);
    try std.testing.expectEqual(ArchiveTelemetry.none, dec.archive);

    // GPU-loaded asset + cache hit toggle
    const stub = CacheEntry.stubLoadedGpuForTest(
        .{ .w = 10.0, .h = 10.0 },
        .{ .w = 0.0, .h = 0.0 },
    );
    var gpu_comp = switch (stub.resident.asset) {
        .loaded_gpu => |g| g,
        .none, .loaded_cpu, .promoting_gpu, .failed => unreachable,
    };
    gpu_comp.size_bytes = 400;
    gpu_comp.decode = .{
        .read_time_ms = 1.25,
        .decode_time_ms = 3.5,
        .conversion_time_ms = 0.5,
        .archive = ArchiveTelemetry.init(4.2, 2048),
    };
    gpu_comp.ingest = .{
        .upload_time_ms = 0.8,
        .memory_size_bytes = 1024,
        .mode = .direct,
        .mipmaps = MipmapTelemetry.init(3, 1.1),
    };
    state.cache.setResidentAsset(key0, .{ .loaded_gpu = gpu_comp }, null);
    state.cache.current_image_cache_hit = true;

    const gpu_snap = state.snapshotStats();
    try std.testing.expect(gpu_snap.current_image_cache_hit);
    try std.testing.expect(gpu_snap.active_image.decode != null);
    try std.testing.expect(gpu_snap.active_image.ingest != null);
    const gpu_ing = gpu_snap.active_image.ingest.?;
    try std.testing.expectEqual(@as(f64, 0.8), gpu_ing.upload_time_ms);
    try std.testing.expectEqual(@as(usize, 1024), gpu_ing.memory_size_bytes);
    try std.testing.expectEqual(UploadMode.direct, gpu_ing.mode);
    switch (gpu_ing.mipmaps) {
        .disabled => return error.TestExpectedGenerated,
        .generated => |g| {
            try std.testing.expectEqual(@as(u32, 3), g.num_levels);
            try std.testing.expectEqual(@as(f64, 1.1), g.generate_time_ms);
        },
    }

    // Promoting GPU asset with loaded thumbnail metadata
    const staged_surf =
        sdl.Surface.create(4, 4, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    state.cache.setResidentAsset(
        key0,
        .{
            .promoting_gpu = .{
                .active = gpu_comp,
                .staged = .{
                    .cpu = .{
                        .surface = staged_surf,
                        .w = 4.0,
                        .h = 4.0,
                        .size_bytes = 64,
                    },
                },
            },
        },
        null,
    );
    state.cache.get(key0).?.resident.thumbnail = .{
        .unloaded = .{
            .w = 4.0,
            .h = 4.0,
            .upload_time_ms = 2.4,
            .source = .freedesktop_cache,
        },
    };

    const promo_snap = state.snapshotStats();
    try std.testing.expect(promo_snap.active_image.decode != null);
    try std.testing.expect(promo_snap.active_image.ingest != null);
    try std.testing.expectEqual(
        @as(usize, 1024),
        promo_snap.active_image.ingest.?.memory_size_bytes,
    );
    try std.testing.expect(promo_snap.active_image.has_thumb);
    try std.testing.expectEqual(
        @as(f64, 2.4),
        promo_snap.active_image.thumb_upload_time_ms,
    );
    try std.testing.expectEqual(
        ThumbnailSource.freedesktop_cache,
        promo_snap.active_image.thumb_source,
    );
}
