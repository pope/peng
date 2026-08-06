# Systems Architecture & Execution Rules Reference

## Core System Execution Constraints

All system functions under `src/app/systems/` in `peng-sys` must strictly comply with the following architectural rules:

- **Rule 1 — Update Phase Execution (`runUpdatePhase`)**:
  - Systems run exclusively during Phase 2 (`runUpdatePhase`) of the 3-phase frame loop tick in `src/viewer.zig` (`Worker Ingestion` -> `Update Phase (runUpdatePhase)` -> `Render Phase`).
  - Never add out-of-band system calls inside state mutation methods (`AppState`) or input event handlers.
  - The system passes execute sequentially in deterministic order:
    1. `sysExecuteIpcCommands(ctx)`: Ingests & dispatches IPC socket commands -> `pending_intents`.
    2. `sysProcessInput(ctx)`: Maps keyboard input -> `pending_intents`.
    3. `sysProcessPaletteInput(ctx)`: Handles command palette query & selection -> `pending_intents`.
    4. `sysUpdateViewport(ctx, palette_closed)` & `sysUpdateSlideshow(ctx)`: Updates motion/timers -> `pending_intents`.
    5. `sysExecuteIntents(ctx)`: Single-pass execution of all enqueued discrete intents.
    6. `sysProcessAssetUploads(ctx)`: Performs EXIF orientation & GPU texture uploads.
    7. `sysUpdateCache(ctx)`: Manages slot eviction, decodes & performs idle neighbor preloading.
    8. `sysSyncMetrics(ctx)`: Synchronizes telemetry & stats for Nerds overlay.

______________________________________________________________________

## Frame Context & Memory Lifetimes

- **Rule 2 — Frame Arena Lifetimes & Capacity Pre-allocation (`FrameContext`)**:
  - Every system function signature accepts `ctx: FrameContext` containing `state: *AppState`, `frame_allocator: Allocator`, `input: FrameInput`, and `delta_time_ms: f32`.
  - Systems must use `ctx.frame_allocator` for transient frame-bound allocations (such as string duping for enqueued intents). Memory allocated with `frame_allocator` automatically resets at frame boundaries.
  - **Dynamic Array Pre-allocation**: State constructors (`NavigationState.init`, `PaletteState.init`, `AppState.ensureInitialCapacities`) and filesystem directory scanners (`scanDirectoryEntries`) use `try entries.ensureTotalCapacity(allocator, N)` to reserve capacity upfront with explicit rationale comments explaining chosen capacities.
  - **Capacity Retention**: Interactive reset methods (`clearIntents()`, `PaletteState.reset()`, `clearDirItems()`) must use `clearRetainingCapacity()` to prevent runtime heap reallocation churn during UI update passes.
  - **Fuzzy Match Filtering & Buffer Pre-allocation**: Rebuild methods (`rebuildActionMatches`, `rebuildDirectoryMatches`, `rebuildFileMatches`) short-circuit on empty queries (`query.items.len == 0`) by populating `matches` 1-to-1 without searcher allocation or fuzzy scoring, and call `ensureTotalCapacity` on match buffers before scoring loops to allow zero-reallocation `appendAssumeCapacity` insertions during search.

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

______________________________________________________________________

## Standardized System Docstrings

- **Rule 5 — Standardized Function & System Pass Documentation (`///`)**:
  - Every system pass entry point (`sysXxx`) must feature a standardized Zig docstring (`/// System Pass: ...`).
  - System pass docstrings must detail numbered `Responsibilities:` (e.g. 1. Ingest input, 2. Filter matches, 3. Rebuild overlays).
  - Internal helper functions must document `Pre-conditions:`, `Parameters:`, return value contracts, and memory ownership / `errdefer` cleanup rules.
