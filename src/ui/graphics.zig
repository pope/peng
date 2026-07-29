const std = @import("std");
const sdl = @import("sdl");
const renderer = @import("renderer.zig");
const clay = @import("zclay");
const theme = @import("theme.zig");
const app = @import("app");
const MeasureTextUserData = app.types.MeasureTextUserData;

pub const GraphicsSetup = struct {
    window: sdl.Window,
    gpu_device: sdl.gpu.Device,
    initial_dpi_scale: f32,
};

pub const GraphicsOptions = struct {
    headless: bool = false,
    high_dpi: bool = true,
};

const builtin = @import("builtin");

pub fn initGraphicsAndWindow(window_title: [:0]const u8, options: GraphicsOptions) !GraphicsSetup {
    if (options.headless and builtin.os.tag != .macos and builtin.os.tag != .windows) {
        _ = sdl.hint.set("SDL_VIDEO_DRIVER", "offscreen");
    }

    if (!sdl.init(sdl.init_flags.video | sdl.init_flags.events)) {
        std.log.err("SDL_Init Error: {s}", .{sdl.getError()});
        return error.SDLInitFailed;
    }
    errdefer sdl.quit();

    sdl.initTtf() catch |err| {
        std.log.err("TTF_Init Error: {}", .{err});
        return error.TTFInitFailed;
    };
    errdefer sdl.quitTtf();

    // Create window
    const win_flags = if (options.headless)
        sdl.window_flags.hidden
    else if (options.high_dpi)
        sdl.window_flags.resizable | sdl.window_flags.high_pixel_density
    else
        sdl.window_flags.resizable;
    const window = sdl.Window.createZ(window_title, 1024, 768, win_flags) orelse {
        std.log.err("SDL_CreateWindow Error: {s}", .{sdl.getError()});
        return error.WindowCreationFailed;
    };
    errdefer window.destroy();

    // Get scales
    const win_size = window.getSize();
    const pix_size = window.getSizeInPixels();
    const initial_dpi_scale = if (win_size.w > 0) @as(f32, @floatFromInt(pix_size.w)) / @as(f32, @floatFromInt(win_size.w)) else 1.0;

    // Create GPU Device
    const dev = sdl.gpu.Device.create(sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl, true) orelse {
        std.log.err("SDL_CreateGPUDevice Error: {s}", .{sdl.getError()});
        return error.DeviceCreationFailed;
    };
    errdefer dev.destroy();

    // Claim window for GPU
    if (!options.headless) {
        if (!window.claimForGpu(dev)) {
            std.log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{sdl.getError()});
            return error.ClaimWindowFailed;
        }
    }

    return GraphicsSetup{
        .window = window,
        .gpu_device = dev,
        .initial_dpi_scale = initial_dpi_scale,
    };
}

pub const GpuResources = struct {
    pipeline: sdl.gpu.Pipeline,
    unpack_compute_pipeline: ?sdl.gpu.ComputePipeline = null,
    sampler: sdl.gpu.Sampler,
    white_texture: sdl.gpu.Texture,
    fonts: [2]?sdl.Font,
};

fn createShaderFromFormat(
    dev: sdl.gpu.Device,
    shader_formats: u32,
    stage: sdl.gpu.ShaderStage,
    spv: []const u8,
    msl: []const u8,
    num_samplers: u32,
    num_uniform_buffers: u32,
) !sdl.gpu.Shader {
    const is_spirv = (shader_formats & sdl.gpu.ShaderFormat.spirv) != 0;
    const is_msl = (shader_formats & sdl.gpu.ShaderFormat.msl) != 0;

    if (!is_spirv and !is_msl) {
        std.log.err("No supported shader format for stage {} (formats mask: {X})", .{ stage, shader_formats });
        return error.UnsupportedShaderFormat;
    }

    const code = if (is_spirv) spv else msl;
    const fmt = if (is_spirv) sdl.gpu.ShaderFormat.spirv else sdl.gpu.ShaderFormat.msl;
    const entry = if (is_spirv) "main" else "main0";

    const info = sdl.gpu.ShaderCreateInfo{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = entry,
        .format = fmt,
        .stage = stage,
        .num_samplers = num_samplers,
        .num_storage_buffers = 0,
        .num_storage_textures = 0,
        .num_uniform_buffers = num_uniform_buffers,
        .props = 0,
    };

    return dev.createShader(&info) orelse {
        std.log.err("Failed to create shader for stage {}: {s}", .{ stage, sdl.getError() });
        return error.ShaderCreationFailed;
    };
}

pub fn initGpuResources(dev: sdl.gpu.Device, window: sdl.Window, initial_dpi_scale: f32, headless: bool) !GpuResources {
    const target_format = if (headless)
        sdl.gpu.TextureFormat.rgba8_unorm
    else
        dev.getSwapchainTextureFormat(window);

    // Load Font from Memory using SDL_IOStream (scaled by DPI scale)
    const roboto_font_bytes = @embedFile("resources/Roboto-Regular.ttf");
    const font = sdl.Font.openConstMem(roboto_font_bytes, 20.0 * initial_dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{sdl.getError()});
        return error.TTFOpenFontFailed;
    };
    errdefer font.close();

    // Re-load font at smaller size for stat rows
    const font_small = sdl.Font.openConstMem(roboto_font_bytes, 14.0 * initial_dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{sdl.getError()});
        return error.TTFOpenFontFailed;
    };
    errdefer font_small.close();

    const fonts = [2]?sdl.Font{ font, font_small };

    // Compile Shaders
    const vert_code_spv = @embedFile("shaders/vert.spv");
    const frag_code_spv = @embedFile("shaders/frag.spv");
    const vert_code_msl = @embedFile("shaders/vert.msl");
    const frag_code_msl = @embedFile("shaders/frag.msl");

    const shader_formats = dev.getShaderFormats();

    // Vertex & Fragment Shaders
    const vert_shader = try createShaderFromFormat(dev, shader_formats, .vertex, vert_code_spv, vert_code_msl, 0, 0);
    defer dev.releaseShader(vert_shader);

    const frag_shader = try createShaderFromFormat(dev, shader_formats, .fragment, frag_code_spv, frag_code_msl, 1, 1);
    defer dev.releaseShader(frag_shader);

    // Create sampler
    const sampler_info = sdl.gpu.SamplerCreateInfo{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0.0,
        .max_anisotropy = 1.0,
        .compare_op = .never,
        .min_lod = 0.0,
        .max_lod = 1000.0,
        .props = 0,
    };
    const sampler = dev.createSampler(&sampler_info) orelse {
        std.log.err("Failed to create GPU sampler: {s}", .{sdl.getError()});
        return error.SamplerCreationFailed;
    };
    errdefer dev.releaseSampler(sampler);

    // Create 1x1 white texture
    const texture_info = sdl.gpu.TextureCreateInfo{
        .type = .type_2d,
        .format = .rgba8_unorm,
        .usage = sdl.gpu.TextureUsage.sampler | sdl.gpu.TextureUsage.color_target,
        .width = 1,
        .height = 1,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = .count_1,
        .props = 0,
    };
    const white_texture = dev.createTexture(&texture_info) orelse {
        std.log.err("Failed to create white texture: {s}", .{sdl.getError()});
        return error.TextureCreationFailed;
    };
    errdefer dev.releaseTexture(white_texture);

    // Upload white pixel
    {
        const cmd_buf_wrapper = dev.acquireCommandBuffer() orelse return error.CommandBufferAcquisitionFailed;
        const transfer_buf = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = 4,
            .props = 0,
        }) orelse {
            _ = cmd_buf_wrapper.submit();
            return error.TransferBufferCreationFailed;
        };
        defer dev.releaseTransferBuffer(transfer_buf);

        const mapped = dev.mapTransferBuffer(transfer_buf, false) orelse {
            _ = cmd_buf_wrapper.submit();
            return error.MapFailed;
        };
        mapped[0] = 255;
        mapped[1] = 255;
        mapped[2] = 255;
        mapped[3] = 255;
        dev.unmapTransferBuffer(transfer_buf);

        const copy_pass = cmd_buf_wrapper.beginCopyPass() orelse {
            _ = cmd_buf_wrapper.submit();
            return error.CopyPassCreationFailed;
        };
        copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
            .transfer_buffer = transfer_buf,
            .offset = 0,
            .pixels_per_row = 1,
            .rows_per_layer = 1,
        }, &sdl.gpu.TextureRegion{
            .texture = white_texture,
            .w = 1,
            .h = 1,
            .d = 1,
        }, false);
        copy_pass.end();
        _ = cmd_buf_wrapper.submit();
    }

    // Create Graphics Pipeline
    const vertex_attribs = [_]sdl.gpu.VertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = .float2, .offset = @offsetOf(renderer.Vertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = .float2, .offset = @offsetOf(renderer.Vertex, "u") },
        .{ .location = 2, .buffer_slot = 0, .format = .ubyte4_norm, .offset = @offsetOf(renderer.Vertex, "color") },
    };
    const vertex_buf_descs = [_]sdl.gpu.VertexBufferDescription{
        .{ .slot = 0, .pitch = @sizeOf(renderer.Vertex), .input_rate = .vertex, .instance_step_rate = 0 },
    };

    var pipeline_info = sdl.gpu.GraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .num_vertex_attributes = vertex_attribs.len,
            .vertex_attributes = &vertex_attribs,
            .num_vertex_buffers = vertex_buf_descs.len,
            .vertex_buffer_descriptions = &vertex_buf_descs,
        },
        .primitive_type = .triangle_list,
        .rasterizer_state = .{
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
        },
        .multisample_state = .{
            .sample_count = .count_1,
        },
        .depth_stencil_state = .{
            .compare_op = .always,
        },
        .target_info = .{
            .num_color_targets = 1,
            .color_target_descriptions = &[_]sdl.gpu.ColorTargetDescription{.{
                .format = target_format,
                .blend_state = .{
                    .src_color_blendfactor = .src_alpha,
                    .dst_color_blendfactor = .one_minus_src_alpha,
                    .color_blend_op = .add,
                    .src_alpha_blendfactor = .one,
                    .dst_alpha_blendfactor = .one_minus_src_alpha,
                    .alpha_blend_op = .add,
                    .color_write_mask = sdl.gpu.ColorComponent.r | sdl.gpu.ColorComponent.g | sdl.gpu.ColorComponent.b | sdl.gpu.ColorComponent.a,
                    .enable_blend = true,
                    .enable_color_write_mask = true,
                },
            }},
            .has_depth_stencil_target = false,
            .depth_stencil_format = .d16_unorm,
        },
        .props = 0,
    };
    const pipeline = dev.createPipeline(&pipeline_info) orelse {
        std.log.err("Failed to create graphics pipeline: {s}", .{sdl.getError()});
        return error.PipelineCreationFailed;
    };

    // Compute Shader for RGB/BGR Unpack
    const comp_code_spv = @embedFile("shaders/unpack_rgb.spv");
    const comp_code_msl = @embedFile("shaders/unpack_rgb.msl");

    const is_comp_spirv = (shader_formats & sdl.gpu.ShaderFormat.spirv) != 0;
    const comp_code = if (is_comp_spirv) comp_code_spv else comp_code_msl;
    const comp_fmt = if (is_comp_spirv) sdl.gpu.ShaderFormat.spirv else sdl.gpu.ShaderFormat.msl;
    const comp_entry = if (is_comp_spirv) "main" else "main0";

    const comp_pipeline_info = sdl.gpu.ComputePipelineCreateInfo{
        .code_size = comp_code.len,
        .code = comp_code.ptr,
        .entrypoint = comp_entry,
        .format = comp_fmt,
        .num_readonly_storage_buffers = 1,
        .num_readwrite_storage_textures = 1,
        .num_uniform_buffers = 1,
        .threadcount_x = 16,
        .threadcount_y = 16,
        .threadcount_z = 1,
    };
    const unpack_compute_pipeline = dev.createComputePipeline(&comp_pipeline_info);
    if (unpack_compute_pipeline == null) {
        std.log.warn("Failed to create unpack compute pipeline (will fallback to SIMD): {s}", .{sdl.getError()});
    }

    return GpuResources{
        .pipeline = pipeline,
        .unpack_compute_pipeline = unpack_compute_pipeline,
        .sampler = sampler,
        .white_texture = white_texture,
        .fonts = fonts,
    };
}

fn getTextureFormatElementSize(format: sdl.gpu.TextureFormat) u32 {
    return switch (format) {
        .rgba8_unorm, .bgra8_unorm, .bgra8_unorm_srgb, .rgba8_unorm_srgb => 4,
        .r16g16b16a16_float => 8,
        .r32g32b32a32_float => 16,
        else => 4, // Fallback safe default
    };
}

pub fn saveTextureToPng(
    dev: sdl.gpu.Device,
    cmd: sdl.gpu.CommandBuffer,
    texture: sdl.gpu.Texture,
    width: u32,
    height: u32,
    texture_format: sdl.gpu.TextureFormat,
    filename: [:0]const u8,
) !void {
    const bpp = getTextureFormatElementSize(texture_format);
    const pitch = width * bpp;
    const size = pitch * height;

    const transfer_buf = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
        .usage = .download,
        .size = size,
        .props = 0,
    }) orelse {
        std.log.err("Failed to create download transfer buffer: {s}", .{sdl.getError()});
        return error.TransferBufferCreationFailed;
    };
    defer dev.releaseTransferBuffer(transfer_buf);

    const copy_pass = cmd.beginCopyPass() orelse {
        _ = cmd.cancel();
        return error.CopyPassCreationFailed;
    };
    copy_pass.downloadFromTexture(&sdl.gpu.TextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = width,
        .h = height,
        .d = 1,
    }, &sdl.gpu.TextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = width,
        .rows_per_layer = height,
    });
    copy_pass.end();

    const fence_opt = cmd.submitAndAcquireFence();
    if (fence_opt) |fence| {
        _ = dev.waitForFence(fence);
        dev.releaseFence(fence);
    } else {
        std.log.err("Failed to acquire GPU fence for screenshot save: {s}", .{sdl.getError()});
        return error.FenceAcquisitionFailed;
    }

    const data_ptr = dev.mapTransferBuffer(transfer_buf, false) orelse return error.MapBufferFailed;
    defer dev.unmapTransferBuffer(transfer_buf);

    var pixel_fmt = sdl.PixelFormat.rgba32;
    if (texture_format == .bgra8_unorm or
        texture_format == .bgra8_unorm_srgb)
    {
        pixel_fmt = sdl.PixelFormat.bgra32;
    }

    const surface = sdl.Surface.createFrom(@intCast(width), @intCast(height), pixel_fmt, data_ptr, @intCast(pitch)) orelse {
        std.log.err("SDL_CreateSurfaceFrom failed: {s}", .{sdl.getError()});
        return error.SurfaceCreationFailed;
    };
    defer surface.destroy();

    if (!surface.savePng(filename)) {
        std.log.err("IMG_SavePNG failed: {s}", .{sdl.getError()});
        return error.SavePngFailed;
    }
}

pub fn sdl3MeasureText(text: []const u8, config: *clay.TextElementConfig, data: *const MeasureTextUserData) clay.Dimensions {
    const clean_text = if (std.mem.indexOfScalar(u8, text, 0)) |idx| text[0..idx] else text;
    if (clean_text.len == 0) return .{ .w = 0, .h = 0 };

    if (config.font_id >= data.fonts.len) return .{ .w = 0, .h = 0 };
    const font = data.fonts[config.font_id] orelse return .{ .w = 0, .h = 0 };
    var target_size = @as(f32, @floatFromInt(config.font_size));
    if (data.is_debug_measuring) {
        // Scale down hardcoded 16px Clay debug text to 12px (0.75x) during debug panel layout
        target_size *= theme.debug_font_scale;
    }
    if (font.getFontSize() != target_size) {
        _ = font.setFontSize(target_size);
    }

    const size = font.getStringSize(data.allocator, clean_text) orelse return .{ .w = 0, .h = 0 };
    return .{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) };
}

pub const GpuUploadResult = app.gpu.GpuUploadResult;
pub const uploadSurfaceToGpu = app.gpu.uploadSurfaceToGpu;

test "uploadSurfaceToGpu compute unpack surface execution" {
    const dev_opt = sdl.gpu.Device.create(sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl, true);
    if (dev_opt) |dev| {
        defer dev.destroy();

        const comp_code_spv = @embedFile("shaders/unpack_rgb.spv");
        const comp_code_msl = @embedFile("shaders/unpack_rgb.msl");
        const shader_formats = dev.getShaderFormats();
        const is_spirv = (shader_formats & sdl.gpu.ShaderFormat.spirv) != 0;
        const comp_code = if (is_spirv) comp_code_spv else comp_code_msl;
        const comp_fmt = if (is_spirv) sdl.gpu.ShaderFormat.spirv else sdl.gpu.ShaderFormat.msl;
        const comp_entry = if (is_spirv) "main" else "main0";

        const comp_pipeline_info = sdl.gpu.ComputePipelineCreateInfo{
            .code_size = comp_code.len,
            .code = comp_code.ptr,
            .entrypoint = comp_entry,
            .format = comp_fmt,
            .num_readonly_storage_buffers = 1,
            .num_readwrite_storage_textures = 1,
            .num_uniform_buffers = 1,
            .threadcount_x = 16,
            .threadcount_y = 16,
            .threadcount_z = 1,
        };
        const unpack_pipeline = dev.createComputePipeline(&comp_pipeline_info) orelse return;
        defer dev.releaseComputePipeline(unpack_pipeline);

        // Test with small image (< 1MP) to ensure compute path is used regardless of size
        const surf = sdl.Surface.create(500, 500, sdl.PixelFormat.rgb24) orelse return;
        defer surf.destroy();

        const upload_res = uploadSurfaceToGpu(dev, surf, unpack_pipeline);
        try std.testing.expect(upload_res != null);

        if (upload_res) |res| {
            dev.releaseTexture(res.gpu_texture);
            try std.testing.expectEqual(@as(f32, 500.0), res.w);
            try std.testing.expectEqual(@as(f32, 500.0), res.h);
            // CPU conversion time should be 0.0 since compute unpack was used
            try std.testing.expectEqual(@as(f64, 0.0), res.conversion_time_ms);
        }
    }
}
