const clay = @import("zclay");
const geom = @import("geom");
const gpu_pkg = @import("gpu");
const state = @import("state");
const std = @import("std");
const theme = @import("theme.zig");

const addBatch = gpu_pkg.pass.addBatch;
const BatchItem = gpu_pkg.render_image.BatchItem;
const ElementTag = state.ElementTag;
const FRect = geom.FRect;
const geometry = gpu_pkg.geometry;
const getOrRenderCachedText = gpu_pkg.pass.getOrRenderCachedText;
const intersectScissor = gpu_pkg.pass.intersectScissor;
const isScissorInvisible = gpu_pkg.pass.isScissorInvisible;
const PacketBuildContext = gpu_pkg.pass.PacketBuildContext;
const packRgba = gpu_pkg.geometry.packRgba;
const PhysicalDims = geom.PhysicalDims;
const Rect = geom.Rect;
const render_image = gpu_pkg.render_image;
const RenderPacket = gpu_pkg.pass.RenderPacket;
const RenderResources = gpu_pkg.graphics.RenderResources;
const UvRect = geom.UvRect;
const Vertex = gpu_pkg.geometry.Vertex;
const ViewportParams = state.ViewportParams;

inline fn elementTagFromUserData(user_data: ?*anyopaque) ElementTag {
    return if (user_data) |ptr| ElementTag.fromInt(@intFromPtr(ptr)) else .none;
}

/// Returns true if any render command in the slice renders a blurred surface.
pub fn hasBlurredSurface(r_commands: []const clay.RenderCommand) bool {
    for (r_commands) |rcmd| {
        if (rcmd.command_type == .rectangle and
            elementTagFromUserData(rcmd.user_data) == .blurred_surface)
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
    config: clay.RectangleRenderData,
    user_data: ?*anyopaque,
    scale_x: f32,
    win_dims: PhysicalDims,
    gpu_res: *const RenderResources,
    scissor: ?Rect,
) !void {
    const active_blur_tex =
        if (elementTagFromUserData(user_data) == .blurred_surface)
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
                gpu_res.white_texture,
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
    config: clay.BorderRenderData,
    user_data: ?*anyopaque,
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

    const is_dashed = (elementTagFromUserData(user_data) == .drop_zone_box);

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
            gpu_res.white_texture,
            .ui_element,
            scissor,
        );
    }
}

fn buildGeometryFromCommands(
    view_params: ViewportParams,
    build_ctx: PacketBuildContext,
    r_commands: []const clay.RenderCommand,
    vertices: *std.ArrayList(Vertex),
    batches: *std.ArrayList(BatchItem),
) !void {
    const win_dims = build_ctx.physical_dims;
    const scale_x = build_ctx.scale.x;
    const scale_y = build_ctx.scale.y;

    var current_scissor: ?Rect = null;
    var scissor_stack: std.ArrayList(Rect) = .empty;
    defer scissor_stack.deinit(build_ctx.frame_allocator);
    var prev_text_bb: ?clay.BoundingBox = null;
    var prev_text_end_x: f32 = 0.0;

    for (r_commands) |rcmd| {
        const bb = rcmd.bounding_box;
        const rect = FRect{
            .x = @round(bb.x * scale_x),
            .y = @round(bb.y * scale_y),
            .w = @round(bb.width * scale_x),
            .h = @round(bb.height * scale_y),
        };

        if (rcmd.command_type == .scissor_start) {
            prev_text_bb = null;
            const raw_sc = Rect{
                .x = @intFromFloat(@round(bb.x * scale_x)),
                .y = @intFromFloat(@round(bb.y * scale_y)),
                .w = @intFromFloat(@round(bb.width * scale_x)),
                .h = @intFromFloat(@round(bb.height * scale_y)),
            };
            const eff_sc = if (scissor_stack.items.len > 0) blk: {
                const parent_sc =
                    scissor_stack.items[scissor_stack.items.len - 1];
                break :blk intersectScissor(parent_sc, raw_sc);
            } else raw_sc;
            try scissor_stack.append(build_ctx.frame_allocator, eff_sc);
            current_scissor = eff_sc;
            continue;
        } else if (rcmd.command_type == .scissor_end) {
            prev_text_bb = null;
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
        }

        if (isScissorInvisible(
            current_scissor,
            win_dims,
        )) continue;

        switch (rcmd.command_type) {
            .scissor_start, .scissor_end => {
                std.log.err(
                    "Unexpected scissor command in render switch: {}",
                    .{rcmd.command_type},
                );
            },
            .rectangle => {
                prev_text_bb = null;
                try appendRectangleCommand(
                    vertices,
                    batches,
                    build_ctx.frame_allocator,
                    rect,
                    rcmd.render_data.rectangle,
                    rcmd.user_data,
                    scale_x,
                    win_dims,
                    build_ctx.gpu_res,
                    current_scissor,
                );
            },
            .text => {
                var text_data = rcmd.render_data.text;
                const debug_w =
                    @as(f32, @floatFromInt(clay.Clay__debugViewWidth));
                const logical_win_w = win_dims.w / scale_x;
                if (clay.isDebugModeEnabled() and
                    bb.x >= (logical_win_w - debug_w - 0.5))
                {
                    // Scale down hardcoded 16px Clay debug text to 12px
                    // (0.75x) for GPU text
                    const scaled_size =
                        @as(f32, @floatFromInt(text_data.font_size)) *
                        theme.debug_font_scale;
                    text_data.font_size = @intFromFloat(@round(scaled_size));
                }
                const text_len: usize =
                    @intCast(text_data.string_contents.length);
                const raw_text: []const u8 = if (text_len > 0)
                    text_data.string_contents.chars[0..text_len]
                else
                    "";
                const rgb = [3]f32{
                    text_data.text_color[0],
                    text_data.text_color[1],
                    text_data.text_color[2],
                };
                if (try getOrRenderCachedText(
                    build_ctx,
                    text_data.font_id,
                    text_data.font_size,
                    raw_text,
                    rgb,
                )) |cached| {
                    const offset_y = @round((rect.h - cached.h) / 2.0);
                    const world_y = rect.y + @max(0.0, offset_y);
                    var world_x = rect.x;

                    if (prev_text_bb) |pbb| {
                        const is_same_line =
                            std.math.approxEqAbs(f32, pbb.y, bb.y, 0.5);
                        const is_adjacent = std.math.approxEqAbs(
                            f32,
                            pbb.x + pbb.width,
                            bb.x,
                            0.5,
                        );
                        if (is_same_line and is_adjacent) {
                            world_x = prev_text_end_x;
                        }
                    }

                    prev_text_bb = bb;
                    prev_text_end_x = world_x + cached.w;

                    const p1 =
                        geometry.toNdc(world_x, world_y, win_dims);
                    const p2 = geometry.toNdc(
                        world_x + cached.w,
                        world_y + cached.h,
                        win_dims,
                    );

                    const start = @as(u32, @intCast(vertices.items.len));
                    const text_alpha_u8 = @as(
                        u8,
                        @intFromFloat(
                            std.math.clamp(text_data.text_color[3], 0.0, 255.0),
                        ),
                    );
                    const vert_color = packRgba(255, 255, 255, text_alpha_u8);
                    try vertices.append(build_ctx.frame_allocator, .{
                        .x = p1.x,
                        .y = p1.y,
                        .u = 0.0,
                        .v = 0.0,
                        .color = vert_color,
                    });
                    try vertices.append(build_ctx.frame_allocator, .{
                        .x = p2.x,
                        .y = p1.y,
                        .u = 1.0,
                        .v = 0.0,
                        .color = vert_color,
                    });
                    try vertices.append(build_ctx.frame_allocator, .{
                        .x = p1.x,
                        .y = p2.y,
                        .u = 0.0,
                        .v = 1.0,
                        .color = vert_color,
                    });
                    try vertices.append(build_ctx.frame_allocator, .{
                        .x = p2.x,
                        .y = p1.y,
                        .u = 1.0,
                        .v = 0.0,
                        .color = vert_color,
                    });
                    try vertices.append(build_ctx.frame_allocator, .{
                        .x = p2.x,
                        .y = p2.y,
                        .u = 1.0,
                        .v = 1.0,
                        .color = vert_color,
                    });
                    try vertices.append(build_ctx.frame_allocator, .{
                        .x = p1.x,
                        .y = p2.y,
                        .u = 0.0,
                        .v = 1.0,
                        .color = vert_color,
                    });

                    try addBatch(
                        batches,
                        build_ctx.frame_allocator,
                        start,
                        6,
                        cached.texture,
                        .ui_element,
                        current_scissor,
                    );
                }
            },
            .border => {
                prev_text_bb = null;
                try appendBorderCommand(
                    vertices,
                    batches,
                    build_ctx.frame_allocator,
                    rect,
                    rcmd.render_data.border,
                    rcmd.user_data,
                    scale_x,
                    win_dims,
                    build_ctx.gpu_res,
                    current_scissor,
                );
            },
            .image => {
                prev_text_bb = null;
                const uv_rect = if (rcmd.user_data) |ptr|
                    @as(*const UvRect, @ptrCast(@alignCast(ptr))).*
                else
                    UvRect{};

                try render_image.appendImageCommand(
                    vertices,
                    batches,
                    addBatch,
                    build_ctx.frame_allocator,
                    rect,
                    rcmd.render_data.image.image_data,
                    view_params,
                    win_dims,
                    current_scissor,
                    uv_rect,
                );
            },
            else => {
                std.log.warn(
                    "Skipping unhandled render command type: {}",
                    .{rcmd.command_type},
                );
            },
        }
    }
}

/// Pass 1 of 2-pass rendering: Traverses layout tree and builds geometry
/// vertices and texture draw command batches into a RenderPacket without
/// submitting GPU render passes.
pub fn buildRenderPacket(
    view_params: ViewportParams,
    build_ctx: PacketBuildContext,
    r_commands: []const clay.RenderCommand,
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

test "Clay debug text detection and scaling on HiDPI display" {
    const debug_w = @as(f32, @floatFromInt(clay.Clay__debugViewWidth));
    // physical pixels (1200 logical points at scale_x = 2.0)
    const win_dims = PhysicalDims{ .w = 2400.0, .h = 1600.0 };
    const scale_x: f32 = 2.0;

    const logical_win_w = win_dims.w / scale_x; // 1200.0
    const debug_panel_min_x = logical_win_w - debug_w - 0.5; // 799.5

    // Element inside debug panel at logical x = 800.0
    const debug_element_x: f32 = 800.0;
    try std.testing.expect(debug_element_x >= debug_panel_min_x);

    // Element in main view at logical x = 400.0
    const main_element_x: f32 = 400.0;
    try std.testing.expect(!(main_element_x >= debug_panel_min_x));
}
