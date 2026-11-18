---
trigger: glob
globs: '**/src/app/**, **/src/cache/**, **/src/intents/**, **/src/input/**, **/src/ipc/**, **/src/state/**, **/src/viewer.zig, **/src/main.zig'
description: AppState/ViewerState/UiViewModel split, 3-phase frame pipeline, AppIntent queue, std.Io.Group workers, cancellation, and cache/upload priority gating.
---

# Concurrency & Application Architecture Rules

## 1. State & View Model Split

- **`AppState` (`src/app/state.zig`)**: Owns hardware (`display`, `gpu_device`,
  `gpu_enabled`, `unpack_compute_pipeline`, `upload_staging`), `allocator`, `io`,
  `cache: ImageCache`, `workers: WorkerManager`, `frame_metrics: FrameMetrics`,
  IPC queues/streams, `pending_intents`, `event_batch`, and embeds
  `viewer: ViewerState`.
- **`ViewerState` (`src/state/viewer_state.zig`)**: 100% main-thread visual/UI
  model. **Purity Invariant**: MUST hold **ZERO** GPU handles, worker pools,
  `std.Io`, mutexes/queues, or stored `std.mem.Allocator` fields (`rotation_map`
  is unmanaged and `PaletteState` uses explicit `allocator` params for its
  non-arena lists/searcher, while `navigation` and `palette` (`dir_items`
  backing buffer + strings in `dir_arena`) own bounded CPU arenas).
- **`UiViewModel` (`src/ui/view_model.zig`)**: Immutable snapshot built in
  `src/viewer.zig`
  (`buildUiViewModel(*const AppState, *const RenderResources, now_ms)`) at the
  Phase 2 -> Phase 3 boundary. Phase 3 (`renderFrame` -> `buildRenderPacket` ->
  `executeFrame`) is strictly read-only (never mutates state, window, or intents).

## 2. 3-Phase Frame Pipeline & Intent Registry

- **Phase 1 — Ingestion (`src/viewer.zig`, `src/app/events.zig`,
  `src/input/polling.zig`)**:
  - `drainWorkerEvents(app_state, now_ms)` runs before
    `computeFrameWaitStrategy`/`pollFrameInput` (using `pre_wait_ms` derived
    from `pre_ingest_start_ns / std.time.ns_per_ms` and forcing `.poll` if
    events were drained) and again right after `pollFrameInput` (using
    `input.now_ms`).
  - `pollFrameInput` samples `poll_end_ns = sdl.timer.getTicksNs()` once to
    derive `FrameInput.now_ms` (`poll_end_ns / std.time.ns_per_ms`) and
    records active CPU time into `FrameInput.poll_cpu_ms`, subtracting ONLY
    blocking OS event-wait sleep (`waitEventTimeout`/`waitEvent` when
    `!pre_wait_terminated`) with `-|`.
  - Uses infallible O(1) `MpscQueue.drain(io, &event_batch)` swap and stages CPU
    surfaces into `ThumbnailState.staged_cpu` and `ResidentAsset.loaded_cpu` /
    `.promoting_gpu` with **zero GPU calls** (disowning transferred pointers
    before `defer evt.deinit()`).
- **Phase 2 — Sequential Systems (`runUpdatePhase` in `src/app/systems/root.zig`)**:
  - Returns `!UpdatePhaseTimings` splitting Phase 2a (`intents_ms`,
    `sysSyncWindowVisibility` through `sysExecuteIntents`) and Phase 2b
    (`sync_ms`, `sysSyncWindow` through `sysUpdateCache` and settle).
  - Systems accept `ctx: FrameContext` and **MUST NOT** call other systems
    directly (communicating solely via `AppState` or `pending_intents`):
    `sysSyncWindowVisibility` $\\to$ `sysUpdateAnimations` $\\to$
    `sysExecuteIpcCommands` $\\to$ `sysProcessPaletteInput` $\\to$
    `sysProcessInput` $\\to$ `sysProcessUiInteractions` $\\to$
    `sysUpdateViewport` & `sysUpdateSlideshow` $\\to$
    `sysExecuteIntents` (`defer self.clearIntents()` right after empty check;
    `defer self.flushPendingSelectionStreams()`) $\\to$
    `sysSyncWindow` $\\to$ `sysProcessAssetUploads` $\\to$
    `sysUpdateCache` (`defer state.flushPendingWaitLoadStreams()`).
  - Complete visible rendered frames in `updateFrame` record `{ ingest_ms,
    intents_ms, sync_ms, render_ms }` into `app_state.frame_metrics` (reset on
    `hideWindow` and `.hidden` without recording partial/suspended frames).
- **Two-Clock Rule (Simulation `now_ms` vs. Profiling Stopwatches)**:
  - **Simulation / Logical Time (`now_ms: u64`)**: All animation, timeout,
    cadence, and `inflight` timestamp logic threads explicit `now_ms: u64`
    from `updateFrame` (`pre_wait_ms`, `input.now_ms` -> `FrameContext.now_ms`,
    `buildUiViewModel(..., input.now_ms)`), `drainWorkerEvents(state, now_ms)`,
    and `openPath(path, now_ms)` / `reloadPath(path, now_ms)`. Never call
    `sdl.timer.getTicks()` ad-hoc inside `src/app/`, `src/input/`,
    `src/state/`, `src/ui/`, or `src/viewer.zig` (only `src/main.zig` calls
    it at one-time CLI cold-start and loop `last_time` init).
  - **Sub-Millisecond Profiling Stopwatches**: Use
    `std.Io.Clock.awake.now(io)` in `io`-bearing pure/worker packages
    (`probe`, `vfs`, `app/workers`), and `sdl.timer.getTicksNs()` in
    `io`-free SDL/GPU/frame-loop packages (`input`, `cache`, `gpu`,
    `app/systems/root.zig`, `viewer.zig`).
- **Intentional Pipeline Trade-Offs (Preserve)**:
  1. *Pre-Render Sync*: `sysProcessAssetUploads` and `sysUpdateCache` run right
     *before* `renderFrame` (not after) so staged CPU surfaces/thumbnails promote
     to GPU and display on the **same frame** with 0-frame lag.
  2. *Data-Plane vs Control-Plane Events*: Only `ipc_command` events push
     `AppIntent`s; decoded `sdl.Surface` and scan payloads stage directly onto
     CPU state in `drainWorkerEvents` so `AppIntent` stays pure value data.
  3. *Startup & Discrete Scan Overlap*: Continuous decodes dispatch via
     `sysUpdateCache`, while `openPathInternal` / `loadPaletteDirectory`
     (2-stage `paletteScanWorker` after zero-I/O `beginDirectoryLoad`) / IPC
     `preview` & `precache` launch one-shot workers directly on transition to
     hide cold-start window/Vulkan init latency.
- **Intents, Registry & Input Isolation**:
  - All UI, keyboard, and IPC actions enqueue `intents.AppIntent` via
    `pushIntent` rather than mutating state inline.
  - Declare user capabilities centrally in `src/intents/actions.zig` (`ActionDef`
    projecting `palette_action_items`, `flat_shortcuts`, `action_cli_options`,
    `ipc_commands`).
  - `src/input/` maps `FrameInput` -> `?AppIntent` with zero `AppState`
    dependency, guarding shortcuts by context and stripping control chars
    (`< 32`, `127`) from text events.

## 3. Workers, Cancellation & Demand-First Gating

- **Main-Thread GPU Exclusivity & Mutex Safety**:
  - Execute all SDL GPU calls exclusively on the main thread (Phase 2
    `sysProcessAssetUploads` and Phase 3). Unlock `std.Io.Mutex` via `defer` and
    never re-enter on the same stack.
- **`std.Io.Group` Lifecycle & Daemon Separation**:
  - Spawn cancellable batch jobs via `workers.group.async(io, ...)` (never
    discard futures); run long-lived listeners (IPC server) on dedicated
    `std.Thread.spawn` threads excluded from `active_threads`.
  - Call `workers.drainAndQuiesce(io)` **ONLY** in `AppState.deinit`.
  - In worker `defer` blocks, `fetchSub` `active_threads` *before*
    `wakeUpMainThread()`. Check `err == error.Canceled or cancel.isCanceled()`
    before `catch` fallbacks, before intermediate events, and after C decoders.
- **Worker Isolation & 3-Tier Epoch Cancellation**:
  - Workers MUST NOT import/accept `*AppState` or `*ViewerState`. Wrap results in
    `SlotBound(T)` or `Generational(T)` (`src/app/workers/events.zig`) and check
    `args.cancelToken()` across `exiting`, `cache.generation`, and per-slot
    `job_epochs`. Spawn all slot decodes via `AppState.spawnSlotDecode`
    (`cache.allocJob()`, `has_gpu_device = (gpu_device != null) or gpu_enabled`).
- **Async Stage-1 Probing (`DecodeMode`) & Priority Gating (`DecodePriority`)**:
  - Keep 100% of file header/dimension/EXIF orientation probing off the render
    thread (`reset_rotation` reads `entry.metadata.orientation`): `decodeWorker`
    reads a 256 KB Stage-1 slice (`openStagedFile`) before `readRemaining()`.
  - `DecodeMode`: `.speculative_thumb` (fast-scroll neighbor, exits after Stage
    1), `.active_fast_scroll` (exits on thumb hit or falls through to Stage 2 in
    the same open-file pass on miss), `.full` (settled or `thumbnail == .not_available`).
    Treat `.staged_cpu` alongside `.loaded` in `is_active_thumb_ready` and
    `skip_active` to prevent duplicate fast-scroll spawns.
  - Gate `sysUpdateCache` neighbor prefetches until `cur_id` is ready, and
    dispatch via `WorkerManager.canSpawnDecode(priority)` (`DecodePriority`:
    `.foreground` `min(12, base + 2)` for `cur_id`, `.promotion` `base` for
    `checkPairPromotion`, `.background` `max(1, base - 1)` for neighbors).
  - In `prepareCacheTextures` (`src/app/systems/asset_upload.zig`), upload active
    `ThumbnailState.staged_cpu` first, pace full-image uploads (`.loaded_cpu` /
    `.promoting_gpu`) at **1 texture/frame** (active first, then closest
    neighbor), transfer `surface` zero-copy to `enqueueDecodedThumbWrite`
    (`MAX_QUEUED_THUMB_WRITES = 8`, yielding when decodes run), and run
    `upload_staging.maybeShrinkIdle`.
  - `loadPaletteDirectory` dispatches the 2-stage `paletteScanWorker`
    (Stage 1 `.palette_dir_loaded` with optional `walk_up_if_empty` and O(1)
    `ArenaAllocator` handoff via `applyLoadedDirectory`; Stage 2
    `.palette_folder_count`), gated by `dir_scan_generation` and tracked via
    `active_dir_scans` for `isWaitLoadReady`.

*(Deep recipes: [systems-architecture.md](../skills/zig-gui-practices/references/systems-architecture.md),
[vram-preloading.md](../skills/zig-gui-practices/references/vram-preloading.md))*
