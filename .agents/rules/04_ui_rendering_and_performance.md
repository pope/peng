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
