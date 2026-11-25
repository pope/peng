const app_config = @import("config");
const core = @import("core");
const std = @import("std");
const termgfx = @import("termgfx");
const thumbcache = @import("thumbcache");

const NoCancel = core.preview.NoCancel;
const PreviewSurface = core.preview.PreviewSurface;
const renderPreviewRgbaFile = core.preview.renderPreviewRgbaFile;
const renderPreviewSurface = core.preview.renderPreviewSurface;
const renderPreviewToOutputFile = core.preview.renderPreviewToOutputFile;
const ThumbCacheConfig = thumbcache.ThumbCacheConfig;

fn renderSurfaceOrExit(
    gpa: std.mem.Allocator,
    io: std.Io,
    thumb_cfg: ThumbCacheConfig,
    target_path: []const u8,
    max_dims: anytype,
) PreviewSurface {
    return renderPreviewSurface(
        gpa,
        io,
        thumb_cfg,
        target_path,
        max_dims,
        NoCancel{},
    ) catch |err| {
        std.log.err(
            "Failed to render preview for '{s}': {s}",
            .{ target_path, @errorName(err) },
        );
        std.process.exit(1);
    };
}

const SurfaceRgbaView = struct {
    pixels: []const u8,
    pitch: usize,
};

fn surfaceRgbaView(preview: PreviewSurface) SurfaceRgbaView {
    const pitch: usize = @intCast(preview.surface.pitch());
    const h_usize: usize = @intCast(preview.dims.h);
    return .{
        .pixels = preview.surface.pixels()[0 .. pitch * h_usize],
        .pitch = pitch,
    };
}

/// Standalone CLI entry point for rendering a terminal image preview
/// (Kitty Graphics Protocol `t=t`, VT340 Sixel, iTerm2 Inline Images, or
/// ANSI truecolor Unicode half-blocks) without a GUI window, Vulkan device, or
/// server.
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

    const target = parsed.protocol.resolve(init.environ_map);
    const term_target: ?termgfx.ResolvedTarget = if (parsed.output_path == null)
        target
    else
        null;
    const cell_px = if (parsed.size.needsCellPixelSize(term_target))
        termgfx.queryCellPixelSize(io)
    else
        null;
    const max_dims = parsed.size.resolveMaxPixels(cell_px);

    if (parsed.output_path) |out_path| {
        _ = renderPreviewToOutputFile(
            gpa,
            io,
            thumb_cfg,
            target_path,
            out_path,
            max_dims,
            NoCancel{},
        ) catch |err| {
            std.log.err(
                "Failed to render preview for '{s}' to '{s}': {s}",
                .{ target_path, out_path, @errorName(err) },
            );
            std.process.exit(1);
        };
        return;
    }

    const preview_opts: termgfx.PreviewOptions = .{
        .transport = target.transport,
        .cell_dims = parsed.size.cellDims(),
        .cell_px = cell_px,
    };

    switch (target.protocol) {
        .kitty => {
            if (target.is_remote) {
                const preview = renderSurfaceOrExit(
                    gpa,
                    io,
                    thumb_cfg,
                    target_path,
                    max_dims,
                );
                defer preview.deinit();
                const rgba = surfaceRgbaView(preview);
                if (!termgfx.writePreviewToStdout(io, .{
                    .kitty = .{
                        .medium = .{
                            .direct_rgba = .{
                                .rgba_pixels = rgba.pixels,
                                .pitch = rgba.pitch,
                            },
                        },
                        .dims = preview.dims,
                        .clear_first = parsed.clear_first,
                    },
                }, preview_opts)) {
                    std.process.exit(1);
                }
            } else {
                const res = renderPreviewRgbaFile(
                    gpa,
                    io,
                    thumb_cfg,
                    target_path,
                    max_dims,
                    NoCancel{},
                ) catch |err| {
                    std.log.err(
                        "Failed to render preview for '{s}': {s}",
                        .{ target_path, @errorName(err) },
                    );
                    std.process.exit(1);
                };
                if (!termgfx.writePreviewToStdout(io, .{
                    .kitty = .{
                        .medium = .{ .temp_file = res.path() },
                        .dims = res.dims,
                        .clear_first = parsed.clear_first,
                    },
                }, preview_opts)) {
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
            }
        },
        .sixel => {
            const preview = renderSurfaceOrExit(
                gpa,
                io,
                thumb_cfg,
                target_path,
                max_dims,
            );
            defer preview.deinit();
            const rgba = surfaceRgbaView(preview);
            if (!termgfx.writePreviewToStdout(io, .{
                .sixel = .{
                    .allocator = gpa,
                    .rgba_pixels = rgba.pixels,
                    .pitch = rgba.pitch,
                    .dims = preview.dims,
                },
            }, preview_opts)) {
                std.process.exit(1);
            }
        },
        .iterm2 => {
            const preview = renderSurfaceOrExit(
                gpa,
                io,
                thumb_cfg,
                target_path,
                max_dims,
            );
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

            if (!termgfx.writePreviewToStdout(io, .{
                .iterm2 = .{
                    .image_bytes = image_bytes,
                    .dims = preview.dims,
                },
            }, preview_opts)) {
                std.process.exit(1);
            }
        },
        .halfblocks => {
            const preview = renderSurfaceOrExit(
                gpa,
                io,
                thumb_cfg,
                target_path,
                max_dims,
            );
            defer preview.deinit();
            const rgba = surfaceRgbaView(preview);

            var hb_opts = preview_opts;
            if (hb_opts.cell_px == null) {
                hb_opts.cell_px = termgfx.default_cell_px;
            }
            if (!termgfx.writePreviewToStdout(io, .{
                .halfblocks = .{
                    .rgba_pixels = rgba.pixels,
                    .pitch = rgba.pitch,
                    .dims = preview.dims,
                },
            }, hb_opts)) {
                std.process.exit(1);
            }
        },
    }
}
