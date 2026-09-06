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
