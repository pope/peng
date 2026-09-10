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

## 2. Branchless Shader Math (`step` & `mix`)

- **Eliminating GPU SIMD Warp Divergence**:
  Replace dynamic conditional branches (`if/else`) with branchless `step()` and `mix()` operations to ensure all execution lanes in a warp/wavefront execute identical instruction paths:
  ```glsl
  // Image vs UI adjustment branchless blend
  vec3 adjColor = (color.rgb - 0.5) * ubo.contrast + 0.5 + ubo.brightness;
  float isImg = step(float(ubo.is_text_or_color), 0.5);
  color.rgb = mix(color.rgb, adjColor, isImg);

  // Branchless safe sinc function
  float ax = abs(x);
  float is_zero = step(ax, 0.0001);
  float pi_x = 3.141592653589793 * ax;
  float safe_pi_x = mix(pi_x, 1.0, is_zero);
  float s = sin(safe_pi_x) / safe_pi_x;
  return mix(s, 1.0, is_zero);
  ```

______________________________________________________________________

## 3. Loop Unrolling & SPIR-V Compilation

- **`#pragma unroll` Directives**:
  Annotate GLSL spatial loops with `#pragma unroll` to instruct `glslangValidator` to inline loop iterations into SPIR-V bytecodes, keeping filter weights in GPU scalar registers without stack memory spilling.
- **Compiler Optimization Flags & Cross-Compilation**:
  Compile shaders in `build.zig` using `glslangValidator -V -Os` for SPIR-V optimization, followed by `spirv-cross --msl` to generate Metal Shading Language (`.msl`) bytecode for Apple Silicon/macOS targets. Shaders reside under `src/ui/shaders/`:
  ```zig
  const spv_cmd = b.addSystemCommand(&.{ "glslangValidator", "-V", "-Os", "-S", def.stage });
  spv_cmd.addFileArg(b.path(b.fmt("src/ui/shaders/{s}", .{def.src_name})));
  spv_cmd.addArg("-o");
  const spv_out = spv_cmd.addOutputFileArg(b.fmt("{s}.spv", .{def.out_name}));

  const msl_cmd = b.addSystemCommand(&.{ "spirv-cross" });
  msl_cmd.addFileArg(spv_out);
  msl_cmd.addArgs(&.{ "--msl", "--output" });
  const msl_out = msl_cmd.addOutputFileArg(b.fmt("{s}.msl", .{def.out_name}));
  ```

______________________________________________________________________

## 4. Negative-Lobe Resampling Invariants

- **4-Tap Bilinear Hardware Reduction Limitations**:
  Hardware bilinear tap reduction (Sigg & Hadwiger 4-tap technique) works **ONLY** for positive-weight filters (B-Splines, Gaussian).
- **Negative Lobes & Division Safety**:
  For filters with negative lobes (Mitchell-Netravali $B=1/3, C=1/3$ and Lanczos3), weight sums cross zero ($w_0 + w_1 = 0$), producing `NaN` division artifacts if forced into 4-tap bilinear reduction. Keep full 16-tap ($4 \\times 4$) and 36-tap ($6 \\times 6$) unrolled sampling and use division-safe normalization:
  ```glsl
  return sum / mix(1.0, total_w, step(0.00001, total_w));
  ```

______________________________________________________________________

## 5. Modern 7-Filter Resampling Suite (`image.frag.glsl`)

Peng implements 7 GPU-accelerated texture reconstruction and upscaling shaders:

| Mode  | Filter Name                | Mathematical Architecture                                            | Zoom Behavior                        |
| :---: | :------------------------- | :------------------------------------------------------------------- | :----------------------------------- |
| **0** | **Nearest Neighbor**       | Snapped texel center sampling `(floor(uv * N) + 0.5) / N`            | All zoom levels                      |
| **1** | **Bilinear (Default)**     | Native GPU hardware linear sampling with trilinear mipmaps           | All zoom levels                      |
| **2** | **Pixel Art (AA-Nearest)** | Inigo Quilez box filter with $-0.5$ texel centering                  | All zoom levels                      |
| **3** | **Mitchell-Netravali**     | 16-tap bicubic ($B=1/3, C=1/3$) via Horner's polynomial form         | All zoom levels (text/manga clarity) |
| **4** | **Lanczos3 (Analytical)**  | 36-tap single-sine trigonometric reduction with anti-ringing bounds  | All zoom levels (text/manga clarity) |
| **5** | **AMD FSR 1.0**            | 12-tap EASU edge-adaptive rotation + single-pass integrated RCAS     | Magnification only (> 100%)          |
| **6** | **Tiny CNN (ESPCN)**       | 2nd-order curvature synthesis, odd-symmetric soft-knee, 18% headroom | Magnification only (> 100%)          |

### Analytical Lanczos3 Reduction (Mode 4)

- Uses trigonometric addition and triple-angle identities to compute all 36 tap weights with only 2 `sin()` evaluations per fragment (1 per axis), achieving a 12x reduction in transcendental ALU calls.
- Numerators are normalized and clamped against the core $2 \\times 2$ bounding envelope $[min4, max4]$ to eliminate ringing artifacts.

### Single-Pass AMD FSR 1.0 (Mode 5)

- Integrates Robust Contrast-Adaptive Sharpening (RCAS) directly within the register context of Edge-Adaptive Spatial Upsampling (EASU).
- Eliminates the need for a secondary framebuffer ping-pong pass or intermediate texture allocation.

### Zero-Drift Neural Super-Resolution (Mode 6)

- **Even-Symmetric Curvature**: Uses 2nd-order spatial curvature ($f_0$ horizontal, $f_1$ vertical, $f_2$ diagonal, $f_3$ isotropic Laplacian).
- **Taylor Translation Prevention**: Odd-symmetric first derivatives ($top - bottom$, $left - right$) must never be added to center luminance with fixed positive weights; doing so creates an edge spatial translation operator $I(x) + \\Delta \\nabla I$. Even-symmetric 2nd derivatives ensure zero spatial displacement.
- **Dynamic Headroom Clamping**: Enforces an 18% aesthetic margin over the local neighborhood min/max to provide high-contrast punch while strictly clamping overshoots.
- **Chroma Preservation**: Scales RGB channels by $(luma_target / l\_{11})$ to prevent white-halo desaturation.

### Inigo Quilez AA-Nearest Centering Invariant (Mode 2)

- Continuous coordinates MUST be shifted by $-0.5$ ($p = uv \\cdot \\text{size} - 0.5$) and sampled at $(i + f + 0.5) / \\text{size}$.
- Ensures texel interiors evaluate to exact center points (100% solid color), with smooth 1-pixel linear anti-aliasing transitions strictly at boundaries.
