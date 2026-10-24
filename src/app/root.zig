//! Application Core Module
//!
//! Encapsulates domain sub-states, background event handling, file I/O,
//! IPC protocol handling, image decoding pipelines, and system update passes.

pub const events = @import("events.zig");
pub const state = @import("state.zig");
pub const systems = @import("systems/root.zig");
pub const thumb_cache = @import("core/thumb_cache.zig");
pub const workers = @import("workers/root.zig");

/// Drains pending worker thread background events from `state.workers.event_queue`,
/// mutating application state and updating active cache/playlist status accordingly.
pub const drainWorkerEvents = events.drainWorkerEvents;

test {
    _ = events;
    _ = state;
    _ = systems;
    _ = workers;
}
