const state = @import("state");
const std = @import("std");

const PhysicalDims = state.PhysicalDims;

/// Integer pixel rectangle for scissor clipping and bounds.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Floating-point pixel rectangle for UI and viewport quad emission.
pub const FRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// 2D floating-point coordinate in screen pixels.
pub const FPoint = struct {
    x: f32,
    y: f32,
};

const RoundedVertex = struct {
    pos: FPoint,
    u: f32,
    v: f32,
};

/// 2D textured colored vertex layout matching GPU pipeline vertex buffer
/// layout.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    color: u32,
};

/// Packs 8-bit integer RGBA channels into a 32-bit color word.
pub inline fn packRgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, r) |
        (@as(u32, g) << 8) |
        (@as(u32, b) << 16) |
        (@as(u32, a) << 24);
}

/// Clamps and packs float RGBA channels (0.0–255.0) into a 32-bit color word.
pub inline fn packRgba255(color: [4]f32) u32 {
    const ur: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 255.0)));
    const ug: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 255.0)));
    const ub: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 255.0)));
    const ua: u32 = @intFromFloat(@round(std.math.clamp(color[3], 0.0, 255.0)));
    return ur | (ug << 8) | (ub << 16) | (ua << 24);
}

/// Clamps and packs normalized float RGBA channels (0.0–1.0) into a 32-bit
/// color word.
pub inline fn packRgbaF(r: f32, g: f32, b: f32, a: f32) u32 {
    const ur: u32 =
        @intFromFloat(@round(std.math.clamp(r * 255.0, 0.0, 255.0)));
    const ug: u32 =
        @intFromFloat(@round(std.math.clamp(g * 255.0, 0.0, 255.0)));
    const ub: u32 =
        @intFromFloat(@round(std.math.clamp(b * 255.0, 0.0, 255.0)));
    const ua: u32 =
        @intFromFloat(@round(std.math.clamp(a * 255.0, 0.0, 255.0)));
    return ur | (ug << 8) | (ub << 16) | (ua << 24);
}

/// 2D point expressed in Normalized Device Coordinates [-1.0, 1.0].
pub const NdcPoint = struct {
    x: f32,
    y: f32,
};

/// Converts screen pixel coordinates into Normalized Device Coordinates
/// [-1.0, 1.0].
pub inline fn toNdc(x: f32, y: f32, win_dims: PhysicalDims) NdcPoint {
    return .{
        .x = (x / win_dims.w) * 2.0 - 1.0,
        .y = 1.0 - (y / win_dims.h) * 2.0,
    };
}

/// Appends a solid axis-aligned rectangle quad (6 vertices / 2 triangles)
/// to the vertex list.
pub fn appendRectQuad(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    rect: FRect,
    rgba255: [4]f32,
    win_dims: PhysicalDims,
    screen_uv: bool,
) !void {
    const p1 = toNdc(rect.x, rect.y, win_dims);
    const p2 = toNdc(rect.x + rect.w, rect.y + rect.h, win_dims);

    const color = packRgba255(rgba255);

    const uv_u1: f32 = if (screen_uv) rect.x / win_dims.w else 0.0;
    const uv_v1: f32 = if (screen_uv) rect.y / win_dims.h else 0.0;
    const uv_u2: f32 = if (screen_uv) (rect.x + rect.w) / win_dims.w else 1.0;
    const uv_v2: f32 = if (screen_uv) (rect.y + rect.h) / win_dims.h else 1.0;

    try vertices.append(allocator, .{
        .x = p1.x,
        .y = p1.y,
        .u = uv_u1,
        .v = uv_v1,
        .color = color,
    });
    try vertices.append(allocator, .{
        .x = p2.x,
        .y = p1.y,
        .u = uv_u2,
        .v = uv_v1,
        .color = color,
    });
    try vertices.append(allocator, .{
        .x = p1.x,
        .y = p2.y,
        .u = uv_u1,
        .v = uv_v2,
        .color = color,
    });
    try vertices.append(allocator, .{
        .x = p2.x,
        .y = p1.y,
        .u = uv_u2,
        .v = uv_v1,
        .color = color,
    });
    try vertices.append(allocator, .{
        .x = p2.x,
        .y = p2.y,
        .u = uv_u2,
        .v = uv_v2,
        .color = color,
    });
    try vertices.append(allocator, .{
        .x = p1.x,
        .y = p2.y,
        .u = uv_u1,
        .v = uv_v2,
        .color = color,
    });
}

fn appendCornerArc(
    vertices_src: []RoundedVertex,
    indices: []usize,
    vertex_count: *usize,
    index_count: *usize,
    center: usize,
    radius: f32,
    start_angle: f32,
    end_angle: f32,
    num_circle_segments: usize,
) void {
    const center_pos = vertices_src[center].pos;
    const angle_step = (end_angle - start_angle) /
        @as(f32, @floatFromInt(num_circle_segments));

    var i: usize = 0;
    while (i < num_circle_segments) : (i += 1) {
        const a1 = start_angle + @as(f32, @floatFromInt(i)) * angle_step;
        const a2 = start_angle + @as(f32, @floatFromInt(i + 1)) * angle_step;

        const cos_1 = @cos(a1);
        const sin_1 = @sin(a1);
        const cos_2 = @cos(a2);
        const sin_2 = @sin(a2);

        vertices_src[vertex_count.*] = .{
            .pos = .{
                .x = center_pos.x + cos_1 * radius,
                .y = center_pos.y + sin_1 * radius,
            },
            .u = 0.0,
            .v = 0.0,
        };
        vertex_count.* += 1;

        vertices_src[vertex_count.*] = .{
            .pos = .{
                .x = center_pos.x + cos_2 * radius,
                .y = center_pos.y + sin_2 * radius,
            },
            .u = 0.0,
            .v = 0.0,
        };
        vertex_count.* += 1;

        const v1_idx: usize = vertex_count.* - 2;
        const v2_idx: usize = vertex_count.* - 1;

        indices[index_count.*] = center;
        index_count.* += 1;
        indices[index_count.*] = v1_idx;
        index_count.* += 1;
        indices[index_count.*] = v2_idx;
        index_count.* += 1;
    }
}

/// Tessellates a filled rounded rectangle with corner arcs into triangle
/// fans and appends vertices.
pub fn renderFillRoundedRect(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    rect: FRect,
    corner_radius: f32,
    rgba255: [4]f32,
    win_dims: PhysicalDims,
    screen_uv: bool,
) !void {
    const packed_color = packRgba255(rgba255);

    const min_radius = @min(rect.w, rect.h) / 2.0;
    const clamped_radius = @min(corner_radius, min_radius);

    if (clamped_radius <= 0.001) {
        return appendRectQuad(
            vertices,
            allocator,
            rect,
            rgba255,
            win_dims,
            screen_uv,
        );
    }

    const num_circle_segments = @max(
        @as(usize, 8),
        @as(usize, @intFromFloat(clamped_radius * 0.75)),
    );

    const total_vertices = 4 + (4 * (num_circle_segments * 2)) + 8;
    const total_indices = 6 + (4 * (num_circle_segments * 3)) + 24;

    const vertices_src = try allocator.alloc(RoundedVertex, total_vertices);
    defer allocator.free(vertices_src);
    const indices = try allocator.alloc(usize, total_indices);
    defer allocator.free(indices);

    var vertex_count: usize = 0;
    var index_count: usize = 0;

    vertices_src[vertex_count] = .{
        .pos = .{
            .x = rect.x + clamped_radius,
            .y = rect.y + clamped_radius,
        },
        .u = 0.0,
        .v = 0.0,
    };
    vertex_count += 1;
    vertices_src[vertex_count] = .{
        .pos = .{
            .x = rect.x + rect.w - clamped_radius,
            .y = rect.y + clamped_radius,
        },
        .u = 1.0,
        .v = 0.0,
    };
    vertex_count += 1;
    vertices_src[vertex_count] = .{
        .pos = .{
            .x = rect.x + rect.w - clamped_radius,
            .y = rect.y + rect.h - clamped_radius,
        },
        .u = 1.0,
        .v = 1.0,
    };
    vertex_count += 1;
    vertices_src[vertex_count] = .{
        .pos = .{
            .x = rect.x + clamped_radius,
            .y = rect.y + rect.h - clamped_radius,
        },
        .u = 0.0,
        .v = 1.0,
    };
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
    appendCornerArc(
        vertices_src,
        indices,
        &vertex_count,
        &index_count,
        0,
        clamped_radius,
        std.math.pi,
        std.math.pi * 1.5,
        num_circle_segments,
    );

    // Top-Right corner: 270° to 360°
    appendCornerArc(
        vertices_src,
        indices,
        &vertex_count,
        &index_count,
        1,
        clamped_radius,
        std.math.pi * 1.5,
        std.math.pi * 2.0,
        num_circle_segments,
    );

    // Bottom-Right corner: 0° to 90°
    appendCornerArc(
        vertices_src,
        indices,
        &vertex_count,
        &index_count,
        2,
        clamped_radius,
        0.0,
        std.math.pi * 0.5,
        num_circle_segments,
    );

    // Bottom-Left corner: 90° to 180°
    appendCornerArc(
        vertices_src,
        indices,
        &vertex_count,
        &index_count,
        3,
        clamped_radius,
        std.math.pi * 0.5,
        std.math.pi,
        num_circle_segments,
    );

    // Top edge
    vertices_src[vertex_count] = .{
        .pos = .{ .x = rect.x + clamped_radius, .y = rect.y },
        .u = 0.0,
        .v = 0.0,
    };
    vertex_count += 1;
    vertices_src[vertex_count] = .{
        .pos = .{ .x = rect.x + rect.w - clamped_radius, .y = rect.y },
        .u = 1.0,
        .v = 0.0,
    };
    vertex_count += 1;

    indices[index_count] = 0;
    index_count += 1;
    indices[index_count] = vertex_count - 2;
    index_count += 1;
    indices[index_count] = vertex_count - 1;
    index_count += 1;
    indices[index_count] = 1;
    index_count += 1;
    indices[index_count] = 0;
    index_count += 1;
    indices[index_count] = vertex_count - 1;
    index_count += 1;

    // Right edge
    vertices_src[vertex_count] = .{
        .pos = .{ .x = rect.x + rect.w, .y = rect.y + clamped_radius },
        .u = 1.0,
        .v = 0.0,
    };
    vertex_count += 1;
    vertices_src[vertex_count] = .{
        .pos = .{
            .x = rect.x + rect.w,
            .y = rect.y + rect.h - clamped_radius,
        },
        .u = 1.0,
        .v = 1.0,
    };
    vertex_count += 1;

    indices[index_count] = 1;
    index_count += 1;
    indices[index_count] = vertex_count - 2;
    index_count += 1;
    indices[index_count] = vertex_count - 1;
    index_count += 1;
    indices[index_count] = 2;
    index_count += 1;
    indices[index_count] = 1;
    index_count += 1;
    indices[index_count] = vertex_count - 1;
    index_count += 1;

    // Bottom edge
    vertices_src[vertex_count] = .{
        .pos = .{
            .x = rect.x + rect.w - clamped_radius,
            .y = rect.y + rect.h,
        },
        .u = 1.0,
        .v = 1.0,
    };
    vertex_count += 1;
    vertices_src[vertex_count] = .{
        .pos = .{ .x = rect.x + clamped_radius, .y = rect.y + rect.h },
        .u = 0.0,
        .v = 1.0,
    };
    vertex_count += 1;

    indices[index_count] = 2;
    index_count += 1;
    indices[index_count] = vertex_count - 2;
    index_count += 1;
    indices[index_count] = vertex_count - 1;
    index_count += 1;
    indices[index_count] = 3;
    index_count += 1;
    indices[index_count] = 2;
    index_count += 1;
    indices[index_count] = vertex_count - 1;
    index_count += 1;

    // Left edge
    vertices_src[vertex_count] = .{
        .pos = .{ .x = rect.x, .y = rect.y + rect.h - clamped_radius },
        .u = 0.0,
        .v = 1.0,
    };
    vertex_count += 1;
    vertices_src[vertex_count] = .{
        .pos = .{ .x = rect.x, .y = rect.y + clamped_radius },
        .u = 0.0,
        .v = 0.0,
    };
    vertex_count += 1;

    indices[index_count] = 3;
    index_count += 1;
    indices[index_count] = vertex_count - 2;
    index_count += 1;
    indices[index_count] = vertex_count - 1;
    index_count += 1;
    indices[index_count] = 0;
    index_count += 1;
    indices[index_count] = 3;
    index_count += 1;
    indices[index_count] = vertex_count - 1;
    index_count += 1;

    // Map indexed vertices into the global non-indexed list
    for (indices[0..index_count]) |idx| {
        const v = vertices_src[idx];
        const pt = toNdc(v.pos.x, v.pos.y, win_dims);
        const u = if (screen_uv) v.pos.x / win_dims.w else v.u;
        const v_coord = if (screen_uv) v.pos.y / win_dims.h else v.v;

        try vertices.append(allocator, .{
            .x = pt.x,
            .y = pt.y,
            .u = u,
            .v = v_coord,
            .color = packed_color,
        });
    }
}

/// Emits geometry for a horizontal dashed line segment between `x1` and `x2`.
pub fn drawDashedLineH(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    x1: f32,
    x2: f32,
    y: f32,
    thickness: f32,
    color: [4]f32,
    dash_len: f32,
    gap_len: f32,
    win_dims: PhysicalDims,
) !void {
    var x = x1;
    while (x < x2) {
        const draw_w = @min(dash_len, x2 - x);
        const rect = FRect{ .x = x, .y = y, .w = draw_w, .h = thickness };
        try appendRectQuad(
            vertices,
            allocator,
            rect,
            color,
            win_dims,
            false,
        );
        x += dash_len + gap_len;
    }
}

/// Emits geometry for a vertical dashed line segment between `y1` and `y2`.
pub fn drawDashedLineV(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    x: f32,
    y1: f32,
    y2: f32,
    thickness: f32,
    color: [4]f32,
    dash_len: f32,
    gap_len: f32,
    win_dims: PhysicalDims,
) !void {
    var y = y1;
    while (y < y2) {
        const draw_h = @min(dash_len, y2 - y);
        const rect = FRect{ .x = x, .y = y, .w = thickness, .h = draw_h };
        try appendRectQuad(
            vertices,
            allocator,
            rect,
            color,
            win_dims,
            false,
        );
        y += dash_len + gap_len;
    }
}

/// Emits geometry for a circular arc or ring sector with custom thickness and
/// RGBA color.
pub fn renderArc(
    vertices: *std.ArrayList(Vertex),
    center: FPoint,
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
    win_dims: PhysicalDims,
) !void {
    const rad_start = start_angle * (std.math.pi / 180.0);
    const rad_end = end_angle * (std.math.pi / 180.0);
    const angle_span = @abs(rad_end - rad_start);

    const quadrant_segs = @max(
        @as(usize, 8),
        @as(usize, @intFromFloat(radius * 0.75)),
    );
    const segs_f = @as(f32, @floatFromInt(quadrant_segs)) *
        (angle_span / (std.math.pi / 2.0));
    const num_circle_segments = @max(
        @as(usize, 8),
        @as(usize, @intFromFloat(@round(segs_f))),
    );

    const angle_step =
        (rad_end - rad_start) / @as(f32, @floatFromInt(num_circle_segments));

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

        const out1 = toNdc(out1_x, out1_y, win_dims);
        const out2 = toNdc(out2_x, out2_y, win_dims);
        const in1 = toNdc(in1_x, in1_y, win_dims);
        const in2 = toNdc(in2_x, in2_y, win_dims);

        // Triangle 1: out1, out2, in2
        try vertices.append(allocator, .{
            .x = out1.x,
            .y = out1.y,
            .u = 0.0,
            .v = 0.0,
            .color = color,
        });
        try vertices.append(allocator, .{
            .x = out2.x,
            .y = out2.y,
            .u = 1.0,
            .v = 0.0,
            .color = color,
        });
        try vertices.append(allocator, .{
            .x = in2.x,
            .y = in2.y,
            .u = 1.0,
            .v = 1.0,
            .color = color,
        });

        // Triangle 2: out1, in2, in1
        try vertices.append(allocator, .{
            .x = out1.x,
            .y = out1.y,
            .u = 0.0,
            .v = 0.0,
            .color = color,
        });
        try vertices.append(allocator, .{
            .x = in2.x,
            .y = in2.y,
            .u = 1.0,
            .v = 1.0,
            .color = color,
        });
        try vertices.append(allocator, .{
            .x = in1.x,
            .y = in1.y,
            .u = 0.0,
            .v = 1.0,
            .color = color,
        });
    }
}

test "packRgba and packRgbaF packing and clamping" {
    // Exact byte packing
    const c1 = packRgba(0x12, 0x34, 0x56, 0x78);
    try std.testing.expectEqual(@as(u32, 0x78563412), c1);

    // Float packing (0.0 - 1.0)
    const c2 = packRgbaF(1.0, 0.0, 0.5, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFF8000FF), c2);

    // Clamping behavior (< 0.0 clamped to 0, > 1.0 clamped to 255)
    const c_clamped = packRgbaF(-0.5, 2.0, 0.0, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), c_clamped);

    // RGBA 255 color packing (0.0 - 255.0)
    const c_255 = packRgba255(.{ 255.0, 128.0, 64.0, 255.0 });
    try std.testing.expectEqual(@as(u32, 0xFF4080FF), c_255);
}

test "toNdc - coordinate conversion" {
    const win_dims = PhysicalDims{ .w = 800.0, .h = 600.0 };

    // Top-left (0, 0) maps to (-1.0, 1.0)
    const p_tl = toNdc(0.0, 0.0, win_dims);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p_tl.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p_tl.y, 0.0001);

    // Bottom-right (800, 600) maps to (1.0, -1.0)
    const p_br = toNdc(800.0, 600.0, win_dims);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p_br.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p_br.y, 0.0001);

    // Center (400, 300) maps to (0.0, 0.0)
    const p_c = toNdc(400.0, 300.0, win_dims);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), p_c.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), p_c.y, 0.0001);
}
