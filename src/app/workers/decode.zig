const context = @import("context.zig");
const core_fs = @import("../core/fs.zig");
const exif = @import("../core/exif.zig");
const image = @import("../core/image.zig");
const manager = @import("manager.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const ArchiveMediaEntry = state_pkg.ArchiveMediaEntry;
const ImageCacheKey = image.ImageCacheKey;
const MediaEntry = state_pkg.MediaEntry;
const PairStreamTarget = state_pkg.PairStreamTarget;
const RawMetadata = state_pkg.RawMetadata;
const WorkerManager = manager.WorkerManager;

/// Contextual arguments and configuration passed to background image decoding worker threads.
pub const DecodeArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    key: ImageCacheKey,
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
    comptime fmt: []const u8,
    fmt_args: anytype,
) void {
    std.log.err(fmt, fmt_args);
    workers.event_queue.push(alloc, io, .{
        .decode_failed = .init(key, .{}),
    }) catch |e| std.log.err("Failed to push decode_failed event: {}", .{e});
    context.wakeUpMainThread();
}

const max_cbz_entry_bytes: u64 = 256 * 1024 * 1024;

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
    // - In Zig 0.16.0, `std.compress.flate.Decompress` pulls from `f_reader.interface` bit-by-bit.
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
            var fb = std.heap.stackFallback(std.fs.max_path_bytes, alloc);
            const temp_alloc = fb.get();

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
            "decodeWorker: statFile failed for '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    const file_size: u64 = s.size;

    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) return true;
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            "decodeWorker: openFile failed for '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    defer file.close(io);

    // Read initial 256KB header via readPositional without allocating full file
    const header_target: usize = @intCast(@min(file_size, 256 * 1024));
    var header_buf: [256 * 1024]u8 = undefined;
    var h_slices = [_][]u8{header_buf[0..header_target]};
    const start_hdr_read = sdl.timer.getTicksNs();
    const header_n = file.readPositional(io, &h_slices, 0) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) return true;
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            "decodeWorker: readPositional failed for '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    const end_hdr_read = sdl.timer.getTicksNs();
    const header_read_time_ms =
        @as(f64, @floatFromInt(end_hdr_read - start_hdr_read)) / 1_000_000.0;
    const header_slice = header_buf[0..header_n];

    const mime_type = image.detectMimeType(header_slice, path);
    const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or
        (header_slice.len >= 8 and std.mem.startsWith(u8, header_slice, "FUJIFILM"));

    var prev_loc_opt: ?exif.ThumbnailLocation = null;
    var med_loc_opt: ?exif.ThumbnailLocation = null;
    var thumb_loc_opt: ?exif.ThumbnailLocation = null;
    var raw_sensor_dims: ?exif.JpegDimensions = null;
    var orientation: state_pkg.Orientation = .normal;

    if (is_fuji) {
        prev_loc_opt = exif.extractFujiRafPreviewLocation(header_slice);
        if (exif.extractFujiRafMetadataLocation(header_slice)) |meta_loc| {
            if (meta_loc.file_offset +| meta_loc.length <= header_n) {
                const end = meta_loc.file_offset + meta_loc.length;
                raw_sensor_dims = exif.parseFujiRafDimensions(
                    header_slice[@intCast(meta_loc.file_offset)..@intCast(end)],
                );
            } else if (meta_loc.length > 0 and meta_loc.length <= 64 * 1024 and
                meta_loc.file_offset +| meta_loc.length <= file_size)
            {
                var m_buf: [64 * 1024]u8 = undefined;
                var m_slices = [_][]u8{m_buf[0..meta_loc.length]};
                const mn = file.readPositional(
                    io,
                    &m_slices,
                    meta_loc.file_offset,
                ) catch |err| blk: {
                    if (err == error.Canceled or cancel.isCanceled()) {
                        return true;
                    }
                    break :blk 0;
                };
                if (mn >= meta_loc.length) {
                    raw_sensor_dims = exif.parseFujiRafDimensions(
                        m_buf[0..meta_loc.length],
                    );
                }
            }
        }
        if (prev_loc_opt) |prev_loc| {
            if (prev_loc.file_offset +| 4096 <= header_n) {
                const off: usize = @intCast(prev_loc.file_offset);
                orientation = exif.parseExifOrientation(header_slice[off..header_n]) orelse .normal;
                if (exif.extractJpegThumbnailLocation(header_slice[off..header_n])) |j_thumb| {
                    thumb_loc_opt = .{
                        .file_offset = prev_loc.file_offset +|
                            j_thumb.file_offset,
                        .length = j_thumb.length,
                    };
                }
            } else {
                var p_hdr: [8192]u8 = undefined;
                var p_slices = [_][]u8{&p_hdr};
                const pn = file.readPositional(
                    io,
                    &p_slices,
                    prev_loc.file_offset,
                ) catch |err| blk: {
                    if (err == error.Canceled or cancel.isCanceled()) {
                        return true;
                    }
                    break :blk 0;
                };
                if (pn > 0) {
                    orientation = exif.parseExifOrientation(p_hdr[0..pn]) orelse .normal;
                    if (exif.extractJpegThumbnailLocation(p_hdr[0..pn])) |j_thumb| {
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
        if (exif.probeTiffIfd0Offset(header_slice)) |ifd0_off| {
            if (ifd0_off >= header_n and ifd0_off < file_size) {
                const tail_target: usize =
                    @intCast(@min(file_size -| ifd0_off, tail_buf.len));
                if (tail_target > 0) {
                    var t_slices = [_][]u8{tail_buf[0..tail_target]};
                    const tn = file.readPositional(
                        io,
                        &t_slices,
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
            exif.TiffSource.initWithTail(header_slice, tiff_tail_off, ts)
        else
            exif.TiffSource.init(header_slice);

        const raw_cands = exif.extractTiffRawPreviewsFromSource(tiff_source);
        prev_loc_opt = raw_cands.preview;
        med_loc_opt = raw_cands.medium;
        thumb_loc_opt = raw_cands.thumbnail;
        raw_sensor_dims = exif.parseExifDimensionsFromSource(tiff_source);
        if (raw_sensor_dims == null) {
            if (image.parseImageDimensions(header_slice, mime_type)) |d| {
                raw_sensor_dims = .{
                    .w = d.w,
                    .h = d.h,
                };
            }
        }
        orientation = exif.parseExifOrientationFromSource(tiff_source) orelse
            .normal;
    }

    if (cancel.isCanceled()) return true;

    if (orientation != .normal) {
        workers.event_queue.push(alloc, io, .{
            .exif_orientation_parsed = .init(
                key,
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

    // Fast scrubbing & instant placeholder thumbnail path
    if ((args.has_gpu_device and args.pair_target == .adaptive) or
        args.thumb_only)
    {
        var thumb_surf: ?sdl.Surface = null;
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
                    _ = workers.thumb_header_hits.fetchAdd(1, .monotonic);
                    thumb_surf = sdl.Surface.loadConstMemOpt(
                        header_slice[t_off .. t_off + t_len],
                    );
                } else {
                    const t_buf = alloc.alloc(u8, t_len) catch null;
                    if (t_buf) |tb| {
                        defer alloc.free(tb);
                        var ts_slices = [_][]u8{tb};
                        const tn = file.readPositional(
                            io,
                            &ts_slices,
                            tloc.file_offset,
                        ) catch |err| blk: {
                            if (err == error.Canceled or cancel.isCanceled()) {
                                return true;
                            }
                            break :blk 0;
                        };
                        if (tn == t_len) {
                            _ = workers.thumb_positional_hits.fetchAdd(
                                1,
                                .monotonic,
                            );
                            thumb_surf = sdl.Surface.loadConstMemOpt(tb);
                        } else {
                            _ = workers.thumb_misses.fetchAdd(1, .monotonic);
                        }
                    }
                }
            }
        }

        if (thumb_surf) |t_surf| {
            if (cancel.isCanceled()) {
                t_surf.destroy();
                return true;
            }
            const full_w: f32 = if (raw_w > 0.0) raw_w else 0.0;
            const full_h: f32 = if (raw_h > 0.0) raw_h else 0.0;
            const dct_snapped = image.detectThumbnailDctPadding(
                t_surf,
                full_w,
                full_h,
            );
            workers.event_queue.push(alloc, io, .{
                .thumb_decoded = .init(key, .{
                    .surface = t_surf,
                    .w = @floatFromInt(t_surf.w()),
                    .h = @floatFromInt(t_surf.h()),
                    .full_w = full_w,
                    .full_h = full_h,
                    .orientation = orientation,
                    .thumb_only = args.thumb_only,
                    .raw_metadata = RawMetadata.init(raw_w, raw_h),
                    .dct_snapped = dct_snapped,
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
                .dimensions_probed = .init(key, .{
                    .w = raw_w,
                    .h = raw_h,
                    .full_w = raw_w,
                    .full_h = raw_h,
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
                "decodeWorker: alloc failed for preview in '{s}': {}",
                .{ path, err },
            );
            return true;
        };
        prev_allocated_buf = p_buf;

        const start_p_read = sdl.timer.getTicksNs();
        var total_read: usize = 0;
        while (total_read < p_buf.len) {
            var p_slices = [_][]u8{p_buf[total_read..]};
            const pn = file.readPositional(
                io,
                &p_slices,
                prev_loc.file_offset + total_read,
            ) catch |err| {
                if (err == error.Canceled or cancel.isCanceled()) return true;
                if (is_pair) return false;
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: readPositional failed " ++
                        "for preview in '{s}': {}",
                    .{ path, err },
                );
                return true;
            };
            if (pn == 0) break;
            total_read += pn;
        }
        const end_p_read = sdl.timer.getTicksNs();
        if (total_read < p_buf.len) {
            if (is_pair) return false;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
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
        if (exif.parseExifOrientation(prev_bytes)) |o| {
            orientation = o;
            if (orientation != .normal) {
                if (cancel.isCanceled()) return true;
                workers.event_queue.push(alloc, io, .{
                    .exif_orientation_parsed = .init(
                        key,
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
            "decodeWorker: failed to load RAW preview surface '{s}': {s}",
            .{ path, sdl.getError() },
        );
        return true;
    }

    if (cancel.isCanceled()) {
        surface.?.destroy();
        return true;
    }

    const conv_res = convertAndScaleSurface(surface, args.pixel_format, args.has_gpu_device);
    const final_surface = conv_res.surface;
    const conversion_time_ms = conv_res.conversion_time_ms;

    if (cancel.isCanceled()) {
        if (final_surface) |surf| surf.destroy();
        return true;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());
        const final_raw_w: f32 = if (raw_w > 0.0) raw_w else orig_w;
        const final_raw_h: f32 = if (raw_h > 0.0) raw_h else orig_h;

        workers.event_queue.push(alloc, io, .{
            .image_decoded = .init(key, .{
                .surface = f_surf,
                .w = orig_w,
                .h = orig_h,
                .mime_type = mime_type,
                .size_bytes = file_size,
                .read_time_ms = read_time_ms,
                .decode_time_ms = decode_time_ms,
                .conversion_time_ms = conversion_time_ms,
                .orientation = orientation,
                .raw_metadata = RawMetadata.init(final_raw_w, final_raw_h),
                .cbz_decompress_time_ms = 0.0,
                .compressed_size_bytes = 0,
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
            .decode_failed = .init(key, .{}),
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
        context.wakeUpMainThread();
        return true;
    }
}

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
        context.wakeUpMainThread();
    }

    if (cancel.isCanceled()) return;

    var file_bytes: []u8 = undefined;
    var is_allocated = false;
    defer if (is_allocated) alloc.free(file_bytes);

    var read_n: usize = 0;
    var size_bytes: u64 = 0;
    var read_time_ms: f64 = 0.0;
    var cbz_decompress_time_ms: f64 = 0.0;
    var compressed_size_bytes: usize = 0;

    switch (media_entry) {
        .archive_entry => |arch| {
            const max_bytes: ?usize = if (args.thumb_only) 256 * 1024 else null;
            const dec_res = decompressCbzMediaEntry(
                alloc,
                io,
                arch,
                max_bytes,
            ) catch |err| {
                if (err == error.Canceled or cancel.isCanceled()) return;
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: failed to decompress CBZ entry '{s}' from '{s}': {}",
                    .{ arch.entry_name, arch.archive_path, err },
                );
                return;
            };
            file_bytes = dec_res.bytes;
            is_allocated = true;
            read_n = dec_res.bytes.len;
            size_bytes = dec_res.bytes.len;
            read_time_ms = dec_res.read_time_ms;
            cbz_decompress_time_ms = dec_res.decompress_time_ms;
            compressed_size_bytes = std.math.cast(
                usize,
                dec_res.compressed_size,
            ) orelse std.math.maxInt(usize);
        },
        .filesystem => |file_item| {
            if (core_fs.isRawFile(file_item.path)) {
                _ = decodeRawFile(args, file_item.path, false);
                return;
            }

            const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, file_item.path, .{}) catch |err| {
                if (err == error.Canceled or cancel.isCanceled()) return;
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: statFile failed for '{s}': {}",
                    .{ file_item.path, err },
                );
                return;
            };
            size_bytes = s.size;

            const start_read = sdl.timer.getTicksNs();
            var file = std.Io.Dir.openFile(
                std.Io.Dir.cwd(),
                io,
                file_item.path,
                .{},
            ) catch |err| {
                if (err == error.Canceled or cancel.isCanceled()) return;
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: openFile failed for '{s}': {}",
                    .{ file_item.path, err },
                );
                return;
            };
            defer file.close(io);

            const file_size: usize = @intCast(s.size);
            const target_read_size: usize = if (args.thumb_only)
                @min(file_size, 256 * 1024)
            else
                file_size;

            file_bytes = alloc.alloc(u8, target_read_size) catch |err| {
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: alloc failed for '{s}': {}",
                    .{ file_item.path, err },
                );
                return;
            };
            is_allocated = true;

            var r_buf: [4096]u8 = undefined;
            var reader = file.reader(io, &r_buf);
            reader.interface.readSliceAll(file_bytes) catch |err| {
                if (err == error.Canceled or cancel.isCanceled()) return;
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: readSliceAll failed for '{s}': {}",
                    .{ file_item.path, err },
                );
                return;
            };
            read_n = file_bytes.len;

            const end_read = sdl.timer.getTicksNs();
            read_time_ms = @as(f64, @floatFromInt(end_read - start_read)) / 1_000_000.0;
        },
        .pair => |pair| {
            if (args.thumb_only) {
                if (decodeRawFile(args, pair.raw_path, true)) {
                    return;
                }
            } else if (args.pair_target != .standalone_jpeg) {
                if (decodeRawFile(args, pair.raw_path, true)) {
                    return;
                }
            }

            const s = std.Io.Dir.statFile(
                std.Io.Dir.cwd(),
                io,
                pair.jpeg_path,
                .{},
            ) catch |err| {
                if (err == error.Canceled or cancel.isCanceled()) return;
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: statFile failed for companion JPEG '{s}': {}",
                    .{ pair.jpeg_path, err },
                );
                return;
            };
            size_bytes = s.size;

            const start_read = sdl.timer.getTicksNs();
            var file = std.Io.Dir.openFile(
                std.Io.Dir.cwd(),
                io,
                pair.jpeg_path,
                .{},
            ) catch |err| {
                if (err == error.Canceled or cancel.isCanceled()) return;
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: openFile failed for companion JPEG '{s}': {}",
                    .{ pair.jpeg_path, err },
                );
                return;
            };
            defer file.close(io);

            const file_size: usize = @intCast(s.size);
            const target_read_size: usize = if (args.thumb_only)
                @min(file_size, 256 * 1024)
            else
                file_size;

            file_bytes = alloc.alloc(u8, target_read_size) catch |err| {
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: alloc failed for companion JPEG '{s}': {}",
                    .{ pair.jpeg_path, err },
                );
                return;
            };
            is_allocated = true;

            var r_buf: [4096]u8 = undefined;
            var reader = file.reader(io, &r_buf);
            reader.interface.readSliceAll(file_bytes) catch |err| {
                if (err == error.Canceled or cancel.isCanceled()) return;
                failDecodeWorker(
                    workers,
                    alloc,
                    io,
                    key,
                    "decodeWorker: readSliceAll failed for companion JPEG '{s}': {}",
                    .{ pair.jpeg_path, err },
                );
                return;
            };
            read_n = file_bytes.len;

            const end_read = sdl.timer.getTicksNs();
            read_time_ms = @as(f64, @floatFromInt(end_read - start_read)) / 1_000_000.0;
        },
    }

    const header_n = @min(read_n, 256 * 1024);
    const header_buf = file_bytes[0..header_n];

    const path = switch (media_entry) {
        .filesystem => |f| f.path,
        .archive_entry => |a| a.entry_name,
        .pair => |p| p.jpeg_path,
    };
    const mime_type = image.detectMimeType(header_buf, path);
    const is_raw_archive = core_fs.isRawFile(path) or std.mem.startsWith(u8, mime_type, "image/x-");

    var raw_preview_slice: ?[]const u8 = null;
    var raw_sensor_dims: ?exif.JpegDimensions = null;
    var orientation: state_pkg.Orientation = .normal;

    if (is_raw_archive) {
        const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or
            (header_buf.len >= 8 and std.mem.startsWith(u8, header_buf, "FUJIFILM"));
        if (is_fuji) {
            if (exif.extractFujiRafPreviewLocation(header_buf)) |ploc| {
                if (ploc.length > 0 and ploc.length <= file_bytes.len and
                    ploc.file_offset <= file_bytes.len - ploc.length)
                {
                    const off: usize = @intCast(ploc.file_offset);
                    const len: usize = @intCast(ploc.length);
                    raw_preview_slice = file_bytes[off .. off + len];
                    orientation = exif.parseExifOrientation(raw_preview_slice.?) orelse .normal;
                }
            }
            if (exif.extractFujiRafMetadataLocation(header_buf)) |mloc| {
                if (mloc.length > 0 and mloc.length <= file_bytes.len and
                    mloc.file_offset <= file_bytes.len - mloc.length)
                {
                    const off: usize = @intCast(mloc.file_offset);
                    const len: usize = @intCast(mloc.length);
                    raw_sensor_dims = exif.parseFujiRafDimensions(file_bytes[off .. off + len]);
                }
            }
        } else {
            const raw_cands = exif.extractTiffRawPreviews(file_bytes);
            const target_prev = if (args.thumb_only)
                (raw_cands.thumbnail orelse raw_cands.medium orelse raw_cands.preview)
            else
                raw_cands.preview;
            if (target_prev) |ploc| {
                if (ploc.length > 0 and ploc.length <= file_bytes.len and
                    ploc.file_offset <= file_bytes.len - ploc.length)
                {
                    const off: usize = @intCast(ploc.file_offset);
                    const len: usize = @intCast(ploc.length);
                    raw_preview_slice = file_bytes[off .. off + len];
                }
            }
            raw_sensor_dims = exif.parseExifDimensions(file_bytes);
            orientation = exif.parseExifOrientation(file_bytes) orelse .normal;
        }
    } else {
        orientation = exif.parseExifOrientation(header_buf) orelse .normal;
    }

    if (orientation != .normal) {
        if (cancel.isCanceled()) return;
        workers.event_queue.push(alloc, io, .{
            .exif_orientation_parsed = .init(
                key,
                .{ .orientation = orientation },
            ),
        }) catch |err| {
            std.log.err("Failed to push EXIF orientation event: {}", .{err});
        };
        context.wakeUpMainThread();
    }

    const full_dims = image.parseImageDimensions(header_buf, mime_type);

    // Attempt fast EXIF thumbnail decoding for instant placeholder preview
    if (std.mem.eql(u8, mime_type, "image/jpeg") and
        args.has_gpu_device and
        args.pair_target == .adaptive)
    {
        var thumb_bytes_opt: ?[]const u8 = null;
        if (exif.extractJpegThumbnailLocation(header_buf)) |loc| {
            const max_thumb_size_bytes = 512 * 1024;
            const within_file_bounds = loc.length > 0 and
                loc.length <= max_thumb_size_bytes and
                loc.file_offset +| loc.length <= read_n;

            if (within_file_bounds) {
                const off: usize = @intCast(loc.file_offset);
                const len: usize = @intCast(loc.length);
                thumb_bytes_opt = file_bytes[off .. off + len];
                if (off + len <= header_buf.len) {
                    _ = workers.thumb_header_hits.fetchAdd(1, .monotonic);
                } else {
                    _ = workers.thumb_positional_hits.fetchAdd(1, .monotonic);
                }
            } else {
                _ = workers.thumb_misses.fetchAdd(1, .monotonic);
            }
        } else {
            _ = workers.thumb_misses.fetchAdd(1, .monotonic);
        }

        if (thumb_bytes_opt) |thumb_bytes| {
            if (cancel.isCanceled()) {
                return;
            }
            if (sdl.Surface.loadConstMemOpt(thumb_bytes)) |t_surf| {
                if (cancel.isCanceled()) {
                    t_surf.destroy();
                    return;
                }
                const full_w: f32 = if (full_dims) |d| d.w else 0.0;
                const full_h: f32 = if (full_dims) |d| d.h else 0.0;
                const dct_snapped = image.detectThumbnailDctPadding(t_surf, full_w, full_h);
                workers.event_queue.push(alloc, io, .{
                    .thumb_decoded = .init(key, .{
                        .surface = t_surf,
                        .w = @floatFromInt(t_surf.w()),
                        .h = @floatFromInt(t_surf.h()),
                        .full_w = full_w,
                        .full_h = full_h,
                        .orientation = orientation,
                        .thumb_only = args.thumb_only,
                        .dct_snapped = dct_snapped,
                    }),
                }) catch |err| {
                    std.log.err("Failed to push thumbnail decode event: {}", .{err});
                    t_surf.destroy();
                };
                context.wakeUpMainThread();

                if (args.thumb_only) {
                    return;
                }
            }
        }
    }

    if (args.thumb_only) {
        if (cancel.isCanceled()) return;
        const full_w: f32 = if (full_dims) |d| d.w else 0.0;
        const full_h: f32 = if (full_dims) |d| d.h else 0.0;
        workers.event_queue.push(alloc, io, .{
            .dimensions_probed = .init(key, .{
                .w = full_w,
                .h = full_h,
                .full_w = full_w,
                .full_h = full_h,
                .orientation = orientation,
                .thumb_only = true,
                .raw_metadata = if (is_raw_archive)
                    (if (raw_sensor_dims) |d|
                        RawMetadata.init(d.w, d.h)
                    else
                        RawMetadata.init(full_w, full_h))
                else
                    .none,
            }),
        }) catch |err| {
            std.log.err("Failed to push dimensions probed event: {}", .{err});
        };
        context.wakeUpMainThread();
        return;
    }

    if (cancel.isCanceled()) return;

    const bytes_to_decode = if (raw_preview_slice) |s| s else file_bytes[0..read_n];
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
            "decodeWorker: failed to load image '{s}': {s}",
            .{ path, sdl.getError() },
        );
        return;
    }

    if (cancel.isCanceled()) {
        if (surface) |surf| surf.destroy();
        return;
    }

    const conv_res = convertAndScaleSurface(surface, args.pixel_format, args.has_gpu_device);
    const final_surface = conv_res.surface;
    const conversion_time_ms = conv_res.conversion_time_ms;

    if (cancel.isCanceled()) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());
        const raw_metadata: RawMetadata = if (is_raw_archive)
            (if (raw_sensor_dims) |d|
                RawMetadata.init(d.w, d.h)
            else
                RawMetadata.init(orig_w, orig_h))
        else
            .none;

        workers.event_queue.push(alloc, io, .{
            .image_decoded = .init(key, .{
                .surface = f_surf,
                .w = orig_w,
                .h = orig_h,
                .mime_type = mime_type,
                .size_bytes = size_bytes,
                .read_time_ms = read_time_ms,
                .decode_time_ms = decode_time_ms,
                .conversion_time_ms = conversion_time_ms,
                .orientation = orientation,
                .raw_metadata = raw_metadata,
                .cbz_decompress_time_ms = cbz_decompress_time_ms,
                .compressed_size_bytes = compressed_size_bytes,
            }),
        }) catch |err| {
            std.log.err("Failed to push image decode event: {}", .{err});
            f_surf.destroy();
        };
        context.wakeUpMainThread();
    } else {
        workers.event_queue.push(alloc, io, .{
            .decode_failed = .init(key, .{}),
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
    }
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
        .key = .{ .index = 0, .generation = 1 },
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
                try std.testing.expectEqual(@as(f32, 1024.0), d.full_w);
                try std.testing.expectEqual(@as(f32, 682.0), d.full_h);
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
        .key = .{ .index = 0, .generation = 1 },
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
                try std.testing.expect(d.full_w > 0.0);
                try std.testing.expect(d.full_h > 0.0);
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
        .key = .{ .index = 0, .generation = 1 },
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
    const mock_path = try std.fmt.bufPrint(
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
            .key = .{ .index = 0, .generation = 1 },
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
                        state_pkg.Orientation.rotate_90,
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
            .key = .{ .index = 0, .generation = 1 },
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
                        state_pkg.Orientation.rotate_90,
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
    const mock_path = try std.fmt.bufPrint(
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
        .key = .{ .index = 0, .generation = 1 },
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
    const arw_path = try std.fmt.bufPrint(
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
            .key = .{ .index = 0, .generation = 1 },
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
                    try std.testing.expectEqual(@as(f32, 6240.0), t.full_w);
                    try std.testing.expectEqual(@as(f32, 4160.0), t.full_h);
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
            .key = .{ .index = 1, .generation = 1 },
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
                    try std.testing.expectEqual(@as(f32, 6240.0), t.full_w);
                    try std.testing.expectEqual(@as(f32, 4160.0), t.full_h);
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
    const raw_file = try std.fmt.bufPrint(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_pair.arw",
        .{tmp.sub_path},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    var current_gen: std.atomic.Value(usize) = .init(1);

    // 1. thumb_only decodes RAW thumbnail
    {
        const pair = state_pkg.FilePair{
            .raw_path = try allocator.dupe(u8, raw_file),
            .jpeg_path = try allocator.dupe(u8, jpg_file),
        };
        const entry = MediaEntry{ .pair = pair };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .index = 0, .generation = 1 },
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
        const pair = state_pkg.FilePair{
            .raw_path = try allocator.dupe(u8, raw_file),
            .jpeg_path = try allocator.dupe(u8, jpg_file),
        };
        const entry = MediaEntry{ .pair = pair };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .index = 1, .generation = 1 },
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
        const pair = state_pkg.FilePair{
            .raw_path = try allocator.dupe(u8, raw_file),
            .jpeg_path = try allocator.dupe(u8, jpg_file),
        };
        const entry = MediaEntry{ .pair = pair };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .index = 2, .generation = 1 },
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
    const pair = state_pkg.FilePair{
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
        .key = .{ .index = 0, .generation = 1 }, // stale generation -> canceled
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
