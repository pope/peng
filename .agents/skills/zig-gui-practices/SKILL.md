---
name: zig-gui-practices
description: Best practices for Zig GUI development with Clay, SDL3, Vulkan/Metal GPU rendering, EXIF image decoding, navigation preloading, and GLSL shader optimization.
  Trigger immediately for:
  - Layout & DPI: Clay UI layout, High-DPI/Retina scaling, zoom-to-mouse math, aspect fit/fill calculations.
  - Image & Memory: EXIF header dimension parsing, APP1 segment skipping, VRAM cache budgeting, navigation throttling, settled preloading.
  - GPU & Shaders: SDL3 GPU/Vulkan text blitting recipe, hardware mipmapping, GLSL shader optimization, Horner's method, branchless GLSL math.
  DO NOT trigger for:
  - Non-GUI backend scripts, database SQL, pure CLI parsing without UI.
---

# Best Practices for Zig GUI & Graphics Development

This guide provides modular procedural recipes and mathematical reference guides for Peng Image Viewer development:

______________________________________________________________________

## Technical Reference Guides

- **[Layout, DPI Scaling & Centering Math](references/dpi-layout-math.md)**

  - Unified state & configuration structs (`PaletteState`, `PaletteConfig`).
  - High-DPI / Retina scale factors (`scale_x`, `scale_y`) for viewports and mouse inputs.
  - Zoom-to-mouse panning math and aspect ratio fitting (`full`, `crop`, `shrink`).

- **[SDL3 GPU Rendering Workflows](references/sdl3-gpu-rendering.md)**

  - Pixel-perfect quad alignment to prevent sub-pixel layout jitter.
  - High-quality SDL3_ttf GPU text rendering pipeline.
  - Hardware mipmap generation (`SDL_GenerateMipmapsForGPUTexture`) over CPU software scaling.

- **[VRAM Budgeting & EXIF Parsing Recipes](references/vram-preloading.md)**

  - VRAM cache memory footprint math (+33% mipmap overhead).
  - Main-thread synchronous EXIF header dimension parsing (< 0.1 ms) & `APP1` (`0xE1`) segment skipping rules.
  - Navigation throttling (< 150ms) and settled preloading triggers (`checkIdlePreload()`).

- **[GPU Shader Optimization Recipes](references/shader-optimization.md)**

  - Horner's method for polynomial splines (chained hardware FMA execution).
  - Branchless math operations (`step()` and `mix()`) for SIMD warp efficiency.
  - `#pragma unroll` directives and `glslangValidator -V -Os` optimization flags.
