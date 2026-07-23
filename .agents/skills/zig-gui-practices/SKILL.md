---
name: zig-gui-practices
description: Best practices for Zig GUI development with Clay, SDL3, Vulkan GPU rendering, EXIF image decoding, navigation preloading, and GLSL shader optimization.
  Trigger immediately for:
  - Layout & DPI: Clay UI layout, High-DPI/Retina scaling, zoom-to-mouse math, aspect fit/fill calculations.
  - Image & Memory: EXIF header dimension parsing, APP1 segment skipping, VRAM cache budgeting, navigation throttling, settled preloading, per-frame arena allocation.
  - GPU & Shaders: SDL3 GPU/Vulkan rendering, text blitting, hardware mipmapping, GLSL shader optimization, Horner's method, branchless GLSL math.
  DO NOT trigger for:
  - Non-GUI backend scripts, database SQL, pure CLI parsing without UI.
---

# Best Practices for Zig GUI & Graphics Development

This guide provides core architecture rules and modular references derived during the development of the Peng Image Viewer. Read the relevant sub-file in `references/` when working on specific subsystems:

______________________________________________________________________

## Technical Reference Guides

1. **\[Layout, DPI Scaling & Centering Math\](file:///home/pope/Code/peng/.agents/skills/zig-gui-practices/references/dpi-layout-math.md)**

   - Unified state & configuration structs (`PaletteState`, `PaletteConfig`).
   - High-DPI / Retina screen scale factors (`scale_x`, `scale_y`) for viewports and mouse deltas.
   - Zoom-to-mouse panning math ($\\text{pan}\_{\\text{new}}$) and aspect ratio fitting (`full`, `crop`, `shrink`).

2. **\[SDL3 GPU & Vulkan Hybrid Rendering\](file:///home/pope/Code/peng/.agents/skills/zig-gui-practices/references/sdl3-gpu-rendering.md)**

   - Per-frame arena allocator (`frame_arena.reset(.retain_capacity)`).
   - Pixel-perfect quad alignment to prevent sub-pixel layout jitter.
   - High-quality text rendering (FreeType rasterization $\\to$ DMA texture upload $\\to$ quad blit).
   - Hardware mipmap generation (`SDL_GenerateMipmapsForGPUTexture`) over single-threaded CPU software scaling.

3. **\[VRAM Budgeting, EXIF Header Parsing & Navigation Throttling\](file:///home/pope/Code/peng/.agents/skills/zig-gui-practices/references/vram-preloading.md)**

   - VRAM memory budget calculation (base texture size $+ 33%$ mipmap overhead).
   - Main-thread synchronous EXIF header dimension parsing (< 0.1 ms) and `APP1` (`0xE1`) segment skipping rules.
   - Navigation throttling (< 150ms intervals) to prevent Vulkan queue exhaustion (`VK_ERROR_DEVICE_LOST`).
   - Settled preload triggers (`checkIdlePreload()`) for background neighbor decoding during idle time.

4. **\[GPU Shader Optimization & GLSL Best Practices\](file:///home/pope/Code/peng/.agents/skills/zig-gui-practices/references/shader-optimization.md)**

   - Horner's method for polynomial splines (chained hardware FMA execution).
   - Branchless math operations (`step()` and `mix()`) to prevent SIMD thread/warp divergence.
   - `#pragma unroll` loop directives and `glslangValidator -V -Os` SPIR-V optimization flags.
   - Negative-lobe resampling invariants (Mitchell/Lanczos vs. 4-tap bilinear hardware reduction).
