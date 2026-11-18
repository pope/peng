//! GPU Render Pass Execution and Target Lifecycle Module
//! Provides pure-Zig rendering passes, batched draw call execution, text
//! glyph upload helpers, and swapchain/headless target submission lifecycle.
//! INVARIANT: Code in `src/gpu/pass.zig` MUST NOT depend on `src/ui/`,
//! `src/core/`, or `src/app/`.

const geom = @import("geom");
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
const DpiScale = geom.DpiScale;
const FontSizePage = text_cache.FontSizePage;
const GlyphCacheKey = text_cache.GlyphCacheKey;
const GlyphCacheValue = text_cache.GlyphCacheValue;
const ImageUniforms = render_image.ImageUniforms;
const MaterialType = render_image.MaterialType;
const PhysicalDims = geom.PhysicalDims;
const PositiveDimsU32 = geom.PositiveDimsU32;
const Rect = geom.Rect;
const RenderResources = graphics.RenderResources;
const saveTextureToPng = graphics.saveTextureToPng;
const UiUniforms = render_image.UiUniforms;
const Vertex = geometry.Vertex;
const ViewportParams = state.ViewportParams;

/// Presentation target for a rendered frame: either a native swapchain
/// window or a headless offscreen render target with physical pixel dimensions.
pub const FrameTarget = union(enum) {
    window: sdl.Window,
    headless: PhysicalDims,
};

/// Context provided by `executeFrame` to the UI packet builder during
/// Pass 1 (geometry and glyph upload recording).
pub const PacketBuildContext = struct {
    gpu_res: *RenderResources,
    copy_pass: sdl.gpu.CopyPass,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    physical_dims: PhysicalDims,
    scale: DpiScale,
    gpa_allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
};

/// Target options and parameters for frame execution and presentation.
pub const FrameTargetOptions = struct {
    target: FrameTarget,
    scale: DpiScale = .{},
    needs_blur: bool = false,
    capture_filename: ?[:0]const u8 = null,
};

/// Total pass duration, active GPU command encoding duration, and swapchain
/// acquisition wait duration returned by `executeFrame` in milliseconds.
pub const PassTimings = struct {
    total_pass_ms: f64 = 0.0,
    gpu_encode_ms: f64 = 0.0,
    swapchain_wait_ms: f64 = 0.0,
};

fn buildPassTimings(
    pass_start_ns: u64,
    pass_end_ns: u64,
    swapchain_wait_ns: u64,
) PassTimings {
    const total_pass_ns = pass_end_ns -| pass_start_ns;
    const gpu_encode_ns = total_pass_ns -| swapchain_wait_ns;
    return .{
        .total_pass_ms = state.nsToMs(total_pass_ns),
        .gpu_encode_ms = state.nsToMs(gpu_encode_ns),
        .swapchain_wait_ms = state.nsToMs(swapchain_wait_ns),
    };
}

fn scissorEqual(a: ?Rect, b: ?Rect) bool {
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
pub fn intersectScissor(a: Rect, b: Rect) Rect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x +| a.w, b.x +| b.w);
    const y2 = @min(a.y +| a.h, b.y +| b.h);
    return Rect{
        .x = x1,
        .y = y1,
        .w = @max(0, x2 -| x1),
        .h = @max(0, y2 -| y1),
    };
}

/// Clips a scissor rectangle to positive render target dimensions, returning
/// `null` if the resulting region has non-positive width or height.
pub fn clipScissorToTarget(sc: Rect, target_dims: PositiveDimsU32) ?Rect {
    const win_w: i32 = @intCast(@min(target_dims.w, std.math.maxInt(i32)));
    const win_h: i32 = @intCast(@min(target_dims.h, std.math.maxInt(i32)));
    const clipped = intersectScissor(sc, .{
        .x = 0,
        .y = 0,
        .w = win_w,
        .h = win_h,
    });
    if (clipped.w <= 0 or clipped.h <= 0) return null;
    return clipped;
}

/// Returns true if scissor box has non-positive area or falls outside window.
pub inline fn isScissorInvisible(sc: ?Rect, win_dims: PhysicalDims) bool {
    if (win_dims.w <= 0.0 or win_dims.h <= 0.0) return true;
    if (sc) |s| {
        const sw: f32 = @floatFromInt(s.w);
        const sh: f32 = @floatFromInt(s.h);
        const sx: f32 = @floatFromInt(s.x);
        const sy: f32 = @floatFromInt(s.y);
        if (s.w <= 0 or s.h <= 0) return true;
        if (sx >= win_dims.w or sy >= win_dims.h) return true;
        if (sx + sw <= 0.0 or sy + sh <= 0.0) return true;
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
    scissor: ?Rect,
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

/// Ensures the unified `1024x1024` UI and font glyph atlas texture exists on
/// `build_ctx.gpu_res.text_cache`, initializing its top-left `4x4` white
/// block on first creation. Falls back to `build_ctx.gpu_res.white_texture`
/// if texture allocation fails.
pub fn ensureUiAtlasTexture(
    build_ctx: PacketBuildContext,
) sdl.gpu.Texture {
    const gpu_res = build_ctx.gpu_res;
    if (gpu_res.text_cache.atlas_texture) |tex| return tex;

    const dev = gpu_res.device;
    const tex_info = sdl.gpu.TextureCreateInfo{
        .type = .type_2d,
        .format = .rgba8_unorm,
        .usage = sdl.gpu.TextureUsage.sampler,
        .width = text_cache.atlas_size,
        .height = text_cache.atlas_size,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = .count_1,
        .props = 0,
    };
    const tex = dev.createTexture(&tex_info) orelse
        return gpu_res.white_texture;

    const wb_size = text_cache.white_block_size;
    const wb_bytes = wb_size * wb_size * 4;
    const transfer_buf = dev.createTransferBuffer(
        &sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = wb_bytes,
            .props = 0,
        },
    ) orelse {
        dev.releaseTexture(tex);
        return gpu_res.white_texture;
    };
    build_ctx.temp_buffers.append(
        build_ctx.frame_allocator,
        transfer_buf,
    ) catch {
        dev.releaseTransferBuffer(transfer_buf);
        dev.releaseTexture(tex);
        return gpu_res.white_texture;
    };

    const mapped_raw = dev.mapTransferBuffer(transfer_buf, false) orelse {
        dev.releaseTexture(tex);
        return gpu_res.white_texture;
    };
    @memset(mapped_raw[0..wb_bytes], 255);
    dev.unmapTransferBuffer(transfer_buf);

    build_ctx.copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = wb_size,
        .rows_per_layer = wb_size,
    }, &sdl.gpu.TextureRegion{
        .texture = tex,
        .x = 0,
        .y = 0,
        .w = wb_size,
        .h = wb_size,
        .d = 1,
    }, false);

    gpu_res.text_cache.atlas_texture = tex;
    gpu_res.text_cache.packer.reset();
    return tex;
}

/// Returns or initializes the direct-indexed `FontSizePage` for
/// `(font_id, target_font_size_u16)`, querying `font.getHeight()` only when the
/// page is first created.
pub fn ensureFontSizePage(
    build_ctx: PacketBuildContext,
    font_id: u16,
    target_font_size: f32,
    target_font_size_u16: u16,
) ?*FontSizePage {
    if (build_ctx.gpu_res.text_cache.findPageMut(
        font_id,
        target_font_size_u16,
    )) |page| {
        return page;
    }

    const fonts = build_ctx.gpu_res.fonts[0..];
    if (font_id >= fonts.len) return null;
    const font = fonts[font_id] orelse return null;
    if (font.getFontSize() != target_font_size) {
        _ = font.setFontSize(target_font_size);
    }
    const line_h: f32 = @floatFromInt(@max(0, font.getHeight()));
    return build_ctx.gpu_res.text_cache.getOrCreatePage(
        font_id,
        target_font_size_u16,
        line_h,
    );
}

/// Retrieves a cached glyph entry from the unified atlas or rasterizes and
/// uploads `codepoint` into the atlas on a cache miss. Color and alpha are
/// modulated dynamically at draw time via GPU vertex color attributes.
pub fn getOrRasterizeGlyph(
    build_ctx: PacketBuildContext,
    font_id: u16,
    target_font_size: f32,
    target_font_size_u16: u16,
    codepoint: u32,
) !?GlyphCacheValue {
    const gpu_res = build_ctx.gpu_res;
    const key = GlyphCacheKey{
        .font_id = font_id,
        .font_size = target_font_size_u16,
        .codepoint = codepoint,
    };

    if (gpu_res.text_cache.getGlyph(key)) |cached| {
        return cached;
    }

    const fonts = gpu_res.fonts[0..];
    if (font_id >= fonts.len) return null;
    const font = fonts[font_id] orelse return null;

    if (font.getFontSize() != target_font_size) {
        _ = font.setFontSize(target_font_size);
    }

    const metrics = font.getGlyphMetrics(codepoint) orelse return null;
    const advance: f32 = @floatFromInt(metrics.advance);
    const offset_x: f32 = @floatFromInt(@min(0, metrics.minx));

    if (metrics.maxx <= metrics.minx or metrics.maxy <= metrics.miny) {
        const val = GlyphCacheValue{
            .advance = advance,
            .has_pixels = false,
        };
        try gpu_res.text_cache.putGlyph(build_ctx.gpa_allocator, key, val);
        return val;
    }

    const atlas_tex = ensureUiAtlasTexture(build_ctx);
    if (atlas_tex.eql(gpu_res.white_texture)) return null;

    const surf = font.renderGlyphBlended(
        codepoint,
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    ) orelse return null;
    defer surf.destroy();

    const converted = surf.convert(sdl.PixelFormat.rgba32) orelse
        return null;
    defer converted.destroy();

    const surf_w: u32 = @intCast(@max(0, converted.w()));
    const surf_h: u32 = @intCast(@max(0, converted.h()));
    if (surf_w == 0 or surf_h == 0) {
        const val = GlyphCacheValue{
            .advance = advance,
            .has_pixels = false,
        };
        try gpu_res.text_cache.putGlyph(build_ctx.gpa_allocator, key, val);
        return val;
    }

    const alloc_w = surf_w + 2;
    const alloc_h = surf_h + 2;
    const pos = gpu_res.text_cache.packer.allocate(alloc_w, alloc_h) orelse
        blk: {
            gpu_res.text_cache.resetAtlas();
            break :blk gpu_res.text_cache.packer.allocate(
                alloc_w,
                alloc_h,
            ) orelse return null;
        };

    const dev = gpu_res.device;
    const size: usize = @as(usize, alloc_w) * @as(usize, alloc_h) * 4;
    const transfer_buf = dev.createTransferBuffer(
        &sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = @intCast(size),
            .props = 0,
        },
    ) orelse return null;
    build_ctx.temp_buffers.append(
        build_ctx.frame_allocator,
        transfer_buf,
    ) catch |err| {
        dev.releaseTransferBuffer(transfer_buf);
        return err;
    };

    const mapped_raw = dev.mapTransferBuffer(transfer_buf, false) orelse
        return null;
    const mapped_u32: [*]u32 = @ptrCast(@alignCast(mapped_raw));
    @memset(mapped_u32[0 .. size / 4], 0x00FFFFFF);

    const src_row_bytes: usize = @as(usize, surf_w) * 4;
    const dst_row_bytes: usize = @as(usize, alloc_w) * 4;
    const pitch: usize = @intCast(converted.pitch());

    var row_y: usize = 0;
    while (row_y < surf_h) : (row_y += 1) {
        const src_start = row_y * pitch;
        const src_row =
            converted.pixels()[src_start .. src_start + src_row_bytes];
        const dst_offset = (row_y + 1) * dst_row_bytes + 4;
        const dst_row = mapped_raw[dst_offset..][0..src_row_bytes];
        @memcpy(dst_row, src_row);
    }
    dev.unmapTransferBuffer(transfer_buf);

    build_ctx.copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = alloc_w,
        .rows_per_layer = alloc_h,
    }, &sdl.gpu.TextureRegion{
        .texture = atlas_tex,
        .x = pos.x,
        .y = pos.y,
        .w = alloc_w,
        .h = alloc_h,
        .d = 1,
    }, false);

    const atlas_f: f32 = @floatFromInt(text_cache.atlas_size);
    const inner_x = pos.x + 1;
    const inner_y = pos.y + 1;
    const val = GlyphCacheValue{
        .u1 = @as(f32, @floatFromInt(inner_x)) / atlas_f,
        .v1 = @as(f32, @floatFromInt(inner_y)) / atlas_f,
        .u2 = @as(f32, @floatFromInt(inner_x + surf_w)) / atlas_f,
        .v2 = @as(f32, @floatFromInt(inner_y + surf_h)) / atlas_f,
        .w = @floatFromInt(surf_w),
        .h = @floatFromInt(surf_h),
        .offset_x = offset_x,
        .advance = advance,
        .has_pixels = true,
    };

    try gpu_res.text_cache.putGlyph(build_ctx.gpa_allocator, key, val);
    return val;
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
    target_dims: PositiveDimsU32,
) void {
    var last_pipeline: ?sdl.gpu.Pipeline = null;
    var last_material: ?MaterialType = null;
    const win_w: i32 = @intCast(target_dims.w);
    const win_h: i32 = @intCast(target_dims.h);

    for (batches) |batch| {
        if (batch.scissor) |sc| {
            const safe_sc = clipScissorToTarget(sc, target_dims) orelse
                continue;
            render_pass.setScissor(
                safe_sc.x,
                safe_sc.y,
                safe_sc.w,
                safe_sc.h,
            );
        } else {
            render_pass.setScissor(0, 0, win_w, win_h);
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
    target_dims: PositiveDimsU32,
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
            target_dims,
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
    src_dims: PositiveDimsU32,
    dst_dims: PositiveDimsU32,
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
        .texel_size_x = 1.0 / @as(f32, @floatFromInt(src_dims.w)),
        .texel_size_y = 1.0 / @as(f32, @floatFromInt(src_dims.h)),
        .radius = radius,
        .padding = 0.0,
    };
    cmd_buf.pushFragmentUniform(0, std.mem.asBytes(&ubo));
    pass.bindFragmentSamplers(0, &[_]sdl.gpu.TextureSamplerBinding{.{
        .texture = source_tex,
        .sampler = gpu.sampler,
    }});

    pass.setScissor(0, 0, @intCast(dst_dims.w), @intCast(dst_dims.h));
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
    target_dims: PositiveDimsU32,
) void {
    const split = findBlurSplit(batches, gpu.blur) orelse {
        _ = renderBatchPass(
            view_params,
            gpu,
            cmd_buf,
            swap_tex,
            batches,
            vert_buf,
            target_dims,
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
        tex.target_dims,
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
        tex.target_dims,
        tex.down_dims,
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
        tex.down_dims,
        tex.down_dims,
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
        final_pass.setScissor(
            0,
            0,
            @intCast(target_dims.w),
            @intCast(target_dims.h),
        );
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
                target_dims,
            );
        }
    }
}

fn executeRenderPacket(
    view_params: ViewportParams,
    gpu_res: *RenderResources,
    cmd_buf: sdl.gpu.CommandBuffer,
    copy_pass: sdl.gpu.CopyPass,
    swap_tex: sdl.gpu.Texture,
    packet: *const RenderPacket,
    frame_allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    target_dims: PositiveDimsU32,
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
        target_dims,
    );
}

/// Orchestrates command buffer acquisition, swapchain vs headless target
/// binding, invocation of render callback, screenshot capture, and fence sync.
/// Returns pass, active GPU encoding, and swapchain wait timings in ms.
pub fn executeFrame(
    gpu_res: *RenderResources,
    view_params: ViewportParams,
    gpa_allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    target: FrameTargetOptions,
    context: anytype,
    comptime build_packet_fn: fn (
        ctx: @TypeOf(context),
        build_ctx: PacketBuildContext,
    ) anyerror!RenderPacket,
) !PassTimings {
    const pass_start_ns = sdl.timer.getTicksNs();
    var swapchain_wait_ns: u64 = 0;

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

    const is_headless = switch (target.target) {
        .headless => true,
        .window => false,
    };

    var target_tex: ?sdl.gpu.Texture = null;
    var target_w: u32 = 0;
    var target_h: u32 = 0;
    var target_format: sdl.gpu.TextureFormat = .invalid;

    const safe_scale = DpiScale.init(target.scale.x, target.scale.y);
    switch (target.target) {
        .headless => |phys_dims| {
            if (phys_dims.toPositiveU32()) |pos| {
                target_w = pos.w;
                target_h = pos.h;
            } else {
                target_w = 1;
                target_h = 1;
            }
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
        },
        .window => |win| {
            var swap_w: u32 = 0;
            var swap_h: u32 = 0;
            const wait_start_ns = sdl.timer.getTicksNs();
            const swap_opt = win.waitAndAcquireSwapchainTexture(
                cmd_buf,
                &swap_w,
                &swap_h,
            );
            const wait_end_ns = sdl.timer.getTicksNs();
            swapchain_wait_ns = wait_end_ns -| wait_start_ns;
            if (swap_opt) |st| {
                target_tex = st;
                target_w = swap_w;
                target_h = swap_h;
                target_format = dev.getSwapchainTextureFormat(win);
            }
        },
    }

    defer if (is_headless) {
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
            const pass_end_ns = sdl.timer.getTicksNs();
            return buildPassTimings(
                pass_start_ns,
                pass_end_ns,
                swapchain_wait_ns,
            );
        }

        const target_dims = PositiveDimsU32{
            .w = target_w,
            .h = target_h,
        };

        if (target.needs_blur) {
            gpu_res.blur.ensure(dev, target_dims, target_format);
        }

        const copy_pass = cmd_buf.beginCopyPass() orelse {
            std.log.err(
                "SDL GPU beginCopyPass failed: {s}",
                .{sdl.getError()},
            );
            return error.GPUCopyPassFailed;
        };
        errdefer copy_pass.end();

        var packet = try build_packet_fn(context, .{
            .gpu_res = gpu_res,
            .copy_pass = copy_pass,
            .temp_buffers = &temp_buffers,
            .physical_dims = .{
                .w = @floatFromInt(target_w),
                .h = @floatFromInt(target_h),
            },
            .scale = safe_scale,
            .gpa_allocator = gpa_allocator,
            .frame_allocator = frame_allocator,
        });
        defer packet.deinit(frame_allocator);

        const vertex_count = packet.vertices.items.len;
        const batch_count = packet.batches.items.len;

        try executeRenderPacket(
            view_params,
            gpu_res,
            cmd_buf,
            copy_pass,
            tex,
            &packet,
            frame_allocator,
            &temp_buffers,
            target_dims,
        );

        gpu_res.metrics.last_ui_vertex_count = vertex_count;
        gpu_res.metrics.last_ui_batch_count = batch_count;
        gpu_res.frame_index += 1;

        if (target.capture_filename) |filename| {
            cmd_buf_submitted = true;
            try saveTextureToPng(
                dev,
                cmd_buf,
                tex,
                target_dims,
                target_format,
                filename,
            );
        } else if (is_headless) {
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
    const pass_end_ns = sdl.timer.getTicksNs();
    return buildPassTimings(pass_start_ns, pass_end_ns, swapchain_wait_ns);
}

test "intersectScissor computes correct overlapping rectangle" {
    const a = Rect{ .x = 10, .y = 20, .w = 100, .h = 100 };
    const b = Rect{ .x = 50, .y = 60, .w = 100, .h = 100 };
    const res = intersectScissor(a, b);
    try std.testing.expectEqual(@as(i32, 50), res.x);
    try std.testing.expectEqual(@as(i32, 60), res.y);
    try std.testing.expectEqual(@as(i32, 60), res.w);
    try std.testing.expectEqual(@as(i32, 60), res.h);

    // Disjoint rectangles
    const c = Rect{ .x = 200, .y = 200, .w = 50, .h = 50 };
    const disjoint = intersectScissor(a, c);
    try std.testing.expectEqual(@as(i32, 0), disjoint.w);
    try std.testing.expectEqual(@as(i32, 0), disjoint.h);

    // Negative coordinates and partial overlap
    const neg1 = Rect{ .x = -20, .y = -20, .w = 50, .h = 50 };
    const neg2 = Rect{ .x = 0, .y = 0, .w = 50, .h = 50 };
    const neg_res = intersectScissor(neg1, neg2);
    try std.testing.expectEqual(@as(i32, 0), neg_res.x);
    try std.testing.expectEqual(@as(i32, 0), neg_res.y);
    try std.testing.expectEqual(@as(i32, 30), neg_res.w);
    try std.testing.expectEqual(@as(i32, 30), neg_res.h);
}

test "clipScissorToTarget clamps both width and height during window resize" {
    const target = PositiveDimsU32{ .w = 800, .h = 500 };

    // Scissor taller and wider than swapchain target (window shrank on resize)
    const oversized = Rect{ .x = 0, .y = 0, .w = 1000, .h = 700 };
    const clipped = clipScissorToTarget(oversized, target).?;
    try std.testing.expectEqual(@as(i32, 0), clipped.x);
    try std.testing.expectEqual(@as(i32, 0), clipped.y);
    try std.testing.expectEqual(@as(i32, 800), clipped.w);
    try std.testing.expectEqual(@as(i32, 500), clipped.h);

    // Offset scissor overflowing bottom-right edge
    const offset_sc = Rect{ .x = 600, .y = 350, .w = 300, .h = 250 };
    const clipped_offset = clipScissorToTarget(offset_sc, target).?;
    try std.testing.expectEqual(@as(i32, 600), clipped_offset.x);
    try std.testing.expectEqual(@as(i32, 350), clipped_offset.y);
    try std.testing.expectEqual(@as(i32, 200), clipped_offset.w);
    try std.testing.expectEqual(@as(i32, 150), clipped_offset.h);

    // Negative origin extending past target
    const neg_sc = Rect{ .x = -50, .y = -100, .w = 900, .h = 700 };
    const clipped_neg = clipScissorToTarget(neg_sc, target).?;
    try std.testing.expectEqual(@as(i32, 0), clipped_neg.x);
    try std.testing.expectEqual(@as(i32, 0), clipped_neg.y);
    try std.testing.expectEqual(@as(i32, 800), clipped_neg.w);
    try std.testing.expectEqual(@as(i32, 500), clipped_neg.h);

    // Completely outside target returns null
    const out_right = Rect{ .x = 800, .y = 0, .w = 100, .h = 100 };
    const out_bottom = Rect{ .x = 0, .y = 500, .w = 100, .h = 100 };
    try std.testing.expect(clipScissorToTarget(out_right, target) == null);
    try std.testing.expect(clipScissorToTarget(out_bottom, target) == null);
}

test "scissorEqual compares rectangles correctly" {
    const r1 = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    const r2 = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    const r3 = Rect{ .x = 11, .y = 20, .w = 30, .h = 40 };

    try std.testing.expect(scissorEqual(null, null));
    try std.testing.expect(!scissorEqual(null, r1));
    try std.testing.expect(!scissorEqual(r1, null));
    try std.testing.expect(scissorEqual(r1, r2));
    try std.testing.expect(!scissorEqual(r1, r3));
}

test "isScissorInvisible detects non-visible scissor bounds" {
    const full_dims = PhysicalDims{ .w = 1000.0, .h = 800.0 };

    // Null scissor is visible (covers full window)
    try std.testing.expect(!isScissorInvisible(null, full_dims));

    // Zero or negative window dimensions
    try std.testing.expect(isScissorInvisible(
        null,
        PhysicalDims{ .w = 0.0, .h = 800.0 },
    ));
    try std.testing.expect(isScissorInvisible(
        null,
        PhysicalDims{ .w = 1000.0, .h = -10.0 },
    ));

    // Normal visible scissor
    const vis = Rect{ .x = 10, .y = 10, .w = 100, .h = 100 };
    try std.testing.expect(!isScissorInvisible(vis, full_dims));

    // Zero or negative area
    const zero_w = Rect{ .x = 10, .y = 10, .w = 0, .h = 100 };
    try std.testing.expect(isScissorInvisible(zero_w, full_dims));
    const neg_h = Rect{ .x = 10, .y = 10, .w = 100, .h = -5 };
    try std.testing.expect(isScissorInvisible(neg_h, full_dims));

    // Off-screen to right/bottom
    const off_r = Rect{ .x = 1000, .y = 10, .w = 100, .h = 100 };
    try std.testing.expect(isScissorInvisible(off_r, full_dims));
    const off_b = Rect{ .x = 10, .y = 800, .w = 100, .h = 100 };
    try std.testing.expect(isScissorInvisible(off_b, full_dims));

    // Off-screen to left/top
    const off_l = Rect{ .x = -100, .y = 10, .w = 100, .h = 100 };
    try std.testing.expect(isScissorInvisible(off_l, full_dims));
    const off_t = Rect{ .x = 10, .y = -100, .w = 100, .h = 100 };
    try std.testing.expect(isScissorInvisible(off_t, full_dims));
}

test "scissor stack dynamically grows beyond 16 levels with arena allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stack: std.ArrayList(Rect) = .empty;
    defer stack.deinit(allocator);

    // Push 32 nested scissor levels
    var i: i32 = 0;
    while (i < 32) : (i += 1) {
        const sc = Rect{ .x = i, .y = i, .w = 500 - i, .h = 500 - i };
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
            .target_dims = .{ .w = 800, .h = 600 },
            .target_format = .rgba8_unorm,
            .down_dims = .{ .w = 200, .h = 150 },
        },
    };
    const blur_res: BlurResources = .{ .initialized = init_res };

    const split = findBlurSplit(&batches, blur_res).?;
    try std.testing.expectEqual(@as(usize, 1), split.split_idx);
    try std.testing.expectEqual(
        @as(u32, 800),
        split.blur.textures.target_dims.w,
    );

    // No blurred_surface in batch slice returns null even when initialized
    try std.testing.expect(findBlurSplit(batches[0..1], blur_res) == null);
}

test "buildPassTimings subtracts swapchain wait saturating safely" {
    const t = buildPassTimings(1_000_000, 18_500_000, 16_000_000);
    try std.testing.expectEqual(@as(f64, 17.5), t.total_pass_ms);
    try std.testing.expectEqual(@as(f64, 1.5), t.gpu_encode_ms);
    try std.testing.expectEqual(@as(f64, 16.0), t.swapchain_wait_ms);

    // Clock anomaly / wait exceeding total pass duration saturates to 0.0.
    const clamped = buildPassTimings(2_000_000, 1_000_000, 5_000_000);
    try std.testing.expectEqual(@as(f64, 0.0), clamped.total_pass_ms);
    try std.testing.expectEqual(@as(f64, 0.0), clamped.gpu_encode_ms);
    try std.testing.expectEqual(@as(f64, 5.0), clamped.swapchain_wait_ms);
}
