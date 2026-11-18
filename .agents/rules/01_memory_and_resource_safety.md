---
trigger: glob
globs: '**/src/**/*.zig'
description: Memory arenas, errdefer lifecycles, --server reclamation, tagged union invariants, binary bounds safety, and error logging.
---

# Memory & Resource Safety Rules

## 1. Allocators, Arenas & Ownership Lifecycles

- **Per-Frame Arena & LIFO Rewind**:
  - Reset per-frame arenas at frame boundaries via `arena.reset(.retain_capacity)`
    and never store arena slices/pointers in persistent state across frames.
  - Pair scratch `frame_allocator` allocations with `defer frame_allocator.free`
    or `defer list.deinit(frame_allocator)` so `ArenaAllocator` rewinds its bump
    cursor (`end_index`) between sequential systems within the same frame.
- **Bounded Session Arenas & Collection Trimming**:
  - Never call unbounded `.reset(.retain_capacity)` on session arenas: use
    `resetDirectoryArena()` (`<= 256 KiB`), `TriageMap.resetArena()`
    (`<= 64 KiB`), and `PaletteState.clearDirItems()` (sets `dir_items = .empty`
    and caps `dir_arena` `<= 64 KiB`, freed via `.free_all` in
    `shrinkToWarmCapacity()`), and call `NavigationState.trimExcessCapacity`
    after playlist replacements when `capacity > 2 * len` and `> 64`.
- **Autonomous Worker Arenas**:
  - Allocate `DirectoryScanResultPayload` strings/slices from its embedded
    `ArenaAllocator` so `BackgroundEvent.deinit` and cancellation unwinds free
    batches in **O(1)** (`scanDirectoryThreadSafe` likewise uses a scratch arena).
- **Stack vs. Arena Sizing**:
  - Never put unbounded collections on fixed stack arrays `[N]T`; use
    `std.ArrayList(T)` on `frame_allocator` (keep fixed arrays only for
    hardware/spec bounds like 16 GPU vertex slots or 8 EXIF IFD levels).
  - Allocate `>= 4 KB` path buffers (`max_path_bytes`) on `frame_allocator` in
    per-frame passes; stack buffers are fine in discrete non-recursive main-thread
    transitions (`openPalette`).
  - Copy shared byte slices via `@memcpy` before mutating across threads, and
    prefer caller-provided buffers or explicit allocators over unowned heap
    returns.
- **Co-located `errdefer` + `try` Teardown**:
  - Pair every fallible heap allocation and transient atomic counter increment
    with an `errdefer` on the very next line; propagate via `try` instead of
    manual `catch` free blocks.
  - Free owned `String*HashMapUnmanaged` keys via `keyIterator()` before
    `clearRetainingCapacity`/`deinit`, and `close(io)` every `std.Io.net.Stream`.
- **Pinned Startup, Reverse `deinit` & `--server` Reclamation**:
  - Every resource-owning struct provides `deinit`. `AppGraphicsAndState.init`
    (`src/main.zig`) initializes `initSdlCore` first, constructs `self.state`
    in-place at its pinned stack address (never copy `AppState` after spawning
    workers holding interior pointers), and keeps `gpu_device = null` /
    `display = .headless` (with `gpu_enabled = true`) until all GPU pipelines
    succeed. `deinit` tears down in reverse order (CLI args -> `exiting = true`
    -> IPC server -> workers & `AppState` -> `RenderResources` -> GPU/window ->
    `quitSdlCore`).
  - On `--server` `hideWindow`, release transient textures/buffers/arenas, flush
    Vulkan deferred destroy queues via `sdl.gpu.Device.reclaimMemory()`, and call
    `sdl.reclaimProcessHeap()` (`malloc_trim(0)`, gated on
    `active_decode_threads == 0` or `.hidden`).
  - `UploadStagingBuffer` (`src/gpu/upload.zig`) keeps buffers `<= 32 MiB`
    (`WARM_STAGING_CAP_BYTES`) warm and decays oversized buffers after `5000 ms`
    (`IDLE_DECAY_MS`) idle via `maybeShrinkIdle` + `decayTimeoutMs`.

## 2. Tagged Unions, Weak Keys & Domain Modeling

- **Safe Tagged Unions (`switch`)**:
  - Access `union(enum)` payloads strictly inside `switch` (direct `u.variant`
    bypasses safety checks in ReleaseFast).
  - Model mutually exclusive states (`SlideshowMode`, `ScrollCadence`, `PanTap`,
    `ZoomPhase`, `PaletteLifecycle`, `ActivePaletteMode`, `DisplayState`,
    `DisplayBackend`, `ResidentAsset`, `ThumbnailState`, `InFlightState`,
    `RawMetadata`, `ArchiveTelemetry`, `UploadMode`, `MipmapTelemetry`,
    `ImageTransition`, `BlurResources`, `RetainedResource`) via `union(enum)`
    and validation constructors (`PhysicalDims.initPositive`), never loose
    booleans, `0`/`0.0` dimension sentinels, interdependent optionals, or
    optional-surface event multiplexing (`dimensions_probed` vs
    `thumb_decoded`). Keep multi-role containers (e.g. TIFF IFD0) as structs,
    use top-level named payload structs across module boundaries, use
    `packed struct` bitfields (`DirectionFlags`, `ZoomFlags`) for orthogonal
    flags, keep domain enums strongly typed, and use `?T` only for genuine
    absence.
- **Weak Generational Cache Keys (Zero Interior Slot Pointers)**:
  - `ImageCache` (`MultiArrayList(CacheSlot)`) uses `swapRemove`, invalidating
    slot addresses. Never pass `*CacheEntry` or slot slices across functions,
    eviction/append calls, or to workers.
  - Pass `ImageCacheKey` (`MediaId` + `generation`) by value, cancel workers via
    pinned `job_epochs: [MAX_DECODE_JOBS]std.atomic.Value(u32)`, validate worker
    events via `SlotBound(T).resolve(&state.cache)`, read by value with
    `getEntry(key)`, and scope mutable `get(key)` borrows strictly to non-mutating
    leaf blocks.

## 3. Binary Parsing & Surface Format Safety

- **Zero Full-File RAW/Archive Reads**:
  - Never read large RAW or archive files fully into RAM; use positional reads
    (`readPositional`) and `<count> * <unit>` buffer expressions (`[256 * 1024]u8`).
- **64-Bit Saturating Offset Bounds**:
  - Always check `offset +| length <= slice_or_file_len` in `u64` arithmetic
    *before* `@intCast`ing to `usize` (never unchecked `offset + length` or
    unsigned `size -| length`, which is `0 <= 0` when `offset == 0`).
- **Explicit Surface Pixel Formats**:
  - Never assume non-32-bit `sdl.Surface` data is 3-byte RGB24 (`index8`, `L8`,
    and 16-bit formats differ in stride). Match `cur_fmt` explicitly: direct copy
    for 32-bit `rgba32`/`bgra32`/`xrgb8888`, GPU `unpack_rgb.comp.glsl` (or CPU
    SIMD in headless mode) for `rgb24`/`bgr24`, and `convert(rgba32)` fallback.

## 4. Error Handling & Worker Fail-Fast

- Never silence errors with empty `catch {}` / `else |_| {}` or discard SDL C-ABI
  boolean/error returns; log context + `sdl.getError()` via `std.log.err`/`warn`.
- Pass strongly typed `*Args` structs to workers (never `?*anyopaque`). On
  uncanceled worker I/O or decode failure: log error, push failure event
  (`.decode_failed`) to `workers.event_queue`, call `context.wakeUpMainThread()`,
  and `return` immediately.
