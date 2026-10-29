//! GPU Render Pass Execution and Target Lifecycle Module
//!
//! Provides zero-Clay rendering passes, batched draw call execution, text
//! glyph upload helpers, and swapchain/headless target submission lifecycle.
//!
//! INVARIANT: Code in `src/gpu/pass.zig` MUST NOT depend on zclay, `src/ui/`,
//! `src/core/`, or `src/app/`.

const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");
const render_image = @import("render_image.zig");
const sdl = @import("sdl");
const state = @import("state");
const std = @import("std");
const text_cache = @import("text_cache.zig");

const BatchItem = render_image.BatchItem;
const BlurResources = graphics.BlurResources;
const BlurUniforms = graphics.BlurUniforms;
const ImageUniforms = render_image.ImageUniforms;
const MaterialType = render_image.MaterialType;
const RenderResources = graphics.RenderResources;
const saveTextureToPng = graphics.saveTextureToPng;
const TextCacheKey = text_cache.TextCacheKey;
const UiUniforms = render_image.UiUniforms;
const Vertex = geometry.Vertex;
const ViewportParams = state.ViewportParams;

/// Cached text texture and rendered dimensions.
pub const CachedText = struct {
    texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
};

/// Target options and parameters for frame execution and presentation.
pub const FrameTargetOptions = struct {
    window: ?sdl.Window,
    width: u32,
    height: u32,
    capture_filename: ?[:0]const u8 = null,
};

fn scissorEqual(a: ?sdl.Rect, b: ?sdl.Rect) bool {
    if (a) |sa| {
        if (b) |sb| {
            return sa.x == sb.x and sa.y == sb.y and
                sa.w == sb.w and sa.h == sb.h;
        }
        return false;
    }
    return b == null;
}

/// Computes the rectangular intersection of two scissor clipping rectangles.
pub fn intersectScissor(a: sdl.Rect, b: sdl.Rect) sdl.Rect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x + a.w, b.x + b.w);
    const y2 = @min(a.y + a.h, b.y + b.h);
    return sdl.Rect{
        .x = x1,
        .y = y1,
        .w = @max(0, x2 - x1),
        .h = @max(0, y2 - y1),
    };
}

/// Returns true if scissor box has non-positive area or falls outside window.
pub inline fn isScissorInvisible(sc: ?sdl.Rect, win_w: i32, win_h: i32) bool {
    if (win_w <= 0 or win_h <= 0) return true;
    if (sc) |s| {
        if (s.w <= 0 or s.h <= 0) return true;
        if (s.x >= win_w or s.y >= win_h) return true;
        if (s.x + s.w <= 0 or s.y + s.h <= 0) return true;
    }
    return false;
}

inline fn shouldCycleFrameBuffer(
    was_reallocated: bool,
    aligned_offset: usize,
) bool {
    return !was_reallocated and aligned_offset == 0;
}

/// Merges contiguous vertex draw calls sharing identical pipeline/texture
/// and scissor state.
pub fn addBatch(
    batches: *std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,
    start: u32,
    count: u32,
    texture: sdl.gpu.Texture,
    material: MaterialType,
    scissor: ?sdl.Rect,
) !void {
    if (batches.items.len > 0) {
        var last = &batches.items[batches.items.len - 1];
        if (last.texture.eql(texture) and
            last.material == material and
            scissorEqual(last.scissor, scissor))
        {
            last.vertex_count += count;
            return;
        }
    }
    try batches.append(allocator, .{
        .vertex_start = start,
        .vertex_count = count,
        .texture = texture,
        .material = material,
        .scissor = scissor,
    });
}

/// Renders or retrieves cached text texture for a glyph string. Alpha is
/// modulated dynamically at draw time via GPU vertex color attributes.
pub fn getOrRenderCachedText(
    gpu_res: *RenderResources,
    copy_pass: sdl.gpu.CopyPass,
    fonts: []const ?sdl.Font,
    font_id: usize,
    font_size: u16,
    raw_text: []const u8,
    rgb: [3]f32,
    scale_x: f32,
    gpa_allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    tb_offset: *usize,
) !?CachedText {
    if (font_id >= fonts.len) return null;
    const font = fonts[font_id] orelse return null;

    if (raw_text.len == 0) return null;
    var text_slice = raw_text;
    if (std.mem.findScalar(u8, text_slice, 0)) |null_idx| {
        text_slice = text_slice[0..null_idx];
    }
    if (text_slice.len == 0) return null;

    const target_font_size = @as(f32, @floatFromInt(font_size)) * scale_x;
    const target_font_size_u16 =
        @as(u16, @intFromFloat(@round(target_font_size)));

    // 1. Check/Lookup cache (RGB only; alpha modulated dynamically via vertex)
    const color_rgb_u32 = @as(u32, @intFromFloat(rgb[0])) |
        (@as(u32, @intFromFloat(rgb[1])) << 8) |
        (@as(u32, @intFromFloat(rgb[2])) << 16);

    const key = TextCacheKey{
        .font_id = font_id,
        .font_size = target_font_size_u16,
        .color = color_rgb_u32,
        .hash = std.hash.Wyhash.hash(0, text_slice),
    };

    const dev = gpu_res.device;

    if (gpu_res.text_cache.getEntry(key)) |entry| {
        entry.value_ptr.last_used_frame = gpu_res.frame_index;
        return CachedText{
            .texture = entry.value_ptr.texture,
            .w = entry.value_ptr.w,
            .h = entry.value_ptr.h,
        };
    }

    const frame_idx = gpu_res.frame_index % 2;

    if (font.getFontSize() != target_font_size) {
        _ = font.setFontSize(target_font_size);
    }

    const surf = font.renderTextBlended(frame_allocator, text_slice, .{
        .r = @intFromFloat(rgb[0]),
        .g = @intFromFloat(rgb[1]),
        .b = @intFromFloat(rgb[2]),
        .a = 255,
    }) catch |err| {
        std.log.warn(
            "font.renderTextBlended failed for '{s}': {}",
            .{ text_slice, err },
        );
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

    const tb_acq = gpu_res.ensureFrameTransferBuffer(
        frame_idx,
        required_capacity,
        64 * 1024,
        frame_allocator,
        temp_buffers,
    ) orelse {
        dev.releaseTexture(tex);
        return null;
    };
    const transfer_buf = tb_acq.handle;
    const cycle_tb =
        shouldCycleFrameBuffer(tb_acq.reallocated, aligned_offset);
    const mapped_raw: [*]u8 = dev.mapTransferBuffer(
        transfer_buf,
        cycle_tb,
    ) orelse {
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
        const src_start = row_y * pitch;
        const src_row =
            converted.pixels()[src_start .. src_start + src_row_bytes];
        const dst_offset = row_y * dst_row_bytes + dst_start_byte;
        const dst_row = mapped[dst_offset..][0..src_row_bytes];
        @memcpy(dst_row, src_row);
    }
    dev.unmapTransferBuffer(transfer_buf);

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

    tb_offset.* = aligned_offset + size;

    const w_f: f32 = @floatFromInt(target_w);
    const h_f: f32 = @floatFromInt(surf_h);

    gpu_res.text_cache.put(gpa_allocator, dev, key, .{
        .texture = tex,
        .w = w_f,
        .h = h_f,
        .last_used_frame = gpu_res.frame_index,
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

/// Data-driven render packet holding geometry vertices, batch draw calls,
/// and transfer buffer offsets for 2-pass UI frame rendering.
pub const RenderPacket = struct {
    vertices: std.ArrayList(Vertex) = .empty,
    batches: std.ArrayList(BatchItem) = .empty,
    tb_offset: usize = 0,

    /// Releases vertex and batch command memory.
    pub fn deinit(self: *RenderPacket, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.batches.deinit(allocator);
    }
};

fn uploadVertexData(
    gpu_res: *RenderResources,
    frame_idx: usize,
    copy_pass: sdl.gpu.CopyPass,
    frame_allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    vertex_items: []const Vertex,
    tb_offset: usize,
) !?sdl.gpu.Buffer {
    const dev = gpu_res.device;
    const needed_size = vertex_items.len * @sizeOf(Vertex);
    if (needed_size == 0) return null;

    const vb_acq = gpu_res.ensureFrameVertexBuffer(
        frame_idx,
        needed_size,
    ) orelse return error.GPUVertexBufferCreationFailed;

    const vert_offset = std.mem.alignForward(usize, tb_offset, 512);
    const total_tb_needed = vert_offset + needed_size;

    const tb_acq = gpu_res.ensureFrameTransferBuffer(
        frame_idx,
        total_tb_needed,
        4 * 1024,
        frame_allocator,
        temp_buffers,
    ) orelse return error.GPUTransferBufferCreationFailed;

    const vb = vb_acq.handle;
    const tb = tb_acq.handle;

    const cycle_tb = shouldCycleFrameBuffer(tb_acq.reallocated, vert_offset);
    const mapped_raw: [*]u8 = dev.mapTransferBuffer(
        tb,
        cycle_tb,
    ) orelse return error.GPUMapFailed;
    const mapped: [*]Vertex = @ptrCast(@alignCast(mapped_raw + vert_offset));
    @memcpy(mapped[0..vertex_items.len], vertex_items);
    dev.unmapTransferBuffer(tb);

    const cycle_vb = shouldCycleFrameBuffer(vb_acq.reallocated, 0);
    copy_pass.uploadToBuffer(&sdl.gpu.TransferBufferLocation{
        .transfer_buffer = tb,
        .offset = @intCast(vert_offset),
    }, &sdl.gpu.BufferRegion{
        .buffer = vb,
        .offset = 0,
        .size = @intCast(needed_size),
    }, cycle_vb);

    return vb;
}

fn drawBatches(
    view_params: ViewportParams,
    gpu: *const RenderResources,
    render_pass: sdl.gpu.RenderPass,
    cmd_buf: sdl.gpu.CommandBuffer,
    batches: []const BatchItem,
    win_w: i32,
    win_h: i32,
) void {
    var last_pipeline: ?sdl.gpu.Pipeline = null;
    var last_material: ?MaterialType = null;

    for (batches) |batch| {
        if (batch.scissor) |sc| {
            var safe_sc = sc;
            safe_sc.x = @max(0, sc.x);
            safe_sc.y = @max(0, sc.y);
            safe_sc.w = @max(0, sc.w - (safe_sc.x - sc.x));
            safe_sc.h = @max(0, sc.h - (safe_sc.y - sc.y));
            if (safe_sc.w <= 0 or safe_sc.h <= 0 or
                safe_sc.x >= win_w or safe_sc.y >= win_h) continue;
            safe_sc.w = @min(safe_sc.w, win_w - safe_sc.x);
            safe_sc.h = @min(safe_sc.h, win_h - safe_sc.y);
            render_pass.setScissor(&safe_sc);
        } else {
            const full_sc = sdl.Rect{ .x = 0, .y = 0, .w = win_w, .h = win_h };
            render_pass.setScissor(&full_sc);
        }

        const is_image = (batch.material == .image_viewer);
        const pipeline = if (is_image) gpu.image_pipeline else gpu.ui_pipeline;

        if (last_pipeline == null or last_pipeline.?.ptr != pipeline.ptr) {
            render_pass.bindPipeline(pipeline);
            last_pipeline = pipeline;
        }

        if (last_material == null or last_material.? != batch.material) {
            if (is_image) {
                const show_original = view_params.compare_original;
                const apply_adj =
                    !show_original and view_params.edits.hasEdits();
                const edits = view_params.edits;
                const img_ubo = ImageUniforms{
                    .brightness = if (apply_adj)
                        edits.get(.brightness)
                    else
                        0.0,
                    .contrast = if (apply_adj)
                        edits.get(.contrast)
                    else
                        1.0,
                    .temperature = if (apply_adj)
                        edits.get(.temperature)
                    else
                        0.0,
                    .tint = if (apply_adj)
                        edits.get(.tint)
                    else
                        0.0,
                    .highlights = if (apply_adj)
                        edits.get(.highlights)
                    else
                        0.0,
                    .shadows = if (apply_adj)
                        edits.get(.shadows)
                    else
                        0.0,
                    .whites = if (apply_adj)
                        edits.get(.whites)
                    else
                        0.0,
                    .blacks = if (apply_adj)
                        edits.get(.blacks)
                    else
                        0.0,
                    .saturation = if (apply_adj)
                        edits.get(.saturation)
                    else
                        0.0,
                    .vibrance = if (apply_adj)
                        edits.get(.vibrance)
                    else
                        0.0,
                    .contrast_blend = if (apply_adj)
                        edits.get(.contrast_blend)
                    else
                        1.0,
                    .scale_mode = view_params.getShaderScaleModeInt(),
                    .has_adjustments = if (apply_adj) 1 else 0,
                    .clarity = if (apply_adj) edits.get(.clarity) else 0.0,
                    .texture = if (apply_adj) edits.get(.texture) else 0.0,
                };
                cmd_buf.pushFragmentUniform(0, std.mem.asBytes(&img_ubo));
            } else {
                const is_blur = (batch.material == .blurred_surface);
                const ui_ubo = UiUniforms{
                    .is_blurred_surface = if (is_blur) 1 else 0,
                };
                cmd_buf.pushFragmentUniform(0, std.mem.asBytes(&ui_ubo));
            }
            last_material = batch.material;
        }

        render_pass.bindFragmentSamplers(0, &[_]sdl.gpu.TextureSamplerBinding{.{
            .texture = batch.texture,
            .sampler = gpu.sampler,
        }});
        render_pass.drawPrimitives(
            batch.vertex_count,
            1,
            batch.vertex_start,
            0,
        );
    }
}

const BlurSplit = struct {
    blur: BlurResources.Initialized,
    split_idx: usize,
};

fn findBlurSplit(
    batches: []const BatchItem,
    blur_res: BlurResources,
) ?BlurSplit {
    const init_res = switch (blur_res) {
        .initialized => |res| res,
        .uninitialized, .failed, .pipelines_ready => return null,
    };
    for (batches, 0..) |batch, i| {
        if (batch.material == .blurred_surface) {
            return .{ .blur = init_res, .split_idx = i };
        }
    }
    return null;
}

fn renderBatchPass(
    view_params: ViewportParams,
    gpu: *const RenderResources,
    cmd_buf: sdl.gpu.CommandBuffer,
    target_tex: sdl.gpu.Texture,
    batches: []const BatchItem,
    vert_buf: ?sdl.gpu.Buffer,
    win_w: i32,
    win_h: i32,
) bool {
    const color_target = sdl.gpu.ColorTargetAttachment{
        .texture = target_tex,
        .clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        .load_op = .clear,
        .store_op = .store,
        .cycle = false,
    };

    const render_pass = cmd_buf.beginRenderPass(&color_target) orelse {
        std.log.err("SDL GPU beginRenderPass failed: {s}", .{sdl.getError()});
        return false;
    };
    defer render_pass.end();

    if (vert_buf) |vb| {
        render_pass.bindVertexBuffers(0, &[_]sdl.gpu.BufferBinding{.{
            .buffer = vb,
            .offset = 0,
        }});
        drawBatches(
            view_params,
            gpu,
            render_pass,
            cmd_buf,
            batches,
            win_w,
            win_h,
        );
    }
    return true;
}

fn runBlurFilterPass(
    cmd_buf: sdl.gpu.CommandBuffer,
    gpu: *const RenderResources,
    target_tex: sdl.gpu.Texture,
    source_tex: sdl.gpu.Texture,
    pipeline: sdl.gpu.Pipeline,
    src_w: u32,
    src_h: u32,
    dst_w: u32,
    dst_h: u32,
    radius: f32,
) bool {
    const target = sdl.gpu.ColorTargetAttachment{
        .texture = target_tex,
        .clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        .load_op = .clear,
        .store_op = .store,
        .cycle = false,
    };
    const pass = cmd_buf.beginRenderPass(&target) orelse {
        std.log.err(
            "SDL GPU beginRenderPass failed for blur pass: {s}",
            .{sdl.getError()},
        );
        return false;
    };
    defer pass.end();

    pass.bindPipeline(pipeline);
    pass.bindVertexBuffers(0, &[_]sdl.gpu.BufferBinding{.{
        .buffer = gpu.fullscreen_vertex_buffer,
        .offset = 0,
    }});

    const ubo = BlurUniforms{
        .texel_size_x = 1.0 / @as(f32, @floatFromInt(src_w)),
        .texel_size_y = 1.0 / @as(f32, @floatFromInt(src_h)),
        .radius = radius,
        .padding = 0.0,
    };
    cmd_buf.pushFragmentUniform(0, std.mem.asBytes(&ubo));
    pass.bindFragmentSamplers(0, &[_]sdl.gpu.TextureSamplerBinding{.{
        .texture = source_tex,
        .sampler = gpu.sampler,
    }});

    const sc = sdl.Rect{
        .x = 0,
        .y = 0,
        .w = @intCast(dst_w),
        .h = @intCast(dst_h),
    };
    pass.setScissor(&sc);
    pass.drawPrimitives(6, 1, 0, 0);
    return true;
}

fn executeRenderPass(
    view_params: ViewportParams,
    gpu: *const RenderResources,
    cmd_buf: sdl.gpu.CommandBuffer,
    swap_tex: sdl.gpu.Texture,
    batches: []const BatchItem,
    vert_buf: ?sdl.gpu.Buffer,
    win_w: i32,
    win_h: i32,
) void {
    const split = findBlurSplit(batches, gpu.blur) orelse {
        _ = renderBatchPass(
            view_params,
            gpu,
            cmd_buf,
            swap_tex,
            batches,
            vert_buf,
            win_w,
            win_h,
        );
        return;
    };

    const blur = split.blur;
    const tex = blur.textures;
    const pipes = blur.pipelines;
    const idx = split.split_idx;

    // Pass 1: Render base scene batches under blurred surface into tex.scene
    if (!renderBatchPass(
        view_params,
        gpu,
        cmd_buf,
        tex.scene,
        batches[0..idx],
        vert_buf,
        win_w,
        win_h,
    )) {
        return;
    }

    // Pass 2: Downsample scene into blur_down (Dual Kawase pass 1)
    if (!runBlurFilterPass(
        cmd_buf,
        gpu,
        tex.blur_down,
        tex.scene,
        pipes.down,
        tex.target_w,
        tex.target_h,
        tex.down_w,
        tex.down_h,
        2.0,
    )) {
        return;
    }

    // Pass 3: Upsample blur_down into blur (Dual Kawase pass 2)
    if (!runBlurFilterPass(
        cmd_buf,
        gpu,
        tex.blur,
        tex.blur_down,
        pipes.up,
        tex.down_w,
        tex.down_h,
        tex.down_w,
        tex.down_h,
        2.5,
    )) {
        return;
    }

    // Pass 4: Composite onto swapchain (blit sharp base scene quad + draw
    // remaining overlay batches on top)
    {
        const final_target = sdl.gpu.ColorTargetAttachment{
            .texture = swap_tex,
            .clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            .load_op = .dont_care,
            .store_op = .store,
            .cycle = false,
        };
        const final_pass = cmd_buf.beginRenderPass(&final_target) orelse {
            std.log.err(
                "SDL GPU beginRenderPass failed for swapchain composite: {s}",
                .{sdl.getError()},
            );
            return;
        };
        defer final_pass.end();

        // 4a. Blit sharp base scene
        final_pass.bindPipeline(gpu.ui_pipeline);
        final_pass.bindVertexBuffers(0, &[_]sdl.gpu.BufferBinding{.{
            .buffer = gpu.fullscreen_vertex_buffer,
            .offset = 0,
        }});
        const fs_ubo = UiUniforms{
            .is_blurred_surface = 0,
        };
        cmd_buf.pushFragmentUniform(0, std.mem.asBytes(&fs_ubo));
        final_pass.bindFragmentSamplers(0, &[_]sdl.gpu.TextureSamplerBinding{.{
            .texture = tex.scene,
            .sampler = gpu.sampler,
        }});
        const full_sc = sdl.Rect{ .x = 0, .y = 0, .w = win_w, .h = win_h };
        final_pass.setScissor(&full_sc);
        final_pass.drawPrimitives(6, 1, 0, 0);

        // 4b. Draw remaining batches (blurred surfaces, text, controls)
        if (vert_buf) |vb| {
            final_pass.bindVertexBuffers(0, &[_]sdl.gpu.BufferBinding{.{
                .buffer = vb,
                .offset = 0,
            }});
            drawBatches(
                view_params,
                gpu,
                final_pass,
                cmd_buf,
                batches[idx..],
                win_w,
                win_h,
            );
        }
    }
}

/// Pass 2 of 2-pass rendering: Uploads vertex data to GPU memory and executes
/// batched GPU render pass draw calls for the extracted RenderPacket.
pub fn executeRenderPacket(
    view_params: ViewportParams,
    gpu_res: *RenderResources,
    cmd_buf: sdl.gpu.CommandBuffer,
    copy_pass: sdl.gpu.CopyPass,
    swap_tex: sdl.gpu.Texture,
    packet: *const RenderPacket,
    frame_allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    win_w: i32,
    win_h: i32,
) !void {
    const frame_idx = gpu_res.frame_index % 2;

    const vert_buf = try uploadVertexData(
        gpu_res,
        frame_idx,
        copy_pass,
        frame_allocator,
        temp_buffers,
        packet.vertices.items,
        packet.tb_offset,
    );

    copy_pass.end();

    executeRenderPass(
        view_params,
        gpu_res,
        cmd_buf,
        swap_tex,
        packet.batches.items,
        vert_buf,
        win_w,
        win_h,
    );
}

/// Orchestrates command buffer acquisition, swapchain vs headless target
/// binding, invocation of render callback, screenshot capture, and fence sync.
pub fn executeFrame(
    gpu_res: *RenderResources,
    frame_allocator: std.mem.Allocator,
    target: FrameTargetOptions,
    context: anytype,
    comptime render_fn: fn (
        ctx: @TypeOf(context),
        cmd_buf: sdl.gpu.CommandBuffer,
        target_tex: sdl.gpu.Texture,
        target_w: u32,
        target_h: u32,
        target_format: sdl.gpu.TextureFormat,
        temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    ) anyerror!void,
) !void {
    const dev = gpu_res.device;
    const cmd_buf = dev.acquireCommandBuffer() orelse
        return error.CommandBufferAcquisitionFailed;
    var cmd_buf_submitted = false;
    errdefer if (!cmd_buf_submitted) {
        _ = cmd_buf.cancel();
    };

    var temp_buffers: std.ArrayList(sdl.gpu.TransferBuffer) = .empty;
    defer {
        for (temp_buffers.items) |buf| {
            dev.releaseTransferBuffer(buf);
        }
        temp_buffers.deinit(frame_allocator);
    }

    const use_headless = (target.window == null);

    var target_tex: ?sdl.gpu.Texture = null;
    var target_w: u32 = 0;
    var target_h: u32 = 0;
    var target_format: sdl.gpu.TextureFormat = .invalid;

    if (use_headless) {
        target_w = target.width;
        target_h = target.height;
        target_format = .rgba8_unorm;

        const target_tex_info = sdl.gpu.TextureCreateInfo{
            .type = .type_2d,
            .format = .rgba8_unorm,
            .usage = sdl.gpu.TextureUsage.color_target,
            .width = target_w,
            .height = target_h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = .count_1,
            .props = 0,
        };
        target_tex = dev.createTexture(&target_tex_info) orelse {
            std.log.err(
                "Failed to create offscreen target texture: {s}",
                .{sdl.getError()},
            );
            return error.OffscreenTargetTextureCreationFailed;
        };
    } else {
        var swap_w: u32 = 0;
        var swap_h: u32 = 0;
        const win = target.window.?;
        if (win.waitAndAcquireSwapchainTexture(
            cmd_buf,
            &swap_w,
            &swap_h,
        )) |st| {
            target_tex = st;
            target_w = swap_w;
            target_h = swap_h;
            target_format = dev.getSwapchainTextureFormat(win);
        }
    }

    defer if (use_headless) {
        if (target_tex) |tex| {
            dev.releaseTexture(tex);
        }
    };

    if (target_tex) |tex| {
        if (target_w == 0 or target_h == 0) {
            cmd_buf_submitted = true;
            _ = cmd_buf.submit();
            if (target.capture_filename != null) {
                return error.SwapchainTextureUnavailable;
            }
            return;
        }

        try render_fn(
            context,
            cmd_buf,
            tex,
            target_w,
            target_h,
            target_format,
            &temp_buffers,
        );

        if (target.capture_filename) |filename| {
            cmd_buf_submitted = true;
            try saveTextureToPng(
                dev,
                cmd_buf,
                tex,
                target_w,
                target_h,
                target_format,
                filename,
            );
        } else if (use_headless) {
            cmd_buf_submitted = true;
            const fence_opt = cmd_buf.submitAndAcquireFence();
            if (fence_opt) |fence| {
                _ = dev.waitForFence(fence);
                dev.releaseFence(fence);
            } else {
                std.log.err(
                    "Failed to acquire GPU fence for headless render: {s}",
                    .{sdl.getError()},
                );
                return error.FenceAcquisitionFailed;
            }
        } else {
            cmd_buf_submitted = true;
            _ = cmd_buf.submit();
        }
    } else {
        cmd_buf_submitted = true;
        _ = cmd_buf.submit();
        if (target.capture_filename != null) {
            return error.SwapchainTextureUnavailable;
        }
    }
}

test "intersectScissor computes correct overlapping rectangle" {
    const a = sdl.Rect{ .x = 10, .y = 20, .w = 100, .h = 100 };
    const b = sdl.Rect{ .x = 50, .y = 60, .w = 100, .h = 100 };
    const res = intersectScissor(a, b);
    try std.testing.expectEqual(@as(i32, 50), res.x);
    try std.testing.expectEqual(@as(i32, 60), res.y);
    try std.testing.expectEqual(@as(i32, 60), res.w);
    try std.testing.expectEqual(@as(i32, 60), res.h);

    // Disjoint rectangles
    const c = sdl.Rect{ .x = 200, .y = 200, .w = 50, .h = 50 };
    const disjoint = intersectScissor(a, c);
    try std.testing.expectEqual(@as(i32, 0), disjoint.w);
    try std.testing.expectEqual(@as(i32, 0), disjoint.h);

    // Negative coordinates and partial overlap
    const neg1 = sdl.Rect{ .x = -20, .y = -20, .w = 50, .h = 50 };
    const neg2 = sdl.Rect{ .x = 0, .y = 0, .w = 50, .h = 50 };
    const neg_res = intersectScissor(neg1, neg2);
    try std.testing.expectEqual(@as(i32, 0), neg_res.x);
    try std.testing.expectEqual(@as(i32, 0), neg_res.y);
    try std.testing.expectEqual(@as(i32, 30), neg_res.w);
    try std.testing.expectEqual(@as(i32, 30), neg_res.h);
}

test "scissorEqual compares rectangles correctly" {
    const r1 = sdl.Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    const r2 = sdl.Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    const r3 = sdl.Rect{ .x = 11, .y = 20, .w = 30, .h = 40 };

    try std.testing.expect(scissorEqual(null, null));
    try std.testing.expect(!scissorEqual(null, r1));
    try std.testing.expect(!scissorEqual(r1, null));
    try std.testing.expect(scissorEqual(r1, r2));
    try std.testing.expect(!scissorEqual(r1, r3));
}

test "isScissorInvisible detects non-visible scissor bounds" {
    // Null scissor is visible (covers full window)
    try std.testing.expect(!isScissorInvisible(null, 1000, 800));

    // Zero or negative window dimensions
    try std.testing.expect(isScissorInvisible(null, 0, 800));
    try std.testing.expect(isScissorInvisible(null, 1000, -10));

    // Normal visible scissor
    const vis = sdl.Rect{ .x = 10, .y = 10, .w = 100, .h = 100 };
    try std.testing.expect(!isScissorInvisible(vis, 1000, 800));

    // Zero or negative area
    const zero_w = sdl.Rect{ .x = 10, .y = 10, .w = 0, .h = 100 };
    try std.testing.expect(isScissorInvisible(zero_w, 1000, 800));
    const neg_h = sdl.Rect{ .x = 10, .y = 10, .w = 100, .h = -5 };
    try std.testing.expect(isScissorInvisible(neg_h, 1000, 800));

    // Off-screen to right/bottom
    const off_r = sdl.Rect{ .x = 1000, .y = 10, .w = 100, .h = 100 };
    try std.testing.expect(isScissorInvisible(off_r, 1000, 800));
    const off_b = sdl.Rect{ .x = 10, .y = 800, .w = 100, .h = 100 };
    try std.testing.expect(isScissorInvisible(off_b, 1000, 800));

    // Off-screen to left/top
    const off_l = sdl.Rect{ .x = -100, .y = 10, .w = 100, .h = 100 };
    try std.testing.expect(isScissorInvisible(off_l, 1000, 800));
    const off_t = sdl.Rect{ .x = 10, .y = -100, .w = 100, .h = 100 };
    try std.testing.expect(isScissorInvisible(off_t, 1000, 800));
}

test "scissor stack dynamically grows beyond 16 levels with arena allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stack: std.ArrayList(sdl.Rect) = .empty;
    defer stack.deinit(allocator);

    // Push 32 nested scissor levels
    var i: i32 = 0;
    while (i < 32) : (i += 1) {
        const sc = sdl.Rect{ .x = i, .y = i, .w = 500 - i, .h = 500 - i };
        const eff = if (stack.items.len > 0)
            intersectScissor(stack.items[stack.items.len - 1], sc)
        else
            sc;
        try stack.append(allocator, eff);
    }

    try std.testing.expectEqual(@as(usize, 32), stack.items.len);
    try std.testing.expectEqual(@as(i32, 31), stack.items[31].x);

    // Pop all levels back down
    while (stack.items.len > 0) {
        _ = stack.pop();
    }
    try std.testing.expectEqual(@as(usize, 0), stack.items.len);
}

test "shouldCycleFrameBuffer cycles reused buffers on first frame write" {
    // Reused buffer at offset 0 (first sub-allocation of frame) must cycle
    try std.testing.expect(shouldCycleFrameBuffer(false, 0));
    // Reused buffer at non-zero offset must NOT cycle (preserves earlier data)
    try std.testing.expect(!shouldCycleFrameBuffer(false, 512));
    // Freshly reallocated buffer must NOT cycle even at offset 0
    try std.testing.expect(!shouldCycleFrameBuffer(true, 0));
    try std.testing.expect(!shouldCycleFrameBuffer(true, 512));
}

test "findBlurSplit pairs initialized resources with blurred_surface index" {
    const dummy_tex: sdl.gpu.Texture = .{ .ptr = @ptrFromInt(0x1000) };
    const batches = [_]BatchItem{
        .{
            .vertex_start = 0,
            .vertex_count = 6,
            .texture = dummy_tex,
            .material = .ui_element,
            .scissor = null,
        },
        .{
            .vertex_start = 6,
            .vertex_count = 6,
            .texture = dummy_tex,
            .material = .blurred_surface,
            .scissor = null,
        },
        .{
            .vertex_start = 12,
            .vertex_count = 6,
            .texture = dummy_tex,
            .material = .ui_element,
            .scissor = null,
        },
    };

    try std.testing.expect(findBlurSplit(&batches, .uninitialized) == null);
    try std.testing.expect(findBlurSplit(&batches, .failed) == null);
    try std.testing.expect(findBlurSplit(&batches, .{
        .pipelines_ready = .{
            .down = .{ .ptr = @ptrFromInt(0x2001) },
            .up = .{ .ptr = @ptrFromInt(0x2002) },
        },
    }) == null);

    const init_res = BlurResources.Initialized{
        .pipelines = .{
            .down = .{ .ptr = @ptrFromInt(0x2001) },
            .up = .{ .ptr = @ptrFromInt(0x2002) },
        },
        .textures = .{
            .scene = .{ .ptr = @ptrFromInt(0x2003) },
            .blur_down = .{ .ptr = @ptrFromInt(0x2004) },
            .blur = .{ .ptr = @ptrFromInt(0x2005) },
            .target_w = 800,
            .target_h = 600,
            .target_format = .rgba8_unorm,
            .down_w = 200,
            .down_h = 150,
        },
    };
    const blur_res: BlurResources = .{ .initialized = init_res };

    const split = findBlurSplit(&batches, blur_res).?;
    try std.testing.expectEqual(@as(usize, 1), split.split_idx);
    try std.testing.expectEqual(@as(u32, 800), split.blur.textures.target_w);

    // No blurred_surface in batch slice returns null even when initialized
    try std.testing.expect(findBlurSplit(batches[0..1], blur_res) == null);
}
