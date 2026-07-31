const std = @import("std");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;
const state_pkg = @import("state");
const CacheEntry = state_pkg.CacheEntry;
const CacheSlotMap = app_state.CacheSlotMap;
const workers_mod = @import("../workers/root.zig");
const DecodeArgs = workers_mod.DecodeArgs;
const sdl = @import("sdl");

/// System function that manages RAM/GPU cache slot eviction, calculates prefetch windows
/// (accounting for rapid navigation throttling), and spawns background image decode workers.
pub fn sysUpdateCache(state: *AppState) !void {
    state.updateCurrentRotation();

    const len = state.viewer.navigation.image_list.items.len;
    if (len == 0) return;

    const idx = state.viewer.navigation.current_index orelse return;
    const gen = state.viewer.generation;

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

    var to_spawn_count: usize = 0;
    var to_spawn_indices: [5]usize = undefined;
    var hit = false;

    const dev_opt = state.gpu_device;

    // 2. Evict cache entries that are no longer wanted
    var i: usize = 0;
    while (i < state.cache.entries.items.len) {
        const entry = &state.cache.entries.items[i];
        var wanted = false;
        for (desired[0..desired_count]) |d| {
            if (entry.index == d) {
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

    const now = sdl.timer.getTicks();
    const is_fast_scrolling = (now - state.viewer.navigation.last_nav_time_ms < 150);

    // 3. Mark wanted entries that are not in the cache yet as .decoding
    for (desired[0..desired_count]) |d| {
        // While fast-scrolling, only spawn decodes for the current index to avoid CPU/IO stutter.
        if (is_fast_scrolling and d != idx) continue;

        var needs_thread = false;
        if (state.cache.get(d)) |entry| {
            if (d == idx and (entry.status == .loaded_cpu or entry.status == .loaded_gpu)) {
                hit = true;
            }
            switch (entry.status) {
                .decoding => |dec| {
                    if (!dec.has_thread) {
                        needs_thread = true;
                    }
                },
                else => {},
            }
        } else {
            const new_entry = CacheEntry{
                .index = d,
                .generation = gen,
                .status = .{ .decoding = .{ .has_thread = false } },
                .full_w = 0.0,
                .full_h = 0.0,
            };
            try state.cache.append(state.allocator, new_entry);
            needs_thread = true;
        }
        if (needs_thread) {
            to_spawn_indices[to_spawn_count] = d;
            to_spawn_count += 1;
        }
    }
    state.viewer.stats.current_image_cache_hit = hit;

    // 4. Batch-fetch file paths
    var to_spawn_paths: [5]?[:0]const u8 = undefined;
    for (to_spawn_indices[0..to_spawn_count], 0..) |d, s_idx| {
        if (d < state.viewer.navigation.image_list.items.len) {
            to_spawn_paths[s_idx] = state.allocator.dupeZ(u8, state.viewer.navigation.image_list.items[d]) catch |err| blk: {
                std.log.err("sysUpdateCache: dupeZ failed for image index {d}: {}", .{ d, err });
                break :blk null;
            };
        } else {
            to_spawn_paths[s_idx] = null;
        }
    }

    // 5. Spawn worker threads
    for (to_spawn_indices[0..to_spawn_count], 0..) |d, s_idx| {
        const path_opt = to_spawn_paths[s_idx];
        if (path_opt == null or !state.workers.canSpawnDecode()) {
            if (path_opt) |p| state.allocator.free(p);
            continue;
        }

        const dup_path = path_opt.?;

        const args = state.allocator.create(DecodeArgs) catch |err| {
            state.allocator.free(dup_path);
            for (to_spawn_paths[s_idx + 1 .. to_spawn_count]) |rem_path_opt| {
                if (rem_path_opt) |rp| state.allocator.free(rp);
            }
            var k: usize = 0;
            while (k < state.cache.entries.items.len) : (k += 1) {
                if (state.cache.entries.items[k].index == d) {
                    state.cache.removeAndDeinit(k, dev_opt);
                    break;
                }
            }
            return err;
        };

        if (state.cache.get(d)) |entry| {
            switch (entry.status) {
                .decoding => |*dec| dec.has_thread = true,
                else => {},
            }
        }

        args.* = DecodeArgs{
            .workers = &state.workers,
            .allocator = state.allocator,
            .io = state.io,
            .index = d,
            .path = dup_path,
            .has_gpu_device = state.gpu_device != null,
            .pixel_format = state.viewer.display.getPixelFormat(),
        };

        workers_mod.spawnDecode(args) catch |err| {
            std.log.err("workers.spawnDecode failed: {}", .{err});
            state.allocator.free(dup_path);
            state.allocator.destroy(args);
            if (state.cache.get(d)) |entry| {
                switch (entry.status) {
                    .decoding => |*dec| dec.has_thread = false,
                    else => {},
                }
            }
        };
    }
}

/// System function that triggers background cache prefetching when the engine loop is idle.
pub fn sysCheckIdlePreload(state: *AppState) void {
    if (state.viewer.navigation.image_list.items.len <= 1) return;
    const now = sdl.timer.getTicks();
    if (now - state.viewer.navigation.last_nav_time_ms >= 150) {
        sysUpdateCache(state) catch |err| std.log.warn("Idle preload sysUpdateCache failed: {}", .{err});
    }
}

test "sysUpdateCache - empty image list" {
    const allocator = std.testing.allocator;
    var state = try AppState.initHeadless(allocator, std.Io.Threaded.global_single_threaded.io());
    defer state.deinit();

    try sysUpdateCache(&state);
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
    try state.cache.append(allocator, .{
        .index = 99,
        .generation = state.viewer.generation,
        .status = .{ .failed = {} },
    });
    try std.testing.expectEqual(@as(usize, 1), state.cache.entries.items.len);

    try sysUpdateCache(&state);

    // Index 99 should have been evicted, and current index 0 should be present
    try std.testing.expect(state.cache.get(99) == null);
    try std.testing.expect(state.cache.get(0) != null);
}

test "sysCheckIdlePreload - single image list" {
    const allocator = std.testing.allocator;
    var state = try AppState.initHeadless(allocator, std.Io.Threaded.global_single_threaded.io());
    defer state.deinit();

    sysCheckIdlePreload(&state);
    try std.testing.expectEqual(@as(usize, 0), state.cache.entries.items.len);
}

test "sysCheckIdlePreload - triggers preloading when idle" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const paths = [_][]const u8{ "a.png", "b.png" };
    for (paths) |p| {
        const dup = try state.viewer.navigation.directory_arena.allocator().dupe(u8, p);
        try state.viewer.navigation.image_list.append(allocator, dup);
    }
    state.viewer.navigation.current_index = 0;
    state.viewer.navigation.last_nav_time_ms = 0; // Simulated past time to satisfy idle threshold (>150ms)

    sysCheckIdlePreload(&state);
    try std.testing.expect(state.cache.entries.items.len > 0);
}
