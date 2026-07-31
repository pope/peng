const std = @import("std");
const fuzzig = @import("fuzzig");
const sdl = @import("sdl");
const clay = @import("zclay");
const state_pkg = @import("state");
const types = state_pkg.types;
const FrameInput = types.FrameInput;
const app_input = @import("input.zig");
const image = @import("image.zig");
const fs = @import("fs.zig");
const events = @import("events.zig");
const pipeline = @import("pipeline.zig");
const ipc = @import("ipc.zig");
const exif = @import("exif.zig");
const screenshot = @import("screenshot.zig");
const systems = @import("systems.zig");
const workers_mod = @import("workers/root.zig");

const view_transform = state_pkg.view_transform;

const uploadSurfaceToGpu = image.uploadSurfaceToGpu;
const CacheStatus = state_pkg.CacheStatus;
const CacheEntry = state_pkg.CacheEntry;
const CacheSlotMap = image.CacheSlotMap;
const TextureHandle = image.TextureHandle;
const DecodeArgs = workers_mod.DecodeArgs;

const intents = @import("intents");
const ScaleMode = intents.ScaleMode;
const TextureScaleMode = intents.TextureScaleMode;
const PaletteMode = intents.PaletteMode;
const AppIntent = intents.AppIntent;

const navigation = @import("navigation.zig");
pub const NavigationState = navigation.NavigationState;
const SlideshowMode = state_pkg.SlideshowMode;

const ui_state = @import("ui_state.zig");
pub const UiState = ui_state.UiState;
const OverlayState = state_pkg.OverlayState;
pub const OverlayFlags = ui_state.OverlayFlags;
const UiRenderMetrics = state_pkg.UiRenderMetrics;
pub const ScreenshotMode = ui_state.ScreenshotMode;
pub const RollingStats = ui_state.RollingStats;

pub const ElementTag = enum(usize) {
    none = 0,
    drop_zone_box = 1337,

    pub fn fromInt(val: usize) ElementTag {
        inline for (std.meta.tags(ElementTag)) |tag| {
            if (val == @intFromEnum(tag)) {
                return tag;
            }
        }
        return .none;
    }
};

const palette_module = @import("palette.zig");
const PaletteState = state_pkg.PaletteState;

pub const DragState = union(enum) {
    none,
    viewport: struct {
        last_x: f32,
        last_y: f32,
    },
    info: struct {
        start_x: f32,
        start_y: f32,
    },
    stats: struct {
        start_x: f32,
        start_y: f32,
    },
};

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

pub fn matchesQueryLower(path: []const u8, query_lower: []const u8) bool {
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

/// Encapsulates resources and state specific to an active windowed GUI session.
///
/// Fields:
/// - `handle`: The underlying SDL window handle for OS window operations.
/// - `pixel_format`: Swapchain GPU texture format associated with the window.
/// - `cached_title`: Heap-allocated buffer of the active window title to prevent redundant SDL title updates.
/// - `is_fullscreen`: Boolean tracking whether the window is currently expanded to fullscreen.
/// - `claimed`: True if the window has claimed focus and rendering output (false during headless tests).
const ActiveWindow = state_pkg.ActiveWindow;
const DisplayState = state_pkg.DisplayState;

/// Cohesive GPU context and render resources initialized for GPU-accelerated rendering.
/// Main Application State Architecture
///
/// Single-Threaded ViewerState Model:
/// - `ViewerState` lives 100% on the main thread and contains ZERO mutexes.
/// - Background workers (decode, scan, IPC) run as isolated tasks that receive plain
///   value copies of parameters (paths, generation counters) and touch zero shared state.
/// - Workers communicate exclusively by pushing event messages into `event_queue` (MpscQueue).
/// - The main thread consumes background events during frame updates and updates `ViewerState` safely.
pub const ViewerState = struct {
    gpu_device: ?sdl.gpu.Device = null,
    unpack_compute_pipeline: ?sdl.gpu.ComputePipeline = null,

    // Domain Sub-States
    viewport: types.ViewportParams = .{},
    navigation: NavigationState,
    ui: UiState,

    cache: CacheSlotMap,
    current_image_cache_hit: bool = false,
    allocator: std.mem.Allocator,
    io: std.Io,
    workers: workers_mod.WorkerManager = .{},
    /// Monotonically increasing cache epoch counter. Incremented on directory/file resets
    /// (resetNavigation) so main-thread event handlers (e.g. handleImageDecodedEvent)
    /// can verify incoming background events match the active image list epoch before modifying CacheEntry slots.
    generation: usize = 0,

    // Tagged Union State Machines
    display: DisplayState = .headless,
    drag_state: DragState = .none,

    running: bool = true,
    dirty: bool = true,
    rotation_map: std.StringHashMap(f32),
    event_batch: std.ArrayList(events.BackgroundEvent) = .empty,
    pending_ipc_commands: std.ArrayList(*ipc.IpcCommandData) = .empty,
    pending_intents: std.ArrayList(AppIntent) = .empty,

    pub fn pushIntent(self: *ViewerState, intent: AppIntent) !void {
        try self.pending_intents.append(self.allocator, intent);
    }

    pub fn clearIntents(self: *ViewerState) void {
        self.pending_intents.clearRetainingCapacity();
    }

    pub inline fn isFullscreen(self: *const ViewerState) bool {
        return self.display.isFullscreen();
    }
    pub inline fn isSlideshowActive(self: *const ViewerState) bool {
        return self.navigation.isSlideshowActive();
    }
    pub inline fn isBusy(self: *const ViewerState) bool {
        return self.navigation.is_loading_files.load(.acquire) or self.workers.isBusy() or self.isSlideshowActive();
    }

    pub fn readJpegExifOrientation(self: *const ViewerState, path: []const u8) ?f32 {
        return exif.readJpegExifOrientation(self.io, path);
    }

    pub fn setDebugShowThumb(self: *ViewerState, enable: bool) !void {
        self.ui.overlays.debug_show_thumb = enable;
        if (!enable) return;

        const entry = self.getCurrentEntry() orelse return;
        if (entry.thumb_gpu_texture != null) return;

        const idx = self.navigation.current_index orelse return;
        if (idx >= self.navigation.image_list.items.len) return;

        const path = self.navigation.image_list.items[idx];
        var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), self.io, path, .{}) catch return;
        defer file.close(self.io);

        var header_buf: [65536]u8 = undefined;
        var slices = [_][]u8{&header_buf};
        const n = file.readPositional(self.io, &slices, 0) catch return;
        if (n == 0) return;

        const full_dims = exif.readJpegDimensions(header_buf[0..n]);
        const thumb_bytes = exif.extractJpegThumbnail(header_buf[0..n]) orelse return;
        const thumb_surf = sdl.Surface.loadConstMemOpt(thumb_bytes) orelse return;
        defer thumb_surf.destroy();

        const dev = self.gpu_device orelse return;
        const upload_res = uploadSurfaceToGpu(dev, thumb_surf, self.unpack_compute_pipeline) orelse return;

        if (self.cache.getWithGeneration(entry.index, entry.generation)) |e| {
            if (e.thumb_gpu_texture) |old_t| {
                dev.releaseTexture(old_t);
            }
            e.thumb_gpu_texture = upload_res.gpu_texture;
            e.thumb_w = upload_res.w;
            e.thumb_h = upload_res.h;
            if (full_dims) |dims| {
                e.full_w = dims.w;
                e.full_h = dims.h;
            }
            e.has_thumb = true;
            e.thumb_upload_time_ms = upload_res.upload_time_ms;
        } else {
            dev.releaseTexture(upload_res.gpu_texture);
        }
    }

    pub fn deinit(self: *ViewerState) void {
        self.workers.drainAndQuiesce(self.io);

        const dev_opt = self.gpu_device;
        self.cache.clear(dev_opt);

        if (self.gpu_device) |dev| {
            switch (self.display) {
                .headless => {},
                .windowed => |*w| {
                    if (w.claimed) {
                        w.handle.releaseFromGpu(dev);
                    }
                    w.deinit(self.allocator);
                },
            }

            self.cache.deinit(self.allocator, dev);
        } else {
            switch (self.display) {
                .headless => {},
                .windowed => |*w| w.deinit(self.allocator),
            }
            self.cache.deinit(self.allocator, null);
        }

        for (self.pending_ipc_commands.items) |cmd_data| {
            cmd_data.client_stream.close(self.io);
            self.allocator.free(cmd_data.command);
            self.allocator.destroy(cmd_data);
        }
        self.navigation.deinit(self.allocator);
        self.ui.deinit(self.io, self.allocator);
        self.pending_ipc_commands.deinit(self.allocator);
        self.pending_intents.deinit(self.allocator);
        self.event_batch.deinit(self.allocator);
        self.workers.event_queue.deinit(self.allocator, self.io);
        self.clearRotationMap();
        self.rotation_map.deinit();
    }

    pub fn putRotation(self: *ViewerState, path: []const u8, angle: f32) !void {
        const gop = try self.rotation_map.getOrPut(path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, path);
        }
        gop.value_ptr.* = angle;
    }

    pub fn clearRotationMap(self: *ViewerState) void {
        var it = self.rotation_map.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.rotation_map.clearRetainingCapacity();
    }

    pub fn resetZoomPan(self: *ViewerState) void {
        self.viewport.reset();
    }

    pub fn getBaseScale(self: *ViewerState) f32 {
        const entry = self.getCurrentEntry() orelse return 1.0;
        const raw_w: f32 = switch (entry.status) {
            .loaded_gpu => |gpu| gpu.w,
            .loaded_cpu => |cpu| cpu.w,
            else => if (entry.full_w > 0) entry.full_w else entry.thumb_w,
        };
        const raw_h: f32 = switch (entry.status) {
            .loaded_gpu => |gpu| gpu.h,
            .loaded_cpu => |cpu| cpu.h,
            else => if (entry.full_h > 0) entry.full_h else entry.thumb_h,
        };
        if (raw_w <= 0.0 or raw_h <= 0.0) return 1.0;

        var pix_w: i32 = 1024;
        var pix_h: i32 = 768;
        var win_w: f32 = 1024.0;
        var win_h: f32 = 768.0;

        switch (self.display) {
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

        const title_bar_h: f32 = if (self.isFullscreen()) 0.0 else 60.0;

        var available_width = win_w;
        if (clay.isDebugModeEnabled()) {
            available_width = @max(available_width - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0);
        }
        const view_w = @max(available_width, 1.0);
        const view_h = @max(win_h - title_bar_h, 1.0);

        const dims = view_transform.computeViewDims(raw_w, raw_h, self.viewport.rotation_angle, view_w, view_h, self.viewport.fit_mode);
        return dims.base_scale;
    }

    pub fn isPointerInDebugPanel(self: *const ViewerState, input: FrameInput) bool {
        _ = self;
        return input.isPointerInDebugPanel();
    }

    pub fn clampZoomFactor(self: *ViewerState, new_factor: f32) types.ZoomFactor {
        const base_scale = self.getBaseScale();
        return view_transform.clampZoomFactor(base_scale, new_factor);
    }

    pub fn getTextureByHandle(self: *ViewerState, handle: TextureHandle) ?sdl.gpu.Texture {
        self.lockCache();
        defer self.unlockCache();
        return self.cache.getTexture(handle);
    }

    pub fn applyTextureScaleMode(self: *ViewerState) void {
        self.dirty = true;
    }

    pub fn rebuildPaletteMatches(self: *ViewerState) !void {
        try self.ui.palette.rebuildFileMatches(self.navigation.image_list.items);
    }

    pub fn rebuildActionMatches(self: *ViewerState) !void {
        try self.ui.palette.rebuildActionMatches();
    }

    pub fn getCurrentEntry(self: *ViewerState) ?CacheEntry {
        const idx = self.navigation.current_index orelse return null;
        if (self.cache.get(idx)) |entry| {
            return entry.*;
        }
        return null;
    }

    pub fn openPalette(self: *ViewerState, active_type: PaletteMode) !void {
        self.ui.palette.reset();
        self.ui.palette.mode = active_type;
        self.ui.palette.selected_idx = switch (active_type) {
            .files => self.navigation.current_index orelse 0,
            else => 0,
        };
        self.ui.palette.selection_dirty = true;

        const max_capacity = switch (active_type) {
            .files => self.navigation.image_list.items.len,
            .actions => types.palette_action_items.len,
            else => 0,
        };
        if (max_capacity > 0) {
            try self.ui.palette.matches.ensureTotalCapacity(self.allocator, max_capacity);
        }

        switch (active_type) {
            .files => try self.rebuildPaletteMatches(),
            .actions => try self.rebuildActionMatches(),
            .directory_navigator => {
                const start_dir = blk: {
                    if (self.navigation.current_index) |idx| {
                        if (idx < self.navigation.image_list.items.len) {
                            break :blk std.fs.path.dirname(self.navigation.image_list.items[idx]) orelse ".";
                        }
                    }
                    if (self.navigation.last_scanned_dir.items.len > 0) {
                        break :blk self.navigation.last_scanned_dir.items;
                    }
                    if (self.ui.palette.last_nav_dir.items.len > 0) {
                        break :blk self.ui.palette.last_nav_dir.items;
                    }
                    break :blk ".";
                };
                try palette_module.loadDirectoryEntries(&self.ui.palette, self.io, start_dir);
                while (self.ui.palette.dir_items.items.len == 0) {
                    const curr = self.ui.palette.current_nav_dir.items;
                    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                    if (fs.getParentDirBuf(curr, &parent_buf)) |parent_dir| {
                        if (!std.mem.eql(u8, parent_dir, curr)) {
                            try palette_module.loadDirectoryEntries(&self.ui.palette, self.io, parent_dir);
                            continue;
                        }
                    }
                    break;
                }
            },
            else => {},
        }

        startTextInput(self.display);
    }

    pub fn prepareCacheTextures(self: *ViewerState) void {
        var upload_target: ?struct {
            index: usize,
            generation: usize,
            cpu: @TypeOf(@as(CacheStatus, undefined).loaded_cpu),
        } = null;

        for (self.cache.entries.items) |*entry| {
            if (entry.status == .loaded_gpu and !self.ui.overlays.debug_show_thumb) {
                if (entry.thumb_gpu_texture) |thumb_tex| {
                    if (self.gpu_device) |gpu_dev| {
                        gpu_dev.releaseTexture(thumb_tex);
                    }
                    entry.thumb_gpu_texture = null;
                }
            }
            switch (entry.status) {
                .loaded_cpu => |cpu| {
                    entry.status = .uploading;
                    upload_target = .{
                        .index = entry.index,
                        .generation = entry.generation,
                        .cpu = cpu,
                    };
                    break;
                },
                else => {},
            }
        }

        if (upload_target) |target| {
            defer target.cpu.surface.destroy();
            if (self.gpu_device) |gpu_dev| {
                if (uploadSurfaceToGpu(gpu_dev, target.cpu.surface, self.unpack_compute_pipeline)) |res| {
                    const loaded_gpu_status = CacheStatus{
                        .loaded_gpu = .{
                            .gpu_texture = res.gpu_texture,
                            .w = target.cpu.w,
                            .h = target.cpu.h,
                            .size_bytes = target.cpu.size_bytes,
                            .mime_type = target.cpu.mime_type,
                            .decode_time_ms = target.cpu.decode_time_ms,
                            .conversion_time_ms = target.cpu.conversion_time_ms,
                            .upload_time_ms = res.upload_time_ms,
                            .memory_size_bytes = res.memory_size_bytes,
                        },
                    };
                    const updated = self.cache.updateStatus(target.index, target.generation, loaded_gpu_status);

                    if (!updated) {
                        gpu_dev.releaseTexture(res.gpu_texture);
                    }
                } else {
                    _ = self.cache.updateStatus(target.index, target.generation, .failed);
                }
            }
        }
    }

    pub fn clearCache(self: *ViewerState) void {
        const dev_opt = self.gpu_device;
        self.cache.clear(dev_opt);
    }

    pub fn checkIdlePreload(self: *ViewerState) void {
        if (self.navigation.image_list.items.len <= 1) return;
        const now = sdl.timer.getTicks();
        if (now - self.navigation.last_nav_time_ms >= 150) {
            const entry_count = self.cache.entries.items.len;
            if (entry_count <= 1) {
                self.updateCache() catch |err| std.log.warn("Idle preload updateCache failed: {}", .{err});
            }
        }
    }

    pub fn updateCurrentRotation(self: *ViewerState) void {
        const path_opt = blk: {
            const len = self.navigation.image_list.items.len;
            const current_idx = self.navigation.current_index orelse break :blk null;
            if (current_idx >= len) break :blk null;
            break :blk self.navigation.image_list.items[current_idx];
        };

        const path = path_opt orelse {
            self.viewport.rotation_angle = 0.0;
            return;
        };

        if (self.rotation_map.get(path)) |user_rot| {
            self.viewport.rotation_angle = user_rot;
        } else if (self.getCurrentEntry()) |entry| {
            self.viewport.rotation_angle = entry.exif_orientation;
        } else {
            self.viewport.rotation_angle = 0.0;
        }
    }

    pub fn handleExifThumbnailEvent(self: *ViewerState, thumb_data: events.ThumbDecodedPayload) void {
        const surf = thumb_data.surface orelse return;
        const current_gen = self.generation;
        if (self.gpu_device) |gpu_dev| {
            if (uploadSurfaceToGpu(gpu_dev, surf, self.unpack_compute_pipeline)) |upload_res| {
                if (self.cache.getWithGeneration(thumb_data.index, current_gen)) |entry| {
                    entry.thumb_gpu_texture = upload_res.gpu_texture;
                    entry.thumb_w = upload_res.w;
                    entry.thumb_h = upload_res.h;
                    entry.exif_orientation = thumb_data.exif_orientation;
                    if (thumb_data.full_w > 0 and thumb_data.full_h > 0) {
                        entry.full_w = thumb_data.full_w;
                        entry.full_h = thumb_data.full_h;
                    }
                    entry.has_thumb = true;
                    entry.thumb_upload_time_ms = upload_res.upload_time_ms;
                } else {
                    gpu_dev.releaseTexture(upload_res.gpu_texture);
                }
                self.updateCurrentRotation();
            }
        }
    }

    pub fn handleImageDecodedEvent(self: *ViewerState, decoded_data: *events.ImageDecodedPayload) void {
        const surf = decoded_data.surface orelse return;
        const current_gen = self.generation;
        if (self.gpu_device) |gpu_dev| {
            if (uploadSurfaceToGpu(gpu_dev, surf, self.unpack_compute_pipeline)) |full_res| {
                if (self.cache.getWithGeneration(decoded_data.index, current_gen)) |entry| {
                    switch (entry.status) {
                        .loaded_cpu => |cpu| cpu.surface.destroy(),
                        .loaded_gpu => |gpu| gpu_dev.releaseTexture(gpu.gpu_texture),
                        else => {},
                    }
                    entry.exif_orientation = decoded_data.exif_orientation;
                    entry.status = .{
                        .loaded_gpu = .{
                            .gpu_texture = full_res.gpu_texture,
                            .w = decoded_data.w,
                            .h = decoded_data.h,
                            .size_bytes = decoded_data.size_bytes,
                            .mime_type = decoded_data.mime_type,
                            .decode_time_ms = decoded_data.decode_time_ms,
                            .conversion_time_ms = full_res.conversion_time_ms,
                            .upload_time_ms = full_res.upload_time_ms,
                            .memory_size_bytes = full_res.memory_size_bytes,
                            .num_mip_levels = full_res.num_mip_levels,
                            .mipmap_time_ms = full_res.mipmap_time_ms,
                            .was_fallback = full_res.was_fallback,
                            .fallback_time_ms = full_res.fallback_time_ms,
                            .has_thumb = entry.has_thumb,
                            .thumb_w = entry.thumb_w,
                            .thumb_h = entry.thumb_h,
                            .thumb_upload_time_ms = entry.thumb_upload_time_ms,
                        },
                    };
                    self.cache.enforceVramBudget(gpu_dev, self.navigation.current_index, CacheSlotMap.DEFAULT_MAX_VRAM_BYTES);
                } else {
                    gpu_dev.releaseTexture(full_res.gpu_texture);
                }
                self.updateCurrentRotation();
            }
        } else {
            if (self.cache.getWithGeneration(decoded_data.index, current_gen)) |entry| {
                entry.exif_orientation = decoded_data.exif_orientation;
                entry.status = .{
                    .loaded_cpu = .{
                        .surface = decoded_data.surface.?,
                        .w = decoded_data.w,
                        .h = decoded_data.h,
                        .size_bytes = decoded_data.size_bytes,
                        .mime_type = decoded_data.mime_type,
                        .decode_time_ms = decoded_data.decode_time_ms,
                        .conversion_time_ms = decoded_data.conversion_time_ms,
                        .has_thumb = entry.has_thumb,
                        .thumb_w = entry.thumb_w,
                        .thumb_h = entry.thumb_h,
                        .thumb_upload_time_ms = entry.thumb_upload_time_ms,
                    },
                };
                decoded_data.surface = null; // Transfer ownership to CacheEntry
            }
            self.updateCurrentRotation();
        }
    }

    pub fn handleDirScannedEvent(self: *ViewerState, scanned_data: events.PathDiscoveredPayload) void {
        const dup = self.navigation.directory_arena.allocator().dupe(u8, scanned_data.path) catch |err| {
            std.log.err("Failed to duplicate path '{s}' in directory arena: {}", .{ scanned_data.path, err });
            return;
        };
        self.navigation.image_list.append(self.allocator, dup) catch |err| std.log.err("Failed to append discovered path to image_list: {}", .{err});
        if (self.navigation.current_index == null and self.navigation.image_list.items.len > 0) {
            self.navigation.current_index = 0;
        }
    }

    pub fn handleDirectoryScanResultEvent(self: *ViewerState, result_data: events.DirectoryScanResultPayload) void {
        if (result_data.is_dir) {
            for (result_data.paths) |item| {
                const dup = self.navigation.directory_arena.allocator().dupe(u8, item) catch |err| {
                    std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                    continue;
                };
                self.navigation.image_list.append(self.allocator, dup) catch |err| {
                    std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
                };
            }
            if (self.navigation.current_index == null and self.navigation.image_list.items.len > 0) {
                self.navigation.current_index = 0;
            }
        } else {
            var target_idx_in_dir: ?usize = null;
            for (result_data.paths, 0..) |item, i| {
                if (std.mem.eql(u8, item, result_data.target_path)) {
                    target_idx_in_dir = i;
                    break;
                }
            }

            _ = self.navigation.directory_arena.reset(.retain_capacity);
            self.navigation.image_list.clearRetainingCapacity();
            for (result_data.paths, 0..) |item, i| {
                const dup = self.navigation.directory_arena.allocator().dupe(u8, item) catch |err| {
                    std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                    continue;
                };
                self.navigation.image_list.append(self.allocator, dup) catch |err| {
                    std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
                };
                if (target_idx_in_dir == null and std.mem.eql(u8, item, result_data.target_path)) {
                    target_idx_in_dir = i;
                }
            }

            if (target_idx_in_dir) |target_i| {
                if (target_i < self.navigation.image_list.items.len) {
                    self.navigation.current_index = target_i;
                }
            } else {
                self.navigation.current_index = 0;
            }
        }

        self.updateCache() catch |err| std.log.err("Failed to update cache after directory scan result: {}", .{err});
    }

    pub fn processBackgroundEvents(self: *ViewerState) bool {
        self.event_batch.clearRetainingCapacity();
        self.workers.event_queue.drain(self.allocator, self.io, &self.event_batch) catch return false;
        if (self.event_batch.items.len == 0) return false;
        self.dirty = true;
        const current_gen = self.generation;

        for (self.event_batch.items) |*evt| {
            defer evt.deinit(self.allocator);

            switch (evt.*) {
                .exif_orientation_parsed => |e| {
                    if (self.cache.getWithGeneration(e.index, current_gen)) |entry| {
                        entry.exif_orientation = e.orientation;
                    }
                    self.updateCurrentRotation();
                },
                .thumb_decoded => |t| handleExifThumbnailEvent(self, t),
                .image_decoded => |*d| handleImageDecodedEvent(self, d),
                .decode_failed => |f| {
                    _ = self.cache.updateStatus(f.index, current_gen, .failed);
                },
                .path_discovered => |p| handleDirScannedEvent(self, p),
                .directory_scan_result => |res| handleDirectoryScanResultEvent(self, res),
                .directory_scan_complete => {},
                .ipc_command => |cmd_data| {
                    self.pending_ipc_commands.append(self.allocator, cmd_data) catch |err| {
                        std.log.err("Failed to append IPC command to pending list: {}", .{err});
                    };
                },
            }
        }
        return true;
    }

    pub fn updateCache(self: *ViewerState) !void {
        self.resetZoomPan();
        self.updateCurrentRotation();

        const len = self.navigation.image_list.items.len;

        if (len == 0) return;

        const idx = self.navigation.current_index orelse return;
        const gen = self.generation;

        const now = sdl.timer.getTicks();
        const is_rapid_scrolling = (now - self.navigation.last_nav_time_ms < 150);
        self.navigation.last_nav_time_ms = now;

        // 1. Gather desired indices
        var desired_count: usize = 0;
        var desired: [5]usize = undefined;
        desired[0] = idx;
        desired_count = 1;

        if (!is_rapid_scrolling) {
            for ([_]usize{
                (idx + 1) % len,
                (idx + 2) % len,
                (idx + len - 1) % len,
                if (len >= 2) (idx + len - 2) % len else idx,
            }) |d| {
                var unique = true;
                for (desired[0..desired_count]) |existing| {
                    if (existing == d) {
                        unique = false;
                        break;
                    }
                }
                if (unique) {
                    desired[desired_count] = d;
                    desired_count += 1;
                }
            }
        }

        var to_spawn_count: usize = 0;
        var to_spawn_indices: [5]usize = undefined;
        var hit = false;

        const dev_opt = self.gpu_device;

        // 2. Evict cache entries that are no longer wanted
        var i: usize = 0;
        while (i < self.cache.entries.items.len) {
            const entry = &self.cache.entries.items[i];
            var wanted = false;
            for (desired[0..desired_count]) |d| {
                if (entry.index == d) {
                    wanted = true;
                    break;
                }
            }
            if (!wanted) {
                // Evict
                self.cache.removeAndDeinit(i, dev_opt);
            } else {
                i += 1;
            }
        }

        // 3. Mark wanted entries that are not in the cache yet as .decoding
        for (desired[0..desired_count]) |d| {
            var needs_thread = false;
            if (self.cache.get(d)) |entry| {
                if (d == idx and (entry.status == .loaded_cpu or entry.status == .loaded_gpu)) {
                    hit = true;
                }
                switch (entry.status) {
                    .decoding => |dec| {
                        if (!dec.has_thread) {
                            needs_thread = true;
                        }
                    },
                    else => {},
                }
            } else {
                const new_entry = CacheEntry{
                    .index = d,
                    .generation = gen,
                    .status = .{ .decoding = .{ .has_thread = false } },
                    .full_w = 0.0,
                    .full_h = 0.0,
                };
                try self.cache.append(self.allocator, new_entry);
                needs_thread = true;
            }
            if (needs_thread) {
                to_spawn_indices[to_spawn_count] = d;
                to_spawn_count += 1;
            }
        }
        self.current_image_cache_hit = hit;

        // 4. Batch-fetch file paths
        var to_spawn_paths: [5]?[:0]const u8 = undefined;
        for (to_spawn_indices[0..to_spawn_count], 0..) |d, s_idx| {
            if (d < self.navigation.image_list.items.len) {
                to_spawn_paths[s_idx] = self.allocator.dupeZ(u8, self.navigation.image_list.items[d]) catch |err| blk: {
                    std.log.err("updateCache: dupeZ failed for image index {d}: {}", .{ d, err });
                    break :blk null;
                };
            } else {
                to_spawn_paths[s_idx] = null;
            }
        }

        // 5. Spawn worker threads
        for (to_spawn_indices[0..to_spawn_count], 0..) |d, s_idx| {
            const path_opt = to_spawn_paths[s_idx];
            if (path_opt == null or !self.workers.canSpawnDecode()) {
                if (path_opt) |p| self.allocator.free(p);
                if (d != idx) {
                    var k: usize = 0;
                    while (k < self.cache.entries.items.len) : (k += 1) {
                        if (self.cache.entries.items[k].index == d) {
                            self.cache.removeAndDeinit(k, dev_opt);
                            break;
                        }
                    }
                }
                continue;
            }

            const dup_path = path_opt.?;

            const args = self.allocator.create(DecodeArgs) catch |err| {
                self.allocator.free(dup_path);
                for (to_spawn_paths[s_idx + 1 .. to_spawn_count]) |rem_path_opt| {
                    if (rem_path_opt) |rp| self.allocator.free(rp);
                }
                var k: usize = 0;
                while (k < self.cache.entries.items.len) : (k += 1) {
                    if (self.cache.entries.items[k].index == d) {
                        self.cache.removeAndDeinit(k, dev_opt);
                        break;
                    }
                }
                return err;
            };

            if (self.cache.get(d)) |entry| {
                switch (entry.status) {
                    .decoding => |*dec| dec.has_thread = true,
                    else => {},
                }
            }

            args.* = DecodeArgs{
                .workers = &self.workers,
                .allocator = self.allocator,
                .io = self.io,
                .index = d,
                .path = dup_path,
                .has_gpu_device = self.gpu_device != null,
                .pixel_format = self.display.getPixelFormat(),
            };

            workers_mod.spawnDecode(args) catch |err| {
                std.log.err("workers.spawnDecode failed: {}", .{err});
                self.allocator.free(dup_path);
                self.allocator.destroy(args);
            };
        }
    }

    pub fn next(self: *ViewerState) !void {
        if (self.navigation.nextIndex() != null) {
            try self.updateCache();
        }
    }

    pub fn prev(self: *ViewerState) !void {
        if (self.navigation.prevIndex() != null) {
            try self.updateCache();
        }
    }

    pub fn handlePathSelection(self: *ViewerState, path: []const u8) !void {
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

        self.navigation.last_scanned_dir.clearRetainingCapacity();
        try self.navigation.last_scanned_dir.appendSlice(self.allocator, dir_target);

        // Clear existing cache and rotation map before resetting directory_arena
        self.generation += 1;
        self.clearCache();
        self.clearRotationMap();
        self.navigation.image_list.clearRetainingCapacity();
        _ = self.navigation.directory_arena.reset(.retain_capacity);
        self.navigation.current_index = null;

        if (has_stat) {
            if (stat.kind == .directory) {
                try fs.startAsyncPathScan(self, path, true);
            } else {
                const dup = try self.navigation.directory_arena.allocator().dupe(u8, path);
                try self.navigation.image_list.append(self.allocator, dup);
                self.navigation.current_index = 0;

                try self.updateCache();

                try fs.startAsyncPathScan(self, path, false);
            }
        }
        try self.rebuildPaletteMatches();
    }

    pub fn startAsyncPathScan(self: *ViewerState, path: []const u8, is_dir: bool) !void {
        _ = is_dir;
        try self.handlePathSelection(path);
    }

    pub fn processPaletteInput(self: *ViewerState, input: FrameInput) !bool {
        if (input.text_input) |text| {
            if (self.ui.palette.mode != .inactive) {
                try self.ui.palette.query.appendSlice(self.allocator, text);
                self.ui.palette.selected_idx = 0;
                self.ui.palette.selection_dirty = true;
                switch (self.ui.palette.mode) {
                    .files => try self.rebuildPaletteMatches(),
                    .actions => try self.rebuildActionMatches(),
                    .directory_navigator => try self.ui.palette.rebuildDirectoryMatches(),
                    else => {},
                }
            }
        }

        var palette_closed_this_frame = false;
        if (input.mouse_left_clicked and self.ui.palette.mode != .inactive) {
            const is_in_debug_panel = self.isPointerInDebugPanel(input);
            const element_id = switch (self.ui.palette.mode) {
                .files => "CommandPalette",
                .actions => "ActionPalette",
                .set_brightness => "BrightnessPalette",
                .set_contrast => "ContrastPalette",
                .go_to_image => "GoToImagePalette",
                .directory_navigator => "DirectoryNavigatorPalette",
                .set_slideshow_interval => "SlideshowPalette",
                .inactive => unreachable,
            };
            if (!clay.pointerOver(clay.getElementId(element_id)) and !is_in_debug_panel) {
                self.ui.palette.mode = .inactive;
                stopTextInput(self.display);
                palette_closed_this_frame = true;
            }
        }
        return palette_closed_this_frame;
    }

    pub fn update(self: *ViewerState, input: FrameInput) !void {
        self.updateCurrentRotation();

        // 0. Enqueued Intents pass
        try systems.sysExecuteIntents(self);

        // 1. Slideshow timer update pass
        try systems.sysUpdateSlideshow(self, input.delta_time_ms);

        // 2. Text input & palette dismissal updates
        const palette_closed_this_frame = try self.processPaletteInput(input);

        // 3. Drop file/directory updates
        if (input.dropped_path) |path| {
            try self.handlePathSelection(path);
        }

        // 4. Viewport Mouse Drag & Scroll Zoom pass
        systems.sysUpdateViewport(self, input, palette_closed_this_frame);

        // 5. Keyboard updates
        for (input.keys_pressed.items) |key| {
            try app_input.handleKeyDown(self, key, input.key_modifiers, input.scale_x, input.scale_y);
        }
    }

    pub const IpcHandlerFn = *const fn (state: *ViewerState, command: []const u8, stream: std.Io.net.Stream) anyerror!void;

    pub fn processIpcCommands(self: *ViewerState, handler_fn: ?IpcHandlerFn) void {
        for (self.pending_ipc_commands.items) |cmd_data| {
            var it = std.mem.tokenizeAny(u8, cmd_data.command, " \t\r\n");
            const cmd = it.next() orelse "";
            if (std.mem.eql(u8, cmd, "screenshot")) {
                if (it.next()) |filepath| {
                    if (filepath.len > 512) {
                        var write_buf: [128]u8 = undefined;
                        var writer = cmd_data.client_stream.writer(self.io, &write_buf);
                        writer.interface.writeAll("ERR PathTooLong\n") catch |err| std.log.warn("IPC screenshot response failed: {}", .{err});
                        writer.interface.flush() catch |err| std.log.warn("IPC flush failed: {}", .{err});
                        cmd_data.client_stream.close(self.io);
                    } else if (self.ui.screenshot_mode == .capturing) {
                        var write_buf: [128]u8 = undefined;
                        var writer = cmd_data.client_stream.writer(self.io, &write_buf);
                        writer.interface.writeAll("ERR Busy\n") catch |err| std.log.warn("IPC screenshot response failed: {}", .{err});
                        writer.interface.flush() catch |err| std.log.warn("IPC flush failed: {}", .{err});
                        cmd_data.client_stream.close(self.io);
                    } else {
                        const dup_path = self.allocator.dupeZ(u8, filepath) catch {
                            var write_buf: [128]u8 = undefined;
                            var writer = cmd_data.client_stream.writer(self.io, &write_buf);
                            writer.interface.writeAll("ERR OutOfMemory\n") catch |err| std.log.warn("IPC screenshot response failed: {}", .{err});
                            writer.interface.flush() catch |err| std.log.warn("IPC flush failed: {}", .{err});
                            cmd_data.client_stream.close(self.io);
                            self.allocator.free(cmd_data.command);
                            self.allocator.destroy(cmd_data);
                            continue;
                        };
                        self.ui.screenshot_mode = .{
                            .capturing = screenshot.ActiveScreenshot{
                                .path = dup_path,
                                .stream = cmd_data.client_stream,
                            },
                        };
                    }
                } else {
                    var write_buf: [128]u8 = undefined;
                    var writer = cmd_data.client_stream.writer(self.io, &write_buf);
                    writer.interface.writeAll("ERR MissingArgument\n") catch |err| std.log.warn("IPC screenshot response failed: {}", .{err});
                    writer.interface.flush() catch |err| std.log.warn("IPC flush failed: {}", .{err});
                    cmd_data.client_stream.close(self.io);
                }
            } else {
                if (handler_fn) |handler| {
                    handler(self, cmd_data.command, cmd_data.client_stream) catch |err| {
                        var response_buf: [128]u8 = undefined;
                        const response = std.fmt.bufPrint(&response_buf, "ERR {s}\n", .{@errorName(err)}) catch "ERR ExecutionFailed\n";
                        var write_buf: [128]u8 = undefined;
                        var writer = cmd_data.client_stream.writer(self.io, &write_buf);
                        writer.interface.writeAll(response) catch |err2| std.log.warn("IPC error response failed: {}", .{err2});
                        writer.interface.flush() catch |err2| std.log.warn("IPC flush failed: {}", .{err2});
                        cmd_data.client_stream.close(self.io);
                    };
                }
            }
            self.allocator.free(cmd_data.command);
            self.allocator.destroy(cmd_data);
        }
        self.pending_ipc_commands.clearRetainingCapacity();
    }

    pub fn handleScreenshotPostRender(self: *ViewerState, render_err: ?anyerror) void {
        switch (self.ui.screenshot_mode) {
            .idle => {},
            .capturing => |*s| {
                if (render_err) |err| {
                    s.respondErr(self.io, self.allocator, err);
                } else {
                    s.respondOk(self.io, self.allocator);
                }
                self.ui.screenshot_mode = .idle;
            },
        }
    }

    pub fn setZoom(self: *ViewerState, factor: f32) void {
        self.viewport.zoom_factor = self.clampZoomFactor(factor);
    }

    pub fn setPan(self: *ViewerState, px: f32, py: f32) void {
        self.viewport.pan_x = px;
        self.viewport.pan_y = py;
    }

    pub fn setAdjustments(self: *ViewerState, br: f32, co: f32) void {
        self.viewport.brightness = std.math.clamp(br, -1.0, 1.0);
        self.viewport.contrast = std.math.clamp(co, 0.0, 5.0);
    }

    pub fn setTextureScaleMode(self: *ViewerState, mode: TextureScaleMode) void {
        self.viewport.texture_scale_mode = mode;
        self.applyTextureScaleMode();
    }

    pub fn setPaletteMode(self: *ViewerState, mode: PaletteMode) void {
        self.ui.palette.mode = mode;
    }

    pub fn requestQuit(self: *ViewerState) void {
        self.running = false;
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

test "ViewerState.clampZoomFactor bounds based on image dimensions" {
    _ = clay.initialize(clay.Arena.init(&test_clay_memory), .{ .w = 1024, .h = 768 }, .{});

    var state = ViewerState{
        .navigation = NavigationState.init(std.testing.allocator),
        .ui = UiState.init(std.testing.allocator),
        .cache = .{},
        .allocator = std.testing.allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .rotation_map = .init(std.testing.allocator),
        .viewport = .{ .fit_mode = .none },
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    // Default base_scale without loaded image is 1.0
    try std.testing.expectEqual(@as(f32, 1.0), state.getBaseScale());
    try std.testing.expectEqual(@as(f32, 10.0), state.clampZoomFactor(15.0).get());
    try std.testing.expectEqual(@as(f32, 0.1), state.clampZoomFactor(0.05).get());

    // Test with loaded CPU image entry
    const surf = sdl.Surface.create(4000, 3000, sdl.PixelFormat.rgba32) orelse unreachable;
    try state.cache.append(std.testing.allocator, .{
        .index = 0,
        .generation = 0,
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
    state.navigation.current_index = 0;

    // In .none mode on 4000x3000 image, base_scale is 1.0
    state.viewport.fit_mode = .none;
    const base_none = state.getBaseScale();
    try std.testing.expectEqual(@as(f32, 1.0), base_none);
    const clamped_max_none = state.clampZoomFactor(15.0);
    try std.testing.expectEqual(@as(f32, 10.0), base_none * clamped_max_none.get());

    // In .full mode in default 1024x708 viewport
    state.viewport.fit_mode = .full;
    const base_full = state.getBaseScale();
    try std.testing.expect(base_full < 1.0);
    const clamped_max_full = state.clampZoomFactor(100.0);
    // Effective max zoom level (base_scale * zoom_factor) must be 10.0x of actual image size
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), base_full * clamped_max_full.get(), 0.001);
    const clamped_min_full = state.clampZoomFactor(0.001);
    // Effective min zoom level (base_scale * zoom_factor) must be 0.1x of actual image size
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), base_full * clamped_min_full.get(), 0.001);
}

test "ViewerState.updateCurrentRotation syncs EXIF orientation" {
    var state = ViewerState{
        .directory_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .image_list = .empty,
        .cache = .{},
        .allocator = std.testing.allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .palette = PaletteState.init(std.testing.allocator),
        .rotation_map = .init(std.testing.allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    try state.image_list.append(std.testing.allocator, "test_photo_1.jpg");
    state.current_index = 0;

    // Initially uncached -> rotation_angle should be 0.0
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.viewport.rotation_angle);

    // Simulate worker thread caching EXIF orientation of 90.0
    try state.cache.append(std.testing.allocator, .{
        .index = 0,
        .generation = 0,
        .status = .{ .decoding = .{} },
        .exif_orientation = 90.0,
    });

    // Calling updateCurrentRotation updates rotation_angle from entry
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 90.0), state.viewport.rotation_angle);

    // Test out of bounds index
    state.current_index = 99;
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.viewport.rotation_angle);

    // Test null index
    state.current_index = null;
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.viewport.rotation_angle);
}

test "ElementTag.fromInt" {
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0));
    try std.testing.expectEqual(ElementTag.drop_zone_box, ElementTag.fromInt(1337));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(9999));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0x7fffffffd000));
}

test "ViewerState.openPalette directory_navigator starting directory rules" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_open_dir_test";
    std.Io.Dir.createDirPath(cwd, io, tmp_dir ++ "/sub1") catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var state = ViewerState{
        .navigation = NavigationState.init(allocator),
        .ui = UiState.init(allocator),
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .rotation_map = .init(allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    // Rule 1: current_index is valid -> starting directory is dirname of current image
    const sample_path = tmp_dir ++ "/image1.jpg";
    try state.navigation.image_list.append(allocator, sample_path);
    state.navigation.current_index = 0;

    try state.openPalette(.directory_navigator);
    try std.testing.expectEqual(PaletteMode.directory_navigator, state.ui.palette.mode);
    try std.testing.expectEqualStrings(tmp_dir, state.ui.palette.current_nav_dir.items);

    // Rule 2: current_index is null -> starting directory remembers last_nav_dir
    state.navigation.current_index = null;
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(tmp_dir, state.ui.palette.current_nav_dir.items);

    // Rule 3: current_index is null and last_nav_dir is empty -> starting directory falls back to "."
    state.ui.palette.last_nav_dir.clearRetainingCapacity();
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(".", state.ui.palette.current_nav_dir.items);

    // Rule 4: current_index out of bounds and last_nav_dir is empty -> starting directory falls back to "."
    state.navigation.current_index = 999;
    state.ui.palette.last_nav_dir.clearRetainingCapacity();
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(".", state.ui.palette.current_nav_dir.items);
}

test "ViewerState.openPalette directory_navigator steps up if 0 subdirectories" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_step_up_test";
    const sub_leaf = tmp_dir ++ "/child_leaf";
    std.Io.Dir.createDirPath(cwd, io, sub_leaf) catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var state = ViewerState{
        .navigation = NavigationState.init(allocator),
        .ui = UiState.init(allocator),
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .rotation_map = .init(allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    // Image in child_leaf (which has 0 subdirectories itself)
    const img_path = sub_leaf ++ "/photo.png";
    try state.navigation.image_list.append(allocator, img_path);
    state.navigation.current_index = 0;

    // openPalette should see sub_leaf has 0 subdirectories, so it steps up to tmp_dir and pre-selects child_leaf
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(tmp_dir, state.ui.palette.current_nav_dir.items);

    // Verify child_leaf is selected
    var found_leaf_selected = false;
    if (state.ui.palette.selected_idx < state.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.ui.palette.dir_items.items[state.ui.palette.selected_idx].name, "child_leaf")) {
            found_leaf_selected = true;
        }
    }
    try std.testing.expect(found_leaf_selected);
}

test "ViewerState.openPalette steps up from top-level relative leaf dir without slashes to dot" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const top_leaf = "tmp_top_level_leaf_test";
    std.Io.Dir.createDirPath(cwd, io, top_leaf) catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, top_leaf) catch {};
    }

    var state = ViewerState{
        .navigation = NavigationState.init(allocator),
        .ui = UiState.init(allocator),
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .rotation_map = .init(allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    const img_path = top_leaf ++ "/photo.png";
    try state.navigation.image_list.append(allocator, img_path);
    state.navigation.current_index = 0;

    try state.openPalette(.directory_navigator);
    // Should step up to "." because top_leaf has 0 subdirectories
    try std.testing.expectEqualStrings(".", state.ui.palette.current_nav_dir.items);

    // Verify top_leaf is pre-selected in "."
    var found_leaf_selected = false;
    if (state.ui.palette.selected_idx < state.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.ui.palette.dir_items.items[state.ui.palette.selected_idx].name, top_leaf)) {
            found_leaf_selected = true;
        }
    }
    try std.testing.expect(found_leaf_selected);
}

test "ViewerState.isPointerInDebugPanel and click localization" {
    _ = clay.initialize(clay.Arena.init(&test_clay_memory), .{ .w = 1000, .h = 800 }, .{});

    clay.setDebugModeEnabled(true);
    defer clay.setDebugModeEnabled(false);

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = ViewerState{
        .navigation = NavigationState.init(allocator),
        .ui = UiState.init(allocator),
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .rotation_map = .init(allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
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

    state.ui.palette.mode = .actions;
    try state.update(input_inside);
    try std.testing.expect(state.ui.palette.mode == .actions);
}

test "ViewerState slideshow timer auto-advances slide" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = ViewerState{
        .navigation = NavigationState.init(allocator),
        .ui = UiState.init(allocator),
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .rotation_map = .init(allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    try state.navigation.image_list.append(allocator, "img1.jpg");
    try state.navigation.image_list.append(allocator, "img2.jpg");
    state.navigation.current_index = 0;
    state.navigation.slideshow = .{ .active = .{ .interval_s = 2.0 } };

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

    try state.update(frame_input_1s);
    try std.testing.expectEqual(@as(usize, 0), state.navigation.current_index.?);

    // Pass another second (total 2000ms >= 2.0s interval) -> advances to index 1
    try state.update(frame_input_1s);
    try std.testing.expectEqual(@as(usize, 1), state.navigation.current_index.?);
}

test "RollingStats mean and stdev" {
    var stats = RollingStats{};
    try std.testing.expectEqual(@as(f64, 0.0), stats.getMeanAndStdev().mean);
    try std.testing.expectEqual(@as(f64, 0.0), stats.getMeanAndStdev().stdev);

    stats.addSample(10.0);
    try std.testing.expectEqual(@as(f64, 10.0), stats.getMeanAndStdev().mean);
    try std.testing.expectEqual(@as(f64, 0.0), stats.getMeanAndStdev().stdev);

    stats.addSample(20.0);
    const result = stats.getMeanAndStdev();
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.mean, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0710678), result.stdev, 0.0001);

    // Fill to 60 samples all with 10.0
    stats.reset();
    for (0..60) |_| {
        stats.addSample(10.0);
    }
    const r60 = stats.getMeanAndStdev();
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), r60.mean, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), r60.stdev, 0.0001);

    // Overfill beyond 60 samples
    for (0..10) |_| {
        stats.addSample(20.0);
    }
    const r_over = stats.getMeanAndStdev();
    try std.testing.expectApproxEqAbs(@as(f64, 11.6666667), r_over.mean, 0.0001);
}
