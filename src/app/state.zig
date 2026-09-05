const std = @import("std");
const fuzzig = @import("fuzzig");
const sdl = @import("sdl");
const clay = @import("zclay");
const state_pkg = @import("state");
const types = state_pkg.types;
const FrameInput = types.FrameInput;
const app_input = @import("input");
const image = @import("core/image.zig");
const core_fs = @import("core/fs.zig");
const events = @import("core/events.zig");
const ipc = @import("ipc");
const exif = @import("core/exif.zig");
const systems = @import("systems/root.zig");
const workers_mod = @import("workers/root.zig");

const view_transform = state_pkg.view_transform;

const uploadSurfaceToGpu = image.uploadSurfaceToGpu;
const CacheStatus = state_pkg.CacheStatus;
const CacheEntry = state_pkg.CacheEntry;
const CacheSlotMap = image.CacheSlotMap;
const CacheKey = image.CacheKey;
const TextureHandle = image.TextureHandle;
const DecodeArgs = workers_mod.DecodeArgs;

const intents = @import("intents");
const ScaleMode = intents.ScaleMode;
const TextureScaleMode = intents.TextureScaleMode;
const PaletteMode = intents.PaletteMode;
const AppIntent = intents.AppIntent;

const SlideshowMode = state_pkg.SlideshowMode;
const OverlayState = state_pkg.OverlayState;
const UiRenderMetrics = state_pkg.UiRenderMetrics;

pub const ElementTag = state_pkg.ElementTag;

const palette_module = @import("core/palette.zig");
const PaletteState = state_pkg.PaletteState;

const DragState = state_pkg.DragState;
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

    /// Queues
    event_batch: std.ArrayList(events.BackgroundEvent) = .empty,
    pending_ipc_commands: std.ArrayList(*ipc.IpcCommandData) = .empty,
    pending_intents: std.ArrayList(AppIntent) = .empty,

    pub fn initHeadless(allocator: std.mem.Allocator, io: std.Io) !AppState {
        var state = AppState{
            .viewer = try ViewerState.initHeadless(allocator),
            .cache = .{},
            .allocator = allocator,
            .io = io,
        };
        try state.ensureInitialCapacities();
        return state;
    }

    pub fn ensureInitialCapacities(self: *AppState) !void {
        // 16 intents: accommodates worst-case enqueued IPC, keyboard, palette, and slideshow intents in a single tick
        try self.pending_intents.ensureTotalCapacity(self.allocator, 16);
        // 16 events: accommodates concurrent worker background events (decodes, EXIF, path scans) processed per tick
        try self.event_batch.ensureTotalCapacity(self.allocator, 16);
        // 8 commands: accommodates queued socket IPC command buffers
        try self.pending_ipc_commands.ensureTotalCapacity(self.allocator, 8);
    }

    pub fn pushIntent(self: *AppState, intent: AppIntent) !void {
        try self.pending_intents.append(self.allocator, intent);
    }

    pub fn clearIntents(self: *AppState) void {
        self.pending_intents.clearRetainingCapacity();
    }

    pub inline fn isBusy(self: *const AppState) bool {
        return self.viewer.navigation.is_loading_files.load(.acquire) or self.workers.isBusy() or self.viewer.isSlideshowActive();
    }

    pub fn readJpegExifOrientation(self: *const AppState, path: []const u8) ?f32 {
        return exif.readJpegExifOrientation(self.io, path);
    }

    pub fn setDebugShowThumb(self: *AppState, enable: bool) !void {
        self.viewer.ui.overlays.debug_show_thumb = enable;
        if (!enable) return;

        const e = self.getCurrentEntryPtr() orelse return;
        if (e.thumbnail == .loaded) return;

        const idx = self.viewer.navigation.current_index orelse return;
        if (idx >= self.viewer.navigation.image_list.items.len) return;

        const media = self.viewer.navigation.image_list.items[idx];
        if (media != .filesystem) return;
        const path = media.filesystem.path;
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

        switch (e.thumbnail) {
            .loaded => |thumb| dev.releaseTexture(thumb.texture),
            else => {},
        }

        if (full_dims) |dims| {
            e.full_w = dims.w;
            e.full_h = dims.h;
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
    }

    pub fn deinit(self: *AppState) void {
        self.workers.drainAndQuiesce(self.io);

        if (self.gpu_device) |dev| {
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

    pub fn putRotation(self: *AppState, path: []const u8, angle: f32) !void {
        try self.viewer.putRotation(self.allocator, path, angle);
    }

    pub fn clearRotationMap(self: *AppState) void {
        self.viewer.clearRotationMap(self.allocator);
    }

    pub fn resetZoomPan(self: *AppState) void {
        self.viewer.resetZoomPan();
    }

    pub fn getBaseScale(self: *AppState) f32 {
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

    pub fn isPointerInDebugPanel(self: *const AppState, input: FrameInput) bool {
        _ = self;
        return input.isPointerInDebugPanel();
    }

    pub fn clampZoomFactor(self: *AppState, new_factor: f32) types.ZoomFactor {
        const base_scale = self.getBaseScale();
        return view_transform.clampZoomFactor(base_scale, new_factor);
    }

    pub fn getTextureByHandle(self: *AppState, handle: TextureHandle) ?sdl.gpu.Texture {
        return self.cache.getTexture(handle);
    }

    pub fn rebuildPaletteMatches(self: *AppState) !void {
        try self.viewer.ui.palette.rebuildFileMatches(self.viewer.navigation.image_list.items);
    }

    pub fn rebuildActionMatches(self: *AppState) !void {
        try self.viewer.ui.palette.rebuildActionMatches();
    }

    pub fn getCurrentEntryPtr(self: *AppState) ?*CacheEntry {
        const idx = self.viewer.navigation.current_index orelse return null;
        return self.cache.get(self.cache.activeKey(idx));
    }

    pub fn getCurrentEntry(self: *AppState) ?CacheEntry {
        if (self.getCurrentEntryPtr()) |entry| {
            return entry.*;
        }
        return null;
    }

    pub fn openPalette(self: *AppState, active_type: PaletteMode) !void {
        self.viewer.ui.palette.reset();
        self.viewer.ui.palette.mode = active_type;
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
                try palette_module.loadDirectoryEntries(&self.viewer.ui.palette, self.io, start_dir);
                while (self.viewer.ui.palette.dir_items.items.len == 0) {
                    const curr = self.viewer.ui.palette.current_nav_dir.items;
                    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                    if (core_fs.getParentDirBuf(curr, &parent_buf)) |parent_dir| {
                        if (!std.mem.eql(u8, parent_dir, curr)) {
                            try palette_module.loadDirectoryEntries(&self.viewer.ui.palette, self.io, parent_dir);
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

    pub fn prepareCacheTextures(self: *AppState) void {
        var upload_target: ?struct {
            key: CacheKey,
            cpu: @TypeOf(@as(CacheStatus, undefined).loaded_cpu),
        } = null;

        const entries = self.cache.slots.items(.entry);
        const keys = self.cache.slots.items(.key);
        for (entries, keys) |*entry, key| {
            if (entry.status == .loaded_gpu and !self.viewer.ui.overlays.debug_show_thumb) {
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
            switch (entry.status) {
                .loaded_cpu => |cpu| {
                    entry.status = .uploading;
                    upload_target = .{
                        .key = key,
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
                    const updated = self.cache.updateStatus(target.key, loaded_gpu_status);

                    if (!updated) {
                        gpu_dev.releaseTexture(res.gpu_texture);
                    }
                } else {
                    _ = self.cache.updateStatus(target.key, .failed);
                }
            }
        }
    }

    pub fn clearCache(self: *AppState) void {
        const dev_opt = self.gpu_device;
        self.cache.clear(dev_opt);
    }

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
            self.viewer.viewport.rotation_angle = entry.exif_orientation;
        } else {
            self.viewer.viewport.rotation_angle = 0.0;
        }
    }

    pub fn next(self: *AppState) !void {
        _ = self.viewer.navigation.nextIndex();
    }

    pub fn prev(self: *AppState) !void {
        _ = self.viewer.navigation.prevIndex();
    }

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

    pub fn startAsyncPathScan(self: *AppState, path: []const u8, is_dir: bool) !void {
        _ = is_dir;
        try self.handlePathSelection(path);
    }

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
        .exif_orientation = 90.0,
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

test "RollingStats mean and stdev" {
    var stats = state_pkg.ui_state.RollingStats{};
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
