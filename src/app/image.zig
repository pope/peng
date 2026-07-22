const std = @import("std");
const c = @import("c.zig").c;
const graphics = @import("../ui/graphics.zig");
const fs = @import("fs.zig");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;

pub const CacheStatusTag = enum {
    decoding,
    loaded_cpu,
    loaded_gpu,
    uploading,
    failed,
};

pub const CacheStatus = union(CacheStatusTag) {
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
        num_mip_levels: u32 = 1,
        mipmap_time_ms: f64 = 0.0,
    },
    uploading: void,
    failed: void,
};

pub const CacheEntry = struct {
    index: usize,
    generation: usize,
    status: CacheStatus,
};

pub const TextureHandle = struct {
    index: usize,
    generation: usize,
};

pub const CacheSlotMap = struct {
    entries: std.ArrayListUnmanaged(CacheEntry) = .empty,

    pub fn deinit(self: *CacheSlotMap, allocator: std.mem.Allocator, gpu_device: ?*c.SDL_GPUDevice) void {
        self.clear(gpu_device);
        self.entries.deinit(allocator);
    }

    pub fn clear(self: *CacheSlotMap, gpu_device: ?*c.SDL_GPUDevice) void {
        for (self.entries.items) |entry| {
            switch (entry.status) {
                .loaded_cpu => |cpu| c.SDL_DestroySurface(cpu.surface),
                .loaded_gpu => |gpu| {
                    if (gpu_device) |gpu_dev| {
                        c.SDL_ReleaseGPUTexture(gpu_dev, gpu.gpu_texture);
                    }
                },
                else => {},
            }
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

    pub fn getTexture(self: *CacheSlotMap, handle: TextureHandle) ?*c.SDL_GPUTexture {
        if (self.getWithGeneration(handle.index, handle.generation)) |entry| {
            if (entry.status == .loaded_gpu) {
                return entry.status.loaded_gpu.gpu_texture;
            }
        }
        return null;
    }

    pub fn getSurface(self: *CacheSlotMap, handle: TextureHandle) ?*c.SDL_Surface {
        if (self.getWithGeneration(handle.index, handle.generation)) |entry| {
            if (entry.status == .loaded_cpu) {
                return entry.status.loaded_cpu.surface;
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

    pub const DEFAULT_MAX_VRAM_BYTES: usize = 256 * 1024 * 1024;

    pub fn getTotalVramBytes(self: *const CacheSlotMap) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.status == .loaded_gpu) {
                total += entry.status.loaded_gpu.memory_size_bytes;
            }
        }
        return total;
    }

    pub fn enforceVramBudget(self: *CacheSlotMap, gpu_device: ?*c.SDL_GPUDevice, current_index: ?usize, max_bytes: usize) void {
        while (self.getTotalVramBytes() > max_bytes) {
            var max_dist: usize = 0;
            var victim_idx: ?usize = null;

            for (self.entries.items, 0..) |entry, i| {
                if (entry.status == .loaded_gpu) {
                    if (current_index) |cur| {
                        if (entry.index == cur) continue;
                        const dist = if (entry.index > cur) entry.index - cur else cur - entry.index;
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
                const entry = &self.entries.items[v_i];
                if (gpu_device) |gpu_dev| {
                    c.SDL_ReleaseGPUTexture(gpu_dev, entry.status.loaded_gpu.gpu_texture);
                }
                _ = self.entries.orderedRemove(v_i);
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

    var uploaded_to_gpu = false;
    if (final_surface) |f_surf| {
        if (state.gpu_device) |gpu_dev| {
            const orig_w: f32 = @floatFromInt(f_surf.*.w);
            const orig_h: f32 = @floatFromInt(f_surf.*.h);

            // Progressive Thumbnail Pass for large images (> 1280px)
            const thumb_max: i32 = 1280;
            if (f_surf.*.w > thumb_max or f_surf.*.h > thumb_max) {
                var tw = f_surf.*.w;
                var th = f_surf.*.h;
                if (tw > th) {
                    tw = thumb_max;
                    th = @divTrunc(f_surf.*.h * thumb_max, f_surf.*.w);
                } else {
                    th = thumb_max;
                    tw = @divTrunc(f_surf.*.w * thumb_max, f_surf.*.h);
                }
                tw = @max(1, tw);
                th = @max(1, th);

                if (c.SDL_ScaleSurface(f_surf, tw, th, c.SDL_SCALEMODE_LINEAR)) |thumb_surf| {
                    defer c.SDL_DestroySurface(thumb_surf);
                    if (graphics.uploadSurfaceToGpu(gpu_dev, thumb_surf)) |thumb_res| {
                        c.SDL_LockMutex(state.cache_mutex);
                        if (!state.exiting.load(.acquire)) {
                            if (state.cache.getWithGeneration(index, args.generation)) |entry| {
                                if (entry.status != .loaded_gpu) {
                                    switch (entry.status) {
                                        .loaded_cpu => |cpu| c.SDL_DestroySurface(cpu.surface),
                                        else => {},
                                    }
                                    entry.status = .{
                                        .loaded_gpu = .{
                                            .gpu_texture = thumb_res.gpu_texture,
                                            .w = orig_w,
                                            .h = orig_h,
                                            .size_bytes = size_bytes,
                                            .mime_type = mime_type,
                                            .decode_time_ms = decode_time_ms,
                                            .conversion_time_ms = conversion_time_ms,
                                            .upload_time_ms = thumb_res.upload_time_ms,
                                            .memory_size_bytes = thumb_res.memory_size_bytes,
                                            .num_mip_levels = thumb_res.num_mip_levels,
                                            .mipmap_time_ms = thumb_res.mipmap_time_ms,
                                        },
                                    };
                                    var event = std.mem.zeroes(c.SDL_Event);
                                    event.type = c.SDL_EVENT_USER;
                                    _ = c.SDL_PushEvent(&event);
                                } else {
                                    c.SDL_ReleaseGPUTexture(gpu_dev, thumb_res.gpu_texture);
                                }
                            } else {
                                c.SDL_ReleaseGPUTexture(gpu_dev, thumb_res.gpu_texture);
                            }
                        } else {
                            c.SDL_ReleaseGPUTexture(gpu_dev, thumb_res.gpu_texture);
                        }
                        c.SDL_UnlockMutex(state.cache_mutex);
                    }
                }
            }

            // Full Resolution GPU Upload Pass
            if (graphics.uploadSurfaceToGpu(gpu_dev, f_surf)) |full_res| {
                uploaded_to_gpu = true;
                c.SDL_LockMutex(state.cache_mutex);
                defer c.SDL_UnlockMutex(state.cache_mutex);

                c.SDL_DestroySurface(f_surf);
                final_surface = null;

                if (!state.exiting.load(.acquire)) {
                    if (state.cache.getWithGeneration(index, args.generation)) |entry| {
                        var old_thumb_tex: ?*c.SDL_GPUTexture = null;
                        switch (entry.status) {
                            .loaded_cpu => |cpu| c.SDL_DestroySurface(cpu.surface),
                            .loaded_gpu => |gpu| old_thumb_tex = gpu.gpu_texture,
                            else => {},
                        }
                        entry.status = .{
                            .loaded_gpu = .{
                                .gpu_texture = full_res.gpu_texture,
                                .w = orig_w,
                                .h = orig_h,
                                .size_bytes = size_bytes,
                                .mime_type = mime_type,
                                .decode_time_ms = decode_time_ms,
                                .conversion_time_ms = conversion_time_ms,
                                .upload_time_ms = full_res.upload_time_ms,
                                .memory_size_bytes = full_res.memory_size_bytes,
                                .num_mip_levels = full_res.num_mip_levels,
                                .mipmap_time_ms = full_res.mipmap_time_ms,
                            },
                        };
                        if (old_thumb_tex) |old_tex| {
                            if (old_tex != full_res.gpu_texture) {
                                c.SDL_ReleaseGPUTexture(gpu_dev, old_tex);
                            }
                        }
                        var event = std.mem.zeroes(c.SDL_Event);
                        event.type = c.SDL_EVENT_USER;
                        _ = c.SDL_PushEvent(&event);

                        state.cache.enforceVramBudget(gpu_dev, state.current_index, CacheSlotMap.DEFAULT_MAX_VRAM_BYTES);
                    } else {
                        // Entry was evicted while uploading full res
                        c.SDL_ReleaseGPUTexture(gpu_dev, full_res.gpu_texture);
                    }
                } else {
                    c.SDL_ReleaseGPUTexture(gpu_dev, full_res.gpu_texture);
                }
            }
        }
    }

    if (!uploaded_to_gpu) {
        c.SDL_LockMutex(state.cache_mutex);
        defer c.SDL_UnlockMutex(state.cache_mutex);

        if (state.exiting.load(.acquire)) {
            if (final_surface) |surf| c.SDL_DestroySurface(surf);
            return 0;
        }

        var found_in_cache = false;
        if (state.cache.getWithGeneration(index, args.generation)) |entry| {
            found_in_cache = true;
            if (final_surface) |surf| {
                const orig_w: f32 = @floatFromInt(surf.*.w);
                const orig_h: f32 = @floatFromInt(surf.*.h);

                switch (entry.status) {
                    .loaded_cpu => |cpu| c.SDL_DestroySurface(cpu.surface),
                    .loaded_gpu => |gpu| c.SDL_ReleaseGPUTexture(state.gpu_device.?, gpu.gpu_texture),
                    else => {},
                }

                entry.status = .{
                    .loaded_cpu = .{
                        .surface = surf,
                        .w = orig_w,
                        .h = orig_h,
                        .size_bytes = size_bytes,
                        .mime_type = mime_type,
                        .decode_time_ms = decode_time_ms,
                        .conversion_time_ms = conversion_time_ms,
                    },
                };
            } else {
                entry.status = .failed;
            }
        } else {
            if (final_surface) |surf| c.SDL_DestroySurface(surf);
        }

        if (found_in_cache) {
            var event = std.mem.zeroes(c.SDL_Event);
            event.type = c.SDL_EVENT_USER;
            _ = c.SDL_PushEvent(&event);
        }
    }

    return 0;
}
