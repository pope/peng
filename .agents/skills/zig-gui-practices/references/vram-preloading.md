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
- **Non-EXIF Fast-Navigation Decompression Bypassing**:
  If no embedded EXIF thumbnail exists (PNG, WebP, GIF, non-EXIF JPEG) and `thumb_only = true`, do NOT fall through to full CPU software decompression (`sdl.Surface.loadConstMemOpt`). Parse image dimensions directly from container headers via `image.parseImageDimensions(header_buf, mime_type)`, push `.thumb_decoded` with `surface = null` so the layout canvas sets the target aspect ratio on Frame 1, and return early. This keeps decode worker threads 100% idle and available during fast scrubbing.
- **Frame-1 Target Aspect Layout & Synchronous Probing**:
  Parse full image dimensions (`full_w`, `full_h`) and EXIF orientation directly from file container headers synchronously on the main thread via `image.probeMediaMetadata` (< 0.1 ms positional read up to 64KB, supporting filesystem files and uncompressed CBZ entries) before spawning background decode worker threads. This allows layout math (`getBaseScale`, aspect ratio fitting) to set exact canvas dimensions on Frame 1.
- **ImageCanvas Placeholder Layout**:
  When `entry.status == .decoding` and no thumbnail is ready, if target dimensions are known (`draw_w > 0 and draw_h > 0`), `renderViewport` renders `ImageCanvas` with `.fixed(draw_w)` and `.fixed(draw_h)` containing a centered `"Loading image..."` indicator. This guarantees that layout geometry and child alignment remain completely stable from the very first frame, eliminating layout jumps and window jitter.
- **EXIF APP1 Segment Skipping Rule**:
  Camera JPEGs embed EXIF thumbnails inside the `APP1` (`0xFF, 0xE1`) segment. When scanning for main image `SOF0`/`SOF2` frame headers, `APP1` segment payloads MUST be explicitly skipped (`idx += seg_len`) to prevent matching the embedded thumbnail's frame header.
- **EXIF Tag Priority**:
  Check EXIF TIFF tags `0x0100` (`ImageWidth`), `0x0101` (`ImageLength`), `0xA002` (`PixelXDimension`), and `0xA003` (`PixelYDimension`) in IFD0 and ExifIFD first, as they reside in the initial 1 KB of the file.

______________________________________________________________________

## 3. Throttled Navigation, Telemetry & Settled Preloading

- **Throttling & Thumbnail-Only Fast Decoding**:
  During rapid scrolling (< 150ms step interval), constrain preload queues strictly to the active image `idx` and set `thumb_only = true` on `DecodeArgs`. Background `decodeWorker` tasks extract and emit the embedded EXIF thumbnail (~0.5ms) via `.thumb_decoded` and exit early (`if (args.thumb_only) return;`), bypassing full software decoding. This eliminates CPU/disk thrashing and prevents driver queue submission exhaustion (`VK_ERROR_DEVICE_LOST`).
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

> [!NOTE]
> For strict main-thread GPU texture release invariants and std.Io task group details, refer to [02_concurrency_and_architecture.md](../../../rules/02_concurrency_and_architecture.md).
