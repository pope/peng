# Universal Zig Memory Safety & Resource Rules

## Tagged Union Access in Release Modes

- ALWAYS use explicit `switch (union)` pattern matching when accessing payloads of tagged unions (`union(enum)`).
- DO NOT use direct property access (e.g. `entry.status.loaded_gpu.texture`) on active union payloads. In `-OReleaseFast`, safety checks are disabled, causing undefined behavior or segmentation faults if the active tag does not match.

## Per-Frame Arena Allocators

- Use a dedicated per-frame Arena allocator (`frame_arena`) for temporary string formatting and dynamic UI generation inside high-frequency render loops.
- Reclaim memory at the beginning of each frame iteration via `_ = frame_arena.reset(.retain_capacity)`.
- DO NOT use fixed stack buffers (`FixedBufferAllocator` with hardcoded item limits) for per-frame UI text partitioning or string operations.

## HashMap Key Lifecycle Cleanup

- When using `std.StringHashMap` or `std.AutoHashMapUnmanaged` with dynamically allocated keys (`allocator.dupe`), iterating over `keyIterator()` to free `key.*` MUST occur prior to calling `clearRetainingCapacity()` or `deinit()`.

## Typed Worker Procedure Signatures (No `*anyopaque` Downcasting)

- Background threads spawned via `std.Thread.spawn` MUST use strongly typed function signatures (e.g. `fn(*DecodeArgs) void` or `fn(*IpcServerState) void`) rather than C-ABI wrapper functions taking `?*anyopaque`.
- Eliminate manual `@ptrCast(@alignCast(...))` downcasts across thread boundaries to guarantee compile-time type safety and eliminate pointer alignment bugs.

## Structured Error Logging Invariant

- NEVER swallow errors silently with empty `catch {}` or `else |_| {}` blocks, or ignore error payloads.
- Always log errors using structured `std.log` calls (`std.log.err`, `std.log.warn`, or `std.log.debug`) with actionable error names and contextual details (e.g. `std.log.err("Operation failed: {}", .{err})`) to guarantee empirical diagnosability.
- Whenever implementing defensive bounds checking or index fallback recovery (such as ignoring out-of-bounds match indices), ALWAYS log a structured warning before executing the fallback.

## Mutex Ownership & Teardown

- Clean up locks and resources in exactly one owner lifecycle method (e.g. `ViewerState.deinit()`).

## Slice Aliasing Protection (`@memcpy` Aliasing)

- Passing a slice of a struct field (e.g. `self.current_nav_dir.items`) into a method that mutates/clears `self.current_nav_dir` causes `@memcpy` parameter aliasing panics in Zig.
- ALWAYS duplicate input path slices (`const copy = try allocator.dupe(u8, input_slice); defer allocator.free(copy);`) at the start of container methods before clearing destination lists.

## Arena Allocator Reset Synchronization

- Clearing an `ArrayList` of strings allocated via an `ArenaAllocator` (`list.clearRetainingCapacity()`) empties the list structure but leaves allocated strings in memory.
- ALWAYS invoke `_ = arena.reset(.retain_capacity)` prior to `list.clearRetainingCapacity()` when replacing collections of arena-allocated objects.

## Single-Pass Filesystem Traversal

- Combine file and subfolder counting into a single directory traversal (`countFolderContents`) returning a composite struct (`FolderCounts`) to cut filesystem disk I/O operations in half.

## Consistent Return Memory Ownership

- Functions accepting an `allocator` MUST maintain uniform memory ownership across all return branches. NEVER return a dynamically allocated slice in one control path while returning borrowed parameters or static literals in others.
- PREFER non-allocating, buffer-based function signatures (`fn foo(dir: []const u8, buf: []u8) ?[]const u8`) using caller-provided stack buffers over mixed heap/borrowed return slices.

## Leak Detection in Unit Tests

- DO NOT wrap `std.testing.allocator` inside an `ArenaAllocator` when testing non-arena code. Arena bulk-deallocation masks memory leaks and prevents Zig's test runner leak detector from catching un-freed allocations.

## No Silent Error Swallowing on Fallbacks

- NEVER use silent error suppression (e.g. `catch null`, `catch {}`, or `else |_| {}`) when catching formatting or filesystem errors.
- ALWAYS log a diagnostic warning (`std.log.warn` or `std.log.err`) with contextual parameters before returning fallback or `null` values.
