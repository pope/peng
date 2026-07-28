const std = @import("std");
const sdl = @import("sdl");
const graphics = @import("ui").graphics;
const fs = @import("fs.zig");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const exif = @import("exif.zig");
const readJpegExifOrientation = exif.readJpegExifOrientation;
const readJpegDimensions = exif.readJpegDimensions;
const extractJpegThumbnail = exif.extractJpegThumbnail;
const JpegDimensions = exif.JpegDimensions;
const parseExifDimensions = exif.parseExifDimensions;
const parseExifOrientation = exif.parseExifOrientation;

pub const CacheStatus = union(enum) {
    decoding: struct {
        has_thread: bool = false,
    },
    loaded_cpu: struct {
        surface: sdl.Surface,
        w: f32,
        h: f32,
        size_bytes: u64,
        mime_type: []const u8,
        decode_time_ms: f64,
        conversion_time_ms: f64,
        has_thumb: bool = false,
        thumb_w: f32 = 0.0,
        thumb_h: f32 = 0.0,
        thumb_upload_time_ms: f64 = 0.0,
    },
    loaded_gpu: struct {
        gpu_texture: sdl.gpu.Texture,
        w: f32,
        h: f32,
        size_bytes: u64,
        mime_type: []const u8,
        decode_time_ms: f64,
        conversion_time_ms: f64,
        upload_time_ms: f64,
        memory_size_bytes: usize,
        num_mip_levels: u32 = 1,
        mipmap_time_ms: f64 = 0.0,
        was_fallback: bool = false,
        fallback_time_ms: f64 = 0.0,
        has_thumb: bool = false,
        thumb_w: f32 = 0.0,
        thumb_h: f32 = 0.0,
        thumb_upload_time_ms: f64 = 0.0,
    },
    uploading: void,
    failed: void,
};

pub const CacheEntry = struct {
    index: usize,
    generation: usize,
    status: CacheStatus,
    thumb_gpu_texture: ?sdl.gpu.Texture = null,
    thumb_w: f32 = 0.0,
    thumb_h: f32 = 0.0,
    full_w: f32 = 0.0,
    full_h: f32 = 0.0,
    exif_orientation: f32 = 0.0,
    has_thumb: bool = false,
    thumb_upload_time_ms: f64 = 0.0,

    pub fn deinit(self: *CacheEntry, gpu_device: ?sdl.gpu.Device) void {
        if (self.thumb_gpu_texture) |thumb_tex| {
            if (gpu_device) |dev| {
                dev.releaseTexture(thumb_tex);
            }
            self.thumb_gpu_texture = null;
        }
        switch (self.status) {
            .loaded_cpu => |cpu| cpu.surface.destroy(),
            .loaded_gpu => |gpu| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(gpu.gpu_texture);
                }
            },
            else => {},
        }
    }
};

pub const TextureHandle = struct {
    index: usize,
    generation: usize,
};

pub const CacheSlotMap = struct {
    entries: std.ArrayListUnmanaged(CacheEntry) = .empty,

    pub fn deinit(self: *CacheSlotMap, allocator: std.mem.Allocator, gpu_device: ?sdl.gpu.Device) void {
        for (self.entries.items) |*entry| {
            entry.deinit(gpu_device);
        }
        self.entries.deinit(allocator);
    }

    pub fn clear(self: *CacheSlotMap, gpu_device: ?sdl.gpu.Device) void {
        for (self.entries.items) |*entry| {
            entry.deinit(gpu_device);
        }
        self.entries.clearRetainingCapacity();
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

    pub fn getTexture(self: *CacheSlotMap, handle: TextureHandle) ?sdl.gpu.Texture {
        if (self.getWithGeneration(handle.index, handle.generation)) |entry| {
            switch (entry.status) {
                .loaded_gpu => |gpu| return gpu.gpu_texture,
                else => {},
            }
        }
        return null;
    }

    pub fn getSurface(self: *CacheSlotMap, handle: TextureHandle) ?sdl.Surface {
        if (self.getWithGeneration(handle.index, handle.generation)) |entry| {
            switch (entry.status) {
                .loaded_cpu => |cpu| return cpu.surface,
                else => {},
            }
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

    pub fn remove(self: *CacheSlotMap, index_in_list: usize) CacheEntry {
        return self.entries.orderedRemove(index_in_list);
    }

    pub fn removeAndDeinit(self: *CacheSlotMap, index_in_list: usize, gpu_device: ?sdl.gpu.Device) void {
        var entry = self.entries.orderedRemove(index_in_list);
        entry.deinit(gpu_device);
    }

    pub const DEFAULT_MAX_VRAM_BYTES: usize = 1024 * 1024 * 1024;

    pub fn getTotalVramBytes(self: *const CacheSlotMap) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| {
            switch (entry.status) {
                .loaded_gpu => |gpu| total += gpu.memory_size_bytes,
                else => {},
            }
        }
        return total;
    }

    pub fn enforceVramBudget(self: *CacheSlotMap, gpu_device: ?sdl.gpu.Device, current_index: ?usize, max_bytes: usize) void {
        while (self.getTotalVramBytes() > max_bytes) {
            var max_dist: usize = 0;
            var victim_idx: ?usize = null;

            for (self.entries.items, 0..) |entry, i| {
                if (entry.status == .loaded_gpu) {
                    if (current_index) |cur| {
                        if (entry.index == cur) continue;
                        const dist = if (entry.index > cur) entry.index - cur else cur - entry.index;
                        // Protect immediate neighbors (dist <= 2) if possible
                        if (dist <= 2 and self.entries.items.len <= 5) continue;
                        if (dist >= max_dist) {
                            max_dist = dist;
                            victim_idx = i;
                        }
                    } else {
                        victim_idx = i;
                        break;
                    }
                }
            }

            if (victim_idx) |v_i| {
                self.removeAndDeinit(v_i, gpu_device);
            } else {
                break;
            }
        }
    }
};

pub const DecodeArgs = struct {
    state: *ViewerState,
    index: usize,
    generation: usize,
    path: [:0]const u8,
};

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
    if (fs.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (fs.eqlIgnoreCase(ext, ".jpg") or fs.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (fs.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (fs.eqlIgnoreCase(ext, ".bmp")) return "image/bmp";
    if (fs.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (fs.eqlIgnoreCase(ext, ".tga")) return "image/x-tga";

    return "unknown";
}

pub fn decodeWorker(args: *DecodeArgs) void {
    const state = args.state;
    const index = args.index;
    const path = args.path;
    defer {
        const alloc = state.allocator;
        alloc.free(path);
        alloc.destroy(args);
        _ = state.active_decode_threads.fetchSub(1, .release);
        _ = state.active_threads.fetchSub(1, .release);
        fs.wakeUpMainThread();
    }

    const exif_rot = readJpegExifOrientation(state.io, path) orelse 0.0;
    if (exif_rot != 0.0) {
        state.event_queue.push(state.allocator, state.io, .{
            .exif_orientation_parsed = .{
                .index = index,
                .generation = args.generation,
                .orientation = exif_rot,
            },
        }) catch |err| std.log.err("Failed to push EXIF orientation event: {}", .{err});
        fs.wakeUpMainThread();
    }

    if (!state.isJobValid(args.generation)) return;

    const mime_type = detectMimeType(state.io, path);

    if (!state.isJobValid(args.generation)) return;

    // Attempt fast EXIF thumbnail decoding for instant placeholder preview
    if (std.mem.eql(u8, mime_type, "image/jpeg") and state.gpu != null) {
        var header_buf: [65536]u8 = undefined;
        var thumb_file = std.Io.Dir.openFile(std.Io.Dir.cwd(), state.io, path, .{}) catch null;
        if (thumb_file) |*f| {
            defer f.close(state.io);
            var slices = [_][]u8{&header_buf};
            const n = f.readPositional(state.io, &slices, 0) catch 0;
            if (n > 0) {
                const full_dims = readJpegDimensions(header_buf[0..n]);
                if (extractJpegThumbnail(header_buf[0..n])) |thumb_bytes| {
                    if (sdl.Surface.loadConstMemOpt(thumb_bytes)) |t_surf| {
                        const full_w: f32 = if (full_dims) |d| d.w else 0.0;
                        const full_h: f32 = if (full_dims) |d| d.h else 0.0;
                        state.event_queue.push(state.allocator, state.io, .{
                            .thumb_decoded = .{
                                .index = index,
                                .generation = args.generation,
                                .surface = t_surf,
                                .w = @floatFromInt(t_surf.w()),
                                .h = @floatFromInt(t_surf.h()),
                                .full_w = full_w,
                                .full_h = full_h,
                                .exif_orientation = exif_rot,
                            },
                        }) catch |err| {
                            std.log.err("Failed to push thumbnail decode event: {}", .{err});
                            t_surf.destroy();
                        };
                        fs.wakeUpMainThread();
                    }
                }
            }
        }
    }

    if (!state.isJobValid(args.generation)) return;

    const start_decode = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadFilePtr(path.ptr);
    const end_decode = sdl.timer.getTicksNs();

    const decode_time_ms = @as(f64, @floatFromInt(end_decode - start_decode)) / 1_000_000.0;

    if (surface == null) {
        std.log.err("decodeWorker: failed to load image '{s}': {s}", .{ path, sdl.getError() });
    }

    if (!state.isJobValid(args.generation)) {
        if (surface) |surf| surf.destroy();
        return;
    }

    var final_surface = surface;
    var conversion_time_ms: f64 = 0.0;
    if (surface) |surf| {
        const pix_fmt = state.display.getPixelFormat();
        if (state.gpu == null and pix_fmt != sdl.PixelFormat.unknown and surf.format() != pix_fmt) {
            const start_convert = sdl.timer.getTicksNs();
            if (surf.convert(pix_fmt)) |conv| {
                const end_convert = sdl.timer.getTicksNs();
                conversion_time_ms = @as(f64, @floatFromInt(end_convert - start_convert)) / 1_000_000.0;
                surf.destroy();
                final_surface = conv;
            } else {
                std.log.err("SDL_ConvertSurface failed: {s}", .{sdl.getError()});
            }
        }

        if (final_surface) |f_surf| {
            const max_dim: i32 = 8192;
            if (f_surf.w() > max_dim or f_surf.h() > max_dim) {
                var new_w = f_surf.w();
                var new_h = f_surf.h();
                if (f_surf.w() > f_surf.h()) {
                    new_w = max_dim;
                    new_h = @divTrunc(f_surf.h() * max_dim, f_surf.w());
                } else {
                    new_h = max_dim;
                    new_w = @divTrunc(f_surf.w() * max_dim, f_surf.h());
                }
                new_w = @max(1, new_w);
                new_h = @max(1, new_h);

                const scaled = f_surf.scale(new_w, new_h, .linear);
                if (scaled) |sc| {
                    f_surf.destroy();
                    final_surface = sc;
                } else {
                    std.log.err("decodeWorker: SDL_ScaleSurface failed: {s}", .{sdl.getError()});
                }
            }
        }
    }

    // Stat the file
    var size_bytes: u64 = 0;
    if (std.Io.Dir.statFile(std.Io.Dir.cwd(), state.io, path, .{})) |s| {
        size_bytes = s.size;
    } else |err| {
        std.log.debug("decodeWorker: statFile failed for '{s}': {any}", .{ path, err });
    }

    if (!state.isJobValid(args.generation)) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());

        state.event_queue.push(state.allocator, state.io, .{
            .image_decoded = .{
                .index = index,
                .generation = args.generation,
                .surface = f_surf,
                .w = orig_w,
                .h = orig_h,
                .mime_type = mime_type,
                .size_bytes = size_bytes,
                .decode_time_ms = decode_time_ms,
                .conversion_time_ms = conversion_time_ms,
                .exif_orientation = exif_rot,
            },
        }) catch |err| {
            std.log.err("Failed to push image decode event: {}", .{err});
            f_surf.destroy();
        };
        fs.wakeUpMainThread();
    } else {
        state.event_queue.push(state.allocator, state.io, .{
            .decode_failed = .{
                .index = index,
                .generation = args.generation,
            },
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
        fs.wakeUpMainThread();
    }

    return;
}
