# SDL3 GPU Rendering & SIMD Vector Reference

## 1. Unified UI + Per-Glyph Font Atlas (`src/gpu/text_cache.zig`, `src/gpu/pass.zig`)

- **Shared `1024x1024` Atlas Texture**:
  - `ensureUiAtlasTexture` lazily allocates a single `1024x1024` `RGBA8_UNORM` GPU texture (`TextCache.atlas_texture`) and uploads a `4x4` opaque white (`0xFFFFFFFF`) block at `(0, 0)`.
  - Solid UI primitives (`appendRectQuad`, `renderFillRoundedRect`, `renderArc` when `screen_uv == false`) emit `uv = (0.0, 0.0)` and bind `gpu_res.uiTexture()`, allowing rectangles, borders, and text in the same scissor region to merge into a single `BatchItem`.
- **Shelf-Packed Codepoint Rasterization (`getOrRasterizeGlyph`)**:
  - Glyphs are indexed by `GlyphCacheKey{ .font_id, .font_size, .codepoint }` and rasterized once in pure white `(255, 255, 255, 255)` via `TTF_RenderGlyph_Blended`.
  - Each glyph upload is padded by 1px of transparent white (`0x00FFFFFF`) on all four sides (`alloc_w = surf_w + 2`, `alloc_h = surf_h + 2`) inside `ShelfPacker` to prevent bilinear edge bleed or uninitialized VRAM sampling.
  - Whitespace and zero-ink glyphs (`metrics.maxx <= metrics.minx or metrics.maxy <= metrics.miny`) cache `.has_pixels = false` with their horizontal `advance`, advancing the cursor without consuming atlas space or emitting vertices.

______________________________________________________________________

## 2. Zero-Allocation Per-Glyph Text Measurement (`FontMeasurer` & `FontSizePage`)

- **Direct-Indexed ASCII Page Tables (`FontSizePage`) & `TTF_GetGlyphMetrics`**:
  - `TextCache` maintains a flat `pages: [max_font_size_pages]FontSizePage` table (keyed by `(font_id, font_size)`) storing `line_height` and a direct-indexed `ascii: [128]GlyphCacheValue` array, falling back to `glyphs` (`AutoHashMapUnmanaged`) only for non-ASCII codepoints (`cp >= 128`).
  - Both `appendSingleTextRun` (`src/ui/renderer.zig`) and `FontMeasurer.measure` / `FontMeasurer.measurePrefix` (`src/gpu/text_cache.zig`) consult `FontSizePage.ascii[byte]` first, performing **zero C-FFI calls** and **zero hash map lookups** for warm ASCII text while guaranteeing exact width parity between layout and rendering.

______________________________________________________________________

## 3. GPU Compute RGB24/BGR24 Unpack Pipeline (`unpack_rgb.comp.glsl`)

- **Zero CPU 24-to-32-Bit Expansion in GPU Mode**:
  When `decodeWorker` decodes a 24-bit `rgb24` or `bgr24` surface while a GPU device is present (`gpu_mode`), it retains the 3-byte-per-pixel surface in RAM rather than expanding it to 4-byte RGBA32 on the CPU.
- **Staging & Compute Dispatch (`src/gpu/upload.zig`)**:
  1. `uploadSurfaceToGpu` copies the 3-byte packed scanlines into a reusable `UploadStagingBuffer` (`AppState.upload_staging`) and uploads them to the shared GPU storage buffer with `cycle = true` (`uploadToBuffer` and `ComputeStorageBufferReadOnlyBinding`) to prevent write-after-read hazards across back-to-back uploads.
  2. A compute pass binds `unpack_rgb.comp.glsl` (`local_size_x = 64`), which reads 3 bytes per texel from the `uint data[]` storage buffer using bit-shift extraction, swaps R and B if `ubo.is_bgr != 0`, and writes `vec4(r, g, b, 1.0)` into the destination `rgba8` texture.
  3. After the compute pass finishes (or after fallback CPU downscaling if `createTexture` exceeded hardware dimension limits), `cmd_buf.generateMipmapsForTexture(tex)` builds the hardware trilinear mipmap pyramid on the GPU, and VRAM accounting records `u_w * u_h * 4` (with $+33%$ mipmap overhead) using the post-upload `RGBA8` texture dimensions.

______________________________________________________________________

## 4. 2-Pass Dual Kawase Backdrop Blur Pipeline (`src/gpu/pass.zig`)

- **Demand-Gated Execution & Lazy Blur Initialization (`BlurResources` Tagged Union)**:
  - `initGpuResources` initializes `blur: BlurResources = .uninitialized` on `RenderResources` to avoid 5–20ms of synchronous driver shader compilation during application startup.
  - State is strictly modeled as a tagged union (`.uninitialized`, `.failed`, `.pipelines_ready: Pipelines`, `.initialized: Initialized`), where `Initialized` composes session-lifetime `Pipelines` (`down`, `up`) and window-sized `Textures` (`scene`, `blur_down`, `blur`, and invariant dimensions). Callers cannot observe or assume partially-initialized resources, and `findBlurSplit` pairs `Initialized` with `split_idx` so render passes require zero `.?` unwraps.
  - When hiding the window in `--server` mode, `BlurResources.releaseTextures(dev)` frees the 3 offscreen textures while transitioning `.initialized` -> `.pipelines_ready`, preserving the compiled Kawase pipelines warm for subsequent window re-opens.
  - When `enable_blur` is enabled and `RenderPacket` contains
    `.blurred_surface` batches (glassmorphic floating overlays, command
    palette, or edit panel are visible), `executeFrame` invokes
    `gpu_res.blur.ensure(...)`, which lazily compiles pipelines (or reuses
    `.pipelines_ready`) and allocates offscreen textures on demand
    (transitioning to `.initialized` on success, or latching `.failed` on any
    error to prevent per-frame log spam):
  1. **Scene Offscreen Render**: The image viewport is rendered into `tex.scene` (`w x h`).
  2. **Kawase Downsample (`blur_down.frag.glsl`)**: Downsamples `tex.scene` -> `tex.blur_down` (`w/4 x h/4`) using 5-tap half-pixel diagonal offsets.
  3. **Kawase Upsample (`blur_up.frag.glsl`)**: Filters `tex.blur_down` -> `tex.blur` (`w/4 x h/4`) using 8-tap tent-weighted offsets.
  4. **Backdrop Composite**: In the swapchain render pass, `tex.scene` is blitted first, and each `.blurred_surface` batch samples `tex.blur` behind the semi-transparent UI card before drawing UI borders and text.
- When `findBlurSplit` returns `null` (no `.blurred_surface` batches present, `enable_blur` is false, or `gpu.blur != .initialized`), the offscreen scene pass and both blur passes are completely skipped, falling back to direct single-pass swapchain rendering.

______________________________________________________________________

## 5. Retained GPU Buffers & Deferred Driver Memory Reclamation (`src/sdl/gpu.zig`)

- **`RetainedResource(Handle)` Tagged Union (`RetainedBuffer`, `RetainedTransferBuffer`)**:
  - Model retained, geometrically grown GPU buffers and transfer buffers
    (`UploadStagingBuffer` in `src/gpu/upload.zig` and double-buffered
    `vertex_buffers` / `transfer_buffers` in `RenderResources`) via
    `sdl.gpu.RetainedResource(Handle)` (`union(enum) { unallocated,
    allocated: .{ handle: Handle, capacity: usize } }`) rather than parallel
    `?Handle` + `usize` capacity fields and `.?` unwraps.
- **SDL3 GPU Deferred Destruction & `Device.reclaimMemory()`**:
  - In SDL3's Vulkan backend (`SDL_gpu_vulkan.c`), `SDL_ReleaseGPUTexture`, `SDL_ReleaseGPUBuffer`, and `SDL_ReleaseGPUTransferBuffer` only append handles to internal deferred queues (`texturesToDestroy`, `buffersToDestroy`, `transferBuffersToDestroy`).
  - Calling `SDL_WaitForGPUIdle` runs `VULKAN_INTERNAL_PerformPendingDestroys`, which destroys the `VkImage`/`VkBuffer` objects and marks newly emptied `VkDeviceMemory` slabs via `renderer->hasEmptyAllocations = true`, **but does not call `VULKAN_INTERNAL_DeallocateMemory` (`vkFreeMemory`)**. SDL3 only invokes `VULKAN_INTERNAL_DeallocateMemory` inside `SDL_SubmitGPUCommandBuffer` (`VULKAN_Submit`) before processing new pending destroys.
  - Therefore, when transitioning to `.hidden` in resident `--server` mode (`RenderResources.releaseTransientResources` + `Device.reclaimMemory()`), execute the 3-step flush sequence:
    1. `waitForIdle()` — drains in-flight work and runs `PerformPendingDestroys` so emptied `VkDeviceMemory` blocks set `hasEmptyAllocations`.
    2. `acquireCommandBuffer()` -> `submit()` — triggers `VULKAN_INTERNAL_DeallocateMemory` (`vkFreeMemory`) on all empty device-local VRAM and host-visible GTT slabs.
    3. `waitForIdle()` — retires the empty command buffer so no fences remain pending while hidden.

______________________________________________________________________

## 6. SIMD Vector Alignment

- **SIMD Vector Pointer Loads**:
  When loading pixel data into SIMD vectors (`@Vector(4, u8)`), verify slice alignment and bounds before executing `@ptrCast`:
  ```zig
  pub inline fn loadVector4(slice: []const u8, offset: usize) ?@Vector(4, u8) {
      if (offset + 4 > slice.len) return null;
      const ptr: *const [4]u8 = @ptrCast(&slice[offset]);
      return ptr.*;
  }
  ```
