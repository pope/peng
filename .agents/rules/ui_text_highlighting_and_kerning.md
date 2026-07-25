# UI Multi-Node Text Highlighting & Kerning Rules

## Highlighting Chunk Partitioning & Whitespace Merging

- Trim leading and trailing whitespace from matched index ranges when partitioning text strings into matched/unmatched layout nodes.
- DO NOT create standalone matched text nodes for whitespace-only matches (`' '` or `'\t'`). Whitespace characters have 0 visible pixels and splitting text at space boundaries breaks font kerning across text nodes.
- Merge adjacent unmatched slices back into single continuous string slices (`last.slice.ptr[0..combined_len]`) so text layout engines (e.g. Clay UI, FreeType, SDL_ttf) render phrases as single unified strings with natural font kerning.

## GPU Text Texture Offset & Advance Alignment

- When uploading text surfaces to GPU textures, calculate the leading space advance width (`leading_space_w`) for text slices starting with whitespace.
- Set the GPU texture target width to `@max(surf_w + leading_space_w, bounding_box_w)` and offset the byte write by `leading_space_w * 4`.
- This guarantees glyph pixels align 100% pixel-perfect inside measured layout boxes without 8–16px spurious layout gaps.

## Per-Frame Arena Allocators for UI Text Chunking

- DO NOT use fixed stack buffers (`FixedBufferAllocator` with hardcoded item limits) for per-frame UI text partitioning.
- Use per-frame arena allocators (`frame_allocator`), which guarantee zero heap fragmentation, unconstrained string sizes, and zero-cost automatic frame cleanup.

## Defensive Fallbacks & Structured Warning Logging

- NEVER silently swallow unexpected bounds violations or contract mismatches with silent fallbacks.
- Whenever implementing defensive bounds checking or index fallback recovery (such as ignoring out-of-bounds match indices):
  - ALWAYS log a structured warning (`std.log.warn` or `std.log.err`) detailing the invalid index, value, string/array name, and container bounds before executing the fallback.
  - Ensures production fault tolerance while guaranteeing immediate developer diagnosability during testing.
