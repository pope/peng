pub const intent_dispatch = @import("intent_dispatch.zig");
pub const slideshow = @import("slideshow.zig");
pub const viewport = @import("viewport.zig");
pub const asset_upload = @import("asset_upload.zig");
pub const metrics = @import("metrics.zig");
pub const events = @import("events.zig");
pub const cache = @import("cache.zig");
pub const ipc = @import("ipc.zig");

pub const sysExecuteIntents = intent_dispatch.sysExecuteIntents;
pub const sysUpdateSlideshow = slideshow.sysUpdateSlideshow;
pub const sysUpdateViewport = viewport.sysUpdateViewport;
pub const sysProcessAssetUploads = asset_upload.sysProcessAssetUploads;
pub const sysSyncMetrics = metrics.sysSyncMetrics;
pub const sysProcessBackgroundEvents = events.sysProcessBackgroundEvents;
pub const sysUpdateCache = cache.sysUpdateCache;
pub const sysCheckIdlePreload = cache.sysCheckIdlePreload;
pub const sysExecuteIpcCommands = ipc.sysExecuteIpcCommands;

test "systems root exports" {
    @import("std").testing.refAllDecls(@This());
}
