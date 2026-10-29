# C-ABI & Module Hygiene Rules

## 1. C-ABI Encapsulation & Dynamic Library Boundaries

- **Single Canonical C Translation Wrapper (`src/sdl/c.zig`)**:
  - Consolidate all C header imports (`SDL3`, `SDL3_ttf`, `SDL3_image`) into the
    `sdl_c` `addTranslateC` step in `build.zig`, re-exported solely via
    `src/sdl/c.zig`. Never import `sdl_c` directly in `src/app/`, `src/ui/`,
    `src/state/`, or `src/config/`.
- **Private C Module & Handle Encapsulation**:
  - Keep `c = @import("c.zig")` private to `src/sdl/`. Encapsulate C handles
    behind type-safe Zig structs with explicit methods rather than exposing raw
    C pointers in domain code.
- **`extern struct` Handle Wrappers & Hot-Reload Typing**:
  - Any wrapper struct passed by value across `callconv(.c)` boundaries MUST be
    declared `extern struct` (e.g.
    `pub const Window = extern struct { ptr: *c.SDL_Window };`).
  - Across dynamic library / hot-reload boundaries (`viewer_update` in
    `src/viewer.zig`), retain concrete single-item pointers (`*AppState`,
    `Window`, `*RenderResources`, `*MeasureTextUserData`) rather than erasing
    types to `*anyopaque`.
- **Complete Enum Mapping & Null-Terminated Slices**:
  - Every wrapper enum converting C constants to Zig MUST provide an
    `inline for (std.meta.tags(Enum))` conversion helper.
  - Pass C-string parameters as null-terminated slices (`[:0]const u8`) rather
    than `[*c]const u8` (except when an SDL3 API natively accepts `ptr` + `len`
    such as `TTF_GetStringSize`).

## 2. Package Hierarchy, App-Private Core & Build Graph

- **Top-Level Package Isolation (`src/`)**:
  - `src/probe/`: Pure header dimension, MIME, and EXIF parsers (standalone,
    zero module imports).
  - `src/vfs/`: Pure filesystem scanning, CBZ ZIP central-directory seeking,
    media entry models, and RAW+JPEG pair consolidation (zero SDL3/Clay
    linkage).
  - `src/triage/`: Pure triage selection maps, arena string keys, JSON
    export serialization, and 256-bit SIMD visibility scans (imports `vfs`;
    zero SDL/Clay).
  - `src/palette/`: Pure command palette state models, fuzzy scoring
    (`fuzzig`), and directory navigation history (zero SDL/Clay).
  - `src/thumbcache/`: Pure Freedesktop Shared Thumbnail Cache specification,
    RFC 3986 URI encoding, MD5 hashing, PNG `tEXt` chunk parsing and splicing,
    and atomic PNG writing (imports `probe`, `vfs`; zero `intents`, SDL/Clay).
  - `src/intents/`: Pure `AppIntent` variants, `ActionDef` registry
    (`actions.zig`), and intent payload structs (imports `triage`).
  - `src/input/`: Pure `FrameInput` event polling and shortcut mapping.
  - `src/ipc/`: Pure `IpcCommand` parsing, `IpcResponse` JSON schema
    (`parseResponse`, `writeOkLine`, `writeErrorLine`, `writePreviewLine`),
    `IpcServer` handle, and UDS socket helpers (`readLineTimeout`,
    `readLineTimeoutAlloc`).
  - `src/state/`: Pure visual/UI data models (`ViewerState`, `UiState`,
    `AnimationState`, `SnackbarState`, `PanController`, `ZoomController`).
    Zero SDL3, zero C library linkage, zero I/O.
  - `src/config/`: CLI argument parsing (`cli.zig`).
  - `src/gpu/`: GPU pipelines, geometry tessellation, render image commands,
    texture cache, shaders (`src/gpu/shaders/`), resources, texture staging
    buffers, compute unpack pipelines, and GPU texture uploads (zero Clay
    linkage).
  - `src/sdl/`: Type-safe SDL3, SDL3_image, SDL3_ttf, and SDL3 GPU wrappers.
  - `src/ui/`: Clay layout builders (`layout.zig`, `palette.zig`,
    `edit_panel.zig`, `stats.zig`), `UiViewModel` presentation snapshot
    (`view_model.zig`), 2-pass GPU renderer (`renderer.zig`), text utilities
    (`text_utils.zig`), theme styling (`theme.zig`), and encapsulated Clay
    interaction / hit-testing (`interaction.zig`). Exclusive consumer of
    `zclay` in the repository.
  - `src/viewer.zig`: Thin coordinator for frame update and render loop entry
    point (compiled statically by default, or as a hot-reloadable shared library
    `viewer` / `libviewer` when built with `-Dhot_reload=true`).
- **Engine Core (`src/core/`)**:
  - State-free utilities (`display.zig`, `events.zig`, `image.zig`,
    `thumbcache.zig`) live in `src/core/`.
  - **Acyclic Dependency Invariant**: Pure modules (`probe`, `vfs`, `triage`,
    `palette`, `thumbcache`, `intents`, `input`, `ipc`, `state`, `config`,
    `core`, `gpu`) MUST NOT import `AppState`, `src/app/systems/`, or
    `src/app/workers/`. Never cross module boundaries via relative file paths
    (e.g. `@import("probe/root.zig")` from `src/main.zig`); always use canonical
    module namespace (`@import("probe")`).
- **Zig 0.17 `std.process.Init` & `std.Io` Streaming I/O Invariants**:
  - Entrypoints (`pub fn main(init: std.process.Init) !void`) MUST thread
    `init.io`, `init.gpa`, `init.minimal.args`, and `init.environ_map`
    (`*const std.process.Environ.Map`) into subsystems rather than calling C's
    `std.c.getenv` or legacy global environment helpers.
  - When writing to `stdout` or `stderr` (`std.Io.File.stdout()`,
    `std.Io.File.stderr()`), ALWAYS use `.writerStreaming(io, &buf)` (or
    `std.Io.File.Writer.initStreaming`). Never call `.writer(io, &buf)` on
    standard streams: in Zig 0.17, `File.writer` defaults to `.mode = .positional` (`pwritev` at offset `0`), which fails with `ESPIPE` on pipes
    and TTYs before falling back to streaming and overwrites offset `0` when
    redirected with `>>`.
  - Format all IPC server responses via `std.json.Stringify` (`writeOkLine`,
    `writeErrorLine`, `writePreviewLine`,
    `NavigationState.writeSelectionsJson` using `encodeJsonStringChars`) and
    validate client responses with `ipc.parseResponse`
    (`std.json.parseFromSlice(IpcResponse, ...)`) rather than raw string
    interpolation or prefix matching.
- **Build Targets & Test Steps (`build.zig`)**:
  - Executables: `peng` (`src/main.zig`), `peng-msg` (`src/msg_main.zig`), and
    `peng-test-runner` (`src/test_runner_main.zig`).
  - Build & Test Commands:
    - `zig build`: Build application binaries.
    - `zig build test-unit`: Run fast unit tests across all 15 module test
      targets (`probe`, `vfs`, `triage`, `palette`, `sdl`, `gpu`, `state`,
      `core`, `app`, `ui`, `intents`, `config`, `input`, `ipc`, `thumbcache`).
    - `zig build test-probe`: Run `probe` (`src/probe/root.zig`) unit tests.
    - `zig build test-gpu`: Run `gpu` (`src/gpu/root.zig`) unit tests.
    - `zig build test-state`: Run `state` (`src/state/root.zig`) unit tests.
    - `zig build test-vfs`: Run `vfs` (`src/vfs/root.zig`) unit tests.
    - `zig build test-triage`: Run `triage` (`src/triage/root.zig`) unit tests.
    - `zig build test-palette`: Run `palette` (`src/palette/root.zig`) unit
      tests.
    - `zig build test-thumbcache`: Run `thumbcache` (`src/thumbcache/root.zig`)
      unit tests.
    - `zig build test-core`: Run `core` (`src/core/root.zig`) unit tests.
    - `zig build test`: Run all unit tests plus headless integration tests
      (`peng-test-runner`).
    - `zig build shaders`: Compile GLSL shaders in `src/gpu/shaders/` to SPIR-V
      (`.spv`) and Metal (`.msl`).

## 3. Imports, Visibility, Pattern Matching & Idiomatic Style

- **Top-of-File Two-Block Alphabetical Imports & Aliases**:
  1. **Block 1 (`@import`)**: Import each external package or source file ONCE
     at the very top of the file, sorted alphabetically by identifier name.
     Never destructure on an `@import` line (`const X = @import("foo.zig").X;`
     is forbidden) and never place `@import` mid-file.
  2. **Block 2 (Symbol Aliases)**: Separated from Block 1 by a single blank
     line; alias extracted symbols (`const AppState = app_state.AppState;`)
     sorted alphabetically by symbol name.
- **No Proxy Re-Exports or Backward-Compatibility Aliases**:
  - Do NOT re-export types from unrelated sub-modules (`src/app/root.zig` must
    not re-export `ipc` or `core` internals).
  - Do NOT introduce `pub const OldName = NewName;` aliases during refactors;
    update all call sites to the canonical symbol and delete superseded names.
- **Result Location Initialization Style (`.empty`, `.init(...)`)**:
  - Use leading-dot inference when the LHS type is explicit (e.g.
    `generation: std.atomic.Value(usize) = .init(0)` instead of repeating
    `std.atomic.Value(usize).init(0)`).
- **Exhaustive Enum & Tagged Union Pattern Matching (Anti-`else => ...`)**:
  - `switch` statements on core domain enums and tagged unions (`PaletteMode`,
    `EditParam`, `EditDomain`, `AppIntent`, `AdjustIntent`, `IpcCommand`,
    `IpcMode`, `ZoomPreset`, `TextureScaleMode`, `ResidentAsset`,
    `InFlightStage`, `ThumbnailState`, `DisplayState`, `DragState`,
    `MediaEntry`, `DirectoryEntry`, `BackgroundEvent`) MUST exhaustively
    list all variants without wildcard `else => ...` branches (including
    `else => {}`, `else => null`, `else => false`, `else => 0`, or
    `else => return`) so adding or modifying a variant triggers compile-time
    errors at every site.
  - Parameter metadata must be retrieved via `intents.getSpec(param)` backed by
    the compile-time `ParamSpec` table instead of ad-hoc switch arms.
  - Group shared cases explicitly (`.inactive, .files, .actions => {}`,
    `.filesystem, .archive_entry => null`) and never use chained
    `if (mode == .a) ... else if (mode == .b)` on enums.
- **Minimal Visibility (`pub`) & Dead-Code Pruning**:
  - Default all declarations to private (`fn`, `const`). Only mark symbols `pub`
    when required across file boundaries or by `@hasDecl` reflection (e.g.
    `deinitQueueItem`).
  - In `src/app/systems/`, only `sysXxx` entry points and `runUpdatePhase` are
    `pub fn`. In `src/ui/`, only top-level render orchestrators (`renderFrame`,
    `renderPalette`, `renderStatsOverlay`, `renderClayCommands`) and
    `interaction` query/lifecycle APIs are `pub fn`. In executable roots, only
    `pub fn main` is public.
  - Same-file `test` blocks can access private declarations directly; never mark
    a symbol `pub` solely for same-file tests.
  - **Zombie Pruning**: Any function, struct, or write-only struct field with
    zero production reads/callers reachable from `main()` MUST be deleted along
    with any obsolete tests referencing it.

## 4. Zig 0.17 Test Architecture

- **No `std.testing.refAllDecls` in Application Roots**:
  - Never call `refAllDecls` or `refAllDeclsRecursive` in `src/main.zig`,
    `src/msg_main.zig`, or `src/viewer.zig`. Standalone packages expose internal
    submodule tests in their own `root.zig` `test` block.
- **3-Tier Testing Architecture**:
  1. **Tier 1 (Pure Algorithm & Parser Tests)**: Inline `test "..."` blocks for
     stateless math, binary parsers (`src/probe/root.zig`,
     `src/vfs/root.zig`), and pixel converters using self-contained
     synthetic byte arrays (never relying solely on external disk fixtures
     guarded by `catch return`).
  2. **Tier 2 (Subsystem & State Transition Tests)**: Test state machines and
     intent dispatchers through public inputs and resulting state transitions.
  3. **Tier 3 (Black-Box Integration Tests)**: Verify end-to-end user workflows,
     IPC commands, and golden screenshots via `peng-test-runner`.
- **No Trivial Accessor Tests**:
  - Do not write unit tests solely asserting on trivial getters, setters, or
    1-to-1 enum-to-integer mappings; test the consuming subsystem instead.

## 5. Mandatory Doc Comments (`///`) & 80-Column Formatting

- **Mandatory `///` Doc Comments**:
  - Every `pub const <Name> = struct` and `pub fn <name>` MUST have an adjacent
    `///` doc comment immediately above it (no blank lines or `//` comments in
    between) describing purpose, units/coordinate spaces, and ownership/`deinit`
    contracts.
- **Strict 80-Column Line Length & Indentation Ceiling**:
  - All Zig, GLSL, and C lines MUST NOT exceed 80 characters (except unbreakable
    `https://...` URLs on dedicated comment lines and existing ASCII tables).
  - Keep peak indentation at or below 24–28 columns (~6 levels) using early
    returns, loop `continue`/`break` guards, and private helper functions.
  - Use trailing commas for multi-line wrapping and verify formatting with
    `zig fmt --check <file>` and:
    ```bash
    git diff | awk '/^\+[^+]/ { if (length($0) > 81) print length($0)-1, $0 }'
    ```
