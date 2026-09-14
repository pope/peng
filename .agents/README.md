# `.agents` Configuration & Rules Index

This directory contains project-specific agent rules, subagent definitions, and skills for **Peng**.

______________________________________________________________________

## Core Rule Architecture (`.agents/rules/`)

- **[`01_memory_and_resource_safety.md`](rules/01_memory_and_resource_safety.md)**:
  Tagged union pattern matching (`switch (union)`), per-frame arenas, HashMap key lifecycle cleanup, typed worker structs, structured logging (`std.log`), slice aliasing protection, socket teardown (`stream.close`), worker early-exit invariants, co-located `errdefer` + `try` cleanup, lifecycle deinitialization (`RenderResources`, `DisplayState`, `ParsedArgs`), zero full-file allocation streaming for large media, saturating offset arithmetic, and strict domain invariant enforcement via validation constructors.

- **[`02_concurrency_and_architecture.md`](rules/02_concurrency_and_architecture.md)**:
  `AppState` vs `ViewerState` structural split, main-thread GPU operations, non-recursive `std.Io.Mutex` safety, `std.Io.Group` task spawning & native cancellation, daemon thread isolation, `MpscQueue` event transport, zero-dependency `AppIntent` queue, worker event draining (`drainWorkerEvents`), 11-step unnested systems pipeline (`src/app/systems/`) with single-pass intent dispatch, `OverlayFlags` packed structs, isolated worker arguments, `ViewerStats` telemetry snapshots, atomic generation epoch versioning, single-pass I/O header consolidation, demand-first cache priority gating, and cooperative worker pruning.

- **[`03_c_abi_and_module_hygiene.md`](rules/03_c_abi_and_module_hygiene.md)**:
  Single canonical `@cImport` (`src/sdl/c.zig`), C-handle encapsulation, complete enum mapping invariant, null-terminated slice signatures, top-of-file alphabetical import & alias block separation, prohibition of proxy re-exports and in-flight backward-compatibility aliases, `.empty`/`.init` inference, Zig 0.16 test architecture (prohibition of `refAllDecls` in app roots, 3-tier testing, accessor test prohibition, and zombie property pruning), standalone package hierarchy & app-private core (`src/app/core/`), minimal declaration visibility (least privilege `pub`), mandatory doc comments (`///`), C-ABI `extern struct` handle wrappers, and code formatting & line-length invariants (80-col goal, 100-col hard ceiling, trailing commas, `zig fmt` compliance).

- **[`04_ui_rendering_and_performance.md`][rule-04]**:
  2-Pass UI `RenderPacket` pipeline (extraction vs allocation-free execution),
  logical vs physical DPI scaling, zero-area scissor skipping, SIMD bounds
  safety, case-insensitive sorting (`lessThanIgnoreCase`), event loop dimension
  tracking (`is_busy`), GPU text texture alpha decoupling, modal dismissal input
  decoupling (`isAcceptingInput`), Universal Pixel Zoom & pre-scaled layout
  invariants, Clay UI modularization, progressive loading dimension purity
  (prohibition of worker thumbnail fallback), monotonic area updates, and
  dissolve quad sizing invariance.

* **[`05_git_workflow_and_repository_hygiene.md`](rules/05_git_workflow_and_repository_hygiene.md)**:
  User-only staging invariant (strictly NO `git add`/`git rm`), never unstage user changes (`git reset`/`git restore --staged`), explicit human commit sign-off invariant, commit message review workflow, permitted read-only Git operations (`git status`, `git diff`, `git log`), test fixture resource isolation (`testfiles/` only), and prohibition of extraneous scratch or audit scripts in version control.

______________________________________________________________________

## Skills (`.agents/skills/`)

- **[`zig-gui-practices`](skills/zig-gui-practices/SKILL.md)**: Best practices for Zig GUI development with Clay, SDL3 GPU rendering, EXIF image decoding, shader optimization, DPI layout math, and SIMD vector reference recipes.
- **[`zig-gui-animations`](skills/zig-gui-animations/SKILL.md)**: Architectural patterns and procedural recipes for zero-allocation Data-Oriented animation state, numerical easing safety, GPU text vertex alpha blitting, and Clay immediate-mode modal alpha scaling.

______________________________________________________________________

## Subagents (`.agents/agents/`)

- **`zig-reviewer`**: Audits Zig source code against all 5 core project rules.
- **`task-executor`**: Fast-path execution subagent for straightforward code implementations.
- **`agent-artifacts-reviewer`**: Audits `.agents/` rules, skills, agent definitions, and documentation for consistency, information density, and rule vs skill classification.

[rule-04]: rules/04_ui_rendering_and_performance.md
