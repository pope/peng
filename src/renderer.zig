const std = @import("std");
const clay = @import("zclay");

const c = @import("main.zig").c;

fn setRenderDrawColor(renderer: ?*c.SDL_Renderer, color: clay.Color) void {
    if (!c.SDL_SetRenderDrawColor(
        renderer,
        @intCast(@as(i32, @intFromFloat(color[0]))),
        @intCast(@as(i32, @intFromFloat(color[1]))),
        @intCast(@as(i32, @intFromFloat(color[2]))),
        @intCast(@as(i32, @intFromFloat(color[3]))),
    )) {
        std.log.err("SDL_SetRenderDrawColor failed: {s}", .{c.SDL_GetError()});
    }
}

fn setTextColor(text_obj: ?*c.TTF_Text, color: clay.Color) void {
    if (!c.TTF_SetTextColor(
        text_obj,
        @intCast(@as(i32, @intFromFloat(color[0]))),
        @intCast(@as(i32, @intFromFloat(color[1]))),
        @intCast(@as(i32, @intFromFloat(color[2]))),
        @intCast(@as(i32, @intFromFloat(color[3]))),
    )) {
        std.log.err("TTF_SetTextColor failed: {s}", .{c.SDL_GetError()});
    }
}

fn renderFillRoundedRect(renderer: ?*c.SDL_Renderer, rect: c.SDL_FRect, corner_radius: f32, clay_color: clay.Color, allocator: std.mem.Allocator) !void {
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

    const vertices = if (total_vertices <= stack_vertices.len)
        stack_vertices[0..@intCast(total_vertices)]
    else
        try allocator.alloc(c.SDL_Vertex, @intCast(total_vertices));
    defer if (total_vertices > stack_vertices.len) allocator.free(vertices);

    const indices = if (total_indices <= stack_indices.len)
        stack_indices[0..@intCast(total_indices)]
    else
        try allocator.alloc(c_int, @intCast(total_indices));
    defer if (total_indices > stack_indices.len) allocator.free(indices);

    var vertex_count: usize = 0;
    var index_count: usize = 0;

    // Define center rectangle
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + clamped_radius, .y = rect.y + clamped_radius }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    vertex_count += 1;
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + rect.w - clamped_radius, .y = rect.y + clamped_radius }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } };
    vertex_count += 1;
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + rect.w - clamped_radius, .y = rect.y + rect.h - clamped_radius }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } };
    vertex_count += 1;
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + clamped_radius, .y = rect.y + rect.h - clamped_radius }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } };
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

    // Define rounded corners as triangle fans
    const step = (std.math.pi / 2.0) / @as(f32, @floatFromInt(num_circle_segments));
    var i: i32 = 0;
    while (i < num_circle_segments) : (i += 1) {
        const angle_1 = @as(f32, @floatFromInt(i)) * step;
        const angle_2 = @as(f32, @floatFromInt(i + 1)) * step;
        const cos_1 = @cos(angle_1);
        const sin_1 = @sin(angle_1);
        const cos_2 = @cos(angle_2);
        const sin_2 = @sin(angle_2);

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

            vertices[vertex_count] = .{
                .position = .{
                    .x = cx + cos_1 * clamped_radius * sign_x,
                    .y = cy + sin_1 * clamped_radius * sign_y,
                },
                .color = color,
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            vertex_count += 1;

            vertices[vertex_count] = .{
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
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + clamped_radius, .y = rect.y }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    vertex_count += 1;
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + rect.w - clamped_radius, .y = rect.y }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } };
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
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + clamped_radius }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } };
    vertex_count += 1;
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + rect.h - clamped_radius }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } };
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
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + rect.w - clamped_radius, .y = rect.y + rect.h }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } };
    vertex_count += 1;
    vertices[vertex_count] = .{ .position = .{ .x = rect.x + clamped_radius, .y = rect.y + rect.h }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } };
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
    vertices[vertex_count] = .{ .position = .{ .x = rect.x, .y = rect.y + rect.h - clamped_radius }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } };
    vertex_count += 1;
    vertices[vertex_count] = .{ .position = .{ .x = rect.x, .y = rect.y + clamped_radius }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
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

    if (!c.SDL_RenderGeometry(renderer, null, &vertices[0], @intCast(vertex_count), &indices[0], @intCast(index_count))) {
        std.log.err("SDL_RenderGeometry failed: {s}", .{c.SDL_GetError()});
    }
}

fn renderArc(renderer: ?*c.SDL_Renderer, center: c.SDL_FPoint, radius: f32, start_angle: f32, end_angle: f32, thickness: f32, clay_color: clay.Color, allocator: std.mem.Allocator) !void {
    setRenderDrawColor(renderer, clay_color);

    const rad_start = start_angle * (std.math.pi / 180.0);
    const rad_end = end_angle * (std.math.pi / 180.0);

    const num_circle_segments = @max(@as(c_int, 16), @as(c_int, @intFromFloat(radius * 1.5)));

    const angle_step = (rad_end - rad_start) / @as(f32, @floatFromInt(num_circle_segments));
    const thickness_step: f32 = 0.4;

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

    var t = thickness_step;
    while (t < thickness - thickness_step) : (t += thickness_step) {
        const clamped_radius = @max(radius - t, 1.0);

        var i: usize = 0;
        while (i < points_len) : (i += 1) {
            points[i] = .{
                .x = @round(center.x + cos_table[i] * clamped_radius),
                .y = @round(center.y + sin_table[i] * clamped_radius),
            };
        }
        if (!c.SDL_RenderLines(renderer, &points[0], @intCast(points_len))) {
            std.log.err("SDL_RenderLines failed: {s}", .{c.SDL_GetError()});
        }
    }
}

pub fn renderClayCommands(renderer: ?*c.SDL_Renderer, text_engine: ?*c.TTF_TextEngine, fonts: []const ?*c.TTF_Font, r_commands: []const clay.RenderCommand, allocator: std.mem.Allocator) !void {
    for (r_commands) |rcmd| {
        const bb = rcmd.bounding_box;
        const rect = c.SDL_FRect{
            .x = @round(bb.x),
            .y = @round(bb.y),
            .w = @round(bb.width),
            .h = @round(bb.height),
        };

        switch (rcmd.command_type) {
            .rectangle => {
                const config = rcmd.render_data.rectangle;
                if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND)) {
                    std.log.err("SDL_SetRenderDrawBlendMode failed: {s}", .{c.SDL_GetError()});
                }
                setRenderDrawColor(renderer, config.background_color);
                if (config.corner_radius.top_left > 0) {
                    try renderFillRoundedRect(renderer, rect, config.corner_radius.top_left, config.background_color, allocator);
                } else {
                    if (!c.SDL_RenderFillRect(renderer, &rect)) {
                        std.log.err("SDL_RenderFillRect failed: {s}", .{c.SDL_GetError()});
                    }
                }
            },
            .text => {
                const config = rcmd.render_data.text;
                if (config.font_id >= fonts.len) continue;
                const font = fonts[config.font_id] orelse continue;
                if (!c.TTF_SetFontSize(font, @as(f32, @floatFromInt(config.font_size)))) {
                    std.log.err("TTF_SetFontSize failed: {s}", .{c.SDL_GetError()});
                }

                // Copy string contents to stack/heap to null terminate
                var stack_buf: [1024]u8 = undefined;
                const str_len = @as(usize, @intCast(config.string_contents.length));
                const buffer = if (str_len + 1 < stack_buf.len)
                    stack_buf[0 .. str_len + 1]
                else
                    try allocator.alloc(u8, str_len + 1);
                defer if (str_len + 1 >= stack_buf.len) allocator.free(buffer);
                @memcpy(buffer[0..str_len], config.string_contents.chars[0..str_len]);
                buffer[str_len] = 0;

                const text_obj = c.TTF_CreateText(text_engine, font, buffer.ptr, str_len) orelse continue;
                defer c.TTF_DestroyText(text_obj);

                setTextColor(text_obj, config.text_color);
                if (!c.TTF_DrawRendererText(text_obj, rect.x, rect.y)) {
                    std.log.err("TTF_DrawRendererText failed: {s}", .{c.SDL_GetError()});
                }
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

                setRenderDrawColor(renderer, config.color);

                if (config.width.left > 0) {
                    const starting_y = rect.y + clamped_radii.top_left;
                    const length = rect.h - clamped_radii.top_left - clamped_radii.bottom_left;
                    const line = c.SDL_FRect{ .x = rect.x, .y = starting_y, .w = @floatFromInt(config.width.left), .h = length };
                    if (!c.SDL_RenderFillRect(renderer, &line)) {
                        std.log.err("SDL_RenderFillRect failed: {s}", .{c.SDL_GetError()});
                    }
                }
                if (config.width.right > 0) {
                    const starting_x = rect.x + rect.w - @as(f32, @floatFromInt(config.width.right));
                    const starting_y = rect.y + clamped_radii.top_right;
                    const length = rect.h - clamped_radii.top_right - clamped_radii.bottom_right;
                    const line = c.SDL_FRect{ .x = starting_x, .y = starting_y, .w = @floatFromInt(config.width.right), .h = length };
                    if (!c.SDL_RenderFillRect(renderer, &line)) {
                        std.log.err("SDL_RenderFillRect failed: {s}", .{c.SDL_GetError()});
                    }
                }
                if (config.width.top > 0) {
                    const starting_x = rect.x + clamped_radii.top_left;
                    const length = rect.w - clamped_radii.top_left - clamped_radii.top_right;
                    const line = c.SDL_FRect{ .x = starting_x, .y = rect.y, .w = length, .h = @floatFromInt(config.width.top) };
                    if (!c.SDL_RenderFillRect(renderer, &line)) {
                        std.log.err("SDL_RenderFillRect failed: {s}", .{c.SDL_GetError()});
                    }
                }
                if (config.width.bottom > 0) {
                    const starting_x = rect.x + clamped_radii.bottom_left;
                    const starting_y = rect.y + rect.h - @as(f32, @floatFromInt(config.width.bottom));
                    const length = rect.w - clamped_radii.bottom_left - clamped_radii.bottom_right;
                    const line = c.SDL_FRect{ .x = starting_x, .y = starting_y, .w = length, .h = @floatFromInt(config.width.bottom) };
                    setRenderDrawColor(renderer, config.color);
                    if (!c.SDL_RenderFillRect(renderer, &line)) {
                        std.log.err("SDL_RenderFillRect failed: {s}", .{c.SDL_GetError()});
                    }
                }

                if (config.corner_radius.top_left > 0) {
                    try renderArc(renderer, .{ .x = rect.x + clamped_radii.top_left - 1, .y = rect.y + clamped_radii.top_left }, clamped_radii.top_left, 180.0, 270.0, @floatFromInt(config.width.top), config.color, allocator);
                }
                if (config.corner_radius.top_right > 0) {
                    try renderArc(renderer, .{ .x = rect.x + rect.w - clamped_radii.top_right - 1, .y = rect.y + clamped_radii.top_right }, clamped_radii.top_right, 270.0, 360.0, @floatFromInt(config.width.top), config.color, allocator);
                }
                if (config.corner_radius.bottom_left > 0) {
                    try renderArc(renderer, .{ .x = rect.x + clamped_radii.bottom_left - 1, .y = rect.y + rect.h - clamped_radii.bottom_left - 1 }, clamped_radii.bottom_left, 90.0, 180.0, @floatFromInt(config.width.bottom), config.color, allocator);
                }
                if (config.corner_radius.bottom_right > 0) {
                    try renderArc(renderer, .{ .x = rect.x + rect.w - clamped_radii.bottom_right - 1, .y = rect.y + rect.h - clamped_radii.bottom_right - 1 }, clamped_radii.bottom_right, 0.0, 90.0, @floatFromInt(config.width.bottom), config.color, allocator);
                }
            },
            .scissor_start => {
                const clip = c.SDL_Rect{
                    .x = @intFromFloat(@round(bb.x)),
                    .y = @intFromFloat(@round(bb.y)),
                    .w = @intFromFloat(@round(bb.width)),
                    .h = @intFromFloat(@round(bb.height)),
                };
                if (!c.SDL_SetRenderClipRect(renderer, &clip)) {
                    std.log.err("SDL_SetRenderClipRect failed: {s}", .{c.SDL_GetError()});
                }
            },
            .scissor_end => {
                if (!c.SDL_SetRenderClipRect(renderer, null)) {
                    std.log.err("SDL_SetRenderClipRect(null) failed: {s}", .{c.SDL_GetError()});
                }
            },
            .image => {
                const texture: ?*c.SDL_Texture = @ptrCast(@alignCast(rcmd.render_data.image.image_data));
                if (!c.SDL_RenderTexture(renderer, texture, null, &rect)) {
                    std.log.err("SDL_RenderTexture failed: {s}", .{c.SDL_GetError()});
                }
            },
            else => {
                std.log.err("Unknown render command type: {}", .{rcmd.command_type});
            },
        }
    }
}
