# Concurrency & GPU Threading Invariants

## Main-Thread GPU Resource Lifecycles

- Release and deallocate all GPU textures, vertex buffers, and pipeline objects (`SDL_ReleaseGPUTexture`) EXCLUSIVELY on the main UI thread between frame render passes.
- NEVER destroy or release GPU resources on background worker threads while main-thread command buffers are recording. This triggers driver use-after-free crashes (`SEGV_MAPERR` in Vulkan/Metal drivers).

## Atomic Worker Thread Counter Placement

- Increment atomic thread counters (`active_decode_threads.fetchAdd`) on the main thread IMMEDIATELY BEFORE spawning worker threads (`SDL_CreateThread`).
- Decrement the counter inside a `defer` block upon worker thread exit. Incrementing inside the thread body causes race conditions during rapid main-thread status checks.

## Offscreen & Frame Synchronization

- Synchronize offscreen texture copies and headless frame completions using GPU fences (`SDL_SubmitGPUCommandBufferAndAcquireFence` & `SDL_WaitForGPUFences`) instead of unfenced calls (`SDL_WaitForGPUIdle`).
