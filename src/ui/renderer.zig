const geom = @import("geom");
const gpu_pkg = @import("gpu");
const state = @import("state");
const std = @import("std");
const theme = @import("theme.zig");

const addBatch = gpu_pkg.pass.addBatch;
const BatchItem = gpu_pkg.render_image.BatchItem;
const Color = theme.Color;
const ElementTag = state.ElementTag;
const ensureFontSizePage = gpu_pkg.pass.ensureFontSizePage;
const ensureUiAtlasTexture = gpu_pkg.pass.ensureUiAtlasTexture;
const FRect = geom.FRect;
const getOrRasterizeGlyph = gpu_pkg.pass.getOrRasterizeGlyph;
const GlyphCacheValue = gpu_pkg.text_cache.GlyphCacheValue;
const intersectScissor = gpu_pkg.pass.intersectScissor;
const isScissorInvisible = gpu_pkg.pass.isScissorInvisible;
const PacketBuildContext = gpu_pkg.pass.PacketBuildContext;
const packRgba255 = gpu_pkg.geometry.packRgba255;
const PhysicalDims = geom.PhysicalDims;
const Rect = geom.Rect;
const render_image = gpu_pkg.render_image;
const RenderPacket = gpu_pkg.pass.RenderPacket;
const RenderResources = gpu_pkg.graphics.RenderResources;
const TextureRef = gpu_pkg.TextureRef;
const UiQuadInstance = gpu_pkg.geometry.UiQuadInstance;
const UvRect = geom.UvRect;
const Vertex = gpu_pkg.geometry.Vertex;
const ViewportParams = state.ViewportParams;

/// Corner radii in logical UI points.
pub const CornerRadius = struct {
    top_left: f32 = 0.0,
    top_right: f32 = 0.0,
    bottom_left: f32 = 0.0,
    bottom_right: f32 = 0.0,

    /// Returns uniform corner radii across all four corners.
    pub inline fn all(radius: f32) CornerRadius {
        return .{
            .top_left = radius,
            .top_right = radius,
            .bottom_left = radius,
            .bottom_right = radius,
        };
    }
};

/// Border stroke widths per edge in logical UI points.
pub const BorderWidth = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    /// Returns uniform stroke widths across all four edges.
    pub inline fn all(width: u16) BorderWidth {
        return .{
            .left = width,
            .right = width,
            .top = width,
            .bottom = width,
        };
    }
};

/// Configuration for filled rectangle UI render commands.
pub const RectConfig = struct {
    background_color: Color,
    corner_radius: CornerRadius = .{},
    tag: ElementTag = .none,
};

/// Configuration for outlined border UI render commands.
pub const BorderConfig = struct {
    color: Color,
    width: BorderWidth = .{},
    corner_radius: CornerRadius = .{},
    tag: ElementTag = .none,
};

/// Configuration for single-string text UI render commands.
pub const TextConfig = struct {
    text: []const u8,
    color: Color,
    font_size: u16 = 13,
    font_id: u16 = 0,
    /// When true, centers the string vertically inside `rect` using its actual
    /// glyph ink bounds rather than the font's full line-box height (ideal for
    /// pill badges, key caps, and buttons).
    optical_center: bool = false,
};

/// Styled sub-slice span for multi-color text runs.
pub const TextSpan = struct {
    text: []const u8,
    color: Color,
};

/// Configuration for contiguous multi-span styled text runs.
pub const TextRunsConfig = struct {
    spans: []const TextSpan,
    font_size: u16 = 13,
    font_id: u16 = 0,
};

/// Configuration for textured image quad render commands.
pub const ImageConfig = struct {
    texture: TextureRef,
    uv: UvRect = .{},
};

/// Configuration for analytic SDF close (`×`) icon render commands.
pub const CloseIconConfig = struct {
    color: Color,
    stroke_width: f32 = 1.5,
};

/// Variant payload for pure-Zig immediate-mode UI draw commands.
pub const CommandPayload = union(enum) {
    scissor_start,
    scissor_end,
    rectangle: RectConfig,
    border: BorderConfig,
    close_icon: CloseIconConfig,
    text: TextConfig,
    text_runs: TextRunsConfig,
    image: ImageConfig,
    atlas_preview: Color,
};

/// Immediate-mode UI draw command with bounding rectangle and payload.
pub const UiCommand = struct {
    rect: FRect = .{},
    payload: CommandPayload,
};

/// Flat command list buffer accumulating immediate-mode UI draw commands.
pub const UiDrawList = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(UiCommand) = .empty,

    /// Appends a command to the draw list.
    pub fn append(self: *UiDrawList, cmd: UiCommand) !void {
        try self.commands.append(self.allocator, cmd);
    }

    /// Reserves an empty command slot and returns its index.
    pub fn reserve(self: *UiDrawList) !usize {
        const idx = self.commands.items.len;
        try self.commands.append(self.allocator, .{
            .rect = .{},
            .payload = .scissor_end,
        });
        return idx;
    }

    /// Overwrites a previously reserved command slot at `index`.
    pub fn set(self: *UiDrawList, index: usize, cmd: UiCommand) void {
        self.commands.items[index] = cmd;
    }

    /// Appends a filled rectangle command.
    pub fn addRect(
        self: *UiDrawList,
        rect: FRect,
        config: RectConfig,
    ) !void {
        try self.append(.{
            .rect = rect,
            .payload = .{ .rectangle = config },
        });
    }

    /// Appends an outlined border command.
    pub fn addBorder(
        self: *UiDrawList,
        rect: FRect,
        config: BorderConfig,
    ) !void {
        try self.append(.{
            .rect = rect,
            .payload = .{ .border = config },
        });
    }

    /// Appends an analytic SDF close (`×`) icon command centered inside `rect`.
    pub fn addCloseIcon(
        self: *UiDrawList,
        rect: FRect,
        config: CloseIconConfig,
    ) !void {
        try self.append(.{
            .rect = rect,
            .payload = .{ .close_icon = config },
        });
    }

    /// Appends a filled rectangle and border in one call.
    pub fn addBox(
        self: *UiDrawList,
        rect: FRect,
        bg_color: Color,
        corner_radius: CornerRadius,
        border_color: Color,
        border_width: BorderWidth,
        tag: ElementTag,
    ) !void {
        try self.addRect(rect, .{
            .background_color = bg_color,
            .corner_radius = corner_radius,
            .tag = tag,
        });
        try self.addBorder(rect, .{
            .color = border_color,
            .width = border_width,
            .corner_radius = corner_radius,
            .tag = tag,
        });
    }

    /// Appends a single-color text command.
    pub fn addText(
        self: *UiDrawList,
        rect: FRect,
        config: TextConfig,
    ) !void {
        try self.append(.{
            .rect = rect,
            .payload = .{ .text = config },
        });
    }

    /// Appends a multi-span styled text runs command.
    pub fn addTextRuns(
        self: *UiDrawList,
        rect: FRect,
        config: TextRunsConfig,
    ) !void {
        try self.append(.{
            .rect = rect,
            .payload = .{ .text_runs = config },
        });
    }

    /// Appends a textured image quad command.
    pub fn addImage(
        self: *UiDrawList,
        rect: FRect,
        config: ImageConfig,
    ) !void {
        try self.append(.{
            .rect = rect,
            .payload = .{ .image = config },
        });
    }

    /// Appends a quad sampling the full `(0.0, 0.0)..(1.0, 1.0)` UV range of
    /// the unified UI + font glyph atlas texture tinted by `tint`.
    pub fn addAtlasPreview(
        self: *UiDrawList,
        rect: FRect,
        tint: Color,
    ) !void {
        try self.append(.{
            .rect = rect,
            .payload = .{ .atlas_preview = tint },
        });
    }

    /// Pushes a scissor clipping rectangle command.
    pub fn pushScissor(self: *UiDrawList, rect: FRect) !void {
        try self.append(.{
            .rect = rect,
            .payload = .scissor_start,
        });
    }

    /// Pops the most recent scissor clipping rectangle command.
    pub fn popScissor(self: *UiDrawList) !void {
        try self.append(.{
            .rect = .{},
            .payload = .scissor_end,
        });
    }
};

/// Returns true if any render command in the slice renders a blurred surface.
pub fn hasBlurredSurface(r_commands: []const UiCommand) bool {
    for (r_commands) |rcmd| {
        if (rcmd.payload == .rectangle and
            rcmd.payload.rectangle.tag == .blurred_surface)
        {
            return true;
        }
    }
    return false;
}

fn appendRectangleCommand(
    instances: *std.ArrayList(UiQuadInstance),
    batches: *std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,
    rect: FRect,
    config: RectConfig,
    scale_x: f32,
    gpu_res: *const RenderResources,
    scissor: ?Rect,
) !void {
    if (rect.w <= 0.0 or rect.h <= 0.0) return;

    const active_blur_tex = if (config.tag == .blurred_surface)
        gpu_res.blur.getBlurTexture()
    else
        null;
    const is_blurred = active_blur_tex != null;

    const min_radius = @min(rect.w, rect.h) * 0.5;
    const start = @as(u32, @intCast(instances.items.len));
    try instances.append(allocator, .{
        .rect = .{ rect.x, rect.y, rect.w, rect.h },
        .radii = .{
            @min(config.corner_radius.top_right * scale_x, min_radius),
            @min(config.corner_radius.bottom_right * scale_x, min_radius),
            @min(config.corner_radius.top_left * scale_x, min_radius),
            @min(config.corner_radius.bottom_left * scale_x, min_radius),
        },
        .fill_color = packRgba255(config.background_color),
        .flags = if (is_blurred) UiQuadInstance.flag_blur else 0.0,
    });

    if (active_blur_tex) |btex| {
        try addBatch(
            batches,
            allocator,
            start,
            1,
            btex,
            .blurred_surface,
            scissor,
        );
    } else {
        try addBatch(
            batches,
            allocator,
            start,
            1,
            gpu_res.uiTexture(),
            .sdf_ui,
            scissor,
        );
    }
}

fn appendBorderCommand(
    instances: *std.ArrayList(UiQuadInstance),
    batches: *std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,
    rect: FRect,
    config: BorderConfig,
    scale_x: f32,
    gpu_res: *const RenderResources,
    scissor: ?Rect,
) !void {
    if (rect.w <= 0.0 or rect.h <= 0.0) return;

    const min_radius = @min(rect.w, rect.h) * 0.5;
    const border_left = @as(f32, @floatFromInt(config.width.left)) * scale_x;
    const border_right = @as(f32, @floatFromInt(config.width.right)) * scale_x;
    const border_top = @as(f32, @floatFromInt(config.width.top)) * scale_x;
    const border_bottom =
        @as(f32, @floatFromInt(config.width.bottom)) * scale_x;
    if (border_left <= 0.0 and border_right <= 0.0 and
        border_top <= 0.0 and border_bottom <= 0.0)
    {
        return;
    }

    const flags = UiQuadInstance.flag_border_only +
        if (config.tag == .drop_zone_box) UiQuadInstance.flag_dashed else 0.0;
    const start = @as(u32, @intCast(instances.items.len));
    try instances.append(allocator, .{
        .rect = .{ rect.x, rect.y, rect.w, rect.h },
        .radii = .{
            @min(config.corner_radius.top_right * scale_x, min_radius),
            @min(config.corner_radius.bottom_right * scale_x, min_radius),
            @min(config.corner_radius.top_left * scale_x, min_radius),
            @min(config.corner_radius.bottom_left * scale_x, min_radius),
        },
        .border = .{
            border_left,
            border_top,
            border_right,
            border_bottom,
        },
        .border_color = packRgba255(config.color),
        .flags = flags,
    });
    try addBatch(
        batches,
        allocator,
        start,
        1,
        gpu_res.uiTexture(),
        .sdf_ui,
        scissor,
    );
}

fn appendSingleTextRun(
    vertices: *std.ArrayList(Vertex),
    batches: *std.ArrayList(BatchItem),
    build_ctx: PacketBuildContext,
    rect: FRect,
    world_x: *f32,
    font_id: u16,
    font_size: u16,
    raw_text: []const u8,
    color: Color,
    optical_center: bool,
    current_scissor: ?Rect,
) !void {
    var text_slice = raw_text;
    if (std.mem.findScalar(u8, text_slice, 0)) |null_idx| {
        text_slice = text_slice[0..null_idx];
    }
    if (text_slice.len == 0) return;

    const target_font_size =
        @as(f32, @floatFromInt(font_size)) * build_ctx.scale.x;
    const target_font_size_u16 =
        @as(u16, @intFromFloat(@round(target_font_size)));
    const page_opt = ensureFontSizePage(
        build_ctx,
        font_id,
        target_font_size,
        target_font_size_u16,
    );
    if (page_opt == null and
        (font_id >= build_ctx.gpu_res.fonts.len or
            build_ctx.gpu_res.fonts[font_id] == null))
    {
        return;
    }

    const line_h = if (page_opt) |p| p.line_height else 0.0;
    const offset_y = @round((rect.h - line_h) / 2.0);
    const world_y = rect.y + @max(0.0, offset_y);
    const win_dims = build_ctx.physical_dims;
    const inv_win_w = 2.0 / win_dims.w;
    const inv_win_h = 2.0 / win_dims.h;

    const vert_color = packRgba255(color);
    const start_vert = @as(u32, @intCast(vertices.items.len));
    try vertices.ensureUnusedCapacity(
        build_ctx.frame_allocator,
        text_slice.len * 6,
    );

    var min_ink_y: f32 = std.math.inf(f32);
    var max_ink_y: f32 = -std.math.inf(f32);
    var byte_idx: usize = 0;
    while (byte_idx < text_slice.len) {
        const first_byte = text_slice[byte_idx];
        const glyph: GlyphCacheValue = if (first_byte < 0x80) blk: {
            byte_idx += 1;
            if (page_opt) |page| {
                const cached = page.ascii[first_byte];
                if (cached.cached) break :blk cached;
            }
            break :blk (try getOrRasterizeGlyph(
                build_ctx,
                font_id,
                target_font_size,
                target_font_size_u16,
                first_byte,
            )) orelse continue;
        } else blk: {
            const cp_len = std.unicode.utf8ByteSequenceLength(
                first_byte,
            ) catch 1;
            const cp: u32 = if (byte_idx + cp_len <= text_slice.len)
                std.unicode.utf8Decode(
                    text_slice[byte_idx .. byte_idx + cp_len],
                ) catch 0xFFFD
            else
                0xFFFD;
            byte_idx += @min(cp_len, text_slice.len - byte_idx);
            break :blk (try getOrRasterizeGlyph(
                build_ctx,
                font_id,
                target_font_size,
                target_font_size_u16,
                cp,
            )) orelse continue;
        };

        if (glyph.has_pixels) {
            min_ink_y = @min(min_ink_y, glyph.offset_y);
            max_ink_y = @max(max_ink_y, glyph.offset_y + glyph.h);
            const gx = world_x.* + glyph.offset_x;
            const gy = world_y + glyph.offset_y;
            const x1 = gx * inv_win_w - 1.0;
            const x2 = (gx + glyph.w) * inv_win_w - 1.0;
            const y1 = 1.0 - gy * inv_win_h;
            const y2 = 1.0 - (gy + glyph.h) * inv_win_h;

            vertices.addManyAsArrayAssumeCapacity(6).* = .{
                .{
                    .x = x1,
                    .y = y1,
                    .u = glyph.u1,
                    .v = glyph.v1,
                    .color = vert_color,
                },
                .{
                    .x = x2,
                    .y = y1,
                    .u = glyph.u2,
                    .v = glyph.v1,
                    .color = vert_color,
                },
                .{
                    .x = x1,
                    .y = y2,
                    .u = glyph.u1,
                    .v = glyph.v2,
                    .color = vert_color,
                },
                .{
                    .x = x2,
                    .y = y1,
                    .u = glyph.u2,
                    .v = glyph.v1,
                    .color = vert_color,
                },
                .{
                    .x = x2,
                    .y = y2,
                    .u = glyph.u2,
                    .v = glyph.v2,
                    .color = vert_color,
                },
                .{
                    .x = x1,
                    .y = y2,
                    .u = glyph.u1,
                    .v = glyph.v2,
                    .color = vert_color,
                },
            };
        }
        world_x.* += glyph.advance;
    }

    const vert_count = @as(u32, @intCast(vertices.items.len)) - start_vert;
    if (optical_center and vert_count > 0 and max_ink_y > min_ink_y) {
        const ink_h = max_ink_y - min_ink_y;
        const opt_y = rect.y + @round((rect.h - ink_h) * 0.5 - min_ink_y);
        const dy_ndc = (world_y - opt_y) * inv_win_h;
        if (dy_ndc != 0.0) {
            for (vertices.items[start_vert..]) |*v| {
                v.y += dy_ndc;
            }
        }
    }
    if (vert_count > 0) {
        try addBatch(
            batches,
            build_ctx.frame_allocator,
            start_vert,
            vert_count,
            build_ctx.gpu_res.uiTexture(),
            .glyph,
            current_scissor,
        );
    }
}

fn buildGeometryFromCommands(
    view_params: ViewportParams,
    build_ctx: PacketBuildContext,
    r_commands: []const UiCommand,
    vertices: *std.ArrayList(Vertex),
    instances: *std.ArrayList(UiQuadInstance),
    batches: *std.ArrayList(BatchItem),
) !void {
    _ = ensureUiAtlasTexture(build_ctx);
    const win_dims = build_ctx.physical_dims;
    const scale_x = build_ctx.scale.x;
    const scale_y = build_ctx.scale.y;
    const target_sc = Rect{
        .x = 0,
        .y = 0,
        .w = @intFromFloat(@max(0.0, @round(win_dims.w))),
        .h = @intFromFloat(@max(0.0, @round(win_dims.h))),
    };

    var current_scissor: ?Rect = null;
    var scissor_stack: std.ArrayList(Rect) = .empty;
    defer scissor_stack.deinit(build_ctx.frame_allocator);

    for (r_commands) |rcmd| {
        const rect = FRect{
            .x = @round(rcmd.rect.x * scale_x),
            .y = @round(rcmd.rect.y * scale_y),
            .w = @round(rcmd.rect.w * scale_x),
            .h = @round(rcmd.rect.h * scale_y),
        };

        switch (rcmd.payload) {
            .scissor_start => {
                const raw_sc = Rect{
                    .x = @intFromFloat(@round(rcmd.rect.x * scale_x)),
                    .y = @intFromFloat(@round(rcmd.rect.y * scale_y)),
                    .w = @intFromFloat(@round(rcmd.rect.w * scale_x)),
                    .h = @intFromFloat(@round(rcmd.rect.h * scale_y)),
                };
                const parent_sc = if (scissor_stack.items.len > 0)
                    scissor_stack.items[scissor_stack.items.len - 1]
                else
                    target_sc;
                const eff_sc = intersectScissor(parent_sc, raw_sc);
                try scissor_stack.append(build_ctx.frame_allocator, eff_sc);
                current_scissor = eff_sc;
                continue;
            },
            .scissor_end => {
                if (scissor_stack.items.len > 0) {
                    _ = scissor_stack.pop();
                    current_scissor = if (scissor_stack.items.len > 0)
                        scissor_stack.items[scissor_stack.items.len - 1]
                    else
                        null;
                } else {
                    current_scissor = null;
                }
                continue;
            },
            else => {},
        }

        if (isScissorInvisible(
            current_scissor,
            win_dims,
        )) continue;

        switch (rcmd.payload) {
            .scissor_start, .scissor_end => unreachable,
            .rectangle => |config| {
                try appendRectangleCommand(
                    instances,
                    batches,
                    build_ctx.frame_allocator,
                    rect,
                    config,
                    scale_x,
                    build_ctx.gpu_res,
                    current_scissor,
                );
            },
            .text => |config| {
                var world_x = rect.x;
                try appendSingleTextRun(
                    vertices,
                    batches,
                    build_ctx,
                    rect,
                    &world_x,
                    config.font_id,
                    config.font_size,
                    config.text,
                    config.color,
                    config.optical_center,
                    current_scissor,
                );
            },
            .text_runs => |config| {
                var world_x = rect.x;
                for (config.spans) |span| {
                    try appendSingleTextRun(
                        vertices,
                        batches,
                        build_ctx,
                        rect,
                        &world_x,
                        config.font_id,
                        config.font_size,
                        span.text,
                        span.color,
                        false,
                        current_scissor,
                    );
                }
            },
            .border => |config| {
                try appendBorderCommand(
                    instances,
                    batches,
                    build_ctx.frame_allocator,
                    rect,
                    config,
                    scale_x,
                    build_ctx.gpu_res,
                    current_scissor,
                );
            },
            .close_icon => |config| {
                if (rect.w > 0.0 and rect.h > 0.0) {
                    const start = @as(u32, @intCast(instances.items.len));
                    try instances.append(build_ctx.frame_allocator, .{
                        .rect = .{ rect.x, rect.y, rect.w, rect.h },
                        .border = .{ config.stroke_width * scale_x, 0, 0, 0 },
                        .fill_color = packRgba255(config.color),
                        .flags = UiQuadInstance.flag_close_icon,
                    });
                    try addBatch(
                        batches,
                        build_ctx.frame_allocator,
                        start,
                        1,
                        build_ctx.gpu_res.uiTexture(),
                        .sdf_ui,
                        current_scissor,
                    );
                }
            },
            .image => |config| {
                try render_image.appendImageCommand(
                    vertices,
                    batches,
                    addBatch,
                    build_ctx.frame_allocator,
                    rect,
                    config.texture,
                    view_params,
                    win_dims,
                    current_scissor,
                    config.uv,
                );
            },
            .atlas_preview => |tint| {
                if (rect.w > 0 and rect.h > 0) {
                    const start_v = @as(u32, @intCast(vertices.items.len));
                    const x1 = (rect.x / win_dims.w) * 2.0 - 1.0;
                    const y1 = 1.0 - (rect.y / win_dims.h) * 2.0;
                    const x2 = ((rect.x + rect.w) / win_dims.w) * 2.0 - 1.0;
                    const y2 = 1.0 - ((rect.y + rect.h) / win_dims.h) * 2.0;
                    const col = packRgba255(tint);
                    try vertices.ensureUnusedCapacity(
                        build_ctx.frame_allocator,
                        6,
                    );
                    vertices.addManyAsArrayAssumeCapacity(6).* = .{
                        .{ .x = x1, .y = y1, .u = 0.0, .v = 0.0, .color = col },
                        .{ .x = x2, .y = y1, .u = 1.0, .v = 0.0, .color = col },
                        .{ .x = x1, .y = y2, .u = 0.0, .v = 1.0, .color = col },
                        .{ .x = x2, .y = y1, .u = 1.0, .v = 0.0, .color = col },
                        .{ .x = x2, .y = y2, .u = 1.0, .v = 1.0, .color = col },
                        .{ .x = x1, .y = y2, .u = 0.0, .v = 1.0, .color = col },
                    };
                    try addBatch(
                        batches,
                        build_ctx.frame_allocator,
                        start_v,
                        6,
                        build_ctx.gpu_res.uiTexture(),
                        .glyph,
                        current_scissor,
                    );
                }
            },
        }
    }
}

/// Pass 1 of 2-pass rendering: Traverses draw commands and builds geometry
/// vertices and texture draw command batches into a RenderPacket without
/// submitting GPU render passes.
pub fn buildRenderPacket(
    view_params: ViewportParams,
    build_ctx: PacketBuildContext,
    r_commands: []const UiCommand,
) !RenderPacket {
    var packet = RenderPacket{};

    try buildGeometryFromCommands(
        view_params,
        build_ctx,
        r_commands,
        &packet.vertices,
        &packet.instances,
        &packet.batches,
    );

    return packet;
}

test "UiDrawList command accumulation" {
    const allocator = std.testing.allocator;
    var list = UiDrawList{ .allocator = allocator };
    defer list.commands.deinit(allocator);

    try list.addRect(.{ .x = 10, .y = 20, .w = 100, .h = 50 }, .{
        .background_color = theme.base,
    });
    try list.pushScissor(.{ .x = 0, .y = 0, .w = 800, .h = 600 });
    try list.addText(.{ .x = 15, .y = 25, .w = 80, .h = 20 }, .{
        .text = "Hello",
        .color = theme.text,
    });
    try list.popScissor();

    try std.testing.expectEqual(@as(usize, 4), list.commands.items.len);
    try std.testing.expectEqual(
        @as(f32, 100),
        list.commands.items[0].rect.w,
    );
    try std.testing.expect(!hasBlurredSurface(list.commands.items));

    try list.addRect(.{ .x = 0, .y = 0, .w = 50, .h = 50 }, .{
        .background_color = theme.base_translucent,
        .tag = .blurred_surface,
    });
    try std.testing.expect(hasBlurredSurface(list.commands.items));
}

test "buildRenderPacket and executeFrame emit TextureRef image batch" {
    gpu_pkg.graphics.initSdlCore(true) catch return;
    defer gpu_pkg.graphics.quitSdlCore();

    const setup = gpu_pkg.graphics.initGraphicsAndWindow(
        "ui-renderer-test",
        .{ .headless = true, .debug_mode = false },
    ) catch return;
    defer {
        setup.gpu_device.destroy();
        setup.window.destroy();
    }

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var gpu_res = gpu_pkg.graphics.initGpuResources(
        io,
        setup.gpu_device,
        setup.window,
        setup.initial_dpi_scale,
        true,
    ) catch return;
    defer gpu_res.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var list = UiDrawList{ .allocator = allocator };
    defer list.commands.deinit(allocator);

    try list.addImage(.{ .x = 10, .y = 20, .w = 200, .h = 100 }, .{
        .texture = .{ .tex = gpu_res.white_texture },
        .uv = .{ .alpha = 0.5 },
    });

    const ProbeCtx = struct {
        commands: []const UiCommand,
        view_params: ViewportParams,
        vertex_count: usize = 0,
        batch_count: usize = 0,
        material: ?render_image.MaterialType = null,
        matches_white: bool = false,
        alpha_byte: u8 = 0,

        fn build(
            ctx: *@This(),
            build_ctx: PacketBuildContext,
        ) anyerror!RenderPacket {
            const pkt = try buildRenderPacket(
                ctx.view_params,
                build_ctx,
                ctx.commands,
            );
            ctx.vertex_count = pkt.vertices.items.len;
            ctx.batch_count = pkt.batches.items.len;
            if (pkt.batches.items.len > 0) {
                ctx.material = pkt.batches.items[0].material;
                ctx.matches_white = pkt.batches.items[0].texture.eql(
                    build_ctx.gpu_res.white_texture,
                );
            }
            if (pkt.vertices.items.len > 0) {
                ctx.alpha_byte = @truncate(pkt.vertices.items[0].color >> 24);
            }
            return pkt;
        }
    };

    var probe = ProbeCtx{
        .commands = list.commands.items,
        .view_params = .{},
    };
    const pass_timings = try gpu_pkg.pass.executeFrame(
        &gpu_res,
        .{},
        allocator,
        arena.allocator(),
        .{
            .target = .{
                .headless = .{ .w = 320.0, .h = 240.0 },
            },
        },
        &probe,
        ProbeCtx.build,
    );

    try std.testing.expectEqual(@as(f64, 0.0), pass_timings.swapchain_wait_ms);
    try std.testing.expectEqual(
        pass_timings.total_pass_ms,
        pass_timings.gpu_encode_ms,
    );
    try std.testing.expectEqual(@as(usize, 6), probe.vertex_count);
    try std.testing.expectEqual(@as(usize, 1), probe.batch_count);
    try std.testing.expectEqual(
        @as(?render_image.MaterialType, .image_viewer),
        probe.material,
    );
    try std.testing.expect(probe.matches_white);
    try std.testing.expectEqual(@as(u8, 127), probe.alpha_byte);
}
