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

## 5. Single Top-Level Module Import Standard

- Import external/internal project modules ONCE at the top of the file:
  ```zig
  const app = @import("app");
  const app_state = app.state;
  const types = app.types;
  const CacheEntry = app.image.CacheEntry;
  ```
- Declare all type aliases as top-level `const` variables at the very top of the file. NEVER write inline `@import(...)` expressions inside function bodies, local blocks, or mid-file declarations.

## 6. No Proxy Re-Exports

- Do NOT re-export types from unrelated sub-modules (`pub const CacheEntry = image.CacheEntry` inside `state.zig`).
- Do NOT add temporary or backward-compatibility type/function re-exports (e.g. `pub const StdinArgs = workers.StdinArgs;`) when refactoring code. Instead, update all call sites, usage, and tests across the codebase to reference the new authoritative home module directly.
- Keep symbol declarations strictly in their home module so import paths remain authoritative and unit tests stay isolated.

## 7. Result Location Initialization Style (`.empty`, `.init(...)`)

- Use leading-dot result location type inference for array lists, optionals, and struct initializations (`.empty`, `.init(allocator)`, `.{ .field = val }`).

## 8. Feature-Complete Canonical Implementations

- When deduplicating utility functions or consolidating symbols into their canonical home module, verify that the retained canonical implementation is the robust, feature-complete version—not a simplified or legacy variant.
