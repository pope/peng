# Concurrency & Application Architecture Rules

## 1. Main-Thread GPU Resource Restrictions

- SDL GPU device calls, pipeline binding, texture creation, and texture destruction MUST execute exclusively on the main application thread.
- Worker threads MUST decode pixels into CPU surfaces (`sdl.Surface`) and send surfaces to the main thread for GPU upload.

## 2. Mutex Safety & Deadlock Prevention

- All mutex locks (`std.Io.Mutex`) MUST be released via `defer mutex.unlock()`.
- Never acquire a mutex twice on the same thread sequence—`std.Io.Mutex` is non-recursive and will deadlock on re-entry.

## 3. Atomic Worker Thread Counters

- Increment worker thread atomic counters (`active_threads.fetchAdd(1, .monotonic)`) *before* spawning threads, and decrement inside `defer active_threads.fetchSub(1, .release)` at thread exit.
- Acquire atomic thread counters on the main thread using `.acquire` memory ordering.

## 4. MpscQueue Transport & Event Loop Wakeup

- Background workers communicate with the main loop by pushing `types.AppEvent` payloads into `ViewerState.event_queue` (`MpscQueue`).
- Producers MUST invoke `fs.wakeUpMainThread()` after pushing events into the queue.
- Disown or null pointer payloads inside `AppEvent` prior to `defer evt.deinit()` execution.

## 5. Action Queue & Deferred Commands (`AppActionId`)

- UI buttons, menu items, and keyboard shortcuts must map to central `types.AppActionId` enums.
- UI inputs MUST NOT execute state mutations inline; they push `AppActionId` identifiers into `ViewerState.action_queue` via `triggerAction(self, action_id)`.
- `action_queue` items are drained and processed sequentially at the end of the frame update loop in `main.zig`.

## 6. Data-Driven State & Packed Struct Overlay Flags (`OverlayFlags`)

- Model mutually exclusive sub-states using `union(enum)` tagged unions (`SlideshowMode`, `DisplayState`, `CacheStatus`).
- Model UI overlay visibility toggles as packed byte bitfield structs (`OverlayFlags = packed struct(u8)`).
- Compose image cache state via explicit component structs (`CpuSurfaceComponent`, `GpuTextureComponent`, `ThumbComponent`).
