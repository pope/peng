# VRAM Budgeting, EXIF Header Parsing & Navigation Throttling

## 1. VRAM Cache Budgeting & Memory Management

- **VRAM Budget Calculation with Mipmap Overhead**:
  When computing VRAM memory footprints, account for the base RGBA32 texture size ($W \\times H \\times 4\\text{ bytes}$) plus the $+33%$ mipmap pyramid overhead ($\\frac{4}{3} \\times \\text{base size}$). Ensure budget caps (e.g. $1024\\text{ MB}$) can accommodate multiple high-resolution ($24\\text{MP}-50\\text{MP}$) images simultaneously.

- **Neighbor Slot Protection**:
  In VRAM cache eviction routines (`enforceVramBudget`), protect the current image and its immediate neighbors ($\\pm 2$ slots) from eviction to prevent constant re-decoding during user navigation.

- **Worker Concurrency & Lifecycle Synchronization**:
  Quiesce and clean up background worker tasks and queues (`state.workers.deinit(io)`) in the top-level owner lifecycle method (`AppState.deinit()`).

- **HashMap String Key Lifetimes**:
  Always iterate `keyIterator()` to free dynamically allocated string keys before calling `clearRetainingCapacity()` or `deinit()` on hash maps:

  ```zig
  var rot_iter = self.rotation_map.keyIterator();
  while (rot_iter.next()) |key| {
      self.allocator.free(key.*);
  }
  self.rotation_map.clearRetainingCapacity();
  ```

______________________________________________________________________

## 2. Synchronous Header Dimension Parsing & EXIF Rules

- **Single-Pass File Read & In-Memory Decoding**:
  `decodeWorker` performs a single file open and read via Zig `std.Io` (`statFile` + `openFile` + `file.reader(io, &r_buf).readSliceAll(...)`) into a task-scoped heap buffer. In Zig 0.16.0, `readSliceAll` bypasses the internal reader buffer for large slices via `readVec`, executing a single vector read syscall directly into the destination buffer with zero syscall penalty. Header parsing, EXIF thumbnail slicing (`file_bytes[off..off+len]`), and full surface decoding (`sdl.Surface.loadConstMemOpt`) operate entirely in RAM, eliminating double-open file descriptor overhead and respecting `io.isCanceled()` during disk I/O.
- **Fast-Scrolling Probe Header Sizing**:
  When `thumb_only = true`, do NOT allocate the full file size on the heap. Allocate and read only `@min(file_size, 128 * 1024)` bytes (up to 128KB). For multi-megabyte photos, this drops read latency from $\\sim 36\\text{ms}$ to $0.17\\text{ms}$ (a $200\\times$ speedup) and eliminates heap thrashing during fast navigation.
- **Non-EXIF Fast-Navigation Decompression Bypassing & Synchronous Thumbnail Presence Probing**:
  `probeMediaMetadata` synchronously checks for embedded thumbnail presence (`has_embedded_thumbnail: bool`) on Frame 1 (< 0.1ms) across Fujifilm RAF, camera RAW/TIFF, EXIF JPEGs, and uncompressed ZIP/CBZ archives. For containers without embedded thumbnails (PNG, WebP, GIF, SVG, BMP, non-EXIF JPEG), `entry.thumbnail` is immediately initialized to `.not_available` on Frame 1, bypassing wasteful `thumb_only` worker dispatches.
- **Frame-1 Target Aspect Layout & Synchronous Probing**:
  Parse full image dimensions (`full_w`, `full_h`) and EXIF orientation directly from file container headers synchronously on the main thread via `image.probeMediaMetadata` (< 0.1 ms positional read up to 64KB, supporting filesystem files and uncompressed CBZ entries) before spawning background decode worker threads. This allows layout math (`getBaseScale`, aspect ratio fitting) to set exact canvas dimensions on Frame 1.
- **ImageCanvas Placeholder Layout & Presentation Grace Period**:
  When `entry.status == .decoding` and no thumbnail is ready, if target dimensions are known (`draw_w > 0 and draw_h > 0`), `renderViewport` renders `ImageCanvas` with `.fixed(draw_w)` and `.fixed(draw_h)`. Rendering of the centered `"Loading image..."` indicator is guarded behind `LOADING_GRACE_PERIOD_MS = 35` (~2 frames at 60Hz / 4 frames at 120Hz). Because embedded thumbnails load in 0.17ms and instant decodes complete in < 16ms, `"Loading image..."` never flashes during fast navigation. If an uncached image requires non-trivial decompression (> 35ms), the indicator appears cleanly on frame 3, giving prompt visual feedback without UI blanking.
- **EXIF APP1 Segment Skipping Rule**:
  Camera JPEGs embed EXIF thumbnails inside the `APP1` (`0xFF, 0xE1`) segment. When scanning for main image `SOF0`/`SOF2` frame headers, `APP1` segment payloads MUST be explicitly skipped (`idx += seg_len`) to prevent matching the embedded thumbnail's frame header.
- **EXIF Tag Priority**:
  Check EXIF TIFF tags `0x0100` (`ImageWidth`), `0x0101` (`ImageLength`), `0xA002` (`PixelXDimension`), and `0xA003` (`PixelYDimension`) in IFD0 and ExifIFD first, as they reside in the initial 1 KB of the file.
- **Camera RAW Zero-Copy Streaming & Embedded Preview Extraction**:
  - Camera RAW files (`.arw`, `.raf`, `.cr2`, `.nef`, `.dng`, `.orf`, `.rw2`, `.pef`) range from 50MB to 150MB+ per file. They MUST NEVER be read entirely into memory.
  - **Synchronous Header Probing & 256KB Buffer Sizing**: Main-thread probing reads up to 256KB into a fixed stack buffer for RAW files (`probeMediaMetadata`), while non-RAW images read 128KB. It extracts raw sensor dimensions, preview JPEG locations, and EXIF orientation with 0 heap allocations in $< 0.1\\text{ms}$.
    - *Why 256KB for RAW*: In DNG files from manufacturers such as Ricoh (GR III, GR IIIx), Pentax, and Leica, extensive manufacturer maker notes (e.g. `DNGPrivateData` tag `0xC634`) are stored within IFD0 before the SubIFDs. A ~161KB maker note block pushes `SubIFD[0]` and `SubIFD[1]` (the full-resolution 6000x4000 embedded JPEG preview) to offsets around 162KB–163KB. A 128KB buffer truncates prior to SubIFD pointers, causing preview discovery to fail.
  - **DNG SubIFD Strip Parsing & JPEG Photometric Validation**:
    - DNG files store full-resolution previews in SubIFDs using standard TIFF JPEG tags (`Compression == 6` OJPEG or `Compression == 7` JPEG) with single-strip layouts (`StripOffsets` `0x0111`, `StripByteCounts` `0x0117` with `val_count == 1`).
    - *Color Space Invariant*: Embedded previews must be validated against standard JPEG color spaces: `PhotometricInterpretation` (`0x0106`) MUST be `6` (YCbCr), `2` (RGB), or `1` (BlackIsZero). RAW sensor data compressed with Lossless JPEG (`Compression == 7`) with CFA Bayer (`32803`) or LinearRaw (`34892`) MUST be excluded to prevent passing non-JPEG sensor bitstreams to image decoders.
  - **Ricoh / Pentax MakerNote Instant Thumbnail Extraction**:
    - Ricoh and Pentax DNGs embed a 720x480 JPEG thumbnail inside `DNGPrivateData` (`Tag 0xC634`) at byte offset ~97KB (length ~55KB). Because this thumbnail sits completely within the 256KB header window, workers decode it directly from memory with zero additional disk I/O (`thumb_header_hits`).
  - **Strict SubIFD Capacity & Early Error Exit**:
    - Fixed-capacity lists (`SubIfdList`) enforce strict bounds (e.g. max 8 SubIFDs) and return `error.TooManySubIfds` upon overflow. This intentional error exit halts parsing early on malformed, unexpected, or excessively deep metadata and emits diagnostic logging so issues can be detected and investigated.
  - **Range-Limited Positional Preview Extraction**: Background workers read only the embedded preview JPEG slice (typically 2–4MB) via positional file I/O (`file.readPositional(io, &slices, prev_loc.file_offset)`), decompressing it via `sdl.Surface.loadConstMemOpt` without touching the multi-megabyte raw sensor bayer pattern payload.
  - **Instant Thumbnail Fast-Scrubbing**: Embedded thumbnails (e.g. Fuji RAF IFD1 `0x0201`/`0x0202` at byte offset 4,192, TIFF IFD1 thumbnail, or Ricoh MakerNote thumbnail) reside completely inside the initial 256KB header buffer. During fast navigation (`thumb_only = true`), decode the thumbnail directly from the header slice with zero additional I/O and return early.
  - **Truncated APP1 Segment Tolerance**: Preview JPEG headers may have large APP1 segments (e.g. 60KB) that span past the initial header slice. Never discard APP1 segments purely because `payload.len < seg_len`; inspect available bytes `data[idx + 2 .. idx + @min(seg_len, data.len - idx)]` for `"Exif\0\0"` and valid TIFF IFD0 headers.
  - **Saturating Bounds Checking**: Offsets and lengths parsed from untrusted headers must always be checked using saturating subtraction or widening: `loc.file_offset <= file_size -| loc.length` and `std.math.add(u32, off, len)`.

______________________________________________________________________

## 3. Throttled Navigation, Telemetry & Settled Preloading

- **Throttling, Directional Speculative Preloading & Active Decode Priority**:
  During rapid scrolling (< 150ms step interval), navigation direction (`.forward` / `.backward`) is tracked. `sysUpdateCache` prioritizes the 5-slot prefetch candidate window along the user's travel direction:
  1. *Embedded Thumbnails Available*: For images with embedded thumbnails (Fuji RAF, camera RAWs, EXIF JPEGs), background workers extract and emit the thumbnail (~0.17ms) via `.thumb_decoded` (`thumb_only = true`), bypassing full software decoding. Once the active image's thumbnail is ready (`is_active_thumb_ready`), Peng speculatively preloads the single next thumbnail (`speculative_idx`) along the travel direction.
  2. *Non-Thumbnail Formats*: If the active image lacks an embedded thumbnail (`entry.thumbnail == .not_available`, such as PNGs or standard JPEGs), `sysUpdateCache` immediately spawns a full decode worker (`thumb_only = false`) rather than stalling behind fast-scrolling throttling. Background neighbor slots (`d != idx`) continue to defer full decode until navigation settles (> 150ms idle time).
- **Telemetry Metric Split ("Stats for Nerds")**:
  High-resolution nanosecond timers (`sdl.timer.getTicksNs()`) isolate disk I/O as `read_time_ms` ("Disk Read Time") separately from CPU software image decompression (`decode_time_ms`). Both metrics are transferred via `ImageDecodedPayload` to the UI overlay.
- **Demand-First Settled Preload & GPU Upload Gating**:
  When navigation settles (> 150ms idle time), `sysUpdateCache(ctx)` MUST verify `is_current_ready` before spawning neighbor decodes ($\\pm 1, \\pm 2$ slots). If the active image is still decoding, neighbor tasks are withheld to prevent CPU/memory bandwidth contention. Similarly, `handleImageDecodedEvent` stores completed neighbor surfaces as `.loaded_cpu` in host RAM if the active image is not yet on the GPU, allowing `prepareCacheTextures` to trickle neighbor textures to VRAM at a paced rate of 1 texture per frame once the active image is visible.

______________________________________________________________________

## 4. Task Concurrency & Dynamic Core Scaling

- **`std.Io.Group` Task Spawning**:
  Spawn background decode tasks using `std.Io.Group` via `WorkerManager` (`state.workers.group.async(io, decodeTask, args)`). Tasks in a `Group` automatically release their task allocation upon return.
- **Native Cancellation & Epoch Validation**:
  Cancel active background tasks via `state.workers.drainAndQuiesce(io)` or `state.workers.group.cancel(state.io)`. In worker functions, check `io.isCanceled()` before queuing event payloads. On the main thread, validate incoming event payloads against the active `state.cache.getGeneration()` epoch before mutating cache entries.
- **Dynamic CPU Core Worker Scaling**:
  Scale max concurrent decode tasks dynamically at runtime based on hardware CPU count (`std.Thread.getCpuCount() catch 4`), e.g. `@max(2, @min(6, cpu_count - 1))`. This ensures high-throughput background decoding on multi-core systems while leaving 1 core dedicated to main-thread rendering.

______________________________________________________________________

## 5. Cooperative Worker Pruning Pattern

- **Non-Blocking Main-Thread Contract**:
  In Zig 0.16.0, calling `std.Io.Group.cancel(io)` is synchronous and blocks the caller (`futexWait`) until all in-flight workers complete their current step. Calling `cancel()` on the main render thread causes frame stutters and input lag. Instead, the main thread increments an atomic generation counter (`state.cache.generation.fetchAdd(1, .release)` or `palette.dir_scan_generation.fetchAdd(1, .release)`), allowing the UI loop to continue rendering immediately at 60/120+ FPS.

- **Atomic Generation Pointer Injection**:
  Worker argument structs take a read-only pointer to the live generation atomic:

  ```zig
  pub const DecodeArgs = struct {
      workers: *WorkerManager,
      allocator: std.mem.Allocator,
      slot_index: usize,
      entry_id: usize,
      assigned_generation: usize,
      current_generation: *const std.atomic.Value(usize),
      // ...
  };
  ```

- **Cooperative Worker Checkpoints**:
  Workers check generation validity at coarse phase transitions before performing expensive operations:

  ```zig
  // At worker task entry
  if (args.current_generation.load(.acquire) != args.assigned_generation) return;

  // Between directory scanning / archive traversal steps
  if (args.current_generation.load(.acquire) != args.assigned_generation) return;

  // Before expensive CPU surface decompression
  if (args.current_generation.load(.acquire) != args.assigned_generation) return;
  ```

- **Clean Resource Unwinding with `defer`**:
  All local resources (open file handles, allocated memory buffers, worker argument allocations, surface allocations, active thread counter decrements) MUST be unwound safely via `defer` so an early return never leaks memory or leaves active thread counters mismatched.

______________________________________________________________________

## 4. Content-Adaptive Embedded Thumbnail Crop Detection & SIMD Analysis

- **Camera Hardware DCT Variance**: In-camera preview JPEG encoders vary by camera model and firmware:
  - *8px DCT Block Snapped*: Fujifilm RAF, Ricoh GR IIIx JPEG pad container letterbox/pillarbox margins to 8-pixel DCT block boundaries.
  - *Theoretical Aspect Ratio*: Sony ARW, standard Fujifilm JPEGs scale active images continuously with exact fractional padding.
  - Container file extensions (`.jpg` vs `.raw`) are NOT predictive. Crop math MUST be content-adaptive.
- **Candidate Boundary Formula**:
  - For letterboxing: `raw_pad_px = (thumb_h - (thumb_w / ar_full)) / 2.0`.
  - For pillarboxing: `raw_pad_px = (thumb_w - (thumb_h * ar_full)) / 2.0`.
  - Compute `nearest_block_px = @round(raw_pad_px / 8.0) * 8.0`.
  - Guard: `nearest_block_px > 0.0 and nearest_block_px * 2.0 < thumb_dim and @abs(raw_pad_px - nearest_block_px) <= 2.0`.
- **Step-Transition Verification & Black Background Immunity**:
  - Test candidate padding rows/cols: `test_bound - 1` and `dim - test_bound` must both be black ($\\le 16$).
  - Test active scene content at the boundary: `!isBlack(test_bound)` or `!isBlack(dim - test_bound - 1)`.
  - If boundary rows are black but active content does NOT begin at `nearest_block_px`, the scene has an extended black background (e.g. astrophotography, studio backdrop). Return `false` to preserve theoretical aspect-ratio padding with zero subject distortion.
- **SIMD Surface Inspection & Memory Layout**:
  - Horizontal rows are contiguous in memory: use `@Vector(16, u8)` with `@reduce(.Or, ...)` for an ~8.6× speedup and linear hardware prefetching.
  - Vertical columns stride across cache lines: use scalar or single 4-byte vector reads with early-exit per row. Cross-cache-line SIMD gathering wastes bandwidth and inhibits early exits.
  - Endian- & Format-Agnostic 32-bit Masking: Derive color mask directly from `details.*.Rmask | details.*.Gmask | details.*.Bmask` via `@as([4]u8, @bitCast(...))` instead of `details.*.Ashift / 8`, correctly handling RGBA, BGRA, ARGB, ABGR, XRGB, and RGBX across all platforms.

> [!NOTE]
> For strict main-thread GPU texture release invariants and std.Io task group details, refer to [02_concurrency_and_architecture.md](../../../rules/02_concurrency_and_architecture.md).
