---
name: zig-gui-animations
description: >-
  Architectural patterns and implementation recipes for high-performance GUI animations in Zig, Clay UI, and SDL3 GPU.
  Trigger immediately for:
  - DOD Animation State: MultiArrayList SoA layout, channel slots, bitmask tracking, zero-allocation frame ticks.
  - Easing & Curves: normalized time evaluation, NaN guards, proportional retargeting/interruption duration math.
  - GPU Text Alpha Blitting: RGB-only text texture caching, vertex color alpha modulation, zero font re-rasterization.
  - Clay UI Transitions: hierarchical alpha scaling, modal dissolve animations, and input decoupling during dismissal.
  DO NOT trigger for:
  - Pure non-visual business logic, database queries, CLI arguments, or network I/O.
---

# Zig GUI & GPU Animation Architecture

This guide provides architectural patterns and procedural recipes for building zero-allocation, 120Hz-smooth GUI animation systems in Zig, integrating with Clay immediate-mode UI and SDL3 GPU hardware rendering.

______________________________________________________________________

## 1. Data-Oriented Animation Engine (DOD)

### MultiArrayList Structure-of-Arrays (SoA) Layout

Store animation parameters in contiguous parallel arrays rather than an Array of Structures (AoS). This packs simulation fields (`value`, `start_val`, `target_val`, `elapsed_ms`, `duration_ms`, `easing`) into CPU cache lines.

```zig
pub const AnimationSlot = struct {
    value: f32,
    start_val: f32,
    target_val: f32,
    elapsed_ms: f32,
    duration_ms: f32,
    easing: EasingType,
};

pub const AnimationState = struct {
    slots: std.MultiArrayList(AnimationSlot),
    active_mask: u32 = 0,
    allocator: std.mem.Allocator,
    // ...
};
```

### Key DOD Rules:

1. **Contiguous Parallel Slices**: Access columns via `self.slots.items(.value)[idx]`.
2. **Bitmask Active Tracking**: Use a single integer bitmask (`active_mask: u32`) where bit $i$ indicates whether channel $i$ is actively animating. This enables $O(1)$ zero-branch checks for event loop wakeups:
   ```zig
   pub inline fn hasActiveAnimations(self: *const AnimationState) bool {
       return self.active_mask != 0;
   }
   ```
3. **Zero Runtime Allocations**: Pre-allocate all channel slots during `init()` (`slots.ensureTotalCapacity(allocator, CHANNEL_COUNT)`). Per-frame methods (`tick`, `get`, `start`, `settle`) MUST NEVER allocate heap memory.
4. **Adaptive Event Loop Sleeping**: Integrate `hasActiveAnimations()` into `AppState.isBusy()`. When animations run, the loop ticks at 120Hz; when settled, it drops to 0% CPU blocking wait (`waitEvent`).

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

When reversing or interrupting an animation mid-flight, scale the duration by remaining progress so short travels don't feel sluggish:

```zig
const progress = animations.get(.palette_reveal);
const duration = @max(DURATION_PALETTE_CLOSE_MS * progress, 30.0);
animations.start(.palette_reveal, 0.0, duration, .ease_out_quad);
```

______________________________________________________________________

## 3. GPU Text Renderer Alpha Decoupling (Zero Cache Thrashing)

### The Anti-Pattern: Baking Alpha into Text Textures

If alpha is part of `TextCacheKey`, an animating label generates 15–20 distinct textures across a 140ms fade, exhausting VRAM and thrashing font rasterization.

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
   const text_alpha_u8 = @as(u8, @intFromFloat(std.math.clamp(text_data.text_color[3], 0.0, 255.0)));
   const vert_color = packRgba(255, 255, 255, text_alpha_u8);
   ```
4. **Shader Multiplication**: The fragment shader computes `outColor = texColor * inColor`, modulating opacity smoothly on GPU with **100% cache hits**.

______________________________________________________________________

## 4. Clay Immediate-Mode Alpha Modulation

Because Clay does not support CSS-like cascading container opacity, all child elements must explicitly scale their color alpha:

```zig
inline fn a(color: clay.Color, progress: f32) clay.Color {
    return theme.withAlpha(color, progress);
}
```

Wrap every background, border, and text element in `a(color, progress)`. When steady state ($progress = 1.0$), `withAlpha(c, 1.0)` is a mathematical identity, guaranteeing 0-pixel differences on golden test screenshots.

______________________________________________________________________

## 5. Modal Dismissal Input Decoupling

When a modal window or overlay begins its animated close sequence:

- **Do NOT block user inputs** while the fade-out is playing.
- Differentiate between "visually dissolving" and "accepting input":
  ```zig
  pub inline fn isAcceptingInput(self: *const PaletteState) bool {
      return self.mode != .inactive and !self.is_closing;
  }
  ```
- Input systems (`sysProcessInput`, `sysUpdateViewport`) must check `isAcceptingInput()`, allowing keyboard shortcuts and viewport interactions to respond immediately while the dissolve completes in the background.
