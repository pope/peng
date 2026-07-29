const std = @import("std");
const app_state = @import("../state.zig");
const ViewerState = app_state.ViewerState;

/// System Pass: Asset Upload & Preload Pipeline
pub fn sysProcessAssetUploads(state: *ViewerState) void {
    state.updateCurrentRotation();
    state.prepareCacheTextures();
    _ = state.processBackgroundEvents();

    const needs_cache_update = blk: {
        if (state.getCurrentEntry()) |entry| {
            switch (entry.status) {
                .decoding => |d| break :blk !d.has_thread,
                else => break :blk false,
            }
        }
        break :blk (state.navigation.current_index != null);
    };
    if (needs_cache_update and state.active_decode_threads.load(.acquire) < ViewerState.getMaxConcurrentDecodes()) {
        const count = state.navigation.image_list.items.len;
        if (count > 0) {
            if (state.navigation.current_index == null) state.navigation.current_index = 0;
            state.updateCache() catch |err| std.log.err("Failed to update cache: {}", .{err});
        }
    }

    state.checkIdlePreload();
}
