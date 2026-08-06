# Systems Architecture & Execution Rules Reference

## Core System Execution Constraints

All system functions under `src/app/systems/` in `peng-sys` must strictly comply with the following architectural rules:

- **Rule 1 — Update Phase Execution (`runUpdatePhase`)**:
  - Systems run exclusively during Phase 2 (`runUpdatePhase`) of the 3-phase frame loop tick in `src/viewer.zig` (`Worker Ingestion` -> `Update Phase (runUpdatePhase)` -> `Render Phase`).
  - Never add out-of-band system calls inside state mutation methods (`AppState`) or input event handlers.
  - The 9 system passes execute sequentially in deterministic order:
    1. `sysExecuteIpcCommands(ctx)`: Ingests & dispatches IPC commands.
    2. `sysProcessInput(ctx)`: Maps keyboard input to intents.
    3. `sysExecuteIntents(ctx)`: Drains IPC & keyboard intents.
    4. `sysProcessPaletteInput(ctx)`: Handles command palette query & selection.
    5. `sysUpdateViewport(ctx, palette_closed)` & `sysUpdateSlideshow(ctx)`: Updates motion/timers.
    6. `sysExecuteIntents(ctx)`: Drains remaining palette & slideshow intents.
    7. `sysProcessAssetUploads(ctx)`: Performs EXIF orientation & GPU texture uploads.
    8. `sysUpdateCache(ctx)`: Manages slot eviction, decodes & performs idle neighbor preloading.
    9. `sysSyncMetrics(ctx)`: Synchronizes telemetry & stats for Nerds overlay.

______________________________________________________________________

## Frame Context & Memory Lifetimes

- **Rule 2 — Frame Arena Lifetimes (`FrameContext`)**:
  - Every system function signature accepts `ctx: FrameContext` containing `state: *AppState`, `frame_allocator: Allocator`, `input: FrameInput`, and `delta_time_ms: f32`.
  - Systems must use `ctx.frame_allocator` for transient frame-bound allocations (such as string duping for enqueued intents). Memory allocated with `frame_allocator` automatically resets at frame boundaries.

______________________________________________________________________

## Decoupled Intent-Driven Systems

- **Rule 3 — Zero Inter-System Calls**:
  - Systems must never call other systems directly.
  - Systems communicate strictly by mutating `AppState` fields or pushing `AppIntent` variants to `state.pending_intents`.

______________________________________________________________________

## CacheSlotMap & Generation Ownership

- **Rule 4 — Cache Slot Generation Ownership & Structure**:
  - `CacheSlotMap` (`state.cache` in `src/app/core/image.zig`) uses Zig's `std.MultiArrayList(CacheSlot)` for Structure-of-Arrays (SoA) memory layout, allowing key scanning without cache-line pollution while mutating key and entry slices atomically.
  - Generation state (`generation: usize`) is owned exclusively by `CacheSlotMap`.
  - Navigation/directory resets advance the generation via `_ = state.cache.advanceGeneration()`.
  - Incoming background event payloads validate their `CacheKey` generation against `state.cache.getGeneration()`. Mismatched generations are ignored to prevent stale decodes from populating active slots.
