const std = @import("std");
const c = @import("c.zig").c;

pub const TextureFormat = enum(c_int) {
    rgba8_unorm = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
    bgra8_unorm = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
    bgra8_unorm_srgb = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB,
    rgba8_unorm_srgb = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB,
    r16g16b16a16_float = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
    r32g32b32a32_float = c.SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT,
    d16_unorm = c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
    invalid = c.SDL_GPU_TEXTUREFORMAT_INVALID,
    _,
};

/// Bitflag constants indicating supported GPU shader bytecode or shading language formats.
pub const ShaderFormat = struct {
    pub const spirv: u32 = c.SDL_GPU_SHADERFORMAT_SPIRV;
    pub const msl: u32 = c.SDL_GPU_SHADERFORMAT_MSL;
};

pub const ShaderStage = enum(c_int) {
    vertex = c.SDL_GPU_SHADERSTAGE_VERTEX,
    fragment = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
};

pub const TextureType = enum(c_int) {
    type_2d = c.SDL_GPU_TEXTURETYPE_2D,
};

/// Bitflag constants defining intended GPU texture usages and binding targets.
pub const TextureUsage = struct {
    pub const sampler: u32 = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
    pub const color_target: u32 = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
    pub const compute_storage_write: u32 = c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE;
    pub const compute_storage_simultaneous_read_write: u32 =
        c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE;
};

/// Bitflag constants specifying GPU buffer bindings and capabilities.
pub const BufferUsage = struct {
    pub const vertex: u32 = c.SDL_GPU_BUFFERUSAGE_VERTEX;
    pub const index: u32 = c.SDL_GPU_BUFFERUSAGE_INDEX;
    pub const compute_storage_read: u32 = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ;
    pub const compute_storage_write: u32 = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE;
};

pub const SampleCount = enum(c_int) {
    count_1 = c.SDL_GPU_SAMPLECOUNT_1,
    count_2 = c.SDL_GPU_SAMPLECOUNT_2,
    count_4 = c.SDL_GPU_SAMPLECOUNT_4,
    count_8 = c.SDL_GPU_SAMPLECOUNT_8,
};

pub const Filter = enum(c_int) {
    nearest = c.SDL_GPU_FILTER_NEAREST,
    linear = c.SDL_GPU_FILTER_LINEAR,
};

pub const SamplerMipmapMode = enum(c_int) {
    nearest = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
    linear = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
};

pub const SamplerAddressMode = enum(c_int) {
    repeat = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
    mirrored_repeat = c.SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT,
    clamp_to_edge = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
};

pub const CompareOp = enum(c_int) {
    invalid = c.SDL_GPU_COMPAREOP_INVALID,
    never = c.SDL_GPU_COMPAREOP_NEVER,
    less = c.SDL_GPU_COMPAREOP_LESS,
    equal = c.SDL_GPU_COMPAREOP_EQUAL,
    less_or_equal = c.SDL_GPU_COMPAREOP_LESS_OR_EQUAL,
    greater = c.SDL_GPU_COMPAREOP_GREATER,
    not_equal = c.SDL_GPU_COMPAREOP_NOT_EQUAL,
    greater_or_equal = c.SDL_GPU_COMPAREOP_GREATER_OR_EQUAL,
    always = c.SDL_GPU_COMPAREOP_ALWAYS,
};

pub const StencilOp = enum(c_int) {
    keep = c.SDL_GPU_STENCILOP_KEEP,
};

pub const FillMode = enum(c_int) {
    fill = c.SDL_GPU_FILLMODE_FILL,
    line = c.SDL_GPU_FILLMODE_LINE,
};

pub const CullMode = enum(c_int) {
    none = c.SDL_GPU_CULLMODE_NONE,
    front = c.SDL_GPU_CULLMODE_FRONT,
    back = c.SDL_GPU_CULLMODE_BACK,
};

pub const FrontFace = enum(c_int) {
    counter_clockwise = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
    clockwise = c.SDL_GPU_FRONTFACE_CLOCKWISE,
};

pub const BlendFactor = enum(c_int) {
    invalid = c.SDL_GPU_BLENDFACTOR_INVALID,
    zero = c.SDL_GPU_BLENDFACTOR_ZERO,
    one = c.SDL_GPU_BLENDFACTOR_ONE,
    src_color = c.SDL_GPU_BLENDFACTOR_SRC_COLOR,
    one_minus_src_color = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_COLOR,
    src_alpha = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
    one_minus_src_alpha = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
    dst_alpha = c.SDL_GPU_BLENDFACTOR_DST_ALPHA,
    one_minus_dst_alpha = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_DST_ALPHA,
    dst_color = c.SDL_GPU_BLENDFACTOR_DST_COLOR,
    one_minus_dst_color = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_DST_COLOR,
    src_alpha_saturate = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA_SATURATE,
};

pub const BlendOp = enum(c_int) {
    invalid = c.SDL_GPU_BLENDOP_INVALID,
    add = c.SDL_GPU_BLENDOP_ADD,
    subtract = c.SDL_GPU_BLENDOP_SUBTRACT,
    reverse_subtract = c.SDL_GPU_BLENDOP_REVERSE_SUBTRACT,
    min = c.SDL_GPU_BLENDOP_MIN,
    max = c.SDL_GPU_BLENDOP_MAX,
};

pub const LoadOp = enum(c_int) {
    load = c.SDL_GPU_LOADOP_LOAD,
    clear = c.SDL_GPU_LOADOP_CLEAR,
    dont_care = c.SDL_GPU_LOADOP_DONT_CARE,
};

pub const StoreOp = enum(c_int) {
    store = c.SDL_GPU_STOREOP_STORE,
    dont_care = c.SDL_GPU_STOREOP_DONT_CARE,
    resolve = c.SDL_GPU_STOREOP_RESOLVE,
};

pub const TransferBufferUsage = enum(c_int) {
    upload = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
    download = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
};

pub const PrimitiveType = enum(c_int) {
    triangle_list = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
    triangle_strip = c.SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP,
    line_list = c.SDL_GPU_PRIMITIVETYPE_LINELIST,
    line_strip = c.SDL_GPU_PRIMITIVETYPE_LINESTRIP,
    point_list = c.SDL_GPU_PRIMITIVETYPE_POINTLIST,
};

pub const VertexElementFormat = enum(c_int) {
    float2 = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
    float4 = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
    ubyte4_norm = c.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM,
};

pub const VertexInputRate = enum(c_int) {
    vertex = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
    instance = c.SDL_GPU_VERTEXINPUTRATE_INSTANCE,
};

/// Bitflag mask constants for color channel writes in pipeline blend states.
pub const ColorComponent = struct {
    pub const r: u8 = c.SDL_GPU_COLORCOMPONENT_R;
    pub const g: u8 = c.SDL_GPU_COLORCOMPONENT_G;
    pub const b: u8 = c.SDL_GPU_COLORCOMPONENT_B;
    pub const a: u8 = c.SDL_GPU_COLORCOMPONENT_A;
};

/// Opaque handle representing a GPU texture resource.
pub const Texture = struct {
    ptr: *c.SDL_GPUTexture,

    /// Compares two texture handles for pointer equality.
    pub fn eql(self: Texture, other: Texture) bool {
        return self.ptr == other.ptr;
    }

    /// Returns the underlying raw texture pointer as a type-erased opaque pointer.
    pub fn asOpaque(self: Texture) *anyopaque {
        return @ptrCast(self.ptr);
    }
};

/// Opaque handle representing a GPU data buffer.
pub const Buffer = struct {
    ptr: *c.SDL_GPUBuffer,
};

/// Opaque handle representing a GPU texture sampler configuration.
pub const Sampler = struct {
    ptr: *c.SDL_GPUSampler,
};

/// Opaque handle representing a compiled GPU vertex or fragment shader.
pub const Shader = struct {
    ptr: *c.SDL_GPUShader,
};

/// Opaque handle representing a compiled GPU graphics pipeline state object.
pub const Pipeline = struct {
    ptr: *c.SDL_GPUGraphicsPipeline,
};

/// Opaque handle representing a compiled GPU compute pipeline state object.
pub const ComputePipeline = struct {
    ptr: *c.SDL_GPUComputePipeline,
};

/// Opaque handle representing host-accessible staging memory for GPU transfers.
pub const TransferBuffer = struct {
    ptr: *c.SDL_GPUTransferBuffer,
};

/// Opaque handle representing a GPU execution synchronization fence.
pub const Fence = struct {
    ptr: *c.SDL_GPUFence,
};

/// Parameters configuring GPU texture dimension, format, and usage during creation.
pub const TextureCreateInfo = struct {
    type: TextureType = .type_2d,
    format: TextureFormat = .rgba8_unorm,
    usage: u32 = TextureUsage.sampler,
    width: u32,
    height: u32,
    layer_count_or_depth: u32 = 1,
    num_levels: u32 = 1,
    sample_count: SampleCount = .count_1,
    props: u32 = 0,
};

/// Parameters configuring texture filtering, addressing modes, and LOD sampling.
pub const SamplerCreateInfo = struct {
    min_filter: Filter = .linear,
    mag_filter: Filter = .linear,
    mipmap_mode: SamplerMipmapMode = .linear,
    address_mode_u: SamplerAddressMode = .clamp_to_edge,
    address_mode_v: SamplerAddressMode = .clamp_to_edge,
    address_mode_w: SamplerAddressMode = .clamp_to_edge,
    mip_lod_bias: f32 = 0.0,
    max_anisotropy: f32 = 1.0,
    compare_op: CompareOp = .never,
    min_lod: f32 = 0.0,
    max_lod: f32 = 1000.0,
    props: u32 = 0,
};

/// Parameters and bytecode payload for compiling a GPU shader stage.
pub const ShaderCreateInfo = struct {
    code_size: usize,
    code: [*]const u8,
    entrypoint: [:0]const u8,
    format: u32,
    stage: ShaderStage,
    num_samplers: u32 = 0,
    num_storage_textures: u32 = 0,
    num_storage_buffers: u32 = 0,
    num_uniform_buffers: u32 = 0,
    props: u32 = 0,
};

/// Parameters, shader code, and resource bindings for creating a compute pipeline.
pub const ComputePipelineCreateInfo = struct {
    code_size: usize,
    code: [*]const u8,
    entrypoint: [:0]const u8,
    format: u32,
    num_samplers: u32 = 0,
    num_readonly_storage_textures: u32 = 0,
    num_readonly_storage_buffers: u32 = 0,
    num_readwrite_storage_textures: u32 = 0,
    num_readwrite_storage_buffers: u32 = 0,
    num_uniform_buffers: u32 = 0,
    threadcount_x: u32 = 16,
    threadcount_y: u32 = 16,
    threadcount_z: u32 = 1,
    props: u32 = 0,
};

/// Binding descriptor for a read-write storage texture in compute passes.
pub const StorageTextureReadWriteBinding = struct {
    texture: Texture,
    mip_level: u32 = 0,
    layer: u32 = 0,
    cycle: bool = false,
};

/// Binding descriptor for a read-write storage buffer in compute passes.
pub const StorageBufferReadWriteBinding = struct {
    buffer: Buffer,
    cycle: bool = false,
};

/// Parameters configuring transfer buffer allocation size and direction (upload/download).
pub const TransferBufferCreateInfo = struct {
    usage: TransferBufferUsage,
    size: u32,
    props: u32 = 0,
};

/// Parameters configuring GPU buffer capacity and usage flags.
pub const BufferCreateInfo = struct {
    usage: u32,
    size: u32,
    props: u32 = 0,
};

/// Staging transfer buffer layout information for texture copy operations.
pub const TextureTransferInfo = struct {
    transfer_buffer: TransferBuffer,
    offset: u32 = 0,
    pixels_per_row: u32 = 0,
    rows_per_layer: u32 = 0,
};

/// Sub-region coordinates and dimensions of a GPU texture slice.
pub const TextureRegion = struct {
    texture: Texture,
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
    w: u32,
    h: u32,
    d: u32 = 1,
    mip_level: u32 = 0,
    layer: u32 = 0,
};

/// Vertex buffer layout slot, pitch stride, and input stepping rate.
pub const VertexBufferDescription = struct {
    slot: u32,
    pitch: u32,
    input_rate: VertexInputRate = .vertex,
    instance_step_rate: u32 = 0,
};

/// Per-vertex attribute location, buffer binding slot, and data format.
pub const VertexAttribute = struct {
    location: u32,
    buffer_slot: u32,
    format: VertexElementFormat,
    offset: u32,
};

/// Color target format and blending configurations for graphics pipeline creation.
pub const ColorTargetDescription = struct {
    format: TextureFormat,
    blend_state: struct {
        src_color_blendfactor: BlendFactor,
        dst_color_blendfactor: BlendFactor,
        color_blend_op: BlendOp,
        src_alpha_blendfactor: BlendFactor,
        dst_alpha_blendfactor: BlendFactor,
        alpha_blend_op: BlendOp,
        color_write_mask: u8,
        enable_blend: bool = true,
        enable_color_write_mask: bool = true,
    },
};

/// Comprehensive descriptor defining shaders, vertex layout, rasterization,
/// depth/stencil, and blend states for a graphics pipeline.
pub const GraphicsPipelineCreateInfo = struct {
    vertex_shader: Shader,
    fragment_shader: Shader,
    vertex_input_state: struct {
        num_vertex_attributes: usize = 0,
        vertex_attributes: ?[*]const VertexAttribute = null,
        num_vertex_buffers: usize = 0,
        vertex_buffer_descriptions: ?[*]const VertexBufferDescription = null,
    },
    primitive_type: PrimitiveType = .triangle_list,
    rasterizer_state: struct {
        fill_mode: FillMode = .fill,
        cull_mode: CullMode = .none,
        front_face: FrontFace = .counter_clockwise,
        depth_bias_constant_factor: f32 = 0,
        depth_bias_clamp: f32 = 0,
        depth_bias_slope_factor: f32 = 0,
        enable_depth_bias: bool = false,
        enable_depth_clip: bool = false,
    } = .{},
    multisample_state: struct {
        sample_count: SampleCount = .count_1,
        sample_mask: u32 = 0,
        enable_mask: bool = false,
        enable_alpha_to_coverage: bool = false,
    } = .{},
    depth_stencil_state: struct {
        compare_op: CompareOp = .always,
        back_stencil_state: struct {
            compare_op: CompareOp = .always,
            fail_op: StencilOp = .keep,
            pass_op: StencilOp = .keep,
            depth_fail_op: StencilOp = .keep,
        } = .{},
        front_stencil_state: struct {
            compare_op: CompareOp = .always,
            fail_op: StencilOp = .keep,
            pass_op: StencilOp = .keep,
            depth_fail_op: StencilOp = .keep,
        } = .{},
        compare_mask: u8 = 0,
        write_mask: u8 = 0,
        enable_depth_test: bool = false,
        enable_depth_write: bool = false,
        enable_stencil_test: bool = false,
    } = .{},
    target_info: struct {
        num_color_targets: usize = 0,
        color_target_descriptions: ?[*]const ColorTargetDescription = null,
        has_depth_stencil_target: bool = false,
        depth_stencil_format: TextureFormat = .d16_unorm,
    },
    props: u32 = 0,
};

/// Render target texture attachment, clear color, and load/store operations for a render pass.
pub const ColorTargetAttachment = struct {
    texture: Texture,
    clear_color: c.SDL_FColor = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    cycle: bool = false,
};

/// Binding configuration associating a GPU buffer with an offset.
pub const BufferBinding = struct {
    buffer: Buffer,
    offset: u32 = 0,
};

/// Sub-region span of a GPU buffer defined by offset and byte length.
pub const BufferRegion = struct {
    buffer: Buffer,
    offset: u32 = 0,
    size: u32,
};

/// Location offset within a staging transfer buffer.
pub const TransferBufferLocation = struct {
    transfer_buffer: TransferBuffer,
    offset: u32 = 0,
};

/// Paired texture and sampler binding for shader fragment sampling.
pub const TextureSamplerBinding = struct {
    texture: Texture,
    sampler: Sampler,
};

/// Command recording context for graphics rendering and rasterization passes.
pub const RenderPass = struct {
    ptr: *c.SDL_GPURenderPass,

    /// Binds a compiled graphics pipeline for subsequent draw calls in this render pass.
    pub fn bindPipeline(self: RenderPass, pipeline: Pipeline) void {
        c.SDL_BindGPUGraphicsPipeline(self.ptr, pipeline.ptr);
    }

    /// Binds an array of vertex buffers starting at the specified input slot.
    pub fn bindVertexBuffers(
        self: RenderPass,
        first_slot: u32,
        bindings: []const BufferBinding,
    ) void {
        std.debug.assert(bindings.len <= 16);
        var c_bindings: [16]c.SDL_GPUBufferBinding = undefined;
        for (bindings, 0..) |b, i| {
            c_bindings[i] = .{ .buffer = b.buffer.ptr, .offset = b.offset };
        }
        c.SDL_BindGPUVertexBuffers(self.ptr, first_slot, &c_bindings, @intCast(bindings.len));
    }

    /// Sets the scissor clipping rectangle for rasterization in this render pass.
    pub fn setScissor(self: RenderPass, rect: *const c.SDL_Rect) void {
        c.SDL_SetGPUScissor(self.ptr, rect);
    }

    /// Binds texture-sampler pairs to fragment shader binding slots.
    pub fn bindFragmentSamplers(
        self: RenderPass,
        first_slot: u32,
        bindings: []const TextureSamplerBinding,
    ) void {
        std.debug.assert(bindings.len <= 16);
        var c_bindings: [16]c.SDL_GPUTextureSamplerBinding = undefined;
        for (bindings, 0..) |b, i| {
            c_bindings[i] = .{ .texture = b.texture.ptr, .sampler = b.sampler.ptr };
        }
        c.SDL_BindGPUFragmentSamplers(self.ptr, first_slot, &c_bindings, @intCast(bindings.len));
    }

    /// Records a non-indexed primitive drawing command.
    pub fn drawPrimitives(
        self: RenderPass,
        num_vertices: u32,
        num_instances: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        c.SDL_DrawGPUPrimitives(
            self.ptr,
            num_vertices,
            num_instances,
            first_vertex,
            first_instance,
        );
    }

    /// Concludes recording commands for this render pass.
    pub fn end(self: RenderPass) void {
        c.SDL_EndGPURenderPass(self.ptr);
    }
};

/// Command recording context for buffer and texture transfer copy operations.
pub const CopyPass = struct {
    ptr: *c.SDL_GPUCopyPass,

    /// Copies pixel data from a transfer buffer to a destination texture region.
    pub fn uploadToTexture(
        self: CopyPass,
        source: *const TextureTransferInfo,
        destination: *const TextureRegion,
        cycle: bool,
    ) void {
        const c_src = c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = source.transfer_buffer.ptr,
            .offset = source.offset,
            .pixels_per_row = source.pixels_per_row,
            .rows_per_layer = source.rows_per_layer,
        };
        const c_dst = c.SDL_GPUTextureRegion{
            .texture = destination.texture.ptr,
            .x = destination.x,
            .y = destination.y,
            .z = destination.z,
            .w = destination.w,
            .h = destination.h,
            .d = destination.d,
            .mip_level = destination.mip_level,
            .layer = destination.layer,
        };
        c.SDL_UploadToGPUTexture(self.ptr, &c_src, &c_dst, cycle);
    }

    /// Copies data from a transfer buffer to a destination GPU buffer region.
    pub fn uploadToBuffer(
        self: CopyPass,
        source: *const TransferBufferLocation,
        destination: *const BufferRegion,
        cycle: bool,
    ) void {
        const c_src = c.SDL_GPUTransferBufferLocation{
            .transfer_buffer = source.transfer_buffer.ptr,
            .offset = source.offset,
        };
        const c_dst = c.SDL_GPUBufferRegion{
            .buffer = destination.buffer.ptr,
            .offset = destination.offset,
            .size = destination.size,
        };
        c.SDL_UploadToGPUBuffer(self.ptr, &c_src, &c_dst, cycle);
    }

    /// Copies pixel data from a texture region into a destination transfer buffer.
    pub fn downloadFromTexture(
        self: CopyPass,
        source: *const TextureRegion,
        destination: *const TextureTransferInfo,
    ) void {
        const c_src = c.SDL_GPUTextureRegion{
            .texture = source.texture.ptr,
            .x = source.x,
            .y = source.y,
            .z = source.z,
            .w = source.w,
            .h = source.h,
            .d = source.d,
            .mip_level = source.mip_level,
            .layer = source.layer,
        };
        const c_dst = c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = destination.transfer_buffer.ptr,
            .offset = destination.offset,
            .pixels_per_row = destination.pixels_per_row,
            .rows_per_layer = destination.rows_per_layer,
        };
        c.SDL_DownloadFromGPUTexture(self.ptr, &c_src, &c_dst);
    }

    /// Concludes recording commands for this copy pass.
    pub fn end(self: CopyPass) void {
        c.SDL_EndGPUCopyPass(self.ptr);
    }
};

/// Command recording context for GPU compute shader dispatches.
pub const ComputePass = struct {
    ptr: *c.SDL_GPUComputePass,

    /// Binds a compiled compute pipeline for subsequent dispatch commands.
    pub fn bindPipeline(self: ComputePass, pipeline: ComputePipeline) void {
        c.SDL_BindGPUComputePipeline(self.ptr, pipeline.ptr);
    }

    /// Binds read-only storage buffers starting at the specified binding slot.
    pub fn bindStorageBuffers(self: ComputePass, first_slot: u32, buffers: []const Buffer) void {
        var c_bufs: [4]*c.SDL_GPUBuffer = undefined;
        const count = @min(buffers.len, 4);
        for (0..count) |i| {
            c_bufs[i] = buffers[i].ptr;
        }
        c.SDL_BindGPUComputeStorageBuffers(self.ptr, first_slot, &c_bufs, @intCast(count));
    }

    /// Dispatches compute workgroups along 3D workgroup dimensions.
    pub fn dispatch(
        self: ComputePass,
        group_count_x: u32,
        group_count_y: u32,
        group_count_z: u32,
    ) void {
        c.SDL_DispatchGPUCompute(self.ptr, group_count_x, group_count_y, group_count_z);
    }

    /// Concludes recording commands for this compute pass.
    pub fn end(self: ComputePass) void {
        c.SDL_EndGPUComputePass(self.ptr);
    }
};

/// Queue submission context for recording and executing GPU passes and uniform updates.
pub const CommandBuffer = struct {
    ptr: *c.SDL_GPUCommandBuffer,

    /// Submits the recorded command buffer to the GPU command queue for execution.
    pub fn submit(self: CommandBuffer) bool {
        return c.SDL_SubmitGPUCommandBuffer(self.ptr);
    }

    /// Submits the command buffer and acquires a synchronization fence signaled
    /// upon GPU completion.
    pub fn submitAndAcquireFence(self: CommandBuffer) ?Fence {
        const raw = c.SDL_SubmitGPUCommandBufferAndAcquireFence(self.ptr);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Cancels command buffer recording and discards all pending commands.
    pub fn cancel(self: CommandBuffer) bool {
        return c.SDL_CancelGPUCommandBuffer(self.ptr);
    }

    /// Pushes immediate uniform data to fragment shader uniform slot.
    pub fn pushFragmentUniform(self: CommandBuffer, slot: u32, data: []const u8) void {
        c.SDL_PushGPUFragmentUniformData(self.ptr, slot, data.ptr, @intCast(data.len));
    }

    /// Begins recording commands for a graphics render pass targeting a color attachment.
    pub fn beginRenderPass(self: CommandBuffer, target: *const ColorTargetAttachment) ?RenderPass {
        const c_info = c.SDL_GPUColorTargetInfo{
            .texture = target.texture.ptr,
            .clear_color = target.clear_color,
            .load_op = @intCast(@intFromEnum(target.load_op)),
            .store_op = @intCast(@intFromEnum(target.store_op)),
            .cycle = target.cycle,
            .padding1 = 0,
            .padding2 = 0,
            .resolve_texture = null,
            .resolve_layer = 0,
            .mip_level = 0,
            .cycle_resolve_texture = false,
        };
        const raw = c.SDL_BeginGPURenderPass(self.ptr, &c_info, 1, null);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Begins recording commands for a buffer or texture transfer copy pass.
    pub fn beginCopyPass(self: CommandBuffer) ?CopyPass {
        const raw = c.SDL_BeginGPUCopyPass(self.ptr);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Pushes immediate uniform data to compute shader uniform slot.
    pub fn pushComputeUniform(self: CommandBuffer, slot: u32, data: []const u8) void {
        c.SDL_PushGPUComputeUniformData(self.ptr, slot, data.ptr, @intCast(data.len));
    }

    /// Begins recording commands for a compute pass with optional read-write storage bindings.
    pub fn beginComputePass(
        self: CommandBuffer,
        storage_textures: ?[]const StorageTextureReadWriteBinding,
        storage_buffers: ?[]const StorageBufferReadWriteBinding,
    ) ?ComputePass {
        var c_storage_tex: [4]c.SDL_GPUStorageTextureReadWriteBinding = undefined;
        var tex_count: u32 = 0;
        if (storage_textures) |stexs| {
            tex_count = @intCast(stexs.len);
            std.debug.assert(tex_count <= 4);
            for (0..tex_count) |i| {
                const b = stexs[i];
                c_storage_tex[i] = .{
                    .texture = b.texture.ptr,
                    .mip_level = b.mip_level,
                    .layer = b.layer,
                    .cycle = b.cycle,
                    .padding1 = 0,
                    .padding2 = 0,
                };
            }
        }

        var c_storage_buf: [4]c.SDL_GPUStorageBufferReadWriteBinding = undefined;
        var buf_count: u32 = 0;
        if (storage_buffers) |sbufs| {
            buf_count = @intCast(sbufs.len);
            std.debug.assert(buf_count <= 4);
            for (0..buf_count) |i| {
                const b = sbufs[i];
                c_storage_buf[i] = .{
                    .buffer = b.buffer.ptr,
                    .cycle = b.cycle,
                    .padding1 = 0,
                    .padding2 = 0,
                    .padding3 = 0,
                };
            }
        }

        const raw = c.SDL_BeginGPUComputePass(
            self.ptr,
            if (tex_count > 0) &c_storage_tex else null,
            tex_count,
            if (buf_count > 0) &c_storage_buf else null,
            buf_count,
        );
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Records commands to generate mipmaps for a GPU texture.
    pub fn generateMipmaps(self: CommandBuffer, texture: Texture) void {
        c.SDL_GenerateMipmapsForGPUTexture(self.ptr, texture.ptr);
    }
};

/// Primary interface for GPU device resource creation, management, and command execution.
pub const Device = struct {
    ptr: *c.SDL_GPUDevice,

    /// Creates a new GPU device supporting the requested shader formats,
    /// optionally enabling debug validation.
    pub fn create(format_flags: u32, debug_mode: bool) ?Device {
        const raw = c.SDL_CreateGPUDevice(format_flags, debug_mode, null);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Destroys the GPU device and frees associated backend resources.
    pub fn destroy(self: Device) void {
        c.SDL_DestroyGPUDevice(self.ptr);
    }

    /// Queries a bitmask of shader bytecode formats supported by this GPU backend.
    pub fn getShaderFormats(self: Device) u32 {
        return c.SDL_GetGPUShaderFormats(self.ptr);
    }

    /// Queries the preferred texture format for a window swapchain on this device.
    pub fn getSwapchainTextureFormat(self: Device, window: anytype) TextureFormat {
        return @enumFromInt(c.SDL_GetGPUSwapchainTextureFormat(self.ptr, @ptrCast(window.ptr)));
    }

    /// Acquires a command buffer for recording GPU commands.
    pub fn acquireCommandBuffer(self: Device) ?CommandBuffer {
        const raw = c.SDL_AcquireGPUCommandBuffer(self.ptr);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Allocates a GPU data buffer according to the provided descriptor.
    pub fn createBuffer(self: Device, info: *const BufferCreateInfo) ?Buffer {
        const c_info = c.SDL_GPUBufferCreateInfo{
            .usage = info.usage,
            .size = info.size,
            .props = info.props,
        };
        const raw = c.SDL_CreateGPUBuffer(self.ptr, &c_info);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Frees an allocated GPU buffer.
    pub fn releaseBuffer(self: Device, buffer: Buffer) void {
        c.SDL_ReleaseGPUBuffer(self.ptr, buffer.ptr);
    }

    /// Creates a GPU texture according to the provided configuration.
    pub fn createTexture(self: Device, info: *const TextureCreateInfo) ?Texture {
        const c_info = c.SDL_GPUTextureCreateInfo{
            .type = @intCast(@intFromEnum(info.type)),
            .format = @intCast(@intFromEnum(info.format)),
            .usage = info.usage,
            .width = info.width,
            .height = info.height,
            .layer_count_or_depth = info.layer_count_or_depth,
            .num_levels = info.num_levels,
            .sample_count = @intCast(@intFromEnum(info.sample_count)),
            .props = info.props,
        };
        const raw = c.SDL_CreateGPUTexture(self.ptr, &c_info);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Frees an allocated GPU texture.
    pub fn releaseTexture(self: Device, texture: Texture) void {
        c.SDL_ReleaseGPUTexture(self.ptr, texture.ptr);
    }

    /// Creates a GPU texture sampler according to the provided configuration.
    pub fn createSampler(self: Device, info: *const SamplerCreateInfo) ?Sampler {
        const c_info = c.SDL_GPUSamplerCreateInfo{
            .min_filter = @intCast(@intFromEnum(info.min_filter)),
            .mag_filter = @intCast(@intFromEnum(info.mag_filter)),
            .mipmap_mode = @intCast(@intFromEnum(info.mipmap_mode)),
            .address_mode_u = @intCast(@intFromEnum(info.address_mode_u)),
            .address_mode_v = @intCast(@intFromEnum(info.address_mode_v)),
            .address_mode_w = @intCast(@intFromEnum(info.address_mode_w)),
            .mip_lod_bias = info.mip_lod_bias,
            .max_anisotropy = info.max_anisotropy,
            .compare_op = @intCast(@intFromEnum(info.compare_op)),
            .min_lod = info.min_lod,
            .max_lod = info.max_lod,
            .props = info.props,
        };
        const raw = c.SDL_CreateGPUSampler(self.ptr, &c_info);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Frees an allocated GPU sampler.
    pub fn releaseSampler(self: Device, sampler: Sampler) void {
        c.SDL_ReleaseGPUSampler(self.ptr, sampler.ptr);
    }

    /// Compiles and creates a GPU shader stage from bytecode.
    pub fn createShader(self: Device, info: *const ShaderCreateInfo) ?Shader {
        const c_info = c.SDL_GPUShaderCreateInfo{
            .code_size = info.code_size,
            .code = info.code,
            .entrypoint = info.entrypoint.ptr,
            .format = info.format,
            .stage = @intCast(@intFromEnum(info.stage)),
            .num_samplers = info.num_samplers,
            .num_storage_textures = info.num_storage_textures,
            .num_storage_buffers = info.num_storage_buffers,
            .num_uniform_buffers = info.num_uniform_buffers,
            .props = info.props,
        };
        const raw = c.SDL_CreateGPUShader(self.ptr, &c_info);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Frees a compiled GPU shader.
    pub fn releaseShader(self: Device, shader: Shader) void {
        c.SDL_ReleaseGPUShader(self.ptr, shader.ptr);
    }

    /// Creates a compute pipeline state object from shader bytecode and thread dimensions.
    pub fn createComputePipeline(
        self: Device,
        info: *const ComputePipelineCreateInfo,
    ) ?ComputePipeline {
        const c_info = c.SDL_GPUComputePipelineCreateInfo{
            .code_size = info.code_size,
            .code = info.code,
            .entrypoint = info.entrypoint.ptr,
            .format = info.format,
            .num_samplers = info.num_samplers,
            .num_readonly_storage_textures = info.num_readonly_storage_textures,
            .num_readonly_storage_buffers = info.num_readonly_storage_buffers,
            .num_readwrite_storage_textures = info.num_readwrite_storage_textures,
            .num_readwrite_storage_buffers = info.num_readwrite_storage_buffers,
            .num_uniform_buffers = info.num_uniform_buffers,
            .threadcount_x = info.threadcount_x,
            .threadcount_y = info.threadcount_y,
            .threadcount_z = info.threadcount_z,
            .props = info.props,
        };
        const raw = c.SDL_CreateGPUComputePipeline(self.ptr, &c_info);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Frees a compiled compute pipeline.
    pub fn releaseComputePipeline(self: Device, pipeline: ComputePipeline) void {
        c.SDL_ReleaseGPUComputePipeline(self.ptr, pipeline.ptr);
    }

    /// Compiles and creates a complete graphics pipeline state object.
    pub fn createPipeline(self: Device, info: *const GraphicsPipelineCreateInfo) ?Pipeline {
        var c_attributes: [16]c.SDL_GPUVertexAttribute = undefined;
        var c_attrib_count: u32 = 0;
        if (info.vertex_input_state.vertex_attributes) |attrs| {
            c_attrib_count = @intCast(info.vertex_input_state.num_vertex_attributes);
            std.debug.assert(c_attrib_count <= 16);
            for (0..c_attrib_count) |i| {
                const a = attrs[i];
                c_attributes[i] = .{
                    .location = a.location,
                    .buffer_slot = a.buffer_slot,
                    .format = @intCast(@intFromEnum(a.format)),
                    .offset = a.offset,
                };
            }
        }

        var c_buffers: [16]c.SDL_GPUVertexBufferDescription = undefined;
        var c_buf_count: u32 = 0;
        if (info.vertex_input_state.vertex_buffer_descriptions) |bufs| {
            c_buf_count = @intCast(info.vertex_input_state.num_vertex_buffers);
            std.debug.assert(c_buf_count <= 16);
            for (0..c_buf_count) |i| {
                const b = bufs[i];
                c_buffers[i] = .{
                    .slot = b.slot,
                    .pitch = b.pitch,
                    .input_rate = @intCast(@intFromEnum(b.input_rate)),
                    .instance_step_rate = b.instance_step_rate,
                };
            }
        }

        var c_color_targets: [16]c.SDL_GPUColorTargetDescription = undefined;
        var c_target_count: u32 = 0;
        if (info.target_info.color_target_descriptions) |targets| {
            c_target_count = @intCast(info.target_info.num_color_targets);
            std.debug.assert(c_target_count <= 16);
            for (0..c_target_count) |i| {
                const t = targets[i];
                const bs = t.blend_state;
                c_color_targets[i] = .{
                    .format = @intCast(@intFromEnum(t.format)),
                    .blend_state = .{
                        .src_color_blendfactor = @intCast(@intFromEnum(bs.src_color_blendfactor)),
                        .dst_color_blendfactor = @intCast(@intFromEnum(bs.dst_color_blendfactor)),
                        .color_blend_op = @intCast(@intFromEnum(bs.color_blend_op)),
                        .src_alpha_blendfactor = @intCast(@intFromEnum(bs.src_alpha_blendfactor)),
                        .dst_alpha_blendfactor = @intCast(@intFromEnum(bs.dst_alpha_blendfactor)),
                        .alpha_blend_op = @intCast(@intFromEnum(bs.alpha_blend_op)),
                        .color_write_mask = bs.color_write_mask,
                        .enable_blend = bs.enable_blend,
                        .enable_color_write_mask = bs.enable_color_write_mask,
                        .padding1 = 0,
                        .padding2 = 0,
                    },
                };
            }
        }

        const dss = info.depth_stencil_state;
        const back_st = dss.back_stencil_state;
        const front_st = dss.front_stencil_state;

        const c_info = c.SDL_GPUGraphicsPipelineCreateInfo{
            .vertex_shader = info.vertex_shader.ptr,
            .fragment_shader = info.fragment_shader.ptr,
            .vertex_input_state = .{
                .num_vertex_attributes = c_attrib_count,
                .vertex_attributes = if (c_attrib_count > 0) &c_attributes else null,
                .num_vertex_buffers = c_buf_count,
                .vertex_buffer_descriptions = if (c_buf_count > 0) &c_buffers else null,
            },
            .primitive_type = @intCast(@intFromEnum(info.primitive_type)),
            .rasterizer_state = .{
                .fill_mode = @intCast(@intFromEnum(info.rasterizer_state.fill_mode)),
                .cull_mode = @intCast(@intFromEnum(info.rasterizer_state.cull_mode)),
                .front_face = @intCast(@intFromEnum(info.rasterizer_state.front_face)),
                .depth_bias_constant_factor = info.rasterizer_state.depth_bias_constant_factor,
                .depth_bias_clamp = info.rasterizer_state.depth_bias_clamp,
                .depth_bias_slope_factor = info.rasterizer_state.depth_bias_slope_factor,
                .enable_depth_bias = info.rasterizer_state.enable_depth_bias,
                .enable_depth_clip = info.rasterizer_state.enable_depth_clip,
                .padding1 = 0,
                .padding2 = 0,
            },
            .multisample_state = .{
                .sample_count = @intCast(@intFromEnum(info.multisample_state.sample_count)),
                .sample_mask = info.multisample_state.sample_mask,
                .enable_mask = info.multisample_state.enable_mask,
                .enable_alpha_to_coverage = info.multisample_state.enable_alpha_to_coverage,
                .padding2 = 0,
                .padding3 = 0,
            },
            .depth_stencil_state = .{
                .compare_op = @intCast(@intFromEnum(dss.compare_op)),
                .back_stencil_state = .{
                    .compare_op = @intCast(@intFromEnum(back_st.compare_op)),
                    .fail_op = @intCast(@intFromEnum(back_st.fail_op)),
                    .pass_op = @intCast(@intFromEnum(back_st.pass_op)),
                    .depth_fail_op = @intCast(@intFromEnum(back_st.depth_fail_op)),
                },
                .front_stencil_state = .{
                    .compare_op = @intCast(@intFromEnum(front_st.compare_op)),
                    .fail_op = @intCast(@intFromEnum(front_st.fail_op)),
                    .pass_op = @intCast(@intFromEnum(front_st.pass_op)),
                    .depth_fail_op = @intCast(@intFromEnum(front_st.depth_fail_op)),
                },
                .compare_mask = dss.compare_mask,
                .write_mask = dss.write_mask,
                .enable_depth_test = dss.enable_depth_test,
                .enable_depth_write = dss.enable_depth_write,
                .enable_stencil_test = dss.enable_stencil_test,
                .padding1 = 0,
                .padding2 = 0,
                .padding3 = 0,
            },
            .target_info = .{
                .num_color_targets = c_target_count,
                .color_target_descriptions = if (c_target_count > 0) &c_color_targets else null,
                .has_depth_stencil_target = info.target_info.has_depth_stencil_target,
                .depth_stencil_format = @intCast(
                    @intFromEnum(info.target_info.depth_stencil_format),
                ),
                .padding1 = 0,
                .padding2 = 0,
            },
            .props = info.props,
        };
        const raw = c.SDL_CreateGPUGraphicsPipeline(self.ptr, &c_info);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Frees a compiled graphics pipeline.
    pub fn releasePipeline(self: Device, pipeline: Pipeline) void {
        c.SDL_ReleaseGPUGraphicsPipeline(self.ptr, pipeline.ptr);
    }

    /// Allocates a host-accessible staging transfer buffer.
    pub fn createTransferBuffer(
        self: Device,
        info: *const TransferBufferCreateInfo,
    ) ?TransferBuffer {
        const c_info = c.SDL_GPUTransferBufferCreateInfo{
            .usage = @intCast(@intFromEnum(info.usage)),
            .size = info.size,
            .props = info.props,
        };
        const raw = c.SDL_CreateGPUTransferBuffer(self.ptr, &c_info);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Frees an allocated transfer buffer.
    pub fn releaseTransferBuffer(self: Device, buffer: TransferBuffer) void {
        c.SDL_ReleaseGPUTransferBuffer(self.ptr, buffer.ptr);
    }

    /// Maps host-accessible transfer buffer memory into CPU address space.
    pub fn mapTransferBuffer(self: Device, buffer: TransferBuffer, cycle: bool) ?[*]u8 {
        const raw = c.SDL_MapGPUTransferBuffer(self.ptr, buffer.ptr, cycle);
        return if (raw) |r| @ptrCast(r) else null;
    }

    /// Unmaps transfer buffer memory from CPU address space.
    pub fn unmapTransferBuffer(self: Device, buffer: TransferBuffer) void {
        c.SDL_UnmapGPUTransferBuffer(self.ptr, buffer.ptr);
    }

    /// Frees a GPU synchronization fence.
    pub fn releaseFence(self: Device, fence: Fence) void {
        c.SDL_ReleaseGPUFence(self.ptr, fence.ptr);
    }

    /// Blocks CPU execution until the specified GPU fence has been signaled.
    pub fn waitForFence(self: Device, fence: Fence) bool {
        var f_arr = [1]?*c.SDL_GPUFence{fence.ptr};
        return c.SDL_WaitForGPUFences(self.ptr, true, &f_arr, 1);
    }
};
