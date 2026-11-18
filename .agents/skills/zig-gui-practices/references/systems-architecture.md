# Systems Architecture & Execution Patterns Reference

## System Pass Pipeline Architecture

- **Pattern 1 — Update Phase Execution (`runUpdatePhase` in `src/app/systems/root.zig`)**:
  - Systems run exclusively during Phase 2 (`runUpdatePhase`) of the 3-phase frame loop in `src/viewer.zig` (`Worker Ingestion` -> `Update Phase` -> `Render Phase`), never via out-of-band calls inside `AppState` or input handlers:
    01. `sysSyncWindowVisibility(ctx)` — Syncs minimize/occlude state before animation/slideshow passes.
    02. `sysUpdateAnimations(ctx)` — Ticks active SoA animation channels by `delta_time_ms`.
    03. `sysExecuteIpcCommands(ctx)` — Parses queued IPC socket commands -> `pending_intents`.
    04. `sysProcessPaletteInput(ctx)` — Handles palette query, selection & click-outside -> `pending_intents`.
    05. `sysProcessInput(ctx, palette_closed)` — Maps keyboard shortcuts & file drops -> `pending_intents`.
    06. `sysProcessUiInteractions(ctx, palette_closed)` — Resolves overlay button & slider pointer hits -> `pending_intents`.
    07. `sysUpdateViewport(ctx, palette_closed)` & `sysUpdateSlideshow(ctx)` — Updates pan/zoom glide & slideshow timers -> `pending_intents`.
    08. `sysExecuteIntents(ctx)` — Single-pass execution of all queued `AppIntent` items.
    09. `sysSyncWindow(ctx)` — Syncs OS window title and display state.
    10. `sysProcessAssetUploads(ctx)` — Updates EXIF rotation, paces GPU texture uploads, and decays oversized staging buffers (> 32 MiB after 5s idle).
    11. `sysUpdateCache(ctx)` — Enforces VRAM budget, evicts slots, and spawns `DecodeMode` / `DecodePriority` workers.
    12. `sysSyncMetrics(ctx)` — Snapshots worker counters & telemetry into `ViewerStats`.

______________________________________________________________________

## Frame Context & Memory Lifetimes

- **Pattern 2 — Frame Arena Lifetimes & Capacity Pre-allocation**
  - Every system function signature accepts `ctx: FrameContext` containing
    `state: *AppState`, `frame_allocator: Allocator`, `input: ?FrameInput`,
    `delta_time_ms: f64`, and `now_ms: u64`.
  - Systems must use `ctx.frame_allocator` for transient frame-bound allocations (such as string duping for enqueued intents). Memory allocated with `frame_allocator` automatically resets at frame boundaries.
  - **Dynamic Array Pre-allocation**: State constructors
    (`NavigationState.init`, `PaletteState.init`,
    `AppState.ensureInitialCapacities`) reserve capacities via
    `ensureTotalCapacity(allocator, N)` with rationale comments (while
    `PaletteState.dir_items` starts `.empty` and is populated off-thread by
    Stage 1 of `paletteScanWorker` into a worker `ArenaAllocator` via
    `scanDirectoryEntries`, then transferred in **O(1)** on
    `.palette_dir_loaded` via `PaletteState.applyLoadedDirectory`;
    `beginDirectoryLoad` clears `dir_items` and bumps `dir_scan_generation` on
    the main thread with zero disk I/O).
  - **Capacity Retention**: Interactive reset methods (`clearIntents()`,
    `PaletteState.reset()`) retain unmanaged list capacities via
    `clearRetainingCapacity()`, while `clearDirItems()` sets
    `dir_items = .empty` and resets `dir_arena` in O(1) with a `64 KiB` cap
    (`shrinkToWarmCapacity(allocator)` and `deinit(allocator)` set
    `dir_items = .empty` and reset `.free_all` / `deinit` `dir_arena`).
    `PaletteState` uses explicit `allocator` params for non-arena lists
    and `searcher`.
  - **Fuzzy Match Filtering & Buffer Pre-allocation**: Rebuild methods
    (`rebuildActionMatches`, `rebuildDirectoryMatches`, `rebuildFileMatches`)
    short-circuit on empty queries (`query.items.len == 0`) by populating
    `matches` 1-to-1 without searcher allocation or fuzzy scoring.
    `rebuildDirectoryMatches` and `rebuildFileMatches` score in a single pass
    with on-demand `max_haystack_len`/`getSearcher` growth (updating
    `max_haystack_len` after `try getSearcher(...)`), hoisting `"RAW+JPG"`
    pair-tag scoring outside the loop in `rebuildFileMatches`, and pre-size
    `scored_matches`/`matches` for `appendAssumeCapacity`.
  - **LIFO Deallocation for Intra-Frame Rewinding**: In addition to resetting
    `frame_arena` at frame boundaries, systems should release transient scratch
    allocations via `defer ctx.frame_allocator.free(slice)` or
    `defer list.deinit(ctx.frame_allocator)`. Zig's `std.heap.ArenaAllocator`
    rewinds its internal bump offset when the most recent allocation is freed,
    allowing subsequent systems in the same frame tick to reuse that memory
    without triggering arena block growth.
  - **Frame-Arena String Lifetimes for `UiDrawList` Text Commands**: In UI
    layout functions (`layout.zig`, `edit_panel.zig`, `palette.zig`,
    `stats.zig`), text commands (`list.addText`, `list.addTextRuns`) store slice
    references (`[]const u8`) inside `UiDrawList`, which are read during the
    render packet extraction pass (`buildRenderPacket`). Dynamic text (such as
    numeric percentages, slider values, formatted labels, or stats strings) MUST
    NOT use local stack buffers (`var buf: [32]u8 = undefined`) that go out of
    scope before `buildRenderPacket` runs. Dynamic labels MUST be formatted into
    `frame_allocator` (e.g. `try frame_allocator.print(...)`), guaranteeing
    memory validity through the GPU text blitting pass.

______________________________________________________________________

## Decoupled Intent-Driven Systems

- **Pattern 3 — Zero Inter-System Calls**:
  - Systems must never call other systems directly.
  - Systems communicate strictly by mutating `AppState` fields or pushing `AppIntent` variants to `state.pending_intents`.

______________________________________________________________________

## ImageCache & Generation Ownership

- **Pattern 4 — Cache Slot Generation Ownership, Weak Keys & Envelope Validation**:
  - `ImageCache` (`state.cache` in `src/cache/root.zig`) uses Zig's
    `std.MultiArrayList(CacheSlot)` for Structure-of-Arrays (SoA) memory
    layout, allowing key scanning without cache-line pollution while mutating
    key and entry slices atomically.
  - Generation state (`generation: std.atomic.Value(usize) = .init(0)`) is owned exclusively by `ImageCache`.
  - Navigation/directory resets advance the generation via `_ = state.cache.advanceGeneration()`.
  - In-flight worker jobs and cached textures are keyed by stable `MediaId`
    (`ImageCacheKey{ .id = MediaId, .generation = usize }`). When a
    single-file launch (`peng /dir/img_50.jpg`) finishes its background
    directory scan, the target item retains its allocated `MediaId(1)`,
    allowing in-flight worker events to resolve directly without slot
    re-keying, alias mapping, or cache eviction.
  - Incoming background event payloads wrap slot-bound data in `SlotBound(T)`
    (`evt.resolve(&state.cache) -> ?SlotBound(T).Resolved`) and
    generation-bound data in `Generational(T)` (`evt.resolve(&generation)`).
    `SlotBound.resolve` returns the validated `ImageCacheKey` rather than a
    raw `*CacheEntry` pointer because `enforceVramBudget` (`swapRemove`)
    relocates the tail slot and invalidates interior pointers. Callers read
    slot state by value via `state.cache.getEntry(key)` and scope mutable
    pointer borrows (`state.cache.get(key)`) to leaf blocks.

______________________________________________________________________

## System Pass Documentation

- **Pattern 5 — Concise System Pass Docstrings (`///`)**:
  - Prefix every public system pass entry point (`pub fn sysXxx`) with a concise
    `/// System Pass: ...` doc comment summarizing its frame responsibility.
  - Keep internal helpers private (`fn`) without verbose multi-section docstring
    templates unless documenting non-obvious ownership or safety contracts.

______________________________________________________________________

## Pure Presentation & Read-Only View Snapshots

- **Pattern 6 — Game-Engine View Model Snapshot Invariant**:
  - The frame lifecycle enforces a strict barrier between simulation/systems
    (Phase 2) and rendering (Phase 3), keeping `app` and `ui` decoupled with
    zero `@import("ui")` in `src/app/`.
  - Prior to calling `ui.layout.renderFrame`, `src/viewer.zig`
    (`buildUiViewModel`) constructs `UiViewModel` (`src/ui/view_model.zig`)
    from `*const AppState` as a fully immutable snapshot struct containing
    const pointers and value types.
  - UI layout evaluation and vertex generation MUST NOT mutate `AppState` or push intents.
  - Any interactive element (e.g. palette search clicks, overlay close buttons) must have its hit testing and intent dispatch evaluated during Phase 2 system passes (`sysProcessPaletteInput`, `sysProcessUiInteractions`).

______________________________________________________________________

## Branchless Orthogonal Orientation & Compact Enum Math

- **Pattern 7 — Low-Bit Bounded Enum Transformations (`enum(u2)`)**:
  - When handling multi-state spatial container metadata (such as TIFF 6.0 / EXIF 2.32 orientation tags 1..8):
    1. **Collapse to 4 Orthogonal States**: A 2D viewer typically performs orthogonal 90° rotations. Collapse the 8 TIFF states down to a 4-state bounded enum:
       ```zig
       pub const Orientation = enum(u2) {
           normal = 0,
           rotate_90 = 1,
           rotate_180 = 2,
           rotate_270 = 3,

           pub fn fromTiff(val: u16) Orientation {
               return switch (val) {
                   6, 7 => .rotate_90,
                   3, 4 => .rotate_180,
                   8, 5 => .rotate_270,
                   else => .normal,
               };
           }

           /// Branchless arithmetic conversion to floating-point degrees: index * 90.0.
           pub inline fn toDegrees(self: Orientation) f32 {
               return @as(f32, @floatFromInt(@backingInt(self))) * 90.0;
           }

           /// Branchless bitwise check: odd indices (1 and 3) swap width and height.
           pub inline fn isDimensionSwapped(self: Orientation) bool {
               return (@backingInt(self) & 1) != 0;
           }
       };
       ```
    2. **Architectural Benefits**:
       - **Zero Branch Mispredictions**: `toDegrees()` executes as direct arithmetic (`val * 90.0`) without conditional jumps or branch prediction penalties.
       - **Single Bit Test**: `isDimensionSwapped()` executes as a single bitwise AND (`test reg, 1`).
       - **Cache Line Efficiency**: Shrinks orientation fields in cache slots from 4 bytes (`f32`) to 1 byte (`enum(u2)`).
       - **Type Safety**: Replaces floating-point inequality checks (`rot != 0.0`) with compile-time verified enum comparisons (`orientation != .normal`).

______________________________________________________________________

## Declarative Capabilities & Input Isolation

- **Pattern 8 — Unified Declarative Action Registry & 4-Way Projection**:
  - Capabilities are defined exclusively in `src/intents/actions.zig` via `ActionDef`:
    - `palette_action_items`: Projected for Command Palette rendering and scoring.
    - `flat_shortcuts`: Flattened mapping of `(Key, Modifiers) -> AppIntent`.
    - `action_cli_options`: CLI flags and aliases merged into `app_config.cli.options` (with dynamic column-width wrapping in `src/config/cli.zig`).
    - `ipc_commands`: UDS IPC control commands projected for `peng-msg`.
  - **Contextual Isolation & Readline Navigation**: High-frequency single-key shortcuts (e.g. `s` scale mode cycling, `Shift+S` filter cycling, `h`/`j`/`k`/`l` panning) must be context-isolated to avoid collisions during palette search or default viewing. Command Palette text entry supports standard Readline/Emacs navigation (`Ctrl+N`/`P`/`J`/`V`/`U`/`W`/`G`) and directory stepping (`Tab` / `Shift+Tab`).
  - **Display State & Resident Server Mode (`DisplayState` / `DisplayBackend`)**:
    - Visibility and backend are modeled as nested tagged unions: `DisplayState = union(enum) { visible: DisplayBackend, hidden: DisplayBackend }` and `DisplayBackend = union(enum) { headless, windowed: ActiveWindow }`. `ActiveWindow` is only constructed once a valid, GPU-claimed `sdl.Window` exists, eliminating boolean sentinels (`is_hidden`, `claimed`) and undefined handle fields.
    - Runtime window operations (`setFullscreen`, `setBordered`, `startTextInput`, `stopTextInput`) pattern-match on `DisplayBackend` or `display.visibleWindow()`, keeping the headless harness (`.headless`) a deterministic no-op.
    - In resident `--server` mode, closing the window (`hideWindow()`)
      transitions `display` to `.hidden`, unloads the active image cache
      (`clearCache`), resets `directory_arena` and `PaletteState.dir_arena` (via
      `shrinkToWarmCapacity`), cancels any pending `screenshot_mode`, and
      sleeps via `.wait_indefinite` in `computeFrameWaitStrategy` while keeping
      the warm GPU device, compiled pipelines, and `path_classifications`
      resident in memory. While `.hidden`, `sysExecuteIpcCommands` rejects
      view/navigation commands with `{"ok":false,"error":"WindowHidden"}` and
      only permits `IpcCommand.isAllowedWhenHidden()` (`open`, `preview`,
      `selections`, `clear_selections`, `close`, `quit`). Bare `open`
      (`AppIntent.open_window`) reveals the window and opens the File Picker
      palette when no media playlist is loaded.

______________________________________________________________________

## MultiArrayList SoA & Slice Snapshot Boundary

- **Pattern 9 — MultiArrayList SoA & View Model Snapshot Boundary**:
  - When domain collections maintain parallel attributes (such as `MediaEntry` (~56 bytes) and `Classification` (1 byte)), avoid separate parallel `ArrayList` collections:
    ```zig
    pub const MediaItem = struct {
        id: MediaId,
        entry: MediaEntry,
        classification: Classification = .unflagged,
    };
    pub const MediaItemList = std.MultiArrayList(MediaItem);
    pub const MediaItemSlice = std.MultiArrayList(MediaItem).Slice;
    ```
  - **Unified Allocation**: `MultiArrayList` manages both partitions in a single block allocation, preventing list length desynchronization and eliminating allocator fragmentation.
  - **L1 Cache Line Density**: Dense 1-byte arrays stream 64 items per 64-byte L1 cache line (a 64x density improvement over AoS structs), enabling sub-microsecond SIMD filtering across 10,000+ items.
  - **Read-Only Snapshot Slice**: Slicing via `nav.items.slice()` creates a zero-allocation `MediaItemSlice = std.MultiArrayList(MediaItem).Slice` passed into Phase 3 (Render) `UiViewModel`.
  - **Encapsulation & Triage Export**: State mutations go through encapsulating
    methods (`appendEntry`, `appendEntryWithId`, `clearEntries`,
    `trimExcessCapacity`, `clearAllClassifications`), UI view models access
    items via bounds-checked inline accessors (`getMediaEntry(idx)`,
    `getClassification(idx)`), persistent path flags are tracked in
    `StringArrayHashMapUnmanaged(Classification)` (keying `.archive_entry` items
    as `<archive_path>#<entry_name>`), live selections are streamed as JSON via
    `writeSelectionsJson` (`peng-msg ... selections`), and picked/rejected
    paths are exported to `stdout` on clean exit
    (`exportClassificationsToStdout`).
  - **O(1) `MediaId` Resolution & SIMD Fallback (`posOfId`)**:
    `NavigationState` maintains `first_seq_id` and `out_of_order_slot` hints
    in `appendEntryWithId` (committed only after all `try` steps succeed) and
    resets them in `clearEntries`/`trimExcessCapacity`. `posOfId` checks
    `out_of_order_slot`, then sequential (`delta = id -% first_seq_id`) and
    single-file shifted (`delta +| 1`) probes, before falling back to an
    8-wide `@Vector(8, u32)` SIMD scan (`raw_ids[i..][0..8].*`, `@bitCast` to
    `u8`, `@ctz(mask)`) and scalar tail.

______________________________________________________________________

## SIMD Vectorized Circular Navigation & Popcounting

- **Pattern 10 — 256-Bit SIMD Vectorized Circular Scanning & Boundary Guards**:
  - When scanning contiguous 1-byte arrays (`[]const Classification`) with portable `@Vector(32, u8)`:
    - **Forward Search (`findNextVisibleInRange`)**: Cast the vector comparison mask to `u32` (`@as(u32, @bitCast(matches))`) and call `@ctz(mask)` to find the lowest matching index in a single CPU cycle (`TZCNT`/`BSF`).
    - **Backward Search Underflow Guard (`findPrevVisibleInRange`)**:
      In reverse chunk loops (`while (cur >= 32)`), when index 0 is reached (`chunk_start == 0`), if the vector comparison finds no matches, immediately return `null`:
      ```zig
      if (chunk_start == 0) return null;
      cur -= 32;
      ```
      Never fall through to remainder scalar processing when the first 32 elements were already verified by SIMD to contain zero matches.
    - **Hardware Popcount (`countVisibleInRangeSimd`)**: Accumulate visible position and visible count using hardware `@popCount(@as(u32, @bitCast(matches)))`. Processes 10,000 image classifications in \<350 CPU cycles.

______________________________________________________________________

## Declarative Snackbar Feedback (`SnackbarState`)

- **Pattern 11 — Zero-Allocation Declarative Snackbar Rules (`src/state/snackbar.zig`)**:
  - `SnackbarState` (`enabled: bool`, `notification: SnackbarNotification`, `enabled_mask: u32`) formats notification messages into `ActiveNotification.message_buf: [128]u8` (`message_len: u8 = 0`, `timeout_ms: u64 = 0`) with zero heap allocations and triggers `.snackbar` fade animations on `AnimationState`.
  - `DEFAULT_SNACKBAR_RULES` declaratively maps `std.meta.Tag(AppIntent)` variants to `FormatFn` callbacks (`formatClassification`, `formatFilter`, `formatZoom`, `formatAdjustParam`, etc.).
  - **Action-Aware & Advance-Aware Classification Feedback**:
    When marking Reject in Default view filters out the active image and advances the cursor, never derive snackbar text by inspecting the new image's classification after the cursor has already advanced. Derive feedback directly from the executed intent and whether the cursor advanced:
    - Advanced away: `"Previous image flagged as rejected"`
    - Remained on screen: `"Flagged as Pick"` / `"Flagged as Reject"`
    - Action in 0-item filter: `"No image to classify"`

______________________________________________________________________

## Tagged Union Variance Control & Comptime Parameter Descriptors

- **Pattern 12 — Tagged Union Hierarchy & Single Source of Truth Metadata**:
  - When introducing multi-parameter adjustment suites (such as photographic
    sliders or audio DSP filters), avoid polluting root `AppIntent` with flat
    variants (`increase_brightness`, `decrease_brightness`, `set_highlights`).
  - Consolidate domain operations into a nested tagged union (`AdjustIntent`):
    ```zig
    pub const AdjustIntent = union(enum) {
        set: struct { param: EditParam, value: f32 },
        step: struct { param: EditParam, direction: StepDirection },
        batch_tone: struct {
            highlights: f32,
            shadows: f32,
            whites: f32,
            blacks: f32,
        },
        batch_color: struct {
            temperature: f32,
            tint: f32,
            vibrance: f32,
            saturation: f32,
        },
        batch_presence: struct {
            clarity: f32,
            texture: f32,
        },
        reset_param: EditParam,
        reset_all,
        toggle_compare,
        set_compare: bool,
    };
    ```
  - **Single Source of Truth Parameter Specification Table**:
    - Centralize parameter boundaries, defaults, step deltas, snap radii, and
      formatting kinds into a static comptime array
      (`specs: [EditParam.count]ParamSpec`).
    - Eliminate duplicated bounds checking, slider hit-testing logic, and
      formatting branches across IPC, UI layouts, and state stores.
    - Let UI widgets and IPC parsers query `intents.getSpec(param)` to
      clamp, snap, and format values consistently.
  - **Nested Prompt Palette Mode (`PaletteMode` / `ActivePaletteMode` /
    `PaletteLifecycle`)**:
    - Modal palette targets collapse single-line text/numeric dialogs into
      `PromptKind` (`go_to_image`, `slideshow_interval`,
      `edit_param: EditParam`), eliminating 13-arm `.set_brightness` ...
      `.set_texture` switches across `intents`, `palette`, `ui`, and `app`.
    - `PaletteState` tracks `lifecycle: PaletteLifecycle` (`.closed`,
      `.open: ActivePaletteMode`, `.closing: ActivePaletteMode`), making
      closed-and-closing states unrepresentable.
    - Opening any mode enters via `AppState.openPalette` /
      `openDirectoryPalette` (resetting stale state, setting `.open`, starting
      `.palette_reveal`, and enabling text input); in-place directory reload
      only applies when `openMode()` is already `.directory_navigator`. Both
      `.directory_navigator` entry listing (with `walk_up_if_empty`) and child
      folder counts run asynchronously off-thread via 2-stage
      `paletteScanWorker` under `dir_scan_generation` and `active_dir_scans`.
    - Confirming a slideshow interval pushes
      `AppIntent.start_slideshow_interval` so interval clamping and
      `NavigationState.slideshow` mutation stay inside `sysExecuteIntents`.
    - Format nested `.set_palette` literals with trailing commas on outer levels
      (no stacked `} } },` closing braces) so only leaf `.{ ... }` is inline.

______________________________________________________________________

## Application Startup & Overlapped Initialization Pattern

- **Pattern 13 — Overlapped I/O, Decode & Graphics Device Startup**:
  - Rather than initializing SDL, window, GPU device, and shaders serially before touching any media, peng overlaps CPU disk I/O and image decode with graphics setup:
    1. **Core SDL Subsystem Init (`gpu.graphics.initSdlCore` in `src/gpu/graphics.zig`)**: Initializes `SDL_INIT_VIDEO | SDL_INIT_EVENTS` (required by background workers for surface operations and thread wakeup via `context.wakeUpMainThread`) and consolidates `TTF_Init` upfront prior to state construction.
    2. **Pinned In-Place State & Early Media Ingestion
       (`AppGraphicsAndState.init` -> `state.openPath` / `readPipedStdin`)**:
       `AppGraphicsAndState.init(self: *AppGraphicsAndState, ...)` initializes
       `self.state` directly in-place at its permanent stack address before
       spawning workers (preventing by-value struct returns from invalidating
       worker pointers to `state.workers`, `state.cache.generation`, and
       `active_file_scans`). When given a direct single-image file path,
       `openPath` appends slot 0 and calls `spawnSlotDecode` to allocate a cache
       job ticket and spawn `decodeWorker` concurrently with `pathScanWorker`.
       When opening a directory or CBZ, spawns `pathScanWorker`. When piped from
       stdin, spawns `stdinWorker`.
    3. **Concurrent Main-Thread Window & GPU Setup**: While workers read file headers, extract EXIF data, and decompress pixels on background threads, the main thread performs window creation, display server negotiation (Wayland/X11 roundtrips), SDL3 GPU device creation (Vulkan / Metal), and shader/pipeline compilation.
    4. **GPU Intent (`gpu_enabled`) & Deferred Binding**: Initializes `state.gpu_enabled = true` so early decode workers know a GPU device will be present (avoiding redundant CPU format conversions and preserving raw surfaces for GPU compute unpack), while keeping `state.gpu_device = null` until all graphics pipelines succeed. If an intermediate setup step fails, `state.deinit()` cleans up worker threads and CPU caches without accessing unowned or destroyed GPU handles (use-after-free).
    5. **Latency-Hiding First Frame**: When `runMainLoop` starts Frame 1, background events in `workers.event_queue` are drained. If decode completed during graphics init, Frame 1 displays the loaded image immediately; if decode is still in flight (large RAW/TIFF), Frame 1 renders the loading state while `computeFrameWaitStrategy` ticks with 8ms polling until `wakeUpMainThread()` triggers the final GPU upload.
