const std = @import("std");
const clay = @import("zclay");
const sdl = @import("sdl");
const app_state = @import("../app/state.zig");

pub const ZoomPan = struct {
    zoom_factor: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    rotation_angle: f32 = 0.0,
};

const geometry = @import("geometry.zig");
pub const Vertex = geometry.Vertex;
pub const packRgba = geometry.packRgba;
pub const packRgbaClay = geometry.packRgbaClay;
pub const packRgbaF = geometry.packRgbaF;

const Uniforms = extern struct {
    brightness: f32,
    contrast: f32,
    is_text_or_color: i32,
    scale_mode: i32,
};

const BatchItem = struct {
    vertex_start: u32,
    vertex_count: u32,
    texture: sdl.gpu.Texture,
    is_image: bool,
    scissor: ?sdl.Rect,
};

fn scissorEqual(a: ?sdl.Rect, b: ?sdl.Rect) bool {
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
    texture: sdl.gpu.Texture,
    is_image: bool,
    scissor: ?sdl.Rect,
) !void {
    if (batches.items.len > 0) {
        var last = &batches.items[batches.items.len - 1];
        if (last.texture.eql(texture) and last.is_image == is_image and scissorEqual(last.scissor, scissor)) {
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
    cmd_buf: sdl.gpu.CommandBuffer,
    swap_tex: sdl.gpu.Texture,
    fonts: []const ?sdl.Font,
    r_commands: []const clay.RenderCommand,
    allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    win_w: i32,
    win_h: i32,
) !void {
    const f_win_w = @as(f32, @floatFromInt(win_w));
    const f_win_h = @as(f32, @floatFromInt(win_h));

    var vertices = std.ArrayList(Vertex).empty;
    defer vertices.deinit(allocator);

    var batches = std.ArrayList(BatchItem).empty;
    defer batches.deinit(allocator);

    var current_scissor: ?sdl.Rect = null;

    for (r_commands) |rcmd| {
        const bb = rcmd.bounding_box;
        const rect = sdl.FRect{
            .x = @round(bb.x),
            .y = @round(bb.y),
            .w = @round(bb.width),
            .h = @round(bb.height),
        };

        switch (rcmd.command_type) {
            .scissor_start => {
                current_scissor = sdl.Rect{
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
                    try geometry.renderFillRoundedRect(&vertices, allocator, rect, config.corner_radius.top_left, config.background_color, f_win_w, f_win_h);
                } else {
                    try geometry.appendRectQuad(&vertices, allocator, rect, config.background_color, f_win_w, f_win_h);
                }

                const count = @as(u32, @intCast(vertices.items.len)) - start;
                if (count > 0) {
                    try addBatch(&batches, allocator, start, count, state.white_texture.?, false, current_scissor);
                }
            },
            .text => {
                const text_data = rcmd.render_data.text;
                if (text_data.font_id >= fonts.len) continue;
                const font = fonts[text_data.font_id] orelse continue;

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

                var cached_tex: ?sdl.gpu.Texture = null;
                var w_f: f32 = 0.0;
                var h_f: f32 = 0.0;

                if (state.text_cache.getEntry(key)) |entry| {
                    entry.value_ptr.last_used_frame = state.gpu_frame_index;
                    cached_tex = entry.value_ptr.texture;
                    w_f = entry.value_ptr.w;
                    h_f = entry.value_ptr.h;
                } else {
                    _ = font.setFontSize(@as(f32, @floatFromInt(text_data.font_size)));

                    const surf = font.renderTextBlended(text_slice, .{
                        .r = @intFromFloat(text_data.text_color[0]),
                        .g = @intFromFloat(text_data.text_color[1]),
                        .b = @intFromFloat(text_data.text_color[2]),
                        .a = @intFromFloat(text_data.text_color[3]),
                    }) catch continue;
                    defer surf.destroy();

                    const converted = surf.convert(sdl.PixelFormat.rgba32) orelse continue;
                    defer converted.destroy();

                    var leading_spaces: usize = 0;
                    while (leading_spaces < text_slice.len and text_slice[leading_spaces] == ' ') : (leading_spaces += 1) {}

                    var leading_space_w: usize = 0;
                    if (leading_spaces > 0 and leading_spaces < text_slice.len) {
                        if (font.getStringSize(text_slice[0..leading_spaces])) |s| {
                            leading_space_w = @intCast(s.w);
                        }
                    }

                    const surf_w: usize = @intCast(converted.w());
                    const surf_h: usize = @intCast(converted.h());
                    const target_w: usize = @max(surf_w + leading_space_w, @as(usize, @intFromFloat(@round(rcmd.bounding_box.width))));
                    const dst_start_byte = @min(leading_space_w * 4, if (target_w > surf_w) (target_w - surf_w) * 4 else 0);

                    const dev = state.gpu_device.?;

                    const tex_info = sdl.gpu.TextureCreateInfo{
                        .type = .type_2d,
                        .format = .rgba8_unorm,
                        .usage = sdl.gpu.TextureUsage.sampler,
                        .width = @intCast(target_w),
                        .height = @intCast(surf_h),
                        .layer_count_or_depth = 1,
                        .num_levels = 1,
                        .sample_count = .count_1,
                        .props = 0,
                    };
                    const tex = dev.createTexture(&tex_info) orelse continue;

                    const size = target_w * surf_h * 4;
                    const transfer_buf = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
                        .usage = .upload,
                        .size = @intCast(size),
                        .props = 0,
                    }) orelse {
                        dev.releaseTexture(tex);
                        continue;
                    };
                    temp_buffers.append(allocator, transfer_buf) catch {
                        dev.releaseTransferBuffer(transfer_buf);
                        dev.releaseTexture(tex);
                        continue;
                    };

                    const mapped = dev.mapTransferBuffer(transfer_buf, false) orelse {
                        dev.releaseTexture(tex);
                        continue;
                    };
                    const src_row_bytes: usize = surf_w * 4;
                    const dst_row_bytes: usize = target_w * 4;
                    const pitch: usize = @intCast(converted.pitch());

                    @memset(mapped[0..size], 0);

                    var row_y: usize = 0;
                    while (row_y < surf_h) : (row_y += 1) {
                        const src_row = converted.pixels()[row_y * pitch .. row_y * pitch + src_row_bytes];
                        const dst_row = mapped[row_y * dst_row_bytes + dst_start_byte .. row_y * dst_row_bytes + dst_start_byte + src_row_bytes];
                        @memcpy(dst_row, src_row);
                    }
                    dev.unmapTransferBuffer(transfer_buf);

                    const cmd = cmd_buf;
                    const copy_pass = cmd.beginCopyPass() orelse {
                        dev.releaseTexture(tex);
                        continue;
                    };
                    copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
                        .transfer_buffer = transfer_buf,
                        .offset = 0,
                        .pixels_per_row = @intCast(target_w),
                        .rows_per_layer = @intCast(surf_h),
                    }, &sdl.gpu.TextureRegion{
                        .texture = tex,
                        .w = @intCast(target_w),
                        .h = @intCast(surf_h),
                        .d = 1,
                    }, false);
                    copy_pass.end();

                    w_f = @floatFromInt(target_w);
                    h_f = @floatFromInt(surf_h);
                    cached_tex = tex;

                    state.text_cache.put(state.allocator, key, .{
                        .texture = tex,
                        .w = w_f,
                        .h = h_f,
                        .last_used_frame = state.gpu_frame_index,
                    }) catch {
                        dev.releaseTexture(tex);
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

                // Append 6 vertices for 2 triangles using white vertex color (packed RGBA8)
                const white_color = packRgba(255, 255, 255, 255);
                try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .color = white_color });
                try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .color = white_color });
                try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .color = white_color });
                try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .color = white_color });
                try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 1.0, .color = white_color });
                try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .color = white_color });

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
                        try geometry.drawDashedLineV(&vertices, allocator, rect.x, starting_y, starting_y + length, @floatFromInt(config.width.left), config.color, 8.0, 6.0, f_win_w, f_win_h);
                    } else {
                        const line = sdl.FRect{ .x = rect.x, .y = starting_y, .w = @floatFromInt(config.width.left), .h = length };
                        try geometry.appendRectQuad(&vertices, allocator, line, config.color, f_win_w, f_win_h);
                    }
                }
                if (config.width.right > 0) {
                    const starting_x = rect.x + rect.w - @as(f32, @floatFromInt(config.width.right));
                    const starting_y = rect.y + clamped_radii.top_right;
                    const length = rect.h - clamped_radii.top_right - clamped_radii.bottom_right;
                    if (is_dashed) {
                        try geometry.drawDashedLineV(&vertices, allocator, starting_x, starting_y, starting_y + length, @floatFromInt(config.width.right), config.color, 8.0, 6.0, f_win_w, f_win_h);
                    } else {
                        const line = sdl.FRect{ .x = starting_x, .y = starting_y, .w = @floatFromInt(config.width.right), .h = length };
                        try geometry.appendRectQuad(&vertices, allocator, line, config.color, f_win_w, f_win_h);
                    }
                }
                if (config.width.top > 0) {
                    const starting_x = rect.x + clamped_radii.top_left;
                    const length = rect.w - clamped_radii.top_left - clamped_radii.top_right;
                    if (is_dashed) {
                        try geometry.drawDashedLineH(&vertices, allocator, starting_x, starting_x + length, rect.y, @floatFromInt(config.width.top), config.color, 8.0, 6.0, f_win_w, f_win_h);
                    } else {
                        const line = sdl.FRect{ .x = starting_x, .y = rect.y, .w = length, .h = @floatFromInt(config.width.top) };
                        try geometry.appendRectQuad(&vertices, allocator, line, config.color, f_win_w, f_win_h);
                    }
                }
                if (config.width.bottom > 0) {
                    const starting_x = rect.x + clamped_radii.bottom_left;
                    const starting_y = rect.y + rect.h - @as(f32, @floatFromInt(config.width.bottom));
                    const length = rect.w - clamped_radii.bottom_left - clamped_radii.bottom_right;
                    if (is_dashed) {
                        try geometry.drawDashedLineH(&vertices, allocator, starting_x, starting_x + length, starting_y, @floatFromInt(config.width.bottom), config.color, 8.0, 6.0, f_win_w, f_win_h);
                    } else {
                        const line = sdl.FRect{ .x = starting_x, .y = starting_y, .w = length, .h = @floatFromInt(config.width.bottom) };
                        try geometry.appendRectQuad(&vertices, allocator, line, config.color, f_win_w, f_win_h);
                    }
                }

                if (config.corner_radius.top_left > 0) {
                    try geometry.renderArc(&vertices, .{ .x = rect.x + clamped_radii.top_left, .y = rect.y + clamped_radii.top_left }, clamped_radii.top_left, 180.0, 270.0, @floatFromInt(config.width.top), r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
                }
                if (config.corner_radius.top_right > 0) {
                    try geometry.renderArc(&vertices, .{ .x = rect.x + rect.w - clamped_radii.top_right, .y = rect.y + clamped_radii.top_right }, clamped_radii.top_right, 270.0, 360.0, @floatFromInt(config.width.top), r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
                }
                if (config.corner_radius.bottom_left > 0) {
                    try geometry.renderArc(&vertices, .{ .x = rect.x + clamped_radii.bottom_left, .y = rect.y + rect.h - clamped_radii.bottom_left }, clamped_radii.bottom_left, 90.0, 180.0, @floatFromInt(config.width.bottom), r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
                }
                if (config.corner_radius.bottom_right > 0) {
                    try geometry.renderArc(&vertices, .{ .x = rect.x + rect.w - clamped_radii.bottom_right, .y = rect.y + rect.h - clamped_radii.bottom_right }, clamped_radii.bottom_right, 0.0, 90.0, @floatFromInt(config.width.bottom), r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
                }

                const count = @as(u32, @intCast(vertices.items.len)) - start_batch;
                if (count > 0) {
                    try addBatch(&batches, allocator, start_batch, count, state.white_texture.?, false, current_scissor);
                }
            },
            .image => {
                const texture: ?sdl.gpu.Texture = if (rcmd.render_data.image.image_data) |ptr| sdl.gpu.Texture{ .ptr = @ptrCast(@alignCast(ptr)) } else null;
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
                    const white_color = packRgba(255, 255, 255, 255);
                    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 0.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x4, .y = ndc_y4, .u = 0.0, .v = 1.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 0.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x3, .y = ndc_y3, .u = 1.0, .v = 1.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x4, .y = ndc_y4, .u = 0.0, .v = 1.0, .color = white_color });

                    try addBatch(&batches, allocator, start, 6, tex, true, current_scissor);
                }
            },
            else => {
                std.log.warn("Skipping unhandled render command type: {}", .{rcmd.command_type});
            },
        }
    }

    // Persistent Vertex Buffer Double-Buffering
    var vert_buf: ?sdl.gpu.Buffer = null;
    const needed_size = vertices.items.len * @sizeOf(Vertex);
    const frame_idx = state.gpu_frame_index % 2;

    const dev = state.gpu_device.?;

    if (needed_size > 0) {
        if (state.gpu_vertex_buffers[frame_idx] == null or state.gpu_buffer_capacities[frame_idx] < needed_size) {
            if (state.gpu_vertex_buffers[frame_idx]) |vb| {
                dev.releaseBuffer(vb);
                state.gpu_vertex_buffers[frame_idx] = null;
            }
            if (state.gpu_transfer_buffers[frame_idx]) |tb| {
                dev.releaseTransferBuffer(tb);
                state.gpu_transfer_buffers[frame_idx] = null;
            }

            const new_capacity = std.mem.alignForward(usize, needed_size * 2, 4096);

            state.gpu_vertex_buffers[frame_idx] = dev.createBuffer(&sdl.gpu.BufferCreateInfo{
                .usage = sdl.gpu.BufferUsage.vertex,
                .size = @intCast(new_capacity),
                .props = 0,
            }) orelse return error.GPUBufferCreationFailed;

            state.gpu_transfer_buffers[frame_idx] = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
                .usage = .upload,
                .size = @intCast(new_capacity),
                .props = 0,
            }) orelse return error.GPUTransferBufferCreationFailed;

            state.gpu_buffer_capacities[frame_idx] = new_capacity;
        }

        const vb = state.gpu_vertex_buffers[frame_idx].?;
        const tb = state.gpu_transfer_buffers[frame_idx].?;

        const mapped: [*]Vertex = @ptrCast(@alignCast(dev.mapTransferBuffer(tb, false) orelse return error.GPUMapFailed));
        @memcpy(mapped[0..vertices.items.len], vertices.items);
        dev.unmapTransferBuffer(tb);

        const cmd = cmd_buf;
        const copy_pass = cmd.beginCopyPass() orelse return error.GPUCopyPassFailed;
        copy_pass.uploadToBuffer(&sdl.gpu.TransferBufferLocation{
            .transfer_buffer = tb,
            .offset = 0,
        }, &sdl.gpu.BufferRegion{
            .buffer = vb,
            .offset = 0,
            .size = @intCast(needed_size),
        }, false);
        copy_pass.end();

        vert_buf = vb;
    }

    const color_target = sdl.gpu.ColorTargetAttachment{
        .texture = swap_tex,
        .clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        .load_op = .clear,
        .store_op = .store,
        .cycle = false,
    };

    const cmd = cmd_buf;
    const render_pass = cmd.beginRenderPass(&color_target) orelse return;
    defer render_pass.end();

    render_pass.bindPipeline(state.gpu_pipeline.?);

    if (vert_buf) |vb| {
        const vert_binding = sdl.gpu.BufferBinding{ .buffer = vb, .offset = 0 };
        render_pass.bindVertexBuffers(0, &[_]sdl.gpu.BufferBinding{vert_binding});

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
                    render_pass.setScissor(&safe_sc);
                } else {
                    const empty_sc = sdl.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
                    render_pass.setScissor(&empty_sc);
                }
            } else {
                const full_sc = sdl.Rect{ .x = 0, .y = 0, .w = win_w, .h = win_h };
                render_pass.setScissor(&full_sc);
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
            cmd.pushFragmentUniform(0, std.mem.asBytes(&ubo));

            render_pass.bindFragmentSamplers(0, &[_]sdl.gpu.TextureSamplerBinding{.{ .texture = batch.texture, .sampler = state.gpu_sampler.? }});
            render_pass.drawPrimitives(batch.vertex_count, 1, batch.vertex_start, 0);
        }
    }

    // 4. Cache eviction for text textures (unused for >120 frames)
    state.text_cache.evictUnused(allocator, dev, state.gpu_frame_index, 120);

    state.gpu_frame_index += 1;
}
