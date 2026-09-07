const app_input = @import("input");
const clay = @import("zclay");
const core_fs = @import("core/fs.zig");
const events = @import("core/events.zig");
const exif = @import("core/exif.zig");
const fuzzig = @import("fuzzig");
const image = @import("core/image.zig");
const intents = @import("intents");
const ipc = @import("ipc");
const palette_module = @import("core/palette.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const systems = @import("systems/root.zig");
const workers_mod = @import("workers/root.zig");

const ActiveWindow = state_pkg.ActiveWindow;
const AppIntent = intents.AppIntent;
const CacheEntry = state_pkg.CacheEntry;
const CacheKey = image.CacheKey;
const CacheSlotMap = image.CacheSlotMap;
const CacheStatus = state_pkg.CacheStatus;
const DecodeArgs = workers_mod.DecodeArgs;
const DisplayState = state_pkg.DisplayState;
const DragState = state_pkg.DragState;
pub const ElementTag = state_pkg.ElementTag;
const FrameInput = types.FrameInput;
const OverlayState = state_pkg.OverlayState;
const PaletteMode = intents.PaletteMode;
const PaletteState = state_pkg.PaletteState;
const ScaleMode = intents.ScaleMode;
const SlideshowMode = state_pkg.SlideshowMode;
const TextureHandle = image.TextureHandle;
const TextureScaleMode = intents.TextureScaleMode;
const types = state_pkg.types;
const UiRenderMetrics = state_pkg.UiRenderMetrics;
const uploadSurfaceToGpu = image.uploadSurfaceToGpu;
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

/// Performs case-insensitive matching between `path` and an already lowercased query string.
fn matchesQueryLower(path: []const u8, query_lower: []const u8) bool {
    if (query_lower.len == 0) return true;
    if (path.len < query_lower.len) return false;

    var i: usize = 0;
    const end = path.len - query_lower.len;
    while (i <= end) : (i += 1) {
        var match = true;
        for (query_lower, 0..) |q_char, j| {
            const pc = std.ascii.toLower(path[i + j]);
            if (q_char != pc) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
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
            self.workers.cached_cpu_count = std.Thread.getCpuCount() catch 4;
        }
        // 16 intents: accommodates worst-case enqueued IPC, keyboard, palette, and slideshow intents in a single tick
        try self.pending_intents.ensureTotalCapacity(self.allocator, 16);
        // 16 events: accommodates concurrent worker background events (decodes, EXIF, path scans) processed per tick
        try self.event_batch.ensureTotalCapacity(self.allocator, 16);
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

    /// Returns `true` if files are currently loading, background workers are active, slideshow is running, or animations are active.
    pub inline fn isBusy(self: *const AppState) bool {
        return self.viewer.hasActiveAnimation() or self.viewer.navigation.is_loading_files.load(.acquire) or self.workers.isBusy() or self.viewer.isSlideshowActive();
    }

    /// Reads EXIF orientation from a JPEG file header on disk, returning `null` if unparseable.
    pub fn readJpegExifOrientation(self: *const AppState, path: []const u8) ?state_pkg.Orientation {
        return exif.readJpegExifOrientation(self.io, path);
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
        const upload_res = uploadSurfaceToGpu(dev, extracted.surface, self.unpack_compute_pipeline, &self.upload_staging) orelse {
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
                },
            },
        };
        self.updateCurrentRotation();
    }

    /// Enables or disables the debug thumbnail overlay preview, extracting and uploading the thumbnail if needed.
    pub fn setDebugShowThumb(self: *AppState, enable: bool) !void {
        self.viewer.ui.overlays.debug_show_thumb = enable;
        if (!enable) return;
        self.ensureCurrentThumbnailLoaded();
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

        const title_bar_h: f32 = if (self.viewer.isFullscreen()) 0.0 else 60.0;

        var available_width = win_w;
        if (clay.isDebugModeEnabled()) {
            available_width = @max(available_width - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0);
        }
        const view_w = @max(available_width, 1.0);
        const view_h = @max(win_h - title_bar_h, 1.0);

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
    fn getCurrentEntryPtr(self: *AppState) ?*CacheEntry {
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
            else => {},
        }

        startTextInput(self.viewer.display);
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

    /// Scans cache slots around the current navigation index, evicting distant textures and uploading ready surfaces to the GPU.
    pub fn prepareCacheTextures(self: *AppState) void {
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

        // Priority gating:
        // - If current image is .loaded_cpu, prioritize uploading it first.
        // - If current image is .decoding or .uploading, withhold neighbor uploads to protect GPU resources.
        // - If current image is .loaded_gpu (or failed, or not present), upload neighbor .loaded_cpu slots (1 per frame).
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
                if (uploadSurfaceToGpu(gpu_dev, target.cpu.surface, self.unpack_compute_pipeline, &self.upload_staging)) |res| {
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
                        self.cache.enforceVramBudget(gpu_dev, self.viewer.navigation.current_index, self.viewer.navigation.image_list.items.len, image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES);
                        if (self.viewer.navigation.current_index) |cur_idx| {
                            if (self.cache.activeKey(cur_idx).index == target.key.index) {
                                if (self.cache.get(target.key)) |entry| {
                                    if (entry.thumbnail == .loaded and !self.viewer.ui.overlays.debug_show_thumb) {
                                        self.viewer.animations.setImmediate(.thumb_crossfade, 0.0);
                                        self.viewer.animations.start(.thumb_crossfade, 1.0, state_pkg.DURATION_THUMB_CROSSFADE_MS, .ease_out_quad);
                                    }
                                }
                            }
                        }
                    }
                } else {
                    _ = self.cache.updateStatus(target.key, .failed);
                }
            }
        }
    }

    /// Releases all GPU textures and resets status across all cache slots.
    fn clearCache(self: *AppState) void {
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

    /// Selects a file or directory path, clearing prior caches and launching asynchronous path scanning.
    pub fn handlePathSelection(self: *AppState, path: []const u8) !void {
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

        // Clear existing cache and rotation map before resetting directory_arena
        _ = self.cache.advanceGeneration();
        self.clearCache();
        self.clearRotationMap();
        self.viewer.navigation.image_list.clearRetainingCapacity();
        _ = self.viewer.navigation.directory_arena.reset(.retain_capacity);
        self.viewer.navigation.current_index = null;

        if (has_stat) {
            if (stat.kind == .directory) {
                try workers_mod.startAsyncPathScan(self, path, true);
            } else if (core_fs.isCbzFile(path)) {
                self.viewer.navigation.is_loading_files.store(true, .release);
                try workers_mod.startAsyncPathScan(self, path, false);
            } else {
                const dup = try self.viewer.navigation.directory_arena.allocator().dupe(u8, path);
                try self.viewer.navigation.image_list.append(self.allocator, .{ .filesystem = .{ .path = dup } });
                self.viewer.navigation.current_index = 0;

                try workers_mod.startAsyncPathScan(self, path, false);
            }
        }
        try self.rebuildPaletteMatches();
    }

    /// Initiates an asynchronous background directory or archive path scan.
    pub fn startAsyncPathScan(self: *AppState, path: []const u8, is_dir: bool) !void {
        _ = is_dir;
        try self.handlePathSelection(path);
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
};

test "matchesQueryLower bounds check" {
    // Normal matches
    try std.testing.expect(matchesQueryLower("hello", "ell"));
    try std.testing.expect(matchesQueryLower("HELLO", "ell"));
    try std.testing.expect(!matchesQueryLower("hello", "world"));

    // Query longer than path (should not overflow/panic)
    try std.testing.expect(!matchesQueryLower("short", "longerquery"));
    try std.testing.expect(matchesQueryLower("short", ""));
}

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

test "ElementTag.fromInt" {
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0));
    try std.testing.expectEqual(ElementTag.drop_zone_box, ElementTag.fromInt(1337));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(9999));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0x7fffffffd000));
}

test "AppState.openPalette directory_navigator starting directory rules" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_open_dir_test";
    std.Io.Dir.createDirPath(cwd, io, tmp_dir ++ "/sub1") catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Rule 1: current_index is valid -> starting directory is dirname of current image
    const sample_path = tmp_dir ++ "/image1.jpg";
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = sample_path } });
    state.viewer.navigation.current_index = 0;

    try state.openPalette(.directory_navigator);
    try std.testing.expectEqual(PaletteMode.directory_navigator, state.viewer.ui.palette.mode);
    try std.testing.expectEqualStrings(tmp_dir, state.viewer.ui.palette.current_nav_dir.items);

    // Rule 2: current_index is null -> starting directory remembers last_nav_dir
    state.viewer.navigation.current_index = null;
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(tmp_dir, state.viewer.ui.palette.current_nav_dir.items);

    // Rule 3: current_index is null and last_nav_dir is empty -> starting directory falls back to "."
    state.viewer.ui.palette.last_nav_dir.clearRetainingCapacity();
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(".", state.viewer.ui.palette.current_nav_dir.items);

    // Rule 4: current_index out of bounds and last_nav_dir is empty -> starting directory falls back to "."
    state.viewer.navigation.current_index = 999;
    state.viewer.ui.palette.last_nav_dir.clearRetainingCapacity();
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(".", state.viewer.ui.palette.current_nav_dir.items);
}

test "AppState.openPalette directory_navigator steps up if 0 subdirectories" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_step_up_test";
    const sub_leaf = tmp_dir ++ "/child_leaf";
    std.Io.Dir.createDirPath(cwd, io, sub_leaf) catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Image in child_leaf (which has 0 subdirectories itself)
    const img_path = sub_leaf ++ "/photo.png";
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = img_path } });
    state.viewer.navigation.current_index = 0;

    // openPalette should see sub_leaf has 0 subdirectories, so it steps up to tmp_dir and pre-selects child_leaf
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(tmp_dir, state.viewer.ui.palette.current_nav_dir.items);

    // Verify child_leaf is selected
    var found_leaf_selected = false;
    if (state.viewer.ui.palette.selected_idx < state.viewer.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.viewer.ui.palette.dir_items.items[state.viewer.ui.palette.selected_idx].getName(), "child_leaf")) {
            found_leaf_selected = true;
        }
    }
    try std.testing.expect(found_leaf_selected);
}

test "AppState.openPalette steps up from top-level relative leaf dir without slashes to dot" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const top_leaf = "tmp_top_level_leaf_test";
    std.Io.Dir.createDirPath(cwd, io, top_leaf) catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, top_leaf) catch {};
    }

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const img_path = top_leaf ++ "/photo.png";
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = img_path } });
    state.viewer.navigation.current_index = 0;

    try state.openPalette(.directory_navigator);
    // Should step up to "." because top_leaf has 0 subdirectories
    try std.testing.expectEqualStrings(".", state.viewer.ui.palette.current_nav_dir.items);

    // Verify top_leaf is pre-selected in "."
    var found_leaf_selected = false;
    if (state.viewer.ui.palette.selected_idx < state.viewer.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.viewer.ui.palette.dir_items.items[state.viewer.ui.palette.selected_idx].getName(), top_leaf)) {
            found_leaf_selected = true;
        }
    }
    try std.testing.expect(found_leaf_selected);
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

    state.viewer.ui.palette.mode = .actions;
    _ = try systems.sysProcessPaletteInput(.{ .state = &state, .frame_allocator = allocator, .input = input_inside });
    try std.testing.expect(state.viewer.ui.palette.mode == .actions);
}

test "AppState slideshow timer auto-advances slide" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "img1.jpg" } });
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "img2.jpg" } });
    state.viewer.navigation.current_index = 0;
    state.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 2.0 } };

    const frame_input_1s = types.FrameInput{
        .win_w = 100,
        .win_h = 100,
        .pix_w = 100,
        .pix_h = 100,
        .scale_x = 1,
        .scale_y = 1,
        .dpi_scale = 1,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 1000.0,
    };

    try systems.sysUpdateSlideshow(.{ .state = &state, .frame_allocator = allocator, .input = frame_input_1s, .delta_time_ms = 1000.0 });
    try std.testing.expectEqual(@as(usize, 0), state.viewer.navigation.current_index.?);

    // Pass another second (total 2000ms >= 2.0s interval) -> advances to index 1
    try systems.sysUpdateSlideshow(.{ .state = &state, .frame_allocator = allocator, .input = frame_input_1s, .delta_time_ms = 1000.0 });
    try std.testing.expectEqual(@as(usize, 1), state.viewer.navigation.current_index.?);
}

test "prepareCacheTextures guards thumbnail eviction during active thumb_crossfade" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "img1.jpg" } });
    state.viewer.navigation.current_index = 0;

    // Simulate entry with loaded thumbnail and loaded GPU texture
    try state.cache.appendWithKey(allocator, .{ .index = 0, .generation = 0 }, .{
        .status = .{ .loaded_gpu = .{
            .gpu_texture = .{ .ptr = @ptrFromInt(0x1234) },
            .w = 800,
            .h = 600,
            .size_bytes = 800 * 600 * 4,
            .mime_type = "image/jpeg",
            .read_time_ms = 1,
            .decode_time_ms = 1,
            .conversion_time_ms = 1,
            .upload_time_ms = 1,
            .memory_size_bytes = 800 * 600 * 4,
            .num_mip_levels = 1,
            .mipmap_time_ms = 1,
            .was_fallback = false,
            .fallback_time_ms = 0,
            .cbz_decompress_time_ms = 0,
            .compressed_size_bytes = 0,
        } },
        .thumbnail = .{ .loaded = .{
            .texture = .{ .ptr = @ptrFromInt(0x5678) },
            .info = .{ .w = 160, .h = 120, .upload_time_ms = 1 },
        } },
    });

    // Case 1: thumb_crossfade is active -> prepareCacheTextures MUST NOT evict thumbnail
    state.viewer.animations.start(.thumb_crossfade, 1.0, 120.0, .ease_out_quad);
    state.prepareCacheTextures();
    var entry = state.cache.get(state.cache.activeKey(0)).?;
    try std.testing.expect(entry.thumbnail == .loaded);

    // Case 2: thumb_crossfade settles -> prepareCacheTextures evicts thumbnail
    state.viewer.animations.settle(.thumb_crossfade);
    state.prepareCacheTextures();
    entry = state.cache.get(state.cache.activeKey(0)).?;
    try std.testing.expect(entry.thumbnail == .unloaded);
}
