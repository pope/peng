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
const ImageCellCrop = tui.canvas.ImageCellCrop;
const InfobarPosition = tui.canvas.InfobarPosition;
const InputAccumulator = tui.input.InputAccumulator;
const LogicalDims = geom.LogicalDims;
const MappedReadback = gpu.graphics.MappedReadback;
const PacketBuildContext = gpu.pass.PacketBuildContext;
const PhysicalDims = geom.PhysicalDims;
const PositiveDimsU32 = geom.PositiveDimsU32;
const RenderPacket = gpu.pass.RenderPacket;
const RenderResources = gpu.graphics.RenderResources;
const ResolvedTarget = termgfx.ResolvedTarget;
const TextureRef = gpu.TextureRef;
const TuiCliArgs = tui.cli.TuiCliArgs;
const UvRect = geom.UvRect;
const ViewportLayout = tui.canvas.ViewportLayout;
const ViewportParams = state_pkg.ViewportParams;

/// Restores terminal state before printing a panic stack trace.
pub const panic = vaxis.Panic;

/// Silences `std.log` output to `stderr` while the TUI alternate screen owns
/// the terminal (or redirects logs to `--log-file` when configured) so `vaxis`
/// and background worker logs never corrupt the UI.
pub const std_options: std.Options = .{
    .logFn = tuiLogFn,
};

var tui_log_muted: std.atomic.Value(bool) = .init(false);
var tui_log_file_enabled: std.atomic.Value(bool) = .init(false);
var tui_log_mutex: std.Io.Mutex = .init;
var tui_log_file: ?std.Io.File = null;
var tui_log_io: ?std.Io = null;

fn tuiLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (tui_log_file_enabled.load(.acquire)) {
        const io = tui_log_io.?;
        tui_log_mutex.lockUncancelable(io);
        defer tui_log_mutex.unlock(io);
        if (tui_log_file) |file| {
            var buf: [2048]u8 = undefined;
            var w = file.writerStreaming(io, &buf);
            const lvl = comptime message_level.asText();
            const prefix = if (scope == .default)
                lvl ++ ": "
            else
                lvl ++ "(" ++ @tagName(scope) ++ "): ";
            w.interface.print(prefix ++ format ++ "\n", args) catch {};
            w.interface.flush() catch {};
            return;
        }
    }
    if (tui_log_muted.load(.acquire)) return;
    std.log.defaultLog(message_level, scope, format, args);
}

const TuiEvent = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    worker_ready,
    timer_tick,
};

fn parseProcessArgs(init: std.process.Init) !TuiCliArgs {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    var raw: std.ArrayList([]const u8) = .empty;
    defer raw.deinit(init.gpa);
    while (iter.next()) |arg| {
        try raw.append(init.gpa, arg);
    }
    return tui.cli.parseArgs(init.gpa, raw.items);
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
    ) !gpu.pass.OffscreenFrameResult {
        return gpu.pass.executeOffscreenReadback(
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

    fn ensureUnpackPipeline(self: *FrameRenderer) ?sdl.gpu.ComputePipeline {
        return switch (self.*) {
            .gpu => |*r| r.resources.ensureUnpackComputePipeline(),
        };
    }

    fn renderImageReadback(
        self: *FrameRenderer,
        gpa: std.mem.Allocator,
        frame_allocator: std.mem.Allocator,
        quad: ImageQuadContext,
        dims: PositiveDimsU32,
    ) !gpu.pass.OffscreenFrameResult {
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
    image_row: u16,
    render_crop: ImageCellCrop,
    present_crop: ImageCellCrop,
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
        render_crop: ImageCellCrop,
        present_crop: ImageCellCrop,
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
            .image_row = layout.image_row,
            .render_crop = render_crop,
            .present_crop = present_crop,
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
    render_crop: ImageCellCrop,
    present_crop: ImageCellCrop,
    visible_rect: FRect,
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
    const full_rect: FRect = .{
        .x = (view_logical.w - draw_dims.w) * 0.5,
        .y = (view_logical.h - draw_dims.h) * 0.5,
        .w = draw_dims.w,
        .h = draw_dims.h,
    };
    // Crop the GPU offscreen target in unpanned `.fit` mode to avoid reading
    // back empty letterbox margins; keep `fullCrop()` when panned or in
    // `.fill`/`.manual` modes so dragging/zooming never reallocates the
    // offscreen GPU texture per frame.
    const render_crop: ImageCellCrop = switch (vp.mode) {
        .fit => if (vp.pan_x == 0.0 and vp.pan_y == 0.0)
            layout.cropForRect(full_rect)
        else
            layout.fullCrop(),
        .fill, .manual => layout.fullCrop(),
    };
    // Compute the exact visible cell rectangle in all modes so `transmitFrame`
    // can slice the mapped readback in O(1) to exclude empty letterbox margins
    // across Kitty, iTerm2, Sixel, and Halfblocks without GPU reallocations.
    const visible_rect: FRect = switch (vp.mode) {
        .fit, .fill => .{
            .x = full_rect.x + vp.pan_x,
            .y = full_rect.y + vp.pan_y,
            .w = full_rect.w,
            .h = full_rect.h,
        },
        .manual => blk: {
            const z = vp.zoom_factor.get();
            if (!std.math.isFinite(z) or z <= 0.0) break :blk full_rect;
            break :blk ImageCellCrop.rotatedAabb(
                full_rect.x + full_rect.w * 0.5,
                full_rect.y + full_rect.h * 0.5,
                auth.w * z,
                auth.h * z,
                vp.rotation_angle,
                vp.pan_x,
                vp.pan_y,
            );
        },
    };
    const present_crop: ImageCellCrop = switch (vp.mode) {
        .fit => if (vp.pan_x == 0.0 and vp.pan_y == 0.0)
            render_crop
        else
            layout.cropForRect(visible_rect),
        .fill, .manual => layout.cropForRect(visible_rect),
    };
    const canvas_rect: FRect = .{
        .x = full_rect.x - render_crop.pxOffsetX(layout.cell_px),
        .y = full_rect.y - render_crop.pxOffsetY(layout.cell_px),
        .w = full_rect.w,
        .h = full_rect.h,
    };

    const prefer_thumb = app_state.viewer.ui.overlays.debug_show_thumb and
        switch (entry.resident.thumbnail) {
            .loaded => true,
            .none, .pending, .staged_cpu, .not_available, .unloaded => false,
        };

    if (!prefer_thumb) if (entry.resident.asset.activeGpu()) |g| {
        return .{
            .tex = g.gpu_texture,
            .render_crop = render_crop,
            .present_crop = present_crop,
            .visible_rect = visible_rect,
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
    };

    switch (entry.resident.thumbnail) {
        .loaded => |thumb| {
            const uv = entry.computeThumbnailUvRect(
                thumb.info,
                auth,
                vp.rotation_angle,
            );
            return .{
                .tex = thumb.texture,
                .render_crop = render_crop,
                .present_crop = present_crop,
                .visible_rect = visible_rect,
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
    crop: ImageCellCrop = .{
        .col_off = 0,
        .row_off = 0,
        .cols = 1,
        .rows = 1,
        .px = .{ .w = 1, .h = 1 },
    },

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
        crop: ImageCellCrop,
    ) !void {
        if (self.pixels.len != readback.pixels.len) {
            const next = try gpa.alloc(u8, readback.pixels.len);
            if (self.pixels.len > 0) gpa.free(self.pixels);
            self.pixels = next;
        }
        @memcpy(self.pixels, readback.pixels);
        self.pitch = readback.pitch;
        self.dims = readback.dims;
        self.crop = crop;
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

fn writePostRenderSync(
    tty_writer: *std.Io.Writer,
    ui_bytes: []const u8,
    image_row: u16,
    crop: ImageCellCrop,
    payload: []const u8,
) !void {
    const sync_set = vaxis.ctlseqs.sync_set;
    const sync_reset = vaxis.ctlseqs.sync_reset;
    const had_sync = ui_bytes.len >= sync_set.len + sync_reset.len and
        std.mem.startsWith(u8, ui_bytes, sync_set) and
        std.mem.endsWith(u8, ui_bytes, sync_reset);
    const ui_body = if (had_sync)
        ui_bytes[0 .. ui_bytes.len - sync_reset.len]
    else
        ui_bytes;

    // Keep vaxis's UI diff (including any full-screen refresh clear) and the
    // raw Sixel/iTerm2/Kitty-fallback payload inside one atomic Synchronized
    // Output frame (BSU..ESU) so terminals never paint a blank intermediate
    // frame or partial Sixel bands.
    var sync_open = false;
    errdefer if (sync_open) {
        tty_writer.writeAll(sync_reset) catch {};
        tty_writer.flush() catch {};
    };

    if (had_sync) {
        sync_open = true;
        try tty_writer.writeAll(ui_body);
    } else {
        sync_open = true;
        try tty_writer.writeAll(sync_set);
        if (ui_body.len > 0) {
            try tty_writer.writeAll(ui_body);
        }
    }

    // Save/restore cursor via DECSC/DECRC so raw post-render graphics never
    // desync vaxis's tracked cursor state.
    try tty_writer.print(
        "\x1b7\x1b[{d};{d}H",
        .{
            image_row + crop.row_off + 1,
            crop.col_off + 1,
        },
    );
    try tty_writer.writeAll(payload);
    try tty_writer.writeAll("\x1b8");
    try tty_writer.writeAll(sync_reset);
    sync_open = false;
    try tty_writer.flush();
}

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

const ActiveOverlay = union(enum) {
    none,
    palette,
    stats: tui.overlays.StatsModel,
    details: tui.overlays.DetailsModel,

    fn isOpen(self: ActiveOverlay) bool {
        return switch (self) {
            .none => false,
            .palette, .stats, .details => true,
        };
    }
};

const UiImageState = union(enum) {
    none,
    kitty: struct {
        id: u32,
        crop: ImageCellCrop,
    },
    other: ImageCellCrop,
};

const UiRenderKey = struct {
    cols: u16,
    rows: u16,
    infobar_pos: InfobarPosition,
    image: UiImageState,
    overlay: std.meta.Tag(ActiveOverlay),
    content_hash: u64,

    fn hashBool(hasher: *std.hash.Wyhash, val: bool) void {
        hasher.update(&.{@intFromBool(val)});
    }

    fn hashEnum(hasher: *std.hash.Wyhash, val: anytype) void {
        const b: u8 = @intCast(@backingInt(val));
        hasher.update(&.{b});
    }

    fn hashOptInt(
        hasher: *std.hash.Wyhash,
        comptime T: type,
        val: ?T,
    ) void {
        if (val) |v| {
            hasher.update(&.{1});
            hasher.update(std.mem.asBytes(&v));
        } else {
            hasher.update(&.{0});
        }
    }

    fn hashInfobar(
        hasher: *std.hash.Wyhash,
        m: tui.infobar.InfobarModel,
    ) void {
        hashOptInt(hasher, usize, m.visible_pos);
        hasher.update(std.mem.asBytes(&m.visible_count));
        hashBool(hasher, m.is_loading);
        hasher.update(m.filename);
        hasher.update(&.{0});
        hashBool(hasher, m.is_raw_jpeg_pair);
        hashEnum(hasher, m.classification);
        hashEnum(hasher, m.view_mode);
        hasher.update(std.mem.asBytes(&m.image_w));
        hasher.update(std.mem.asBytes(&m.image_h));
        hasher.update(std.mem.asBytes(&@as(u32, @bitCast(m.zoom_factor))));
        hashEnum(hasher, m.fit_mode);
        hashBool(hasher, m.is_manual_zoom);
        hashEnum(hasher, m.scale_filter);
        hasher.update(std.mem.asBytes(&@as(u32, @bitCast(m.rotation_deg))));
        hashBool(hasher, m.has_edits);
        hashBool(hasher, m.compare_original);
        hashBool(hasher, m.slideshow_active);
        hashBool(hasher, m.slideshow_paused);
        hasher.update(m.notification);
        hasher.update(&.{0});
    }

    fn init(
        layout: ViewportLayout,
        infobar_pos: InfobarPosition,
        image: UiImageState,
        infobar_model: tui.infobar.InfobarModel,
        app_state: *const AppState,
        active_overlay: ActiveOverlay,
    ) UiRenderKey {
        var hasher = std.hash.Wyhash.init(0);
        hashInfobar(&hasher, infobar_model);

        switch (active_overlay) {
            .none => {},
            .palette => {
                const pal = &app_state.viewer.ui.palette;
                if (pal.visibleMode()) |mode| {
                    hashEnum(&hasher, std.meta.activeTag(mode));
                    switch (mode) {
                        .prompt => |kind| {
                            hashEnum(&hasher, std.meta.activeTag(kind));
                            switch (kind) {
                                .edit_param => |param| hashEnum(&hasher, param),
                                .go_to_image, .slideshow_interval => {},
                            }
                        },
                        .files, .actions, .directory_navigator => {},
                    }
                }
                hasher.update(std.mem.asBytes(&pal.selected_idx));
                hasher.update(pal.query.items);
                hasher.update(&.{0});
                hasher.update(pal.current_nav_dir.items);
                hasher.update(&.{0});
                hasher.update(std.mem.asBytes(&pal.matches.items.len));
                if (pal.matches.items.len <= 32) {
                    hasher.update(std.mem.sliceAsBytes(pal.matches.items));
                } else {
                    const sel = @min(
                        pal.selected_idx,
                        pal.matches.items.len - 1,
                    );
                    const start = sel -| 16;
                    const end = @min(start + 32, pal.matches.items.len);
                    hasher.update(std.mem.sliceAsBytes(
                        pal.matches.items[start..end],
                    ));
                }
                hasher.update(std.mem.asBytes(&pal.dir_items.items.len));
                hasher.update(std.mem.asBytes(&pal.current_dir_image_count));
                const dir_gen = pal.dir_scan_generation.load(.monotonic);
                const dir_scans = pal.active_dir_scans.load(.monotonic);
                hasher.update(std.mem.asBytes(&dir_gen));
                hasher.update(std.mem.asBytes(&dir_scans));
                hasher.update(std.mem.asBytes(
                    &app_state.viewer.navigation.items.len,
                ));
            },
            .stats => |s| {
                hasher.update(s.protocol_label);
                hasher.update(std.mem.asBytes(&s.viewport_cols));
                hasher.update(std.mem.asBytes(&s.viewport_rows));
                hasher.update(std.mem.asBytes(&s.viewport_px_w));
                hasher.update(std.mem.asBytes(&s.viewport_px_h));
                hasher.update(std.mem.asBytes(&s.cell_px_w));
                hasher.update(std.mem.asBytes(&s.cell_px_h));
                hasher.update(std.mem.asBytes(&@as(
                    u64,
                    @bitCast(s.gpu_pass_ms),
                )));
                hasher.update(std.mem.asBytes(&@as(
                    u64,
                    @bitCast(s.term_encode_ms),
                )));
                hasher.update(std.mem.asBytes(&@as(u64, @bitCast(s.read_ms))));
                hasher.update(std.mem.asBytes(&@as(
                    u64,
                    @bitCast(s.decode_ms),
                )));
                hasher.update(std.mem.asBytes(&@as(
                    u64,
                    @bitCast(s.upload_ms),
                )));
                hasher.update(std.mem.asBytes(&s.vram_bytes));
                hasher.update(std.mem.asBytes(&s.cached_entries));
                hasher.update(std.mem.asBytes(&s.total_images));
                hashBool(&hasher, s.debug_show_thumb);
            },
            .details => |d| {
                hasher.update(d.filename);
                hasher.update(&.{0});
                hasher.update(d.source_path);
                hasher.update(&.{0});
                hasher.update(std.mem.asBytes(&d.width));
                hasher.update(std.mem.asBytes(&d.height));
                hashOptInt(&hasher, u64, d.file_size_bytes);
                hashEnum(&hasher, d.classification);
                hasher.update(std.mem.asBytes(&d.zoom_pct));
                hasher.update(std.mem.asBytes(&d.rotation_deg));
                hasher.update(d.filter_name);
            },
        }

        return .{
            .cols = layout.cols,
            .rows = layout.rows,
            .infobar_pos = infobar_pos,
            .image = image,
            .overlay = std.meta.activeTag(active_overlay),
            .content_hash = hasher.final(),
        };
    }

    fn eql(a: UiRenderKey, b: UiRenderKey) bool {
        return std.meta.eql(a, b);
    }
};

const KittyVaxisState = struct {
    image: vaxis.Image,
    crop: ImageCellCrop,
    pending_free_id: ?u32 = null,
};

const PostRenderState = struct {
    payload: CachedPostRenderPayload = .{},
    crop: ImageCellCrop,
    pixel_dims: PositiveDimsU32,
    kitty_fallback: ?termgfx.TransportMode = null,
};

const PresentationContent = union(enum) {
    none,
    kitty_vaxis: KittyVaxisState,
    halfblocks: CachedHalfblocks,
    post_render: PostRenderState,
};

const PresentationState = struct {
    last_key: ?RenderKey = null,
    last_ui_key: ?UiRenderKey = null,
    content: PresentationContent = .none,

    fn deinit(
        self: *PresentationState,
        gpa: std.mem.Allocator,
        vx: *vaxis.Vaxis,
        tty_writer: *std.Io.Writer,
    ) void {
        self.clearImage(gpa, vx, tty_writer);
    }

    fn flushPendingKittyFree(
        self: *PresentationState,
        vx: *vaxis.Vaxis,
        tty_writer: *std.Io.Writer,
    ) void {
        switch (self.content) {
            .kitty_vaxis => |*kv| {
                if (kv.pending_free_id) |old_id| {
                    vx.freeImage(tty_writer, old_id);
                    kv.pending_free_id = null;
                }
            },
            .none, .halfblocks, .post_render => {},
        }
    }

    fn clearContent(
        self: *PresentationState,
        gpa: std.mem.Allocator,
        vx: *vaxis.Vaxis,
        tty_writer: *std.Io.Writer,
    ) void {
        switch (self.content) {
            .none => {},
            .kitty_vaxis => |*kv| {
                if (kv.pending_free_id) |old_id| {
                    vx.freeImage(tty_writer, old_id);
                }
                vx.freeImage(tty_writer, kv.image.id);
            },
            .halfblocks => |*hb| hb.deinit(gpa),
            .post_render => |*pr| {
                if (pr.kitty_fallback) |tr| {
                    emitKittyDeleteFallback(tty_writer, tr);
                }
                pr.payload.deinit(gpa);
            },
        }
        self.content = .none;
    }

    fn clearImage(
        self: *PresentationState,
        gpa: std.mem.Allocator,
        vx: *vaxis.Vaxis,
        tty_writer: *std.Io.Writer,
    ) void {
        self.last_key = null;
        self.clearContent(gpa, vx, tty_writer);
    }

    fn hasActiveContent(self: *const PresentationState) bool {
        return switch (self.content) {
            .none => false,
            .kitty_vaxis, .halfblocks, .post_render => true,
        };
    }

    fn uiImageState(
        self: *const PresentationState,
        has_quad: bool,
    ) UiImageState {
        if (!has_quad) return .none;
        return switch (self.content) {
            .none => .none,
            .kitty_vaxis => |kv| .{
                .kitty = .{ .id = kv.image.id, .crop = kv.crop },
            },
            .halfblocks => |hb| .{ .other = hb.crop },
            .post_render => |pr| .{ .other = pr.crop },
        };
    }

    fn markPostRenderDirty(self: *PresentationState) void {
        switch (self.content) {
            .post_render => |*pr| pr.payload.dirty = true,
            .none, .kitty_vaxis, .halfblocks => {},
        }
    }

    fn ensureHalfblocks(
        self: *PresentationState,
        gpa: std.mem.Allocator,
        vx: *vaxis.Vaxis,
        tty_writer: *std.Io.Writer,
    ) *CachedHalfblocks {
        switch (self.content) {
            .halfblocks => |*hb| return hb,
            .none, .kitty_vaxis, .post_render => {
                self.clearContent(gpa, vx, tty_writer);
                self.content = .{ .halfblocks = .{} };
                return &self.content.halfblocks;
            },
        }
    }

    fn ensurePostRender(
        self: *PresentationState,
        gpa: std.mem.Allocator,
        vx: *vaxis.Vaxis,
        tty_writer: *std.Io.Writer,
        crop: ImageCellCrop,
        pixel_dims: PositiveDimsU32,
        kitty_fallback: ?termgfx.TransportMode,
    ) *CachedPostRenderPayload {
        switch (self.content) {
            .post_render => |*pr| {
                const shrunk = pixel_dims.w < pr.pixel_dims.w or
                    pixel_dims.h < pr.pixel_dims.h;
                if (!pr.crop.eql(crop) or shrunk) {
                    // Wipe stale Sixel/iTerm2/Kitty-fallback margins when the
                    // cropped cell rectangle shifts or pixel extents shrink.
                    if (pr.kitty_fallback) |tr| {
                        emitKittyDeleteFallback(tty_writer, tr);
                    }
                    vx.queueRefresh();
                }
                pr.crop = crop;
                pr.pixel_dims = pixel_dims;
                pr.kitty_fallback = kitty_fallback;
                pr.payload.clear();
                return &pr.payload;
            },
            .none, .kitty_vaxis, .halfblocks => {
                self.clearContent(gpa, vx, tty_writer);
                self.content = .{
                    .post_render = .{
                        .crop = crop,
                        .pixel_dims = pixel_dims,
                        .kitty_fallback = kitty_fallback,
                    },
                };
                return &self.content.post_render.payload;
            },
        }
    }

    fn setKittyImage(
        self: *PresentationState,
        gpa: std.mem.Allocator,
        vx: *vaxis.Vaxis,
        tty_writer: *std.Io.Writer,
        new_img: vaxis.Image,
        crop: ImageCellCrop,
    ) void {
        switch (self.content) {
            .kitty_vaxis => |*kv| {
                // Defer freeing the previous Kitty image until after
                // `vx.render()` places `new_img` inside Synchronized Output,
                // preventing a black flash between `a=d` and `a=p`.
                if (kv.pending_free_id) |old_id| {
                    vx.freeImage(tty_writer, old_id);
                }
                kv.pending_free_id = kv.image.id;
                kv.image = new_img;
                kv.crop = crop;
            },
            .none, .halfblocks, .post_render => {
                self.clearContent(gpa, vx, tty_writer);
                self.content = .{
                    .kitty_vaxis = .{ .image = new_img, .crop = crop },
                };
            },
        }
    }
};

const SlicedReadback = struct {
    readback: MappedReadback,
    crop: ImageCellCrop,
};

/// Returns a zero-copy strided sub-view of `readback` paired with the exact
/// `ImageCellCrop` it covers. Falls back to `readback` + `render_crop` when
/// `present_crop` matches `render_crop` or fails bounds validation.
fn sliceReadbackToCrop(
    readback: MappedReadback,
    render_crop: ImageCellCrop,
    present_crop: ImageCellCrop,
    cell_px: termgfx.CellPixelSize,
) SlicedReadback {
    if (render_crop.eql(present_crop)) {
        return .{ .readback = readback, .crop = render_crop };
    }
    const range = ImageCellCrop.subRectByteRange(
        render_crop,
        present_crop,
        cell_px,
        readback.dims,
        readback.pitch,
        readback.pixels.len,
    ) orelse return .{ .readback = readback, .crop = render_crop };

    var sub = readback;
    sub.pixels = readback.pixels[range.start..range.end];
    sub.dims = present_crop.px;
    return .{ .readback = sub, .crop = present_crop };
}

fn wrapReadbackSurface(readback: MappedReadback) !sdl.Surface {
    const w_i32 = std.math.cast(i32, readback.dims.w) orelse
        return error.InvalidDimensions;
    const h_i32 = std.math.cast(i32, readback.dims.h) orelse
        return error.InvalidDimensions;
    const pitch_i32 = std.math.cast(i32, readback.pitch) orelse
        return error.InvalidPitch;
    return sdl.Surface.createFrom(
        w_i32,
        h_i32,
        sdl.PixelFormat.rgba32,
        @constCast(readback.pixels.ptr),
        pitch_i32,
    ) orelse return error.SurfaceCreationFailed;
}

fn encodeReadbackPng(
    gpa: std.mem.Allocator,
    readback: MappedReadback,
) ![]u8 {
    const surf = try wrapReadbackSurface(readback);
    defer surf.destroy();
    return surf.encodePngAlloc(gpa);
}

fn encodeReadbackIterm2(
    gpa: std.mem.Allocator,
    readback: MappedReadback,
) ![]u8 {
    const surf = try wrapReadbackSurface(readback);
    defer surf.destroy();
    if (try surf.encodeJpegAlloc(gpa, 85)) |jpeg| {
        return jpeg;
    }
    return surf.encodePngAlloc(gpa);
}

fn trimReadbackToVisiblePixels(
    readback: MappedReadback,
    crop: ImageCellCrop,
    visible_rect: FRect,
    cell_px: termgfx.CellPixelSize,
) MappedReadback {
    const trimmed = ImageCellCrop.pixelTrimByteRange(
        crop,
        visible_rect,
        cell_px,
        readback.dims,
        readback.pitch,
        readback.pixels.len,
    ) orelse return readback;
    var sub = readback;
    sub.pixels = readback.pixels[trimmed.start..trimmed.end];
    sub.dims = trimmed.dims;
    return sub;
}

fn transmitFrame(
    gpa: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    io: std.Io,
    vx: *vaxis.Vaxis,
    tty_writer: *std.Io.Writer,
    target: ResolvedTarget,
    layout: ViewportLayout,
    crop: ImageCellCrop,
    visible_rect: FRect,
    readback: MappedReadback,
    pres: *PresentationState,
) !void {
    switch (target.protocol) {
        .halfblocks => {
            const hb = pres.ensureHalfblocks(gpa, vx, tty_writer);
            try hb.update(gpa, readback, crop);
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

                pres.setKittyImage(gpa, vx, tty_writer, new_img, crop);
            } else {
                const payload = pres.ensurePostRender(
                    gpa,
                    vx,
                    tty_writer,
                    crop,
                    readback.dims,
                    target.transport,
                );
                var aw: std.Io.Writer.Allocating = .fromArrayList(
                    gpa,
                    &payload.bytes,
                );
                defer payload.bytes = aw.toArrayList();

                const opts: termgfx.PreviewOptions = .{
                    .transport = target.transport,
                    .cell_dims = .{
                        .cols = crop.cols,
                        .rows = crop.rows,
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
                payload.dirty = true;
            }
        },
        .sixel => {
            const payload = pres.ensurePostRender(
                gpa,
                vx,
                tty_writer,
                crop,
                readback.dims,
                null,
            );
            var aw: std.Io.Writer.Allocating = .fromArrayList(
                gpa,
                &payload.bytes,
            );
            defer payload.bytes = aw.toArrayList();
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
            payload.dirty = true;
        },
        .iterm2 => {
            // Trim sub-cell transparent padding before JPEG encoding so opaque
            // JPEG frames don't show a thin black border around the image.
            const trimmed_rb = trimReadbackToVisiblePixels(
                readback,
                crop,
                visible_rect,
                layout.cell_px,
            );
            const payload = pres.ensurePostRender(
                gpa,
                vx,
                tty_writer,
                crop,
                trimmed_rb.dims,
                null,
            );
            const img_bytes = try encodeReadbackIterm2(
                frame_allocator,
                trimmed_rb,
            );
            defer frame_allocator.free(img_bytes);
            var aw: std.Io.Writer.Allocating = .fromArrayList(
                gpa,
                &payload.bytes,
            );
            defer payload.bytes = aw.toArrayList();
            try termgfx.writePreview(
                &aw.writer,
                .{
                    .iterm2 = .{
                        .image_bytes = img_bytes,
                        .dims = trimmed_rb.dims,
                    },
                },
                .{ .transport = target.transport },
            );
            try aw.writer.flush();
            payload.dirty = true;
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
        .notification = if (app_state.viewer.animations.get(.snackbar) > 0.001)
            app_state.viewer.ui.snackbar.getMessage()
        else
            "",
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

    const filter_name = vp.scale_filter.shortLabel();

    const zoom_pct: u32 = if (std.math.isFinite(vp.zoom_factor.get()) and
        vp.zoom_factor.get() > 0.0)
        @intFromFloat(@min(@round(vp.zoom_factor.get() * 100.0), 99999.0))
    else
        100;
    const rot_deg: i32 = if (std.math.isFinite(vp.rotation_angle))
        @intFromFloat(@mod(@round(vp.rotation_angle), 360.0))
    else
        0;

    const size_bytes: ?u64 = if (cache_opt) |c|
        c.resident.asset.diskSizeBytes()
    else
        null;

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

fn protocolDisplayLabel(target: ResolvedTarget) []const u8 {
    return switch (target.protocol) {
        .kitty => switch (target.transport) {
            .direct => if (target.is_remote)
                "Kitty (SSH PNG)"
            else
                "Kitty (local)",
            .tmux_passthrough,
            .tmux_unicode_placeholders,
            => "Kitty (tmux)",
        },
        .sixel => "Sixel",
        .iterm2 => "iTerm2",
        .halfblocks => "Halfblocks (SIMD)",
    };
}

fn buildStatsModel(
    app_state: *const AppState,
    target: ResolvedTarget,
    layout: ViewportLayout,
    last_gpu_pass_ms: f64,
    last_term_encode_ms: f64,
) tui.overlays.StatsModel {
    const cache_opt = app_state.getCurrentEntry();
    var read_ms: f64 = 0.0;
    var decode_ms: f64 = 0.0;
    var upload_ms: f64 = 0.0;
    var vram_bytes: u64 = 0;

    if (cache_opt) |c| {
        if (c.resident.asset.decodeTelemetry()) |d| {
            read_ms = d.read_time_ms;
            decode_ms = d.decode_time_ms;
        }
        if (c.resident.asset.activeGpu()) |g| {
            upload_ms = g.ingest.upload_time_ms;
            vram_bytes = g.ingest.memory_size_bytes;
        }
    }

    return .{
        .protocol_label = protocolDisplayLabel(target),
        .viewport_cols = layout.image_cols,
        .viewport_rows = layout.image_rows,
        .viewport_px_w = layout.image_px.w,
        .viewport_px_h = layout.image_px.h,
        .cell_px_w = layout.cell_px.w,
        .cell_px_h = layout.cell_px.h,
        .gpu_pass_ms = last_gpu_pass_ms,
        .term_encode_ms = last_term_encode_ms,
        .read_ms = read_ms,
        .decode_ms = decode_ms,
        .upload_ms = upload_ms,
        .vram_bytes = vram_bytes,
        .cached_entries = app_state.cache.slots.len,
        .total_images = app_state.viewer.navigation.items.len,
        .debug_show_thumb = app_state.viewer.ui.overlays.debug_show_thumb,
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

    var cli = parseProcessArgs(init) catch |err| {
        std.log.err("Invalid arguments ({s}). Use --help for usage.", .{
            @errorName(err),
        });
        std.process.exit(1);
    };
    defer cli.deinit(gpa);

    if (cli.help) {
        tui.cli.printHelp(io);
        return;
    }

    if (cli.log_file) |log_path| {
        const f = std.Io.Dir.cwd().createFile(io, log_path, .{
            .truncate = true,
        }) catch |err| {
            std.log.err("Failed to open log file '{s}': {s}", .{
                log_path,
                @errorName(err),
            });
            std.process.exit(1);
        };
        tui_log_io = io;
        tui_log_mutex.lockUncancelable(io);
        tui_log_file = f;
        tui_log_mutex.unlock(io);
        tui_log_file_enabled.store(true, .release);
    }
    defer if (tui_log_file_enabled.swap(false, .acq_rel)) {
        const log_io = tui_log_io.?;
        tui_log_mutex.lockUncancelable(log_io);
        const f_opt = tui_log_file;
        tui_log_file = null;
        tui_log_mutex.unlock(log_io);
        if (f_opt) |f| f.close(log_io);
    };

    const selections_tsv = try runTuiSession(init, cli);
    defer if (selections_tsv) |tsv| gpa.free(tsv);

    // Emit TSV classifications to stdout strictly after alt-screen teardown
    // so piped shell workflows receive clean `PICK\t<path>` / `REJECT\t<path>`.
    if (selections_tsv) |tsv| {
        var out_buf: [4096]u8 = undefined;
        var out_w = std.Io.File.stdout().writerStreaming(io, &out_buf);
        out_w.interface.writeAll(tsv) catch {};
        out_w.interface.flush() catch {};
    }
}

fn runTuiSession(init: std.process.Init, cli: TuiCliArgs) !?[]u8 {
    const gpa = init.gpa;
    const io = init.io;

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

    var vx = try vaxis.init(io, gpa, init.environ_map, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
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

    var app_state: AppState = undefined;
    try app_state.initInPlace(gpa, io, .{
        .defaults = .{
            .default_scale = cli.default_scale,
            .animations = .disabled,
            .snackbar_enabled = true,
            .auto_title = false,
            .stack_raw_jpeg = cli.stack_raw_jpeg,
        },
        .visibility = .visible,
        .gpu = if (renderer.gpuDevice()) |dev|
            .{ .ready = dev }
        else
            .disabled,
        .waker = .{
            .callback = .{
                .ctx = &loop,
                .wake_fn = wakeVaxisLoop,
            },
        },
    });
    defer {
        app_state.workers.exiting.store(true, .release);
        app_state.deinit();
    }
    app_state.viewer.ui.palette.hide_gui_only_actions = true;
    app_state.viewer.viewport.scale_filter = cli.scale_filter;
    if (cli.slideshow_interval_s) |secs| {
        app_state.viewer.navigation.slideshow = .{
            .active = .{ .interval_s = secs },
        };
    }
    app_state.initThumbCache(init.environ_map, cli.thumb_cache, .normal);

    const start_ms = state_pkg.timestampToMs(std.Io.Clock.awake.now(io));
    try app_state.openInitialTarget(cli.path, start_ms);

    var winsize: vaxis.Winsize = tty.getWinsize() catch .{
        .cols = 80,
        .rows = 24,
        .x_pixel = 0,
        .y_pixel = 0,
    };
    try vx.resize(gpa, tty.writer(), winsize);

    var infobar_pos = cli.infobar;
    var last_visible_infobar: InfobarPosition = switch (infobar_pos) {
        .bottom, .top => infobar_pos,
        .none => .bottom,
    };
    const initial_pinned = switch (infobar_pos) {
        .bottom, .top => true,
        .none => false,
    };
    app_state.viewer.ui.overlays.title_display = if (initial_pinned)
        .pinned
    else
        .hidden;
    var prev_title_pinned = initial_pinned;
    var last_gpu_pass_ms: f64 = 0.0;
    var last_term_encode_ms: f64 = 0.0;
    var pres: PresentationState = .{};
    defer pres.deinit(gpa, &vx, tty.writer());

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    var last_frame_ms = start_ms;
    var mouse_left_down = false;
    var last_mouse_x: f32 = 0.0;
    var last_mouse_y: f32 = 0.0;
    var directional_held: state_pkg.DirectionFlags = .{};
    var prev_overlay_open = false;
    var unpack_warmed = false;

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

        const text_capture = app_state.viewer.ui.palette.isAcceptingInput();
        if (text_capture) {
            directional_held = .{};
        }
        var acc = InputAccumulator.init(
            frame_alloc,
            mouse_left_down,
            last_mouse_x,
            last_mouse_y,
        ).withDirectionalHeld(directional_held, vx.caps.kitty_keyboard);
        defer acc.deinit();

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
                .key_release => |k| acc.handleKeyRelease(k),
                .mouse => |m| acc.handleMouse(m, cell_w_f, cell_h_f),
                .winsize => |ws| {
                    winsize = ws;
                    resized = true;
                },
                .focus_out => acc.clearHeld(),
                .focus_in, .worker_ready, .timer_tick => {},
            }
            ev_opt = loop.tryEvent() catch |err| switch (err) {
                error.Closed => break,
                else => return err,
            };
        }

        if (resized) {
            try vx.resize(gpa, tty.writer(), winsize);
            pres.markPostRenderDirty();
        }
        if (acc.local_actions.cycle_infobar) {
            infobar_pos = infobar_pos.next();
            switch (infobar_pos) {
                .bottom, .top => {
                    last_visible_infobar = infobar_pos;
                    app_state.viewer.ui.overlays.title_display = .pinned;
                    prev_title_pinned = true;
                },
                .none => {
                    app_state.viewer.ui.overlays.title_display = .hidden;
                    prev_title_pinned = false;
                },
            }
            pres.markPostRenderDirty();
        }
        if (acc.local_actions.open_file_search) {
            try app_state.pushIntent(.{ .set_palette = .{ .mode = .files } });
        }

        mouse_left_down = acc.mouse_left_down;
        last_mouse_x = acc.mouse_x;
        last_mouse_y = acc.mouse_y;
        directional_held = acc.directional_held;

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
            false,
        );
        if (!app_state.viewer.running) break;

        // Sync `toggle_title` / `set_title` intents with the TUI infobar.
        const now_title_pinned =
            app_state.viewer.ui.overlays.title_display.isPinned();
        if (now_title_pinned != prev_title_pinned) {
            prev_title_pinned = now_title_pinned;
            if (now_title_pinned) {
                infobar_pos = last_visible_infobar;
            } else {
                switch (infobar_pos) {
                    .bottom, .top => last_visible_infobar = infobar_pos,
                    .none => {},
                }
                infobar_pos = .none;
            }
            pres.markPostRenderDirty();
        }

        const render_layout = ViewportLayout.compute(winsize, infobar_pos);
        app_state.viewer.last_win_dims = .{
            .w = @floatFromInt(render_layout.image_px.w),
            .h = @floatFromInt(render_layout.image_px.h),
        };

        var image_changed = false;
        const active_quad = resolveActiveImageQuad(&app_state, render_layout);
        if (active_quad) |active| {
            const key = RenderKey.init(
                active.tex,
                render_layout,
                active.render_crop,
                active.present_crop,
                active.quad,
            );
            const dirty = pres.last_key == null or
                !pres.last_key.?.eql(key);
            if (dirty) {
                const frame_res = try renderer.renderImageReadback(
                    gpa,
                    frame_alloc,
                    active.quad,
                    active.render_crop.px,
                );
                defer frame_res.readback.deinit();
                last_gpu_pass_ms = frame_res.timings.total_pass_ms;

                const sliced = sliceReadbackToCrop(
                    frame_res.readback,
                    active.render_crop,
                    active.present_crop,
                    render_layout.cell_px,
                );

                const enc_start = std.Io.Clock.awake.now(io);
                try transmitFrame(
                    gpa,
                    frame_alloc,
                    io,
                    &vx,
                    tty.writer(),
                    target,
                    render_layout,
                    sliced.crop,
                    active.visible_rect,
                    sliced.readback,
                    &pres,
                );
                const enc_end = std.Io.Clock.awake.now(io);
                switch (target.protocol) {
                    .kitty, .sixel, .iterm2 => {
                        last_term_encode_ms = state_pkg.durationToMs(
                            enc_start.durationTo(enc_end),
                        );
                    },
                    .halfblocks => {},
                }
                pres.last_key = key;
                image_changed = true;
            }
        } else if (pres.last_key != null or pres.hasActiveContent()) {
            pres.clearImage(gpa, &vx, tty.writer());
            image_changed = true;
        }

        var active_overlay: ActiveOverlay = if (app_state.viewer.ui.palette
            .isAcceptingInput())
            .palette
        else if (app_state.viewer.ui.overlays.stats_panel.visible)
            .{
                .stats = buildStatsModel(
                    &app_state,
                    target,
                    render_layout,
                    last_gpu_pass_ms,
                    last_term_encode_ms,
                ),
            }
        else if (app_state.viewer.ui.overlays.info_panel.visible)
            .{ .details = buildDetailsModel(&app_state) }
        else
            .none;
        const overlay_open = active_overlay.isOpen();
        const ui_image = pres.uiImageState(active_quad != null);

        const infobar_model = buildInfobarModel(&app_state);
        const ui_key = UiRenderKey.init(
            render_layout,
            infobar_pos,
            ui_image,
            infobar_model,
            &app_state,
            active_overlay,
        );
        const ui_dirty = resized or image_changed or
            pres.last_ui_key == null or
            !pres.last_ui_key.?.eql(ui_key);

        if (ui_dirty) {
            const root_win = vx.window();
            root_win.clear();
            const image_win = render_layout.imageWindow(root_win);

            if (active_quad != null) switch (pres.content) {
                .kitty_vaxis => |kv| {
                    // z < -1_073_741_824 places the image beneath both text
                    // and non-default cell backgrounds (Kitty spec), so modals
                    // with explicit RGB backgrounds render opaque while
                    // `.default` viewport cells let the image show through.
                    try kv.image.draw(kv.crop.subWindow(image_win), .{
                        .z_index = -1_073_741_825,
                        .size = .{
                            .cols = kv.crop.cols,
                            .rows = kv.crop.rows,
                        },
                    });
                },
                .halfblocks => |hb| {
                    if (hb.pixels.len > 0) {
                        const blit_start = std.Io.Clock.awake.now(io);
                        tui.canvas.blitHalfblocksToWindow(
                            hb.crop.subWindow(image_win),
                            hb.pixels,
                            hb.pitch,
                            hb.dims,
                        );
                        const blit_end = std.Io.Clock.awake.now(io);
                        last_term_encode_ms = state_pkg.durationToMs(
                            blit_start.durationTo(blit_end),
                        );
                        switch (active_overlay) {
                            .stats => |*sm| {
                                sm.term_encode_ms = last_term_encode_ms;
                            },
                            .none, .palette, .details => {},
                        }
                    }
                },
                .none, .post_render => {},
            };

            if (render_layout.infobarWindow(root_win)) |bar| {
                tui.infobar.render(bar, infobar_model, frame_alloc);
            }

            switch (active_overlay) {
                .none => {},
                .palette => {
                    const nav_slice = app_state.viewer.navigation.items.slice();
                    tui.overlays.renderPalette(
                        image_win,
                        &app_state.viewer.ui.palette,
                        nav_slice.items(.entry),
                        nav_slice.items(.classification),
                        frame_alloc,
                    );
                },
                .stats => |sm| {
                    tui.overlays.renderStats(image_win, sm, frame_alloc);
                },
                .details => |dm| {
                    tui.overlays.renderDetails(image_win, dm, frame_alloc);
                },
            }

            if (!prev_overlay_open and overlay_open) {
                // Only Kitty fallback (`a=T` at z=0) draws above text cells
                // and requires clearing before opening a modal. iTerm2 and
                // Sixel cells outside the modal rect stay visible when vaxis
                // diffs only the modal cells over them.
                switch (pres.content) {
                    .post_render => |pr| {
                        if (pr.kitty_fallback) |tr| {
                            emitKittyDeleteFallback(tty.writer(), tr);
                            vx.queueRefresh();
                        }
                    },
                    .none, .kitty_vaxis, .halfblocks => {},
                }
            } else if (prev_overlay_open and !overlay_open) {
                pres.markPostRenderDirty();
            }
            prev_overlay_open = overlay_open;

            // Do not fuse `tmux_passthrough` inside tmux's DEC 2026 block:
            // tmux forwards passthrough directly while deferring pane cell
            // clears until `sync_reset`, which would overwrite the image.
            const transport_allows_fuse = switch (target.transport) {
                .direct, .tmux_unicode_placeholders => true,
                .tmux_passthrough => false,
            };
            const fuse_post_render = transport_allows_fuse and
                switch (pres.content) {
                    .post_render => |pr| !overlay_open and pr.payload.dirty and
                        pr.payload.bytes.items.len > 0,
                    .none, .kitty_vaxis, .halfblocks => false,
                };
            if (fuse_post_render) {
                var ui_buf: std.Io.Writer.Allocating = .init(frame_alloc);
                defer ui_buf.deinit();
                try vx.render(&ui_buf.writer);
                switch (pres.content) {
                    .post_render => |*pr| {
                        try writePostRenderSync(
                            tty.writer(),
                            ui_buf.written(),
                            render_layout.image_row,
                            pr.crop,
                            pr.payload.bytes.items,
                        );
                        pr.payload.dirty = false;
                    },
                    .none, .kitty_vaxis, .halfblocks => unreachable,
                }
            } else {
                try vx.render(tty.writer());
                pres.flushPendingKittyFree(&vx, tty.writer());
            }
            pres.last_ui_key = ui_key;
        }

        switch (pres.content) {
            .post_render => |*pr| {
                if (!overlay_open and pr.payload.dirty and
                    pr.payload.bytes.items.len > 0)
                {
                    try writePostRenderSync(
                        tty.writer(),
                        "",
                        render_layout.image_row,
                        pr.crop,
                        pr.payload.bytes.items,
                    );
                    pr.payload.dirty = false;
                }
            },
            .none, .kitty_vaxis, .halfblocks => {},
        }

        // Lazily warm the RGB24 compute unpack pipeline after the first image
        // is presented so cold-start time-to-first-pixel is never blocked.
        if (!unpack_warmed and image_changed) {
            unpack_warmed = true;
            app_state.unpack_compute_pipeline = renderer.ensureUnpackPipeline();
        }
    }

    if (!app_state.viewer.navigation.triage.hasAnySelections()) return null;
    var tsv: std.Io.Writer.Allocating = .init(gpa);
    errdefer tsv.deinit();
    try app_state.viewer.navigation.writeSelectionsTsv(&tsv.writer);
    try tsv.writer.flush();
    return try tsv.toOwnedSlice();
}
