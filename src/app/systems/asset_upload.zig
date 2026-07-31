const std = @import("std");
const app_state = @import("../state.zig");
const ViewerState = app_state.ViewerState;

/// System Pass: Uploads decoded CPU surfaces in cache slots to GPU textures.
pub fn sysProcessAssetUploads(state: *ViewerState) void {
    state.updateCurrentRotation();
    state.prepareCacheTextures();
}

test "sysProcessAssetUploads - safe execution on headless state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try ViewerState.initHeadless(allocator, io);
    defer state.deinit();

    sysProcessAssetUploads(&state);
}
