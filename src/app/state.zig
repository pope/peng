const std = @import("std");
const c = @import("c.zig").c;
const clay = @import("zclay");
const FrameInput = @import("types.zig").FrameInput;
const app_input = @import("input.zig");
const renderer = @import("../ui/renderer.zig");
const commands = @import("../commands.zig");

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

pub const CacheStatus = union(enum) {
    decoding: void,
    loaded_cpu: struct {
        surface: *c.SDL_Surface,
        w: f32,
        h: f32,
        size_bytes: u64,
        mime_type: []const u8,
        decode_time_ms: f64,
        conversion_time_ms: f64,
    },
    uploading: void,
    loaded_gpu: struct {
        gpu_texture: *c.SDL_GPUTexture,
        w: f32,
        h: f32,
        size_bytes: u64,
        mime_type: []const u8,
        decode_time_ms: f64,
        conversion_time_ms: f64,
        upload_time_ms: f64,
        memory_size_bytes: usize,
    },
    failed: void,
};

pub const CacheEntry = struct {
    index: usize,
    generation: usize,
    status: CacheStatus = .decoding,
};

pub const CacheSlotMap = struct {
    entries: std.ArrayListUnmanaged(CacheEntry) = .empty,

    pub fn deinit(self: *CacheSlotMap, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *CacheSlotMap) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn get(self: *CacheSlotMap, index: usize) ?*CacheEntry {
        for (self.entries.items) |*entry| {
            if (entry.index == index) return entry;
        }
        return null;
    }

    pub fn getWithGeneration(self: *CacheSlotMap, index: usize, generation: usize) ?*CacheEntry {
        for (self.entries.items) |*entry| {
            if (entry.index == index and entry.generation == generation) return entry;
        }
        return null;
    }

    pub fn updateStatus(self: *CacheSlotMap, index: usize, generation: usize, status: CacheStatus) bool {
        if (self.getWithGeneration(index, generation)) |entry| {
            entry.status = status;
            return true;
        }
        return false;
    }

    pub fn append(self: *CacheSlotMap, allocator: std.mem.Allocator, entry: CacheEntry) !void {
        try self.entries.append(allocator, entry);
    }

    pub fn remove(self: *CacheSlotMap, i: usize) CacheEntry {
        return self.entries.orderedRemove(i);
    }

    pub fn pop(self: *CacheSlotMap) ?CacheEntry {
        return self.entries.pop();
    }
};

pub const DecodeArgs = struct {
    state: *ViewerState,
    index: usize,
    generation: usize,
    path: [:0]const u8,
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

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |char_a, index| {
        if (std.ascii.toLower(char_a) != std.ascii.toLower(b[index])) return false;
    }
    return true;
}

pub fn isImageExtension(ext: []const u8) bool {
    const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".webp" };
    for (extensions) |e| {
        if (eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

pub fn scanDirectory(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, list: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open directory '{s}': {}", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries = std.ArrayList([]const u8).empty;
    defer dir_entries.deinit(allocator);
    errdefer {
        for (dir_entries.items) |entry| {
            allocator.free(entry);
        }
    }

    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (isImageExtension(ext)) {
                const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                try dir_entries.append(allocator, full_path);
            }
        }
    }

    // Sort entries alphabetically
    std.mem.sort([]const u8, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    try list.appendSlice(allocator, dir_entries.items);
}

pub fn detectMimeType(io: std.Io, path: []const u8) []const u8 {
    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch return "unknown";
    defer file.close(io);

    var header: [12]u8 = undefined;
    var slices = [_][]u8{&header};
    const bytes_read = file.readPositional(io, &slices, 0) catch return "unknown";
    if (bytes_read < 4) return "unknown";

    if (std.mem.startsWith(u8, &header, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) {
        return "image/png";
    }
    if (std.mem.startsWith(u8, &header, &[_]u8{ 0xFF, 0xD8, 0xFF })) {
        return "image/jpeg";
    }
    if (std.mem.startsWith(u8, &header, "GIF87a") or std.mem.startsWith(u8, &header, "GIF89a")) {
        return "image/gif";
    }
    if (std.mem.startsWith(u8, &header, "BM")) {
        return "image/bmp";
    }
    if (bytes_read >= 12 and std.mem.startsWith(u8, &header, "RIFF") and std.mem.eql(u8, header[8..12], "WEBP")) {
        return "image/webp";
    }

    const ext = std.fs.path.extension(path);
    if (eqlIgnoreCase(ext, ".png")) return "image/png";
    if (eqlIgnoreCase(ext, ".jpg") or eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (eqlIgnoreCase(ext, ".bmp")) return "image/bmp";
    if (eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (eqlIgnoreCase(ext, ".tga")) return "image/x-tga";

    return "unknown";
}

pub fn decodeWorker(data: ?*anyopaque) callconv(.c) c_int {
    const args: *DecodeArgs = @ptrCast(@alignCast(data.?));
    const state = args.state;
    const index = args.index;
    const path = args.path;

    defer {
        state.allocator.free(path);
        state.allocator.destroy(args);
        _ = state.active_threads.fetchSub(1, .release);
    }

    if (state.exiting.load(.acquire)) return 0;

    const mime_type = detectMimeType(state.io, path);

    if (state.exiting.load(.acquire)) return 0;

    const start_decode = c.SDL_GetTicksNS();
    const surface = c.IMG_Load(path.ptr);
    const end_decode = c.SDL_GetTicksNS();

    const decode_time_ms = @as(f64, @floatFromInt(end_decode - start_decode)) / 1_000_000.0;

    if (state.exiting.load(.acquire)) {
        if (surface) |surf| c.SDL_DestroySurface(surf);
        return 0;
    }

    var final_surface = surface;
    var conversion_time_ms: f64 = 0.0;
    if (surface) |surf| {
        if (state.window_pixel_format != c.SDL_PIXELFORMAT_UNKNOWN and surf.*.format != state.window_pixel_format) {
            const start_convert = c.SDL_GetTicksNS();
            const converted = c.SDL_ConvertSurface(surf, state.window_pixel_format);
            const end_convert = c.SDL_GetTicksNS();

            if (converted) |conv| {
                conversion_time_ms = @as(f64, @floatFromInt(end_convert - start_convert)) / 1_000_000.0;
                c.SDL_DestroySurface(surf);
                final_surface = conv;
            } else {
                std.log.err("SDL_ConvertSurface failed: {s}", .{c.SDL_GetError()});
            }
        }

        if (final_surface) |f_surf| {
            const max_dim: i32 = 8192;
            if (f_surf.*.w > max_dim or f_surf.*.h > max_dim) {
                var new_w = f_surf.*.w;
                var new_h = f_surf.*.h;
                if (f_surf.*.w > f_surf.*.h) {
                    new_w = max_dim;
                    new_h = @divTrunc(f_surf.*.h * max_dim, f_surf.*.w);
                } else {
                    new_h = max_dim;
                    new_w = @divTrunc(f_surf.*.w * max_dim, f_surf.*.h);
                }
                new_w = @max(1, new_w);
                new_h = @max(1, new_h);

                const scaled = c.SDL_ScaleSurface(f_surf, new_w, new_h, c.SDL_SCALEMODE_LINEAR);
                if (scaled) |sc| {
                    c.SDL_DestroySurface(f_surf);
                    final_surface = sc;
                } else {
                    std.log.err("decodeWorker: SDL_ScaleSurface failed: {s}", .{c.SDL_GetError()});
                }
            }
        }
    }

    // Stat the file
    var size_bytes: u64 = 0;
    if (std.Io.Dir.statFile(std.Io.Dir.cwd(), state.io, path, .{})) |s| {
        size_bytes = s.size;
    } else |_| {}

    if (state.exiting.load(.acquire)) {
        if (final_surface) |surf| c.SDL_DestroySurface(surf);
        return 0;
    }

    // Lock cache and update
    c.SDL_LockMutex(state.cache_mutex);
    defer c.SDL_UnlockMutex(state.cache_mutex);

    if (state.exiting.load(.acquire)) {
        if (final_surface) |surf| c.SDL_DestroySurface(surf);
        return 0;
    }

    // Check if this index is still wanted
    var found_in_cache = false;
    if (state.cache.getWithGeneration(index, args.generation)) |entry| {
        found_in_cache = true;
        if (final_surface) |surf| {
            if (entry.status == .loaded_cpu or entry.status == .loaded_gpu) {
                c.SDL_DestroySurface(surf);
            } else {
                entry.status = .{
                    .loaded_cpu = .{
                        .surface = surf,
                        .w = @floatFromInt(surf.*.w),
                        .h = @floatFromInt(surf.*.h),
                        .size_bytes = size_bytes,
                        .mime_type = mime_type,
                        .decode_time_ms = decode_time_ms,
                        .conversion_time_ms = conversion_time_ms,
                    },
                };
            }
        } else {
            if (entry.status != .loaded_cpu and entry.status != .loaded_gpu) {
                entry.status = .failed;
            }
        }
    }

    if (!found_in_cache) {
        if (final_surface) |surf| {
            c.SDL_DestroySurface(surf);
        }
    } else {
        // Push SDL user event to wake up the main loop
        var event: c.SDL_Event = undefined;
        event.type = c.SDL_EVENT_USER;
        _ = c.SDL_PushEvent(&event);
    }

    return 0;
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
    gpu_text_engine: ?*c.TTF_TextEngine = null,
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

        for (self.gpu_vertex_buffers) |vb| {
            if (vb) |b| c.SDL_ReleaseGPUBuffer(self.gpu_device.?, b);
        }
        for (self.gpu_transfer_buffers) |tb| {
            if (tb) |b| c.SDL_ReleaseGPUTransferBuffer(self.gpu_device.?, b);
        }

        var text_iter = self.text_cache.valueIterator();
        while (text_iter.next()) |val| {
            c.SDL_ReleaseGPUTexture(self.gpu_device.?, val.texture);
        }
        self.text_cache.deinit(self.allocator);

        if (self.gpu_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(self.gpu_device, pipeline);
        if (self.gpu_sampler) |sampler| c.SDL_ReleaseGPUSampler(self.gpu_device, sampler);
        if (self.white_texture) |white_tex| c.SDL_ReleaseGPUTexture(self.gpu_device, white_tex);
        if (self.gpu_text_engine) |engine| c.TTF_DestroyGPUTextEngine(engine);
        if (self.window_claimed) {
            if (self.window) |w| c.SDL_ReleaseWindowFromGPUDevice(self.gpu_device, w);
        }

        c.SDL_DestroyMutex(self.cache_mutex);
        for (self.image_list.items) |item| {
            self.allocator.free(item);
        }
        self.image_list.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.palette.deinit();
        self.rotation_map.deinit();
    }

    pub fn resetZoomPan(self: *ViewerState) void {
        self.zoom_factor = 1.0;
        self.pan_x = 0.0;
        self.pan_y = 0.0;
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
            .max_lod = 0.0,
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
            const start_upload = c.SDL_GetTicksNS();
            var current_surf = target.cpu.surface;
            var scaled_surf: ?*c.SDL_Surface = null;
            defer if (scaled_surf) |s| c.SDL_DestroySurface(s);
            defer c.SDL_DestroySurface(target.cpu.surface);

            var img_w = current_surf.*.w;
            var img_h = current_surf.*.h;
            var tex: ?*c.SDL_GPUTexture = null;

            var try_max_dim: i32 = 16384;
            while (try_max_dim >= 2048) : (try_max_dim = @divTrunc(try_max_dim, 2)) {
                if (img_w <= try_max_dim and img_h <= try_max_dim) {
                    const img_tex_info = c.SDL_GPUTextureCreateInfo{
                        .type = c.SDL_GPU_TEXTURETYPE_2D,
                        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                        .width = @intCast(img_w),
                        .height = @intCast(img_h),
                        .layer_count_or_depth = 1,
                        .num_levels = 1,
                        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
                        .props = 0,
                    };
                    tex = c.SDL_CreateGPUTexture(self.gpu_device, &img_tex_info);
                    if (tex != null) break;
                }

                const next_dim = @divTrunc(try_max_dim, 2);
                if (img_w > next_dim or img_h > next_dim) {
                    var new_w = img_w;
                    var new_h = img_h;
                    if (img_w > img_h) {
                        new_w = next_dim;
                        new_h = @divTrunc(img_h * next_dim, img_w);
                    } else {
                        new_h = next_dim;
                        new_w = @divTrunc(img_w * next_dim, img_h);
                    }
                    new_w = @max(1, new_w);
                    new_h = @max(1, new_h);

                    const new_scale = c.SDL_ScaleSurface(
                        current_surf,
                        new_w,
                        new_h,
                        c.SDL_SCALEMODE_LINEAR,
                    );
                    if (new_scale) |ns| {
                        if (scaled_surf) |s| c.SDL_DestroySurface(s);
                        scaled_surf = ns;
                        current_surf = ns;
                        img_w = new_w;
                        img_h = new_h;
                    } else {
                        std.log.err("SDL_ScaleSurface failed: {s}", .{c.SDL_GetError()});
                        break;
                    }
                }
            }

            if (tex == null) {
                std.log.err("Create GPU Texture failed for image size {d}x{d}: {s}", .{ target.cpu.surface.*.w, target.cpu.surface.*.h, c.SDL_GetError() });
                c.SDL_LockMutex(self.cache_mutex);
                _ = self.cache.updateStatus(target.index, target.generation, .failed);
                c.SDL_UnlockMutex(self.cache_mutex);
                return;
            }
            const gpu_tex = tex.?;

            const cmd_buf = c.SDL_AcquireGPUCommandBuffer(self.gpu_device) orelse {
                c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                c.SDL_LockMutex(self.cache_mutex);
                _ = self.cache.updateStatus(target.index, target.generation, .failed);
                c.SDL_UnlockMutex(self.cache_mutex);
                return;
            };
            const size = @as(usize, @intCast(img_w)) * @as(usize, @intCast(img_h)) * 4;
            const transfer_buf = c.SDL_CreateGPUTransferBuffer(self.gpu_device, &c.SDL_GPUTransferBufferCreateInfo{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = @intCast(size),
                .props = 0,
            }) orelse {
                std.log.err("Create transfer buffer failed: {s}", .{c.SDL_GetError()});
                _ = c.SDL_CancelGPUCommandBuffer(cmd_buf);
                c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                c.SDL_LockMutex(self.cache_mutex);
                _ = self.cache.updateStatus(target.index, target.generation, .failed);
                c.SDL_UnlockMutex(self.cache_mutex);
                return;
            };
            defer c.SDL_ReleaseGPUTransferBuffer(self.gpu_device, transfer_buf);

            const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.gpu_device, transfer_buf, false) orelse {
                _ = c.SDL_CancelGPUCommandBuffer(cmd_buf);
                c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                c.SDL_LockMutex(self.cache_mutex);
                _ = self.cache.updateStatus(target.index, target.generation, .failed);
                c.SDL_UnlockMutex(self.cache_mutex);
                return;
            });
            const pixels: [*]const u8 = @ptrCast(current_surf.*.pixels);
            @memcpy(mapped[0..size], pixels[0..size]);
            c.SDL_UnmapGPUTransferBuffer(self.gpu_device, transfer_buf);

            const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
                _ = c.SDL_CancelGPUCommandBuffer(cmd_buf);
                c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                c.SDL_LockMutex(self.cache_mutex);
                _ = self.cache.updateStatus(target.index, target.generation, .failed);
                c.SDL_UnlockMutex(self.cache_mutex);
                return;
            };
            c.SDL_UploadToGPUTexture(copy_pass, &c.SDL_GPUTextureTransferInfo{
                .transfer_buffer = transfer_buf,
                .offset = 0,
                .pixels_per_row = @intCast(img_w),
                .rows_per_layer = @intCast(img_h),
            }, &c.SDL_GPUTextureRegion{
                .texture = gpu_tex,
                .w = @intCast(img_w),
                .h = @intCast(img_h),
                .d = 1,
            }, false);
            c.SDL_EndGPUCopyPass(copy_pass);
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);

            const end_upload = c.SDL_GetTicksNS();
            const upload_time_ms = @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;

            c.SDL_LockMutex(self.cache_mutex);
            const loaded_gpu_status = CacheStatus{
                .loaded_gpu = .{
                    .gpu_texture = gpu_tex,
                    .w = @floatFromInt(img_w),
                    .h = @floatFromInt(img_h),
                    .size_bytes = target.cpu.size_bytes,
                    .mime_type = target.cpu.mime_type,
                    .decode_time_ms = target.cpu.decode_time_ms,
                    .conversion_time_ms = target.cpu.conversion_time_ms,
                    .upload_time_ms = upload_time_ms,
                    .memory_size_bytes = size,
                },
            };
            const updated = self.cache.updateStatus(target.index, target.generation, loaded_gpu_status);
            c.SDL_UnlockMutex(self.cache_mutex);

            if (!updated) {
                // The cache entry was evicted or cleared while we were uploading.
                // We must release the GPU texture to prevent a leak!
                c.SDL_ReleaseGPUTexture(self.gpu_device.?, gpu_tex);
            }
        }
        if (self.adjustments_dirty) {
            self.adjustments_dirty = false;
        }
    }

    pub fn clearCache(self: *ViewerState) void {
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);

        for (self.cache.entries.items) |entry| {
            switch (entry.status) {
                .loaded_cpu => |cpu| c.SDL_DestroySurface(cpu.surface),
                .loaded_gpu => |gpu| c.SDL_ReleaseGPUTexture(self.gpu_device, gpu.gpu_texture),
                else => {},
            }
        }
        self.cache.clearRetainingCapacity();
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
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);

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

        // 3. Add wanted entries that are not in the cache yet
        var hit = false;
        for (desired[0..desired_count]) |d| {
            var exists = false;
            if (self.cache.get(d)) |entry| {
                exists = true;
                if (d == idx and (entry.status == .loaded_cpu or entry.status == .loaded_gpu)) {
                    hit = true;
                }
            }
            if (!exists) {
                const path = try self.allocator.dupeZ(u8, self.image_list.items[d]);
                errdefer self.allocator.free(path);

                const new_entry = CacheEntry{
                    .index = d,
                    .generation = self.generation,
                    .status = .decoding,
                };
                try self.cache.append(self.allocator, new_entry);
                errdefer _ = self.cache.pop();

                // Spawn worker thread
                const args = try self.allocator.create(DecodeArgs);
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
                    _ = self.cache.pop();
                }
            }
        }
        self.current_image_cache_hit = hit;
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
        // Clear existing list
        for (self.image_list.items) |item| {
            self.allocator.free(item);
        }
        self.image_list.clearRetainingCapacity();
        self.rotation_map.clearRetainingCapacity();

        self.generation += 1;
        self.clearCache();
        self.current_index = null;

        var stat: std.Io.File.Stat = undefined;
        var has_stat = true;
        if (std.Io.Dir.statFile(std.Io.Dir.cwd(), self.io, path, .{})) |s| {
            stat = s;
        } else |err| {
            std.log.err("Failed to access path '{s}': {}", .{ path, err });
            has_stat = false;
        }

        if (has_stat) {
            if (stat.kind == .directory) {
                try scanDirectory(self.allocator, self.io, path, &self.image_list);
                if (self.image_list.items.len > 0) {
                    self.current_index = 0;
                    try self.updateCache();
                }
            } else {
                const dir_path = std.fs.path.dirname(path) orelse ".";
                try scanDirectory(self.allocator, self.io, dir_path, &self.image_list);

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
                    const dup = try self.allocator.dupe(u8, path);
                    errdefer self.allocator.free(dup);
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
    defer cache.deinit(allocator);

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
