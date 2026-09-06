const app_state = @import("../state.zig");
pub const asset_upload = @import("asset_upload.zig");
pub const cache = @import("cache.zig");
pub const input = @import("input.zig");
pub const intents = @import("intents.zig");
pub const ipc = @import("ipc.zig");
pub const metrics = @import("metrics.zig");
pub const palette_input = @import("palette_input.zig");
pub const slideshow = @import("slideshow.zig");
const state_pkg = @import("state");
const std = @import("std");
pub const ui_interactions = @import("ui_interactions.zig");
pub const viewport = @import("viewport.zig");
pub const window = @import("window.zig");

const AppState = app_state.AppState;
pub const sysExecuteIntents = intents.sysExecuteIntents;
pub const sysExecuteIpcCommands = ipc.sysExecuteIpcCommands;
pub const sysProcessAssetUploads = asset_upload.sysProcessAssetUploads;
pub const sysProcessInput = input.sysProcessInput;
pub const sysProcessPaletteInput = palette_input.sysProcessPaletteInput;
pub const sysProcessUiInteractions = ui_interactions.sysProcessUiInteractions;
pub const sysSyncMetrics = metrics.sysSyncMetrics;
pub const sysSyncWindow = window.sysSyncWindow;
pub const sysUpdateCache = cache.sysUpdateCache;
pub const sysUpdateSlideshow = slideshow.sysUpdateSlideshow;
pub const sysUpdateViewport = viewport.sysUpdateViewport;

/// Contextual state, temporary frame allocator, input events, and delta time passed to every update system.
pub const FrameContext = struct {
    state: *AppState,
    frame_allocator: std.mem.Allocator,
    input: ?state_pkg.FrameInput = null,
    delta_time_ms: f64 = 0.0,
};

test {
    _ = intents;
    _ = slideshow;
    _ = viewport;
    _ = asset_upload;
    _ = metrics;
    _ = cache;
    _ = ipc;
    _ = input;
    _ = palette_input;
    _ = window;
    _ = ui_interactions;
}
