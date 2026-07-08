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

fn renderFillRoundedRect(renderer: ?*c.SDL_Renderer, rect: c.SDL_FRect, cornerRadius: f32, clay_color: clay.Color, allocator: std.mem.Allocator) !void {
    const color = c.SDL_FColor{
        .r = clay_color[0] / 255.0,
        .g = clay_color[1] / 255.0,
        .b = clay_color[2] / 255.0,
        .a = clay_color[3] / 255.0,
    };

    const minRadius = @min(rect.w, rect.h) / 2.0;
    const clampedRadius = @min(cornerRadius, minRadius);

    const numCircleSegments = @max(@as(c_int, 16), @as(c_int, @intFromFloat(clampedRadius * 0.5)));

    const totalVertices = 4 + (4 * (numCircleSegments * 2)) + 8;
    const totalIndices = 6 + (4 * (numCircleSegments * 3)) + 24;

    const vertices = try allocator.alloc(c.SDL_Vertex, @intCast(totalVertices));
    defer allocator.free(vertices);

    const indices = try allocator.alloc(c_int, @intCast(totalIndices));
    defer allocator.free(indices);

    var vertexCount: usize = 0;
    var indexCount: usize = 0;

    // Define center rectangle
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + clampedRadius, .y = rect.y + clampedRadius }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    vertexCount += 1;
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + rect.w - clampedRadius, .y = rect.y + clampedRadius }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } };
    vertexCount += 1;
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + rect.w - clampedRadius, .y = rect.y + rect.h - clampedRadius }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } };
    vertexCount += 1;
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + clampedRadius, .y = rect.y + rect.h - clampedRadius }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } };
    vertexCount += 1;

    indices[indexCount] = 0;
    indexCount += 1;
    indices[indexCount] = 1;
    indexCount += 1;
    indices[indexCount] = 3;
    indexCount += 1;
    indices[indexCount] = 1;
    indexCount += 1;
    indices[indexCount] = 2;
    indexCount += 1;
    indices[indexCount] = 3;
    indexCount += 1;

    // Define rounded corners as triangle fans
    const step = (std.math.pi / 2.0) / @as(f32, @floatFromInt(numCircleSegments));
    var i: i32 = 0;
    while (i < numCircleSegments) : (i += 1) {
        const angle1 = @as(f32, @floatFromInt(i)) * step;
        const angle2 = @as(f32, @floatFromInt(i + 1)) * step;

        var j: usize = 0;
        while (j < 4) : (j += 1) {
            var cx: f32 = 0;
            var cy: f32 = 0;
            var signX: f32 = 0;
            var signY: f32 = 0;

            switch (j) {
                0 => {
                    cx = rect.x + clampedRadius;
                    cy = rect.y + clampedRadius;
                    signX = -1;
                    signY = -1;
                },
                1 => {
                    cx = rect.x + rect.w - clampedRadius;
                    cy = rect.y + clampedRadius;
                    signX = 1;
                    signY = -1;
                },
                2 => {
                    cx = rect.x + rect.w - clampedRadius;
                    cy = rect.y + rect.h - clampedRadius;
                    signX = 1;
                    signY = 1;
                },
                3 => {
                    cx = rect.x + clampedRadius;
                    cy = rect.y + rect.h - clampedRadius;
                    signX = -1;
                    signY = 1;
                },
                else => unreachable,
            }

            vertices[vertexCount] = .{
                .position = .{
                    .x = cx + @cos(angle1) * clampedRadius * signX,
                    .y = cy + @sin(angle1) * clampedRadius * signY,
                },
                .color = color,
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            vertexCount += 1;

            vertices[vertexCount] = .{
                .position = .{
                    .x = cx + @cos(angle2) * clampedRadius * signX,
                    .y = cy + @sin(angle2) * clampedRadius * signY,
                },
                .color = color,
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            vertexCount += 1;

            indices[indexCount] = @intCast(j);
            indexCount += 1;
            indices[indexCount] = @intCast(vertexCount - 2);
            indexCount += 1;
            indices[indexCount] = @intCast(vertexCount - 1);
            indexCount += 1;
        }
    }

    // Top edge
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + clampedRadius, .y = rect.y }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    vertexCount += 1;
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + rect.w - clampedRadius, .y = rect.y }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } };
    vertexCount += 1;

    indices[indexCount] = 0;
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 2);
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 1);
    indexCount += 1;
    indices[indexCount] = 1;
    indexCount += 1;
    indices[indexCount] = 0;
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 1);
    indexCount += 1;

    // Right edge
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + clampedRadius }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } };
    vertexCount += 1;
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + rect.h - clampedRadius }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } };
    vertexCount += 1;

    indices[indexCount] = 1;
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 2);
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 1);
    indexCount += 1;
    indices[indexCount] = 2;
    indexCount += 1;
    indices[indexCount] = 1;
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 1);
    indexCount += 1;

    // Bottom edge
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + rect.w - clampedRadius, .y = rect.y + rect.h }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } };
    vertexCount += 1;
    vertices[vertexCount] = .{ .position = .{ .x = rect.x + clampedRadius, .y = rect.y + rect.h }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } };
    vertexCount += 1;

    indices[indexCount] = 2;
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 2);
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 1);
    indexCount += 1;
    indices[indexCount] = 3;
    indexCount += 1;
    indices[indexCount] = 2;
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 1);
    indexCount += 1;

    // Left edge
    vertices[vertexCount] = .{ .position = .{ .x = rect.x, .y = rect.y + rect.h - clampedRadius }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } };
    vertexCount += 1;
    vertices[vertexCount] = .{ .position = .{ .x = rect.x, .y = rect.y + clampedRadius }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    vertexCount += 1;

    indices[indexCount] = 3;
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 2);
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 1);
    indexCount += 1;
    indices[indexCount] = 0;
    indexCount += 1;
    indices[indexCount] = 3;
    indexCount += 1;
    indices[indexCount] = @intCast(vertexCount - 1);
    indexCount += 1;

    if (!c.SDL_RenderGeometry(renderer, null, &vertices[0], @intCast(vertexCount), &indices[0], @intCast(indexCount))) {
        std.log.err("SDL_RenderGeometry failed: {s}", .{c.SDL_GetError()});
    }
}

fn renderArc(renderer: ?*c.SDL_Renderer, center: c.SDL_FPoint, radius: f32, startAngle: f32, endAngle: f32, thickness: f32, clay_color: clay.Color, allocator: std.mem.Allocator) !void {
    setRenderDrawColor(renderer, clay_color);

    const radStart = startAngle * (std.math.pi / 180.0);
    const radEnd = endAngle * (std.math.pi / 180.0);

    const numCircleSegments = @max(@as(c_int, 16), @as(c_int, @intFromFloat(radius * 1.5)));

    const angleStep = (radEnd - radStart) / @as(f32, @floatFromInt(numCircleSegments));
    const thicknessStep: f32 = 0.4;

    const points = try allocator.alloc(c.SDL_FPoint, @intCast(numCircleSegments + 1));
    defer allocator.free(points);

    var t = thicknessStep;
    while (t < thickness - thicknessStep) : (t += thicknessStep) {
        const clampedRadius = @max(radius - t, 1.0);

        var i: i32 = 0;
        while (i <= numCircleSegments) : (i += 1) {
            const angle = radStart + @as(f32, @floatFromInt(i)) * angleStep;
            points[@intCast(i)] = .{
                .x = @round(center.x + @cos(angle) * clampedRadius),
                .y = @round(center.y + @sin(angle) * clampedRadius),
            };
        }
        if (!c.SDL_RenderLines(renderer, &points[0], @intCast(numCircleSegments + 1))) {
            std.log.err("SDL_RenderLines failed: {s}", .{c.SDL_GetError()});
        }
    }
}

pub fn renderClayCommands(renderer: ?*c.SDL_Renderer, textEngine: ?*c.TTF_TextEngine, fonts: [*]?*c.TTF_Font, rcommands: clay.ClayArray(clay.RenderCommand), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    const len = @as(usize, @intCast(rcommands.length));
    while (i < len) : (i += 1) {
        const rcmd = rcommands.internal_array[i];
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
                const font = fonts[config.font_id];

                // Copy string contents to stack/heap to null terminate
                var stack_buf: [1024]u8 = undefined;
                const str_len = @as(usize, @intCast(config.string_contents.length));
                const buffer = if (str_len < stack_buf.len)
                    stack_buf[0..str_len]
                else
                    try allocator.alloc(u8, str_len);
                defer if (str_len >= stack_buf.len) allocator.free(buffer);
                @memcpy(buffer, config.string_contents.chars[0..str_len]);

                const text_obj = c.TTF_CreateText(textEngine, font, buffer.ptr, str_len) orelse continue;
                defer c.TTF_DestroyText(text_obj);

                setTextColor(text_obj, config.text_color);
                if (!c.TTF_DrawRendererText(text_obj, rect.x, rect.y)) {
                    std.log.err("TTF_DrawRendererText failed: {s}", .{c.SDL_GetError()});
                }
            },
            .border => {
                const config = rcmd.render_data.border;
                const minRadius = @min(rect.w, rect.h) / 2.0;
                const clampedRadii = struct {
                    top_left: f32,
                    top_right: f32,
                    bottom_left: f32,
                    bottom_right: f32,
                }{
                    .top_left = @min(config.corner_radius.top_left, minRadius),
                    .top_right = @min(config.corner_radius.top_right, minRadius),
                    .bottom_left = @min(config.corner_radius.bottom_left, minRadius),
                    .bottom_right = @min(config.corner_radius.bottom_right, minRadius),
                };

                setRenderDrawColor(renderer, config.color);

                if (config.width.left > 0) {
                    const starting_y = rect.y + clampedRadii.top_left;
                    const length = rect.h - clampedRadii.top_left - clampedRadii.bottom_left;
                    const line = c.SDL_FRect{ .x = rect.x, .y = starting_y, .w = @floatFromInt(config.width.left), .h = length };
                    if (!c.SDL_RenderFillRect(renderer, &line)) {
                        std.log.err("SDL_RenderFillRect failed: {s}", .{c.SDL_GetError()});
                    }
                }
                if (config.width.right > 0) {
                    const starting_x = rect.x + rect.w - @as(f32, @floatFromInt(config.width.right));
                    const starting_y = rect.y + clampedRadii.top_right;
                    const length = rect.h - clampedRadii.top_right - clampedRadii.bottom_right;
                    const line = c.SDL_FRect{ .x = starting_x, .y = starting_y, .w = @floatFromInt(config.width.right), .h = length };
                    if (!c.SDL_RenderFillRect(renderer, &line)) {
                        std.log.err("SDL_RenderFillRect failed: {s}", .{c.SDL_GetError()});
                    }
                }
                if (config.width.top > 0) {
                    const starting_x = rect.x + clampedRadii.top_left;
                    const length = rect.w - clampedRadii.top_left - clampedRadii.top_right;
                    const line = c.SDL_FRect{ .x = starting_x, .y = rect.y, .w = length, .h = @floatFromInt(config.width.top) };
                    if (!c.SDL_RenderFillRect(renderer, &line)) {
                        std.log.err("SDL_RenderFillRect failed: {s}", .{c.SDL_GetError()});
                    }
                }
                if (config.width.bottom > 0) {
                    const starting_x = rect.x + clampedRadii.bottom_left;
                    const starting_y = rect.y + rect.h - @as(f32, @floatFromInt(config.width.bottom));
                    const length = rect.w - clampedRadii.bottom_left - clampedRadii.bottom_right;
                    const line = c.SDL_FRect{ .x = starting_x, .y = starting_y, .w = length, .h = @floatFromInt(config.width.bottom) };
                    setRenderDrawColor(renderer, config.color);
                    if (!c.SDL_RenderFillRect(renderer, &line)) {
                        std.log.err("SDL_RenderFillRect failed: {s}", .{c.SDL_GetError()});
                    }
                }

                if (config.corner_radius.top_left > 0) {
                    try renderArc(renderer, .{ .x = rect.x + clampedRadii.top_left - 1, .y = rect.y + clampedRadii.top_left }, clampedRadii.top_left, 180.0, 270.0, @floatFromInt(config.width.top), config.color, allocator);
                }
                if (config.corner_radius.top_right > 0) {
                    try renderArc(renderer, .{ .x = rect.x + rect.w - clampedRadii.top_right - 1, .y = rect.y + clampedRadii.top_right }, clampedRadii.top_right, 270.0, 360.0, @floatFromInt(config.width.top), config.color, allocator);
                }
                if (config.corner_radius.bottom_left > 0) {
                    try renderArc(renderer, .{ .x = rect.x + clampedRadii.bottom_left - 1, .y = rect.y + rect.h - clampedRadii.bottom_left - 1 }, clampedRadii.bottom_left, 90.0, 180.0, @floatFromInt(config.width.bottom), config.color, allocator);
                }
                if (config.corner_radius.bottom_right > 0) {
                    try renderArc(renderer, .{ .x = rect.x + rect.w - clampedRadii.bottom_right - 1, .y = rect.y + rect.h - clampedRadii.bottom_right - 1 }, clampedRadii.bottom_right, 0.0, 90.0, @floatFromInt(config.width.bottom), config.color, allocator);
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
