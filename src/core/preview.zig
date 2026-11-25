//! Terminal Preview Renderer
//!
//! Decodes standard raster images, Camera RAW embedded previews, `.cbz`
//! archives, and Freedesktop cached thumbnails, scales and orients them to
//! RGBA32, and writes temporary files for the Kitty Graphics Protocol (`t=t`).

const geom = @import("geom");
const probe = @import("probe");
const sdl = @import("sdl");
const std = @import("std");
const thumbcache = @import("thumbcache");
const thumbcache_sdl = @import("thumbcache.zig");
const vfs = @import("vfs");

const decompressCbzMediaEntry = vfs.decompressCbzMediaEntry;
const isRawFile = vfs.isRawFile;
const loadCachedThumbnail = thumbcache_sdl.loadCachedThumbnail;
const max_cbz_entry_bytes = vfs.max_cbz_entry_bytes;
const MediaEntry = vfs.MediaEntry;
const Orientation = probe.Orientation;
const PositiveDimsU32 = geom.PositiveDimsU32;
const readLocationBytes = probe.readLocationBytes;
const readRangePositional = probe.readRangePositional;
const scaleAndOrientSurface = thumbcache_sdl.scaleAndOrientSurface;
const scanCbzImageEntries = vfs.scanCbzImageEntries;
const ThumbCacheConfig = thumbcache.ThumbCacheConfig;
const ThumbCacheKey = thumbcache.ThumbCacheKey;
const ThumbnailLocation = probe.ThumbnailLocation;

const header_probe_limit: usize = 256 * 1024;
var preview_file_seq: std.atomic.Value(u64) = .init(0);

/// Zero-cost non-canceling token for one-shot CLI preview rendering.
pub const NoCancel = struct {
    /// Always returns `false`.
    pub inline fn isCanceled(_: NoCancel) bool {
        return false;
    }
};

/// Result of rendering a scaled, EXIF-oriented RGBA32 preview surface in
/// memory (used directly by inline terminal encoders like Sixel or written
/// to a temp file for Kitty `t=t`).
pub const PreviewSurface = struct {
    surface: sdl.Surface,
    dims: PositiveDimsU32,

    /// Destroys the owned `sdl.Surface`.
    pub fn deinit(self: PreviewSurface) void {
        self.surface.destroy();
    }
};

/// Result of rendering a raw RGBA32 preview file for the Kitty Graphics
/// Protocol (`t=t`).
pub const PreviewRenderResult = struct {
    path_buf: [128]u8 = undefined,
    path_len: usize,
    dims: PositiveDimsU32,

    /// Returns the written temporary file path slice.
    pub fn path(self: *const PreviewRenderResult) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

const DecodedPreviewSource = struct {
    surface: sdl.Surface,
    orientation: Orientation,
};

fn preRotationMaxDims(
    max_dims: PositiveDimsU32,
    orientation: Orientation,
) PositiveDimsU32 {
    const quarter_turns: u2 = @backingInt(orientation);
    const is_swapped = (quarter_turns & 1) != 0;
    const raw_w = if (is_swapped) max_dims.h else max_dims.w;
    const raw_h = if (is_swapped) max_dims.w else max_dims.h;
    return .{
        .w = @min(raw_w, 4096),
        .h = @min(raw_h, 4096),
    };
}

fn decodeEmbeddedLocSurface(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    cancel: anytype,
    header_slice: []const u8,
    file_size: u64,
    loc: ThumbnailLocation,
    raw_max: PositiveDimsU32,
) !?sdl.Surface {
    if (cancel.isCanceled()) return error.Canceled;
    var loc_bytes = (try readLocationBytes(
        allocator,
        file,
        io,
        cancel,
        header_slice,
        file_size,
        loc,
        null,
    )) orelse return null;
    defer loc_bytes.deinit(allocator);
    if (cancel.isCanceled()) return error.Canceled;
    return sdl.Surface.loadConstMemScaledOpt(
        loc_bytes.bytes,
        raw_max.w,
        raw_max.h,
    );
}

fn decodePreviewSourceSurface(
    allocator: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: ThumbCacheConfig,
    path: []const u8,
    max_dims: PositiveDimsU32,
    cancel: anytype,
) !DecodedPreviewSource {
    if (cancel.isCanceled()) return error.Canceled;

    const s = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, path, .{});
    if (s.kind == .directory) return error.IsDir;
    if (s.kind != .file) return error.UnsupportedFileType;
    const file_size: u64 = s.size;
    if (file_size == 0) return error.EmptyFile;
    const mtime_sec = s.mtime.toSeconds();

    if (std.ascii.endsWithIgnoreCase(path, ".cbz")) {
        var cbz_entries: std.ArrayList(MediaEntry) = .empty;
        defer {
            for (cbz_entries.items) |item| item.deinit(allocator);
            cbz_entries.deinit(allocator);
        }
        try scanCbzImageEntries(allocator, io, path, &cbz_entries);
        if (cbz_entries.items.len == 0) return error.NoImagesInArchive;
        if (cancel.isCanceled()) return error.Canceled;
        const decomp = try decompressCbzMediaEntry(
            allocator,
            io,
            cbz_entries.items[0].archive_entry,
            null,
        );
        defer allocator.free(decomp.bytes);
        if (cancel.isCanceled()) return error.Canceled;
        const hdr = decomp.bytes[0..@min(decomp.bytes.len, header_probe_limit)];
        const orientation = probe.parseExifOrientation(hdr) orelse .normal;
        const raw_max = preRotationMaxDims(max_dims, orientation);
        const surf = sdl.Surface.loadConstMemScaledOpt(
            decomp.bytes,
            raw_max.w,
            raw_max.h,
        ) orelse return error.DecodeFailed;
        return .{ .surface = surf, .orientation = orientation };
    }

    const req_max_dim = @max(max_dims.w, max_dims.h);
    if (req_max_dim <= 1024) {
        switch (thumb_cfg) {
            .enabled => |cfg| {
                if (ThumbCacheKey.fromFilePath(
                    io,
                    path,
                    cfg.cache_dir,
                )) |cache_key| {
                    if (loadCachedThumbnail(
                        allocator,
                        io,
                        cfg,
                        &cache_key,
                        mtime_sec,
                        req_max_dim,
                    )) |cached| {
                        return .{
                            .surface = cached.surface,
                            .orientation = .normal,
                        };
                    }
                }
            },
            .disabled => {},
        }
    }

    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{});
    defer file.close(io);

    const header_target: usize = @intCast(@min(file_size, header_probe_limit));
    const header_buf = try allocator.alloc(u8, header_target);
    defer allocator.free(header_buf);

    const header_n = try readRangePositional(
        file,
        io,
        cancel,
        header_buf,
        0,
    );
    if (header_n == 0) return error.EmptyFile;
    const header_slice = header_buf[0..header_n];

    const mime_type = probe.detectMimeType(header_slice, path);
    const is_raw = isRawFile(path) or
        probe.isRawContainer(header_slice, mime_type);

    if (is_raw) {
        const raw_probe = probe.probeRawFileHeader(
            io,
            &file,
            file_size,
            header_slice,
            mime_type,
        );
        if (cancel.isCanceled()) return error.Canceled;

        const orientation = raw_probe.orientation;
        const raw_max = preRotationMaxDims(max_dims, orientation);
        const candidates = raw_probe.selectPreviewCandidates(max_dims);
        var small_fallback: ?sdl.Surface = null;
        errdefer if (small_fallback) |fb| fb.destroy();

        for (candidates, 0..) |cand_opt, idx| {
            const loc = cand_opt orelse continue;
            if (try decodeEmbeddedLocSurface(
                allocator,
                file,
                io,
                cancel,
                header_slice,
                file_size,
                loc,
                raw_max,
            )) |surf| {
                const is_small_medium = idx == 0 and
                    raw_probe.medium != null and
                    raw_probe.preview != null and
                    loc.file_offset == raw_probe.medium.?.file_offset and
                    @as(u32, @intCast(@max(0, surf.w()))) < raw_max.w and
                    @as(u32, @intCast(@max(0, surf.h()))) < raw_max.h;
                if (is_small_medium) {
                    small_fallback = surf;
                    continue;
                }
                if (small_fallback) |fb| fb.destroy();
                return .{ .surface = surf, .orientation = orientation };
            }
        }
        if (small_fallback) |surf| {
            return .{ .surface = surf, .orientation = orientation };
        }
        return error.DecodeFailed;
    }

    const orientation = probe.parseExifOrientation(header_slice) orelse .normal;
    const raw_max = preRotationMaxDims(max_dims, orientation);
    if (max_dims.w <= 200 and max_dims.h <= 200) {
        if (probe.extractValidJpegThumbnailLocation(
            header_slice,
            mime_type,
            file_size,
            null,
        )) |loc| {
            if (try decodeEmbeddedLocSurface(
                allocator,
                file,
                io,
                cancel,
                header_slice,
                file_size,
                loc,
                raw_max,
            )) |surf| {
                return .{ .surface = surf, .orientation = orientation };
            }
        }
    }

    if (file_size > max_cbz_entry_bytes) return error.FileTooLarge;
    const file_usize = std.math.cast(usize, file_size) orelse
        return error.FileTooLarge;
    var full_allocated: ?[]u8 = null;
    defer if (full_allocated) |b| allocator.free(b);

    const bytes_to_decode: []const u8 = if (file_usize <= header_n)
        header_slice[0..file_usize]
    else blk: {
        const buf = try allocator.alloc(u8, file_usize);
        full_allocated = buf;
        @memcpy(buf[0..header_n], header_slice);
        const rem_n = try readRangePositional(
            file,
            io,
            cancel,
            buf[header_n..],
            header_n,
        );
        if (header_n + rem_n != file_usize) return error.UnexpectedEof;
        break :blk buf;
    };

    if (cancel.isCanceled()) return error.Canceled;
    const surf = sdl.Surface.loadConstMemScaledOpt(
        bytes_to_decode,
        raw_max.w,
        raw_max.h,
    ) orelse return error.DecodeFailed;
    return .{ .surface = surf, .orientation = orientation };
}

/// Decodes `path` (supporting standard raster images, Camera RAW embedded
/// previews, `.cbz` archives, and Freedesktop cached thumbnails), scales and
/// rotates it to fit within `max_dims`, and returns an owned RGBA32 surface.
pub fn renderPreviewSurface(
    allocator: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: ThumbCacheConfig,
    path: []const u8,
    max_dims: PositiveDimsU32,
    cancel: anytype,
) !PreviewSurface {
    const decoded = try decodePreviewSourceSurface(
        allocator,
        io,
        thumb_cfg,
        path,
        max_dims,
        cancel,
    );
    var owns_decoded = true;
    errdefer if (owns_decoded) decoded.surface.destroy();

    if (cancel.isCanceled()) return error.Canceled;

    const src_w = decoded.surface.w();
    const src_h = decoded.surface.h();
    if (src_w <= 0 or src_h <= 0) return error.InvalidDimensions;

    const raw_max = preRotationMaxDims(max_dims, decoded.orientation);
    const eff_max_w: i32 = @intCast(raw_max.w);
    const eff_max_h: i32 = @intCast(raw_max.h);

    var target_w: i32 = src_w;
    var target_h: i32 = src_h;
    if (src_w > eff_max_w or src_h > eff_max_h) {
        const sx = @as(f64, @floatFromInt(eff_max_w)) /
            @as(f64, @floatFromInt(src_w));
        const sy = @as(f64, @floatFromInt(eff_max_h)) /
            @as(f64, @floatFromInt(src_h));
        const factor = @min(sx, sy);
        target_w = @max(
            1,
            @as(
                i32,
                @intFromFloat(@round(@as(f64, @floatFromInt(src_w)) * factor)),
            ),
        );
        target_h = @max(
            1,
            @as(
                i32,
                @intFromFloat(@round(@as(f64, @floatFromInt(src_h)) * factor)),
            ),
        );
    }

    const transformed = try scaleAndOrientSurface(
        decoded.surface,
        target_w,
        target_h,
        decoded.orientation,
        true,
    );
    if (transformed.owned) {
        decoded.surface.destroy();
        owns_decoded = false;
    }
    errdefer if (transformed.owned) transformed.surface.destroy();

    const final_surf = transformed.surface;
    if (cancel.isCanceled()) return error.Canceled;

    const out_w = final_surf.w();
    const out_h = final_surf.h();
    if (out_w <= 0 or out_h <= 0) return error.InvalidDimensions;

    return .{
        .surface = final_surf,
        .dims = .{
            .w = @intCast(out_w),
            .h = @intCast(out_h),
        },
    };
}

const TempPreviewFile = struct {
    file: std.Io.File,
    res: PreviewRenderResult,
};

fn createTempPreviewFile(
    io: std.Io,
    ext: []const u8,
    dims: PositiveDimsU32,
) !TempPreviewFile {
    const seq = preview_file_seq.fetchAdd(1, .monotonic);
    const tick: u64 =
        @intCast(@max(0, std.Io.Clock.awake.now(io).nanoseconds));
    const file_perms: std.Io.File.Permissions =
        if (std.Io.File.Permissions.has_executable_bit)
            .fromMode(0o600)
        else
            .default_file;

    var res: PreviewRenderResult = .{
        .path_len = 0,
        .dims = dims,
    };

    const candidate_dirs = [_][]const u8{ "/dev/shm", "/tmp" };
    dir_loop: for (candidate_dirs) |dir_prefix| {
        for (0..4) |attempt| {
            const candidate_path = std.mem.print(
                &res.path_buf,
                "{s}/tty-graphics-protocol-peng-{x}-{d}.{s}",
                .{ dir_prefix, tick, seq + attempt, ext },
            ) catch continue :dir_loop;
            if (std.Io.Dir.createFile(
                std.Io.Dir.cwd(),
                io,
                candidate_path,
                .{ .permissions = file_perms, .exclusive = true },
            )) |f| {
                res.path_len = candidate_path.len;
                return .{ .file = f, .res = res };
            } else |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => {
                    std.log.debug(
                        "Preview temp file create failed in '{s}': {}",
                        .{ dir_prefix, err },
                    );
                    continue :dir_loop;
                },
            }
        }
    }
    return error.TempFileCreateFailed;
}

/// Atomically writes `bytes` to `out_path` via temp-file creation and rename.
pub fn writeOutputFileAtomic(
    io: std.Io,
    out_path: []const u8,
    bytes: []const u8,
) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, out_path, .{
        .replace = true,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.replace(io);
}

/// Decodes, orients, and scales `path` to fit within `max_dims`, encodes it as
/// JPEG (opaque) or PNG (alpha), and writes it to a temporary file in
/// `/dev/shm` or `/tmp`. Caller owns the returned file path.
pub fn renderPreviewEncodedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: ThumbCacheConfig,
    path: []const u8,
    max_dims: PositiveDimsU32,
    cancel: anytype,
) !PreviewRenderResult {
    const preview = try renderPreviewSurface(
        allocator,
        io,
        thumb_cfg,
        path,
        max_dims,
        cancel,
    );
    defer preview.deinit();

    const image_bytes = try preview.surface.encodePreviewImageAlloc(
        allocator,
        85,
    );
    defer allocator.free(image_bytes);
    if (cancel.isCanceled()) return error.Canceled;

    const tmp = try createTempPreviewFile(io, "img", preview.dims);
    var out_file = tmp.file;
    const res = tmp.res;
    errdefer {
        std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, res.path()) catch |del_e| {
            std.log.warn(
                "Failed to clean up preview temp file '{s}': {}",
                .{ res.path(), del_e },
            );
        };
    }
    defer out_file.close(io);

    try out_file.writeStreamingAll(io, image_bytes);
    if (cancel.isCanceled()) return error.Canceled;
    return res;
}

/// Decodes, orients, and scales `path` to fit within `max_dims`, encodes it as
/// JPEG (opaque) or PNG (alpha), and atomically writes the result to
/// `out_path`.
pub fn renderPreviewToOutputFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: ThumbCacheConfig,
    path: []const u8,
    out_path: []const u8,
    max_dims: PositiveDimsU32,
    cancel: anytype,
) !PositiveDimsU32 {
    const preview = try renderPreviewSurface(
        allocator,
        io,
        thumb_cfg,
        path,
        max_dims,
        cancel,
    );
    defer preview.deinit();

    const image_bytes = try preview.surface.encodePreviewImageAlloc(
        allocator,
        85,
    );
    defer allocator.free(image_bytes);
    if (cancel.isCanceled()) return error.Canceled;

    try writeOutputFileAtomic(io, out_path, image_bytes);
    return preview.dims;
}

/// Decodes, orients, and scales `path` to fit within `max_dims`, then writes
/// raw packed RGBA32 bytes to a temporary file in `/dev/shm` or `/tmp` for
/// Kitty Graphics Protocol `t=t` transfer.
pub fn renderPreviewRgbaFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: ThumbCacheConfig,
    path: []const u8,
    max_dims: PositiveDimsU32,
    cancel: anytype,
) !PreviewRenderResult {
    const preview = try renderPreviewSurface(
        allocator,
        io,
        thumb_cfg,
        path,
        max_dims,
        cancel,
    );
    defer preview.deinit();
    const final_surf = preview.surface;

    const tmp = try createTempPreviewFile(io, "rgba", preview.dims);
    var out_file = tmp.file;
    const res = tmp.res;
    errdefer {
        std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, res.path()) catch |del_e| {
            std.log.warn(
                "Failed to clean up preview temp file '{s}': {}",
                .{ res.path(), del_e },
            );
        };
    }
    defer out_file.close(io);

    const w_usize: usize = @intCast(res.dims.w);
    const h_usize: usize = @intCast(res.dims.h);
    const row_bytes: usize = w_usize * 4;
    const pitch_usize: usize = @intCast(final_surf.pitch());
    const base_ptr = final_surf.pixels();

    if (pitch_usize == row_bytes) {
        try out_file.writeStreamingAll(io, base_ptr[0 .. row_bytes * h_usize]);
    } else {
        for (0..h_usize) |row| {
            const row_start = row * pitch_usize;
            try out_file.writeStreamingAll(
                io,
                base_ptr[row_start .. row_start + row_bytes],
            );
        }
    }
    if (cancel.isCanceled()) return error.Canceled;
    return res;
}

test "renderPreviewRgbaFile downscales and writes RGBA32 temp file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const res = try renderPreviewRgbaFile(
        allocator,
        io,
        .disabled,
        "testfiles/images/000_0_1024x682.jpg",
        .{ .w = 160, .h = 120 },
        NoCancel{},
    );
    defer std.Io.Dir.deleteFile(
        std.Io.Dir.cwd(),
        io,
        res.path(),
    ) catch {};

    try std.testing.expect(res.dims.w <= 160);
    try std.testing.expect(res.dims.h <= 120);

    const stat = try std.Io.Dir.statFile(
        std.Io.Dir.cwd(),
        io,
        res.path(),
        .{},
    );
    const expected_bytes = @as(u64, res.dims.w) * @as(u64, res.dims.h) * 4;
    try std.testing.expectEqual(expected_bytes, stat.size);
}
