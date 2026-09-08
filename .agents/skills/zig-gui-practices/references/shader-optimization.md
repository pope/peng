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

## 5. Dual Lanczos3 Filter Formulations: Exact Trig vs. Horner Spline

To balance absolute mathematical precision and maximum GPU ALU throughput, `src/ui/shaders/image.frag.glsl` provides two 36-tap ($6 \\times 6$) Lanczos3 implementations:

### 1. Analytical Single-Sine Reduction (`lanczos3`, scale mode 4)

- **Problem**: Naive `sinc(x) * sinc(x/3)` computes 24 `sin()` calls, 24 divisions, and 48 `mix`/`step` safety evaluations per fragment.
- **Trigonometric Identities**:
  - Periodicity: $\\sin(\\pi(x \\pm k)) = (-1)^k \\sin(\\pi f)$.
  - Angle addition: $\\sin(\\frac{\\pi k}{3} \\pm \\theta)$ where $\\theta = \\frac{\\pi f}{3}$.
  - Triple-angle: $\\sin(\\pi f) = \\sin(3\\theta) = \\sin\\theta (3 - 4\\sin^2\\theta)$.
  - Pythagorean: $\\cos\\theta = \\sqrt{\\max(0, 1 - \\sin^2\\theta)}$.
- **Execution**: Computes a single `sin(theta)` per dimension (2 `sin()` calls total per fragment, a **12x transcendental reduction**). Numerators are computed via 1-cycle FMAs and divided by squared distances with branchless division-by-zero guards (`f -> 0` and `f -> 1`).
- **Precision**: 100% mathematically exact to reference Lanczos3 ($< 10^{-5}$ float error).

### 2. Horner's Form Polynomial Spline (`lanczos3_spline`, scale mode 5)

- **Zero-Transcendental Architecture**: Eliminates all trigonometric calls (`sin`, `cos`, `sqrt`) in favor of pure hardware FMA polynomial evaluation.
- **Interval Normalization on $[0, 1]$**:
  All 6 tap weights map directly to 3 functions on $t \\in [0, 1]$:
  $$w_0 = P_2(f), \\quad w_1 = P_1(f), \\quad w_2 = P_0(f)$$
  $$w_3 = P_0(1 - f), \\quad w_4 = P_1(1 - f), \\quad w_5 = P_2(1 - f)$$
- **Degree-5 Horner Form**:
  $$P_0(t) = ((((-0.5863178 t + 1.5360549) t - 0.1446258) t - 1.8036159) t - 0.0015766) t + 1.0000228$$
  $$P_1(t) = ((((0.4109854 t - 1.1136012) t + 0.3772881) t + 1.1529428) t - 0.8275555) t + 0.0000243$$
  $$P_2(t) = ((((-0.1947629 t + 0.4508454) t - 0.1122383) t - 0.3531353) t + 0.2092624) t - 0.0000649$$
- **Precision**: Max error across the entire $[0, 1]$ range is $< 9.4 \\times 10^{-5}$ (visually indistinguishable from reference).
