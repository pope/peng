const std = @import("std");
const sdl = @import("sdl");
const core_fs = @import("fs.zig");
const state_pkg = @import("state");
const exif = @import("exif.zig");

const JpegDimensions = exif.JpegDimensions;
const parseExifDimensions = exif.parseExifDimensions;
const parseExifOrientation = exif.parseExifOrientation;

/// CPU surface component holding decoded image pixel buffer, dimensions, and decode timing.
const CpuSurfaceComponent = state_pkg.CpuSurfaceComponent;
const GpuTextureComponent = state_pkg.GpuTextureComponent;
const ThumbComponent = state_pkg.ThumbComponent;
const CacheStatus = state_pkg.CacheStatus;
const CacheEntry = state_pkg.CacheEntry;

pub const TextureHandle = struct {
    index: usize,
    generation: usize,
};

pub const CacheSlotMap = struct {
    entries: std.ArrayList(CacheEntry) = .empty,

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

pub fn detectMimeType(header: []const u8, path: []const u8) []const u8 {
    if (header.len >= 8 and std.mem.startsWith(u8, header, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) {
        return "image/png";
    }
    if (header.len >= 3 and std.mem.startsWith(u8, header, &[_]u8{ 0xFF, 0xD8, 0xFF })) {
        return "image/jpeg";
    }
    if (header.len >= 6 and (std.mem.startsWith(u8, header, "GIF87a") or std.mem.startsWith(u8, header, "GIF89a"))) {
        return "image/gif";
    }
    if (header.len >= 2 and std.mem.startsWith(u8, header, "BM")) {
        return "image/bmp";
    }
    if (header.len >= 12 and std.mem.startsWith(u8, header, "RIFF") and std.mem.eql(u8, header[8..12], "WEBP")) {
        return "image/webp";
    }

    const ext = std.fs.path.extension(path);
    if (core_fs.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (core_fs.eqlIgnoreCase(ext, ".jpg") or core_fs.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (core_fs.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (core_fs.eqlIgnoreCase(ext, ".bmp")) return "image/bmp";
    if (core_fs.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (core_fs.eqlIgnoreCase(ext, ".tga")) return "image/x-tga";

    return "unknown";
}

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

pub const GpuUploadResult = struct {
    gpu_texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    upload_time_ms: f64,
    memory_size_bytes: usize,
    num_mip_levels: u32,
    mipmap_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    was_fallback: bool = false,
    fallback_time_ms: f64 = 0.0,
};

pub fn uploadSurfaceToGpu(
    dev: sdl.gpu.Device,
    surf: sdl.Surface,
    comp_pipeline: ?sdl.gpu.ComputePipeline,
) ?GpuUploadResult {
    const start_upload = sdl.timer.getTicksNs();
    var current_surf = surf;

    const src_fmt = current_surf.format();
    const gpu_format: sdl.gpu.TextureFormat = switch (src_fmt) {
        sdl.PixelFormat.bgra32, sdl.PixelFormat.xrgb8888, sdl.PixelFormat.bgrx8888 => .bgra8_unorm,
        sdl.PixelFormat.rgba32, sdl.PixelFormat.xbgr8888, sdl.PixelFormat.rgbx8888 => .rgba8_unorm,
        else => .rgba8_unorm,
    };

    var scaled_surf: ?sdl.Surface = null;
    defer if (scaled_surf) |s| s.destroy();

    var img_w = current_surf.w();
    var img_h = current_surf.h();
    var tex: ?sdl.gpu.Texture = null;
    const max_dim_u: u32 = @intCast(@max(img_w, img_h));
    const num_levels: u32 = if (max_dim_u > 1) @intCast(std.math.log2(max_dim_u) + 1) else 1;
    var was_fallback: bool = false;
    var fallback_time_ms: f64 = 0.0;

    const u_w: usize = @intCast(img_w);
    const u_h: usize = @intCast(img_h);
    const cur_fmt = current_surf.format();
    const comp_pipeline_opt: ?sdl.gpu.ComputePipeline = if (cur_fmt == sdl.PixelFormat.rgb24 or cur_fmt == sdl.PixelFormat.bgr24) comp_pipeline else null;

    var tex_usage = sdl.gpu.TextureUsage.sampler | sdl.gpu.TextureUsage.color_target;
    if (comp_pipeline_opt != null) {
        tex_usage |= sdl.gpu.TextureUsage.compute_storage_write;
    }

    var img_tex_info = sdl.gpu.TextureCreateInfo{
        .type = .type_2d,
        .format = gpu_format,
        .usage = tex_usage,
        .width = @intCast(img_w),
        .height = @intCast(img_h),
        .layer_count_or_depth = 1,
        .num_levels = num_levels,
        .sample_count = .count_1,
        .props = 0,
    };
    tex = dev.createTexture(&img_tex_info);

    if (tex == null) {
        const start_fb = sdl.timer.getTicksNs();
        was_fallback = true;
        var try_max_dim: i32 = 8192;
        while (try_max_dim >= 2048) : (try_max_dim = @divTrunc(try_max_dim, 2)) {
            if (img_w > try_max_dim or img_h > try_max_dim) {
                var new_w = img_w;
                var new_h = img_h;
                if (img_w > img_h) {
                    new_w = try_max_dim;
                    new_h = @divTrunc(img_h * try_max_dim, img_w);
                } else {
                    new_h = try_max_dim;
                    new_w = @divTrunc(img_w * try_max_dim, img_h);
                }
                new_w = @max(1, new_w);
                new_h = @max(1, new_h);

                const new_scale = current_surf.scale(new_w, new_h, .linear);
                if (new_scale) |ns| {
                    if (scaled_surf) |s| s.destroy();
                    scaled_surf = ns;
                    current_surf = ns;
                    img_w = new_w;
                    img_h = new_h;

                    const fb_max_dim: u32 = @intCast(@max(img_w, img_h));
                    const fb_levels: u32 = if (fb_max_dim > 1) @intCast(std.math.log2(fb_max_dim) + 1) else 1;
                    img_tex_info.width = @intCast(img_w);
                    img_tex_info.height = @intCast(img_h);
                    img_tex_info.num_levels = fb_levels;
                    tex = dev.createTexture(&img_tex_info);
                    if (tex != null) break;
                } else {
                    std.log.err("uploadSurfaceToGpu: SDL_ScaleSurface fallback failed: {s}", .{sdl.getError()});
                    break;
                }
            }
        }
        const end_fb = sdl.timer.getTicksNs();
        fallback_time_ms = @as(f64, @floatFromInt(end_fb - start_fb)) / 1_000_000.0;
    }

    const gpu_tex = tex orelse return null;

    if (comp_pipeline_opt) |pipeline_handle| {
        const src_pitch: usize = @intCast(current_surf.pitch());
        const pixels: [*]const u8 = current_surf.pixels();
        const raw_bytes_len = src_pitch * u_h;

        const transfer_buf = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = @intCast(raw_bytes_len),
            .props = 0,
        }) orelse {
            dev.releaseTexture(gpu_tex);
            return null;
        };
        defer dev.releaseTransferBuffer(transfer_buf);

        const mapped = dev.mapTransferBuffer(transfer_buf, false) orelse {
            dev.releaseTexture(gpu_tex);
            return null;
        };
        @memcpy(mapped[0..raw_bytes_len], pixels[0..raw_bytes_len]);
        dev.unmapTransferBuffer(transfer_buf);

        const storage_buf_size = std.mem.alignForward(usize, raw_bytes_len, 4);
        const storage_buf = dev.createBuffer(&sdl.gpu.BufferCreateInfo{
            .usage = sdl.gpu.BufferUsage.compute_storage_read,
            .size = @intCast(storage_buf_size),
            .props = 0,
        }) orelse {
            dev.releaseTexture(gpu_tex);
            return null;
        };
        defer dev.releaseBuffer(storage_buf);

        const cmd_wrapper = dev.acquireCommandBuffer() orelse {
            dev.releaseTexture(gpu_tex);
            return null;
        };

        const copy_pass = cmd_wrapper.beginCopyPass() orelse {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        };
        copy_pass.uploadToBuffer(&sdl.gpu.TransferBufferLocation{
            .transfer_buffer = transfer_buf,
            .offset = 0,
        }, &sdl.gpu.BufferRegion{
            .buffer = storage_buf,
            .offset = 0,
            .size = @intCast(raw_bytes_len),
        }, false);
        copy_pass.end();

        const compute_pass = cmd_wrapper.beginComputePass(
            &[_]sdl.gpu.StorageTextureReadWriteBinding{.{ .texture = gpu_tex, .mip_level = 0, .layer = 0, .cycle = false }},
            null,
        ) orelse {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        };

        const Params = extern struct {
            width: u32,
            height: u32,
            is_bgr: u32,
            src_pitch: u32,
        };
        const params = Params{
            .width = @intCast(img_w),
            .height = @intCast(img_h),
            .is_bgr = if (cur_fmt == sdl.PixelFormat.bgr24) 1 else 0,
            .src_pitch = @intCast(src_pitch),
        };
        cmd_wrapper.pushComputeUniform(0, std.mem.asBytes(&params));

        compute_pass.bindPipeline(pipeline_handle);
        compute_pass.bindStorageBuffers(0, &[_]sdl.gpu.Buffer{storage_buf});
        const group_x: u32 = @intCast((u_w + 15) / 16);
        const group_y: u32 = @intCast((u_h + 15) / 16);
        compute_pass.dispatch(group_x, group_y, 1);
        compute_pass.end();

        var mipmap_time_ms: f64 = 0.0;
        if (num_levels > 1) {
            const start_mip = sdl.timer.getTicksNs();
            cmd_wrapper.generateMipmaps(gpu_tex);
            const end_mip = sdl.timer.getTicksNs();
            mipmap_time_ms = @as(f64, @floatFromInt(end_mip - start_mip)) / 1_000_000.0;
        }

        _ = cmd_wrapper.submit();

        const end_upload = sdl.timer.getTicksNs();
        const upload_time_ms = @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;

        var memory_size_bytes: usize = raw_bytes_len;
        if (num_levels > 1) {
            memory_size_bytes = (memory_size_bytes * 4) / 3;
        }

        return .{
            .gpu_texture = gpu_tex,
            .w = @floatFromInt(img_w),
            .h = @floatFromInt(img_h),
            .upload_time_ms = upload_time_ms,
            .memory_size_bytes = memory_size_bytes,
            .num_mip_levels = num_levels,
            .mipmap_time_ms = mipmap_time_ms,
            .conversion_time_ms = 0.0,
            .was_fallback = was_fallback,
            .fallback_time_ms = fallback_time_ms,
        };
    }

    const cmd_wrapper = dev.acquireCommandBuffer() orelse {
        dev.releaseTexture(gpu_tex);
        return null;
    };

    const dst_pitch: usize = u_w * 4;
    const size = dst_pitch * u_h;

    const transfer_buf = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
        .usage = .upload,
        .size = @intCast(size),
        .props = 0,
    }) orelse {
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };
    defer dev.releaseTransferBuffer(transfer_buf);

    const mapped = dev.mapTransferBuffer(transfer_buf, false) orelse {
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };

    const src_pixels: [*]const u8 = current_surf.pixels();
    const src_pitch: usize = @intCast(current_surf.pitch());
    var conversion_time_ms: f64 = 0.0;
    const is_32bit_fmt = switch (cur_fmt) {
        sdl.PixelFormat.rgba32, sdl.PixelFormat.bgra32, sdl.PixelFormat.xrgb8888, sdl.PixelFormat.xbgr8888, sdl.PixelFormat.rgbx8888, sdl.PixelFormat.bgrx8888 => true,
        else => false,
    };
    if (is_32bit_fmt) {
        if (src_pitch == dst_pitch) {
            @memcpy(mapped[0..size], src_pixels[0..size]);
        } else {
            var y: usize = 0;
            while (y < u_h) : (y += 1) {
                @memcpy(mapped[y * dst_pitch .. y * dst_pitch + u_w * 4], src_pixels[y * src_pitch .. y * src_pitch + u_w * 4]);
            }
        }
    } else if (cur_fmt == sdl.PixelFormat.rgb24) {
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertRgb24ToRgba32Simd(src_pixels[0 .. src_pitch * u_h], mapped[0..size], u_w, u_h, src_pitch, dst_pitch);
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms = @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
    } else if (cur_fmt == sdl.PixelFormat.bgr24) {
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertBgr24ToRgba32Simd(src_pixels[0 .. src_pitch * u_h], mapped[0..size], u_w, u_h, src_pitch, dst_pitch);
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms = @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
    } else {
        const start_conv = sdl.timer.getTicksNs();
        const tmp_surf = current_surf.convert(sdl.PixelFormat.rgba32);
        if (tmp_surf) |ts| {
            defer ts.destroy();
            const ts_pixels = ts.pixels();
            const ts_pitch: usize = @intCast(ts.pitch());
            if (ts_pitch == dst_pitch) {
                @memcpy(mapped[0..size], ts_pixels[0..size]);
            } else {
                var y: usize = 0;
                while (y < u_h) : (y += 1) {
                    @memcpy(mapped[y * dst_pitch .. y * dst_pitch + u_w * 4], ts_pixels[y * ts_pitch .. y * ts_pitch + u_w * 4]);
                }
            }
            const end_conv = sdl.timer.getTicksNs();
            conversion_time_ms = @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
        } else {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        }
    }

    const copy_pass = cmd_wrapper.beginCopyPass() orelse {
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };

    copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = @intCast(u_w),
        .rows_per_layer = @intCast(u_h),
    }, &sdl.gpu.TextureRegion{
        .texture = gpu_tex,
        .w = @intCast(img_w),
        .h = @intCast(img_h),
        .d = 1,
    }, false);
    copy_pass.end();

    var mipmap_time_ms: f64 = 0.0;
    if (num_levels > 1) {
        const start_mip = sdl.timer.getTicksNs();
        cmd_wrapper.generateMipmaps(gpu_tex);
        const end_mip = sdl.timer.getTicksNs();
        mipmap_time_ms = @as(f64, @floatFromInt(end_mip - start_mip)) / 1_000_000.0;
    }

    _ = cmd_wrapper.submit();

    const end_upload = sdl.timer.getTicksNs();
    const upload_time_ms = @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;

    var memory_size_bytes: usize = u_w * u_h * 4;
    if (num_levels > 1) {
        memory_size_bytes = (memory_size_bytes * 4) / 3;
    }

    return .{
        .gpu_texture = gpu_tex,
        .w = @floatFromInt(img_w),
        .h = @floatFromInt(img_h),
        .upload_time_ms = upload_time_ms,
        .memory_size_bytes = memory_size_bytes,
        .num_mip_levels = num_levels,
        .mipmap_time_ms = mipmap_time_ms,
        .conversion_time_ms = conversion_time_ms,
        .was_fallback = was_fallback,
        .fallback_time_ms = fallback_time_ms,
    };
}
