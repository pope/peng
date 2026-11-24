const app_config = @import("config");
const core = @import("core");
const std = @import("std");
const termgfx = @import("termgfx");
const thumbcache = @import("thumbcache");

const NoCancel = core.preview.NoCancel;
const renderPreviewRgbaFile = core.preview.renderPreviewRgbaFile;
const renderPreviewSurface = core.preview.renderPreviewSurface;
const ThumbCacheConfig = thumbcache.ThumbCacheConfig;

/// Standalone CLI entry point for rendering a terminal image preview
/// (Kitty Graphics Protocol `t=t`, VT340 Sixel, or iTerm2 Inline Images)
/// without a GUI window, Vulkan device, or server.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var parsed = app_config.cli.parsePreviewArgs(init, gpa) catch {
        std.process.exit(1);
    };
    defer parsed.deinit(gpa);

    if (parsed.help) {
        app_config.cli.printPreviewHelp(io);
        return;
    }

    const target_path = parsed.path orelse {
        std.log.err("Missing image path. Use --help for usage.", .{});
        std.process.exit(1);
    };

    var thumb_cfg = ThumbCacheConfig.initFromEnviron(
        gpa,
        init.environ_map,
        parsed.thumb_cache.toWritePolicy(),
        .normal,
    );
    defer thumb_cfg.deinit(gpa);

    const protocol = parsed.protocol.resolve(init.environ_map);
    const stdout = std.Io.File.stdout();

    switch (protocol) {
        .kitty => {
            const res = renderPreviewRgbaFile(
                gpa,
                io,
                thumb_cfg,
                target_path,
                parsed.max_dims,
                NoCancel{},
            ) catch |err| {
                std.log.err(
                    "Failed to render preview for '{s}': {s}",
                    .{ target_path, @errorName(err) },
                );
                std.process.exit(1);
            };
            var stdout_buf: [1024]u8 = undefined;
            var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
            const write_res: ?anyerror = blk: {
                termgfx.writePreview(&stdout_writer.interface, .{
                    .kitty = .{
                        .temp_path = res.path(),
                        .dims = res.dims,
                        .clear_first = parsed.clear_first,
                    },
                }) catch |err| break :blk err;
                stdout_writer.interface.flush() catch |err| break :blk err;
                break :blk null;
            };
            if (write_res) |err| {
                const write_err: anyerror = stdout_writer.err orelse err;
                if (write_err != error.BrokenPipe) {
                    std.log.err("Failed to write Kitty preview: {s}", .{
                        @errorName(write_err),
                    });
                }
                std.Io.Dir.deleteFile(
                    std.Io.Dir.cwd(),
                    io,
                    res.path(),
                ) catch |del_e| {
                    std.log.warn(
                        "Failed to clean up preview temp file '{s}': {}",
                        .{ res.path(), del_e },
                    );
                };
                std.process.exit(1);
            }
        },
        .sixel => {
            const preview = renderPreviewSurface(
                gpa,
                io,
                thumb_cfg,
                target_path,
                parsed.max_dims,
                NoCancel{},
            ) catch |err| {
                std.log.err(
                    "Failed to render preview for '{s}': {s}",
                    .{ target_path, @errorName(err) },
                );
                std.process.exit(1);
            };
            defer preview.deinit();

            const pitch: usize = @intCast(preview.surface.pitch());
            const h_usize: usize = @intCast(preview.dims.h);
            const pixels = preview.surface.pixels()[0 .. pitch * h_usize];

            var stdout_buf: [16 * 1024]u8 = undefined;
            var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
            const write_res: ?anyerror = blk: {
                termgfx.writePreview(&stdout_writer.interface, .{
                    .sixel = .{
                        .allocator = gpa,
                        .rgba_pixels = pixels,
                        .pitch = pitch,
                        .dims = preview.dims,
                    },
                }) catch |err| break :blk err;
                stdout_writer.interface.flush() catch |err| break :blk err;
                break :blk null;
            };
            if (write_res) |err| {
                const write_err: anyerror = stdout_writer.err orelse err;
                if (write_err != error.BrokenPipe) {
                    std.log.err("Failed to write Sixel preview: {s}", .{
                        @errorName(write_err),
                    });
                }
                std.process.exit(1);
            }
        },
        .iterm2 => {
            const preview = renderPreviewSurface(
                gpa,
                io,
                thumb_cfg,
                target_path,
                parsed.max_dims,
                NoCancel{},
            ) catch |err| {
                std.log.err(
                    "Failed to render preview for '{s}': {s}",
                    .{ target_path, @errorName(err) },
                );
                std.process.exit(1);
            };
            defer preview.deinit();

            const image_bytes = preview.surface.encodePreviewImageAlloc(
                gpa,
                85,
            ) catch |err| {
                std.log.err(
                    "Failed to encode iTerm2 preview for '{s}': {s}",
                    .{ target_path, @errorName(err) },
                );
                std.process.exit(1);
            };
            defer gpa.free(image_bytes);

            var stdout_buf: [16 * 1024]u8 = undefined;
            var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
            const write_res: ?anyerror = blk: {
                termgfx.writePreview(&stdout_writer.interface, .{
                    .iterm2 = .{
                        .image_bytes = image_bytes,
                        .dims = preview.dims,
                    },
                }) catch |err| break :blk err;
                stdout_writer.interface.flush() catch |err| break :blk err;
                break :blk null;
            };
            if (write_res) |err| {
                const write_err: anyerror = stdout_writer.err orelse err;
                if (write_err != error.BrokenPipe) {
                    std.log.err("Failed to write iTerm2 preview: {s}", .{
                        @errorName(write_err),
                    });
                }
                std.process.exit(1);
            }
        },
    }
}
