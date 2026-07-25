# Universal Zig Memory Safety & Resource Rules

## Tagged Union Access in Release Modes

- ALWAYS use explicit `switch (union)` pattern matching when accessing payloads of tagged unions (`union(enum)`).
- DO NOT use direct property access (e.g. `entry.status.loaded_gpu.texture`) on active union payloads. In `-OReleaseFast`, safety checks are disabled, causing undefined behavior or segmentation faults if the active tag does not match.

## Per-Frame Arena Allocators

- Use a dedicated per-frame Arena allocator (`frame_arena`) for temporary string formatting and dynamic UI generation inside high-frequency render loops.
- Reclaim memory at the beginning of each frame iteration via `_ = frame_arena.reset(.retain_capacity)`.

## HashMap Key Lifecycle Cleanup

- When using `std.StringHashMap` or `std.AutoHashMapUnmanaged` with dynamically allocated keys (`allocator.dupe`), iterating over `keyIterator()` to free `key.*` MUST occur prior to calling `clearRetainingCapacity()` or `deinit()`.

## Typed Worker Procedure Signatures (No `*anyopaque` Downcasting)

- Background threads spawned via `std.Thread.spawn` MUST use strongly typed function signatures (e.g. `fn(*DecodeArgs) void` or `fn(*IpcServerState) void`) rather than C-ABI wrapper functions taking `?*anyopaque`.
- Eliminate manual `@ptrCast(@alignCast(...))` downcasts across thread boundaries to guarantee compile-time type safety and eliminate pointer alignment bugs.

## Structured Error Logging Invariant

- NEVER swallow errors silently with empty `catch {}` or `else |_| {}` blocks or ignore error payloads.
- Always log errors using structured `std.log` calls (`std.log.err`, `std.log.warn`, or `std.log.debug`) with actionable error names and contextual details (e.g. `std.log.err("Operation failed: {}", .{err})`) to guarantee empirical diagnosability.
- If an operation cannot fail in practice, prefer explicit handling or assertion over empty blocks.

## Mutex Ownership & Teardown

- Clean up locks and resources in exactly one owner lifecycle method (e.g. `ViewerState.deinit()`).
