# SDL3 GPU & macOS Native Rendering Rules

## Shader Formats & Device Creation

- On macOS, SDL3 GPU utilizes the Metal driver backend.
- `SDL_CreateGPUDevice` must request `SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_MSL`.
- Query `SDL_GetGPUShaderFormats(device)` dynamically to bind MSL shaders on macOS and SPIR-V shaders on Vulkan/Linux.

## Headless & Offscreen Synchronization

- Do not set `SDL_HINT_VIDEO_DRIVER = "offscreen"` on macOS; use `SDL_WINDOW_HIDDEN` with standard Cocoa/Metal driver instead.
- Synchronize offscreen copies and headless frame completions using fences (`SDL_SubmitGPUCommandBufferAndAcquireFence` & `SDL_WaitForGPUFences`) instead of un-fenced `SDL_WaitForGPUIdle`.

## 2D UI Pipeline Blend Modes

- 2D quad renderers supplying straight-alpha vertex colors must use standard `SDL_GPU_BLENDFACTOR_SRC_ALPHA` and `SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA` pipeline blend state to prevent additive over-brightness on semi-transparent overlays.

## Background IPC Thread Teardown

- Before calling `SDL_Quit()`, unblock background `accept()` calls by triggering a dummy socket connection to ensure IPC worker threads exit cleanly.
