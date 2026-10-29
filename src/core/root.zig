//! Engine Core Module
//!
//! Houses pure, state-free utility types, image cache slot maps, palette
//! helpers, and messaging constructs used internally by app system passes and
//! worker threads.
//!
//! INVARIANT: Code in `src/core/` MUST NOT depend on `src/app/` or `src/ui/`
//! (zero imports of `AppState`, systems, workers, or app actions).

pub const display = @import("display.zig");
pub const events = @import("events.zig");
pub const image = @import("image.zig");
pub const thumbcache = @import("thumbcache.zig");

test {
    _ = display;
    _ = events;
    _ = image;
    _ = thumbcache;
}
