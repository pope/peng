const context = @import("context.zig");
const image = @import("../core/image.zig");
const ipc = @import("ipc");
const manager = @import("manager.zig");
const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const thumb_cache = @import("../core/thumb_cache.zig");
const vfs = @import("vfs");

const ArchiveMediaEntry = vfs.ArchiveMediaEntry;
const FilePair = vfs.FilePair;
const ImageCacheKey = image.ImageCacheKey;
const isRawFile = vfs.isRawFile;
const MediaEntry = vfs.MediaEntry;
const MediaId = state_pkg.types.MediaId;
const Orientation = probe.Orientation;
const PairStreamTarget = state_pkg.PairStreamTarget;
const RawMetadata = state_pkg.RawMetadata;
const scanCbzImageEntries = vfs.scanCbzImageEntries;
const ThumbnailSource = state_pkg.ThumbnailSource;
const WorkerManager = manager.WorkerManager;

/// Contextual arguments and configuration passed to background image decoding worker threads.
pub const DecodeArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    key: ImageCacheKey,
    job_id: u8 = 0,
    job_epoch: u32 = 0,
    current_job_epoch: ?*const std.atomic.Value(u32) = null,
    entry: MediaEntry,
    has_gpu_device: bool,
    pixel_format: u32,
    thumb_only: bool = false,
    pair_target: PairStreamTarget = .adaptive,
    current_generation: *const std.atomic.Value(usize),

    /// Builds a cooperative cancellation token for this decode task.
    pub inline fn cancelToken(
        self: *const DecodeArgs,
    ) context.CancellationToken {
        return .{
            .exiting = &self.workers.exiting,
            .generation = self.key.generation,
            .current_generation = self.current_generation,
            .job_epoch = self.job_epoch,
            .current_job_epoch = self.current_job_epoch,
        };
    }
};

/// Spawns a background `decodeWorker` task for image file decoding and EXIF thumbnail extraction,
/// tracking active decode thread and active worker thread counts.
pub fn spawnDecode(args: *DecodeArgs) !void {
    _ = args.workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    args.workers.group.async(args.io, decodeWorker, .{args});
}

fn failDecodeWorker(
    workers: *WorkerManager,
    alloc: std.mem.Allocator,
    io: std.Io,
    key: ImageCacheKey,
    job_epoch: u32,
    comptime fmt: []const u8,
    fmt_args: anytype,
) void {
    std.log.err(fmt, fmt_args);
    workers.event_queue.push(alloc, io, .{
        .decode_failed = .init(key, job_epoch, .{}),
    }) catch |e| std.log.err("Failed to push decode_failed event: {}", .{e});
    context.wakeUpMainThread();
}

const max_cbz_entry_bytes: u64 = 256 * 1024 * 1024;
const header_probe_limit: usize = 256 * 1024;

fn readRangePositional(
    file: std.Io.File,
    io: std.Io,
    cancel: context.CancellationToken,
    dest: []u8,
    start_offset: u64,
) !usize {
    var total_read: usize = 0;
    while (total_read < dest.len) {
        if (cancel.isCanceled()) return error.Canceled;
        var slices = [_][]u8{dest[total_read..]};
        const n = try file.readPositional(
            io,
            &slices,
            start_offset + total_read,
        );
        if (n == 0) break;
        total_read += n;
    }
    return total_read;
}

const DecompressCbzResult = struct {
    bytes: []u8,
    read_time_ms: f64,
    decompress_time_ms: f64,
    compressed_size: u64,
};

fn decompressCbzMediaEntry(
    alloc: std.mem.Allocator,
    io: std.Io,
    entry: ArchiveMediaEntry,
    max_bytes: ?usize,
) !DecompressCbzResult {
    const start_read = sdl.timer.getTicksNs();
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, entry.archive_path, .{});
    defer file.close(io);

    // Sized to 128KB:
    // - In Zig 0.17.0, `std.compress.flate.Decompress` pulls from
    //   `f_reader.interface` bit-by-bit.
    //   A 4KB reader buffer forced ~188 `fileReadPositional` syscalls per 1.1MB compressed page.
    //   128KB drops syscalls to ~10 (19x reduction) and matches typical CPU L2 cache boundaries.
    // - Sized comfortably on the stack (< 192KB combined with `flate_buf`), using < 1.2% of the
    //   worker thread's 16MB default stack (`std.Thread.SpawnConfig.default_stack_size`),
    //   completely avoiding heap allocation, lock contention, and memory fragmentation.
    var reader_buf: [128 * 1024]u8 = undefined;
    var f_reader = file.reader(io, &reader_buf);

    var data_offset: u64 = undefined;
    var uncompressed_size: u64 = undefined;
    var compressed_size: u64 = undefined;
    var comp_method_enum: std.zip.CompressionMethod = undefined;

    switch (entry.seek_info) {
        .indexed => |seek| {
            try f_reader.seekTo(seek.file_offset);
            const local_header = try f_reader.interface.takeStruct(
                std.zip.LocalFileHeader,
                .little,
            );
            if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig))
                return error.ZipBadFileOffset;

            data_offset = seek.file_offset +|
                @sizeOf(std.zip.LocalFileHeader) +|
                local_header.filename_len +| local_header.extra_len;
            uncompressed_size = seek.uncompressed_size;
            compressed_size = local_header.compressed_size;
            comp_method_enum = seek.compression_method;
            try f_reader.seekTo(data_offset);
        },
        .unindexed => {
            var iterator = try std.zip.Iterator.init(&f_reader);
            var stack_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            var fb: std.heap.BufferFirstAllocator = .init(&stack_buf, alloc);
            const temp_alloc = fb.allocator();

            var found = false;
            while (try iterator.next()) |zip_entry| {
                if (zip_entry.filename_len == 0) continue;

                try f_reader.seekTo(
                    zip_entry.header_zip_offset +|
                        @sizeOf(std.zip.CentralDirectoryFileHeader),
                );
                const name = try temp_alloc.alloc(u8, zip_entry.filename_len);
                defer temp_alloc.free(name);
                try f_reader.interface.readSliceAll(name);

                if (!std.mem.eql(u8, name, entry.entry_name)) continue;

                try f_reader.seekTo(zip_entry.file_offset);
                const local_header = try f_reader.interface.takeStruct(
                    std.zip.LocalFileHeader,
                    .little,
                );
                if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig))
                    return error.ZipBadFileOffset;

                data_offset = zip_entry.file_offset +|
                    @sizeOf(std.zip.LocalFileHeader) +|
                    local_header.filename_len +| local_header.extra_len;
                uncompressed_size = zip_entry.uncompressed_size;
                compressed_size = zip_entry.compressed_size;
                comp_method_enum = zip_entry.compression_method;
                try f_reader.seekTo(data_offset);
                found = true;
                break;
            }
            if (!found) return error.FileNotFound;
        },
    }

    if (uncompressed_size > max_cbz_entry_bytes) return error.FileTooBig;
    const target_len_u64 = if (max_bytes) |mb|
        @min(uncompressed_size, mb)
    else
        uncompressed_size;
    const target_len = std.math.cast(usize, target_len_u64) orelse
        return error.FileTooBig;

    const end_read = sdl.timer.getTicksNs();
    const read_time_ms = @as(f64, @floatFromInt(end_read - start_read)) / 1_000_000.0;

    const out_buf = try alloc.alloc(u8, target_len);
    errdefer alloc.free(out_buf);

    const start_dec = sdl.timer.getTicksNs();
    switch (comp_method_enum) {
        .store => {
            try f_reader.interface.readSliceAll(out_buf);
        },
        .deflate => {
            // Sized to 64KB (`flate.max_window_len = history_len * 2` where `history_len = 32768`):
            // Implements RFC 1951 Deflate's double-buffered LZ77 sliding history window.
            // Benchmarking confirmed that exceeding 64KB yields no additional syscall gains.
            var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(
                &f_reader.interface,
                .raw,
                &flate_buf,
            );
            try decompress.reader.readSliceAll(out_buf);
        },
        else => return error.UnsupportedCompressionMethod,
    }

    const end_dec = sdl.timer.getTicksNs();
    const decompress_time_ms = @as(f64, @floatFromInt(end_dec - start_dec)) / 1_000_000.0;
    return .{
        .bytes = out_buf,
        .read_time_ms = read_time_ms,
        .decompress_time_ms = decompress_time_ms,
        .compressed_size = compressed_size,
    };
}

const ConvertResult = struct {
    surface: ?sdl.Surface,
    conversion_time_ms: f64 = 0.0,
};

fn convertAndScaleSurface(
    surface: ?sdl.Surface,
    pix_fmt: u32,
    has_gpu_device: bool,
) ConvertResult {
    var final_surface = surface;
    var conversion_time_ms: f64 = 0.0;
    if (surface) |surf| {
        if (!has_gpu_device and pix_fmt != sdl.PixelFormat.unknown and surf.format() != pix_fmt) {
            const start_convert = sdl.timer.getTicksNs();
            if (surf.convert(pix_fmt)) |conv| {
                const end_convert = sdl.timer.getTicksNs();
                conversion_time_ms =
                    @as(f64, @floatFromInt(end_convert - start_convert)) / 1_000_000.0;
                surf.destroy();
                final_surface = conv;
            } else {
                std.log.err("SDL_ConvertSurface failed: {s}", .{sdl.getError()});
            }
        } else if (has_gpu_device) {
            // For GPU rendering:
            // - 24-bit RGB/BGR surfaces are left as-is so the GPU compute unpack shader
            //   (`unpack_rgb.comp.glsl`) can unpack them directly into RGBA32 in VRAM.
            // - Exotic formats (e.g. paletted 8-bit, grayscale) are converted here on the
            //   background worker thread to prevent main-thread format conversion stalls.
            const cur_fmt = surf.format();
            const is_32bit = switch (cur_fmt) {
                sdl.PixelFormat.rgba32,
                sdl.PixelFormat.bgra32,
                sdl.PixelFormat.xrgb8888,
                sdl.PixelFormat.xbgr8888,
                sdl.PixelFormat.rgbx8888,
                sdl.PixelFormat.bgrx8888,
                => true,
                else => false,
            };
            if (!is_32bit and
                cur_fmt != sdl.PixelFormat.rgb24 and
                cur_fmt != sdl.PixelFormat.bgr24)
            {
                const start_convert = sdl.timer.getTicksNs();
                if (surf.convert(sdl.PixelFormat.rgba32)) |conv| {
                    const end_convert = sdl.timer.getTicksNs();
                    conversion_time_ms =
                        @as(f64, @floatFromInt(end_convert - start_convert)) / 1_000_000.0;
                    surf.destroy();
                    final_surface = conv;
                } else {
                    std.log.err("SDL_ConvertSurface failed: {s}", .{sdl.getError()});
                }
            }
        }

        if (final_surface) |f_surf| {
            const max_dim: i32 = 8192;
            if (f_surf.w() > max_dim or f_surf.h() > max_dim) {
                var new_w = f_surf.w();
                var new_h = f_surf.h();
                if (f_surf.w() > f_surf.h()) {
                    new_w = max_dim;
                    new_h = @divTrunc(f_surf.h() * max_dim, f_surf.w());
                } else {
                    new_h = max_dim;
                    new_w = @divTrunc(f_surf.w() * max_dim, f_surf.h());
                }
                new_w = @max(1, new_w);
                new_h = @max(1, new_h);

                const scaled = f_surf.scale(new_w, new_h, .linear);
                if (scaled) |sc| {
                    f_surf.destroy();
                    final_surface = sc;
                } else {
                    std.log.err("decodeWorker: SDL_ScaleSurface failed: {s}", .{sdl.getError()});
                }
            }
        }
    }
    return .{
        .surface = final_surface,
        .conversion_time_ms = conversion_time_ms,
    };
}

const CacheProbeOutcome = enum {
    not_probed,
    excluded_path,
    target_tier_missing,
    target_tier_valid,
};

const LoadedThumbnail = struct {
    surface: sdl.Surface,
    source: ThumbnailSource,
    probe_outcome: CacheProbeOutcome = .not_probed,
    source_dims: ?state_pkg.PhysicalDims = null,
};

const ThumbLoadResult = union(enum) {
    hit: LoadedThumbnail,
    miss: CacheProbeOutcome,
};

fn probeFreedesktopThumbCache(
    workers: *WorkerManager,
    alloc: std.mem.Allocator,
    io: std.Io,
    cancel: context.CancellationToken,
    path: []const u8,
    source_mtime_sec: ?i64,
    had_embedded_candidate: bool,
) error{Canceled}!ThumbLoadResult {
    const mtime_sec = source_mtime_sec orelse {
        if (had_embedded_candidate) {
            _ = workers.thumb_misses.fetchAdd(1, .monotonic);
        }
        return .{ .miss = .not_probed };
    };
    switch (workers.thumb_cache_config) {
        .disabled => {
            if (had_embedded_candidate) {
                _ = workers.thumb_misses.fetchAdd(1, .monotonic);
            }
            return .{ .miss = .not_probed };
        },
        .enabled => |cfg| {
            const c_key = thumb_cache.ThumbCacheKey.fromFilePath(
                io,
                path,
                cfg.cache_dir,
            ) orelse {
                if (had_embedded_candidate) {
                    _ = workers.thumb_misses.fetchAdd(1, .monotonic);
                }
                return .{ .miss = .excluded_path };
            };
            if (thumb_cache.loadCachedThumbnail(
                alloc,
                io,
                cfg,
                &c_key,
                mtime_sec,
            )) |cached| {
                if (cancel.isCanceled()) {
                    cached.surface.destroy();
                    return error.Canceled;
                }
                _ = workers.thumb_cache_hits.fetchAdd(1, .monotonic);
                const outcome: CacheProbeOutcome =
                    if (cached.tier == cfg.write_tier)
                        .target_tier_valid
                    else
                        .not_probed;
                return .{
                    .hit = .{
                        .surface = cached.surface,
                        .source = .freedesktop_cache,
                        .probe_outcome = outcome,
                        .source_dims = cached.source_dims,
                    },
                };
            } else {
                _ = workers.thumb_misses.fetchAdd(1, .monotonic);
                return .{ .miss = .target_tier_missing };
            }
        },
    }
}

fn resolveThumbWriteMtime(
    io: std.Io,
    cfg_state: thumb_cache.ThumbCacheConfig,
    path: []const u8,
    source_mtime_sec: ?i64,
    had_embedded_thumb: bool,
    probe_outcome: CacheProbeOutcome,
) ?i64 {
    const mtime_sec = source_mtime_sec orelse return null;
    return switch (cfg_state) {
        .disabled => null,
        .enabled => |cfg| blk: {
            const had_target_valid = (probe_outcome == .target_tier_valid);
            if (!cfg.write_policy.shouldWrite(
                had_embedded_thumb,
                had_target_valid,
            )) {
                break :blk null;
            }
            switch (probe_outcome) {
                .target_tier_valid, .excluded_path => break :blk null,
                .target_tier_missing => break :blk mtime_sec,
                .not_probed => {
                    const c_key = thumb_cache.ThumbCacheKey.fromFilePath(
                        io,
                        path,
                        cfg.cache_dir,
                    ) orelse break :blk null;
                    break :blk if (!thumb_cache.hasValidTargetTierThumbnail(
                        io,
                        cfg,
                        &c_key,
                        mtime_sec,
                    ))
                        mtime_sec
                    else
                        null;
                },
            }
        },
    };
}

fn decodeRawFile(args: *DecodeArgs, path: []const u8, is_pair: bool) bool {
    const workers = args.workers;
    const alloc = args.allocator;
    const io = args.io;
    const key = args.key;
    const cancel = args.cancelToken();

    if (cancel.isCanceled()) return true;

    const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) return true;
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: statFile failed for '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    const file_size: u64 = s.size;
    const source_mtime_sec = s.mtime.toSeconds();

    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) return true;
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: openFile failed for '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    defer file.close(io);

    // Read initial 256KB header via readPositional without allocating full file
    const header_target: usize = @intCast(@min(file_size, header_probe_limit));
    var header_buf: [header_probe_limit]u8 = undefined;
    const start_hdr_read = sdl.timer.getTicksNs();
    const header_n = readRangePositional(
        file,
        io,
        cancel,
        header_buf[0..header_target],
        0,
    ) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) return true;
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: readPositional failed for '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    const end_hdr_read = sdl.timer.getTicksNs();
    const header_read_time_ms =
        @as(f64, @floatFromInt(end_hdr_read - start_hdr_read)) / 1_000_000.0;
    const header_slice = header_buf[0..header_n];

    const mime_type = probe.detectMimeType(header_slice, path);
    const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or
        (header_slice.len >= 8 and std.mem.startsWith(u8, header_slice, "FUJIFILM"));

    var prev_loc_opt: ?probe.ThumbnailLocation = null;
    var med_loc_opt: ?probe.ThumbnailLocation = null;
    var thumb_loc_opt: ?probe.ThumbnailLocation = null;
    var raw_sensor_dims: ?probe.JpegDimensions = null;
    var orientation: probe.Orientation = .normal;

    if (is_fuji) {
        prev_loc_opt = probe.extractFujiRafPreviewLocation(header_slice);
        if (probe.extractFujiRafMetadataLocation(header_slice)) |meta_loc| {
            if (meta_loc.file_offset +| meta_loc.length <= header_n) {
                const end = meta_loc.file_offset + meta_loc.length;
                raw_sensor_dims = probe.parseFujiRafDimensions(
                    header_slice[@intCast(meta_loc.file_offset)..@intCast(end)],
                );
            } else if (meta_loc.length > 0 and meta_loc.length <= 64 * 1024 and
                meta_loc.file_offset +| meta_loc.length <= file_size)
            {
                var m_buf: [64 * 1024]u8 = undefined;
                const mn = readRangePositional(
                    file,
                    io,
                    cancel,
                    m_buf[0..meta_loc.length],
                    meta_loc.file_offset,
                ) catch |err| blk: {
                    if (err == error.Canceled or cancel.isCanceled()) {
                        return true;
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
                orientation =
                    probe.parseExifOrientation(
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
                const pn = readRangePositional(
                    file,
                    io,
                    cancel,
                    &p_hdr,
                    prev_loc.file_offset,
                ) catch |err| blk: {
                    if (err == error.Canceled or cancel.isCanceled()) {
                        return true;
                    }
                    break :blk 0;
                };
                if (pn > 0) {
                    orientation =
                        probe.parseExifOrientation(p_hdr[0..pn]) orelse .normal;
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
        var tail_slice: ?[]const u8 = null;
        var tiff_tail_off: u32 = 0;
        if (probe.probeTiffIfd0Offset(header_slice)) |ifd0_off| {
            if (ifd0_off >= header_n and ifd0_off < file_size) {
                const tail_target: usize =
                    @intCast(@min(file_size -| ifd0_off, tail_buf.len));
                if (tail_target > 0) {
                    const tn = readRangePositional(
                        file,
                        io,
                        cancel,
                        tail_buf[0..tail_target],
                        ifd0_off,
                    ) catch |err| blk: {
                        if (err == error.Canceled or cancel.isCanceled()) {
                            return true;
                        }
                        break :blk 0;
                    };
                    if (tn > 0) {
                        tail_slice = tail_buf[0..tn];
                        tiff_tail_off = ifd0_off;
                    }
                }
            }
        }
        const tiff_source = if (tail_slice) |ts|
            probe.TiffSource.initWithTail(header_slice, tiff_tail_off, ts)
        else
            probe.TiffSource.init(header_slice);

        const raw_cands = probe.extractTiffRawPreviewsFromSource(tiff_source);
        prev_loc_opt = raw_cands.preview;
        med_loc_opt = raw_cands.medium;
        thumb_loc_opt = raw_cands.thumbnail;
        raw_sensor_dims = probe.parseExifDimensionsFromSource(tiff_source);
        if (raw_sensor_dims == null) {
            if (probe.parseImageDimensions(header_slice, mime_type)) |d| {
                raw_sensor_dims = .{
                    .w = d.w,
                    .h = d.h,
                };
            }
        }
        orientation = probe.parseExifOrientationFromSource(tiff_source) orelse
            .normal;
    }

    if (cancel.isCanceled()) return true;

    if (orientation != .normal) {
        workers.event_queue.push(alloc, io, .{
            .exif_orientation_parsed = .init(
                key,
                args.job_epoch,
                .{ .orientation = orientation },
            ),
        }) catch |err| {
            std.log.err(
                "Failed to push EXIF orientation event: {}",
                .{err},
            );
        };
        context.wakeUpMainThread();
    }

    const raw_w: f32 = if (raw_sensor_dims) |d| d.w else 0.0;
    const raw_h: f32 = if (raw_sensor_dims) |d| d.h else 0.0;
    var had_embedded_thumb = (thumb_loc_opt != null) or (med_loc_opt != null);
    var probe_outcome: CacheProbeOutcome = .not_probed;

    // Fast scrubbing & instant placeholder thumbnail path
    if ((args.has_gpu_device and args.pair_target == .adaptive) or
        args.thumb_only)
    {
        var thumb_surf: ?sdl.Surface = null;
        var thumb_source: ThumbnailSource = .embedded_header;
        var cached_dims: ?state_pkg.PhysicalDims = null;
        const target_loc_opt = if (args.thumb_only)
            (thumb_loc_opt orelse med_loc_opt)
        else
            (med_loc_opt orelse thumb_loc_opt);
        const max_placeholder_bytes: u32 = if (args.thumb_only)
            512 * 1024
        else
            2 * 1024 * 1024;

        if (target_loc_opt) |tloc| {
            if (tloc.length > 0 and tloc.length <= max_placeholder_bytes and
                tloc.file_offset +| tloc.length <= file_size)
            {
                const t_len: usize = @intCast(tloc.length);
                if (tloc.file_offset +| tloc.length <= header_n) {
                    const t_off: usize = @intCast(tloc.file_offset);
                    thumb_surf = sdl.Surface.loadConstMemOpt(
                        header_slice[t_off .. t_off + t_len],
                    );
                    if (thumb_surf != null) {
                        _ = workers.thumb_header_hits.fetchAdd(1, .monotonic);
                        thumb_source = .embedded_header;
                        had_embedded_thumb = true;
                    }
                } else {
                    const t_buf = alloc.alloc(u8, t_len) catch null;
                    if (t_buf) |tb| {
                        defer alloc.free(tb);
                        const tn = readRangePositional(
                            file,
                            io,
                            cancel,
                            tb,
                            tloc.file_offset,
                        ) catch |err| blk: {
                            if (err == error.Canceled or cancel.isCanceled()) {
                                return true;
                            }
                            break :blk 0;
                        };
                        if (tn == t_len) {
                            thumb_surf = sdl.Surface.loadConstMemOpt(tb);
                            if (thumb_surf != null) {
                                _ = workers.thumb_positional_hits.fetchAdd(
                                    1,
                                    .monotonic,
                                );
                                thumb_source = .embedded_positional;
                                had_embedded_thumb = true;
                            }
                        }
                    }
                }
            }
        }

        if (thumb_surf == null) {
            had_embedded_thumb = false;
            const cache_res = probeFreedesktopThumbCache(
                workers,
                alloc,
                io,
                cancel,
                path,
                source_mtime_sec,
                target_loc_opt != null,
            ) catch return true;
            switch (cache_res) {
                .hit => |hit| {
                    thumb_surf = hit.surface;
                    thumb_source = hit.source;
                    cached_dims = hit.source_dims;
                    probe_outcome = hit.probe_outcome;
                },
                .miss => |outcome| {
                    probe_outcome = outcome;
                },
            }
        }

        if (thumb_surf) |t_surf| {
            if (cancel.isCanceled()) {
                t_surf.destroy();
                return true;
            }
            const source_dims =
                state_pkg.PhysicalDims.initPositive(raw_w, raw_h) orelse
                cached_dims;
            const dct_snapped = if (thumb_source == .freedesktop_cache)
                false
            else if (source_dims) |sd|
                image.detectThumbnailDctPadding(t_surf, sd.w, sd.h)
            else
                false;
            workers.event_queue.push(alloc, io, .{
                .thumb_decoded = .init(key, args.job_epoch, .{
                    .surface = t_surf,
                    .w = @floatFromInt(t_surf.w()),
                    .h = @floatFromInt(t_surf.h()),
                    .source_dims = source_dims,
                    .orientation = orientation,
                    .thumb_only = args.thumb_only,
                    .raw_metadata = if (source_dims) |sd|
                        RawMetadata.init(sd.w, sd.h)
                    else
                        .none,
                    .dct_snapped = dct_snapped,
                    .source = thumb_source,
                }),
            }) catch |err| {
                std.log.err(
                    "Failed to push thumbnail decode event: {}",
                    .{err},
                );
                t_surf.destroy();
            };
            context.wakeUpMainThread();

            if (args.thumb_only) {
                return true;
            }
        } else if (args.thumb_only) {
            if (is_pair) return false;
            // If no small thumbnail available, emit dimensions_probed
            // to immediately establish canvas aspect ratio on Frame 1
            // without decoding pixels
            if (cancel.isCanceled()) return true;
            workers.event_queue.push(alloc, io, .{
                .dimensions_probed = .init(key, args.job_epoch, .{
                    .source_dims = state_pkg.PhysicalDims.initPositive(
                        raw_w,
                        raw_h,
                    ),
                    .orientation = orientation,
                    .thumb_only = true,
                    .raw_metadata = RawMetadata.init(raw_w, raw_h),
                }),
            }) catch |err| {
                std.log.err(
                    "Failed to push dimensions probed event: {}",
                    .{err},
                );
            };
            context.wakeUpMainThread();
            return true;
        }
    }

    if (cancel.isCanceled()) return true;

    const prev_loc = prev_loc_opt orelse {
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: no embedded preview found in RAW file '{s}'",
            .{path},
        );
        return true;
    };

    if (prev_loc.length == 0 or
        prev_loc.file_offset +| prev_loc.length > file_size)
    {
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: invalid preview location in RAW file '{s}'",
            .{path},
        );
        return true;
    }

    var prev_bytes: []const u8 = undefined;
    var prev_allocated_buf: ?[]u8 = null;
    defer if (prev_allocated_buf) |b| alloc.free(b);

    var read_time_ms = header_read_time_ms;

    if (prev_loc.file_offset +| prev_loc.length <= header_n) {
        const off: usize = @intCast(prev_loc.file_offset);
        const len: usize = @intCast(prev_loc.length);
        prev_bytes = header_slice[off .. off + len];
    } else {
        const p_buf = alloc.alloc(u8, prev_loc.length) catch |err| {
            if (is_pair) return false;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: alloc failed for preview in '{s}': {}",
                .{ path, err },
            );
            return true;
        };
        prev_allocated_buf = p_buf;

        const start_p_read = sdl.timer.getTicksNs();
        const total_read = readRangePositional(
            file,
            io,
            cancel,
            p_buf,
            prev_loc.file_offset,
        ) catch |err| {
            if (err == error.Canceled or cancel.isCanceled()) return true;
            if (is_pair) return false;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: readPositional failed " ++
                    "for preview in '{s}': {}",
                .{ path, err },
            );
            return true;
        };
        const end_p_read = sdl.timer.getTicksNs();
        if (total_read < p_buf.len) {
            if (is_pair) return false;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: incomplete preview read for '{s}'",
                .{path},
            );
            return true;
        }
        read_time_ms = header_read_time_ms +
            (@as(f64, @floatFromInt(end_p_read - start_p_read)) / 1_000_000.0);
        prev_bytes = p_buf;
    }

    if (is_fuji and orientation == .normal) {
        if (probe.parseExifOrientation(prev_bytes)) |o| {
            orientation = o;
            if (orientation != .normal) {
                if (cancel.isCanceled()) return true;
                workers.event_queue.push(alloc, io, .{
                    .exif_orientation_parsed = .init(
                        key,
                        args.job_epoch,
                        .{ .orientation = orientation },
                    ),
                }) catch |err| {
                    std.log.err(
                        "Failed to push EXIF orientation event: {}",
                        .{err},
                    );
                };
                context.wakeUpMainThread();
            }
        }
    }

    const start_dec = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadConstMemOpt(prev_bytes);
    const end_dec = sdl.timer.getTicksNs();
    const decode_time_ms = @as(f64, @floatFromInt(end_dec - start_dec)) / 1_000_000.0;

    if (surface == null) {
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: failed to load RAW preview surface '{s}': {s}",
            .{ path, sdl.getError() },
        );
        return true;
    }

    if (cancel.isCanceled()) {
        surface.?.destroy();
        return true;
    }

    const unscaled_w: f32 = @floatFromInt(surface.?.w());
    const unscaled_h: f32 = @floatFromInt(surface.?.h());
    const conv_res = convertAndScaleSurface(
        surface,
        args.pixel_format,
        args.has_gpu_device,
    );
    const final_surface = conv_res.surface;
    const conversion_time_ms = conv_res.conversion_time_ms;

    if (cancel.isCanceled()) {
        if (final_surface) |surf| surf.destroy();
        return true;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());
        const final_raw_w: f32 = if (raw_w > 0.0) raw_w else unscaled_w;
        const final_raw_h: f32 = if (raw_h > 0.0) raw_h else unscaled_h;
        const thumb_write_mtime_sec = resolveThumbWriteMtime(
            io,
            workers.thumb_cache_config,
            path,
            source_mtime_sec,
            had_embedded_thumb,
            probe_outcome,
        );

        workers.event_queue.push(alloc, io, .{
            .image_decoded = .init(key, args.job_epoch, .{
                .surface = f_surf,
                .w = orig_w,
                .h = orig_h,
                .source_dims = state_pkg.PhysicalDims.initPositive(
                    final_raw_w,
                    final_raw_h,
                ),
                .mime_type = mime_type,
                .size_bytes = file_size,
                .orientation = orientation,
                .raw_metadata = RawMetadata.init(final_raw_w, final_raw_h),
                .decode = .{
                    .read_time_ms = read_time_ms,
                    .decode_time_ms = decode_time_ms,
                    .conversion_time_ms = conversion_time_ms,
                    .archive = .none,
                },
                .thumb_write_mtime_sec = thumb_write_mtime_sec,
            }),
        }) catch |err| {
            std.log.err("Failed to push image decode event: {}", .{err});
            f_surf.destroy();
        };
        context.wakeUpMainThread();
        return true;
    } else {
        if (is_pair) return false;
        workers.event_queue.push(alloc, io, .{
            .decode_failed = .init(key, args.job_epoch, .{}),
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
        context.wakeUpMainThread();
        return true;
    }
}

/// Encapsulates the two-stage payload lifecycle for `decodeWorker`:
/// - Stage 1 (`openStagedFile`): reads only up to `header_probe_limit` (256 KB) so EXIF orientation,
///   dimensions, and embedded JPEG thumbnails can be extracted and pushed to the main thread first.
/// - Stage 2 (`readRemaining`): reads any remaining file bytes and closes the `std.Io.File` handle
///   before CPU surface decompression begins.
const DecodePayload = struct {
    const Stage = union(enum) {
        staged_file: std.Io.File,
        complete,
    };

    path: []const u8,
    log_prefix: []const u8 = "",
    bytes: []u8,
    read_n: usize,
    size_bytes: u64,
    mtime_sec: ?i64 = null,
    read_time_ms: f64,
    archive: state_pkg.ArchiveTelemetry = .none,
    stage: Stage,

    fn fromArchiveEntry(
        args: *DecodeArgs,
        arch: ArchiveMediaEntry,
    ) ?DecodePayload {
        const max_bytes: ?usize = if (args.thumb_only) header_probe_limit else null;
        const dec_res = decompressCbzMediaEntry(
            args.allocator,
            args.io,
            arch,
            max_bytes,
        ) catch |err| {
            if (err == error.Canceled or args.cancelToken().isCanceled()) return null;
            failDecodeWorker(
                args.workers,
                args.allocator,
                args.io,
                args.key,
                args.job_epoch,
                "decodeWorker: failed to decompress CBZ entry '{s}' from '{s}': {}",
                .{ arch.entry_name, arch.archive_path, err },
            );
            return null;
        };

        return .{
            .path = arch.entry_name,
            .bytes = dec_res.bytes,
            .read_n = dec_res.bytes.len,
            .size_bytes = dec_res.bytes.len,
            .read_time_ms = dec_res.read_time_ms,
            .archive = state_pkg.ArchiveTelemetry.init(
                dec_res.decompress_time_ms,
                std.math.cast(
                    usize,
                    dec_res.compressed_size,
                ) orelse std.math.maxInt(usize),
            ),
            .stage = .complete,
        };
    }

    fn openStagedFile(
        args: *DecodeArgs,
        file_path: []const u8,
        log_prefix: []const u8,
    ) ?DecodePayload {
        const workers = args.workers;
        const alloc = args.allocator;
        const io = args.io;
        const key = args.key;
        const cancel = args.cancelToken();

        const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, file_path, .{}) catch |err| {
            if (err == error.Canceled or cancel.isCanceled()) return null;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: statFile failed for {s}'{s}': {}",
                .{ log_prefix, file_path, err },
            );
            return null;
        };

        const file_size = std.math.cast(usize, s.size) orelse {
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: file too large for {s}'{s}': {}",
                .{ log_prefix, file_path, s.size },
            );
            return null;
        };

        const start_read = sdl.timer.getTicksNs();
        const file = std.Io.Dir.openFile(
            std.Io.Dir.cwd(),
            io,
            file_path,
            .{},
        ) catch |err| {
            if (err == error.Canceled or cancel.isCanceled()) return null;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: openFile failed for {s}'{s}': {}",
                .{ log_prefix, file_path, err },
            );
            return null;
        };

        const stage1_target = @min(file_size, header_probe_limit);
        const target_read_size: usize = if (args.thumb_only)
            stage1_target
        else
            file_size;

        const bytes = alloc.alloc(u8, target_read_size) catch |err| {
            file.close(io);
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: alloc failed for {s}'{s}': {}",
                .{ log_prefix, file_path, err },
            );
            return null;
        };

        const read_n = readRangePositional(
            file,
            io,
            cancel,
            bytes[0..stage1_target],
            0,
        ) catch |err| {
            alloc.free(bytes);
            file.close(io);
            if (err == error.Canceled or cancel.isCanceled()) return null;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: readPositional failed for {s}'{s}': {}",
                .{ log_prefix, file_path, err },
            );
            return null;
        };

        const end_read = sdl.timer.getTicksNs();
        const read_time_ms = @as(f64, @floatFromInt(end_read - start_read)) / 1_000_000.0;

        const has_more_on_disk = (read_n == stage1_target) and (read_n < file_size);
        const stage: Stage = if (has_more_on_disk)
            .{ .staged_file = file }
        else blk: {
            file.close(io);
            break :blk .complete;
        };

        return .{
            .path = file_path,
            .log_prefix = log_prefix,
            .bytes = bytes,
            .read_n = read_n,
            .size_bytes = s.size,
            .mtime_sec = s.mtime.toSeconds(),
            .read_time_ms = read_time_ms,
            .stage = stage,
        };
    }

    fn deinit(self: *DecodePayload, alloc: std.mem.Allocator, io: std.Io) void {
        switch (self.stage) {
            .staged_file => |file| {
                file.close(io);
                self.stage = .complete;
            },
            .complete => {},
        }
        alloc.free(self.bytes);
    }

    fn headerSlice(self: *const DecodePayload) []const u8 {
        return self.bytes[0..@min(self.read_n, header_probe_limit)];
    }

    fn readRemaining(self: *DecodePayload, args: *DecodeArgs) ?[]const u8 {
        switch (self.stage) {
            .complete => return self.bytes[0..self.read_n],
            .staged_file => |file| {
                defer {
                    file.close(args.io);
                    self.stage = .complete;
                }
                if (self.read_n < self.bytes.len) {
                    const cancel = args.cancelToken();
                    const start_read = sdl.timer.getTicksNs();
                    const rem_n = readRangePositional(
                        file,
                        args.io,
                        cancel,
                        self.bytes[self.read_n..],
                        self.read_n,
                    ) catch |err| {
                        if (err == error.Canceled or cancel.isCanceled()) return null;
                        failDecodeWorker(
                            args.workers,
                            args.allocator,
                            args.io,
                            args.key,
                            args.job_epoch,
                            "decodeWorker: readPositional failed for {s}'{s}': {}",
                            .{ self.log_prefix, self.path, err },
                        );
                        return null;
                    };
                    const end_read = sdl.timer.getTicksNs();
                    self.read_time_ms += @as(f64, @floatFromInt(end_read - start_read)) / 1_000_000.0;
                    self.read_n += rem_n;
                }
                return self.bytes[0..self.read_n];
            },
        }
    }

    fn loadThumbnailSurface(
        self: *const DecodePayload,
        args: *DecodeArgs,
        valid_jpeg_thumb_loc: ?probe.ThumbnailLocation,
    ) error{Canceled}!ThumbLoadResult {
        const cancel = args.cancelToken();

        if (valid_jpeg_thumb_loc) |loc| {
            const len: usize = @intCast(loc.length);
            if (loc.file_offset +| loc.length <= self.read_n) {
                if (cancel.isCanceled()) return error.Canceled;
                const off: usize = @intCast(loc.file_offset);
                const slice = self.bytes[off .. off + len];
                if (sdl.Surface.loadConstMemOpt(slice)) |surf| {
                    _ = args.workers.thumb_header_hits.fetchAdd(
                        1,
                        .monotonic,
                    );
                    return .{
                        .hit = .{
                            .surface = surf,
                            .source = .embedded_header,
                        },
                    };
                }
            } else if (self.stage == .staged_file) {
                const file = self.stage.staged_file;
                if (args.allocator.alloc(u8, len)) |tb| {
                    defer args.allocator.free(tb);
                    const tn = readRangePositional(
                        file,
                        args.io,
                        cancel,
                        tb,
                        loc.file_offset,
                    ) catch |err| blk: {
                        const canceled = (err == error.Canceled) or
                            cancel.isCanceled();
                        if (canceled) {
                            return error.Canceled;
                        }
                        break :blk 0;
                    };
                    if (tn == len) {
                        if (cancel.isCanceled()) return error.Canceled;
                        if (sdl.Surface.loadConstMemOpt(tb)) |surf| {
                            _ = args.workers.thumb_positional_hits
                                .fetchAdd(1, .monotonic);
                            return .{
                                .hit = .{
                                    .surface = surf,
                                    .source = .embedded_positional,
                                },
                            };
                        }
                    }
                } else |_| {}
            }
        }

        return probeFreedesktopThumbCache(
            args.workers,
            args.allocator,
            args.io,
            cancel,
            self.path,
            self.mtime_sec,
            valid_jpeg_thumb_loc != null,
        );
    }
};

/// Background worker task that reads image files from disk or CBZ archives, parses metadata,
/// extracts EXIF thumbnails, and decompresses image surfaces into CPU memory.
pub fn decodeWorker(args: *DecodeArgs) void {
    const workers = args.workers;
    const alloc = args.allocator;
    const io = args.io;
    const key = args.key;
    const media_entry = args.entry;
    const cancel = args.cancelToken();
    defer {
        media_entry.deinit(alloc);
        alloc.destroy(args);
        _ = workers.active_decode_threads.fetchSub(1, .release);
        _ = workers.active_threads.fetchSub(1, .release);
        if (cancel.isCanceled()) {
            sdl.reclaimProcessHeap();
        }
        context.wakeUpMainThread();
    }

    if (cancel.isCanceled()) return;

    var payload: DecodePayload = switch (media_entry) {
        .archive_entry => |arch| DecodePayload.fromArchiveEntry(args, arch) orelse return,
        .filesystem => |file_item| blk: {
            if (isRawFile(file_item.path)) {
                _ = decodeRawFile(args, file_item.path, false);
                return;
            }
            break :blk DecodePayload.openStagedFile(args, file_item.path, "") orelse return;
        },
        .pair => |pair| blk: {
            if (args.thumb_only or args.pair_target != .standalone_jpeg) {
                if (decodeRawFile(args, pair.raw_path, true)) {
                    return;
                }
            }
            break :blk DecodePayload.openStagedFile(
                args,
                pair.jpeg_path,
                "companion JPEG ",
            ) orelse return;
        },
    };
    defer payload.deinit(alloc, io);

    const header_buf = payload.headerSlice();
    const path = payload.path;
    const mime_type = probe.detectMimeType(header_buf, path);
    const is_raw_archive = isRawFile(path) or
        std.mem.startsWith(u8, mime_type, "image/x-");

    var raw_preview_slice: ?[]const u8 = null;
    var raw_sensor_dims: ?probe.JpegDimensions = null;
    var orientation: probe.Orientation = .normal;

    if (is_raw_archive) {
        const raw_bytes = payload.readRemaining(args) orelse return;
        const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or
            (header_buf.len >= 8 and
                std.mem.startsWith(u8, header_buf, "FUJIFILM"));
        if (is_fuji) {
            if (probe.extractFujiRafPreviewLocation(header_buf)) |ploc| {
                if (ploc.length > 0 and ploc.length <= raw_bytes.len and
                    ploc.file_offset <= raw_bytes.len - ploc.length)
                {
                    const off: usize = @intCast(ploc.file_offset);
                    const len: usize = @intCast(ploc.length);
                    const preview_slice = raw_bytes[off .. off + len];
                    raw_preview_slice = preview_slice;
                    orientation =
                        probe.parseExifOrientation(preview_slice) orelse
                        .normal;
                }
            }
            if (probe.extractFujiRafMetadataLocation(header_buf)) |mloc| {
                if (mloc.length > 0 and mloc.length <= raw_bytes.len and
                    mloc.file_offset <= raw_bytes.len - mloc.length)
                {
                    const off: usize = @intCast(mloc.file_offset);
                    const len: usize = @intCast(mloc.length);
                    raw_sensor_dims = probe.parseFujiRafDimensions(
                        raw_bytes[off .. off + len],
                    );
                }
            }
        } else {
            const raw_cands = probe.extractTiffRawPreviews(raw_bytes);
            const target_prev = if (args.thumb_only)
                (raw_cands.thumbnail orelse
                    raw_cands.medium orelse
                    raw_cands.preview)
            else
                raw_cands.preview;
            if (target_prev) |ploc| {
                if (ploc.length > 0 and ploc.length <= raw_bytes.len and
                    ploc.file_offset <= raw_bytes.len - ploc.length)
                {
                    const off: usize = @intCast(ploc.file_offset);
                    const len: usize = @intCast(ploc.length);
                    raw_preview_slice = raw_bytes[off .. off + len];
                }
            }
            raw_sensor_dims = probe.parseExifDimensions(raw_bytes);
            orientation = probe.parseExifOrientation(raw_bytes) orelse .normal;
        }
    } else {
        orientation = probe.parseExifOrientation(header_buf) orelse .normal;
    }

    if (orientation != .normal) {
        if (cancel.isCanceled()) return;
        workers.event_queue.push(alloc, io, .{
            .exif_orientation_parsed = .init(
                key,
                args.job_epoch,
                .{ .orientation = orientation },
            ),
        }) catch |err| {
            std.log.err("Failed to push EXIF orientation event: {}", .{err});
        };
        context.wakeUpMainThread();
    }

    const full_dims = probe.parseImageDimensions(header_buf, mime_type);
    const valid_jpeg_thumb_loc: ?probe.ThumbnailLocation = blk: {
        if (!std.mem.eql(u8, mime_type, "image/jpeg")) break :blk null;
        const loc = probe.extractJpegThumbnailLocation(header_buf) orelse
            break :blk null;
        const max_thumb_size_bytes = 512 * 1024;
        if (loc.length == 0 or
            loc.length > max_thumb_size_bytes or
            loc.file_offset +| loc.length > payload.size_bytes)
        {
            break :blk null;
        }
        break :blk loc;
    };
    var had_embedded_thumb = (valid_jpeg_thumb_loc != null);
    var probe_outcome: CacheProbeOutcome = .not_probed;

    // Attempt fast EXIF or Freedesktop cache thumbnail decoding for instant
    // placeholder preview
    const can_try_thumb = (valid_jpeg_thumb_loc != null) or
        (workers.thumb_cache_config != .disabled and payload.mtime_sec != null);
    if (can_try_thumb and
        (args.has_gpu_device or args.thumb_only) and
        args.pair_target == .adaptive)
    {
        const thumb_res = payload.loadThumbnailSurface(
            args,
            valid_jpeg_thumb_loc,
        ) catch return;
        switch (thumb_res) {
            .hit => |loaded_thumb| {
                const t_surf = loaded_thumb.surface;
                had_embedded_thumb =
                    (loaded_thumb.source != .freedesktop_cache);
                probe_outcome = loaded_thumb.probe_outcome;
                if (cancel.isCanceled()) {
                    t_surf.destroy();
                    return;
                }
                const source_dims = if (full_dims) |d|
                    state_pkg.PhysicalDims.initPositive(d.w, d.h)
                else
                    loaded_thumb.source_dims;
                const dct_snapped =
                    if (loaded_thumb.source == .freedesktop_cache)
                        false
                    else if (source_dims) |sd|
                        image.detectThumbnailDctPadding(t_surf, sd.w, sd.h)
                    else
                        false;
                workers.event_queue.push(alloc, io, .{
                    .thumb_decoded = .init(key, args.job_epoch, .{
                        .surface = t_surf,
                        .w = @floatFromInt(t_surf.w()),
                        .h = @floatFromInt(t_surf.h()),
                        .source_dims = source_dims,
                        .orientation = orientation,
                        .thumb_only = args.thumb_only,
                        .dct_snapped = dct_snapped,
                        .source = loaded_thumb.source,
                    }),
                }) catch |err| {
                    std.log.err(
                        "Failed to push thumbnail decode event: {}",
                        .{err},
                    );
                    t_surf.destroy();
                };
                context.wakeUpMainThread();

                if (args.thumb_only) {
                    return;
                }
            },
            .miss => |outcome| {
                had_embedded_thumb = false;
                probe_outcome = outcome;
            },
        }
    }

    if (args.thumb_only) {
        if (cancel.isCanceled()) return;
        const source_dims = if (full_dims) |d|
            state_pkg.PhysicalDims.initPositive(d.w, d.h)
        else
            null;
        workers.event_queue.push(alloc, io, .{
            .dimensions_probed = .init(key, args.job_epoch, .{
                .source_dims = source_dims,
                .orientation = orientation,
                .thumb_only = true,
                .raw_metadata = if (is_raw_archive)
                    (if (raw_sensor_dims) |d|
                        RawMetadata.init(d.w, d.h)
                    else if (source_dims) |sd|
                        RawMetadata.init(sd.w, sd.h)
                    else
                        .none)
                else
                    .none,
            }),
        }) catch |err| {
            std.log.err("Failed to push dimensions probed event: {}", .{err});
        };
        return;
    }

    if (cancel.isCanceled()) return;

    const full_bytes = payload.readRemaining(args) orelse return;
    const bytes_to_decode = if (raw_preview_slice) |s| s else full_bytes;
    const start_decode = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadConstMemOpt(bytes_to_decode);
    const end_decode = sdl.timer.getTicksNs();

    const decode_time_ms = @as(f64, @floatFromInt(end_decode - start_decode)) / 1_000_000.0;

    if (surface == null) {
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: failed to load image '{s}': {s}",
            .{ path, sdl.getError() },
        );
        return;
    }

    if (cancel.isCanceled()) {
        if (surface) |surf| surf.destroy();
        return;
    }

    const unscaled_w: f32 = @floatFromInt(surface.?.w());
    const unscaled_h: f32 = @floatFromInt(surface.?.h());
    const conv_res = convertAndScaleSurface(
        surface,
        args.pixel_format,
        args.has_gpu_device,
    );
    const final_surface = conv_res.surface;
    const conversion_time_ms = conv_res.conversion_time_ms;

    if (cancel.isCanceled()) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());
        const source_dims = if (full_dims) |d|
            state_pkg.PhysicalDims.initPositive(d.w, d.h)
        else
            state_pkg.PhysicalDims.initPositive(unscaled_w, unscaled_h);
        const raw_metadata: RawMetadata = if (is_raw_archive)
            (if (raw_sensor_dims) |d|
                RawMetadata.init(d.w, d.h)
            else if (source_dims) |sd|
                RawMetadata.init(sd.w, sd.h)
            else
                .none)
        else
            .none;
        const thumb_write_mtime_sec = resolveThumbWriteMtime(
            io,
            workers.thumb_cache_config,
            path,
            payload.mtime_sec,
            had_embedded_thumb,
            probe_outcome,
        );

        workers.event_queue.push(alloc, io, .{
            .image_decoded = .init(key, args.job_epoch, .{
                .surface = f_surf,
                .w = orig_w,
                .h = orig_h,
                .source_dims = source_dims,
                .mime_type = mime_type,
                .size_bytes = payload.size_bytes,
                .orientation = orientation,
                .raw_metadata = raw_metadata,
                .decode = .{
                    .read_time_ms = payload.read_time_ms,
                    .decode_time_ms = decode_time_ms,
                    .conversion_time_ms = conversion_time_ms,
                    .archive = payload.archive,
                },
                .thumb_write_mtime_sec = thumb_write_mtime_sec,
            }),
        }) catch |err| {
            std.log.err("Failed to push image decode event: {}", .{err});
            f_surf.destroy();
        };
    } else {
        workers.event_queue.push(alloc, io, .{
            .decode_failed = .init(key, args.job_epoch, .{}),
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
    }
}

var preview_file_seq: std.atomic.Value(u64) = .init(0);

/// Result of rendering a raw RGBA32 preview file for the Kitty Graphics
/// Protocol (`t=t`).
pub const PreviewRenderResult = struct {
    path_buf: [128]u8 = undefined,
    path_len: usize,
    dims: state_pkg.PositiveDimsU32,

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
    max_dims: state_pkg.PositiveDimsU32,

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

    const cancel: context.CancellationToken = .{
        .exiting = &workers.exiting,
    };
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
        res.dims.w,
        res.dims.h,
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
    orientation: probe.Orientation,
};

fn decodeEmbeddedLocSurface(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    cancel: context.CancellationToken,
    header_slice: []const u8,
    file_size: u64,
    loc: probe.ThumbnailLocation,
) !?sdl.Surface {
    if (loc.length == 0 or loc.file_offset +| loc.length > file_size) {
        return null;
    }
    const len: usize = @intCast(loc.length);
    if (loc.file_offset +| loc.length <= header_slice.len) {
        if (cancel.isCanceled()) return error.Canceled;
        const off: usize = @intCast(loc.file_offset);
        return sdl.Surface.loadConstMemOpt(header_slice[off .. off + len]);
    }
    const buf = try allocator.alloc(u8, len);
    defer allocator.free(buf);
    const n = try readRangePositional(file, io, cancel, buf, loc.file_offset);
    if (n != len) return null;
    if (cancel.isCanceled()) return error.Canceled;
    return sdl.Surface.loadConstMemOpt(buf);
}

fn decodePreviewSourceSurface(
    allocator: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: thumb_cache.ThumbCacheConfig,
    path: []const u8,
    max_dims: state_pkg.PositiveDimsU32,
    cancel: context.CancellationToken,
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
                if (thumb_cache.ThumbCacheKey.fromFilePath(
                    io,
                    path,
                    cfg.cache_dir,
                )) |cache_key| {
                    if (thumb_cache.loadCachedThumbnail(
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
    const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or
        (header_slice.len >= 8 and
            std.mem.startsWith(u8, header_slice, "FUJIFILM"));
    const is_raw = isRawFile(path) or
        is_fuji or
        std.mem.startsWith(u8, mime_type, "image/x-");

    if (is_raw) {
        var prev_loc_opt: ?probe.ThumbnailLocation = null;
        var med_loc_opt: ?probe.ThumbnailLocation = null;
        var thumb_loc_opt: ?probe.ThumbnailLocation = null;
        var orientation: probe.Orientation = .normal;

        if (is_fuji) {
            prev_loc_opt = probe.extractFujiRafPreviewLocation(header_slice);
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
                    var p_hdr: [8 * 1024]u8 = undefined;
                    const pn = try readRangePositional(
                        file,
                        io,
                        cancel,
                        &p_hdr,
                        prev_loc.file_offset,
                    );
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
            var tail_slice: ?[]const u8 = null;
            var tiff_tail_off: u32 = 0;
            if (probe.probeTiffIfd0Offset(header_slice)) |ifd0_off| {
                if (ifd0_off >= header_n and ifd0_off < file_size) {
                    const tail_target: usize = @intCast(
                        @min(file_size -| ifd0_off, tail_buf.len),
                    );
                    if (tail_target > 0) {
                        const tn = try readRangePositional(
                            file,
                            io,
                            cancel,
                            tail_buf[0..tail_target],
                            ifd0_off,
                        );
                        if (tn > 0) {
                            tail_slice = tail_buf[0..tn];
                            tiff_tail_off = ifd0_off;
                        }
                    }
                }
            }
            const tiff_source = if (tail_slice) |ts|
                probe.TiffSource.initWithTail(header_slice, tiff_tail_off, ts)
            else
                probe.TiffSource.init(header_slice);
            const raw_cands = probe.extractTiffRawPreviewsFromSource(
                tiff_source,
            );
            prev_loc_opt = raw_cands.preview;
            med_loc_opt = raw_cands.medium;
            thumb_loc_opt = raw_cands.thumbnail;
            orientation = probe.parseExifOrientationFromSource(
                tiff_source,
            ) orelse .normal;
        }

        const candidates = if (max_dims.w <= 320 and max_dims.h <= 320)
            [_]?probe.ThumbnailLocation{
                med_loc_opt,
                prev_loc_opt,
                thumb_loc_opt,
            }
        else
            [_]?probe.ThumbnailLocation{
                prev_loc_opt,
                med_loc_opt,
                thumb_loc_opt,
            };

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
    if (max_dims.w <= 200 and max_dims.h <= 200 and
        std.mem.eql(u8, mime_type, "image/jpeg"))
    {
        if (probe.extractJpegThumbnailLocation(header_slice)) |loc| {
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
pub fn renderPreviewRgbaFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: thumb_cache.ThumbCacheConfig,
    path: []const u8,
    max_dims: state_pkg.PositiveDimsU32,
    cancel: context.CancellationToken,
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

test "decodeWorker - thumb_only does not do full decompression on JPEG" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const path = try allocator.dupe(u8, "testfiles/images/000_0_1024x682.jpg");
    const entry = MediaEntry{ .filesystem = .{ .path = path } };

    var current_gen: std.atomic.Value(usize) = .init(1);
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .current_generation = &current_gen,
        .entry = entry,
        .has_gpu_device = false,
        .pixel_format = sdl.PixelFormat.rgba32,
        .thumb_only = true,
    };

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);

    decodeWorker(args);

    var dimensions_probed_seen = false;
    var image_decoded_seen = false;

    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .dimensions_probed => |d_evt| {
                const d = d_evt.unwrapForTest();
                dimensions_probed_seen = true;
                try std.testing.expect(d.thumb_only);
                try std.testing.expectEqual(
                    state_pkg.PhysicalDims{ .w = 1024.0, .h = 682.0 },
                    d.source_dims.?,
                );
            },
            .image_decoded => {
                image_decoded_seen = true;
            },
            else => {},
        }
    }

    try std.testing.expect(dimensions_probed_seen);
    try std.testing.expect(!image_decoded_seen);
}

test "decodeWorker - thumb_only does not do full decompression on PNG" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const path = try allocator.dupe(u8, "testfiles/golden-screenshots/init.png");
    const entry = MediaEntry{ .filesystem = .{ .path = path } };

    var current_gen: std.atomic.Value(usize) = .init(1);
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .current_generation = &current_gen,
        .entry = entry,
        .has_gpu_device = true,
        .pixel_format = sdl.PixelFormat.rgba32,
        .thumb_only = true,
    };

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);

    decodeWorker(args);

    var dimensions_probed_seen = false;
    var image_decoded_seen = false;

    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .dimensions_probed => |d_evt| {
                const d = d_evt.unwrapForTest();
                dimensions_probed_seen = true;
                try std.testing.expect(d.thumb_only);
                try std.testing.expect(d.source_dims != null);
            },
            .image_decoded => {
                image_decoded_seen = true;
            },
            else => {},
        }
    }

    try std.testing.expect(dimensions_probed_seen);
    try std.testing.expect(!image_decoded_seen);
}

test "decodeWorker - prunes early when current_generation does not match key.generation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const path = try allocator.dupe(u8, "testfiles/golden-screenshots/init.png");
    const entry = MediaEntry{ .filesystem = .{ .path = path } };

    var current_gen: std.atomic.Value(usize) = .init(2);
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .entry = entry,
        .has_gpu_device = true,
        .pixel_format = sdl.PixelFormat.rgba32,
        .thumb_only = false,
        .current_generation = &current_gen,
    };

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);

    decodeWorker(args);

    var event_seen = false;
    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        event_seen = true;
    }

    try std.testing.expect(!event_seen);
}

test "decompressCbzMediaEntry - deflate entry with 128KB buffer" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const cbz_path = "testfiles/sample.cbz";
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, cbz_path, .{});
    file.close(io);

    const entry = ArchiveMediaEntry{
        .archive_path = cbz_path,
        .entry_name = "000_0_1024x682.jpg",
    };

    const res = try decompressCbzMediaEntry(allocator, io, entry, null);
    defer allocator.free(res.bytes);

    try std.testing.expectEqual(@as(usize, 58713), res.bytes.len);
    try std.testing.expectEqual(@as(u64, 57867), res.compressed_size);
    try std.testing.expect(res.compressed_size != res.bytes.len);
    try std.testing.expect(res.decompress_time_ms >= 0.0);

    // Partial prefix read (max_bytes = 4096)
    const prefix_res = try decompressCbzMediaEntry(allocator, io, entry, 4096);
    defer allocator.free(prefix_res.bytes);
    try std.testing.expectEqual(@as(usize, 4096), prefix_res.bytes.len);
    try std.testing.expectEqualSlices(
        u8,
        res.bytes[0..4096],
        prefix_res.bytes,
    );

    // Oversized uncompressed_size is rejected with error.FileTooBig
    const oversized_entry = ArchiveMediaEntry{
        .archive_path = cbz_path,
        .entry_name = "000_0_1024x682.jpg",
        .seek_info = .{
            .indexed = .{
                .header_zip_offset = 0,
                .file_offset = 0,
                .uncompressed_size = max_cbz_entry_bytes + 1,
                .compression_method = .deflate,
            },
        },
    };
    try std.testing.expectError(
        error.FileTooBig,
        decompressCbzMediaEntry(allocator, io, oversized_entry, null),
    );
}

test "decodeWorker - Sony ARW range reading and preview extraction" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Read real JPEG to embed as preview
    const sample_jpg_path = "testfiles/images/000_0_1024x682.jpg";
    var real_jpg = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, sample_jpg_path, .{});
    defer real_jpg.close(io);
    const jpg_stat = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, sample_jpg_path, .{});
    const jpg_bytes = try allocator.alloc(u8, @intCast(jpg_stat.size));
    defer allocator.free(jpg_bytes);
    var j_slices = [_][]u8{jpg_bytes};
    _ = try real_jpg.readPositional(io, &j_slices, 0);

    // Construct mock TIFF ARW
    var tiff_buf = try allocator.alloc(u8, 100 + jpg_bytes.len);
    defer allocator.free(tiff_buf);
    @memset(tiff_buf, 0);

    // TIFF Header
    tiff_buf[0] = 'I';
    tiff_buf[1] = 'I';
    tiff_buf[2] = 0x2A;
    tiff_buf[3] = 0x00;
    std.mem.writeInt(u32, tiff_buf[4..8], 8, .little);

    // IFD0 (num = 4)
    std.mem.writeInt(u16, tiff_buf[8..10], 4, .little);
    var off: usize = 10;
    // 1. 0x0100 (ImageWidth) = 6000
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0100, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 6000, .little);
    off += 12;

    // 2. 0x0101 (ImageLength) = 4000
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0101, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 4000, .little);
    off += 12;

    // 3. 0x0112 (Orientation) = 6 (rotate 90)
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0112, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 3, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u16, tiff_buf[off + 8 ..][0..2], 6, .little);
    off += 12;

    // 4. 0x014A (SubIFD) pointing to offset 60
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x014A, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 60, .little);
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little); // next IFD = 0

    // SubIFD at 60 (num = 2)
    off = 60;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 2, .little);
    off += 2;
    // 1. 0x0201 (JPEGInterchangeFormat) pointing to 100
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 100, .little);
    off += 12;

    // 2. 0x0202 (JPEGInterchangeFormatLength) = jpg_bytes.len
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], @intCast(jpg_bytes.len), .little);
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little);

    // Copy JPEG at 100
    @memcpy(tiff_buf[100 .. 100 + jpg_bytes.len], jpg_bytes);

    // Write mock file in isolated temp directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_test.arw", .{});
    var wr_slices = [_][]const u8{tiff_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_test.arw",
        .{tmp.sub_path},
    );

    // Test 1: Full decode (thumb_only = false)
    {
        var workers = WorkerManager{};
        defer workers.deinit(allocator, io);

        const p = try allocator.dupe(u8, mock_path);
        const entry = MediaEntry{ .filesystem = .{ .path = p } };
        var current_gen: std.atomic.Value(usize) = .init(1);
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = false,
        };

        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);

        decodeWorker(args);

        var image_decoded_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .image_decoded => |img_evt| {
                    const img_payload = img_evt.unwrapForTest();
                    image_decoded_seen = true;
                    try std.testing.expect(img_payload.raw_metadata.isRaw());
                    const s_dims = img_payload.raw_metadata.getSensorDims().?;
                    try std.testing.expectEqual(@as(f32, 6000.0), s_dims.w);
                    try std.testing.expectEqual(@as(f32, 4000.0), s_dims.h);
                    try std.testing.expectEqual(
                        probe.Orientation.rotate_90,
                        img_payload.orientation,
                    );
                    try std.testing.expect(img_payload.surface != null);
                    try std.testing.expectEqual(@as(f32, 1024.0), img_payload.w);
                    try std.testing.expectEqual(@as(f32, 682.0), img_payload.h);
                },
                else => {},
            }
        }
        try std.testing.expect(image_decoded_seen);
    }

    // Test 2: Thumb only decode (thumb_only = true)
    {
        var workers = WorkerManager{};
        defer workers.deinit(allocator, io);

        const p = try allocator.dupe(u8, mock_path);
        const entry = MediaEntry{ .filesystem = .{ .path = p } };
        var current_gen: std.atomic.Value(usize) = .init(1);
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = true,
        };

        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);

        decodeWorker(args);

        var thumb_decoded_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .thumb_decoded => |t_evt| {
                    const t_payload = t_evt.unwrapForTest();
                    thumb_decoded_seen = true;
                    try std.testing.expect(t_payload.raw_metadata.isRaw());
                    try std.testing.expect(t_payload.thumb_only);
                    const ts_dims = t_payload.raw_metadata.getSensorDims().?;
                    try std.testing.expectEqual(@as(f32, 6000.0), ts_dims.w);
                    try std.testing.expectEqual(@as(f32, 4000.0), ts_dims.h);
                    try std.testing.expectEqual(
                        probe.Orientation.rotate_90,
                        t_payload.orientation,
                    );
                },
                else => {},
            }
        }
        try std.testing.expect(thumb_decoded_seen);
    }
}

test "decodeWorker - Fujifilm RAF range reading and preview extraction" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Read real JPEG to embed as preview
    const sample_jpg_path = "testfiles/images/000_0_1024x682.jpg";
    var real_jpg = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, sample_jpg_path, .{});
    defer real_jpg.close(io);
    const jpg_stat = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, sample_jpg_path, .{});
    const jpg_bytes = try allocator.alloc(u8, @intCast(jpg_stat.size));
    defer allocator.free(jpg_bytes);
    var j_slices = [_][]u8{jpg_bytes};
    _ = try real_jpg.readPositional(io, &j_slices, 0);

    // Construct mock Fujifilm RAF
    var raf_buf = try allocator.alloc(u8, 200 + jpg_bytes.len);
    defer allocator.free(raf_buf);
    @memset(raf_buf, 0);

    @memcpy(raf_buf[0..8], "FUJIFILM");
    std.mem.writeInt(u32, raf_buf[84..88], 200, .big);
    std.mem.writeInt(u32, raf_buf[88..92], @intCast(jpg_bytes.len), .big);
    std.mem.writeInt(u32, raf_buf[92..96], 120, .big);
    std.mem.writeInt(u32, raf_buf[96..100], 12, .big);

    // Metadata block at 120:
    std.mem.writeInt(u32, raf_buf[120..124], 1, .big);
    std.mem.writeInt(u16, raf_buf[124..126], 0x0111, .big);
    std.mem.writeInt(u16, raf_buf[126..128], 4, .big);
    std.mem.writeInt(u16, raf_buf[128..130], 4160, .big);
    std.mem.writeInt(u16, raf_buf[130..132], 6240, .big);

    // Copy preview JPEG at 200
    @memcpy(raf_buf[200 .. 200 + jpg_bytes.len], jpg_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_test.raf", .{});
    var wr_slices = [_][]const u8{raf_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_test.raf",
        .{tmp.sub_path},
    );

    // Test full decode
    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const p = try allocator.dupe(u8, mock_path);
    const entry = MediaEntry{ .filesystem = .{ .path = p } };
    var current_gen: std.atomic.Value(usize) = .init(1);
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .current_generation = &current_gen,
        .entry = entry,
        .has_gpu_device = true,
        .pixel_format = sdl.PixelFormat.rgba32,
        .thumb_only = false,
    };

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);

    decodeWorker(args);

    var image_decoded_seen = false;
    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .image_decoded => |img_evt| {
                const img_payload = img_evt.unwrapForTest();
                image_decoded_seen = true;
                try std.testing.expect(img_payload.raw_metadata.isRaw());
                const s_dims = img_payload.raw_metadata.getSensorDims().?;
                try std.testing.expectEqual(@as(f32, 6240.0), s_dims.w);
                try std.testing.expectEqual(@as(f32, 4160.0), s_dims.h);
                try std.testing.expect(img_payload.surface != null);
                try std.testing.expectEqual(@as(f32, 1024.0), img_payload.w);
                try std.testing.expectEqual(@as(f32, 682.0), img_payload.h);
            },
            else => {},
        }
    }
    try std.testing.expect(image_decoded_seen);
}

test "decodeWorker - progressive 3-tier loading for synthetic ARW" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const thumb_path = "testfiles/images/063_63_1024x576.jpg"; // ~18 KB
    const med_path = "testfiles/images/024_24_1024x380.jpg"; // ~28 KB
    const prev_path = "testfiles/images/000_0_1024x682.jpg"; // ~58 KB

    const readJpeg = struct {
        fn run(
            alloc: std.mem.Allocator,
            io_inst: std.Io,
            path: []const u8,
        ) ![]u8 {
            var f = try std.Io.Dir.openFile(
                std.Io.Dir.cwd(),
                io_inst,
                path,
                .{},
            );
            defer f.close(io_inst);
            const st = try std.Io.Dir.statFile(
                std.Io.Dir.cwd(),
                io_inst,
                path,
                .{},
            );
            const buf = try alloc.alloc(u8, @intCast(st.size));
            errdefer alloc.free(buf);
            var slices = [_][]u8{buf};
            _ = try f.readPositional(io_inst, &slices, 0);
            return buf;
        }
    }.run;

    const thumb_bytes = try readJpeg(allocator, io, thumb_path);
    defer allocator.free(thumb_bytes);
    const med_bytes = try readJpeg(allocator, io, med_path);
    defer allocator.free(med_bytes);
    const prev_bytes = try readJpeg(allocator, io, prev_path);
    defer allocator.free(prev_bytes);

    const header_len: usize = 256;
    const thumb_off: usize = header_len;
    const med_off: usize = thumb_off + thumb_bytes.len;
    const prev_off: usize = med_off + med_bytes.len;
    const total_len: usize = prev_off + prev_bytes.len;

    const tiff_buf = try allocator.alloc(u8, total_len);
    defer allocator.free(tiff_buf);
    @memset(tiff_buf, 0);

    // Little-endian TIFF header, IFD0 at offset 8
    tiff_buf[0] = 'I';
    tiff_buf[1] = 'I';
    tiff_buf[2] = 0x2A;
    tiff_buf[3] = 0x00;
    std.mem.writeInt(u32, tiff_buf[4..8], 8, .little);

    // IFD0 at 8: 2 entries (medium preview) -> next IFD1 at 60
    var off: usize = 8;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 2, .little);
    off += 2;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(med_off),
        .little,
    );
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(med_bytes.len),
        .little,
    );
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 60, .little);

    // IFD1 at 60: 2 entries (smallest thumbnail) -> next IFD2 at 110
    off = 60;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 2, .little);
    off += 2;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(thumb_off),
        .little,
    );
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(thumb_bytes.len),
        .little,
    );
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 110, .little);

    // IFD2 at 110: 4 entries (largest preview + visible dimensions 6240x4160)
    off = 110;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 4, .little);
    off += 2;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0100, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 6240, .little);
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0101, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 4160, .little);
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(prev_off),
        .little,
    );
    off += 12;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(
        u32,
        tiff_buf[off + 8 ..][0..4],
        @intCast(prev_bytes.len),
        .little,
    );
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little);

    @memcpy(tiff_buf[thumb_off .. thumb_off + thumb_bytes.len], thumb_bytes);
    @memcpy(tiff_buf[med_off .. med_off + med_bytes.len], med_bytes);
    @memcpy(tiff_buf[prev_off .. prev_off + prev_bytes.len], prev_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_3tier.arw", .{});
    var wr_slices = [_][]const u8{tiff_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const arw_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_3tier.arw",
        .{tmp.sub_path},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    var current_gen: std.atomic.Value(usize) = .init(1);

    // Case 1: Fast scrubbing (thumb_only = true) -> receives IFD1 (1024x576)
    {
        const p = try allocator.dupe(u8, arw_path);
        const entry = MediaEntry{ .filesystem = .{ .path = p } };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = true,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);

        decodeWorker(args);

        var thumb_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .thumb_decoded => |t_evt| {
                    const t = t_evt.unwrapForTest();
                    thumb_seen = true;
                    try std.testing.expectEqual(@as(f32, 1024.0), t.w);
                    try std.testing.expectEqual(@as(f32, 576.0), t.h);
                    try std.testing.expectEqual(
                        state_pkg.PhysicalDims{ .w = 6240.0, .h = 4160.0 },
                        t.source_dims.?,
                    );
                },
                else => {},
            }
        }
        try std.testing.expect(thumb_seen);
    }

    // Case 2: Settled viewing (thumb_only = false) -> receives IFD0 medium
    // placeholder (1024x380), then IFD2 full preview (1024x682)
    {
        const p = try allocator.dupe(u8, arw_path);
        const entry = MediaEntry{ .filesystem = .{ .path = p } };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(2), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = false,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);

        decodeWorker(args);

        var med_thumb_seen = false;
        var full_image_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .thumb_decoded => |t_evt| {
                    const t = t_evt.unwrapForTest();
                    med_thumb_seen = true;
                    try std.testing.expectEqual(@as(f32, 1024.0), t.w);
                    try std.testing.expectEqual(@as(f32, 380.0), t.h);
                    try std.testing.expectEqual(
                        state_pkg.PhysicalDims{ .w = 6240.0, .h = 4160.0 },
                        t.source_dims.?,
                    );
                },
                .image_decoded => |img_evt| {
                    const img = img_evt.unwrapForTest();
                    full_image_seen = true;
                    try std.testing.expectEqual(@as(f32, 1024.0), img.w);
                    try std.testing.expectEqual(@as(f32, 682.0), img.h);
                    const s_dims = img.raw_metadata.getSensorDims().?;
                    try std.testing.expectEqual(@as(f32, 6240.0), s_dims.w);
                    try std.testing.expectEqual(@as(f32, 4160.0), s_dims.h);
                },
                else => {},
            }
        }
        try std.testing.expect(med_thumb_seen);
        try std.testing.expect(full_image_seen);
    }
}

test "decodeWorker - progressive pair loading with PairStreamTarget" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const jpg_file = "testfiles/images/000_0_1024x682.jpg";
    var real_jpg = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, jpg_file, .{});
    defer real_jpg.close(io);
    const s = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, jpg_file, .{});
    const jpg_bytes = try allocator.alloc(u8, s.size);
    defer allocator.free(jpg_bytes);
    var j_slices = [_][]u8{jpg_bytes};
    _ = try real_jpg.readPositional(io, &j_slices, 0);

    var tiff_buf = try allocator.alloc(u8, 100 + jpg_bytes.len);
    defer allocator.free(tiff_buf);
    @memset(tiff_buf, 0);

    tiff_buf[0] = 'I';
    tiff_buf[1] = 'I';
    tiff_buf[2] = 0x2A;
    tiff_buf[3] = 0x00;
    std.mem.writeInt(u32, tiff_buf[4..8], 8, .little);

    std.mem.writeInt(u16, tiff_buf[8..10], 4, .little);
    var off: usize = 10;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0100, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 6000, .little);
    off += 12;

    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0101, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 4000, .little);
    off += 12;

    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0112, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 3, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u16, tiff_buf[off + 8 ..][0..2], 1, .little);
    off += 12;

    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x014A, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 60, .little);
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little);

    off = 60;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 2, .little);
    off += 2;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 100, .little);
    off += 12;

    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], @intCast(jpg_bytes.len), .little);
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little);

    @memcpy(tiff_buf[100 .. 100 + jpg_bytes.len], jpg_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_pair.arw", .{});
    var wr_slices = [_][]const u8{tiff_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const raw_file = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_pair.arw",
        .{tmp.sub_path},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    var current_gen: std.atomic.Value(usize) = .init(1);

    // 1. thumb_only decodes RAW thumbnail
    {
        const pair = FilePair{
            .raw_path = try allocator.dupe(u8, raw_file),
            .jpeg_path = try allocator.dupe(u8, jpg_file),
        };
        const entry = MediaEntry{ .pair = pair };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = true,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        var thumb_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            if (ev.* == .thumb_decoded) {
                thumb_seen = true;
                try std.testing.expect(
                    ev.thumb_decoded.unwrapForTest().raw_metadata.isRaw(),
                );
            }
        }
        try std.testing.expect(thumb_seen);
    }

    // 2. pair_target = .standalone_jpeg decodes companion JPEG
    {
        const pair = FilePair{
            .raw_path = try allocator.dupe(u8, raw_file),
            .jpeg_path = try allocator.dupe(u8, jpg_file),
        };
        const entry = MediaEntry{ .pair = pair };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(2), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = false,
            .pair_target = .standalone_jpeg,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        var jpeg_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            if (ev.* == .image_decoded) {
                jpeg_seen = true;
                const img = ev.image_decoded.unwrapForTest();
                try std.testing.expect(!img.raw_metadata.isRaw());
                try std.testing.expectEqual(@as(f32, 1024.0), img.w);
                try std.testing.expectEqual(@as(f32, 682.0), img.h);
            }
        }
        try std.testing.expect(jpeg_seen);
    }

    // 3. pair_target = .adaptive settled decodes RAW preview
    {
        const pair = FilePair{
            .raw_path = try allocator.dupe(u8, raw_file),
            .jpeg_path = try allocator.dupe(u8, jpg_file),
        };
        const entry = MediaEntry{ .pair = pair };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(3), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = false,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        var raw_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            if (ev.* == .image_decoded) {
                raw_seen = true;
                try std.testing.expect(
                    ev.image_decoded.unwrapForTest().raw_metadata.isRaw(),
                );
            }
        }
        try std.testing.expect(raw_seen);
    }
}

test "decodeWorker - canceled RAW pair exits without fallback" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    var current_gen: std.atomic.Value(usize) = .init(2);
    const pair = FilePair{
        .raw_path = try allocator.dupe(u8, "nonexistent.raf"),
        .jpeg_path = try allocator.dupe(
            u8,
            "testfiles/images/000_0_1024x682.jpg",
        ),
    };
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        // Stale generation -> canceled
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .current_generation = &current_gen,
        .entry = .{ .pair = pair },
        .has_gpu_device = false,
        .pixel_format = sdl.PixelFormat.rgba32,
        .thumb_only = false,
    };

    try std.testing.expect(decodeRawFile(args, pair.raw_path, true));

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);
    decodeWorker(args);

    try std.testing.expectEqual(
        @as(usize, 0),
        workers.active_decode_threads.load(.acquire),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        workers.active_threads.load(.acquire),
    );
    try std.testing.expect(workers.event_queue.pop() == null);
}

test "decodeWorker - two-stage JPEG read emits header and positional thumbnails before Stage 2" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const main_jpg_path = "testfiles/images/000_0_1024x682.jpg";
    const thumb_jpg_path = "testfiles/images/063_63_1024x576.jpg";

    const readAll = struct {
        fn run(alloc: std.mem.Allocator, io_inst: std.Io, p: []const u8) ![]u8 {
            var f = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io_inst, p, .{});
            defer f.close(io_inst);
            const st = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io_inst, p, .{});
            const buf = try alloc.alloc(u8, @intCast(st.size));
            errdefer alloc.free(buf);
            var slices = [_][]u8{buf};
            _ = try f.readPositional(io_inst, &slices, 0);
            return buf;
        }
    }.run;

    const main_jpg = try readAll(allocator, io, main_jpg_path);
    defer allocator.free(main_jpg);
    const thumb_jpg = try readAll(allocator, io, thumb_jpg_path);
    defer allocator.free(thumb_jpg);

    // Build a synthetic JPEG > 256 KB where:
    // - SOI (2 bytes) + APP1 EXIF header (72 bytes) with Orientation = 6 (rotate_90)
    //   and IFD1 JPEGInterchangeFormat pointing to `thumb_tiff_rel_off`.
    // - Followed by `main_jpg[2..]` so SOF0/SOS/EOI are valid.
    // - Padded past `header_probe_limit` (256 KB) with `thumb_jpg` placed at `positional_thumb_off`.
    const app1_payload_len: usize = 6 + 64; // "Exif\x00\x00" + 64-byte TIFF header
    const app1_total_len: usize = 4 + app1_payload_len; // 0xFF 0xE1 + len(2) + payload
    const tiff_start_off: usize = 2 + 4 + 6; // offset 12 in file
    const positional_thumb_off: usize = header_probe_limit + 16 * 1024;
    const total_file_len: usize = positional_thumb_off + thumb_jpg.len;

    const file_buf = try allocator.alloc(u8, total_file_len);
    defer allocator.free(file_buf);
    @memset(file_buf, 0);

    // 1. SOI
    file_buf[0] = 0xFF;
    file_buf[1] = 0xD8;

    // 2. APP1 marker at offset 2
    file_buf[2] = 0xFF;
    file_buf[3] = 0xE1;
    std.mem.writeInt(u16, file_buf[4..6], @intCast(2 + app1_payload_len), .big);
    @memcpy(file_buf[6..12], "Exif\x00\x00");

    // 3. Little-endian TIFF header at `tiff_start_off` (12)
    const tiff = file_buf[tiff_start_off .. tiff_start_off + 64];
    tiff[0] = 'I';
    tiff[1] = 'I';
    std.mem.writeInt(u16, tiff[2..4], 0x002A, .little);
    std.mem.writeInt(u32, tiff[4..8], 8, .little); // IFD0 at 8

    // IFD0 at +8: 1 entry (Orientation = 6), next IFD1 at +26
    std.mem.writeInt(u16, tiff[8..10], 1, .little);
    std.mem.writeInt(u16, tiff[10..12], 0x0112, .little);
    std.mem.writeInt(u16, tiff[12..14], 3, .little);
    std.mem.writeInt(u32, tiff[14..18], 1, .little);
    std.mem.writeInt(u16, tiff[18..20], 6, .little);
    std.mem.writeInt(u32, tiff[22..26], 26, .little); // IFD1 offset = 26

    // IFD1 at +26: 2 entries (0x0201 offset, 0x0202 length)
    std.mem.writeInt(u16, tiff[26..28], 2, .little);
    std.mem.writeInt(u16, tiff[28..30], 0x0201, .little);
    std.mem.writeInt(u16, tiff[30..32], 4, .little);
    std.mem.writeInt(u32, tiff[32..36], 1, .little);
    std.mem.writeInt(
        u32,
        tiff[36..40],
        @intCast(positional_thumb_off - tiff_start_off),
        .little,
    );
    std.mem.writeInt(u16, tiff[40..42], 0x0202, .little);
    std.mem.writeInt(u16, tiff[42..44], 4, .little);
    std.mem.writeInt(u32, tiff[44..48], 1, .little);
    std.mem.writeInt(u32, tiff[48..52], @intCast(thumb_jpg.len), .little);
    std.mem.writeInt(u32, tiff[52..56], 0, .little);

    // 4. Copy main JPEG body right after APP1
    const body_start = 2 + app1_total_len;
    @memcpy(file_buf[body_start .. body_start + (main_jpg.len - 2)], main_jpg[2..]);

    // 5. Place thumbnail at `positional_thumb_off` (> 256 KB)
    @memcpy(
        file_buf[positional_thumb_off .. positional_thumb_off + thumb_jpg.len],
        thumb_jpg,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "staged_pos_thumb.jpg", .{});
    var wr_slices = [_][]const u8{file_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/staged_pos_thumb.jpg",
        .{tmp.sub_path},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    var current_gen: std.atomic.Value(usize) = .init(1);

    // Case 1: thumb_only = true with thumbnail past 256 KB succeeds via Stage 1 open file
    {
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{ .filesystem = .{ .path = try allocator.dupe(u8, mock_path) } },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = true,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        try std.testing.expectEqual(@as(usize, 0), workers.thumb_header_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 1), workers.thumb_positional_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 0), workers.thumb_misses.load(.monotonic));

        var orient_seen = false;
        var thumb_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .exif_orientation_parsed => |o_evt| {
                    orient_seen = true;
                    try std.testing.expectEqual(
                        probe.Orientation.rotate_90,
                        o_evt.unwrapForTest().orientation,
                    );
                },
                .thumb_decoded => |t_evt| {
                    const t = t_evt.unwrapForTest();
                    thumb_seen = true;
                    try std.testing.expect(t.thumb_only);
                    try std.testing.expectEqual(@as(f32, 1024.0), t.w);
                    try std.testing.expectEqual(@as(f32, 576.0), t.h);
                    try std.testing.expectEqual(
                        state_pkg.PhysicalDims{ .w = 1024.0, .h = 682.0 },
                        t.source_dims.?,
                    );
                },
                .image_decoded,
                .dimensions_probed,
                .decode_failed,
                .path_discovered,
                .directory_scan_result,
                .palette_folder_count,
                .precache_completed,
                .ipc_command,
                => {
                    return error.TestUnexpectedResult;
                },
            }
        }
        try std.testing.expect(orient_seen);
        try std.testing.expect(thumb_seen);
    }

    // Case 2: thumb_only = false emits orientation + thumb in Stage 1, then full image in Stage 2
    {
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(2), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{ .filesystem = .{ .path = try allocator.dupe(u8, mock_path) } },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = false,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        try std.testing.expectEqual(@as(usize, 2), workers.thumb_positional_hits.load(.monotonic));

        var batch: std.ArrayList(@TypeOf(workers.event_queue.items.items[0])) = .empty;
        defer {
            for (batch.items) |*ev| ev.deinit(allocator);
            batch.deinit(allocator);
        }
        try workers.event_queue.drain(allocator, io, &batch);
        try std.testing.expectEqual(@as(usize, 3), batch.items.len);

        try std.testing.expect(batch.items[0] == .exif_orientation_parsed);
        try std.testing.expect(batch.items[1] == .thumb_decoded);
        const t = batch.items[1].thumb_decoded.unwrapForTest();
        try std.testing.expect(!t.thumb_only);
        try std.testing.expectEqual(@as(f32, 1024.0), t.w);
        try std.testing.expectEqual(@as(f32, 576.0), t.h);

        try std.testing.expect(batch.items[2] == .image_decoded);
        const img = batch.items[2].image_decoded.unwrapForTest();
        try std.testing.expectEqual(@as(f32, 1024.0), img.w);
        try std.testing.expectEqual(@as(f32, 682.0), img.h);
        try std.testing.expectEqual(@as(u64, total_file_len), img.size_bytes);
    }

    // Case 3: Header-resident thumbnail in > 256 KB JPEG records thumb_header_hits
    {
        const header_thumb_off: usize = 128 * 1024;
        std.mem.writeInt(
            u32,
            file_buf[tiff_start_off + 36 ..][0..4],
            @intCast(header_thumb_off - tiff_start_off),
            .little,
        );
        @memcpy(
            file_buf[header_thumb_off .. header_thumb_off + thumb_jpg.len],
            thumb_jpg,
        );

        var hdr_file = try tmp.dir.createFile(io, "staged_hdr_thumb.jpg", .{});
        var hdr_slices = [_][]const u8{file_buf};
        _ = try hdr_file.writePositional(io, &hdr_slices, 0);
        hdr_file.close(io);

        var hdr_path_buf: [128]u8 = undefined;
        const hdr_path = try std.mem.print(
            &hdr_path_buf,
            ".zig-cache/tmp/{s}/staged_hdr_thumb.jpg",
            .{tmp.sub_path},
        );

        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(3), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{ .filesystem = .{ .path = try allocator.dupe(u8, hdr_path) } },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = false,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        try std.testing.expectEqual(@as(usize, 1), workers.thumb_header_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 2), workers.thumb_positional_hits.load(.monotonic));

        var batch: std.ArrayList(@TypeOf(workers.event_queue.items.items[0])) = .empty;
        defer {
            for (batch.items) |*ev| ev.deinit(allocator);
            batch.deinit(allocator);
        }
        try workers.event_queue.drain(allocator, io, &batch);
        try std.testing.expectEqual(@as(usize, 3), batch.items.len);
        try std.testing.expect(batch.items[0] == .exif_orientation_parsed);
        try std.testing.expect(batch.items[1] == .thumb_decoded);
        try std.testing.expect(batch.items[2] == .image_decoded);
    }
}

test "decodeWorker and background writer Freedesktop thumbnail roundtrip" {
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

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    workers.thumb_cache_config = try thumb_cache.ThumbCacheConfig.initWithDir(
        allocator,
        abs_cache_dir,
        .large,
        .all_missing,
    );

    const png_path = "testfiles/golden-screenshots/init.png";
    var current_gen: std.atomic.Value(usize) = .init(1);

    // 1. Cold cache: PNG has no embedded thumbnail and no cached thumbnail yet
    {
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{
                .filesystem = .{ .path = try allocator.dupe(u8, png_path) },
            },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = false,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        const stats1 = workers.snapshotThumbStats();
        try std.testing.expectEqual(@as(usize, 0), stats1.cache_hits);
        try std.testing.expectEqual(@as(usize, 1), stats1.misses);

        var ev = workers.event_queue.pop() orelse return error.MissingEvent;
        defer ev.deinit(allocator);
        try std.testing.expect(ev == .image_decoded);

        const img = ev.image_decoded.unwrapForTest();
        try std.testing.expect(img.thumb_write_mtime_sec != null);
        try std.testing.expect(img.thumb_write_mtime_sec.? > 0);

        const surf = img.surface orelse return error.MissingSurface;
        // Disown surface from event and enqueue background Freedesktop
        // thumbnail write
        ev.image_decoded.unchecked_payload.surface = null;
        workers.enqueueThumbWrite(allocator, io, .{
            .surface = surf,
            .source_path = try allocator.dupe(u8, png_path),
            .mime_type = img.mime_type,
            .file_size = img.size_bytes,
            .mtime_sec = img.thumb_write_mtime_sec.?,
            .orientation = img.orientation,
            .source_dims = .{ .w = img.w, .h = img.h },
        });

        var wait_iters: usize = 0;
        while (workers.thumb_cache_write_queued.load(.acquire) > 0 or
            workers.active_thumb_writers.load(.acquire) > 0) : (wait_iters += 1)
        {
            if (wait_iters > 400) return error.ThumbWriteTimeout;
            try std.Io.sleep(io, .fromMilliseconds(5), .awake);
        }

        const stats2 = workers.snapshotThumbStats();
        try std.testing.expectEqual(@as(usize, 1), stats2.cache_writes);
        try std.testing.expectEqual(@as(usize, 0), stats2.cache_write_queued);
    }

    // 2. Warm cache: decoding the same PNG now hits the Freedesktop cache in
    // Stage 1 and sets needs_thumb_write = false
    {
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{
                .filesystem = .{ .path = try allocator.dupe(u8, png_path) },
            },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .thumb_only = false,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        const stats3 = workers.snapshotThumbStats();
        try std.testing.expectEqual(@as(usize, 1), stats3.cache_hits);
        try std.testing.expectEqual(@as(usize, 1), stats3.misses);

        const EventItem = @TypeOf(workers.event_queue.items.items[0]);
        var batch: std.ArrayList(EventItem) = .empty;
        defer {
            for (batch.items) |*ev| ev.deinit(allocator);
            batch.deinit(allocator);
        }
        try workers.event_queue.drain(allocator, io, &batch);
        try std.testing.expectEqual(@as(usize, 2), batch.items.len);
        try std.testing.expect(batch.items[0] == .thumb_decoded);
        const thumb = batch.items[0].thumb_decoded.unwrapForTest();
        try std.testing.expectEqual(
            ThumbnailSource.freedesktop_cache,
            thumb.source,
        );
        try std.testing.expect(!thumb.dct_snapped);
        try std.testing.expect(thumb.w <= 256.0 and thumb.h <= 256.0);

        try std.testing.expect(batch.items[1] == .image_decoded);
        const img = batch.items[1].image_decoded.unwrapForTest();
        try std.testing.expect(img.thumb_write_mtime_sec == null);
    }
}
