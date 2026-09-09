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
- **No Discarded C-ABI / External Return Status**: Do NOT discard boolean or error code returns from external library or C-ABI functions (e.g. `_ = win.handle.setBordered(...)` or `_ = sdl.c.SDL_StartTextInput(...)`). Always verify success and log failures with descriptive context and library error strings (e.g. `sdl.getError()`):
  ```zig
  if (!win.handle.setBordered(!win.is_borderless)) {
      std.log.err("SDL_SetWindowBordered failed: {s}", .{sdl.getError()});
  }
  ```

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

## 14. Zero Full-File Allocation Constraint for Large Media Formats

- Large media files (e.g. Camera RAW, uncompressed archives, video containers) range from 50MB to 500MB+. Reading full files into RAM causes severe memory spikes, heap fragmentation, and out-of-memory crashes.
- Workers and probes MUST use fixed-size stack buffers (e.g. `[128 * 1024]u8`) for header inspections and metadata extraction.
- Data extraction (e.g. embedded preview JPEGs, sub-streams) MUST be performed via range-limited positional file reads (`file.readPositional(io, &slices, offset)`) into precisely-sized allocations matching the exact payload length.
- **Buffer Sizing Arithmetic Invariant (`<count> * <unit>`)**:
  - Fixed-size stack and scratch buffers MUST use explicit compile-time arithmetic expressions
    rather than magic byte literals (e.g. write `[64 * 1024]u8` instead of `[65536]u8`).
  - Maintain canonical `<count> * <unit>` ordering (`64 * 1024`, `128 * 1024`, `256 * 1024`)
    consistently across all modules for immediate readability in KiB/MiB.

## 15. Saturating Arithmetic on Untrusted File Offsets & Lengths

- In file parsing routines (TIFF, EXIF, RAF, ZIP), offsets and lengths extracted from untrusted binary headers MUST be validated against buffer and file sizes before slicing or allocation.
- NEVER use simple addition `offset + length <= file_size`, which risks integer overflow panics in Zig Debug and ReleaseSafe modes when parsing corrupt or malicious files with near-max values.
- ALWAYS use saturating subtraction: `offset <= file_size -| length` or `offset <= buffer_len -| length`.

## 16. Strict Domain Invariant Enforcement via Tagged Unions

- When domain metadata contains mutually exclusive states or conditional properties (e.g. Camera RAW sensor dimensions), NEVER use loose booleans with optional or uninitialized fields (e.g. `is_raw: bool, sensor_w: f32`).

- Model the domain state explicitly using a tagged union (`union(enum)`) with an invariant validation constructor (`init(...)`):

  ```zig
  pub const RawMetadata = union(enum) {
      none,
      raw: struct {
          sensor_w: f32,
          sensor_h: f32,
      },

      pub fn init(is_raw: bool, w: f32, h: f32) RawMetadata {
          if (is_raw and w > 0.0 and h > 0.0) {
              return .{ .raw = .{ .sensor_w = w, .sensor_h = h } };
          }
          return .none;
      }
  };
  ```

- This eliminates illegal states at compile time and makes invalid combinations impossible to construct.

- **Top-Level Named Structs for Cross-Module Payloads**: When tagged union payloads are passed between modules (e.g. between domain state, view models, and UI rendering), define top-level named structs (`Active<Name>`) rather than inline anonymous structs.

- **Inline Accessors**: Provide inline convenience methods on the union (e.g. `getPrevIndex(self) ?usize`) to allow read access to active payload values without requiring nested pattern-matching blocks at every call site:

  ```zig
  pub const ActiveImageTransition = struct {
      prev_index: usize,
      prev_rotation: f32,
  };

  pub const ImageTransition = union(enum) {
      none,
      active: ActiveImageTransition,

      pub inline fn getPrevIndex(self: ImageTransition) ?usize {
          return switch (self) {
              .none => null,
              .active => |a| a.prev_index,
          };
      }
  };
  ```

- **Prohibition of Interdependent Optionals**:

  - NEVER maintain clusters of interdependent optional fields
    (e.g. `offset: ?u64, size: ?u64, method: ?u16`) in a state struct.
  - If fields are semantically dependent, bundle them into a concrete payload struct and represent
    the presence/absence via a tagged union (`union(enum) { unindexed, indexed: ZipSeekOffsets }`).

- **Prohibition of Multiplexed Event Payloads**:

  - NEVER overload an event payload with an optional resource handle (`surface: ?sdl.Surface`) to
    represent two fundamentally different event outcomes (e.g. dimension metadata probing vs.
    decoded thumbnail availability).
  - Define distinct event union variants (`dimensions_probed: DimensionsProbedPayload` vs.
    `thumb_decoded: ThumbDecodedPayload`).
  - **Resource Ownership Invariant**: The variant owning the resource must hold a non-optional
    handle (`surface: sdl.Surface`), enabling unconditional destruction in `BackgroundEvent.deinit`
    without defensive null-checking.

- **Enum Precision in Domain State**:

  - Do NOT degrade standard library or domain enums (`std.zip.CompressionMethod`) to primitive
    integers (`u16`, `u32`) or booleans in state structs or payloads.
  - Retain the strongly-typed enum to preserve compile-time safety, eliminate `@intFromEnum` /
    `@enumFromInt` conversions, and enable exhaustive `switch` dispatching.

- **Explicit Enum Branching via `switch`**:

  - When branching on enum values, prefer `switch (val)` over `if (val == .variant)`.
  - If only a specific variant is handled, write explicit branches
    (`switch (val) { .store => ..., else => {} }`) to document intentional fallbacks and facilitate
    future variant expansion.
