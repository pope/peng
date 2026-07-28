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
