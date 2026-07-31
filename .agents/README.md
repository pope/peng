# `.agents` Configuration & Rules Index

This directory contains project-specific agent rules, subagent definitions, and skills for **Peng**.

______________________________________________________________________

## Core Rule Architecture (`.agents/rules/`)

- **[`01_memory_and_resource_safety.md`](rules/01_memory_and_resource_safety.md)**:
  Tagged union pattern matching (`switch (union)`), per-frame arenas, HashMap key lifecycle cleanup, typed worker signatures, non-negotiable structured error logging (`std.log`), slice aliasing protection, socket stream teardown, and worker early-exit error invariants (`failDecodeWorker`).

- **[`02_concurrency_and_architecture.md`](rules/02_concurrency_and_architecture.md)**:
  Main-thread exclusive GPU operations, non-recursive `std.Io.Mutex` safety, `std.Io.Group` task spawning & native cancellation, `MpscQueue` event transport, Zero-Dependency Intent Queue (`AppIntent`), `systems.zig` 5-stage engine pipeline (`sysSyncMetrics`), `OverlayFlags` packed structs, worker thread isolation (`DecodeArgs`/`PathScanArgs`/`StdinArgs`/`IpcServerArgs`), telemetry consolidation (`ViewerStats`), main-thread cache epoch versioning, and single-pass I/O header consolidation in workers.

- **[`03_c_abi_and_module_hygiene.md`](rules/03_c_abi_and_module_hygiene.md)**:
  Single canonical `@cImport` file (`src/sdl/c.zig`), C-handle encapsulation, complete enum mapping invariant, single top-level `@import` standard, prohibition of proxy re-exports, and `.empty` / `.init(...)` initialization style.

- **[`04_ui_rendering_and_performance.md`](rules/04_ui_rendering_and_performance.md)**:
  2-Pass UI Render Packet architecture (`RenderPacket`), allocation-free execution pass, logical vs physical DPI coordinate scaling, zero-area scissor skipping, SIMD zero-copy bounds safety, and case-insensitive sorting (`lessThanIgnoreCase`).

______________________________________________________________________

## Skills (`.agents/skills/`)

- **[`zig-gui-practices`](skills/zig-gui-practices/SKILL.md)**: Best practices for Zig GUI development with Clay, SDL3 GPU rendering, EXIF image decoding, shader optimization, DPI layout math, and SIMD vector reference recipes.

______________________________________________________________________

## Subagents (`.agents/agents/`)

- **`zig-reviewer`**: Audits Zig source code against all 4 core project rules.
- **`task-executor`**: Fast-path execution subagent for straightforward code implementations.
- **`agent-artifacts-reviewer`**: Audits `.agents/` rules, skills, agent definitions, and documentation for consistency, information density, and rule vs skill classification.
