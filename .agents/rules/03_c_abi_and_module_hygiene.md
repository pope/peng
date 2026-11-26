---
trigger: glob
globs: '**/src/**/*.zig, **/build.zig'
description: SDL3 C-ABI encapsulation, hot-reload extern boundaries, IPC JSON contracts, visibility rules, and 3-tier test architecture.
---

# C-ABI, Visibility & Test Hygiene Rules

## 1. C-ABI Encapsulation & Hot-Reload Boundaries

- **Single Private C Translation Unit (`src/sdl/c.zig`)**:
  - Consolidate all C headers (`SDL3`, `SDL3_ttf`, `SDL3_image`, and
    `libturbojpeg` `<turbojpeg.h>` on non-Windows gated by
    `sdl_options.has_turbojpeg`) into `sdl_c` (`addTranslateC` in `build.zig`),
    re-exported solely via private `src/sdl/c.zig`. Never import `sdl_c` outside
    `src/sdl/`.
  - Wrap C handles and structs in native Zig types (`src/geom/` for 2D geometry
    converted at the `src/sdl/` boundary; `src/sdl/` for `FColor`, `Vertex`, and
    GPU handles; `pub const FRect = c.SDL_FRect;` is forbidden).
- **`extern struct` Wrappers, Hot-Reload Typing & C Strings**:
  - Declare any handle wrapper passed by value across `callconv(.c)` as
    `extern struct` (e.g. `pub const Window = extern struct { ptr: *c.SDL_Window };`).
  - Retain concrete single-item pointers (`*AppState`, `Window`,
    `?*RenderResources`, `?*SoftwarePresenter`, `*MeasureTextUserData`) across
    `viewer_update` in `src/viewer.zig` rather than erasing to `*anyopaque`.
  - Provide `inline for (std.meta.tags(Enum))` C-constant mapping helpers on
    wrapper enums, and pass C strings as `[:0]const u8` (never `[*c]const u8`,
    except `(ptr, len)` APIs like `TTF_GetStringSize`).

## 2. IPC Serialization & Visibility Discipline

- **Structured JSON IPC (`src/ipc/`)**:
  - Serialize all IPC responses with `std.json.Stringify` (`writeOkLine`,
    `writeErrorLine`, `writePreviewLine`, `writeSelectionsJson`) and parse client
    replies via `ipc.parseResponse` (`std.json.parseFromSlice(IpcResponse, ...)`),
    never raw string interpolation or prefix matching.
- **Strict Public Surface**:
  - In `src/app/systems/`, only `sysXxx` entry points and `runUpdatePhase` are
    `pub fn`.
  - In `src/ui/`, only top-level renderers (`renderFrame`, `renderPalette`,
    `renderEditPanel`, `renderStatsOverlay`, `buildRenderPacket`,
    `hasBlurredSurface`), `computeDrawDims`, `edit_panel` helpers
    (`formatValue`, `formatBrightness`, `formatContrast`, `renderSlider`), and
    `text_utils`/`theme` APIs are `pub fn`.
  - In executable roots (`*main.zig`), only `pub fn main` is public. Never mark
    declarations `pub` solely for same-file `test` blocks.

## 3. 3-Tier Zig 0.17 Test Architecture

- **No `refAllDecls` in Executable/Hot-Reload Roots**:
  - Never call `refAllDecls` or `refAllDeclsRecursive` in `src/main.zig`,
    `src/tui_main.zig`, `src/msg_main.zig`, `src/preview_main.zig`,
    `src/precache_main.zig`, `src/test_runner_main.zig`, or `src/viewer.zig`;
    wire submodule tests from each standalone package's own `root.zig` `test`
    block.
- **No Fake Opaque Pointers (`@ptrFromInt`)**:
  - Never forge non-null C/GPU handle pointers via `@ptrFromInt(0x1000)` in
    tests; use real headless/GPU handles (`sdl.Surface.create`,
    `sdl.gpu.Device.create`) or pure union variants.
- **3-Tier Coverage**:
  1. **Tier 1 (Pure Parsers & Math)**: Self-contained synthetic byte arrays in
     inline `test` blocks (`src/probe/`, `src/vfs/`, `src/geom/`) — never gated
     solely on external files with `catch return`.
  2. **Tier 2 (Subsystem & State Transitions)**: Drive state machines and
     `sysExecuteIntents`/`sysUpdateCache` via public inputs and assert resulting
     domain states.
  3. **Tier 3 (Headless Integration)**: End-to-end workflows, `--server` IPC, and
     golden screenshot pixel parity via `peng-test-runner`.
