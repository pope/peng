//! Terminal Preview Worker Module
//!
//! Spawns background worker tasks to decode, downscale, and serialize
//! raw RGBA32 temporary files for Kitty Graphics Protocol (`t=t`) preview.

const context = @import("context.zig");
const core = @import("core");
const geom = @import("geom");
const ipc = @import("ipc");
const manager = @import("manager.zig");
const probe = @import("probe");
const sdl = @import("sdl");
const std = @import("std");
const thumbcache = @import("thumbcache");
const vfs = @import("vfs");

const CancellationToken = context.CancellationToken;
const decompressCbzMediaEntry = vfs.decompressCbzMediaEntry;
const header_probe_limit = context.header_probe_limit;
const isRawFile = vfs.isRawFile;
const loadCachedThumbnail = core.thumbcache.loadCachedThumbnail;
const max_cbz_entry_bytes = vfs.max_cbz_entry_bytes;
const MediaEntry = vfs.MediaEntry;
const Orientation = probe.Orientation;
const PositiveDimsU32 = geom.PositiveDimsU32;
const readRangePositional = context.readRangePositional;
const scanCbzImageEntries = vfs.scanCbzImageEntries;
const ThumbCacheConfig = thumbcache.ThumbCacheConfig;
const ThumbCacheKey = thumbcache.ThumbCacheKey;
const ThumbnailLocation = probe.ThumbnailLocation;
const WorkerManager = manager.WorkerManager;

var preview_file_seq: std.atomic.Value(u64) = .init(0);

/// Result of rendering a raw RGBA32 preview file for the Kitty Graphics
/// Protocol (`t=t`).
const PreviewRenderResult = struct {
    path_buf: [128]u8 = undefined,
    path_len: usize,
    dims: PositiveDimsU32,

    /// Returns the written temporary file path slice.
    pub fn path(self: *const PreviewRenderResult) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// Contextual arguments passed to background terminal preview worker tasks.
pub const PreviewWorkerArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    client_stream: std.Io.net.Stream,
    path: []const u8,
    max_dims: PositiveDimsU32,
    generation: usize = 0,

    /// Builds a cooperative cancellation token for this preview task.
    pub inline fn cancelToken(
        self: *const PreviewWorkerArgs,
    ) CancellationToken {
        return .{
            .exiting = &self.workers.exiting,
            .generation = self.generation,
            .current_generation = &self.workers.preview_generation,
        };
    }

    /// Frees the owned path slice and argument struct.
    pub fn deinit(self: *PreviewWorkerArgs) void {
        const alloc = self.allocator;
        alloc.free(self.path);
        alloc.destroy(self);
    }
};

/// Spawns a background `previewWorker` task on `workers.group` to decode,
/// downscale, and write a raw RGBA32 temporary file for Kitty `t=t` display.
pub fn spawnPreview(args: *PreviewWorkerArgs) void {
    args.generation =
        args.workers.preview_generation.fetchAdd(1, .acq_rel) +% 1;
    _ = args.workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    args.workers.group.async(args.io, previewWorker, .{args});
}

fn previewWorker(args: *PreviewWorkerArgs) void {
    const workers = args.workers;
    const alloc = args.allocator;
    const io = args.io;
    const stream = args.client_stream;
    defer {
        const prev_decodes = workers.active_decode_threads.fetchSub(
            1,
            .acq_rel,
        );
        if (prev_decodes == 1) {
            sdl.reclaimProcessHeap();
        }
        _ = workers.active_threads.fetchSub(1, .acq_rel);
        context.wakeUpMainThread();
    }
    defer args.deinit();

    const cancel = args.cancelToken();
    const res = renderPreviewRgbaFile(
        alloc,
        io,
        workers.thumb_cache_config,
        args.path,
        args.max_dims,
        cancel,
    ) catch |err| {
        ipc.respondErrorName(io, stream, @errorName(err));
        return;
    };

    ipc.respondPreview(
        io,
        stream,
        res.path(),
        res.dims,
    ) catch |err| {
        std.log.warn("IPC preview response write failed: {}", .{err});
        std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, res.path()) catch |del_e| {
            std.log.warn(
                "Failed to delete unconsumed preview temp file '{s}': {}",
                .{ res.path(), del_e },
            );
        };
    };
}

const DecodedPreviewSource = struct {
    surface: sdl.Surface,
    orientation: Orientation,
};

fn decodeEmbeddedLocSurface(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    cancel: CancellationToken,
    header_slice: []const u8,
    file_size: u64,
    loc: ThumbnailLocation,
) !?sdl.Surface {
    if (cancel.isCanceled()) return error.Canceled;
    var loc_bytes = (try context.readLocationBytes(
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
    return sdl.Surface.loadConstMemOpt(loc_bytes.bytes);
}

fn decodePreviewSourceSurface(
    allocator: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: ThumbCacheConfig,
    path: []const u8,
    max_dims: PositiveDimsU32,
    cancel: CancellationToken,
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
        const surf = sdl.Surface.loadConstMemOpt(decomp.bytes) orelse
            return error.DecodeFailed;
        return .{ .surface = surf, .orientation = orientation };
    }

    if (max_dims.w <= 256 and max_dims.h <= 256) {
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
        const candidates = raw_probe.selectPreviewCandidates(max_dims);

        for (candidates) |cand_opt| {
            const loc = cand_opt orelse continue;
            if (try decodeEmbeddedLocSurface(
                allocator,
                file,
                io,
                cancel,
                header_slice,
                file_size,
                loc,
            )) |surf| {
                return .{ .surface = surf, .orientation = orientation };
            }
        }
        return error.DecodeFailed;
    }

    const orientation = probe.parseExifOrientation(header_slice) orelse .normal;
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
    const surf = sdl.Surface.loadConstMemOpt(bytes_to_decode) orelse
        return error.DecodeFailed;
    return .{ .surface = surf, .orientation = orientation };
}

/// Decodes `path` (supporting standard raster images, Camera RAW embedded
/// previews, `.cbz` archives, and Freedesktop cached thumbnails), scales and
/// rotates it to fit within `max_dims`, and writes raw RGBA32 pixels to a
/// Kitty Graphics Protocol `t=t` temporary file.
fn renderPreviewRgbaFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: ThumbCacheConfig,
    path: []const u8,
    max_dims: PositiveDimsU32,
    cancel: CancellationToken,
) !PreviewRenderResult {
    const decoded = try decodePreviewSourceSurface(
        allocator,
        io,
        thumb_cfg,
        path,
        max_dims,
        cancel,
    );
    defer decoded.surface.destroy();

    if (cancel.isCanceled()) return error.Canceled;

    const src_w = decoded.surface.w();
    const src_h = decoded.surface.h();
    if (src_w <= 0 or src_h <= 0) return error.InvalidDimensions;

    const quarter_turns: u2 = @backingInt(decoded.orientation);
    const is_swapped = (quarter_turns & 1) != 0;
    const raw_max_w = if (is_swapped) max_dims.h else max_dims.w;
    const raw_max_h = if (is_swapped) max_dims.w else max_dims.h;
    const eff_max_w: i32 = @intCast(@min(raw_max_w, 4096));
    const eff_max_h: i32 = @intCast(@min(raw_max_h, 4096));

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

    const scaled_owned = if (target_w != src_w or target_h != src_h)
        decoded.surface.scaleRgba32Smooth(target_w, target_h) orelse
            return error.ScaleFailed
    else
        null;
    defer if (scaled_owned) |s| s.destroy();
    const base_surf = scaled_owned orelse decoded.surface;

    const rotated_owned = if (quarter_turns != 0)
        base_surf.rotateOrthogonal(quarter_turns) orelse
            return error.RotateFailed
    else
        null;
    defer if (rotated_owned) |r| r.destroy();
    const oriented_surf = rotated_owned orelse base_surf;

    const needs_rgba = oriented_surf.format() != sdl.PixelFormat.rgba32;
    const converted_owned = if (needs_rgba)
        oriented_surf.convert(sdl.PixelFormat.rgba32) orelse
            return error.ConvertFailed
    else
        null;
    defer if (converted_owned) |c| c.destroy();
    const final_surf = converted_owned orelse oriented_surf;

    if (cancel.isCanceled()) return error.Canceled;

    const seq = preview_file_seq.fetchAdd(1, .monotonic);
    const tick = sdl.timer.getTicksNs();
    const file_perms: std.Io.File.Permissions =
        if (std.Io.File.Permissions.has_executable_bit)
            .fromMode(0o600)
        else
            .default_file;

    var res: PreviewRenderResult = .{
        .path_len = 0,
        .dims = .{
            .w = @intCast(final_surf.w()),
            .h = @intCast(final_surf.h()),
        },
    };

    const candidate_dirs = [_][]const u8{ "/dev/shm", "/tmp" };
    var out_file_opt: ?std.Io.File = null;
    for (candidate_dirs) |dir_prefix| {
        const candidate_path = std.mem.print(
            &res.path_buf,
            "{s}/tty-graphics-protocol-peng-{x}-{d}.rgba",
            .{ dir_prefix, tick, seq },
        ) catch continue;
        if (std.Io.Dir.createFile(
            std.Io.Dir.cwd(),
            io,
            candidate_path,
            .{ .permissions = file_perms, .exclusive = true },
        )) |f| {
            res.path_len = candidate_path.len;
            out_file_opt = f;
            break;
        } else |_| {}
    }
    var out_file = out_file_opt orelse return error.TempFileCreateFailed;
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

    var exiting = std.atomic.Value(bool).init(false);
    const cancel: CancellationToken = .{ .exiting = &exiting };

    const res = try renderPreviewRgbaFile(
        allocator,
        io,
        .disabled,
        "testfiles/images/000_0_1024x682.jpg",
        .{ .w = 160, .h = 120 },
        cancel,
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

test "renderPreviewRgbaFile aborts when preview_generation advances" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    workers.preview_generation.store(2, .release);

    const cancel: CancellationToken = .{
        .exiting = &workers.exiting,
        .generation = 1,
        .current_generation = &workers.preview_generation,
    };

    const result = renderPreviewRgbaFile(
        allocator,
        io,
        .disabled,
        "testfiles/images/000_0_1024x682.jpg",
        .{ .w = 160, .h = 120 },
        cancel,
    );
    try std.testing.expectError(error.Canceled, result);
}
