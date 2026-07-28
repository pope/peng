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
