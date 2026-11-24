# SDL3 GPU Rendering & SIMD Vector Reference

## 1. Tight Ink-Box `R8_UNORM` Glyph Atlas & Instanced SDF Quads (`src/gpu/text_cache.zig`, `src/gpu/pass.zig`)

- **Single-Channel `1024x1024` `R8_UNORM` Atlas & Batched `glyph_staging`**:
  - `ensureUiAtlasTexture` lazily allocates a single `1024x1024` `R8_UNORM` GPU texture (`TextCache.atlas_texture`) and uploads a `4x4` opaque coverage (`255`) block at `(0, 0)` for coverage-modulated draws (`glyph.frag.glsl`).
  - Solid rectangles, rounded cards, borders, soft SDF drop shadows, and analytic close icons are emitted as instanced `UiQuadInstance` records rendered by `sdf.vert.glsl` / `sdf.frag.glsl` rather than CPU-tessellated triangles.
- **Shelf-Packed Codepoint Rasterization (`getOrRasterizeGlyph`)**:
  - `executeFrame` opens the shared `CopyPass` (`cmd_buf.beginCopyPass()`) and calls `text_cache.beginFrameGlyphUploads()` *before* invoking `buildRenderPacket` with `PacketBuildContext.copy_pass`.
  - Glyphs are indexed by `GlyphCacheKey{ .font_id, .font_size, .codepoint }` and rasterized to tight ink bounds via `TTF_RenderGlyph_Blended`; `getOrRasterizeGlyph` sub-allocates from `TextCache.glyph_staging` (`acquireGlyphUpload`), writes directly to the mapped transfer buffer, and records `build_ctx.copy_pass.uploadToTexture(...)` immediately into that open `CopyPass`.
  - Each glyph upload is padded by a 1px `0` coverage gutter on all four sides (`alloc_w = ink_w + 2`, `alloc_h = ink_h + 2`) inside `ShelfPacker` to prevent bilinear edge bleed or uninitialized VRAM sampling.
  - Whitespace and zero-ink glyphs (`metrics.maxx <= metrics.minx or metrics.maxy <= metrics.miny`) cache `.has_pixels = false` with their horizontal `advance`, advancing the cursor without consuming atlas space or emitting vertices.

______________________________________________________________________

## 2. Zero-Allocation Per-Glyph Text Measurement (`FontMeasurer` & `FontSizePage`)

- **HiDPI Physical Page Mapping & Direct-Indexed ASCII Tables (`FontSizePage`)**:
  - `FontMeasurer.dpi_scale` maps logical `target_size` requests to rounded physical pixel sizes (`round(target_size * dpi_scale)`) so glyphs rasterize crisply at native framebuffer resolution on HiDPI displays.
  - `TextCache` maintains a flat `pages: [max_font_size_pages]FontSizePage` table (keyed by `(font_id, font_size)`) storing `line_height` and a direct-indexed `ascii: [128]GlyphCacheValue` array, falling back to `glyphs` (`AutoHashMapUnmanaged`) only for non-ASCII codepoints (`cp >= 128`).
  - Both `appendSingleTextRun` (`src/ui/renderer.zig`) and `FontMeasurer.measure` / `FontMeasurer.measurePrefix` (`src/gpu/text_cache.zig`) consult `FontSizePage.ascii[byte]` first, performing **zero C-FFI calls** and **zero hash map lookups** for warm ASCII text while guaranteeing exact width parity between layout and rendering.
- **Lazy Embedded Pan-Unicode/CJK Fallback Font (`src/sdl/font.zig`, `src/gpu/graphics.zig`, `src/gpu/text_cache.zig`)**:
  - `initGpuResources` loads only `Roboto-Regular.ttf` (`fonts[0].ptr`) to keep startup fast; embedded GNU `unifont_jp.otf` (`src/gpu/text_cache.zig`) is attached lazily via `RenderResources.ensureFallbackFont` (`Font.addFallback` / `TTF_AddFallbackFont`) on the first non-ASCII glyph request (`codepoint >= 0x80` in `src/gpu/pass.zig`).
  - Because `TTF_SetFontSize` and `TTF_CloseFont` in `SDL3_ttf` do not automatically resize or free attached fallback handles, `sdl.Font.setFontSize` and `sdl.Font.close` MUST propagate point-size updates and teardown to `fallback_ptr` alongside `ptr`.

______________________________________________________________________

## 3. GPU Compute RGB24/BGR24 Unpack Pipeline (`unpack_rgb.comp.glsl`)

- **Zero CPU 24-to-32-Bit Expansion in GPU Mode**:
  When `decodeWorker` decodes a 24-bit `rgb24` or `bgr24` surface while a GPU device is present (`gpu_mode`), it retains the 3-byte-per-pixel surface in RAM rather than expanding it to 4-byte RGBA32 on the CPU.
- **2-Phase Async Staging & Compute Dispatch (`src/gpu/upload.zig`, `src/app/systems/asset_upload.zig`)**:
  1. For full-image uploads, the main thread maps a reusable `UploadStagingBuffer` (`AppState.upload_staging`) via `beginAsyncUpload` (`AsyncGpuUploadSlot`) and dispatches `StagedTransferJob.executeStagingCopy` on `stageCopyWorker` (`upload_group`) to perform the multi-megabyte row `memcpy` (and `sdl.Surface` teardown when not queued for thumbnail writing) off the render thread, waking the main loop on completion.
  2. `finishAsyncUpload` unmaps the transfer buffer on the main thread, submits the GPU copy (and for 24-bit `rgb24`/`bgr24`, uploads packed bytes to the shared storage buffer with `cycle = true` and dispatches `unpack_rgb.comp.glsl` at `local_size_x = 64`, swapping R/B if `ubo.is_bgr != 0` and writing `vec4(r, g, b, 1.0)` into the `rgba8` texture).
  3. After the copy/compute pass finishes (or after fallback CPU downscaling if `createTexture` exceeded hardware dimension limits), `cmd_buf.generateMipmapsForTexture(tex)` builds the hardware trilinear mipmap pyramid on the GPU, and VRAM accounting records `u_w * u_h * 4` (with $+33%$ mipmap overhead) using the post-upload `RGBA8` texture dimensions.

______________________________________________________________________

## 4. 3-Pass 2-Level Dual Kawase Backdrop Blur Pipeline (`src/gpu/pass.zig`)

- **Demand-Gated Execution & Lazy Blur Initialization (`BlurResources` Tagged Union)**:
  - `initGpuResources` initializes `blur: BlurResources = .uninitialized` on `RenderResources` to avoid 5–20ms of synchronous driver shader compilation during application startup.
  - State is strictly modeled as a tagged union (`.uninitialized`, `.failed`, `.pipelines_ready: Pipelines`, `.initialized: Initialized`), where `Initialized` composes session-lifetime `Pipelines` (`down`, `up`) and window-sized `Textures` (`scene`, `blur_down`, `blur`, `target_dims`, `half_dims`, `down_dims`, `target_format`). Callers cannot observe or assume partially-initialized resources, and `findBlurSplit` pairs `Initialized` with `split_idx` so render passes require zero `.?` unwraps.
  - When hiding the window in `--server` mode, `BlurResources.releaseTextures(dev)` frees the 3 offscreen textures while transitioning `.initialized` -> `.pipelines_ready`, preserving the compiled Kawase pipelines warm for subsequent window re-opens.
  - When `enable_blur` is enabled and `RenderPacket` contains
    `.blurred_surface` batches (glassmorphic floating overlays, command
    palette, or edit panel are visible), `executeFrame` invokes
    `gpu_res.blur.ensure(...)`, which lazily compiles pipelines (or reuses
    `.pipelines_ready`) and allocates offscreen textures on demand
    (transitioning to `.initialized` on success, or latching `.failed` on any
    error to prevent per-frame log spam):
  1. **Scene Offscreen Render**: The image viewport is rendered into `tex.scene` (`w x h`).
  2. **Kawase Downsample 1 (`blur_down.frag.glsl`)**: Downsamples `tex.scene` (`w x h`) -> `tex.blur` (`half_dims`, `w/2 x h/2`) using 5-tap half-pixel diagonal offsets.
  3. **Kawase Downsample 2 (`blur_down.frag.glsl`)**: Downsamples `tex.blur` (`w/2 x h/2`) -> `tex.blur_down` (`down_dims`, `w/4 x h/4`).
  4. **Kawase Upsample (`blur_up.frag.glsl`)**: Filters `tex.blur_down` (`w/4 x h/4`) -> `tex.blur` (`half_dims`, `w/2 x h/2`) using 8-tap tent-weighted offsets.
  5. **Backdrop Composite**: In the swapchain render pass, `tex.scene` is blitted first, and each `.blurred_surface` batch samples `tex.blur` with vibrancy modulation behind the semi-transparent SDF UI card (with soft SDF drop shadows) before drawing UI borders and text.
- When `findBlurSplit` returns `null` (no `.blurred_surface` batches present, `enable_blur` is false, or `gpu.blur != .initialized`), the offscreen scene pass and all blur passes are completely skipped, falling back to direct single-pass swapchain rendering.

______________________________________________________________________

## 5. Retained GPU Buffers & Deferred Driver Memory Reclamation (`src/sdl/gpu.zig`)

- **`RetainedResource(Handle)` Tagged Union (`RetainedBuffer`, `RetainedTransferBuffer`)**:
  - Model retained, geometrically grown GPU buffers and transfer buffers
    (`UploadStagingBuffer` in `src/gpu/upload.zig` and double-buffered
    `vertex_buffers` / `transfer_buffers` in `RenderResources`) via
    `sdl.gpu.RetainedResource(Handle)` (`union(enum) { unallocated, allocated: .{ handle: Handle, capacity: usize } }`) rather than parallel
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
