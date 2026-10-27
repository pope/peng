//! Core Sub-module of App
//!
//! Houses pure, state-free utility types, file system helpers,
//! image cache slot maps, palette helpers, and messaging constructs used
//! internally by app system passes and worker threads.
//!
//! INVARIANT: Code in `src/app/core/` MUST NOT depend on any code in `src/app/`
//! outside of `src/app/core/` (zero imports of `AppState`, systems, workers, or app actions).

pub const events = @import("events.zig");
pub const fs = @import("fs.zig");
pub const image = @import("image.zig");
pub const palette = @import("palette.zig");
pub const thumb_cache = @import("thumb_cache.zig");

test {
    _ = events;
    _ = fs;
    _ = image;
    _ = palette;
    _ = thumb_cache;
}
