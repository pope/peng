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
- **Compiler Optimization Flags**:
  Compile shaders in `build.zig` with `glslangValidator -V -Os` to enable SPIR-V size, dead-code elimination, and instruction folding passes:
  ```zig
  const vert_cmd = b.addSystemCommand(&.{ "glslangValidator", "-V", "-Os", "-S", "vert", "src/shaders/vert.glsl", "-o", "src/shaders/vert.spv" });
  const frag_cmd = b.addSystemCommand(&.{ "glslangValidator", "-V", "-Os", "-S", "frag", "src/shaders/frag.glsl", "-o", "src/shaders/frag.spv" });
  ```

______________________________________________________________________

## 4. Negative-Lobe Resampling Invariants

- **4-Tap Bilinear Hardware Reduction Limitations**:
  Hardware bilinear tap reduction (Sigg & Hadwiger 4-tap technique) works **ONLY** for positive-weight filters (B-Splines, Gaussian).
- **Negative Lobes & Division Safety**:
  For filters with negative lobes (Mitchell-Netravali $B=1/3, C=1/3$ and Lanczos3), weight sums cross zero ($w_0 + w_1 = 0$), producing `NaN` division artifacts if forced into 4-tap bilinear reduction. Keep full 16-tap ($4 \\times 4$) and 36-tap ($6 \\times 6$) unrolled Horner sampling and use division-safe normalization:
  ```glsl
  return sum / mix(1.0, total_w, step(0.00001, total_w));
  ```
