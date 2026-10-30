# UI Rendering & Performance Rules

## 1. 2-Pass GPU Render Pipeline, Text Caching & Scissor Safety

- **2-Pass UI `RenderPacket` Pipeline (`src/ui/renderer.zig`,
  `src/gpu/pass.zig`)**:
  1. **Extraction Pass (`buildRenderPacket`)**: Traverses the Clay command list
     to populate vertex arrays, scissor rects, and batched draw commands
     (`RenderPacket`), while `uploadPendingTextGlyphs` uploads newly rasterized
     glyph textures on text cache misses and defers all GPU render passes.
  2. **Execution Pass (`executeRenderPacket` / `FrameTarget`)**: Acquires a
     unified `FrameTarget` (`swapchain` or `headless` via `acquireTarget`),
     uploads geometry via double-buffered transfer buffers, runs the 2-pass
     quarter-resolution Dual Kawase backdrop blur (`scene_texture` ->
     `blur_down_texture` -> `blur_texture`, gated on `enable_blur` and
     `.blurred_surface` batches), and issues batched GPU draw calls before
     presenting via `submitAndPresentTarget`.
- **GPU Text Texture Alpha Decoupling**:
  - `TextCacheKey` MUST index strictly by `font_id`, `font_size`, `hash`, and
    RGB channels (`color_u32 & 0x00FFFFFF`). Always rasterize glyph surfaces at
    full opacity (`a = 255`) and modulate alpha dynamically via quad vertex
    color (`inColor.a`) to prevent font re-rasterization and cache thrashing
    during fades.
- **Zero-Area Scissor Skipping & SIMD Bounds Safety**:
  - Clip scissor rects against physical framebuffer bounds and skip any draw
    with `scissor.w <= 0` or `scissor.h <= 0`.
  - Verify slice alignment and bounds (`offset + 4 <= slice.len`) before
    casting pixel slices into SIMD vectors (`@ptrCast(&slice[offset])`).

## 2. DPI Scaling, Universal Zoom & Viewport Invariants

- **Logical Window Points vs. Physical Framebuffer Pixels**:
  - Clay layout and overlay drag positions operate in logical window points
    (`LogicalDims`, `LogicalPoint`), whereas GPU framebuffers,
    `ViewportParams.pan_x/y`, `getBaseScale`, and `isImageOverflowing` operate
    in physical pixels (`PhysicalDims`, `PhysicalPoint`, `PositiveDimsU32`,
    converted via `DpiScale` in `src/geom/root.zig`).
  - Pass strongly typed coordinate/dimension structs (`LogicalDims`,
    `PhysicalDims`, `PositiveDimsU32`, `LogicalPoint`, `PhysicalPoint`) across
    function boundaries rather than raw `w, h` or `x, y` scalar pairs, and pass
    `PhysicalDims` (`logical_dims.toPhysical(scale)`) directly when a callee
    only needs physical pixel dimensions rather than pairing `LogicalDims` +
    `DpiScale`.
  - Evaluate `computeViewDims` in physical framebuffer space via
    `view_transform.computeLogicalDrawDims` and convert the resulting draw
    bounds back to `LogicalDims` for Clay layout.
  - Multiply UI panel width deductions (e.g. docked edit panel or debug
    inspector) by the display scale factor $S = \\text{pix_w} / \\text{win_w}$
    before subtracting from physical framebuffer dimensions.
- **Clay Pre-Scaled Rectangles vs. Manual Zoom Quads**:
  - In preset modes (`.fit`, `.fill`), Clay's `rect.w` and `rect.h`
    (`computeDrawDims`) are already scaled to screen dimensions; never multiply
    them by $Z\_{\\text{base}}$ a second time.
  - In manual zoom mode and outgoing crossfade quads
    (`ImageTransitionPrevQuad`), compute physical quad dimensions directly from
    unrotated source dimensions and `ZoomFactor` (`dst_w = sw * z`,
    `dst_h = sh * z`), guarded by `std.math.isFinite(z) and z > 0.0` and
    `dst_w > 0 and dst_h > 0`.
- **Zoom Synchronization, Detents & Overflow Panning**:
  - Call `self.updateCurrentRotation()` *before* synchronizing
    `vp.zoom_factor = ZoomFactor.init(self.getBaseScale())` on navigation and
    rotation intents so preset zoom reflects the active slide's orientation.
  - For discrete zoom steps (`i`/`o`) and smooth `ZoomController` glides, detect
    100% ($Z = 1.0$) detents via boundary crossing
    (`(old < 1.0 and target >= 1.0) or (old > 1.0 and target <= 1.0)`), never a
    narrow epsilon band.
  - Switch `h`/`j`/`k`/`l` and arrow keys between image navigation and viewport
    panning strictly on `isImageOverflowing()`, never on `zoom > 1.0`.

## 3. Clay UI Interaction, Animations & Event Loop Polling

- **Event Loop Wait Strategy (`AppState.computeFrameWaitStrategy`)**:
  - When `self.display == .hidden` (resident `--server` mode with the window
    closed), `computeFrameWaitStrategy` immediately returns `.wait_indefinite`
    (unless `had_bg_events` is true) so the resident daemon blocks at 0% CPU
    until woken by an IPC command or OS event.
  - When `.visible`, `computeFrameWaitStrategy` (`src/app/state.zig`) selects
    `.poll` when pre-wait background events were drained, or schedules a bounded
    `8ms` tick when `self.isBusy()` (active SoA animations, active slideshow,
    active workers), `is_current_loading`, `drag_state != .none`,
    `pan_controller.isBusy()`, `zoom_controller.isBusy()`,
    `has_unpopulated_cache`, or `window_resized` is true.
  - When idle, `getWaitTimeoutMs` schedules a bounded `waitEventTimeout` for
    active transient overlay deadlines (`title_display == .transient` or
    `snackbar.notification == .active`), and otherwise enters 0% CPU blocking
    `wait_indefinite` (including when the command palette is open and idle).
- **Modal Dismissal Input Decoupling & Held-Key Suppression**:
  - Animated overlays (such as `PaletteState`) MUST decouple input focus from
    close animations via `isAcceptingInput()`
    (`mode != .inactive and !is_closing`) and set
    `pointer_capture_mode = .passthrough` while closing or dissolving
    (`ImageTransitionPrevQuad`) so background controls respond immediately.
  - When opening a modal or clicking UI controls, suppress held directional and
    zoom keys (`pan_controller.suppress`, `zoom_controller.suppress`) so held
    keys do not bleed into the viewport upon modal dismissal.
- **Clay Scroll Containers vs. Pointer Controls**:
  - Pass `enableDragScrolling = false` to `clay.updateScrollContainers` on
    desktop containers so clicking child sliders/buttons does not initiate
    scroll-dragging.
  - Zero `scroll_delta` while a slider drag is active (`drag_state == .slider`
    or `active_slider != null`) to prevent container jitter.
- **Image Crossfade & Scrubbing Invariants**:
  - **Snap-and-Cut on Scrubbing/Interruption**: Never retarget duration across
    three textures. If navigation steps occur within $< 200\\text{ms}$ or
    interrupt an in-flight crossfade, immediately snap
    (`setImmediate(.image_crossfade, 1.0)`, `image_transition = .none`) and cut.
  - **GPU Residency & Mutual Exclusion**: Only start a crossfade if the outgoing
    slide is `.loaded_gpu` and the incoming slide did not fail. Never run a
    thumbnail crossfade concurrently with an active `image_transition` or during
    pair stream promotion, and protect both active and outgoing
    (`getTransitionPrevIndex()`) slots in `enforceVramBudget`.
- **Clay Modularization & Single-Source-of-Truth State Binding**:
  - Decompose complex Clay views into private helpers that preserve exact
    sizing, padding, corner radii, border widths, and
    `theme.withAlpha(color, progress)` multipliers.
  - Bind UI overlays and "Stats for Nerds" (`src/ui/stats.zig`) directly to
    canonical domain state fields through `UiViewModel`, never to duplicate
    shadow fields.

## 4. Progressive Loading & Aspect Ratio Stability

- **Raw Bayer Sensor Stream Exclusion**:
  - Header probes (`probeMediaMetadata`) MUST exclude unprocessed raw sensor
    streams so `full_w`/`full_h` reflect true visible photo dimensions rather
    than optical-black sensor dimensions *(see `vram-preloading.md` §2 for
    format-specific TIFF tags)*.
- **No Worker Thumbnail Dimension Fallback**:
  - Decode workers (`decodeRawFile`, `decodeWorker`) MUST leave
    `full_w = 0.0, full_h = 0.0` when true full dimensions are unknown; never
    substitute thumbnail dimensions (`t_surf.w()`), which poisons cache aspect
    ratios.
- **Monotonic Area Updates & `only_has_thumb` Guard**:
  - Guard asynchronous dimension updates (`applyProbedMetadata`,
    `updateFullDims`) with monotonic area checks
    (`cur_area <= 0.0 or new_area > cur_area`) so lower-tier previews never
    downgrade authoritative dimensions.
  - Guard `.shrink` -> `.full` placeholder promotion in `computeDrawDims` with
    `only_has_thumb` (`full_w <= 0.0`, `raw_metadata.getSensorDims() == null`,
    and `thumbnail != .none`) so small icons with known dimensions never blow up
    to fill the viewport.
- **Case-Insensitive Deterministic Sorting**:
  - Sort all filesystem scans, archives, and directory lists with
    `std.ascii.lessThanIgnoreCase`.

## 5. GPU Shader & Visual Regression Test Invariants

*(See `skills/zig-gui-practices/references/shader-optimization.md` for full
mathematical formulas, filter kernels, and color science equations.)*

- **Shader Numerical & Identity Invariants**
  (`src/gpu/shaders/image.frag.glsl`):
  1. **CPU-Gated Identity Bypass**: Check the dynamically uniform
     `if (ubo.has_adjustments != 0)` flag (computed via `ImageEdits.hasEdits()`
     across all 13 edit parameters) to completely bypass sRGB \<-> linear
     conversions when edits are neutral, preserving bit-exact golden baselines.
  2. **Pre-`pow` Ringing Clamping**: Negative-lobe filters (Mitchell-Netravali,
     Lanczos3) can ring below `0.0`; always clamp `max(..., 0.0)` before
     fractional `pow(c, 2.4)` in `srgb_to_linear` to prevent `NaN` propagation.
  3. **Zero-Phase Filter Symmetry, Explicit LOD & Bilinear Center Reference**:
     Never add odd-symmetric 1st derivatives with static positive weights in
     sharpening passes (use even-symmetric 2nd-order curvature), use explicit
     LOD/gradients for nearest and AA-nearest sampling, and compare bilateral
     detail ring taps against a consistent bilinear center reference `Y_ref`.
  4. **Photometric Exposure Ordering & Monotonic Tonal Quad**: Apply contrast
     around 18% linear middle gray (`0.18`) *before* optical stop exposure gain
     $\\exp_2(\\text{brightness} \\times 2.0)$, and keep root-space tonal curves
     within monotonic derivative bounds.
- **Headless Test Mode (`--test-mode`) & Overlay Isolation**:
  - Disable non-instant animations and transient overlays in test mode
    (`src/main.zig`):
    ```zig
    state.viewer.ui.overlays.auto_title = !parsed.test_mode;
    state.viewer.ui.snackbar.enabled = !parsed.test_mode;
    state.viewer.navigation.crossfade = !parsed.test_mode;
    ```
  - When testing glassmorphic or blurred UI overlays, use synthetic triggers
    (`SnackbarTrigger.testing`) rather than mutating viewport zoom/filter/edit
    state so background pixels beneath the overlay remain invariant.
