# Memory & Resource Safety Rules

## 1. Tagged Union Access (`switch (union)`)

- Always access tagged union payloads using explicit pattern matching via `switch (union)`.
- **Safety Invariant**: Do NOT use direct field access (`union.variant`) on tagged unions unless payload existence is guaranteed by an enclosing `switch`. Direct access bypasses safety checks in ReleaseFast/ReleaseSmall modes.

## 2. Per-Frame Arenas & Allocator Lifecycle

- Reset per-frame arena allocators at frame boundaries via `arena.reset(.retain_capacity)`.
- Never store references or pointers to arena-allocated data inside persistent state structs across frame boundaries.

## 3. HashMap Key Lifecycle Cleanup

- When managing `std.StringHashMap` or custom key-value maps, ensure key memory owned by the map is freed (or arena-managed) prior to calling `map.clearRetainingCapacity()` or `map.deinit()`.

## 4. Strongly-Typed Worker Procedures

- Background thread functions must accept strongly-typed struct parameter pointers. Avoid using raw `?*anyopaque` handles or untyped pointer downcasting.

## 5. Non-Negotiable Structured Error Logging

- Never swallow errors silently with empty `catch {}` or `else |_| {}` blocks.
- Always log caught errors via `std.log.err` or `std.log.warn` with contextual details before returning fallbacks or `null`.

```zig
// BAD: Silent error swallowing
const data = readBuffer() catch return null;

// GOOD: Contextual structured logging
const data = readBuffer() catch |err| {
    std.log.err("Failed to read buffer for path '{s}': {any}", .{ path, err });
    return null;
};
```

## 6. Buffer Aliasing & Slice Copying

- When modifying shared byte buffers, copy input slices via `@memcpy` into target allocations before mutation to prevent buffer aliasing bugs across concurrent reader threads.

## 7. Caller-Provided Output Buffers

- Functions generating variable-length data should accept caller-provided output buffers or explicit allocators rather than returning unowned heap memory.

## 8. Surface Pixel Format Bounds & Conversion Safety

- When processing raw pixel buffers or `sdl.Surface` memory, NEVER assume non-32bit formats are fixed 3-byte RGB24.
- Indexed 8-bit (`index8`), grayscale (`L8`), or 16-bit surfaces have different bytes-per-pixel strides. Naive index calculation (`sp = col * 3`) causes `SIGSEGV` buffer overruns on 1-byte indexed buffers.
- Always use explicit pixel format matching (`switch (cur_fmt)`):
  - Direct `@memcpy` for RGBA32 / BGRA32 / XRGB8888.
  - High-performance SIMD converters for RGB24 / BGR24.
  - Safe fallback surface conversion (`current_surf.convert(PixelFormat.rgba32)`) for indexed 8-bit, grayscale, and arbitrary formats before GPU buffer upload.

## 9. `std.Io.net.Stream` Socket Teardown Invariants

- Always invoke `stream.close(io)` on `std.Io.net.Stream` socket handles during queue item teardown (`deinitQueueItem`) and state deallocation (`AppState.deinit`).
- Dropping or freeing structs containing socket streams without calling `.close(io)` leaks OS file and socket descriptors on application shutdown or event cancellation.

## 10. Worker Task Early-Exit & Fail-Fast Error Invariants

When a worker task encounters a file I/O failure (`statFile`, `openFile`, initial `readPositional`) or decoder failure (e.g., `sdl.Surface.loadFilePtr` returning null):

1. **Never swallow errors** with `catch null`, `catch 0`, or logging without state notification.
2. **Always notify state**: Push a corresponding failure event (e.g., `.decode_failed`) to `context.workers.event_queue` and wake up the main thread (`context.wakeUpMainThread()`).
3. **Exit early immediately**: Execute `return` right after logging and event dispatch.
4. **Avoid redundant checks**: Once an early exit check handles `n == 0` or error cases, do not wrap subsequent code in redundant `if (n > 0)` checks.

## 11. Lifecycle Teardown & Deinitialization Invariants

Every struct owning heap memory, GPU handles, socket connections, or child sub-states MUST provide an explicit `deinit` method accepting appropriate allocator/context parameters:

- **`RenderResources.deinit(allocator)`**: Must be invoked on main thread shutdown to release font text cache (`text_cache.deinit(allocator, device)`), font handles (`font.close()`), double-buffered vertex and transfer staging buffers (`releaseBuffer`, `releaseTransferBuffer`), graphics pipelines (`releasePipeline`), compute pipelines (`releaseComputePipeline`), samplers, and fallback textures.
- **`DisplayState.deinit(allocator)`**: Must be invoked during `ViewerState.deinit` to clean up windowed mode heap allocations (`allocator.free(cached_title)`).
- **`ParsedArgs.deinit(gpa)`**: Must be invoked during CLI configuration teardown to free heap-allocated argument path slices (`arg_path`).
- **Canonical Top-Level Teardown Order (`AppGraphicsAndState.deinit`)**:
  1. `parsed.deinit(gpa)` (CLI allocations)
  2. `ipc_server.deinit(io)` (Socket handles & threads)
  3. `gpa.free(clay_memory)` (UI layout buffer)
  4. `state.deinit()` (Workers, cache, intents, and `viewer.deinit(gpa, io)`)
  5. `resources.deinit(gpa)` (GPU staging buffers, fonts, pipelines)
  6. `gpu_device.destroy()` & `window.destroy()` (SDL hardware context)

## 12. Co-located Resource Cleanup (`errdefer` + `try` Invariant)

- **Immediate `errdefer` Placement**: In fallible functions returning `!T` or `!void`, every heap allocation (`allocator.create`, `allocator.dupe`) and transient state flag modification MUST be paired with an `errdefer` statement placed on the line immediately following the allocation/mutation.
- **Prohibition of Manual `catch` Teardown Blocks**: Do NOT handle allocation or worker thread spawning failures with manual `catch |err| { allocator.free(...); allocator.destroy(...); }` blocks. Propagate errors via `try` and rely on `errdefer` stack unwinding.
- **Atomic Flag Reversal**: If setting an atomic flag prior to a fallible task (e.g. `is_loading_files.store(true, .release)`), use `errdefer is_loading_files.store(false, .release)` to guarantee state consistency upon failure.

## 13. Prohibition of Meaningless Optionality & Null Checks

- Do NOT make struct fields or function parameters optional (`?T = null`) defensively if the dependency or state is always present and required for correct runtime execution.
- Optional types (`?T`) MUST represent genuine, valid domain absence (e.g. `current_index: ?usize = null` when a playlist is empty, or `surface: ?sdl.Surface` when a thumbnail is unavailable).
- Wrapping non-optional dependencies in optionals introduces dead branches (`if (args.dep) |dep|`), obscures API contracts, and forces callers to handle impossible `null` scenarios. Require the dependency directly (`dep: T`).
