---
name: zig-gui-practices
description: >-
  Best practices for Zig GUI development with Clay, SDL3, Vulkan/Metal GPU rendering, EXIF image decoding, navigation preloading, and GLSL shader optimization.
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

- **[Systems Architecture & Execution Rules](references/systems-architecture.md)**

  - 3-Phase frame loop: Ingestion (1) -> Systems Update Phase (2) -> Render (3).
  - Read-only `UiViewModel` snapshot barrier between Phase 2 and Phase 3 with zero state mutations in render.
  - System lifetime bound to single frame iteration via `FrameContext` (`frame_allocator`).
  - Strict prohibition of direct inter-system calls (intent-driven communication).
  - Intra-frame LIFO deallocation for `ArenaAllocator` bump rewinding.
  - Frame-arena string lifetime invariants for retained Clay UI layout labels.

- **[Layout, DPI Scaling & Centering Math](references/dpi-layout-math.md)**

  - Unified state & configuration structs (`PaletteState`, `PaletteConfig`).
  - High-DPI / Retina scale factors (`scale_x`, `scale_y`) for viewports and mouse inputs.
  - Zoom-to-mouse panning math and aspect ratio fitting (`full`, `crop`, `shrink`).
  - Dynamic `clay.getElementData` bounding box sampling for interactive widgets and sliders.

- **[SDL3 GPU Rendering Workflows](references/sdl3-gpu-rendering.md)**

  - Pixel-perfect quad alignment to prevent sub-pixel layout jitter.
  - High-quality SDL3_ttf GPU text rendering pipeline.
  - Hardware mipmap generation (`SDL_GenerateMipmapsForGPUTexture`) over CPU software scaling.
  - Zero-allocation text measurement (`TTF_GetStringSize` / `TTF_MeasureString`) with slice length passing.

- **[VRAM Budgeting & EXIF Parsing Recipes](references/vram-preloading.md)**

  - VRAM cache memory footprint math (+33% mipmap overhead).
  - Main-thread synchronous EXIF header dimension parsing (< 0.1 ms) & single-pass Zig `std.Io` in-memory decoding.
  - Camera RAW preview extraction: Canon CR2 multi-IFD disambiguation (IFD0 preview vs IFD2 raw RGB vs IFD3 Lossless JPEG SOF3), Fujifilm RAF fixed 12MP preview budgeting, DNG SubIFDs, and Ricoh/Pentax MakerNotes.
  - RAW+JPEG 4-tier progressive streaming, zero-copy resident preview
    slicing, and companion JPEG bounded reads.
  - Navigation throttling (< 150ms), thumbnail-only fast decoding, telemetry metric split (Disk Read vs Decode), and settled preloading triggers (`sysUpdateCache(ctx)`).

- **[GPU Shader Optimization Recipes](references/shader-optimization.md)**

  - Horner's method for polynomial splines (chained hardware FMA execution).
  - Branchless math (`greaterThan()`, `step()`, `mix()`) vs dynamically uniform branches (`if (overshoot > 0.0)`).
  - Photometric exposure ($2^{\\text{EV}}$), 18% middle gray contrast, and rational soft-knee highlight protection.
  - Reciprocal FMAs, zero hardware vector FDIV, and scalar peak helpers.
  - `#pragma unroll` directives and `glslangValidator -V -Os` optimization flags.
