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
/// growing transfer and storage buffers. Buffers up to
/// `WARM_STAGING_CAP_BYTES` (32 MiB) remain warm across frames; oversized
/// buffers decay back to `.unallocated` after `IDLE_DECAY_MS` (5000 ms) of
/// upload and decode inactivity.
pub const UploadStagingBuffer = struct {
    pub const WARM_STAGING_CAP_BYTES: usize = 32 * 1024 * 1024;
    pub const IDLE_DECAY_MS: u64 = 5000;

    transfer: sdl.gpu.RetainedTransferBuffer = .unallocated,
    storage: sdl.gpu.RetainedBuffer = .unallocated,
    oversized_since_ms: ?u64 = null,

    /// Releases retained GPU transfer and compute storage buffers and resets
    /// the idle decay timer.
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
        self.oversized_since_ms = null;
    }

    fn isTransferOversized(self: UploadStagingBuffer) bool {
        return switch (self.transfer) {
            .unallocated => false,
            .allocated => |a| a.capacity > WARM_STAGING_CAP_BYTES,
        };
    }

    fn isStorageOversized(self: UploadStagingBuffer) bool {
        return switch (self.storage) {
            .unallocated => false,
            .allocated => |a| a.capacity > WARM_STAGING_CAP_BYTES,
        };
    }

    fn hasOversizedBuffer(self: UploadStagingBuffer) bool {
        return self.isTransferOversized() or self.isStorageOversized();
    }

    /// Releases retained staging buffers exceeding `WARM_STAGING_CAP_BYTES`
    /// back to `.unallocated` after `IDLE_DECAY_MS` of upload and decode
    /// inactivity while keeping buffers at or below `WARM_STAGING_CAP_BYTES`
    /// warm. Returns `true` if any buffer was released.
    pub fn maybeShrinkIdle(
        self: *UploadStagingBuffer,
        dev: sdl.gpu.Device,
        now_ms: u64,
        is_idle: bool,
    ) bool {
        if (!self.hasOversizedBuffer()) {
            self.oversized_since_ms = null;
            return false;
        }
        if (!is_idle) {
            self.oversized_since_ms = now_ms;
            return false;
        }
        const since = self.oversized_since_ms orelse {
            self.oversized_since_ms = now_ms;
            return false;
        };
        if (now_ms -| since < IDLE_DECAY_MS) {
            return false;
        }
        switch (self.transfer) {
            .unallocated => {},
            .allocated => |a| {
                if (a.capacity > WARM_STAGING_CAP_BYTES) {
                    dev.releaseTransferBuffer(a.handle);
                    self.transfer = .unallocated;
                }
            },
        }
        switch (self.storage) {
            .unallocated => {},
            .allocated => |a| {
                if (a.capacity > WARM_STAGING_CAP_BYTES) {
                    dev.releaseBuffer(a.handle);
                    self.storage = .unallocated;
                }
            },
        }
        self.oversized_since_ms = null;
        return true;
    }

    /// Returns remaining milliseconds until the idle decay deadline expires,
    /// or `null` when no oversized buffer decay is pending.
    pub fn decayTimeoutMs(self: UploadStagingBuffer, now_ms: u64) ?u32 {
        const since = self.oversized_since_ms orelse return null;
        const rem = IDLE_DECAY_MS -| (now_ms -| since);
        return @intCast(@max(1, rem));
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
    io: std.Io,
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
        const start_conv = std.Io.Clock.awake.now(io);
        sdl.surface.convertRgb24ToRgba32Simd(
            src_pixels[0 .. src_pitch * u_h],
            mapped[0..size],
            u_w,
            u_h,
            src_pitch,
            dst_pitch,
        );
        conversion_time_ms = state_pkg.durationToMs(
            start_conv.untilNow(io, .awake),
        );
        std.log.info(
            "main-thread RGB24 conversion ({d}x{d}) took {d:.2}ms",
            .{ u_w, u_h, conversion_time_ms },
        );
    } else if (cur_fmt == sdl.PixelFormat.bgr24) {
        const start_conv = std.Io.Clock.awake.now(io);
        sdl.surface.convertBgr24ToRgba32Simd(
            src_pixels[0 .. src_pitch * u_h],
            mapped[0..size],
            u_w,
            u_h,
            src_pitch,
            dst_pitch,
        );
        conversion_time_ms = state_pkg.durationToMs(
            start_conv.untilNow(io, .awake),
        );
        std.log.info(
            "main-thread BGR24 conversion ({d}x{d}) took {d:.2}ms",
            .{ u_w, u_h, conversion_time_ms },
        );
    } else {
        const start_conv = std.Io.Clock.awake.now(io);
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
        conversion_time_ms = state_pkg.durationToMs(
            start_conv.untilNow(io, .awake),
        );
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
    io: std.Io,
    dev: sdl.gpu.Device,
    surf: sdl.Surface,
    comp_pipeline: ?sdl.gpu.ComputePipeline,
    staging: ?*UploadStagingBuffer,
) ?GpuUploadResult {
    const start_upload = std.Io.Clock.awake.now(io);
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
        const start_fb = std.Io.Clock.awake.now(io);
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
        fallback_time_ms = state_pkg.durationToMs(
            start_fb.untilNow(io, .awake),
        );
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
            &[_]sdl.gpu.StorageTextureReadWriteBinding{
                .{
                    .texture = gpu_tex,
                    .mip_level = 0,
                    .layer = 0,
                    .cycle = false,
                },
            },
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
            const start_mip = std.Io.Clock.awake.now(io);
            cmd_wrapper.generateMipmaps(gpu_tex);
            mipmap_time_ms = state_pkg.durationToMs(
                start_mip.untilNow(io, .awake),
            );
        }

        _ = cmd_wrapper.submit();

        const upload_time_ms = state_pkg.durationToMs(
            start_upload.untilNow(io, .awake),
        );

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
        io,
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
        const start_mip = std.Io.Clock.awake.now(io);
        cmd_wrapper.generateMipmaps(gpu_tex);
        mipmap_time_ms = state_pkg.durationToMs(
            start_mip.untilNow(io, .awake),
        );
    }

    _ = cmd_wrapper.submit();

    const upload_time_ms = state_pkg.durationToMs(
        start_upload.untilNow(io, .awake),
    );

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

    const io = std.Io.Threaded.global_single_threaded.io();
    const res1 = uploadSurfaceToGpu(io, dev, surf1, null, &staging);
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

    const res2 = uploadSurfaceToGpu(io, dev, surf2, null, &staging);
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

    const io = std.Io.Threaded.global_single_threaded.io();
    const conv_ms = stageSurfaceToRgba32(
        io,
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

test "uploadSurfaceToGpu - compute pipeline unpacks RGB24 and BGR24 pixels" {
    if (!sdl.init(sdl.init_flags.video)) return;
    defer sdl.quit();

    const dev = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        false,
    ) orelse return;
    defer dev.destroy();

    const comp_code_spv = @embedFile("shaders/unpack_rgb.spv");
    const comp_code_msl = @embedFile("shaders/unpack_rgb.msl");
    const shader_formats = dev.getShaderFormats();
    const is_spirv = (shader_formats & sdl.gpu.ShaderFormat.spirv) != 0;
    const comp_code = if (is_spirv) comp_code_spv else comp_code_msl;

    const comp_info = sdl.gpu.ComputePipelineCreateInfo{
        .code_size = comp_code.len,
        .code = comp_code.ptr,
        .entrypoint = if (is_spirv) "main" else "main0",
        .format = if (is_spirv)
            sdl.gpu.ShaderFormat.spirv
        else
            sdl.gpu.ShaderFormat.msl,
        .num_readonly_storage_buffers = 1,
        .num_readwrite_storage_textures = 1,
        .num_uniform_buffers = 1,
        .threadcount_x = 16,
        .threadcount_y = 16,
        .threadcount_z = 1,
    };
    const comp_pipeline = dev.createComputePipeline(&comp_info) orelse
        return error.ComputePipelineCreationFailed;
    defer dev.releaseComputePipeline(comp_pipeline);

    var staging = UploadStagingBuffer{};
    defer staging.deinit(dev);

    const Case = struct { fmt: u32, src: [3]u8, expected: [4]u8 };
    const cases = [_]Case{
        .{
            .fmt = sdl.PixelFormat.rgb24,
            .src = .{ 0x12, 0x7A, 0xE4 },
            .expected = .{ 0x12, 0x7A, 0xE4, 0xFF },
        },
        .{
            .fmt = sdl.PixelFormat.bgr24,
            .src = .{ 0xE4, 0x7A, 0x12 },
            .expected = .{ 0x12, 0x7A, 0xE4, 0xFF },
        },
    };

    for (cases) |tc| {
        const surf = sdl.Surface.create(5, 3, tc.fmt) orelse
            return error.SurfaceCreateFailed;
        defer surf.destroy();

        const pitch: usize = @intCast(surf.pitch());
        const pixels = surf.pixels()[0 .. pitch * 3];
        @memset(pixels, 0);
        for (0..3) |y| {
            for (0..5) |x| {
                const off = y * pitch + x * 3;
                pixels[off + 0] = tc.src[0];
                pixels[off + 1] = tc.src[1];
                pixels[off + 2] = tc.src[2];
            }
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        const uploaded = uploadSurfaceToGpu(
            io,
            dev,
            surf,
            comp_pipeline,
            &staging,
        ) orelse return error.UploadFailed;
        defer dev.releaseTexture(uploaded.gpu_texture);

        const dl_size: u32 = 5 * 3 * 4;
        const dl_buf = dev.createTransferBuffer(&.{
            .usage = .download,
            .size = dl_size,
        }) orelse return error.TransferBufferCreateFailed;
        defer dev.releaseTransferBuffer(dl_buf);

        const cmd = dev.acquireCommandBuffer() orelse
            return error.CommandBufferFailed;
        const copy_pass = cmd.beginCopyPass() orelse
            return error.CopyPassFailed;
        copy_pass.downloadFromTexture(&.{
            .texture = uploaded.gpu_texture,
            .w = 5,
            .h = 3,
            .d = 1,
        }, &.{
            .transfer_buffer = dl_buf,
            .offset = 0,
            .pixels_per_row = 5,
            .rows_per_layer = 3,
        });
        copy_pass.end();

        const fence = cmd.submitAndAcquireFence() orelse
            return error.SubmitFailed;
        defer dev.releaseFence(fence);
        try std.testing.expect(dev.waitForFence(fence));

        const mapped = dev.mapTransferBuffer(dl_buf, false) orelse
            return error.MapFailed;
        defer dev.unmapTransferBuffer(dl_buf);

        for (0..15) |px| {
            try std.testing.expectEqualSlices(
                u8,
                &tc.expected,
                mapped[px * 4 .. px * 4 + 4],
            );
        }
    }
}

test "UploadStagingBuffer.decayTimeoutMs reports remaining cooldown" {
    var staging = UploadStagingBuffer{};
    try std.testing.expectEqual(@as(?u32, null), staging.decayTimeoutMs(1000));

    // Timestamp 0 is distinct from null
    staging.oversized_since_ms = 0;
    try std.testing.expectEqual(@as(?u32, 5000), staging.decayTimeoutMs(0));
    try std.testing.expectEqual(@as(?u32, 2500), staging.decayTimeoutMs(2500));
    try std.testing.expectEqual(@as(?u32, 1), staging.decayTimeoutMs(5000));

    staging.oversized_since_ms = 1000;
    try std.testing.expectEqual(@as(?u32, 5000), staging.decayTimeoutMs(1000));
    try std.testing.expectEqual(@as(?u32, 1), staging.decayTimeoutMs(5999));
    try std.testing.expectEqual(@as(?u32, 1), staging.decayTimeoutMs(6000));
    try std.testing.expectEqual(@as(?u32, 1), staging.decayTimeoutMs(9000));
    try std.testing.expectEqual(@as(?u32, 5000), staging.decayTimeoutMs(500));
}

test "UploadStagingBuffer.maybeShrinkIdle keeps warm and decays oversized" {
    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var staging = UploadStagingBuffer{};
    defer staging.deinit(dev);

    // Buffers <= 32 MiB remain warm and never stamp oversized_since_ms
    try std.testing.expect(staging.getOrCreateTransferBuffer(
        dev,
        UploadStagingBuffer.WARM_STAGING_CAP_BYTES,
    ) != null);
    try std.testing.expect(staging.getOrCreateStorageBuffer(
        dev,
        4 * 1024 * 1024,
    ) != null);
    try std.testing.expect(!staging.maybeShrinkIdle(dev, 1000, true));
    try std.testing.expectEqual(@as(?u64, null), staging.oversized_since_ms);
    try std.testing.expect(!staging.maybeShrinkIdle(dev, 10000, true));
    switch (staging.transfer) {
        .allocated => {},
        .unallocated => return error.TestExpectedAllocatedTransfer,
    }
    switch (staging.storage) {
        .allocated => {},
        .unallocated => return error.TestExpectedAllocatedStorage,
    }

    // Grow transfer buffer past 32 MiB while keeping storage warm at 4 MiB
    try std.testing.expect(staging.getOrCreateTransferBuffer(
        dev,
        UploadStagingBuffer.WARM_STAGING_CAP_BYTES + 4096,
    ) != null);
    try std.testing.expect(!staging.maybeShrinkIdle(dev, 1000, true));
    try std.testing.expectEqual(@as(?u64, 1000), staging.oversized_since_ms);

    // Active frame refreshes cooldown timestamp
    try std.testing.expect(!staging.maybeShrinkIdle(dev, 3000, false));
    try std.testing.expectEqual(@as(?u64, 3000), staging.oversized_since_ms);

    // Just before 5000ms idle elapsed -> retained
    try std.testing.expect(!staging.maybeShrinkIdle(dev, 7999, true));
    switch (staging.transfer) {
        .allocated => {},
        .unallocated => return error.TestExpectedAllocatedTransfer,
    }

    // At 5000ms idle elapsed -> oversized transfer released, warm storage kept
    try std.testing.expect(staging.maybeShrinkIdle(dev, 8000, true));
    try std.testing.expectEqual(@as(?u64, null), staging.oversized_since_ms);
    switch (staging.transfer) {
        .unallocated => {},
        .allocated => return error.TestExpectedUnallocatedTransfer,
    }
    switch (staging.storage) {
        .allocated => {},
        .unallocated => return error.TestExpectedAllocatedStorage,
    }
}

test "UploadStagingBuffer.maybeShrinkIdle decays oversized storage only" {
    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var staging = UploadStagingBuffer{};
    defer staging.deinit(dev);

    try std.testing.expect(staging.getOrCreateTransferBuffer(
        dev,
        4 * 1024 * 1024,
    ) != null);
    try std.testing.expect(staging.getOrCreateStorageBuffer(
        dev,
        UploadStagingBuffer.WARM_STAGING_CAP_BYTES + 4096,
    ) != null);

    // Stamp at timestamp 0; still retained at 4999ms, released at 5000ms
    try std.testing.expect(!staging.maybeShrinkIdle(dev, 0, true));
    try std.testing.expectEqual(@as(?u64, 0), staging.oversized_since_ms);
    try std.testing.expect(!staging.maybeShrinkIdle(dev, 4999, true));
    try std.testing.expect(staging.maybeShrinkIdle(dev, 5000, true));
    try std.testing.expectEqual(@as(?u64, null), staging.oversized_since_ms);
    switch (staging.storage) {
        .unallocated => {},
        .allocated => return error.TestExpectedUnallocatedStorage,
    }
    switch (staging.transfer) {
        .allocated => {},
        .unallocated => return error.TestExpectedAllocatedTransfer,
    }

    // deinit clears any pending oversized_since_ms
    staging.oversized_since_ms = 1234;
    staging.deinit(dev);
    try std.testing.expectEqual(@as(?u64, null), staging.oversized_since_ms);
}
