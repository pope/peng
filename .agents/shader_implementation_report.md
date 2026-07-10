# Hybrid OpenGL/SDL3 Resampling Shader Implementation Report

This report summarizes our efforts to integrate custom GPU-based resampling filters (**Mitchell-Netravali** and **Lanczos3**) into the SDL3-based image viewer via a hybrid OpenGL rendering pipeline.

______________________________________________________________________

## 1. What We Accomplished

- **OpenGL Build Integration**: Linked the native system `GL` library in `build.zig` and configured `@cImport` in `src/main.zig` with `GL_GLEXT_PROTOTYPES` and `<GL/gl.h>` headers.
- **Driver Configuration**: Guaranteed that the window uses the OpenGL backend by setting `SDL_HINT_RENDER_DRIVER` to `"opengl"` at window creation time.
- **Filter Mode State Machine & Action Palette**: Added `mitchell` and `lanczos3` options to the `TextureScaleMode` enum, wired the corresponding actions into the Action Palette, and updated the Stats for Nerds overlay.
- **GLSL Shader Sources**: Written 4 fragment shaders in `src/main.zig` matching POT (`GL_TEXTURE_2D`) and NPOT (`GL_TEXTURE_RECTANGLE`) textures:
  - `mitchell_fragment_source` (2D) & `mitchell_rect_fragment_source` (Rectangle)
  - `lanczos3_fragment_source` (2D) & `lanczos3_rect_fragment_source` (Rectangle)
- **On-Demand Compilation**: Implemented `compileShader` and `createProgram` helpers to compile the shaders and link them on application startup.
- **Robust Cache Navigation**: Patched a list index underflow panic in `updateCache()` when cycling paths with fewer than 3 images.

______________________________________________________________________

## 2. Rendering Pipeline Iterations

We developed and refined the `.image` render pass in \[src/renderer.zig\](file:///home/pope/Code/peng/src/renderer.zig) over three major iterations:

### Iteration A: Initial Fixed-Function Hybrid

- **Approach**: Flushed the SDL3 renderer, bound the raw OpenGL texture ID (`SDL_PROP_TEXTURE_OPENGL_TEXTURE_NUMBER`), bound the fragment shader program, and drew a quad using fixed-function projection (`glOrtho`) and modelview matrices.
- **Result**: The first image (POT) rendered correctly, but navigating to other (NPOT) images showed a blank screen.
- **Diagnosis**: SDL3 uploads NPOT textures to the GPU as `GL_TEXTURE_RECTANGLE` instead of `GL_TEXTURE_2D`, which expects raw pixel coordinates ($0 \\dots \\text{width}$) and the `sampler2DRect` uniform in GLSL.

### Iteration B: Full Pipeline with Vertex Shader

- **Approach**: Added a custom vertex shader to pass texture coordinates (`gl_TexCoord[0] = gl_MultiTexCoord0`), and added a dynamic target selector query for `GL_TEXTURE_RECTANGLE` to map denormalized coordinates.
- **Result**: Images did not load at all (blank screen).
- **Diagnosis**: Re-writing the vertex shader bypassed `SDL_Renderer`'s internal texture matrices (`gl_TextureMatrix[0]`), projecting coordinates out-of-bounds. Also, the active OpenGL draw color (`glColor`) was left dirty (black/transparent) after the UI render pass.

### Iteration C: Texture Matrix & State Restoration

- **Approach**: Reverted to fragment-only shader linking to let the GPU's fixed-function vertex pipeline automatically resolve SDL's texture matrices. Re-introduced `glOrtho` for projection mapping, forced `glColor4f(1.0, 1.0, 1.0, 1.0)` for full brightness, and fully restored all cached GL states (`GL_ACTIVE_TEXTURE`, bindings, and current program) to prevent renderer side-effects.
- **Result**: The screen still displays blank when Mitchell or Lanczos3 is active.

______________________________________________________________________

## 3. Potential Remaining Bottlenecks (For Future Reference)

Since the shaders compile successfully (returning valid IDs like `41`) and the pipeline runs without crash or OpenGL errors (`GL_NO_ERROR`), the blank screen is likely caused by one of the following:

1. **OpenGL Context & Function Pointer Loading**:
   - **Issue**: On Linux/X11/Wayland, shader functions (`glUseProgram`, `glCreateShader`, etc.) are extension entry points. Although they compile against header prototypes, they must be resolved at runtime using an extension loader (like Glad/GLEW) or via `SDL_GL_GetProcAddress`. Calling them without manual address resolution can result in silent no-ops on some drivers.
2. **Viewport Coordinate Mapping**:
   - **Issue**: Even with `glOrtho` set to `SDL_GetRenderViewport`, high-DPI scaling or viewport clipping rects applied by `SDL_Renderer` might mismatch the logical coordinate space of our quad drawing.
3. **Texture Synchronization / Thread Boundaries**:
   - **Issue**: SDL3 textures might be bound to specific framebuffers or contexts that are not current when we run raw GL operations during the UI render loop.

______________________________________________________________________

## 4. Recommended Next Steps

If returning to this in the future:

- **Option 1: OpenGL Function Pointer Verification**: Wrap all modern OpenGL shader calls in checks using `SDL_GL_GetProcAddress` to verify that function entry points are loaded correctly.
- **Option 2: SDL3 Shader API (If Available)**: Look out for native shader support in the SDL3 GPU API if it is exposed in future releases, avoiding the raw OpenGL state-management hybrid completely.
