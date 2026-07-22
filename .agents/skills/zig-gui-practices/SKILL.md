---
name: zig-gui-practices
description: Reference guidelines and best practices for developing GUI applications in Zig with Clay and SDL3, focusing on layout math, DPI scaling, and memory safety. Trigger this skill when the user asks to implement, debug, or optimize GUI code, layouts, DPI scaling, aspect ratios, or memory management in Zig applications.
---

# Best Practices for Zig GUI Development

This guide outlines core principles, patterns, and mathematical techniques derived during the development of the Peng Image Viewer. Follow these practices when extending the viewer or developing similar GUI applications in Zig.

______________________________________________________________________

## 1. Unified State & Constant Layout Structs

Instead of duplicating states (e.g., maintaining multiple lists or parallel command palette definitions), consolidate similar subsystems into a single structure using a runtime type tag:

- **Single State Instance**: Keep a single state struct (like `PaletteState`) and use an enum (like `PaletteType`) to represent the active mode.
- **Unified UI Layout Configuration**: Switch once on the active type at the beginning of layout functions to return a configuration struct containing all structural strings and metrics:
  ```zig
  const PaletteConfig = struct {
      title: []const u8,
      placeholder: []const u8,
      element_id: []const u8,
      base_item_height: f32,
  };
  ```
  This eliminates inline switch duplication and prevents `comptime_float` runtime-control dependencies by providing concrete types.

______________________________________________________________________

## 2. High-DPI / Retina Screen Scaling

Displays with high pixel density (Retina screens) distinguish between **window coordinates (logical points)** and **physical screen pixels**.

- **DPI Scale Computation**:
  Compute horizontal and vertical scale factors at layout time using logical window size and physical pixel size:
  ```zig
  const scale_x = @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w));
  const scale_y = @as(f32, @floatFromInt(pix_h)) / @as(f32, @floatFromInt(win_h));
  ```
- **Viewport Height Calculation**:
  When calculating the available viewport space, subtract header/footer heights scaled by the DPI factor from the total physical height:
  ```zig
  const view_h = height - (title_bar_h + nav_bar_h) * scale_y - padding * 2.0;
  ```
  *Failing to scale subtracted heights causes clipping and overflow errors on Retina screens.*
- **Input Deltas**:
  Mouse events (like mouse drags) and keyboard panning offsets must scale by `scale_x` and `scale_y` to maintain consistent speed across screen densities:
  ```zig
  self.pan_x += 30.0 * scale_x;
  ```

______________________________________________________________________

## 3. Centering, Fitting, and Zooming Math

### Zoom-to-Mouse (Focus Centered Zoom)

To zoom in/out while keeping the point under the mouse pointer static on the screen:

1. Compute the relative offset ($rel_x$, $rel_y$) of the mouse from the default screen center:
   $$rel_x = x\_{mouse} - x\_{center}$$
2. Update the pan offset using the ratio of new zoom to old zoom:
   $$pan\_{new} = rel_x - (rel_x - pan\_{old}) \\cdot \\frac{zoom\_{new}}{zoom\_{old}}$$

### Image Fitting & Aspect Ratios

Let $R\_{img} = \\frac{img_w}{img_h}$ and $R\_{view} = \\frac{view_w}{view_h}$.

- **`full` (Aspect Fit)**:
  - If $R\_{img} > R\_{view}$: width is limited. $draw_w = view_w$, $draw_h = \\frac{view_w}{R\_{img}}$.
  - Else: height is limited. $draw_h = view_h$, $draw_w = view_h \\cdot R\_{img}$.
- **`crop` (Aspect Fill)**:
  - If $R\_{img} > R\_{view}$: height is filled. $draw_h = view_h$, $draw_w = view_h \\cdot R\_{img}$.
  - Else: width is filled. $draw_w = view_w$, $draw_h = \\frac{view_w}{R\_{img}}$.
- **`shrink` (Fit if Larger)**:
  - If image fits inside viewport ($img_w \\le view_w$ and $img_h \\le view_h$), draw at 100%.
  - Else, apply the **`full`** aspect fit calculations.

______________________________________________________________________

## 4. Memory Safety & Lifecycle Management in UI Loops

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

## 5. High-Performance Hybrid GPU Rendering (Vulkan + SDL3 GPU)

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

## 6. High-Quality Text Rendering with GPU Blitting Fallback

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

______________________________________________________________________

## 7. VRAM Cache Budgeting & Memory Safety Invariants

- **VRAM Budget Calculation with Mipmap Overhead**:
  When computing VRAM memory footprints, account for the base RGBA32 texture size ($W \\times H \\times 4\\text{ bytes}$) plus the $+33%$ mipmap pyramid overhead ($\\frac{4}{3} \\times \\text{base size}$). Ensure budget caps (e.g. $1024\\text{ MB}$) can accommodate multiple high-resolution ($24\\text{MP}-50\\text{MP}$) images simultaneously.
- **Neighbor Slot Protection**:
  In VRAM cache eviction routines (`enforceVramBudget`), protect the current image and its immediate neighbors ($\\pm 2$ slots) from eviction to prevent constant re-decoding during user navigation.
- **Mutex Ownership Invariants**:
  Destroy `SDL_Mutex` objects in exactly one owner lifecycle method (e.g. `ViewerState.deinit()`). Do NOT place duplicate `defer c.SDL_DestroyMutex()` calls at initialization callsites, as double-destroying a mutex triggers glibc heap corruption (`malloc_consolidate`: unaligned fastbin chunk).
- **HashMap String Key Lifetimes in Zig**:
  Calling `clearRetainingCapacity()` or `deinit()` on a `std.StringHashMap` or `std.AutoHashMapUnmanaged` with dynamically allocated keys (`allocator.dupe`) clears map slots without freeing key memory. Always iterate `keyIterator()` to free `key.*` before clearing or deinitializing:
  ```zig
  var rot_iter = self.rotation_map.keyIterator();
  while (rot_iter.next()) |key| {
      self.allocator.free(key.*);
  }
  self.rotation_map.clearRetainingCapacity();
  ```
