# SDL3 GPU Rendering & SIMD Vector Reference

## Text Advance Alignment & Whitespace Partitioning

- **GPU Text Advance Offset**:
  When calculating sub-pixel advances for text rendering, compute horizontal offsets using font metrics:
  $$\\text{advance_x} = \\text{glyph_advance} + \\text{letter_spacing}$$

- **Whitespace Merging**:
  Partition string slices by contiguous whitespace chunks before glyph measurement to minimize redundant layout calls.

______________________________________________________________________

## SIMD Vector Alignment & Swizzle Snippets

- **SIMD Vector Pointer Loads**:
  When loading pixel data into SIMD vectors (`@Vector(4, u8)`), verify slice alignment and bounds before executing `@ptrCast`:

```zig
pub inline fn loadVector4(slice: []const u8, offset: usize) ?@Vector(4, u8) {
    if (offset + 4 > slice.len) return null;
    const ptr: *const [4]u8 = @ptrCast(&slice[offset]);
    return ptr.*;
}
```

- **NixOS SDL3 Image Configuration**:
  On NixOS environments, dynamic codec loading requires explicitly enabling `libavif`, `libpng`, `libwebp`, and `libjpeg` flags in `build.zig`.
