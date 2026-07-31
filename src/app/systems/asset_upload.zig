const std = @import("std");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;

/// System Pass: Uploads decoded CPU surfaces in cache slots to GPU textures.
pub fn sysProcessAssetUploads(state: *AppState) void {
    state.updateCurrentRotation();
    state.prepareCacheTextures();
}

test "sysProcessAssetUploads - safe execution on headless state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    sysProcessAssetUploads(&state);
}
