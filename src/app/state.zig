const std = @import("std");
const sdl = @import("../sdl/root.zig");
const clay = @import("zclay");
const FrameInput = @import("types.zig").FrameInput;
const app_input = @import("input.zig");
const renderer = @import("../ui/renderer.zig");
const commands = @import("../commands.zig");
const graphics = @import("../ui/graphics.zig");
pub const image = @import("image.zig");
pub const fs = @import("fs.zig");
pub const events = @import("events.zig");
pub const pipeline = @import("pipeline.zig");
pub const ipc = @import("ipc.zig");

pub const CacheStatus = image.CacheStatus;
pub const CacheEntry = image.CacheEntry;
pub const CacheSlotMap = image.CacheSlotMap;
pub const TextureHandle = image.TextureHandle;
pub const DecodeArgs = image.DecodeArgs;
pub const detectMimeType = image.detectMimeType;
pub const parseExifOrientation = image.parseExifOrientation;
pub const readJpegExifOrientation = image.readJpegExifOrientation;
pub const eqlIgnoreCase = fs.eqlIgnoreCase;
pub const isImageExtension = fs.isImageExtension;
pub const scanDirectory = fs.scanDirectory;
pub const uploadSurfaceToGpu = graphics.uploadSurfaceToGpu;
pub const GpuUploadResult = graphics.GpuUploadResult;

pub const ScaleMode = enum {
    none,
    shrink,
    full,
    crop,
};

pub const TextureScaleMode = enum {
    nearest,
    linear,
    pixel_art,
    mitchell,
    lanczos3,
};

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

pub const PaletteMode = enum {
    inactive,
    files,
    actions,
    set_brightness,
    set_contrast,
    go_to_image,
};

pub const DragState = union(enum) {
    none,
    viewport: struct {
        last_x: f32,
        last_y: f32,
    },
    stats: struct {
        start_x: f32,
        start_y: f32,
    },
};

pub const TextCacheKey = struct {
    font_id: usize,
    font_size: u16,
    color: u32,
    hash: u64,
};

pub const TextCacheValue = struct {
    texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    last_used_frame: usize,
};

pub const PaletteState = struct {
    mode: PaletteMode = .inactive,
    query: std.ArrayList(u8),
    selected_idx: usize = 0,
    selection_dirty: bool = false,
    matches: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PaletteState {
        return .{
            .query = std.ArrayList(u8).empty,
            .matches = std.ArrayList(usize).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PaletteState) void {
        self.query.deinit(self.allocator);
        self.matches.deinit(self.allocator);
    }

    pub fn reset(self: *PaletteState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.mode = .inactive;
        self.selected_idx = 0;
        self.selection_dirty = true;
    }
};

pub fn startTextInput(window: ?sdl.Window) void {
    if (window) |win| {
        if (!win.startTextInput()) {
            std.log.err("SDL_StartTextInput failed: {s}", .{sdl.getError()});
        }
    }
}

pub fn stopTextInput(window: ?sdl.Window) void {
    if (window) |win| {
        if (!win.stopTextInput()) {
            std.log.err("SDL_StopTextInput failed: {s}", .{sdl.getError()});
        }
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

pub const ViewerState = struct {
    gpu_device: ?sdl.gpu.Device = null,
    gpu_pipeline: ?sdl.gpu.Pipeline = null,
    gpu_sampler: ?sdl.gpu.Sampler = null,
    white_texture: ?sdl.gpu.Texture = null,

    /// Thread Safety: directory_arena allocations must only occur while holding image_list_mutex.
    directory_arena: std.heap.ArenaAllocator,
    image_list: std.ArrayList([]const u8),
    image_list_mutex: std.Io.Mutex = .init,
    is_loading_files: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    current_index: ?usize = null,
    cache: CacheSlotMap,
    cache_mutex: std.Io.Mutex = .init,
    current_image_cache_hit: bool = false,
    allocator: std.mem.Allocator,
    io: std.Io,
    active_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_decode_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    exiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    window_pixel_format: u32 = sdl.PixelFormat.unknown,
    palette: PaletteState,
    window: ?sdl.Window,
    is_fullscreen: bool = false,
    running: bool = true,
    show_stats_overlay: bool = false,
    debug_show_thumb: bool = false,
    window_claimed: bool = false,
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
    stats_offset_x: f32 = 20.0,
    stats_offset_y: f32 = 20.0,
    drag_state: DragState = .none,
    mouse_inside: bool = true,
    last_nav_time_ms: u64 = 0,
    event_queue: events.MpscQueue(events.BackgroundEvent) = .{},
    pending_ipc_commands: std.ArrayListUnmanaged(*ipc.IpcCommandData) = .empty,

    // Persistent double-buffered vertex resources
    gpu_vertex_buffers: [2]?sdl.gpu.Buffer = .{ null, null },
    gpu_transfer_buffers: [2]?sdl.gpu.TransferBuffer = .{ null, null },
    gpu_buffer_capacities: [2]usize = .{ 0, 0 },
    gpu_frame_index: usize = 0,

    // Font text texture cache
    text_cache: std.AutoHashMapUnmanaged(TextCacheKey, TextCacheValue) = .empty,

    pub fn readJpegExifOrientation(self: *const ViewerState, path: []const u8) ?f32 {
        return image.readJpegExifOrientation(self.io, path);
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

        const full_dims = image.readJpegDimensions(header_buf[0..n]);
        const thumb_bytes = image.extractJpegThumbnail(header_buf[0..n]) orelse return;
        const thumb_surf = sdl.Surface.loadConstMemOpt(thumb_bytes) orelse return;
        defer thumb_surf.destroy();

        const gpu_dev = self.gpu_device orelse return;
        const upload_res = graphics.uploadSurfaceToGpu(gpu_dev, thumb_surf) orelse return;

        self.lockCache();
        defer self.unlockCache();

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

            var text_iter = self.text_cache.valueIterator();
            while (text_iter.next()) |val| {
                dev.releaseTexture(val.texture);
            }

            if (self.gpu_pipeline) |pipe| dev.releasePipeline(pipe);
            if (self.gpu_sampler) |samp| dev.releaseSampler(samp);
            if (self.white_texture) |tex| dev.releaseTexture(tex);
            if (self.window_claimed) {
                if (self.window) |w| w.releaseFromGpu(dev);
            }
        }

        for (self.pending_ipc_commands.items) |cmd_data| {
            self.allocator.free(cmd_data.command);
            self.allocator.destroy(cmd_data);
        }
        self.pending_ipc_commands.deinit(self.allocator);
        self.event_queue.deinit(self.allocator, self.io);
        self.text_cache.deinit(self.allocator);
        self.image_list.deinit(self.allocator);
        self.cache.deinit(self.allocator, self.gpu_device);
        self.palette.deinit();
        self.rotation_map.deinit();
        self.directory_arena.deinit();
    }

    pub fn lockCache(self: *ViewerState) void {
        self.cache_mutex.lockUncancelable(self.io);
    }

    pub fn unlockCache(self: *ViewerState) void {
        self.cache_mutex.unlock(self.io);
    }

    pub fn lockImageList(self: *ViewerState) void {
        self.image_list_mutex.lockUncancelable(self.io);
    }

    pub fn unlockImageList(self: *ViewerState) void {
        self.image_list_mutex.unlock(self.io);
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

        const angle = self.rotation_angle;
        const is_90_or_270 = (std.math.approxEqAbs(f32, angle, 90.0, 0.1) or
            std.math.approxEqAbs(f32, angle, 270.0, 0.1) or
            std.math.approxEqAbs(f32, angle, -90.0, 0.1) or
            std.math.approxEqAbs(f32, angle, -270.0, 0.1));
        const img_w = if (is_90_or_270) raw_h else raw_w;
        const img_h = if (is_90_or_270) raw_w else raw_h;

        var pix_w: i32 = 1024;
        var pix_h: i32 = 768;
        if (self.window) |win| {
            const pix_size = win.getSizeInPixels();
            if (pix_size.w > 0 and pix_size.h > 0) {
                pix_w = pix_size.w;
                pix_h = pix_size.h;
            }
        }

        const title_bar_h: f32 = if (self.is_fullscreen) 0.0 else 60.0;
        var scale_y: f32 = 1.0;
        if (self.window) |win| {
            const win_size = win.getSize();
            if (win_size.h > 0) {
                scale_y = @as(f32, @floatFromInt(pix_h)) / @as(f32, @floatFromInt(win_size.h));
            }
        }

        var available_width = @as(f32, @floatFromInt(pix_w));
        if (clay.isDebugModeEnabled()) {
            available_width = @max(available_width - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0);
        }
        const view_w = @max(available_width, 1.0);
        const view_h = @max(@as(f32, @floatFromInt(pix_h)) - title_bar_h * scale_y, 1.0);

        const r_img = img_w / img_h;
        const r_view = view_w / view_h;

        var draw_w: f32 = img_w;
        switch (self.scale_mode) {
            .none => {
                draw_w = img_w;
            },
            .shrink => {
                if (img_w <= view_w and img_h <= view_h) {
                    draw_w = img_w;
                } else {
                    if (r_img > r_view) {
                        draw_w = view_w;
                    } else {
                        draw_w = view_h * r_img;
                    }
                }
            },
            .full => {
                if (r_img > r_view) {
                    draw_w = view_w;
                } else {
                    draw_w = view_h * r_img;
                }
            },
            .crop => {
                if (r_img > r_view) {
                    draw_w = view_h * r_img;
                } else {
                    draw_w = view_w;
                }
            },
        }

        return draw_w / img_w;
    }

    pub fn clampZoomFactor(self: *ViewerState, new_factor: f32) f32 {
        const base_scale = self.getBaseScale();
        const min_factor = if (base_scale > 0.0) 0.1 / base_scale else 0.1;
        const max_factor = if (base_scale > 0.0) 10.0 / base_scale else 10.0;
        return std.math.clamp(new_factor, min_factor, max_factor);
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
        self.lockImageList();
        defer self.unlockImageList();

        self.palette.matches.clearRetainingCapacity();
        const query = self.palette.query.items;
        if (query.len == 0) {
            for (self.image_list.items, 0..) |_, real_idx| {
                try self.palette.matches.append(self.allocator, real_idx);
            }
            return;
        }

        for (self.image_list.items, 0..) |item_path, real_idx| {
            const basename = std.fs.path.basename(item_path);
            if (fs.containsIgnoreCase(basename, query)) {
                try self.palette.matches.append(self.allocator, real_idx);
            }
        }
    }

    pub fn rebuildActionMatches(self: *ViewerState) !void {
        self.palette.matches.clearRetainingCapacity();
        const query = self.palette.query.items;
        if (query.len == 0) {
            for (commands.actions.app_actions, 0..) |_, idx| {
                try self.palette.matches.append(self.allocator, idx);
            }
            return;
        }

        var stack_query_lower: [256]u8 = undefined;
        const query_lower = if (query.len <= stack_query_lower.len) blk: {
            for (query, 0..) |c_val, idx| {
                stack_query_lower[idx] = std.ascii.toLower(c_val);
            }
            break :blk stack_query_lower[0..query.len];
        } else blk: {
            const buf = try self.allocator.alloc(u8, query.len);
            for (query, 0..) |c_val, idx| {
                buf[idx] = std.ascii.toLower(c_val);
            }
            break :blk buf;
        };
        defer if (query.len > stack_query_lower.len) self.allocator.free(query_lower);

        for (commands.actions.app_actions, 0..) |action_id, idx| {
            const meta = commands.actions.getActionMetadata(action_id);
            if (matchesQueryLower(meta.name, query_lower)) {
                try self.palette.matches.append(self.allocator, idx);
            }
        }
    }

    pub fn triggerAction(self: *ViewerState, action_id: commands.actions.AppActionId) !void {
        try commands.actions.triggerAction(self, action_id);
    }

    pub fn getCurrentEntry(self: *ViewerState) ?CacheEntry {
        self.lockCache();
        defer self.unlockCache();

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
            else => {},
        }

        startTextInput(self.window);
    }

    pub fn prepareCacheTextures(self: *ViewerState) void {
        self.lockCache();

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

        self.unlockCache();

        if (upload_target) |target| {
            defer target.cpu.surface.destroy();
            if (self.gpu_device) |gpu_dev| {
                if (uploadSurfaceToGpu(gpu_dev, target.cpu.surface)) |res| {
                    self.lockCache();
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
                    self.unlockCache();

                    if (!updated) {
                        gpu_dev.releaseTexture(res.gpu_texture);
                    }
                } else {
                    self.lockCache();
                    _ = self.cache.updateStatus(target.index, target.generation, .failed);
                    self.unlockCache();
                }
            }
        }
        if (self.adjustments_dirty) {
            self.adjustments_dirty = false;
        }
    }

    pub fn clearCache(self: *ViewerState) void {
        self.lockCache();
        defer self.unlockCache();

        self.cache.clear(self.gpu_device);
    }

    pub fn checkIdlePreload(self: *ViewerState) void {
        if (self.image_list.items.len <= 1) return;
        const now = sdl.timer.getTicks();
        if (now - self.last_nav_time_ms >= 150) {
            self.lockCache();
            const entry_count = self.cache.entries.items.len;
            self.unlockCache();
            if (entry_count <= 1) {
                self.updateCache() catch |err| std.log.warn("Idle preload updateCache failed: {}", .{err});
            }
        }
    }

    pub fn updateCurrentRotation(self: *ViewerState) void {
        const path_opt = blk: {
            self.lockImageList();
            defer self.unlockImageList();
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
                    self.lockCache();
                    if (self.cache.getWithGeneration(e.index, e.generation)) |entry| {
                        entry.exif_orientation = e.orientation;
                    }
                    self.unlockCache();
                    self.updateCurrentRotation();
                },
                .thumb_decoded => |t| {
                    if (t.generation != current_gen) continue;
                    if (t.surface == null) continue;
                    if (self.gpu_device) |gpu_dev| {
                        if (graphics.uploadSurfaceToGpu(gpu_dev, t.surface.?)) |upload_res| {
                            self.lockCache();
                            if (self.cache.getWithGeneration(t.index, t.generation)) |entry| {
                                entry.thumb_gpu_texture = upload_res.gpu_texture;
                                entry.thumb_w = upload_res.w;
                                entry.thumb_h = upload_res.h;
                                entry.exif_orientation = t.exif_orientation;
                                if (t.full_w > 0 and t.full_h > 0) {
                                    entry.full_w = t.full_w;
                                    entry.full_h = t.full_h;
                                }
                                entry.has_thumb = true;
                                entry.thumb_upload_time_ms = upload_res.upload_time_ms;
                            } else {
                                gpu_dev.releaseTexture(upload_res.gpu_texture);
                            }
                            self.unlockCache();
                            self.updateCurrentRotation();
                        }
                    }
                },
                .image_decoded => |*d| {
                    if (d.generation != current_gen) continue;
                    if (d.surface == null) continue;
                    if (self.gpu_device) |gpu_dev| {
                        if (graphics.uploadSurfaceToGpu(gpu_dev, d.surface.?)) |full_res| {
                            self.lockCache();
                            if (self.cache.getWithGeneration(d.index, d.generation)) |entry| {
                                switch (entry.status) {
                                    .loaded_cpu => |cpu| cpu.surface.destroy(),
                                    .loaded_gpu => |gpu| gpu_dev.releaseTexture(gpu.gpu_texture),
                                    else => {},
                                }
                                entry.exif_orientation = d.exif_orientation;
                                entry.status = .{
                                    .loaded_gpu = .{
                                        .gpu_texture = full_res.gpu_texture,
                                        .w = d.w,
                                        .h = d.h,
                                        .size_bytes = d.size_bytes,
                                        .mime_type = d.mime_type,
                                        .decode_time_ms = d.decode_time_ms,
                                        .conversion_time_ms = d.conversion_time_ms,
                                        .upload_time_ms = full_res.upload_time_ms,
                                        .memory_size_bytes = full_res.memory_size_bytes,
                                        .num_mip_levels = full_res.num_mip_levels,
                                        .mipmap_time_ms = full_res.mipmap_time_ms,
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
                            self.unlockCache();
                            self.updateCurrentRotation();
                        }
                    } else {
                        self.lockCache();
                        if (self.cache.getWithGeneration(d.index, d.generation)) |entry| {
                            entry.exif_orientation = d.exif_orientation;
                            entry.status = .{
                                .loaded_cpu = .{
                                    .surface = d.surface.?,
                                    .w = d.w,
                                    .h = d.h,
                                    .size_bytes = d.size_bytes,
                                    .mime_type = d.mime_type,
                                    .decode_time_ms = d.decode_time_ms,
                                    .conversion_time_ms = d.conversion_time_ms,
                                    .has_thumb = entry.has_thumb,
                                    .thumb_w = entry.thumb_w,
                                    .thumb_h = entry.thumb_h,
                                    .thumb_upload_time_ms = entry.thumb_upload_time_ms,
                                },
                            };
                            d.surface = null; // Transfer ownership to CacheEntry
                        }
                        self.unlockCache();
                        self.updateCurrentRotation();
                    }
                },
                .decode_failed => |f| {
                    if (f.generation != current_gen) continue;
                    self.lockCache();
                    _ = self.cache.updateStatus(f.index, f.generation, .failed);
                    self.unlockCache();
                },
                .path_discovered => |p| {
                    if (p.generation != current_gen) continue;
                    self.lockImageList();
                    const dup = self.directory_arena.allocator().dupe(u8, p.path) catch {
                        self.unlockImageList();
                        continue;
                    };
                    self.image_list.append(self.allocator, dup) catch |err| std.log.err("Failed to append discovered path to image_list: {}", .{err});
                    if (self.current_index == null and self.image_list.items.len > 0) {
                        self.current_index = 0;
                    }
                    self.unlockImageList();
                },
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

        self.lockImageList();
        const len = self.image_list.items.len;
        self.unlockImageList();

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

        {
            self.lockCache();
            defer self.unlockCache();

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
        }

        // 4. Batch-fetch file paths under a single image_list_mutex lock
        var to_spawn_paths: [5]?[:0]const u8 = undefined;
        {
            self.lockImageList();
            defer self.unlockImageList();
            for (to_spawn_indices[0..to_spawn_count], 0..) |d, s_idx| {
                if (d < self.image_list.items.len) {
                    to_spawn_paths[s_idx] = self.allocator.dupeZ(u8, self.image_list.items[d]) catch null;
                } else {
                    to_spawn_paths[s_idx] = null;
                }
            }
        }

        // 5. Spawn worker threads outside cache_mutex lock
        const max_decodes = getMaxConcurrentDecodes();
        for (to_spawn_indices[0..to_spawn_count], 0..) |d, s_idx| {
            const path_opt = to_spawn_paths[s_idx];
            if (path_opt == null or self.active_decode_threads.load(.acquire) >= max_decodes) {
                if (path_opt) |p| self.allocator.free(p);
                if (d != idx) {
                    self.lockCache();
                    var k: usize = 0;
                    while (k < self.cache.entries.items.len) : (k += 1) {
                        if (self.cache.entries.items[k].index == d) {
                            self.cache.removeAndDeinit(k, self.gpu_device);
                            break;
                        }
                    }
                    self.unlockCache();
                }
                continue;
            }

            const dup_path = path_opt.?;

            const args = self.allocator.create(DecodeArgs) catch |err| {
                self.allocator.free(dup_path);
                for (to_spawn_paths[s_idx + 1 .. to_spawn_count]) |rem_path_opt| {
                    if (rem_path_opt) |rp| self.allocator.free(rp);
                }
                self.lockCache();
                var k: usize = 0;
                while (k < self.cache.entries.items.len) : (k += 1) {
                    if (self.cache.entries.items[k].index == d) {
                        self.cache.removeAndDeinit(k, self.gpu_device);
                        break;
                    }
                }
                self.unlockCache();
                return err;
            };

            self.lockCache();
            if (self.cache.get(d)) |entry| {
                if (entry.status == .decoding) {
                    entry.status.decoding.has_thread = true;
                }
            }
            self.unlockCache();

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
        self.lockImageList();
        const len = self.image_list.items.len;
        self.unlockImageList();

        if (len == 0) return;
        if (self.current_index) |idx| {
            self.current_index = (idx + 1) % len;
        } else {
            self.current_index = 0;
        }
        try self.updateCache();
    }

    pub fn prev(self: *ViewerState) !void {
        self.lockImageList();
        const len = self.image_list.items.len;
        self.unlockImageList();

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

        self.lockImageList();
        // Clear existing cache and rotation map before resetting directory_arena
        _ = self.generation.fetchAdd(1, .release);
        self.clearCache();
        self.rotation_map.clearRetainingCapacity();
        self.image_list.clearRetainingCapacity();
        _ = self.directory_arena.reset(.retain_capacity);
        self.current_index = null;
        self.unlockImageList();

        if (has_stat) {
            if (stat.kind == .directory) {
                try fs.startAsyncPathScan(self, path, true);
            } else {
                self.lockImageList();
                const dup = try self.directory_arena.allocator().dupe(u8, path);
                try self.image_list.append(self.allocator, dup);
                self.current_index = 0;
                self.unlockImageList();

                try self.updateCache();

                try fs.startAsyncPathScan(self, path, false);
            }
        }
        try self.rebuildPaletteMatches();
    }

    pub fn update(self: *ViewerState, input: FrameInput) !void {
        self.updateCurrentRotation();

        // 1. Text input updates
        if (input.text_input) |text| {
            if (self.palette.mode != .inactive) {
                try self.palette.query.appendSlice(self.allocator, text);
                self.palette.selected_idx = 0;
                self.palette.selection_dirty = true;
                switch (self.palette.mode) {
                    .files => try self.rebuildPaletteMatches(),
                    .actions => try self.rebuildActionMatches(),
                    else => {},
                }
            }
        }

        // 2. Drop file/directory updates
        if (input.dropped_path) |path| {
            try self.handlePathSelection(path);
        }

        // 3. Mouse dragging updates
        var next_drag_state = self.drag_state;
        switch (next_drag_state) {
            .none => {},
            .stats => |stats| {
                if (input.mouse_left_down) {
                    self.stats_offset_x = (input.mouse_x - stats.start_x) / input.dpi_scale;
                    self.stats_offset_y = (input.mouse_y - stats.start_y) / input.dpi_scale;
                } else {
                    next_drag_state = .none;
                }
            },
            .viewport => |*vp| {
                if (input.mouse_left_down) {
                    self.pan_x += input.mouse_x - vp.last_x;
                    self.pan_y += input.mouse_y - vp.last_y;
                    vp.last_x = input.mouse_x;
                    vp.last_y = input.mouse_y;
                } else {
                    next_drag_state = .none;
                }
            },
        }
        self.drag_state = next_drag_state;

        // 4. Mouse click triggers (starts dragging)
        if (input.mouse_left_clicked) {
            var palette_closed_this_frame = false;
            // Check if we should close the palette
            if (self.palette.mode != .inactive) {
                const element_id = switch (self.palette.mode) {
                    .files => "CommandPalette",
                    .actions => "ActionPalette",
                    .set_brightness => "BrightnessPalette",
                    .set_contrast => "ContrastPalette",
                    .go_to_image => "GoToImagePalette",
                    .inactive => unreachable,
                };
                if (!clay.pointerOver(clay.getElementId(element_id))) {
                    self.palette.mode = .inactive;
                    stopTextInput(self.window);
                    palette_closed_this_frame = true;
                }
            }

            if (self.show_stats_overlay and
                clay.pointerOver(clay.getElementId("StatsPanel")) and
                !clay.pointerOver(clay.getElementId("StatsCloseBtn")))
            {
                self.drag_state = .{
                    .stats = .{
                        .start_x = input.mouse_x - self.stats_offset_x * input.dpi_scale,
                        .start_y = input.mouse_y - self.stats_offset_y * input.dpi_scale,
                    },
                };
            } else if (self.palette.mode == .inactive and !palette_closed_this_frame and clay.pointerOver(clay.getElementId("Viewport"))) {
                self.drag_state = .{
                    .viewport = .{
                        .last_x = input.mouse_x,
                        .last_y = input.mouse_y,
                    },
                };
            }
        }

        // 5. Mouse Wheel Zoom updates
        if (input.scroll_delta_y != 0) {
            if (self.palette.mode == .inactive and clay.pointerOver(clay.getElementId("Viewport"))) {
                const old_zoom = self.zoom_factor;
                self.zoom_factor = self.clampZoomFactor(self.zoom_factor + input.scroll_delta_y * 0.1);

                const available_width = if (clay.isDebugModeEnabled()) @max(input.pix_w - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0) else input.pix_w;
                const cx = available_width / 2.0;
                var title_bar_h: f32 = 60.0;
                if (self.is_fullscreen) {
                    title_bar_h = 0;
                }
                const cy = (title_bar_h * input.scale_y) + ((input.pix_h - title_bar_h * input.scale_y) / 2.0);

                const rel_x = input.mouse_x - cx;
                const rel_y = input.mouse_y - cy;

                self.pan_x = rel_x - (rel_x - self.pan_x) * (self.zoom_factor / old_zoom);
                self.pan_y = rel_y - (rel_y - self.pan_y) * (self.zoom_factor / old_zoom);
            }
        }

        // 6. Keyboard updates
        for (input.keys_pressed.items) |key| {
            try app_input.handleKeyDown(self, key, input.key_modifiers, input.scale_x, input.scale_y);
        }
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

test "ViewerState.clampZoomFactor bounds based on image dimensions" {
    const clay_memory = try std.testing.allocator.alloc(u8, clay.minMemorySize());
    defer std.testing.allocator.free(clay_memory);
    _ = clay.initialize(clay.Arena.init(clay_memory), .{ .w = 1024, .h = 768 }, .{});

    var state = ViewerState{
        .directory_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .image_list_mutex = .init,
        .cache = .{},
        .cache_mutex = .init,
        .allocator = std.testing.allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .palette = PaletteState.init(std.testing.allocator),
        .rotation_map = std.StringHashMap(f32).init(std.testing.allocator),
        .scale_mode = .none,
        .window = null,
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
        .image_list_mutex = .init,
        .cache = .{},
        .cache_mutex = .init,
        .allocator = std.testing.allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .palette = PaletteState.init(std.testing.allocator),
        .rotation_map = std.StringHashMap(f32).init(std.testing.allocator),
        .window = null,
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
