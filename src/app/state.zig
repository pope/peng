const std = @import("std");
const main = @import("../main.zig");
const c = main.c;
const clay = main.clay;
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

pub const PaletteType = enum {
    files,
    actions,
    set_brightness,
    set_contrast,
    go_to_image,
};

pub const PaletteState = struct {
    show: bool = false,
    active_type: PaletteType = .files,
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
        self.selected_idx = 0;
        self.selection_dirty = true;
    }
};

pub const CacheEntry = struct {
    index: usize,
    generation: usize,
    gpu_texture: ?*c.SDL_GPUTexture = null,
    w: f32 = 0,
    h: f32 = 0,
    size_bytes: u64 = 0,
    mime_type: []const u8 = "unknown",
    decode_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    upload_time_ms: f64 = 0.0,
    memory_size_bytes: usize = 0,
    surface: ?*c.SDL_Surface = null,
    status: enum { decoding, loaded, failed } = .decoding,
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
    for (state.cache.items) |*entry| {
        if (entry.index == index and entry.generation == args.generation) {
            found_in_cache = true;
            if (final_surface) |surf| {
                if (entry.surface != null or entry.gpu_texture != null) {
                    c.SDL_DestroySurface(surf);
                } else {
                    entry.surface = surf;
                    entry.w = @floatFromInt(surf.*.w);
                    entry.h = @floatFromInt(surf.*.h);
                    entry.memory_size_bytes = @intCast(surf.*.pitch * surf.*.h);
                    entry.size_bytes = size_bytes;
                    entry.mime_type = mime_type;
                    entry.decode_time_ms = decode_time_ms;
                    entry.conversion_time_ms = conversion_time_ms;
                    entry.status = .loaded;
                }
            } else {
                if (entry.status != .loaded) {
                    entry.status = .failed;
                }
            }
            break;
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
    cache: std.ArrayList(CacheEntry),
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
    test_mode: bool = false,
    update_baselines: bool = false,
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
    stats_dragging: bool = false,
    drag_start_x: f32 = 0.0,
    drag_start_y: f32 = 0.0,
    viewport_dragging: bool = false,
    drag_last_x: f32 = 0.0,
    drag_last_y: f32 = 0.0,
    mouse_inside: bool = true,

    pub fn deinit(self: *ViewerState) void {
        self.exiting.store(true, .release);
        while (self.active_threads.load(.acquire) > 0) {
            c.SDL_Delay(1);
        }

        self.clearCache();

        if (self.gpu_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(self.gpu_device, pipeline);
        if (self.gpu_sampler) |sampler| c.SDL_ReleaseGPUSampler(self.gpu_device, sampler);
        if (self.white_texture) |white_tex| c.SDL_ReleaseGPUTexture(self.gpu_device, white_tex);
        if (self.gpu_text_engine) |engine| c.TTF_DestroyGPUTextEngine(engine);
        if (self.window) |w| c.SDL_ReleaseWindowFromGPUDevice(self.gpu_device, w);

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
        for (self.cache.items) |entry| {
            if (entry.index == idx) {
                return entry;
            }
        }
        return null;
    }

    pub fn prepareCacheTextures(self: *ViewerState) void {
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);

        for (self.cache.items) |*entry| {
            if (entry.status == .loaded and entry.surface != null) {
                if (entry.gpu_texture == null) {
                    const start_upload = c.SDL_GetTicksNS();
                    var current_surf = entry.surface.?;
                    var scaled_surf: ?*c.SDL_Surface = null;
                    defer if (scaled_surf) |s| c.SDL_DestroySurface(s);

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
                        std.log.err("Create GPU Texture failed for image size {d}x{d}: {s}", .{ entry.surface.?.*.w, entry.surface.?.*.h, c.SDL_GetError() });
                        continue;
                    }
                    const gpu_tex = tex.?;

                    const cmd_buf = c.SDL_AcquireGPUCommandBuffer(self.gpu_device) orelse {
                        c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                        continue;
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
                        continue;
                    };
                    defer c.SDL_ReleaseGPUTransferBuffer(self.gpu_device, transfer_buf);

                    const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.gpu_device, transfer_buf, false) orelse {
                        _ = c.SDL_CancelGPUCommandBuffer(cmd_buf);
                        c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                        continue;
                    });
                    const pixels: [*]const u8 = @ptrCast(current_surf.*.pixels);
                    @memcpy(mapped[0..size], pixels[0..size]);
                    c.SDL_UnmapGPUTransferBuffer(self.gpu_device, transfer_buf);

                    const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
                        _ = c.SDL_CancelGPUCommandBuffer(cmd_buf);
                        c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                        continue;
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

                    entry.gpu_texture = gpu_tex;
                    c.SDL_DestroySurface(entry.surface.?);
                    entry.surface = null;

                    const end_upload = c.SDL_GetTicksNS();
                    entry.upload_time_ms = @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;
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

        for (self.cache.items) |entry| {
            if (entry.gpu_texture) |tex| {
                c.SDL_ReleaseGPUTexture(self.gpu_device, tex);
            }
            if (entry.surface) |surf| {
                c.SDL_DestroySurface(surf);
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
            (idx + (len - 1)) % len,
            (idx + (len - 2)) % len,
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
        while (i < self.cache.items.len) {
            const entry = &self.cache.items[i];
            var wanted = false;
            for (desired[0..desired_count]) |d| {
                if (entry.index == d) {
                    wanted = true;
                    break;
                }
            }
            if (!wanted) {
                // Evict
                if (entry.gpu_texture) |tex| {
                    c.SDL_ReleaseGPUTexture(self.gpu_device, tex);
                }
                if (entry.surface) |surf| {
                    c.SDL_DestroySurface(surf);
                }
                _ = self.cache.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // 3. Add wanted entries that are not in the cache yet
        var hit = false;
        for (desired[0..desired_count]) |d| {
            var exists = false;
            for (self.cache.items) |entry| {
                if (entry.index == d) {
                    exists = true;
                    if (d == idx and entry.status == .loaded) {
                        hit = true;
                    }
                    break;
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

    pub fn handleKeyDown(self: *ViewerState, key: c.SDL_Keycode, mod: c.SDL_Keymod, scale_x: f32, scale_y: f32) !void {
        const app_input = @import("input.zig");
        try app_input.handleKeyDown(self, key, mod, scale_x, scale_y);
    }

    pub fn handlePaletteKeys(self: *ViewerState, key: c.SDL_Keycode) !bool {
        const app_input = @import("input.zig");
        return try app_input.handlePaletteKeys(self, key);
    }

    pub fn update(self: *ViewerState, input: main.FrameInput, gpa: std.mem.Allocator) !void {
        // 1. Text input updates
        if (input.text_input) |text| {
            if (self.palette.show) {
                try self.palette.query.appendSlice(gpa, text);
                self.palette.selected_idx = 0;
                self.palette.selection_dirty = true;
                switch (self.palette.active_type) {
                    .files => try self.rebuildPaletteMatches(),
                    .actions => try self.rebuildActionMatches(),
                    .set_brightness, .set_contrast, .go_to_image => {},
                }
            }
        }

        // 2. Drop file/directory updates
        if (input.dropped_path) |path| {
            try self.handlePathSelection(path);
        }

        // 3. Mouse dragging updates
        if (self.show_stats_overlay and self.stats_dragging) {
            if (input.mouse_left_down) {
                self.stats_offset_x = input.mouse_x - self.stats_offset_x;
                self.stats_offset_y = input.mouse_y - self.stats_offset_y;
            } else {
                self.stats_dragging = false;
            }
        } else if (self.viewport_dragging) {
            if (input.mouse_left_down) {
                self.pan_x += input.mouse_x - self.drag_last_x;
                self.pan_y += input.mouse_y - self.drag_last_y;
                self.drag_last_x = input.mouse_x;
                self.drag_last_y = input.mouse_y;
            } else {
                self.viewport_dragging = false;
            }
        }

        // 4. Mouse click triggers (starts dragging)
        if (input.mouse_left_clicked) {
            // Check if we should close the palette
            if (self.palette.show) {
                const element_id = switch (self.palette.active_type) {
                    .files => "CommandPalette",
                    .actions => "ActionPalette",
                    .set_brightness => "BrightnessPalette",
                    .set_contrast => "ContrastPalette",
                    .go_to_image => "GoToImagePalette",
                };
                if (!clay.pointerOver(clay.getElementId(element_id))) {
                    self.palette.show = false;
                    stopTextInput(self.window);
                }
            }

            if (self.show_stats_overlay and
                clay.pointerOver(clay.getElementId("StatsPanel")) and
                !clay.pointerOver(clay.getElementId("StatsCloseBtn")))
            {
                self.stats_dragging = true;
                self.drag_start_x = input.mouse_x - self.stats_offset_x;
                self.drag_start_y = input.mouse_y - self.stats_offset_y;
            } else if (!self.palette.show and clay.pointerOver(clay.getElementId("Viewport"))) {
                self.viewport_dragging = true;
                self.drag_last_x = input.mouse_x;
                self.drag_last_y = input.mouse_y;
            }
        }

        // 5. Mouse Wheel Zoom updates
        if (input.scroll_delta_y != 0) {
            if (!self.palette.show and clay.pointerOver(clay.getElementId("Viewport"))) {
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
            try self.handleKeyDown(key, input.key_modifiers, input.scale_x, input.scale_y);
        }
    }
};
