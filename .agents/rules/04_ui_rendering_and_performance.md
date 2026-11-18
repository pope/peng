---
trigger: glob
globs: '**/src/ui/**, **/src/gpu/**, **/src/state/**, **/src/geom/**, **/src/viewer.zig, **/src/main.zig'
description: 2-pass RenderPacket & Dual Kawase blur, GlyphCacheKey atlas, HiDPI/zoom math, frame wait sleeping, crossfades, progressive aspect stability, and shader invariants.
---

# UI Rendering & Performance Rules

## 1. 2-Pass `RenderPacket`, Unified Font Atlas & Scissor Safety

- **2-Pass Render Pipeline (`src/ui/renderer.zig`, `src/gpu/pass.zig`)**:
  1. `buildRenderPacket`: Extracts `UiDrawList` into vertices, scissors, and
     batches (`RenderPacket`), ensuring the `1024x1024` UI+glyph atlas and
     rasterizing uncached glyphs via `getOrRasterizeGlyph` with zero render passes.
  2. `executeFrame` / `executeRenderPacket`: Uploads geometry via double-buffered
     transfer buffers, runs lazy 2-pass quarter-res Dual Kawase blur
     (`BlurResources`: `tex.scene` -> `tex.blur_down` -> `tex.blur` when
     `enable_blur` and `.blurred_surface` batches exist), and submits draws.
  - `ImageConfig` (`src/ui/renderer.zig`) and `appendImageCommand`
    (`src/gpu/render_image.zig`) pass non-null `gpu.TextureRef` handles
    (`src/gpu/root.zig`) without `*anyopaque` erasure or `@import("sdl")` in
    `src/ui/`.
- **Unified `1024x1024` UI + Per-Glyph Atlas (`src/gpu/text_cache.zig`)**:
  - Reserve top-left `4x4` opaque white (`0xFFFFFFFF`) at `uv = (0, 0)` for solid
    UI primitives (`gpu_res.uiTexture()`) so chrome and text merge into single
    scissor batches.
  - Key glyphs strictly by `GlyphCacheKey{ .font_id, .font_size, .codepoint }`,
    rasterized once in pure white `(255, 255, 255, 255)` with a 1px `0x00FFFFFF`
    gutter, and modulate RGBA via `Vertex.color` (`packRgba255`).
- **Scissor & SIMD Bounds**: Clip scissors to physical bounds, skip draws with
  `scissor.w <= 0` or `scissor.h <= 0`, and check `offset + 4 <= slice.len`
  before SIMD `@ptrCast`.

## 2. HiDPI Coordinates, Universal Zoom & Panning

- **Logical Points vs. Physical Pixels (`src/geom/root.zig`)**:
  - UI `RectCut` (`FRect`) and overlay drags use logical points (`LogicalDims`,
    `LogicalPoint`); framebuffers, `ViewportParams.pan_x/y`, `getBaseScale`, and
    `isImageOverflowing` use physical pixels (`PhysicalDims`, `PhysicalPoint`,
    `PositiveDimsU32`, converted via `DpiScale`). Pass typed wrappers rather than
    raw `w, h` / `x, y` scalars, and scale docked UI deductions by `DpiScale`
    before subtracting from physical dimensions.
- **Zoom Sizing, Detents & Overflow Routing**:
  - Never multiply `.fit`/`.fill` `computeDrawDims` bounds by $Z\_{\\text{base}}$ a
    second time; compute manual/outgoing transition quads from unrotated source
    dims $\\times$ `ZoomFactor` guarded by `isFinite(z) and z > 0`.
  - Call `updateCurrentRotation()` *before* `ZoomFactor.init(getBaseScale())`.
  - Detect $1.0\\times$ zoom detents via boundary crossing (`(old < 1 and new >= 1)`
    or `(old > 1 and new <= 1)`), and switch `h/j/k/l`/arrows between navigation
    and panning strictly on `isImageOverflowing()`.

## 3. Event Loop Sleeping, Modal Dismissal & Crossfades

- **Frame Wait Strategy (`AppState.computeFrameWaitStrategy`)**:
  - Return `.wait_indefinite` (0% CPU) when `.hidden` or settled idle; `.poll`
    when background events were drained or during active `hasVisualMotion` on a
    visible GPU swapchain window; `8ms` tick when `hasPendingAsyncWork()` or
    headless motion is active; and `getWaitTimeoutMs` for transient overlays,
    unpaused `SlideshowMode.remainingTimeoutMs`,
    `ScrollCadence.settleTimeoutMs` (`35ms` `.single_step`, `200ms`
    `.brisk_scroll`, `251ms` promotion), `upload_staging.decayTimeoutMs`, and
    `PresentTracker.settleTimeoutMs` (`1000ms` `PRESENT_IDLE_GAP_MS`, gated on
    `stats_panel.visible` so `.active` -> `.idle` wakes once with zero infinite
    redraw loop).
- **Modal Input Decoupling & Scroll Containers**:
  - Gate modal input on `isAcceptingInput()` (`PaletteLifecycle.open`), render
    `visibleMode()` and pass `captures_pointer = false` while `.closing`, and
    call `suppress` on `pan_controller`/`zoom_controller` when opening modals or
    clicking UI chrome.
  - Drive scroll containers strictly from wheel deltas (never pointer drag), and
    zero `scroll_delta` during active slider drags.
- **Image Crossfade Invariants**:
  - Snap-and-cut (`setImmediate(.image_crossfade, 1.0)`, `image_transition = .none`)
    when `< 200ms` (`shouldBypassCrossfade`) or interrupting an active dissolve.
  - Require outgoing `.loaded_gpu` and non-failed target; never run
    `thumb_crossfade` alongside `image_transition` or pair promotion; protect
    `getTransitionPrevIndex()` in `enforceVramBudget`.

## 4. Progressive Aspect Stability & Shader/Test Determinism

- **Dimension Stability**: Exclude raw Bayer CFA/LinearRaw streams from RAW
  probes; keep `full_dims = null` when unknown (never substitute thumbnail dims);
  enforce monotonic area updates (`cand_area > cur_area`); guard `.shrink -> .full`
  with `only_has_thumb`; sort lists via `std.ascii.lessThanIgnoreCase`.
- **Shader & `--test-mode` Invariants (`src/gpu/shaders/image.frag.glsl`)**:
  - Bypass sRGB \<-> linear math via uniform `if (ubo.has_adjustments != 0)` when
    `ImageEdits.hasEdits()` is false; clamp `max(..., 0.0)` before `pow(c, 2.4)`;
    use even-symmetric 2nd-order sharpening, explicit LOD/gradients for
    nearest/AA-nearest, and bilinear `Y_ref` for bilateral taps; apply `0.18`
    middle-gray contrast *before* $\\exp_2(\\text{brightness} \\times 2.0)$.
  - `--test-mode` disables `auto_title`, `snackbar`, and `crossfade`; test
    blurred overlays via `SnackbarTrigger.testing` without mutating viewport zoom.

*(Deep recipes: [sdl3-gpu-rendering.md](../skills/zig-gui-practices/references/sdl3-gpu-rendering.md),
[dpi-layout-math.md](../skills/zig-gui-practices/references/dpi-layout-math.md),
[shader-optimization.md](../skills/zig-gui-practices/references/shader-optimization.md))*
