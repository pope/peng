const std = @import("std");
const sdl = @import("sdl");
const fs = @import("../fs.zig");
const image = @import("../core/image.zig");
const exif = @import("../core/exif.zig");
const context = @import("context.zig");
const root = @import("root.zig");
const WorkerManager = root.WorkerManager;

const CacheKey = image.CacheKey;

pub const DecodeArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    key: CacheKey,
    path: [:0]const u8,
    has_gpu_device: bool,
    pixel_format: u32,
    thumb_only: bool = false,
};

fn failDecodeWorker(workers: *WorkerManager, alloc: std.mem.Allocator, io: std.Io, key: CacheKey, path: []const u8, comptime fmt: []const u8, fmt_args: anytype) void {
    std.log.err(fmt, fmt_args);
    workers.event_queue.push(alloc, io, .{
        .decode_failed = .{ .key = key },
    }) catch |e| std.log.err("Failed to push decode_failed event for '{s}': {}", .{ path, e });
    context.wakeUpMainThread();
}

pub fn decodeWorker(args: *DecodeArgs) void {
    const workers = args.workers;
    const alloc = args.allocator;
    const io = args.io;
    const key = args.key;
    const path = args.path;
    defer {
        alloc.free(path);
        alloc.destroy(args);
        _ = workers.active_decode_threads.fetchSub(1, .release);
        _ = workers.active_threads.fetchSub(1, .release);
        context.wakeUpMainThread();
    }

    const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        failDecodeWorker(workers, alloc, io, key, path, "decodeWorker: statFile failed for '{s}': {}", .{ path, err });
        return;
    };
    const size_bytes = s.size;
    if (size_bytes == 0) {
        failDecodeWorker(workers, alloc, io, key, path, "decodeWorker: 0-byte file '{s}'", .{path});
        return;
    }

    const file_bytes = alloc.alloc(u8, size_bytes) catch |err| {
        failDecodeWorker(workers, alloc, io, key, path, "decodeWorker: failed to allocate {d} bytes for '{s}': {}", .{ size_bytes, path, err });
        return;
    };
    defer alloc.free(file_bytes);

    const start_read = sdl.timer.getTicksNs();
    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        failDecodeWorker(workers, alloc, io, key, path, "decodeWorker: openFile failed for '{s}': {}", .{ path, err });
        return;
    };
    defer file.close(io);

    var slices = [_][]u8{file_bytes};
    const read_n = file.readPositional(io, &slices, 0) catch |err| {
        failDecodeWorker(workers, alloc, io, key, path, "decodeWorker: readPositional failed for '{s}': {}", .{ path, err });
        return;
    };
    const end_read = sdl.timer.getTicksNs();
    const read_time_ms = @as(f64, @floatFromInt(end_read - start_read)) / 1_000_000.0;

    if (read_n == 0) {
        failDecodeWorker(workers, alloc, io, key, path, "decodeWorker: empty file or 0-byte read for '{s}'", .{path});
        return;
    }

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
        failDecodeWorker(workers, alloc, io, key, path, "decodeWorker: failed to load image '{s}': {s}", .{ path, sdl.getError() });
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
