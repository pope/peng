# SDL3 GPU Rendering & SIMD Vector Reference

## 1. Text Advance Alignment & Whitespace Partitioning

- **GPU Text Advance Offset**:
  When calculating sub-pixel advances for text rendering, compute horizontal offsets using font metrics:
  $$\\text{advance_x} = \\text{glyph_advance} + \\text{letter_spacing}$$
- **Whitespace Merging**:
  Partition string slices by contiguous whitespace chunks before glyph measurement to minimize redundant layout calls.

______________________________________________________________________

## 2. Zero-Allocation Text Measurement (`TTF_GetStringSize` / `TTF_MeasureString`)

- **Direct Slice Pointer and Length Passing**:
  SDL3_ttf functions accept byte counts directly (`text.ptr` and `text.len`). Never allocate temporary null-terminated slices (`allocator.dupeZ`) or force text sizing signatures to accept an unneeded `allocator: std.mem.Allocator` parameter.
- **Early Return for Empty Strings**:
  Check for empty text slices (`text.len == 0`) before making C-ABI calls to avoid unnecessary FFI overhead:
  ```zig
  pub fn getStringSize(self: Font, text: []const u8) ?TextSize {
      if (text.len == 0) return TextSize{ .w = 0, .h = 0 };
      var w: c_int = 0;
      var h: c_int = 0;
      if (!c.TTF_GetStringSize(self.ptr, text.ptr, text.len, &w, &h)) {
          return null;
      }
      return TextSize{
          .w = @intCast(@max(0, w)),
          .h = @intCast(@max(0, h)),
      };
  }
  ```

______________________________________________________________________

## 3. GPU Compute RGB24/BGR24 Unpack Pipeline (`unpack_rgb.comp.glsl`)

- **Zero CPU 24-to-32-Bit Expansion in GPU Mode**:
  When `decodeWorker` decodes a 24-bit `rgb24` or `bgr24` surface while a GPU device is present (`gpu_mode`), it retains the 3-byte-per-pixel surface in RAM rather than expanding it to 4-byte RGBA32 on the CPU.
- **Staging & Compute Dispatch (`src/app/core/image.zig`, `src/ui/renderer.zig`)**:
  1. `uploadSurfaceToGpu` copies the 3-byte packed scanlines into a reusable `UploadStagingBuffer` (`AppState.upload_staging`) and uploads them to a temporary GPU storage buffer.
  2. A compute pass binds `unpack_rgb.comp.glsl` (`local_size_x = 64`), which reads 3 bytes per texel from the `uint data[]` storage buffer using bit-shift extraction, swaps R and B if `ubo.is_bgr != 0`, and writes `vec4(r, g, b, 1.0)` into the destination `rgba8` texture.
  3. After the compute pass finishes, `cmd_buf.generateMipmapsForTexture(tex)` builds the hardware trilinear mipmap pyramid on the GPU.

______________________________________________________________________

## 4. 4-Pass Dual Kawase Backdrop Blur Pipeline (`src/ui/renderer.zig`)

- **Demand-Gated Execution**:
  When `overlays.enable_blur` is enabled and `packet.blur_rects.items.len > 0` (glassmorphic floating overlays, command palette, or edit panel are visible):
  1. **Scene Offscreen Render**: The image viewport is rendered into `resources.scene_texture` (`w x h`).
  2. **2-Step Kawase Downsample (`blur_down.frag.glsl`)**: Downsamples `scene_texture` -> `blur_tex_a` (`w/2 x h/2`) -> `blur_tex_b` (`w/4 x h/4`) using 5-tap half-pixel diagonal offsets.
  3. **2-Step Kawase Upsample (`blur_up.frag.glsl`)**: Upsamples `blur_tex_b` -> `blur_tex_a` (`w/2 x h/2`) -> `blur_tex_a` composite using 8-tap tent-weighted offsets.
  4. **Scissor-Clipped Backdrop Composite**: In the swapchain render pass, each `blur_rect` samples the blurred texture behind the semi-transparent UI card before drawing UI borders and text.
- When `blur_rects` is empty or `enable_blur` is false, the offscreen scene pass and all 4 blur passes are completely skipped.

______________________________________________________________________

## 5. SIMD Vector Alignment

- **SIMD Vector Pointer Loads**:
  When loading pixel data into SIMD vectors (`@Vector(4, u8)`), verify slice alignment and bounds before executing `@ptrCast`:
  ```zig
  pub inline fn loadVector4(slice: []const u8, offset: usize) ?@Vector(4, u8) {
      if (offset + 4 > slice.len) return null;
      const ptr: *const [4]u8 = @ptrCast(&slice[offset]);
      return ptr.*;
  }
  ```
