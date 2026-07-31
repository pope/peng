const std = @import("std");
const sdl = @import("sdl");
const app_state = @import("../state.zig");
const ViewerState = app_state.ViewerState;
const fs = @import("../fs.zig");
const image = @import("../image.zig");
const exif = @import("../exif.zig");
const context = @import("context.zig");

pub const DecodeArgs = struct {
    state: *ViewerState,
    index: usize,
    path: [:0]const u8,
    has_gpu_device: bool,
    pixel_format: u32,
};

fn failDecodeWorker(state: *ViewerState, index: usize, path: []const u8, comptime fmt: []const u8, fmt_args: anytype) void {
    std.log.err(fmt, fmt_args);
    state.event_queue.push(state.allocator, state.io, .{
        .decode_failed = .{ .index = index },
    }) catch |e| std.log.err("Failed to push decode_failed event for '{s}': {}", .{ path, e });
    context.wakeUpMainThread();
}

pub fn decodeWorker(args: *DecodeArgs) void {
    const state = args.state;
    const index = args.index;
    const path = args.path;
    defer {
        const alloc = state.allocator;
        alloc.free(path);
        alloc.destroy(args);
        _ = state.workers.active_decode_threads.fetchSub(1, .release);
        _ = state.workers.active_threads.fetchSub(1, .release);
        context.wakeUpMainThread();
    }

    const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), state.io, path, .{}) catch |err| {
        failDecodeWorker(state, index, path, "decodeWorker: statFile failed for '{s}': {}", .{ path, err });
        return;
    };
    const size_bytes = s.size;

    var header_buf: [65536]u8 = undefined;
    var exif_rot: f32 = 0.0;
    var mime_type: []const u8 = "unknown";

    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), state.io, path, .{}) catch |err| {
        failDecodeWorker(state, index, path, "decodeWorker: openFile failed for '{s}': {}", .{ path, err });
        return;
    };
    defer file.close(state.io);

    var slices = [_][]u8{&header_buf};
    const n = file.readPositional(state.io, &slices, 0) catch |err| {
        failDecodeWorker(state, index, path, "decodeWorker: initial readPositional failed for '{s}': {}", .{ path, err });
        return;
    };

    if (n == 0) {
        failDecodeWorker(state, index, path, "decodeWorker: empty file or 0-byte header read for '{s}'", .{path});
        return;
    }

    exif_rot = exif.parseExifOrientation(header_buf[0..n]) orelse 0.0;
    if (exif_rot != 0.0) {
        state.event_queue.push(state.allocator, state.io, .{
            .exif_orientation_parsed = .{
                .index = index,
                .orientation = exif_rot,
            },
        }) catch |err| std.log.err("Failed to push EXIF orientation event: {}", .{err});
        context.wakeUpMainThread();
    }

    mime_type = image.detectMimeType(header_buf[0..n], path);

    // Attempt fast EXIF thumbnail decoding for instant placeholder preview
    if (std.mem.eql(u8, mime_type, "image/jpeg") and args.has_gpu_device) {
        const full_dims = exif.readJpegDimensions(header_buf[0..n]);
        var thumb_bytes_opt: ?[]const u8 = exif.extractJpegThumbnail(header_buf[0..n]);
        var heap_thumb_buf: ?[]u8 = null;
        defer if (heap_thumb_buf) |b| state.allocator.free(b);

        if (thumb_bytes_opt != null) {
            _ = state.thumb_header_hits.fetchAdd(1, .monotonic);
        } else if (exif.extractJpegThumbnailLocation(header_buf[0..n])) |loc| {
            const max_thumb_size_bytes = 512 * 1024; // 512 KiB sanity limit for EXIF thumbnails
            const within_file_bounds = (size_bytes == 0 or (loc.file_offset + loc.length <= size_bytes));

            if (loc.length > 0 and loc.length <= max_thumb_size_bytes and within_file_bounds) {
                if (state.allocator.alloc(u8, loc.length)) |t_buf| {
                    heap_thumb_buf = t_buf;
                    var t_slices = [_][]u8{t_buf};
                    const read_n = file.readPositional(state.io, &t_slices, loc.file_offset) catch |err| blk: {
                        std.log.warn("decodeWorker: readPositional for thumbnail failed at offset {d} (len {d}): {}", .{ loc.file_offset, loc.length, err });
                        break :blk 0;
                    };
                    if (read_n == loc.length) {
                        thumb_bytes_opt = t_buf;
                        _ = state.thumb_positional_hits.fetchAdd(1, .monotonic);
                    } else {
                        std.log.warn("decodeWorker: incomplete thumbnail read at offset {d}: expected {d} bytes, got {d}", .{ loc.file_offset, loc.length, read_n });
                        _ = state.thumb_misses.fetchAdd(1, .monotonic);
                    }
                } else |err| {
                    std.log.warn("decodeWorker: failed to allocate {d} bytes for thumbnail: {}", .{ loc.length, err });
                    _ = state.thumb_misses.fetchAdd(1, .monotonic);
                }
            } else {
                _ = state.thumb_misses.fetchAdd(1, .monotonic);
            }
        } else {
            _ = state.thumb_misses.fetchAdd(1, .monotonic);
        }

        if (thumb_bytes_opt) |thumb_bytes| {
            if (sdl.Surface.loadConstMemOpt(thumb_bytes)) |t_surf| {
                const full_w: f32 = if (full_dims) |d| d.w else 0.0;
                const full_h: f32 = if (full_dims) |d| d.h else 0.0;
                state.event_queue.push(state.allocator, state.io, .{
                    .thumb_decoded = .{
                        .index = index,
                        .surface = t_surf,
                        .w = @floatFromInt(t_surf.w()),
                        .h = @floatFromInt(t_surf.h()),
                        .full_w = full_w,
                        .full_h = full_h,
                        .exif_orientation = exif_rot,
                    },
                }) catch |err| {
                    std.log.err("Failed to push thumbnail decode event: {}", .{err});
                    t_surf.destroy();
                };
                context.wakeUpMainThread();
            }
        }
    }

    if (state.exiting.load(.acquire)) return;

    const start_decode = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadFilePtr(path.ptr);
    const end_decode = sdl.timer.getTicksNs();

    const decode_time_ms = @as(f64, @floatFromInt(end_decode - start_decode)) / 1_000_000.0;

    if (surface == null) {
        failDecodeWorker(state, index, path, "decodeWorker: failed to load image '{s}': {s}", .{ path, sdl.getError() });
        return;
    }

    if (state.exiting.load(.acquire)) {
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

    if (state.exiting.load(.acquire)) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());

        state.event_queue.push(state.allocator, state.io, .{
            .image_decoded = .{
                .index = index,
                .surface = f_surf,
                .w = orig_w,
                .h = orig_h,
                .mime_type = mime_type,
                .size_bytes = size_bytes,
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
        state.event_queue.push(state.allocator, state.io, .{
            .decode_failed = .{
                .index = index,
            },
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
        context.wakeUpMainThread();
    }
}
