const std = @import("std");
const c = @import("c.zig").c;
const clay = @import("zclay");
const FrameInput = @import("types.zig").FrameInput;
const app_input = @import("input.zig");
const renderer = @import("../ui/renderer.zig");
const commands = @import("../commands.zig");
const graphics = @import("../ui/graphics.zig");
pub const image = @import("image.zig");
pub const fs = @import("fs.zig");

pub const CacheStatus = image.CacheStatus;
pub const CacheEntry = image.CacheEntry;
pub const CacheSlotMap = image.CacheSlotMap;
pub const TextureHandle = image.TextureHandle;
pub const DecodeArgs = image.DecodeArgs;
pub const detectMimeType = image.detectMimeType;
pub const decodeWorker = image.decodeWorker;
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
    texture: *c.SDL_GPUTexture,
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

pub fn startTextInput(window: ?*c.SDL_Window) void {
    if (window) |win| {
        if (!c.SDL_StartTextInput(win)) {
            std.log.err("SDL_StartTextInput failed: {s}", .{c.SDL_GetError()});
        }
    }
}

pub fn stopTextInput(window: ?*c.SDL_Window) void {
    if (window) |win| {
        if (!c.SDL_StopTextInput(win)) {
            std.log.err("SDL_StopTextInput failed: {s}", .{c.SDL_GetError()});
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
    gpu_device: ?*c.SDL_GPUDevice = null,
    gpu_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    gpu_sampler: ?*c.SDL_GPUSampler = null,
    white_texture: ?*c.SDL_GPUTexture = null,

    directory_arena: std.heap.ArenaAllocator,
    image_list: std.ArrayList([]const u8),
    current_index: ?usize = null,
    cache: CacheSlotMap,
    cache_mutex: *c.SDL_Mutex,
    current_image_cache_hit: bool = false,
    allocator: std.mem.Allocator,
    io: std.Io,
    active_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    exiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: usize = 0,
    window_pixel_format: c.SDL_PixelFormat = c.SDL_PIXELFORMAT_UNKNOWN,
    palette: PaletteState,
    window: ?*c.SDL_Window,
    is_fullscreen: bool = false,
    running: bool = true,
    show_stats_overlay: bool = false,
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

    // Persistent double-buffered vertex resources
    gpu_vertex_buffers: [2]?*c.SDL_GPUBuffer = .{ null, null },
    gpu_transfer_buffers: [2]?*c.SDL_GPUTransferBuffer = .{ null, null },
    gpu_buffer_capacities: [2]usize = .{ 0, 0 },
    gpu_frame_index: usize = 0,

    // Font text texture cache
    text_cache: std.AutoHashMapUnmanaged(TextCacheKey, TextCacheValue) = .empty,

    pub fn deinit(self: *ViewerState) void {
        self.exiting.store(true, .release);
        while (self.active_threads.load(.acquire) > 0) {
            c.SDL_Delay(1);
        }

        self.clearCache();

        if (self.gpu_device) |gpu_dev| {
            for (self.gpu_vertex_buffers) |vb| {
                if (vb) |b| c.SDL_ReleaseGPUBuffer(gpu_dev, b);
            }
            for (self.gpu_transfer_buffers) |tb| {
                if (tb) |b| c.SDL_ReleaseGPUTransferBuffer(gpu_dev, b);
            }

            var text_iter = self.text_cache.valueIterator();
            while (text_iter.next()) |val| {
                c.SDL_ReleaseGPUTexture(gpu_dev, val.texture);
            }

            if (self.gpu_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(gpu_dev, pipeline);
            if (self.gpu_sampler) |sampler| c.SDL_ReleaseGPUSampler(gpu_dev, sampler);
            if (self.white_texture) |white_tex| c.SDL_ReleaseGPUTexture(gpu_dev, white_tex);
            if (self.window_claimed) {
                if (self.window) |w| c.SDL_ReleaseWindowFromGPUDevice(gpu_dev, w);
            }
        }

        self.text_cache.deinit(self.allocator);
        c.SDL_DestroyMutex(self.cache_mutex);
        self.image_list.deinit(self.allocator);
        self.cache.deinit(self.allocator, self.gpu_device);
        self.palette.deinit();
        self.rotation_map.deinit();
        self.directory_arena.deinit();
    }

    pub fn resetZoomPan(self: *ViewerState) void {
        self.zoom_factor = 1.0;
        self.pan_x = 0.0;
        self.pan_y = 0.0;
    }

    pub fn getTextureByHandle(self: *ViewerState, handle: TextureHandle) ?*c.SDL_GPUTexture {
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);
        return self.cache.getTexture(handle);
    }

    pub fn applyTextureScaleMode(self: *ViewerState) void {
        const filter = if (self.texture_scale_mode == .linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST;
        if (self.gpu_sampler) |old_sampler| {
            c.SDL_ReleaseGPUSampler(self.gpu_device, old_sampler);
        }

        const sampler_info = c.SDL_GPUSamplerCreateInfo{
            .min_filter = @intCast(filter),
            .mag_filter = @intCast(filter),
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 1.0,
            .compare_op = c.SDL_GPU_COMPAREOP_NEVER,
            .min_lod = 0.0,
            .max_lod = 1000.0,
            .props = 0,
        };
        self.gpu_sampler = c.SDL_CreateGPUSampler(self.gpu_device, &sampler_info) orelse {
            std.log.err("Failed to recreate GPU sampler: {s}", .{c.SDL_GetError()});
            return;
        };
    }

    pub fn rebuildPaletteMatches(self: *ViewerState) !void {
        self.palette.matches.clearRetainingCapacity();
        const query = self.palette.query.items;
        if (query.len == 0) {
            for (self.image_list.items, 0..) |_, real_idx| {
                try self.palette.matches.append(self.allocator, real_idx);
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

        for (self.image_list.items, 0..) |item, real_idx| {
            if (matchesQueryLower(item, query_lower)) {
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
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);

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
        c.SDL_LockMutex(self.cache_mutex);

        var upload_target: ?struct {
            index: usize,
            generation: usize,
            cpu: @TypeOf(@as(CacheStatus, undefined).loaded_cpu),
        } = null;

        for (self.cache.entries.items) |*entry| {
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

        c.SDL_UnlockMutex(self.cache_mutex);

        if (upload_target) |target| {
            defer c.SDL_DestroySurface(target.cpu.surface);
            if (self.gpu_device) |gpu_dev| {
                if (uploadSurfaceToGpu(gpu_dev, target.cpu.surface)) |res| {
                    c.SDL_LockMutex(self.cache_mutex);
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
                    c.SDL_UnlockMutex(self.cache_mutex);

                    if (!updated) {
                        c.SDL_ReleaseGPUTexture(gpu_dev, res.gpu_texture);
                    }
                } else {
                    c.SDL_LockMutex(self.cache_mutex);
                    _ = self.cache.updateStatus(target.index, target.generation, .failed);
                    c.SDL_UnlockMutex(self.cache_mutex);
                }
            }
        }
        if (self.adjustments_dirty) {
            self.adjustments_dirty = false;
        }
    }

    pub fn clearCache(self: *ViewerState) void {
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);

        self.cache.clear(self.gpu_device);
    }

    pub fn updateCache(self: *ViewerState) !void {
        self.resetZoomPan();
        const current_idx = self.current_index;
        if (current_idx != null and current_idx.? < self.image_list.items.len) {
            const path = self.image_list.items[current_idx.?];
            self.rotation_angle = self.rotation_map.get(path) orelse 0.0;
        } else {
            self.rotation_angle = 0.0;
        }

        const len = self.image_list.items.len;
        if (len == 0) return;

        const idx = self.current_index orelse return;

        // 1. Gather desired indices
        var desired_count: usize = 0;
        var desired: [5]usize = undefined;
        for ([_]usize{
            idx,
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

        var to_spawn_count: usize = 0;
        var to_spawn_indices: [5]usize = undefined;
        var hit = false;

        {
            c.SDL_LockMutex(self.cache_mutex);
            defer c.SDL_UnlockMutex(self.cache_mutex);

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
                    switch (entry.status) {
                        .loaded_cpu => |cpu| c.SDL_DestroySurface(cpu.surface),
                        .loaded_gpu => |gpu| c.SDL_ReleaseGPUTexture(self.gpu_device, gpu.gpu_texture),
                        else => {},
                    }
                    _ = self.cache.remove(i);
                } else {
                    i += 1;
                }
            }

            // 3. Mark wanted entries that are not in the cache yet as .decoding
            for (desired[0..desired_count]) |d| {
                var exists = false;
                if (self.cache.get(d)) |entry| {
                    exists = true;
                    if (d == idx and (entry.status == .loaded_cpu or entry.status == .loaded_gpu)) {
                        hit = true;
                    }
                }
                if (!exists) {
                    const new_entry = CacheEntry{
                        .index = d,
                        .generation = self.generation,
                        .status = .decoding,
                    };
                    try self.cache.append(self.allocator, new_entry);
                    to_spawn_indices[to_spawn_count] = d;
                    to_spawn_count += 1;
                }
            }
            self.current_image_cache_hit = hit;
        }

        // 4. Spawn worker threads outside cache_mutex lock
        for (to_spawn_indices[0..to_spawn_count]) |d| {
            const path = self.allocator.dupeZ(u8, self.image_list.items[d]) catch |err| {
                c.SDL_LockMutex(self.cache_mutex);
                var k: usize = 0;
                while (k < self.cache.entries.items.len) : (k += 1) {
                    if (self.cache.entries.items[k].index == d) {
                        _ = self.cache.remove(k);
                        break;
                    }
                }
                c.SDL_UnlockMutex(self.cache_mutex);
                return err;
            };
            errdefer self.allocator.free(path);

            const args = self.allocator.create(DecodeArgs) catch |err| {
                self.allocator.free(path);
                c.SDL_LockMutex(self.cache_mutex);
                var k: usize = 0;
                while (k < self.cache.entries.items.len) : (k += 1) {
                    if (self.cache.entries.items[k].index == d) {
                        _ = self.cache.remove(k);
                        break;
                    }
                }
                c.SDL_UnlockMutex(self.cache_mutex);
                return err;
            };
            errdefer self.allocator.destroy(args);

            args.* = DecodeArgs{
                .state = self,
                .index = d,
                .generation = self.generation,
                .path = path,
            };

            _ = self.active_threads.fetchAdd(1, .monotonic);
            const thread = c.SDL_CreateThread(decodeWorker, "decode_worker", args);
            if (thread) |t| {
                c.SDL_DetachThread(t);
            } else {
                std.log.err("Failed to create SDL thread: {s}", .{c.SDL_GetError()});
                _ = self.active_threads.fetchSub(1, .monotonic);
                self.allocator.free(path);
                self.allocator.destroy(args);

                c.SDL_LockMutex(self.cache_mutex);
                defer c.SDL_UnlockMutex(self.cache_mutex);
                if (self.cache.get(d)) |entry| {
                    if (entry.status == .decoding) {
                        var k: usize = 0;
                        while (k < self.cache.entries.items.len) : (k += 1) {
                            if (self.cache.entries.items[k].index == d) {
                                _ = self.cache.remove(k);
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn next(self: *ViewerState) !void {
        if (self.image_list.items.len == 0) return;
        if (self.current_index) |idx| {
            self.current_index = (idx + 1) % self.image_list.items.len;
        } else {
            self.current_index = 0;
        }
        try self.updateCache();
    }

    pub fn prev(self: *ViewerState) !void {
        if (self.image_list.items.len == 0) return;
        if (self.current_index) |idx| {
            if (idx == 0) {
                self.current_index = self.image_list.items.len - 1;
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

        // Clear existing cache and rotation map before resetting directory_arena
        self.generation += 1;
        self.clearCache();
        self.rotation_map.clearRetainingCapacity();
        self.image_list.clearRetainingCapacity();
        _ = self.directory_arena.reset(.retain_capacity);
        self.current_index = null;

        if (has_stat) {
            if (stat.kind == .directory) {
                try scanDirectory(self.allocator, self.directory_arena.allocator(), self.io, path, &self.image_list);
                if (self.image_list.items.len > 0) {
                    self.current_index = 0;
                    try self.updateCache();
                }
            } else {
                const dir_path = std.fs.path.dirname(path) orelse ".";
                try scanDirectory(self.allocator, self.directory_arena.allocator(), self.io, dir_path, &self.image_list);

                var found_idx: ?usize = null;
                for (self.image_list.items, 0..) |item, i| {
                    if (std.mem.eql(u8, item, path)) {
                        found_idx = i;
                        break;
                    }
                }

                if (found_idx) |idx| {
                    self.current_index = idx;
                } else {
                    const dup = try self.directory_arena.allocator().dupe(u8, path);
                    try self.image_list.append(self.allocator, dup);
                    self.current_index = self.image_list.items.len - 1;
                }
                try self.updateCache();
            }
        }
        try self.rebuildPaletteMatches();
    }

    pub fn update(self: *ViewerState, input: FrameInput) !void {
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
                self.zoom_factor = std.math.clamp(self.zoom_factor + input.scroll_delta_y * 0.1, 0.1, 10.0);

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
        .status = .decoding,
    });
    try cache.append(allocator, .{
        .index = 20,
        .generation = 1,
        .status = .decoding,
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
