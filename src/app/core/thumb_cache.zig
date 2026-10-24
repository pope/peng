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
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const Orientation = state_pkg.Orientation;

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
    var slices = [_][]u8{&hdr_buf};
    const n = file.readPositional(io, &slices, 0) catch return false;
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

        const stat = std.Io.Dir.statFile(
            std.Io.Dir.cwd(),
            io,
            thumb_path,
            .{},
        ) catch continue;
        if (stat.size < ihdr_end_offset or stat.size > max_cached_png_bytes) {
            continue;
        }
        const size: usize = @intCast(stat.size);

        var file = std.Io.Dir.openFile(
            std.Io.Dir.cwd(),
            io,
            thumb_path,
            .{},
        ) catch continue;
        defer file.close(io);

        const bytes = allocator.alloc(u8, size) catch continue;
        defer allocator.free(bytes);

        var total_read: usize = 0;
        while (total_read < size) {
            var slices = [_][]u8{bytes[total_read..]};
            const n = file.readPositional(io, &slices, total_read) catch break;
            if (n == 0) break;
            total_read += n;
        }
        if (total_read != size) continue;

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
        surface.scale(target_w, target_h, .linear) orelse
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
