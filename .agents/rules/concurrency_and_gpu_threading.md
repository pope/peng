# Concurrency & GPU Threading Invariants

## Main-Thread GPU Resource Lifecycles

- Release and deallocate all GPU textures, vertex buffers, and pipeline objects (`SDL_ReleaseGPUTexture`) EXCLUSIVELY on the main UI thread between frame render passes.
- NEVER destroy or release GPU resources on background worker threads while main-thread command buffers are recording. This triggers driver use-after-free crashes (`SEGV_MAPERR` in Vulkan/Metal drivers).

## macOS & Vulkan GPU Driver Setup

- On macOS, SDL3 GPU utilizes the Metal driver backend. Requests MUST specify `SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_MSL` during device creation (`SDL_CreateGPUDevice`).
- Query `SDL_GetGPUShaderFormats(device)` dynamically to bind MSL shaders on macOS and SPIR-V shaders on Vulkan/Linux.
- Do not set `SDL_HINT_VIDEO_DRIVER = "offscreen"` on macOS; use `SDL_WINDOW_HIDDEN` with standard Cocoa/Metal driver instead.
- 2D quad renderers supplying straight-alpha vertex colors must use standard `SDL_GPU_BLENDFACTOR_SRC_ALPHA` and `SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA` pipeline blend state to prevent additive over-brightness on semi-transparent overlays.

## Offscreen & Frame Synchronization

- Synchronize offscreen texture copies and headless frame completions using GPU fences (`SDL_SubmitGPUCommandBufferAndAcquireFence` & `SDL_WaitForGPUFences`) instead of unfenced calls (`SDL_WaitForGPUIdle`).

## Atomic Worker Thread Counter Placement

- Increment atomic thread counters (`active_threads.fetchAdd`) on the main thread IMMEDIATELY BEFORE spawning worker threads (`std.Thread.spawn`).
- Decrement the counter inside a `defer` block upon worker thread exit. Incrementing inside the thread body causes race conditions during rapid main-thread status checks.

## Non-Recursive Mutex Re-entrancy Invariants (`std.Io.Mutex`)

- `std.Io.Mutex` in Zig 0.16 is **non-recursive**. Functions or thread worker routines holding a mutex (`image_list_mutex` or `cache_mutex`) MUST NEVER invoke helper methods that attempt to re-acquire the same mutex on the same thread. Doing so causes an immediate self-deadlock.

## Event Channel Transport (`MpscQueue`) & Event Loop Wakeup

- Cross-thread events (e.g. image decodes, EXIF metadata, IPC socket commands) MUST be pushed directly to thread-safe `MpscQueue` instances (`BackgroundEvent`).
- Use `fs.wakeUpMainThread()` (`SDL_PushEvent(SDL_EVENT_USER)`) strictly as a lightweight main loop wakeup pulse, rather than passing raw C pointers through custom SDL event data fields.
- If `processBackgroundEvents()` processes one or more events, it MUST return `true` (or flag activity) to include in active polling mode for that frame. Otherwise, `SDL_WaitEvent` will block before rendering can occur, stalling UI updates.
- Before calling `SDL_Quit()`, unblock background `accept()` calls by triggering a dummy socket connection to ensure IPC worker threads exit cleanly.

## Event Payload Pointer Ownership Transfer

- When transferring pointer ownership (e.g. `?*c.SDL_Surface` or string slices) from a background event payload into a long-lived cache struct, set the event payload field to `null` (or disown it) immediately before `defer evt.deinit()` runs. This prevents double-frees and use-after-free crashes.

## Atomic Reference Counting Memory Barriers

- Always use `.acq_rel` (Acquire-Release) on atomic fetch-decrement operations (e.g. `ref_count.fetchSub(1, .acq_rel)`) so that the thread performing final deallocation observes all prior writes from other threads.
