# DPI Layout & Arc Geometry Math Reference

## High-DPI Coordinate Transformations

- **Logical to Physical Pixels**:
  Clay UI layout engine works in logical coordinate points. Convert logical bounding boxes to physical GPU framebuffer pixels using Retina scale factors:
  $$\\text{physical_x} = \\lfloor \\text{logical_x} \\times \\text{scale_x} \\rceil$$
  $$\\text{physical_y} = \\lfloor \\text{logical_y} \\times \\text{scale_y} \\rceil$$

______________________________________________________________________

## Continuous Arc & Annular Quad Geometry Formulas

- When building circular or rounded UI layout boxes, compute quadrant vertices using continuous `@sin` and `@cos` floating-point math:
  $$\\text{x} = \\text{center_x} + \\text{radius} \\times \\sin(\\theta)$$
  $$\\text{y} = \\text{center_y} + \\text{radius} \\times \\cos(\\theta)$$

- For inner/outer rounded borders (annular quad vertices), maintain separate inner and outer radii using single-precision floats (`f32`) to prevent vertex overlapping and anti-aliasing artifacts.

______________________________________________________________________

## Zoom-to-Cursor Anchor Panning Math

- **Cursor Zoom Anchor Formula**:
  When zooming into a viewport relative to a focus point (e.g. mouse cursor $(x\_{\\text{mouse}}, y\_{\\text{mouse}})$), compute relative offset relative to viewport center $(x\_{\\text{center}}, y\_{\\text{center}})$:
  $$r_x = x\_{\\text{mouse}} - x\_{\\text{center}}, \\quad r_y = y\_{\\text{mouse}} - y\_{\\text{center}}$$
  $$\\text{ratio} = \\frac{Z\_{\\text{new}}}{Z\_{\\text{old}}}$$
  $$\\text{pan}\_x = r_x - (r_x - \\text{pan}\_x) \\times \\text{ratio}$$
  $$\\text{pan}\_y = r_y - (r_y - \\text{pan}\_y) \\times \\text{ratio}$$

- **Domain Encapsulation**:
  Use `ViewportParams.zoomAtPoint(new_zoom, mouse_x, mouse_y, center_x, center_y)` to update viewport zoom factor and anchor pan offsets in a single domain call.

______________________________________________________________________

## Viewport Panning & Mouse Input Coordinate Space Rules

- **Physical Pixel Basis**:
  `ViewportParams.pan_x` and `pan_y` store offsets in **physical framebuffer pixels** to match GPU rasterization space in `appendImageCommand`.

- **Mouse Input Scaling (`pixMouseX()` / `pixMouseY()`)**:
  SDL mouse state and Clay pointer events are in **logical points**. Convert mouse positions to physical pixels before performing viewport pan/zoom operations using `FrameInput` helper methods:
  $$\\text{mouse_x}_{\\text{phys}} = \\text{FrameInput.pixMouseX}() = \\text{mouse_x} \\times \\text{scale_x}$$
  $$\\text{mouse_y}_{\\text{phys}} = \\text{FrameInput.pixMouseY}() = \\text{mouse_y} \\times \\text{scale_y}$$

- **Viewport Center in Physical Pixels**:
  When calling `zoomAtPoint`, the container center $(x\_{\\text{center}}, y\_{\\text{center}})$ must also be converted to physical pixels ($\\text{cx} \\times \\text{scale_x}, \\text{cy} \\times \\text{scale_y}$).

- **Logical UI Overlays vs Physical Viewport**:
  UI overlay elements (`InfoCard`, `StatsCard`) store drag offsets in **logical points** (`input.mouse_x`), whereas Viewport pan and zoom-at-cursor operations operate strictly in **physical pixels** (`input.pixMouseX()`, `input.pixMouseY()`).
