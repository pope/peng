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
    if (count == 0) return;
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
    u_min: f32,
    v_min: f32,
    u_max: f32,
    v_max: f32,
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

    const is_ui_image = (state.white_texture != null and tex.ptr == state.white_texture.?.ptr);

    var dst_rect = rect;
    var cos_val: f32 = 1.0;
    var sin_val: f32 = 0.0;

    if (!is_ui_image) {
        var dst_w = rect.w;
        var dst_h = rect.h;
        const angle = state.rotation_angle;
        const is_90_or_270 = std.math.approxEqAbs(f32, angle, 90.0, 0.01) or std.math.approxEqAbs(f32, angle, 270.0, 0.01);
        if (is_90_or_270) {
            dst_w = rect.h;
            dst_h = rect.w;
        }
        dst_rect.w = dst_w * state.zoom_factor;
        dst_rect.h = dst_h * state.zoom_factor;
        const center_x = rect.x + rect.w / 2.0;
        const center_y = rect.y + rect.h / 2.0;
        dst_rect.x = center_x - (dst_rect.w / 2.0) + state.pan_x;
        dst_rect.y = center_y - (dst_rect.h / 2.0) + state.pan_y;

        const rad = angle * (std.math.pi / 180.0);
        cos_val = @cos(rad);
        sin_val = @sin(rad);
    }

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

    const start = @as(u32, @intCast(vertices.items.len));
    const white_color = packRgba(255, 255, 255, 255);
    try vertices.append(allocator, .{ .x = p1.x, .y = p1.y, .u = 0.0, .v = 0.0, .color = white_color });
    try vertices.append(allocator, .{ .x = p2.x, .y = p2.y, .u = 1.0, .v = 0.0, .color = white_color });
    try vertices.append(allocator, .{ .x = p4.x, .y = p4.y, .u = 0.0, .v = 1.0, .color = white_color });
    try vertices.append(allocator, .{ .x = p2.x, .y = p2.y, .u = 1.0, .v = 0.0, .color = white_color });
    try vertices.append(allocator, .{ .x = p3.x, .y = p3.y, .u = 1.0, .v = 1.0, .color = white_color });
    try vertices.append(allocator, .{ .x = p4.x, .y = p4.y, .u = 0.0, .v = 1.0, .color = white_color });

    try addBatch(batches, allocator, start, 6, tex, !is_ui_image, scissor);
}

fn getOrRenderCachedText(
    state: *app_state.ViewerState,
    copy_pass: sdl.gpu.CopyPass,
    fonts: []const ?sdl.Font,
    text_data: *clay.TextRenderData,
    scale_x: f32,
    allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    tb_offset: *usize,
) !?CachedText {
    if (text_data.font_id >= fonts.len) return null;
    const font = fonts[text_data.font_id] orelse return null;

    if (text_data.string_contents.length <= 0) return null;
    const len: usize = @intCast(text_data.string_contents.length);
    var text_slice = text_data.string_contents.chars[0..len];
    if (std.mem.indexOfScalar(u8, text_slice, 0)) |null_idx| {
        text_slice = text_slice[0..null_idx];
    }
    if (text_slice.len == 0) return null;

    const target_font_size = @as(f32, @floatFromInt(text_data.font_size)) * scale_x;
    if (target_font_size <= 0.0) return null;
    const target_font_size_u16 = @as(u16, @intFromFloat(@round(target_font_size)));

    const color_u32 = packRgba(
        @intFromFloat(text_data.text_color[0]),
        @intFromFloat(text_data.text_color[1]),
        @intFromFloat(text_data.text_color[2]),
        @intFromFloat(text_data.text_color[3]),
    );

    const key = app_state.TextCacheModule.TextCacheKey{
        .font_id = text_data.font_id,
        .font_size = target_font_size_u16,
        .color = color_u32,
        .hash = std.hash.Wyhash.hash(0, text_slice),
    };

    if (state.text_cache.get(key)) |val| {
        return CachedText{
            .u_min = val.u_min,
            .v_min = val.v_min,
            .u_max = val.u_max,
            .v_max = val.v_max,
            .w = val.w,
            .h = val.h,
        };
    }

    const dev = state.gpu_device.?;
    const frame_idx = state.gpu_frame_index % 2;

    _ = font.setFontSize(target_font_size);

    const surf = font.renderTextBlended(allocator, text_slice, .{
        .r = @intFromFloat(@round(std.math.clamp(text_data.text_color[0], 0.0, 255.0))),
        .g = @intFromFloat(@round(std.math.clamp(text_data.text_color[1], 0.0, 255.0))),
        .b = @intFromFloat(@round(std.math.clamp(text_data.text_color[2], 0.0, 255.0))),
        .a = @intFromFloat(@round(std.math.clamp(text_data.text_color[3], 0.0, 255.0))),
    }) catch |err| {
        std.log.warn("font.renderTextBlended failed for '{s}': {}", .{ text_slice, err });
        return null;
    };
    defer surf.destroy();

    const converted = surf.convert(sdl.PixelFormat.rgba32) orelse return null;
    defer converted.destroy();

    const surf_w: usize = @intCast(converted.w());
    const surf_h: usize = @intCast(converted.h());

    const slot = state.text_cache.allocateSlot(@intCast(surf_w), @intCast(surf_h)) orelse return null;
    const atlas_tex = state.white_texture.?;

    const dst_row_bytes = std.mem.alignForward(usize, surf_w * 4, 256);
    const size = dst_row_bytes * surf_h;
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
            return null;
        }
        state.gpu_buffer_capacities[frame_idx] = new_tbcap;
    }

    const transfer_buf = state.gpu_transfer_buffers[frame_idx].?;
    const mapped_raw: [*]u8 = dev.mapTransferBuffer(transfer_buf, false) orelse return null;
    const mapped = mapped_raw + aligned_offset;
    const src_row_bytes: usize = surf_w * 4;
    const pitch: usize = @intCast(converted.pitch());

    var row_y: usize = 0;
    while (row_y < surf_h) : (row_y += 1) {
        const src_row = converted.pixels()[row_y * pitch .. row_y * pitch + src_row_bytes];
        const dst_row = mapped[row_y * dst_row_bytes .. row_y * dst_row_bytes + src_row_bytes];
        @memcpy(dst_row, src_row);
    }
    dev.unmapTransferBuffer(transfer_buf);

    copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = @intCast(aligned_offset),
        .pixels_per_row = @intCast(dst_row_bytes / 4),
        .rows_per_layer = @intCast(surf_h),
    }, &sdl.gpu.TextureRegion{
        .texture = atlas_tex,
        .x = @intCast(slot.x),
        .y = @intCast(slot.y),
        .w = @intCast(surf_w),
        .h = @intCast(surf_h),
        .d = 1,
    }, false);

    tb_offset.* = aligned_offset + size;

    const w_f: f32 = @floatFromInt(surf_w);
    const h_f: f32 = @floatFromInt(surf_h);
    const atlas_size_f: f32 = @floatFromInt(app_state.TextCacheModule.ATLAS_SIZE);

    const u_min = @as(f32, @floatFromInt(slot.x)) / atlas_size_f;
    const v_min = @as(f32, @floatFromInt(slot.y)) / atlas_size_f;
    const u_max = @as(f32, @floatFromInt(slot.x + surf_w)) / atlas_size_f;
    const v_max = @as(f32, @floatFromInt(slot.y + surf_h)) / atlas_size_f;

    const cache_val = app_state.TextCacheModule.TextCacheValue{
        .u_min = u_min,
        .v_min = v_min,
        .u_max = u_max,
        .v_max = v_max,
        .w = w_f,
        .h = h_f,
    };

    state.text_cache.put(state.allocator, key, cache_val) catch |err| {
        std.log.err("Failed to cache rendered text: {}", .{err});
        return null;
    };

    return CachedText{
        .u_min = u_min,
        .v_min = v_min,
        .u_max = u_max,
        .v_max = v_max,
        .w = w_f,
        .h = h_f,
    };
}

pub inline fn isScissorInvisible(sc: ?sdl.Rect, win_w: i32, win_h: i32) bool {
    if (sc) |s| {
        if (s.w <= 0 or s.h <= 0) return true;
        if (s.x >= win_w or s.y >= win_h) return true;
        if (s.x + s.w <= 0 or s.y + s.h <= 0) return true;
    }
    return false;
}

pub inline fn normalizeScissor(sc: ?sdl.Rect, win_w: i32, win_h: i32) ?sdl.Rect {
    const s = sc orelse return null;
    if (s.w <= 0 or s.h <= 0) return s;

    const clamped_x = @max(0, s.x);
    const clamped_y = @max(0, s.y);

    const diff_x = clamped_x - s.x;
    const diff_y = clamped_y - s.y;

    if (s.w <= diff_x or s.h <= diff_y) return s;

    var clamped_w = s.w - diff_x;
    var clamped_h = s.h - diff_y;

    if (clamped_x >= win_w or clamped_y >= win_h) return s;

    clamped_w = @min(clamped_w, win_w - clamped_x);
    clamped_h = @min(clamped_h, win_h - clamped_y);

    if (clamped_w <= 0 or clamped_h <= 0) return s;

    if (clamped_x == 0 and clamped_y == 0 and clamped_w >= win_w and clamped_h >= win_h) {
        return null;
    }

    return sdl.Rect{ .x = clamped_x, .y = clamped_y, .w = clamped_w, .h = clamped_h };
}

fn buildGeometryFromCommands(
    state: *app_state.ViewerState,
    copy_pass: sdl.gpu.CopyPass,
    fonts: []const ?sdl.Font,
    r_commands: []const clay.RenderCommand,
    allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    win_w: i32,
    win_h: i32,
    scale_x: f32,
    scale_y: f32,
    vertices: *std.ArrayList(Vertex),
    batches: *std.ArrayList(BatchItem),
    tb_offset: *usize,
) !void {
    const f_win_w = @as(f32, @floatFromInt(win_w));
    const f_win_h = @as(f32, @floatFromInt(win_h));

    var current_scissor: ?sdl.Rect = null;
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

        if (rcmd.command_type == .scissor_start) {
            prev_text_bb = null;
            const raw_sc = sdl.Rect{
                .x = @intFromFloat(@round(bb.x * scale_x)),
                .y = @intFromFloat(@round(bb.y * scale_y)),
                .w = @intFromFloat(@round(bb.width * scale_x)),
                .h = @intFromFloat(@round(bb.height * scale_y)),
            };
            current_scissor = normalizeScissor(raw_sc, win_w, win_h);
            continue;
        } else if (rcmd.command_type == .scissor_end) {
            prev_text_bb = null;
            current_scissor = null;
            continue;
        }

        if (isScissorInvisible(current_scissor, win_w, win_h)) continue;

        switch (rcmd.command_type) {
            .scissor_start, .scissor_end => {
                std.log.err("Unexpected scissor command in render switch: {}", .{rcmd.command_type});
            },
            .rectangle => {
                prev_text_bb = null;
                try appendRectangleCommand(
                    vertices,
                    batches,
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
                var text_data = rcmd.render_data.text;
                if (try getOrRenderCachedText(
                    state,
                    copy_pass,
                    fonts,
                    &text_data,
                    scale_x,
                    allocator,
                    temp_buffers,
                    tb_offset,
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

                    const p1 = geometry.toNdc(world_x, world_y, f_win_w, f_win_h);
                    const p2 = geometry.toNdc(world_x + cached.w, world_y + cached.h, f_win_w, f_win_h);

                    const start = @as(u32, @intCast(vertices.items.len));
                    const white_color = packRgba(255, 255, 255, 255);
                    try vertices.append(allocator, .{ .x = p1.x, .y = p1.y, .u = cached.u_min, .v = cached.v_min, .color = white_color });
                    try vertices.append(allocator, .{ .x = p2.x, .y = p1.y, .u = cached.u_max, .v = cached.v_min, .color = white_color });
                    try vertices.append(allocator, .{ .x = p1.x, .y = p2.y, .u = cached.u_min, .v = cached.v_max, .color = white_color });
                    try vertices.append(allocator, .{ .x = p2.x, .y = p1.y, .u = cached.u_max, .v = cached.v_min, .color = white_color });
                    try vertices.append(allocator, .{ .x = p2.x, .y = p2.y, .u = cached.u_max, .v = cached.v_max, .color = white_color });
                    try vertices.append(allocator, .{ .x = p1.x, .y = p2.y, .u = cached.u_min, .v = cached.v_max, .color = white_color });

                    try addBatch(batches, allocator, start, 6, state.white_texture.?, false, current_scissor);
                }
            },
            .border => {
                prev_text_bb = null;
                try appendBorderCommand(
                    vertices,
                    batches,
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
                    vertices,
                    batches,
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
}

fn uploadVertexData(
    state: *app_state.ViewerState,
    dev: sdl.gpu.Device,
    frame_idx: usize,
    copy_pass: sdl.gpu.CopyPass,
    allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    vertex_items: []const Vertex,
    tb_offset: usize,
) !?sdl.gpu.Buffer {
    const needed_size = vertex_items.len * @sizeOf(Vertex);
    if (needed_size == 0) return null;

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
        }) orelse return error.GPUVertexBufferCreationFailed;
        state.gpu_vertex_capacities[frame_idx] = new_vcap;
    }

    const vert_offset = std.mem.alignForward(usize, tb_offset, 512);
    const total_tb_needed = vert_offset + needed_size;

    if (state.gpu_transfer_buffers[frame_idx] == null or state.gpu_buffer_capacities[frame_idx] < total_tb_needed) {
        if (state.gpu_transfer_buffers[frame_idx]) |old_tb| {
            // Catch OOM on the deferred cleanup list so a non-critical array append failure
            // does not abort the entire frame's render pass. Log the error and continue rendering.
            temp_buffers.append(allocator, old_tb) catch |err| {
                std.log.err("Failed to append old transfer buffer to cleanup list in uploadVertexData: {}", .{err});
                dev.releaseTransferBuffer(old_tb);
            };
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
    @memcpy(mapped[0..vertex_items.len], vertex_items);
    dev.unmapTransferBuffer(tb);

    copy_pass.uploadToBuffer(&sdl.gpu.TransferBufferLocation{
        .transfer_buffer = tb,
        .offset = @intCast(vert_offset),
    }, &sdl.gpu.BufferRegion{
        .buffer = vb,
        .offset = 0,
        .size = @intCast(needed_size),
    }, false);

    return vb;
}

fn executeRenderPass(
    state: *app_state.ViewerState,
    cmd_buf: sdl.gpu.CommandBuffer,
    swap_tex: sdl.gpu.Texture,
    batches: []const BatchItem,
    vert_buf: ?sdl.gpu.Buffer,
    win_w: i32,
    win_h: i32,
) void {
    const color_target = sdl.gpu.ColorTargetAttachment{
        .texture = swap_tex,
        .clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        .load_op = .clear,
        .store_op = .store,
        .cycle = false,
    };

    const render_pass = cmd_buf.beginRenderPass(&color_target) orelse {
        std.log.err("SDL GPU beginRenderPass failed in renderClayCommands: {s}", .{sdl.getError()});
        return;
    };
    defer render_pass.end();

    render_pass.bindPipeline(state.gpu_pipeline.?);

    if (vert_buf) |vb| {
        const vert_binding = sdl.gpu.BufferBinding{ .buffer = vb, .offset = 0 };
        render_pass.bindVertexBuffers(0, &[_]sdl.gpu.BufferBinding{vert_binding});

        for (batches) |batch| {
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

            const scale_mode_val: i32 = if (batch.is_image) switch (state.texture_scale_mode) {
                .nearest => 0,
                .linear => 1,
                .pixel_art => 2,
                .mitchell => 3,
                .lanczos3 => 4,
            } else 0;
            const ubo = Uniforms{
                .brightness = state.brightness,
                .contrast = state.contrast,
                .is_text_or_color = if (batch.is_image) 0 else 1,
                .scale_mode = scale_mode_val,
            };
            cmd_buf.pushFragmentUniform(0, std.mem.asBytes(&ubo));

            render_pass.bindFragmentSamplers(0, &[_]sdl.gpu.TextureSamplerBinding{.{ .texture = batch.texture, .sampler = state.gpu_sampler.? }});
            render_pass.drawPrimitives(batch.vertex_count, 1, batch.vertex_start, 0);
        }
    }
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
    const dev = state.gpu_device.?;
    const frame_idx = state.gpu_frame_index % 2;

    if (state.text_cache.needs_reset) {
        state.text_cache.resetAtlas();
    }

    var vertices = std.ArrayList(Vertex).empty;
    defer vertices.deinit(allocator);

    var batches = std.ArrayList(BatchItem).empty;
    defer batches.deinit(allocator);

    var tb_offset: usize = 0;

    const copy_pass = cmd_buf.beginCopyPass() orelse {
        std.log.err("SDL GPU beginCopyPass failed in renderClayCommands: {s}", .{sdl.getError()});
        return error.GPUCopyPassFailed;
    };
    errdefer copy_pass.end();

    try buildGeometryFromCommands(
        state,
        copy_pass,
        fonts,
        r_commands,
        allocator,
        temp_buffers,
        win_w,
        win_h,
        scale_x,
        scale_y,
        &vertices,
        &batches,
        &tb_offset,
    );

    const vert_buf = try uploadVertexData(
        state,
        dev,
        frame_idx,
        copy_pass,
        allocator,
        temp_buffers,
        vertices.items,
        tb_offset,
    );

    copy_pass.end();

    executeRenderPass(
        state,
        cmd_buf,
        swap_tex,
        batches.items,
        vert_buf,
        win_w,
        win_h,
    );

    const end_render = sdl.timer.getTicksNs();
    const render_time_ms = @as(f64, @floatFromInt(end_render - start_render)) / 1_000_000.0;
    state.last_ui_render_time_ms = render_time_ms;
    state.ui_render_stats.addSample(render_time_ms);
    state.last_ui_vertex_count = vertices.items.len;
    state.last_ui_batch_count = batches.items.len;

    state.gpu_frame_index += 1;
}
