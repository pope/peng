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
