---
name: zig-gui-animations
description: >-
  Implementation recipes for Peng's zero-allocation SoA AnimationState, easing
  curves and proportional interruption scaling, UI alpha modulation, dual-quad
  image crossfade dissolves, and smooth PanController/ZoomController motion. Use
  when implementing or tuning animations, transitions, or continuous motion.
---

# Zig GUI & GPU Animation Recipes

## 1. Data-Oriented Animation Engine (`src/state/animation.zig`)

Store all channel parameters in flat parallel static arrays (`MAX_CHANNELS = 32`,
676 bytes total, zero heap allocations):

```zig
pub const AnimationState = struct {
    values: [MAX_CHANNELS]f32 = initValues(),
    start_vals: [MAX_CHANNELS]f32 = initValues(),
    target_vals: [MAX_CHANNELS]f32 = initValues(),
    elapsed_ms: [MAX_CHANNELS]f32 = @splat(0.0),
    durations_ms: [MAX_CHANNELS]f32 = @splat(0.0),
    easings: [MAX_CHANNELS]EasingType = @splat(.linear),
    active_mask: u32 = 0,
};
```

- **Bitmask Active Tracking**: `active_mask != 0` (`hasActiveAnimations()`) gives
  $O(1)$ branchless busy checks for `AppState.computeFrameWaitStrategy` alongside
  `pan_controller.isBusy()` and `zoom_controller.isBusy()`.
- **Static Descriptors**: `CHANNEL_DESCRIPTORS` maps each `AnimationChannel` to
  default open/close durations, easings, and resting values.

______________________________________________________________________

## 2. Easing Guards & Proportional Interruption

- **NaN & Clamp Guard**: Guard normalized $t = \\text{elapsed} / \\text{duration}$
  with `if (std.math.isNan(t)) return 0.0;` and `std.math.clamp(t, 0.0, 1.0)`.
- **Proportional Reversal**: When closing a scalar UI element mid-open, scale
  close duration by current progress `p` with a `30ms` floor:
  ```zig
  const progress = self.viewer.animations.get(.palette_reveal);
  const close_dur = @max(DURATION_PALETTE_CLOSE_MS * progress, 30.0);
  self.viewer.animations.start(.palette_reveal, 0.0, close_dur, .ease_out_quad);
  ```

______________________________________________________________________

## 3. UI Opacity, Glyph Modulation & Modal Dismissal

- **Immediate-Mode Alpha**: Scale colors explicitly via
  `theme.withAlpha(color, progress)` (`progress == 1.0` is an exact identity for
  golden screenshot parity).
- **Atlas & Modal References**: For per-glyph white atlas RGBA vertex modulation
  and `isAcceptingInput()` modal close decoupling, follow
  [`04_ui_rendering_and_performance.md`](../../rules/04_ui_rendering_and_performance.md)
  §1 & §3 and
  [`sdl3-gpu-rendering.md`](../zig-gui-practices/references/sdl3-gpu-rendering.md) §1.

______________________________________________________________________

## 4. Dual-Quad Image Crossfade Dissolves

Proportional retargeting is an anti-pattern for image dissolves (causing 3-quad
mud or luminance pops). Use **snap-and-cut** when `< 200ms`
(`ScrollCadence.shouldBypassCrossfade`) or interrupting an active dissolve, and
require outgoing `.loaded_gpu` residency.

- **Dual-Quad Alpha & Layering**:
  - Outgoing quad (`ImageTransitionPrevQuad` at $z = 0$):
    $A\_{\\text{prev}} = 1.0 - p^2$ (quadratic falloff preserves perceived
    luminance), sized from unrotated source dims $\\times Z\_{\\text{prev}}$
    (`dst_w = sw * prev_zoom`, `dst_h = sh * prev_zoom`) anchored at viewport
    center + `prev_pan`.
  - Incoming quad (`ImageCanvas` at $z = 1$): $A\_{\\text{cur}} = p$, seeded on
    navigation via `updateCurrentRotation()` -> `ZoomFactor.init(getBaseScale())`
    for Frame-1 aspect stability.
  - Settled ($p \\ge 0.999$): `image_transition = .none`, single quad at $A = 1.0$.
  - Never run `thumb_crossfade` while `image_transition != .none`.

______________________________________________________________________

## 5. Smooth Motion Controllers (`PanController`, `ZoomController`)

Defined in `src/state/viewport.zig` (ticked via `src/input/key_mapping.zig`) for
120Hz OS-repeat-independent keyboard motion:

- **Packed Bitfields**: `DirectionFlags = packed struct(u4)` indexes a 16-entry
  compile-time `DIRECTION_UNIT_LUT[16]` via `@backingInt` ($\\frac{1}{\\sqrt{2}}$
  diagonals + opposite-key cancellation); `ZoomFlags = packed struct(u2)` cancels
  simultaneous `in` + `out`.
- **Glide, Tap Floor & Suppression**:
  - `PanController`: `GLIDE_SPEED = 800.0` px/s held, `TAP_DISTANCE = 30.0` px
    minimum tap travel (`TAP_EPSILON_PX = 0.001`), tracked via
    `tap: PanTap` (`.idle` | `.active: ActivePanTap`).
  - `ZoomController`: `GLIDE_RATE = 1.5`
    ($\\text{zoom} \\cdot e^{\\pm 1.5 dt}$), `TAP_STEP_RATIO = 1.25`,
    `ZoomDirection = enum(u1)` (`.in`, `.out`), and `DETENT_PAUSE_MS = 150.0`
    pause on crossing $1.0\\times$, tracked via `phase: ZoomPhase`
    (`.idle` | `.tap: ActiveZoomTap` | `.detent_pause_ms`).
  - Call `suppress(held)` on modal open or UI chrome clicks until keys release.
