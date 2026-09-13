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
   - NEVER combine `@import` with field destructuring on the same line (e.g., `const X = @import("foo.zig").X;` is strictly forbidden). Block 1 is exclusively for pure module imports.
   - NEVER mix symbol aliases (`const Symbol = mod.Symbol;`) into this block.

2. **Block 2: Symbol Aliases & Destructuring**

   - Placed immediately following the import block, separated by a single empty line.
   - All extracted types, constants, and helper functions aliased from imported modules (`const AppState = app_state.AppState;`).
   - Declarations MUST be sorted alphabetically by symbol name.

3. **Strict Invariants**:

   - **NO Inline `@import` Expressions**: NEVER write `@import(...)` inside function bodies, struct fields, or mid-file declarations. All `@import` calls must reside exclusively in Block 1.
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

## 9. Zig 0.16 Test Architecture & Blanket Import Prohibition

- **Zig 0.16 Lazy Semantic Analysis Invariant**: Zig's compiler lazily analyzes
  declarations and test blocks. Declarations in application code are ONLY compiled
  into the production binary if reachable from `main()`.
- **Prohibition of `std.testing.refAllDecls` in Application Roots**:
  - NEVER call `std.testing.refAllDecls` or `std.testing.refAllDeclsRecursive` in
    application executable roots (`src/main.zig`, `src/msg_main.zig`, `src/viewer.zig`).
  - `refAllDecls` is for standalone public libraries to guarantee uncalled generic
    APIs compile; in an application, it transforms uncalled dead code into mandatory
    compilation dependencies and creates test-locked zombies.
  - The runtime entry point `main()` defines the authoritative reachability graph
    for application code.
- **Dedicated Module Test Artifacts in `build.zig`**:
  - To test standalone packages (`src/sdl`, `src/intents`, `src/config`, `src/state`,
    `src/app/core`), declare explicit test steps in `build.zig` via
    `b.addTest(.{ .root_module = module })`.
  - Do NOT cross-pollinate module tests into `exe.root_module`.
  - Platform abstraction packages (`src/sdl/root.zig`) or core utilities
    (`src/app/core/root.zig`) expose their own internal submodule tests within
    their package boundary using `_ = @import("submodule.zig");` or `_ = submodule;`
    in their module-level root `test` block.
- **The 3-Tier Testing Architecture**:
  1. **Tier 1: Pure Algorithm & Parser Tests (Inline `test "..."`)**: Co-locate unit
     tests only for deterministic, stateless math, parsers, and pixel converters
     (`exif.zig`, `easing.zig`, `surface.zig`, `fs.zig`).
  2. **Tier 2: Subsystem & State Transition Tests**: Test state machines and intent
     dispatchers via public inputs and resulting states, never via intermediate
     struct getters or internal layouts.
  3. **Tier 3: Black-Box Integration Tests (`test_runner_main.zig`)**: Verify
     user-visible behaviors, IPC socket commands, and rendering determinism via
     golden screenshots.
- **Prohibition of Accessor & Data-Shape Unit Tests**:
  - NEVER write unit tests solely verifying trivial getters, setters, or
    intermediate enum/struct layout mappings (`toScaleModeInt()`, `getImageCount()`).
  - If a data model is not consumed by a production system, do NOT write a test to
    assert on it. Test the consuming subsystem instead.
- **Prohibition of Cross-Module File Path Imports**:
  - NEVER cross module boundaries using relative file paths (e.g.
    `@import("app/core/exif.zig")` from `src/main.zig`). This causes
    `error: file exists in modules 'root' and 'app'`. Always access declarations
    through their canonical module namespace (e.g. `app.core.exif`).

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

### 7. Proactive Dead Code & Zombie Property Pruning

- **Production Reachability Invariant**: A declaration is dead if it has zero
  callers in runtime production code, even if unit tests call it. Tests MUST NOT
  be the sole reason an application function, method, or struct exists.
- **Verification via Build Isolation**: To verify whether code is dead, temporarily
  remove or comment it out and run `zig build`. If `zig build` succeeds and only
  `zig build test` fails, the symbol is a "test-locked zombie": delete both the
  dead symbol and the obsolete test assertion.
- **Prohibition of Write-Only Zombie Properties**:
  - Struct fields MUST NOT exist solely to receive telemetry or cache data if no
    downstream UI layout, shader, or decision-making logic reads them.
  - If a field is assigned every frame in a system pass (e.g. `sysSyncMetrics`) or
    initialized in struct literals, verify that at least one production read
    (`val = obj.field`) exists. If unread, prune the field and its assignment
    immediately.

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

## 13. C-ABI Dynamic Library Boundary Typing & Handle Wrapper Invariant

- **C-ABI Handle Wrappers Must Be `extern struct`**: Any Zig wrapper struct representing a C handle passed by value across `callconv(.c)` boundaries MUST be declared as `extern struct` (e.g., `pub const Window = extern struct { ptr: *c.SDL_Window };`). Regular Zig `struct` types have undefined in-memory layout and trigger compiler errors in C calling conventions.
- **Strong Typing Across Dynamic Library Boundaries**: Do NOT degrade known subsystem pointers to `*anyopaque` at dynamic library / hot-reloading boundaries (`viewer_update`). Single-item pointers (`*T`, `?*T`) share identical representation with C pointers (`void*`). Retain concrete typed pointers (`*AppState`, `Window`, `*RenderResources`, `*MeasureTextUserData`, `?*IpcServer`) to preserve compile-time type safety across host and shared library modules.

## 14. Code Formatting & Line Length Invariants (Strict 80-Column Ceiling)

Every Zig source file (`src/**/*.zig`, `build.zig`) MUST adhere strictly to the
project's formatting and line-length constraints:

### 1. Line Length Limits

- **80 Columns Absolute Hard Ceiling**: Every line of Zig code (including
  struct field definitions, function parameter lists, function call arguments,
  expressions, and assignments) MUST NOT exceed 80 characters. Zero tolerance
  for lines > 80 columns, except for unbreakable URLs/hyperlinks as specified in
  Subsection 14.2.
- **Proactive Pre-Commit Audit**: Prior to proposing any commit or completing
  code modifications, run an automated line-length check:
  ```bash
  git diff HEAD~1 | awk '/^\+[^+]/ {
    if (length($0) > 81) print length($0)-1, $0
  }'
  ```
  Every reported line must be wrapped with Zig trailing commas or extracted into
  local `const` bindings to satisfy the \<= 80 character limit.

### 2. Comment Wrapping & Preservation

- Wrap inline comments and doc comments (`///`) cleanly to ~80 columns.
- **Never Break URLs/Hyperlinks**: Lines containing hyperlinks or URLs (e.g. `https://...`) are an explicit exception to the 100-character ceiling and must NEVER be broken or split across lines, as splitting destroys clickability.
- **Dedicated URL Lines**: Place long hyperlinks on their own dedicated comment line (e.g. `/// See:\n/// https://...`) so surrounding comment text wraps cleanly without unnecessary overflow.
- **Preserve ASCII Art & Tables**: Preformatted ASCII art, diagrams, and markdown tables in comments must retain their visual structure and indentation. Authors should design diagrams to fit within 80–100 columns; existing structural diagrams are exempt from line-wrapping that would destroy visual alignment.

### 3. Multi-Line Wrapping & Trailing Commas

- Use Zig's canonical trailing comma syntax (`.{ foo, bar, }`, `fn foo(\n a: T,\n b: U,\n)`) to instruct `zig fmt` to break arguments, struct initializers, and switch branches onto multiple lines so each line comfortably ends around 80 characters.
- In struct declarations and anonymous struct literals, place fields on their own lines with trailing commas whenever a single line would approach or exceed 80 characters.
- When boolean conditions or arithmetic expressions push lines past ~80 characters, extract pure subexpressions into local immutable `const` bindings (e.g., `const can_snap = ...;`, `const is_win_drive = ...;`).
- **Short-Circuit Evaluation Caution**: When extracting boolean conditions into local `const` bindings, ensure you do not bypass short-circuit evaluation guards (e.g. pointer null checks `ptr != null` or slice bounds checks `idx < len`) that protect subsequent expressions from runtime panics or illegal memory access.

### 4. Verification & Formatting Invariant

- All code modifications MUST cleanly pass `zig fmt --check <file>` before
  completion.
- When reviewing or writing Zig, GLSL, or C code, proactively verify that all
  new and modified lines strictly obey the \<= 80 columns ceiling.

## 15. Exhaustive Enum Pattern Matching & Anti-`else => {}` Invariant

- **Exhaustive Matching on Architectural Enums**:
  - Switch statements evaluating core domain enums (`PaletteMode`, `EditParam`,
    `AppIntent`, `ScaleMode`, `FilterKind`) MUST exhaustively list every
    variant.
  - Wildcard or catch-all branches (`else => {}` or `else => ...`) are strictly
    forbidden for domain-critical enums.
- **Compile-Time Regressions Guard**:
  - When a new mode or parameter variant is added to an enum, the Zig compiler
    must immediately trigger compile errors at all unhandled call sites across
    the codebase.
  - Fallback `else => {}` silences these errors, leading to insidious runtime
    bugs where newly added features are silently ignored in event loops, input
    handlers, or rendering systems.
- **Handling Inactive or Non-Applicable Modes**:
  - If multiple variants share a no-op or default behavior, enumerate them
    explicitly in a multi-case pattern (e.g.
    `.inactive, .files, .actions => {}`).
