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
    generation: usize,
    path: [:0]const u8,
};

pub fn decodeWorker(args: *DecodeArgs) void {
    const state = args.state;
    const index = args.index;
    const path = args.path;
    defer {
        const alloc = state.allocator;
        alloc.free(path);
        alloc.destroy(args);
        _ = state.active_decode_threads.fetchSub(1, .release);
        _ = state.active_threads.fetchSub(1, .release);
        context.wakeUpMainThread();
    }

    const exif_rot = exif.readJpegExifOrientation(state.io, path) orelse 0.0;
    if (exif_rot != 0.0) {
        state.event_queue.push(state.allocator, state.io, .{
            .exif_orientation_parsed = .{
                .index = index,
                .generation = args.generation,
                .orientation = exif_rot,
            },
        }) catch |err| std.log.err("Failed to push EXIF orientation event: {}", .{err});
        context.wakeUpMainThread();
    }

    if (!state.isJobValid(args.generation)) return;

    const mime_type = image.detectMimeType(state.io, path);

    if (!state.isJobValid(args.generation)) return;

    // Attempt fast EXIF thumbnail decoding for instant placeholder preview
    if (std.mem.eql(u8, mime_type, "image/jpeg") and state.gpu_device != null) {
        var header_buf: [65536]u8 = undefined;
        var thumb_file = std.Io.Dir.openFile(std.Io.Dir.cwd(), state.io, path, .{}) catch null;
        if (thumb_file) |*f| {
            defer f.close(state.io);
            var slices = [_][]u8{&header_buf};
            const n = f.readPositional(state.io, &slices, 0) catch 0;
            if (n > 0) {
                const full_dims = exif.readJpegDimensions(header_buf[0..n]);
                if (exif.extractJpegThumbnail(header_buf[0..n])) |thumb_bytes| {
                    if (sdl.Surface.loadConstMemOpt(thumb_bytes)) |t_surf| {
                        const full_w: f32 = if (full_dims) |d| d.w else 0.0;
                        const full_h: f32 = if (full_dims) |d| d.h else 0.0;
                        state.event_queue.push(state.allocator, state.io, .{
                            .thumb_decoded = .{
                                .index = index,
                                .generation = args.generation,
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
        }
    }

    if (!state.isJobValid(args.generation)) return;

    const start_decode = sdl.timer.getTicksNs();
    const surface = sdl.Surface.loadFilePtr(path.ptr);
    const end_decode = sdl.timer.getTicksNs();

    const decode_time_ms = @as(f64, @floatFromInt(end_decode - start_decode)) / 1_000_000.0;

    if (surface == null) {
        std.log.err("decodeWorker: failed to load image '{s}': {s}", .{ path, sdl.getError() });
    }

    if (!state.isJobValid(args.generation)) {
        if (surface) |surf| surf.destroy();
        return;
    }

    var final_surface = surface;
    var conversion_time_ms: f64 = 0.0;
    if (surface) |surf| {
        const pix_fmt = state.display.getPixelFormat();
        if (state.gpu_device == null and pix_fmt != sdl.PixelFormat.unknown and surf.format() != pix_fmt) {
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

    // Stat the file
    var size_bytes: u64 = 0;
    if (std.Io.Dir.statFile(std.Io.Dir.cwd(), state.io, path, .{})) |s| {
        size_bytes = s.size;
    } else |err| {
        std.log.debug("decodeWorker: statFile failed for '{s}': {any}", .{ path, err });
    }

    if (!state.isJobValid(args.generation)) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());

        state.event_queue.push(state.allocator, state.io, .{
            .image_decoded = .{
                .index = index,
                .generation = args.generation,
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
                .generation = args.generation,
            },
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
        context.wakeUpMainThread();
    }
}
