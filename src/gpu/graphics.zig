const builtin = @import("builtin");
const geom = @import("geom");
const geometry = @import("geometry.zig");
const sdl = @import("sdl");
const state = @import("state");
const std = @import("std");
const text_cache = @import("text_cache.zig");

const FontMeasurer = text_cache.FontMeasurer;
const PositiveDimsU32 = geom.PositiveDimsU32;
const TextCache = text_cache.TextCache;
const UiRenderMetrics = state.UiRenderMetrics;
const UiRenderMetricsSnapshot = state.UiRenderMetricsSnapshot;

/// Initialized window handle and initial DPI scale factor (before GPU device
/// creation or claim).
pub const WindowSetup = struct {
    window: sdl.Window,
    initial_dpi_scale: f32,
};

/// Initialized window handle, SDL GPU device, and DPI scale factor.
pub const GraphicsSetup = struct {
    window: sdl.Window,
    gpu_device: sdl.gpu.Device,
    initial_dpi_scale: f32,
};

/// Render target format source for `initGpuResources`: either a GPU-claimed
/// window (matching its swapchain format) or headless offscreen rendering
/// (`.rgba8_unorm`).
pub const ResourceTarget = union(enum) {
    window: sdl.Window,
    headless,
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

    const verts_size =
        @sizeOf(@FieldType(StaticInitPayload, "fullscreen_verts"));
    const verts_offset = @offsetOf(StaticInitPayload, "fullscreen_verts");
    const pixel_offset = @offsetOf(StaticInitPayload, "white_pixel");
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

const sdf_vertex_attribs = [_]sdl.gpu.VertexAttribute{
    .{
        .location = 0,
        .buffer_slot = 0,
        .format = .float4,
        .offset = @offsetOf(geometry.UiQuadInstance, "rect"),
    },
    .{
        .location = 1,
        .buffer_slot = 0,
        .format = .float4,
        .offset = @offsetOf(geometry.UiQuadInstance, "radii"),
    },
    .{
        .location = 2,
        .buffer_slot = 0,
        .format = .float4,
        .offset = @offsetOf(geometry.UiQuadInstance, "border"),
    },
    .{
        .location = 3,
        .buffer_slot = 0,
        .format = .ubyte4_norm,
        .offset = @offsetOf(geometry.UiQuadInstance, "fill_color"),
    },
    .{
        .location = 4,
        .buffer_slot = 0,
        .format = .ubyte4_norm,
        .offset = @offsetOf(geometry.UiQuadInstance, "border_color"),
    },
    .{
        .location = 5,
        .buffer_slot = 0,
        .format = .float2,
        .offset = @offsetOf(geometry.UiQuadInstance, "softness"),
    },
};

const sdf_vertex_buf_descs = [_]sdl.gpu.VertexBufferDescription{
    .{
        .slot = 0,
        .pitch = @sizeOf(geometry.UiQuadInstance),
        .input_rate = .instance,
        .instance_step_rate = 0,
    },
};

/// Manages pipelines and offscreen textures for the 2-level, 3-pass Dual Kawase
/// backdrop blur. State is modeled as a tagged union to guarantee that callers
/// can never observe or assume partially-initialized resources, with no
/// non-null assertions required.
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

    /// Window-sized scene texture and 2-level Kawase ping-pong render targets
    /// (`blur` at half resolution, `blur_down` at quarter resolution).
    pub const Textures = struct {
        scene: sdl.gpu.Texture,
        blur_down: sdl.gpu.Texture,
        blur: sdl.gpu.Texture,
        target_dims: PositiveDimsU32,
        target_format: sdl.gpu.TextureFormat,
        half_dims: PositiveDimsU32,
        down_dims: PositiveDimsU32,

        /// Releases the scene and downsample/upsample textures from `dev`.
        pub fn deinit(self: Textures, dev: sdl.gpu.Device) void {
            dev.releaseTexture(self.scene);
            dev.releaseTexture(self.blur_down);
            dev.releaseTexture(self.blur);
        }

        /// Returns `true` if the offscreen textures match `dims` and `fmt`.
        pub fn matches(
            self: Textures,
            dims: PositiveDimsU32,
            fmt: sdl.gpu.TextureFormat,
        ) bool {
            return self.target_dims.w == dims.w and
                self.target_dims.h == dims.h and
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

    /// Returns the blurred scene texture if blur resources are initialized and
    /// ready.
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

        const color_targets = [_]sdl.gpu.ColorTargetDescription{.{
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
        }};

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
                .color_target_descriptions = &color_targets,
                .has_depth_stencil_target = false,
                .depth_stencil_format = .d16_unorm,
            },
            .props = 0,
        };

        const blur_down_pipeline =
            dev.createPipeline(&blur_down_pipeline_info) orelse {
                std.log.err(
                    "Failed to create blur down pipeline: {s}",
                    .{sdl.getError()},
                );
                return error.PipelineCreationFailed;
            };
        errdefer dev.releasePipeline(blur_down_pipeline);

        var blur_up_pipeline_info = blur_down_pipeline_info;
        blur_up_pipeline_info.fragment_shader = blur_up_frag_shader;
        const blur_up_pipeline =
            dev.createPipeline(&blur_up_pipeline_info) orelse {
                std.log.err(
                    "Failed to create blur up pipeline: {s}",
                    .{sdl.getError()},
                );
                return error.PipelineCreationFailed;
            };

        return .{
            .down = blur_down_pipeline,
            .up = blur_up_pipeline,
        };
    }

    fn createTextures(
        dev: sdl.gpu.Device,
        dims: PositiveDimsU32,
        target_format: sdl.gpu.TextureFormat,
    ) !Textures {
        const scene_tex = dev.createTexture(&sdl.gpu.TextureCreateInfo{
            .type = .type_2d,
            .format = target_format,
            .usage = sdl.gpu.TextureUsage.color_target |
                sdl.gpu.TextureUsage.sampler,
            .width = dims.w,
            .height = dims.h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = .count_1,
            .props = 0,
        }) orelse return error.SceneTextureCreationFailed;
        errdefer dev.releaseTexture(scene_tex);

        const half_dims = PositiveDimsU32{
            .w = @max(1, @divCeil(dims.w, 2)),
            .h = @max(1, @divCeil(dims.h, 2)),
        };
        const down_dims = PositiveDimsU32{
            .w = @max(1, @divCeil(dims.w, 4)),
            .h = @max(1, @divCeil(dims.h, 4)),
        };

        const half_info = sdl.gpu.TextureCreateInfo{
            .type = .type_2d,
            .format = .rgba8_unorm,
            .usage = sdl.gpu.TextureUsage.color_target |
                sdl.gpu.TextureUsage.sampler,
            .width = half_dims.w,
            .height = half_dims.h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = .count_1,
            .props = 0,
        };
        const down_info = sdl.gpu.TextureCreateInfo{
            .type = .type_2d,
            .format = .rgba8_unorm,
            .usage = sdl.gpu.TextureUsage.color_target |
                sdl.gpu.TextureUsage.sampler,
            .width = down_dims.w,
            .height = down_dims.h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = .count_1,
            .props = 0,
        };

        const blur_down_tex = dev.createTexture(&down_info) orelse
            return error.BlurTextureCreationFailed;
        errdefer dev.releaseTexture(blur_down_tex);

        const blur_tex = dev.createTexture(&half_info) orelse
            return error.BlurTextureCreationFailed;

        return .{
            .scene = scene_tex,
            .blur_down = blur_down_tex,
            .blur = blur_tex,
            .target_dims = dims,
            .target_format = target_format,
            .half_dims = half_dims,
            .down_dims = down_dims,
        };
    }

    /// Ensures blur pipelines and offscreen textures are ready for rendering.
    /// On failure, logs a single warning and latches .failed for the session
    /// without log spam.
    pub fn ensure(
        self: *BlurResources,
        dev: sdl.gpu.Device,
        dims: PositiveDimsU32,
        target_format: sdl.gpu.TextureFormat,
    ) void {
        if (dims.w == 0 or dims.h == 0) return;

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
                    dims,
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
                    dims,
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
                if (init_res.textures.matches(dims, target_format)) {
                    return;
                }

                const textures = createTextures(
                    dev,
                    dims,
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

/// Lifecycle state for an optional GPU pipeline compiled lazily on first use.
pub fn LazyPipeline(comptime Handle: type) type {
    return union(enum) {
        uninitialized,
        ready: Handle,
        failed,

        /// Returns the compiled pipeline handle if ready, or `null` otherwise.
        pub inline fn get(self: @This()) ?Handle {
            return switch (self) {
                .ready => |p| p,
                .uninitialized, .failed => null,
            };
        }
    };
}

/// Cached offscreen color target texture for headless rendering, reallocated
/// only when dimensions or format change.
pub const OffscreenTarget = union(enum) {
    unallocated,
    allocated: struct {
        texture: sdl.gpu.Texture,
        dims: PositiveDimsU32,
        format: sdl.gpu.TextureFormat,
    },

    /// Returns a cached texture matching `dims` and `format`, reallocating if
    /// absent or mismatched.
    pub fn ensure(
        self: *OffscreenTarget,
        dev: sdl.gpu.Device,
        dims: PositiveDimsU32,
        format: sdl.gpu.TextureFormat,
    ) !sdl.gpu.Texture {
        switch (self.*) {
            .allocated => |a| {
                if (a.dims.w == dims.w and
                    a.dims.h == dims.h and
                    a.format == format)
                {
                    return a.texture;
                }
                dev.releaseTexture(a.texture);
                self.* = .unallocated;
            },
            .unallocated => {},
        }
        const tex = dev.createTexture(&sdl.gpu.TextureCreateInfo{
            .type = .type_2d,
            .format = format,
            .usage = sdl.gpu.TextureUsage.color_target,
            .width = dims.w,
            .height = dims.h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = .count_1,
            .props = 0,
        }) orelse {
            std.log.err(
                "Failed to create offscreen target texture: {s}",
                .{sdl.getError()},
            );
            return error.OffscreenTargetTextureCreationFailed;
        };
        self.* = .{
            .allocated = .{
                .texture = tex,
                .dims = dims,
                .format = format,
            },
        };
        return tex;
    }

    /// Releases the cached offscreen texture if allocated, returning `true` if
    /// a texture was freed.
    pub fn release(self: *OffscreenTarget, dev: sdl.gpu.Device) bool {
        switch (self.*) {
            .allocated => |a| {
                dev.releaseTexture(a.texture);
                self.* = .unallocated;
                return true;
            },
            .unallocated => return false,
        }
    }
};

/// Mapped CPU-readable view of a downloaded GPU texture borrowing the caller's
/// `sdl.gpu.TransferBuffer`. Call `deinit` to unmap before issuing another
/// `downloadTexture` on the same buffer or releasing it.
pub const MappedReadback = struct {
    device: sdl.gpu.Device,
    transfer_buf: sdl.gpu.TransferBuffer,
    pixels: []u8,
    pitch: u32,
    dims: PositiveDimsU32,
    format: sdl.gpu.TextureFormat,

    /// Unmaps the underlying GPU download transfer buffer.
    pub fn deinit(self: MappedReadback) void {
        self.device.unmapTransferBuffer(self.transfer_buf);
    }
};

/// Cohesive GPU context and render resources initialized for GPU-accelerated
/// rendering.
pub const RenderResources = struct {
    io: std.Io,
    device: sdl.gpu.Device,
    swapchain_format: sdl.gpu.TextureFormat = .rgba8_unorm,
    image_pipeline: LazyPipeline(sdl.gpu.Pipeline) = .uninitialized,
    blit_pipeline: sdl.gpu.Pipeline,
    glyph_pipeline: sdl.gpu.Pipeline,
    sdf_pipeline: sdl.gpu.Pipeline,
    fullscreen_vertex_buffer: sdl.gpu.Buffer,
    unpack_compute_pipeline: LazyPipeline(sdl.gpu.ComputePipeline) =
        .uninitialized,
    sampler: sdl.gpu.Sampler,
    white_texture: sdl.gpu.Texture,

    // Offscreen blur subsystem (lazily initialized on first blur demand)
    blur: BlurResources = .uninitialized,

    // Reusable headless offscreen render target and GPU->CPU readback buffer
    offscreen_target: OffscreenTarget = .unallocated,
    download_buffer: sdl.gpu.RetainedTransferBuffer = .unallocated,

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
    fallback_font_attempted: bool = false,
    metrics: UiRenderMetrics = .{},

    /// Lazily loads and attaches the CJK/Unicode fallback font to
    /// `self.fonts[font_id]` on first non-ASCII glyph demand.
    pub fn ensureFallbackFont(self: *RenderResources, font_id: usize) void {
        if (font_id >= self.fonts.len) return;
        if (self.fonts[font_id]) |*font| {
            text_cache.ensureFallbackFont(font, &self.fallback_font_attempted);
        }
    }

    /// Lazily compiles and caches the full color-grading / resampling image
    /// pipeline on first demand. Latches `.failed` to avoid retry churn.
    pub fn ensureImagePipeline(self: *RenderResources) ?sdl.gpu.Pipeline {
        switch (self.image_pipeline) {
            .ready => |pipe| return pipe,
            .failed => return null,
            .uninitialized => {},
        }

        const dev = self.device;
        const shader_formats = dev.getShaderFormats();
        const vert_code_spv = @embedFile("shaders/vert.spv");
        const vert_code_msl = @embedFile("shaders/vert.msl");
        const image_frag_code_spv = @embedFile("shaders/image.frag.spv");
        const image_frag_code_msl = @embedFile("shaders/image.frag.msl");

        const vert_shader = createShaderFromFormat(
            dev,
            shader_formats,
            .vertex,
            vert_code_spv,
            vert_code_msl,
            0,
            0,
        ) catch {
            self.image_pipeline = .failed;
            return null;
        };
        defer dev.releaseShader(vert_shader);

        const image_frag_shader = createShaderFromFormat(
            dev,
            shader_formats,
            .fragment,
            image_frag_code_spv,
            image_frag_code_msl,
            1,
            1,
        ) catch {
            self.image_pipeline = .failed;
            return null;
        };
        defer dev.releaseShader(image_frag_shader);

        const color_targets = makeAlphaBlendColorTargets(self.swapchain_format);
        const pipeline_info = makeQuadPipelineInfo(
            vert_shader,
            image_frag_shader,
            &color_targets,
        );
        const pipe = dev.createPipeline(&pipeline_info) orelse {
            std.log.err(
                "Failed to create image graphics pipeline: {s}",
                .{sdl.getError()},
            );
            self.image_pipeline = .failed;
            return null;
        };
        self.image_pipeline = .{ .ready = pipe };
        return pipe;
    }

    /// Lazily compiles and caches the RGB24/BGR24 compute unpack pipeline on
    /// first demand. Latches `.failed` to avoid retry churn.
    pub fn ensureUnpackComputePipeline(
        self: *RenderResources,
    ) ?sdl.gpu.ComputePipeline {
        switch (self.unpack_compute_pipeline) {
            .ready => |pipe| return pipe,
            .failed => return null,
            .uninitialized => {},
        }

        const dev = self.device;
        const shader_formats = dev.getShaderFormats();
        const comp_code_spv = @embedFile("shaders/unpack_rgb.spv");
        const comp_code_msl = @embedFile("shaders/unpack_rgb.msl");

        const is_comp_spirv =
            (shader_formats & sdl.gpu.ShaderFormat.spirv) != 0;
        const comp_code = if (is_comp_spirv) comp_code_spv else comp_code_msl;
        const comp_fmt = if (is_comp_spirv)
            sdl.gpu.ShaderFormat.spirv
        else
            sdl.gpu.ShaderFormat.msl;
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
        const pipe = dev.createComputePipeline(&comp_pipeline_info) orelse {
            std.log.warn(
                "Failed to create unpack compute pipeline " ++
                    "(will fallback to SIMD): {s}",
                .{sdl.getError()},
            );
            self.unpack_compute_pipeline = .failed;
            return null;
        };
        self.unpack_compute_pipeline = .{ .ready = pipe };
        return pipe;
    }

    /// Snapshots UI vertex/batch counts and live font-atlas metrics for HUD
    /// overlay display.
    pub fn snapshotMetrics(
        self: *const RenderResources,
    ) UiRenderMetricsSnapshot {
        return .{
            .last_ui_vertex_count = self.metrics.last_ui_vertex_count,
            .last_ui_batch_count = self.metrics.last_ui_batch_count,
            .atlas_shelf_x = self.text_cache.packer.cur_x,
            .atlas_shelf_y = self.text_cache.packer.cur_y,
            .atlas_used_h = self.text_cache.usedHeight(),
            .atlas_page_count = self.text_cache.page_count,
            .atlas_ascii_glyphs = self.text_cache.countCachedAsciiGlyphs(),
            .atlas_unicode_glyphs = self.text_cache.glyphs.count(),
        };
    }

    /// Returns a `FontMeasurer` bound to this resource context's loaded fonts
    /// and glyph cache.
    pub inline fn fontMeasurer(self: *RenderResources) FontMeasurer {
        return .{
            .fonts = self.fonts[0..],
            .fallback_attempted = &self.fallback_font_attempted,
            .cache = &self.text_cache,
        };
    }

    /// Returns the unified UI + font glyph atlas texture when initialized,
    /// falling back to the 1x1 `white_texture`.
    pub inline fn uiTexture(self: *const RenderResources) sdl.gpu.Texture {
        return self.text_cache.atlas_texture orelse self.white_texture;
    }

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
    /// offscreen blur textures, headless offscreen target, download readback
    /// buffer, and double-buffered vertex/transfer buffers) while preserving
    /// compiled pipelines, sampler, white texture, and fonts.
    /// Returns `true` if any GPU resources were released.
    pub fn releaseTransientResources(
        self: *RenderResources,
        allocator: std.mem.Allocator,
    ) bool {
        var released = false;
        if (self.text_cache.hasResources()) {
            self.text_cache.deinit(allocator, self.device);
            self.text_cache = .{};
            released = true;
        }
        if (self.blur.releaseTextures(self.device)) {
            released = true;
        }
        if (self.offscreen_target.release(self.device)) {
            released = true;
        }
        switch (self.download_buffer) {
            .unallocated => {},
            .allocated => |a| {
                self.device.releaseTransferBuffer(a.handle);
                self.download_buffer = .unallocated;
                released = true;
            },
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
        self.metrics = .{};
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
        if (self.image_pipeline.get()) |pipe| {
            self.device.releasePipeline(pipe);
        }
        self.device.releasePipeline(self.blit_pipeline);
        self.device.releasePipeline(self.glyph_pipeline);
        self.device.releasePipeline(self.sdf_pipeline);
        if (self.unpack_compute_pipeline.get()) |pipe| {
            self.device.releaseComputePipeline(pipe);
        }
        self.device.releaseSampler(self.sampler);
        self.device.releaseTexture(self.white_texture);
    }
};

// Zig's test runner fails tests on any `std.log.err`; headless CI tests
// expect SDL/GPU init to fail and skip cleanly.
fn logInitErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        std.log.err(fmt, args);
    }
}

/// Initializes SDL3 subsystems (video and events) and TTF engine.
/// Must be called before background workers start pushing SDL events or loading
/// surfaces.
pub fn initSdlCore(headless: bool) !void {
    if (headless and builtin.os.tag != .macos and builtin.os.tag != .windows) {
        _ = sdl.hint.set("SDL_VIDEO_DRIVER", "offscreen");
    }
    // Keep window close (SDL_EVENT_WINDOW_CLOSE_REQUESTED) distinct from
    // process termination (SDL_EVENT_QUIT from SIGINT/SIGTERM) so server mode
    // hides the window on close while exiting cleanly on termination signals.
    _ = sdl.hint.set("SDL_QUIT_ON_LAST_WINDOW_CLOSE", "0");

    // Allow the OS screensaver and power management by default; we dynamically
    // inhibit it only while an active slideshow is playing in a visible window.
    _ = sdl.hint.set("SDL_VIDEO_ALLOW_SCREENSAVER", "1");
    _ = sdl.hint.set(
        "SDL_SCREENSAVER_INHIBIT_ACTIVITY_NAME",
        "Viewing a slideshow",
    );
    _ = sdl.hint.set("SDL_APP_NAME", "Peng");
    // Disable 3D acceleration for `SDL_GetWindowSurface` so software-first
    // startup stays pure CPU for fast first-frame display (no OpenGL/EGL
    // init). Rendering upgrades to the hardware-accelerated SDL GPU pipeline
    // (Vulkan/Metal) once background device initialization finishes.
    _ = sdl.hint.set("SDL_FRAMEBUFFER_ACCELERATION", "0");

    if (!sdl.init(sdl.init_flags.video | sdl.init_flags.events)) {
        logInitErr("SDL_Init Error: {s}", .{sdl.getError()});
        return error.SDLInitFailed;
    }
    errdefer sdl.quit();

    sdl.initTtf() catch |err| {
        logInitErr("TTF_Init Error: {}", .{err});
        return error.TTFInitFailed;
    };
}

/// Shuts down SDL TTF engine and SDL subsystems.
pub fn quitSdlCore() void {
    sdl.quitTtf();
    sdl.quit();
}

/// Creates the main SDL window and queries its initial DPI scale without
/// initializing a GPU device yet. Assumes `initSdlCore` has been called.
pub fn createWindowOnly(
    window_title: [:0]const u8,
    options: GraphicsOptions,
) !WindowSetup {
    std.debug.assert(
        (sdl.wasInit(sdl.init_flags.video) & sdl.init_flags.video) != 0,
    );
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
    const window =
        sdl.Window.createZ(window_title, 1024, 768, win_flags) orelse {
            logInitErr("SDL_CreateWindow Error: {s}", .{sdl.getError()});
            return error.WindowCreationFailed;
        };
    errdefer window.destroy();

    const win_size = window.getSize();
    const pix_size = window.getSizeInPixels();
    const initial_dpi_scale = if (win_size.w > 0)
        @as(f32, @floatFromInt(pix_size.w)) /
            @as(f32, @floatFromInt(win_size.w))
    else
        1.0;

    return .{
        .window = window,
        .initial_dpi_scale = initial_dpi_scale,
    };
}

/// Creates an SDL3 GPU device (SPIR-V/MSL) without requiring a window.
/// Assumes `initSdlCore` has been called.
pub fn createGpuDevice(debug_mode: bool) !sdl.gpu.Device {
    std.debug.assert(
        (sdl.wasInit(sdl.init_flags.video) & sdl.init_flags.video) != 0,
    );
    const shader_flags = sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl;
    return sdl.gpu.Device.create(shader_flags, debug_mode) orelse {
        logInitErr("SDL_CreateGPUDevice Error: {s}", .{sdl.getError()});
        return error.DeviceCreationFailed;
    };
}

/// Creates the main window and claims the GPU graphics device.
/// Assumes SDL core and TTF subsystems have been initialized via `initSdlCore`.
pub fn initGraphicsAndWindow(
    window_title: [:0]const u8,
    options: GraphicsOptions,
) !GraphicsSetup {
    const win_setup = try createWindowOnly(window_title, options);
    errdefer win_setup.window.destroy();

    const dev = try createGpuDevice(options.debug_mode);
    errdefer dev.destroy();

    // Claim window for GPU
    if (!options.headless) {
        if (!win_setup.window.claimForGpu(dev)) {
            logInitErr(
                "SDL_ClaimWindowForGPUDevice failed: {s}",
                .{sdl.getError()},
            );
            return error.ClaimWindowFailed;
        }
    }

    return GraphicsSetup{
        .window = win_setup.window,
        .gpu_device = dev,
        .initial_dpi_scale = win_setup.initial_dpi_scale,
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
    const fmt =
        if (is_spirv) sdl.gpu.ShaderFormat.spirv else sdl.gpu.ShaderFormat.msl;
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
        std.log.err(
            "Failed to create shader for stage {}: {s}",
            .{ stage, sdl.getError() },
        );
        return error.ShaderCreationFailed;
    };
}

fn makeAlphaBlendColorTargets(
    target_format: sdl.gpu.TextureFormat,
) [1]sdl.gpu.ColorTargetDescription {
    return .{.{
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
    }};
}

fn makeQuadPipelineInfo(
    vertex_shader: sdl.gpu.Shader,
    fragment_shader: sdl.gpu.Shader,
    color_targets: *const [1]sdl.gpu.ColorTargetDescription,
) sdl.gpu.GraphicsPipelineCreateInfo {
    return .{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
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
            .color_target_descriptions = color_targets,
            .has_depth_stencil_target = false,
            .depth_stencil_format = .d16_unorm,
        },
        .props = 0,
    };
}

/// Creates core GPU pipelines, samplers, primary font, and static buffers.
/// Targets either a GPU-claimed window swapchain format or headless offscreen
/// rendering (`.rgba8_unorm`). Heavy optional resources (`image_pipeline`,
/// RGB24 compute unpack, blur pipelines, and CJK fallback font) are
/// initialized lazily on first demand to minimize cold-start latency.
pub fn initGpuResources(
    io: std.Io,
    dev: sdl.gpu.Device,
    target: ResourceTarget,
    initial_dpi_scale: f32,
) !RenderResources {
    const target_format = switch (target) {
        .window => |win| dev.getSwapchainTextureFormat(win),
        .headless => sdl.gpu.TextureFormat.rgba8_unorm,
    };

    // Load primary UI font from memory (CJK fallback `unifont_jp.otf` is
    // attached lazily on first non-ASCII glyph demand).
    const initial_font_size = 20.0 * initial_dpi_scale;
    const roboto_font_bytes = @embedFile("resources/Roboto-Regular.ttf");
    const font = sdl.Font.openConstMem(
        roboto_font_bytes,
        initial_font_size,
    ) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{sdl.getError()});
        return error.TTFOpenFontFailed;
    };
    errdefer font.close();

    const fonts = [1]?sdl.Font{font};

    // Compile lightweight UI/blit shaders (`image.frag` and `unpack_rgb` are
    // compiled lazily on first demand).
    const vert_code_spv = @embedFile("shaders/vert.spv");
    const vert_code_msl = @embedFile("shaders/vert.msl");
    const blit_frag_code_spv = @embedFile("shaders/blit.frag.spv");
    const blit_frag_code_msl = @embedFile("shaders/blit.frag.msl");

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

    const blit_frag_shader = try createShaderFromFormat(
        dev,
        shader_formats,
        .fragment,
        blit_frag_code_spv,
        blit_frag_code_msl,
        1,
        0,
    );
    defer dev.releaseShader(blit_frag_shader);

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
        .usage = sdl.gpu.TextureUsage.sampler |
            sdl.gpu.TextureUsage.color_target,
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

    // Create textured-quad blit Graphics Pipeline (glyphs, fast image blit)
    const color_targets = makeAlphaBlendColorTargets(target_format);
    const blit_pipeline_info = makeQuadPipelineInfo(
        vert_shader,
        blit_frag_shader,
        &color_targets,
    );
    const blit_pipeline = dev.createPipeline(&blit_pipeline_info) orelse {
        std.log.err(
            "Failed to create blit graphics pipeline: {s}",
            .{sdl.getError()},
        );
        return error.PipelineCreationFailed;
    };
    errdefer dev.releasePipeline(blit_pipeline);

    // Create R8 glyph atlas Graphics Pipeline
    const glyph_frag_spv = @embedFile("shaders/glyph.frag.spv");
    const glyph_frag_msl = @embedFile("shaders/glyph.frag.msl");
    const glyph_frag = try createShaderFromFormat(
        dev,
        shader_formats,
        .fragment,
        glyph_frag_spv,
        glyph_frag_msl,
        1,
        0,
    );
    defer dev.releaseShader(glyph_frag);

    const glyph_pipeline_info = makeQuadPipelineInfo(
        vert_shader,
        glyph_frag,
        &color_targets,
    );
    const glyph_pipeline = dev.createPipeline(&glyph_pipeline_info) orelse {
        std.log.err(
            "Failed to create glyph graphics pipeline: {s}",
            .{sdl.getError()},
        );
        return error.PipelineCreationFailed;
    };
    errdefer dev.releasePipeline(glyph_pipeline);

    // Create instanced SDF UI Graphics Pipeline
    const sdf_vert_spv = @embedFile("shaders/sdf.vert.spv");
    const sdf_vert_msl = @embedFile("shaders/sdf.vert.msl");
    const sdf_frag_spv = @embedFile("shaders/sdf.frag.spv");
    const sdf_frag_msl = @embedFile("shaders/sdf.frag.msl");

    const sdf_vert = try createShaderFromFormat(
        dev,
        shader_formats,
        .vertex,
        sdf_vert_spv,
        sdf_vert_msl,
        0,
        1,
    );
    defer dev.releaseShader(sdf_vert);

    const sdf_frag = try createShaderFromFormat(
        dev,
        shader_formats,
        .fragment,
        sdf_frag_spv,
        sdf_frag_msl,
        1,
        0,
    );
    defer dev.releaseShader(sdf_frag);

    var sdf_pipeline_info = makeQuadPipelineInfo(
        sdf_vert,
        sdf_frag,
        &color_targets,
    );
    sdf_pipeline_info.vertex_input_state = .{
        .num_vertex_attributes = sdf_vertex_attribs.len,
        .vertex_attributes = &sdf_vertex_attribs,
        .num_vertex_buffers = sdf_vertex_buf_descs.len,
        .vertex_buffer_descriptions = &sdf_vertex_buf_descs,
    };
    const sdf_pipeline = dev.createPipeline(&sdf_pipeline_info) orelse {
        std.log.err(
            "Failed to create SDF graphics pipeline: {s}",
            .{sdl.getError()},
        );
        return error.PipelineCreationFailed;
    };
    errdefer dev.releasePipeline(sdf_pipeline);

    // Create static 6-vertex buffer for fullscreen passes
    const fullscreen_vertex_buffer = dev.createBuffer(&sdl.gpu.BufferCreateInfo{
        .usage = sdl.gpu.BufferUsage.vertex,
        .size = @intCast(StaticInitPayload.verts_size),
        .props = 0,
    }) orelse return error.GPUVertexBufferCreationFailed;
    errdefer dev.releaseBuffer(fullscreen_vertex_buffer);

    // Upload static 1x1 white pixel texture and 6-vertex fullscreen quad in
    // a single copy pass
    {
        const transfer_buf =
            dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
                .usage = .upload,
                .size = @intCast(@sizeOf(StaticInitPayload)),
                .props = 0,
            }) orelse return error.TransferBufferCreationFailed;
        defer dev.releaseTransferBuffer(transfer_buf);

        const mapped: *StaticInitPayload = @ptrCast(@alignCast(
            dev.mapTransferBuffer(transfer_buf, false) orelse
                return error.MapFailed,
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

    return RenderResources{
        .io = io,
        .device = dev,
        .swapchain_format = target_format,
        .image_pipeline = .uninitialized,
        .blit_pipeline = blit_pipeline,
        .glyph_pipeline = glyph_pipeline,
        .sdf_pipeline = sdf_pipeline,
        .blur = .uninitialized,
        .fullscreen_vertex_buffer = fullscreen_vertex_buffer,
        .unpack_compute_pipeline = .uninitialized,
        .sampler = sampler,
        .white_texture = white_texture,
        .fonts = fonts,
    };
}

fn getTextureFormatElementSize(format: sdl.gpu.TextureFormat) u32 {
    return switch (format) {
        .r8_unorm => 1,
        .rgba8_unorm, .bgra8_unorm, .bgra8_unorm_srgb, .rgba8_unorm_srgb => 4,
        .r16g16b16a16_float => 8,
        .r32g32b32a32_float => 16,
        else => 4, // Fallback safe default
    };
}

fn ensureDownloadTransferBuffer(
    dev: sdl.gpu.Device,
    slot: *sdl.gpu.RetainedTransferBuffer,
    required_size: u32,
) !sdl.gpu.TransferBuffer {
    switch (slot.*) {
        .allocated => |a| {
            if (a.capacity >= required_size) return a.handle;
            dev.releaseTransferBuffer(a.handle);
            slot.* = .unallocated;
        },
        .unallocated => {},
    }
    const tb = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
        .usage = .download,
        .size = required_size,
        .props = 0,
    }) orelse {
        std.log.err(
            "Failed to create download transfer buffer: {s}",
            .{sdl.getError()},
        );
        return error.TransferBufferCreationFailed;
    };
    slot.* = .{
        .allocated = .{
            .handle = tb,
            .capacity = required_size,
        },
    };
    return tb;
}

/// Records a GPU-to-CPU copy of `texture` into `download_buf` (growing it if
/// needed), submits `cmd`, waits on the fence, and returns a `MappedReadback`
/// view of the downloaded pixels. Consumes `cmd` (submits or cancels on error).
pub fn downloadTexture(
    dev: sdl.gpu.Device,
    cmd: sdl.gpu.CommandBuffer,
    download_buf: *sdl.gpu.RetainedTransferBuffer,
    texture: sdl.gpu.Texture,
    dims: PositiveDimsU32,
    texture_format: sdl.gpu.TextureFormat,
) !MappedReadback {
    var cmd_consumed = false;
    errdefer if (!cmd_consumed) {
        _ = cmd.cancel();
    };

    const bpp = getTextureFormatElementSize(texture_format);
    const pitch = std.math.mul(u32, dims.w, bpp) catch
        return error.ReadbackSizeOverflow;
    const size = std.math.mul(u32, pitch, dims.h) catch
        return error.ReadbackSizeOverflow;

    const transfer_buf = try ensureDownloadTransferBuffer(
        dev,
        download_buf,
        size,
    );

    const copy_pass = cmd.beginCopyPass() orelse {
        std.log.err(
            "SDL GPU beginCopyPass failed for texture readback: {s}",
            .{sdl.getError()},
        );
        return error.CopyPassCreationFailed;
    };
    copy_pass.downloadFromTexture(&sdl.gpu.TextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = dims.w,
        .h = dims.h,
        .d = 1,
    }, &sdl.gpu.TextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = dims.w,
        .rows_per_layer = dims.h,
    });
    copy_pass.end();

    cmd_consumed = true;
    const fence = cmd.submitAndAcquireFence() orelse {
        std.log.err(
            "Failed to acquire GPU fence for texture readback: {s}",
            .{sdl.getError()},
        );
        return error.FenceAcquisitionFailed;
    };
    defer dev.releaseFence(fence);
    if (!dev.waitForFence(fence)) {
        std.log.err(
            "SDL GPU waitForFence failed for texture readback: {s}",
            .{sdl.getError()},
        );
        return error.FenceWaitFailed;
    }

    const data_ptr = dev.mapTransferBuffer(transfer_buf, false) orelse {
        std.log.err(
            "SDL GPU mapTransferBuffer failed for texture readback: {s}",
            .{sdl.getError()},
        );
        return error.MapBufferFailed;
    };

    return .{
        .device = dev,
        .transfer_buf = transfer_buf,
        .pixels = data_ptr[0..size],
        .pitch = pitch,
        .dims = dims,
        .format = texture_format,
    };
}

/// Encodes a mapped GPU texture `readback` and saves it as a PNG file.
pub fn saveReadbackToPng(
    readback: MappedReadback,
    filename: [:0]const u8,
) !void {
    const pixel_fmt = switch (readback.format) {
        .rgba8_unorm, .rgba8_unorm_srgb => sdl.PixelFormat.rgba32,
        .bgra8_unorm, .bgra8_unorm_srgb => sdl.PixelFormat.bgra32,
        else => return error.UnsupportedReadbackFormat,
    };

    const w_i32 = std.math.cast(i32, readback.dims.w) orelse
        return error.ReadbackSizeOverflow;
    const h_i32 = std.math.cast(i32, readback.dims.h) orelse
        return error.ReadbackSizeOverflow;
    const pitch_i32 = std.math.cast(i32, readback.pitch) orelse
        return error.ReadbackSizeOverflow;

    const surface = sdl.Surface.createFrom(
        w_i32,
        h_i32,
        pixel_fmt,
        readback.pixels.ptr,
        pitch_i32,
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

test "BlurResources tagged union lifecycle and failure latching" {
    var blur: BlurResources = .uninitialized;
    try std.testing.expect(blur == .uninitialized);
    try std.testing.expect(blur.getBlurTexture() == null);

    // Window dimensions of zero must short-circuit without attempting GPU
    // calls or mutating state
    const dummy_dev: sdl.gpu.Device = .{ .ptr = @ptrFromInt(0x1000) };
    blur.ensure(dummy_dev, .{ .w = 0, .h = 0 }, .rgba8_unorm);
    try std.testing.expect(blur == .uninitialized);

    // Initialized state composes session-lifetime Pipelines and window-sized
    // Textures
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
                .target_dims = .{ .w = 800, .h = 600 },
                .target_format = .rgba8_unorm,
                .half_dims = .{ .w = 400, .h = 300 },
                .down_dims = .{ .w = 200, .h = 150 },
            },
        },
    };
    try std.testing.expect(blur == .initialized);
    try std.testing.expect(
        blur.initialized.textures.matches(
            .{ .w = 800, .h = 600 },
            .rgba8_unorm,
        ),
    );
    try std.testing.expect(
        !blur.initialized.textures.matches(
            .{ .w = 1024, .h = 768 },
            .rgba8_unorm,
        ),
    );
    try std.testing.expectEqual(
        @as(?sdl.gpu.Texture, .{ .ptr = @ptrFromInt(0x2005) }),
        blur.getBlurTexture(),
    );

    // Calling ensure with matching dimensions on initialized resources is a
    // no-op
    blur.ensure(dummy_dev, .{ .w = 800, .h = 600 }, .rgba8_unorm);
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
    blur.ensure(dummy_dev, .{ .w = 800, .h = 600 }, .rgba8_unorm);
    try std.testing.expect(blur == .failed);

    // Deinit on failed resets state back to uninitialized without
    // dereferencing dev
    blur.deinit(dummy_dev);
    try std.testing.expect(blur == .uninitialized);
}

test "StaticInitPayload packs fullscreen quad and 4-byte aligned white pixel" {
    const payload = StaticInitPayload{};
    try std.testing.expectEqual(@as(usize, 0), StaticInitPayload.verts_offset);
    try std.testing.expectEqual(
        @as(usize, 6 * @sizeOf(geometry.Vertex)),
        StaticInitPayload.verts_size,
    );
    try std.testing.expectEqual(
        @as(usize, 120),
        StaticInitPayload.pixel_offset,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        StaticInitPayload.pixel_offset % 4,
    );
    try std.testing.expectEqual(@as(usize, 124), @sizeOf(StaticInitPayload));
    try std.testing.expectEqualSlices(
        u8,
        &.{ 255, 255, 255, 255 },
        &payload.white_pixel,
    );
    try std.testing.expectEqual(@as(usize, 6), payload.fullscreen_verts.len);
}

test "RenderResources.snapshotMetrics combines pass and atlas telemetry" {
    initSdlCore(true) catch return;
    defer quitSdlCore();

    const dev = createGpuDevice(false) catch return;
    defer dev.destroy();

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var gpu_res = initGpuResources(io, dev, .headless, 1.0) catch return;
    defer gpu_res.deinit(allocator);

    gpu_res.metrics.last_ui_vertex_count = 360;
    gpu_res.metrics.last_ui_batch_count = 6;
    gpu_res.text_cache.packer.cur_x = 128;
    gpu_res.text_cache.packer.cur_y = 64;
    gpu_res.text_cache.page_count = 1;

    const snap = gpu_res.snapshotMetrics();
    try std.testing.expectEqual(@as(usize, 360), snap.last_ui_vertex_count);
    try std.testing.expectEqual(@as(usize, 6), snap.last_ui_batch_count);
    try std.testing.expectEqual(@as(u32, 128), snap.atlas_shelf_x);
    try std.testing.expectEqual(@as(u32, 64), snap.atlas_shelf_y);
    try std.testing.expectEqual(
        gpu_res.text_cache.usedHeight(),
        snap.atlas_used_h,
    );
    try std.testing.expectEqual(@as(usize, 1), snap.atlas_page_count);

    // First call releases text_cache (page_count == 1) and resets metrics.
    try std.testing.expect(gpu_res.releaseTransientResources(allocator));
    const reset_snap = gpu_res.snapshotMetrics();
    try std.testing.expectEqual(
        @as(usize, 0),
        reset_snap.last_ui_vertex_count,
    );
    try std.testing.expectEqual(@as(usize, 0), reset_snap.last_ui_batch_count);

    // Subsequent call with only metrics populated must return false while
    // still resetting metrics.
    gpu_res.metrics.last_ui_vertex_count = 42;
    gpu_res.metrics.last_ui_batch_count = 3;
    try std.testing.expect(!gpu_res.releaseTransientResources(allocator));
    const second_snap = gpu_res.snapshotMetrics();
    try std.testing.expectEqual(
        @as(usize, 0),
        second_snap.last_ui_vertex_count,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        second_snap.last_ui_batch_count,
    );
}

test "OffscreenTarget reuses handle and downloadTexture reads clear color" {
    initSdlCore(true) catch return;
    defer quitSdlCore();

    const dev = createGpuDevice(false) catch return;
    defer dev.destroy();

    var target: OffscreenTarget = .unallocated;
    defer _ = target.release(dev);

    const dims = PositiveDimsU32{ .w = 4, .h = 2 };
    const tex1 = try target.ensure(dev, dims, .rgba8_unorm);
    const tex2 = try target.ensure(dev, dims, .rgba8_unorm);
    try std.testing.expect(tex1.eql(tex2));

    var download_buf: sdl.gpu.RetainedTransferBuffer = .unallocated;
    defer switch (download_buf) {
        .unallocated => {},
        .allocated => |a| dev.releaseTransferBuffer(a.handle),
    };

    const cmd = dev.acquireCommandBuffer() orelse
        return error.CommandBufferAcquisitionFailed;
    const attachment = sdl.gpu.ColorTargetAttachment{
        .texture = tex1,
        .clear_color = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        .load_op = .clear,
        .store_op = .store,
        .cycle = false,
    };
    const pass = cmd.beginRenderPass(&attachment) orelse {
        _ = cmd.cancel();
        return error.RenderPassFailed;
    };
    pass.end();

    {
        const readback = try downloadTexture(
            dev,
            cmd,
            &download_buf,
            tex1,
            dims,
            .rgba8_unorm,
        );
        defer readback.deinit();

        try std.testing.expectEqual(@as(u32, 16), readback.pitch);
        try std.testing.expectEqual(@as(usize, 32), readback.pixels.len);
        try std.testing.expectEqualSlices(
            u8,
            &.{ 255, 0, 0, 255 },
            readback.pixels[0..4],
        );
    }

    // Resize reallocates offscreen target and grows download transfer buffer.
    const big_dims = PositiveDimsU32{ .w = 8, .h = 4 };
    const tex3 = try target.ensure(dev, big_dims, .rgba8_unorm);
    const cmd2 = dev.acquireCommandBuffer() orelse
        return error.CommandBufferAcquisitionFailed;
    const attachment2 = sdl.gpu.ColorTargetAttachment{
        .texture = tex3,
        .clear_color = .{ .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 },
        .load_op = .clear,
        .store_op = .store,
        .cycle = false,
    };
    const pass2 = cmd2.beginRenderPass(&attachment2) orelse {
        _ = cmd2.cancel();
        return error.RenderPassFailed;
    };
    pass2.end();

    {
        const readback2 = try downloadTexture(
            dev,
            cmd2,
            &download_buf,
            tex3,
            big_dims,
            .rgba8_unorm,
        );
        defer readback2.deinit();

        try std.testing.expectEqual(@as(u32, 32), readback2.pitch);
        try std.testing.expectEqual(@as(usize, 128), readback2.pixels.len);
        try std.testing.expectEqualSlices(
            u8,
            &.{ 0, 255, 0, 255 },
            readback2.pixels[0..4],
        );
    }

    try std.testing.expect(target.release(dev));
    try std.testing.expect(!target.release(dev));
}
