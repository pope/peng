//! Freedesktop Shared Thumbnail Cache (`$XDG_CACHE_HOME/thumbnails/`)
//!
//! Implements reading and atomic writing of PNG thumbnails conforming to the
//! Freedesktop Thumbnail Managing Standard:
//! - Canonical `file:///` URI with RFC 3986 percent-encoding + lowercase hex
//!   MD5 filename.
//! - PNG `tEXt` metadata validation (`Thumb::MTime`, `Thumb::URI`,
//!   `Thumb::Image::Width/Height`) placed immediately after `IHDR` (prior to
//!   `IDAT`) for compatibility with `libpng` (`png_read_info`), KDE Dolphin
//!   (`KIO::PreviewJob`), GNOME/GLib, and Yazi.

const builtin = @import("builtin");
const core_fs = @import("fs.zig");
const image = @import("image.zig");
const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const Orientation = probe.Orientation;

const png_signature = "\x89PNG\r\n\x1a\n";
const ihdr_end_offset: usize = 33; // 8-byte signature + 25-byte IHDR chunk
const max_cached_png_bytes: usize = 2 * 1024 * 1024;

/// Standard Freedesktop thumbnail bounding-box size tiers.
pub const ThumbTier = enum {
    normal,
    large,
    x_large,
    xx_large,

    /// Probed in ascending size order so `peng` loads the smallest,
    /// fastest-decoding placeholder available while still utilizing larger
    /// tiers if present.
    pub const read_probe_order = [_]ThumbTier{
        .normal,
        .large,
        .x_large,
        .xx_large,
    };

    /// Subdirectory name under `$XDG_CACHE_HOME/thumbnails/`.
    pub fn dirName(self: ThumbTier) []const u8 {
        return switch (self) {
            .normal => "normal",
            .large => "large",
            .x_large => "x-large",
            .xx_large => "xx-large",
        };
    }

    /// Maximum pixel width and height bounding box for this tier.
    pub fn maxDim(self: ThumbTier) i32 {
        return switch (self) {
            .normal => 128,
            .large => 256,
            .x_large => 512,
            .xx_large => 1024,
        };
    }
};

/// Policy governing when `peng` contributes newly generated thumbnails back to
/// the Freedesktop thumbnail cache.
pub const ThumbWritePolicy = enum {
    /// Never write thumbnails to disk (read-only cache consumer).
    never,
    /// Only write when the source image lacked an embedded EXIF/RAW thumbnail
    /// (e.g. PNG, WebP, AVIF, TIFF, or stripped JPEG).
    missing_embedded_only,
    /// Write whenever the target Freedesktop tier is missing or stale,
    /// including for RAW and JPEG files (pre-warming Dolphin / Yazi caches).
    all_missing,

    /// Evaluates whether a thumbnail should be written given lookup outcomes.
    pub fn shouldWrite(
        self: ThumbWritePolicy,
        had_embedded_thumb: bool,
        had_target_tier_valid: bool,
    ) bool {
        if (had_target_tier_valid) return false;
        return switch (self) {
            .never => false,
            .missing_embedded_only => !had_embedded_thumb,
            .all_missing => true,
        };
    }
};

/// Active configuration when Freedesktop thumbnail caching is enabled.
pub const EnabledThumbCacheConfig = struct {
    cache_dir: []const u8,
    write_tier: ThumbTier = .large,
    write_policy: ThumbWritePolicy = .all_missing,
};

/// Tagged union encapsulating platform/user Freedesktop thumbnail cache
/// configuration.
pub const ThumbCacheConfig = union(enum) {
    disabled,
    enabled: EnabledThumbCacheConfig,

    /// Initializes the platform configuration from `environ_map`
    /// (`proc_init.environ_map` provided by `std.process.Init`) and
    /// `write_policy_opt`:
    /// - Enabled on Linux/FreeBSD using `$XDG_CACHE_HOME/thumbnails` or
    ///   `$HOME/.cache/thumbnails` when `write_policy_opt != null`.
    /// - Disabled when `write_policy_opt == null` or on macOS/Windows.
    pub fn initFromEnviron(
        allocator: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        write_policy_opt: ?ThumbWritePolicy,
    ) ThumbCacheConfig {
        if (builtin.os.tag != .linux and builtin.os.tag != .freebsd) {
            return .disabled;
        }
        return initPosixFromEnviron(allocator, environ_map, write_policy_opt);
    }

    /// Resolves `$XDG_CACHE_HOME/thumbnails` (or `$HOME/.cache/thumbnails` if
    /// `$XDG_CACHE_HOME` is unset or relative) from `environ_map` with
    /// `write_policy_opt`.
    pub fn initPosixFromEnviron(
        allocator: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        write_policy_opt: ?ThumbWritePolicy,
    ) ThumbCacheConfig {
        const policy = write_policy_opt orelse return .disabled;

        if (environ_map.get("XDG_CACHE_HOME")) |xdg| {
            if (xdg.len > 0 and std.Io.Dir.path.isAbsolute(xdg)) {
                if (std.Io.Dir.path.join(
                    allocator,
                    &.{ xdg, "thumbnails" },
                )) |dir| {
                    return .{
                        .enabled = .{
                            .cache_dir = dir,
                            .write_policy = policy,
                        },
                    };
                } else |_| {}
            }
        }

        if (environ_map.get("HOME")) |home| {
            if (home.len > 0 and std.Io.Dir.path.isAbsolute(home)) {
                if (std.Io.Dir.path.join(
                    allocator,
                    &.{ home, ".cache", "thumbnails" },
                )) |dir| {
                    return .{
                        .enabled = .{
                            .cache_dir = dir,
                            .write_policy = policy,
                        },
                    };
                } else |_| {}
            }
        }

        return .disabled;
    }

    /// Initializes an explicit enabled configuration backed by `dir_path`.
    pub fn initWithDir(
        allocator: std.mem.Allocator,
        dir_path: []const u8,
        write_tier: ThumbTier,
        write_policy: ThumbWritePolicy,
    ) !ThumbCacheConfig {
        const owned = try allocator.dupe(u8, dir_path);
        return .{
            .enabled = .{
                .cache_dir = owned,
                .write_tier = write_tier,
                .write_policy = write_policy,
            },
        };
    }

    /// Releases owned directory path memory and transitions to `.disabled`.
    pub fn deinit(self: *ThumbCacheConfig, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .disabled => {},
            .enabled => |cfg| {
                allocator.free(cfg.cache_dir);
                self.* = .disabled;
            },
        }
    }
};

/// Canonical `file:///` URI and 32-character lowercase hex MD5 digest key.
pub const ThumbCacheKey = struct {
    uri_buf: [std.Io.Dir.max_path_bytes * 3 + 16]u8,
    uri_len: usize,
    md5_hex: [32]u8,

    /// Returns the formatted `file:///` URI slice.
    pub fn uri(self: *const ThumbCacheKey) []const u8 {
        return self.uri_buf[0..self.uri_len];
    }

    /// Formats an already-canonicalized absolute file path into a `file:///`
    /// URI with RFC 3986 percent-encoding and computes its MD5 hex digest.
    pub fn fromCanonicalPath(abs_path: []const u8) ?ThumbCacheKey {
        if (abs_path.len == 0 or abs_path[0] != '/') return null;

        var uri_buf: [std.Io.Dir.max_path_bytes * 3 + 16]u8 = undefined;
        const prefix = "file://";
        @memcpy(uri_buf[0..prefix.len], prefix);
        var pos: usize = prefix.len;

        const hex_upper = "0123456789ABCDEF";
        for (abs_path) |b| {
            const is_unreserved = (b >= 'A' and b <= 'Z') or
                (b >= 'a' and b <= 'z') or
                (b >= '0' and b <= '9') or
                b == '-' or b == '.' or b == '_' or b == '~' or b == '/';
            if (is_unreserved) {
                if (pos + 1 > uri_buf.len) return null;
                uri_buf[pos] = b;
                pos += 1;
            } else {
                if (pos + 3 > uri_buf.len) return null;
                uri_buf[pos] = '%';
                uri_buf[pos + 1] = hex_upper[b >> 4];
                uri_buf[pos + 2] = hex_upper[b & 0x0F];
                pos += 3;
            }
        }

        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(uri_buf[0..pos], &digest, .{});
        return .{
            .uri_buf = uri_buf,
            .uri_len = pos,
            .md5_hex = std.fmt.bytesToHex(digest, .lower),
        };
    }

    fn isPathInsideDir(abs_path: []const u8, dir_path: []const u8) bool {
        const trimmed = std.mem.trimEnd(u8, dir_path, "/");
        if (trimmed.len == 0) return false;
        if (!std.mem.startsWith(u8, abs_path, trimmed)) return false;
        return abs_path.len == trimmed.len or abs_path[trimmed.len] == '/';
    }

    /// Resolves `path` via `realPathFile`, enforces exclusion rules (skipping
    /// `/tmp/` and files inside `cache_dir`), and returns the Freedesktop cache
    /// key.
    pub fn fromFilePath(
        io: std.Io,
        path: []const u8,
        cache_dir: []const u8,
    ) ?ThumbCacheKey {
        var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const real_len = std.Io.Dir.realPathFile(
            std.Io.Dir.cwd(),
            io,
            path,
            &real_buf,
        ) catch return null;
        const abs_path = real_buf[0..real_len];

        // Never read or write thumbnails for files inside the thumbnail cache
        // itself or /tmp/
        if (isPathInsideDir(abs_path, cache_dir) or
            isPathInsideDir(abs_path, "/tmp"))
        {
            return null;
        }

        return fromCanonicalPath(abs_path);
    }
};

/// Metadata parsed from a cached Freedesktop PNG header (`IHDR` + `tEXt`
/// chunks).
pub const PngThumbMetadata = struct {
    thumb_w: u32,
    thumb_h: u32,
    mtime_sec: ?i64 = null,
    source_dims: ?state_pkg.PhysicalDims = null,
};

/// Parses `IHDR` dimensions and Freedesktop `tEXt` chunks (`Thumb::MTime`,
/// `Thumb::Image::Width`, `Thumb::Image::Height`) from a PNG buffer.
pub fn parsePngThumbnailMetadata(png_bytes: []const u8) ?PngThumbMetadata {
    if (png_bytes.len < ihdr_end_offset) return null;
    if (!std.mem.eql(u8, png_bytes[0..8], png_signature)) return null;

    var thumb_w: u32 = 0;
    var thumb_h: u32 = 0;
    var mtime_sec: ?i64 = null;
    var full_w_opt: ?u32 = null;
    var full_h_opt: ?u32 = null;
    var pos: usize = 8;

    while (pos + 8 <= png_bytes.len) {
        const chunk_len: usize = std.mem.readInt(
            u32,
            png_bytes[pos..][0..4],
            .big,
        );
        const chunk_type = png_bytes[pos + 4 ..][0..4];
        const data_start = pos + 8;

        if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        if (data_start +| chunk_len > png_bytes.len) break;
        const payload = png_bytes[data_start .. data_start + chunk_len];

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (payload.len < 8) return null;
            thumb_w = std.mem.readInt(u32, payload[0..4], .big);
            thumb_h = std.mem.readInt(u32, payload[4..8], .big);
        } else if (std.mem.eql(u8, chunk_type, "tEXt")) {
            if (std.mem.indexOfScalar(u8, payload, 0)) |sep_idx| {
                const key = payload[0..sep_idx];
                const val = payload[sep_idx + 1 ..];
                if (std.mem.eql(u8, key, "Thumb::MTime")) {
                    mtime_sec = std.fmt.parseInt(i64, val, 10) catch null;
                } else if (std.mem.eql(u8, key, "Thumb::Image::Width")) {
                    if (std.fmt.parseInt(u32, val, 10)) |w| {
                        if (w > 0) full_w_opt = w;
                    } else |_| {}
                } else if (std.mem.eql(u8, key, "Thumb::Image::Height")) {
                    if (std.fmt.parseInt(u32, val, 10)) |h| {
                        if (h > 0) full_h_opt = h;
                    } else |_| {}
                }
            }
        }

        const next_pos = data_start +| chunk_len +| 4;
        if (next_pos <= pos) break;
        pos = next_pos;
    }

    if (thumb_w == 0 or thumb_h == 0) return null;
    const source_dims: ?state_pkg.PhysicalDims = if (full_w_opt) |fw|
        (if (full_h_opt) |fh|
            state_pkg.PhysicalDims.initPositive(
                @floatFromInt(fw),
                @floatFromInt(fh),
            )
        else
            null)
    else
        null;
    return .{
        .thumb_w = thumb_w,
        .thumb_h = thumb_h,
        .mtime_sec = mtime_sec,
        .source_dims = source_dims,
    };
}

/// Metadata written into Freedesktop PNG `tEXt` chunks.
pub const WriteThumbMetadata = struct {
    uri: []const u8,
    mtime_sec: i64,
    file_size: u64,
    mime_type: []const u8 = "",
    source_dims: ?state_pkg.PhysicalDims = null,
};

fn appendTextChunk(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    val: []const u8,
) !void {
    const chunk_len = std.math.cast(u32, key.len +| 1 +| val.len) orelse
        return error.ChunkTooLarge;
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, chunk_len, .big);
    try list.appendSlice(allocator, &len_bytes);
    try list.appendSlice(allocator, "tEXt");
    try list.appendSlice(allocator, key);
    try list.append(allocator, 0);
    try list.appendSlice(allocator, val);

    var crc = std.hash.Crc32.init();
    crc.update("tEXt");
    crc.update(key);
    crc.update(&.{0});
    crc.update(val);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try list.appendSlice(allocator, &crc_bytes);
}

/// Splices Freedesktop `tEXt` metadata chunks immediately after the 33-byte
/// `IHDR` header (before `IDAT`) so `libpng` (`png_read_info`), Dolphin, and
/// Yazi recognize them.
pub fn splicePngTextChunks(
    allocator: std.mem.Allocator,
    raw_png: []const u8,
    meta: WriteThumbMetadata,
) ![]u8 {
    if (raw_png.len < ihdr_end_offset or
        !std.mem.eql(u8, raw_png[0..8], png_signature) or
        std.mem.readInt(u32, raw_png[8..12], .big) != 13 or
        !std.mem.eql(u8, raw_png[12..16], "IHDR"))
    {
        return error.InvalidPngHeader;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, raw_png.len + meta.uri.len + 256);

    // 1. Copy PNG signature + IHDR chunk (first 33 bytes)
    try out.appendSlice(allocator, raw_png[0..ihdr_end_offset]);

    // 2. Insert Freedesktop tEXt chunks prior to IDAT
    try appendTextChunk(&out, allocator, "Software", "peng");
    try appendTextChunk(&out, allocator, "Thumb::URI", meta.uri);

    var num_buf: [64]u8 = undefined;
    const mtime_str = try std.mem.print(&num_buf, "{d}", .{meta.mtime_sec});
    try appendTextChunk(&out, allocator, "Thumb::MTime", mtime_str);

    const size_str = try std.mem.print(&num_buf, "{d}", .{meta.file_size});
    try appendTextChunk(&out, allocator, "Thumb::Size", size_str);

    if (meta.mime_type.len > 0) {
        try appendTextChunk(&out, allocator, "Thumb::Mimetype", meta.mime_type);
    }
    if (meta.source_dims) |dims| {
        if (dims.toPositiveU32()) |px| {
            const w_str = try std.mem.print(&num_buf, "{d}", .{px.w});
            try appendTextChunk(&out, allocator, "Thumb::Image::Width", w_str);
            const h_str = try std.mem.print(&num_buf, "{d}", .{px.h});
            try appendTextChunk(&out, allocator, "Thumb::Image::Height", h_str);
        }
    }

    // 3. Copy remaining chunks (IDAT .. IEND)
    try out.appendSlice(allocator, raw_png[ihdr_end_offset..]);
    return out.toOwnedSlice(allocator);
}

/// Result of loading a valid Freedesktop cached thumbnail.
pub const CachedThumbResult = struct {
    surface: sdl.Surface,
    tier: ThumbTier,
    source_dims: ?state_pkg.PhysicalDims = null,
};

fn formatTierFilePath(
    buf: *[std.Io.Dir.max_path_bytes]u8,
    cache_dir: []const u8,
    tier: ThumbTier,
    md5_hex: [32]u8,
) ?[]const u8 {
    return std.mem.print(
        buf,
        "{s}/{s}/{s}.png",
        .{ cache_dir, tier.dirName(), md5_hex },
    ) catch null;
}

/// Checks whether the configured target write tier (e.g. `large/<md5>.png`)
/// already exists on disk with a `Thumb::MTime` matching `source_mtime_sec`.
/// Reads at most 2 KB into a stack buffer with zero heap allocations.
pub fn hasValidTargetTierThumbnail(
    io: std.Io,
    cfg: EnabledThumbCacheConfig,
    key: *const ThumbCacheKey,
    source_mtime_sec: i64,
) bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const thumb_path = formatTierFilePath(
        &path_buf,
        cfg.cache_dir,
        cfg.write_tier,
        key.md5_hex,
    ) orelse return false;

    var file = std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        thumb_path,
        .{},
    ) catch return false;
    defer file.close(io);

    var hdr_buf: [2048]u8 = undefined;
    const n = file.readPositional(io, &.{&hdr_buf}, 0) catch return false;
    const meta = parsePngThumbnailMetadata(hdr_buf[0..n]) orelse return false;
    return meta.mtime_sec == source_mtime_sec;
}

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
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    for (ThumbTier.read_probe_order) |tier| {
        const thumb_path = formatTierFilePath(
            &path_buf,
            cfg.cache_dir,
            tier,
            key.md5_hex,
        ) orelse continue;

        var file = std.Io.Dir.openFile(
            std.Io.Dir.cwd(),
            io,
            thumb_path,
            .{},
        ) catch continue;
        defer file.close(io);

        const stat = file.stat(io) catch continue;
        if (stat.size < ihdr_end_offset or stat.size > max_cached_png_bytes) {
            continue;
        }
        const size: usize = @intCast(stat.size);

        const bytes = allocator.alloc(u8, size) catch continue;
        defer allocator.free(bytes);

        if ((file.readPositionalAll(io, bytes, 0) catch 0) != size) continue;

        const meta = parsePngThumbnailMetadata(bytes) orelse continue;
        if (meta.mtime_sec != source_mtime_sec) continue;

        if (sdl.Surface.loadConstMemOpt(bytes)) |surf| {
            return .{
                .surface = surf,
                .tier = tier,
                .source_dims = meta.source_dims,
            };
        }
    }

    return null;
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
    const src_w = surface.w();
    const src_h = surface.h();
    if (src_w <= 0 or src_h <= 0) return error.InvalidDimensions;

    const max_dim = cfg.write_tier.maxDim();
    var target_w = src_w;
    var target_h = src_h;
    if (src_w > max_dim or src_h > max_dim) {
        if (src_w >= src_h) {
            target_w = max_dim;
            target_h = @max(1, @divTrunc(src_h * max_dim, src_w));
        } else {
            target_h = max_dim;
            target_w = @max(1, @divTrunc(src_w * max_dim, src_h));
        }
    }

    const scaled_owned = if (target_w != src_w or target_h != src_h)
        surface.scaleRgba32Smooth(target_w, target_h) orelse
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

    const raw_png = try final_surf.encodePngAlloc(allocator);
    defer allocator.free(raw_png);

    const spliced_png = try splicePngTextChunks(allocator, raw_png, meta);
    defer allocator.free(spliced_png);

    const dir_perms: std.Io.File.Permissions =
        if (std.Io.File.Permissions.has_executable_bit)
            .fromMode(0o700)
        else
            .default_dir;
    const file_perms: std.Io.File.Permissions =
        if (std.Io.File.Permissions.has_executable_bit)
            .fromMode(0o600)
        else
            .default_file;

    // Ensure `<cache_dir>/<tier>` exists with 0700 permissions and open it
    var tier_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tier_dir_path = try std.mem.print(
        &tier_dir_buf,
        "{s}/{s}",
        .{ cfg.cache_dir, cfg.write_tier.dirName() },
    );
    var tier_dir = try std.Io.Dir.cwd().createDirPathOpen(io, tier_dir_path, .{
        .permissions = dir_perms,
    });
    defer tier_dir.close(io);

    var filename_buf: [32 + 4]u8 = undefined;
    const filename = try std.mem.print(
        &filename_buf,
        "{s}.png",
        .{key.md5_hex},
    );

    var atomic_file = try tier_dir.createFileAtomic(io, filename, .{
        .permissions = file_perms,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    try atomic_file.file.writeStreamingAll(io, spliced_png);
    try atomic_file.replace(io);
}

const precache_header_limit: usize = 256 * 1024;

/// Result of attempting to pre-cache a single image file's Freedesktop
/// thumbnail.
pub const PrecacheOutcome = enum {
    written,
    already_valid,
    skipped,
    failed,
    canceled,
};

/// Aggregated statistics from a batch thumbnail pre-caching run.
pub const PrecacheStats = struct {
    total_files: usize = 0,
    written: usize = 0,
    already_valid: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

/// Cooperative cancellation state for thumbnail pre-caching operations.
pub const PrecacheCancel = struct {
    exiting: ?*const std.atomic.Value(bool) = null,
    generation: usize = 0,
    current_generation: ?*const std.atomic.Value(usize) = null,

    pub inline fn isCanceled(self: PrecacheCancel) bool {
        if (self.exiting) |ex| {
            if (ex.load(.acquire)) return true;
        }
        if (self.current_generation) |cur| {
            if (cur.load(.acquire) != self.generation) return true;
        }
        return false;
    }
};

fn readPositionalRange(
    file: std.Io.File,
    io: std.Io,
    cancel: PrecacheCancel,
    dest: []u8,
    start_offset: u64,
) !usize {
    var total_read: usize = 0;
    while (total_read < dest.len) {
        if (cancel.isCanceled()) return error.Canceled;
        const n = try file.readPositional(
            io,
            &.{dest[total_read..]},
            start_offset + total_read,
        );
        if (n == 0) break;
        total_read += n;
    }
    return total_read;
}

fn decodeEmbeddedRangeSurface(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    cancel: PrecacheCancel,
    header_slice: []const u8,
    file_size: u64,
    loc: probe.ThumbnailLocation,
) error{Canceled}!?sdl.Surface {
    if (loc.length == 0 or loc.file_offset +| loc.length > file_size) {
        return null;
    }
    const len: usize = @intCast(loc.length);
    if (loc.file_offset +| loc.length <= header_slice.len) {
        if (cancel.isCanceled()) return error.Canceled;
        const off: usize = @intCast(loc.file_offset);
        return sdl.Surface.loadConstMemOpt(header_slice[off .. off + len]);
    }

    const buf = allocator.alloc(u8, len) catch return null;
    defer allocator.free(buf);
    const n = readPositionalRange(
        file,
        io,
        cancel,
        buf,
        loc.file_offset,
    ) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) {
            return error.Canceled;
        }
        return null;
    };
    if (n != len) return null;
    if (cancel.isCanceled()) return error.Canceled;
    return sdl.Surface.loadConstMemOpt(buf);
}

/// Checks whether `path` already has an up-to-date Freedesktop thumbnail in
/// `cfg.cache_dir`, and if missing or stale, extracts an embedded preview (for
/// RAW files) or decodes the image and atomically writes the PNG thumbnail.
pub fn precacheFileThumbnail(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: EnabledThumbCacheConfig,
    path: []const u8,
    cancel: PrecacheCancel,
) PrecacheOutcome {
    if (cancel.isCanceled()) return .canceled;
    if (cfg.write_policy == .never) return .skipped;

    const key = ThumbCacheKey.fromFilePath(io, path, cfg.cache_dir) orelse
        return .skipped;

    const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) {
            return .canceled;
        }
        return .failed;
    };
    const file_size: u64 = s.size;
    if (file_size == 0) return .failed;
    const mtime_sec = s.mtime.toSeconds();

    if (hasValidTargetTierThumbnail(io, cfg, &key, mtime_sec)) {
        return .already_valid;
    }

    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) {
            return .canceled;
        }
        return .failed;
    };
    defer file.close(io);

    const header_target: usize = @intCast(@min(file_size, precache_header_limit));
    var header_buf: [precache_header_limit]u8 = undefined;
    const header_n = readPositionalRange(
        file,
        io,
        cancel,
        header_buf[0..header_target],
        0,
    ) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) {
            return .canceled;
        }
        return .failed;
    };
    if (header_n == 0) return .failed;
    const header_slice = header_buf[0..header_n];

    const mime_type = probe.detectMimeType(header_slice, path);
    const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or
        (header_slice.len >= 8 and
            std.mem.startsWith(u8, header_slice, "FUJIFILM"));
    const is_raw = core_fs.isRawFile(path) or
        is_fuji or
        std.mem.startsWith(u8, mime_type, "image/x-");

    if (is_raw) {
        var prev_loc_opt: ?probe.ThumbnailLocation = null;
        var med_loc_opt: ?probe.ThumbnailLocation = null;
        var thumb_loc_opt: ?probe.ThumbnailLocation = null;
        var raw_sensor_dims: ?probe.JpegDimensions = null;
        var orientation: Orientation = .normal;

        if (is_fuji) {
            prev_loc_opt = probe.extractFujiRafPreviewLocation(header_slice);
            if (probe.extractFujiRafMetadataLocation(header_slice)) |meta_loc| {
                if (meta_loc.file_offset +| meta_loc.length <= header_n) {
                    const end = meta_loc.file_offset + meta_loc.length;
                    raw_sensor_dims = probe.parseFujiRafDimensions(
                        header_slice[@intCast(meta_loc.file_offset)..@intCast(end)],
                    );
                } else if (meta_loc.length > 0 and
                    meta_loc.length <= 64 * 1024 and
                    meta_loc.file_offset +| meta_loc.length <= file_size)
                {
                    var m_buf: [64 * 1024]u8 = undefined;
                    const mn = readPositionalRange(
                        file,
                        io,
                        cancel,
                        m_buf[0..meta_loc.length],
                        meta_loc.file_offset,
                    ) catch |err| blk: {
                        if (err == error.Canceled or cancel.isCanceled()) {
                            return .canceled;
                        }
                        break :blk 0;
                    };
                    if (mn >= meta_loc.length) {
                        raw_sensor_dims = probe.parseFujiRafDimensions(
                            m_buf[0..meta_loc.length],
                        );
                    }
                }
            }
            if (prev_loc_opt) |prev_loc| {
                if (prev_loc.file_offset +| 4096 <= header_n) {
                    const off: usize = @intCast(prev_loc.file_offset);
                    orientation = probe.parseExifOrientation(
                        header_slice[off..header_n],
                    ) orelse .normal;
                    if (probe.extractJpegThumbnailLocation(
                        header_slice[off..header_n],
                    )) |j_thumb| {
                        thumb_loc_opt = .{
                            .file_offset = prev_loc.file_offset +|
                                j_thumb.file_offset,
                            .length = j_thumb.length,
                        };
                    }
                } else {
                    var p_hdr: [8192]u8 = undefined;
                    const pn = readPositionalRange(
                        file,
                        io,
                        cancel,
                        &p_hdr,
                        prev_loc.file_offset,
                    ) catch |err| blk: {
                        if (err == error.Canceled or cancel.isCanceled()) {
                            return .canceled;
                        }
                        break :blk 0;
                    };
                    if (pn > 0) {
                        orientation = probe.parseExifOrientation(
                            p_hdr[0..pn],
                        ) orelse .normal;
                        if (probe.extractJpegThumbnailLocation(
                            p_hdr[0..pn],
                        )) |j_thumb| {
                            thumb_loc_opt = .{
                                .file_offset = prev_loc.file_offset +|
                                    j_thumb.file_offset,
                                .length = j_thumb.length,
                            };
                        }
                    }
                }
            }
        } else {
            var tail_buf: [16 * 1024]u8 = undefined;
            const tiff_source = probe.readTiffSource(
                io,
                &file,
                file_size,
                header_slice,
                &tail_buf,
            );
            const raw_cands =
                probe.extractTiffRawPreviewsFromSource(tiff_source);
            prev_loc_opt = raw_cands.preview;
            med_loc_opt = raw_cands.medium;
            thumb_loc_opt = raw_cands.thumbnail;
            raw_sensor_dims = probe.parseExifDimensionsFromSource(tiff_source);
            if (raw_sensor_dims == null) {
                if (probe.parseImageDimensions(header_slice, mime_type)) |d| {
                    raw_sensor_dims = .{ .w = d.w, .h = d.h };
                }
            }
            orientation =
                probe.parseExifOrientationFromSource(tiff_source) orelse
                .normal;
        }

        const had_embedded_thumb = (thumb_loc_opt != null) or
            (med_loc_opt != null);
        if (!cfg.write_policy.shouldWrite(had_embedded_thumb, false)) {
            return .skipped;
        }

        const candidates = [_]?probe.ThumbnailLocation{
            med_loc_opt,
            prev_loc_opt,
            thumb_loc_opt,
        };
        var decoded_surf: ?sdl.Surface = null;
        for (candidates) |cand_opt| {
            const loc = cand_opt orelse continue;
            const surf_opt = decodeEmbeddedRangeSurface(
                allocator,
                file,
                io,
                cancel,
                header_slice,
                file_size,
                loc,
            ) catch return .canceled;
            if (surf_opt) |surf| {
                decoded_surf = surf;
                break;
            }
        }
        const surf = decoded_surf orelse return .failed;
        defer surf.destroy();

        if (cancel.isCanceled()) return .canceled;

        const source_dims = if (raw_sensor_dims) |d|
            state_pkg.PhysicalDims.initPositive(d.w, d.h)
        else
            state_pkg.PhysicalDims.initPositive(
                @floatFromInt(surf.w()),
                @floatFromInt(surf.h()),
            );

        writeThumbnailPng(
            allocator,
            io,
            cfg,
            &key,
            surf,
            orientation,
            .{
                .uri = key.uri(),
                .mtime_sec = mtime_sec,
                .file_size = file_size,
                .mime_type = mime_type,
                .source_dims = source_dims,
            },
        ) catch return .failed;
        return .written;
    }

    const orientation = probe.parseExifOrientation(header_slice) orelse .normal;
    const full_dims = probe.parseImageDimensions(header_slice, mime_type);
    const had_embedded_thumb: bool = blk: {
        if (!std.mem.eql(u8, mime_type, "image/jpeg")) break :blk false;
        const loc = probe.extractJpegThumbnailLocation(header_slice) orelse
            break :blk false;
        const max_thumb_size_bytes = 512 * 1024;
        break :blk loc.length > 0 and
            loc.length <= max_thumb_size_bytes and
            loc.file_offset +| loc.length <= file_size;
    };

    if (!cfg.write_policy.shouldWrite(had_embedded_thumb, false)) {
        return .skipped;
    }

    const file_usize = std.math.cast(usize, file_size) orelse return .failed;
    var full_allocated: ?[]u8 = null;
    defer if (full_allocated) |b| allocator.free(b);

    const bytes_to_decode: []const u8 = if (file_usize <= header_n)
        header_slice[0..file_usize]
    else blk: {
        const buf = allocator.alloc(u8, file_usize) catch return .failed;
        full_allocated = buf;
        @memcpy(buf[0..header_n], header_slice);
        const rem_n = readPositionalRange(
            file,
            io,
            cancel,
            buf[header_n..],
            header_n,
        ) catch |err| {
            if (err == error.Canceled or cancel.isCanceled()) {
                return .canceled;
            }
            return .failed;
        };
        if (header_n + rem_n != file_usize) return .failed;
        break :blk buf;
    };

    if (cancel.isCanceled()) return .canceled;
    const surf = sdl.Surface.loadConstMemOpt(bytes_to_decode) orelse
        return .failed;
    defer surf.destroy();

    if (cancel.isCanceled()) return .canceled;

    const source_dims = if (full_dims) |d|
        state_pkg.PhysicalDims.initPositive(d.w, d.h)
    else
        state_pkg.PhysicalDims.initPositive(
            @floatFromInt(surf.w()),
            @floatFromInt(surf.h()),
        );

    writeThumbnailPng(
        allocator,
        io,
        cfg,
        &key,
        surf,
        orientation,
        .{
            .uri = key.uri(),
            .mtime_sec = mtime_sec,
            .file_size = file_size,
            .mime_type = mime_type,
            .source_dims = source_dims,
        },
    ) catch return .failed;
    return .written;
}

fn collectPrecacheDirInner(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    recursive: bool,
    out_paths: *std.ArrayList([]const u8),
) !void {
    var dir = std.Io.Dir.openDir(
        std.Io.Dir.cwd(),
        io,
        dir_path,
        .{ .iterate = true },
    ) catch |err| {
        std.log.warn(
            "collectPrecacheFiles: openDir failed for '{s}': {}",
            .{ dir_path, err },
        );
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const kind = core_fs.resolveEntryKind(dir, io, entry) orelse continue;
        if (kind == .file) {
            if (core_fs.isImageFile(entry.name)) {
                const full = try std.Io.Dir.path.join(
                    allocator,
                    &.{ dir_path, entry.name },
                );
                errdefer allocator.free(full);
                try out_paths.append(allocator, full);
            }
        } else if (recursive and kind == .directory) {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            var sub_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            var sub_sfa: std.heap.BufferFirstAllocator = .init(
                &sub_buf,
                allocator,
            );
            const sub_alloc = sub_sfa.allocator();
            const sub_path = try std.Io.Dir.path.join(
                sub_alloc,
                &.{ dir_path, entry.name },
            );
            defer sub_alloc.free(sub_path);
            try collectPrecacheDirInner(
                allocator,
                io,
                sub_path,
                true,
                out_paths,
            );
        }
    }
}

/// Discovers supported image files in `target_path` (either a single file or a
/// directory, optionally traversing non-hidden subdirectories when `recursive`
/// is true) and appends path slices allocated with `allocator` (typically an
/// `ArenaAllocator`) to `out_paths` in sorted order.
pub fn collectPrecacheFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    target_path: []const u8,
    recursive: bool,
    out_paths: *std.ArrayList([]const u8),
) !void {
    const start_len = out_paths.items.len;
    errdefer {
        for (out_paths.items[start_len..]) |p| allocator.free(p);
        out_paths.shrinkRetainingCapacity(start_len);
    }

    const stat = try std.Io.Dir.statFile(
        std.Io.Dir.cwd(),
        io,
        target_path,
        .{},
    );
    if (stat.kind == .file) {
        if (core_fs.isImageFile(target_path)) {
            const dup = try allocator.dupe(u8, target_path);
            errdefer allocator.free(dup);
            try out_paths.append(allocator, dup);
        }
        return;
    }

    if (stat.kind == .directory) {
        try collectPrecacheDirInner(
            allocator,
            io,
            target_path,
            recursive,
            out_paths,
        );
        std.mem.sort([]const u8, out_paths.items[start_len..], {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        }.lessThan);
    }
}

const ParallelPrecacheContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: EnabledThumbCacheConfig,
    paths: []const []const u8,
    cancel: PrecacheCancel,
    next_idx: std.atomic.Value(usize) = .init(0),
    written: std.atomic.Value(usize) = .init(0),
    already_valid: std.atomic.Value(usize) = .init(0),
    skipped: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(usize) = .init(0),

    fn workerTask(self: *ParallelPrecacheContext) void {
        var scratch_arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch_arena.deinit();

        while (!self.cancel.isCanceled()) {
            defer _ = scratch_arena.reset(.{
                .retain_with_limit = 4 * 1024 * 1024,
            });
            const idx = self.next_idx.fetchAdd(1, .monotonic);
            if (idx >= self.paths.len) break;

            switch (precacheFileThumbnail(
                scratch_arena.allocator(),
                self.io,
                self.cfg,
                self.paths[idx],
                self.cancel,
            )) {
                .written => _ = self.written.fetchAdd(1, .monotonic),
                .already_valid => _ = self.already_valid.fetchAdd(
                    1,
                    .monotonic,
                ),
                .skipped => _ = self.skipped.fetchAdd(1, .monotonic),
                .failed => _ = self.failed.fetchAdd(1, .monotonic),
                .canceled => break,
            }
        }
    }
};

/// Pre-caches Freedesktop thumbnails for `paths` in parallel across up to
/// `max_workers` concurrent worker tasks using `std.Io.Group`.
pub fn precachePathsParallel(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: EnabledThumbCacheConfig,
    paths: []const []const u8,
    max_workers: usize,
    cancel: PrecacheCancel,
) PrecacheStats {
    if (paths.len == 0) return .{};

    var ctx = ParallelPrecacheContext{
        .allocator = allocator,
        .io = io,
        .cfg = cfg,
        .paths = paths,
        .cancel = cancel,
    };

    const worker_count = @max(1, @min(paths.len, max_workers));
    if (worker_count == 1) {
        ctx.workerTask();
    } else {
        var group: std.Io.Group = .init;
        for (0..worker_count) |_| {
            group.async(io, ParallelPrecacheContext.workerTask, .{&ctx});
        }
        group.await(io) catch {};
    }

    return .{
        .total_files = paths.len,
        .written = ctx.written.load(.acquire),
        .already_valid = ctx.already_valid.load(.acquire),
        .skipped = ctx.skipped.load(.acquire),
        .failed = ctx.failed.load(.acquire),
    };
}

test "ThumbCacheKey.fromCanonicalPath RFC 3986 URI encoding and MD5" {
    // Verified against real Yazi/Freedesktop thumbnail hash:
    const key = ThumbCacheKey.fromCanonicalPath(
        "/home/pope/Pictures/Dane/20200130-Dane Halo Boudoir-0026.RAF",
    ) orelse return error.KeyFailed;

    const expected_uri =
        "file:///home/pope/Pictures/Dane/" ++
        "20200130-Dane%20Halo%20Boudoir-0026.RAF";
    try std.testing.expectEqualStrings(expected_uri, key.uri());
    try std.testing.expectEqualStrings(
        "471d74bb412f63823a18d8ea393ef5c2",
        &key.md5_hex,
    );
}

test "ThumbCacheConfig.initPosixFromEnviron resolves XDG_CACHE_HOME and HOME" {
    const allocator = std.testing.allocator;

    // 1. XDG_CACHE_HOME set to absolute path takes precedence
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("XDG_CACHE_HOME", "/custom/xdg_cache");
        try env.put("HOME", "/home/tester");

        var cfg = ThumbCacheConfig.initPosixFromEnviron(
            allocator,
            &env,
            .all_missing,
        );
        defer cfg.deinit(allocator);
        try std.testing.expect(cfg == .enabled);
        try std.testing.expectEqualStrings(
            "/custom/xdg_cache/thumbnails",
            cfg.enabled.cache_dir,
        );
        try std.testing.expectEqual(
            ThumbWritePolicy.all_missing,
            cfg.enabled.write_policy,
        );
    }

    // 2. Relative XDG_CACHE_HOME is ignored per XDG Base Directory
    //    Specification, falling back to $HOME/.cache/thumbnails
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("XDG_CACHE_HOME", "relative/cache");
        try env.put("HOME", "/home/tester");

        var cfg = ThumbCacheConfig.initPosixFromEnviron(
            allocator,
            &env,
            .missing_embedded_only,
        );
        defer cfg.deinit(allocator);
        try std.testing.expect(cfg == .enabled);
        try std.testing.expectEqualStrings(
            "/home/tester/.cache/thumbnails",
            cfg.enabled.cache_dir,
        );
        try std.testing.expectEqual(
            ThumbWritePolicy.missing_embedded_only,
            cfg.enabled.write_policy,
        );
    }

    // 3. Empty environment or null policy returns .disabled
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();

        var cfg = ThumbCacheConfig.initPosixFromEnviron(
            allocator,
            &env,
            .all_missing,
        );
        defer cfg.deinit(allocator);
        try std.testing.expect(cfg == .disabled);

        try env.put("HOME", "/home/tester");
        var off_cfg = ThumbCacheConfig.initPosixFromEnviron(
            allocator,
            &env,
            null,
        );
        defer off_cfg.deinit(allocator);
        try std.testing.expect(off_cfg == .disabled);
    }
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
        !hasValidTargetTierThumbnail(io, enabled_cfg, &key, mtime_sec),
    );

    try writeThumbnailPng(allocator, io, enabled_cfg, &key, surf, .rotate_90, .{
        .uri = key.uri(),
        .mtime_sec = mtime_sec,
        .file_size = 39358464,
        .mime_type = "image/x-sony-arw",
        .source_dims = .{ .w = 600.0, .h = 400.0 },
    });

    try std.testing.expect(
        hasValidTargetTierThumbnail(io, enabled_cfg, &key, mtime_sec),
    );
    // Mismatched mtime must report invalid
    try std.testing.expect(
        !hasValidTargetTierThumbnail(io, enabled_cfg, &key, mtime_sec + 1),
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

test "precacheFileThumbnail and precachePathsParallel generate and skip valid thumbnails" {
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
    const first_outcome = precacheFileThumbnail(
        allocator,
        io,
        enabled_cfg,
        test_img,
        .{},
    );
    try std.testing.expectEqual(PrecacheOutcome.written, first_outcome);

    // Second run detects valid cached thumbnail and returns .already_valid
    const second_outcome = precacheFileThumbnail(
        allocator,
        io,
        enabled_cfg,
        test_img,
        .{},
    );
    try std.testing.expectEqual(PrecacheOutcome.already_valid, second_outcome);
}

test "collectPrecacheFiles respects flat vs recursive directory traversal" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.createDirPath(io, ".hidden");
    {
        var f1 = try tmp.dir.createFile(io, "a.jpg", .{});
        f1.close(io);
        var f2 = try tmp.dir.createFile(io, "nested/b.png", .{});
        f2.close(io);
        var f3 = try tmp.dir.createFile(io, ".hidden/c.png", .{});
        f3.close(io);
        var f4 = try tmp.dir.createFile(io, "notes.txt", .{});
        f4.close(io);
    }

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try std.mem.print(
        &root_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    // Flat scan finds only a.jpg
    {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var flat_paths: std.ArrayList([]const u8) = .empty;
        try collectPrecacheFiles(
            arena.allocator(),
            io,
            root_path,
            false,
            &flat_paths,
        );
        try std.testing.expectEqual(@as(usize, 1), flat_paths.items.len);
        try std.testing.expect(
            std.mem.endsWith(u8, flat_paths.items[0], "a.jpg"),
        );
    }

    // Recursive scan finds a.jpg and nested/b.png (ignoring .hidden and .txt)
    {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var rec_paths: std.ArrayList([]const u8) = .empty;
        try collectPrecacheFiles(
            arena.allocator(),
            io,
            root_path,
            true,
            &rec_paths,
        );
        try std.testing.expectEqual(@as(usize, 2), rec_paths.items.len);
        try std.testing.expect(
            std.mem.endsWith(u8, rec_paths.items[0], "a.jpg"),
        );
        try std.testing.expect(
            std.mem.endsWith(u8, rec_paths.items[1], "nested/b.png"),
        );
    }
}
