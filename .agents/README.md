# `.agents` Configuration & Rules Index

This directory contains project-specific agent rules, subagent definitions, and skills for **Peng**.

______________________________________________________________________

## Core Rule Architecture (`.agents/rules/`)

- **[`01_memory_and_resource_safety.md`](rules/01_memory_and_resource_safety.md)**:
  Tagged union pattern matching (`switch (union)`), per-frame arenas, HashMap key lifecycle cleanup, typed worker signatures, non-negotiable structured error logging (`std.log`), slice aliasing protection, socket stream teardown, worker early-exit error invariants, co-located resource cleanup (`errdefer` + `try` invariant), lifecycle deinitialization guardrails (`RenderResources.deinit(gpa)`, `DisplayState.deinit(gpa)`, `ParsedArgs.deinit(gpa)`), zero full-file allocation streaming for large media formats, saturating arithmetic on untrusted offsets, and strict domain invariant enforcement via tagged unions with validation constructors.

- **[`02_concurrency_and_architecture.md`](rules/02_concurrency_and_architecture.md)**:
  AppState vs ViewerState structural split (`src/app/state.zig` vs `src/state/viewer_state.zig`), main-thread exclusive GPU operations, non-recursive `std.Io.Mutex` safety, `std.Io.Group` task spawning & native cancellation, `MpscQueue` event transport, Zero-Dependency Intent Queue (`AppIntent`), worker event draining (`drainWorkerEvents`), `src/app/systems/` unnested top-level system pass engine pipeline (`sysExecuteIpcCommands`, `sysProcessInput`, `sysExecuteIntents`, `sysProcessPaletteInput`, `sysUpdateViewport`, `sysUpdateSlideshow`, dual `sysExecuteIntents`, `sysProcessAssetUploads`, `sysUpdateCache`, `sysSyncMetrics`), `OverlayFlags` packed structs, worker thread isolation (`DecodeArgs`/`PathScanArgs`/`StdinArgs`/`IpcServerArgs`), telemetry consolidation (`ViewerStats`), CacheSlotMap epoch versioning, and single-pass I/O header consolidation in workers.

- **[`03_c_abi_and_module_hygiene.md`](rules/03_c_abi_and_module_hygiene.md)**:
  Single canonical `@cImport` file (`src/sdl/c.zig`), C-handle encapsulation, complete enum mapping invariant, single top-level `@import` standard, prohibition of proxy re-exports, `.empty` / `.init(...)` initialization style, Zig 0.16 lazy test discovery mechanics (`std.testing.refAllDecls` across module boundaries and `_ = @import(...)` within modules), standalone package hierarchy & app-private core (`src/app/core/`) architecture, and mandatory doc comments (`///`) on all public structs and functions.

- **[`04_ui_rendering_and_performance.md`](rules/04_ui_rendering_and_performance.md)**:
  2-Pass UI Render Packet architecture (`RenderPacket`), allocation-free execution pass, logical vs physical DPI coordinate scaling, zero-area scissor skipping, SIMD zero-copy bounds safety, case-insensitive sorting (`lessThanIgnoreCase`), event loop dimension tracking, GPU text texture alpha decoupling (RGB cache keys + vertex alpha modulation), and modal dismissal input decoupling (`isAcceptingInput`).

______________________________________________________________________

## Skills (`.agents/skills/`)

- **[`zig-gui-practices`](skills/zig-gui-practices/SKILL.md)**: Best practices for Zig GUI development with Clay, SDL3 GPU rendering, EXIF image decoding, shader optimization, DPI layout math, and SIMD vector reference recipes.
- **[`zig-gui-animations`](skills/zig-gui-animations/SKILL.md)**: Architectural patterns and procedural recipes for zero-allocation Data-Oriented animation state, numerical easing safety, GPU text vertex alpha blitting, and Clay immediate-mode modal alpha scaling.

______________________________________________________________________

## Subagents (`.agents/agents/`)

- **`zig-reviewer`**: Audits Zig source code against all 4 core project rules.
- **`task-executor`**: Fast-path execution subagent for straightforward code implementations.
- **`agent-artifacts-reviewer`**: Audits `.agents/` rules, skills, agent definitions, and documentation for consistency, information density, and rule vs skill classification.
