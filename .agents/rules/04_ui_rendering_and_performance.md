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
