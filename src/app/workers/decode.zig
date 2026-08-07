const std = @import("std");
const sdl = @import("sdl");
const fs = @import("../fs.zig");
const core_fs = @import("../core/fs.zig");
const image = @import("../core/image.zig");
const exif = @import("../core/exif.zig");
const context = @import("context.zig");
const root = @import("root.zig");
const WorkerManager = root.WorkerManager;

const CacheKey = image.CacheKey;

const MediaEntry = @import("state").MediaEntry;

pub const DecodeArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    key: CacheKey,
    entry: MediaEntry,
    has_gpu_device: bool,
    pixel_format: u32,
    thumb_only: bool = false,
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

const ArchiveMediaEntry = @import("state").ArchiveMediaEntry;

fn decompressCbzMediaEntry(
    alloc: std.mem.Allocator,
    io: std.Io,
    entry: ArchiveMediaEntry,
) !DecompressCbzResult {
    const start_read = sdl.timer.getTicksNs();
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, entry.archive_path, .{});
    defer file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var f_reader = file.reader(io, &reader_buf);

    var data_offset: u64 = undefined;
    var uncompressed_size: u64 = undefined;
    var comp_method_enum: std.zip.CompressionMethod = undefined;

    if (entry.file_offset) |offset| {
        try f_reader.seekTo(offset);
        const local_header = try f_reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig))
            return error.ZipBadFileOffset;

        data_offset = offset + @sizeOf(std.zip.LocalFileHeader) + local_header.filename_len + local_header.extra_len;
        uncompressed_size = entry.uncompressed_size orelse local_header.uncompressed_size;
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
        .compressed_size = uncompressed_size,
    };
}

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

    var file_bytes: []u8 = undefined;
    var is_allocated = false;
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
            size_bytes = dec_res.bytes.len;
            read_time_ms = dec_res.read_time_ms;
            cbz_decompress_time_ms = dec_res.decompress_time_ms;
            compressed_size_bytes = @intCast(dec_res.compressed_size);
        },
        .filesystem => |file_item| {
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
            file_bytes = alloc.alloc(u8, file_size) catch |err| {
                failDecodeWorker(workers, alloc, io, key, "decodeWorker: alloc failed for '{s}': {}", .{ file_item.path, err });
                return;
            };
            is_allocated = true;

            var r_buf: [4096]u8 = undefined;
            var reader = file.reader(io, &r_buf);
            reader.interface.readSliceAll(file_bytes) catch |err| {
                alloc.free(file_bytes);
                failDecodeWorker(workers, alloc, io, key, "decodeWorker: readSliceAll failed for '{s}': {}", .{ file_item.path, err });
                return;
            };
            const end_read = sdl.timer.getTicksNs();
            read_time_ms = @as(f64, @floatFromInt(end_read - start_read)) / 1_000_000.0;
        },
    }
    defer if (is_allocated) alloc.free(file_bytes);

    const read_n = file_bytes.len;

    const header_n = @min(read_n, 65536);
    const header_buf = file_bytes[0..header_n];

    const exif_rot = exif.parseExifOrientation(header_buf) orelse 0.0;
    if (exif_rot != 0.0) {
        workers.event_queue.push(alloc, io, .{
            .exif_orientation_parsed = .{
                .key = key,
                .orientation = exif_rot,
            },
        }) catch |err| std.log.err("Failed to push EXIF orientation event: {}", .{err});
        context.wakeUpMainThread();
    }

    const path = media_entry.getPath();
    const mime_type = image.detectMimeType(header_buf, path);

    // Attempt fast EXIF thumbnail decoding for instant placeholder preview
    if (std.mem.eql(u8, mime_type, "image/jpeg") and args.has_gpu_device) {
        const full_dims = exif.readJpegDimensions(header_buf);
        var thumb_bytes_opt: ?[]const u8 = exif.extractJpegThumbnail(header_buf);

        if (thumb_bytes_opt != null) {
            _ = workers.thumb_header_hits.fetchAdd(1, .monotonic);
        } else if (exif.extractJpegThumbnailLocation(header_buf)) |loc| {
            const max_thumb_size_bytes = 512 * 1024; // 512 KiB sanity limit for EXIF thumbnails
            const within_file_bounds = (loc.file_offset + loc.length <= read_n);

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
                        .exif_orientation = exif_rot,
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

    if (workers.exiting.load(.acquire)) return;

    const start_decode = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadConstMemOpt(file_bytes[0..read_n]);
    const end_decode = sdl.timer.getTicksNs();

    const decode_time_ms = @as(f64, @floatFromInt(end_decode - start_decode)) / 1_000_000.0;

    if (surface == null) {
        failDecodeWorker(workers, alloc, io, key, "decodeWorker: failed to load image '{s}': {s}", .{ path, sdl.getError() });
        return;
    }

    if (workers.exiting.load(.acquire)) {
        if (surface) |surf| surf.destroy();
        return;
    }

    var final_surface = surface;
    var conversion_time_ms: f64 = 0.0;
    if (surface) |surf| {
        const pix_fmt = args.pixel_format;
        if (!args.has_gpu_device and pix_fmt != sdl.PixelFormat.unknown and surf.format() != pix_fmt) {
            const start_convert = sdl.timer.getTicksNs();
            if (surf.convert(pix_fmt)) |conv| {
                const end_convert = sdl.timer.getTicksNs();
                conversion_time_ms = @as(f64, @floatFromInt(end_convert - start_convert)) / 1_000_000.0;
                surf.destroy();
                final_surface = conv;
            } else {
                std.log.err("SDL_ConvertSurface failed: {s}", .{sdl.getError()});
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

    if (workers.exiting.load(.acquire)) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());

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
                .exif_orientation = exif_rot,
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
