# Zig State Machine Architecture & Tagged Union Invariants

## 1. Mutually Exclusive Sub-States as Tagged Unions (`union(enum)`)

- Represent sub-states that are conditionally active or mutually exclusive as Zig `union(enum)` tagged unions (e.g. `SlideshowMode = union(enum) { inactive, active: struct { interval_s: f32, timer_ms: f32 } }`, `DisplayState = union(enum) { headless, windowed: ActiveWindow }`).
- This guarantees that variables specific to an active state (such as timers, window handles, title buffers, screenshot streams) do not exist in memory when the state is inactive.
- **Safety Invariant**: Always payload-match via explicit `switch (union)` as specified in [`zig_memory_safety.md`](zig_memory_safety.md#tagged-union-access-in-release-modes).

## 2. Streaming Dataset Compatibility

- Do NOT wrap live-streamed dataset collections (`image_list`, `current_index`) into mutually exclusive tagged unions (e.g. `scanning` vs `active`) if background worker threads stream discovery events continuously into main-thread event queues (`MpscQueue`).
- Keep dataset navigation as a unified struct to avoid pattern-matching friction on every event pulse. See [`concurrency_and_gpu_threading.md`](concurrency_and_gpu_threading.md#event-channel-transport-mpscqueue--event-loop-wakeup).

## 3. Domain Type Passing Over Facade Unwrapping

- Rather than exposing facade getters on the root state that convert tagged unions back into optionals (e.g. `state.getWindow() -> ?sdl.Window`), pass domain tagged unions directly to consumer functions (e.g. `stopTextInput(display: DisplayState)`).
- Pattern match inside consumer functions to guarantee compile-time safety and eliminate optional unwrapping at call sites.

```zig
// AVOID: Facade getters unwrapping tagged unions into optionals
pub fn getWindow(self: *const AppState) ?sdl.Window {
    return switch (self.display) {
        .windowed => |w| w.handle,
        .headless => null,
    };
}

// PREFER: Passing domain tagged unions directly and pattern matching in consumers
pub fn stopTextInput(display: DisplayState) void {
    switch (display) {
        .windowed => |w| w.handle.stopTextInput(),
        .headless => {},
    }
}
```

## 4. Self-Documenting State Unions

- Document every tagged union, field payload, and helper method with explicit Zig `///` doc comments detailing state variants, units, and lifecycle guarantees.
