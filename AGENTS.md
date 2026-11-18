# Peng Agent Guidelines (`AGENTS.md`)

**Peng** is a GPU-accelerated image viewer and photo triage tool written in
**Zig 0.17.0** with **SDL3 GPU** (Vulkan/Metal), licensed under **GNU GPLv3**.

______________________________________________________________________

## 1. Build, Test & Formatting Commands

- `zig build` — Build `peng`, `peng-msg`, and `peng-test-runner`.
- `zig build test-unit` — Fast unit suite across all 17 modules (`geom`, `probe`,
  `vfs`, `triage`, `palette`, `sdl`, `gpu`, `state`, `cache`, `core`, `app`,
  `ui`, `intents`, `config`, `input`, `ipc`, `thumbcache`).
- `zig build test-<mod>` — Isolated module tests (`geom`, `probe`, `vfs`,
  `triage`, `palette`, `thumbcache`, `cache`, `core`, `state`, `gpu`, `ui`,
  `ipc`).
- `zig build test-integration` — Headless integration & golden screenshot suite.
- `zig build test` — Full unit + headless integration suite.
- `zig build -Dhot_reload=true` — Verify shared-library (`libviewer`) build.
- `zig build shaders` — Compile `src/gpu/shaders/*.glsl` to `.spv` and `.msl`.
- `zig fmt --check src/ build.zig` — Verify canonical Zig formatting.

______________________________________________________________________

## 2. Git Workflow & Repository Hygiene

- **User-Only Staging (Strictly NO `git add`)**:
  - **NEVER** run `git add`, `git rm`, `git restore --staged`, `git reset`,
    `git rebase`, `git push`, `git checkout .`, or `git restore .`.
  - Leave all edits unstaged in the working tree; never unstage or disturb files
    already staged by the user in the index.
- **Explicit Commit Sign-Off**:
  - **NEVER** run `git commit` autonomously, even when all tests pass.
  - Once verified, present a concise conventional commit message, wait for the
    user to stage desired changes and give explicit sign-off, and commit only
    what is staged (`git status`, `git diff`, and `git log` checks encouraged).
- **Test Fixture & Scratch Isolation**:
  - Tests **MUST ONLY** use committed `testfiles/` fixtures (or self-cleaning
    temporary directories / `testfiles/current-run/`). **NEVER** scan `"."` or
    reference personal/untracked paths (`Capture/`, `ThumbTest/`).
  - Never commit scratch or audit scripts into VCS; run inline checks or store
    temporary scripts in `<appDataDir>/brain/<id>/scratch/`.

______________________________________________________________________

## 3. Frame Pipeline & Acyclic Package Boundaries (`src/`)

- **North-Star Game-Engine Frame Loop (`src/viewer.zig`, `src/app/systems/root.zig`)**:
  - Each frame executes unidirectionally: **1. Ingest** (`pollFrameInput` + O(1)
    `drainWorkerEvents` staging onto CPU state, zero GPU/VRAM calls) $\\to$
    **2a. Reduce Intents** (input/IPC/UI/motion systems push `AppIntent`s reduced
    by `sysExecuteIntents`, zero render-thread disk I/O) $\\to$ **2b. Sync
    Hardware & Workers** (`sysSyncWindow` $\\to$ `sysProcessAssetUploads` $\\to$
    `sysUpdateCache`) $\\to$ **3. Render Snapshot**
    (`buildUiViewModel(*const AppState, *const RenderResources, now_ms)` $\\to$
    `ui.layout.renderFrame`, recording next-frame hit rects on explicit
    `*InteractionState`).
  - **Intentional Nuances**: (a) Phase 2b runs *before* `renderFrame` so staged
    thumbnails/surfaces promote to GPU and draw with **0-frame lag**; (b)
    data-plane worker surfaces stage directly on CPU cache unions while only
    `ipc_command`s emit `AppIntent`s (keeping `AppIntent` pure value data); (c)
    startup/discrete directory opens spawn scan/slot-0 workers immediately to
    overlap cold-start I/O with window/Vulkan initialization.
- **Zero-SDL Pure Packages**:
  - `geom` (pure `std` 2D geometry, DPI, `FRect` `RectCut`), `probe` (MIME,
    EXIF, RAW headers), `vfs` (dir scan, CBZ seek, RAW+JPEG pairs), `triage`
    (picks/rejects, 256-bit SIMD filter), `palette` (unmanaged fuzzy/nav state),
    `thumbcache` (Freedesktop MD5/PNG `tEXt`), `intents` (`AppIntent`,
    `actions.zig`), `ipc` (UDS JSON protocol), `state` (`ViewerState`, `UiState`,
    `InteractionState`, `AnimationState`, motion controllers), `config` (CLI).
  - `ui`: Immediate-mode `RectCut` layouts, `UiViewModel`, `UiDrawList` & 2-pass
    `RenderPacket` builder. **Zero `@import("sdl")`, zero `@import("core")`**
    (imports `cache`, `geom`, `gpu`, `intents`, `palette`, `state`).
- **Engine & Hardware Packages**:
  - `sdl` (sole C wrapper via private `src/sdl/c.zig`), `core` (`display`,
    `mpsc_queue`, `thumbcache`), `cache` (`ImageCache`, `CacheEntry`,
    `job_epochs`), `input` (`FrameInput` polling & shortcuts), `gpu` (pipelines,
    shaders, `TextCache`, `UploadStagingBuffer`, `pass.zig`), `app` (`state.zig`,
    `events.zig`, `systems/`, `workers/` — **zero `@import("ui")`**).
  - `src/viewer.zig`: Composition root bridging `app` and `ui` via
    `buildUiViewModel(*const AppState, *const RenderResources, now_ms)`
    (static or `-Dhot_reload=true`).
- **Boundary Rules**: Pure/engine packages MUST NOT import `app`. Never import
  across modules by relative file path (use `@import("<mod>")`), and never add
  cross-module `pub const` proxy re-exports or `OldName = NewName` aliases.

______________________________________________________________________

## 4. Zig 0.17 Style, Formatting & Documentation

- **Two-Block Top-of-File Imports**:
  1. Alphabetical `const x = @import("...");` (once per target, never inline
     `.Symbol` destructuring, never mid-file).
  2. Blank line, then alphabetical symbol aliases (`const Foo = x.Foo;`).
- **Zig 0.17 Idioms**:
  - Entrypoints use `pub fn main(init: std.process.Init) !void` threading
    `init.io`, `init.gpa`, `init.minimal.args`, and `init.environ_map` (never
    `std.c.getenv`).
  - Standard streams (`stdout`/`stderr`) **MUST** use `.writerStreaming(io, &b)`
    (never positional `.writer(io, &b)`, which `ESPIPE`s/overwrites offset `0`).
  - Use leading-dot `.empty` / `.init(...)` decl literals, unmanaged containers
    (`std.ArrayList`, `std.MultiArrayList`, `*HashMapUnmanaged`), `@backingInt` /
    `@fromBackingInt` (never `@intFromEnum`/`@enumFromInt` or packed `@bitCast`),
    `@divCeil`, `@splat`, `std.mem.print` / `allocator.print` (never
    `std.fmt.bufPrint`/`allocPrint`), `std.mem.find` / `findScalar` (never
    `std.mem.indexOf*`), and `std.Io.Clock.awake.now(io)` in workers.
- **Exhaustive Pattern Matching & Minimal Visibility**:
  - `switch` on domain enums and tagged unions (`ActivePaletteMode`,
    `PaletteLifecycle`, `PaletteMode`, `PromptKind`, `EditParam`, `AppIntent`,
    `AdjustIntent`, `IpcCommand`, `ZoomPreset`, `TextureScaleMode`,
    `DecodeMode`, `DecodePriority`, `ScrollCadence`, `PanTap`, `ZoomPhase`,
    `ZoomDirection`, `ResidentAsset`, `InFlightState`, `ThumbnailState`,
    `DisplayState`, `DragState`, `MediaEntry`, `BackgroundEvent`) **MUST** list
    every variant without `else =>` wildcards or `if (x == .a)` chains. Use
    `intents.getSpec` for `EditParam` metadata.
  - Default declarations to private; delete dead/write-only zombie symbols and
    trivial getter tests.
- **Mandatory `///` Docs & Strict `<= 80`-Column Ceiling**:
  - Place an adjacent `///` doc comment immediately above every `pub const <Name> = struct`
    and `pub fn <name>` (documenting purpose, units/spaces, and ownership).
  - Keep all Zig, GLSL, and C lines `<= 80` columns (except unbreakable comment
    URLs) and indentation `<= ~6` levels. Put trailing commas inside
    nested/multi-field struct and union literals so `zig fmt` expands each
    level onto its own lines and closing braces never stack (`} } },` is
    forbidden):
    ```bash
    git diff | awk '/^\+[^+]/ { if (length($0) > 81) print length($0)-1, $0 }'
    ```

______________________________________________________________________

## 5. Scoped Rules, Skills & Subagents (`.agents/`)

- **Glob-Triggered Rules (`.agents/rules/`)**:
  - [`01_memory_and_resource_safety.md`](.agents/rules/01_memory_and_resource_safety.md)
  - [`02_concurrency_and_architecture.md`](.agents/rules/02_concurrency_and_architecture.md)
  - [`03_c_abi_and_module_hygiene.md`](.agents/rules/03_c_abi_and_module_hygiene.md)
  - [`04_ui_rendering_and_performance.md`](.agents/rules/04_ui_rendering_and_performance.md)
- **Procedural Skills (`.agents/skills/`)**:
  - [`zig-gui-practices`](.agents/skills/zig-gui-practices/SKILL.md) &
    [`zig-gui-animations`](.agents/skills/zig-gui-animations/SKILL.md)
- **Custom Subagents (`.agents/agents/`)**:
  - [`zig-reviewer`](.agents/agents/zig-reviewer.md),
    [`task-executor`](.agents/agents/task-executor.md),
    [`agent-artifacts-reviewer`](.agents/agents/agent-artifacts-reviewer.md)
