const app_state = @import("../state.zig");
const context = @import("context.zig");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;

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

test "prepareCacheTextures guards thumbnail eviction during active thumb_crossfade" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "img1.jpg" },
    });
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    // Simulate entry with loaded thumbnail and loaded GPU texture
    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_gpu = .{
                    .gpu_texture = .{ .ptr = @ptrFromInt(0x1234) },
                    .w = 800,
                    .h = 600,
                    .size_bytes = 800 * 600 * 4,
                    .mime_type = "image/jpeg",
                    .decode = .{
                        .read_time_ms = 1,
                        .decode_time_ms = 1,
                        .conversion_time_ms = 1,
                    },
                    .ingest = .{
                        .upload_time_ms = 1,
                        .memory_size_bytes = 800 * 600 * 4,
                    },
                },
            },
            .thumbnail = .{ .loaded = .{
                .texture = .{ .ptr = @ptrFromInt(0x5678) },
                .info = .{ .w = 160, .h = 120, .upload_time_ms = 1 },
            } },
        },
    });

    // Case 1: thumb_crossfade is active -> prepareCacheTextures MUST NOT evict thumbnail
    state.viewer.animations.startFrom(
        .thumb_crossfade,
        0.0,
        1.0,
        120.0,
        .ease_out_quad,
    );
    state.prepareCacheTextures();
    var entry = state.cache.get(state.cache.activeKey(id0)).?;
    try std.testing.expect(entry.resident.thumbnail == .loaded);

    // Case 2: thumb_crossfade settles -> prepareCacheTextures evicts thumbnail
    state.viewer.animations.settle(.thumb_crossfade);
    state.prepareCacheTextures();
    entry = state.cache.get(state.cache.activeKey(id0)).?;
    try std.testing.expect(entry.resident.thumbnail == .unloaded);
}
