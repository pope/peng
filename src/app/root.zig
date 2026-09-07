//! Application Core Module
//!
//! Encapsulates domain sub-states, background event handling, file I/O,
//! IPC protocol handling, image decoding pipelines, and system update passes.

pub const core = @import("core/root.zig");
pub const events = @import("events.zig");
pub const state = @import("state.zig");
pub const systems = @import("systems/root.zig");
pub const workers = @import("workers/root.zig");

pub const drainWorkerEvents = events.drainWorkerEvents;

test {
    _ = @import("state.zig");
    _ = @import("core/root.zig");
    _ = @import("events.zig");
    _ = @import("systems/root.zig");
    _ = @import("workers/root.zig");
}
