# UI Text Formatting, SIMD & Codec Performance Invariants

## Highlighting Chunk Partitioning & Whitespace Merging

- Trim leading and trailing whitespace from matched index ranges when partitioning text strings into matched/unmatched layout nodes.
- DO NOT create standalone matched text nodes for whitespace-only matches (`' '` or `'\t'`). Whitespace characters have 0 visible pixels and splitting text at space boundaries breaks font kerning across text nodes.
- Merge adjacent unmatched slices back into single continuous string slices (`last.slice.ptr[0..combined_len]`) so text layout engines (e.g. Clay UI, FreeType, SDL_ttf) render phrases as single unified strings with natural font kerning.

## GPU Text Texture Offset & Advance Alignment

- When uploading text surfaces to GPU textures, calculate the leading space advance width (`leading_space_w`) for text slices starting with whitespace.
- Set the GPU texture target width to `@max(surf_w + leading_space_w, bounding_box_w)` and offset the byte write by `leading_space_w * 4`.
- This guarantees glyph pixels align 100% pixel-perfect inside measured layout boxes without 8–16px spurious layout gaps.

## Zero-Copy Vector Memory Loads in `@Vector` Loops

- Avoid copying payload bytes into temporary stack arrays (e.g. `var buf: [16]u8 = undefined; @memcpy(...)`) prior to vector casting when processing memory slices with Zig SIMD vectors (`@Vector(N, T)`).
- Perform direct, unaligned vector reads using pointer casting:
  ```zig
  const chunk = @as(*align(1) const Vec16, @ptrCast(&slice[offset])).* ;
  ```
- Pair unaligned reads with safe loop bounds (`offset + 16 <= slice.len`) so reading 16 bytes is guaranteed to remain strictly inside slice bounds. Any trailing elements must be cleanly handled by a scalar tail loop.

## Bitwise SIMD Fast-Paths & Reduction Masks

- When using vector reduction masks (`@reduce(.Or, mask)`), avoid falling back to scalar loops for identical or matching data blocks.
- Vectorize identical-element processing using bitwise SIMD operations (e.g. `(v_base >> 2) & 0x003F3F3F`) to keep execution entirely within vector registers without scalar unrolling.

## Endian-Aware SDL3 Pixel Format Conversions

- Always verify memory byte ordering for `SDL_PixelFormat` targets on little-endian hardware (e.g. `SDL_PIXELFORMAT_RGBA32` is stored in memory as bytes `[R, G, B, A]`).
- Ensure format swizzling (e.g. `BGR24` $\\rightarrow$ `RGBA32` or `BGRA32` $\\rightarrow$ `RGBA32`) is executed in a single SIMD vector pass (`convertBgr24ToRgba32Simd`) rather than chaining multiple conversion steps.

## NixOS `sdl3-image` JPEG Codec Backend Configuration

- In NixOS `nixpkgs`, `sdl3-image` defaults to using `stb_image` (`SDLIMAGE_BACKEND_STB=ON`) as its JPEG decoder backend.
- For maximum CPU JPEG decoding throughput, ensure `sdl3-image` is configured without `stb_image` so it delegates to SIMD-accelerated `libjpeg-turbo`.
