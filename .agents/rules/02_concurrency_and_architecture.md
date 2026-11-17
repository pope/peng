---
trigger: glob
globs: '**/src/app/**, **/src/cache/**, **/src/intents/**, **/src/input/**, **/src/ipc/**, **/src/state/**, **/src/viewer.zig, **/src/main.zig'
description: AppState/ViewerState/UiViewModel split, 3-phase frame pipeline, AppIntent queue, std.Io.Group workers, cancellation, and cache/upload priority gating.
---

# Concurrency & Application Architecture Rules

## 1. State & View Model Split

- **`AppState` (`src/app/state.zig`)**: Owns hardware (`display`, `gpu_device`,
  `gpu_enabled`, `unpack_compute_pipeline`, `upload_staging`), `allocator`, `io`,
  `cache: ImageCache`, `workers: WorkerManager`, IPC queues/streams,
  `pending_intents`, `event_batch`, and embeds `viewer: ViewerState`.
- **`ViewerState` (`src/state/viewer_state.zig`)**: 100% main-thread visual/UI
  model. **Purity Invariant**: MUST hold **ZERO** GPU handles, worker pools,
  `std.Io`, mutexes/queues, or stored `std.mem.Allocator` fields (`rotation_map`
  and `PaletteState` are unmanaged; only `navigation` owns bounded CPU arenas).
- **`UiViewModel` (`src/ui/view_model.zig`)**: Immutable snapshot built in
  `src/viewer.zig` (`buildUiViewModel(*const AppState, now_ms)`) at the Phase 2
  -> Phase 3 boundary. Phase 3 (`renderFrame` -> `buildRenderPacket` ->
  `executeFrame`) is strictly read-only (never mutates state, window, or intents).

## 2. 3-Phase Frame Pipeline & Intent Registry

- **Phase 1 — Ingestion (`src/viewer.zig`, `src/app/events.zig`)**:
  - `drainWorkerEvents` runs before `computeFrameWaitStrategy`/`pollFrameInput`
    (forcing `.poll` if events were drained) and again right after `pollFrameInput`.
  - Uses infallible O(1) `MpscQueue.drain(io, &event_batch)` swap and stages CPU
    surfaces into `ThumbnailState.staged_cpu` and `ResidentAsset.loaded_cpu` /
    `.promoting_gpu` with **zero GPU calls** (disowning transferred pointers
    before `defer evt.deinit()`).
- **Phase 2 — Sequential Systems (`runUpdatePhase` in `src/app/systems/root.zig`)**:
  - Systems accept `ctx: FrameContext` and **MUST NOT** call other systems
    directly (communicating solely via `AppState` or `pending_intents`):
    1. `sysSyncWindowVisibility` -> 02. `sysUpdateAnimations` ->
    2. `sysExecuteIpcCommands` -> 04. `sysProcessPaletteInput` ->
    3. `sysProcessInput` -> 06. `sysProcessUiInteractions` ->
    4. `sysUpdateViewport` & `sysUpdateSlideshow` ->
    5. `sysExecuteIntents` (`defer self.clearIntents()` right after empty check;
       `defer self.flushPendingSelectionStreams()`) ->
    6. `sysSyncWindow` -> 10. `sysProcessAssetUploads` ->
    7. `sysUpdateCache` (`defer state.flushPendingWaitLoadStreams()`) ->
    8. `sysSyncMetrics`.
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

*(Deep recipes: [systems-architecture.md](../skills/zig-gui-practices/references/systems-architecture.md),
[vram-preloading.md](../skills/zig-gui-practices/references/vram-preloading.md))*
