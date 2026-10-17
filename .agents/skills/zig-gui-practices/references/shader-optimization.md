# GPU Shader Optimization & GLSL Best Practices

## 1. Horner's Method for Polynomial Splines

- **Fused Multiply-Add (FMA) Execution**:
  Express cubic polynomials $a x^3 + b x^2 + c x + d$ in Horner's form ($((a \\cdot x + b) \\cdot x + c) \\cdot x + d$) to enable hardware FMA execution in GPU shader ALUs:
  ```glsl
  float mitchell_p1(float x) {
      return ((7.0 / 6.0 * x - 2.0) * x) * x + (8.0 / 9.0);
  }

  float mitchell_p2(float x) {
      return (((-7.0 / 18.0 * x + 2.0) * x - 10.0 / 3.0) * x) + (16.0 / 9.0);
  }
  ```

______________________________________________________________________

## 2. Branchless Shader Math vs. Dynamically Uniform Branching

- **Eliminating Per-Pixel Warp Divergence (`step` & `mix`)**:
  For per-pixel divergent conditions, replace dynamic conditional branches (`if/else`) with branchless vector operations so all lanes in a GPU warp/wavefront execute identical instructions:
  ```glsl
  float ax = abs(x);
  float is_zero = step(ax, 0.0001);
  float pi_x = 3.141592653589793 * ax;
  float safe_pi_x = mix(pi_x, 1.0, is_zero);
  float s = sin(safe_pi_x) / safe_pi_x;
  return mix(s, 1.0, is_zero);
  ```
- **Dynamically Uniform Branching (`ubo.has_adjustments`)**:
  Do NOT replace branches with `step()` / `mix()` when the condition depends strictly on uniform variables (`if (ubo.has_adjustments != 0)`, `if (ubo.clarity != 0.0 || ubo.texture_adj != 0.0)`, `if (overshoot > 0.0)`). Uniform branches evaluate identically across all lanes in the quad with **0% warp divergence**, allowing the GPU to completely skip expensive transcendental blocks and preserve bit-exact sRGB identity when edits are neutral.

______________________________________________________________________

## 3. Loop Unrolling & SPIR-V / MSL Compilation

- **`#pragma unroll` Directives**:
  Annotate GLSL spatial filter loops with `#pragma unroll` so `glslangValidator` inlines tap iterations into scalar registers without stack spilling.
- **Shader Build Pipeline (`zig build shaders`)**:
  Shaders in `src/ui/shaders/` (`vert.glsl`, `ui.frag.glsl`, `image.frag.glsl`, `blur_down.frag.glsl`, `blur_up.frag.glsl`, `unpack_rgb.comp.glsl`) are compiled via `glslangValidator -V -Os` to SPIR-V (`.spv`) and cross-compiled via `spirv-cross --msl` to Metal (`.msl`).

______________________________________________________________________

## 4. Negative-Lobe Resampling Invariants

- **4-Tap Bilinear Hardware Reduction Limitations**:
  Hardware bilinear tap reduction (Sigg & Hadwiger 4-tap technique) works **ONLY** for positive-weight filters (B-Splines, Gaussian).
- **Negative Lobes & Division Safety**:
  For filters with negative lobes (Mitchell-Netravali $B=1/3, C=1/3$ and Lanczos3), weight sums can cross zero ($w_0 + w_1 = 0$), producing `NaN` division artifacts if forced into 4-tap bilinear reduction. Keep full 16-tap ($4 \\times 4$) and 36-tap ($6 \\times 6$) unrolled sampling with division-safe normalization:
  ```glsl
  return sum / mix(1.0, total_w, step(0.00001, total_w));
  ```

______________________________________________________________________

## 5. Modern 7-Filter Resampling Suite (`image.frag.glsl`)

| Mode  | Filter Name                | Mathematical Architecture                                            | Zoom Behavior                        |
| :---: | :------------------------- | :------------------------------------------------------------------- | :----------------------------------- |
| **0** | **Nearest Neighbor**       | Snapped texel center sampling `(floor(uv * N) + 0.5) / N`            | All zoom levels                      |
| **1** | **Bilinear (Default)**     | Native GPU hardware linear sampling with trilinear mipmaps           | All zoom levels                      |
| **2** | **Pixel Art (AA-Nearest)** | Inigo Quilez box filter with $-0.5$ texel centering                  | All zoom levels                      |
| **3** | **Mitchell-Netravali**     | 16-tap bicubic ($B=1/3, C=1/3$) via Horner's polynomial form         | All zoom levels (text/manga clarity) |
| **4** | **Lanczos3 (Analytical)**  | 36-tap single-sine trigonometric reduction with anti-ringing bounds  | All zoom levels (text/manga clarity) |
| **5** | **AMD FSR 1.0**            | 12-tap EASU edge-adaptive rotation + single-pass integrated RCAS     | Magnification only (> 100%)          |
| **6** | **Tiny CNN (ESPCN)**       | 2nd-order curvature synthesis, odd-symmetric soft-knee, 18% headroom | Magnification only (> 100%)          |

- **Analytical Lanczos3 (Mode 4)**: Uses trigonometric addition and triple-angle identities to compute all 36 tap weights with only 2 `sin()` calls per fragment, clamping output to the core $2 \\times 2$ neighborhood `[min4, max4]` to eliminate ringing.
- **Single-Pass AMD FSR 1.0 (Mode 5)**: Integrates RCAS sharpening directly in registers after 12-tap EASU without a secondary ping-pong pass.
- **Zero-Drift Tiny CNN (Mode 6)**: Uses even-symmetric 2nd-order curvature ($2c - l - r$, never odd-symmetric 1st derivatives that shift edges by Taylor expansion $I(x) + \\Delta \\nabla I$), an 18% local neighborhood headroom clamp, and luminance ratio scaling (`luma_target / l11`) to preserve chroma.
- **Inigo Quilez AA-Nearest Centering (Mode 2)**: Shifts continuous texel coordinates by $-0.5$ (`p = uv * tex_size - 0.5`) and samples at `(i + f + 0.5) / tex_size` so pixel interiors remain 100% solid with 1-pixel boundary anti-aliasing.

______________________________________________________________________

## 6. 13-Parameter Photographic Color & Presence Pipeline (`image.frag.glsl`)

When `ubo.has_adjustments != 0` in `main()`, `image.frag.glsl` converts the sampled color to scene-referred linear space (`srgb_to_linear` using reciprocal FMAs `* (1.0 / 12.92)` and `* (1.0 / 1.055)`, `max(..., 0.0)` pre-`pow` ringing guard, and hardware `greaterThan` select):

### Step 1: Opponent White Balance (`temperature`, `tint`)

- Applies opponent chromatic adaptation in linear space while normalizing against Rec.709 perceived luminance (`REC709_LUMA = vec3(0.212639, 0.715169, 0.072192)`):
  ```glsl
  vec3 wb_gains = vec3(
      1.0 + ubo.temperature * 0.4 + ubo.tint * 0.2,
      1.0 - ubo.tint * 0.4,
      1.0 - ubo.temperature * 0.4 + ubo.tint * 0.2
  );
  vec3 wb_linear = linear * max(wb_gains, vec3(0.05));
  float Y_wb = dot(wb_linear, REC709_LUMA);
  wb_linear *= (Y_in / max(Y_wb, 1e-5));
  float wb_env = smoothstep(0.0, 0.04, Y_in) *
                 (1.0 - smoothstep(0.92, 1.0, Y_in));
  linear = mix(linear, wb_linear, wb_env);
  ```

### Step 2: Dual-Path Contrast Around 18% Middle Gray (`contrast`, `contrast_blend`)

- Pivots power-law contrast (`safe_contrast = clamp(ubo.contrast, 0.0, 5.0)`) around physical 18% linear reflectance (`0.18`), blending between pure luminance contrast (`0.0`) and classic filmic per-channel RGB contrast (`1.0`, default):
  ```glsl
  float Y_contrast = 0.18 * pow(Y_safe * (1.0 / 0.18), safe_contrast);
  vec3 linear_luma = linear * (Y_contrast / Y_safe);
  vec3 linear_rgb = 0.18 * pow(max(linear, vec3(1e-5)) * (1.0 / 0.18), vec3(safe_contrast));
  linear = mix(linear_luma, linear_rgb, clamp(ubo.contrast_blend, 0.0, 1.0));
  ```

### Step 3: Monotonic Root-Space Tonal Quad (`highlights`, `shadows`, `whites`, `blacks`)

- Evaluates smooth polynomial basis weights in perceptual root-space $u = \\sqrt{\\text{clamp}(Y_c, 0.0, 1.0)}$ with bounded EV coefficients ($0.5B + 1.0S + 1.0H + 0.5W$) satisfying $\\frac{d(\\Delta\\text{EV})}{d(\\log_2 Y)} \\ge -1.0$ (with highlight taper to 0 at $u = 0.98$), and scales `linear *= exp2(delta_ev)`.

### Step 4: Post-Contrast Photometric Exposure (`brightness`)

- Multiplied *after* contrast and tonal curves so contrast adjustments never rescale optical stop gains:
  ```glsl
  linear *= exp2(ubo.brightness * 2.0);
  ```

### Step 5: Perceptual Saturation & Skin-Protected Vibrance (`saturation`, `vibrance`)

- Evaluates chroma in linear space (`c_safe = max(linear, vec3(0.0))`) and isolates the human skin locus branchlessly via the opponent chromatic ratio (`skin_ratio = d_rg / max(d_rg + d_gb, 1e-5)` centered at `0.55` via `1.0 - smoothstep(0.15, 0.35, abs(skin_ratio - 0.55))`), damping vibrance on skin tones by `1.0 - 0.75 * skin_factor`.

### Step 5.5: Presence & Detail — Bilateral Texture & Mipmap Clarity (`ubo.texture_adj`, `ubo.clarity`)

*(Note: Because `texture` is a reserved GLSL keyword, the uniform is named `ubo.texture_adj` in GLSL and `texture: f32` in Zig's `ImageUniforms`.)*

1. **Texture (`ubo.texture_adj` — 8-Tap $R = 2.0\\text{px}$ Bilateral Micro-Contrast)**:
   - Samples 8 equidistant offsets on a $R = 2.0\\text{px}$ ring (`(±2, 0)`, `(0, ±2)`, `(±1.414214, ±1.414214)`).
   - Applies Gaussian bilateral range weights `exp(-(diff * diff) * 138.889)` ($\\sigma_r = 0.06$), halo suppression `1.0 - smoothstep(0.04, 0.12, abs(detail_tex))`, noise coring `smoothstep(0.002, 0.010, abs(detail_tex))`, and Weber-Rose shadow adaptation `(Y_in + 0.04)`.
2. **Clarity (`ubo.clarity` — 8-Tap $R = 12\\text{px}$ Bilateral Midtone Structure)**:
   - Samples 8 wide offsets (`clar_offsets[i] * 8.0`, effective radius $12\\text{px}$) with bilateral range weights `exp(-(diff_c * diff_c) * 25.0)` ($\\sigma_r = 0.20$).
   - Applies rational soft-clamping `s_c * (a_c * 0.15) / (a_c + 0.15)`, midtone envelope `smoothstep(0.04, 0.20, Y_curr) * (1.0 - smoothstep(0.70, 0.95, Y_curr))`, and Weber-Rose adaptation `(Y_in + 0.05)`.

### Steps 6 & 7: Display Encoding & Continuous Rational Highlight Soft-Knee

- Converts back to display sRGB (`linear_to_srgb`) and computes scalar peak ceiling via `linear_to_srgb_scalar(peak_linear)`. When `overshoot > 0.0`, computes `knee = mix(1.0, 0.75, min(overshoot * 0.75, 1.0))` and rolls off highlights above `knee` using $C^1$-continuous rational compression `srgb - excess^2 / (excess + w)`.
