//! Engine Core Module
//!
//! Houses pure, state-free utility types, image cache slot maps, palette
//! helpers, and messaging constructs used internally by app system passes and
//! worker threads.
//!
//! INVARIANT: Code in `src/core/` MUST NOT depend on `src/app/` or `src/ui/`
//! (zero imports of `AppState`, systems, workers, or app actions).

pub const display = @import("display.zig");
pub const image = @import("image.zig");
pub const mpsc_queue = @import("mpsc_queue.zig");
pub const thumbcache = @import("thumbcache.zig");

/// Thread-safe multi-producer single-consumer queue backed by a mutex and
/// `ArrayList`.
pub const MpscQueue = mpsc_queue.MpscQueue;

test {
    _ = display;
    _ = image;
    _ = mpsc_queue;
    _ = thumbcache;
}
