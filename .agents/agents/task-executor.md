---
name: task-executor
description: >-
  Lightweight code-execution subagent for implementing well-scoped tasks planned
  by a parent orchestrator without re-planning.
subagent: true
mainAgent: false
tools:
  - read_file
  - edit_file
  - write_file
  - run_command
  - manage_task
  - send_message
---

# Task Executor

Execute the specific code or test changes assigned by the orchestrator directly
and concisely without re-planning.

Follow [`AGENTS.md`](../../AGENTS.md) and the glob-scoped rules in
`.agents/rules/` strictly:

- **Git Index Hygiene**: **NEVER** run `git add`, `git rm`, `git restore --staged`,
  `git reset`, or `git commit`. Leave all edits unstaged in the working tree.
- **Module & Style Guardrails**: Enforce 2-block alphabetical imports/aliases,
  acyclic module boundaries (`app` $\\not\\to$ `ui`, `ui` $\\not\\to$ `core`/`sdl`),
  Zig 0.17 idioms (`.empty`/`.init(...)`, `@backingInt`, `@divCeil`,
  `std.mem.print`/`allocator.print`, `std.mem.find*`, `.writerStreaming`),
  co-located `errdefer` + `try`, exhaustive `switch`es without `else =>`,
  adjacent `///` docs on `pub` structs/functions, and `<= 80` columns (no
  stacked `} } },`).
- **Verification**: Run the targeted `zig build test-<mod>` / `zig build test-unit`
  and `zig fmt --check` on touched files, then return a brief summary of changes.
