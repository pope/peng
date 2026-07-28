const std = @import("std");
const fuzzig = @import("fuzzig");
const sdl = @import("sdl");
const clay = @import("zclay");
const types = @import("types.zig");
const FrameInput = types.FrameInput;
const app_input = @import("input.zig");
const renderer = @import("../ui/renderer.zig");
const commands = @import("../commands.zig");
const graphics = @import("../ui/graphics.zig");
pub const image = @import("image.zig");
pub const fs = @import("fs.zig");
pub const events = @import("events.zig");
pub const pipeline = @import("pipeline.zig");
pub const ipc = @import("ipc.zig");
pub const exif = @import("exif.zig");
const screenshot = @import("screenshot.zig");

pub const CacheStatus = image.CacheStatus;
pub const CacheEntry = image.CacheEntry;
pub const CacheSlotMap = image.CacheSlotMap;
pub const TextureHandle = image.TextureHandle;
pub const DecodeArgs = image.DecodeArgs;
pub const detectMimeType = image.detectMimeType;
pub const parseExifOrientation = exif.parseExifOrientation;
pub const readJpegExifOrientation = exif.readJpegExifOrientation;
pub const eqlIgnoreCase = fs.eqlIgnoreCase;
pub const isImageExtension = fs.isImageExtension;
pub const scanDirectory = fs.scanDirectory;
pub const uploadSurfaceToGpu = graphics.uploadSurfaceToGpu;
pub const GpuUploadResult = graphics.GpuUploadResult;

pub const ScaleMode = types.ScaleMode;
pub const TextureScaleMode = types.TextureScaleMode;

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

pub const palette_module = @import("palette.zig");
pub const PaletteMode = palette_module.PaletteMode;
pub const PaletteState = palette_module.PaletteState;

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

pub const RollingStats = struct {
    samples: [60]f64 = [_]f64{0.0} ** 60,
    count: usize = 0,
    index: usize = 0,

    pub fn addSample(self: *RollingStats, value: f64) void {
        self.samples[self.index] = value;
        self.index = (self.index + 1) % self.samples.len;
        if (self.count < self.samples.len) {
            self.count += 1;
        }
    }

    pub fn getMeanAndStdev(self: *const RollingStats) struct { mean: f64, stdev: f64 } {
        if (self.count == 0) return .{ .mean = 0.0, .stdev = 0.0 };
        var sum: f64 = 0.0;
        for (0..self.count) |i| {
            sum += self.samples[i];
        }
        const mean = sum / @as(f64, @floatFromInt(self.count));
        if (self.count < 2) return .{ .mean = mean, .stdev = 0.0 };

        var variance_sum: f64 = 0.0;
        for (0..self.count) |i| {
            const diff = self.samples[i] - mean;
            variance_sum += diff * diff;
        }
        const variance = @max(0.0, variance_sum) / @as(f64, @floatFromInt(self.count - 1));
        const stdev = @sqrt(variance);
        return .{ .mean = mean, .stdev = stdev };
    }

    pub fn reset(self: *RollingStats) void {
        self.count = 0;
        self.index = 0;
    }
};

pub const TextCacheModule = @import("../ui/text_cache.zig");
pub const TextCacheKey = TextCacheModule.TextCacheKey;
pub const TextCacheValue = TextCacheModule.TextCacheValue;
pub const TextCache = TextCacheModule.TextCache;

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

/// Mutually exclusive state machine for automated image slideshow transitions.
///
/// Variants:
/// - `inactive`: Slideshow is stopped. Timer memory and interval variables do not exist.
/// - `active`: Slideshow is actively advancing images.
///   - `interval_s`: Duration (in seconds) to display each image before transitioning.
///   - `timer_ms`: Accumulated millisecond counter tracking progress toward the next slide transition.
pub const SlideshowMode = union(enum) {
    inactive,
    active: struct {
        interval_s: f32,
        timer_ms: f32 = 0.0,
    },

    /// Advances the slideshow timer by `delta_ms`.
    /// Returns `true` when the timer exceeds `interval_s`, triggering an image transition.
    pub fn tick(self: *SlideshowMode, delta_ms: f32) bool {
        switch (self.*) {
            .inactive => return false,
            .active => |*data| {
                if (data.interval_s <= 0.0) return false;
                data.timer_ms += delta_ms;
                if (data.timer_ms >= data.interval_s * 1000.0) {
                    data.timer_ms = 0.0;
                    return true;
                }
                return false;
            },
        }
    }

    /// Resets the accumulated slide transition timer back to 0.0ms without deactivating the slideshow.
    pub fn resetTimer(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*data| data.timer_ms = 0.0,
        }
    }
};

/// Encapsulates resources and state specific to an active windowed GUI session.
///
/// Fields:
/// - `handle`: The underlying SDL window handle for OS window operations.
/// - `pixel_format`: Swapchain GPU texture format associated with the window.
/// - `cached_title`: Heap-allocated buffer of the active window title to prevent redundant SDL title updates.
/// - `is_fullscreen`: Boolean tracking whether the window is currently expanded to fullscreen.
/// - `claimed`: True if the window has claimed focus and rendering output (false during headless tests).
pub const ActiveWindow = struct {
    handle: sdl.Window,
    pixel_format: u32 = sdl.PixelFormat.unknown,
    cached_title: ?[]const u8 = null,
    is_fullscreen: bool = false,
    claimed: bool = false,

    /// Frees cached window title memory upon window teardown.
    pub fn deinit(self: *ActiveWindow, gpa: std.mem.Allocator) void {
        if (self.cached_title) |t| {
            gpa.free(t);
        }
    }
};

/// Tagged union discriminating between offscreen/headless mode and active windowed GUI mode.
///
/// Variants:
/// - `headless`: Render operations execute offscreen; no physical OS window or swapchain exists.
/// - `windowed`: Active GUI windowing mode containing an `ActiveWindow` instance.
pub const DisplayState = union(enum) {
    headless,
    windowed: ActiveWindow,

    /// Returns the cached window title slice if windowed, or `null` if headless.
    pub inline fn getTitle(self: DisplayState) ?[]const u8 {
        return switch (self) {
            .headless => null,
            .windowed => |w| w.cached_title,
        };
    }

    /// Returns whether the display is currently in fullscreen mode (always `false` in headless mode).
    pub inline fn isFullscreen(self: DisplayState) bool {
        return switch (self) {
            .headless => false,
            .windowed => |w| w.is_fullscreen,
        };
    }

    /// Returns whether the window has claimed rendering output.
    pub inline fn isClaimed(self: DisplayState) bool {
        return switch (self) {
            .headless => false,
            .windowed => |w| w.claimed,
        };
    }

    /// Returns the GPU swapchain pixel format for windowed mode, or default format if headless.
    pub inline fn getPixelFormat(self: DisplayState) u32 {
        return switch (self) {
            .headless => sdl.PixelFormat.unknown,
            .windowed => |w| w.pixel_format,
        };
    }
};

/// Tagged union modeling IPC screenshot capture state.
///
/// Variants:
/// - `idle`: No screenshot capture request is currently in progress.
/// - `capturing`: A screenshot capture is currently executing for a connected IPC socket client.
pub const ScreenshotMode = union(enum) {
    idle,
    capturing: screenshot.ActiveScreenshot,
};

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
    gpu_pipeline: ?sdl.gpu.Pipeline = null,
    unpack_compute_pipeline: ?sdl.gpu.ComputePipeline = null,
    gpu_sampler: ?sdl.gpu.Sampler = null,
    white_texture: ?sdl.gpu.Texture = null,

    directory_arena: std.heap.ArenaAllocator,
    image_list: std.ArrayList([]const u8),
    is_loading_files: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    current_index: ?usize = null,
    cache: CacheSlotMap,
    current_image_cache_hit: bool = false,
    allocator: std.mem.Allocator,
    io: std.Io,
    active_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_decode_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    exiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    palette: PaletteState,

    // Tagged Union State Machines
    display: DisplayState = .headless,
    slideshow: SlideshowMode = .inactive,
    screenshot_mode: ScreenshotMode = .idle,
    drag_state: DragState = .none,

    running: bool = true,
    show_info_overlay: bool = false,
    show_stats_overlay: bool = false,
    debug_show_thumb: bool = false,
    scale_mode: ScaleMode = .full,
    zoom_factor: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    rotation_angle: f32 = 0.0,
    rotation_map: std.StringHashMap(f32),
    texture_scale_mode: TextureScaleMode = .linear,
    brightness: f32 = 0.0,
    contrast: f32 = 1.0,
    adjustments_dirty: bool = false,
    info_offset_x: f32 = 20.0,
    info_offset_y: f32 = 20.0,
    stats_offset_x: f32 = -20.0,
    stats_offset_y: f32 = 20.0,
    mouse_inside: bool = true,
    last_nav_time_ms: u64 = 0,
    last_scanned_dir: std.ArrayList(u8) = std.ArrayList(u8).empty,
    event_queue: events.MpscQueue(events.BackgroundEvent) = .{},
    pending_ipc_commands: std.ArrayListUnmanaged(*ipc.IpcCommandData) = .empty,

    // UI Render Performance Statistics
    last_ui_render_time_ms: f64 = 0.0,
    ui_render_stats: RollingStats = .{},
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,

    // Persistent double-buffered vertex resources
    gpu_vertex_buffers: [2]?sdl.gpu.Buffer = .{ null, null },
    gpu_transfer_buffers: [2]?sdl.gpu.TransferBuffer = .{ null, null },
    gpu_buffer_capacities: [2]usize = .{ 0, 0 },
    gpu_vertex_capacities: [2]usize = .{ 0, 0 },
    gpu_frame_index: usize = 0,

    // Font text texture cache
    text_cache: TextCache = .{},

    pub inline fn isFullscreen(self: *const ViewerState) bool {
        return self.display.isFullscreen();
    }
    pub inline fn isSlideshowActive(self: *const ViewerState) bool {
        return self.slideshow == .active;
    }
    pub inline fn isBusy(self: *const ViewerState) bool {
        return self.is_loading_files.load(.acquire) or (self.active_threads.load(.acquire) > 0) or self.isSlideshowActive();
    }

    pub fn readJpegExifOrientation(self: *const ViewerState, path: []const u8) ?f32 {
        return exif.readJpegExifOrientation(self.io, path);
    }

    pub fn setDebugShowThumb(self: *ViewerState, enable: bool) !void {
        self.debug_show_thumb = enable;
        if (!enable) return;

        const entry = self.getCurrentEntry() orelse return;
        if (entry.thumb_gpu_texture != null) return;

        const idx = self.current_index orelse return;
        if (idx >= self.image_list.items.len) return;

        const path = self.image_list.items[idx];
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

        const gpu_dev = self.gpu_device orelse return;
        const upload_res = graphics.uploadSurfaceToGpu(gpu_dev, thumb_surf, self.unpack_compute_pipeline) orelse return;

        if (self.cache.getWithGeneration(entry.index, entry.generation)) |e| {
            if (e.thumb_gpu_texture) |old_t| {
                gpu_dev.releaseTexture(old_t);
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
            gpu_dev.releaseTexture(upload_res.gpu_texture);
        }
    }

    pub fn deinit(self: *ViewerState) void {
        self.exiting.store(true, .release);
        while (self.active_threads.load(.acquire) > 0) {
            sdl.timer.delay(1);
        }

        self.clearCache();

        if (self.gpu_device) |dev| {
            for (self.gpu_vertex_buffers) |vb| {
                if (vb) |b| dev.releaseBuffer(b);
            }
            for (self.gpu_transfer_buffers) |tb| {
                if (tb) |b| dev.releaseTransferBuffer(b);
            }

            if (self.gpu_pipeline) |pipe| dev.releasePipeline(pipe);
            if (self.unpack_compute_pipeline) |pipe| dev.releaseComputePipeline(pipe);
            if (self.gpu_sampler) |samp| dev.releaseSampler(samp);
            if (self.white_texture) |tex| dev.releaseTexture(tex);
        }

        switch (self.display) {
            .headless => {},
            .windowed => |*w| {
                if (w.claimed) {
                    if (self.gpu_device) |dev| {
                        w.handle.releaseFromGpu(dev);
                    }
                }
                w.deinit(self.allocator);
            },
        }

        switch (self.screenshot_mode) {
            .idle => {},
            .capturing => |*s| {
                s.respondQuit(self.io, self.allocator);
                self.screenshot_mode = .idle;
            },
        }

        for (self.pending_ipc_commands.items) |cmd_data| {
            self.allocator.free(cmd_data.command);
            self.allocator.destroy(cmd_data);
        }
        self.last_scanned_dir.deinit(self.allocator);
        self.pending_ipc_commands.deinit(self.allocator);
        self.event_queue.deinit(self.allocator, self.io);
        self.text_cache.deinit(self.allocator, self.gpu_device);
        self.image_list.deinit(self.allocator);
        self.cache.deinit(self.allocator, self.gpu_device);
        self.palette.deinit();
        self.rotation_map.deinit();
        self.directory_arena.deinit();
    }

    /// Returns true if the application is still running and the background job's
    /// snapshot generation matches the current viewer state generation.
    /// Used by worker threads to drop stale results early when navigation changes.
    pub fn isJobValid(self: *ViewerState, generation: usize) bool {
        return !self.exiting.load(.acquire) and self.generation.load(.acquire) == generation;
    }

    pub fn resetZoomPan(self: *ViewerState) void {
        self.zoom_factor = 1.0;
        self.pan_x = 0.0;
        self.pan_y = 0.0;
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

        const view_transform = @import("view_transform.zig");
        const dims = view_transform.computeViewDims(raw_w, raw_h, self.rotation_angle, view_w, view_h, self.scale_mode);
        return dims.base_scale;
    }

    pub fn isPointerInDebugPanel(self: *const ViewerState, input: FrameInput) bool {
        _ = self;
        if (!clay.isDebugModeEnabled()) return false;
        const debug_w = @as(f32, @floatFromInt(clay.Clay__debugViewWidth));
        return input.mouse_x >= (input.win_w - debug_w) and input.mouse_x <= input.win_w and
            input.mouse_y >= 0 and input.mouse_y <= input.win_h;
    }

    pub fn clampZoomFactor(self: *ViewerState, new_factor: f32) f32 {
        const base_scale = self.getBaseScale();
        const view_transform = @import("view_transform.zig");
        return view_transform.clampZoomFactor(base_scale, new_factor);
    }

    pub fn getTextureByHandle(self: *ViewerState, handle: TextureHandle) ?sdl.gpu.Texture {
        self.lockCache();
        defer self.unlockCache();
        return self.cache.getTexture(handle);
    }

    pub fn applyTextureScaleMode(self: *ViewerState) void {
        const filter = if (self.texture_scale_mode == .linear) sdl.gpu.Filter.linear else sdl.gpu.Filter.nearest;
        if (self.gpu_device) |gpu_dev| {
            if (self.gpu_sampler) |old_sampler| {
                gpu_dev.releaseSampler(old_sampler);
            }

            const sampler_info = sdl.gpu.SamplerCreateInfo{
                .min_filter = filter,
                .mag_filter = filter,
                .mipmap_mode = .linear,
                .address_mode_u = .clamp_to_edge,
                .address_mode_v = .clamp_to_edge,
                .address_mode_w = .clamp_to_edge,
                .mip_lod_bias = 0.0,
                .max_anisotropy = 1.0,
                .compare_op = .never,
                .min_lod = 0.0,
                .max_lod = 1000.0,
                .props = 0,
            };
            self.gpu_sampler = gpu_dev.createSampler(&sampler_info);
        }
    }

    pub fn rebuildPaletteMatches(self: *ViewerState) !void {
        try self.palette.rebuildFileMatches(self.image_list.items);
    }

    pub fn rebuildActionMatches(self: *ViewerState) !void {
        try self.palette.rebuildActionMatches(commands.actions.app_actions);
    }

    pub fn triggerAction(self: *ViewerState, action_id: commands.actions.AppActionId) !void {
        try commands.actions.triggerAction(self, action_id);
    }

    pub fn getCurrentEntry(self: *ViewerState) ?CacheEntry {
        const idx = self.current_index orelse return null;
        if (self.cache.get(idx)) |entry| {
            return entry.*;
        }
        return null;
    }

    pub fn openPalette(self: *ViewerState, active_type: PaletteMode) !void {
        self.palette.reset();
        self.palette.mode = active_type;
        self.palette.selected_idx = switch (active_type) {
            .files => self.current_index orelse 0,
            else => 0,
        };
        self.palette.selection_dirty = true;

        const max_capacity = switch (active_type) {
            .files => self.image_list.items.len,
            .actions => commands.actions.app_actions.len,
            else => 0,
        };
        if (max_capacity > 0) {
            try self.palette.matches.ensureTotalCapacity(self.allocator, max_capacity);
        }

        switch (active_type) {
            .files => try self.rebuildPaletteMatches(),
            .actions => try self.rebuildActionMatches(),
            .directory_navigator => {
                const start_dir = blk: {
                    if (self.current_index) |idx| {
                        if (idx < self.image_list.items.len) {
                            break :blk std.fs.path.dirname(self.image_list.items[idx]) orelse ".";
                        }
                    }
                    if (self.last_scanned_dir.items.len > 0) {
                        break :blk self.last_scanned_dir.items;
                    }
                    if (self.palette.last_nav_dir.items.len > 0) {
                        break :blk self.palette.last_nav_dir.items;
                    }
                    break :blk ".";
                };
                try self.palette.loadDirectoryEntries(self.io, start_dir);
                while (self.palette.dir_items.items.len == 0) {
                    const curr = self.palette.current_nav_dir.items;
                    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                    if (fs.getParentDirBuf(curr, &parent_buf)) |parent_dir| {
                        if (!std.mem.eql(u8, parent_dir, curr)) {
                            try self.palette.loadDirectoryEntries(self.io, parent_dir);
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
            if (entry.status == .loaded_gpu and entry.thumb_gpu_texture != null and !self.debug_show_thumb) {
                if (self.gpu_device) |gpu_dev| {
                    gpu_dev.releaseTexture(entry.thumb_gpu_texture.?);
                }
                entry.thumb_gpu_texture = null;
            }
            if (entry.status == .loaded_cpu) {
                const cpu = entry.status.loaded_cpu;
                entry.status = .uploading;
                upload_target = .{
                    .index = entry.index,
                    .generation = entry.generation,
                    .cpu = cpu,
                };
                break;
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
        if (self.adjustments_dirty) {
            self.adjustments_dirty = false;
        }
    }

    pub fn clearCache(self: *ViewerState) void {
        self.cache.clear(self.gpu_device);
    }

    pub fn checkIdlePreload(self: *ViewerState) void {
        if (self.image_list.items.len <= 1) return;
        const now = sdl.timer.getTicks();
        if (now - self.last_nav_time_ms >= 150) {
            const entry_count = self.cache.entries.items.len;
            if (entry_count <= 1) {
                self.updateCache() catch |err| std.log.warn("Idle preload updateCache failed: {}", .{err});
            }
        }
    }

    pub fn updateCurrentRotation(self: *ViewerState) void {
        const path_opt = blk: {
            const len = self.image_list.items.len;
            const current_idx = self.current_index orelse break :blk null;
            if (current_idx >= len) break :blk null;
            break :blk self.image_list.items[current_idx];
        };

        const path = path_opt orelse {
            self.rotation_angle = 0.0;
            return;
        };

        if (self.rotation_map.get(path)) |user_rot| {
            self.rotation_angle = user_rot;
        } else if (self.getCurrentEntry()) |entry| {
            self.rotation_angle = entry.exif_orientation;
        } else {
            self.rotation_angle = 0.0;
        }
    }

    pub fn handleExifThumbnailEvent(self: *ViewerState, thumb_data: events.ThumbDecodedPayload) void {
        const current_gen = self.generation.load(.acquire);
        if (thumb_data.generation != current_gen) return;
        if (thumb_data.surface == null) return;
        if (self.gpu_device) |gpu_dev| {
            if (graphics.uploadSurfaceToGpu(gpu_dev, thumb_data.surface.?, self.unpack_compute_pipeline)) |upload_res| {
                if (self.cache.getWithGeneration(thumb_data.index, thumb_data.generation)) |entry| {
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
        const current_gen = self.generation.load(.acquire);
        if (decoded_data.generation != current_gen) return;
        if (decoded_data.surface == null) return;
        if (self.gpu_device) |gpu_dev| {
            if (graphics.uploadSurfaceToGpu(gpu_dev, decoded_data.surface.?, self.unpack_compute_pipeline)) |full_res| {
                if (self.cache.getWithGeneration(decoded_data.index, decoded_data.generation)) |entry| {
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
                    self.cache.enforceVramBudget(gpu_dev, self.current_index, CacheSlotMap.DEFAULT_MAX_VRAM_BYTES);
                } else {
                    gpu_dev.releaseTexture(full_res.gpu_texture);
                }
                self.updateCurrentRotation();
            }
        } else {
            if (self.cache.getWithGeneration(decoded_data.index, decoded_data.generation)) |entry| {
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
        const current_gen = self.generation.load(.acquire);
        if (scanned_data.generation != current_gen) return;
        const dup = self.directory_arena.allocator().dupe(u8, scanned_data.path) catch |err| {
            std.log.err("Failed to duplicate path '{s}' in directory arena: {}", .{ scanned_data.path, err });
            return;
        };
        self.image_list.append(self.allocator, dup) catch |err| std.log.err("Failed to append discovered path to image_list: {}", .{err});
        if (self.current_index == null and self.image_list.items.len > 0) {
            self.current_index = 0;
        }
    }

    pub fn handleDirectoryScanResultEvent(self: *ViewerState, result_data: events.DirectoryScanResultPayload) void {
        const current_gen = self.generation.load(.acquire);
        if (result_data.generation != current_gen) return;

        if (result_data.is_dir) {
            for (result_data.paths) |item| {
                const dup = self.directory_arena.allocator().dupe(u8, item) catch |err| {
                    std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                    continue;
                };
                self.image_list.append(self.allocator, dup) catch |err| {
                    std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
                };
            }
            if (self.current_index == null and self.image_list.items.len > 0) {
                self.current_index = 0;
            }
        } else {
            var target_idx_in_dir: ?usize = null;
            for (result_data.paths, 0..) |item, i| {
                if (std.mem.eql(u8, item, result_data.target_path)) {
                    target_idx_in_dir = i;
                    break;
                }
            }

            _ = self.directory_arena.reset(.retain_capacity);
            self.image_list.clearRetainingCapacity();
            for (result_data.paths, 0..) |item, i| {
                const dup = self.directory_arena.allocator().dupe(u8, item) catch |err| {
                    std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                    continue;
                };
                self.image_list.append(self.allocator, dup) catch |err| {
                    std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
                };
                if (target_idx_in_dir == null and std.mem.eql(u8, item, result_data.target_path)) {
                    target_idx_in_dir = i;
                }
            }

            if (target_idx_in_dir) |target_i| {
                if (target_i < self.image_list.items.len) {
                    self.current_index = target_i;
                }
            } else {
                self.current_index = 0;
            }
        }

        self.updateCache() catch |err| std.log.err("Failed to update cache after directory scan result: {}", .{err});
    }

    pub fn processBackgroundEvents(self: *ViewerState) bool {
        var event_batch = std.ArrayList(events.BackgroundEvent).empty;
        defer event_batch.deinit(self.allocator);

        self.event_queue.drain(self.allocator, self.io, &event_batch) catch return false;
        if (event_batch.items.len == 0) return false;
        const current_gen = self.generation.load(.acquire);

        for (event_batch.items) |*evt| {
            defer evt.deinit(self.allocator);

            switch (evt.*) {
                .exif_orientation_parsed => |e| {
                    if (e.generation != current_gen) continue;
                    if (self.cache.getWithGeneration(e.index, e.generation)) |entry| {
                        entry.exif_orientation = e.orientation;
                    }
                    self.updateCurrentRotation();
                },
                .thumb_decoded => |t| handleExifThumbnailEvent(self, t),
                .image_decoded => |*d| handleImageDecodedEvent(self, d),
                .decode_failed => |f| {
                    if (f.generation != current_gen) continue;
                    _ = self.cache.updateStatus(f.index, f.generation, .failed);
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

    pub fn getMaxConcurrentDecodes() usize {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        if (cpu_count <= 2) return 2;
        return @min(6, cpu_count - 1);
    }

    pub fn updateCache(self: *ViewerState) !void {
        self.resetZoomPan();
        self.updateCurrentRotation();

        const len = self.image_list.items.len;

        if (len == 0) return;

        const idx = self.current_index orelse return;
        const gen = self.generation.load(.acquire);

        const now = sdl.timer.getTicks();
        const is_rapid_scrolling = (now - self.last_nav_time_ms < 150);
        self.last_nav_time_ms = now;

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
                self.cache.removeAndDeinit(i, self.gpu_device);
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
                if (entry.status == .decoding and !entry.status.decoding.has_thread) {
                    needs_thread = true;
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
            if (d < self.image_list.items.len) {
                to_spawn_paths[s_idx] = self.allocator.dupeZ(u8, self.image_list.items[d]) catch |err| blk: {
                    std.log.err("updateCache: dupeZ failed for image index {d}: {}", .{ d, err });
                    break :blk null;
                };
            } else {
                to_spawn_paths[s_idx] = null;
            }
        }

        // 5. Spawn worker threads
        const max_decodes = getMaxConcurrentDecodes();
        for (to_spawn_indices[0..to_spawn_count], 0..) |d, s_idx| {
            const path_opt = to_spawn_paths[s_idx];
            if (path_opt == null or self.active_decode_threads.load(.acquire) >= max_decodes) {
                if (path_opt) |p| self.allocator.free(p);
                if (d != idx) {
                    var k: usize = 0;
                    while (k < self.cache.entries.items.len) : (k += 1) {
                        if (self.cache.entries.items[k].index == d) {
                            self.cache.removeAndDeinit(k, self.gpu_device);
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
                        self.cache.removeAndDeinit(k, self.gpu_device);
                        break;
                    }
                }
                return err;
            };

            if (self.cache.get(d)) |entry| {
                if (entry.status == .decoding) {
                    entry.status.decoding.has_thread = true;
                }
            }

            args.* = DecodeArgs{
                .state = self,
                .index = d,
                .generation = gen,
                .path = dup_path,
            };

            _ = self.active_decode_threads.fetchAdd(1, .monotonic);
            _ = self.active_threads.fetchAdd(1, .monotonic);
            if (std.Thread.spawn(.{}, image.decodeWorker, .{args})) |t| {
                t.detach();
            } else |err| {
                std.log.err("std.Thread.spawn failed: {}", .{err});
                _ = self.active_decode_threads.fetchSub(1, .release);
                _ = self.active_threads.fetchSub(1, .release);
                self.allocator.free(dup_path);
                self.allocator.destroy(args);
            }
        }
    }

    pub fn next(self: *ViewerState) !void {
        self.slideshow.resetTimer();
        const len = self.image_list.items.len;

        if (len == 0) return;
        if (self.current_index) |idx| {
            self.current_index = (idx + 1) % len;
        } else {
            self.current_index = 0;
        }
        try self.updateCache();
    }

    pub fn prev(self: *ViewerState) !void {
        self.slideshow.resetTimer();
        const len = self.image_list.items.len;

        if (len == 0) return;
        if (self.current_index) |idx| {
            if (idx == 0) {
                self.current_index = len - 1;
            } else {
                self.current_index = idx - 1;
            }
        } else {
            self.current_index = 0;
        }
        try self.updateCache();
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

        self.last_scanned_dir.clearRetainingCapacity();
        try self.last_scanned_dir.appendSlice(self.allocator, dir_target);

        // Clear existing cache and rotation map before resetting directory_arena
        _ = self.generation.fetchAdd(1, .release);
        self.clearCache();
        self.rotation_map.clearRetainingCapacity();
        self.image_list.clearRetainingCapacity();
        _ = self.directory_arena.reset(.retain_capacity);
        self.current_index = null;

        if (has_stat) {
            if (stat.kind == .directory) {
                try fs.startAsyncPathScan(self, path, true);
            } else {
                const dup = try self.directory_arena.allocator().dupe(u8, path);
                try self.image_list.append(self.allocator, dup);
                self.current_index = 0;

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
            if (self.palette.mode != .inactive) {
                try self.palette.query.appendSlice(self.allocator, text);
                self.palette.selected_idx = 0;
                self.palette.selection_dirty = true;
                switch (self.palette.mode) {
                    .files => try self.rebuildPaletteMatches(),
                    .actions => try self.rebuildActionMatches(),
                    .directory_navigator => try self.palette.rebuildDirectoryMatches(),
                    else => {},
                }
            }
        }

        var palette_closed_this_frame = false;
        if (input.mouse_left_clicked and self.palette.mode != .inactive) {
            const is_in_debug_panel = self.isPointerInDebugPanel(input);
            const element_id = switch (self.palette.mode) {
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
                self.palette.mode = .inactive;
                stopTextInput(self.display);
                palette_closed_this_frame = true;
            }
        }
        return palette_closed_this_frame;
    }

    pub fn processDragState(self: *ViewerState, input: FrameInput, palette_closed_this_frame: bool) void {
        var next_drag_state = self.drag_state;
        switch (next_drag_state) {
            .none => {},
            .viewport => |v| {
                if (input.mouse_left_down) {
                    const dx = input.pixMouseX() - v.last_x;
                    const dy = input.pixMouseY() - v.last_y;
                    self.pan_x += dx;
                    self.pan_y += dy;
                    next_drag_state = .{ .viewport = .{ .last_x = input.pixMouseX(), .last_y = input.pixMouseY() } };
                } else {
                    next_drag_state = .none;
                }
            },
            .info => |inf| {
                if (input.mouse_left_down) {
                    self.info_offset_x = input.mouse_x - inf.start_x;
                    self.info_offset_y = input.mouse_y - inf.start_y;
                } else {
                    next_drag_state = .none;
                }
            },
            .stats => |st| {
                if (input.mouse_left_down) {
                    self.stats_offset_x = input.mouse_x - st.start_x;
                    self.stats_offset_y = input.mouse_y - st.start_y;
                } else {
                    next_drag_state = .none;
                }
            },
        }

        if (next_drag_state == .none and input.mouse_left_clicked and !palette_closed_this_frame) {
            if (self.palette.mode == .inactive) {
                const is_in_debug_panel = self.isPointerInDebugPanel(input);
                if (self.show_info_overlay and !is_in_debug_panel and clay.pointerOver(clay.getElementId("InfoCard"))) {
                    next_drag_state = .{ .info = .{ .start_x = input.mouse_x - self.info_offset_x, .start_y = input.mouse_y - self.info_offset_y } };
                } else if (self.show_stats_overlay and !is_in_debug_panel and clay.pointerOver(clay.getElementId("StatsCard"))) {
                    next_drag_state = .{ .stats = .{ .start_x = input.mouse_x - self.stats_offset_x, .start_y = input.mouse_y - self.stats_offset_y } };
                } else if (!is_in_debug_panel and clay.pointerOver(clay.getElementId("Viewport"))) {
                    next_drag_state = .{ .viewport = .{ .last_x = input.pixMouseX(), .last_y = input.pixMouseY() } };
                }
            }
        }
        self.drag_state = next_drag_state;
    }

    pub fn processZoomAtCursor(self: *ViewerState, input: FrameInput) void {
        if (input.scroll_delta_y != 0) {
            if (self.palette.mode == .inactive and !self.isPointerInDebugPanel(input) and clay.pointerOver(clay.getElementId("Viewport"))) {
                const old_zoom = self.zoom_factor;
                self.zoom_factor = self.clampZoomFactor(self.zoom_factor + input.scroll_delta_y * 0.1);

                const available_width = if (clay.isDebugModeEnabled()) @max(input.win_w - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0) else input.win_w;
                const cx = available_width / 2.0;
                var title_bar_h: f32 = 60.0;
                if (self.isFullscreen()) {
                    title_bar_h = 0;
                }
                const cy = title_bar_h + ((input.win_h - title_bar_h) / 2.0);

                const rel_x = (input.mouse_x - cx) * input.scale_x;
                const rel_y = (input.mouse_y - cy) * input.scale_y;

                self.pan_x = rel_x - (rel_x - self.pan_x) * (self.zoom_factor / old_zoom);
                self.pan_y = rel_y - (rel_y - self.pan_y) * (self.zoom_factor / old_zoom);
            }
        }
    }

    pub fn update(self: *ViewerState, input: FrameInput) !void {
        self.updateCurrentRotation();

        // 0. Slideshow timer update
        if (self.slideshow.tick(input.delta_time_ms)) {
            try self.next();
        }

        // 1. Text input & palette dismissal updates
        const palette_closed_this_frame = try self.processPaletteInput(input);

        // 2. Drop file/directory updates
        if (input.dropped_path) |path| {
            try self.handlePathSelection(path);
        }

        // 3. Mouse dragging updates
        self.processDragState(input, palette_closed_this_frame);

        // 4. Mouse Wheel Zoom updates
        self.processZoomAtCursor(input);

        // 5. Keyboard updates
        for (input.keys_pressed.items) |key| {
            try app_input.handleKeyDown(self, key, input.key_modifiers, input.scale_x, input.scale_y);
        }
    }

    pub fn processIpcCommands(self: *ViewerState, ipc_server: ?*ipc.IpcServer) void {
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
                    } else if (self.screenshot_mode == .capturing) {
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
                        self.screenshot_mode = .{
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
                if (ipc_server) |srv| {
                    srv.executeCommand(self, cmd_data.command, cmd_data.client_stream) catch |err| {
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
        switch (self.screenshot_mode) {
            .idle => {},
            .capturing => |*s| {
                if (render_err) |err| {
                    s.respondErr(self.io, self.allocator, err);
                } else {
                    s.respondOk(self.io, self.allocator);
                }
                self.screenshot_mode = .idle;
            },
        }
    }

    pub fn setZoom(self: *ViewerState, factor: f32) void {
        self.zoom_factor = self.clampZoomFactor(factor);
    }

    pub fn setPan(self: *ViewerState, px: f32, py: f32) void {
        self.pan_x = px;
        self.pan_y = py;
    }

    pub fn setAdjustments(self: *ViewerState, br: f32, co: f32) void {
        self.brightness = std.math.clamp(br, -1.0, 1.0);
        self.contrast = std.math.clamp(co, 0.0, 5.0);
        self.adjustments_dirty = true;
    }

    pub fn setTextureScaleMode(self: *ViewerState, mode: TextureScaleMode) void {
        self.texture_scale_mode = mode;
        self.applyTextureScaleMode();
    }

    pub fn setPaletteMode(self: *ViewerState, mode: PaletteMode) void {
        self.palette.mode = mode;
    }

    pub fn requestQuit(self: *ViewerState) void {
        self.running = false;
    }
};

test "CacheSlotMap.updateStatus" {
    const allocator = std.testing.allocator;
    var cache = CacheSlotMap{};
    defer cache.deinit(allocator, null);

    try cache.append(allocator, .{
        .index = 10,
        .generation = 1,
        .status = .{ .decoding = .{} },
    });
    try cache.append(allocator, .{
        .index = 20,
        .generation = 1,
        .status = .{ .decoding = .{} },
    });

    // Test successful update
    const updated = cache.updateStatus(20, 1, .failed);
    try std.testing.expect(updated);
    try std.testing.expectEqual(CacheStatus.failed, cache.entries.items[1].status);

    // Test updating non-existent index
    const updated_missing = cache.updateStatus(30, 1, .failed);
    try std.testing.expect(!updated_missing);

    // Test updating matching index but mismatching generation
    const updated_gen_mismatch = cache.updateStatus(10, 2, .failed);
    try std.testing.expect(!updated_gen_mismatch);
}

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
        .directory_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .cache = .{},
        .allocator = std.testing.allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .palette = PaletteState.init(std.testing.allocator),
        .rotation_map = std.StringHashMap(f32).init(std.testing.allocator),
        .scale_mode = .none,
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    // Default base_scale without loaded image is 1.0
    try std.testing.expectEqual(@as(f32, 1.0), state.getBaseScale());
    try std.testing.expectEqual(@as(f32, 10.0), state.clampZoomFactor(15.0));
    try std.testing.expectEqual(@as(f32, 0.1), state.clampZoomFactor(0.05));

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
    state.current_index = 0;

    // In .none mode on 4000x3000 image, base_scale is 1.0
    state.scale_mode = .none;
    const base_none = state.getBaseScale();
    try std.testing.expectEqual(@as(f32, 1.0), base_none);
    const clamped_max_none = state.clampZoomFactor(15.0);
    try std.testing.expectEqual(@as(f32, 10.0), base_none * clamped_max_none);

    // In .full mode in default 1024x708 viewport
    state.scale_mode = .full;
    const base_full = state.getBaseScale();
    try std.testing.expect(base_full < 1.0);
    const clamped_max_full = state.clampZoomFactor(100.0);
    // Effective max zoom level (base_scale * zoom_factor) must be 10.0x of actual image size
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), base_full * clamped_max_full, 0.001);
    const clamped_min_full = state.clampZoomFactor(0.001);
    // Effective min zoom level (base_scale * zoom_factor) must be 0.1x of actual image size
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), base_full * clamped_min_full, 0.001);
}

test "ViewerState.updateCurrentRotation syncs EXIF orientation" {
    var state = ViewerState{
        .directory_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .cache = .{},
        .allocator = std.testing.allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .palette = PaletteState.init(std.testing.allocator),
        .rotation_map = std.StringHashMap(f32).init(std.testing.allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    try state.image_list.append(std.testing.allocator, "test_photo_1.jpg");
    state.current_index = 0;

    // Initially uncached -> rotation_angle should be 0.0
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.rotation_angle);

    // Simulate worker thread caching EXIF orientation of 90.0
    try state.cache.append(std.testing.allocator, .{
        .index = 0,
        .generation = 0,
        .status = .{ .decoding = .{} },
        .exif_orientation = 90.0,
    });

    // Calling updateCurrentRotation updates rotation_angle from entry
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 90.0), state.rotation_angle);

    // Test out of bounds index
    state.current_index = 99;
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.rotation_angle);

    // Test null index
    state.current_index = null;
    state.updateCurrentRotation();
    try std.testing.expectEqual(@as(f32, 0.0), state.rotation_angle);
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
        .directory_arena = std.heap.ArenaAllocator.init(allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .palette = PaletteState.init(allocator),
        .rotation_map = std.StringHashMap(f32).init(allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    // Rule 1: current_index is valid -> starting directory is dirname of current image
    const sample_path = tmp_dir ++ "/image1.jpg";
    try state.image_list.append(allocator, sample_path);
    state.current_index = 0;

    try state.openPalette(.directory_navigator);
    try std.testing.expectEqual(PaletteMode.directory_navigator, state.palette.mode);
    try std.testing.expectEqualStrings(tmp_dir, state.palette.current_nav_dir.items);

    // Rule 2: current_index is null -> starting directory remembers last_nav_dir
    state.current_index = null;
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(tmp_dir, state.palette.current_nav_dir.items);

    // Rule 3: current_index is null and last_nav_dir is empty -> starting directory falls back to "."
    state.palette.last_nav_dir.clearRetainingCapacity();
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(".", state.palette.current_nav_dir.items);

    // Rule 4: current_index out of bounds and last_nav_dir is empty -> starting directory falls back to "."
    state.current_index = 999;
    state.palette.last_nav_dir.clearRetainingCapacity();
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(".", state.palette.current_nav_dir.items);
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
        .directory_arena = std.heap.ArenaAllocator.init(allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .palette = PaletteState.init(allocator),
        .rotation_map = std.StringHashMap(f32).init(allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    // Image in child_leaf (which has 0 subdirectories itself)
    const img_path = sub_leaf ++ "/photo.png";
    try state.image_list.append(allocator, img_path);
    state.current_index = 0;

    // openPalette should see sub_leaf has 0 subdirectories, so it steps up to tmp_dir and pre-selects child_leaf
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(tmp_dir, state.palette.current_nav_dir.items);

    // Verify child_leaf is selected
    var found_leaf_selected = false;
    if (state.palette.selected_idx < state.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.palette.dir_items.items[state.palette.selected_idx].name, "child_leaf")) {
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
        .directory_arena = std.heap.ArenaAllocator.init(allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .palette = PaletteState.init(allocator),
        .rotation_map = std.StringHashMap(f32).init(allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    const img_path = top_leaf ++ "/photo.png";
    try state.image_list.append(allocator, img_path);
    state.current_index = 0;

    try state.openPalette(.directory_navigator);
    // Should step up to "." because top_leaf has 0 subdirectories
    try std.testing.expectEqualStrings(".", state.palette.current_nav_dir.items);

    // Verify top_leaf is pre-selected in "."
    var found_leaf_selected = false;
    if (state.palette.selected_idx < state.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.palette.dir_items.items[state.palette.selected_idx].name, top_leaf)) {
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
        .directory_arena = std.heap.ArenaAllocator.init(allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .palette = PaletteState.init(allocator),
        .rotation_map = std.StringHashMap(f32).init(allocator),
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
        .keys_pressed = std.ArrayList(types.Key).empty,
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
        .keys_pressed = std.ArrayList(types.Key).empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };
    try std.testing.expect(!state.isPointerInDebugPanel(input_outside));

    state.palette.mode = .actions;
    try state.update(input_inside);
    try std.testing.expect(state.palette.mode == .actions);
}

test "ViewerState slideshow timer auto-advances slide" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = ViewerState{
        .directory_arena = std.heap.ArenaAllocator.init(allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .palette = PaletteState.init(allocator),
        .rotation_map = std.StringHashMap(f32).init(allocator),
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    try state.image_list.append(allocator, "img1.jpg");
    try state.image_list.append(allocator, "img2.jpg");
    state.current_index = 0;
    state.slideshow = .{ .active = .{ .interval_s = 2.0 } };

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
        .keys_pressed = std.ArrayList(types.Key).empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 1000.0,
    };

    try state.update(frame_input_1s);
    try std.testing.expectEqual(@as(usize, 0), state.current_index.?);

    // Pass another second (total 2000ms >= 2.0s interval) -> advances to index 1
    try state.update(frame_input_1s);
    try std.testing.expectEqual(@as(usize, 1), state.current_index.?);
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
