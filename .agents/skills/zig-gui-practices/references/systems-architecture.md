# Systems Architecture & Execution Rules Reference

## Core System Execution Constraints

All system functions under `src/app/systems/` in `peng-sys` must strictly comply with the following architectural rules:

- **Rule 1 — Update Phase Execution (`runUpdatePhase`)**:
  - Systems run exclusively during Phase 2 (`runUpdatePhase`) of the 3-phase frame loop tick in `src/viewer.zig` (`Worker Ingestion` -> `Update Phase (runUpdatePhase)` -> `Render Phase`).
  - Never add out-of-band system calls inside state mutation methods (`AppState`) or input event handlers.
  - The system passes execute sequentially in deterministic order:
    01. `sysUpdateAnimations(ctx)`: Ticks active SoA animation channels forward by `delta_time_ms`.
    02. `sysExecuteIpcCommands(ctx)`: Ingests & dispatches IPC socket commands -> `pending_intents`.
    03. `sysProcessPaletteInput(ctx)`: Handles command palette query, item selection & click-outside -> `pending_intents`.
    04. `sysProcessInput(ctx, palette_closed)`: Maps keyboard input & file drop events -> `pending_intents`.
    05. `sysProcessUiInteractions(ctx)`: Resolves pointer hover/click interactions for UI close buttons -> `pending_intents`.
    06. `sysUpdateViewport(ctx, palette_closed)` & `sysUpdateSlideshow(ctx)`: Updates motion deltas & slideshow timers -> `pending_intents`.
    07. `sysSyncWindow(ctx)`: Synchronizes OS window title and display fullscreen/state.
    08. `sysExecuteIntents(ctx)`: Single-pass execution of all enqueued discrete intents.
    09. `sysProcessAssetUploads(ctx)`: Performs EXIF orientation & GPU texture uploads.
    10. `sysUpdateCache(ctx)`: Manages slot eviction, decodes & performs idle neighbor preloading.
    11. `sysSyncMetrics(ctx)`: Synchronizes telemetry & stats for Nerds overlay.

______________________________________________________________________

## Frame Context & Memory Lifetimes

- **Rule 2 — Frame Arena Lifetimes & Capacity Pre-allocation (`FrameContext`)**:
  - Every system function signature accepts `ctx: FrameContext` containing `state: *AppState`, `frame_allocator: Allocator`, `input: FrameInput`, and `delta_time_ms: f32`.
  - Systems must use `ctx.frame_allocator` for transient frame-bound allocations (such as string duping for enqueued intents). Memory allocated with `frame_allocator` automatically resets at frame boundaries.
  - **Dynamic Array Pre-allocation**: State constructors (`NavigationState.init`, `PaletteState.init`, `AppState.ensureInitialCapacities`) and filesystem directory scanners (`scanDirectoryEntries`) use `try entries.ensureTotalCapacity(allocator, N)` to reserve capacity upfront with explicit rationale comments explaining chosen capacities.
  - **Capacity Retention**: Interactive reset methods (`clearIntents()`, `PaletteState.reset()`, `clearDirItems()`) must use `clearRetainingCapacity()` to prevent runtime heap reallocation churn during UI update passes.
  - **Fuzzy Match Filtering & Buffer Pre-allocation**: Rebuild methods (`rebuildActionMatches`, `rebuildDirectoryMatches`, `rebuildFileMatches`) short-circuit on empty queries (`query.items.len == 0`) by populating `matches` 1-to-1 without searcher allocation or fuzzy scoring, and call `ensureTotalCapacity` on match buffers before scoring loops to allow zero-reallocation `appendAssumeCapacity` insertions during search.
  - **Frame-Arena String Lifetimes for Retained Clay UI Labels**: In Clay UI layout functions (`layout.zig`, `edit_panel.zig`, `command_palette.zig`), text elements take slice references (`clay.text(formatted_str, ...)`). Clay retains these slice pointers across the layout hierarchy and hands them directly to the render execution pass (`executeRenderPacket`). Dynamic text (such as numeric percentages, slider values, formatted labels, or stats strings) MUST NOT use local stack buffers (`var buf: [32]u8 = undefined`), which become invalid once the function returns. Dynamic labels MUST be formatted into `frame_allocator` (e.g. `try std.fmt.allocPrint(frame_allocator, ...)`), guaranteeing memory validity through the GPU text blitting pass.

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

______________________________________________________________________

## Pure Presentation & Read-Only View Snapshots

- **Rule 6 — Game-Engine View Model Snapshot Invariant**:
  - The frame lifecycle enforces a strict barrier between simulation/systems (Phase 2) and rendering (Phase 3).
  - Prior to calling `ui.layout.renderFrame`, construct `UiViewModel` as a fully immutable snapshot struct containing const pointers and value types.
  - UI layout evaluation and vertex generation MUST NOT mutate `AppState` or push intents.
  - Any interactive element (e.g. palette search clicks, overlay close buttons) must have its hit testing and intent dispatch evaluated during Phase 2 system passes (`sysProcessPaletteInput`, `sysProcessUiInteractions`).

______________________________________________________________________

## Branchless Orthogonal Orientation & Compact Enum Math

- **Rule 7 — Low-Bit Bounded Enum Transformations (`enum(u2)`)**:
  - When handling multi-state spatial container metadata (such as TIFF 6.0 / EXIF 2.32 orientation tags 1..8):
    1. **Collapse to 4 Orthogonal States**: A 2D viewer typically performs orthogonal 90° rotations. Collapse the 8 TIFF states down to a 4-state bounded enum:
       ```zig
       pub const Orientation = enum(u2) {
           normal = 0,
           rotate_90 = 1,
           rotate_180 = 2,
           rotate_270 = 3,

           pub fn fromTiff(val: u16) Orientation {
               return switch (val) {
                   6, 7 => .rotate_90,
                   3, 4 => .rotate_180,
                   8, 5 => .rotate_270,
                   else => .normal,
               };
           }

           /// Branchless arithmetic conversion to floating-point degrees: index * 90.0.
           pub inline fn toDegrees(self: Orientation) f32 {
               return @as(f32, @floatFromInt(@intFromEnum(self))) * 90.0;
           }

           /// Branchless bitwise check: odd indices (1 and 3) swap width and height.
           pub inline fn isDimensionSwapped(self: Orientation) bool {
               return (@intFromEnum(self) & 1) != 0;
           }
       };
       ```
    2. **Architectural Benefits**:
       - **Zero Branch Mispredictions**: `toDegrees()` executes as direct arithmetic (`val * 90.0`) without conditional jumps or branch prediction penalties.
       - **Single Bit Test**: `isDimensionSwapped()` executes as a single bitwise AND (`test reg, 1`).
       - **Cache Line Efficiency**: Shrinks orientation fields in cache slots from 4 bytes (`f32`) to 1 byte (`enum(u2)`).
       - **Type Safety**: Replaces floating-point inequality checks (`rot != 0.0`) with compile-time verified enum comparisons (`orientation != .normal`).

______________________________________________________________________

## Declarative Capabilities & Input Isolation

- **Rule 8 — Unified Declarative Action Registry & 4-Way Projection Invariant**:
  - Capabilities are defined exclusively in `src/intents/actions.zig` via `ActionDef`:
    - `palette_action_items`: Projected for Command Palette rendering and scoring.
    - `flat_shortcuts`: Flattened mapping of `(Key, Modifiers) -> AppIntent`.
    - `action_cli_options`: CLI flags and aliases merged into `app_config.cli.options`.
    - `ipc_commands`: UDS IPC control commands projected for `peng-msg`.
  - **Contextual Isolation**: High-frequency single-key shortcuts (e.g. `s` scale mode cycling, `Shift+S` filter cycling, `h`/`j`/`k`/`l` panning) must be context-isolated to avoid collisions during palette search or default viewing.
  - **Display State Decoupling**: Runtime window toggles (`setFullscreen`, `setBordered`) operate exclusively through `DisplayState.windowed`. The headless harness (`DisplayState.headless`) must remain a no-op to guarantee deterministic offscreen CI test execution.

______________________________________________________________________

## MultiArrayList SoA & Slice Snapshot Boundary

- **Rule 9 — MultiArrayList Structure-of-Arrays (SoA) & View Model Snapshot Invariant**:
  - When domain collections maintain parallel attributes (such as `MediaEntry` (~56 bytes) and `Classification` (1 byte)), avoid separate parallel `ArrayList` collections:
    ```zig
    pub const MediaItem = struct {
        entry: MediaEntry,
        classification: Classification = .unflagged,
    };
    pub const MediaItemList = std.MultiArrayList(MediaItem);
    ```
  - **Unified Allocation**: `MultiArrayList` manages both partitions in a single block allocation, preventing list length desynchronization and eliminating allocator fragmentation.
  - **L1 Cache Line Density**: Dense 1-byte arrays stream 64 items per 64-byte L1 cache line (a 64x density improvement over AoS structs), enabling sub-microsecond SIMD filtering across 10,000+ items.
  - **Read-Only Snapshot Slice**: Slicing via `nav.items.slice()` creates a zero-allocation `MediaItemSlice = std.MultiArrayList(MediaItem).Slice` passed into Phase 3 (Render) `UiViewModel`.
  - **Encapsulation**: State mutations go through encapsulating methods (`appendEntry`, `clearEntries`), and UI view models access items via bounds-checked inline accessors (`getMediaEntry(idx)`, `getClassification(idx)`).

______________________________________________________________________

## SIMD Vectorized Circular Navigation & Popcounting

- **Rule 10 — 256-Bit SIMD Vectorized Circular Scanning & Boundary Guards**:
  - When scanning contiguous 1-byte arrays (`[]const Classification`) with portable `@Vector(32, u8)`:
    - **Forward Search (`findNextVisibleInRange`)**: Cast the vector comparison mask to `u32` (`@as(u32, @bitCast(matches))`) and call `@ctz(mask)` to find the lowest matching index in a single CPU cycle (`TZCNT`/`BSF`).
    - **Backward Search Underflow Guard (`findPrevVisibleInRange`)**:
      In reverse chunk loops (`while (cur >= 32)`), when index 0 is reached (`chunk_start == 0`), if the vector comparison finds no matches, immediately return `null`:
      ```zig
      if (chunk_start == 0) return null;
      cur -= 32;
      ```
      Never fall through to remainder scalar processing when the first 32 elements were already verified by SIMD to contain zero matches.
    - **Hardware Popcount (`countVisibleInRangeSimd`)**: Accumulate visible position and visible count using hardware `@popCount(@as(u32, @bitCast(matches)))`. Processes 10,000 image classifications in \<350 CPU cycles.

______________________________________________________________________

## State-Transition Feedback Invariants

- **Rule 11 — Action-Aware & Advance-Aware Snackbar Feedback**:
  - When user actions cause items to be filtered out and advance the cursor (e.g. marking Reject in Default view hides the image and moves to the next visible image):
    - Never derive snackbar text by inspecting the current image's classification after the mutation has already advanced the cursor.
    - Derive feedback directly from the executed intent and track cursor advancement:
      - Advanced away: `"Previous image flagged as rejected"`
      - Remained on screen: `"Flagged as Pick"` / `"Flagged as Reject"`
      - Action in 0-item filter: `"No image to classify"`

______________________________________________________________________

## Tagged Union Variance Control & Comptime Parameter Descriptors

- **Rule 12 — Tagged Union Hierarchy & Single Source of Truth Metadata**:
  - When introducing multi-parameter adjustment suites (such as photographic
    sliders or audio DSP filters), avoid polluting root `AppIntent` with flat
    variants (`increase_brightness`, `decrease_brightness`, `set_highlights`).
  - Consolidate domain operations into a nested tagged union (`AdjustIntent`):
    ```zig
    pub const AdjustIntent = union(enum) {
        set: struct { param: EditParam, value: f32 },
        step: struct { param: EditParam, direction: StepDirection },
        batch_tone: struct {
            highlights: f32,
            shadows: f32,
            whites: f32,
            blacks: f32,
        },
        batch_color: struct {
            temperature: f32,
            tint: f32,
            vibrance: f32,
            saturation: f32,
        },
        reset_param: EditParam,
        reset_all,
        toggle_compare,
        set_compare: bool,
    };
    ```
  - **Single Source of Truth Descriptor Table**:
    - Centralize parameter boundaries, defaults, step deltas, snap radii, and
      formatting kinds into a static comptime array
      (`descriptors: [EditParam.count]ParamDescriptor`).
    - Eliminate duplicated bounds checking, slider hit-testing logic, and
      formatting branches across IPC, UI layouts, and state stores.
    - Let UI widgets and IPC parsers query `param.descriptor()` to clamp and
      format values consistently.
