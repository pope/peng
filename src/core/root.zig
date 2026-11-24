//! Engine Core Module
//!
//! Houses pure, state-free engine constructs (`display`, `mpsc_queue`,
//! `preview`, and `thumbcache`) used by application system passes, worker
//! threads, and standalone CLI utilities.
//!
//! INVARIANT: Code in `src/core/` MUST NOT depend on `src/app/` or `src/ui/`
//! (zero imports of `AppState`, systems, workers, or app actions).

pub const display = @import("display.zig");
pub const mpsc_queue = @import("mpsc_queue.zig");
pub const preview = @import("preview.zig");
pub const thumbcache = @import("thumbcache.zig");

/// Thread-safe multi-producer single-consumer queue backed by a mutex and
/// `ArrayList`.
pub const MpscQueue = mpsc_queue.MpscQueue;

test {
    _ = display;
    _ = mpsc_queue;
    _ = preview;
    _ = thumbcache;
}
