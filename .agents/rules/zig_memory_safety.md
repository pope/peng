# Universal Zig Memory Safety & Resource Rules

## Tagged Union Access in Release Modes

- ALWAYS use explicit `switch (union)` pattern matching when accessing payloads of tagged unions (`union(enum)`).
- DO NOT use direct property access (e.g. `entry.status.loaded_gpu.texture`) on active union payloads. In `-OReleaseFast`, safety checks are disabled, causing undefined behavior or segmentation faults if the active tag does not match.

## Per-Frame Arena Allocators

- Use a dedicated per-frame Arena allocator (`frame_arena`) for temporary string formatting and dynamic UI generation inside high-frequency render loops.
- Reclaim memory at the beginning of each frame iteration via `_ = frame_arena.reset(.retain_capacity)`.

## HashMap Key Lifecycle Cleanup

- When using `std.StringHashMap` or `std.AutoHashMapUnmanaged` with dynamically allocated keys (`allocator.dupe`), iterating over `keyIterator()` to free `key.*` MUST occur prior to calling `clearRetainingCapacity()` or `deinit()`.

## Mutex Ownership & Teardown

- Destroy `SDL_Mutex` objects in exactly one owner lifecycle method (e.g. `ViewerState.deinit()`).
- NEVER put duplicate `defer c.SDL_DestroyMutex()` calls at initialization callsites, as double-destroying a mutex causes heap corruption (`malloc_consolidate`: unaligned fastbin chunk).
