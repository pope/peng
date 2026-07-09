______________________________________________________________________

## name: zig-gui-practices description: Reference guidelines and best practices for developing GUI applications in Zig with Clay and SDL3, focusing on layout math, DPI scaling, and memory safety. Trigger this skill when the user asks to implement, debug, or optimize GUI code, layouts, DPI scaling, aspect ratios, or memory management in Zig applications.

# Best Practices for Zig GUI Development

This guide outlines core principles, patterns, and mathematical techniques derived during the development of the Peng Image Viewer. Follow these practices when extending the viewer or developing similar GUI applications in Zig.

______________________________________________________________________

## 1. Unified State & Constant Layout Structs

Instead of duplicating states (e.g., maintaining multiple lists or parallel command palette definitions), consolidate similar subsystems into a single structure using a runtime type tag:

- **Single State Instance**: Keep a single state struct (like `PaletteState`) and use an enum (like `PaletteType`) to represent the active mode.
- **Unified UI Layout Configuration**: Switch once on the active type at the beginning of layout functions to return a configuration struct containing all structural strings and metrics:
  ```zig
  const PaletteConfig = struct {
      title: []const u8,
      placeholder: []const u8,
      element_id: []const u8,
      base_item_height: f32,
  };
  ```
  This eliminates inline switch duplication and prevents `comptime_float` runtime-control dependencies by providing concrete types.

______________________________________________________________________

## 2. High-DPI / Retina Screen Scaling

Displays with high pixel density (Retina screens) distinguish between **window coordinates (logical points)** and **physical screen pixels**.

- **DPI Scale Computation**:
  Compute horizontal and vertical scale factors at layout time using logical window size and physical pixel size:
  ```zig
  const scale_x = @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w));
  const scale_y = @as(f32, @floatFromInt(pix_h)) / @as(f32, @floatFromInt(win_h));
  ```
- **Viewport Height Calculation**:
  When calculating the available viewport space, subtract header/footer heights scaled by the DPI factor from the total physical height:
  ```zig
  const view_h = height - (title_bar_h + nav_bar_h) * scale_y - padding * 2.0;
  ```
  *Failing to scale subtracted heights causes clipping and overflow errors on Retina screens.*
- **Input Deltas**:
  Mouse events (like mouse drags) and keyboard panning offsets must scale by `scale_x` and `scale_y` to maintain consistent speed across screen densities:
  ```zig
  self.pan_x += 30.0 * scale_x;
  ```

______________________________________________________________________

## 3. Centering, Fitting, and Zooming Math

### Zoom-to-Mouse (Focus Centered Zoom)

To zoom in/out while keeping the point under the mouse pointer static on the screen:

1. Compute the relative offset ($rel_x$, $rel_y$) of the mouse from the default screen center:
   $$rel_x = x\_{mouse} - x\_{center}$$
1. Update the pan offset using the ratio of new zoom to old zoom:
   $$pan\_{new} = rel_x - (rel_x - pan\_{old}) \\cdot \\frac{zoom\_{new}}{zoom\_{old}}$$

### Image Fitting & Aspect Ratios

Let $R\_{img} = \\frac{img_w}{img_h}$ and $R\_{view} = \\frac{view_w}{view_h}$.

- **`full` (Aspect Fit)**:
  - If $R\_{img} > R\_{view}$: width is limited. $draw_w = view_w$, $draw_h = \\frac{view_w}{R\_{img}}$.
  - Else: height is limited. $draw_h = view_h$, $draw_w = view_h \\cdot R\_{img}$.
- **`crop` (Aspect Fill)**:
  - If $R\_{img} > R\_{view}$: height is filled. $draw_h = view_h$, $draw_w = view_h \\cdot R\_{img}$.
  - Else: width is filled. $draw_w = view_w$, $draw_h = \\frac{view_w}{R\_{img}}$.
- **`shrink` (Fit if Larger)**:
  - If image fits inside viewport ($img_w \\le view_w$ and $img_h \\le view_h$), draw at 100%.
  - Else, apply the **`full`** aspect fit calculations.

______________________________________________________________________

## 4. Memory Safety & Lifecycle Management in UI Loops

Interactive GUI loops run at 60+ frames per second. Memory management must prevent heap fragmentation and leaks.

- **Per-Frame Arena Allocator**:
  Use a per-frame Arena allocator (`frame_arena`) for all allocations inside the rendering loop (such as UI text generation, formatted strings, and layout structures).
- **Reset Arena capacity**:
  Reset the arena at the start of each frame iteration to reclaim memory instantly without freeing and re-allocating heap headers:
  ```zig
  _ = frame_arena.reset(.retain_capacity);
  ```
- **Persistent CLI Parsers**:
  Command-line or startup config parsers (like `Args.Iterator`) should be allocated on a General Purpose Allocator (GPA) and cleaned up immediately before entering the main loop:
  ```zig
  var args_it = try std.process.Args.Iterator.initAllocator(args, gpa);
  defer args_it.deinit();
  ```
