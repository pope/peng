const std = @import("std");
const sdl = @import("sdl");
const core_fs = @import("../core/fs.zig");
const image = @import("../core/image.zig");
const exif = @import("../core/exif.zig");
const context = @import("context.zig");
const root = @import("root.zig");
const WorkerManager = root.WorkerManager;

const CacheKey = image.CacheKey;

const MediaEntry = @import("state").MediaEntry;

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

const ArchiveMediaEntry = @import("state").ArchiveMediaEntry;

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

    var file_bytes: []u8 = undefined;
    var is_allocated = false;
    defer if (is_allocated) alloc.free(file_bytes);

    var read_n: usize = 0;
    var size_bytes: u64 = 0;
    var read_time_ms: f64 = 0.0;
    var cbz_decompress_time_ms: f64 = 0.0;
    var compressed_size_bytes: usize = 0;

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) return;

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
    const full_dims = image.parseImageDimensions(header_buf, mime_type);

    // Attempt fast EXIF thumbnail decoding for instant placeholder preview
    if (std.mem.eql(u8, mime_type, "image/jpeg") and args.has_gpu_device) {
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
                .exif_orientation = exif_rot,
                .thumb_only = true,
            },
        }) catch |err| {
            std.log.err("Failed to push thumbnail decode event: {}", .{err});
        };
        context.wakeUpMainThread();
        return;
    }

    if (workers.exiting.load(.acquire) or args.current_generation.load(.acquire) != key.generation) return;

    const start_decode = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadConstMemOpt(file_bytes[0..read_n]);
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
        } else if (args.has_gpu_device) {
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

test "decodeWorker - thumb_only does not do full decompression on JPEG" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.group.wait(io);

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
    defer workers.group.wait(io);

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
    defer workers.group.wait(io);

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
