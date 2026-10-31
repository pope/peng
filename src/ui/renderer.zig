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
const geometry = gpu_pkg.geometry;
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
    image_data: ?*anyopaque,
    uv: UvRect = .{},
};

/// Variant payload for pure-Zig immediate-mode UI draw commands.
pub const CommandPayload = union(enum) {
    scissor_start,
    scissor_end,
    rectangle: RectConfig,
    border: BorderConfig,
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
    vertices: *std.ArrayList(Vertex),
    batches: *std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,
    rect: FRect,
    config: RectConfig,
    scale_x: f32,
    win_dims: PhysicalDims,
    gpu_res: *const RenderResources,
    scissor: ?Rect,
) !void {
    const active_blur_tex = if (config.tag == .blurred_surface)
        gpu_res.blur.getBlurTexture()
    else
        null;
    const is_blurred = active_blur_tex != null;

    const start = @as(u32, @intCast(vertices.items.len));

    const corner_radius = config.corner_radius.top_left * scale_x;
    if (corner_radius > 0) {
        try geometry.renderFillRoundedRect(
            vertices,
            allocator,
            rect,
            corner_radius,
            config.background_color,
            win_dims,
            is_blurred,
        );
    } else {
        try geometry.appendRectQuad(
            vertices,
            allocator,
            rect,
            config.background_color,
            win_dims,
            is_blurred,
        );
    }

    const count = @as(u32, @intCast(vertices.items.len)) - start;
    if (count > 0) {
        if (active_blur_tex) |btex| {
            try addBatch(
                batches,
                allocator,
                start,
                count,
                btex,
                .blurred_surface,
                scissor,
            );
        } else {
            try addBatch(
                batches,
                allocator,
                start,
                count,
                gpu_res.uiTexture(),
                .ui_element,
                scissor,
            );
        }
    }
}

fn appendBorderCommand(
    vertices: *std.ArrayList(Vertex),
    batches: *std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,
    rect: FRect,
    config: BorderConfig,
    scale_x: f32,
    win_dims: PhysicalDims,
    gpu_res: *const RenderResources,
    scissor: ?Rect,
) !void {
    const min_radius = @min(rect.w, rect.h) / 2.0;
    const clamped_radii = struct {
        top_left: f32,
        top_right: f32,
        bottom_left: f32,
        bottom_right: f32,
    }{
        .top_left = @min(config.corner_radius.top_left * scale_x, min_radius),
        .top_right = @min(config.corner_radius.top_right * scale_x, min_radius),
        .bottom_left = @min(
            config.corner_radius.bottom_left * scale_x,
            min_radius,
        ),
        .bottom_right = @min(
            config.corner_radius.bottom_right * scale_x,
            min_radius,
        ),
    };

    const is_dashed = (config.tag == .drop_zone_box);

    const r = config.color[0] / 255.0;
    const g = config.color[1] / 255.0;
    const b = config.color[2] / 255.0;
    const a = config.color[3] / 255.0;

    const start_batch = @as(u32, @intCast(vertices.items.len));

    const border_left = @as(f32, @floatFromInt(config.width.left)) * scale_x;
    const border_right = @as(f32, @floatFromInt(config.width.right)) * scale_x;
    const border_top = @as(f32, @floatFromInt(config.width.top)) * scale_x;
    const border_bottom =
        @as(f32, @floatFromInt(config.width.bottom)) * scale_x;

    if (border_left > 0) {
        const starting_y = rect.y + clamped_radii.top_left;
        const length =
            rect.h - clamped_radii.top_left - clamped_radii.bottom_left;
        if (is_dashed) {
            try geometry.drawDashedLineV(
                vertices,
                allocator,
                rect.x,
                starting_y,
                starting_y + length,
                border_left,
                config.color,
                8.0 * scale_x,
                6.0 * scale_x,
                win_dims,
            );
        } else {
            const line = FRect{
                .x = rect.x,
                .y = starting_y,
                .w = border_left,
                .h = length,
            };
            try geometry.appendRectQuad(
                vertices,
                allocator,
                line,
                config.color,
                win_dims,
                false,
            );
        }
    }
    if (border_right > 0) {
        const starting_x = rect.x + rect.w - border_right;
        const starting_y = rect.y + clamped_radii.top_right;
        const length =
            rect.h - clamped_radii.top_right - clamped_radii.bottom_right;
        if (is_dashed) {
            try geometry.drawDashedLineV(
                vertices,
                allocator,
                starting_x,
                starting_y,
                starting_y + length,
                border_right,
                config.color,
                8.0 * scale_x,
                6.0 * scale_x,
                win_dims,
            );
        } else {
            const line = FRect{
                .x = starting_x,
                .y = starting_y,
                .w = border_right,
                .h = length,
            };
            try geometry.appendRectQuad(
                vertices,
                allocator,
                line,
                config.color,
                win_dims,
                false,
            );
        }
    }
    if (border_top > 0) {
        const starting_x = rect.x + clamped_radii.top_left;
        const length =
            rect.w - clamped_radii.top_left - clamped_radii.top_right;
        if (is_dashed) {
            try geometry.drawDashedLineH(
                vertices,
                allocator,
                starting_x,
                starting_x + length,
                rect.y,
                border_top,
                config.color,
                8.0 * scale_x,
                6.0 * scale_x,
                win_dims,
            );
        } else {
            const line = FRect{
                .x = starting_x,
                .y = rect.y,
                .w = length,
                .h = border_top,
            };
            try geometry.appendRectQuad(
                vertices,
                allocator,
                line,
                config.color,
                win_dims,
                false,
            );
        }
    }
    if (border_bottom > 0) {
        const starting_x = rect.x + clamped_radii.bottom_left;
        const starting_y = rect.y + rect.h - border_bottom;
        const length =
            rect.w - clamped_radii.bottom_left - clamped_radii.bottom_right;
        if (is_dashed) {
            try geometry.drawDashedLineH(
                vertices,
                allocator,
                starting_x,
                starting_x + length,
                starting_y,
                border_bottom,
                config.color,
                8.0 * scale_x,
                6.0 * scale_x,
                win_dims,
            );
        } else {
            const line = FRect{
                .x = starting_x,
                .y = starting_y,
                .w = length,
                .h = border_bottom,
            };
            try geometry.appendRectQuad(
                vertices,
                allocator,
                line,
                config.color,
                win_dims,
                false,
            );
        }
    }

    if (clamped_radii.top_left > 0) {
        try geometry.renderArc(
            vertices,
            .{
                .x = rect.x + clamped_radii.top_left,
                .y = rect.y + clamped_radii.top_left,
            },
            clamped_radii.top_left,
            180.0,
            270.0,
            border_top,
            r,
            g,
            b,
            a,
            allocator,
            is_dashed,
            win_dims,
        );
    }
    if (clamped_radii.top_right > 0) {
        try geometry.renderArc(
            vertices,
            .{
                .x = rect.x + rect.w - clamped_radii.top_right,
                .y = rect.y + clamped_radii.top_right,
            },
            clamped_radii.top_right,
            270.0,
            360.0,
            border_top,
            r,
            g,
            b,
            a,
            allocator,
            is_dashed,
            win_dims,
        );
    }
    if (clamped_radii.bottom_left > 0) {
        try geometry.renderArc(
            vertices,
            .{
                .x = rect.x + clamped_radii.bottom_left,
                .y = rect.y + rect.h - clamped_radii.bottom_left,
            },
            clamped_radii.bottom_left,
            90.0,
            180.0,
            border_bottom,
            r,
            g,
            b,
            a,
            allocator,
            is_dashed,
            win_dims,
        );
    }
    if (clamped_radii.bottom_right > 0) {
        try geometry.renderArc(
            vertices,
            .{
                .x = rect.x + rect.w - clamped_radii.bottom_right,
                .y = rect.y + rect.h - clamped_radii.bottom_right,
            },
            clamped_radii.bottom_right,
            0.0,
            90.0,
            border_bottom,
            r,
            g,
            b,
            a,
            allocator,
            is_dashed,
            win_dims,
        );
    }

    const count = @as(u32, @intCast(vertices.items.len)) - start_batch;
    if (count > 0) {
        try addBatch(
            batches,
            allocator,
            start_batch,
            count,
            gpu_res.uiTexture(),
            .ui_element,
            scissor,
        );
    }
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
    const ndc_y1 = 1.0 - (world_y / win_dims.h) * 2.0;
    const ndc_y2 = 1.0 - ((world_y + line_h) / win_dims.h) * 2.0;

    const vert_color = packRgba255(color);
    const start_vert = @as(u32, @intCast(vertices.items.len));
    try vertices.ensureUnusedCapacity(
        build_ctx.frame_allocator,
        text_slice.len * 6,
    );

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
            const gx = world_x.* + glyph.offset_x;
            const x1 = gx * inv_win_w - 1.0;
            const x2 = (gx + glyph.w) * inv_win_w - 1.0;
            const y2 = if (glyph.h == line_h)
                ndc_y2
            else
                1.0 - ((world_y + glyph.h) / win_dims.h) * 2.0;

            vertices.addManyAsArrayAssumeCapacity(6).* = .{
                .{
                    .x = x1,
                    .y = ndc_y1,
                    .u = glyph.u1,
                    .v = glyph.v1,
                    .color = vert_color,
                },
                .{
                    .x = x2,
                    .y = ndc_y1,
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
                    .y = ndc_y1,
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
    if (vert_count > 0) {
        try addBatch(
            batches,
            build_ctx.frame_allocator,
            start_vert,
            vert_count,
            build_ctx.gpu_res.uiTexture(),
            .ui_element,
            current_scissor,
        );
    }
}

fn buildGeometryFromCommands(
    view_params: ViewportParams,
    build_ctx: PacketBuildContext,
    r_commands: []const UiCommand,
    vertices: *std.ArrayList(Vertex),
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
                    vertices,
                    batches,
                    build_ctx.frame_allocator,
                    rect,
                    config,
                    scale_x,
                    win_dims,
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
                        current_scissor,
                    );
                }
            },
            .border => |config| {
                try appendBorderCommand(
                    vertices,
                    batches,
                    build_ctx.frame_allocator,
                    rect,
                    config,
                    scale_x,
                    win_dims,
                    build_ctx.gpu_res,
                    current_scissor,
                );
            },
            .image => |config| {
                try render_image.appendImageCommand(
                    vertices,
                    batches,
                    addBatch,
                    build_ctx.frame_allocator,
                    rect,
                    config.image_data,
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
                        .ui_element,
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
