# UI Rendering & Performance Rules

## 1. 2-Pass UI Render Packet Pipeline (`RenderPacket`)

- The UI render pipeline is strictly divided into two distinct passes:
  1. **Extraction Pass (`buildRenderPacket`)**: Traverses the Clay layout tree and builds intermediate vertex arrays and texture batch draw items (`RenderPacket`). Zero GPU calls are issued during layout iteration.
  2. **Execution Pass (`executeRenderPacket`)**: Takes the `RenderPacket`, uploads vertex arrays to GPU memory buffers, and executes batched GPU render pass draw calls.
- **Allocation-Free Execution**: `executeRenderPacket` MUST NOT perform dynamic heap allocations. Geometry buffers and staging transfer buffers are double-buffered and reused.

## 2. Logical vs. Physical Coordinates & DPI Scaling

- Clay layout engine runs in logical window coordinates (e.g. 1024x768).
- Scale vertex coordinates and scissor rectangles to physical GPU framebuffer pixels using Retina scale factors (`scale_x`, `scale_y`).

## 3. Zero-Area Scissor Skipping

- Before issuing GPU draw calls, scissor rectangles must be clipped against the window bounds.
- Scissor rects with zero or negative width/height (`scissor.w <= 0` or `scissor.h <= 0`) MUST be skipped to avoid GPU render errors.

## 4. Vector/SIMD Zero-Copy Bounds Safety

- Before loading pixel data into SIMD vectors via `@ptrCast(&slice[offset])`, verify slice alignment and bounds (`offset + 4 <= slice.len`) to prevent out-of-bounds memory reads.

## 5. Case-Insensitive Alphabetical Sorting Invariant

- All filesystem traversals, image lists, and directory items MUST be sorted using case-insensitive comparison (`std.ascii.lessThanIgnoreCase`) to guarantee deterministic cross-platform navigation order.

## 6. Event Loop Polling & Window Dimension Invariants

- When using blocking event polling (`waitEvent`) for power optimization, the `is_busy` calculation MUST include window dimension changes (`cur_win_w != last_win_w` or `window_resized`).
- This guarantees the event loop unblocks immediately for layout recalculation (Clay `setLayoutDimensions`) and GPU frame presentation upon window resizing or fullscreen toggling without requiring mouse movement.

## 7. GPU Text Texture Alpha Decoupling

- `TextCacheKey` MUST index strictly by `font_id`, `font_size`, `hash`, and RGB color channels (`color_u32 & 0x00FFFFFF`). Text glyph surfaces MUST always be rasterized at solid opacity (`a = 255`).
- Opacity modulation during UI animations MUST occur dynamically via the quad vertex color attribute (`inColor.a`).
- Never include alpha in the text cache key; doing so causes catastrophic cache thrashing and font re-rasterization during fade animations.

## 8. Modal Dismissal Input Decoupling

- Overlay containers with animated dismissal transitions (such as the command palette) MUST decouple input focus from visual dissolution.
- Provide and check `isAcceptingInput()` (`mode != .inactive and !is_closing`).
- Keyboard shortcuts and viewport interactions (zooming, panning, navigation) MUST NOT be blocked while a dismissal animation is in-flight.

## 9. Image Crossfade Transitions & Fast Navigation Scrubbing Invariants

- **Snap-and-Cut Over Proportional Retargeting**: Proportional duration retargeting between two *distinct* GPU textures is an anti-pattern. If navigation is interrupted or rapidly scrubbed ($elapsed < 200\\text{ms}$), never attempt to retarget to a third texture; immediately snap the in-flight transition (`setImmediate(1.0)`, `transition = .none`) and cut directly to the target image to prevent sudden luminance pops, muddy 3-quad blending, and visual ghosting.
- **Outgoing Slide GPU Validity Invariant**: Only initiate a crossfade transition if the outgoing image is resident on the GPU (`.loaded_gpu`). Navigating away from a slide that was still decoding or failed MUST cut immediately.
- **Mutual Exclusion with Thumbnail Crossfade**: An image dissolve and a thumbnail crossfade underlay must never execute concurrently. Guard `is_thumb_crossfading` with `image_transition == .none` to prevent quad collisions at $z = 0$.
- **VRAM Budget Eviction Protection**: During an active crossfade, both the incoming slide and the outgoing slide (`getTransitionPrevIndex()`) must be explicitly protected from eviction in `enforceVramBudget`.

## 10. Headless Test Mode Animation & Overlay Isolation

- Automated visual regression testing requires absolute frame-by-frame determinism.
- All non-instant animations and transient auto-overlays (e.g., navigation crossfading, fast-scrub auto-title bar reveal) MUST be disabled when running under test mode (`--test-mode`):
  ```zig
  state.viewer.ui.overlays.auto_title = !parsed.test_mode;
  state.viewer.ui.overlays.show_snackbar = !parsed.test_mode;
  state.viewer.navigation.crossfade = !parsed.test_mode;
  ```
- This guarantees test suite commands execute immediate cuts, avoiding race conditions and golden screenshot pixel discrepancies.

## 11. UI Integration Test Trigger Decoupling

- Automated tests for UI overlays (e.g. snackbars, modal dialogs, floating title bars) MUST NOT mutate the underlying viewport rendering state (such as switching resampling filters, zoom levels, or color adjustments) merely to trigger a notification toast.
- Because UI overlays frequently feature semi-transparent glassmorphism or background blur, altering viewport rendering modifies the background pixels beneath the overlay, causing false-positive visual regression failures when shaders are refactored.
- Use dedicated synthetic test triggers (such as `SnackbarTrigger.testing` generating static `"Test Notification"` text) that preserve the clean, neutral baseline rendering across overlay test steps.

## 12. GLSL Fragment Filter Kernel Symmetry & Phase Alignment

- In single-pass image resampling and sharpening fragment shaders:
  - Odd-symmetric first derivatives ($f(-x) = -f(x)$, such as Sobel $top - bottom$ or $left - right$) must never be multiplied by static positive scalar weights and added to the center pixel. By Taylor series expansion ($I(x + \\Delta x) \\approx I(x) + \\Delta x \\frac{\\partial I}{\\partial x}$), adding a directional first derivative acts as a spatial translation operator, displacing edges and causing perceived pixel shifting when toggling filters.
  - Always use even-symmetric second-order curvature operators (Laplacian, 2nd derivatives $2 c - l - r$) or phase-modulate first derivatives by sub-pixel offsets $(p - \\lfloor p \\rfloor - 0.5)$ so that high-frequency reconstruction remains strictly zero-phase and centered on the texel coordinate.

## 13. Inigo Quilez AA-Nearest Texel Centering Invariant

- When implementing anti-aliased nearest-neighbor filtering (`clamp((f - 0.5) / w + 0.5, 0.0, 1.0)`):
  - Continuous texel space coordinate $p$ MUST be shifted by $-0.5$ ($p = uv \\times \\text{tex_size} - 0.5$) and sampled at $(i + f + 0.5) / \\text{tex_size}$.
  - Failing to shift $p$ by $-0.5$ treats texel centers as edges and boundaries as flat regions, resulting in a 50% bilinear blur across ~90% of the pixel area instead of solid pixel centers with 1-pixel boundary transitions.

## 14. Stats & ViewModel Canonical State Synchronization

- Debug overlays and view models (e.g., "Stats for Nerds" in `stats.zig`) MUST bind directly to the canonical active domain state field (`scale_filter`), never to deprecated or un-synchronized auxiliary fields (`texture_scale_mode`).
- Redundant fields that can cause state desynchronization must be eliminated or strictly aliased to maintain single-source-of-truth invariants.

## 15. Photographic Color Pipeline, Dynamic Uniformity & Numerical Invariants

- **Photometric Exposure & 18% Middle Gray Contrast**:
  - Image brightness adjustments MUST operate as optical stop exposure gains ($2^{2 \\cdot \\text{EV}}$) in scene-referred linear photometric space (IEC 61966-2-1).
  - Contrast MUST pivot around physical 18% middle gray (`0.18`) in linear space rather than arbitrary 0.5 display sRGB. In log2/EV space, this scales dynamic range symmetrically around middle gray.
  - Highlights overshooting 1.0 MUST be smoothly rolled off into a $C^1$-continuous rational shoulder (`excess^2 / (excess + w)`) rather than hard clipped.
- **Identity Bypass Invariant**:
  - Shaders with color adjustments MUST check for neutral settings (`safe_contrast == 1.0 && brightness == 0.0`) and bypass the pipeline completely.
  - Passing neutral colors through sRGB \<-> linear conversions introduces 32-bit floating-point transcendental rounding drift, breaking golden test image baselines.
- **Dynamic Uniformity vs. Branchless Execution**:
  - Conditional branches that depend strictly on uniform variables (such as `has_adjustments` or `overshoot > 0.0`) are **dynamically uniform** across the entire quad draw call.
  - Because all lanes in a SIMD warp evaluate the identical branch condition, warp divergence is 0%. Dynamic uniform branches SHOULD be used to skip expensive transcendental math rather than unconditionally executing both paths via arithmetic `mix`/`step`.
- **Negative-Lobe Filter NaN Guards**:
  - Bicubic and windowed sinc filters (Mitchell-Netravali, Lanczos3) produce negative values in high-contrast ringing regions.
  - Input colors MUST be clamped to `[0.0, 1.0]` before applying sRGB-to-linear conversion to prevent negative inputs to fractional powers (`pow(c, 2.4)`), which generate rendering `NaN`s.

## 16. Aspect Ratio Invariance Across Progressive Previews (Raw Sensor vs. Active Photo)

- **Raw Bayer Sensor Filtering**:
  - In camera RAW containers (Sony ARW, Fujifilm RAF, Adobe DNG, TIFF-EP), header probing for target canvas dimensions (`full_w`, `full_h`) MUST filter out unprocessed Bayer CFA sensor streams (`PhotometricInterpretation == 32803 CFA` or `34892 LinearRaw` or primary `NewSubfileType == 0` SubIFDs).
  - Sensor arrays contain masked optical black calibration pixels (e.g. 6656 × 4608) that do not match visible photograph dimensions (e.g. 6240 × 4160, exact 3:2).
- **Consequences of Sensor Dimension Leakage**:
  - Sizing the layout canvas to raw sensor dimensions corrupts aspect ratio fitting ($1.4444$ vs $1.5000$).
  - Thumbnail 8px DCT block boundary snapping fails ($|\\text{raw_pad} - \\text{nearest}| > 2.0\\text{ px}$), leaving uncropped black letterbox bars.
  - Medium previews are erroneously cropped (e.g. 28px cut off horizontally) due to false pillarboxing.
  - Viewport quad abruptly pops/resizes (e.g. 60px canvas jump) upon swapping from placeholder to full resolution.
- Probing MUST strictly return photographic visible dimensions so the canvas quad remains 100% stable across all loading tiers.

## 17. Invariant Modeling via Tagged Unions vs. Composite Container Anti-Patterns

- **Enforce Invariants via Tagged Unions**:
  - Mathematical constraints that exhibit mutual exclusion MUST be modeled with Zig tagged unions (`union(enum)`).
  - Use `ThumbnailPadding = union(enum) { none, letterbox: struct { v_min: f32, v_max: f32, pad_px: f32 }, pillarbox: struct { u_min: f32, u_max: f32, pad_px: f32 } }` to guarantee by construction that:
    1. Letterboxing and pillarboxing are mutually exclusive.
    2. Active image axes are centered symmetrically ($v\_\\text{max} = 1.0 - v\_\\text{min}$ and $u\_\\text{max} = 1.0 - u\_\\text{min}$).
    3. Unpadded axis remains normalized to $[0.0, 1.0]$.
  - Decouple geometric domain calculations from GPU rendering state (`alpha`, `rotation_angle`).
- **Composite Container Anti-Pattern**:
  - NEVER model an entire TIFF IFD as a mutually exclusive tagged union (`union(enum) { raw_sensor, preview, container, exif }`).
  - In TIFF-EP and Sony ARW specifications, IFD0 is a composite entity: it is simultaneously a container (pointing to SubIFDs via tag `0x014A`), a preview provider (tags `0x0201`/`0x0202`), and an EXIF directory (tag `0x8769`). Forcing mutually exclusive roles on container directories breaks preview extraction. Tagged unions belong on payload/result types, not multi-role containers.

## 18. Clay Scroll Containers vs. Pointer-Driven Controls Decoupling

- **Disable Drag-Scrolling for Desktop Pointer Containers**:
  - In desktop UI environments, Clay scroll containers containing interactive
    widgets (sliders, scrubbers, buttons) MUST specify
    `enableDragScrolling = false` in `clay.updateScrollContainers(...)`.
  - Passing `true` causes mouse button down events on child controls to initiate
    container pan/scroll gestures instead of delivering slider drag events.
- **Pointer Scroll Delta Zeroing During Active Manipulation**:
  - While an interactive control is actively being manipulated
    (`drag_state == .slider` or `active_slider != null`), mouse wheel and
    trackpad scroll deltas (`scroll_delta`) MUST be zeroed before dispatching
    to `updateScrollContainers`.
  - This prevents accidental vertical container movement and layout jitter
    while the user is fine-tuning slider values.

## 19. Photographic Contrast Blending, Exposure Ordering & Monotonicity

- **Classic Per-Channel Contrast & Dynamic Blending**:
  - Contrast defaults to 100% classic RGB per-channel power-law contrast around
    physical 18% middle gray (`0.18`), providing rich, filmic saturation.
  - A dedicated `contrast_blend` parameter enables smooth linear interpolation
    between pure luminance contrast (`0.0`) and classic RGB contrast (`1.0`).
- **Post-Contrast Linear Exposure Ordering**:
  - Photometric exposure gain $\\exp_2(\\text{brightness} \\times 2.0)$ MUST be
    multiplied *after* contrast in scene-referred linear photometric space.
  - Ordering exposure after contrast ensures that altering contrast does not
    rescale exposure stop gains, matching physical camera exposure behavior.
- **Monotonic Root-Space Tonal Quad**:
  - Highlights, Shadows, Whites, and Blacks curves operate in perceptual
    root-space ($u = \\sqrt{Y}$) with bounded EV weights ($0.5B, 1.0S, 1.0H,
    0.5W$) satisfying $\\frac{d(\\Delta \\text{EV})}{d(\\log_2 Y)} \\ge -1.0$.
  - This mathematically guarantees that tone inversions and solarization
    contours cannot occur across any combination of slider values.
  - Highlight weighting strictly tapers to 0 at $u = 0.98$ ($Y \\approx 0.96$),
    protecting specular whites from chalkiness.
- **Opponent White Balance & Neutral Anchors**:
  - Opponent chromatic adaptation ($T$ Amber/Blue, $G$ Magenta/Green) normalizes
    against Rec.709 perceived luminance ($Y = 0.212639R + 0.715169G +
    0.072192B$) to preserve 100% perceived brightness across color temperature
    adjustments.
  - Hermite $C^1$ envelopes anchor deep blacks ($Y \\le 0.04$) and specular
    highlights ($Y \\ge 0.92$), preventing noise tinting and white casts.

## 20. DPI Coordinate Alignment, Universal Zoom & Pre-Scaled Layout Invariants

- **Framebuffer Pixels vs. Logical Window Points**:

  - In High-DPI, Wayland, and Retina environments, window dimensions
    (`win.handle.getSize()`) represent logical coordinate points, whereas GPU
    framebuffers (`win.handle.getSizeInPixels()`) represent physical pixels.
  - When computing the base scale $Z\_{\\text{base}}$ or evaluating physical
    viewport overflow (`isImageOverflowing`), always query physical pixel
    dimensions (`getSizeInPixels()`).
  - Deductions for UI overlay panels (e.g. Clay debug inspector, docked edit
    panel) must be multiplied by the display scale factor $S =
    \\frac{\\text{pix_w}}{\\text{win_w}}$ before subtracting from physical
    dimensions. Failing to do so causes scale mismatches and visual jumps when
    switching from preset to manual zoom.

- **Clay Layout Pre-Scaled Rectangles vs. Universal Zoom Quads**:

  - Clay UI computes element bounding boxes (`rect.w`, `rect.h`) based on
    preset fitting math (`computeDrawDims`). In preset modes (`.fit`, `.fill` /
    `crop`), `rect.w` and `rect.h` are ALREADY the scaled screen dimensions.
  - NEVER multiply `rect.w` by $Z\_{\\text{base}}$ in preset modes, as this
    squares the scale factor ($W\_{\\text{auth}} \\cdot Z\_{\\text{base}}^2$) and
    shrinks the image twice.
  - Preset mode quad rendering must use an effective zoom multiplier of `1.0`
    over Clay's layout rect, reserving $Z$ magnification strictly for manual
    inspection mode (`mode == .manual`).

- **Continuous Crossing Detent Logic for Stepped Inputs**:

  - When implementing snap detents (e.g. snapping to 100% / $Z = 1.0$) for
    stepped inputs (e.g. 25% jumps from keyboard shortcuts `"i"` and `"o"`),
    never test an epsilon band around the target (`abs(target - 1.0) < 0.05`).
    Because input steps ($0.25$) exceed the epsilon width ($0.05$), the detent
    is easily bypassed.
  - Always test for boundary crossing:
    ```zig
    // In zoom_in:
    if (old_zoom.get() < 1.0 and target >= 1.0) target = 1.0;
    // In zoom_out:
    if (old_zoom.get() > 1.0 and target <= 1.0) target = 1.0;
    ```

- **Navigation Context Switching vs. Physical Overflow**:

  - Arrow and Vim navigation keys (`h`/`j`/`k`/`l`) must switch between photo
    navigation and directional panning based strictly on physical viewport
    boundary overflow (`isImageOverflowing()`), never on `zoom > 1.0`. Small
    images magnified in "Fit" mode should never be trapped in panning mode.

## 21. Clay UI Modularization & Visual Regression Invariants

- **Component Decomposition**:
  - Break down large, multi-screen Clay UI procedures (e.g. Command Palette
    renderers, Inspector panels) into focused helper functions (e.g.
    `renderDirectoryListItem`, `renderClassificationBadge`,
    `renderSearchInput`).
- **Strict Visual Parameter Preservation**:
  - Extracted helper functions MUST retain exact layout dimensions and styling
    properties:
    - Sizing constraints (`.w = .grow`, `.h = .fixed(...)`).
    - Inner and outer padding (`.top`, `.bottom`, `.left`, `.right`).
    - Corner radius definitions.
    - Background colors and dynamic alpha modulation (`progress` multiplier).
    - Border colors, edge specifications, and widths.
  - The headless IPC test runner (`peng-test-runner`) performs pixel-exact
    comparisons against baseline PNG screenshots. Any altered padding or missing
    alpha scale factor will fail visual integration tests.

## 22. Progressive Loading Invariance, Dimension Poisoning & Dissolve Sizing

- **Prohibition of Worker Thumbnail Dimension Fallback**:

  - Background decode workers (`decodeRawFile`, `decodeWorker`) MUST NEVER fall
    back to low-resolution thumbnail surface dimensions (`t_surf.w()`,
    `t_surf.h()`) when true full-resolution or raw sensor dimensions are
    unknown.
  - Workers must explicitly set `full_w = 0.0, full_h = 0.0`. Emitting thumbnail
    dimensions as full image dimensions permanently poisons cache entries,
    causing layout and zoom math to compute false aspect ratios or snap
    erratically when full decompression completes.

- **Monotonic Area Dimension Updates**:

  - Dimension events (`handleDimensionsProbedEvent`, `handleExifThumbnailEvent`,
    `handleImageDecodedEvent`) arrive asynchronously from worker threads and
    main-thread header probes.
  - Event handlers must guard dimension mutations using strict monotonic area
    comparison:
    ```zig
    const cur_area = entry.full_w * entry.full_h;
    const new_area = new_w * new_h;
    if (cur_area <= 0.0 or new_area > cur_area) {
        entry.full_w = new_w;
        entry.full_h = new_h;
    }
    ```
  - This prevents lower-resolution thumbnail events or unrotated previews from
    downgrading already-probed authoritative sensor dimensions.

- **Small-Image Viewport Fitting Heuristic (`only_has_thumb`)**:

  - The viewport layout heuristic promoting `.shrink` mode to `.full` during
    background decode (`computeDrawDims`) must be strictly guarded by
    `only_has_thumb`:
    ```zig
    const only_has_thumb = entry.full_w <= 0.0 and
        entry.raw_metadata.getSensorDims() == null and
        entry.thumbnail != .none;
    ```
  - This allows thumbnails of large photos with yet-unknown dimensions to expand
    to the viewport on Frame 1, while preventing genuinely small images (e.g.
    64x64 icons or small badges whose dimensions are known) from temporarily
    blowing up to fill the screen and snapping back down upon decode.

- **Universal Zoom Dissolve Quad Sizing Invariance**:

  - In crossfade transitions, outgoing dissolve quads
    (`ImageTransitionPrevQuad`) and manual inspection quads must calculate
    physical screen dimensions directly from native unrotated source
    dimensions and zoom factor:
    ```zig
    const dst_w = sw * z;
    const dst_h = sh * z;
    ```
  - NEVER multiply Clay's pre-fitted screen rect by $Z$, which causes $O(Z^2)$
    double-scaling. Quad dimensions must include NaN/infinite guards
    (`std.math.isFinite(z) and z > 0.0`) and early-out on degenerate rects
    ($w \\le 0$ or $h \\le 0$).

- **Immediate Zoom Factor Synchronization on Navigation**:

  - Navigation actions (`navigateToIndex`, filter changes) must immediately
    synchronize `vp.zoom_factor = UniversalZoom.init(self.getBaseScale())` and
    reset pending pan/zoom offsets upon index transition. Deferring zoom factor
    recalculation to subsequent frames leaves the viewport in a stale scale
    state, causing Frame-1 thumbnail scale flickers.
