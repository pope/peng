# DPI Layout & Arc Geometry Math Reference

## High-DPI Coordinate Transformations

- **Logical to Physical Pixels**:
  The immediate-mode `RectCut` UI layout engine works in logical coordinate
  points (`geom.FRect`). Convert logical bounding boxes to physical GPU
  framebuffer pixels using Retina scale factors:
  $$\\text{physical_x} = \\lfloor \\text{logical_x} \\times \\text{scale_x} \\rceil$$
  $$\\text{physical_y} = \\lfloor \\text{logical_y} \\times \\text{scale_y} \\rceil$$

______________________________________________________________________

## Continuous Arc & Annular Quad Geometry Formulas

- When building circular or rounded UI layout boxes, compute quadrant vertices
  using continuous `@sin` and `@cos` floating-point math:
  $$x = \\text{center_x} + \\text{radius} \\times \\sin(\\theta)$$
  $$y = \\text{center_y} + \\text{radius} \\times \\cos(\\theta)$$

- For inner/outer rounded borders (annular quad vertices), maintain separate
  inner and outer radii using single-precision floats (`f32`) to prevent vertex
  overlapping and anti-aliasing artifacts.

______________________________________________________________________

## Zoom-to-Cursor Anchor Panning Math

- **Cursor Zoom Anchor Formula**:
  When zooming into a viewport relative to a focus point (e.g. mouse cursor
  $(x\_{\\text{mouse}}, y\_{\\text{mouse}})$), compute relative offset relative to
  viewport center $(x\_{\\text{center}}, y\_{\\text{center}})$:
  $$r_x = x\_{\\text{mouse}} - x\_{\\text{center}}, \\quad r_y = y\_{\\text{mouse}} - y\_{\\text{center}}$$
  $$\\text{ratio} = \\frac{Z\_{\\text{new}}}{Z\_{\\text{old}}}$$
  $$\\text{pan}\_x = r_x - (r_x - \\text{pan}\_x) \\times \\text{ratio}$$
  $$\\text{pan}\_y = r_y - (r_y - \\text{pan}\_y) \\times \\text{ratio}$$

- **Domain Encapsulation**:
  Use `ViewportParams.zoomAtPoint(new_zoom, focus_phys, center_phys)` (`ZoomFactor`, `PhysicalPoint`, `PhysicalPoint`) to update viewport zoom factor and anchor pan offsets in a single domain call.

______________________________________________________________________

## Viewport Panning & Mouse Input Coordinate Space Rules

- **Coordinate Space Wrappers (`src/geom/root.zig`)**:
  Use `LogicalDims` / `LogicalPoint` for UI layout and window points,
  `PhysicalDims` / `PhysicalPoint` / `PositiveDimsU32` for GPU framebuffer and
  texture pixels (`PhysicalDims.initPositive(w, h)`,
  `PhysicalDims.toPositiveU32()`, `PositiveDimsU32.initClamped()`), and
  `DpiScale` (`FrameInput.dpiScale()`) to convert between spaces
  (`toPhysical(scale)`, `toLogical(scale)`).

- **Physical Pixel Basis**:
  `ViewportParams.pan_x` and `pan_y` store offsets in **physical framebuffer pixels** to match GPU rasterization space in `appendImageCommand`.

- **HiDPI Mouse Drag Differential**:
  Physical mouse drag deltas update viewport pan offsets in framebuffer pixels:
  $$\\Delta x\_{\\text{phys}} = \\text{FrameInput.pixMouseX}() - v.\\text{last_x}$$
  $$\\Delta y\_{\\text{phys}} = \\text{FrameInput.pixMouseY}() - v.\\text{last_y}$$
  $$\\text{pan_x} \\mathrel{+}= \\Delta x\_{\\text{phys}}, \\quad \\text{pan_y} \\mathrel{+}= \\Delta y\_{\\text{phys}}$$

- **Scroll Wheel & 2-Finger Touchpad Panning**:
  Scroll events accumulate into `scroll_delta_x/y` in `polling.zig`:
  $$\\text{scroll_delta} = \\text{event.wheel.x} \\times \\text{MOUSE_WHEEL_SCROLL_MULTIPLIER} \\quad (\\text{MOUSE_WHEEL_SCROLL_MULTIPLIER} = 6.0)$$
  Viewport panning converts scroll deltas to physical framebuffer pixels:
  $$\\Delta \\text{pan_x} = \\text{scroll_delta_x} \\times \\text{scale_x} \\times 5.0$$
  $$\\Delta \\text{pan_y} = \\text{scroll_delta_y} \\times \\text{scale_y} \\times 5.0$$

- **Mouse Input Scaling (`physicalMousePos()` / `pixMouseX()` / `pixMouseY()`)**:
  SDL mouse state and UI pointer events are in **logical points**. Convert
  mouse positions to physical pixels before performing viewport pan/zoom
  operations using `FrameInput` helper methods:
  $$\\text{mouse_x}_{\\text{phys}} = \\text{FrameInput.pixMouseX}() = \\text{mouse_x} \\times \\text{scale_x}$$
  $$\\text{mouse_y}_{\\text{phys}} = \\text{FrameInput.pixMouseY}() = \\text{mouse_y} \\times \\text{scale_y}$$

- **Viewport Center in Physical Pixels**:
  When calling `zoomAtPoint`, the container center
  `logical_center: LogicalPoint` must be converted to physical pixels via
  `logical_center.toPhysical(scale)`.

- **Logical UI Overlays vs Physical Viewport**:
  UI overlay elements (`"InfoOverlayCard"`, `"StatsPanel"`) store drag
  offsets in **logical points** (`input.mouse_x`), whereas Viewport pan and
  zoom-at-cursor operations operate strictly in **physical pixels**
  (`input.physicalMousePos()`).

______________________________________________________________________

## Pinch-to-Zoom: Wayland Touchpad vs Multi-Touch Gestures

- **Wayland / macOS Trackpad Pinch (`SDL_EVENT_PINCH_*`)**:

  - Pinch delta accumulation:
    $\\text{pinch_delta} \\mathrel{+}= (\\text{event.pinch.scale} - 1.0)$ on
    `SDL_EVENT_PINCH_UPDATE` (ignoring uninitialized scale on
    `SDL_EVENT_PINCH_BEGIN`).
  - Focus anchor: Mouse cursor physical location
    $(x\_{\\text{mouse}} \\times \\text{scale_x}, y\_{\\text{mouse}} \\times \\text{scale_y})$.

- **Touchscreen Multi-Finger Gestures (`SDL_EVENT_FINGER_*`)**:

  - Inter-finger distance:
    $$\\text{dist} = \\sqrt{((x_2 - x_1) \\times \\text{win_w})^2 + ((y_2 - y_1) \\times \\text{win_h})^2}$$
  - Pinch delta accumulation:
    $$\\text{pinch_delta} \\mathrel{+}= \\frac{\\text{dist} - \\text{last_dist}}{\\text{last_dist}}$$
  - Focus anchor: Touch midpoint physical location
    $(\\text{midpoint_x} \\times \\text{scale_x}, \\text{midpoint_y} \\times \\text{scale_y})$.

- **Zoom Application (`viewport.zig`)**:

  - **Exponential Wheel Zoom**:
    $$Z\_{\\text{new}} = \\text{clamp}(Z\_{\\text{old}} \\cdot \\exp(\\text{scroll_delta_y} \\cdot 0.05))$$
  - **Multiplicative Touchpad Pinch with Negative Safety Guard**:
    $$Z\_{\\text{new}} = \\text{clamp}(Z\_{\\text{old}} \\cdot \\max(0.01, 1.0 + \\text{pinch_delta} \\cdot 0.5))$$
  - **Preset Seeding**: When initiating a wheel or pinch gesture from `.fit` or
    `.fill` mode, seed $Z\_{\\text{old}}$ from `state.getBaseScale()` rather than
    an uninitialized or static multiplier.
  - **Dynamic Viewport Center**: Focus coordinates must anchor relative to the
    dynamic center queried from
    `state.viewer.ui.interaction.resolveViewportCenter(...)` (backed by
    `InteractionState.viewport` inside `src/state/interaction.zig`) rather than
    assuming static window center, ensuring correct anchor positioning when
    side panels are docked.
  - **Viewport Anchor Call**:
    `ViewportParams.zoomAtPoint(`
    `new_zoom, focus, logical_center.toPhysical(scale))`

______________________________________________________________________

## Immediate-Mode `FRect` Bounding Box Recording & Hit-Testing

- **Avoid Static Coordinate Assumptions**:
  When building custom interactive widgets (e.g., sliders, scrubbers, toggle
  switches, docked side panels, or resize splitters), never calculate click or
  drag coordinates using fixed window dimensions or static offsets. Layout
  dimensions change dynamically due to side panels, animations, or DPI changes.

- **Record Bounds During Layout & Query in `src/state/interaction.zig`**:
  During the immediate-mode `RectCut` layout pass (`renderFrame`,
  `renderEditPanel`, `renderPalette`, `renderStatsOverlay`), record widget
  `FRect` bounds into `InteractionState` (`setSliderRects`, `setEditPanelRects`,
  `setPaletteModalRect`, `recordPaletteItem`, `setInfoPanelRects`,
  `setStatsPanelRects`), and query them on `InteractionState` in
  `src/state/interaction.zig` (`hitTestEditPanel`, `hitTestPaletteClick`,
  `isHovered`):

  ```zig
  // src/state/interaction.zig: hit-test against recorded slider track FRect
  pub fn getHoveredSliderTrack() ?SliderTrackHit {
      if (!state.has_layout) return null;
      if (!state.edit_scroll_list.contains(state.pointer)) return null;
      inline for (intents.specs, 0..) |spec, idx| {
          const track = state.slider_tracks[idx];
          const knob = state.slider_knobs[idx];
          if (track.contains(state.pointer) or knob.contains(state.pointer)) {
              return .{
                  .param = spec.param,
                  .x = track.x,
                  .w = track.w,
              };
          }
      }
      return null;
  }
  ```

- **Invariance Across Active Slide Animations & Resizing**:
  Because `InteractionState` stores the exact computed `FRect` bounding boxes
  from the preceding layout pass (clipped against scroll container rects where
  applicable), interactive widgets maintain 100% hit-test accuracy even when
  containers are mid-flight in an opening/closing animation or scrolled.

______________________________________________________________________

## Compound Row Badge Alignment & Dynamic Truncation Budgeting

- **Right-Cut Badges & Remaining-Width Text Truncation**:
  When positioning status pills/badges (e.g. `[PICK]`, `[REJECT]`, or shortcut
  badges) in a list row:
  1. **Right-to-Left Badge Cuts**: Advance `right_limit` leftward from
     `rect.x + rect.w - pad_right` as each badge is measured and emitted,
     vertically centering each badge at `rect.y + (rect.h - badge_h) * 0.5`.
  2. **Dynamic Truncation Budgeting**: Compute the remaining horizontal space
     `available_text_w = @max(right_limit - text_x, 10.0)` and pass it directly
     to `truncateFilenameMiddle` / `truncateDirectory` so text never overlaps
     adjacent badges.

______________________________________________________________________

## Normalized Theme Color Alpha Invariant (0.0 .. 1.0)

- **Normalized Float Range**:
  Utility functions modifying color alpha (such as `theme.withAlpha(color, alpha)`) strictly accept floating-point alpha in the normalized range `0.0..1.0`.
- **Clamping Trap**:
  Passing raw integer percentages (such as `40` instead of `0.40`) causes the function to clamp alpha to `1.0` (100% solid opacity). If text and badge background share the same theme color hue, 100% opacity renders text invisible against its background, appearing as an empty solid block. Always pass normalized floating-point factors (e.g. `theme.withAlpha(theme.green, 0.25 * progress)`).
