const std = @import("std");
const sdl = @import("sdl");
const geometry = @import("geometry.zig");
const state = @import("state");

pub const Vertex = geometry.Vertex;
pub const packRgba = geometry.packRgba;
pub const ViewportParams = state.ViewportParams;

/// Defines batch rendering material pipelines, controlling whether image
/// adjustment shader uniforms apply.
pub const MaterialType = enum {
    ui_element,
    image_viewer,
    blurred_surface,
};

/// Fragment shader push uniform block for image viewer photo adjustments and
/// filter algorithms.
pub const ImageUniforms = extern struct {
    brightness: f32 = 0.0,
    contrast: f32 = 1.0,
    temperature: f32 = 0.0,
    tint: f32 = 0.0,

    highlights: f32 = 0.0,
    shadows: f32 = 0.0,
    whites: f32 = 0.0,
    blacks: f32 = 0.0,

    saturation: f32 = 0.0,
    vibrance: f32 = 0.0,
    contrast_blend: f32 = 1.0,
    scale_mode: i32 = 1,

    has_adjustments: i32 = 0,
    clarity: f32 = 0.0,
    texture: f32 = 0.0,
    pad1: i32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(ImageUniforms) == 64);
    std.debug.assert(@offsetOf(ImageUniforms, "brightness") == 0);
    std.debug.assert(@offsetOf(ImageUniforms, "contrast") == 4);
    std.debug.assert(@offsetOf(ImageUniforms, "temperature") == 8);
    std.debug.assert(@offsetOf(ImageUniforms, "tint") == 12);
    std.debug.assert(@offsetOf(ImageUniforms, "highlights") == 16);
    std.debug.assert(@offsetOf(ImageUniforms, "shadows") == 20);
    std.debug.assert(@offsetOf(ImageUniforms, "whites") == 24);
    std.debug.assert(@offsetOf(ImageUniforms, "blacks") == 28);
    std.debug.assert(@offsetOf(ImageUniforms, "saturation") == 32);
    std.debug.assert(@offsetOf(ImageUniforms, "vibrance") == 36);
    std.debug.assert(@offsetOf(ImageUniforms, "contrast_blend") == 40);
    std.debug.assert(@offsetOf(ImageUniforms, "scale_mode") == 44);
    std.debug.assert(@offsetOf(ImageUniforms, "has_adjustments") == 48);
    std.debug.assert(@offsetOf(ImageUniforms, "clarity") == 52);
    std.debug.assert(@offsetOf(ImageUniforms, "texture") == 56);
    std.debug.assert(@offsetOf(ImageUniforms, "pad1") == 60);
}

/// Fragment shader push uniform block for UI shapes, text, and frosted glass panels.
pub const UiUniforms = extern struct {
    is_blurred_surface: i32,
    padding1: f32 = 0.0,
    padding2: f32 = 0.0,
    padding3: f32 = 0.0,
};

/// Draw call batch grouping vertex offset/count, texture binding, material type,
/// and scissor rectangle.
pub const BatchItem = struct {
    vertex_start: u32,
    vertex_count: u32,
    texture: sdl.gpu.Texture,
    material: MaterialType = .ui_element,
    scissor: ?sdl.Rect,
};

/// Appends image viewer vertex geometry for the current image texture, applying
/// pan, zoom factor, and rotation.
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
) !void {
    const texture: ?sdl.gpu.Texture = if (image_data) |ptr|
        sdl.gpu.Texture{ .ptr = @ptrCast(@alignCast(ptr)) }
    else
        null;
    const tex = texture orelse return;

    var dst_w = rect.w;
    var dst_h = rect.h;
    const angle = uv_rect.rotation_angle orelse view_params.rotation_angle;
    const is_90_or_270 = state.view_transform.isAngle90or270(angle);
    if (is_90_or_270) {
        dst_w = rect.h;
        dst_h = rect.w;
    }
    var dst_rect = rect;
    dst_rect.w = dst_w * view_params.zoom_factor.get();
    dst_rect.h = dst_h * view_params.zoom_factor.get();
    const center_x = rect.x + rect.w / 2.0;
    const center_y = rect.y + rect.h / 2.0;
    dst_rect.x = center_x - (dst_rect.w / 2.0) + view_params.pan_x;
    dst_rect.y = center_y - (dst_rect.h / 2.0) + view_params.pan_y;

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
    const alpha_u8 = @as(u8, @intFromFloat(std.math.clamp(uv_rect.alpha, 0.0, 1.0) * 255.0));
    const vert_color = packRgba(255, 255, 255, alpha_u8);
    try vertices.appendSlice(allocator, &[_]Vertex{
        .{ .x = p1.x, .y = p1.y, .u = u_min, .v = v_min, .color = vert_color },
        .{ .x = p2.x, .y = p2.y, .u = u_max, .v = v_min, .color = vert_color },
        .{ .x = p4.x, .y = p4.y, .u = u_min, .v = v_max, .color = vert_color },
        .{ .x = p2.x, .y = p2.y, .u = u_max, .v = v_min, .color = vert_color },
        .{ .x = p3.x, .y = p3.y, .u = u_max, .v = v_max, .color = vert_color },
        .{ .x = p4.x, .y = p4.y, .u = u_min, .v = v_max, .color = vert_color },
    });

    try addBatchFn(batches, allocator, start, 6, tex, .image_viewer, scissor);
}
