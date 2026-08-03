const std = @import("std");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;
const FrameContext = @import("root.zig").FrameContext;

/// System Pass: Uploads decoded CPU surfaces in cache slots to GPU textures.
pub fn sysProcessAssetUploads(ctx: FrameContext) void {
    const state = ctx.state;
    state.updateCurrentRotation();
    state.prepareCacheTextures();
}

test "sysProcessAssetUploads - safe execution on headless state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysProcessAssetUploads(ctx);
}

