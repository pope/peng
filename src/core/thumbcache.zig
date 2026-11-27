//! Freedesktop Shared Thumbnail Cache SDL3 Adapter
//!
//! Bridges SDL surface loading, smooth downscaling, orthogonal EXIF rotation,
//! and PNG encoding with the pure `thumbcache` module.

const builtin = @import("builtin");
const geom = @import("geom");
const probe = @import("probe");
const sdl = @import("sdl");
const std = @import("std");
const thumbcache = @import("thumbcache");

const EnabledThumbCacheConfig = thumbcache.EnabledThumbCacheConfig;
const Orientation = probe.Orientation;
const PhysicalDims = geom.PhysicalDims;
const PositiveDimsU32 = geom.PositiveDimsU32;
const PrecacheOutcome = thumbcache.PrecacheOutcome;
const ThumbCacheConfig = thumbcache.ThumbCacheConfig;
const ThumbCacheKey = thumbcache.ThumbCacheKey;
const ThumbTier = thumbcache.ThumbTier;
const WriteThumbMetadata = thumbcache.WriteThumbMetadata;

/// Result of loading a valid Freedesktop cached thumbnail into an SDL surface.
pub const CachedThumbResult = struct {
    surface: sdl.Surface,
    tier: ThumbTier,
    source_dims: ?PhysicalDims = null,
};

/// Probes cached PNG files across `ThumbTier.read_probe_order` whose bounding
/// box is at least `min_dim` pixels (`0` matches any tier), validates
/// `Thumb::MTime == source_mtime_sec`, and decodes the cached PNG into an
/// `sdl.Surface`.
pub fn loadCachedThumbnail(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: EnabledThumbCacheConfig,
    key: *const ThumbCacheKey,
    source_mtime_sec: i64,
    min_dim: u32,
) ?CachedThumbResult {
    const cached = thumbcache.readCachedThumbnailBytes(
        allocator,
        io,
        cfg,
        key,
        source_mtime_sec,
        min_dim,
    ) orelse return null;
    defer cached.deinit(allocator);

    if (sdl.Surface.loadConstMemOpt(cached.png_bytes)) |surf| {
        const source_dims: ?PhysicalDims = if (cached.source_dims) |px|
            PhysicalDims.initPositive(
                @floatFromInt(px.w),
                @floatFromInt(px.h),
            )
        else
            null;
        return .{
            .surface = surf,
            .tier = cached.tier,
            .source_dims = source_dims,
        };
    }
    return null;
}

/// Holds an SDL surface transformed by scaling, rotating, or pixel format
/// conversion, tracking whether the underlying pointer must be destroyed.
pub const TransformedSurface = struct {
    surface: sdl.Surface,
    owned: bool,

    /// Destroys the surface if it was created during the transformation pass.
    pub fn deinit(self: TransformedSurface) void {
        if (self.owned) self.surface.destroy();
    }
};

/// Scales `surface` to `(target_w, target_h)` if different from its
/// current dimensions, applies orthogonal EXIF `orientation` rotation,
/// and optionally converts the resulting surface to `rgba32`.
/// Caller must call `.deinit()` on the returned `TransformedSurface`.
pub fn scaleAndOrientSurface(
    surface: sdl.Surface,
    target_w: i32,
    target_h: i32,
    orientation: Orientation,
    ensure_rgba32: bool,
) !TransformedSurface {
    const src_w = surface.w();
    const src_h = surface.h();
    if (src_w <= 0 or src_h <= 0 or target_w <= 0 or target_h <= 0) {
        return error.InvalidDimensions;
    }

    var cur = surface;
    var owned = false;
    errdefer if (owned) cur.destroy();

    if (target_w != src_w or target_h != src_h) {
        const scaled = cur.scaleRgba32Smooth(target_w, target_h) orelse
            return error.ScaleFailed;
        if (owned) cur.destroy();
        cur = scaled;
        owned = true;
    }

    const quarter_turns: u2 = @backingInt(orientation);
    if (quarter_turns != 0) {
        const rotated = cur.rotateOrthogonal(quarter_turns) orelse
            return error.RotateFailed;
        if (owned) cur.destroy();
        cur = rotated;
        owned = true;
    }

    if (ensure_rgba32 and cur.format() != sdl.PixelFormat.rgba32) {
        const converted = cur.convert(sdl.PixelFormat.rgba32) orelse
            return error.ConvertFailed;
        if (owned) cur.destroy();
        cur = converted;
        owned = true;
    }

    return .{ .surface = cur, .owned = owned };
}

fn encodeSurfaceToPngAlloc(
    allocator: std.mem.Allocator,
    surface: sdl.Surface,
    tier: ThumbTier,
    orientation: Orientation,
    source_dims_opt: ?PositiveDimsU32,
) ![]u8 {
    const dim_w: i32 = if (source_dims_opt) |d|
        std.math.cast(i32, d.w) orelse surface.w()
    else
        surface.w();
    const dim_h: i32 = if (source_dims_opt) |d|
        std.math.cast(i32, d.h) orelse surface.h()
    else
        surface.h();
    const scaled_dims = tier.computeScaledDims(dim_w, dim_h) orelse
        return error.InvalidDimensions;

    const transformed = try scaleAndOrientSurface(
        surface,
        scaled_dims.w,
        scaled_dims.h,
        orientation,
        false,
    );
    defer transformed.deinit();

    return transformed.surface.encodePngAlloc(allocator);
}

/// Downscales `surface` to fit within `cfg.write_tier.maxDim()` (preserving
/// aspect ratio), applies orthogonal EXIF `orientation` so the saved thumbnail
/// is visually upright, splices Freedesktop `tEXt` chunks, and atomically
/// writes `<cache_dir>/<tier>/<md5>.png`.
pub fn writeThumbnailPng(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: EnabledThumbCacheConfig,
    key: *const ThumbCacheKey,
    surface: sdl.Surface,
    orientation: Orientation,
    meta: WriteThumbMetadata,
) !void {
    const raw_png = try encodeSurfaceToPngAlloc(
        allocator,
        surface,
        cfg.write_tier,
        orientation,
        null,
    );
    defer allocator.free(raw_png);

    try thumbcache.writeCachedThumbnailBytes(
        allocator,
        io,
        cfg,
        key,
        raw_png,
        meta,
    );
}

/// Decodes `source_bytes` into an SDL surface (using DCT-scaled JPEG decoding
/// when available), computes downscaled dimensions for `tier`, applies
/// orthogonal EXIF `orientation`, and encodes the result as an allocated PNG
/// buffer while preserving original unscaled `decoded_dims`.
pub fn encodeBytesToThumbnailPng(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    tier: ThumbTier,
    orientation: Orientation,
) ?thumbcache.EncodedThumbPng {
    const max_dim: u32 = @intCast(tier.maxDim());
    const dec = sdl.Surface.loadConstMemScaledWithDimsOpt(
        source_bytes,
        max_dim,
        max_dim,
    ) orelse return null;
    defer dec.surface.destroy();

    const dims: ?PositiveDimsU32 = if (dec.source_w > 0 and dec.source_h > 0)
        .{ .w = dec.source_w, .h = dec.source_h }
    else
        null;

    const png = encodeSurfaceToPngAlloc(
        allocator,
        dec.surface,
        tier,
        orientation,
        dims,
    ) catch return null;
    return .{
        .png_bytes = png,
        .decoded_dims = dims,
    };
}

test "writeThumbnailPng and loadCachedThumbnail roundtrip with rotation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cache_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel_cache_dir = try std.mem.print(
        &cache_dir_buf,
        ".zig-cache/tmp/{s}/thumbnails",
        .{tmp.sub_path},
    );
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, rel_cache_dir);

    var real_cache_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_cache_len = try std.Io.Dir.realPathFile(
        std.Io.Dir.cwd(),
        io,
        rel_cache_dir,
        &real_cache_buf,
    );
    const abs_cache_dir = real_cache_buf[0..real_cache_len];

    var cfg = try ThumbCacheConfig.initWithDir(
        allocator,
        abs_cache_dir,
        .large,
        .all_missing,
    );
    defer cfg.deinit(allocator);
    const enabled_cfg = cfg.enabled;

    const key =
        ThumbCacheKey.fromCanonicalPath("/photos/shoot 01/DSC0001.ARW").?;
    const mtime_sec: i64 = 1729700000;

    // Create a 600x400 landscape surface with rotate_90 orientation -> should
    // save as 170x256 portrait
    const surf = sdl.Surface.create(
        600,
        400,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;
    defer surf.destroy();
    @memset(surf.pixels()[0..@intCast(surf.pitch() * 400)], 128);

    try std.testing.expect(
        !thumbcache.hasValidTargetTierThumbnail(
            io,
            enabled_cfg,
            &key,
            mtime_sec,
        ),
    );

    try writeThumbnailPng(allocator, io, enabled_cfg, &key, surf, .rotate_90, .{
        .uri = key.uri(),
        .mtime_sec = mtime_sec,
        .file_size = 39358464,
        .mime_type = "image/x-sony-arw",
        .source_dims = .{ .w = 600, .h = 400 },
    });

    try std.testing.expect(
        thumbcache.hasValidTargetTierThumbnail(
            io,
            enabled_cfg,
            &key,
            mtime_sec,
        ),
    );
    // Mismatched mtime must report invalid
    try std.testing.expect(
        !thumbcache.hasValidTargetTierThumbnail(
            io,
            enabled_cfg,
            &key,
            mtime_sec + 1,
        ),
    );

    // Load back from cache
    const loaded = loadCachedThumbnail(
        allocator,
        io,
        enabled_cfg,
        &key,
        mtime_sec,
        0,
    ) orelse return error.CacheLoadFailed;
    defer loaded.surface.destroy();

    try std.testing.expectEqual(ThumbTier.large, loaded.tier);
    // 600x400 scaled to max 256 -> 256x170, then rotated 90° CW -> 170x256
    try std.testing.expectEqual(@as(i32, 170), loaded.surface.w());
    try std.testing.expectEqual(@as(i32, 256), loaded.surface.h());
    try std.testing.expectEqual(@as(f32, 600.0), loaded.source_dims.?.w);
    try std.testing.expectEqual(@as(f32, 400.0), loaded.source_dims.?.h);

    // Stale mtime must return null
    try std.testing.expect(
        loadCachedThumbnail(
            allocator,
            io,
            enabled_cfg,
            &key,
            mtime_sec + 5,
            0,
        ) == null,
    );
}

test "precacheFileThumbnail and precachePathsParallel valid thumbnails" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cache_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel_cache_dir = try std.mem.print(
        &cache_dir_buf,
        ".zig-cache/tmp/{s}/thumbnails",
        .{tmp.sub_path},
    );
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, rel_cache_dir);

    var real_cache_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_cache_len = try std.Io.Dir.realPathFile(
        std.Io.Dir.cwd(),
        io,
        rel_cache_dir,
        &real_cache_buf,
    );
    const abs_cache_dir = real_cache_buf[0..real_cache_len];

    var cfg = try ThumbCacheConfig.initWithDir(
        allocator,
        abs_cache_dir,
        .large,
        .all_missing,
    );
    defer cfg.deinit(allocator);
    const enabled_cfg = cfg.enabled;

    const test_img = "testfiles/images/000_0_1024x682.jpg";

    // First run writes the thumbnail
    const first_outcome = thumbcache.precacheFileThumbnail(
        allocator,
        io,
        enabled_cfg,
        test_img,
        .{},
        encodeBytesToThumbnailPng,
    );
    try std.testing.expectEqual(PrecacheOutcome.written, first_outcome);

    // Second run detects valid cached thumbnail and returns .already_valid
    const second_outcome = thumbcache.precacheFileThumbnail(
        allocator,
        io,
        enabled_cfg,
        test_img,
        .{},
        encodeBytesToThumbnailPng,
    );
    try std.testing.expectEqual(PrecacheOutcome.already_valid, second_outcome);

    // Verify PNG metadata retains original unscaled dimensions (1024x682)
    // and exact large-tier thumbnail dimensions (256x170)
    const key = ThumbCacheKey.fromFilePath(io, test_img, abs_cache_dir).?;
    const s = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, test_img, .{});
    const loaded = loadCachedThumbnail(
        allocator,
        io,
        enabled_cfg,
        &key,
        s.mtime.toSeconds(),
        0,
    ) orelse return error.CacheLoadFailed;
    defer loaded.surface.destroy();
    try std.testing.expectEqual(@as(i32, 256), loaded.surface.w());
    try std.testing.expectEqual(@as(i32, 170), loaded.surface.h());
    try std.testing.expectEqual(@as(f32, 1024.0), loaded.source_dims.?.w);
    try std.testing.expectEqual(@as(f32, 682.0), loaded.source_dims.?.h);
}

test "scaleAndOrientSurface - identity, rgba32 conversion, and invalid dims" {
    const src = sdl.Surface.create(
        16,
        12,
        sdl.PixelFormat.rgb24,
    ) orelse return error.SurfaceFailed;
    defer src.destroy();

    // 1. Identity call (same dims, .normal, ensure_rgba32 = false) -> borrowed
    var id_res = try scaleAndOrientSurface(src, 16, 12, .normal, false);
    defer id_res.deinit();
    try std.testing.expect(!id_res.owned);
    try std.testing.expectEqual(src.ptr, id_res.surface.ptr);

    // 2. Format conversion on rgb24 with ensure_rgba32 = true -> owned rgba32
    var conv_res = try scaleAndOrientSurface(src, 16, 12, .normal, true);
    defer conv_res.deinit();
    try std.testing.expect(conv_res.owned);
    try std.testing.expect(conv_res.surface.ptr != src.ptr);
    try std.testing.expectEqual(
        sdl.PixelFormat.rgba32,
        conv_res.surface.format(),
    );

    // 3. Invalid non-positive target dimensions -> error.InvalidDimensions
    try std.testing.expectError(
        error.InvalidDimensions,
        scaleAndOrientSurface(src, 0, 12, .normal, false),
    );
}
