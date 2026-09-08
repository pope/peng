pub const animation = @import("animation.zig");
pub const asset_upload = @import("asset_upload.zig");
pub const cache = @import("cache.zig");
pub const context = @import("context.zig");
pub const input = @import("input.zig");
pub const intents = @import("intents.zig");
pub const ipc = @import("ipc.zig");
pub const metrics = @import("metrics.zig");
pub const palette_input = @import("palette_input.zig");
pub const slideshow = @import("slideshow.zig");
pub const ui_interactions = @import("ui_interactions.zig");
pub const viewport = @import("viewport.zig");
pub const window = @import("window.zig");

pub const FrameContext = context.FrameContext;
pub const sysExecuteIntents = intents.sysExecuteIntents;
pub const sysExecuteIpcCommands = ipc.sysExecuteIpcCommands;
pub const sysProcessAssetUploads = asset_upload.sysProcessAssetUploads;
pub const sysProcessInput = input.sysProcessInput;
pub const sysProcessPaletteInput = palette_input.sysProcessPaletteInput;
pub const sysProcessUiInteractions = ui_interactions.sysProcessUiInteractions;
pub const sysSyncMetrics = metrics.sysSyncMetrics;
pub const sysSyncWindow = window.sysSyncWindow;
pub const sysUpdateAnimations = animation.sysUpdateAnimations;
pub const sysUpdateCache = cache.sysUpdateCache;
pub const sysUpdateSlideshow = slideshow.sysUpdateSlideshow;
pub const sysUpdateViewport = viewport.sysUpdateViewport;

test {
    _ = @import("animation.zig");
    _ = @import("asset_upload.zig");
    _ = @import("cache.zig");
    _ = @import("context.zig");
    _ = @import("input.zig");
    _ = @import("intents.zig");
    _ = @import("ipc.zig");
    _ = @import("metrics.zig");
    _ = @import("palette_input.zig");
    _ = @import("slideshow.zig");
    _ = @import("ui_interactions.zig");
    _ = @import("viewport.zig");
    _ = @import("window.zig");
}
