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
  `decodeWorker` performs a single file open and read via Zig `std.Io` (`statFile` + `openFile` + `readPositional`) into a task-scoped heap buffer. Header parsing, EXIF thumbnail slicing (`file_bytes[off..off+len]`), and full surface decoding (`sdl.Surface.loadConstMemOpt`) operate entirely in RAM, eliminating double-open file descriptor overhead and respecting `io.isCanceled()` during disk I/O.
- **Frame-1 Target Aspect Layout**:
  Parse full image dimensions (`full_w`, `full_h`) directly from file headers synchronously on the main thread (< 0.1 ms I/O) before spawning decode worker threads. This allows layout math (`getBaseScale`, aspect ratio fitting) to set exact canvas dimensions on Frame 1, eliminating layout jumps and window jitter.
- **EXIF APP1 Segment Skipping Rule**:
  Camera JPEGs embed EXIF thumbnails inside the `APP1` (`0xFF, 0xE1`) segment. When scanning for main image `SOF0`/`SOF2` frame headers, `APP1` segment payloads MUST be explicitly skipped (`idx += seg_len`) to prevent matching the embedded thumbnail's frame header.
- **EXIF Tag Priority**:
  Check EXIF TIFF tags `0x0100` (`ImageWidth`), `0x0101` (`ImageLength`), `0xA002` (`PixelXDimension`), and `0xA003` (`PixelYDimension`) in IFD0 and ExifIFD first, as they reside in the initial 1 KB of the file.

______________________________________________________________________

## 3. Throttled Navigation, Telemetry & Settled Preloading

- **Throttling & Thumbnail-Only Fast Decoding**:
  During rapid scrolling (< 150ms step interval), constrain preload queues strictly to the active image `idx` and set `thumb_only = true` on `DecodeArgs`. Background `decodeWorker` tasks extract and emit the embedded EXIF thumbnail (~0.5ms) via `.thumb_decoded` and exit early (`if (args.thumb_only) return;`), bypassing full software decoding. This eliminates CPU/disk thrashing and prevents driver queue submission exhaustion (`VK_ERROR_DEVICE_LOST`).
- **Telemetry Metric Split ("Stats for Nerds")**:
  High-resolution nanosecond timers (`sdl.timer.getTicksNs()`) isolate disk I/O (`readPositional`) as `read_time_ms` ("Disk Read Time") separately from CPU software image decompression (`decode_time_ms`). Both metrics are transferred via `ImageDecodedPayload` to the UI overlay.
- **Settled Preload & Resolution Upgrade Trigger**:
  When navigation settles (> 150ms idle time), `sysUpdateCache(ctx)` automatically triggers full-resolution image decoding (`thumb_only = false`) for active and neighboring images ($\\pm 1, \\pm 2$ slots) to upgrade thumbnail placeholders to full high-res GPU textures seamlessly.

______________________________________________________________________

## 4. Task Concurrency & Dynamic Core Scaling

- **`std.Io.Group` Task Spawning**:
  Spawn background decode tasks using `std.Io.Group` via `WorkerManager` (`state.workers.group.async(io, decodeTask, args)`). Tasks in a `Group` automatically release their task allocation upon return.
- **Native Cancellation & Epoch Validation**:
  Cancel active background tasks via `state.workers.drainAndQuiesce(io)` or `state.workers.group.cancel(state.io)`. In worker functions, check `io.isCanceled()` before queuing event payloads. On the main thread, validate incoming event payloads against the active `state.cache.getGeneration()` epoch before mutating cache entries.
- **Dynamic CPU Core Worker Scaling**:
  Scale max concurrent decode tasks dynamically at runtime based on hardware CPU count (`std.Thread.getCpuCount() catch 4`), e.g. `@max(2, @min(6, cpu_count - 1))`. This ensures high-throughput background decoding on multi-core systems while leaving 1 core dedicated to main-thread rendering.

> [!NOTE]
> For strict main-thread GPU texture release invariants and std.Io task group details, refer to [02_concurrency_and_architecture.md](../../../rules/02_concurrency_and_architecture.md).
