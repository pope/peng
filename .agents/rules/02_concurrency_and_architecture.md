# Concurrency & Application Architecture Rules

## 1. AppState vs. ViewerState Structural Split

- **`AppState` (Outer Engine & Hardware Container)**: Top-level application context defined in `src/app/state.zig` (exported as `app.state.AppState`). Owns hardware contexts (`gpu_device`, `unpack_compute_pipeline`), memory allocators (`allocator`), async I/O (`io`), texture slot cache map (`cache: CacheSlotMap`), worker task manager (`workers: WorkerManager`), pending IPC commands (`pending_ipc_commands`), intent queue (`pending_intents`), event batch (`event_batch`), and embeds `viewer: ViewerState`. Deinitialized via `state.deinit()`. All system pass functions in `src/app/systems/` accept `ctx: FrameContext` (which wraps `state: *AppState`, `frame_allocator`, `input`, `delta_time_ms`).
- **`ViewerState` (Pure Visual & UI Data Model)**: Defined in `src/state/viewer_state.zig` (exported as `state.ViewerState`) and embedded within `AppState.viewer`. Lives 100% on the main application thread. Contains pure visual/UI data (`viewport`, `navigation`, `ui`, `stats`, `rotation_map`, `display`, `drag_state`, `running`, `dirty`). Deinitialized via `viewer.deinit(allocator, io)`, which cleans up `navigation`, `ui`, `display` (`DisplayState.deinit(allocator)`), and `rotation_map` string keys.
- **Data Invariant**: `ViewerState` MUST contain **ZERO** hardware device pointers (`gpu_device`), **ZERO** task groups or thread pools (`workers`), **ZERO** memory allocators (`allocator`), **ZERO** I/O contexts (`io`), and **ZERO** concurrency primitives (`std.Io.Mutex`) or queues (`MpscQueue`). It is safe for layout calculation, UI rendering passes, and headless unit testing without concurrency overhead.

## 2. Main-Thread GPU Resource Restrictions

- SDL GPU device calls, pipeline binding, texture creation, and texture destruction MUST execute exclusively on the main application thread.
- Worker threads MUST decode pixels into CPU surfaces (`sdl.Surface`) and send surfaces to the main thread via `workers.event_queue` for GPU upload.

## 3. Mutex Safety & Deadlock Prevention

- All mutex locks (`std.Io.Mutex`) MUST be released via `defer mutex.unlock(io)`.
- Never acquire a mutex twice on the same thread sequence—`std.Io.Mutex` is non-recursive and will deadlock on re-entry.

## 4. `std.Io.Group` Task Spawning & Native Cancellation

- **Avoid Orphaned `io.async` Future Leaks**: Never discard the return value of `io.async` (`_ = io.async(...)`). `io.async` allocates a `Future` on the heap that leaks if not explicitly awaited or canceled.
- **Use `std.Io.Group`**: Spawn background tasks via `WorkerManager` (`state.workers.group.async(io, func, args)`). Tasks in a `Group` automatically release their task memory when they return.
- **Native Task Cancellation**: Use `state.workers.drainAndQuiesce(io)` or `state.workers.group.cancel(io)` to cancel active background tasks instead of polling manual atomic generation counters.
- **`error.Canceled` & C-Call Checks**: Handle `error.Canceled` from `std.Io` calls (`openDir`, `iterate`, `readPositional`, `takeDelimiter`). After non-cancellable external C calls (e.g. SDL image loading), check `io.isCanceled()` before pushing results to event queues.

## 5. MpscQueue Transport & Event Loop Wakeup

- Background workers communicate with the main loop by pushing `events.BackgroundEvent` payloads into `AppState.workers.event_queue` (`MpscQueue`).
- Producers MUST invoke `context.wakeUpMainThread()` after pushing events into the queue.
- Disown or null pointer payloads inside `BackgroundEvent` prior to `defer evt.deinit()` execution.

## 6. Zero-Dependency Intent Queue (`AppIntent`) & Co-Located Actions

- UI buttons, menu items, keyboard shortcuts, and IPC socket commands MUST map directly to high-level `intents.AppIntent` payloads from the standalone `intents` module (`src/intents/root.zig`).
- UI inputs MUST NOT execute state mutations inline; they push `AppIntent` values into `AppState.pending_intents` via `state.pushIntent(intent)`.
- `pending_intents` is an allocation-free `std.ArrayList(AppIntent)` cleared frame-over-frame using `.clearRetainingCapacity()`.
- Intent execution logic is co-located inside `src/app/systems/intents.zig` (`executeIntent`), operating directly against domain sub-states (`vp`, `nav`, `ui`) without needing forwarding wrappers on `AppState`.

## 7. Decoupled Data-Driven Input & System Passes

- **Pure Input Package (`src/input/`)**: Input event polling (`pollFrameInput`) and shortcut mapping (`mapKeyToAction`) operate exclusively on immutable data snapshots (`FrameInput`) and emit pure intent variants (`?AppIntent`). The `src/input/` package MUST have zero dependencies on `AppState`.
- **System Passes (`src/app/systems/`)**: Application input processing is performed via dedicated system passes (`sysProcessInput`, `sysProcessPaletteInput`). These system passes take `FrameInput` data snapshots and map active inputs into `AppIntent` variants dispatched through `sysExecuteIntents`.

## 8. Data-Driven State & Packed Struct Overlay Flags (`OverlayFlags`)

- Model mutually exclusive sub-states using `union(enum)` tagged unions (`SlideshowMode`, `DisplayState`, `CacheStatus`).
- Model UI overlay visibility toggles as packed byte bitfield structs (`OverlayFlags = packed struct(u8)`).
- Compose image cache state via explicit component structs (`CpuSurfaceComponent`, `GpuTextureComponent`, `ThumbComponent`).

## 9. Pure System Passes & Top-Level Linear Engine Pipeline (`src/app/systems/`)

- Procedural tick logic, socket command handling, input sampling, slideshow timers, asset uploads, and telemetry MUST be extracted into pure system pass functions accepting `ctx: FrameContext` in `src/app/systems/`, while worker event queue draining is handled by `app.drainWorkerEvents` in `src/app/events.zig`:
  - `drainWorkerEvents`: Drains worker thread event queues (`state.workers.event_queue`).
  - `sysExecuteIpcCommands`: Parses and dispatches socket commands (`state.pending_ipc_commands`).
  - `sysProcessInput`: Maps keyboard input to intents (`state.pending_intents`).
  - `sysExecuteIntents`: Drains queued `AppIntent` payloads (`state.pending_intents`, executed twice per frame tick: after keyboard input and after palette/slideshow updates).
  - `sysProcessPaletteInput`: Manages command palette query text, list navigation, and click-outside dismissal.
  - `sysUpdateViewport`: Handles mouse drag deltas and mouse-wheel zoom-at-cursor calculations.
  - `sysUpdateSlideshow`: Manages slideshow timer ticks.
  - `sysProcessAssetUploads`: Handles EXIF orientation and CPU-to-GPU texture uploads.
  - `sysUpdateCache`: Manages cache slot eviction, spawns decode workers, and performs idle neighbor preloading.
  - `sysSyncMetrics`: Copies atomic worker counters (`state.workers`), active image GPU telemetry, and cache status into `ViewerStats` (`state.viewer.stats`) once per frame tick.
- Systems MUST NOT invoke other systems nested inside them.
- The main frame update in `src/viewer.zig` (`updateFrame` / `runUpdatePhase`) MUST follow the strict top-level unnested engine pipeline:
  1. Worker Event Ingestion (`drainWorkerEvents` in `updateFrame`)
  2. Input Polling (`pollFrameInput` in `updateFrame`)
  3. `runUpdatePhase` Systems Pipeline:
     a. `sysExecuteIpcCommands(ctx)`
     b. `sysProcessPaletteInput(ctx)` (typing, item selection, outside clicks -> intents)
     c. `sysProcessInput(ctx)` (keyboard shortcuts, file drops -> intents)
     d. `sysProcessUiInteractions(ctx)` (UI close buttons -> intents)
     e. `sysUpdateViewport(ctx, palette_closed_this_frame)` & `sysUpdateSlideshow(ctx)`
     f. `sysSyncWindow(ctx)` (window title & display sync)
     g. `sysExecuteIntents(ctx)` (single-pass execution of all enqueued intents)
     h. `sysProcessAssetUploads(ctx)`
     i. `sysUpdateCache(ctx)`
     j. `sysSyncMetrics(ctx)`
  4. Clay UI Layout & Pointer Updates
  5. GPU Execution Pass & Frame Presentation

## 10. Worker Thread Isolation, Telemetry (`ViewerStats`), & Cache Epochs

- **Worker Thread Isolation**: Background worker tasks (`decodeWorker`, `pathScanWorker`, `stdinWorker`, `ipcServerWorkerTask`) MUST NOT import or receive `*AppState` or `*ViewerState`. They accept explicit parameter structs (`DecodeArgs`, `PathScanArgs`, `StdinArgs`, `IpcServerArgs`) containing `workers: *WorkerManager`, `allocator: std.mem.Allocator`, and `io: std.Io`.
- **Explicit Argument Initialization**: Instantiation of argument structs on the caller side MUST populate explicit field values directly. Avoid setting struct fields to `= undefined` placeholders before passing them into spawner functions.
- **Telemetry Consolidation (`ViewerStats`)**: Separate UI/Stats telemetry from core business logic. Keep atomic counters (`active_threads`, `active_decode_threads`, `exiting`) in `WorkerManager` for control flow throttling (`canSpawnDecode()`, `isBusy()`). Once per frame, `sysSyncMetrics` snapshots live atomics and active image metrics into plain `usize`/`bool` fields on `state.viewer.stats` (`ViewerStats`) for UI rendering ("Stats for Nerds") without reading atomics during layout evaluation.
- **Cache Epoch Versioning**: `CacheSlotMap` (`state.cache`) owns the epoch generation counter (`generation: usize`), incremented via `state.cache.advanceGeneration()` on navigation/directory resets (`resetNavigation`). Incoming worker background event payloads validate against `state.cache.getGeneration()` before modifying `CacheSlotMap` entries.

## 11. Single-Pass I/O Header & Metadata Consolidation in Workers

Worker tasks performing file inspection and decoding MUST consolidate file I/O operations:

1. **Single File Stat**: Issue `statFile` once at the top of the worker to retrieve `size_bytes`.
2. **Single File Open**: Open `std.Io.Dir.openFile` once for the duration of the worker task pass.
3. **Single Header Read**: Issue `file.readPositional(io, &slices, 0)` once to populate a 64KB stack buffer (`header_buf`).
4. **In-Memory Zero-Copy Operations**: Pass `header_buf[0..n]` in-memory to all metadata parsers (`exif.parseExifOrientation`, `image.detectMimeType`, `exif.readJpegDimensions`, `exif.extractJpegThumbnail`). Never open or read the file multiple times per worker pass.

## 12. Read-Only View Model Snapshot (`UiViewModel`) & Pure Render Invariant

- **Immutable Frame Snapshot**: At the end of Phase 2 (`runUpdatePhase`), construct an immutable, read-only snapshot struct `UiViewModel` (`src/state/types.zig`).
- **No Mutable State in View Model**: `UiViewModel` MUST NOT contain mutable pointers to `AppState`, `ViewerState`, `metrics`, `display`, or `pending_intents`. All metrics must be snapshotted (`UiRenderMetrics.toSnapshot()`), strings pre-computed (`window_title`), and state references typed as `*const`.
- **Pure Phase 3 Presentation**: Phase 3 (`renderFrame`) operates strictly as a read-only presentation pass. Layout evaluation (Clay) and vertex extraction MUST NOT mutate application state, dispatch OS/window title changes, or enqueue intents inline. All interactive widget clicks (such as close buttons and palette item selection) are detected and mapped to `AppIntent` payloads during Phase 2 systems passes before layout drawing.

## 13. Demand-First Priority Gating for Cache & GPU Uploads

To guarantee minimum Time-to-First-Frame (TTFF) and eliminate main-thread stutter when viewing high-resolution images:

1. **Decode Worker Gating (`sysUpdateCache`)**:

   - Never dispatch background decode workers for neighbor prefetch slots ($\\pm 1, \\pm 2$) while the active image (`idx`) is still decoding or uploading.
   - Dedicate 100% of available background worker threads, CPU L3 cache, memory bus bandwidth, and file I/O to the active navigation target.
   - Only initiate neighbor prefetch passes once the active image has reached `.loaded_gpu` (or `.loaded_cpu` in headless mode, or `.failed`).

2. **GPU Upload Prioritization (`handleImageDecodedEvent`)**:

   - Never issue direct GPU texture uploads (`uploadSurfaceToGpu`) or trigger hardware mipmap generation for neighbor slots while the active image is still in flight.
   - If a neighbor finishes decoding while the active image is still loading, save the neighbor as `.loaded_cpu` in host RAM and retain the CPU surface.

3. **Paced Deferred Uploads (`prepareCacheTextures`)**:

   - If the active image is `.loaded_cpu`, prioritize uploading it first before any neighbors.
   - Once the active image is securely resident on the GPU, trickle queued `.loaded_cpu` neighbor surfaces into VRAM at a maximum rate of **1 texture per frame** to eliminate multi-image frame hitching.
