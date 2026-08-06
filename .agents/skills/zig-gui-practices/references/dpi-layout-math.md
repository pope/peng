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
