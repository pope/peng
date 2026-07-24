# Native Zig Type Abstractions & C-ABI Boundaries

## Input Event Boundary Translation

- Platform keycodes and keyboard modifiers (e.g. `SDL_Keycode` and `SDL_Keymod`) MUST be translated into native, strongly-typed Zig enums (`Key`, `KeyModifiers`) at the input polling boundary (`src/app/input.zig`).
- All internal application action maps, shortcut registries, palette searching, and event handlers MUST operate exclusively on native Zig `Key` and `KeyModifiers` types, isolating core application logic from C-ABI headers and third-party library dependencies.
