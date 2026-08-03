const std = @import("std");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;
const state_pkg = @import("state");
const CacheEntry = state_pkg.CacheEntry;
const image = @import("../core/image.zig");
const CacheSlotMap = image.CacheSlotMap;
const workers_mod = @import("../workers/root.zig");
const DecodeArgs = workers_mod.DecodeArgs;
const sdl = @import("sdl");

fn spawnCacheDecodeSlot(state: *AppState, index: usize, dup_path: [:0]const u8) !void {
    errdefer state.allocator.free(dup_path);

    const args = try state.allocator.create(DecodeArgs);
    errdefer state.allocator.destroy(args);

    const key = state.cache.activeKey(index);
    if (state.cache.get(key)) |entry| {
        switch (entry.status) {
            .decoding => |*dec| dec.has_thread = true,
            else => {},
        }
    }
    errdefer {
        if (state.cache.get(key)) |entry| {
            switch (entry.status) {
                .decoding => |*dec| dec.has_thread = false,
                else => {},
            }
        }
    }

    args.* = DecodeArgs{
        .workers = &state.workers,
        .allocator = state.allocator,
        .io = state.io,
        .key = key,
        .path = dup_path,
        .has_gpu_device = state.gpu_device != null,
        .pixel_format = state.viewer.display.getPixelFormat(),
    };

    try workers_mod.spawnDecode(args);
}

const FrameContext = @import("root.zig").FrameContext;

/// System function that manages RAM/GPU cache slot eviction, calculates prefetch windows
/// (accounting for rapid navigation throttling), and spawns background image decode workers.
pub fn sysUpdateCache(ctx: FrameContext) !void {
    const state = ctx.state;
    state.updateCurrentRotation();

    const len = state.viewer.navigation.image_list.items.len;
    if (len == 0) return;

    const idx = state.viewer.navigation.current_index orelse return;

    // 1. Gather desired indices (5-slot window: idx, +1, +2, -1, -2)
    var desired_count: usize = 0;
    var desired: [5]usize = undefined;
    desired[0] = idx;
    desired_count = 1;

    for ([_]usize{
        (idx + 1) % len,
        (idx + 2) % len,
        (idx + len - 1) % len,
        if (len >= 2) (idx + len - 2) % len else idx,
    }) |d| {
        var unique = true;
        for (desired[0..desired_count]) |existing| {
            if (existing == d) {
                unique = false;
                break;
            }
        }
        if (unique) {
            desired[desired_count] = d;
            desired_count += 1;
        }
    }

    const dev_opt = state.gpu_device;

    // 2. Evict cache entries that are no longer wanted
    var i: usize = 0;
    while (i < state.cache.entries.items.len) {
        const key = state.cache.keys.items[i];
        var wanted = false;
        for (desired[0..desired_count]) |d| {
            if (key.index == d) {
                wanted = true;
                break;
            }
        }
        if (!wanted) {
            state.cache.removeAndDeinit(i, dev_opt);
        } else {
            i += 1;
        }
    }

    // Fast-scrolling check
    const now = sdl.timer.getTicks();
    const is_fast_scrolling = (now - state.viewer.navigation.last_nav_time_ms < 150);

    // 3. Mark missing slots as decoding in cache map
    var to_spawn_indices: [5]usize = undefined;
    var to_spawn_paths: [5]?[:0]const u8 = [1]?[:0]const u8{null} ** 5;
    var to_spawn_count: usize = 0;
    var hit = false;

    for (desired[0..desired_count]) |d| {
        if (d >= state.viewer.navigation.image_list.items.len) continue;

        if (is_fast_scrolling and d != idx) continue;

        const key = state.cache.activeKey(d);
        if (state.cache.get(key)) |entry| {
            if (d == idx and (entry.status == .loaded_cpu or entry.status == .loaded_gpu)) {
                hit = true;
            }
        } else {
            _ = try state.cache.appendSlot(state.allocator, d, .{ .decoding = .{} });
        }

        if (state.cache.get(key)) |entry| {
            switch (entry.status) {
                .decoding => |dec| {
                    if (!dec.has_thread) {
                        if (to_spawn_count < 5) {
                            to_spawn_indices[to_spawn_count] = d;
                            to_spawn_paths[to_spawn_count] = try state.allocator.dupeZ(u8, state.viewer.navigation.image_list.items[d]);
                            to_spawn_count += 1;
                        }
                    }
                },
                else => {},
            }
        }
    }
    state.viewer.stats.current_image_cache_hit = hit;

    // 4. Spawn worker threads
    for (to_spawn_indices[0..to_spawn_count], 0..) |d, s_idx| {
        const path_opt = to_spawn_paths[s_idx];
        if (path_opt == null or !state.workers.canSpawnDecode()) {
            if (path_opt) |p| state.allocator.free(p);
            continue;
        }

        const dup_path = path_opt.?;
        spawnCacheDecodeSlot(state, d, dup_path) catch |err| {
            std.log.err("Failed to spawn decode worker for index {}: {}", .{ d, err });
        };
    }
}

test "sysUpdateCache - empty image list" {
    const allocator = std.testing.allocator;
    var state = try AppState.initHeadless(allocator, std.Io.Threaded.global_single_threaded.io());
    defer state.deinit();

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);
    try std.testing.expectEqual(@as(usize, 0), state.cache.entries.items.len);
}

test "sysUpdateCache - populates prefetch window and evicts unwanted entries" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Populate mock image list with 5 images
    const paths = [_][]const u8{ "img0.png", "img1.png", "img2.png", "img3.png", "img4.png" };
    for (paths) |p| {
        const dup = try state.viewer.navigation.directory_arena.allocator().dupe(u8, p);
        try state.viewer.navigation.image_list.append(allocator, dup);
    }
    state.viewer.navigation.current_index = 0;

    // Add an out-of-window entry at index 99
    try state.cache.appendWithKey(allocator, .{
        .index = 99,
        .generation = state.viewer.generation,
    }, .{
        .status = .{ .failed = {} },
    });
    try std.testing.expectEqual(@as(usize, 1), state.cache.entries.items.len);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Index 99 should have been evicted, and current index 0 should be present
    try std.testing.expect(state.cache.get(state.activeKey(99)) == null);
    try std.testing.expect(state.cache.get(state.activeKey(0)) != null);
}

