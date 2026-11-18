---
name: zig-gui-practices
description: >-
  Procedural recipes and mathematical references for Peng's immediate-mode
  RectCut UI, HiDPI/zoom math, SDL3 GPU rendering (glyph atlas, RGB24 compute
  unpack, Dual Kawase blur), EXIF/RAW progressive streaming, VRAM/staging
  budgets, and GLSL shaders. Use when modifying UI layout, viewport transforms,
  image probing/caching, or GPU pipelines/shaders.
---

# Zig GUI & Graphics Reference Index

Read only the specific reference file needed for your current task:

- **[Systems Architecture & Execution Patterns](references/systems-architecture.md)**:
  3-phase frame loop, 11-step `runUpdatePhase`, `FrameContext` arena lifetimes,
  `ImageCacheKey` & `SlotBound` generation envelopes, `Orientation` `enum(u2)`
  math, `actions.zig` 4-way projections, `MultiArrayList` 256-bit SIMD triage
  scans, `SnackbarState`, `AdjustIntent`/`PaletteMode`, and overlapped startup.
- **[Layout, DPI Scaling & Centering Math](references/dpi-layout-math.md)**:
  `LogicalDims`/`PhysicalDims`/`DpiScale` conversions, annular arc geometry,
  zoom-to-cursor anchor math (`zoomAtPoint`), Wayland/touchscreen pinch math,
  `InteractionState` `FRect` hit-testing, and right-cut badge truncation.
- **[SDL3 GPU Rendering Workflows](references/sdl3-gpu-rendering.md)**:
  Unified `1024x1024` UI + `GlyphCacheKey` font atlas, `FontSizePage` ASCII
  measurement & CJK fallback, `unpack_rgb.comp.glsl` staging, lazy 2-pass Dual
  Kawase blur (`BlurResources`), and Vulkan `Device.reclaimMemory()` flush.
- **[VRAM Budgeting, EXIF/RAW Parsing & Throttling](references/vram-preloading.md)**:
  VRAM mipmap budgeting, 32 MiB/5s staging decay, `malloc_trim` contention
  guards, Stage-1 `DecodeMode` & Freedesktop thumbnail cache, camera RAW quirks
  table & 4-tier RAW+JPEG streaming, `ScrollCadence` & `DecodePriority`, and
  SIMD DCT letterbox crop detection (`scaleRgba32Smooth`).
- **[GPU Shader Optimization Recipes](references/shader-optimization.md)**:
  Horner's method, branchless vs uniform GLSL branching, 7-filter resampling
  suite (Nearest, Bilinear, AA-Nearest, Mitchell, Lanczos3, FSR 1.0, Tiny CNN),
  and the 13-parameter linear photographic color & bilateral presence pipeline.
