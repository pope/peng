# SDL3 GPU & Vulkan Hybrid Rendering

## 1. Memory Safety & Lifecycle Management in UI Loops

Interactive GUI loops run at 60+ frames per second. Memory management must prevent heap fragmentation and leaks.

- **Per-Frame Arena Allocator**:
  Use a per-frame Arena allocator (`frame_arena`) for all allocations inside the rendering loop (such as UI text generation, formatted strings, and layout structures).
- **Reset Arena capacity**:
  Reset the arena at the start of each frame iteration to reclaim memory instantly without freeing and re-allocating heap headers:
  ```zig
  _ = frame_arena.reset(.retain_capacity);
  ```
- **Persistent CLI Parsers**:
  Command-line or startup config parsers (like `Args.Iterator`) should be allocated on a General Purpose Allocator (GPA) and cleaned up immediately before entering the main loop:
  ```zig
  var args_it = try std.process.Args.Iterator.initAllocator(args, gpa);
  defer args_it.deinit();
  ```

______________________________________________________________________

## 2. High-Performance Hybrid GPU Rendering (Vulkan + SDL3 GPU)

When rendering with high-performance APIs (Vulkan/Direct3D/Metal) using `SDL_GPUDevice`, the window swapchain is owned exclusively by the GPU device.

- **Exclusivity Constraint**: You cannot attach both `SDL_Renderer` (legacy 2D API) and `SDL_GPUDevice` to the same window simultaneously. The rendering system must fully own the presentation pipeline.
- **Pixel-Perfect Quad Alignment**: To prevent layout jitter and sub-pixel misalignment (blurriness), round the bounding box origin *once* before compiling vertex coordinates, rather than rounding coordinates on a per-vertex basis:
  ```zig
  const origin_x = @round(rcmd.bounding_box.x);
  const origin_y = @round(rcmd.bounding_box.y);

  const world_x = origin_x + pt_xy.x;
  const world_y = origin_y - pt_xy.y;
  ```

______________________________________________________________________

## 3. High-Quality Text Rendering with GPU Blitting Fallback

The experimental `TTF_GPUTextEngine` in `SDL3_ttf` utilizes a dynamic glyph texture atlas that lacks mature font hinting and subpixel alignment, causing janky text and atlas bleeding (odd pixel artifacts around characters).

- **Surface-to-Texture Rendering Pattern**:
  For sharp, high-quality text rendering, rasterize text using the mature CPU FreeType rasterizer, convert the surface to the GPU-native pixel format, upload it to a temporary texture, and draw it as a single quad:
  1. Rasterize string: `TTF_RenderText_Blended`
  2. Convert format: `SDL_ConvertSurface` to `SDL_PIXELFORMAT_RGBA32`
  3. Create texture: `SDL_CreateGPUTexture` using `SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM`
  4. Copy pixel data via staging transfer buffer, copy commands, and submit.
  5. Draw as a single textured quad in `.text` shader mode (bypassing adjustments).
  6. Collect and release temporary textures and transfer buffers *after* command buffer submission to avoid leaking resources.
- **Hardware Mipmapping over CPU Downscaling**:
  Do NOT perform single-threaded CPU software surface downscaling (`SDL_ScaleSurface`) prior to GPU upload. CPU software downscaling on multi-megapixel buffers takes 20-60 ms, whereas direct DMA surface uploads take 2-4 ms. Upload the unscaled surface directly to VRAM and invoke hardware mipmap generation (`SDL_GenerateMipmapsForGPUTexture`). The GPU creates the full downsampled LOD pyramid in hardware in ~0.04 ms (40 microseconds), offering optimal downsampled rendering with zero CPU overhead.
