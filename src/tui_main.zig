//! GPU-Accelerated Terminal Image Viewer (`peng-tui`)
//!
//! Combines `libvaxis` terminal lifecycle/input/UI with Peng's headless SDL3
//! GPU image-processing pipeline and `termgfx` graphics protocol encoders.

const app = @import("app");
const core = @import("core");
const geom = @import("geom");
const gpu = @import("gpu");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const termgfx = @import("termgfx");
const tui = @import("tui");
const vaxis = @import("vaxis");

const AppState = app.state.AppState;
const FRect = geom.FRect;
const InfobarPosition = tui.canvas.InfobarPosition;
const InputAccumulator = tui.input.InputAccumulator;
const LogicalDims = geom.LogicalDims;
const MappedReadback = gpu.graphics.MappedReadback;
const PacketBuildContext = gpu.pass.PacketBuildContext;
const PhysicalDims = geom.PhysicalDims;
const PositiveDimsU32 = geom.PositiveDimsU32;
const ProtocolMode = termgfx.ProtocolMode;
const RenderPacket = gpu.pass.RenderPacket;
const RenderResources = gpu.graphics.RenderResources;
const ResolvedTarget = termgfx.ResolvedTarget;
const TextureRef = gpu.TextureRef;
const UvRect = geom.UvRect;
const ViewportLayout = tui.canvas.ViewportLayout;
const ViewportParams = state_pkg.ViewportParams;

/// Restores terminal state before printing a panic stack trace.
pub const panic = vaxis.Panic;

/// Silences `std.log` output to `stderr` while the TUI alternate screen owns
/// the terminal so `vaxis` and background worker logs never corrupt the UI.
pub const std_options: std.Options = .{
    .logFn = tuiLogFn,
};

var tui_log_muted: std.atomic.Value(bool) = .init(false);

fn tuiLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (tui_log_muted.load(.acquire)) return;
    std.log.defaultLog(message_level, scope, format, args);
}

const TuiEvent = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    worker_ready,
    timer_tick,
};

const TuiCliArgs = struct {
    path: ?[]const u8 = null,
    protocol: ProtocolMode = .auto,
    infobar: InfobarPosition = .bottom,
    help: bool = false,
};

fn parseInfobarPosition(str: []const u8) ?InfobarPosition {
    if (std.mem.eql(u8, str, "bottom")) return .bottom;
    if (std.mem.eql(u8, str, "top")) return .top;
    if (std.mem.eql(u8, str, "none")) return .none;
    return null;
}

fn parseCliArgs(init: std.process.Init) !TuiCliArgs {
    var result: TuiCliArgs = .{};
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.help = true;
            return result;
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            const val = iter.next() orelse return error.MissingArgument;
            result.protocol = ProtocolMode.parse(val) orelse
                return error.InvalidProtocol;
        } else if (std.mem.eql(u8, arg, "--infobar")) {
            const val = iter.next() orelse return error.MissingArgument;
            result.infobar = parseInfobarPosition(val) orelse
                return error.InvalidInfobar;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (result.path == null) {
            result.path = try init.gpa.dupe(u8, arg);
        }
    }
    return result;
}

fn printHelp(io: std.Io) void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    w.interface.writeAll(
        \\Usage: peng-tui [OPTIONS] [PATH]
        \\
        \\GPU-accelerated terminal image viewer and photo triage tool.
        \\
        \\Options:
        \\  --protocol <auto|kitty|sixel|iterm2|halfblocks>
        \\                         Terminal graphics protocol (default: auto)
        \\  --infobar <bottom|top|none>
        \\                         Infobar placement (default: bottom)
        \\  -h, --help             Show this help message
        \\
    ) catch {};
    w.interface.flush() catch {};
}

fn wakeVaxisLoop(ptr: *anyopaque) void {
    const loop: *vaxis.Loop(TuiEvent) = @ptrCast(@alignCast(ptr));
    _ = loop.tryPostEvent(.worker_ready) catch {};
}

const ImageQuadContext = struct {
    rect: FRect,
    texture: TextureRef,
    view_params: ViewportParams,
    uv: UvRect,
};

fn buildSingleImagePacket(
    ctx: ImageQuadContext,
    build_ctx: PacketBuildContext,
) !RenderPacket {
    var packet: RenderPacket = .{};
    errdefer packet.deinit(build_ctx.frame_allocator);

    try gpu.render_image.appendImageCommand(
        &packet.vertices,
        &packet.batches,
        gpu.pass.addBatch,
        build_ctx.frame_allocator,
        ctx.rect,
        ctx.texture,
        ctx.view_params,
        build_ctx.physical_dims,
        null,
        ctx.uv,
    );
    return packet;
}

const GpuOffscreenRenderer = struct {
    device: sdl.gpu.Device,
    resources: RenderResources,

    fn init(io: std.Io) !GpuOffscreenRenderer {
        const dev = try gpu.graphics.createGpuDevice(false);
        errdefer dev.destroy();
        const res = try gpu.graphics.initGpuResources(io, dev, .headless, 1.0);
        return .{
            .device = dev,
            .resources = res,
        };
    }

    fn deinit(self: *GpuOffscreenRenderer, gpa: std.mem.Allocator) void {
        self.resources.deinit(gpa);
        self.device.destroy();
    }

    fn renderImageReadback(
        self: *GpuOffscreenRenderer,
        gpa: std.mem.Allocator,
        frame_allocator: std.mem.Allocator,
        quad: ImageQuadContext,
        dims: PositiveDimsU32,
    ) !MappedReadback {
        const res = try gpu.pass.executeOffscreenReadback(
            &self.resources,
            quad.view_params,
            gpa,
            frame_allocator,
            .{
                .w = @floatFromInt(dims.w),
                .h = @floatFromInt(dims.h),
            },
            .{},
            quad,
            buildSingleImagePacket,
        );
        return res.readback;
    }
};

/// Closed tagged union abstracting offscreen image rendering so a future CPU
/// software backend can be added without virtual dispatch or GPU overhead.
const FrameRenderer = union(enum) {
    gpu: GpuOffscreenRenderer,

    fn deinit(self: *FrameRenderer, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .gpu => |*r| r.deinit(gpa),
        }
    }

    fn gpuDevice(self: *const FrameRenderer) ?sdl.gpu.Device {
        return switch (self.*) {
            .gpu => |r| r.device,
        };
    }

    fn unpackPipeline(self: *const FrameRenderer) ?sdl.gpu.ComputePipeline {
        return switch (self.*) {
            .gpu => |r| r.resources.unpack_compute_pipeline.get(),
        };
    }

    fn renderImageReadback(
        self: *FrameRenderer,
        gpa: std.mem.Allocator,
        frame_allocator: std.mem.Allocator,
        quad: ImageQuadContext,
        dims: PositiveDimsU32,
    ) !MappedReadback {
        return switch (self.*) {
            .gpu => |*r| r.renderImageReadback(
                gpa,
                frame_allocator,
                quad,
                dims,
            ),
        };
    }
};

const RenderKey = struct {
    tex_ptr: usize,
    px_w: u32,
    px_h: u32,
    image_row: u16,
    image_cols: u16,
    image_rows: u16,
    mode: @TypeOf(@as(ViewportParams, .{}).mode),
    fit_mode: @TypeOf(@as(ViewportParams, .{}).fit_mode),
    zoom_bits: u32,
    pan_x_bits: u32,
    pan_y_bits: u32,
    rot_bits: u32,
    scale_mode: i32,
    compare_original: bool,
    edits_hash: u64,
    quad_hash: u64,

    fn init(
        tex: sdl.gpu.Texture,
        layout: ViewportLayout,
        quad: ImageQuadContext,
    ) RenderKey {
        const vp = quad.view_params;
        var edits_hasher = std.hash.Wyhash.init(0);
        edits_hasher.update(std.mem.asBytes(&vp.edits));

        var quad_hasher = std.hash.Wyhash.init(0);
        quad_hasher.update(std.mem.asBytes(&quad.rect));
        quad_hasher.update(std.mem.asBytes(&quad.uv));
        return .{
            .tex_ptr = @intFromPtr(tex.ptr),
            .px_w = layout.image_px.w,
            .px_h = layout.image_px.h,
            .image_row = layout.image_row,
            .image_cols = layout.image_cols,
            .image_rows = layout.image_rows,
            .mode = vp.mode,
            .fit_mode = vp.fit_mode,
            .zoom_bits = @bitCast(vp.zoom_factor.get()),
            .pan_x_bits = @bitCast(vp.pan_x),
            .pan_y_bits = @bitCast(vp.pan_y),
            .rot_bits = @bitCast(vp.rotation_angle),
            .scale_mode = vp.getShaderScaleModeInt(),
            .compare_original = vp.compare_original,
            .edits_hash = edits_hasher.final(),
            .quad_hash = quad_hasher.final(),
        };
    }

    fn eql(a: RenderKey, b: RenderKey) bool {
        return std.meta.eql(a, b);
    }
};

const ActiveImageQuad = struct {
    quad: ImageQuadContext,
    tex: sdl.gpu.Texture,
};

fn resolveActiveImageQuad(
    app_state: *const AppState,
    layout: ViewportLayout,
) ?ActiveImageQuad {
    const entry = app_state.getCurrentEntry() orelse return null;
    const vp = app_state.viewer.viewport;
    const auth = entry.getAuthoritativeDims();
    if (auth.w <= 0.0 or auth.h <= 0.0) return null;

    const view_logical: LogicalDims = .{
        .w = @floatFromInt(layout.image_px.w),
        .h = @floatFromInt(layout.image_px.h),
    };
    const draw_dims = state_pkg.view_transform.computeLogicalDrawDims(
        auth,
        view_logical,
        .{},
        vp.rotation_angle,
        vp.fit_mode,
    );
    const canvas_rect: FRect = .{
        .x = (view_logical.w - draw_dims.w) * 0.5,
        .y = (view_logical.h - draw_dims.h) * 0.5,
        .w = draw_dims.w,
        .h = draw_dims.h,
    };

    switch (entry.resident.asset) {
        .loaded_gpu => |g| {
            return .{
                .tex = g.gpu_texture,
                .quad = .{
                    .rect = canvas_rect,
                    .texture = .{ .tex = g.gpu_texture },
                    .view_params = vp,
                    .uv = .{
                        .rotation_angle = vp.rotation_angle,
                        .source_w = auth.w,
                        .source_h = auth.h,
                    },
                },
            };
        },
        .promoting_gpu => |promo| {
            return .{
                .tex = promo.active.gpu_texture,
                .quad = .{
                    .rect = canvas_rect,
                    .texture = .{ .tex = promo.active.gpu_texture },
                    .view_params = vp,
                    .uv = .{
                        .rotation_angle = vp.rotation_angle,
                        .source_w = auth.w,
                        .source_h = auth.h,
                    },
                },
            };
        },
        .none, .loaded_cpu, .failed => {},
    }

    switch (entry.resident.thumbnail) {
        .loaded => |thumb| {
            const pre_oriented = thumb.info.source.isPreOriented();
            const swapped = pre_oriented and
                entry.metadata.orientation.isDimensionSwapped();
            const ref_full: PhysicalDims = if (entry.metadata.full_dims) |fd|
                (if (swapped) .{ .w = fd.h, .h = fd.w } else fd)
            else
                .{ .w = 0.0, .h = 0.0 };
            var uv = state_pkg.view_transform.computeThumbnailUvCrop(
                ref_full,
                .{ .w = thumb.info.w, .h = thumb.info.h },
                thumb.info.dct_snapped,
            );
            uv.rotation_angle = if (pre_oriented)
                @mod(
                    vp.rotation_angle -
                        entry.metadata.orientation.toDegrees() + 360.0,
                    360.0,
                )
            else
                vp.rotation_angle;
            uv.source_w = if (swapped) auth.h else auth.w;
            uv.source_h = if (swapped) auth.w else auth.h;
            return .{
                .tex = thumb.texture,
                .quad = .{
                    .rect = canvas_rect,
                    .texture = .{ .tex = thumb.texture },
                    .view_params = vp,
                    .uv = uv,
                },
            };
        },
        .none, .pending, .staged_cpu, .not_available, .unloaded => return null,
    }
}

const CachedHalfblocks = struct {
    pixels: []u8 = &.{},
    pitch: usize = 0,
    dims: PositiveDimsU32 = .{ .w = 1, .h = 1 },

    fn deinit(self: *CachedHalfblocks, gpa: std.mem.Allocator) void {
        if (self.pixels.len > 0) {
            gpa.free(self.pixels);
            self.pixels = &.{};
        }
    }

    fn update(
        self: *CachedHalfblocks,
        gpa: std.mem.Allocator,
        readback: MappedReadback,
    ) !void {
        if (self.pixels.len != readback.pixels.len) {
            const next = try gpa.alloc(u8, readback.pixels.len);
            if (self.pixels.len > 0) gpa.free(self.pixels);
            self.pixels = next;
        }
        @memcpy(self.pixels, readback.pixels);
        self.pitch = readback.pitch;
        self.dims = readback.dims;
    }
};

const CachedPostRenderPayload = struct {
    bytes: std.ArrayList(u8) = .empty,
    dirty: bool = false,

    fn deinit(self: *CachedPostRenderPayload, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }

    fn clear(self: *CachedPostRenderPayload) void {
        self.bytes.clearRetainingCapacity();
        self.dirty = false;
    }
};

fn emitKittyDeleteFallback(
    tty_writer: *std.Io.Writer,
    transport: termgfx.TransportMode,
) void {
    const seq = switch (transport) {
        .direct => "\x1b_Ga=d,d=i,i=1,q=2\x1b\\",
        .tmux_passthrough,
        .tmux_unicode_placeholders,
        => "\x1bPtmux;\x1b\x1b_Ga=d,d=i,i=1,q=2\x1b\x1b\\\x1b\\",
    };
    tty_writer.writeAll(seq) catch {};
    tty_writer.flush() catch {};
}

const PresentationState = struct {
    transport: termgfx.TransportMode = .direct,
    last_key: ?RenderKey = null,
    kitty_image: ?vaxis.Image = null,
    has_kitty_fallback: bool = false,
    halfblocks: CachedHalfblocks = .{},
    post_render: CachedPostRenderPayload = .{},

    fn deinit(
        self: *PresentationState,
        gpa: std.mem.Allocator,
        vx: *vaxis.Vaxis,
        tty_writer: *std.Io.Writer,
    ) void {
        self.clearImage(vx, tty_writer);
        self.halfblocks.deinit(gpa);
        self.post_render.deinit(gpa);
    }

    fn clearImage(
        self: *PresentationState,
        vx: *vaxis.Vaxis,
        tty_writer: *std.Io.Writer,
    ) void {
        self.last_key = null;
        if (self.kitty_image) |img| {
            vx.freeImage(tty_writer, img.id);
            self.kitty_image = null;
        }
        if (self.has_kitty_fallback) {
            emitKittyDeleteFallback(tty_writer, self.transport);
            self.has_kitty_fallback = false;
        }
        self.post_render.clear();
    }
};

fn encodeReadbackPng(
    gpa: std.mem.Allocator,
    readback: MappedReadback,
) ![]u8 {
    const w_i32 = std.math.cast(i32, readback.dims.w) orelse
        return error.InvalidDimensions;
    const h_i32 = std.math.cast(i32, readback.dims.h) orelse
        return error.InvalidDimensions;
    const pitch_i32 = std.math.cast(i32, readback.pitch) orelse
        return error.InvalidPitch;
    const surf = sdl.Surface.createFrom(
        w_i32,
        h_i32,
        sdl.PixelFormat.rgba32,
        @constCast(readback.pixels.ptr),
        pitch_i32,
    ) orelse return error.SurfaceCreationFailed;
    defer surf.destroy();
    return surf.encodePngAlloc(gpa);
}

fn transmitFrame(
    gpa: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    io: std.Io,
    vx: *vaxis.Vaxis,
    tty_writer: *std.Io.Writer,
    target: ResolvedTarget,
    layout: ViewportLayout,
    readback: MappedReadback,
    pres: *PresentationState,
) !void {
    switch (target.protocol) {
        .halfblocks => {
            try pres.halfblocks.update(gpa, readback);
            pres.post_render.clear();
        },
        .kitty => {
            if (vx.caps.kitty_graphics and target.transport == .direct and
                readback.dims.w <= std.math.maxInt(u16) and
                readback.dims.h <= std.math.maxInt(u16))
            {
                const w_u16: u16 = @intCast(readback.dims.w);
                const h_u16: u16 = @intCast(readback.dims.h);
                const new_img: vaxis.Image = if (target.is_remote) blk: {
                    const png = try encodeReadbackPng(
                        frame_allocator,
                        readback,
                    );
                    defer frame_allocator.free(png);
                    break :blk try vx.transmitImage(
                        frame_allocator,
                        tty_writer,
                        png,
                        w_u16,
                        h_u16,
                        .png,
                    );
                } else blk: {
                    const w_i32 = std.math.cast(i32, readback.dims.w) orelse
                        return error.InvalidDimensions;
                    const h_i32 = std.math.cast(i32, readback.dims.h) orelse
                        return error.InvalidDimensions;
                    const pitch_i32 = std.math.cast(i32, readback.pitch) orelse
                        return error.InvalidPitch;
                    const surf = sdl.Surface.createFrom(
                        w_i32,
                        h_i32,
                        sdl.PixelFormat.rgba32,
                        @constCast(readback.pixels.ptr),
                        pitch_i32,
                    ) orelse return error.SurfaceCreationFailed;
                    defer surf.destroy();

                    const transfer = try core.preview.writeSurfaceKittyLocal(
                        io,
                        surf,
                        readback.dims,
                    );
                    errdefer transfer.cleanup(io);
                    const med: vaxis.Image.TransmitMedium =
                        switch (transfer.kind) {
                            .shared_memory => .shared_mem,
                            .temp_file => .temp_file,
                        };
                    break :blk try vx.transmitLocalImagePath(
                        frame_allocator,
                        tty_writer,
                        transfer.name(),
                        w_u16,
                        h_u16,
                        med,
                        .rgba,
                    );
                };

                if (pres.kitty_image) |old| {
                    vx.freeImage(tty_writer, old.id);
                }
                pres.kitty_image = new_img;
                pres.post_render.clear();
            } else {
                pres.post_render.clear();
                var aw: std.Io.Writer.Allocating = .fromArrayList(
                    gpa,
                    &pres.post_render.bytes,
                );
                defer pres.post_render.bytes = aw.toArrayList();

                const opts: termgfx.PreviewOptions = .{
                    .transport = target.transport,
                    .cell_dims = .{
                        .cols = layout.image_cols,
                        .rows = layout.image_rows,
                    },
                    .cell_px = layout.cell_px,
                };
                if (target.is_remote) {
                    const png = try encodeReadbackPng(
                        frame_allocator,
                        readback,
                    );
                    defer frame_allocator.free(png);
                    try termgfx.writePreview(
                        &aw.writer,
                        .{
                            .kitty = .{
                                .medium = .{ .direct_png = png },
                                .dims = readback.dims,
                                .image_id = 1,
                            },
                        },
                        opts,
                    );
                } else {
                    try termgfx.writePreview(
                        &aw.writer,
                        .{
                            .kitty = .{
                                .medium = .{
                                    .direct_rgba = .{
                                        .rgba_pixels = readback.pixels,
                                        .pitch = readback.pitch,
                                    },
                                },
                                .dims = readback.dims,
                                .image_id = 1,
                            },
                        },
                        opts,
                    );
                }
                try aw.writer.flush();
                pres.has_kitty_fallback = true;
                pres.post_render.dirty = true;
            }
        },
        .sixel => {
            pres.post_render.clear();
            var aw: std.Io.Writer.Allocating = .fromArrayList(
                gpa,
                &pres.post_render.bytes,
            );
            defer pres.post_render.bytes = aw.toArrayList();
            try termgfx.writePreview(
                &aw.writer,
                .{
                    .sixel = .{
                        .allocator = frame_allocator,
                        .rgba_pixels = readback.pixels,
                        .pitch = readback.pitch,
                        .dims = readback.dims,
                    },
                },
                .{ .transport = target.transport },
            );
            try aw.writer.flush();
            pres.post_render.dirty = true;
        },
        .iterm2 => {
            pres.post_render.clear();
            const png = try encodeReadbackPng(frame_allocator, readback);
            defer frame_allocator.free(png);
            var aw: std.Io.Writer.Allocating = .fromArrayList(
                gpa,
                &pres.post_render.bytes,
            );
            defer pres.post_render.bytes = aw.toArrayList();
            try termgfx.writePreview(
                &aw.writer,
                .{
                    .iterm2 = .{
                        .image_bytes = png,
                        .dims = readback.dims,
                    },
                },
                .{ .transport = target.transport },
            );
            try aw.writer.flush();
            pres.post_render.dirty = true;
        },
    }
}

fn buildInfobarModel(app_state: *const AppState) tui.infobar.InfobarModel {
    const nav = &app_state.viewer.navigation;
    const vp = app_state.viewer.viewport;
    const entry_opt = nav.getCurrentImageEntry();
    const cache_opt = app_state.getCurrentEntry();
    const auth = if (cache_opt) |c|
        c.getAuthoritativeDims()
    else
        PhysicalDims{ .w = 0.0, .h = 0.0 };

    const is_pair = if (entry_opt) |e| switch (e) {
        .pair => true,
        .filesystem, .archive_entry => false,
    } else false;

    const ss_state: struct { active: bool, paused: bool } =
        switch (nav.slideshow) {
            .inactive => .{ .active = false, .paused = false },
            .active => |data| .{
                .active = true,
                .paused = switch (data.clock) {
                    .paused => true,
                    .unarmed, .running => false,
                },
            },
        };

    return .{
        .visible_pos = nav.getVisiblePosition(),
        .visible_count = nav.getVisibleCount(),
        .is_loading = nav.isLoadingFiles(),
        .filename = if (entry_opt) |e| e.getBasename() else "",
        .is_raw_jpeg_pair = is_pair,
        .classification = nav.getCurrentClassification(),
        .view_mode = nav.getViewMode(),
        .image_w = if (std.math.isFinite(auth.w) and auth.w > 0.0)
            std.math.lossyCast(u32, @round(auth.w))
        else
            0,
        .image_h = if (std.math.isFinite(auth.h) and auth.h > 0.0)
            std.math.lossyCast(u32, @round(auth.h))
        else
            0,
        .zoom_factor = vp.zoom_factor.get(),
        .fit_mode = vp.fit_mode,
        .is_manual_zoom = switch (vp.mode) {
            .manual => true,
            .fit, .fill => false,
        },
        .scale_filter = vp.scale_filter,
        .rotation_deg = vp.rotation_angle,
        .has_edits = vp.edits.hasEdits(),
        .compare_original = vp.compare_original,
        .slideshow_active = ss_state.active,
        .slideshow_paused = ss_state.paused,
    };
}

fn buildDetailsModel(app_state: *const AppState) tui.overlays.DetailsModel {
    const nav = &app_state.viewer.navigation;
    const vp = app_state.viewer.viewport;
    const entry_opt = nav.getCurrentImageEntry();
    const cache_opt = app_state.getCurrentEntry();
    const auth = if (cache_opt) |c|
        c.getAuthoritativeDims()
    else
        PhysicalDims{ .w = 0.0, .h = 0.0 };

    const src_path: []const u8 = if (entry_opt) |e| switch (e) {
        .filesystem => |f| f.path,
        .archive_entry => |a| a.archive_path,
        .pair => |p| p.raw_path,
    } else "";

    const filter_name: []const u8 = switch (vp.scale_filter) {
        .nearest => "Nearest",
        .linear => "Linear",
        .pixel_art => "PixelAA",
        .mitchell => "Mitchell",
        .lanczos3 => "Lanczos3",
        .fsr => "FSR",
        .tiny_cnn => "TinyCNN",
    };

    const zoom_pct: u32 = if (std.math.isFinite(vp.zoom_factor.get()) and
        vp.zoom_factor.get() > 0.0)
        @intFromFloat(@min(@round(vp.zoom_factor.get() * 100.0), 99999.0))
    else
        100;
    const rot_deg: i32 = if (std.math.isFinite(vp.rotation_angle))
        @intFromFloat(@mod(@round(vp.rotation_angle), 360.0))
    else
        0;

    const size_bytes: ?u64 = if (cache_opt) |c| switch (c.resident.asset) {
        .loaded_gpu => |g| g.size_bytes,
        .promoting_gpu => |p| p.active.size_bytes,
        .loaded_cpu => |cpu| cpu.cpu.size_bytes,
        .none, .failed => null,
    } else null;

    return .{
        .filename = if (entry_opt) |e| e.getBasename() else "",
        .source_path = src_path,
        .width = if (std.math.isFinite(auth.w) and auth.w > 0.0)
            std.math.lossyCast(u32, @round(auth.w))
        else
            0,
        .height = if (std.math.isFinite(auth.h) and auth.h > 0.0)
            std.math.lossyCast(u32, @round(auth.h))
        else
            0,
        .file_size_bytes = size_bytes,
        .classification = nav.getCurrentClassification(),
        .zoom_pct = zoom_pct,
        .rotation_deg = rot_deg,
        .filter_name = filter_name,
    };
}

fn timerWakeTask(
    io: std.Io,
    loop: *vaxis.Loop(TuiEvent),
    delay_ms: i32,
) void {
    io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake) catch return;
    _ = loop.tryPostEvent(.timer_tick) catch {};
}

/// Entry point for the `peng-tui` GPU-accelerated terminal image viewer.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cli = parseCliArgs(init) catch |err| {
        std.log.err("Invalid arguments ({s}). Use --help for usage.", .{
            @errorName(err),
        });
        std.process.exit(1);
    };
    defer if (cli.path) |p| gpa.free(p);

    if (cli.help) {
        printHelp(io);
        return;
    }

    const target = cli.protocol.resolve(init.environ_map);

    try gpu.graphics.initSdlCore(true);
    defer gpu.graphics.quitSdlCore();

    var renderer: FrameRenderer = .{
        .gpu = try GpuOffscreenRenderer.init(io),
    };
    defer renderer.deinit(gpa);

    var tty_buf: [64 * 1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(TuiEvent) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    tui_log_muted.store(true, .release);
    defer tui_log_muted.store(false, .release);
    try vx.queryTerminal(tty.writer(), .fromMilliseconds(250));
    try vx.setMouseMode(tty.writer(), true);

    var app_state = AppState{
        .viewer = blk: {
            var nav = try state_pkg.NavigationState.init(gpa);
            errdefer nav.deinit(gpa);
            const ui_state = try state_pkg.UiState.init(gpa);
            break :blk .{
                .defaults = .{
                    .crossfade = false,
                    .snackbar_enabled = false,
                    .auto_title = false,
                },
                .navigation = nav,
                .ui = ui_state,
                .animations = .{},
                .rotation_map = .empty,
                .running = true,
            };
        },
        .display = .{ .visible = .headless },
        .gpu_device = renderer.gpuDevice(),
        .gpu_enabled = true,
        .unpack_compute_pipeline = renderer.unpackPipeline(),
        .cache = .{},
        .workers = .init(.{
            .callback = .{
                .ctx = &loop,
                .wake_fn = wakeVaxisLoop,
            },
        }),
        .allocator = gpa,
        .io = io,
    };
    app_state.viewer.resetToDefaults();
    defer {
        app_state.workers.exiting.store(true, .release);
        app_state.deinit();
    }
    try app_state.ensureInitialCapacities();
    app_state.initThumbCache(init.environ_map, .read_only, .normal);

    const start_ms = state_pkg.timestampToMs(std.Io.Clock.awake.now(io));
    if (cli.path) |path| {
        try app_state.openPath(path, start_ms);
    } else {
        try app.workers.readPipedStdin(
            &app_state.workers,
            &app_state.viewer.navigation.active_file_scans,
            io,
            gpa,
        );
    }

    var winsize: vaxis.Winsize = tty.getWinsize() catch .{
        .cols = 80,
        .rows = 24,
        .x_pixel = 0,
        .y_pixel = 0,
    };
    try vx.resize(gpa, tty.writer(), winsize);

    var infobar_pos = cli.infobar;
    var pres: PresentationState = .{ .transport = target.transport };
    defer pres.deinit(gpa, &vx, tty.writer());

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    var last_frame_ms = start_ms;
    var mouse_left_down = false;
    var last_mouse_x: f32 = 0.0;
    var last_mouse_y: f32 = 0.0;
    var prev_overlay_open = false;

    while (app_state.viewer.running) {
        _ = frame_arena.reset(.retain_capacity);
        const frame_alloc = frame_arena.allocator();

        const now_ms = state_pkg.timestampToMs(std.Io.Clock.awake.now(io));
        const bg_processed = app.drainWorkerEvents(&app_state, now_ms);
        const layout = ViewportLayout.compute(winsize, infobar_pos);

        const wait_strategy = app_state.computeFrameWaitStrategy(
            @floatFromInt(layout.image_px.w),
            @floatFromInt(layout.image_px.h),
            bg_processed,
            false,
            now_ms,
        );

        var acc = InputAccumulator.init(
            frame_alloc,
            mouse_left_down,
            last_mouse_x,
            last_mouse_y,
        );
        defer acc.deinit();
        const text_capture = app_state.viewer.ui.palette.isAcceptingInput();

        // Block only when no events are queued and engine says we can idle.
        var first_event = loop.tryEvent() catch |err| switch (err) {
            error.Closed => break,
            else => return err,
        };
        if (first_event == null) {
            switch (wait_strategy) {
                .poll => {},
                .wait_indefinite => {
                    first_event = loop.nextEvent() catch |err| switch (err) {
                        error.Closed => break,
                        else => return err,
                    };
                },
                .wait_timeout_ms => |ms| {
                    if (ms > 0) {
                        var timer = try io.concurrent(
                            timerWakeTask,
                            .{ io, &loop, ms },
                        );
                        defer timer.cancel(io);
                        first_event = loop.nextEvent() catch |err|
                            switch (err) {
                                error.Closed => break,
                                else => return err,
                            };
                    }
                },
            }
        }

        const cell_w_f: f32 = @floatFromInt(layout.cell_px.w);
        const cell_h_f: f32 = @floatFromInt(layout.cell_px.h);
        var resized = false;

        var ev_opt = first_event;
        while (ev_opt) |ev| {
            switch (ev) {
                .key_press => |k| try acc.handleKeyPress(k, text_capture),
                .mouse => |m| acc.handleMouse(m, cell_w_f, cell_h_f),
                .winsize => |ws| {
                    winsize = ws;
                    resized = true;
                },
                .focus_in, .focus_out, .worker_ready, .timer_tick => {},
            }
            ev_opt = loop.tryEvent() catch |err| switch (err) {
                error.Closed => break,
                else => return err,
            };
        }

        if (resized) {
            try vx.resize(gpa, tty.writer(), winsize);
            pres.post_render.dirty = true;
        }
        if (acc.local_actions.cycle_infobar) {
            infobar_pos = infobar_pos.next();
            pres.post_render.dirty = true;
        }
        if (acc.local_actions.open_file_search) {
            try app_state.pushIntent(.{ .set_palette = .{ .mode = .files } });
        }

        mouse_left_down = acc.mouse_left_down;
        last_mouse_x = acc.mouse_x;
        last_mouse_y = acc.mouse_y;

        const post_ms = state_pkg.timestampToMs(std.Io.Clock.awake.now(io));
        _ = app.drainWorkerEvents(&app_state, post_ms);

        const active_layout = ViewportLayout.compute(winsize, infobar_pos);
        const dt_ms: f32 = @floatFromInt(post_ms -| last_frame_ms);
        last_frame_ms = post_ms;

        const frame_input = acc.toFrameInput(
            @floatFromInt(active_layout.image_px.w),
            @floatFromInt(active_layout.image_px.h),
            dt_ms,
            post_ms,
        );
        app_state.viewer.last_win_dims = frame_input.logicalWinDims();
        app_state.viewer.mouse_inside = frame_input.mouse_inside;

        _ = try app.systems.runUpdatePhase(
            &app_state,
            frame_input,
            frame_alloc,
            true,
        );
        if (!app_state.viewer.running) break;

        // Settle animations so terminal frames don't waste bandwidth on
        // intermediate interpolation frames, and finalize any closing palette.
        app_state.viewer.animations.settleAll();
        switch (app_state.viewer.ui.palette.lifecycle) {
            .closing => app_state.viewer.ui.palette.reset(),
            .open, .closed => {},
        }

        const root_win = vx.window();
        root_win.clear();
        const image_win = active_layout.imageWindow(root_win);

        if (resolveActiveImageQuad(&app_state, active_layout)) |active| {
            const key = RenderKey.init(
                active.tex,
                active_layout,
                active.quad,
            );
            const dirty = pres.last_key == null or
                !pres.last_key.?.eql(key);
            if (dirty) {
                const readback = try renderer.renderImageReadback(
                    gpa,
                    frame_alloc,
                    active.quad,
                    active_layout.image_px,
                );
                defer readback.deinit();

                try transmitFrame(
                    gpa,
                    frame_alloc,
                    io,
                    &vx,
                    tty.writer(),
                    target,
                    active_layout,
                    readback,
                    &pres,
                );
                pres.last_key = key;
            }

            if (pres.kitty_image) |img| {
                // z < -1_073_741_824 places the image beneath both text and
                // non-default cell backgrounds (Kitty spec), so modals with
                // explicit RGB backgrounds render opaque while `.default`
                // viewport cells let the image show through.
                try img.draw(image_win, .{
                    .z_index = -1_073_741_825,
                    .size = .{
                        .cols = active_layout.image_cols,
                        .rows = active_layout.image_rows,
                    },
                });
            } else if (target.protocol == .halfblocks and
                pres.halfblocks.pixels.len > 0)
            {
                tui.canvas.blitHalfblocksToWindow(
                    image_win,
                    pres.halfblocks.pixels,
                    pres.halfblocks.pitch,
                    pres.halfblocks.dims,
                );
            }
        } else {
            pres.clearImage(&vx, tty.writer());
        }

        if (active_layout.infobarWindow(root_win)) |bar| {
            tui.infobar.render(bar, buildInfobarModel(&app_state), frame_alloc);
        }

        const pal_open = app_state.viewer.ui.palette.isAcceptingInput();
        const details_open = app_state.viewer.ui.overlays.info_panel.visible;
        const overlay_open = pal_open or details_open;
        if (pal_open) {
            const nav_slice = app_state.viewer.navigation.items.slice();
            tui.overlays.renderPalette(
                image_win,
                &app_state.viewer.ui.palette,
                nav_slice.items(.entry),
                nav_slice.items(.classification),
                frame_alloc,
            );
        } else if (details_open) {
            tui.overlays.renderDetails(
                image_win,
                buildDetailsModel(&app_state),
                frame_alloc,
            );
        }
        if (!prev_overlay_open and overlay_open) {
            // Only Kitty fallback (`a=T` at z=0) draws above text cells and
            // requires clearing before opening a modal. iTerm2 and Sixel cells
            // outside the modal rect stay visible when vaxis diffs only the
            // modal cells over them.
            if (pres.has_kitty_fallback) {
                emitKittyDeleteFallback(tty.writer(), pres.transport);
                vx.queueRefresh();
            }
        } else if (prev_overlay_open and !overlay_open) {
            pres.post_render.dirty = true;
        }
        prev_overlay_open = overlay_open;

        try vx.render(tty.writer());

        if (!overlay_open and pres.post_render.dirty and
            pres.post_render.bytes.items.len > 0)
        {
            // Save/restore cursor via DECSC/DECRC so raw post-render graphics
            // never desync vaxis's tracked cursor state.
            try tty.writer().print(
                "\x1b7\x1b[{d};1H",
                .{active_layout.image_row + 1},
            );
            try tty.writer().writeAll(pres.post_render.bytes.items);
            try tty.writer().writeAll("\x1b8");
            try tty.writer().flush();
            pres.post_render.dirty = false;
        }
    }
}
