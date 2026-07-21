const std = @import("std");
const clay = @import("zclay");
const c = @import("../app/c.zig").c;
const app_state = @import("../app/state.zig");

pub const ZoomPan = struct {
    zoom_factor: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    rotation_angle: f32 = 0.0,
};

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const Uniforms = extern struct {
    brightness: f32,
    contrast: f32,
    is_text_or_color: i32,
    scale_mode: i32,
};

const BatchItem = struct {
    vertex_start: u32,
    vertex_count: u32,
    texture: *c.SDL_GPUTexture,
    is_image: bool,
    scissor: ?c.SDL_Rect,
};

fn appendRectQuad(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    rect: c.SDL_FRect,
    clay_color: clay.Color,
    win_w: f32,
    win_h: f32,
) !void {
    const ndc_x1 = (rect.x / win_w) * 2.0 - 1.0;
    const ndc_x2 = ((rect.x + rect.w) / win_w) * 2.0 - 1.0;
    const ndc_y1 = 1.0 - (rect.y / win_h) * 2.0;
    const ndc_y2 = 1.0 - ((rect.y + rect.h) / win_h) * 2.0;

    const r = clay_color[0] / 255.0;
    const g = clay_color[1] / 255.0;
    const b = clay_color[2] / 255.0;
    const a = clay_color[3] / 255.0;

    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .r = r, .g = g, .b = b, .a = a });
    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .r = r, .g = g, .b = b, .a = a });
    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .r = r, .g = g, .b = b, .a = a });
    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .r = r, .g = g, .b = b, .a = a });
    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 1.0, .r = r, .g = g, .b = b, .a = a });
    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .r = r, .g = g, .b = b, .a = a });
}

fn appendLineQuad(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    p1: c.SDL_FPoint,
    p2: c.SDL_FPoint,
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

    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .r = r, .g = g, .b = b, .a = a });
    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 0.0, .r = r, .g = g, .b = b, .a = a });
    try vertices.append(allocator, .{ .x = ndc_x3, .y = ndc_y3, .u = 1.0, .v = 1.0, .r = r, .g = g, .b = b, .a = a });

    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .r = r, .g = g, .b = b, .a = a });
    try vertices.append(allocator, .{ .x = ndc_x3, .y = ndc_y3, .u = 1.0, .v = 1.0, .r = r, .g = g, .b = b, .a = a });
    try vertices.append(allocator, .{ .x = ndc_x4, .y = ndc_y4, .u = 0.0, .v = 1.0, .r = r, .g = g, .b = b, .a = a });
}

const TrigStep = struct {
    cos_val: f32,
    sin_val: f32,
};

const TRIG_QUADRANT_STEPS = 32;
var trig_quadrant_table: [TRIG_QUADRANT_STEPS + 1]TrigStep = undefined;
var trig_table_initialized: bool = false;

fn ensureTrigTableInitialized() void {
    if (trig_table_initialized) return;
    const step = (std.math.pi / 2.0) / @as(f32, @floatFromInt(TRIG_QUADRANT_STEPS));
    var i: usize = 0;
    while (i <= TRIG_QUADRANT_STEPS) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * step;
        trig_quadrant_table[i] = .{
            .cos_val = @cos(angle),
            .sin_val = @sin(angle),
        };
    }
    trig_table_initialized = true;
}

fn getTrigQuadrant(step_idx: usize, total_steps: usize) TrigStep {
    ensureTrigTableInitialized();
    if (total_steps == TRIG_QUADRANT_STEPS) {
        return trig_quadrant_table[@min(step_idx, TRIG_QUADRANT_STEPS)];
    }
    const ratio = @as(f32, @floatFromInt(step_idx)) / @as(f32, @floatFromInt(total_steps));
    const angle = ratio * (std.math.pi / 2.0);
    return .{
        .cos_val = @cos(angle),
        .sin_val = @sin(angle),
    };
}

fn renderFillRoundedRect(
    vertices: *std.ArrayList(Vertex),
    allocator: std.mem.Allocator,
    rect: c.SDL_FRect,
    corner_radius: f32,
    clay_color: clay.Color,
    win_w: f32,
    win_h: f32,
) !void {
    const color = c.SDL_FColor{
        .r = clay_color[0] / 255.0,
        .g = clay_color[1] / 255.0,
        .b = clay_color[2] / 255.0,
        .a = clay_color[3] / 255.0,
    };

    const min_radius = @min(rect.w, rect.h) / 2.0;
    const clamped_radius = @min(corner_radius, min_radius);

    const num_circle_segments = @max(@as(c_int, 16), @as(c_int, @intFromFloat(clamped_radius * 0.5)));

    const total_vertices = 4 + (4 * (num_circle_segments * 2)) + 8;
    const total_indices = 6 + (4 * (num_circle_segments * 3)) + 24;

    var stack_vertices: [512]c.SDL_Vertex = undefined;
    var stack_indices: [1024]c_int = undefined;

    const vertices_src = if (total_vertices <= stack_vertices.len)
        stack_vertices[0..@intCast(total_vertices)]
    else
        try allocator.alloc(c.SDL_Vertex, @intCast(total_vertices));
    defer if (total_vertices > stack_vertices.len) allocator.free(vertices_src);

    const indices = if (total_indices <= stack_indices.len)
        stack_indices[0..@intCast(total_indices)]
    else
        try allocator.alloc(c_int, @intCast(total_indices));
    defer if (total_indices > stack_indices.len) allocator.free(indices);

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

    const num_seg_u: usize = @intCast(num_circle_segments);
    var i: usize = 0;
    while (i < num_seg_u) : (i += 1) {
        const t1 = getTrigQuadrant(i, num_seg_u);
        const t2 = getTrigQuadrant(i + 1, num_seg_u);
        const cos_1 = t1.cos_val;
        const sin_1 = t1.sin_val;
        const cos_2 = t2.cos_val;
        const sin_2 = t2.sin_val;

        var j: usize = 0;
        while (j < 4) : (j += 1) {
            var cx: f32 = 0;
            var cy: f32 = 0;
            var sign_x: f32 = 0;
            var sign_y: f32 = 0;

            switch (j) {
                0 => {
                    cx = rect.x + clamped_radius;
                    cy = rect.y + clamped_radius;
                    sign_x = -1;
                    sign_y = -1;
                },
                1 => {
                    cx = rect.x + rect.w - clamped_radius;
                    cy = rect.y + clamped_radius;
                    sign_x = 1;
                    sign_y = -1;
                },
                2 => {
                    cx = rect.x + rect.w - clamped_radius;
                    cy = rect.y + rect.h - clamped_radius;
                    sign_x = 1;
                    sign_y = 1;
                },
                3 => {
                    cx = rect.x + clamped_radius;
                    cy = rect.y + rect.h - clamped_radius;
                    sign_x = -1;
                    sign_y = 1;
                },
                else => unreachable,
            }

            vertices_src[vertex_count] = .{
                .position = .{
                    .x = cx + cos_1 * clamped_radius * sign_x,
                    .y = cy + sin_1 * clamped_radius * sign_y,
                },
                .color = color,
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            vertex_count += 1;

            vertices_src[vertex_count] = .{
                .position = .{
                    .x = cx + cos_2 * clamped_radius * sign_x,
                    .y = cy + sin_2 * clamped_radius * sign_y,
                },
                .color = color,
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            vertex_count += 1;

            indices[index_count] = @intCast(j);
            index_count += 1;
            indices[index_count] = @intCast(vertex_count - 2);
            index_count += 1;
            indices[index_count] = @intCast(vertex_count - 1);
            index_count += 1;
        }
    }

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
            .r = v.color.r,
            .g = v.color.g,
            .b = v.color.b,
            .a = v.color.a,
        });
    }
}

fn drawDashedLineH(vertices: *std.ArrayList(Vertex), allocator: std.mem.Allocator, x1: f32, x2: f32, y: f32, thickness: f32, color: clay.Color, dash_len: f32, gap_len: f32, win_w: f32, win_h: f32) !void {
    var x = x1;
    while (x < x2) {
        const draw_w = @min(dash_len, x2 - x);
        const rect = c.SDL_FRect{ .x = x, .y = y, .w = draw_w, .h = thickness };
        try appendRectQuad(vertices, allocator, rect, color, win_w, win_h);
        x += dash_len + gap_len;
    }
}

fn drawDashedLineV(vertices: *std.ArrayList(Vertex), allocator: std.mem.Allocator, x: f32, y1: f32, y2: f32, thickness: f32, color: clay.Color, dash_len: f32, gap_len: f32, win_w: f32, win_h: f32) !void {
    var y = y1;
    while (y < y2) {
        const draw_h = @min(dash_len, y2 - y);
        const rect = c.SDL_FRect{ .x = x, .y = y, .w = thickness, .h = draw_h };
        try appendRectQuad(vertices, allocator, rect, color, win_w, win_h);
        y += dash_len + gap_len;
    }
}

fn renderArc(
    vertices: *std.ArrayList(Vertex),
    center: c.SDL_FPoint,
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

    const num_circle_segments = @max(@as(c_int, 16), @as(c_int, @intFromFloat(radius * 1.5)));

    const angle_step = (rad_end - rad_start) / @as(f32, @floatFromInt(num_circle_segments));

    const points_len = @as(usize, @intCast(num_circle_segments + 1));

    var stack_points: [128]c.SDL_FPoint = undefined;
    const points = if (points_len <= stack_points.len)
        stack_points[0..points_len]
    else
        try allocator.alloc(c.SDL_FPoint, points_len);
    defer if (points_len > stack_points.len) allocator.free(points);

    var stack_cos: [128]f32 = undefined;
    var stack_sin: [128]f32 = undefined;

    const cos_table = if (points_len <= stack_cos.len)
        stack_cos[0..points_len]
    else
        try allocator.alloc(f32, points_len);
    defer if (points_len > stack_cos.len) allocator.free(cos_table);

    const sin_table = if (points_len <= stack_sin.len)
        stack_sin[0..points_len]
    else
        try allocator.alloc(f32, points_len);
    defer if (points_len > stack_sin.len) allocator.free(sin_table);

    var idx: usize = 0;
    while (idx < points_len) : (idx += 1) {
        const angle = rad_start + @as(f32, @floatFromInt(idx)) * angle_step;
        cos_table[idx] = @cos(angle);
        sin_table[idx] = @sin(angle);
    }

    // Calculate points along the middle line of the arc thickness
    const clamped_radius = @max(radius - thickness * 0.5, 1.0);

    var i: usize = 0;
    while (i < points_len) : (i += 1) {
        points[i] = .{
            .x = center.x + cos_table[i] * clamped_radius,
            .y = center.y + sin_table[i] * clamped_radius,
        };
    }

    if (is_dashed) {
        var s: usize = 0;
        while (s < points_len - 1) : (s += 4) {
            const segment_len = @min(2, points_len - 1 - s);
            var k: usize = 0;
            while (k < segment_len) : (k += 1) {
                try appendLineQuad(vertices, allocator, points[s + k], points[s + k + 1], thickness, r, g, b, a, win_w, win_h);
            }
        }
    } else {
        var s: usize = 0;
        while (s < points_len - 1) : (s += 1) {
            try appendLineQuad(vertices, allocator, points[s], points[s + 1], thickness, r, g, b, a, win_w, win_h);
        }
    }
}

fn scissorEqual(a: ?c.SDL_Rect, b: ?c.SDL_Rect) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const sa = a.?;
    const sb = b.?;
    return sa.x == sb.x and sa.y == sb.y and sa.w == sb.w and sa.h == sb.h;
}

fn addBatch(
    batches: *std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,
    start: u32,
    count: u32,
    texture: *c.SDL_GPUTexture,
    is_image: bool,
    scissor: ?c.SDL_Rect,
) !void {
    if (batches.items.len > 0) {
        var last = &batches.items[batches.items.len - 1];
        if (last.texture == texture and last.is_image == is_image and scissorEqual(last.scissor, scissor)) {
            last.vertex_count += count;
            return;
        }
    }
    try batches.append(allocator, .{
        .vertex_start = start,
        .vertex_count = count,
        .texture = texture,
        .is_image = is_image,
        .scissor = scissor,
    });
}

pub fn renderClayCommands(
    state: *app_state.ViewerState,
    cmd_buf: *c.SDL_GPUCommandBuffer,
    swap_tex: *c.SDL_GPUTexture,
    fonts: []const ?*c.TTF_Font,
    r_commands: []const clay.RenderCommand,
    allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(*c.SDL_GPUTransferBuffer),
    win_w: i32,
    win_h: i32,
) !void {
    const f_win_w = @as(f32, @floatFromInt(win_w));
    const f_win_h = @as(f32, @floatFromInt(win_h));

    var vertices = std.ArrayList(Vertex).empty;
    defer vertices.deinit(allocator);

    var batches = std.ArrayList(BatchItem).empty;
    defer batches.deinit(allocator);

    var current_scissor: ?c.SDL_Rect = null;

    for (r_commands) |rcmd| {
        const bb = rcmd.bounding_box;
        const rect = c.SDL_FRect{
            .x = @round(bb.x),
            .y = @round(bb.y),
            .w = @round(bb.width),
            .h = @round(bb.height),
        };

        switch (rcmd.command_type) {
            .scissor_start => {
                current_scissor = c.SDL_Rect{
                    .x = @intFromFloat(@round(bb.x)),
                    .y = @intFromFloat(@round(bb.y)),
                    .w = @intFromFloat(@round(bb.width)),
                    .h = @intFromFloat(@round(bb.height)),
                };
            },
            .scissor_end => {
                current_scissor = null;
            },
            .rectangle => {
                const config = rcmd.render_data.rectangle;
                const start = @as(u32, @intCast(vertices.items.len));

                if (config.corner_radius.top_left > 0) {
                    try renderFillRoundedRect(&vertices, allocator, rect, config.corner_radius.top_left, config.background_color, f_win_w, f_win_h);
                } else {
                    try appendRectQuad(&vertices, allocator, rect, config.background_color, f_win_w, f_win_h);
                }

                const count = @as(u32, @intCast(vertices.items.len)) - start;
                if (count > 0) {
                    try addBatch(&batches, allocator, start, count, state.white_texture.?, false, current_scissor);
                }
            },
            .text => {
                const text_data = rcmd.render_data.text;
                if (text_data.font_id >= fonts.len) continue;
                const font_ptr = fonts[text_data.font_id] orelse continue;

                const len = @as(usize, @intCast(text_data.string_contents.length));
                const text_slice = text_data.string_contents.chars[0..len];

                // 1. Check/Lookup cache
                const color_u32 = @as(u32, @intFromFloat(text_data.text_color[0])) |
                    (@as(u32, @intFromFloat(text_data.text_color[1])) << 8) |
                    (@as(u32, @intFromFloat(text_data.text_color[2])) << 16) |
                    (@as(u32, @intFromFloat(text_data.text_color[3])) << 24);

                const key = app_state.TextCacheKey{
                    .font_id = text_data.font_id,
                    .font_size = text_data.font_size,
                    .color = color_u32,
                    .hash = std.hash.Wyhash.hash(0, text_slice),
                };

                var cached_tex: ?*c.SDL_GPUTexture = null;
                var w_f: f32 = 0.0;
                var h_f: f32 = 0.0;

                if (state.text_cache.getEntry(key)) |entry| {
                    entry.value_ptr.last_used_frame = state.gpu_frame_index;
                    cached_tex = entry.value_ptr.texture;
                    w_f = entry.value_ptr.w;
                    h_f = entry.value_ptr.h;
                } else {
                    // Set font size
                    if (!c.TTF_SetFontSize(font_ptr, @as(f32, @floatFromInt(text_data.font_size)))) {
                        std.log.err("TTF_SetFontSize failed: {s}", .{c.SDL_GetError()});
                    }

                    const buffer = try allocator.alloc(u8, len + 1);
                    defer allocator.free(buffer);
                    @memcpy(buffer[0..len], text_slice);
                    buffer[len] = 0;

                    const surf = c.TTF_RenderText_Blended(font_ptr, buffer.ptr, len, c.SDL_Color{
                        .r = @intFromFloat(text_data.text_color[0]),
                        .g = @intFromFloat(text_data.text_color[1]),
                        .b = @intFromFloat(text_data.text_color[2]),
                        .a = @intFromFloat(text_data.text_color[3]),
                    }) orelse continue;
                    defer c.SDL_DestroySurface(surf);

                    const converted = c.SDL_ConvertSurface(surf, c.SDL_PIXELFORMAT_RGBA32) orelse continue;
                    defer c.SDL_DestroySurface(converted);

                    const tex_info = c.SDL_GPUTextureCreateInfo{
                        .type = c.SDL_GPU_TEXTURETYPE_2D,
                        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                        .width = @intCast(converted.*.w),
                        .height = @intCast(converted.*.h),
                        .layer_count_or_depth = 1,
                        .num_levels = 1,
                        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
                        .props = 0,
                    };
                    const tex = c.SDL_CreateGPUTexture(state.gpu_device.?, &tex_info) orelse continue;

                    const size = @as(usize, @intCast(converted.*.w)) * @as(usize, @intCast(converted.*.h)) * 4;
                    const transfer_buf = c.SDL_CreateGPUTransferBuffer(state.gpu_device.?, &c.SDL_GPUTransferBufferCreateInfo{
                        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                        .size = @intCast(size),
                        .props = 0,
                    }) orelse {
                        c.SDL_ReleaseGPUTexture(state.gpu_device.?, tex);
                        continue;
                    };
                    temp_buffers.append(allocator, transfer_buf) catch {
                        c.SDL_ReleaseGPUTransferBuffer(state.gpu_device.?, transfer_buf);
                        c.SDL_ReleaseGPUTexture(state.gpu_device.?, tex);
                        continue;
                    };

                    const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(state.gpu_device.?, transfer_buf, false) orelse {
                        c.SDL_ReleaseGPUTexture(state.gpu_device.?, tex);
                        continue;
                    });
                    const pixels: [*]const u8 = @ptrCast(converted.*.pixels);
                    @memcpy(mapped[0..size], pixels[0..size]);
                    c.SDL_UnmapGPUTransferBuffer(state.gpu_device.?, transfer_buf);

                    const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
                        c.SDL_ReleaseGPUTexture(state.gpu_device.?, tex);
                        continue;
                    };
                    c.SDL_UploadToGPUTexture(copy_pass, &c.SDL_GPUTextureTransferInfo{
                        .transfer_buffer = transfer_buf,
                        .offset = 0,
                        .pixels_per_row = @intCast(converted.*.w),
                        .rows_per_layer = @intCast(converted.*.h),
                    }, &c.SDL_GPUTextureRegion{
                        .texture = tex,
                        .w = @intCast(converted.*.w),
                        .h = @intCast(converted.*.h),
                        .d = 1,
                    }, false);
                    c.SDL_EndGPUCopyPass(copy_pass);

                    w_f = @floatFromInt(converted.*.w);
                    h_f = @floatFromInt(converted.*.h);
                    cached_tex = tex;

                    state.text_cache.put(state.allocator, key, .{
                        .texture = tex,
                        .w = w_f,
                        .h = h_f,
                        .last_used_frame = state.gpu_frame_index,
                    }) catch {
                        c.SDL_ReleaseGPUTexture(state.gpu_device.?, tex);
                        continue;
                    };
                }

                const tex = cached_tex.?;

                // Align to pixel grid
                const offset_y = @round((rcmd.bounding_box.height - h_f) / 2.0);
                const world_y = @round(rcmd.bounding_box.y) + @max(0.0, offset_y);
                const world_x = @round(rcmd.bounding_box.x);

                const ndc_x1 = (world_x / f_win_w) * 2.0 - 1.0;
                const ndc_y1 = 1.0 - (world_y / f_win_h) * 2.0;
                const ndc_x2 = ((world_x + w_f) / f_win_w) * 2.0 - 1.0;
                const ndc_y2 = 1.0 - ((world_y + h_f) / f_win_h) * 2.0;

                const start = @as(u32, @intCast(vertices.items.len));

                // Append 6 vertices for 2 triangles using white vertex color to avoid color squaring (pre-colored on CPU surface)
                try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 1.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });

                try addBatch(&batches, allocator, start, 6, tex, false, current_scissor);
            },
            .border => {
                const config = rcmd.render_data.border;
                const min_radius = @min(rect.w, rect.h) / 2.0;
                const clamped_radii = struct {
                    top_left: f32,
                    top_right: f32,
                    bottom_left: f32,
                    bottom_right: f32,
                }{
                    .top_left = @min(config.corner_radius.top_left, min_radius),
                    .top_right = @min(config.corner_radius.top_right, min_radius),
                    .bottom_left = @min(config.corner_radius.bottom_left, min_radius),
                    .bottom_right = @min(config.corner_radius.bottom_right, min_radius),
                };

                const tag = if (rcmd.user_data) |ptr| app_state.ElementTag.fromInt(@intFromPtr(ptr)) else .none;
                const is_dashed = (tag == .drop_zone_box);

                const r = config.color[0] / 255.0;
                const g = config.color[1] / 255.0;
                const b = config.color[2] / 255.0;
                const a = config.color[3] / 255.0;

                const start_batch = @as(u32, @intCast(vertices.items.len));

                if (config.width.left > 0) {
                    const starting_y = rect.y + clamped_radii.top_left;
                    const length = rect.h - clamped_radii.top_left - clamped_radii.bottom_left;
                    if (is_dashed) {
                        try drawDashedLineV(&vertices, allocator, rect.x, starting_y, starting_y + length, @floatFromInt(config.width.left), config.color, 8.0, 6.0, f_win_w, f_win_h);
                    } else {
                        const line = c.SDL_FRect{ .x = rect.x, .y = starting_y, .w = @floatFromInt(config.width.left), .h = length };
                        try appendRectQuad(&vertices, allocator, line, config.color, f_win_w, f_win_h);
                    }
                }
                if (config.width.right > 0) {
                    const starting_x = rect.x + rect.w - @as(f32, @floatFromInt(config.width.right));
                    const starting_y = rect.y + clamped_radii.top_right;
                    const length = rect.h - clamped_radii.top_right - clamped_radii.bottom_right;
                    if (is_dashed) {
                        try drawDashedLineV(&vertices, allocator, starting_x, starting_y, starting_y + length, @floatFromInt(config.width.right), config.color, 8.0, 6.0, f_win_w, f_win_h);
                    } else {
                        const line = c.SDL_FRect{ .x = starting_x, .y = starting_y, .w = @floatFromInt(config.width.right), .h = length };
                        try appendRectQuad(&vertices, allocator, line, config.color, f_win_w, f_win_h);
                    }
                }
                if (config.width.top > 0) {
                    const starting_x = rect.x + clamped_radii.top_left;
                    const length = rect.w - clamped_radii.top_left - clamped_radii.top_right;
                    if (is_dashed) {
                        try drawDashedLineH(&vertices, allocator, starting_x, starting_x + length, rect.y, @floatFromInt(config.width.top), config.color, 8.0, 6.0, f_win_w, f_win_h);
                    } else {
                        const line = c.SDL_FRect{ .x = starting_x, .y = rect.y, .w = length, .h = @floatFromInt(config.width.top) };
                        try appendRectQuad(&vertices, allocator, line, config.color, f_win_w, f_win_h);
                    }
                }
                if (config.width.bottom > 0) {
                    const starting_x = rect.x + clamped_radii.bottom_left;
                    const starting_y = rect.y + rect.h - @as(f32, @floatFromInt(config.width.bottom));
                    const length = rect.w - clamped_radii.bottom_left - clamped_radii.bottom_right;
                    if (is_dashed) {
                        try drawDashedLineH(&vertices, allocator, starting_x, starting_x + length, starting_y, @floatFromInt(config.width.bottom), config.color, 8.0, 6.0, f_win_w, f_win_h);
                    } else {
                        const line = c.SDL_FRect{ .x = starting_x, .y = starting_y, .w = length, .h = @floatFromInt(config.width.bottom) };
                        try appendRectQuad(&vertices, allocator, line, config.color, f_win_w, f_win_h);
                    }
                }

                if (config.corner_radius.top_left > 0) {
                    try renderArc(&vertices, .{ .x = rect.x + clamped_radii.top_left, .y = rect.y + clamped_radii.top_left }, clamped_radii.top_left, 180.0, 270.0, @floatFromInt(config.width.top), r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
                }
                if (config.corner_radius.top_right > 0) {
                    try renderArc(&vertices, .{ .x = rect.x + rect.w - clamped_radii.top_right, .y = rect.y + clamped_radii.top_right }, clamped_radii.top_right, 270.0, 360.0, @floatFromInt(config.width.top), r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
                }
                if (config.corner_radius.bottom_left > 0) {
                    try renderArc(&vertices, .{ .x = rect.x + clamped_radii.bottom_left, .y = rect.y + rect.h - clamped_radii.bottom_left }, clamped_radii.bottom_left, 90.0, 180.0, @floatFromInt(config.width.bottom), r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
                }
                if (config.corner_radius.bottom_right > 0) {
                    try renderArc(&vertices, .{ .x = rect.x + rect.w - clamped_radii.bottom_right, .y = rect.y + rect.h - clamped_radii.bottom_right }, clamped_radii.bottom_right, 0.0, 90.0, @floatFromInt(config.width.bottom), r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
                }

                const count = @as(u32, @intCast(vertices.items.len)) - start_batch;
                if (count > 0) {
                    try addBatch(&batches, allocator, start_batch, count, state.white_texture.?, false, current_scissor);
                }
            },
            .image => {
                const texture: ?*c.SDL_GPUTexture = @ptrCast(@alignCast(rcmd.render_data.image.image_data));
                if (texture) |tex| {
                    var dst_w = rect.w;
                    var dst_h = rect.h;
                    const angle = state.rotation_angle;
                    const is_90_or_270 = std.math.approxEqAbs(f32, angle, 90.0, 0.01) or std.math.approxEqAbs(f32, angle, 270.0, 0.01);
                    if (is_90_or_270) {
                        dst_w = rect.h;
                        dst_h = rect.w;
                    }
                    var dst_rect = rect;
                    dst_rect.w = dst_w * state.zoom_factor;
                    dst_rect.h = dst_h * state.zoom_factor;
                    const center_x = rect.x + rect.w / 2.0;
                    const center_y = rect.y + rect.h / 2.0;
                    dst_rect.x = center_x - (dst_rect.w / 2.0) + state.pan_x;
                    dst_rect.y = center_y - (dst_rect.h / 2.0) + state.pan_y;

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

                    const ndc_x1 = (world_x1 / f_win_w) * 2.0 - 1.0;
                    const ndc_y1 = 1.0 - (world_y1 / f_win_h) * 2.0;
                    const ndc_x2 = (world_x2 / f_win_w) * 2.0 - 1.0;
                    const ndc_y2 = 1.0 - (world_y2 / f_win_h) * 2.0;
                    const ndc_x3 = (world_x3 / f_win_w) * 2.0 - 1.0;
                    const ndc_y3 = 1.0 - (world_y3 / f_win_h) * 2.0;
                    const ndc_x4 = (world_x4 / f_win_w) * 2.0 - 1.0;
                    const ndc_y4 = 1.0 - (world_y4 / f_win_h) * 2.0;

                    const start = @as(u32, @intCast(vertices.items.len));
                    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 0.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                    try vertices.append(allocator, .{ .x = ndc_x4, .y = ndc_y4, .u = 0.0, .v = 1.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 0.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                    try vertices.append(allocator, .{ .x = ndc_x3, .y = ndc_y3, .u = 1.0, .v = 1.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
                    try vertices.append(allocator, .{ .x = ndc_x4, .y = ndc_y4, .u = 0.0, .v = 1.0, .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });

                    try addBatch(&batches, allocator, start, 6, tex, true, current_scissor);
                }
            },
            else => {
                std.log.warn("Skipping unhandled render command type: {}", .{rcmd.command_type});
            },
        }
    }

    // Persistent Vertex Buffer Double-Buffering
    var vert_buf: ?*c.SDL_GPUBuffer = null;
    const needed_size = vertices.items.len * @sizeOf(Vertex);
    const frame_idx = state.gpu_frame_index % 2;

    if (needed_size > 0) {
        if (state.gpu_vertex_buffers[frame_idx] == null or state.gpu_buffer_capacities[frame_idx] < needed_size) {
            if (state.gpu_vertex_buffers[frame_idx]) |vb| {
                c.SDL_ReleaseGPUBuffer(state.gpu_device.?, vb);
            }
            if (state.gpu_transfer_buffers[frame_idx]) |tb| {
                c.SDL_ReleaseGPUTransferBuffer(state.gpu_device.?, tb);
            }

            const new_capacity = std.mem.alignForward(usize, needed_size * 2, 4096);

            state.gpu_vertex_buffers[frame_idx] = c.SDL_CreateGPUBuffer(state.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
                .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
                .size = @intCast(new_capacity),
                .props = 0,
            }) orelse return error.GPUBufferCreationFailed;

            state.gpu_transfer_buffers[frame_idx] = c.SDL_CreateGPUTransferBuffer(state.gpu_device.?, &c.SDL_GPUTransferBufferCreateInfo{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = @intCast(new_capacity),
                .props = 0,
            }) orelse return error.GPUTransferBufferCreationFailed;

            state.gpu_buffer_capacities[frame_idx] = new_capacity;
        }

        const vb = state.gpu_vertex_buffers[frame_idx].?;
        const tb = state.gpu_transfer_buffers[frame_idx].?;

        const mapped: [*]Vertex = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(state.gpu_device.?, tb, false) orelse return error.GPUMapFailed));
        @memcpy(mapped[0..vertices.items.len], vertices.items);
        c.SDL_UnmapGPUTransferBuffer(state.gpu_device.?, tb);

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse return error.GPUCopyPassFailed;
        c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
            .transfer_buffer = tb,
            .offset = 0,
        }, &c.SDL_GPUBufferRegion{
            .buffer = vb,
            .offset = 0,
            .size = @intCast(needed_size),
        }, false);
        c.SDL_EndGPUCopyPass(copy_pass);

        vert_buf = vb;
    }

    const color_target = c.SDL_GPUColorTargetInfo{
        .texture = swap_tex,
        .clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .cycle = false,
        .padding1 = 0,
        .padding2 = 0,
    };

    const render_pass = c.SDL_BeginGPURenderPass(cmd_buf, &color_target, 1, null) orelse return;
    defer c.SDL_EndGPURenderPass(render_pass);

    c.SDL_BindGPUGraphicsPipeline(render_pass, state.gpu_pipeline.?);

    if (vert_buf) |vb| {
        const vert_binding = c.SDL_GPUBufferBinding{ .buffer = vb, .offset = 0 };
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &vert_binding, 1);

        for (batches.items) |batch| {
            if (batch.scissor) |sc| {
                var safe_sc = sc;
                safe_sc.x = @max(0, sc.x);
                safe_sc.y = @max(0, sc.y);
                safe_sc.w = @max(0, sc.w - (safe_sc.x - sc.x));
                safe_sc.h = @max(0, sc.h - (safe_sc.y - sc.y));
                if (safe_sc.x < win_w and safe_sc.y < win_h) {
                    safe_sc.w = @min(safe_sc.w, win_w - safe_sc.x);
                    safe_sc.h = @min(safe_sc.h, win_h - safe_sc.y);
                    c.SDL_SetGPUScissor(render_pass, &safe_sc);
                } else {
                    const empty_sc = c.SDL_Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
                    c.SDL_SetGPUScissor(render_pass, &empty_sc);
                }
            } else {
                const full_sc = c.SDL_Rect{ .x = 0, .y = 0, .w = win_w, .h = win_h };
                c.SDL_SetGPUScissor(render_pass, &full_sc);
            }

            const scale_mode_val: i32 = switch (state.texture_scale_mode) {
                .nearest => 0,
                .linear => 1,
                .pixel_art => 2,
                .mitchell => 3,
                .lanczos3 => 4,
            };
            const ubo = Uniforms{
                .brightness = state.brightness,
                .contrast = state.contrast,
                .is_text_or_color = if (batch.is_image) 0 else 1,
                .scale_mode = scale_mode_val,
            };
            c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &ubo, @sizeOf(Uniforms));

            c.SDL_BindGPUFragmentSamplers(render_pass, 0, &c.SDL_GPUTextureSamplerBinding{ .texture = batch.texture, .sampler = state.gpu_sampler.? }, 1);
            c.SDL_DrawGPUPrimitives(render_pass, batch.vertex_count, 1, batch.vertex_start, 0);
        }
    }

    // 4. Cache eviction for text textures (unused for >120 frames)
    var to_evict = std.ArrayList(app_state.TextCacheKey).empty;
    defer to_evict.deinit(allocator);

    var text_iter = state.text_cache.iterator();
    while (text_iter.next()) |entry| {
        if (state.gpu_frame_index > entry.value_ptr.last_used_frame and
            state.gpu_frame_index - entry.value_ptr.last_used_frame > 120)
        {
            to_evict.append(allocator, entry.key_ptr.*) catch {};
        }
    }

    for (to_evict.items) |k| {
        if (state.text_cache.fetchRemove(k)) |removed| {
            c.SDL_ReleaseGPUTexture(state.gpu_device.?, removed.value.texture);
        }
    }

    state.gpu_frame_index += 1;
}
