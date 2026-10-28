//! Freedesktop Shared Thumbnail Cache SDL3 Adapter
//!
//! Bridges SDL surface loading, smooth downscaling, orthogonal EXIF rotation,
//! and PNG encoding with the pure `thumbcache` module.

const intents = @import("intents");
const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const thumbcache = @import("thumbcache");

const EnabledThumbCacheConfig = thumbcache.EnabledThumbCacheConfig;
const Orientation = probe.Orientation;
const PhysicalDims = state_pkg.PhysicalDims;
const PositiveDimsU32 = intents.PositiveDimsU32;
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

/// Probes cached PNG files across `ThumbTier.read_probe_order`, validates
/// `Thumb::MTime == source_mtime_sec`, and decodes the cached PNG into an
/// `sdl.Surface`.
pub fn loadCachedThumbnail(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: EnabledThumbCacheConfig,
    key: *const ThumbCacheKey,
    source_mtime_sec: i64,
) ?CachedThumbResult {
    const cached = thumbcache.readCachedThumbnailBytes(
        allocator,
        io,
        cfg,
        key,
        source_mtime_sec,
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

fn encodeSurfaceToPngAlloc(
    allocator: std.mem.Allocator,
    surface: sdl.Surface,
    tier: ThumbTier,
    orientation: Orientation,
) ![]u8 {
    const src_w = surface.w();
    const src_h = surface.h();
    const scaled_dims = tier.computeScaledDims(src_w, src_h) orelse
        return error.InvalidDimensions;

    const scaled_owned = if (scaled_dims.w != src_w or scaled_dims.h != src_h)
        surface.scaleRgba32Smooth(scaled_dims.w, scaled_dims.h) orelse
            return error.ScaleFailed
    else
        null;
    defer if (scaled_owned) |s| s.destroy();
    const base_surf = scaled_owned orelse surface;

    const quarter_turns: u2 = @backingInt(orientation);
    const rotated_owned = if (quarter_turns != 0)
        base_surf.rotateOrthogonal(quarter_turns) orelse
            return error.RotateFailed
    else
        null;
    defer if (rotated_owned) |r| r.destroy();
    const final_surf = rotated_owned orelse base_surf;

    return final_surf.encodePngAlloc(allocator);
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

/// Decodes `source_bytes` into an SDL surface, computes downscaled dimensions
/// for `tier`, applies orthogonal EXIF `orientation`, and encodes the result
/// as an allocated PNG buffer.
pub fn encodeBytesToThumbnailPng(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    tier: ThumbTier,
    orientation: Orientation,
) ?thumbcache.EncodedThumbPng {
    const surf = sdl.Surface.loadConstMemOpt(source_bytes) orelse return null;
    defer surf.destroy();

    const w = surf.w();
    const h = surf.h();
    const dims: ?PositiveDimsU32 = if (w > 0 and h > 0)
        .{ .w = @intCast(w), .h = @intCast(h) }
    else
        null;

    const png = encodeSurfaceToPngAlloc(
        allocator,
        surf,
        tier,
        orientation,
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
        loadCachedThumbnail(allocator, io, enabled_cfg, &key, mtime_sec + 5) ==
            null,
    );
}

test "precacheFileThumbnail and precachePathsParallel valid thumbnails" {
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
}
