# Memory & Resource Safety Rules

## 1. Allocators, Arenas & Ownership Lifecycles

- **Per-Frame Arenas & LIFO Rewind Invariant**:
  - Reset per-frame arena allocators at frame boundaries via
    `arena.reset(.retain_capacity)`.
  - Never store references or pointers to arena-allocated data inside persistent
    state structs across frame boundaries.
  - Zig's `std.heap.ArenaAllocator.free` and `resize` rewind the bump pointer
    (`end_index`) when releasing the most recent allocation in the active node.
    Always pair `frame_allocator` scratch allocations with
    `defer frame_allocator.free(...)` or `defer list.deinit(frame_allocator)` so
    sequential systems reuse frame memory without arena growth.
- **Bounded Session Arena Retention & Collection Trimming**:
  - Never use unbounded `.reset(.retain_capacity)` on session arenas that hold
    dynamic directory paths or user classification data.
  - Reset `directory_arena` via `resetDirectoryArena()` bounding retained
    memory pages to $\le 256\text{ KiB}$
    (`MAX_RETAINED_DIR_ARENA_BYTES = 256 * 1024`).
  - Reset `classification_arena` via `TriageMap.resetArena()` bounding
    retained memory pages to $\le 64\text{ KiB}$
    (`MAX_RETAINED_CLASS_ARENA_BYTES = 64 * 1024`).
  - After directory scans or playlist replacements, call
    `NavigationState.trimExcessCapacity` to shrink `MultiArrayList(MediaItem)`
    via `setCapacity` (or `clearAndFree` when `len == 0`) whenever capacity
    exceeds $2 \times \text{len}$ and exceeds 64 elements, avoiding retention
    of peak capacity from massive directories.
- **Autonomous Worker Arenas for Batched Event Payloads**:
  - `DirectoryScanResultPayload` embeds a dedicated `std.heap.ArenaAllocator`
    initialized from `gpa` in `pathScanWorker`.
  - All joined directory paths, CBZ archive entry names, and the final `paths`
    slice are allocated from the arena allocator (`scan_alloc`).
  - On the main thread, `BackgroundEvent.deinit` invokes
    `res.unchecked_payload.deinit()` to release the entire payload in **O(1)**
    without per-item freeing loops.
  - On worker cancellation or queue push failure, `scan_arena.deinit()` executes
    in O(1), ensuring zero memory leaks.
  - In `scanDirectoryThreadSafe`, use a local scratch `std.heap.ArenaAllocator`
    so intermediate path strings are released in O(1) via `defer`.
- **Stack Allocation vs. Arena Decision Matrix**:
  - *Dynamic / Unbounded Collections* (prefetch queues, scissor stacks, match
    lists): NEVER use fixed stack arrays `[N]T` that risk silent truncation or
    panic. Use `std.ArrayList(T)` backed by `frame_allocator` with
    `defer list.deinit(frame_allocator)`.
  - *Large Path Buffers* ($\ge 4\text{ KB}$ like `std.Io.Dir.max_path_bytes`):
    - *Per-Frame Layout & Render Passes*: Allocate from `frame_allocator` with
      `defer frame_allocator.free(...)` rather than placing 4 KB arrays on the
      stack inside per-frame loops.
    - *One-Off Main-Thread State Transitions*: In discrete, non-recursive state
      transitions where `frame_allocator` is unavailable (e.g. `openPalette`),
      a stack buffer (`var parent_buf: [std.Io.Dir.max_path_bytes]u8 =
      undefined;`) is preferred over `self.allocator.alloc` to avoid heap churn.
  - *Assert-Bounded Hardware/FFI Limits* (e.g. 16 vertex buffer slots in SDL3
    GPU, 8 IFD levels in EXIF): Keep on the stack and document the hardware/API
    bound in comments.
- **Caller-Provided Output Buffers & Slice Aliasing**:
  - Functions generating variable-length data should accept caller-provided
    output buffers or explicit allocators rather than returning unowned heap
    memory.
  - When modifying shared byte buffers, copy input slices via `@memcpy` into
    target allocations before mutation to prevent buffer aliasing across
    concurrent reader threads.
- **Co-located Resource Cleanup (`errdefer` + `try` Invariant)**:
  - In fallible functions returning `!T` or `!void`, every heap allocation
    (`allocator.create`, `allocator.dupe`) and transient atomic counter mutation
    MUST be paired with an `errdefer` on the immediately following line (e.g.
    `errdefer _ = active_threads.fetchSub(1, .release)`).
  - Do NOT write manual `catch |err| { allocator.free(...); }` teardown blocks;
    propagate errors via `try` and rely on `errdefer` stack unwinding.
- **HashMap Key & Socket Stream Cleanup**:
  - When managing `std.StringHashMapUnmanaged`,
    `std.StringArrayHashMapUnmanaged`, or custom key-value maps, free owned keys
    via `keyIterator()` prior to calling `clearRetainingCapacity()` or
    `deinit(allocator)`.
  - Always invoke `stream.close(io)` on `std.Io.net.Stream` socket handles
    during queue item teardown (`deinitQueueItem`) and `AppState.deinit` to
    prevent OS file/socket descriptor leaks.
- **Reverse-Initialization Lifecycle Teardown & Overlapped Startup**:
  - Every struct owning heap memory, GPU handles, socket connections, or child
    sub-states (`AppState`, `ViewerState`, `DisplayState`, `RenderResources`,
    `ParsedArgs`) MUST provide an explicit `deinit` method.
  - Startup initialization (`AppGraphicsAndState.init` in `src/main.zig`) MUST
    initialize `self.state` in-place at its pinned stack address
    (`*AppGraphicsAndState`) and decouple SDL core initialization
    (`gpu.graphics.initSdlCore`) from window and GPU creation
    (`initGraphicsAndWindow`). SDL events and video MUST be initialized before
    `AppState` or background workers launch, and `AppState` MUST NEVER be copied
    or returned by value after spawning workers that hold pointers to
    `state.workers`, `state.cache.generation`, or
    `state.viewer.navigation.active_file_scans`.
  - State initialization and early worker tasks (`openPath` / `readPipedStdin`)
    run concurrently with main-thread window and GPU creation. GPU handles
    (`state.gpu_device`) and the claimed `DisplayBackend.windowed`
    (`ActiveWindow`) MUST remain unbound (`state.gpu_device = null`, `display`
    holding `.headless`) until all pipeline and GPU resource allocations
    succeed, while `state.gpu_enabled = true` declares hardware GPU intent to
    early workers. This guarantees that intermediate failure unwinding only
    deinitializes CPU state without accessing destroyed GPU or window handles
    (use-after-free).
  - Top-level application teardown (`AppGraphicsAndState.deinit` in
    `src/main.zig`) frees CLI arguments upfront as independent CPU memory,
    followed by reverse teardown of runtime subsystems: signal worker
    quiescence (`workers.exiting.store(true, .release)`), stop and join the IPC
    server, quiesce and join background workers and deinitialize
    `AppState`/`ViewerState`, release GPU `RenderResources`, destroy the SDL GPU
    device and window, and finally call `gpu.graphics.quitSdlCore()`.
- **Resident `--server` Mode Memory Reclamation (`hideWindow`, `reclaimMemory`, `reclaimProcessHeap`)**:
  - When hiding the window in `--server` mode (`AppState.hideWindow` +
    `RenderResources.releaseTransientResources`), release all cached CPU
    surfaces, GPU image/thumbnail textures, `upload_staging` buffers, glyph
    `text_cache` textures, offscreen `blur` textures (transitioning
    `BlurResources` `.initialized` -> `.pipelines_ready`), and double-buffered
    UI `vertex_buffers`/`transfer_buffers`, and shrink oversized dynamic
    containers (`cache.slots`, `navigation.items`, `palette`).
  - Flush SDL3's deferred Vulkan destruction queues (`texturesToDestroy`,
    `buffersToDestroy`, `transferBuffersToDestroy`) via
    `sdl.gpu.Device.reclaimMemory()` (`waitForIdle` -> empty `submit` ->
    `waitForIdle`) so empty `VkDeviceMemory` VRAM/GTT blocks are returned to the
    OS, and call `sdl.reclaimProcessHeap()` (`malloc_trim(0)` on Linux/glibc,
    gated on `active_decode_threads == 0` or `.hidden`) to return freed
    cross-thread C decoder (`SDL_image`/`stb_image`) arena pages to the OS.

## 2. Tagged Unions, Enums & Domain Invariant Modeling

- **Explicit Tagged Union Access (`switch (union)`)**:
  - Always access tagged union payloads via explicit `switch (union)` pattern
    matching. Do NOT use direct field access (`union.variant`) unless guarded by
    an enclosing `switch`; direct access bypasses safety checks in
    ReleaseFast/ReleaseSmall builds.
- **Strict Domain Invariants via Tagged Unions**:
  - Model mutually exclusive domain states (`SlideshowMode`, `DisplayState`,
    `DisplayBackend`, `ResidentAsset`, `ThumbnailState`, `ThumbnailPadding`,
    `RawMetadata`, `ArchiveTelemetry`, `UploadMode`, `MipmapTelemetry`,
    `ImageTransition`, `BlurResources`, `RetainedResource`, `ParsedIpcArgs`)
    using `union(enum)` with validation constructors (`init(...)`) rather than
    loose booleans or parallel optionals:
    ```zig
    pub const RawMetadata = union(enum) {
        none,
        raw: PhysicalDims,

        pub fn init(sensor_w: f32, sensor_h: f32) RawMetadata {
            if (PhysicalDims.initPositive(sensor_w, sensor_h)) |dims| {
                return .{ .raw = dims };
            }
            return .none;
        }

        pub inline fn fromDims(dims: PhysicalDims) RawMetadata {
            return init(dims.w, dims.h);
        }
    };
    ```
  - **Top-Level Named Payload Structs**: When union payloads cross module
    boundaries (domain state -> view model -> UI), define top-level named
    structs (`ActiveImageTransition`) and provide `inline` convenience accessors
    on the union (`getPrevIndex(self) ?usize`).
  - **No Interdependent Optionals, In-Band Zero Sentinels, or Multiplexed Event Payloads**:
    Bundle semantically coupled optionals into a single tagged union variant
    (`union(enum) { unindexed, indexed: ZipSeekOffsets }`, `ArchiveTelemetry =
    union(enum) { none, archive: struct { ... } }`, `UploadMode`,
    `MipmapTelemetry`) or validated optional struct (`source_dims: ?PhysicalDims
    = null` constructed via `PhysicalDims.initPositive(w, h)`). Never represent
    optional composite data (such as 2D dimensions) as independent primitive
    fields with in-band `0` / `0.0` sentinels (`full_w: f32 = 0.0, full_h: f32 =
    0.0`) or boolean + defaulted primitive pairs (`needs_thumb_write: bool` +
    `source_mtime_sec: i64 = 0`), which permit half-valid states (`w > 0` with
    `h == 0`) and axis-shearing on per-axis fallback. Never overload an event
    payload with an optional handle (`surface: ?sdl.Surface`) to represent
    different outcomes; define distinct union variants (`dimensions_probed` vs
    `thumb_decoded`) with non-optional resource ownership.
  - **Weak Generational Keys Over Raw Container Interior Pointers**:
    `ImageCache` (`std.MultiArrayList(CacheSlot)`) evicts entries via
    `swapRemove`, which relocates the tail element into the evicted index and
    overwrites the former tail slot with `undefined` (`0xaa` in Debug).
    Never return or pass raw `*CacheEntry` pointers (or `slots.items(.entry)`
    or `slots.items(.key)` slices) across function boundaries, to workers,
    or across any call that may append to or evict from `ImageCache` (e.g.
    `enforceVramBudget`, `appendSlot`, `completeDecodedGpuUpload`). Workers
    must NEVER hold interior pointers to cache slots; use the pinned static
    table `job_epochs: [MAX_DECODE_JOBS]std.atomic.Value(u32)` inside
    `ImageCache` for zero-allocation cooperative cancellation. Pass
    `ImageCacheKey` (composed of stable `id: MediaId` and generation epoch)
    by value, let `SlotBound(T).resolve(&state.cache)` validate both cache
    generation and per-job epoch before returning `{ key, payload }`, read
    slot state by value via `cache.getEntry(key)`, and scope mutable pointer
    borrows (`if (cache.get(key)) |entry| { ... }`) strictly to leaf blocks
    that do not mutate container capacity.
  - **Multi-Role Container Caveat**: Do not force mutually exclusive tagged
    unions onto multi-role container descriptors (such as TIFF IFD0, which
    simultaneously acts as a SubIFD container, preview provider, and EXIF
    directory). Reserve tagged unions for genuinely mutually exclusive domain
    states and results.
- **Packed Bitfields & Component Composition**:
  - Use explicit `packed struct` bitfields for orthogonal directional or state
    flags (`DirectionFlags = packed struct(u4)`,
    `ZoomFlags = packed struct(u2)`).
  - Compose image cache slot state via explicit component structs and unions
    (`CpuSurfaceComponent`, `GpuTextureComponent`, `ThumbnailState`).
- **Prohibition of Meaningless Optionality (`?T`)**:
  - Do NOT make struct fields or function parameters optional (`?T = null`)
    defensively when the value is always required. Optional types MUST represent
    genuine domain absence (e.g. `current_index: ?usize` on an empty playlist).
- **Enum Precision in Domain State**:
  - Retain strongly-typed standard library or domain enums
    (`std.zip.CompressionMethod`, `Orientation`) in state structs and payloads
    rather than degrading them to primitive integers (`u16`, `u32`) or booleans.

## 3. Binary Parsing, Large Media & Pixel Format Safety

- **Zero Full-File Allocation for Large Media Formats**:
  - Camera RAW files, archives, and large containers (50MB–500MB+) MUST NEVER
    be read entirely into RAM.
  - Use fixed-size buffers for header inspection and range-limited positional
    reads (`file.readPositional(io, &slices, offset)`) into exact-sized buffers
    for embedded preview extraction.
  - **Buffer Sizing Arithmetic Invariant (`<count> * <unit>`)**: Always write
    fixed buffer sizes as compile-time `<count> * <unit>` expressions
    (`[64 * 1024]u8`, `[128 * 1024]u8`, `[256 * 1024]u8`) rather than magic byte
    literals (`[65536]u8`).
- **Saturating Arithmetic on Untrusted Offsets & Lengths**:
  - In binary parsers (TIFF, EXIF, RAF, ZIP), NEVER validate bounds with
    unchecked `offset + length <= file_size` (which overflows on corrupt
    headers) AND NEVER use `offset <= file_size -| length` on unsigned integers
    (when `offset == 0` and `length > file_size`, `file_size -| length == 0`
    and `0 <= 0` falsely evaluates to `true`).
  - ALWAYS use saturating addition: `offset +| length <= file_size` or
    `offset +| length <= buffer_len`.
- **32-Bit Platform Offset `@intCast` Bounds Safety**:
  - When container offsets or lengths are `u64`, NEVER `@intCast` either
    `file_offset` or `length` to `usize` before checking bounds against
    `slice.len` (which panics on 32-bit targets if > 4GB).
  - Verify `offset +| length <= slice.len` in `u64` arithmetic first:
    ```zig
    if (loc.file_offset +| loc.length <= slice.len) {
        const t_off: usize = @intCast(loc.file_offset);
        const t_len: usize = @intCast(loc.length);
        return slice[t_off .. t_off + t_len];
    }
    ```
- **Surface Pixel Format Bounds & GPU/CPU Conversion Safety**:
  - NEVER assume non-32-bit `sdl.Surface` buffers are 3-byte RGB24; indexed
    8-bit (`index8`), grayscale (`L8`), and 16-bit surfaces have different
    strides.
  - Explicitly match on `cur_fmt`:
    - Direct `@memcpy` for 32-bit `rgba32` / `bgra32` / `xrgb8888`.
    - For 24-bit `rgb24` / `bgr24`: in GPU mode, keep the 3-byte surface intact
      on the CPU and unpack to RGBA32 on the GPU via `unpack_rgb.comp.glsl` and
      `UploadStagingBuffer`; in headless/CPU mode, use the SIMD 24-to-32-bit
      converter (`src/sdl/surface.zig`).
    - Safe fallback conversion (`current_surf.convert(PixelFormat.rgba32)`) for
      indexed, grayscale, or arbitrary formats prior to upload.

## 4. Error Handling & Worker Fail-Fast Invariants

- **Non-Negotiable Structured Error Logging**:
  - Never swallow errors silently with empty `catch {}` or `else |_| {}` blocks.
    Log caught errors via `std.log.err` or `std.log.warn` with context before
    returning fallbacks.
  - Never discard boolean or error-code returns from C-ABI / SDL calls (e.g.
    `_ = win.handle.setBordered(...)`). Always check the return status and log
    `sdl.getError()` on failure.
- **Strongly-Typed Worker Procedures**:
  - Background thread functions must accept strongly-typed struct parameter
    pointers (`DecodeArgs`, `PathScanArgs`, `PaletteScanArgs`,
    `PreviewWorkerArgs`, `StdinArgs`, `IpcServerArgs`). Never use raw
    `?*anyopaque` handles or untyped pointer downcasting.
- **Worker Task Early-Exit & Fail-Fast Invariants**:
  - When a worker encounters a file I/O or decode failure (and the task was not
    canceled):
    1. Log the error with context.
    2. Push the failure event (e.g. `.decode_failed`) to
       `context.workers.event_queue` and call `context.wakeUpMainThread()`.
    3. `return` immediately without wrapping subsequent code in redundant
       nested `if` blocks.
