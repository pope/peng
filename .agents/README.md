# `.agents` Configuration & Rules Index

This directory contains project-specific agent rules, subagent definitions,
and skills for **Peng**.

______________________________________________________________________

## Core Rule Architecture (`.agents/rules/`)

The 5 files in `.agents/rules/` are the single authoritative source of truth for
project invariants:

- **[`01_memory_and_resource_safety.md`][rule-01]**:
  Allocators, per-frame arena LIFO rewinding, `errdefer` + `try` lifecycles,
  tagged union / packed bitfield domain invariants, binary parsing bounds
  safety, and structured error handling.
- **[`02_concurrency_and_architecture.md`][rule-02]**:
  `AppState` vs `ViewerState` vs `UiViewModel` split, 3-phase frame pipeline,
  11-step `runUpdatePhase` systems pass, `AppIntent` queue & `actions.zig`
  registry, `std.Io.Group` worker concurrency, and demand-first cache/upload
  gating.
- **[`03_c_abi_and_module_hygiene.md`][rule-03]**:
  C-ABI encapsulation (`src/sdl/c.zig`), package hierarchy & `build.zig` test
  targets, 2-block alphabetical imports/aliases, exhaustive enum `switch`
  matching, minimal `pub` visibility, 3-tier testing, mandatory `///` doc
  comments, and the strict `<= 80`-column ceiling.
- **[`04_ui_rendering_and_performance.md`][rule-04]**:
  2-pass `RenderPacket` GPU pipeline, Dual Kawase backdrop blur gating, RGB-only
  `TextCacheKey`, HiDPI coordinate spaces, `ZoomFactor` & `is_busy` invariants,
  progressive loading dimension stability, shader identity bypass, and
  `--test-mode` determinism.
- **[`05_git_workflow_and_repository_hygiene.md`][rule-05]**:
  User-only staging (strictly NO `git add`/`git rm` or unstaging), explicit
  human commit sign-off, `testfiles/` fixture isolation, and no scratch scripts
  in version control.

______________________________________________________________________

## Skills (`.agents/skills/`)

- **[`zig-gui-practices`](skills/zig-gui-practices/SKILL.md)**:
  Modular reference guides for Peng's 3-phase systems architecture, DPI &
  zoom-to-cursor math, SDL3 GPU text/compute-unpack/Kawase-blur pipelines,
  VRAM budgeting & camera RAW progressive loading, and 7-filter / 13-parameter
  GLSL shaders.
- **[`zig-gui-animations`](skills/zig-gui-animations/SKILL.md)**:
  Architectural patterns and recipes for zero-allocation SoA `AnimationState`,
  proportional interruption math, GPU vertex text alpha blitting, dual-quad
  image crossfades, and smooth `PanController` / `ZoomController` motion.

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
