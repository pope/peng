# `.agents` Configuration & Rules Index

This directory contains project-specific agent rules, subagent definitions, and skills for **Peng**.

______________________________________________________________________

## Project Rules (`.agents/rules/`)

- **[`zig_state_machine_design.md`](rules/zig_state_machine_design.md)**: State machine architecture, tagged union invariants, streaming dataset isolation, and domain type passing.

- **[`zig_memory_safety.md`](rules/zig_memory_safety.md)**: Universal memory safety, resource lifecycle, and error logging rules.

  - **Structured Error Logging Invariant**: Never swallow errors with empty `catch {}` or `else |_| {}` blocks. Always log errors via `std.log` with contextual details.
  - **No Silent Error Swallowing on Fallbacks**: Log a `std.log.warn` or `std.log.err` prior to returning fallbacks or `null`.
  - **Tagged Union Access**: Always match via `switch (union)` to avoid Release mode safety bypasses.
  - **Per-Frame Arenas & HashMap Key Cleanup**: Arena resets and proper key iterator lifecycle before clearing maps.
  - **Thread Procedure Types**: Strongly-typed thread worker signatures without `?*anyopaque` downcasting.

- **[`concurrency_and_gpu_threading.md`](rules/concurrency_and_gpu_threading.md)**: GPU texture lifetime, main-thread rendering restrictions, and SDL3 GPU backend invariants.

- **[`clay-dpi-rendering.md`](rules/clay-dpi-rendering.md)**: High-DPI scaling, Clay UI layout, and Retina scale factor calculations.

- **[`directory_navigation_and_sorting.md`](rules/directory_navigation_and_sorting.md)**: Single-pass filesystem counting and directory sorting rules.

- **[`native_zig_type_abstractions.md`](rules/native_zig_type_abstractions.md)**: Type-safe Zig abstractions and C-interop guidelines.

- **[`ui_text_and_performance.md`](rules/ui_text_and_performance.md)**: FreeType text cache lifecycle and performance optimization.

______________________________________________________________________

## Skills (`.agents/skills/`)

- **[`zig-gui-practices`](skills/zig-gui-practices/SKILL.md)**: Best practices for Zig GUI development with Clay, SDL3 GPU rendering, EXIF image decoding, and shader optimization.

______________________________________________________________________

## Subagents (`.agents/agents/`)

- **`zig-reviewer`**: Audits Zig source code against all project rules, including structured error logging (`zig_memory_safety.md`) and thread safety rules.
- **`task-executor`**: Fast-path execution subagent for straightforward code implementations.
