# Clay UI DPI Scaling & Geometry Standards

## 1. Clay Layout Coordinate Space

- Always set Clay layout dimensions (`clay.setLayoutDimensions`) and pointer state (`clay.setPointerState`) using **Logical Window Coordinates** (`win_w`, `win_h`, `mouse_x`, `mouse_y`).
- Never pass raw physical pixel framebuffer sizes to Clay layout initialization, as this breaks internal unscaled metrics like `Clay__debugViewWidth` (400pt) and debug panel text sizing on HiDPI displays.

## 2. GPU Renderer Responsibilities

- Convert Clay bounding boxes from logical points to physical pixels at GPU vertex generation time:
  - `rect.x = bounding_box.x * scale_x`
  - `rect.w = bounding_box.width * scale_x`
  - `corner_radius = config.corner_radius * scale_x`
  - `font_size = config.font_size * scale_x`
- Keep scissor rectangles in physical pixel coordinates and clamp bounds to window limits.

## 3. Geometry Generation for Arcs and Rounded Rectangles

- Compute arc vertex angles using continuous floating-point math (`@cos`, `@sin`) rather than integer-divided lookup tables to avoid degenerate zero-area triangles.
- Construct rounded border arcs as **annular quads** connecting inner ($r\_{\\text{inner}} = \\max(r - t, 0)$) and outer ($r\_{\\text{outer}} = r$) circular vertices.

## 4. Input State Invariants

- Keep mouse pointer coordinates in `FrameInput` in logical window points as the primary input state. Provide helper methods (`pixMouseX()`, `pixMouseY()`) for pixel-space conversions.
- Keep mouse scroll wheel deltas in logical points to maintain uniform scroll speed across displays with different scaling factors.

## 5. SDL GPU Render Loop Optimizations

- **Zero-Area Scissor Skipping**: When calculating scissor bounds, if `scissor.w <= 0` or `scissor.h <= 0` (or if origin lies off-screen), skip setting scissors and skip dispatching `drawPrimitives` for that batch entirely to avoid unnecessary GPU pipeline state changes.
- **Transfer Buffer Pooling**: Pack transient text texture surfaces and dynamic vertex geometry into persistent per-frame `TransferBuffer`s using aligned offsets (`std.mem.alignForward(usize, offset, 512)`), avoiding per-element buffer allocation and release overhead inside the render loop.

## 6. Generic Allocator Polymorphism

- Functions accepting `allocator: std.mem.Allocator` must always pair `allocator.alloc()` with `defer allocator.free()`, even when called in an arena context. This guarantees memory safety and leak-free operation regardless of whether an Arena, GeneralPurposeAllocator, or Testing allocator is passed behind the vtable interface.
