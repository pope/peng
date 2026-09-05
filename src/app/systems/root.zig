const std = @import("std");
const state_pkg = @import("state");
const AppState = @import("../state.zig").AppState;

pub const FrameContext = struct {
    state: *AppState,
    frame_allocator: std.mem.Allocator,
    input: ?state_pkg.FrameInput = null,
    delta_time_ms: f64 = 0.0,
};

pub const intents = @import("intents.zig");
pub const slideshow = @import("slideshow.zig");
pub const viewport = @import("viewport.zig");
pub const asset_upload = @import("asset_upload.zig");
pub const metrics = @import("metrics.zig");
pub const cache = @import("cache.zig");
pub const ipc = @import("ipc.zig");
pub const input = @import("input.zig");
pub const palette_input = @import("palette_input.zig");
pub const window = @import("window.zig");
pub const ui_interactions = @import("ui_interactions.zig");

pub const sysExecuteIntents = intents.sysExecuteIntents;
pub const sysUpdateSlideshow = slideshow.sysUpdateSlideshow;
pub const sysUpdateViewport = viewport.sysUpdateViewport;
pub const sysProcessAssetUploads = asset_upload.sysProcessAssetUploads;
pub const sysSyncMetrics = metrics.sysSyncMetrics;
pub const sysUpdateCache = cache.sysUpdateCache;
pub const sysExecuteIpcCommands = ipc.sysExecuteIpcCommands;
pub const sysProcessInput = input.sysProcessInput;
pub const sysProcessPaletteInput = palette_input.sysProcessPaletteInput;
pub const sysSyncWindow = window.sysSyncWindow;
pub const sysProcessUiInteractions = ui_interactions.sysProcessUiInteractions;

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
