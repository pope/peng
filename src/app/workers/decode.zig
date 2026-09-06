const context = @import("context.zig");
const core_fs = @import("../core/fs.zig");
const exif = @import("../core/exif.zig");
const image = @import("../core/image.zig");
const root = @import("root.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const ArchiveMediaEntry = state_pkg.ArchiveMediaEntry;
const CacheKey = image.CacheKey;
const MediaEntry = state_pkg.MediaEntry;
const RawMetadata = state_pkg.RawMetadata;
const WorkerManager = root.WorkerManager;

/// Contextual arguments and configuration passed to background image decoding worker threads.
pub const DecodeArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    key: CacheKey,
    entry: MediaEntry,
    has_gpu_device: bool,
    pixel_format: u32,
    thumb_only: bool = false,
    current_generation: *const std.atomic.Value(usize),
};

fn failDecodeWorker(workers: *WorkerManager, alloc: std.mem.Allocator, io: std.Io, key: CacheKey, comptime fmt: []const u8, fmt_args: anytype) void {
    std.log.err(fmt, fmt_args);
    workers.event_queue.push(alloc, io, .{
        .decode_failed = .{ .key = key },
    }) catch |e| std.log.err("Failed to push decode_failed event: {}", .{e});
    context.wakeUpMainThread();
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
) !DecompressCbzResult {
    const start_read = sdl.timer.getTicksNs();
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, entry.archive_path, .{});
    defer file.close(io);

    // Sized to 128KB:
    // - In Zig 0.16.0, `std.compress.flate.Decompress` pulls from `f_reader.interface` bit-by-bit.
    //   A 4KB reader buffer forced ~188 `fileReadPositional` syscalls per 1.1MB compressed page.
    //   128KB drops syscalls to ~10 (19x reduction) and matches typical CPU L2 cache boundaries.
    // - Sized comfortably on the stack (< 192KB combined with `flate_buf`), using < 1.2% of the
    //   worker thread's 16MB default stack (`std.Thread.SpawnConfig.default_stack_size`), completely
    //   avoiding heap allocation, lock contention, and memory fragmentation across worker threads.
    var reader_buf: [128 * 1024]u8 = undefined;
    var f_reader = file.reader(io, &reader_buf);

    var data_offset: u64 = undefined;
    var uncompressed_size: u64 = undefined;
    var compressed_size: u64 = undefined;
    var comp_method_enum: std.zip.CompressionMethod = undefined;

    if (entry.file_offset) |offset| {
        try f_reader.seekTo(offset);
        const local_header = try f_reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig))
            return error.ZipBadFileOffset;

        data_offset = offset + @sizeOf(std.zip.LocalFileHeader) + local_header.filename_len + local_header.extra_len;
        uncompressed_size = entry.uncompressed_size orelse local_header.uncompressed_size;
        compressed_size = local_header.compressed_size;
        comp_method_enum = if (entry.compression_method) |cm| @enumFromInt(cm) else local_header.compression_method;
        try f_reader.seekTo(data_offset);
    } else {
        var iterator = try std.zip.Iterator.init(&f_reader);
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        var found = false;
        while (try iterator.next()) |zip_entry| {
            if (zip_entry.filename_len == 0) continue;
            _ = arena.reset(.retain_capacity);
            const temp_alloc = arena.allocator();

            try f_reader.seekTo(zip_entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
            const name = try temp_alloc.alloc(u8, zip_entry.filename_len);
            try f_reader.interface.readSliceAll(name);

            if (!std.mem.eql(u8, name, entry.entry_name)) continue;

            try f_reader.seekTo(zip_entry.file_offset);
            const local_header = try f_reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
            if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig))
                return error.ZipBadFileOffset;

            data_offset = zip_entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local_header.filename_len + local_header.extra_len;
            uncompressed_size = zip_entry.uncompressed_size;
            compressed_size = zip_entry.compressed_size;
            comp_method_enum = zip_entry.compression_method;
            try f_reader.seekTo(data_offset);
            found = true;
            break;
        }
        if (!found) return error.FileNotFound;
    }

    const end_read = sdl.timer.getTicksNs();
    const read_time_ms = @as(f64, @floatFromInt(end_read - start_read)) / 1_000_000.0;

    const out_buf = try alloc.alloc(u8, @intCast(uncompressed_size));
    errdefer alloc.free(out_buf);

    const start_dec = sdl.timer.getTicksNs();
    switch (comp_method_enum) {
        .store => {
            try f_reader.interface.readSliceAll(out_buf);
        },
        .deflate => {
            // Sized to 64KB (`flate.max_window_len = history_len * 2` where `history_len = 32768`):
            // Implements RFC 1951 Deflate's double-buffered LZ77 sliding history window.
            // Benchmarking confirmed that exceeding 64KB yields no additional syscall or latency gains.
            var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&f_reader.interface, .raw, &flate_buf);
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
                conversion_time_ms = @as(f64, @floatFromInt(end_convert - start_convert)) / 1_000_000.0;
                surf.destroy();
                final_surface = conv;
            } else {
                std.log.err("SDL_ConvertSurface failed: {s}", .{sdl.getError()});
            }
        } else if (has_gpu_device) {
            // For GPU rendering:
            // - 24-bit RGB/BGR surfaces are left as-is so the GPU compute unpack shader (`unpack_rgb.comp.glsl`)
            //   can unpack them directly into RGBA32 in VRAM with zero CPU overhead.
            // - Exotic formats (e.g. paletted 8-bit, grayscale) are converted here on the background worker thread
            //   to prevent main-thread CPU format conversion stalls during `uploadSurfaceToGpu`.
            const cur_fmt = surf.format();
            const is_32bit = switch (cur_fmt) {
                sdl.PixelFormat.rgba32, sdl.PixelFormat.bgra32, sdl.PixelFormat.xrgb8888, sdl.PixelFormat.xbgr8888, sdl.PixelFormat.rgbx8888, sdl.PixelFormat.bgrx8888 => true,
                else => false,
            };
            if (!is_32bit and cur_fmt != sdl.PixelFormat.rgb24 and cur_fmt != sdl.PixelFormat.bgr24) {
                const start_convert = sdl.timer.getTicksNs();
                if (surf.convert(sdl.PixelFormat.rgba32)) |conv| {
                    const end_convert = sdl.timer.getTicksNs();
                    conversion_time_ms = @as(f64, @floatFromInt(end_convert - start_convert)) / 1_000_000.0;
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

fn decodeRawFile(args: *DecodeArgs, path: []const u8) void {
    const workers = args.workers;
    const alloc = args.allocator;
    const io = args.io;
    const key = args.key;

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) return;

    const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: statFile failed for '{s}': {}", .{ path, err });
        return;
    };
    const file_size: u64 = s.size;

    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: openFile failed for '{s}': {}", .{ path, err });
        return;
    };
    defer file.close(io);

    // Read initial 128KB header via readPositional without allocating full file
    const header_target: usize = @intCast(@min(file_size, 128 * 1024));
    var header_buf: [128 * 1024]u8 = undefined;
    var h_slices = [_][]u8{header_buf[0..header_target]};
    const start_hdr_read = sdl.timer.getTicksNs();
    const header_n = file.readPositional(io, &h_slices, 0) catch |err| {
        if (err == error.Canceled or workers.exiting.load(.acquire)) return;
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: readPositional failed for '{s}': {}", .{ path, err });
        return;
    };
    const end_hdr_read = sdl.timer.getTicksNs();
    const header_read_time_ms = @as(f64, @floatFromInt(end_hdr_read - start_hdr_read)) / 1_000_000.0;
    const header_slice = header_buf[0..header_n];

    const mime_type = image.detectMimeType(header_slice, path);
    const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or (header_slice.len >= 8 and std.mem.startsWith(u8, header_slice, "FUJIFILM"));

    var prev_loc_opt: ?exif.ThumbnailLocation = null;
    var thumb_loc_opt: ?exif.ThumbnailLocation = null;
    var raw_sensor_dims: ?exif.JpegDimensions = null;
    var orientation: state_pkg.Orientation = .normal;

    if (is_fuji) {
        prev_loc_opt = exif.extractFujiRafPreviewLocation(header_slice);
        if (exif.extractFujiRafMetadataLocation(header_slice)) |meta_loc| {
            if (meta_loc.file_offset <= header_n -| meta_loc.length) {
                const end = meta_loc.file_offset + meta_loc.length;
                raw_sensor_dims = exif.parseFujiRafDimensions(header_slice[@intCast(meta_loc.file_offset)..@intCast(end)]);
            } else if (meta_loc.length > 0 and meta_loc.length <= 64 * 1024 and meta_loc.file_offset <= file_size -| meta_loc.length) {
                var m_buf: [64 * 1024]u8 = undefined;
                var m_slices = [_][]u8{m_buf[0..meta_loc.length]};
                const mn = file.readPositional(io, &m_slices, meta_loc.file_offset) catch 0;
                if (mn >= meta_loc.length) {
                    raw_sensor_dims = exif.parseFujiRafDimensions(m_buf[0..meta_loc.length]);
                }
            }
        }
        if (prev_loc_opt) |prev_loc| {
            const off: usize = @intCast(prev_loc.file_offset);
            if (off + 4096 <= header_n) {
                orientation = exif.parseExifOrientation(header_slice[off..header_n]) orelse .normal;
                if (exif.extractJpegThumbnailLocation(header_slice[off..header_n])) |j_thumb| {
                    thumb_loc_opt = .{
                        .file_offset = prev_loc.file_offset + j_thumb.file_offset,
                        .length = j_thumb.length,
                    };
                }
            } else {
                var p_hdr: [8192]u8 = undefined;
                var p_slices = [_][]u8{&p_hdr};
                const pn = file.readPositional(io, &p_slices, prev_loc.file_offset) catch 0;
                if (pn > 0) {
                    orientation = exif.parseExifOrientation(p_hdr[0..pn]) orelse .normal;
                    if (exif.extractJpegThumbnailLocation(p_hdr[0..pn])) |j_thumb| {
                        thumb_loc_opt = .{
                            .file_offset = prev_loc.file_offset + j_thumb.file_offset,
                            .length = j_thumb.length,
                        };
                    }
                }
            }
        }
    } else {
        const raw_cands = exif.extractTiffRawPreviews(header_slice);
        prev_loc_opt = raw_cands.preview;
        thumb_loc_opt = raw_cands.thumbnail;
        raw_sensor_dims = exif.parseExifDimensions(header_slice);
        orientation = exif.parseExifOrientation(header_slice) orelse .normal;
    }

    if (orientation != .normal) {
        workers.event_queue.push(alloc, io, .{
            .exif_orientation_parsed = .{
                .key = key,
                .orientation = orientation,
            },
        }) catch |err| std.log.err("Failed to push EXIF orientation event: {}", .{err});
        context.wakeUpMainThread();
    }

    const raw_w: f32 = if (raw_sensor_dims) |d| d.w else 0.0;
    const raw_h: f32 = if (raw_sensor_dims) |d| d.h else 0.0;

    // Fast scrubbing & instant placeholder thumbnail path
    if (args.has_gpu_device or args.thumb_only) {
        var thumb_surf: ?sdl.Surface = null;
        const max_thumb_size_bytes = 512 * 1024;

        if (thumb_loc_opt) |tloc| {
            if (tloc.length > 0 and tloc.length <= max_thumb_size_bytes and tloc.file_offset <= file_size -| tloc.length) {
                const t_off: usize = @intCast(tloc.file_offset);
                const t_len: usize = @intCast(tloc.length);
                if (t_off + t_len <= header_n) {
                    _ = workers.thumb_header_hits.fetchAdd(1, .monotonic);
                    thumb_surf = sdl.Surface.loadConstMemOpt(header_slice[t_off .. t_off + t_len]);
                } else {
                    const t_buf = alloc.alloc(u8, t_len) catch null;
                    if (t_buf) |tb| {
                        defer alloc.free(tb);
                        var ts_slices = [_][]u8{tb};
                        const tn = file.readPositional(io, &ts_slices, tloc.file_offset) catch 0;
                        if (tn == t_len) {
                            _ = workers.thumb_positional_hits.fetchAdd(1, .monotonic);
                            thumb_surf = sdl.Surface.loadConstMemOpt(tb);
                        } else {
                            _ = workers.thumb_misses.fetchAdd(1, .monotonic);
                        }
                    }
                }
            }
        }

        if (thumb_surf) |t_surf| {
            if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) {
                t_surf.destroy();
                return;
            }
            const full_w: f32 = if (raw_w > 0.0) raw_w else @floatFromInt(t_surf.w());
            const full_h: f32 = if (raw_h > 0.0) raw_h else @floatFromInt(t_surf.h());
            workers.event_queue.push(alloc, io, .{
                .thumb_decoded = .{
                    .key = key,
                    .surface = t_surf,
                    .w = @floatFromInt(t_surf.w()),
                    .h = @floatFromInt(t_surf.h()),
                    .full_w = full_w,
                    .full_h = full_h,
                    .orientation = orientation,
                    .thumb_only = args.thumb_only,
                    .raw_metadata = RawMetadata.init(raw_w, raw_h),
                },
            }) catch |err| {
                std.log.err("Failed to push thumbnail decode event: {}", .{err});
                t_surf.destroy();
            };
            context.wakeUpMainThread();

            if (args.thumb_only) {
                return;
            }
        } else if (args.thumb_only) {
            // If no small thumbnail available, emit surface = null
            // to immediately establish canvas aspect ratio on Frame 1 without decoding pixels
            if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) return;
            workers.event_queue.push(alloc, io, .{
                .thumb_decoded = .{
                    .key = key,
                    .surface = null,
                    .w = raw_w,
                    .h = raw_h,
                    .full_w = raw_w,
                    .full_h = raw_h,
                    .orientation = orientation,
                    .thumb_only = true,
                    .raw_metadata = RawMetadata.init(raw_w, raw_h),
                },
            }) catch |err| {
                std.log.err("Failed to push thumbnail decode event: {}", .{err});
            };
            context.wakeUpMainThread();
            return;
        }
    }

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) return;

    const prev_loc = prev_loc_opt orelse {
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: no embedded preview found in RAW file '{s}'", .{path});
        return;
    };

    if (prev_loc.length == 0 or prev_loc.file_offset > file_size -| prev_loc.length) {
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: invalid preview location in RAW file '{s}'", .{path});
        return;
    }

    const prev_bytes = alloc.alloc(u8, prev_loc.length) catch |err| {
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: alloc failed for preview in '{s}': {}", .{ path, err });
        return;
    };
    defer alloc.free(prev_bytes);

    const start_p_read = sdl.timer.getTicksNs();
    var total_read: usize = 0;
    while (total_read < prev_bytes.len) {
        var p_slices = [_][]u8{prev_bytes[total_read..]};
        const pn = file.readPositional(io, &p_slices, prev_loc.file_offset + total_read) catch |err| {
            if (err == error.Canceled or workers.exiting.load(.acquire)) return;
            failDecodeWorker(workers, alloc, io, key, "decodeWorker: readPositional failed for preview in '{s}': {}", .{ path, err });
            return;
        };
        if (pn == 0) break;
        total_read += pn;
    }
    const end_p_read = sdl.timer.getTicksNs();
    if (total_read < prev_bytes.len) {
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: incomplete preview read for '{s}'", .{path});
        return;
    }
    const read_time_ms = header_read_time_ms + (@as(f64, @floatFromInt(end_p_read - start_p_read)) / 1_000_000.0);

    if (is_fuji and orientation == .normal) {
        if (exif.parseExifOrientation(prev_bytes)) |o| {
            orientation = o;
            if (orientation != .normal) {
                workers.event_queue.push(alloc, io, .{
                    .exif_orientation_parsed = .{
                        .key = key,
                        .orientation = orientation,
                    },
                }) catch |err| std.log.err("Failed to push EXIF orientation event: {}", .{err});
                context.wakeUpMainThread();
            }
        }
    }

    const start_dec = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadConstMemOpt(prev_bytes);
    const end_dec = sdl.timer.getTicksNs();
    const decode_time_ms = @as(f64, @floatFromInt(end_dec - start_dec)) / 1_000_000.0;

    if (surface == null) {
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: failed to load RAW preview surface '{s}': {s}", .{ path, sdl.getError() });
        return;
    }

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) {
        surface.?.destroy();
        return;
    }

    const conv_res = convertAndScaleSurface(surface, args.pixel_format, args.has_gpu_device);
    const final_surface = conv_res.surface;
    const conversion_time_ms = conv_res.conversion_time_ms;

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());
        const final_raw_w: f32 = if (raw_w > 0.0) raw_w else orig_w;
        const final_raw_h: f32 = if (raw_h > 0.0) raw_h else orig_h;

        workers.event_queue.push(alloc, io, .{
            .image_decoded = .{
                .key = key,
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
            },
        }) catch |err| {
            std.log.err("Failed to push image decode event: {}", .{err});
            f_surf.destroy();
        };
        context.wakeUpMainThread();
    } else {
        workers.event_queue.push(alloc, io, .{
            .decode_failed = .{
                .key = key,
            },
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
        context.wakeUpMainThread();
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
    defer {
        media_entry.deinit(alloc);
        alloc.destroy(args);
        _ = workers.active_decode_threads.fetchSub(1, .release);
        _ = workers.active_threads.fetchSub(1, .release);
        context.wakeUpMainThread();
    }

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) return;

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
            const dec_res = decompressCbzMediaEntry(alloc, io, arch) catch |err| {
                failDecodeWorker(workers, alloc, io, key, "decodeWorker: failed to decompress CBZ entry '{s}' from '{s}': {}", .{ arch.entry_name, arch.archive_path, err });
                return;
            };
            file_bytes = dec_res.bytes;
            is_allocated = true;
            read_n = dec_res.bytes.len;
            size_bytes = dec_res.bytes.len;
            read_time_ms = dec_res.read_time_ms;
            cbz_decompress_time_ms = dec_res.decompress_time_ms;
            compressed_size_bytes = @intCast(dec_res.compressed_size);
        },
        .filesystem => |file_item| {
            if (core_fs.isRawFile(file_item.path)) {
                decodeRawFile(args, file_item.path);
                return;
            }

            const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, file_item.path, .{}) catch |err| {
                failDecodeWorker(workers, alloc, io, key, "decodeWorker: statFile failed for '{s}': {}", .{ file_item.path, err });
                return;
            };
            size_bytes = s.size;

            const start_read = sdl.timer.getTicksNs();
            var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, file_item.path, .{}) catch |err| {
                failDecodeWorker(workers, alloc, io, key, "decodeWorker: openFile failed for '{s}': {}", .{ file_item.path, err });
                return;
            };
            defer file.close(io);

            const file_size: usize = @intCast(s.size);
            const target_read_size: usize = if (args.thumb_only) @min(file_size, 128 * 1024) else file_size;

            file_bytes = alloc.alloc(u8, target_read_size) catch |err| {
                failDecodeWorker(workers, alloc, io, key, "decodeWorker: alloc failed for '{s}': {}", .{ file_item.path, err });
                return;
            };
            is_allocated = true;

            var r_buf: [4096]u8 = undefined;
            var reader = file.reader(io, &r_buf);
            reader.interface.readSliceAll(file_bytes) catch |err| {
                if (err == error.Canceled or workers.exiting.load(.acquire)) return;
                failDecodeWorker(workers, alloc, io, key, "decodeWorker: readSliceAll failed for '{s}': {}", .{ file_item.path, err });
                return;
            };
            read_n = file_bytes.len;

            const end_read = sdl.timer.getTicksNs();
            read_time_ms = @as(f64, @floatFromInt(end_read - start_read)) / 1_000_000.0;
        },
    }

    const header_n = @min(read_n, 128 * 1024);
    const header_buf = file_bytes[0..header_n];

    const path = media_entry.getPath();
    const mime_type = image.detectMimeType(header_buf, path);
    const is_raw_archive = core_fs.isRawFile(path) or std.mem.startsWith(u8, mime_type, "image/x-");

    var raw_preview_slice: ?[]const u8 = null;
    var raw_sensor_dims: ?exif.JpegDimensions = null;
    var orientation: state_pkg.Orientation = .normal;

    if (is_raw_archive) {
        const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or (header_buf.len >= 8 and std.mem.startsWith(u8, header_buf, "FUJIFILM"));
        if (is_fuji) {
            if (exif.extractFujiRafPreviewLocation(header_buf)) |ploc| {
                const off: usize = @intCast(ploc.file_offset);
                const len: usize = @intCast(ploc.length);
                if (off + len <= file_bytes.len) {
                    raw_preview_slice = file_bytes[off .. off + len];
                    orientation = exif.parseExifOrientation(raw_preview_slice.?) orelse .normal;
                }
            }
            if (exif.extractFujiRafMetadataLocation(header_buf)) |mloc| {
                const off: usize = @intCast(mloc.file_offset);
                const len: usize = @intCast(mloc.length);
                if (off + len <= file_bytes.len) {
                    raw_sensor_dims = exif.parseFujiRafDimensions(file_bytes[off .. off + len]);
                }
            }
        } else {
            const raw_cands = exif.extractTiffRawPreviews(header_buf);
            if (raw_cands.preview) |ploc| {
                const off: usize = @intCast(ploc.file_offset);
                const len: usize = @intCast(ploc.length);
                if (off + len <= file_bytes.len) {
                    raw_preview_slice = file_bytes[off .. off + len];
                }
            }
            raw_sensor_dims = exif.parseExifDimensions(header_buf);
            orientation = exif.parseExifOrientation(header_buf) orelse .normal;
        }
    } else {
        orientation = exif.parseExifOrientation(header_buf) orelse .normal;
    }

    if (orientation != .normal) {
        workers.event_queue.push(alloc, io, .{
            .exif_orientation_parsed = .{
                .key = key,
                .orientation = orientation,
            },
        }) catch |err| std.log.err("Failed to push EXIF orientation event: {}", .{err});
        context.wakeUpMainThread();
    }

    const full_dims = image.parseImageDimensions(header_buf, mime_type);

    // Attempt fast EXIF thumbnail decoding for instant placeholder preview
    if (std.mem.eql(u8, mime_type, "image/jpeg") and args.has_gpu_device) {
        var thumb_bytes_opt: ?[]const u8 = exif.extractJpegThumbnail(header_buf);

        if (thumb_bytes_opt != null) {
            _ = workers.thumb_header_hits.fetchAdd(1, .monotonic);
        } else if (exif.extractJpegThumbnailLocation(header_buf)) |loc| {
            const max_thumb_size_bytes = 512 * 1024; // 512 KiB sanity limit for EXIF thumbnails
            const within_file_bounds = (loc.file_offset <= read_n -| loc.length);

            if (loc.length > 0 and loc.length <= max_thumb_size_bytes and within_file_bounds) {
                const off = @as(usize, loc.file_offset);
                const len = @as(usize, loc.length);
                thumb_bytes_opt = file_bytes[off .. off + len];
                _ = workers.thumb_positional_hits.fetchAdd(1, .monotonic);
            } else {
                _ = workers.thumb_misses.fetchAdd(1, .monotonic);
            }
        } else {
            _ = workers.thumb_misses.fetchAdd(1, .monotonic);
        }

        if (thumb_bytes_opt) |thumb_bytes| {
            if (sdl.Surface.loadConstMemOpt(thumb_bytes)) |t_surf| {
                const full_w: f32 = if (full_dims) |d| d.w else 0.0;
                const full_h: f32 = if (full_dims) |d| d.h else 0.0;
                workers.event_queue.push(alloc, io, .{
                    .thumb_decoded = .{
                        .key = key,
                        .surface = t_surf,
                        .w = @floatFromInt(t_surf.w()),
                        .h = @floatFromInt(t_surf.h()),
                        .full_w = full_w,
                        .full_h = full_h,
                        .orientation = orientation,
                        .thumb_only = args.thumb_only,
                    },
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
        const full_w: f32 = if (full_dims) |d| d.w else 0.0;
        const full_h: f32 = if (full_dims) |d| d.h else 0.0;
        workers.event_queue.push(alloc, io, .{
            .thumb_decoded = .{
                .key = key,
                .surface = null,
                .w = full_w,
                .h = full_h,
                .full_w = full_w,
                .full_h = full_h,
                .orientation = orientation,
                .thumb_only = true,
                .raw_metadata = if (is_raw_archive) (if (raw_sensor_dims) |d| RawMetadata.init(d.w, d.h) else RawMetadata.init(full_w, full_h)) else .none,
            },
        }) catch |err| {
            std.log.err("Failed to push thumbnail decode event: {}", .{err});
        };
        context.wakeUpMainThread();
        return;
    }

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) return;

    const bytes_to_decode = if (raw_preview_slice) |s| s else file_bytes[0..read_n];
    const start_decode = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadConstMemOpt(bytes_to_decode);
    const end_decode = sdl.timer.getTicksNs();

    const decode_time_ms = @as(f64, @floatFromInt(end_decode - start_decode)) / 1_000_000.0;

    if (surface == null) {
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: failed to load image '{s}': {s}", .{ path, sdl.getError() });
        return;
    }

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) {
        if (surface) |surf| surf.destroy();
        return;
    }

    const conv_res = convertAndScaleSurface(surface, args.pixel_format, args.has_gpu_device);
    const final_surface = conv_res.surface;
    const conversion_time_ms = conv_res.conversion_time_ms;

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());
        const raw_metadata: RawMetadata = if (is_raw_archive) (if (raw_sensor_dims) |d| RawMetadata.init(d.w, d.h) else RawMetadata.init(orig_w, orig_h)) else .none;

        workers.event_queue.push(alloc, io, .{
            .image_decoded = .{
                .key = key,
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
            },
        }) catch |err| {
            std.log.err("Failed to push image decode event: {}", .{err});
            f_surf.destroy();
        };
        context.wakeUpMainThread();
    } else {
        workers.event_queue.push(alloc, io, .{
            .decode_failed = .{
                .key = key,
            },
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
        context.wakeUpMainThread();
    }
}

test "decodeWorker - thumb_only does not do full decompression on JPEG" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.drainAndQuiesce(io);

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

    var thumb_decoded_seen = false;
    var image_decoded_seen = false;

    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .thumb_decoded => |t| {
                thumb_decoded_seen = true;
                try std.testing.expect(t.thumb_only);
                try std.testing.expectEqual(@as(f32, 1024.0), t.full_w);
                try std.testing.expectEqual(@as(f32, 682.0), t.full_h);
                try std.testing.expect(t.surface == null);
            },
            .image_decoded => {
                image_decoded_seen = true;
            },
            else => {},
        }
    }

    try std.testing.expect(thumb_decoded_seen);
    try std.testing.expect(!image_decoded_seen);
}

test "decodeWorker - thumb_only does not do full decompression on PNG" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.drainAndQuiesce(io);

    const path = try allocator.dupe(u8, "testfiles/golden-screenshots/test_0_init.png");
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

    var thumb_decoded_seen = false;
    var image_decoded_seen = false;

    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .thumb_decoded => |t| {
                thumb_decoded_seen = true;
                try std.testing.expect(t.thumb_only);
                try std.testing.expect(t.full_w > 0.0);
                try std.testing.expect(t.full_h > 0.0);
                try std.testing.expect(t.surface == null);
            },
            .image_decoded => {
                image_decoded_seen = true;
            },
            else => {},
        }
    }

    try std.testing.expect(thumb_decoded_seen);
    try std.testing.expect(!image_decoded_seen);
}

test "decodeWorker - prunes early when current_generation does not match key.generation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.drainAndQuiesce(io);

    const path = try allocator.dupe(u8, "testfiles/golden-screenshots/test_0_init.png");
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

test "decompressCbzMediaEntry - decompresses zip deflate entry with 128KB buffer and valid compressed_size" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const cbz_path = "5 Centimeters per Second.cbz";
    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, cbz_path, .{}) catch return;
    file.close(io);

    const entry = ArchiveMediaEntry{
        .archive_path = cbz_path,
        .entry_name = "5 Centimeters per Second/page000.jpeg",
    };

    const res = try decompressCbzMediaEntry(allocator, io, entry);
    defer allocator.free(res.bytes);

    try std.testing.expect(res.bytes.len == 230405);
    try std.testing.expect(res.compressed_size == 228667);
    try std.testing.expect(res.compressed_size != res.bytes.len);
    try std.testing.expect(res.decompress_time_ms >= 0.0);
}

test "decodeWorker - Sony ARW range reading and preview extraction" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Read real JPEG to embed as preview
    var real_jpg = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, "testfiles/images/000_0_1024x682.jpg", .{});
    defer real_jpg.close(io);
    const jpg_stat = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, "testfiles/images/000_0_1024x682.jpg", .{});
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

    // Write mock file
    const mock_path = "testfiles/current-run/mock_test.arw";
    var mock_file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, mock_path, .{});
    var wr_slices = [_][]const u8{tiff_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, mock_path) catch {};

    // Test 1: Full decode (thumb_only = false)
    {
        var workers = WorkerManager{};
        defer workers.drainAndQuiesce(io);

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
                .image_decoded => |img_payload| {
                    image_decoded_seen = true;
                    try std.testing.expect(img_payload.raw_metadata.isRaw());
                    const s_dims = img_payload.raw_metadata.getSensorDims().?;
                    try std.testing.expectEqual(@as(f32, 6000.0), s_dims.w);
                    try std.testing.expectEqual(@as(f32, 4000.0), s_dims.h);
                    try std.testing.expectEqual(state_pkg.Orientation.rotate_90, img_payload.orientation);
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
        defer workers.drainAndQuiesce(io);

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
                .thumb_decoded => |t_payload| {
                    thumb_decoded_seen = true;
                    try std.testing.expect(t_payload.raw_metadata.isRaw());
                    try std.testing.expect(t_payload.thumb_only);
                    const ts_dims = t_payload.raw_metadata.getSensorDims().?;
                    try std.testing.expectEqual(@as(f32, 6000.0), ts_dims.w);
                    try std.testing.expectEqual(@as(f32, 4000.0), ts_dims.h);
                    try std.testing.expectEqual(state_pkg.Orientation.rotate_90, t_payload.orientation);
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
    var real_jpg = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, "testfiles/images/000_0_1024x682.jpg", .{});
    defer real_jpg.close(io);
    const jpg_stat = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, "testfiles/images/000_0_1024x682.jpg", .{});
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

    const mock_path = "testfiles/current-run/mock_test.raf";
    var mock_file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, mock_path, .{});
    var wr_slices = [_][]const u8{raf_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, mock_path) catch {};

    // Test full decode
    var workers = WorkerManager{};
    defer workers.drainAndQuiesce(io);

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
            .image_decoded => |img_payload| {
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
