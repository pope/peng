# Concurrency & Application Architecture Rules

## 1. Main-Thread GPU Resource Restrictions

- SDL GPU device calls, pipeline binding, texture creation, and texture destruction MUST execute exclusively on the main application thread.
- Worker threads MUST decode pixels into CPU surfaces (`sdl.Surface`) and send surfaces to the main thread for GPU upload.

## 2. Mutex Safety & Deadlock Prevention

- All mutex locks (`std.Io.Mutex`) MUST be released via `defer mutex.unlock(io)`.
- Never acquire a mutex twice on the same thread sequence—`std.Io.Mutex` is non-recursive and will deadlock on re-entry.

## 3. `std.Io.Group` Task Spawning & Native Cancellation

- **Avoid Orphaned `io.async` Future Leaks**: Never discard the return value of `io.async` (`_ = io.async(...)`). `io.async` allocates a `Future` on the heap that leaks if not explicitly awaited or canceled.
- **Use `std.Io.Group`**: For background worker tasks or task pools, spawn tasks using `std.Io.Group` (`state.worker_group.async(io, func, args)`). Tasks in a `Group` automatically release their task memory when they return.
- **Native Task Cancellation**: Use `state.worker_group.cancel(state.io)` to cancel active background tasks instead of polling manual atomic generation counters.
- **`error.Canceled` & C-Call Checks**: Handle `error.Canceled` from `std.Io` calls (`openDir`, `iterate`, `readPositional`, `takeDelimiter`). After non-cancellable external C calls (e.g. SDL image loading), check `io.isCanceled()` before pushing results to event queues.

## 4. MpscQueue Transport & Event Loop Wakeup

- Background workers communicate with the main loop by pushing `events.BackgroundEvent` payloads into `ViewerState.event_queue` (`MpscQueue`).
- Producers MUST invoke `fs.wakeUpMainThread()` after pushing events into the queue.
- Disown or null pointer payloads inside `BackgroundEvent` prior to `defer evt.deinit()` execution.

## 5. Zero-Dependency Intent Queue (`AppIntent`) & Co-Located Actions

- UI buttons, menu items, keyboard shortcuts, and IPC socket commands MUST map directly to high-level `intents.AppIntent` payloads from the standalone `intents` module (`src/intents/root.zig`).
- UI inputs MUST NOT execute state mutations inline; they push `AppIntent` values into `ViewerState.pending_intents` via `state.pushIntent(intent)`.
- `pending_intents` is an allocation-free `std.ArrayListUnmanaged(AppIntent)` cleared frame-over-frame using `.clearRetainingCapacity()`.
- Intent execution logic is co-located inside `src/app/actions.zig` (`executeIntent`), operating directly against `ViewerState` without needing an isolated top-level `commands` package.

## 6. Data-Driven State & Packed Struct Overlay Flags (`OverlayFlags`)

- Model mutually exclusive sub-states using `union(enum)` tagged unions (`SlideshowMode`, `DisplayState`, `CacheStatus`).
- Model UI overlay visibility toggles as packed byte bitfield structs (`OverlayFlags = packed struct(u8)`).
- Compose image cache state via explicit component structs (`CpuSurfaceComponent`, `GpuTextureComponent`, `ThumbComponent`).

## 7. Pure System Passes & 5-Stage Engine Loop (`systems.zig`)

- Procedural tick logic, input sampling, slideshow timers, and asset uploads MUST be extracted into pure system pass functions in `src/app/systems.zig`:
  - `sysExecuteIntents`: Drains queued `AppIntent` payloads.
  - `sysUpdateSlideshow`: Manages slideshow timer ticks.
  - `sysUpdateViewport`: Handles mouse drag deltas and mouse-wheel zoom-at-cursor calculations.
  - `sysProcessAssetUploads`: Handles EXIF orientation, CPU-to-GPU texture uploads, background events, and idle preloading.
- The main frame update in `src/viewer.zig` (`updateFrame`) MUST follow the strict 5-stage engine pipeline:
  1. Sampling & IPC Receive
  2. Asset Upload & Preload Pre-pass (`sysProcessAssetUploads`)
  3. System Ticks & State Updates (`sysExecuteIntents`, `sysUpdateSlideshow`, `sysUpdateViewport`)
  4. Clay UI Pointer & Layout State Updates
  5. GPU Execution Pass & Screenshot Post-Processing

## 8. Thread Isolation & Cache Epoch Versioning

- **Thread Isolation**: Background worker tasks must touch zero shared non-atomic main-thread state (`ViewerState`, `DisplayState`, `Device`). Capture immutable value copies (`has_gpu_device: bool`, `pixel_format: u32`) inside worker argument structs (`DecodeArgs`) at spawn time.
- **Cache Epoch Versioning**: Use a plain main-thread `usize` epoch counter (`ViewerState.generation`) incremented on navigation/directory resets (`resetNavigation`) to validate that incoming background event payloads match the active image list epoch before modifying `CacheSlotMap` entries.

## 9. Single-Pass I/O Header & Metadata Consolidation in Workers

Worker tasks performing file inspection and decoding MUST consolidate file I/O operations:

1. **Single File Stat**: Issue `statFile` once at the top of the worker to retrieve `size_bytes`.
2. **Single File Open**: Open `std.Io.Dir.openFile` once for the duration of the worker task pass.
3. **Single Header Read**: Issue `file.readPositional(io, &slices, 0)` once to populate a 64KB stack buffer (`header_buf`).
4. **In-Memory Zero-Copy Operations**: Pass `header_buf[0..n]` in-memory to all metadata parsers (`exif.parseExifOrientation`, `image.detectMimeType`, `exif.readJpegDimensions`, `exif.extractJpegThumbnail`). Never open or read the file multiple times per worker pass.
