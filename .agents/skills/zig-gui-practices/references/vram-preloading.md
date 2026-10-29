# VRAM Budgeting, EXIF Header Parsing & Navigation Throttling

## 1. VRAM Cache Budgeting & Memory Management

- **VRAM Budget Calculation with Mipmap Overhead**:
  When computing VRAM memory footprints, account for the base RGBA32 texture size ($W \\times H \\times 4\\text{ bytes}$, including 24-bit RGB/BGR surfaces unpacked to `RGBA8` on the GPU) plus the $+33%$ mipmap pyramid overhead ($\\frac{4}{3} \\times \\text{base size}$). Ensure budget caps (e.g. $1024\\text{ MB}$) can accommodate multiple high-resolution ($24\\text{MP}-50\\text{MP}$) images simultaneously, and dynamically cap the neighbor prefetch radius ($2 \\to 1 \\to 0$) in `sysUpdateCache` when the $\\pm 2$ window exceeds `max_vram_bytes`.
- **ViewMode-Aware Neighbor & Transition Slot Protection**:
  In `sysUpdateCache` and `enforceVramBudget`, resolve visible neighbors via `NavigationState.getVisibleNeighbors()` (`VisibleNeighbors`) so prefetching and eviction protection respect active `ViewMode` filtering (`.default`, `.picks`, `.rejects`, `.all`) alongside `getTransitionPrevIndex()`.
- **Worker Concurrency & Lifecycle Synchronization**:
  Quiesce and clean up background worker tasks and queues (`state.workers.deinit(self.allocator, self.io)`) in the top-level owner lifecycle method (`AppState.deinit()`).
- **HashMap String Key Lifetimes**:
  Always iterate `keyIterator()` to free dynamically allocated string keys before calling `clearRetainingCapacity()` or `deinit()` on hash maps:
  ```zig
  var rot_iter = self.rotation_map.keyIterator();
  while (rot_iter.next()) |key| {
      self.allocator.free(key.*);
  }
  self.rotation_map.clearRetainingCapacity();
  ```
- **Resident `--server` Mode Reclamation & Cross-Thread C Decoder Arena Trimming (`sdl.reclaimProcessHeap`)**:
  - When `decodeWorker` decodes images via `SDL_image` / `stb_image` on background worker threads and transfers the resulting `SDL_Surface` to the main thread (`handleImageDecodedEvent`, `prepareCacheTextures`), `SDL_DestroySurface` frees those multi-megabyte pixel buffers back into the worker threads' glibc `ptmalloc2` non-main arenas (`64MB` `mmap` heaps). Because glibc dynamically raises `M_MMAP_THRESHOLD` (up to `32MB`) and `M_TRIM_THRESHOLD` (up to `64MB`) after the first large free, worker thread arenas retain 100MB+ of dirty anonymous pages unless explicitly trimmed via `sdl.reclaimProcessHeap()` (`malloc_trim(0)` on Linux/glibc).
  - **Contention Guard**: Because `malloc_trim(0)` acquires every per-thread glibc arena lock across the process, NEVER call `sdl.reclaimProcessHeap()` on `.thumb_decoded` events during rapid scrolling or while `workers.active_decode_threads.load(.acquire) > 0` during normal viewing. Invoke `sdl.reclaimProcessHeap()` only when:
    1. All active decode workers have finished (`active_decode_threads == 0`) after destroying a full-image `SDL_Surface` (`drainWorkerEvents`, `prepareCacheTextures`),
    2. A background worker exits after cancellation (`cancel.isCanceled()` in `decodeWorker`) or background thumbnail/precache batch completion (`thumbWriterWorker`, `precacheDirectoryWorker`), or
    3. The window transitions to `.hidden` in `--server` mode (`AppState.hideWindow` + `viewer.zig`, alongside `RenderResources.releaseTransientResources` and `sdl.gpu.Device.reclaimMemory()`).

______________________________________________________________________

## 2. Synchronous Header Probing, Camera RAW Streaming & Progressive Loading

- **Two-Stage Header-First Read & In-Memory Decoding (`DecodePayload`, `decodeWorker`)**:
  `DecodePayload.openStagedFile` (`Stage = union(enum) { staged_file: std.Io.File, complete }`) performs a single `statFile` + `openFile` and reads Stage 1 (`@min(target_read_size, 256 * 1024)` bytes) via `readRangePositional`. `decodeWorker` parses orientation, probes dimensions, and extracts/emits `.thumb_decoded` (from the Stage 1 header slice or via a positional read on `.staged_file` when an EXIF thumbnail sits beyond 256KB) *before* reading the remaining file bytes in `DecodePayload.readRemaining()` (Stage 2) and closing the file descriptor prior to `sdl.Surface.loadConstMemOpt`.
- **Fast-Scrolling Bounded Header Read (`thumb_only = true`)**:
  When `thumb_only = true`, `DecodePayload.openStagedFile` caps allocation at `@min(file_size, 256 * 1024)` bytes while keeping `.staged_file` open if `file_size > 256KB` so thumbnails located past 256KB can still be extracted via positional read before `defer payload.deinit()` closes the file.
- **Same-Batch Thumbnail Upload Skip (`hasSubsequentImageDecoded`)**:
  When an image decodes quickly and `.thumb_decoded` and `.image_decoded` arrive in the same `drainWorkerEvents` batch, `handleExifThumbnailEvent` applies probed metadata but skips GPU upload so fast decodes never upload an unused thumbnail texture or trigger a 120ms blurry `thumb_crossfade`.
- **Freedesktop Shared Thumbnail Cache (`src/thumbcache/root.zig` /
  `src/core/thumbcache.zig`)**:
  - **Stage-1 Read Fallback (`probeFreedesktopThumbCache`)**: When a file has no embedded thumbnail, workers compute the canonical `file://` URI (`std.Io.Dir.realPathFile`, RFC 3986 percent-encoding) and lowercase MD5 hex digest (`ThumbCacheKey`, excluding `/tmp/` and `cache_dir` itself), probing `$XDG_CACHE_HOME/thumbnails/` across `.normal` -> `.large` -> `.x_large` -> `.xx_large` and verifying `Thumb::MTime` matches `statFile` `mtime.toSeconds()`. Cached Freedesktop PNGs are pre-oriented upright on disk (`ThumbnailSource.freedesktop_cache.isPreOriented() == true`).
  - **Idle-Gated Background Writer (`thumbWriterWorker`)**: On a full decode where `resolveThumbWriteMtime` returns a valid `mtime_sec` (`ThumbWritePolicy.all_missing`), `handleImageDecodedEvent` transfers the CPU `sdl.Surface` zero-copy into `WorkerManager.enqueueThumbWrite` (`MAX_QUEUED_THUMB_WRITES = 8`). `thumbWriterWorker` pops jobs under `thumb_write_mutex` (exiting immediately when empty), yields while `active_decode_threads > 0`, downscales to `.large` ($256\\times256$), applies orthogonal EXIF rotation, splices `tEXt` metadata chunks (`Thumb::URI`, `Thumb::MTime`, `Thumb::Size`, `Thumb::Mimetype`, `Thumb::Image::Width`/`Height`, `Software`) immediately after the 33-byte `IHDR`, and writes via `0600` temp file + atomic `rename`.
- **Main-Thread Synchronous Header Probing (`probeMediaMetadata`)**:
  - Reads up to **256KB** into a stack buffer for Camera RAW files and **128KB** for non-RAW images (< 0.1ms, 0 heap allocations) before spawning background decode workers.
  - Extracts target canvas dimensions (`full_w`, `full_h`), EXIF orientation, and `has_embedded_thumbnail: bool` on Frame 1 so `getBaseScale` and aspect ratio fitting size `ImageCanvas` immediately.
  - For containers without embedded thumbnails (PNG, WebP, GIF, SVG, BMP, non-EXIF JPEG) or when probing fails/returns `null`, immediately set `entry.thumbnail = .not_available` so `needs_dimensions` (`entry.thumbnail == .none`) never re-triggers a hot-loop 256KB read on subsequent frames.
- **Loading Grace Period (`LOADING_GRACE_PERIOD_MS = 35`)**:
  When `entry.status == .decoding` and no thumbnail is ready, `renderViewport` sizes `ImageCanvas` to `.fixed(draw_w)` / `.fixed(draw_h)` and delays the `"Loading image..."` text until `elapsed >= 35ms` (~2 frames at 60Hz), preventing UI text flashes on fast decodes.
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

1. **Tier 1 (Small Thumbnail, $\\le 512\\text{KB}$)**: Decoded in ~0.17ms directly from the resident 256KB header slice during rapid scrubbing (`thumb_only = true`).
2. **Tier 2 (Medium Preview, $\\le 2\\text{MB}$, e.g. 1616x1080)**: Decoded as an instant placeholder during settled viewing (`thumb_only = false`). Skipped if the container has only a single preview (`preview == thumbnail`). If `prev_loc.file_offset +| prev_loc.length <= header_slice.len`, sliced zero-copy from `header_slice`.
3. **Tier 3 (Full-Resolution RAW Preview, e.g. 6240x4160)**: Decoded in the background via positional read and crossfaded over Tier 2.
4. **Tier 4 (Companion Full-Resolution JPEG)**: Deferred until physical pixel demand exceeds the embedded preview resolution:
   $$M\_{\\text{tex}} = Z \\times \\max\\left(\\frac{W\_{\\text{auth}}}{W\_{\\text{loaded}}}, \\frac{H\_{\\text{auth}}}{H\_{\\text{loaded}}}\\right) > 1.05$$
   (or $M\_{\\text{tex}} > 1.15$ after `250ms` settled in Fit mode), or when the user presses `j` (`.toggle_pair_stream`).
5. **Progressive Dimension & Promotion Purity Invariants**:
   - **No Worker Thumbnail Fallback**: Workers MUST set `full_w = 0.0, full_h = 0.0` when true full dimensions are unknown; never substitute `t_surf.w()` / `t_surf.h()`.
   - **Monotonic Area Updates (`applyProbedMetadata`, `updateFullDims`)**: Event handlers only update `entry.full_w/h` when `cur_area <= 0.0 or new_area > cur_area`.
   - **Pair Promotion Guards**: When `args.pair_target != .adaptive`, skip embedded EXIF thumbnail extraction in `decodeStandardRasterFile`; in `events.zig`, ignore `.thumb_decoded` when `entry.status == .loaded_gpu`/`.loaded_cpu` and gate `triggerDecodedGpuCrossfades` on `!was_loaded_gpu` so promoting a pair never flashes a blurry thumbnail over a sharp preview.
   - **Small-Image Fitting Guard (`only_has_thumb`)**: In `computeDrawDims`, only promote `.shrink` to `.full` during background decode when `entry.full_w <= 0.0 and entry.raw_metadata.getSensorDims() == null and entry.thumbnail != .none`.
   - **Main-Thread Stale Upload & Promotion Release Guard**: Resolve `SlotBound` events via `evt.resolve(&state.cache)` before calling `uploadSurfaceToGpu`, and explicitly release any existing `.loaded_gpu` texture (`gpu_dev.releaseTexture`) or destroy `.loaded_cpu` surface (`cpu.surface.destroy()`) before overwriting `entry.status` in `applyDecodedGpuTexture` / `handleImageDecodedEvent` on in-place pair promotion.

______________________________________________________________________

## 3. Throttled Navigation, Telemetry & Settled Preloading

- **Navigation Throttling Thresholds**:
  - **`FAST_SCROLL_THRESHOLD_MS = 35` (`LOADING_GRACE_PERIOD_MS` in `src/app/systems/cache.zig`)**: When the interval since `last_nav_time_ms` is $< 35\\text{ms}$, `is_fast_scrolling` is true:
    1. *Embedded Thumbnails Available*: Workers run with `thumb_only = true` (~0.17ms). Once the active thumbnail is ready (`is_active_thumb_ready`), `sysUpdateCache` speculatively preloads the next single thumbnail (`speculative_idx`) along `direction` (`NavDirection`: `.forward` / `.backward`).
    2. *Non-Thumbnail Formats*: If `entry.thumbnail == .not_available` (e.g. PNG), `sysUpdateCache` spawns a full decode (`thumb_only = false`) for the active slot immediately while withholding neighbor decodes until navigation settles ($\\ge 35\\text{ms}$).
  - **`200ms` Rapid Scrubbing Threshold (`src/app/systems/intents.zig`)**: Navigation steps within $< 200\\text{ms}$ bypass image crossfade animations (snapping immediately) and trigger the transient auto-title overlay.
  - **`250ms` Settled Fit Promotion (`src/app/systems/cache.zig`)**: Companion JPEG Tier-4 promotion in Fit mode waits until $elapsed \\ge 250\\text{ms}$ to avoid 200MB decodes while stepping through a folder.
- **Telemetry Metric Split ("Stats for Nerds")**:
  High-resolution nanosecond timers (`sdl.timer.getTicksNs()`) measure disk I/O
  (`read_time_ms`) separately from CPU decompression (`decode_time_ms`) in
  `DecodeTelemetry` and GPU texture ingestion in `IngestTelemetry` using
  zero-sentinel tagged unions (`ArchiveTelemetry`, `UploadMode`,
  `MipmapTelemetry`).
- **Demand-First Settled Preload & GPU Upload Gating**:
  Once navigation settles ($\\ge 35\\text{ms}$) AND the active slot is `.loaded_gpu` (or `.loaded_cpu` in headless mode, or `.failed`), `sysUpdateCache` dispatches visible neighbor prefetch workers ($\\pm 1, \\pm 2$). Completed neighbor surfaces are held as `.loaded_cpu` while the active image is in flight, then trickled to the GPU at 1 texture per frame in `prepareCacheTextures`.

______________________________________________________________________

## 4. Task Concurrency & Dynamic Core Scaling

- **`std.Io.Group` Task Spawning**:
  Spawn background decode tasks using `std.Io.Group` via `WorkerManager` (`state.workers.group.async(io, decodeWorker, args)`).
- **Dynamic CPU Core Worker Scaling (`WorkerManager.getMaxConcurrentDecodes`)**:
  Scales max concurrent decode tasks dynamically based on hardware CPU count (`std.Thread.getCpuCount() catch 4`):
  ```zig
  return @max(1, @min(8, cpus -| 1));
  ```
  This leaves 1 core dedicated to main-thread rendering while capping concurrent decode memory pressure at 8 threads.

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
  3. *Per-Slot / Per-Job Atomic Epoch*: Each decode job receives a pinned
     ticket `job_epochs: [16]std.atomic.Value(u32)`. Advancing a job's epoch
     instantly cancels only that specific worker on eviction or stream switch.
- **`CancellationToken` & `SlotBound` Injection**:
  `DecodeArgs` in `src/app/workers/decode.zig` bundles the slot's
  `ImageCacheKey` (stable `id: MediaId` and assigned `generation`),
  `MediaEntry`, `current_generation`, `job_id`, `job_epoch`, and
  `current_job_epoch`, exposing `cancelToken()` (`context.CancellationToken`):
  ```zig
  pub const DecodeArgs = struct {
      workers: *WorkerManager,
      allocator: std.mem.Allocator,
      key: ImageCacheKey,
      entry: MediaEntry,
      io: std.Io,
      thumb_only: bool = false,
      pair_target: PairStreamTarget = .adaptive,
      current_generation: *const std.atomic.Value(usize),
      job_id: u8 = 0,
      job_epoch: u32 = 0,
      current_job_epoch: ?*const std.atomic.Value(u32) = null,
      has_gpu_device: bool,
      pixel_format: u32,

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
