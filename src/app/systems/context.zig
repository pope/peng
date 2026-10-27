const app_state = @import("../state.zig");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;

/// Contextual state, temporary frame allocator, input events, and delta time
/// passed to every update system.
pub const FrameContext = struct {
    state: *AppState,
    frame_allocator: std.mem.Allocator,
    input: ?state_pkg.FrameInput = null,
    delta_time_ms: f64 = 0.0,
    /// Current frame timestamp in milliseconds.
    now_ms: u64 = 0,
};
