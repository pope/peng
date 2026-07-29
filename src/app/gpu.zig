const std = @import("std");
const sdl = @import("sdl");

/// Result payload returned after uploading a CPU surface to an SDL GPU texture,
/// including dimensions, memory usage, and timing statistics.
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

/// Uploads a CPU SDL surface to an SDL GPU texture using direct transfer buffers
/// or high-performance compute shader pixel unpacking when available.
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

    if (comp_pipeline_opt) |pipeline| {
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

        compute_pass.bindPipeline(pipeline);
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

    var memory_size_bytes: usize = size;
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

test "uploadSurfaceToGpu handles indexed and non-32bit pixel formats safely" {
    const dev_opt = sdl.gpu.Device.create(sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl, true);
    if (dev_opt == null) return;
    const dev = dev_opt.?;
    defer dev.destroy();

    // 1. Test index8 (indexed 8-bit image surface format)
    {
        const surf = sdl.Surface.create(16, 16, sdl.PixelFormat.index8) orelse return;
        defer surf.destroy();
        const upload_res = uploadSurfaceToGpu(dev, surf, null);
        try std.testing.expect(upload_res != null);
        if (upload_res) |res| {
            dev.releaseTexture(res.gpu_texture);
            try std.testing.expectEqual(@as(f32, 16.0), res.w);
            try std.testing.expectEqual(@as(f32, 16.0), res.h);
        }
    }

    // 2. Test rgb24 surface
    {
        const surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgb24) orelse return;
        defer surf.destroy();
        const upload_res = uploadSurfaceToGpu(dev, surf, null);
        try std.testing.expect(upload_res != null);
        if (upload_res) |res| {
            dev.releaseTexture(res.gpu_texture);
            try std.testing.expectEqual(@as(f32, 16.0), res.w);
            try std.testing.expectEqual(@as(f32, 16.0), res.h);
        }
    }

    // 3. Test bgr24 surface
    {
        const surf = sdl.Surface.create(16, 16, sdl.PixelFormat.bgr24) orelse return;
        defer surf.destroy();
        const upload_res = uploadSurfaceToGpu(dev, surf, null);
        try std.testing.expect(upload_res != null);
        if (upload_res) |res| {
            dev.releaseTexture(res.gpu_texture);
            try std.testing.expectEqual(@as(f32, 16.0), res.w);
            try std.testing.expectEqual(@as(f32, 16.0), res.h);
        }
    }
}
