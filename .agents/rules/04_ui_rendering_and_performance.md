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
