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
- **Stack Allocation vs. Arena Decision Matrix**:
  - *Dynamic / Unbounded Collections* (prefetch queues, scissor stacks, match
    lists): NEVER use fixed stack arrays `[N]T` that risk silent truncation or
    panic. Use `std.ArrayList(T)` backed by `frame_allocator` with
    `defer list.deinit(frame_allocator)`.
  - *Large Path Buffers* ($\\ge 4\\text{ KB}$ like `std.fs.max_path_bytes`):
    - *Per-Frame Layout & Render Passes*: Allocate from `frame_allocator` with
      `defer frame_allocator.free(...)` rather than placing 4 KB arrays on the
      stack inside per-frame loops.
    - *One-Off Main-Thread State Transitions*: In discrete, non-recursive state
      transitions where `frame_allocator` is unavailable (e.g. `openPalette`), a
      stack buffer (`var parent_buf: [std.fs.max_path_bytes]u8 = undefined;`) is
      preferred over `self.allocator.alloc` to avoid heap churn.
  - *Assert-Bounded Hardware/FFI Limits* (e.g. 16 vertex buffer slots in SDL3
    GPU, 8 IFD levels in EXIF): Keep on the stack and document the hardware/API
    bound in comments.
  - *Short Formatting Scratchpads for Clay IDs* ($\\le 64$ bytes): Keep on the
    stack using `std.fmt.bufPrint`. Clay hashes ID strings immediately into
    integers (`clay.getElementId`) and does not retain the string.
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
  - When managing `std.StringHashMap` or custom key-value maps, free owned keys
    via `keyIterator()` prior to calling `clearRetainingCapacity()` or
    `deinit()`.
  - Always invoke `stream.close(io)` on `std.Io.net.Stream` socket handles
    during queue item teardown (`deinitQueueItem`) and `AppState.deinit` to
    prevent OS file/socket descriptor leaks.
- **Reverse-Initialization Lifecycle Teardown**:
  - Every struct owning heap memory, GPU handles, socket connections, or child
    sub-states (`AppState`, `ViewerState`, `DisplayState`, `RenderResources`,
    `ParsedArgs`) MUST provide an explicit `deinit` method.
  - Top-level application teardown (`AppGraphicsAndState.deinit` in
    `src/main.zig`) MUST execute in strict reverse-initialization order: free
    CLI args and stop the IPC server, free Clay layout memory, quiesce workers
    and deinitialize `AppState`/`ViewerState`, release GPU `RenderResources`,
    and finally destroy the SDL GPU device, window, and SDL subsystems.

## 2. Tagged Unions, Enums & Domain Invariant Modeling

- **Explicit Tagged Union Access (`switch (union)`)**:
  - Always access tagged union payloads via explicit `switch (union)` pattern
    matching. Do NOT use direct field access (`union.variant`) unless guarded by
    an enclosing `switch`; direct access bypasses safety checks in
    ReleaseFast/ReleaseSmall builds.
- **Strict Domain Invariants via Tagged Unions**:
  - Model mutually exclusive domain states (`SlideshowMode`, `DisplayState`,
    `CacheStatus`, `ThumbnailState`, `ThumbnailPadding`, `RawMetadata`,
    `ImageTransition`) using `union(enum)` with validation constructors
    (`init(...)`) rather than loose booleans or parallel optionals:
    ```zig
    pub const RawMetadata = union(enum) {
        none,
        raw: struct { sensor_w: f32, sensor_h: f32 },

        pub fn init(sensor_w: f32, sensor_h: f32) RawMetadata {
            if (sensor_w > 0.0 and sensor_h > 0.0 and
                std.math.isFinite(sensor_w) and std.math.isFinite(sensor_h))
            {
                return .{
                    .raw = .{ .sensor_w = sensor_w, .sensor_h = sensor_h },
                };
            }
            return .none;
        }
    };
    ```
  - **Top-Level Named Payload Structs**: When union payloads cross module
    boundaries (domain state -> view model -> UI), define top-level named
    structs (`ActiveImageTransition`) and provide `inline` convenience accessors
    on the union (`getPrevIndex(self) ?usize`).
  - **No Interdependent Optionals or Multiplexed Event Payloads**: Bundle
    semantically coupled optionals into a single tagged union variant
    (`union(enum) { unindexed, indexed: ZipSeekOffsets }`). Never overload an
    event payload with an optional handle (`surface: ?sdl.Surface`) to represent
    different outcomes; define distinct union variants (`dimensions_probed` vs
    `thumb_decoded`) with non-optional resource ownership.
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
  - Camera RAW files, archives, and large containers (50MB–500MB+) MUST NEVER be
    read entirely into RAM.
  - Use fixed-size buffers for header inspection and range-limited positional
    reads (`file.readPositional(io, &slices, offset)`) into exact-sized buffers
    for embedded preview extraction.
  - **Buffer Sizing Arithmetic Invariant (`<count> * <unit>`)**: Always write
    fixed buffer sizes as compile-time `<count> * <unit>` expressions
    (`[64 * 1024]u8`, `[128 * 1024]u8`, `[256 * 1024]u8`) rather than magic byte
    literals (`[65536]u8`).
- **Saturating Arithmetic on Untrusted Offsets & Lengths**:
  - In binary parsers (TIFF, EXIF, RAF, ZIP), NEVER validate bounds with
    `offset + length <= file_size`, which overflows on corrupt headers.
  - ALWAYS use saturating subtraction: `offset <= file_size -| length` or
    `offset <= buffer_len -| length`.
- **32-Bit Platform Offset `@intCast` Bounds Safety**:
  - When container offsets are `u64`, NEVER `@intCast` to `usize` before
    checking bounds against `slice.len` (which panics on 32-bit targets if
    offset > 4GB).
  - Verify bounds in `u64` arithmetic first:
    ```zig
    const t_len: usize = @intCast(loc.length);
    if (loc.file_offset <= slice.len -| loc.length) {
        const t_off: usize = @intCast(loc.file_offset);
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
    pointers (`DecodeArgs`, `PathScanArgs`, `StdinArgs`, `IpcServerArgs`). Never
    use raw `?*anyopaque` handles or untyped pointer downcasting.
- **Worker Task Early-Exit & Fail-Fast Invariants**:
  - When a worker encounters a file I/O or decode failure (and the task was not
    canceled):
    1. Log the error with context.
    2. Push the failure event (e.g. `.decode_failed`) to
       `context.workers.event_queue` and call `context.wakeUpMainThread()`.
    3. `return` immediately without wrapping subsequent code in redundant
       nested `if` blocks.
