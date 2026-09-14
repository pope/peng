# `.agents` Configuration & Rules Index

This directory contains project-specific agent rules, subagent definitions,
and skills for **Peng**.

______________________________________________________________________

## Core Rule Architecture (`.agents/rules/`)

- **[`01_memory_and_resource_safety.md`][rule-01]**:
  Tagged union pattern matching (`switch (union)`), per-frame arenas, HashMap
  key lifecycle cleanup, typed worker structs, structured error logging, slice
  aliasing protection, socket stream teardown, worker early-exit invariants,
  co-located `errdefer` + `try` cleanup, lifecycle deinitialization guardrails,
  zero full-file allocation streaming for large media, saturating offset
  arithmetic, strict domain invariant enforcement via validation constructors,
  and 32-bit platform offset `@intCast` safety.

- **[`02_concurrency_and_architecture.md`][rule-02]**:
  `AppState` vs `ViewerState` structural split, main-thread GPU operations,
  non-recursive `std.Io.Mutex` safety, `std.Io.Group` task spawning & native
  cancellation, daemon thread isolation, `MpscQueue` event transport,
  zero-dependency `AppIntent` queue, worker event draining, 11-step unnested
  systems pipeline with single-pass intent dispatch, `OverlayFlags` packed
  structs, isolated worker arguments, `ViewerStats` telemetry snapshots, atomic
  generation epoch versioning, single-pass I/O header consolidation,
  demand-first cache priority gating, and cooperative worker pruning.

- **[`03_c_abi_and_module_hygiene.md`][rule-03]**:
  Single canonical `@cImport` (`src/sdl/c.zig`), C-handle encapsulation,
  complete enum mapping invariant, null-terminated slice signatures, top-of-file
  alphabetical import & alias block separation, prohibition of proxy re-exports
  and in-flight backward-compatibility aliases, `.empty`/`.init` inference,
  Zig 0.16 test architecture (prohibition of `refAllDecls` in app roots, 3-tier
  testing, accessor test prohibition, and zombie property pruning), standalone
  package hierarchy & app-private core (`src/app/core/`), minimal declaration
  visibility (`pub`), mandatory doc comments (`///`), C-ABI `extern struct`
  handle wrappers, and strict \<= 80-column line-length ceiling.

- **[`04_ui_rendering_and_performance.md`][rule-04]**:
  2-Pass UI `RenderPacket` pipeline (extraction vs allocation-free execution),
  logical vs physical DPI scaling, zero-area scissor skipping, SIMD bounds
  safety, case-insensitive sorting (`lessThanIgnoreCase`), event loop dimension
  tracking (`is_busy`), GPU text texture alpha decoupling, modal dismissal input
  decoupling (`isAcceptingInput`), Universal Pixel Zoom & pre-scaled layout
  invariants, Clay UI modularization, progressive loading dimension purity
  (prohibition of worker thumbnail fallback), monotonic area updates, and
  dissolve quad sizing invariance.

- **[`05_git_workflow_and_repository_hygiene.md`][rule-05]**:
  User-only staging invariant (strictly NO `git add`/`git rm`), never unstage
  user changes (`git reset`/`git restore --staged`), explicit human commit
  sign-off invariant, commit message review workflow, permitted read-only Git
  operations (`git status`, `git diff`, `git log`), test fixture resource
  isolation (`testfiles/` only), and prohibition of extraneous scratch or audit
  scripts in version control.

______________________________________________________________________

## Skills (`.agents/skills/`)

- **[`zig-gui-practices`](skills/zig-gui-practices/SKILL.md)**:
  Best practices for Zig GUI development with Clay, SDL3 GPU rendering,
  EXIF image decoding, shader optimization, DPI layout math, and SIMD
  vector reference recipes.
- **[`zig-gui-animations`](skills/zig-gui-animations/SKILL.md)**:
  Architectural patterns and procedural recipes for zero-allocation
  Data-Oriented animation state, numerical easing safety, GPU text vertex
  alpha blitting, and Clay immediate-mode modal alpha scaling.

______________________________________________________________________

## Subagents (`.agents/agents/`)

- **`zig-reviewer`**:
  Audits Zig source code against all 5 core project rules.
- **`task-executor`**:
  Fast-path execution subagent for straightforward code implementations.
- **`agent-artifacts-reviewer`**:
  Audits `.agents/` rules, skills, agent definitions, and documentation for
  consistency, information density, and rule vs skill classification.

[rule-01]: rules/01_memory_and_resource_safety.md
[rule-02]: rules/02_concurrency_and_architecture.md
[rule-03]: rules/03_c_abi_and_module_hygiene.md
[rule-04]: rules/04_ui_rendering_and_performance.md
[rule-05]: rules/05_git_workflow_and_repository_hygiene.md
