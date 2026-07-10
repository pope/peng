const std = @import("std");
const main = @import("../main.zig");
const c = main.c;
const renderer = @import("renderer.zig");

pub const GraphicsSetup = struct {
    window: *c.SDL_Window,
    gpu_device: *c.SDL_GPUDevice,
    initial_dpi_scale: f32,
};

pub fn initGraphicsAndWindow(window_title: [:0]const u8, test_mode: bool) !GraphicsSetup {
    _ = test_mode;
    // Initialize SDL3
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) {
        std.log.err("SDL_Init Error: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    errdefer c.SDL_Quit();

    // Initialize SDL3_ttf
    if (!c.TTF_Init()) {
        std.log.err("TTF_Init Error: {s}", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }
    errdefer c.TTF_Quit();

    // Create window
    const window = c.SDL_CreateWindow(window_title.ptr, 1024, 768, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse {
        std.log.err("SDL_CreateWindow Error: {s}", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    // Get scales
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    if (!c.SDL_GetWindowSize(window, &win_w, &win_h)) {
        std.log.err("SDL_GetWindowSize failed: {s}", .{c.SDL_GetError()});
    }
    var pix_w: c_int = 0;
    var pix_h: c_int = 0;
    if (!c.SDL_GetWindowSizeInPixels(window, &pix_w, &pix_h)) {
        std.log.err("SDL_GetWindowSizeInPixels failed: {s}", .{c.SDL_GetError()});
    }
    const initial_dpi_scale = if (win_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;

    // Create GPU Device
    const gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, true, null) orelse {
        std.log.err("SDL_CreateGPUDevice Error: {s}", .{c.SDL_GetError()});
        return error.DeviceCreationFailed;
    };
    errdefer c.SDL_DestroyGPUDevice(gpu_device);

    if (!c.SDL_ClaimWindowForGPUDevice(gpu_device, window)) {
        std.log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
        return error.ClaimWindowFailed;
    }

    return GraphicsSetup{
        .window = window,
        .gpu_device = gpu_device,
        .initial_dpi_scale = initial_dpi_scale,
    };
}

pub const GpuResources = struct {
    text_engine: *c.TTF_TextEngine,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    white_texture: *c.SDL_GPUTexture,
    fonts: [2]?*c.TTF_Font,
};

pub fn initGpuResources(gpu_device: *c.SDL_GPUDevice, window: *c.SDL_Window, initial_dpi_scale: f32) !GpuResources {
    // Load Font from Memory using SDL_IOStream (scaled by DPI scale)
    const roboto_font_bytes = @embedFile("../resources/Roboto-Regular.ttf");
    const stream = c.SDL_IOFromConstMem(roboto_font_bytes.ptr, roboto_font_bytes.len) orelse {
        std.log.err("SDL_IOFromConstMem Error: {s}", .{c.SDL_GetError()});
        return error.SDLMemIOFailed;
    };
    errdefer _ = c.SDL_CloseIO(stream);
    const font = c.TTF_OpenFontIO(stream, true, 20.0 * initial_dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{c.SDL_GetError()});
        return error.TTFOpenFontFailed;
    };
    errdefer c.TTF_CloseFont(font);

    // Create TTF GPU Text Engine
    const text_engine = c.TTF_CreateGPUTextEngine(gpu_device) orelse {
        std.log.err("TTF_CreateGPUTextEngine Error: {s}", .{c.SDL_GetError()});
        return error.TTFCreateEngineFailed;
    };
    errdefer c.TTF_DestroyGPUTextEngine(text_engine);

    // Re-load font at smaller size for stat rows
    const stream2 = c.SDL_IOFromConstMem(roboto_font_bytes.ptr, roboto_font_bytes.len) orelse {
        std.log.err("SDL_IOFromConstMem Error: {s}", .{c.SDL_GetError()});
        return error.SDLMemIOFailed;
    };
    errdefer _ = c.SDL_CloseIO(stream2);
    const font_small = c.TTF_OpenFontIO(stream2, true, 14.0 * initial_dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{c.SDL_GetError()});
        return error.TTFOpenFontFailed;
    };
    errdefer c.TTF_CloseFont(font_small);

    const fonts = [2]?*c.TTF_Font{ font, font_small };

    // Compile Shaders
    const vert_code = @embedFile("../shaders/vert.spv");
    const frag_code = @embedFile("../shaders/frag.spv");

    const vert_info = c.SDL_GPUShaderCreateInfo{
        .code_size = vert_code.len,
        .code = vert_code.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
        .num_samplers = 0,
        .num_storage_buffers = 0,
        .num_storage_textures = 0,
        .num_uniform_buffers = 0,
        .props = 0,
    };
    const vert_shader = c.SDL_CreateGPUShader(gpu_device, &vert_info) orelse {
        std.log.err("Failed to create vertex shader: {s}", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(gpu_device, vert_shader);

    const frag_info = c.SDL_GPUShaderCreateInfo{
        .code_size = frag_code.len,
        .code = frag_code.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = 1,
        .num_storage_buffers = 0,
        .num_storage_textures = 0,
        .num_uniform_buffers = 1,
        .props = 0,
    };
    const frag_shader = c.SDL_CreateGPUShader(gpu_device, &frag_info) orelse {
        std.log.err("Failed to create fragment shader: {s}", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(gpu_device, frag_shader);

    // Create sampler
    const sampler_info = c.SDL_GPUSamplerCreateInfo{
        .min_filter = c.SDL_GPU_FILTER_LINEAR,
        .mag_filter = c.SDL_GPU_FILTER_LINEAR,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0.0,
        .max_anisotropy = 1.0,
        .compare_op = c.SDL_GPU_COMPAREOP_NEVER,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .props = 0,
    };
    const sampler = c.SDL_CreateGPUSampler(gpu_device, &sampler_info) orelse {
        std.log.err("Failed to create GPU sampler: {s}", .{c.SDL_GetError()});
        return error.SamplerCreationFailed;
    };
    errdefer c.SDL_ReleaseGPUSampler(gpu_device, sampler);

    // Create 1x1 white texture
    const texture_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
        .width = 1,
        .height = 1,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };
    const white_texture = c.SDL_CreateGPUTexture(gpu_device, &texture_info) orelse {
        std.log.err("Failed to create white texture: {s}", .{c.SDL_GetError()});
        return error.TextureCreationFailed;
    };
    errdefer c.SDL_ReleaseGPUTexture(gpu_device, white_texture);

    // Upload white pixel
    {
        const cmd_buf = c.SDL_AcquireGPUCommandBuffer(gpu_device) orelse return error.CommandBufferAcquisitionFailed;
        const transfer_buf = c.SDL_CreateGPUTransferBuffer(gpu_device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = 4,
            .props = 0,
        }) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            return error.TransferBufferCreationFailed;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(gpu_device, transfer_buf);

        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(gpu_device, transfer_buf, false) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            return error.MapFailed;
        });
        mapped[0] = 255;
        mapped[1] = 255;
        mapped[2] = 255;
        mapped[3] = 255;
        c.SDL_UnmapGPUTransferBuffer(gpu_device, transfer_buf);

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            return error.CopyPassFailed;
        };
        c.SDL_UploadToGPUTexture(copy_pass, &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer_buf,
            .offset = 0,
            .pixels_per_row = 1,
            .rows_per_layer = 1,
        }, &c.SDL_GPUTextureRegion{
            .texture = white_texture,
            .w = 1,
            .h = 1,
            .d = 1,
        }, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    }

    // Create Graphics Pipeline
    const vertex_attribs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(renderer.Vertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(renderer.Vertex, "u") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(renderer.Vertex, "r") },
    };
    const vertex_buf_descs = [_]c.SDL_GPUVertexBufferDescription{
        .{ .slot = 0, .pitch = @sizeOf(renderer.Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
    };

    var pipeline_info = c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .num_vertex_attributes = vertex_attribs.len,
            .vertex_attributes = &vertex_attribs,
            .num_vertex_buffers = vertex_buf_descs.len,
            .vertex_buffer_descriptions = &vertex_buf_descs,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = .{
            .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS,
            .back_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS, .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP },
            .front_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS, .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP },
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = false,
            .enable_depth_write = false,
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .num_color_targets = 1,
            .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{.{
                .format = c.SDL_GetGPUSwapchainTextureFormat(gpu_device, window),
                .blend_state = .{
                    .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                    .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                    .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
                    .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                    .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .enable_blend = true,
                    .enable_color_write_mask = false,
                    .padding1 = 0,
                    .padding2 = 0,
                },
            }},
            .has_depth_stencil_target = false,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
            .padding1 = 0,
            .padding2 = 0,
        },
        .props = 0,
    };
    const pipeline = c.SDL_CreateGPUGraphicsPipeline(gpu_device, &pipeline_info) orelse {
        std.log.err("Failed to create graphics pipeline: {s}", .{c.SDL_GetError()});
        return error.PipelineCreationFailed;
    };

    return GpuResources{
        .text_engine = text_engine,
        .pipeline = pipeline,
        .sampler = sampler,
        .white_texture = white_texture,
        .fonts = fonts,
    };
}
