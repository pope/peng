const builtin = @import("builtin");
const clay = @import("zclay");
const geometry = @import("geometry.zig");
const sdl = @import("sdl");
const state = @import("state");
const std = @import("std");
const text_cache = @import("text_cache.zig");
const theme = @import("theme.zig");

const MeasureTextUserData = state.MeasureTextUserData;
const TextCache = text_cache.TextCache;

/// Initialized window handle, SDL GPU device, and DPI scale factor.
pub const GraphicsSetup = struct {
    window: sdl.Window,
    gpu_device: sdl.gpu.Device,
    initial_dpi_scale: f32,
};

/// Configuration options for graphics and window creation (headless mode,
/// initial hidden state, high-DPI scaling, and borderless mode).
pub const GraphicsOptions = struct {
    headless: bool = false,
    hidden: bool = false,
    high_dpi: bool = true,
    borderless: bool = false,
    debug_mode: bool = builtin.mode == .debug,
};

/// Immediate uniform parameters for Dual Kawase downsample and upsample passes.
pub const BlurUniforms = extern struct {
    texel_size_x: f32,
    texel_size_y: f32,
    radius: f32,
    padding: f32 = 0.0,
};

const StaticInitPayload = extern struct {
    fullscreen_verts: [6]geometry.Vertex = .{
        .{ .x = -1.0, .y = 1.0, .u = 0.0, .v = 0.0, .color = 0xFFFFFFFF },
        .{ .x = -1.0, .y = -1.0, .u = 0.0, .v = 1.0, .color = 0xFFFFFFFF },
        .{ .x = 1.0, .y = 1.0, .u = 1.0, .v = 0.0, .color = 0xFFFFFFFF },
        .{ .x = 1.0, .y = 1.0, .u = 1.0, .v = 0.0, .color = 0xFFFFFFFF },
        .{ .x = -1.0, .y = -1.0, .u = 0.0, .v = 1.0, .color = 0xFFFFFFFF },
        .{ .x = 1.0, .y = -1.0, .u = 1.0, .v = 1.0, .color = 0xFFFFFFFF },
    },
    white_pixel: [4]u8 = .{ 255, 255, 255, 255 },

    pub const verts_size = @sizeOf(@FieldType(StaticInitPayload, "fullscreen_verts"));
    pub const verts_offset = @offsetOf(StaticInitPayload, "fullscreen_verts");
    pub const pixel_offset = @offsetOf(StaticInitPayload, "white_pixel");
};

const quad_vertex_attribs = [_]sdl.gpu.VertexAttribute{
    .{
        .location = 0,
        .buffer_slot = 0,
        .format = .float2,
        .offset = @offsetOf(geometry.Vertex, "x"),
    },
    .{
        .location = 1,
        .buffer_slot = 0,
        .format = .float2,
        .offset = @offsetOf(geometry.Vertex, "u"),
    },
    .{
        .location = 2,
        .buffer_slot = 0,
        .format = .ubyte4_norm,
        .offset = @offsetOf(geometry.Vertex, "color"),
    },
};

const quad_vertex_buf_descs = [_]sdl.gpu.VertexBufferDescription{
    .{
        .slot = 0,
        .pitch = @sizeOf(geometry.Vertex),
        .input_rate = .vertex,
        .instance_step_rate = 0,
    },
};

/// Manages pipelines and offscreen textures for the 2-pass Dual Kawase backdrop blur.
/// State is modeled as a tagged union to guarantee that callers can never observe
/// or assume partially-initialized resources, with no non-null assertions required.
pub const BlurResources = union(enum) {
    uninitialized,
    failed,
    pipelines_ready: Pipelines,
    initialized: Initialized,

    /// Compiled Dual Kawase downsample and upsample graphics pipelines.
    pub const Pipelines = struct {
        down: sdl.gpu.Pipeline,
        up: sdl.gpu.Pipeline,

        /// Releases both Kawase blur pipelines from `dev`.
        pub fn deinit(self: Pipelines, dev: sdl.gpu.Device) void {
            dev.releasePipeline(self.down);
            dev.releasePipeline(self.up);
        }
    };

    /// Window-sized scene texture and quarter-resolution Kawase ping-pong
    /// render targets.
    pub const Textures = struct {
        scene: sdl.gpu.Texture,
        blur_down: sdl.gpu.Texture,
        blur: sdl.gpu.Texture,
        target_w: u32,
        target_h: u32,
        target_format: sdl.gpu.TextureFormat,
        down_w: u32,
        down_h: u32,

        /// Releases the scene and downsample/upsample textures from `dev`.
        pub fn deinit(self: Textures, dev: sdl.gpu.Device) void {
            dev.releaseTexture(self.scene);
            dev.releaseTexture(self.blur_down);
            dev.releaseTexture(self.blur);
        }

        /// Returns `true` if the offscreen textures match `w`, `h`, and `fmt`.
        pub fn matches(
            self: Textures,
            w: u32,
            h: u32,
            fmt: sdl.gpu.TextureFormat,
        ) bool {
            return self.target_w == w and
                self.target_h == h and
                self.target_format == fmt;
        }
    };

    /// Fully initialized Kawase blur pipelines and offscreen textures.
    pub const Initialized = struct {
        pipelines: Pipelines,
        textures: Textures,

        /// Releases both pipelines and offscreen textures from `dev`.
        pub fn deinit(self: *Initialized, dev: sdl.gpu.Device) void {
            self.pipelines.deinit(dev);
            self.textures.deinit(dev);
        }
    };

    /// Returns the blurred scene texture if blur resources are initialized and ready.
    pub fn getBlurTexture(self: *const BlurResources) ?sdl.gpu.Texture {
        return switch (self.*) {
            .initialized => |init_res| init_res.textures.blur,
            .uninitialized, .failed, .pipelines_ready => null,
        };
    }

    /// Releases offscreen blur textures while retaining compiled pipelines in
    /// `.pipelines_ready`, returning `true` if textures were freed.
    pub fn releaseTextures(self: *BlurResources, dev: sdl.gpu.Device) bool {
        switch (self.*) {
            .initialized => |init_res| {
                init_res.textures.deinit(dev);
                self.* = .{ .pipelines_ready = init_res.pipelines };
                return true;
            },
            .uninitialized, .failed, .pipelines_ready => return false,
        }
    }

    /// Releases blur pipelines and textures and resets state to .uninitialized.
    pub fn deinit(self: *BlurResources, dev: sdl.gpu.Device) void {
        switch (self.*) {
            .initialized => |*init_res| init_res.deinit(dev),
            .pipelines_ready => |pipes| pipes.deinit(dev),
            .uninitialized, .failed => {},
        }
        self.* = .uninitialized;
    }

    fn createPipelines(dev: sdl.gpu.Device) !Pipelines {
        const vert_code_spv = @embedFile("shaders/vert.spv");
        const vert_code_msl = @embedFile("shaders/vert.msl");
        const blur_down_code_spv = @embedFile("shaders/blur_down.spv");
        const blur_down_code_msl = @embedFile("shaders/blur_down.msl");
        const blur_up_code_spv = @embedFile("shaders/blur_up.spv");
        const blur_up_code_msl = @embedFile("shaders/blur_up.msl");

        const shader_formats = dev.getShaderFormats();

        const vert_shader = try createShaderFromFormat(
            dev,
            shader_formats,
            .vertex,
            vert_code_spv,
            vert_code_msl,
            0,
            0,
        );
        defer dev.releaseShader(vert_shader);

        const blur_down_frag_shader = try createShaderFromFormat(
            dev,
            shader_formats,
            .fragment,
            blur_down_code_spv,
            blur_down_code_msl,
            1,
            1,
        );
        defer dev.releaseShader(blur_down_frag_shader);

        const blur_up_frag_shader = try createShaderFromFormat(
            dev,
            shader_formats,
            .fragment,
            blur_up_code_spv,
            blur_up_code_msl,
            1,
            1,
        );
        defer dev.releaseShader(blur_up_frag_shader);

        var blur_down_pipeline_info = sdl.gpu.GraphicsPipelineCreateInfo{
            .vertex_shader = vert_shader,
            .fragment_shader = blur_down_frag_shader,
            .vertex_input_state = .{
                .num_vertex_attributes = quad_vertex_attribs.len,
                .vertex_attributes = &quad_vertex_attribs,
                .num_vertex_buffers = quad_vertex_buf_descs.len,
                .vertex_buffer_descriptions = &quad_vertex_buf_descs,
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
                .compare_op = .never,
            },
            .target_info = .{
                .num_color_targets = 1,
                .color_target_descriptions = &[_]sdl.gpu.ColorTargetDescription{.{
                    .format = .rgba8_unorm,
                    .blend_state = .{
                        .src_color_blendfactor = .one,
                        .dst_color_blendfactor = .zero,
                        .color_blend_op = .add,
                        .src_alpha_blendfactor = .one,
                        .dst_alpha_blendfactor = .zero,
                        .alpha_blend_op = .add,
                        .color_write_mask = sdl.gpu.ColorComponent.r |
                            sdl.gpu.ColorComponent.g |
                            sdl.gpu.ColorComponent.b |
                            sdl.gpu.ColorComponent.a,
                        .enable_blend = false,
                        .enable_color_write_mask = true,
                    },
                }},
                .has_depth_stencil_target = false,
                .depth_stencil_format = .d16_unorm,
            },
            .props = 0,
        };

        const blur_down_pipeline = dev.createPipeline(&blur_down_pipeline_info) orelse {
            std.log.err("Failed to create blur down pipeline: {s}", .{sdl.getError()});
            return error.PipelineCreationFailed;
        };
        errdefer dev.releasePipeline(blur_down_pipeline);

        var blur_up_pipeline_info = blur_down_pipeline_info;
        blur_up_pipeline_info.fragment_shader = blur_up_frag_shader;
        const blur_up_pipeline = dev.createPipeline(&blur_up_pipeline_info) orelse {
            std.log.err("Failed to create blur up pipeline: {s}", .{sdl.getError()});
            return error.PipelineCreationFailed;
        };

        return .{
            .down = blur_down_pipeline,
            .up = blur_up_pipeline,
        };
    }

    fn createTextures(
        dev: sdl.gpu.Device,
        win_w: u32,
        win_h: u32,
        target_format: sdl.gpu.TextureFormat,
    ) !Textures {
        const scene_tex = dev.createTexture(&sdl.gpu.TextureCreateInfo{
            .type = .type_2d,
            .format = target_format,
            .usage = sdl.gpu.TextureUsage.color_target | sdl.gpu.TextureUsage.sampler,
            .width = win_w,
            .height = win_h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = .count_1,
            .props = 0,
        }) orelse return error.SceneTextureCreationFailed;
        errdefer dev.releaseTexture(scene_tex);

        const down_w = @max(1, (win_w + 3) / 4);
        const down_h = @max(1, (win_h + 3) / 4);

        const down_info = sdl.gpu.TextureCreateInfo{
            .type = .type_2d,
            .format = .rgba8_unorm,
            .usage = sdl.gpu.TextureUsage.color_target | sdl.gpu.TextureUsage.sampler,
            .width = down_w,
            .height = down_h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = .count_1,
            .props = 0,
        };

        const blur_down_tex = dev.createTexture(&down_info) orelse return error.BlurTextureCreationFailed;
        errdefer dev.releaseTexture(blur_down_tex);

        const blur_tex = dev.createTexture(&down_info) orelse return error.BlurTextureCreationFailed;

        return .{
            .scene = scene_tex,
            .blur_down = blur_down_tex,
            .blur = blur_tex,
            .target_w = win_w,
            .target_h = win_h,
            .target_format = target_format,
            .down_w = down_w,
            .down_h = down_h,
        };
    }

    /// Ensures blur pipelines and offscreen textures are ready for rendering.
    /// On failure, logs a single warning and latches .failed for the session without log spam.
    pub fn ensure(
        self: *BlurResources,
        dev: sdl.gpu.Device,
        win_w: u32,
        win_h: u32,
        target_format: sdl.gpu.TextureFormat,
    ) void {
        if (win_w == 0 or win_h == 0) return;

        switch (self.*) {
            .failed => return,
            .uninitialized => {
                const pipes = createPipelines(dev) catch |err| {
                    std.log.warn(
                        "Failed to initialize blur pipelines: {}, " ++
                            "disabling backdrop blur",
                        .{err},
                    );
                    self.* = .failed;
                    return;
                };

                const textures = createTextures(
                    dev,
                    win_w,
                    win_h,
                    target_format,
                ) catch |err| {
                    std.log.warn(
                        "Failed to allocate blur textures: {}, " ++
                            "disabling backdrop blur",
                        .{err},
                    );
                    pipes.deinit(dev);
                    self.* = .failed;
                    return;
                };

                self.* = .{
                    .initialized = .{
                        .pipelines = pipes,
                        .textures = textures,
                    },
                };
            },
            .pipelines_ready => |pipes| {
                const textures = createTextures(
                    dev,
                    win_w,
                    win_h,
                    target_format,
                ) catch |err| {
                    std.log.warn(
                        "Failed to allocate blur textures from warm " ++
                            "pipelines: {}, disabling backdrop blur",
                        .{err},
                    );
                    pipes.deinit(dev);
                    self.* = .failed;
                    return;
                };

                self.* = .{
                    .initialized = .{
                        .pipelines = pipes,
                        .textures = textures,
                    },
                };
            },
            .initialized => |*init_res| {
                if (init_res.textures.matches(win_w, win_h, target_format)) {
                    return;
                }

                const textures = createTextures(
                    dev,
                    win_w,
                    win_h,
                    target_format,
                ) catch |err| {
                    std.log.warn(
                        "Failed to reallocate blur textures on resize: {}, " ++
                            "disabling backdrop blur",
                        .{err},
                    );
                    init_res.deinit(dev);
                    self.* = .failed;
                    return;
                };

                init_res.textures.deinit(dev);
                init_res.textures = textures;
            },
        }
    }
};

/// Result of ensuring a per-frame GPU buffer or transfer buffer, pairing the
/// non-null handle with whether the underlying allocation was freshly replaced.
pub fn AcquiredFrameBuffer(comptime Handle: type) type {
    return struct {
        handle: Handle,
        reallocated: bool,
    };
}

/// Cohesive GPU context and render resources initialized for GPU-accelerated rendering.
pub const RenderResources = struct {
    device: sdl.gpu.Device,
    image_pipeline: sdl.gpu.Pipeline,
    ui_pipeline: sdl.gpu.Pipeline,
    fullscreen_vertex_buffer: sdl.gpu.Buffer,
    unpack_compute_pipeline: ?sdl.gpu.ComputePipeline = null,
    sampler: sdl.gpu.Sampler,
    white_texture: sdl.gpu.Texture,

    // Offscreen blur subsystem (lazily initialized on first blur demand)
    blur: BlurResources = .uninitialized,

    // Persistent double-buffered vertex and transfer staging buffers
    vertex_buffers: [2]sdl.gpu.RetainedBuffer = .{
        .unallocated,
        .unallocated,
    },
    transfer_buffers: [2]sdl.gpu.RetainedTransferBuffer = .{
        .unallocated,
        .unallocated,
    },
    frame_index: usize = 0,

    // Font text texture cache & font
    text_cache: TextCache = .{},
    fonts: [1]?sdl.Font = .{null},

    /// Ensures the per-frame vertex buffer at `frame_idx` has at least
    /// `required_size` bytes, reallocating with 2x geometric growth if needed.
    pub fn ensureFrameVertexBuffer(
        self: *RenderResources,
        frame_idx: usize,
        required_size: usize,
    ) ?AcquiredFrameBuffer(sdl.gpu.Buffer) {
        switch (self.vertex_buffers[frame_idx]) {
            .allocated => |a| {
                if (a.capacity >= required_size) {
                    return .{ .handle = a.handle, .reallocated = false };
                }
                self.device.releaseBuffer(a.handle);
                self.vertex_buffers[frame_idx] = .unallocated;
            },
            .unallocated => {},
        }
        const new_vcap = std.mem.alignForward(
            usize,
            required_size * 2,
            4 * 1024,
        );
        const vb = self.device.createBuffer(&sdl.gpu.BufferCreateInfo{
            .usage = sdl.gpu.BufferUsage.vertex,
            .size = @intCast(new_vcap),
            .props = 0,
        }) orelse return null;
        self.vertex_buffers[frame_idx] = .{
            .allocated = .{ .handle = vb, .capacity = new_vcap },
        };
        return .{ .handle = vb, .reallocated = true };
    }

    /// Ensures the per-frame transfer buffer at `frame_idx` has at least
    /// `required_size` bytes. If an existing buffer is replaced, appends it to
    /// `temp_buffers` so in-flight copy operationsEarlier in the frame remain
    /// valid until command buffer submission.
    pub fn ensureFrameTransferBuffer(
        self: *RenderResources,
        frame_idx: usize,
        required_size: usize,
        min_capacity: usize,
        frame_allocator: std.mem.Allocator,
        temp_buffers: *std.ArrayList(sdl.gpu.TransferBuffer),
    ) ?AcquiredFrameBuffer(sdl.gpu.TransferBuffer) {
        switch (self.transfer_buffers[frame_idx]) {
            .allocated => |a| {
                if (a.capacity >= required_size) {
                    return .{ .handle = a.handle, .reallocated = false };
                }
                temp_buffers.append(frame_allocator, a.handle) catch |err| {
                    std.log.err(
                        "Failed to append old transfer buffer to cleanup " ++
                            "list: {}",
                        .{err},
                    );
                    self.device.releaseTransferBuffer(a.handle);
                };
                self.transfer_buffers[frame_idx] = .unallocated;
            },
            .unallocated => {},
        }
        const new_tbcap = std.mem.alignForward(
            usize,
            @max(required_size * 2, min_capacity),
            4 * 1024,
        );
        const tb = self.device.createTransferBuffer(
            &sdl.gpu.TransferBufferCreateInfo{
                .usage = .upload,
                .size = @intCast(new_tbcap),
                .props = 0,
            },
        ) orelse return null;
        self.transfer_buffers[frame_idx] = .{
            .allocated = .{ .handle = tb, .capacity = new_tbcap },
        };
        return .{ .handle = tb, .reallocated = true };
    }

    /// Releases transient window-scoped GPU allocations (cached glyph textures,
    /// offscreen blur textures, and double-buffered vertex/transfer buffers)
    /// while preserving compiled pipelines, sampler, white texture, and fonts.
    /// Returns `true` if any GPU resources were released.
    pub fn releaseTransientResources(
        self: *RenderResources,
        allocator: std.mem.Allocator,
    ) bool {
        var released = false;
        if (self.text_cache.map.count() > 0) {
            self.text_cache.deinit(allocator, self.device);
            self.text_cache = .{};
            released = true;
        }
        if (self.blur.releaseTextures(self.device)) {
            released = true;
        }
        for (&self.vertex_buffers) |*slot| {
            switch (slot.*) {
                .unallocated => {},
                .allocated => |a| {
                    self.device.releaseBuffer(a.handle);
                    slot.* = .unallocated;
                    released = true;
                },
            }
        }
        for (&self.transfer_buffers) |*slot| {
            switch (slot.*) {
                .unallocated => {},
                .allocated => |a| {
                    self.device.releaseTransferBuffer(a.handle);
                    slot.* = .unallocated;
                    released = true;
                },
            }
        }
        return released;
    }

    /// Releases GPU pipelines, samplers, fallback textures, staging buffers,
    /// text cache, and fonts on application teardown.
    pub fn deinit(self: *RenderResources, allocator: std.mem.Allocator) void {
        _ = self.releaseTransientResources(allocator);
        self.text_cache.deinit(allocator, self.device);
        for (self.fonts) |f| {
            if (f) |font| font.close();
        }
        self.blur.deinit(self.device);
        self.device.releaseBuffer(self.fullscreen_vertex_buffer);
        self.device.releasePipeline(self.image_pipeline);
        self.device.releasePipeline(self.ui_pipeline);
        if (self.unpack_compute_pipeline) |pipe| {
            self.device.releaseComputePipeline(pipe);
        }
        self.device.releaseSampler(self.sampler);
        self.device.releaseTexture(self.white_texture);
    }
};

/// Initializes SDL3 subsystems (video and events) and TTF engine.
/// Must be called before background workers start pushing SDL events or loading surfaces.
pub fn initSdlCore(headless: bool) !void {
    if (headless and builtin.os.tag != .macos and builtin.os.tag != .windows) {
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
}

/// Shuts down SDL TTF engine and SDL subsystems.
pub fn quitSdlCore() void {
    sdl.quitTtf();
    sdl.quit();
}

/// Creates the main window and claims the GPU graphics device.
/// Assumes SDL core and TTF subsystems have been initialized via `initSdlCore`.
pub fn initGraphicsAndWindow(window_title: [:0]const u8, options: GraphicsOptions) !GraphicsSetup {
    // Create window
    var win_flags = if (options.headless)
        sdl.window_flags.hidden
    else if (options.high_dpi)
        sdl.window_flags.resizable | sdl.window_flags.high_pixel_density
    else
        sdl.window_flags.resizable;
    if (options.borderless and !options.headless) {
        win_flags |= sdl.window_flags.borderless;
    }
    if (options.hidden and !options.headless) {
        win_flags |= sdl.window_flags.hidden;
    }
    const window = sdl.Window.createZ(window_title, 1024, 768, win_flags) orelse {
        std.log.err("SDL_CreateWindow Error: {s}", .{sdl.getError()});
        return error.WindowCreationFailed;
    };
    errdefer window.destroy();

    // Get scales
    const win_size = window.getSize();
    const pix_size = window.getSizeInPixels();
    const initial_dpi_scale = if (win_size.w > 0)
        @as(f32, @floatFromInt(pix_size.w)) / @as(f32, @floatFromInt(win_size.w))
    else
        1.0;

    // Create GPU Device
    const shader_flags = sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl;
    const dev = sdl.gpu.Device.create(shader_flags, options.debug_mode) orelse {
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
        std.log.err(
            "No supported shader format for stage {} (formats mask: {X})",
            .{ stage, shader_formats },
        );
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

/// Creates graphics shaders, pipelines, samplers, font texture caches, and
/// double-buffered staging buffers.
pub fn initGpuResources(
    dev: sdl.gpu.Device,
    window: sdl.Window,
    initial_dpi_scale: f32,
    headless: bool,
) !RenderResources {
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

    const fonts = [1]?sdl.Font{font};

    // Compile Shaders
    const vert_code_spv = @embedFile("shaders/vert.spv");
    const image_frag_code_spv = @embedFile("shaders/image.frag.spv");
    const vert_code_msl = @embedFile("shaders/vert.msl");
    const image_frag_code_msl = @embedFile("shaders/image.frag.msl");
    const ui_frag_code_spv = @embedFile("shaders/ui.frag.spv");
    const ui_frag_code_msl = @embedFile("shaders/ui.frag.msl");

    const shader_formats = dev.getShaderFormats();

    // Vertex & Fragment Shaders
    const vert_shader = try createShaderFromFormat(
        dev,
        shader_formats,
        .vertex,
        vert_code_spv,
        vert_code_msl,
        0,
        0,
    );
    defer dev.releaseShader(vert_shader);

    const image_frag_shader = try createShaderFromFormat(
        dev,
        shader_formats,
        .fragment,
        image_frag_code_spv,
        image_frag_code_msl,
        1,
        1,
    );
    defer dev.releaseShader(image_frag_shader);

    const ui_frag_shader = try createShaderFromFormat(
        dev,
        shader_formats,
        .fragment,
        ui_frag_code_spv,
        ui_frag_code_msl,
        1,
        1,
    );
    defer dev.releaseShader(ui_frag_shader);

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

    // Create Graphics Pipeline
    var pipeline_info = sdl.gpu.GraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = image_frag_shader,
        .vertex_input_state = .{
            .num_vertex_attributes = quad_vertex_attribs.len,
            .vertex_attributes = &quad_vertex_attribs,
            .num_vertex_buffers = quad_vertex_buf_descs.len,
            .vertex_buffer_descriptions = &quad_vertex_buf_descs,
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
            .compare_op = .never,
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
                    .color_write_mask = sdl.gpu.ColorComponent.r |
                        sdl.gpu.ColorComponent.g |
                        sdl.gpu.ColorComponent.b |
                        sdl.gpu.ColorComponent.a,
                    .enable_blend = true,
                    .enable_color_write_mask = true,
                },
            }},
            .has_depth_stencil_target = false,
            .depth_stencil_format = .d16_unorm,
        },
        .props = 0,
    };
    const image_pipeline = dev.createPipeline(&pipeline_info) orelse {
        std.log.err("Failed to create image graphics pipeline: {s}", .{sdl.getError()});
        return error.PipelineCreationFailed;
    };
    errdefer dev.releasePipeline(image_pipeline);

    var ui_pipeline_info = pipeline_info;
    ui_pipeline_info.fragment_shader = ui_frag_shader;
    const ui_pipeline = dev.createPipeline(&ui_pipeline_info) orelse {
        std.log.err("Failed to create UI graphics pipeline: {s}", .{sdl.getError()});
        return error.PipelineCreationFailed;
    };
    errdefer dev.releasePipeline(ui_pipeline);

    // Create static 6-vertex buffer for fullscreen passes
    const fullscreen_vertex_buffer = dev.createBuffer(&sdl.gpu.BufferCreateInfo{
        .usage = sdl.gpu.BufferUsage.vertex,
        .size = @intCast(StaticInitPayload.verts_size),
        .props = 0,
    }) orelse return error.GPUVertexBufferCreationFailed;
    errdefer dev.releaseBuffer(fullscreen_vertex_buffer);

    // Upload static 1x1 white pixel texture and 6-vertex fullscreen quad in a single copy pass
    {
        const transfer_buf = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = @intCast(@sizeOf(StaticInitPayload)),
            .props = 0,
        }) orelse return error.TransferBufferCreationFailed;
        defer dev.releaseTransferBuffer(transfer_buf);

        const mapped: *StaticInitPayload = @ptrCast(@alignCast(
            dev.mapTransferBuffer(transfer_buf, false) orelse return error.MapFailed,
        ));
        mapped.* = .{};
        dev.unmapTransferBuffer(transfer_buf);

        const cmd_buf_wrapper = dev.acquireCommandBuffer() orelse
            return error.CommandBufferAcquisitionFailed;
        const copy_pass = cmd_buf_wrapper.beginCopyPass() orelse {
            _ = cmd_buf_wrapper.cancel();
            return error.CopyPassCreationFailed;
        };
        copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
            .transfer_buffer = transfer_buf,
            .offset = StaticInitPayload.pixel_offset,
            .pixels_per_row = 1,
            .rows_per_layer = 1,
        }, &sdl.gpu.TextureRegion{
            .texture = white_texture,
            .w = 1,
            .h = 1,
            .d = 1,
        }, false);
        copy_pass.uploadToBuffer(&sdl.gpu.TransferBufferLocation{
            .transfer_buffer = transfer_buf,
            .offset = StaticInitPayload.verts_offset,
        }, &sdl.gpu.BufferRegion{
            .buffer = fullscreen_vertex_buffer,
            .offset = 0,
            .size = @intCast(StaticInitPayload.verts_size),
        }, false);
        copy_pass.end();
        _ = cmd_buf_wrapper.submit();
    }

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
        std.log.warn(
            "Failed to create unpack compute pipeline (will fallback to SIMD): {s}",
            .{sdl.getError()},
        );
    }

    return RenderResources{
        .device = dev,
        .image_pipeline = image_pipeline,
        .ui_pipeline = ui_pipeline,
        .blur = .uninitialized,
        .fullscreen_vertex_buffer = fullscreen_vertex_buffer,
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

/// Downloads pixel data from a GPU texture via transfer buffer and saves it as a PNG image file.
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

    const surface = sdl.Surface.createFrom(
        @intCast(width),
        @intCast(height),
        pixel_fmt,
        data_ptr,
        @intCast(pitch),
    ) orelse {
        std.log.err("SDL_CreateSurfaceFrom failed: {s}", .{sdl.getError()});
        return error.SurfaceCreationFailed;
    };
    defer surface.destroy();

    if (!surface.savePng(filename)) {
        std.log.err("IMG_SavePNG failed: {s}", .{sdl.getError()});
        return error.SavePngFailed;
    }
}

/// Measures text pixel width and height via SDL_ttf for Clay layout element sizing.
pub fn sdl3MeasureText(
    text: []const u8,
    config: *clay.TextElementConfig,
    data: *const MeasureTextUserData,
) clay.Dimensions {
    const clean_text = if (std.mem.findScalar(u8, text, 0)) |idx|
        text[0..idx]
    else
        text;
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

    const size = font.getStringSize(clean_text) orelse
        return .{ .w = 0, .h = 0 };
    return .{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) };
}

test "BlurResources tagged union lifecycle and failure latching" {
    var blur: BlurResources = .uninitialized;
    try std.testing.expect(blur == .uninitialized);
    try std.testing.expect(blur.getBlurTexture() == null);

    // Window dimensions of zero must short-circuit without attempting GPU calls or mutating state
    const dummy_dev: sdl.gpu.Device = .{ .ptr = @ptrFromInt(0x1000) };
    blur.ensure(dummy_dev, 0, 0, .rgba8_unorm);
    try std.testing.expect(blur == .uninitialized);

    // Initialized state composes session-lifetime Pipelines and window-sized Textures
    blur = .{
        .initialized = .{
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
        },
    };
    try std.testing.expect(blur == .initialized);
    try std.testing.expect(blur.initialized.textures.matches(800, 600, .rgba8_unorm));
    try std.testing.expect(!blur.initialized.textures.matches(1024, 768, .rgba8_unorm));
    try std.testing.expectEqual(@as(?sdl.gpu.Texture, .{ .ptr = @ptrFromInt(0x2005) }), blur.getBlurTexture());

    // Calling ensure with matching dimensions on initialized resources is a no-op
    blur.ensure(dummy_dev, 800, 600, .rgba8_unorm);
    try std.testing.expect(blur == .initialized);

    // Pipelines-ready state preserves warm pipelines while textures are absent
    blur = .{
        .pipelines_ready = .{
            .down = .{ .ptr = @ptrFromInt(0x2001) },
            .up = .{ .ptr = @ptrFromInt(0x2002) },
        },
    };
    try std.testing.expect(blur == .pipelines_ready);
    try std.testing.expect(blur.getBlurTexture() == null);
    try std.testing.expect(!blur.releaseTextures(dummy_dev));

    // Transition to failed latches failure and denies texture access
    blur = .failed;
    try std.testing.expect(blur == .failed);
    try std.testing.expect(blur.getBlurTexture() == null);

    // Calls to ensure while failed must remain failed without mutating state
    blur.ensure(dummy_dev, 800, 600, .rgba8_unorm);
    try std.testing.expect(blur == .failed);

    // Deinit on failed resets state back to uninitialized without dereferencing dev
    blur.deinit(dummy_dev);
    try std.testing.expect(blur == .uninitialized);
}

test "StaticInitPayload packs fullscreen quad and 4-byte aligned white pixel" {
    const payload = StaticInitPayload{};
    try std.testing.expectEqual(@as(usize, 0), StaticInitPayload.verts_offset);
    try std.testing.expectEqual(@as(usize, 6 * @sizeOf(geometry.Vertex)), StaticInitPayload.verts_size);
    try std.testing.expectEqual(@as(usize, 120), StaticInitPayload.pixel_offset);
    try std.testing.expectEqual(@as(usize, 0), StaticInitPayload.pixel_offset % 4);
    try std.testing.expectEqual(@as(usize, 124), @sizeOf(StaticInitPayload));
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &payload.white_pixel);
    try std.testing.expectEqual(@as(usize, 6), payload.fullscreen_verts.len);
}
