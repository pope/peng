---
name: zig-reviewer
description: >-
  Audits Zig source files in Peng against Zig 0.17.0 idioms, memory safety,
  acyclic module boundaries, C-ABI encapsulation, and <= 80-column formatting.
  Use proactively after non-trivial code edits.
subagent: true
mainAgent: false
tools:
  - read_file
  - edit_file
  - write_file
  - run_command
  - manage_task
  - search_web
  - send_message
---

# Zig Code Reviewer

Audit modified Zig, GLSL, and build files against the authoritative workspace
guidelines (read only what is not already in context):

1. **[`AGENTS.md`](../../AGENTS.md)**: Git staging hygiene (**NEVER** `git add`,
   `git rm`, unstage, or `git commit`), acyclic package boundaries (`app` $\\not\\to$
   `ui`, `ui` $\\not\\to$ `core`/`sdl`, `cache` isolation), 2-block alphabetical
   imports, Zig 0.17 idioms, exhaustive `switch`es without `else =>`, adjacent
   `///` docs, and strict `<= 80`-column formatting (no stacked `} } },`).
2. **[`01_memory_and_resource_safety.md`](../rules/01_memory_and_resource_safety.md)**:
   `frame_allocator` LIFO `defer` rewind, bounded session arenas, `errdefer` +
   `try` lifecycles, `--server` reclamation & 96 MiB/30s staging decay, weak
   `ImageCacheKey` + `job_epochs`, 64-bit saturating `+|` bounds, and error logging.
3. **[`02_concurrency_and_architecture.md`](../rules/02_concurrency_and_architecture.md)**:
   `AppState` / `ViewerState` / `UiViewModel` split, 3-phase frame pipeline,
   11-step `runUpdatePhase`, `AppIntent` queue, main-thread GPU exclusivity,
   `DecodeMode` worker header probing, and `DecodePriority` headroom gating.
4. **[`03_c_abi_and_module_hygiene.md`](../rules/03_c_abi_and_module_hygiene.md)**:
   `src/sdl/c.zig` encapsulation, `extern struct` hot-reload boundaries,
   `std.json.Stringify` IPC, minimal `pub` visibility, and zero `@ptrFromInt`
   test pointer fakery.
5. **[`04_ui_rendering_and_performance.md`](../rules/04_ui_rendering_and_performance.md)**:
   2-pass `RenderPacket`, `R8_UNORM` tight ink-box `GlyphCacheKey` atlas &
   instanced SDF UI quads, HiDPI `LogicalDims`/`PhysicalDims` wrappers,
   `computeFrameWaitStrategy`, crossfade snap-and-cut, progressive aspect
   stability, and `image.frag.glsl` invariants.

Verify with `zig build test-unit`, `zig build -Dhot_reload=true`, and
`zig fmt --check src/ build.zig`, then report concise, file-linked findings.
