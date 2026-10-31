//! GPU Texture Upload and Staging Module
//!
//! Provides reusable host staging buffers, format conversion, and GPU texture
//! uploads with automatic mipmap generation and compute unpack pipelines.

const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const IngestTelemetry = state_pkg.IngestTelemetry;
const MipmapTelemetry = state_pkg.MipmapTelemetry;
const UploadMode = state_pkg.UploadMode;

/// Reusable GPU staging buffers for texture uploads, eliminating allocation
/// and deallocation churn on every frame by retaining and geometrically
/// growing transfer and storage buffers.
///
/// TODO: Add heuristics to periodically evaluate and shrink retained staging
/// buffers after a duration/inactivity threshold (or high-water decay) so
/// memory is reclaimed if a single exceptionally large image temporarily
/// expanded capacity.
pub const UploadStagingBuffer = struct {
    transfer: sdl.gpu.RetainedTransferBuffer = .unallocated,
    storage: sdl.gpu.RetainedBuffer = .unallocated,

    /// Releases retained GPU transfer and compute storage buffers.
    pub fn deinit(self: *UploadStagingBuffer, dev: sdl.gpu.Device) void {
        switch (self.transfer) {
            .unallocated => {},
            .allocated => |a| {
                dev.releaseTransferBuffer(a.handle);
                self.transfer = .unallocated;
            },
        }
        switch (self.storage) {
            .unallocated => {},
            .allocated => |a| {
                dev.releaseBuffer(a.handle);
                self.storage = .unallocated;
            },
        }
    }

    /// Obtains a transfer buffer with at least `required_size` capacity,
    /// reusing the existing buffer or reallocating with geometric growth
    /// when capacity is insufficient.
    fn getOrCreateTransferBuffer(
        self: *UploadStagingBuffer,
        dev: sdl.gpu.Device,
        required_size: usize,
    ) ?sdl.gpu.TransferBuffer {
        const growth_cap = switch (self.transfer) {
            .allocated => |a| blk: {
                if (a.capacity >= required_size) return a.handle;
                dev.releaseTransferBuffer(a.handle);
                self.transfer = .unallocated;
                break :blk a.capacity * 2;
            },
            .unallocated => 4 * 1024 * 1024,
        };
        const next_cap = @max(required_size, growth_cap);
        const aligned_cap = std.mem.alignForward(usize, next_cap, 4 * 1024);

        const tb = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = @intCast(aligned_cap),
            .props = 0,
        }) orelse return null;
        self.transfer = .{
            .allocated = .{ .handle = tb, .capacity = aligned_cap },
        };
        return tb;
    }

    /// Obtains a compute storage buffer with at least `required_size`
    /// capacity, reusing the existing buffer or reallocating with geometric
    /// growth when capacity is insufficient.
    fn getOrCreateStorageBuffer(
        self: *UploadStagingBuffer,
        dev: sdl.gpu.Device,
        required_size: usize,
    ) ?sdl.gpu.Buffer {
        const growth_cap = switch (self.storage) {
            .allocated => |a| blk: {
                if (a.capacity >= required_size) return a.handle;
                dev.releaseBuffer(a.handle);
                self.storage = .unallocated;
                break :blk a.capacity * 2;
            },
            .unallocated => 4 * 1024 * 1024,
        };
        const next_cap = @max(required_size, growth_cap);
        const aligned_cap = std.mem.alignForward(usize, next_cap, 4 * 1024);

        const sb = dev.createBuffer(&sdl.gpu.BufferCreateInfo{
            .usage = sdl.gpu.BufferUsage.compute_storage_read,
            .size = @intCast(aligned_cap),
            .props = 0,
        }) orelse return null;
        self.storage = .{
            .allocated = .{ .handle = sb, .capacity = aligned_cap },
        };
        return sb;
    }
};

/// Result payload containing the created GPU texture, dimensions, and
/// ingestion telemetry.
pub const GpuUploadResult = struct {
    gpu_texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    ingest: IngestTelemetry = .{},
};

/// Computes the mipmap pyramid level count for a 2D texture of size `w` x `h`.
fn computeMipLevels(w: i32, h: i32) u32 {
    const max_dim_u: u32 = @intCast(@max(1, @max(w, h)));
    return if (max_dim_u > 1)
        @intCast(std.math.log2(max_dim_u) + 1)
    else
        1;
}

/// Aspect-preserving dimensions and mipmap level count for fallback scaling.
const FallbackScaleDims = struct {
    w: i32,
    h: i32,
    num_levels: u32,
};

/// Computes aspect-preserving fallback dimensions and mipmap levels when a
/// surface exceeds `try_max_dim`. Returns `null` if both dimensions fit.
fn computeFallbackScaleDims(
    img_w: i32,
    img_h: i32,
    try_max_dim: i32,
) ?FallbackScaleDims {
    if (img_w <= 0 or img_h <= 0 or try_max_dim <= 0) return null;
    if (img_w <= try_max_dim and img_h <= try_max_dim) return null;
    var new_w = img_w;
    var new_h = img_h;
    if (img_w > img_h) {
        new_w = try_max_dim;
        new_h = @intCast(@divTrunc(
            @as(i64, img_h) * @as(i64, try_max_dim),
            @as(i64, img_w),
        ));
    } else {
        new_h = try_max_dim;
        new_w = @intCast(@divTrunc(
            @as(i64, img_w) * @as(i64, try_max_dim),
            @as(i64, img_h),
        ));
    }
    new_w = @max(1, new_w);
    new_h = @max(1, new_h);
    return .{
        .w = new_w,
        .h = new_h,
        .num_levels = computeMipLevels(new_w, new_h),
    };
}

/// Copies or converts `current_surf` into a tightly packed 32-bit `mapped`
/// transfer buffer of size `dst_pitch * u_h`, returning conversion time in ms.
fn stageSurfaceToRgba32(
    current_surf: sdl.Surface,
    mapped: []u8,
    u_w: usize,
    u_h: usize,
    dst_pitch: usize,
    cur_fmt: u32,
) ?f64 {
    const size = dst_pitch * u_h;
    const src_pixels: [*]const u8 = current_surf.pixels();
    const src_pitch: usize = @intCast(current_surf.pitch());
    var conversion_time_ms: f64 = 0.0;
    const is_32bit_fmt = switch (cur_fmt) {
        sdl.PixelFormat.rgba32,
        sdl.PixelFormat.bgra32,
        sdl.PixelFormat.xrgb8888,
        sdl.PixelFormat.xbgr8888,
        sdl.PixelFormat.rgbx8888,
        sdl.PixelFormat.bgrx8888,
        => true,
        else => false,
    };
    if (is_32bit_fmt) {
        if (src_pitch == dst_pitch) {
            @memcpy(mapped[0..size], src_pixels[0..size]);
        } else {
            var y: usize = 0;
            while (y < u_h) : (y += 1) {
                const row_len = u_w * 4;
                @memcpy(
                    mapped[y * dst_pitch .. y * dst_pitch + row_len],
                    src_pixels[y * src_pitch .. y * src_pitch + row_len],
                );
            }
        }
    } else if (cur_fmt == sdl.PixelFormat.rgb24) {
        // NOTE: If the GPU compute unpack pipeline is unavailable, RGB24/BGR24
        // falls back to main-thread SIMD conversion here. Plumbing
        // `has_compute_unpack: bool` through DecodeArgs can offload this to
        // background decode workers if this log appears in practice.
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertRgb24ToRgba32Simd(
            src_pixels[0 .. src_pitch * u_h],
            mapped[0..size],
            u_w,
            u_h,
            src_pitch,
            dst_pitch,
        );
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms =
            @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
        std.log.info(
            "main-thread RGB24 conversion ({d}x{d}) took {d:.2}ms",
            .{ u_w, u_h, conversion_time_ms },
        );
    } else if (cur_fmt == sdl.PixelFormat.bgr24) {
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertBgr24ToRgba32Simd(
            src_pixels[0 .. src_pitch * u_h],
            mapped[0..size],
            u_w,
            u_h,
            src_pitch,
            dst_pitch,
        );
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms =
            @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
        std.log.info(
            "main-thread BGR24 conversion ({d}x{d}) took {d:.2}ms",
            .{ u_w, u_h, conversion_time_ms },
        );
    } else {
        const start_conv = sdl.timer.getTicksNs();
        const tmp_surf = current_surf.convert(sdl.PixelFormat.rgba32) orelse
            return null;
        defer tmp_surf.destroy();
        const ts_pixels = tmp_surf.pixels();
        const ts_pitch: usize = @intCast(tmp_surf.pitch());
        if (ts_pitch == dst_pitch) {
            @memcpy(mapped[0..size], ts_pixels[0..size]);
        } else {
            var y: usize = 0;
            while (y < u_h) : (y += 1) {
                const row_len = u_w * 4;
                @memcpy(
                    mapped[y * dst_pitch .. y * dst_pitch + row_len],
                    ts_pixels[y * ts_pitch .. y * ts_pitch + row_len],
                );
            }
        }
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms =
            @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
    }
    return conversion_time_ms;
}

fn computeTextureVramBytes(u_w: usize, u_h: usize, num_levels: u32) usize {
    const base_bytes: usize = u_w * u_h * 4;
    return if (num_levels > 1) (base_bytes * 4) / 3 else base_bytes;
}

/// Uploads a CPU surface into an SDL GPU texture with automatic mipmap pyramid
/// generation, using an optional compute pipeline for fast RGB24/BGR24 unpack
/// and optional staging buffer reuse.
pub fn uploadSurfaceToGpu(
    dev: sdl.gpu.Device,
    surf: sdl.Surface,
    comp_pipeline: ?sdl.gpu.ComputePipeline,
    staging: ?*UploadStagingBuffer,
) ?GpuUploadResult {
    const start_upload = sdl.timer.getTicksNs();
    var current_surf = surf;

    const src_fmt = current_surf.format();
    const gpu_format: sdl.gpu.TextureFormat = switch (src_fmt) {
        sdl.PixelFormat.bgra32,
        sdl.PixelFormat.xrgb8888,
        sdl.PixelFormat.bgrx8888,
        => .bgra8_unorm,
        sdl.PixelFormat.rgba32,
        sdl.PixelFormat.xbgr8888,
        sdl.PixelFormat.rgbx8888,
        => .rgba8_unorm,
        else => .rgba8_unorm,
    };

    var scaled_surf: ?sdl.Surface = null;
    defer if (scaled_surf) |s| s.destroy();

    var img_w = current_surf.w();
    var img_h = current_surf.h();
    if (img_w <= 0 or img_h <= 0) return null;
    var tex: ?sdl.gpu.Texture = null;
    var num_levels: u32 = computeMipLevels(img_w, img_h);
    var was_fallback: bool = false;
    var fallback_time_ms: f64 = 0.0;

    const comp_pipeline_opt: ?sdl.gpu.ComputePipeline =
        if (src_fmt == sdl.PixelFormat.rgb24 or
        src_fmt == sdl.PixelFormat.bgr24)
            comp_pipeline
        else
            null;

    var tex_usage =
        sdl.gpu.TextureUsage.sampler | sdl.gpu.TextureUsage.color_target;
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
        while (try_max_dim >= 2048) : (try_max_dim = @divTrunc(
            try_max_dim,
            2,
        )) {
            if (computeFallbackScaleDims(img_w, img_h, try_max_dim)) |fb| {
                const new_scale = current_surf.scale(fb.w, fb.h, .linear);
                if (new_scale) |ns| {
                    if (scaled_surf) |s| s.destroy();
                    scaled_surf = ns;
                    current_surf = ns;
                    img_w = fb.w;
                    img_h = fb.h;
                    num_levels = fb.num_levels;

                    img_tex_info.width = @intCast(img_w);
                    img_tex_info.height = @intCast(img_h);
                    img_tex_info.num_levels = num_levels;
                    tex = dev.createTexture(&img_tex_info);
                    if (tex != null) break;
                } else {
                    std.log.err(
                        "uploadSurfaceToGpu: SDL_ScaleSurface failed: {s}",
                        .{sdl.getError()},
                    );
                    break;
                }
            }
        }
        const end_fb = sdl.timer.getTicksNs();
        fallback_time_ms =
            @as(f64, @floatFromInt(end_fb - start_fb)) / 1_000_000.0;
    }

    const gpu_tex = tex orelse return null;
    const u_w: usize = @intCast(img_w);
    const u_h: usize = @intCast(img_h);
    const cur_fmt = current_surf.format();

    if (comp_pipeline_opt) |pipeline_handle| {
        const src_pitch: usize = @intCast(current_surf.pitch());
        const pixels: [*]const u8 = current_surf.pixels();
        const raw_bytes_len = src_pitch * u_h;
        const storage_buf_size = std.mem.alignForward(usize, raw_bytes_len, 4);

        const is_staged = (staging != null);
        const transfer_buf = if (staging) |st|
            st.getOrCreateTransferBuffer(dev, raw_bytes_len) orelse {
                dev.releaseTexture(gpu_tex);
                return null;
            }
        else
            dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
                .usage = .upload,
                .size = @intCast(raw_bytes_len),
                .props = 0,
            }) orelse {
                dev.releaseTexture(gpu_tex);
                return null;
            };
        defer if (!is_staged) dev.releaseTransferBuffer(transfer_buf);

        const mapped = dev.mapTransferBuffer(transfer_buf, is_staged) orelse {
            dev.releaseTexture(gpu_tex);
            return null;
        };
        @memcpy(mapped[0..raw_bytes_len], pixels[0..raw_bytes_len]);
        dev.unmapTransferBuffer(transfer_buf);

        const storage_buf = if (staging) |st|
            st.getOrCreateStorageBuffer(dev, storage_buf_size) orelse {
                dev.releaseTexture(gpu_tex);
                return null;
            }
        else
            dev.createBuffer(&sdl.gpu.BufferCreateInfo{
                .usage = sdl.gpu.BufferUsage.compute_storage_read,
                .size = @intCast(storage_buf_size),
                .props = 0,
            }) orelse {
                dev.releaseTexture(gpu_tex);
                return null;
            };
        defer if (!is_staged) dev.releaseBuffer(storage_buf);

        const cmd_wrapper = dev.acquireCommandBuffer() orelse {
            dev.releaseTexture(gpu_tex);
            return null;
        };

        const copy_pass = cmd_wrapper.beginCopyPass() orelse {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        };
        // Cycle `storage_buf` when shared across staged uploads (`is_staged`)
        // to avoid GPU WAR/WAW hazards with in-flight compute unpack passes.
        copy_pass.uploadToBuffer(&sdl.gpu.TransferBufferLocation{
            .transfer_buffer = transfer_buf,
            .offset = 0,
        }, &sdl.gpu.BufferRegion{
            .buffer = storage_buf,
            .offset = 0,
            .size = @intCast(raw_bytes_len),
        }, is_staged);
        copy_pass.end();

        const compute_pass = cmd_wrapper.beginComputePass(
            &[_]sdl.gpu.StorageTextureReadWriteBinding{.{
                .texture = gpu_tex,
                .mip_level = 0,
                .layer = 0,
                .cycle = false,
            }},
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
        const group_x: u32 = @intCast(@divCeil(u_w, 16));
        const group_y: u32 = @intCast(@divCeil(u_h, 16));
        compute_pass.dispatch(group_x, group_y, 1);
        compute_pass.end();

        var mipmap_time_ms: f64 = 0.0;
        if (num_levels > 1) {
            const start_mip = sdl.timer.getTicksNs();
            cmd_wrapper.generateMipmaps(gpu_tex);
            const end_mip = sdl.timer.getTicksNs();
            mipmap_time_ms =
                @as(f64, @floatFromInt(end_mip - start_mip)) / 1_000_000.0;
        }

        _ = cmd_wrapper.submit();

        const end_upload = sdl.timer.getTicksNs();
        const upload_time_ms =
            @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;

        const memory_size_bytes = computeTextureVramBytes(
            u_w,
            u_h,
            num_levels,
        );

        return .{
            .gpu_texture = gpu_tex,
            .w = @floatFromInt(img_w),
            .h = @floatFromInt(img_h),
            .ingest = .{
                .upload_time_ms = upload_time_ms,
                .memory_size_bytes = memory_size_bytes,
                .mode = UploadMode.init(
                    was_fallback,
                    fallback_time_ms,
                ),
                .mipmaps = MipmapTelemetry.init(
                    num_levels,
                    mipmap_time_ms,
                ),
            },
        };
    }

    const cmd_wrapper = dev.acquireCommandBuffer() orelse {
        dev.releaseTexture(gpu_tex);
        return null;
    };

    const dst_pitch: usize = u_w * 4;
    const size = dst_pitch * u_h;

    const is_staged = (staging != null);
    const transfer_buf = if (staging) |st|
        st.getOrCreateTransferBuffer(dev, size) orelse {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        }
    else
        dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = @intCast(size),
            .props = 0,
        }) orelse {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        };
    defer if (!is_staged) dev.releaseTransferBuffer(transfer_buf);

    const mapped = dev.mapTransferBuffer(transfer_buf, is_staged) orelse {
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };

    _ = stageSurfaceToRgba32(
        current_surf,
        mapped[0..size],
        u_w,
        u_h,
        dst_pitch,
        cur_fmt,
    ) orelse {
        dev.unmapTransferBuffer(transfer_buf);
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };

    dev.unmapTransferBuffer(transfer_buf);

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
        mipmap_time_ms =
            @as(f64, @floatFromInt(end_mip - start_mip)) / 1_000_000.0;
    }

    _ = cmd_wrapper.submit();

    const end_upload = sdl.timer.getTicksNs();
    const upload_time_ms =
        @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;

    const memory_size_bytes = computeTextureVramBytes(
        u_w,
        u_h,
        num_levels,
    );

    return .{
        .gpu_texture = gpu_tex,
        .w = @floatFromInt(img_w),
        .h = @floatFromInt(img_h),
        .ingest = .{
            .upload_time_ms = upload_time_ms,
            .memory_size_bytes = memory_size_bytes,
            .mode = UploadMode.init(
                was_fallback,
                fallback_time_ms,
            ),
            .mipmaps = MipmapTelemetry.init(
                num_levels,
                mipmap_time_ms,
            ),
        },
    };
}

test "UploadStagingBuffer - capacity growth and clean deinit" {
    var staging = UploadStagingBuffer{};
    try std.testing.expect(staging.transfer == .unallocated);
    try std.testing.expect(staging.storage == .unallocated);

    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    // Initial allocation should be at least 4MB aligned to 4KB
    const tb1 = staging.getOrCreateTransferBuffer(dev, 1024);
    try std.testing.expect(tb1 != null);
    try std.testing.expectEqual(
        @as(usize, 4 * 1024 * 1024),
        staging.transfer.allocated.capacity,
    );

    // Reuse existing buffer when required_size <= transfer_capacity
    const tb2 = staging.getOrCreateTransferBuffer(dev, 2 * 1024 * 1024);
    try std.testing.expect(tb2 != null);
    try std.testing.expectEqual(
        @as(usize, 4 * 1024 * 1024),
        staging.transfer.allocated.capacity,
    );

    // Reallocation with geometric growth (4MB -> 8MB) when required
    // exceeds capacity
    const tb3 = staging.getOrCreateTransferBuffer(dev, 5 * 1024 * 1024);
    try std.testing.expect(tb3 != null);
    try std.testing.expectEqual(
        @as(usize, 8 * 1024 * 1024),
        staging.transfer.allocated.capacity,
    );

    // Storage buffer test
    const sb1 = staging.getOrCreateStorageBuffer(dev, 1024);
    try std.testing.expect(sb1 != null);
    try std.testing.expectEqual(
        @as(usize, 4 * 1024 * 1024),
        staging.storage.allocated.capacity,
    );

    // Deinit releases all buffers and resets capacities
    staging.deinit(dev);
    try std.testing.expect(staging.transfer == .unallocated);
    try std.testing.expect(staging.storage == .unallocated);
}

test "uploadSurfaceToGpu - staging buffer reuse across consecutive uploads" {
    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var staging = UploadStagingBuffer{};
    defer staging.deinit(dev);

    const surf1 = sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse
        return;
    defer surf1.destroy();

    const res1 = uploadSurfaceToGpu(dev, surf1, null, &staging);
    try std.testing.expect(res1 != null);
    if (res1) |r| {
        dev.releaseTexture(r.gpu_texture);
        try std.testing.expectEqual(@as(f32, 64.0), r.w);
        try std.testing.expectEqual(@as(f32, 64.0), r.h);
    }

    try std.testing.expect(staging.transfer == .allocated);
    const cap1 = staging.transfer.allocated.capacity;
    try std.testing.expect(cap1 >= 64 * 64 * 4);

    // Second upload should reuse staging transfer buffer without reallocating
    const surf2 = sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse
        return;
    defer surf2.destroy();

    const res2 = uploadSurfaceToGpu(dev, surf2, null, &staging);
    try std.testing.expect(res2 != null);
    if (res2) |r| {
        dev.releaseTexture(r.gpu_texture);
        try std.testing.expectEqual(@as(f32, 32.0), r.w);
        try std.testing.expectEqual(@as(f32, 32.0), r.h);
    }

    try std.testing.expectEqual(cap1, staging.transfer.allocated.capacity);
}

test "computeFallbackScaleDims and stageSurfaceToRgba32 downscale safely" {
    const allocator = std.testing.allocator;

    // 1. Non-positive or already-fitting dimensions return null
    try std.testing.expect(computeFallbackScaleDims(0, 10000, 8192) == null);
    try std.testing.expect(computeFallbackScaleDims(10000, -1, 8192) == null);
    try std.testing.expect(computeFallbackScaleDims(10000, 10000, 0) == null);
    try std.testing.expect(computeFallbackScaleDims(4096, 2048, 8192) == null);

    // 2. Landscape downscale updates width, height, and mip levels
    const fb_land = computeFallbackScaleDims(16384, 8192, 8192).?;
    try std.testing.expectEqual(@as(i32, 8192), fb_land.w);
    try std.testing.expectEqual(@as(i32, 4096), fb_land.h);
    try std.testing.expectEqual(@as(u32, 14), fb_land.num_levels);

    // 3. Portrait and huge dimensions clamp to >= 1 without i32 overflow
    const fb_port = computeFallbackScaleDims(10, 300_000, 8192).?;
    try std.testing.expectEqual(@as(i32, 1), fb_port.w);
    try std.testing.expectEqual(@as(i32, 8192), fb_port.h);
    try std.testing.expectEqual(@as(u32, 14), fb_port.num_levels);

    const fb_huge = computeFallbackScaleDims(300_000, 600_000, 8192).?;
    try std.testing.expectEqual(@as(i32, 4096), fb_huge.w);
    try std.testing.expectEqual(@as(i32, 8192), fb_huge.h);
    try std.testing.expectEqual(@as(u32, 14), fb_huge.num_levels);

    // 4. Downscaled RGB24 surface stages using updated dims without over-read
    const orig_surf = sdl.Surface.create(128, 64, sdl.PixelFormat.rgb24).?;
    defer orig_surf.destroy();
    const fb = computeFallbackScaleDims(orig_surf.w(), orig_surf.h(), 64).?;
    try std.testing.expectEqual(@as(i32, 64), fb.w);
    try std.testing.expectEqual(@as(i32, 32), fb.h);

    const scaled = orig_surf.scale(fb.w, fb.h, .linear).?;
    defer scaled.destroy();

    const u_w: usize = @intCast(scaled.w());
    const u_h: usize = @intCast(scaled.h());
    const dst_pitch: usize = u_w * 4;
    const mapped = try allocator.alloc(u8, dst_pitch * u_h);
    defer allocator.free(mapped);

    const conv_ms = stageSurfaceToRgba32(
        scaled,
        mapped,
        u_w,
        u_h,
        dst_pitch,
        scaled.format(),
    );
    try std.testing.expect(conv_ms != null);
}

test "computeTextureVramBytes - reports 4bpp RGBA8 footprint with mipmaps" {
    try std.testing.expectEqual(
        @as(usize, 100 * 50 * 4),
        computeTextureVramBytes(100, 50, 1),
    );
    try std.testing.expectEqual(
        @as(usize, (100 * 50 * 4 * 4) / 3),
        computeTextureVramBytes(100, 50, 8),
    );
}
