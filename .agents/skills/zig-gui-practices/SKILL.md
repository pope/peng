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
  `LogicalDims`/`PhysicalDims`/`DpiScale` conversions, analytic SDF UI quads &
  optical pill centering, zoom-to-cursor anchor math (`zoomAtPoint`),
  Wayland/touchscreen pinch math, `InteractionState` `FRect` hit-testing, and
  right-cut badge truncation.
- **[SDL3 GPU Rendering Workflows](references/sdl3-gpu-rendering.md)**:
  Tight ink-box `1024x1024` `R8_UNORM` glyph atlas with batched `glyph_staging`,
  instanced SDF UI quads (`sdf.vert`/`sdf.frag`), HiDPI `FontMeasurer` physical
  `FontSizePage`s & CJK fallback, `unpack_rgb.comp.glsl` + 2-phase async
  staging, lazy 3-pass 2-level Dual Kawase blur (`BlurResources`) with vibrancy
  & SDF drop shadows, and Vulkan `Device.reclaimMemory()` flush.
- **[VRAM Budgeting, EXIF/RAW Parsing & Throttling](references/vram-preloading.md)**:
  VRAM mipmap budgeting, 96 MiB/30s staging decay, 2-phase async GPU staging
  (`stageCopyWorker`), `malloc_trim` contention guards, Stage-1 `DecodeMode` &
  DPI-mapped Freedesktop thumbnail cache (`ThumbTier.fromDpiScale`),
  `libturbojpeg` DCT scaling & `core.preview`, camera RAW quirks table & 4-tier
  RAW+JPEG streaming, `ScrollCadence` & `DecodePriority`, and SIMD DCT
  letterbox crop detection (`scaleRgba32Smooth`).
- **[GPU Shader Optimization Recipes](references/shader-optimization.md)**:
  Horner's method, branchless vs uniform GLSL branching, 7-filter resampling
  suite (Nearest, Bilinear, AA-Nearest, Mitchell, Lanczos3, FSR 1.0, Tiny CNN),
  and the 13-parameter linear photographic color & bilateral presence pipeline.
