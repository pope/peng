# Concurrency & Application Architecture Rules

## 1. State & View Model Split (`AppState` vs `ViewerState` vs `UiViewModel`)

- **`AppState` (Outer Engine & Hardware Container)**:
  - Defined in `src/app/state.zig` (`app.state.AppState`).
  - Owns hardware contexts (`display: DisplayState`, `gpu_device`,
    `gpu_enabled: bool`, `unpack_compute_pipeline`,
    `upload_staging: gpu.UploadStagingBuffer`), allocators (`allocator`),
    async I/O (`io`), texture slot cache (`cache: ImageCache`), worker manager
    (`workers: WorkerManager`), IPC command queue (`pending_ipc_commands`),
    deferred IPC selection and `wait_load` barrier streams
    (`pending_selection_streams`, `pending_wait_load_streams`), intent queue
    (`pending_intents`), event batch (`event_batch`), and embeds
    `viewer: ViewerState`.
  - All system pass functions in `src/app/systems/` accept `ctx: FrameContext`
    (`src/app/systems/context.zig`), which bundles `state: *AppState`,
    `frame_allocator: Allocator`, `input: ?FrameInput`, `delta_time_ms: f64`,
    and `now_ms: u64`.
- **`ViewerState` (Pure Visual & UI Data Model)**:
  - Defined in `src/state/viewer_state.zig` (`state.ViewerState`) and embedded
    at `AppState.viewer`. Lives 100% on the main thread.
  - Contains pure visual, controller, and UI state (`viewport`, `navigation`,
    `ui`, `stats`, `animations: AnimationState`,
    `image_transition: ImageTransition`, `pan_controller: PanController`,
    `zoom_controller: ZoomController`, `rotation_map`, `drag_state`,
    `mouse_inside`, `last_win_dims: LogicalDims`, `server_mode`, `running`).
  - **Purity Invariant**: `ViewerState` MUST contain **ZERO** GPU device
    pointers, **ZERO** worker thread pools, **ZERO** `std.Io` contexts,
    **ZERO** mutexes or concurrent queues, and **ZERO** raw
    `std.mem.Allocator` fields (`rotation_map` uses
    `std.StringHashMapUnmanaged(f32)`, and `PaletteState` is unmanaged—passing
    `allocator` explicitly to mutating and teardown methods—leaving only
    `navigation` holding CPU arenas).
    It must remain safe for headless unit testing without GPU, I/O, or worker
    setup.
- **`UiViewModel` (Read-Only Presentation Snapshot)**:
  - Defined in `src/ui/view_model.zig` (`ui.UiViewModel`).
  - Constructed in `src/viewer.zig`
    (`buildUiViewModel(*const AppState, now_ms)`) at the Phase 2 -> Phase 3
    boundary as an immutable snapshot with `*const` references, pre-computed
    strings (`window_title`), and value-copied metrics
    (`UiRenderMetrics.toSnapshot()`), keeping `app` and `ui` decoupled.
  - **Pure Phase 3 Presentation**: Phase 3 (`ui.layout.renderFrame`,
    `ui.renderer.buildRenderPacket`, and `gpu.pass.executeFrame`) is
    strictly read-only. Layout and render passes MUST NOT mutate
    `AppState`/`ViewerState`, change OS window state, or enqueue intents.

## 2. Linear Frame Pipeline, Intents & Capabilities Registry

- **Authoritative 3-Phase Frame Pipeline (`src/viewer.zig`)**:
  - **Phase 1: Ingestion**: `app.drainWorkerEvents` (`src/app/events.zig`) runs
    both before `computeFrameWaitStrategy` / `input.pollFrameInput` (forcing
    non-blocking `.poll` when pre-wait events are drained) and again
    immediately after `input.pollFrameInput` so background events arriving
    during `waitEventTimeout` are rendered on the same frame.
  - **Phase 2: Sequential Systems Pipeline (`runUpdatePhase`)**: Systems in
    `src/app/systems/` MUST NOT call other systems directly; they communicate
    solely via `AppState` fields or `state.pending_intents`:
    01. `sysUpdateAnimations(ctx)`: Ticks active SoA animation channels by
        `delta_time_ms`.
    02. `sysExecuteIpcCommands(ctx)`: Parses queued IPC commands ->
        `pending_intents`.
    03. `sysProcessPaletteInput(ctx)`: Handles palette text editing, selection,
        and click-outside dismissal -> `pending_intents`.
    04. `sysProcessInput(ctx, palette_closed_this_frame)`: Maps keyboard
        shortcuts and file drops -> `pending_intents`.
    05. `sysProcessUiInteractions(ctx, palette_closed_this_frame)`: Resolves
        pointer hover/clicks on overlay controls and edit sliders ->
        `pending_intents`.
    06. `sysUpdateViewport(ctx, palette_closed_this_frame)` &
        `sysUpdateSlideshow(ctx)`: Applies mouse/touch pan/zoom deltas, smooth
        `PanController`/`ZoomController` glide, and slideshow timers.
    07. `sysExecuteIntents(ctx)`: Single-pass batch execution of all queued
        `AppIntent` payloads (`src/app/systems/intents.zig`), declarative
        snackbar notifications (`src/state/snackbar.zig`), and post-intent IPC
        selection stream flushing (`defer self.flushPendingSelectionStreams()`).
    08. `sysSyncWindow(ctx)`: Synchronizes OS window title and display
        properties with the active image immediately following intent
        execution.
    09. `sysProcessAssetUploads(ctx)`: Handles EXIF orientation, paced
        CPU-to-GPU texture uploads, and 5s idle decay of oversized
        `UploadStagingBuffer` buffers (> 32 MiB)
        (`src/app/systems/asset_upload.zig`).
    10. `sysUpdateCache(ctx)`: Enforces VRAM budget, spawns decode workers,
        schedules settled neighbor preloading, and flushes satisfied IPC
        `wait_load` barrier streams
        (`defer state.flushPendingWaitLoadStreams()`).
    11. `sysSyncMetrics(ctx)`: Snapshots atomic worker counters, active image
        telemetry, and cache status into `state.viewer.stats` (`ViewerStats`).
  - **Phase 3: Presentation**: `src/viewer.zig` builds `UiViewModel` from
    `*const AppState`, evaluates immediate-mode `RectCut` UI layout
    (`UiDrawList`), and executes the 2-pass GPU renderer (`buildRenderPacket` ->
    `executeRenderPacket`).
- **Zero-Dependency Intent Queue (`AppIntent`)**:
  - UI controls, keyboard shortcuts, and IPC commands MUST push high-level
    `intents.AppIntent` variants (`src/intents/root.zig`) via
    `state.pushIntent(intent)` rather than mutating state inline.
  - **Drainage Safety Invariant (`defer self.clearIntents()`)**: In
    `sysExecuteIntents`, place `defer self.clearIntents();` immediately after
    the empty-queue check so an error in any handler still clears the queue and
    cannot trigger an infinite frame-over-frame error loop.
- **Unified Capabilities Declarative Registry (`src/intents/actions.zig`)**:
  - Declare all user-facing actions, keyboard shortcuts, Command Palette items,
    CLI flags, and IPC verbs centrally in `actions: [_]ActionDef`.
  - Compile-time projections (`palette_action_items`, `flat_shortcuts`,
    `action_cli_options`, `ipc_commands`) derive from `actions` and are verified
    by `test "actions registry projections"`.
- **Decoupled Input Package & Contextual Isolation**:
  - `src/input/` operates purely on `FrameInput` snapshots and emits
    `?AppIntent` with zero dependency on `AppState`.
  - Guard modal and spatial inputs by active context (`ctx == .viewer_zoomed` or
    active `PaletteMode`), and strip ASCII control characters (`< 32` and `127`)
    from raw text events.

## 3. Worker Concurrency, Cancellation & Demand-First Cache Gating

- **Startup Concurrency & Overlapped Graphics Initialization**:
  - `gpu.graphics.initSdlCore` initializes SDL core before in-place
    `AppGraphicsAndState.init` spawns early workers (`openPath` /
    `readPipedStdin`) with `gpu_enabled = true` and `gpu_device = null`.
  - Disk I/O, EXIF parsing, and decompression run on worker threads overlapped
    with main-thread window/GPU/shader initialization.
  - Background events queue in `workers.event_queue` and drain on Frame 1
    (see [systems-architecture.md][sys-arch] Pattern 13).
- **Main-Thread Exclusive GPU Access**:
  - All SDL GPU device calls, pipeline bindings, compute dispatches, and texture
    creations/releases MUST execute on the main thread inside Phase 2
    (`sysProcessAssetUploads` / `prepareCacheTextures`) and Phase 3.
  - Workers decode into CPU `sdl.Surface` handles and push `BackgroundEvent`
    items into `workers.event_queue` (`MpscQueue`), followed by
    `context.wakeUpMainThread()`. `drainWorkerEvents` (`src/app/events.zig`)
    clears `state.event_batch`, calls infallible `MpscQueue.drain(io, &batch)`
    to swap backing `ArrayList` headers in O(1) without allocation or copying,
    and stages CPU surfaces directly inside `CacheEntry.resident` tagged
    unions (`ThumbnailState.staged_cpu` for thumbnails, and
    `ResidentAsset.loaded_cpu: CpuAsset` or
    `ResidentAsset.promoting_gpu: PromotingGpuComponent` for full images) with
    zero GPU calls. Disown transferred pointers before `defer evt.deinit()`.
- **Non-Recursive Mutex Safety**:
  - Always unlock `std.Io.Mutex` via `defer mutex.unlock(io)` and never re-enter
    the same mutex on the same call stack.
- **`std.Io.Group` Lifecycle, Daemon Isolation & Cancellation**:
  - Never discard `io.async(...)` futures; spawn cancellable batch workers
    (image decodes, path scans, stdin reader) through `WorkerManager`
    (`state.workers.group.async(io, func, args)`).
  - Spawn long-lived daemon listeners (such as the IPC socket server) on
    dedicated threads (`std.Thread.spawn`) joined on shutdown (`deinit`), never
    counted in `WorkerManager.active_threads`.
  - Call `workers.drainAndQuiesce(io)` ONLY during application shutdown
    (`AppState.deinit`), never during runtime navigation or path opening.
  - Order worker exit `defer` blocks so `active_threads.fetchSub(1, .release)`
    executes *before* `context.wakeUpMainThread()` so the main thread observes
    updated idle counters upon waking.
  - In workers, never silence `readPositional` errors with `catch 0` without
    first checking `err == error.Canceled or cancel.isCanceled()`.
  - Check `if (cancel.isCanceled()) return;` (`args.cancelToken()`) before
    pushing intermediate events (`exif_orientation_parsed`,
    `dimensions_probed`) and after non-cancellable C decoder calls.
- **Worker Isolation, Telemetry (`ViewerStats`) & Envelope Pruning**:
  - Worker tasks (`decodeWorker`, `pathScanWorker`, `paletteScanWorker`,
    `previewWorker`, `stdinWorker`, `ipcServerWorkerTask`) MUST NOT import or
    accept `*AppState` or `*ViewerState`. Pass explicit argument structs
    (`DecodeArgs`, `PathScanArgs`, `PaletteScanArgs`, `PreviewWorkerArgs`,
    `StdinArgs`, `IpcServerArgs`) initialized directly without `= undefined`
    field placeholders.
  - Keep atomic counters (`active_threads`, `active_decode_threads`, `exiting`
    in `WorkerManager`; `active_file_scans` in `NavigationState`) for scheduling
    (`canSpawnDecode()`, `isBusy()`, `wait_load`), and snapshot them once per
    frame in `sysSyncMetrics` into `ViewerStats`.
  - Wrap generational worker payloads in `SlotBound(T)`
    (`resolve(&state.cache)`) or `Generational(T)` (`resolve(&generation)`)
    (`src/app/workers/events.zig`) and construct `CancellationToken`
    (`src/app/workers/context.zig`) via `args.cancelToken()` so stale epoch
    validation and cooperative cancellation are enforced at the type boundary.
    Cancellation is three-tiered: application shutdown (`exiting`), global
    cache generation invalidation, and per-slot atomic job epoch invalidation
    (`job_epochs: [MAX_DECODE_JOBS]std.atomic.Value(u32)`). All decode workers
    (overlapped `openPath` slot 0, `sysUpdateCache`, and pair promotion) spawn
    via `AppState.spawnSlotDecode`, acquiring a `cache.allocJob()` epoch ticket
    with `has_gpu_device = (gpu_device != null) or gpu_enabled`.
- **Two-Stage Header-First I/O, `DecodeMode` & Freedesktop Thumbnail Cache**:
  - Issue single `statFile` and `openFile` per worker pass and keep ALL header
    probing and EXIF orientation reads off the main thread
    (`executeIntent(.reset_rotation)` reads `entry.metadata.orientation`
    directly). Read 256KB Stage 1 header via `probe.readRangePositional` for
    metadata probing and thumbnail extraction before
    `DecodePayload.readRemaining()` executes Stage 2.
  - Select `DecodeMode` per slot in `sysUpdateCache`: `.speculative_thumb` for
    fast-scroll neighbors (exiting after Stage 1), `.active_fast_scroll` for
    active fast-scroll slots (returning early on thumbnail hit or falling
    through to Stage 2 full decode in the same open-file pass on miss), and
    `.full` when settled/idle or when `thumbnail == .not_available`.
  - Fall back to `$XDG_CACHE_HOME/thumbnails/` when no embedded preview is
    present, noting cached Freedesktop PNGs are pre-oriented upright.
  - Background thumbnail writes (`thumbWriterWorker`) are bounded to
    `MAX_QUEUED_THUMB_WRITES = 8` and yield in 5ms slices when decodes run
    (see [vram-preloading.md][vram-preload] §2).
- **Demand-First Priority Gating for Cache & GPU Uploads**:
  1. **Decode Gating (`sysUpdateCache`)**: Never spawn neighbor prefetch workers
     ($\\pm 1, \\pm 2$) while the active slot (`idx`) is still decoding or
     uploading.
  2. **Staged CPU Ingestion (`handleImageDecodedEvent` /
     `handleExifThumbnailEvent`)**:
     In Phase 1 (`src/app/events.zig`), stage decoded surfaces directly in
     `entry.resident` (`ThumbnailState.staged_cpu` when
     `gpu_enabled or gpu_device != null`, `ResidentAsset.loaded_cpu: CpuAsset`
     on `.none`/`.failed`/`.loaded_cpu`, and
     `ResidentAsset.promoting_gpu: PromotingGpuComponent` on
     `.loaded_gpu`/`.promoting_gpu` to keep the active texture resident during
     promotions while discarding any superseded `.staged_cpu` thumbnail when
     `image_decoded` arrives) with zero GPU calls and zero surface clones.
  3. **Unified Paced Uploads (`prepareCacheTextures`)**: In Phase 2
     (`src/app/systems/asset_upload.zig`), upload active
     `ThumbnailState.staged_cpu` via narrowed `uploadActivePendingThumb` (when
     not superseded by a loaded/staged full image), pace full image uploads
     (`.loaded_cpu` / `.promoting_gpu`) at a maximum rate of **1 texture per
     frame** (active slot first, then closest neighbor), transfer
     `surface` ownership directly to `enqueueDecodedThumbWrite` after
     `enforceVramBudget`, and invoke
     `upload_staging.maybeShrinkIdle(gpu_dev, ctx.now_ms, is_idle)` so
     staging buffers exceeding `WARM_STAGING_CAP_BYTES` (32 MiB) decay back to
     `.unallocated` after `IDLE_DECAY_MS` (5000 ms) of upload/decode
     inactivity.

[sys-arch]: ../skills/zig-gui-practices/references/systems-architecture.md
[vram-preload]: ../skills/zig-gui-practices/references/vram-preloading.md
