const std = @import("std");
const sdl = @import("sdl");
const renderer = @import("renderer.zig");
const clay = @import("zclay");
const MeasureTextUserData = @import("../app/types.zig").MeasureTextUserData;

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
    sampler: sdl.gpu.Sampler,
    white_texture: sdl.gpu.Texture,
    fonts: [2]?sdl.Font,
};

pub fn initGpuResources(dev: sdl.gpu.Device, window: sdl.Window, initial_dpi_scale: f32, headless: bool) !GpuResources {
    const target_format = if (headless)
        sdl.gpu.TextureFormat.rgba8_unorm
    else
        dev.getSwapchainTextureFormat(window);

    // Load Font from Memory using SDL_IOStream (scaled by DPI scale)
    const roboto_font_bytes = @embedFile("../resources/Roboto-Regular.ttf");
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
    const vert_code_spv = @embedFile("../shaders/vert.spv");
    const frag_code_spv = @embedFile("../shaders/frag.spv");
    const vert_code_msl = @embedFile("../shaders/vert.msl");
    const frag_code_msl = @embedFile("../shaders/frag.msl");

    const shader_formats = dev.getShaderFormats();

    // Vertex Shader Info
    const vert_info = if ((shader_formats & sdl.gpu.ShaderFormat.spirv) != 0)
        sdl.gpu.ShaderCreateInfo{
            .code_size = vert_code_spv.len,
            .code = vert_code_spv.ptr,
            .entrypoint = "main",
            .format = sdl.gpu.ShaderFormat.spirv,
            .stage = .vertex,
            .num_samplers = 0,
            .num_storage_buffers = 0,
            .num_storage_textures = 0,
            .num_uniform_buffers = 0,
            .props = 0,
        }
    else if ((shader_formats & sdl.gpu.ShaderFormat.msl) != 0)
        sdl.gpu.ShaderCreateInfo{
            .code_size = vert_code_msl.len,
            .code = vert_code_msl.ptr,
            .entrypoint = "main0",
            .format = sdl.gpu.ShaderFormat.msl,
            .stage = .vertex,
            .num_samplers = 0,
            .num_storage_buffers = 0,
            .num_storage_textures = 0,
            .num_uniform_buffers = 0,
            .props = 0,
        }
    else {
        std.log.err("No supported shader format for vertex shader (formats mask: {X})", .{shader_formats});
        return error.UnsupportedShaderFormat;
    };

    const vert_shader = dev.createShader(&vert_info) orelse {
        std.log.err("Failed to create vertex shader: {s}", .{sdl.getError()});
        return error.ShaderCreationFailed;
    };
    defer dev.releaseShader(vert_shader);

    // Fragment Shader Info
    const frag_info = if ((shader_formats & sdl.gpu.ShaderFormat.spirv) != 0)
        sdl.gpu.ShaderCreateInfo{
            .code_size = frag_code_spv.len,
            .code = frag_code_spv.ptr,
            .entrypoint = "main",
            .format = sdl.gpu.ShaderFormat.spirv,
            .stage = .fragment,
            .num_samplers = 1,
            .num_storage_buffers = 0,
            .num_storage_textures = 0,
            .num_uniform_buffers = 1,
            .props = 0,
        }
    else if ((shader_formats & sdl.gpu.ShaderFormat.msl) != 0)
        sdl.gpu.ShaderCreateInfo{
            .code_size = frag_code_msl.len,
            .code = frag_code_msl.ptr,
            .entrypoint = "main0",
            .format = sdl.gpu.ShaderFormat.msl,
            .stage = .fragment,
            .num_samplers = 1,
            .num_storage_buffers = 0,
            .num_storage_textures = 0,
            .num_uniform_buffers = 1,
            .props = 0,
        }
    else {
        std.log.err("No supported shader format for fragment shader (formats mask: {X})", .{shader_formats});
        return error.UnsupportedShaderFormat;
    };

    const frag_shader = dev.createShader(&frag_info) orelse {
        std.log.err("Failed to create fragment shader: {s}", .{sdl.getError()});
        return error.ShaderCreationFailed;
    };
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

    return GpuResources{
        .pipeline = pipeline,
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
    if (config.font_id >= data.fonts.len) return .{ .w = 0, .h = 0 };
    const font = data.fonts[config.font_id] orelse return .{ .w = 0, .h = 0 };
    const target_size = @as(f32, @floatFromInt(config.font_size));
    if (font.getFontSize() != target_size) {
        _ = font.setFontSize(target_size);
    }

    const size = font.getStringSize(data.allocator, text) orelse return .{ .w = 0, .h = 0 };
    return .{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) };
}

pub const GpuUploadResult = struct {
    gpu_texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    upload_time_ms: f64,
    memory_size_bytes: usize,
    num_mip_levels: u32 = 1,
    mipmap_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
};

pub fn uploadSurfaceToGpu(dev: sdl.gpu.Device, surf: sdl.Surface) ?GpuUploadResult {
    const start_upload = sdl.timer.getTicksNs();
    var current_surf = surf;

    const src_fmt = current_surf.format();
    const gpu_format: sdl.gpu.TextureFormat = if (src_fmt == sdl.PixelFormat.bgra32)
        .bgra8_unorm
    else
        .rgba8_unorm;

    var scaled_surf: ?sdl.Surface = null;
    defer if (scaled_surf) |s| s.destroy();

    var img_w = current_surf.w();
    var img_h = current_surf.h();
    var tex: ?sdl.gpu.Texture = null;
    const max_dim_u: u32 = @intCast(@max(img_w, img_h));
    const num_levels: u32 = if (max_dim_u > 1) @intCast(std.math.log2(max_dim_u) + 1) else 1;

    var try_max_dim: i32 = 16384;
    while (try_max_dim >= 2048) : (try_max_dim = @divTrunc(try_max_dim, 2)) {
        if (img_w <= try_max_dim and img_h <= try_max_dim) {
            const img_tex_info = sdl.gpu.TextureCreateInfo{
                .type = .type_2d,
                .format = gpu_format,
                .usage = sdl.gpu.TextureUsage.sampler | sdl.gpu.TextureUsage.color_target,
                .width = @intCast(img_w),
                .height = @intCast(img_h),
                .layer_count_or_depth = 1,
                .num_levels = num_levels,
                .sample_count = .count_1,
                .props = 0,
            };
            tex = dev.createTexture(&img_tex_info);
            if (tex != null) break;
        }

        const next_dim = @divTrunc(try_max_dim, 2);
        if (img_w > next_dim or img_h > next_dim) {
            var new_w = img_w;
            var new_h = img_h;
            if (img_w > img_h) {
                new_w = next_dim;
                new_h = @divTrunc(img_h * next_dim, img_w);
            } else {
                new_h = next_dim;
                new_w = @divTrunc(img_w * next_dim, img_h);
            }
            new_w = @max(1, new_w);
            new_h = @max(1, new_h);

            const new_scale = current_surf.scale(new_w, new_h, .linear);
            if (new_scale) |ns| {
                if (scaled_surf) |s| s.destroy();
                scaled_surf = ns;
                current_surf = ns;
                img_w = new_w;
                img_h = new_h;
            } else {
                std.log.err("uploadSurfaceToGpu: SDL_ScaleSurface failed: {s}", .{sdl.getError()});
                break;
            }
        }
    }

    const gpu_tex = tex orelse return null;

    const cmd_wrapper = dev.acquireCommandBuffer() orelse {
        dev.releaseTexture(gpu_tex);
        return null;
    };

    const u_w: usize = @intCast(img_w);
    const u_h: usize = @intCast(img_h);
    const dst_pitch: usize = std.mem.alignForward(usize, u_w * 4, 256);
    const size = dst_pitch * u_h;

    const transfer_buf = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
        .usage = .upload,
        .size = @intCast(size),
        .props = 0,
    }) orelse {
        std.log.err("Create transfer buffer failed: {s}", .{sdl.getError()});
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };
    defer dev.releaseTransferBuffer(transfer_buf);

    const mapped = dev.mapTransferBuffer(transfer_buf, false) orelse {
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };

    const src_pitch: usize = @intCast(current_surf.pitch());
    const pixels: [*]const u8 = current_surf.pixels();
    const cur_fmt = current_surf.format();
    var conversion_time_ms: f64 = 0.0;

    if (cur_fmt == sdl.PixelFormat.rgba32 or cur_fmt == sdl.PixelFormat.bgra32) {
        if (src_pitch == dst_pitch) {
            @memcpy(mapped[0..size], pixels[0..size]);
        } else {
            var y: usize = 0;
            while (y < u_h) : (y += 1) {
                @memcpy(mapped[y * dst_pitch .. y * dst_pitch + u_w * 4], pixels[y * src_pitch .. y * src_pitch + u_w * 4]);
            }
        }
    } else if (cur_fmt == sdl.PixelFormat.rgb24) {
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertRgb24ToRgba32Simd(pixels[0 .. src_pitch * u_h], mapped[0..size], u_w, u_h, src_pitch, dst_pitch);
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms = @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
    } else if (cur_fmt == sdl.PixelFormat.bgr24) {
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertBgr24ToRgba32Simd(pixels[0 .. src_pitch * u_h], mapped[0..size], u_w, u_h, src_pitch, dst_pitch);
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms = @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
    } else {
        const start_conv = sdl.timer.getTicksNs();
        const tmp_surf = current_surf.convert(sdl.PixelFormat.rgba32);
        if (tmp_surf) |ts| {
            defer ts.destroy();
            const ts_pixels = ts.pixels();
            const ts_pitch: usize = @intCast(ts.pitch());
            if (ts_pitch == dst_pitch) {
                @memcpy(mapped[0..size], ts_pixels[0..size]);
            } else {
                var y: usize = 0;
                while (y < u_h) : (y += 1) {
                    @memcpy(mapped[y * dst_pitch .. y * dst_pitch + u_w * 4], ts_pixels[y * ts_pitch .. y * ts_pitch + u_w * 4]);
                }
            }
            const end_conv = sdl.timer.getTicksNs();
            conversion_time_ms = @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
        } else {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        }
    }
    dev.unmapTransferBuffer(transfer_buf);

    const copy_pass = cmd_wrapper.beginCopyPass() orelse {
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };
    copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = @intCast(dst_pitch / 4),
        .rows_per_layer = @intCast(img_h),
    }, &sdl.gpu.TextureRegion{
        .texture = gpu_tex,
        .w = @intCast(img_w),
        .h = @intCast(img_h),
        .d = 1,
    }, false);
    copy_pass.end();

    var mipmap_time_ms: f64 = 0.0;
    if (num_levels > 1) {
        const start_mip = sdl.timer.getTicksNs();
        cmd_wrapper.generateMipmaps(gpu_tex);
        const end_mip = sdl.timer.getTicksNs();
        mipmap_time_ms = @as(f64, @floatFromInt(end_mip - start_mip)) / 1_000_000.0;
    }

    _ = cmd_wrapper.submit();

    const end_upload = sdl.timer.getTicksNs();
    const upload_time_ms = @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;

    var memory_size_bytes: usize = size;
    if (num_levels > 1) {
        memory_size_bytes = (memory_size_bytes * 4) / 3;
    }

    return .{
        .gpu_texture = gpu_tex,
        .w = @floatFromInt(img_w),
        .h = @floatFromInt(img_h),
        .upload_time_ms = upload_time_ms,
        .memory_size_bytes = memory_size_bytes,
        .num_mip_levels = num_levels,
        .mipmap_time_ms = mipmap_time_ms,
        .conversion_time_ms = conversion_time_ms,
    };
}
