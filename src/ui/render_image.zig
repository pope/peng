const std = @import("std");
const sdl = @import("sdl");
const geometry = @import("geometry.zig");
const state = @import("state");

pub const Vertex = geometry.Vertex;
pub const packRgba = geometry.packRgba;
pub const ViewportParams = state.ViewportParams;

/// Defines batch rendering material pipelines, controlling whether image adjustment shader uniforms apply.
pub const MaterialType = enum {
    ui_element,
    image_viewer,
};

/// Shader uniforms passed to GPU fragment pipeline for brightness, contrast, and color modes.
pub const Uniforms = extern struct {
    brightness: f32,
    contrast: f32,
    is_text_or_color: i32,
    scale_mode: i32,
};

/// Represents a single instanced GPU render batch with vertex offset, count, texture, and scissor rect.
pub const BatchItem = struct {
    vertex_start: u32,
    vertex_count: u32,
    texture: sdl.gpu.Texture,
    material: MaterialType = .ui_element,
    scissor: ?sdl.Rect,
};

/// Appends image viewer vertex geometry for the current image texture, applying pan, zoom factor, and rotation.
pub fn appendImageCommand(
    vertices: *std.ArrayList(Vertex),
    batches: *std.ArrayList(BatchItem),
    addBatchFn: anytype,
    allocator: std.mem.Allocator,
    rect: sdl.FRect,
    image_data: ?*anyopaque,
    view_params: ViewportParams,
    f_win_w: f32,
    f_win_h: f32,
    scissor: ?sdl.Rect,
    uv_rect: state.UvRect,
    start_offset: f32,
) !void {
    const texture: ?sdl.gpu.Texture = if (image_data) |ptr| sdl.gpu.Texture{ .ptr = @ptrCast(@alignCast(ptr)) } else null;
    const tex = texture orelse return;

    var dst_w = rect.w;
    var dst_h = rect.h;
    const angle = view_params.rotation_angle;
    const is_90_or_270 = state.view_transform.isAngle90or270(angle);
    if (is_90_or_270) {
        dst_w = rect.h;
        dst_h = rect.w;
    }
    var dst_rect = rect;
    dst_rect.w = dst_w * view_params.zoom_factor.get();
    dst_rect.h = dst_h * view_params.zoom_factor.get();

    if (view_params.view_mode == .comics_strip) {
        const is_horizontal = (view_params.fit_mode == .fit_height);
        const title_bar_h: f32 = 60.0;

        if (is_horizontal) {
            dst_rect.x = start_offset - view_params.pan_x;
            dst_rect.y = rect.y + view_params.pan_y;
        } else {
            dst_rect.x = rect.x + view_params.pan_x;
            dst_rect.y = title_bar_h + start_offset - view_params.pan_y;
        }
    } else {
        const center_x = rect.x + rect.w / 2.0;
        const center_y = rect.y + rect.h / 2.0;
        dst_rect.x = center_x - (dst_rect.w / 2.0) + view_params.pan_x;
        dst_rect.y = center_y - (dst_rect.h / 2.0) + view_params.pan_y;
    }

    const rad = angle * (std.math.pi / 180.0);
    const cos_val = @cos(rad);
    const sin_val = @sin(rad);

    const half_w = dst_rect.w * 0.5;
    const half_h = dst_rect.h * 0.5;
    const c_x = dst_rect.x + half_w;
    const c_y = dst_rect.y + half_h;

    const rx1 = -half_w * cos_val - (-half_h) * sin_val;
    const ry1 = -half_w * sin_val + (-half_h) * cos_val;

    const rx2 = half_w * cos_val - (-half_h) * sin_val;
    const ry2 = half_w * sin_val + (-half_h) * cos_val;

    const rx3 = half_w * cos_val - half_h * sin_val;
    const ry3 = half_w * sin_val + half_h * cos_val;

    const rx4 = -half_w * cos_val - half_h * sin_val;
    const ry4 = -half_w * sin_val + half_h * cos_val;

    const world_x1 = c_x + rx1;
    const world_y1 = c_y + ry1;
    const world_x2 = c_x + rx2;
    const world_y2 = c_y + ry2;
    const world_x3 = c_x + rx3;
    const world_y3 = c_y + ry3;
    const world_x4 = c_x + rx4;
    const world_y4 = c_y + ry4;

    const p1 = geometry.toNdc(world_x1, world_y1, f_win_w, f_win_h);
    const p2 = geometry.toNdc(world_x2, world_y2, f_win_w, f_win_h);
    const p3 = geometry.toNdc(world_x3, world_y3, f_win_w, f_win_h);
    const p4 = geometry.toNdc(world_x4, world_y4, f_win_w, f_win_h);

    const u_min = uv_rect.u_min;
    const v_min = uv_rect.v_min;
    const u_max = uv_rect.u_max;
    const v_max = uv_rect.v_max;

    const start = @as(u32, @intCast(vertices.items.len));
    const white_color = packRgba(255, 255, 255, 255);
    try vertices.append(allocator, .{ .x = p1.x, .y = p1.y, .u = u_min, .v = v_min, .color = white_color });
    try vertices.append(allocator, .{ .x = p2.x, .y = p2.y, .u = u_max, .v = v_min, .color = white_color });
    try vertices.append(allocator, .{ .x = p4.x, .y = p4.y, .u = u_min, .v = v_max, .color = white_color });
    try vertices.append(allocator, .{ .x = p2.x, .y = p2.y, .u = u_max, .v = v_min, .color = white_color });
    try vertices.append(allocator, .{ .x = p3.x, .y = p3.y, .u = u_max, .v = v_max, .color = white_color });
    try vertices.append(allocator, .{ .x = p4.x, .y = p4.y, .u = u_min, .v = v_max, .color = white_color });

    try addBatchFn(batches, allocator, start, 6, tex, .image_viewer, scissor);
}
