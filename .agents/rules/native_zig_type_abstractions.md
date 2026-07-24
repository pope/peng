# Native Zig Type Abstractions & C-ABI Boundaries

## Single `@cImport` Canonical Source Invariant

- Third-party C header imports (`@cImport`) MUST be declared in **exactly ONE boundary file** (e.g. `src/sdl/c.zig`).
- All boundary wrappers inside `src/sdl/` import `c` from that single canonical file (`const c = @import("c.zig").c;`).
- **Rationale**: In Zig, each `@cImport` block generates unique struct type definitions. Multiple `@cImport` blocks across files cause type mismatch compiler errors (e.g. `cimport_1.struct_SDL_GPUDevice` != `cimport_2.struct_SDL_GPUDevice`).

## Private `c` Module & Zero C-Symbol Leakage Outside Boundary

- Boundary root modules (e.g. `src/sdl/root.zig`) MUST keep the raw `c` import **private** (`const c = @import("c.zig").c;`).
- Application code outside the boundary directory MUST NEVER import raw C symbols, declare `const c = sdl.c;`, or use raw C pointer types (such as `*sdl.c.SDL_GPUTexture` or `*c.SDL_Surface`).
- All application state, UI renderer code, state maps, and test runners MUST use native Zig handle abstractions (`sdl.gpu.Texture`, `sdl.gpu.Device`, `sdl.Surface`, `sdl.Window`, etc.) and native Zig enums exclusively.

## Encapsulation of Handle `.ptr` Fields

- Application code outside the boundary layer MUST NOT access or inspect `.ptr` on handle structs directly.
- Expose explicit domain-appropriate helper methods on handle structs (e.g. `pub fn asOpaque(self: Texture) *anyopaque` or `pub fn eql(self: Texture, other: Texture) bool`) to keep `.ptr` encapsulated inside `src/sdl/`.

## Complete Enum Mapping Invariant

- When wrapping C library enums in native Zig `enum(c_int)` or `enum(u32)` definitions, ALL C enum variants required or defined by the system headers MUST be explicitly mapped.
- DO NOT truncate, omit, or default-map variants to unrelated tags (e.g. mapping `.pixel_art => .nearest`), as this causes subtle rendering, scaling, or runtime behavioral regressions.

## Null-Terminated Slice Type Signatures (`[:0]const u8`)

- Boundary helper methods that expect null-terminated C strings (and functions ending with the `Z` suffix, e.g. `createZ`, `dupeZ`) MUST use Zig null-terminated slices (`[:0]const u8` or `[:0]u8`) as parameter types.
- DO NOT use raw non-sentinel pointers (`[*]const u8` or `[]const u8`) for C-string parameters. Use `[:0]const u8` or `[*:0]const u8`, which carry sentinel null-termination guarantees and automatically coerce to C-string pointers (`.ptr`) when passed to C-ABI functions.

## Lean & Targeted Boundary Wrapper Scope

- C-ABI abstraction modules (such as `src/sdl/`) MUST remain lean and targeted.
- Wrap strictly the types, structs, methods, and enums actively required by the application, avoiding broad or speculative 1-to-1 C library translation layers.

## Input Event Boundary Translation

- Platform keycodes and keyboard modifiers (e.g. `SDL_Keycode` and `SDL_Keymod`) MUST be translated into native, strongly-typed Zig enums (`Key`, `KeyModifiers`) at the input polling boundary (`src/app/input.zig`).
- All internal application action maps, shortcut registries, palette searching, and event handlers MUST operate exclusively on native Zig `Key` and `KeyModifiers` types, isolating core application logic from C-ABI headers and third-party library dependencies.
