# VRAM Budgeting, EXIF Header Parsing & Navigation Throttling

## 1. VRAM Cache Budgeting & Memory Management

- **VRAM Budget Calculation with Mipmap Overhead**:
  When computing VRAM memory footprints, account for the base RGBA32 texture size ($W \\times H \\times 4\\text{ bytes}$, including 24-bit RGB/BGR surfaces unpacked to `RGBA8` on the GPU) plus the $+33%$ mipmap pyramid overhead ($\\frac{4}{3} \\times \\text{base size}$). Ensure budget caps (e.g. $1024\\text{ MB}$) can accommodate multiple high-resolution ($24\\text{MP}-50\\text{MP}$) images simultaneously, and dynamically cap the neighbor prefetch radius ($2 \\to 1 \\to 0$) in `sysUpdateCache` when the $\\pm 2$ window exceeds `max_vram_bytes`.
- **ViewMode-Aware Neighbor & Transition Slot Protection**:
  In `sysUpdateCache` and `enforceVramBudget`, resolve visible neighbors via `NavigationState.getVisibleNeighbors()` (`VisibleNeighbors`) so prefetching and eviction protection respect active `ViewMode` filtering (`.default`, `.picks`, `.rejects`, `.all`) alongside `getTransitionPrevIndex()`.
- **Resident `--server` Mode Reclamation & Cross-Thread C Decoder Arena Trimming (`sdl.reclaimProcessHeap`)**:
  - When `decodeWorker` decodes images via `SDL_image` / `stb_image` on background worker threads and transfers the resulting `SDL_Surface` to the main thread (`handleImageDecodedEvent`, `prepareCacheTextures` in `src/app/systems/asset_upload.zig`), `SDL_DestroySurface` frees those multi-megabyte pixel buffers back into the worker threads' glibc `ptmalloc2` non-main arenas (`64MB` `mmap` heaps). Because glibc dynamically raises `M_MMAP_THRESHOLD` (up to `32MB`) and `M_TRIM_THRESHOLD` (up to `64MB`) after the first large free, worker thread arenas retain 100MB+ of dirty anonymous pages unless explicitly trimmed via `sdl.reclaimProcessHeap()` (`malloc_trim(0)` on Linux/glibc).
  - **Contention Guard**: Because `malloc_trim(0)` acquires every per-thread glibc arena lock across the process, NEVER call `sdl.reclaimProcessHeap()` on `.thumb_decoded` events during rapid scrolling or while `workers.active_decode_threads.load(.acquire) > 0` during normal viewing. Invoke `sdl.reclaimProcessHeap()` only when:
    1. All active decode workers have finished (`active_decode_threads == 0`) after destroying a full-image `SDL_Surface` (`drainWorkerEvents`, `prepareCacheTextures`),
    2. A background worker exits after cancellation (`cancel.isCanceled()` in `decodeWorker`) or background thumbnail/precache batch completion (`thumbWriterWorker`, `precacheDirectoryWorker`), or
    3. The window transitions to `.hidden` in `--server` mode (`AppState.hideWindow` + `viewer.zig`, alongside `RenderResources.releaseTransientResources` and `sdl.gpu.Device.reclaimMemory()`).
- **Staging Buffer Warm Cap & Idle Decay (`UploadStagingBuffer`)**:
  - `UploadStagingBuffer` (`src/gpu/upload.zig`) keeps retained transfer and compute storage buffers up to `WARM_STAGING_CAP_BYTES = 32 * 1024 * 1024` (32 MiB) warm across frames.
  - At the end of `sysProcessAssetUploads` (`src/app/systems/asset_upload.zig`), `maybeShrinkIdle(gpu_dev, ctx.now_ms, is_idle)` evaluates idle state (`!did_upload and !cache.hasPendingCpuUploads(true) and active_decode_threads == 0`): active frames refresh `oversized_since_ms = now_ms`, and after `IDLE_DECAY_MS = 5000` (5s) idle, any buffer exceeding 32 MiB is released back to `.unallocated` while buffers `<= 32 MiB` stay warm.
  - `AppState.getWaitTimeoutMs` (`src/app/state.zig`) incorporates
    `upload_staging.decayTimeoutMs(now)` and (when `stats_panel.visible` is
    `true`) `frame_metrics.present.settleTimeoutMs(now)` so idle viewers wake
    deterministically at settle/decay boundaries before returning to 0% CPU
    `.wait_indefinite` sleep once `oversized_since_ms == null` and `present`
    lands in `.primed`.

______________________________________________________________________

## 2. Asynchronous Header Probing, Camera RAW Streaming & Progressive Loading

- **Two-Stage Header-First Read & In-Memory Decoding (`DecodePayload`, `decodeWorker`)**:
  `DecodePayload.openStagedFile` (`Stage = union(enum) { staged_file: std.Io.File, complete }`) performs a single `statFile` + `openFile` and reads Stage 1 (`@min(target_read_size, 256 * 1024)` bytes) via `readRangePositional`. `decodeWorker` parses orientation, probes dimensions, and extracts/emits `.thumb_decoded` (from the Stage 1 header slice or via a positional read on `.staged_file` when an EXIF thumbnail sits beyond 256KB) *before* reading the remaining file bytes in `DecodePayload.readRemaining()` (Stage 2) and closing the file descriptor prior to `sdl.Surface.loadConstMemOpt`.
- **Single-Pass `DecodeMode` Staging (`full`, `active_fast_scroll`, `speculative_thumb`)**:
  - `.speculative_thumb`: Caps allocation at `@min(file_size, 256 * 1024)` bytes (and CBZ decompression at `header_probe_limit`), extracts a small placeholder thumbnail (`thumb_only = true`) or emits `dimensions_probed` (`thumb_only = true`) if none exists, and returns without Stage 2 decode.
  - `.active_fast_scroll`: Reads Stage 1 (`256KB`) while keeping `.staged_file` open if `file_size > 256KB`. If a thumbnail IS found (embedded header/positional, RAW thumb, or XDG cache), emits `thumb_decoded` (`thumb_only = true`) and returns immediately, deferring full decode until `ScrollCadence` settles. If NO thumbnail exists (e.g. PNG/WebP without cached thumb), falls straight through from Stage 1 to Stage 2 full decode via `readRemaining()` in the **same open-file pass**.
  - `.full`: Emits a fast placeholder thumbnail when available (`thumb_only = false`) and proceeds directly to Stage 2 full decode.
- **Same-Batch Thumbnail Upload Skip (`hasSubsequentImageDecoded`)**:
  When an image decodes quickly and `.thumb_decoded` and `.image_decoded`
  arrive in the same `drainWorkerEvents` batch, `handleExifThumbnailEvent`
  applies probed metadata and skips staging `ThumbnailState.staged_cpu` (and
  `handleImageDecodedEvent` discards any earlier `.staged_cpu`), so fast
  decodes never upload an unused thumbnail texture or trigger a 120ms blurry
  `thumb_crossfade`.
- **Freedesktop Shared Thumbnail Cache (`src/thumbcache/root.zig` /
  `src/core/thumbcache.zig`)**:
  - **Stage-1 Read Fallback (`probeFreedesktopThumbCache`)**: When a file has no embedded thumbnail, workers compute the canonical `file://` URI (`std.Io.Dir.realPathFile`, RFC 3986 percent-encoding) and lowercase MD5 hex digest (`ThumbCacheKey`, excluding `/tmp/` and `cache_dir` itself), probing `$XDG_CACHE_HOME/thumbnails/` across `.normal` -> `.large` -> `.x_large` -> `.xx_large` and verifying `Thumb::MTime` matches `statFile` `mtime.toSeconds()`. Cached Freedesktop PNGs are pre-oriented upright on disk (`ThumbnailSource.freedesktop_cache.isPreOriented() == true`).
  - **Idle-Gated Background Writer (`thumbWriterWorker`)**: On a full decode
    where `resolveThumbWriteMtime` returns a valid `mtime_sec`
    (`ThumbWritePolicy.all_missing`), `prepareCacheTextures` /
    `completeGpuUpload` (`src/app/systems/asset_upload.zig`) transfers the CPU
    `sdl.Surface` zero-copy into `enqueueDecodedThumbWrite` ->
    `WorkerManager.enqueueThumbWrite` (`MAX_QUEUED_THUMB_WRITES = 8`) after GPU
    upload and `enforceVramBudget`. `thumbWriterWorker` pops jobs under
    `thumb_write_mutex` (exiting immediately when empty), yields while
    `active_decode_threads > 0`, downscales to `.large` ($256\\times256$),
    applies orthogonal EXIF rotation (`scaleAndOrientSurface` in
    `src/core/thumbcache.zig`), splices `tEXt` metadata chunks (`Thumb::URI`,
    `Thumb::MTime`, `Thumb::Size`, `Thumb::Mimetype`,
    `Thumb::Image::Width`/`Height`, `Software`) immediately after the 33-byte
    `IHDR`, and writes via `0600` temp file + atomic `rename`.
- **Off-Main-Thread Header Probing (`DecodeMode`)**:
  - All file header opens, dimension probes, and EXIF orientation reads run exclusively on background `decodeWorker` threads via Stage 1 (`header_probe_limit = 256 * 1024`), eliminating blocking filesystem/archive I/O from `sysUpdateCache` and `executeIntent(.reset_rotation)` (which reads `entry.metadata.orientation` directly from `getCurrentEntry()`, defaulting to `.normal`).
  - When `.speculative_thumb` finds no thumbnail or `.active_fast_scroll` completes Stage 2 full decode, main-thread event handlers set `entry.resident.thumbnail = .not_available` so subsequent frames never re-spawn thumbnail-only probes.
- **Loading Grace Period (`LOADING_GRACE_PERIOD_MS = 35`)**:
  When `entry.resident.asset == .none` with an active `InFlightState`
  (`.queued_decode`, `.decoding`, or `.uploading`) and no thumbnail is ready,
  `renderViewport` sizes `ImageCanvas` to `.fixed(draw_w)` / `.fixed(draw_h)`
  and delays the `"Loading image..."` text until `elapsed > 35ms` (~2 frames
  at 60Hz), preventing UI text flashes on fast decodes.
- **EXIF APP1 & TIFF Rules**:
  - **APP1 Skipping**: When scanning JPEG markers for main image `SOF0`/`SOF2` dimensions, explicitly skip `APP1` (`0xFF, 0xE1`) segments (`idx += seg_len`) so embedded thumbnail SOF headers are not mistaken for main image dimensions.
  - **Truncated APP1 Tolerance**: Never discard an APP1 segment solely because `payload.len < seg_len`; inspect available bytes `data[idx + 2 .. idx + @min(seg_len, data.len - idx)]` for `"Exif\0\0"` and TIFF IFD0 headers.
  - **Segmented TIFF Virtual Addressing (`probeRawFileHeader`)**:
    `probe.probeRawFileHeader` probes the 4-byte IFD0 offset from the initial
    8-byte header first, only calling `file.length(io)` and reading a 16KB stack
    `tail_buf` (`[16 * 1024]u8`) when `ifd0_off >= header_len` (e.g.
    Ricoh/Pentax tail IFD0 at 30MB+). Keep `TiffSource.getSlice`, `init`, and
    `initWithTail` marked `inline`.
  - **SubIFD Clamping & Cycle Guard**: Clamp `SubIfdList` to `@min(count, 8)` without erroring, and track `visited: [8]u32` during IFD traversal to break cyclic IFD pointers.

### Camera RAW Format Quirks & Disqualification Table

Camera RAW files (`.arw`, `.raf`, `.cr2`, `.nef`, `.dng`, `.orf`, `.rw2`, `.pef`) must never be read into memory in full; workers extract embedded preview JPEGs via positional reads (`file.readPositional`).

| Format / Camera                            | Header Window        | Preview & Thumbnail Layout                                                                                                                                                     | Parser Constraints & Disqualifications                                                                                                                                                                                                                                                          |
| :----------------------------------------- | :------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Adobe DNG / Ricoh GR III / Pentax**      | `256 * 1024` (256KB) | ~161KB `DNGPrivateData` (`0xC634`) pushes `SubIFD[0..1]` to ~162KB; Ricoh embeds a 720x480 JPEG thumb inside `0xC634` at ~97KB (len ~55KB); IFD0 may sit at file tail (30MB+). | Require single-strip JPEG (`Compression == 6` or `7`, `val_count == 1`) with `PhotometricInterpretation` in `{1, 2, 6}` (or `null`) and `PlanarConfiguration == 1` (or `null`). Exclude CFA (`32803`) and LinearRaw (`34892`). Fall back to `parseImageDimensions` if SubIFDs lack sensor dims. |
| **Canon CR2** (`"CR\x02\x00"` at offset 8) | `256 * 1024` (256KB) | IFD0 holds full-res JPEG preview (e.g. 2496x1664) but **omits** `PhotometricInterpretation` (`0x0106`). IFD1 holds thumbnail.                                                  | Explicitly disqualify **IFD2** (uncompressed 24-bit RGB tagged as `Compression == 6` lacking `\xFF\xD8` SOI) and **IFD3** (Lossless JPEG `SOF3` / `0xC3` raw Bayer sensor stream). Walk first 1024 bytes of candidate strips to verify `\xFF\xD8` and reject `SOF3` (`0xC3`).                   |
| **Fujifilm RAF**                           | `256 * 1024` (256KB) | Embedded JPEG preview capped at ~12MP (4240x2832 or 4000x3000); IFD1 thumbnail at offset ~4,192 fits inside 256KB header.                                                      | Never infer full sensor resolution or aspect ratio from the 12MP preview SOF header; always read `PixelXDimension` (`0xA002`) / `PixelYDimension` (`0xA003`) from EXIF metadata.                                                                                                                |
| **Sony ARW / Nikon NEF / TIFF-EP**         | `256 * 1024` (256KB) | IFD0 acts simultaneously as SubIFD container (`0x014A`), preview provider (`0x0201`/`0x0202`), and EXIF directory (`0x8769`).                                                  | Filter out raw Bayer sensor streams (`32803` CFA / `34892` LinearRaw / `NewSubfileType == 0` raw SubIFDs) whose optical-black margins (e.g. 6656x4608 vs 6240x4160) would corrupt aspect ratio fitting.                                                                                         |

### Progressive 4-Tier RAW+JPEG Pipeline & Dimension Invariants

1. **Tier 1 (Small Thumbnail, $\\le 512\\text{KB}$)**: Decoded in ~0.17ms directly from the resident 256KB header slice during rapid scrubbing (`DecodeMode.active_fast_scroll` / `.speculative_thumb`).
2. **Tier 2 (Medium Preview, $\\le 2\\text{MB}$, e.g. 1616x1080)**: Decoded as an instant placeholder during settled viewing (`DecodeMode.full`). Skipped if the container has only a single preview (`preview == thumbnail`). If `prev_loc.file_offset +| prev_loc.length <= header_slice.len`, sliced zero-copy from `header_slice`.
3. **Tier 3 (Full-Resolution RAW Preview, e.g. 6240x4160)**: Decoded in the background via positional read and crossfaded over Tier 2.
4. **Tier 4 (Companion Full-Resolution JPEG)**: Deferred until physical pixel demand exceeds the embedded preview resolution:
   $$M\_{\\text{tex}} = Z \\times \\max\\left(\\frac{W\_{\\text{auth}}}{W\_{\\text{loaded}}}, \\frac{H\_{\\text{auth}}}{H\_{\\text{loaded}}}\\right) > 1.05$$
   (or $M\_{\\text{tex}} > 1.15$ after `250ms` settled in Fit mode), or when the user presses `j` (`.toggle_pair_stream`).
5. **Progressive Dimension & Promotion Purity Invariants**:
   - **No Worker Thumbnail Fallback**: Workers MUST set `full_dims = null`
     when true full dimensions are unknown; never substitute `t_surf.w()` / `t_surf.h()`.
   - **Monotonic Area Updates (`applyProbedMetadata`, `updateFullDims`)**: Event
     handlers only update `metadata.full_dims` when `cand_area > cur_area`.
   - **Pair Promotion Guards**: When `args.pair_target != .adaptive`, skip
     embedded EXIF thumbnail extraction in `decodeStandardRasterFile`; in
     `events.zig`, ignore `.thumb_decoded` when
     `entry.resident.asset.isLoaded()` (`.loaded_gpu`, `.loaded_cpu`, or
     `.promoting_gpu`), and in `asset_upload.zig` gate `checkLoadedGpuCrossfade`
     on `!was_loaded_gpu` so promoting a pair never flashes a blurry thumbnail
     over a sharp preview.
   - **Small-Image Fitting Guard (`only_has_thumb`)**: In `computeDrawDims`, only
     promote `.shrink` to `.full` during background decode when
     `entry.metadata.full_dims == null`,
     `entry.metadata.raw_metadata.getSensorDims() == null`, and
     `entry.resident.thumbnail` is not `.none`.
   - **Main-Thread Stale Upload & Promotion Release Guard**: Phase 1
     (`drainWorkerEvents`) resolves `SlotBound` events via
     `evt.resolve(&state.cache)` and stages decoded surfaces into
     `ThumbnailState.staged_cpu` and `ResidentAsset.loaded_cpu` (`CpuAsset`) /
     `.promoting_gpu` (`PromotingGpuComponent`) without calling
     `uploadSurfaceToGpu` or destroying any existing `.loaded_gpu` texture.
     Phase 2 (`prepareCacheTextures` / `completeGpuUpload` in
     `src/app/systems/asset_upload.zig`) performs all GPU uploads, atomically
     resolves `ImageCacheKey` via `getEntry` after `enforceVramBudget` before
     transferring `surface` to `enqueueDecodedThumbWrite`.

______________________________________________________________________

## 3. Throttled Navigation, Telemetry & Settled Preloading

- **Navigation Throttling (`ScrollCadence` in `src/state/types.zig`)**:
  - **Brisk-Scroll Streak (`FAST_SCROLL_MS=35`, `CROSSFADE_BYPASS_MS=200`)**:
    `ScrollCadence` encodes `.idle`, `.single_step: u64`, and
    `.brisk_scroll: u64`. Stepping from `.idle` (or after
    $\\ge 200\\text{ms}$) enters `.single_step` (`isFastScrolling` active for
    `35ms`); stepping again within $< 200\\text{ms}$ promotes to
    `.brisk_scroll` (`isFastScrolling` active for `200ms` across continuous
    brisk steps). While `NavigationState.cadence.isFastScrolling(now)` is true,
    `is_fast_scrolling` is true:
    1. *Active Slot (`cur_id`)*: Unless
       `entry.resident.thumbnail == .not_available` (in which case
       `sysUpdateCache` spawns `DecodeMode.full`), workers run with
       `DecodeMode.active_fast_scroll`. If a thumbnail is present, Stage 1
       emits `thumb_decoded` (`thumb_only = true`, ~0.17ms) and exits; if none
       exists, Stage 1 falls straight through to Stage 2 full decode in the same
       open-file pass. Both `is_active_thumb_ready` and `skip_active` recognize
       `.staged_cpu` alongside `.loaded` so `cur_id` never spawns duplicate
       `.active_fast_scroll` workers while a thumbnail is staged on CPU awaiting
       GPU upload.
    2. *Speculative Neighbor*: Once the active thumbnail is ready
       (`is_active_thumb_ready`), `sysUpdateCache` speculatively preloads the
       next single neighbor (`speculative_idx`) along `direction`
       (`NavDirection`: `.forward` / `.backward`) using
       `DecodeMode.speculative_thumb`, deferring full decodes until navigation
       settles ($\\ge 35\\text{ms}$ for `.single_step`, $\\ge 200\\text{ms}$ for
       `.brisk_scroll`).
  - **`ScrollCadence.CROSSFADE_BYPASS_MS = 200` (`shouldBypassCrossfade`)**:
    Navigation steps within $< 200\\text{ms}$ (`src/app/systems/intents.zig`)
    bypass image crossfade animations (snapping immediately) and trigger the
    transient auto-title overlay.
  - **`ScrollCadence.SETTLED_PROMOTE_MS = 250` (`isSettledForPromotion`)**:
    Companion JPEG Tier-4 promotion in Fit mode (`src/app/systems/cache.zig`)
    waits until `cadence` is `.idle` or elapsed $> 250\\text{ms}$ to avoid 200MB
    decodes while stepping through a folder. `AppState.getWaitTimeoutMs`
    incorporates `cadence.settleTimeoutMs(now)` (`35ms` for `.single_step`,
    `200ms` for `.brisk_scroll`, and `251ms` for promotion) so settle
    boundaries reliably wake the event loop before dropping to
    `.wait_indefinite`.
- **Telemetry Metric Split ("Stats for Nerds")**:
  High-resolution nanosecond timers (`std.Io.Clock.awake.now(io)` via
  `state.durationToMs` and `state.activeDurationMs` uniformly across `probe`,
  `vfs`, `cache`, `input`, `gpu`, `app`, and `viewer`, while `src/ui/` and
  `src/state/` remain clock-free) measure disk I/O (`read_time_ms`) separately
  from CPU decompression (`decode_time_ms`) in `DecodeTelemetry` and GPU texture
  ingestion in `IngestTelemetry` using zero-sentinel tagged unions
  (`ArchiveTelemetry`, `UploadMode`, `MipmapTelemetry`).
  `RenderStats.summarize()` computes rolling 60-frame `StatsSummary`
  (`mean`, `stdev`, `max`) for `FrameMetrics` (`ingest`, `intents`, `sync`,
  `ui_layout`, `gpu_encode`, `swapchain_wait`, and `total` — excluding blocking
  OS event-wait sleep via `FrameInput.poll_cpu_ms` and VSync/GPU backpressure
  `swapchain_wait_ms`), while `PresentTracker` (5-state `Phase`: `.idle`,
  `.primed`, `.warming`, `.settling`, `.streaming` with
  `PRESENT_IDLE_GAP_MS = 250` and `is_paced_step` gating against passive
  event-wait sleep + VRR cold-wake transients) derives event-driven
  `PresentCadence` (`mean_fps = 1000.0 / summary.mean`,
  `low_fps = 1000.0 / summary.max` across its 60-interval `RenderStats` window,
  settling once via `settleBeforeRender` before `buildUiViewModel`—or via
  `.settling` with `settleTimeoutMs == 0` when a `.streaming` burst expires in
  `record`—and `stats_panel.visible`-gated `settleTimeoutMs` in
  `AppState.getWaitTimeoutMs` without waking idle viewers), and
  `UiRenderMetrics` reports
  `last_ui_batch_count`, `last_ui_vertex_count`, and font-atlas usage.
- **Demand-First Settled Preload & GPU Upload Gating**:
  Once navigation settles ($\\ge 35\\text{ms}$ for `.single_step` or
  $\\ge 200\\text{ms}$ for `.brisk_scroll`) AND the active slot is
  `.loaded_gpu` / `.promoting_gpu` (or `.loaded_cpu` in headless mode, or
  `.failed`), `sysUpdateCache` dispatches visible neighbor prefetch workers
  ($\\pm 1, \\pm 2$) with `DecodePriority.background`. Completed surfaces are
  staged in `ResidentAsset.loaded_cpu` (`CpuAsset`) or `.promoting_gpu`
  (`PromotingGpuComponent`), then trickled to the GPU at 1 texture per frame
  (active slot first, then closest neighbor) in `prepareCacheTextures`
  (`src/app/systems/asset_upload.zig`).

______________________________________________________________________

## 4. Task Concurrency & Dynamic Core Scaling

- **`std.Io.Group` Task Spawning**:
  Spawn background decode tasks using `std.Io.Group` via `WorkerManager` (`state.workers.group.async(io, decodeWorker, args)`).
- **Dynamic Core Scaling & Tiered `DecodePriority` (`WorkerManager`)**:
  Scales base concurrent decode tasks dynamically based on hardware CPU count
  (`std.Thread.getCpuCount() catch 4`):
  ```zig
  return @max(1, @min(8, cpus -| 1));
  ```
  This leaves 1 core dedicated to main-thread rendering while capping base
  decode concurrency at 8 threads.
  `WorkerManager.canSpawnDecode(priority: DecodePriority)` enforces three
  priority tiers:
  - `.background` (`getMaxBackgroundDecodes` = `if (base > 1) base - 1 else 1`):
    Used for neighbor prefetches in `sysUpdateCache`, reserving at least 1 base
    slot when `base > 1`.
  - `.promotion` (`getMaxConcurrentDecodes` = `base`): Used for Fit-mode / zoom
    pair promotions in `checkPairPromotion`.
  - `.foreground` (`getMaxForegroundDecodes` = `@min(12, base + 2)` via
    `FOREGROUND_BURST_SLOTS = 2`,
    `MAX_FOREGROUND_DECODES = 12 <= cache.MAX_DECODE_JOBS`): Used for the active
    slide `cur_id` in `sysUpdateCache` so active slides spawn immediately even
    if canceled background workers still occupy base slots.

______________________________________________________________________

## 5. Cooperative Worker Pruning Pattern

- **Non-Blocking Main-Thread Contract**:
  Calling `std.Io.Group.cancel(io)` blocks (`futexWait`) until in-flight workers
  finish. Instead, during runtime navigation or slot reuse, the main thread
  cancels jobs cooperatively without blocking.
- **Three-Tiered Cooperative Cancellation**:
  1. *Application Shutdown*: `workers.exiting` aborts all background activity.
  2. *Global Generation*: `state.cache.generation.fetchAdd(1, .release)`
     invalidates all stale directory or navigation decodes en masse.
  3. *Per-Slot / Per-Job Atomic Epoch*: `AppState.spawnSlotDecode` uniformly
     allocates a pinned ticket (`cache.allocJob()`,
     `job_epochs: [16]std.atomic.Value(u32)`) for both overlapped `openPath`
     slot 0 and `sysUpdateCache` / pair promotion decodes. Advancing a job's
     epoch instantly cancels only that specific worker on eviction or stream
     switch.
- **`CancellationToken` & `SlotBound` Injection**:
  `DecodeArgs` in `src/app/workers/decode.zig` bundles the slot's
  `ImageCacheKey` (stable `id: MediaId` and assigned `generation`),
  `MediaEntry`, `current_generation`, `job_id`, `job_epoch`, and
  `current_job_epoch`, exposing `cancelToken()` (`context.CancellationToken`):
  ```zig
  pub const DecodeArgs = struct {
      workers: *WorkerManager,
      allocator: std.mem.Allocator,
      io: std.Io,
      key: ImageCacheKey,
      job_id: u8 = 0,
      job_epoch: u32 = 0,
      current_job_epoch: ?*const std.atomic.Value(u32) = null,
      entry: MediaEntry,
      has_gpu_device: bool,
      pixel_format: u32,
      mode: DecodeMode = .full,
      pair_target: PairStreamTarget = .adaptive,
      current_generation: *const std.atomic.Value(usize),

      pub inline fn cancelToken(
          self: *const DecodeArgs,
      ) context.CancellationToken {
          return .{
              .exiting = &self.workers.exiting,
              .generation = self.key.generation,
              .current_generation = self.current_generation,
              .job_epoch = self.job_epoch,
              .current_job_epoch = self.current_job_epoch,
          };
      }
  };
  ```
- **Cooperative Checkpoints & `defer` Unwinding**:
  Workers construct `const cancel = args.cancelToken();` and check
  `cancel.isCanceled()` at task entry, between archive/directory steps,
  before `Surface.loadConstMemOpt`, and before pixel format conversion,
  returning early with all local resources unwound via `defer`.

______________________________________________________________________

## 6. Content-Adaptive Embedded Thumbnail Crop Detection & SIMD Analysis

- **Camera Hardware DCT Variance**:
  - *8px DCT Block Snapped*: Fujifilm RAF and Ricoh GR IIIx JPEG pad letterbox/pillarbox margins to 8-pixel DCT block boundaries.
  - *Theoretical Aspect Ratio*: Sony ARW and standard JPEGs scale active images continuously with exact fractional padding.
- **Candidate Boundary & Step-Transition Verification**:
  - Compute `raw_pad_px` from full aspect ratio `ar_full` and `nearest_block_px = @round(raw_pad_px / 8.0) * 8.0`.
  - Guard: `nearest_block_px > 0.0 and nearest_block_px * 2.0 < thumb_dim and @abs(raw_pad_px - nearest_block_px) <= 2.0`.
  - Verify padding rows/cols (`test_bound - 1` and `dim - test_bound`) are black ($\\le 16$) AND active content begins at `test_bound` or `dim - test_bound - 1` so dark scenes (astrophotography, studio backdrops) are never falsely cropped.
- **SIMD Surface Inspection & Single-Pass RGBA32 Downscaling (`Surface.scaleRgba32Smooth`)**:
  - Scan contiguous horizontal rows with `@Vector(16, u8)` and `@reduce(.Or, ...)`; scan strided vertical columns with scalar/4-byte reads and early exit.
  - Derive endian-agnostic RGB masks from `details.*.Rmask | details.*.Gmask | details.*.Bmask`.
  - When downscaling CPU surfaces (`RGB24`, `BGR24`, `RGBA32`) for Freedesktop thumbnail generation (`writeThumbnailPng`) or Kitty terminal previews (`renderPreviewRgbaFile` -> `/dev/shm/tty-graphics-protocol-peng-...` `t=t` transfer), use `Surface.scaleRgba32Smooth` (`resampleDirectToRgba32`) instead of `SDL_ScaleSurface(..., SDL_SCALEMODE_LINEAR)` (which falls back to nearest-neighbor on 24-bit `RGB24` surfaces and exhibits single-pass bilinear aliasing on $>2\\times$ reductions). `scaleRgba32Smooth` performs single-pass `i64` 16.16 fixed-point $4\\times 4$ / $2\\times 2$ box-grid area averaging (or bilinear for $\<2\\times$) directly into the target `RGBA32` buffer with zero intermediate surface allocations.
