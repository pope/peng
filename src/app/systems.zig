pub const systems = @import("systems/root.zig");

pub const FrameContext = systems.FrameContext;

pub const sysExecuteIntents = systems.sysExecuteIntents;
pub const sysUpdateSlideshow = systems.sysUpdateSlideshow;
pub const sysUpdateViewport = systems.sysUpdateViewport;
pub const sysProcessAssetUploads = systems.sysProcessAssetUploads;
pub const sysSyncMetrics = systems.sysSyncMetrics;
pub const sysUpdateCache = systems.sysUpdateCache;
pub const sysExecuteIpcCommands = systems.sysExecuteIpcCommands;
pub const sysProcessInput = systems.sysProcessInput;
pub const sysProcessPaletteInput = systems.sysProcessPaletteInput;

test "systems facade exports" {
    @import("std").testing.refAllDecls(@This());
}
