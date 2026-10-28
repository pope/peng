//! Core Sub-module of App
//!
//! Houses pure, state-free utility types, image cache slot maps, palette
//! helpers, and messaging constructs used internally by app system passes and
//! worker threads.
//!
//! INVARIANT: Code in `src/app/core/` MUST NOT depend on any code in `src/app/`
//! outside of `src/app/core/` (zero imports of `AppState`, systems, workers,
//! or app actions).

pub const events = @import("events.zig");
pub const image = @import("image.zig");
pub const thumbcache = @import("thumbcache.zig");

test {
    _ = events;
    _ = image;
    _ = thumbcache;
}
