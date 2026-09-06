# C-ABI & Module Hygiene Rules

## 1. Single Canonical `@cImport` File

- All C header imports (`SDL3`, `SDL3_ttf`, `SDL3_image`) MUST be consolidated inside a single canonical file: `src/sdl/c.zig`.
- Do NOT issue `@cImport` calls in application modules (`src/app/`, `src/ui/`, `src/config/`).

## 2. Private C Module & Handle Encapsulation

- Keep `pub const c = @import("c.zig");` private to the wrapper module (`src/sdl/`).
- Do NOT expose raw C handles or `.ptr` fields in application domain code. Encapsulate handles behind type-safe Zig structs with explicit methods.

## 3. Complete Enum Mapping Invariant

- Every wrapper enum converting C library constants to Zig MUST provide an `inline for (std.meta.tags(Enum))` conversion function to guarantee complete enum coverage.

## 4. Null-Terminated Slice Signatures

- Pass C-string parameters using null-terminated slice types (`[:0]const u8`) rather than raw `[*c]const u8` pointers.

## 5. Top-of-File Alphabetical Import Sorting & Alias Block Separation

Every Zig source file MUST organize its module imports and symbol aliases into two distinct, alphabetically sorted header blocks separated by an empty line before any structs, functions, or logic:

1. **Block 1: Module Imports (`@import`)**

   - Every external package and internal source module MUST be imported ONCE at the very top of the file.
   - Declarations MUST be sorted alphabetically by identifier name (`const app = @import("app"); ... const std = @import("std");`).
   - NEVER mix symbol aliases (`const Symbol = mod.Symbol;`) into this block.

2. **Block 2: Symbol Aliases & Destructuring**

   - Placed immediately following the import block, separated by a single empty line.
   - All extracted types, constants, and helper functions aliased from imported modules (`const AppState = app_state.AppState;`).
   - Declarations MUST be sorted alphabetically by symbol name.

3. **Strict Invariants**:

   - **NO Inline `@import` Expressions**: NEVER write `@import(...)` inside function bodies, struct fields, or mid-file declarations (e.g., `const MediaEntry = @import("state").MediaEntry;` placed mid-file is forbidden).
   - **Clean Scoping**: If a symbol is needed across multiple functions or struct scopes, alias it once in Block 2.

```zig
// GOOD: Canonical two-block header structure
const app_state = @import("../state.zig");
const image = @import("../core/image.zig");
const root = @import("root.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const workers_mod = @import("../workers/root.zig");

const AppState = app_state.AppState;
const CacheEntry = state_pkg.CacheEntry;
const CacheSlotMap = image.CacheSlotMap;
const DecodeArgs = workers_mod.DecodeArgs;
const FrameContext = root.FrameContext;
const MediaEntry = state_pkg.MediaEntry;

// Structs and function definitions begin here...
```

## 6. No Proxy Re-Exports or In-Flight Backward-Compatibility Aliases

- **No Proxy Re-Exports**: Do NOT re-export types from unrelated sub-modules (e.g. `pub const CacheEntry = image.CacheEntry` inside `state.zig`). Keep symbol declarations strictly in their canonical home module so import paths remain authoritative and unit tests stay isolated.
- **No In-Flight Backward-Compatibility Aliases**: When introducing, renaming, or refactoring symbols in an active change list or working branch, NEVER introduce backward-compatibility type/function aliases (e.g., `pub const OldName = NewName;`).
  - Active CLs have zero backward-compatibility obligations.
  - Update all call sites, event payloads, tests, and documentation directly to use the new canonical symbol.
  - Delete superseded names completely so the public API remains minimal, unambiguous, and authoritative.

## 7. Result Location Initialization Style (`.empty`, `.init(...)`)

- Use leading-dot result location type inference for array lists, optionals, atomic values, and struct initializations where the type is explicitly specified on the LHS (`.empty`, `.init(allocator)`, `.{ .field = val }`):
  ```zig
  // GOOD: Clean, idiomatic inference
  generation: std.atomic.Value(usize) = .init(0),
  active_threads: std.atomic.Value(usize) = .init(0),
  var current_gen: std.atomic.Value(usize) = .init(2);

  // AVOID: Redundant type repetition
  generation: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
  var current_gen = std.atomic.Value(usize).init(2);
  ```

## 8. Feature-Complete Canonical Implementations

- When deduplicating utility functions or consolidating symbols into their canonical home module, verify that the retained canonical implementation is the robust, feature-complete version—not a simplified or legacy variant.

## 9. Submodule Test Exposure Pattern (`test { _ = submodule; }`) for Zig 0.16

- **Zig 0.16 Lazy Test Discovery Invariant**: In Zig 0.16, the compiler lazily analyzes test declarations. Unit tests declared inside child submodules or files are **ONLY** compiled and executed during `zig build test` if explicitly referenced inside an active test container block in the parent/root module (`root.zig` or `main.zig`).
- **Standard Module Root Pattern**: Every package entrypoint or module root (`src/main.zig`, `src/state/root.zig`, `src/app/root.zig`, `src/ui/root.zig`, `src/app/systems/root.zig`) MUST include a top-level `test` block referencing all imported child modules:
  ```zig
  test {
      _ = types;
      _ = view_transform;
      _ = palette_state;
      _ = viewer_state;
      _ = navigation;
      _ = ui_state;
  }
  ```
- **Rule**: Omitting `_ = child_module;` inside top-level `test` blocks will cause Zig to silently skip all unit tests inside those submodules. Always maintain complete submodule test exposure across module root files.

## 10. Standalone Package Hierarchy & App-Private Core (`src/app/core/`) Architecture

- **Standalone Package Isolation**: Shared domain types, input mapping, command parsers, and state models MUST live in dedicated top-level packages under `src/`:
  - `src/intents/`: Pure `AppIntent` variants and payload structs.
  - `src/input/`: Pure `FrameInput` event polling and keybind mapping.
  - `src/ipc/`: Pure `IpcCommand` parsing, `IpcServer` handle, and socket response helpers.
  - `src/state/`: Pure visual/UI data models (`ViewerState`, `UiState`).
- **App-Private Core Subdirectory (`src/app/core/`)**: App-internal, state-free utility types, file system helpers, EXIF parsers, image slot maps, palette matching logic, and event constructs MUST live inside `src/app/core/`:
  - `src/app/core/events.zig`: Background event payloads and thread-safe `MpscQueue(T)`.
  - `src/app/core/fs.zig`: Pure file system inspection & path manipulation helpers.
  - `src/app/core/exif.zig`: EXIF header parsing & orientation detection.
  - `src/app/core/image.zig`: Image MIME detection, `CacheSlotMap`, and GPU surface upload helpers.
  - `src/app/core/palette.zig`: Palette directory loading.
  - **Core Isolation Invariant**: Code inside `src/app/core/` MUST NOT depend on ANY code in `src/app/` outside of `src/app/core/` (zero imports of `AppState`, system passes, worker tasks, or app actions).
- **Prohibition of Proxy Re-Exports**:
  - `src/app/root.zig` MUST NOT proxy re-export top-level packages (e.g. `pub const ipc = @import("ipc");`) or `src/app/core/` sub-modules directly at the top level of `app`.
  - Consuming code MUST import top-level packages directly (`@import("ipc")`, `@import("input")`) or access core modules via `app.core` (`@import("core/fs.zig")`, `@import("core/image.zig")`, `@import("core/palette.zig")`, `@import("core/events.zig")`, `@import("core/exif.zig")`).
- **Acyclic Dependency Invariants**: Pure domain modules (`intents`, `input`, `ipc`, `state`, `core`) MUST NOT import `AppState`, application system passes, worker tasks, or app actions.

## 11. Minimal Declaration Visibility & Public API Scoping Invariants

In Zig, declaration visibility is lexically scoped to the declaring file or container struct. Symbols MUST follow the principle of least privilege: default to private (`fn`, `const`, `var`), and only declare `pub` when crossing an architectural boundary.

### 1. Never Default to `pub`

- All functions, structs, enums, unions, and constants MUST be private unless required by external callers outside the file.
- If a helper is only called within the file it is defined in, it MUST NOT be `pub`.

### 2. Subsystem Passes & Component Rendering

- **System Passes (`src/app/systems/`)**:
  - ONLY the primary system entry point (`sysProcessInput`, `sysUpdateCache`, `sysProcessPaletteInput`) may be `pub fn`.
  - Sub-routines, key mappings, and internal handlers (e.g. `handleKeyDown`, `handlePaletteKeys`) MUST be private `fn`.
- **UI Rendering Components (`src/ui/`)**:
  - ONLY the top-level render orchestrators (`renderFrame`, `renderPalette`, `renderStatsOverlay`, `renderClayCommands`) may be `pub fn`.
  - Intermediate layout builders and widget sub-trees (e.g. `renderHeaderBar`, `renderEmptyState`, `renderViewport`, `renderTextInputDialog`, `renderSelectionList`, `renderStatRow`, `renderInfoOverlay`) MUST be private `fn`.
- **Render Pipelines & Geometry**:
  - Internal staging packets and multi-pass stages (e.g. `RenderPacket`, `buildRenderPacket`, `executeRenderPacket`, `appendCornerArc`) MUST be private to their pipeline file.

### 3. Application Drivers & Executables

- In executable roots (`main.zig`, `test_runner_main.zig`, `msg_main.zig`), ONLY `pub fn main` (or `build` in `build.zig`) is public.
- Setup contexts (`AppGraphicsAndState`), initialization routines (`initAppGraphicsAndState`), and execution loops (`runMainLoop`, `runUpdatePhase`) MUST be private.

### 4. Same-File Unit Test Access

- In Zig, unit test blocks (`test "..."`) have full access to private (`fn`, `const`) declarations in the same file.
- NEVER mark a symbol `pub` merely to test it if the test resides within the same file.

### 5. Generic Reflection (`@hasDecl`) Exception

- Zig's `@hasDecl(T, "name")` reflection strictly tests for public declarations. Any method intended to be detected or invoked polymorphically by a generic container (such as `deinitQueueItem` in `MpscQueue(T)`) MUST be declared `pub fn`.

### 6. Signature Types & Type Inference

- Types that appear in public function signatures (as parameters or return types) MUST be `pub`, even if callers use type inference (`const pt = geometry.toNdc(...)`) or anonymous struct literals (`initGraphicsAndWindow(..., .{ .headless = true })`).

### 7. Proactive Dead Code Pruning

- Do NOT leave orphaned functions, methods, or structs in the codebase with `pub`. If a declaration has zero callers across production and test code, eliminate it immediately.

## 12. Mandatory Documentation Invariant for Public Structs and Functions (`///`)

Every public struct and public function across the codebase MUST be documented using idiomatic Zig doc comments (`///`):

### 1. Scope of the Invariant

- **Public Structs**: Any declaration matching `pub const <Name> = struct` (including handle wrappers, configuration descriptors, data packet structs, and internal state containers) MUST have a doc comment preceding it.
- **Public Functions**: Any `pub fn <name>` (including standalone package functions, system pass entry points, and public methods declared inside structs or unions) MUST have a doc comment preceding it.
- **Strict Adjacency**: Doc comments MUST use `///` on every line and be placed immediately above the declaration with NO blank lines or regular comments (`//`) separating the doc comment from the declaration.

### 2. Documentation Content Standards

- **Functions**:
  - State clearly and concisely what the function accomplishes.
  - Detail any non-obvious parameter semantics, units (e.g. milliseconds, nanoseconds, bytes), or coordinate systems (e.g. NDC `[-1, 1]` vs logical pixels vs physical framebuffer pixels).
  - Explicitly document preconditions, error conditions, and resource lifecycle expectations (e.g. whether the caller assumes ownership or must call `.deinit()`).
- **Structs**:
  - Explain the purpose and role of the struct within the subsystem.
  - Note lifetime or lifecycle semantics (e.g. frame-bounded arena vs GPA allocator owned vs opaque GPU handle).
  - Distinguish clearly between configuration descriptors (passed to factory functions), active state models, and type-safe wrappers around backend handles.

### 3. Verification & Enforcement

- Agents and automated reviewers MUST verify that any introduced or modified public struct or public function includes complete, idiomatic doc comments.
- Code submissions with undocumented public structs or functions will fail hygiene review.
