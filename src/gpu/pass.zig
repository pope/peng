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
const downloadTexture = graphics.downloadTexture;
const DpiScale = geom.DpiScale;
const FontSizePage = text_cache.FontSizePage;
const GlyphCacheKey = text_cache.GlyphCacheKey;
const GlyphCacheValue = text_cache.GlyphCacheValue;
const ImageUniforms = render_image.ImageUniforms;
const MappedReadback = graphics.MappedReadback;
const MaterialType = render_image.MaterialType;
const PhysicalDims = geom.PhysicalDims;
const PositiveDimsU32 = geom.PositiveDimsU32;
const Rect = geom.Rect;
const RenderResources = graphics.RenderResources;
const saveReadbackToPng = graphics.saveReadbackToPng;
const UiQuadInstance = geometry.UiQuadInstance;
const UiSdfVertUniforms = geometry.UiSdfVertUniforms;
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

/// Total pass duration, active GPU command encoding duration, swapchain
/// acquisition wait duration, and optional window swapchain submission
/// timestamp returned by `executeFrame`.
pub const PassTimings = struct {
    total_pass_ms: f64 = 0.0,
    gpu_encode_ms: f64 = 0.0,
    swapchain_wait_ms: f64 = 0.0,
    swapchain_present_ts: ?std.Io.Timestamp = null,
};

/// Rendered offscreen frame readback plus pass timings returned by
/// `executeOffscreenReadback`. Caller must call `readback.deinit()` before
/// reusing `gpu_res.download_buffer` on a subsequent frame.
pub const OffscreenFrameResult = struct {
    readback: MappedReadback,
    timings: PassTimings,
};

const FrameCapture = union(enum) {
    none,
    png_file: [:0]const u8,
    readback: *?MappedReadback,

    fn isRequested(self: FrameCapture) bool {
        return switch (self) {
            .none => false,
            .png_file, .readback => true,
        };
    }
};

fn buildPassTimings(
    total_pass: std.Io.Duration,
    swapchain_wait: std.Io.Duration,
    swapchain_present_ts: ?std.Io.Timestamp,
) PassTimings {
    return .{
        .total_pass_ms = state.durationToMs(total_pass),
        .gpu_encode_ms = state.activeDurationMs(total_pass, swapchain_wait),
        .swapchain_wait_ms = state.durationToMs(swapchain_wait),
        .swapchain_present_ts = swapchain_present_ts,
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
        .format = .r8_unorm,
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
    const wb_bytes = wb_size * wb_size;
    const upload = gpu_res.text_cache.acquireGlyphUpload(
        dev,
        wb_bytes,
        build_ctx.frame_allocator,
        build_ctx.temp_buffers,
    ) orelse {
        dev.releaseTexture(tex);
        return gpu_res.white_texture;
    };

    const mapped_raw = dev.mapTransferBuffer(
        upload.buffer,
        upload.cycle,
    ) orelse {
        dev.releaseTexture(tex);
        return gpu_res.white_texture;
    };
    @memset(mapped_raw[upload.offset .. upload.offset + wb_bytes], 255);
    dev.unmapTransferBuffer(upload.buffer);

    build_ctx.copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
        .transfer_buffer = upload.buffer,
        .offset = @intCast(upload.offset),
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
    if (codepoint >= 0x80) {
        gpu_res.ensureFallbackFont(font_id);
    }
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

    // Scan alpha channel to crop to tight ink bounds (eliminates empty
    // ascender/descender padding inside the R8 glyph atlas).
    const pitch: usize = @intCast(converted.pitch());
    const pixels = converted.pixels();
    var min_x: u32 = surf_w;
    var max_x: u32 = 0;
    var min_y: u32 = surf_h;
    var max_y: u32 = 0;
    var scan_y: u32 = 0;
    while (scan_y < surf_h) : (scan_y += 1) {
        const row_base = @as(usize, scan_y) * pitch;
        var scan_x: u32 = 0;
        while (scan_x < surf_w) : (scan_x += 1) {
            if (pixels[row_base + @as(usize, scan_x) * 4 + 3] != 0) {
                min_x = @min(min_x, scan_x);
                max_x = @max(max_x, scan_x);
                min_y = @min(min_y, scan_y);
                max_y = @max(max_y, scan_y);
            }
        }
    }
    if (min_x > max_x or min_y > max_y) {
        const val = GlyphCacheValue{
            .advance = advance,
            .has_pixels = false,
        };
        try gpu_res.text_cache.putGlyph(build_ctx.gpa_allocator, key, val);
        return val;
    }

    const tight_w = max_x - min_x + 1;
    const tight_h = max_y - min_y + 1;
    const alloc_w = tight_w + 2;
    const alloc_h = tight_h + 2;
    const pos = gpu_res.text_cache.packer.allocate(alloc_w, alloc_h) orelse
        blk: {
            gpu_res.text_cache.resetAtlas();
            break :blk gpu_res.text_cache.packer.allocate(
                alloc_w,
                alloc_h,
            ) orelse return null;
        };

    const dev = gpu_res.device;
    const size: usize = @as(usize, alloc_w) * @as(usize, alloc_h);
    const upload = gpu_res.text_cache.acquireGlyphUpload(
        dev,
        size,
        build_ctx.frame_allocator,
        build_ctx.temp_buffers,
    ) orelse return null;

    const mapped_raw = dev.mapTransferBuffer(
        upload.buffer,
        upload.cycle,
    ) orelse return null;
    const dst_slice = mapped_raw[upload.offset .. upload.offset + size];
    @memset(dst_slice, 0);

    var row_y: u32 = 0;
    while (row_y < tight_h) : (row_y += 1) {
        const src_row = @as(usize, min_y + row_y) * pitch;
        const dst_row = @as(usize, row_y + 1) * @as(usize, alloc_w) + 1;
        var col_x: u32 = 0;
        while (col_x < tight_w) : (col_x += 1) {
            dst_slice[dst_row + col_x] =
                pixels[src_row + @as(usize, min_x + col_x) * 4 + 3];
        }
    }
    dev.unmapTransferBuffer(upload.buffer);

    build_ctx.copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
        .transfer_buffer = upload.buffer,
        .offset = @intCast(upload.offset),
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
        .u2 = @as(f32, @floatFromInt(inner_x + tight_w)) / atlas_f,
        .v2 = @as(f32, @floatFromInt(inner_y + tight_h)) / atlas_f,
        .w = @floatFromInt(tight_w),
        .h = @floatFromInt(tight_h),
        .offset_x = offset_x + @as(f32, @floatFromInt(min_x)),
        .offset_y = @floatFromInt(min_y),
        .advance = advance,
        .has_pixels = true,
    };

    try gpu_res.text_cache.putGlyph(build_ctx.gpa_allocator, key, val);
    return val;
}

/// Data-driven render packet holding geometry vertices, instanced SDF UI
/// quads, batch draw calls, and transfer buffer offsets for 2-pass UI frame
/// rendering.
pub const RenderPacket = struct {
    vertices: std.ArrayList(Vertex) = .empty,
    instances: std.ArrayList(UiQuadInstance) = .empty,
    batches: std.ArrayList(BatchItem) = .empty,
    tb_offset: usize = 0,

    /// Releases vertex, instance, and batch command memory.
    pub fn deinit(self: *RenderPacket, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.instances.deinit(allocator);
        self.batches.deinit(allocator);
    }
};

const FrameGeometryBuffer = struct {
    buffer: sdl.gpu.Buffer,
    instance_offset: u32,
};

fn uploadFrameGeometry(
    gpu_res: *RenderResources,
    frame_idx: usize,
    copy_pass: sdl.gpu.CopyPass,
    frame_allocator: std.mem.Allocator,
    temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    vertex_items: []const Vertex,
    instance_items: []const UiQuadInstance,
    tb_offset: usize,
) !?FrameGeometryBuffer {
    const dev = gpu_res.device;
    const vert_bytes = vertex_items.len * @sizeOf(Vertex);
    const inst_offset = std.mem.alignForward(usize, vert_bytes, 64);
    const inst_bytes = instance_items.len * @sizeOf(UiQuadInstance);
    const needed_size = if (inst_bytes > 0)
        inst_offset + inst_bytes
    else
        vert_bytes;
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
    if (vert_bytes > 0) {
        const mapped_v: [*]Vertex = @ptrCast(
            @alignCast(mapped_raw + vert_offset),
        );
        @memcpy(mapped_v[0..vertex_items.len], vertex_items);
    }
    if (inst_bytes > 0) {
        const mapped_i: [*]UiQuadInstance = @ptrCast(
            @alignCast(mapped_raw + vert_offset + inst_offset),
        );
        @memcpy(mapped_i[0..instance_items.len], instance_items);
    }
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

    return .{
        .buffer = vb,
        .instance_offset = @intCast(inst_offset),
    };
}

fn drawBatches(
    view_params: ViewportParams,
    gpu: *RenderResources,
    render_pass: sdl.gpu.RenderPass,
    cmd_buf: sdl.gpu.CommandBuffer,
    batches: []const BatchItem,
    geom_buf: FrameGeometryBuffer,
    target_dims: PositiveDimsU32,
    straight_alpha_replace: bool,
) void {
    const BufferBindingKind = enum {
        vertices,
        instances,
    };
    var last_pipeline: ?sdl.gpu.Pipeline = null;
    var last_binding: ?BufferBindingKind = null;
    var image_ubo_pushed = false;
    var sdf_vert_ubo_pushed = false;
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

        const VertexBatchKind = enum { image, blit, glyph };
        const batch_kind: VertexBatchKind = switch (batch.material) {
            .sdf_ui, .blurred_surface, .overlay_shadow => {
                if (last_pipeline == null or
                    last_pipeline.?.ptr != gpu.sdf_pipeline.ptr)
                {
                    render_pass.bindPipeline(gpu.sdf_pipeline);
                    last_pipeline = gpu.sdf_pipeline;
                }
                if (last_binding != .instances) {
                    render_pass.bindVertexBuffers(
                        0,
                        &[_]sdl.gpu.BufferBinding{.{
                            .buffer = geom_buf.buffer,
                            .offset = geom_buf.instance_offset,
                        }},
                    );
                    last_binding = .instances;
                }
                if (!sdf_vert_ubo_pushed) {
                    const sdf_ubo = UiSdfVertUniforms{
                        .win_dims = .{
                            @floatFromInt(target_dims.w),
                            @floatFromInt(target_dims.h),
                        },
                    };
                    cmd_buf.pushVertexUniform(0, std.mem.asBytes(&sdf_ubo));
                    sdf_vert_ubo_pushed = true;
                }
                render_pass.bindFragmentSamplers(
                    0,
                    &[_]sdl.gpu.TextureSamplerBinding{.{
                        .texture = batch.texture,
                        .sampler = gpu.sampler,
                    }},
                );
                render_pass.drawPrimitives(
                    6,
                    batch.vertex_count,
                    0,
                    batch.vertex_start,
                );
                continue;
            },
            .image_viewer => .image,
            .ui_element => .blit,
            .glyph => .glyph,
        };
        const is_image = (batch_kind == .image);
        const show_original = view_params.compare_original;
        const apply_adj = !show_original and view_params.edits.hasEdits();
        const scale_mode = view_params.getShaderScaleModeInt();
        const needs_full_image_shader = is_image and
            (apply_adj or scale_mode != 1);

        const active_image_pipe = if (is_image)
            (if (straight_alpha_replace)
                (if (needs_full_image_shader)
                    gpu.ensureImagePipelineReplace()
                else
                    gpu.image_pipeline_replace.get())
            else if (needs_full_image_shader)
                gpu.ensureImagePipeline()
            else
                gpu.image_pipeline.get())
        else
            null;
        const use_image_pipeline = (active_image_pipe != null);
        const pipeline = active_image_pipe orelse switch (batch_kind) {
            .glyph => gpu.glyph_pipeline,
            .image, .blit => if (straight_alpha_replace)
                gpu.ensureBlitPipelineReplace() orelse gpu.blit_pipeline
            else
                gpu.blit_pipeline,
        };

        if (last_pipeline == null or last_pipeline.?.ptr != pipeline.ptr) {
            render_pass.bindPipeline(pipeline);
            last_pipeline = pipeline;
        }
        if (last_binding != .vertices) {
            render_pass.bindVertexBuffers(0, &[_]sdl.gpu.BufferBinding{.{
                .buffer = geom_buf.buffer,
                .offset = 0,
            }});
            last_binding = .vertices;
        }

        if (use_image_pipeline and !image_ubo_pushed) {
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
                .scale_mode = scale_mode,
                .has_adjustments = if (apply_adj) 1 else 0,
                .clarity = if (apply_adj) edits.get(.clarity) else 0.0,
                .texture = if (apply_adj) edits.get(.texture) else 0.0,
            };
            cmd_buf.pushFragmentUniform(0, std.mem.asBytes(&img_ubo));
            image_ubo_pushed = true;
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
    var first_shadow_idx: ?usize = null;
    for (batches, 0..) |batch, i| {
        switch (batch.material) {
            .overlay_shadow => {
                if (first_shadow_idx == null) first_shadow_idx = i;
            },
            .blurred_surface => {
                const split_idx = if (first_shadow_idx) |s| @min(s, i) else i;
                return .{ .blur = init_res, .split_idx = split_idx };
            },
            .ui_element, .glyph, .image_viewer, .sdf_ui => {},
        }
    }
    return null;
}

fn renderBatchPass(
    view_params: ViewportParams,
    gpu: *RenderResources,
    cmd_buf: sdl.gpu.CommandBuffer,
    target_tex: sdl.gpu.Texture,
    batches: []const BatchItem,
    geom_buf: ?FrameGeometryBuffer,
    target_dims: PositiveDimsU32,
    clear_color: sdl.gpu.FColor,
) bool {
    const color_target = sdl.gpu.ColorTargetAttachment{
        .texture = target_tex,
        .clear_color = clear_color,
        .load_op = .clear,
        .store_op = .store,
        .cycle = false,
    };

    const render_pass = cmd_buf.beginRenderPass(&color_target) orelse {
        std.log.err("SDL GPU beginRenderPass failed: {s}", .{sdl.getError()});
        return false;
    };
    defer render_pass.end();

    if (geom_buf) |gb| {
        drawBatches(
            view_params,
            gpu,
            render_pass,
            cmd_buf,
            batches,
            gb,
            target_dims,
            clear_color.a == 0.0,
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
        .load_op = .dont_care,
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
    gpu: *RenderResources,
    cmd_buf: sdl.gpu.CommandBuffer,
    swap_tex: sdl.gpu.Texture,
    batches: []const BatchItem,
    geom_buf: ?FrameGeometryBuffer,
    target_dims: PositiveDimsU32,
    clear_color: sdl.gpu.FColor,
) void {
    const split = findBlurSplit(batches, gpu.blur) orelse {
        _ = renderBatchPass(
            view_params,
            gpu,
            cmd_buf,
            swap_tex,
            batches,
            geom_buf,
            target_dims,
            clear_color,
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
        geom_buf,
        tex.target_dims,
        clear_color,
    )) {
        return;
    }

    // Pass 2a: Downsample scene into blur (full -> 1/2 res)
    if (!runBlurFilterPass(
        cmd_buf,
        gpu,
        tex.blur,
        tex.scene,
        pipes.down,
        tex.target_dims,
        tex.half_dims,
        1.0,
    )) {
        return;
    }

    // Pass 2b: Downsample blur into blur_down (1/2 -> 1/4 res)
    if (!runBlurFilterPass(
        cmd_buf,
        gpu,
        tex.blur_down,
        tex.blur,
        pipes.down,
        tex.half_dims,
        tex.down_dims,
        1.5,
    )) {
        return;
    }

    // Pass 3: Upsample blur_down into blur (1/4 -> 1/2 res)
    if (!runBlurFilterPass(
        cmd_buf,
        gpu,
        tex.blur,
        tex.blur_down,
        pipes.up,
        tex.down_dims,
        tex.half_dims,
        2.0,
    )) {
        return;
    }

    // Pass 4: Composite onto swapchain (blit sharp base scene quad + draw
    // remaining overlay batches on top)
    {
        const final_target = sdl.gpu.ColorTargetAttachment{
            .texture = swap_tex,
            .clear_color = clear_color,
            .load_op = if (clear_color.a < 1.0) .clear else .dont_care,
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
        const blit_pipe = if (clear_color.a == 0.0)
            gpu.ensureBlitPipelineReplace() orelse gpu.blit_pipeline
        else
            gpu.blit_pipeline;
        final_pass.bindPipeline(blit_pipe);
        final_pass.bindVertexBuffers(0, &[_]sdl.gpu.BufferBinding{.{
            .buffer = gpu.fullscreen_vertex_buffer,
            .offset = 0,
        }});
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
        if (geom_buf) |gb| {
            drawBatches(
                view_params,
                gpu,
                final_pass,
                cmd_buf,
                batches[idx..],
                gb,
                target_dims,
                false,
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
    clear_color: sdl.gpu.FColor,
) !void {
    const frame_idx = gpu_res.frame_index % 2;

    const geom_buf = try uploadFrameGeometry(
        gpu_res,
        frame_idx,
        copy_pass,
        frame_allocator,
        temp_buffers,
        packet.vertices.items,
        packet.instances.items,
        packet.tb_offset,
    );

    copy_pass.end();

    executeRenderPass(
        view_params,
        gpu_res,
        cmd_buf,
        swap_tex,
        packet.batches.items,
        geom_buf,
        target_dims,
        clear_color,
    );
}

/// Orchestrates command buffer acquisition, swapchain vs headless target
/// binding, invocation of render callback, screenshot capture, and fence sync.
/// Returns `PassTimings` with pass, active GPU encode, and swapchain wait
/// durations in milliseconds plus the optional window swapchain submit
/// timestamp.
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
    const capture: FrameCapture = if (target.capture_filename) |filename|
        .{ .png_file = filename }
    else
        .none;
    return executeFrameImpl(
        gpu_res,
        view_params,
        gpa_allocator,
        frame_allocator,
        target,
        capture,
        context,
        build_packet_fn,
    );
}

/// Renders a headless offscreen frame at `phys_dims` and downloads the
/// rendered `.rgba8_unorm` pixels directly into memory without disk I/O.
/// Caller owns the returned `readback` mapping and must call
/// `result.readback.deinit()` before rendering another readback frame.
pub fn executeOffscreenReadback(
    gpu_res: *RenderResources,
    view_params: ViewportParams,
    gpa_allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    phys_dims: PhysicalDims,
    scale: DpiScale,
    context: anytype,
    comptime build_packet_fn: fn (
        ctx: @TypeOf(context),
        build_ctx: PacketBuildContext,
    ) anyerror!RenderPacket,
) !OffscreenFrameResult {
    var readback: ?MappedReadback = null;
    errdefer if (readback) |rb| rb.deinit();
    const timings = try executeFrameImpl(
        gpu_res,
        view_params,
        gpa_allocator,
        frame_allocator,
        .{
            .target = .{ .headless = phys_dims },
            .scale = scale,
        },
        .{ .readback = &readback },
        context,
        build_packet_fn,
    );
    return .{
        .readback = readback orelse return error.OffscreenReadbackUnavailable,
        .timings = timings,
    };
}

fn executeFrameImpl(
    gpu_res: *RenderResources,
    view_params: ViewportParams,
    gpa_allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    target: FrameTargetOptions,
    capture: FrameCapture,
    context: anytype,
    comptime build_packet_fn: fn (
        ctx: @TypeOf(context),
        build_ctx: PacketBuildContext,
    ) anyerror!RenderPacket,
) !PassTimings {
    const io = gpu_res.io;
    const pass_start = std.Io.Clock.awake.now(io);
    var swapchain_wait: std.Io.Duration = .zero;
    var swapchain_present_ts: ?std.Io.Timestamp = null;

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
            const pos = phys_dims.toPositiveU32() orelse
                PositiveDimsU32{ .w = 1, .h = 1 };
            target_w = pos.w;
            target_h = pos.h;
            target_format = .rgba8_unorm;
            target_tex = try gpu_res.offscreen_target.ensure(
                dev,
                pos,
                target_format,
            );
        },
        .window => |win| {
            var swap_w: u32 = 0;
            var swap_h: u32 = 0;
            const wait_start = std.Io.Clock.awake.now(io);
            const swap_opt = win.waitAndAcquireSwapchainTexture(
                cmd_buf,
                &swap_w,
                &swap_h,
            );
            swapchain_wait = wait_start.untilNow(io, .awake);
            if (swap_opt) |st| {
                target_tex = st;
                target_w = swap_w;
                target_h = swap_h;
                target_format = dev.getSwapchainTextureFormat(win);
            }
        },
    }

    if (target_tex) |tex| {
        if (target_w == 0 or target_h == 0) {
            cmd_buf_submitted = true;
            _ = cmd_buf.submit();
            if (capture.isRequested()) {
                return error.SwapchainTextureUnavailable;
            }
            return buildPassTimings(
                pass_start.untilNow(io, .awake),
                swapchain_wait,
                null,
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
        var copy_pass_ended = false;
        errdefer if (!copy_pass_ended) {
            copy_pass.end();
        };

        gpu_res.text_cache.beginFrameGlyphUploads();

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

        const clear_color: sdl.gpu.FColor = switch (capture) {
            .readback => .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
            .none, .png_file => .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        };

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
            clear_color,
        );
        copy_pass_ended = true;

        gpu_res.metrics.last_ui_vertex_count = vertex_count;
        gpu_res.metrics.last_ui_batch_count = batch_count;
        gpu_res.frame_index += 1;

        switch (capture) {
            .png_file => |filename| {
                cmd_buf_submitted = true;
                const readback = try downloadTexture(
                    dev,
                    cmd_buf,
                    &gpu_res.download_buffer,
                    tex,
                    target_dims,
                    target_format,
                );
                defer readback.deinit();
                try saveReadbackToPng(readback, filename);
            },
            .readback => |out| {
                cmd_buf_submitted = true;
                out.* = try downloadTexture(
                    dev,
                    cmd_buf,
                    &gpu_res.download_buffer,
                    tex,
                    target_dims,
                    target_format,
                );
            },
            .none => if (is_headless) {
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
                if (cmd_buf.submit()) {
                    swapchain_present_ts = std.Io.Clock.awake.now(io);
                }
            },
        }
    } else {
        cmd_buf_submitted = true;
        _ = cmd_buf.submit();
        if (capture.isRequested()) {
            return error.SwapchainTextureUnavailable;
        }
    }
    return buildPassTimings(
        pass_start.untilNow(io, .awake),
        swapchain_wait,
        swapchain_present_ts,
    );
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
            .half_dims = .{ .w = 400, .h = 300 },
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
    const present_ts = std.Io.Timestamp.fromNanoseconds(50_000_000);
    const t = buildPassTimings(
        .{ .nanoseconds = 17_500_000 },
        .{ .nanoseconds = 16_000_000 },
        present_ts,
    );
    try std.testing.expectEqual(@as(f64, 17.5), t.total_pass_ms);
    try std.testing.expectEqual(@as(f64, 1.5), t.gpu_encode_ms);
    try std.testing.expectEqual(@as(f64, 16.0), t.swapchain_wait_ms);
    try std.testing.expectEqual(
        @as(?std.Io.Timestamp, present_ts),
        t.swapchain_present_ts,
    );

    // Clock anomaly / wait exceeding total pass duration saturates to 0.0.
    const clamped = buildPassTimings(
        .{ .nanoseconds = -1_000_000 },
        .{ .nanoseconds = 5_000_000 },
        null,
    );
    try std.testing.expectEqual(@as(f64, 0.0), clamped.total_pass_ms);
    try std.testing.expectEqual(@as(f64, 0.0), clamped.gpu_encode_ms);
    try std.testing.expectEqual(@as(f64, 5.0), clamped.swapchain_wait_ms);
    try std.testing.expectEqual(
        @as(?std.Io.Timestamp, null),
        clamped.swapchain_present_ts,
    );
}

test "findBlurSplit includes leading overlay_shadow in Pass 4b" {
    const dummy_tex = sdl.gpu.Texture{ .ptr = @ptrFromInt(0x1000) };
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
            .half_dims = .{ .w = 400, .h = 300 },
            .down_dims = .{ .w = 200, .h = 150 },
        },
    };
    const blur_res: BlurResources = .{ .initialized = init_res };

    const shadow_only = [_]BatchItem{
        .{
            .vertex_start = 0,
            .vertex_count = 1,
            .texture = dummy_tex,
            .material = .overlay_shadow,
            .scissor = null,
        },
    };
    try std.testing.expectEqual(
        @as(?BlurSplit, null),
        findBlurSplit(&shadow_only, blur_res),
    );

    const shadow_then_blur = [_]BatchItem{
        .{
            .vertex_start = 0,
            .vertex_count = 6,
            .texture = dummy_tex,
            .material = .image_viewer,
            .scissor = null,
        },
        .{
            .vertex_start = 0,
            .vertex_count = 1,
            .texture = dummy_tex,
            .material = .overlay_shadow,
            .scissor = null,
        },
        .{
            .vertex_start = 1,
            .vertex_count = 1,
            .texture = dummy_tex,
            .material = .blurred_surface,
            .scissor = null,
        },
    };
    const split = findBlurSplit(&shadow_then_blur, blur_res).?;
    try std.testing.expectEqual(@as(usize, 1), split.split_idx);
}

test "executeOffscreenReadback renders quad directly to MappedReadback" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    graphics.initSdlCore(true) catch return error.SkipZigTest;
    defer graphics.quitSdlCore();

    const dev = graphics.createGpuDevice(false) catch
        return error.SkipZigTest;
    defer dev.destroy();

    var gpu_res = graphics.initGpuResources(
        io,
        dev,
        .headless,
        1.0,
    ) catch return error.SkipZigTest;
    defer gpu_res.deinit(allocator);

    const Builder = struct {
        fn build(
            _: void,
            build_ctx: PacketBuildContext,
        ) !RenderPacket {
            var packet: RenderPacket = .{};
            errdefer packet.deinit(build_ctx.frame_allocator);

            // Semi-transparent blue (R=0, G=0, B=255, A=128) in 0xAABBGGRR
            // covering only the left half (NDC x in [-1, 0]) so the test
            // verifies both straight-RGBA output (not premultiplied) and
            // transparent readback clear color (0, 0, 0, 0).
            const blue: u32 = 0x80FF0000;
            const verts = [_]Vertex{
                .{ .x = -1.0, .y = -1.0, .u = 0.0, .v = 1.0, .color = blue },
                .{ .x = 0.0, .y = -1.0, .u = 1.0, .v = 1.0, .color = blue },
                .{ .x = 0.0, .y = 1.0, .u = 1.0, .v = 0.0, .color = blue },
                .{ .x = -1.0, .y = -1.0, .u = 0.0, .v = 1.0, .color = blue },
                .{ .x = 0.0, .y = 1.0, .u = 1.0, .v = 0.0, .color = blue },
                .{ .x = -1.0, .y = 1.0, .u = 0.0, .v = 0.0, .color = blue },
            };
            try packet.vertices.appendSlice(build_ctx.frame_allocator, &verts);
            try addBatch(
                &packet.batches,
                build_ctx.frame_allocator,
                0,
                verts.len,
                build_ctx.gpu_res.white_texture,
                .ui_element,
                null,
            );
            return packet;
        }
    };

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    const res = try executeOffscreenReadback(
        &gpu_res,
        .{},
        allocator,
        frame_arena.allocator(),
        .{ .w = 4.0, .h = 4.0 },
        .{},
        {},
        Builder.build,
    );
    defer res.readback.deinit();

    try std.testing.expectEqual(@as(u32, 4), res.readback.dims.w);
    try std.testing.expectEqual(@as(u32, 4), res.readback.dims.h);
    try std.testing.expectEqual(@as(u32, 16), res.readback.pitch);
    try std.testing.expectEqual(
        sdl.gpu.TextureFormat.rgba8_unorm,
        res.readback.format,
    );
    try std.testing.expectEqual(@as(usize, 64), res.readback.pixels.len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 255, 128 },
        res.readback.pixels[0..4],
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 0, 0 },
        res.readback.pixels[8..12],
    );
}
