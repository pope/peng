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

/// Spawns an asynchronous worker task to decode an image file from disk into RAM.
///
/// Pre-conditions: `dup_path` must be a valid null-terminated heap string owned by the caller.
/// On failure, `dup_path` is freed via `errdefer`.
///
/// Parameters:
/// - `state`: Pointer to global application state.
/// - `index`: Image list index being decoded.
/// - `dup_path`: Null-terminated file path string.
/// - `thumb_only`: If true, restricts decoding to low-resolution thumbnail for rapid scrolling.
const MediaEntry = state_pkg.MediaEntry;

fn spawnCacheDecodeSlot(state: *AppState, index: usize, entry_item: MediaEntry, thumb_only: bool) !void {
    const dup_entry = entry_item.dupe(state.allocator) catch |err| {
        std.log.err("Failed to dupe MediaEntry for decode worker: {}", .{err});
        return err;
    };
    errdefer dup_entry.deinit(state.allocator);

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
        .entry = dup_entry,
        .has_gpu_device = state.gpu_device != null,
        .pixel_format = state.viewer.display.getPixelFormat(),
        .thumb_only = thumb_only,
    };

    try workers_mod.spawnDecode(args);
}

const FrameContext = @import("root.zig").FrameContext;

/// System Pass: Update image RAM/GPU texture cache and background preloading window.
pub fn sysUpdateCache(ctx: FrameContext) !void {
    const state = ctx.state;
    state.updateCurrentRotation();

    const len = state.viewer.navigation.image_list.items.len;
    if (len == 0) return;

    const idx = state.viewer.navigation.current_index orelse 0;

    // 1. Gather desired indices dynamically using frame_allocator
    var desired_list: std.ArrayList(usize) = .empty;
    defer desired_list.deinit(ctx.frame_allocator);

    const nav = &state.viewer.navigation;
    if (nav.view_mode == .comics_strip) {
        const frustum = nav.visible_frustum;
        const first = frustum.first_index;
        const last = frustum.last_index;

        // Tier 1: Visible frustum [first..last]
        var d = first;
        while (d <= last and d < len) : (d += 1) {
            try desired_list.append(ctx.frame_allocator, d);
        }

        // Tier 2 & 3: Buffer ring (3 before first, 6 after last)
        var b_behind: usize = 1;
        while (b_behind <= 3 and first >= b_behind) : (b_behind += 1) {
            try desired_list.append(ctx.frame_allocator, first - b_behind);
        }
        var b_ahead: usize = 1;
        while (b_ahead <= 6 and last + b_ahead < len) : (b_ahead += 1) {
            try desired_list.append(ctx.frame_allocator, last + b_ahead);
        }

        // Deduplicate
        var clean_list: std.ArrayList(usize) = .empty;
        defer clean_list.deinit(ctx.frame_allocator);
        for (desired_list.items) |item| {
            var found = false;
            for (clean_list.items) |u| {
                if (u == item) {
                    found = true;
                    break;
                }
            }
            if (!found) try clean_list.append(ctx.frame_allocator, item);
        }
        desired_list.clearRetainingCapacity();
        try desired_list.appendSlice(ctx.frame_allocator, clean_list.items);
    } else {
        try desired_list.append(ctx.frame_allocator, idx);
        for ([_]usize{
            (idx + 1) % len,
            (idx + 2) % len,
            (idx + len - 1) % len,
            if (len >= 2) (idx + len - 2) % len else idx,
        }) |d| {
            var unique = true;
            for (desired_list.items) |existing| {
                if (existing == d) {
                    unique = false;
                    break;
                }
            }
            if (unique) {
                try desired_list.append(ctx.frame_allocator, d);
            }
        }
    }

    const desired = desired_list.items;
    const dev_opt = state.gpu_device;

    // 2. Evict cache entries that are no longer wanted
    var i: usize = 0;
    while (i < state.cache.count()) {
        const keys = state.cache.slots.items(.key);
        const key = keys[i];
        var wanted = false;
        for (desired) |d| {
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
    var to_spawn_indices: std.ArrayList(usize) = .empty;
    defer to_spawn_indices.deinit(ctx.frame_allocator);
    var to_spawn_entries: std.ArrayList(MediaEntry) = .empty;
    defer to_spawn_entries.deinit(ctx.frame_allocator);

    var hit = false;

    for (desired) |d| {
        if (d >= state.viewer.navigation.image_list.items.len) continue;

        if (is_fast_scrolling and d != idx and nav.view_mode != .comics_strip) continue;

        const key = state.cache.activeKey(d);
        if (state.cache.get(key)) |entry| {
            if (d == idx and (entry.status == .loaded_cpu or entry.status == .loaded_gpu)) {
                hit = true;
            }
            switch (entry.status) {
                .decoding => |dec| {
                    if (!dec.has_thread) {
                        try to_spawn_indices.append(ctx.frame_allocator, d);
                        try to_spawn_entries.append(ctx.frame_allocator, state.viewer.navigation.image_list.items[d]);
                    }
                },
                else => {},
            }
        } else {
            _ = try state.cache.appendSlot(state.allocator, d, .{ .decoding = .{} });
            try to_spawn_indices.append(ctx.frame_allocator, d);
            try to_spawn_entries.append(ctx.frame_allocator, state.viewer.navigation.image_list.items[d]);
        }
    }
    state.viewer.stats.current_image_cache_hit = hit;

    // 4. Spawn worker threads
    for (to_spawn_indices.items, 0..) |d, s_idx| {
        const item = to_spawn_entries.items[s_idx];
        if (!state.workers.canSpawnDecode()) break;

        spawnCacheDecodeSlot(state, d, item, is_fast_scrolling) catch |err| {
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
    try std.testing.expectEqual(@as(usize, 0), state.cache.count());
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
        try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = dup } });
    }
    state.viewer.navigation.current_index = 0;

    // Add an out-of-window entry at index 99
    try state.cache.appendWithKey(allocator, .{
        .index = 99,
        .generation = state.cache.getGeneration(),
    }, .{
        .status = .{ .failed = {} },
    });
    try std.testing.expectEqual(@as(usize, 1), state.cache.count());

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Index 99 should have been evicted, and current index 0 should be present
    try std.testing.expect(state.cache.get(state.cache.activeKey(99)) == null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(0)) != null);
}
