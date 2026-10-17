# Concurrency & Application Architecture Rules

## 1. State & View Model Split (`AppState` vs `ViewerState` vs `UiViewModel`)

- **`AppState` (Outer Engine & Hardware Container)**:
  - Defined in `src/app/state.zig` (`app.state.AppState`).
  - Owns hardware contexts (`gpu_device`, `unpack_compute_pipeline`,
    `upload_staging: image.UploadStagingBuffer`, `ipc_server: ?*IpcServer`),
    allocators (`allocator`), async I/O (`io`), texture slot cache
    (`cache: CacheSlotMap`), worker manager (`workers: WorkerManager`), IPC
    command queue (`pending_ipc_commands`), intent queue (`pending_intents`),
    event batch (`event_batch`), and embeds `viewer: ViewerState`.
  - All system pass functions in `src/app/systems/` accept `ctx: FrameContext`
    (`src/app/systems/context.zig`), which bundles `state: *AppState`,
    `frame_allocator`, `input: FrameInput`, and `delta_time_ms: f32`.
- **`ViewerState` (Pure Visual & UI Data Model)**:
  - Defined in `src/state/viewer_state.zig` (`state.ViewerState`) and embedded
    at `AppState.viewer`. Lives 100% on the main thread.
  - Contains pure visual, controller, and UI state (`viewport`, `navigation`,
    `ui`, `stats`, `animations: AnimationState`,
    `image_transition: ImageTransition`, `pan_controller: PanController`,
    `zoom_controller: ZoomController`, `rotation_map`, `display`, `drag_state`,
    `mouse_inside`, `last_win_w`, `last_win_h`, `running`).
  - **Purity Invariant**: `ViewerState` MUST contain **ZERO** GPU device
    pointers, **ZERO** worker thread pools, **ZERO** `std.Io` contexts, and
    **ZERO** mutexes or concurrent queues (only CPU memory allocators/arenas for
    its self-contained `navigation`, `rotation_map`, and `palette` sub-states).
    It must remain safe for headless unit testing without GPU, I/O, or worker
    setup.
- **`UiViewModel` (Read-Only Presentation Snapshot)**:
  - Defined in `src/state/view_model.zig` (`state.UiViewModel`).
  - Constructed at the end of Phase 2 (`runUpdatePhase`) as an immutable
    snapshot with `*const` references, pre-computed strings (`window_title`),
    and value-copied metrics (`UiRenderMetrics.toSnapshot()`).
  - **Pure Phase 3 Presentation**: Phase 3 (`ui.layout.renderFrame` and
    `ui.renderer.renderClayCommands`) is strictly read-only. Layout and render
    passes MUST NOT mutate `AppState`/`ViewerState`, change OS window state, or
    enqueue intents.

## 2. Linear Frame Pipeline, Intents & Capabilities Registry

- **Authoritative 3-Phase Frame Pipeline (`src/viewer.zig`)**:
  - **Phase 1: Ingestion**: `app.drainWorkerEvents` (`src/app/events.zig`) and
    `input.pollFrameInput`.
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
    05. `sysProcessUiInteractions(ctx)`: Resolves pointer hover/clicks on
        overlay controls and edit sliders -> `pending_intents`.
    06. `sysUpdateViewport(ctx, palette_closed_this_frame)` &
        `sysUpdateSlideshow(ctx)`: Applies mouse/touch pan/zoom deltas, smooth
        `PanController`/`ZoomController` glide, and slideshow timers.
    07. `sysSyncWindow(ctx)`: Synchronizes OS window title and fullscreen/border
        state.
    08. `sysExecuteIntents(ctx)`: Single-pass batch execution of all queued
        `AppIntent` payloads (`src/app/systems/intents.zig`) and declarative
        snackbar notifications (`src/state/snackbar.zig`).
    09. `sysProcessAssetUploads(ctx)`: Handles EXIF orientation and paced
        CPU-to-GPU texture uploads.
    10. `sysUpdateCache(ctx)`: Enforces VRAM budget, spawns decode workers, and
        schedules settled neighbor preloading.
    11. `sysSyncMetrics(ctx)`: Snapshots atomic worker counters, active image
        telemetry, and cache status into `state.viewer.stats` (`ViewerStats`).
  - **Phase 3: Presentation**: Builds `UiViewModel`, evaluates Clay layout, and
    executes the 2-pass GPU renderer (`buildRenderPacket` ->
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

- **Main-Thread Exclusive GPU Access**:
  - All SDL GPU device calls, pipeline bindings, compute dispatches, and texture
    creations/releases MUST execute on the main thread.
  - Workers decode into CPU `sdl.Surface` handles and push `BackgroundEvent`
    items into `workers.event_queue` (`MpscQueue`), followed by
    `context.wakeUpMainThread()`. Disown transferred pointers before
    `defer evt.deinit()`.
- **Non-Recursive Mutex Safety**:
  - Always unlock `std.Io.Mutex` via `defer mutex.unlock(io)` and never re-enter
    the same mutex on the same call stack.
- **`std.Io.Group` Lifecycle, Daemon Isolation & Cancellation**:
  - Never discard `io.async(...)` futures; spawn cancellable batch workers
    (image decodes, path scans, stdin reader) through `WorkerManager`
    (`state.workers.group.async(io, func, args)`).
  - Spawn long-lived daemon listeners (such as the IPC socket server) on
    dedicated detached threads (`std.Thread.spawn`), never on the cancellable
    `WorkerManager.group`.
  - Call `workers.drainAndQuiesce(io)` ONLY during application shutdown
    (`AppState.deinit`), never during runtime navigation or path opening.
  - In workers, never silence `readPositional` errors with `catch 0` without
    first checking `err == error.Canceled or workers.exiting.load(.acquire)`.
  - Check `if (isStale(workers, args, key)) return;` before pushing intermediate
    events (`exif_orientation_parsed`, `dimensions_probed`) and after
    non-cancellable C decoder calls (`io.isCanceled()`).
- **Worker Isolation, Telemetry (`ViewerStats`) & Epoch Pruning**:
  - Worker tasks (`decodeWorker`, `pathScanWorker`, `stdinWorker`,
    `ipcServerWorkerTask`) MUST NOT import or accept `*AppState` or
    `*ViewerState`. Pass explicit argument structs (`DecodeArgs`,
    `PathScanArgs`, `StdinArgs`, `IpcServerArgs`) initialized directly without
    `= undefined` field placeholders.
  - Keep atomic counters (`active_threads`, `active_decode_threads`, `exiting`)
    in `WorkerManager` for scheduling (`canSpawnDecode()`, `isBusy()`), and
    snapshot them once per frame in `sysSyncMetrics` into `ViewerStats`.
  - Subsystems with generational invalidation (`CacheSlotMap.generation`,
    `PaletteState.dir_scan_generation`) increment `std.atomic.Value(usize)` with
    `.release` ordering on the main thread. Workers observe
    `current_generation: *const std.atomic.Value(usize)` with `.acquire`
    ordering at coarse checkpoints (task entry, archive/directory step, before
    surface decode, before pixel conversion) and `return` early on mismatch.
- **Single-Pass I/O Consolidation in Workers**:
  - Issue `statFile` once and `openFile` once per worker pass.
  - For RAW files (`decodeRawFile`), read a single **256KB** stack header buffer
    and extract embedded previews via positional reads; for fast scrolling
    (`thumb_only = true`), read at most **128KB**; for settled standard raster
    decodes, read into a task-scoped buffer via `readSliceAll` and run header
    probes, thumbnail slicing, and `Surface.loadConstMemOpt` in memory.
- **Demand-First Priority Gating for Cache & GPU Uploads**:
  1. **Decode Gating (`sysUpdateCache`)**: Never spawn neighbor prefetch workers
     ($\\pm 1, \\pm 2$) while the active slot (`idx`) is still decoding or
     uploading.
  2. **Upload Gating (`handleImageDecodedEvent`)**: While the active image is in
     flight, store completed neighbor decodes as `.loaded_cpu` in host RAM
     rather than uploading to the GPU immediately.
  3. **Paced Trickle Uploads (`prepareCacheTextures`)**: Upload the active image
     first; once it is `.loaded_gpu`, upload queued `.loaded_cpu` neighbors at a
     maximum rate of **1 texture per frame**.
