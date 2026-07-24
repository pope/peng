# Concurrency & GPU Threading Invariants

## Main-Thread GPU Resource Lifecycles

- Release and deallocate all GPU textures, vertex buffers, and pipeline objects (`SDL_ReleaseGPUTexture`) EXCLUSIVELY on the main UI thread between frame render passes.
- NEVER destroy or release GPU resources on background worker threads while main-thread command buffers are recording. This triggers driver use-after-free crashes (`SEGV_MAPERR` in Vulkan/Metal drivers).

## Atomic Worker Thread Counter Placement

- Increment atomic thread counters (`active_threads.fetchAdd`) on the main thread IMMEDIATELY BEFORE spawning worker threads (`std.Thread.spawn`).
- Decrement the counter inside a `defer` block upon worker thread exit. Incrementing inside the thread body causes race conditions during rapid main-thread status checks.

## Non-Recursive Mutex Re-entrancy Invariants (`std.Io.Mutex`)

- `std.Io.Mutex` in Zig 0.16 is **non-recursive**. Functions or thread worker routines holding a mutex (`image_list_mutex` or `cache_mutex`) MUST NEVER invoke helper methods that attempt to re-acquire the same mutex on the same thread. Doing so causes an immediate self-deadlock.

## Event Channel Transport (`MpscQueue`) & Main Loop Wakeup

- Cross-thread events (e.g. image decodes, EXIF metadata, IPC socket commands) MUST be pushed directly to thread-safe `MpscQueue` instances (`BackgroundEvent`).
- Use `fs.wakeUpMainThread()` (`SDL_PushEvent(SDL_EVENT_USER)`) strictly as a lightweight main loop wakeup pulse, rather than passing raw C pointers through custom SDL event data fields.

## Offscreen & Frame Synchronization

- Synchronize offscreen texture copies and headless frame completions using GPU fences (`SDL_SubmitGPUCommandBufferAndAcquireFence` & `SDL_WaitForGPUFences`) instead of unfenced calls (`SDL_WaitForGPUIdle`).

## Event Loop Wakeup & Active Polling Synchronization

- Draining background event queues on the main thread often updates application state (e.g. GPU texture creation). If `processBackgroundEvents()` processes one or more events, it MUST return `true` (or flag activity) to include in `is_busy` / active polling mode for that frame. Otherwise, `SDL_WaitEvent` will block *before* rendering can occur, stalling UI updates until manual user interaction (e.g. mouse movement).

## Event Payload Pointer Ownership Transfer

- When transferring pointer ownership (e.g. `?*c.SDL_Surface` or string slices) from a background event payload into a long-lived cache struct, set the event payload field to `null` (or disown it) immediately before `defer evt.deinit()` runs. This ensures `evt.deinit()` cleanly skips destroying the transferred resource, preventing double-frees and use-after-free crashes.

## Atomic Reference Counting Memory Barriers

- Always use `.acq_rel` (Acquire-Release) on atomic fetch-decrement operations (e.g. `ref_count.fetchSub(1, .acq_rel)`) so that the thread performing final deallocation observes all prior writes from other threads.
