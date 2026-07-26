const std = @import("std");
const clay = @import("zclay");
const sdl = @import("sdl");

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    color: u32,
};

pub inline fn packRgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, a) << 24);
}

pub inline fn packRgbaClay(clay_color: clay.Color) u32 {
    const ur: u32 = @intFromFloat(@round(std.math.clamp(clay_color[0], 0.0, 255.0)));
    const ug: u32 = @intFromFloat(@round(std.math.clamp(clay_color[1], 0.0, 255.0)));
    const ub: u32 = @intFromFloat(@round(std.math.clamp(clay_color[2], 0.0, 255.0)));
    const ua: u32 = @intFromFloat(@round(std.math.clamp(clay_color[3], 0.0, 255.0)));
    return ur | (ug << 8) | (ub << 16) | (ua << 24);
}

pub inline fn packRgbaF(r: f32, g: f32, b: f32, a: f32) u32 {
    const ur: u32 = @intFromFloat(@round(std.math.clamp(r * 255.0, 0.0, 255.0)));
    const ug: u32 = @intFromFloat(@round(std.math.clamp(g * 255.0, 0.0, 255.0)));
    const ub: u32 = @intFromFloat(@round(std.math.clamp(b * 255.0, 0.0, 255.0)));
    const ua: u32 = @intFromFloat(@round(std.math.clamp(a * 255.0, 0.0, 255.0)));
    return ur | (ug << 8) | (ub << 16) | (ua << 24);
}

pub fn appendRectQuad(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    rect: sdl.FRect,
    clay_color: clay.Color,
    win_w: f32,
    win_h: f32,
) !void {
    const ndc_x1 = (rect.x / win_w) * 2.0 - 1.0;
    const ndc_x2 = ((rect.x + rect.w) / win_w) * 2.0 - 1.0;
    const ndc_y1 = 1.0 - (rect.y / win_h) * 2.0;
    const ndc_y2 = 1.0 - ((rect.y + rect.h) / win_h) * 2.0;

    const color = packRgbaClay(clay_color);

    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .color = color });
    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .color = color });
    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .color = color });
    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .color = color });
    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 1.0, .color = color });
    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .color = color });
}

pub fn appendLineQuad(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    p1: sdl.FPoint,
    p2: sdl.FPoint,
    thickness: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    win_w: f32,
    win_h: f32,
) !void {
    const dx = p2.x - p1.x;
    const dy = p2.y - p1.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0.0) return;

    const nx = -dy / len;
    const ny = dx / len;

    const ox = nx * thickness * 0.5;
    const oy = ny * thickness * 0.5;

    const x1 = p1.x - ox;
    const y1 = p1.y - oy;
    const x2 = p1.x + ox;
    const y2 = p1.y + oy;
    const x3 = p2.x + ox;
    const y3 = p2.y + oy;
    const x4 = p2.x - ox;
    const y4 = p2.y - oy;

    const ndc_x1 = (x1 / win_w) * 2.0 - 1.0;
    const ndc_y1 = 1.0 - (y1 / win_h) * 2.0;
    const ndc_x2 = (x2 / win_w) * 2.0 - 1.0;
    const ndc_y2 = 1.0 - (y2 / win_h) * 2.0;
    const ndc_x3 = (x3 / win_w) * 2.0 - 1.0;
    const ndc_y3 = 1.0 - (y3 / win_h) * 2.0;
    const ndc_x4 = (x4 / win_w) * 2.0 - 1.0;
    const ndc_y4 = 1.0 - (y4 / win_h) * 2.0;

    const color = packRgbaF(r, g, b, a);

    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .color = color });
    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 0.0, .color = color });
    try vertices.append(allocator, .{ .x = ndc_x3, .y = ndc_y3, .u = 1.0, .v = 1.0, .color = color });

    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .color = color });
    try vertices.append(allocator, .{ .x = ndc_x3, .y = ndc_y3, .u = 1.0, .v = 1.0, .color = color });
    try vertices.append(allocator, .{ .x = ndc_x4, .y = ndc_y4, .u = 0.0, .v = 1.0, .color = color });
}

pub fn appendCornerArc(
    vertices_src: []sdl.Vertex,
    indices: []c_int,
    vertex_count: *usize,
    index_count: *usize,
    center: c_int,
    radius: f32,
    start_angle: f32,
    end_angle: f32,
    color: sdl.FColor,
    num_circle_segments: usize,
) void {
    const center_pos = vertices_src[@intCast(center)].position;
    const angle_step = (end_angle - start_angle) / @as(f32, @floatFromInt(num_circle_segments));

    var i: usize = 0;
    while (i < num_circle_segments) : (i += 1) {
        const a1 = start_angle + @as(f32, @floatFromInt(i)) * angle_step;
        const a2 = start_angle + @as(f32, @floatFromInt(i + 1)) * angle_step;

        const cos_1 = @cos(a1);
        const sin_1 = @sin(a1);
        const cos_2 = @cos(a2);
        const sin_2 = @sin(a2);

        vertices_src[vertex_count.*] = .{
            .position = .{
                .x = center_pos.x + cos_1 * radius,
                .y = center_pos.y + sin_1 * radius,
            },
            .color = color,
            .tex_coord = .{ .x = 0, .y = 0 },
        };
        vertex_count.* += 1;

        vertices_src[vertex_count.*] = .{
            .position = .{
                .x = center_pos.x + cos_2 * radius,
                .y = center_pos.y + sin_2 * radius,
            },
            .color = color,
            .tex_coord = .{ .x = 0, .y = 0 },
        };
        vertex_count.* += 1;

        const v1_idx: c_int = @intCast(vertex_count.* - 2);
        const v2_idx: c_int = @intCast(vertex_count.* - 1);

        indices[index_count.*] = center;
        index_count.* += 1;
        indices[index_count.*] = v1_idx;
        index_count.* += 1;
        indices[index_count.*] = v2_idx;
        index_count.* += 1;
    }
}

pub fn renderFillRoundedRect(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    rect: sdl.FRect,
    corner_radius: f32,
    clay_color: clay.Color,
    win_w: f32,
    win_h: f32,
) !void {
    const color = sdl.FColor{
        .r = clay_color[0] / 255.0,
        .g = clay_color[1] / 255.0,
        .b = clay_color[2] / 255.0,
        .a = clay_color[3] / 255.0,
    };

    const min_radius = @min(rect.w, rect.h) / 2.0;
    const clamped_radius = @min(corner_radius, min_radius);

    if (clamped_radius <= 0.001) {
        return appendRectQuad(vertices, allocator, rect, clay_color, win_w, win_h);
    }

    const num_circle_segments = @max(@as(usize, 8), @as(usize, @intFromFloat(clamped_radius * 0.75)));

    const total_vertices = 4 + (4 * (num_circle_segments * 2)) + 8;
    const total_indices = 6 + (4 * (num_circle_segments * 3)) + 24;

    const vertices_src = try allocator.alloc(sdl.Vertex, total_vertices);
    defer allocator.free(vertices_src);
    const indices = try allocator.alloc(c_int, total_indices);
    defer allocator.free(indices);

    var vertex_count: usize = 0;
    var index_count: usize = 0;

    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + clamped_radius, .y = rect.y + clamped_radius }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    vertex_count += 1;
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + rect.w - clamped_radius, .y = rect.y + clamped_radius }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } };
    vertex_count += 1;
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + rect.w - clamped_radius, .y = rect.y + rect.h - clamped_radius }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } };
    vertex_count += 1;
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + clamped_radius, .y = rect.y + rect.h - clamped_radius }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } };
    vertex_count += 1;

    indices[index_count] = 0;
    index_count += 1;
    indices[index_count] = 1;
    index_count += 1;
    indices[index_count] = 3;
    index_count += 1;
    indices[index_count] = 1;
    index_count += 1;
    indices[index_count] = 2;
    index_count += 1;
    indices[index_count] = 3;
    index_count += 1;

    // Top-Left corner: 180° to 270°
    appendCornerArc(vertices_src, indices, &vertex_count, &index_count, 0, clamped_radius, std.math.pi, std.math.pi * 1.5, color, num_circle_segments);

    // Top-Right corner: 270° to 360°
    appendCornerArc(vertices_src, indices, &vertex_count, &index_count, 1, clamped_radius, std.math.pi * 1.5, std.math.pi * 2.0, color, num_circle_segments);

    // Bottom-Right corner: 0° to 90°
    appendCornerArc(vertices_src, indices, &vertex_count, &index_count, 2, clamped_radius, 0.0, std.math.pi * 0.5, color, num_circle_segments);

    // Bottom-Left corner: 90° to 180°
    appendCornerArc(vertices_src, indices, &vertex_count, &index_count, 3, clamped_radius, std.math.pi * 0.5, std.math.pi, color, num_circle_segments);

    // Top edge
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + clamped_radius, .y = rect.y }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    vertex_count += 1;
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + rect.w - clamped_radius, .y = rect.y }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } };
    vertex_count += 1;

    indices[index_count] = 0;
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 2);
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 1);
    index_count += 1;
    indices[index_count] = 1;
    index_count += 1;
    indices[index_count] = 0;
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 1);
    index_count += 1;

    // Right edge
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + clamped_radius }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } };
    vertex_count += 1;
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + rect.h - clamped_radius }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } };
    vertex_count += 1;

    indices[index_count] = 1;
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 2);
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 1);
    index_count += 1;
    indices[index_count] = 2;
    index_count += 1;
    indices[index_count] = 1;
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 1);
    index_count += 1;

    // Bottom edge
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + rect.w - clamped_radius, .y = rect.y + rect.h }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } };
    vertex_count += 1;
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x + clamped_radius, .y = rect.y + rect.h }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } };
    vertex_count += 1;

    indices[index_count] = 2;
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 2);
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 1);
    index_count += 1;
    indices[index_count] = 3;
    index_count += 1;
    indices[index_count] = 2;
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 1);
    index_count += 1;

    // Left edge
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x, .y = rect.y + rect.h - clamped_radius }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } };
    vertex_count += 1;
    vertices_src[vertex_count] = .{ .position = .{ .x = rect.x, .y = rect.y + clamped_radius }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    vertex_count += 1;

    indices[index_count] = 3;
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 2);
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 1);
    index_count += 1;
    indices[index_count] = 0;
    index_count += 1;
    indices[index_count] = 3;
    index_count += 1;
    indices[index_count] = @intCast(vertex_count - 1);
    index_count += 1;

    // Map indexed vertices into the global non-indexed list
    for (indices[0..index_count]) |idx| {
        const v = vertices_src[@intCast(idx)];
        const ndc_x = (v.position.x / win_w) * 2.0 - 1.0;
        const ndc_y = 1.0 - (v.position.y / win_h) * 2.0;

        try vertices.append(allocator, .{
            .x = ndc_x,
            .y = ndc_y,
            .u = v.tex_coord.x,
            .v = v.tex_coord.y,
            .color = packRgbaF(v.color.r, v.color.g, v.color.b, v.color.a),
        });
    }
}

pub fn drawDashedLineH(vertices: *std.ArrayList(Vertex), allocator: std.mem.Allocator, x1: f32, x2: f32, y: f32, thickness: f32, color: clay.Color, dash_len: f32, gap_len: f32, win_w: f32, win_h: f32) !void {
    var x = x1;
    while (x < x2) {
        const draw_w = @min(dash_len, x2 - x);
        const rect = sdl.FRect{ .x = x, .y = y, .w = draw_w, .h = thickness };
        try appendRectQuad(vertices, allocator, rect, color, win_w, win_h);
        x += dash_len + gap_len;
    }
}

pub fn drawDashedLineV(vertices: *std.ArrayList(Vertex), allocator: std.mem.Allocator, x: f32, y1: f32, y2: f32, thickness: f32, color: clay.Color, dash_len: f32, gap_len: f32, win_w: f32, win_h: f32) !void {
    var y = y1;
    while (y < y2) {
        const draw_h = @min(dash_len, y2 - y);
        const rect = sdl.FRect{ .x = x, .y = y, .w = thickness, .h = draw_h };
        try appendRectQuad(vertices, allocator, rect, color, win_w, win_h);
        y += dash_len + gap_len;
    }
}

pub fn renderArc(
    vertices: *std.ArrayList(Vertex),
    center: sdl.FPoint,
    radius: f32,
    start_angle: f32,
    end_angle: f32,
    thickness: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    allocator: std.mem.Allocator,
    is_dashed: bool,
    win_w: f32,
    win_h: f32,
) !void {
    const rad_start = start_angle * (std.math.pi / 180.0);
    const rad_end = end_angle * (std.math.pi / 180.0);
    const angle_span = @abs(rad_end - rad_start);

    const quadrant_segs = @max(@as(usize, 8), @as(usize, @intFromFloat(radius * 0.75)));
    const segs_f = @as(f32, @floatFromInt(quadrant_segs)) * (angle_span / (std.math.pi / 2.0));
    const num_circle_segments = @max(@as(usize, 8), @as(usize, @intFromFloat(@round(segs_f))));

    const angle_step = (rad_end - rad_start) / @as(f32, @floatFromInt(num_circle_segments));

    const r_outer = radius;
    const r_inner = @max(radius - thickness, 0.0);
    const color = packRgbaF(r, g, b, a);

    var s: usize = 0;
    while (s < num_circle_segments) : (s += 1) {
        if (is_dashed and (s % 4 >= 2)) continue;

        const a1 = rad_start + @as(f32, @floatFromInt(s)) * angle_step;
        const a2 = rad_start + @as(f32, @floatFromInt(s + 1)) * angle_step;

        const cos1 = @cos(a1);
        const sin1 = @sin(a1);
        const cos2 = @cos(a2);
        const sin2 = @sin(a2);

        const out1_x = center.x + cos1 * r_outer;
        const out1_y = center.y + sin1 * r_outer;
        const out2_x = center.x + cos2 * r_outer;
        const out2_y = center.y + sin2 * r_outer;

        const in1_x = center.x + cos1 * r_inner;
        const in1_y = center.y + sin1 * r_inner;
        const in2_x = center.x + cos2 * r_inner;
        const in2_y = center.y + sin2 * r_inner;

        const ndc_out1_x = (out1_x / win_w) * 2.0 - 1.0;
        const ndc_out1_y = 1.0 - (out1_y / win_h) * 2.0;

        const ndc_out2_x = (out2_x / win_w) * 2.0 - 1.0;
        const ndc_out2_y = 1.0 - (out2_y / win_h) * 2.0;

        const ndc_in1_x = (in1_x / win_w) * 2.0 - 1.0;
        const ndc_in1_y = 1.0 - (in1_y / win_h) * 2.0;

        const ndc_in2_x = (in2_x / win_w) * 2.0 - 1.0;
        const ndc_in2_y = 1.0 - (in2_y / win_h) * 2.0;

        // Triangle 1: out1, out2, in2
        try vertices.append(allocator, .{ .x = ndc_out1_x, .y = ndc_out1_y, .u = 0.0, .v = 0.0, .color = color });
        try vertices.append(allocator, .{ .x = ndc_out2_x, .y = ndc_out2_y, .u = 1.0, .v = 0.0, .color = color });
        try vertices.append(allocator, .{ .x = ndc_in2_x, .y = ndc_in2_y, .u = 1.0, .v = 1.0, .color = color });

        // Triangle 2: out1, in2, in1
        try vertices.append(allocator, .{ .x = ndc_out1_x, .y = ndc_out1_y, .u = 0.0, .v = 0.0, .color = color });
        try vertices.append(allocator, .{ .x = ndc_in2_x, .y = ndc_in2_y, .u = 1.0, .v = 1.0, .color = color });
        try vertices.append(allocator, .{ .x = ndc_in1_x, .y = ndc_in1_y, .u = 0.0, .v = 1.0, .color = color });
    }
}
