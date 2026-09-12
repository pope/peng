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

______________________________________________________________________

## Zero-Allocation Text Measurement (`TTF_GetStringSize` / `TTF_MeasureString`)

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
