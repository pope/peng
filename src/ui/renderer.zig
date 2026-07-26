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

const CachedText = struct {
    texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
};

fn appendRectangleCommand(
    vertices: *std.ArrayList(Vertex),
    batches: *std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,
    rect: sdl.FRect,
    config: clay.RectangleRenderData,
    scale_x: f32,
    f_win_w: f32,
    f_win_h: f32,
    white_texture: sdl.gpu.Texture,
    scissor: ?sdl.Rect,
) !void {
    const start = @as(u32, @intCast(vertices.items.len));

    const corner_radius = config.corner_radius.top_left * scale_x;
    if (corner_radius > 0) {
        try geometry.renderFillRoundedRect(vertices, allocator, rect, corner_radius, config.background_color, f_win_w, f_win_h);
    } else {
        try geometry.appendRectQuad(vertices, allocator, rect, config.background_color, f_win_w, f_win_h);
    }

    const count = @as(u32, @intCast(vertices.items.len)) - start;
    if (count > 0) {
        try addBatch(batches, allocator, start, count, white_texture, false, scissor);
    }
}

fn appendBorderCommand(
    vertices: *std.ArrayList(Vertex),
    batches: *std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,
    rect: sdl.FRect,
    config: clay.BorderRenderData,
    user_data: ?*anyopaque,
    scale_x: f32,
    f_win_w: f32,
    f_win_h: f32,
    white_texture: sdl.gpu.Texture,
    scissor: ?sdl.Rect,
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
        .bottom_left = @min(config.corner_radius.bottom_left * scale_x, min_radius),
        .bottom_right = @min(config.corner_radius.bottom_right * scale_x, min_radius),
    };

    const tag = if (user_data) |ptr| app_state.ElementTag.fromInt(@intFromPtr(ptr)) else .none;
    const is_dashed = (tag == .drop_zone_box);

    const r = config.color[0] / 255.0;
    const g = config.color[1] / 255.0;
    const b = config.color[2] / 255.0;
    const a = config.color[3] / 255.0;

    const start_batch = @as(u32, @intCast(vertices.items.len));

    const border_left = @as(f32, @floatFromInt(config.width.left)) * scale_x;
    const border_right = @as(f32, @floatFromInt(config.width.right)) * scale_x;
    const border_top = @as(f32, @floatFromInt(config.width.top)) * scale_x;
    const border_bottom = @as(f32, @floatFromInt(config.width.bottom)) * scale_x;

    if (border_left > 0) {
        const starting_y = rect.y + clamped_radii.top_left;
        const length = rect.h - clamped_radii.top_left - clamped_radii.bottom_left;
        if (is_dashed) {
            try geometry.drawDashedLineV(vertices, allocator, rect.x, starting_y, starting_y + length, border_left, config.color, 8.0 * scale_x, 6.0 * scale_x, f_win_w, f_win_h);
        } else {
            const line = sdl.FRect{ .x = rect.x, .y = starting_y, .w = border_left, .h = length };
            try geometry.appendRectQuad(vertices, allocator, line, config.color, f_win_w, f_win_h);
        }
    }
    if (border_right > 0) {
        const starting_x = rect.x + rect.w - border_right;
        const starting_y = rect.y + clamped_radii.top_right;
        const length = rect.h - clamped_radii.top_right - clamped_radii.bottom_right;
        if (is_dashed) {
            try geometry.drawDashedLineV(vertices, allocator, starting_x, starting_y, starting_y + length, border_right, config.color, 8.0 * scale_x, 6.0 * scale_x, f_win_w, f_win_h);
        } else {
            const line = sdl.FRect{ .x = starting_x, .y = starting_y, .w = border_right, .h = length };
            try geometry.appendRectQuad(vertices, allocator, line, config.color, f_win_w, f_win_h);
        }
    }
    if (border_top > 0) {
        const starting_x = rect.x + clamped_radii.top_left;
        const length = rect.w - clamped_radii.top_left - clamped_radii.top_right;
        if (is_dashed) {
            try geometry.drawDashedLineH(vertices, allocator, starting_x, starting_x + length, rect.y, border_top, config.color, 8.0 * scale_x, 6.0 * scale_x, f_win_w, f_win_h);
        } else {
            const line = sdl.FRect{ .x = starting_x, .y = rect.y, .w = length, .h = border_top };
            try geometry.appendRectQuad(vertices, allocator, line, config.color, f_win_w, f_win_h);
        }
    }
    if (border_bottom > 0) {
        const starting_x = rect.x + clamped_radii.bottom_left;
        const starting_y = rect.y + rect.h - border_bottom;
        const length = rect.w - clamped_radii.bottom_left - clamped_radii.bottom_right;
        if (is_dashed) {
            try geometry.drawDashedLineH(vertices, allocator, starting_x, starting_x + length, starting_y, border_bottom, config.color, 8.0 * scale_x, 6.0 * scale_x, f_win_w, f_win_h);
        } else {
            const line = sdl.FRect{ .x = starting_x, .y = starting_y, .w = length, .h = border_bottom };
            try geometry.appendRectQuad(vertices, allocator, line, config.color, f_win_w, f_win_h);
        }
    }

    if (clamped_radii.top_left > 0) {
        try geometry.renderArc(vertices, .{ .x = rect.x + clamped_radii.top_left, .y = rect.y + clamped_radii.top_left }, clamped_radii.top_left, 180.0, 270.0, border_top, r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
    }
    if (clamped_radii.top_right > 0) {
        try geometry.renderArc(vertices, .{ .x = rect.x + rect.w - clamped_radii.top_right, .y = rect.y + clamped_radii.top_right }, clamped_radii.top_right, 270.0, 360.0, border_top, r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
    }
    if (clamped_radii.bottom_left > 0) {
        try geometry.renderArc(vertices, .{ .x = rect.x + clamped_radii.bottom_left, .y = rect.y + rect.h - clamped_radii.bottom_left }, clamped_radii.bottom_left, 90.0, 180.0, border_bottom, r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
    }
    if (clamped_radii.bottom_right > 0) {
        try geometry.renderArc(vertices, .{ .x = rect.x + rect.w - clamped_radii.bottom_right, .y = rect.y + rect.h - clamped_radii.bottom_right }, clamped_radii.bottom_right, 0.0, 90.0, border_bottom, r, g, b, a, allocator, is_dashed, f_win_w, f_win_h);
    }

    const count = @as(u32, @intCast(vertices.items.len)) - start_batch;
    if (count > 0) {
        try addBatch(batches, allocator, start_batch, count, white_texture, false, scissor);
    }
}

fn appendImageCommand(
    vertices: *std.ArrayList(Vertex),
    batches: *std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,
    rect: sdl.FRect,
    image_data: ?*anyopaque,
    state: *const app_state.ViewerState,
    f_win_w: f32,
    f_win_h: f32,
    scissor: ?sdl.Rect,
) !void {
    const texture: ?sdl.gpu.Texture = if (image_data) |ptr| sdl.gpu.Texture{ .ptr = @ptrCast(@alignCast(ptr)) } else null;
    const tex = texture orelse return;

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

    try addBatch(batches, allocator, start, 6, tex, true, scissor);
}

fn getOrRenderCachedText(
    state: *app_state.ViewerState,
    cmd_buf: sdl.gpu.CommandBuffer,
    fonts: []const ?sdl.Font,
    text_data: clay.TextRenderData,
    scale_x: f32,
    allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    tb_offset: *usize,
) !?CachedText {
    if (text_data.font_id >= fonts.len) return null;
    const font = fonts[text_data.font_id] orelse return null;

    const len = @as(usize, @intCast(text_data.string_contents.length));
    if (len == 0) return null;
    var text_slice = text_data.string_contents.chars[0..len];
    if (std.mem.indexOfScalar(u8, text_slice, 0)) |null_idx| {
        text_slice = text_slice[0..null_idx];
    }
    if (text_slice.len == 0) return null;

    const target_font_size = @as(f32, @floatFromInt(text_data.font_size)) * scale_x;
    const target_font_size_u16 = @as(u16, @intFromFloat(@round(target_font_size)));

    // 1. Check/Lookup cache
    const color_u32 = @as(u32, @intFromFloat(text_data.text_color[0])) |
        (@as(u32, @intFromFloat(text_data.text_color[1])) << 8) |
        (@as(u32, @intFromFloat(text_data.text_color[2])) << 16) |
        (@as(u32, @intFromFloat(text_data.text_color[3])) << 24);

    const key = app_state.TextCacheKey{
        .font_id = text_data.font_id,
        .font_size = target_font_size_u16,
        .color = color_u32,
        .hash = std.hash.Wyhash.hash(0, text_slice),
    };

    if (state.text_cache.getEntry(key)) |entry| {
        entry.value_ptr.last_used_frame = state.gpu_frame_index;
        return CachedText{
            .texture = entry.value_ptr.texture,
            .w = entry.value_ptr.w,
            .h = entry.value_ptr.h,
        };
    }

    const dev = state.gpu_device.?;
    const frame_idx = state.gpu_frame_index % 2;

    _ = font.setFontSize(target_font_size);

    const surf = font.renderTextBlended(allocator, text_slice, .{
        .r = @intFromFloat(text_data.text_color[0]),
        .g = @intFromFloat(text_data.text_color[1]),
        .b = @intFromFloat(text_data.text_color[2]),
        .a = @intFromFloat(text_data.text_color[3]),
    }) catch |err| {
        std.log.warn("font.renderTextBlended failed for '{s}': {}", .{ text_slice, err });
        return null;
    };
    defer surf.destroy();

    const converted = surf.convert(sdl.PixelFormat.rgba32) orelse return null;
    defer converted.destroy();

    const surf_w: usize = @intCast(converted.w());
    const surf_h: usize = @intCast(converted.h());
    const target_w: usize = surf_w;
    const dst_start_byte: usize = 0;

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
    const tex = dev.createTexture(&tex_info) orelse return null;

    const size = target_w * surf_h * 4;
    const aligned_offset = std.mem.alignForward(usize, tb_offset.*, 512);
    const required_capacity = aligned_offset + size;

    if (state.gpu_transfer_buffers[frame_idx] == null or state.gpu_buffer_capacities[frame_idx] < required_capacity) {
        const new_tbcap = std.mem.alignForward(usize, @max(required_capacity * 2, 65536), 4096);
        if (state.gpu_transfer_buffers[frame_idx]) |old_tb| {
            temp_buffers.append(allocator, old_tb) catch |err| {
                std.log.err("Failed to append old transfer buffer to cleanup list: {}", .{err});
            };
        }
        state.gpu_transfer_buffers[frame_idx] = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = @intCast(new_tbcap),
            .props = 0,
        });
        if (state.gpu_transfer_buffers[frame_idx] == null) {
            state.gpu_buffer_capacities[frame_idx] = 0;
            dev.releaseTexture(tex);
            return null;
        }
        state.gpu_buffer_capacities[frame_idx] = new_tbcap;
    }

    const transfer_buf = state.gpu_transfer_buffers[frame_idx].?;
    const mapped_raw: [*]u8 = dev.mapTransferBuffer(transfer_buf, false) orelse {
        dev.releaseTexture(tex);
        return null;
    };
    const mapped = mapped_raw + aligned_offset;
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

    const copy_pass = cmd_buf.beginCopyPass() orelse {
        dev.releaseTexture(tex);
        return null;
    };
    copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = @intCast(aligned_offset),
        .pixels_per_row = @intCast(target_w),
        .rows_per_layer = @intCast(surf_h),
    }, &sdl.gpu.TextureRegion{
        .texture = tex,
        .w = @intCast(target_w),
        .h = @intCast(surf_h),
        .d = 1,
    }, false);
    copy_pass.end();

    tb_offset.* = aligned_offset + size;

    const w_f: f32 = @floatFromInt(target_w);
    const h_f: f32 = @floatFromInt(surf_h);

    state.text_cache.put(state.allocator, key, .{
        .texture = tex,
        .w = w_f,
        .h = h_f,
        .last_used_frame = state.gpu_frame_index,
    }) catch |err| {
        std.log.err("Failed to cache rendered text: {}", .{err});
        dev.releaseTexture(tex);
        return null;
    };

    return CachedText{
        .texture = tex,
        .w = w_f,
        .h = h_f,
    };
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
    scale_x: f32,
    scale_y: f32,
) !void {
    const start_render = sdl.timer.getTicksNs();
    const f_win_w = @as(f32, @floatFromInt(win_w));
    const f_win_h = @as(f32, @floatFromInt(win_h));

    var vertices = std.ArrayList(Vertex).empty;
    defer vertices.deinit(allocator);

    var batches = std.ArrayList(BatchItem).empty;
    defer batches.deinit(allocator);

    var current_scissor: ?sdl.Rect = null;

    const dev = state.gpu_device.?;
    const frame_idx = state.gpu_frame_index % 2;
    var tb_offset: usize = 0;

    var prev_text_bb: ?clay.BoundingBox = null;
    var prev_text_end_x: f32 = 0.0;

    for (r_commands) |rcmd| {
        const bb = rcmd.bounding_box;
        const rect = sdl.FRect{
            .x = @round(bb.x * scale_x),
            .y = @round(bb.y * scale_y),
            .w = @round(bb.width * scale_x),
            .h = @round(bb.height * scale_y),
        };

        switch (rcmd.command_type) {
            .scissor_start => {
                prev_text_bb = null;
                current_scissor = sdl.Rect{
                    .x = @intFromFloat(@round(bb.x * scale_x)),
                    .y = @intFromFloat(@round(bb.y * scale_y)),
                    .w = @intFromFloat(@round(bb.width * scale_x)),
                    .h = @intFromFloat(@round(bb.height * scale_y)),
                };
            },
            .scissor_end => {
                prev_text_bb = null;
                current_scissor = null;
            },
            .rectangle => {
                prev_text_bb = null;
                try appendRectangleCommand(
                    &vertices,
                    &batches,
                    allocator,
                    rect,
                    rcmd.render_data.rectangle,
                    scale_x,
                    f_win_w,
                    f_win_h,
                    state.white_texture.?,
                    current_scissor,
                );
            },
            .text => {
                if (try getOrRenderCachedText(
                    state,
                    cmd_buf,
                    fonts,
                    rcmd.render_data.text,
                    scale_x,
                    allocator,
                    temp_buffers,
                    &tb_offset,
                )) |cached| {
                    const offset_y = @round((rect.h - cached.h) / 2.0);
                    const world_y = rect.y + @max(0.0, offset_y);
                    var world_x = rect.x;

                    if (prev_text_bb) |pbb| {
                        const is_same_line = std.math.approxEqAbs(f32, pbb.y, bb.y, 0.5);
                        const is_adjacent = std.math.approxEqAbs(f32, pbb.x + pbb.width, bb.x, 0.5);
                        if (is_same_line and is_adjacent) {
                            world_x = prev_text_end_x;
                        }
                    }

                    prev_text_bb = bb;
                    prev_text_end_x = world_x + cached.w;

                    const ndc_x1 = (world_x / f_win_w) * 2.0 - 1.0;
                    const ndc_y1 = 1.0 - (world_y / f_win_h) * 2.0;
                    const ndc_x2 = ((world_x + cached.w) / f_win_w) * 2.0 - 1.0;
                    const ndc_y2 = 1.0 - ((world_y + cached.h) / f_win_h) * 2.0;

                    const start = @as(u32, @intCast(vertices.items.len));
                    const white_color = packRgba(255, 255, 255, 255);
                    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y1, .u = 0.0, .v = 0.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y1, .u = 1.0, .v = 0.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x2, .y = ndc_y2, .u = 1.0, .v = 1.0, .color = white_color });
                    try vertices.append(allocator, .{ .x = ndc_x1, .y = ndc_y2, .u = 0.0, .v = 1.0, .color = white_color });

                    try addBatch(&batches, allocator, start, 6, cached.texture, false, current_scissor);
                }
            },
            .border => {
                prev_text_bb = null;
                try appendBorderCommand(
                    &vertices,
                    &batches,
                    allocator,
                    rect,
                    rcmd.render_data.border,
                    rcmd.user_data,
                    scale_x,
                    f_win_w,
                    f_win_h,
                    state.white_texture.?,
                    current_scissor,
                );
            },
            .image => {
                prev_text_bb = null;
                try appendImageCommand(
                    &vertices,
                    &batches,
                    allocator,
                    rect,
                    rcmd.render_data.image.image_data,
                    state,
                    f_win_w,
                    f_win_h,
                    current_scissor,
                );
            },
            else => {
                std.log.warn("Skipping unhandled render command type: {}", .{rcmd.command_type});
            },
        }
    }

    // Persistent Vertex Buffer Double-Buffering
    var vert_buf: ?sdl.gpu.Buffer = null;
    const needed_size = vertices.items.len * @sizeOf(Vertex);

    if (needed_size > 0) {
        if (state.gpu_vertex_buffers[frame_idx] == null or state.gpu_vertex_capacities[frame_idx] < needed_size) {
            if (state.gpu_vertex_buffers[frame_idx]) |vb| {
                dev.releaseBuffer(vb);
                state.gpu_vertex_buffers[frame_idx] = null;
            }
            const new_vcap = std.mem.alignForward(usize, needed_size * 2, 4096);
            state.gpu_vertex_buffers[frame_idx] = dev.createBuffer(&sdl.gpu.BufferCreateInfo{
                .usage = sdl.gpu.BufferUsage.vertex,
                .size = @intCast(new_vcap),
                .props = 0,
            }) orelse return error.GPUBufferCreationFailed;
            state.gpu_vertex_capacities[frame_idx] = new_vcap;
        }

        const vert_offset = std.mem.alignForward(usize, tb_offset, 512);
        const total_tb_needed = vert_offset + needed_size;

        if (state.gpu_transfer_buffers[frame_idx] == null or state.gpu_buffer_capacities[frame_idx] < total_tb_needed) {
            if (state.gpu_transfer_buffers[frame_idx]) |old_tb| {
                try temp_buffers.append(allocator, old_tb);
            }
            const new_tbcap = std.mem.alignForward(usize, total_tb_needed * 2, 4096);
            state.gpu_transfer_buffers[frame_idx] = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
                .usage = .upload,
                .size = @intCast(new_tbcap),
                .props = 0,
            }) orelse return error.GPUTransferBufferCreationFailed;
            state.gpu_buffer_capacities[frame_idx] = new_tbcap;
        }

        const vb = state.gpu_vertex_buffers[frame_idx].?;
        const tb = state.gpu_transfer_buffers[frame_idx].?;

        const mapped_raw: [*]u8 = dev.mapTransferBuffer(tb, false) orelse return error.GPUMapFailed;
        const mapped: [*]Vertex = @ptrCast(@alignCast(mapped_raw + vert_offset));
        @memcpy(mapped[0..vertices.items.len], vertices.items);
        dev.unmapTransferBuffer(tb);

        const cmd = cmd_buf;
        const copy_pass = cmd.beginCopyPass() orelse return error.GPUCopyPassFailed;
        copy_pass.uploadToBuffer(&sdl.gpu.TransferBufferLocation{
            .transfer_buffer = tb,
            .offset = @intCast(vert_offset),
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
                if (safe_sc.w <= 0 or safe_sc.h <= 0 or safe_sc.x >= win_w or safe_sc.y >= win_h) continue;
                safe_sc.w = @min(safe_sc.w, win_w - safe_sc.x);
                safe_sc.h = @min(safe_sc.h, win_h - safe_sc.y);
                render_pass.setScissor(&safe_sc);
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

    const end_render = sdl.timer.getTicksNs();
    state.last_ui_render_time_ms = @as(f64, @floatFromInt(end_render - start_render)) / 1_000_000.0;
    state.last_ui_vertex_count = vertices.items.len;
    state.last_ui_batch_count = batches.items.len;

    state.gpu_frame_index += 1;
}
