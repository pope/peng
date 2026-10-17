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
  - Read-only `UiViewModel` (`src/state/view_model.zig`) snapshot barrier between Phase 2 and Phase 3 with zero state mutations in render.
  - System lifetime bound to single frame iteration via `FrameContext` (`frame_allocator`) with intra-frame LIFO deallocation.
  - Frame-arena string lifetime invariants for retained Clay UI layout labels (`layout.zig`, `edit_panel.zig`, `palette.zig`).
  - Declarative capabilities (`actions.zig`), zero-allocation `SnackbarState` (`src/state/snackbar.zig`), and `MultiArrayList` SoA SIMD navigation.

- **[Layout, DPI Scaling & Centering Math](references/dpi-layout-math.md)**

  - High-DPI / Retina scale factors (`scale_x`, `scale_y`) for viewports and mouse inputs.
  - Zoom-to-mouse panning math and aspect ratio fitting (`full`, `crop`, `shrink`).
  - Dynamic `clay.getElementData` bounding box sampling for interactive widgets and sliders.
  - Compound row badge alignment and normalized `[0.0, 1.0]` theme alpha invariants.

- **[SDL3 GPU Rendering Workflows](references/sdl3-gpu-rendering.md)**

  - High-quality SDL3_ttf GPU text rendering and zero-allocation text measurement (`TTF_GetStringSize`).
  - GPU compute RGB24/BGR24 unpack pipeline (`unpack_rgb.comp.glsl` & `UploadStagingBuffer`) with hardware mipmap generation.
  - 4-pass Dual Kawase backdrop blur pipeline (`blur_down.frag.glsl`, `blur_up.frag.glsl`) for glassmorphic overlays.

- **[VRAM Budgeting & EXIF Parsing Recipes](references/vram-preloading.md)**

  - VRAM cache memory footprint math (+33% mipmap overhead) and active/transition/neighbor slot protection.
  - Synchronous main-thread header probing (< 0.1ms, 256KB RAW / 128KB standard) & single-pass `std.Io` in-memory decoding.
  - Camera RAW format quirks table (Adobe DNG / Ricoh GR III, Canon CR2 IFD0/2/3 disambiguation, Fujifilm RAF 12MP ceiling, Sony ARW Bayer CFA exclusion) and 4-tier RAW+JPEG progressive streaming.
  - Navigation throttling (`35ms` fast-scroll `thumb_only`, `200ms` crossfade bypass, `250ms` settled Fit promotion), dynamic worker scaling (`@max(1, @min(8, cpus -| 1))`), and cooperative `CacheKey` epoch pruning.

- **[GPU Shader Optimization Recipes](references/shader-optimization.md)**

  - Horner's method for polynomial splines and `#pragma unroll` SPIR-V / Metal compilation (`zig build shaders`).
  - Branchless per-pixel math (`greaterThan()`, `step()`, `mix()`) vs dynamically uniform branches (`if (ubo.has_adjustments != 0)`).
  - 7-filter resampling suite (`Nearest`, `Bilinear`, `AA-Nearest`, `Mitchell-Netravali`, `Lanczos3`, `AMD FSR 1.0`, `Tiny CNN`).
  - 13-parameter color & presence pipeline: opponent WB, dual-path 18% middle gray contrast, monotonic root-space tonal quad, post-contrast exposure ($2^{2\\cdot\\text{EV}}$), skin-protected vibrance, 8-tap $R=2\\text{px}$ bilateral Texture, 8-tap $R=12\\text{px}$ bilateral Clarity, and rational highlight soft-knee.
