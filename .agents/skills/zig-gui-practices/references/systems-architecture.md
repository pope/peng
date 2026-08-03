# Systems Architecture & Execution Rules Reference

## Core System Execution Constraints

All system functions under `src/app/systems/` in `peng-sys` must strictly comply with the following three architectural rules:

- **Rule 1 — Update Phase Execution**:
  - Systems run exclusively during Phase 2 (`runUpdatePhase`) of the 3-phase frame loop tick in `src/viewer.zig` (`Ingestion` -> `Systems Update Phase` -> `Render Phase`).
  - Never add out-of-band system calls inside state mutation methods (`AppState`) or input event handlers.

______________________________________________________________________

## Frame Context & Memory Lifetimes

- **Rule 2 — Frame Arena Lifetimes**:
  - Every system function signature accepts `ctx: FrameContext` containing `state`, `frame_allocator`, `input`, and `delta_time_ms`.
  - Systems must use `ctx.frame_allocator` for transient frame-bound allocations (such as string duping for enqueued intents). Memory allocated with `frame_allocator` automatically resets at frame boundaries.

______________________________________________________________________

## Decoupled Intent-Driven Systems

- **Rule 3 — Zero Inter-System Calls**:
  - Systems must never call other systems directly.
  - Systems communicate strictly by mutating `AppState` fields or pushing `AppIntent` variants to `state.pending_intents`.
