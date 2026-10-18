---
name: zig-gui-animations
description: >-
  Architectural patterns and implementation recipes for high-performance GUI animations in Zig, Clay UI, and SDL3 GPU.
  Trigger immediately for:
  - DOD Animation State: flat static SoA arrays, ChannelDescriptor table, bitmask tracking, zero-allocation lifecycle.
  - Easing & Curves: normalized time evaluation, NaN guards, proportional retargeting/interruption duration math.
  - GPU Text Alpha Blitting: RGB-only text texture caching, vertex color alpha modulation, zero font re-rasterization.
  - Clay UI Transitions: hierarchical alpha scaling, modal dissolve animations, and input decoupling during dismissal.
  - Image Crossfade & Scrubbing: dual-quad viewport dissolves, quadratic alpha falloff, fast-navigation snap-and-cut bypasses.
  DO NOT trigger for:
  - Pure non-visual business logic, database queries, CLI arguments, or network I/O.
---

# Zig GUI & GPU Animation Architecture

This guide provides architectural patterns and procedural recipes for building zero-allocation, 120Hz-smooth GUI animation systems in Zig, integrating with Clay immediate-mode UI and SDL3 GPU hardware rendering.

______________________________________________________________________

## 1. Data-Oriented Animation Engine (DOD)

### Flat Static Structure-of-Arrays (SoA) Layout

Store animation parameters in contiguous parallel static arrays rather than an Array of Structures (AoS) or dynamic list. This packs simulation fields (`values`, `start_vals`, `target_vals`, `elapsed_ms`, `durations_ms`, `easings`) into cache lines without any heap allocations.

```zig
pub const MAX_CHANNELS: usize = 32;

pub const ChannelDescriptor = struct {
    default_open_duration_ms: f32,
    default_close_duration_ms: f32,
    open_easing: EasingType,
    close_easing: EasingType,
    default_value: f32 = 0.0,
};

pub const AnimationState = struct {
    values: [MAX_CHANNELS]f32 = initValues(),
    start_vals: [MAX_CHANNELS]f32 = initValues(),
    target_vals: [MAX_CHANNELS]f32 = initValues(),
    elapsed_ms: [MAX_CHANNELS]f32 = [_]f32{0.0} ** MAX_CHANNELS,
    durations_ms: [MAX_CHANNELS]f32 = [_]f32{0.0} ** MAX_CHANNELS,
    easings: [MAX_CHANNELS]EasingType = [_]EasingType{.linear} ** MAX_CHANNELS,
    active_mask: u32 = 0,
    // ...
};
```

### Key DOD Rules:

1. **Zero Runtime Allocations**: Pre-sized flat arrays total 676 bytes. Initialization and per-frame methods (`tick`, `get`, `start`, `startFrom`, `trigger`, `setImmediate`, `settle`, `settleAll`) require **zero heap allocations**.
2. **Bitmask Active Tracking**: Use a single integer bitmask (`active_mask: u32`) where bit $i$ indicates whether channel $i$ is actively animating. This enables $O(1)$ zero-branch checks for event loop wakeups:
   ```zig
   pub inline fn hasActiveAnimations(self: *const AnimationState) bool {
       return self.active_mask != 0;
   }
   ```
3. **Compile-Time Channel Descriptors**: Static descriptor table `CHANNEL_DESCRIPTORS` maps each `AnimationChannel` to default open/close durations, easings, and base values.
4. **Adaptive Event Loop Sleeping**: Integrate `hasActiveAnimation()` (`animations.hasActiveAnimations()`), `pan_controller.isBusy()`, and `zoom_controller.isBusy()` into `AppState.computeFrameWaitStrategy` (`isBusy()` / `getWaitTimeoutMs()` in `src/app/state.zig` and `src/viewer.zig`). When animations or smooth controllers run, the loop ticks at display refresh rate; when only timers or background tasks are active, it sleeps via `waitEventTimeout`; when settled, it drops to 0% CPU blocking wait (`waitEvent`).

______________________________________________________________________

## 2. Easing & Numerical Robustness

### Clamping and NaN Guards

Normalized time $t = \\text{elapsed} / \\text{duration}$ must be guarded against NaN and clamped to $[0.0, 1.0]$:

```zig
pub inline fn eval(self: EasingType, t: f32) f32 {
    if (std.math.isNan(t)) return 0.0;
    const ct = std.math.clamp(t, 0.0, 1.0);
    return switch (self) {
        .linear => ct,
        .ease_out_cubic => 1.0 - std.math.pow(f32, 1.0 - ct, 3),
        .ease_out_quad => 1.0 - (1.0 - ct) * (1.0 - ct),
        // ...
    };
}
```

### Proportional Interruption Scaling

When reversing or interrupting a scalar UI animation mid-flight (such as closing a palette or floating overlay that hasn't finished opening), scale the close duration by the current progress `p` (with a 30ms floor) and invoke `animations.start(...)`:

```zig
const progress = self.viewer.animations.get(.palette_reveal);
const close_dur = @max(DURATION_PALETTE_CLOSE_MS * progress, 30.0);
self.viewer.animations.start(
    .palette_reveal,
    0.0,
    close_dur,
    .ease_out_quad,
);
```

______________________________________________________________________

## 3. GPU Text Renderer Alpha Decoupling (Zero Cache Thrashing)

*(See authoritative invariant: `04_ui_rendering_and_performance.md` §1)*

### The Anti-Pattern: Baking Alpha into Text Textures

If alpha is part of `TextCacheKey`, an animating label generates 15–20 distinct
textures across a 140ms fade, exhausting VRAM and thrashing font rasterization.

### The Correct Pattern: Hardware Vertex Blitting

1. **Hash RGB Only in Cache Key**:
   ```zig
   const color_rgb_u32 = @as(u32, @intFromFloat(text_data.text_color[0])) |
       (@as(u32, @intFromFloat(text_data.text_color[1])) << 8) |
       (@as(u32, @intFromFloat(text_data.text_color[2])) << 16);
   ```
2. **Rasterize Once at Solid Alpha (`a = 255`)**: Cache glyphs at full opacity.
3. **Pack Requested Alpha into Vertex Color Quad**:
   ```zig
   const text_alpha_u8 = @as(
       u8,
       @intFromFloat(std.math.clamp(text_data.text_color[3], 0.0, 255.0)),
   );
   const vert_color = packRgba(255, 255, 255, text_alpha_u8);
   ```
4. **Shader Multiplication**: The fragment shader computes
   `outColor = texColor * inColor`, modulating opacity smoothly on GPU with
   **100% cache hits**.

______________________________________________________________________

## 4. Clay Immediate-Mode Alpha Modulation

Because Clay does not support CSS-like cascading container opacity, all child
elements must explicitly scale their color alpha:

```zig
inline fn a(color: clay.Color, progress: f32) clay.Color {
    return theme.withAlpha(color, progress);
}
```

Wrap every background, border, and text element in `a(color, progress)`. When
steady state ($progress = 1.0$), `withAlpha(c, 1.0)` is a mathematical identity,
guaranteeing 0-pixel differences on golden test screenshots.

______________________________________________________________________

## 5. Modal Dismissal Input Decoupling

*(See authoritative invariant: `04_ui_rendering_and_performance.md` §3)*

When a modal window or overlay begins its animated close sequence:

- **Do NOT block user inputs** while the fade-out is playing.
- Differentiate between "visually dissolving" and "accepting input":
  ```zig
  pub inline fn isAcceptingInput(self: *const PaletteState) bool {
      return self.mode != .inactive and !self.is_closing;
  }
  ```
- Input systems (`sysProcessInput`, `sysUpdateViewport`) must check
  `isAcceptingInput()`, allowing keyboard shortcuts and viewport interactions to
  respond immediately while the dissolve completes in the background.

______________________________________________________________________

## 6. Image Crossfade Transitions & Fast Navigation Scrubbing

*(See authoritative invariants: `04_ui_rendering_and_performance.md` §2, §3)*

### The Anti-Pattern: Proportional Retargeting for Distinct Textures

While proportional duration retargeting is ideal for scalar UI elements (e.g.
fading a single modal or button opacity from 0.4 back to 0.0), it is a
**visual anti-pattern for image crossfades**:

- In an image crossfade, Quad A is fading out while Quad B is fading in.
- If the user quickly navigates to Image C mid-flight, attempting to retarget
  either leaves a muddy 3-quad composite or causes a sudden luminance pop (e.g.
  Quad B jumping from 40% to 100% opacity).

### The Correct Pattern: Snap-and-Cut on Scrubbing or Interruption

1. **Rapid Scrubbing Bypass**: If navigation occurs within 200ms of the previous
   navigation action ($elapsed < 200\\text{ms}$), bypass the animation entirely
   and cut immediately.
2. **Interruption Snap-and-Cut**: If an animation is already in flight
   ($0.0 < p < 0.999$), immediately snap to the settled state:
   ```zig
   self.viewer.animations.setImmediate(.image_crossfade, 1.0);
   self.viewer.image_transition = .none;
   ```
3. **Outgoing Slide GPU Invariant**: Only initiate crossfade if the outgoing
   slide is resident in VRAM (`old_entry.status == .loaded_gpu`). Navigating
   away from a slide that is still decoding or failed cuts immediately.
4. **Dual-Quad Alpha & Layering Math**:
   - Outgoing Quad (`ImageTransitionPrevQuad`): Floating at $z = 0$,
     centered in viewport, opacity $A\_{\\text{prev}} = 1.0 - p^2$ (quadratic
     falloff preserves perceived luminance).
   - Incoming Quad (`ImageCanvas`): Floating at $z = 1$, centered in viewport,
     opacity $A\_{\\text{cur}} = p$.
   - When settled ($p \\ge 0.999$): Transition resets to `.none`, rendering a
     single static quad at $A = 1.0$.
5. **Mutual Exclusion**: Guard thumbnail crossfade underlays so they never
   execute while an image dissolve is active, preventing quad collisions at
   $z = 0$.

### Universal Zoom Quad Sizing & Frame-1 Aspect Invariance

- **Dual-Quad Universal Sizing**: Outgoing dissolve quads
  (`ImageTransitionPrevQuad`) must be sized from native unrotated source
  texture dimensions scaled by the outgoing slide's universal zoom factor:
  $$
  \\text{dst_w} = sw \\times Z\_{\\text{prev}}, \\quad
  \\text{dst_h} = sh \\times Z\_{\\text{prev}}
  $$
  Centering coordinates must align with viewport center plus pan offset,
  ensuring that outgoing images dissolve smoothly even if they have different
  native aspect ratios from the incoming image.
- **Immediate Navigation Base Scale Seeding**: State systems must immediately
  synchronize the new slide's `zoom_factor` to
  `ZoomFactor.init(self.getBaseScale())` on navigation, guaranteeing that the
  incoming slide's thumbnail matches its final loaded bounds from Frame 1.

______________________________________________________________________

## 7. Continuous Smooth Motion Controllers (`PanController`, `ZoomController`)

To provide 120Hz-smooth keyboard panning and zooming without discrete OS key-repeat stutter, `ViewerState` embeds allocation-free motion controllers (`src/state/types.zig`, ticked via `src/input/key_mapping.zig`):

1. **Packed Bitfields & Branchless 16-State Direction LUT**:
   - `DirectionFlags = packed struct(u4)` (`left`, `right`, `up`, `down`) indexes directly into a 16-entry compile-time unit vector lookup table (`DIRECTION_UNIT_LUT[16]`) via `@as(u4, @bitCast(self))` with $\\frac{1}{\\sqrt{2}}$ diagonal normalization and opposite-key cancellation.
   - `ZoomFlags = packed struct(u2)` (`in`, `out`) packs held zoom keys into a 2-bit bitfield (`raw()`, `fromRaw()`, `hasAny()`, `merge()`) with opposite-key cancellation when both `in` and `out` are held.
2. **Constant Glide Speed, Smooth Tap Completion & Held-Key Suppression**:
   - `PanController` (`smooth_tap_remaining: f32`, `tap_direction: DirectionFlags`, `prev_held: DirectionFlags`, `suppressed_held: DirectionFlags`) glides at `GLIDE_SPEED = 800.0` px/sec while held and guarantees at least `TAP_DISTANCE = 30.0` px of smooth travel on a brief tap.
   - `ZoomController` (`smooth_tap_remaining: f32`, `tap_direction: ZoomDirection`, `prev_held: ZoomFlags`, `suppressed_held: ZoomFlags`, `detent_pause_ms: f32`, `detent_target: ?f32`) glides at logarithmic rate `GLIDE_RATE = 1.5` ($\\text{zoom} \\times e^{\\pm 1.5 \\cdot dt}$) and completes a `TAP_STEP_RATIO = 1.25` ($\\ln(1.25) \\approx 0.2231$) step on a quick tap.
   - Both controllers provide `suppress(held)` to mask out keys held when a modal opens or a UI control is clicked until those keys are physically released.
3. **100% ($1.0\\times$) Zoom Detent Pause & Event Loop Integration**:
   - When continuous zooming crosses `detent_target` ($1.0\\times$), `ZoomController` snaps to `1.0` and sets `detent_pause_ms = 150.0` (`DETENT_PAUSE_MS`), pausing briefly at native 1:1 pixel scale before continuing if the key remains held.
   - Both controllers expose `isBusy()` (`smooth_tap_remaining > 0.001` / `0.0001` or `prev_held.hasAny()`, plus `or self.detent_pause_ms > 0.001` in `ZoomController`), which is checked in `AppState.computeFrameWaitStrategy()`.
