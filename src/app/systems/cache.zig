const app_state = @import("../state.zig");
const context = @import("context.zig");
const decode_mod = @import("../workers/decode.zig");
const image = @import("../core/image.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const CacheEntry = state_pkg.CacheEntry;
const CacheSlotMap = image.CacheSlotMap;
const DecodeArgs = decode_mod.DecodeArgs;
const FrameContext = context.FrameContext;
const MediaEntry = state_pkg.MediaEntry;

/// Fast-scrolling threshold: when navigation events occur faster than this interval,
/// worker spawning is throttled exclusively to the active slot `idx`.
const FAST_SCROLL_THRESHOLD_MS: u64 = state_pkg.LOADING_GRACE_PERIOD_MS;

/// Spawns an asynchronous worker task to decode an image file from disk into RAM.
///
/// Pre-conditions: `entry_item` is cloned into a duplicated heap instance owned by the decode task.
/// On failure, resources are freed via `errdefer`.
///
/// Parameters:
/// - `state`: Pointer to global application state.
/// - `index`: Image list index being decoded.
/// - `entry_item`: Media entry being decoded.
/// - `thumb_only`: If true, restricts decoding to low-resolution thumbnail for rapid scrolling.
fn spawnCacheDecodeSlot(
    state: *AppState,
    index: usize,
    entry_item: MediaEntry,
    thumb_only: bool,
) !void {
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
        .current_generation = &state.cache.generation,
    };

    try decode_mod.spawnDecode(args);
}

/// System Pass: Update image RAM/GPU texture cache and background preloading window.
pub fn sysUpdateCache(ctx: FrameContext) !void {
    const state = ctx.state;
    state.updateCurrentRotation();

    const len = state.viewer.navigation.image_list.items.len;
    if (len == 0) return;

    const idx = state.viewer.navigation.current_index orelse return;

    // 1. Gather desired indices (5-slot window: idx, prioritized along travel direction)
    var desired_count: usize = 0;
    var desired: [5]usize = undefined;
    desired[0] = idx;
    desired_count = 1;

    const next_idx = (idx + 1) % len;
    const prev_idx = (idx + len - 1) % len;
    const next_2 = (idx + 2) % len;
    const prev_2 = if (len >= 2) (idx + len - 2) % len else idx;

    const candidates = if (state.viewer.navigation.direction == .backward)
        [_]usize{ prev_idx, next_idx, prev_2, next_2 }
    else
        [_]usize{ next_idx, prev_idx, next_2, prev_2 };

    for (candidates) |d| {
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

    // 2. Evict cache entries that are no longer wanted, decoupling prefetch from retention
    var i: usize = 0;
    while (i < state.cache.count()) {
        const keys = state.cache.slots.items(.key);
        const entries = state.cache.slots.items(.entry);
        const key = keys[i];
        const entry = entries[i];

        var in_desired = false;
        for (desired[0..desired_count]) |d| {
            if (key.index == d) {
                in_desired = true;
                break;
            }
        }

        if (in_desired) {
            i += 1;
        } else if (entry.status == .loaded_gpu) {
            // Retain loaded GPU textures beyond ±2 window until VRAM budget requires eviction
            i += 1;
        } else if (dev_opt == null and entry.status == .loaded_cpu) {
            // Retain loaded CPU surfaces in headless mode
            i += 1;
        } else {
            state.cache.removeAndDeinit(i, dev_opt);
        }
    }

    state.cache.enforceVramBudget(
        dev_opt,
        idx,
        state.viewer.getTransitionPrevIndex(),
        len,
        image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES,
    );

    // Fast-scrolling check: only active if navigation has actually occurred
    const now = sdl.timer.getTicks();
    const is_fast_scrolling = state.viewer.navigation.last_nav_time_ms > 0 and
        (now -| state.viewer.navigation.last_nav_time_ms < FAST_SCROLL_THRESHOLD_MS);

    state.viewer.stats.max_decode_threads = state.workers.getMaxConcurrentDecodes();

    // Resource protection: check whether the current image is fully ready or failed.
    // When false, background decode workers are restricted strictly to the active image `idx`.
    // In headless/mock mode (no GPU device), .loaded_cpu is terminal ready;
    // with GPU, .loaded_gpu is required.
    const is_current_ready = blk: {
        const cur_key = state.cache.activeKey(idx);
        if (state.cache.get(cur_key)) |cur_entry| {
            break :blk switch (cur_entry.status) {
                .loaded_gpu, .failed => true,
                .loaded_cpu => state.gpu_device == null,
                .decoding, .uploading => false,
            };
        }
        break :blk false;
    };

    // Fast-scrolling thumbnail readiness: check whether active image has
    // thumbnail or full texture ready. Speculative thumbnail preloading for
    // next image only runs if active image thumbnail is already ready.
    const is_active_thumb_ready = blk: {
        const cur_key = state.cache.activeKey(idx);
        if (state.cache.get(cur_key)) |cur_entry| {
            break :blk switch (cur_entry.thumbnail) {
                .loaded, .not_available => true,
                .none, .pending, .unloaded => is_current_ready,
            };
        }
        break :blk false;
    };

    const speculative_idx = if (state.viewer.navigation.direction == .backward)
        prev_idx
    else
        next_idx;

    // 3. Mark missing slots as decoding in cache map
    var to_spawn_indices: [5]usize = undefined;
    var to_spawn_entries: [5]?MediaEntry = [1]?MediaEntry{null} ** 5;
    var to_spawn_count: usize = 0;
    var hit = false;

    for (desired[0..desired_count]) |d| {
        if (d >= state.viewer.navigation.image_list.items.len) continue;

        if (d != idx) {
            if (is_fast_scrolling) {
                if (d != speculative_idx or !is_active_thumb_ready) continue;
            } else {
                if (!is_current_ready) continue;
            }
        }

        const key = state.cache.activeKey(d);
        if (state.cache.get(key)) |entry| {
            if (d == idx and (entry.status == .loaded_cpu or entry.status == .loaded_gpu)) {
                hit = true;
            }
        } else {
            _ = try state.cache.appendSlot(
                state.allocator,
                d,
                .{ .decoding = .{ .start_time_ms = now } },
            );
        }

        if (state.cache.get(key)) |entry| {
            const is_active_slot = (d == idx);
            const needs_dimensions = (entry.full_w <= 0.0 or entry.full_h <= 0.0);
            if (is_active_slot and needs_dimensions) {
                const media_item = state.viewer.navigation.image_list.items[idx];
                if (image.probeMediaMetadata(state.io, media_item)) |meta| {
                    entry.full_w = meta.dims.w;
                    entry.full_h = meta.dims.h;
                    if (meta.orientation != .normal or entry.orientation == .normal) {
                        entry.orientation = meta.orientation;
                    }
                    if (meta.raw_metadata.isRaw()) {
                        entry.raw_metadata = meta.raw_metadata;
                    }
                    if (entry.thumbnail == .none) {
                        entry.thumbnail = if (meta.has_embedded_thumbnail)
                            .pending
                        else
                            .not_available;
                    }
                    state.updateCurrentRotation();
                }
            }

            switch (entry.status) {
                .decoding => |dec| {
                    if (!dec.has_thread) {
                        // During fast scrolling we prioritize thumbnails:
                        // 1. For neighbor slots (d != idx), skip if no thumbnail
                        //    is available or already loaded.
                        // 2. For active slot (d == idx), skip full decode only if
                        //    its thumbnail is already loaded and rendering on screen.
                        //    If no thumbnail is available, immediately decode the full image!
                        const skip_neighbor = d != idx and is_fast_scrolling and
                            (entry.thumbnail == .not_available or entry.thumbnail == .loaded);
                        const skip_active = d == idx and is_fast_scrolling and
                            entry.thumbnail == .loaded;
                        if (skip_neighbor) {
                            // Wait until user settles to trigger full decode of background slots.
                        } else if (skip_active) {
                            // Active thumbnail is already on screen, wait until user settles.
                        } else {
                            if (to_spawn_count < 5) {
                                to_spawn_indices[to_spawn_count] = d;
                                to_spawn_entries[to_spawn_count] =
                                    state.viewer.navigation.image_list.items[d];
                                to_spawn_count += 1;
                            }
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
        const entry_opt = to_spawn_entries[s_idx];
        if (entry_opt == null or !state.workers.canSpawnDecode()) continue;

        const key = state.cache.activeKey(d);
        const thumb_only = is_fast_scrolling and blk: {
            if (state.cache.get(key)) |entry| {
                if (entry.thumbnail == .not_available) break :blk false;
            }
            break :blk true;
        };

        spawnCacheDecodeSlot(state, d, entry_opt.?, thumb_only) catch |err| {
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
        try state.viewer.navigation.image_list.append(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;

    // Add an out-of-window entry at index 99
    _ = try state.cache.appendSlot(allocator, 99, .{ .failed = {} });
    try std.testing.expectEqual(@as(usize, 1), state.cache.count());

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Index 99 should have been evicted, and current index 0 should be present
    try std.testing.expect(state.cache.get(state.cache.activeKey(99)) == null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(0)) != null);
    // While index 0 is decoding, neighbor index 1 should NOT be populated yet
    try std.testing.expect(state.cache.get(state.cache.activeKey(1)) == null);

    // Simulate index 0 finishing decode (loaded in headless state)
    _ = state.cache.updateStatus(state.cache.activeKey(0), .{
        .loaded_cpu = .{
            .surface = undefined,
            .w = 100,
            .h = 100,
            .size_bytes = 1000,
        },
    });

    // Run sysUpdateCache again: now that index 0 is ready, neighbors should populate
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(1)) != null);
}

test "sysUpdateCache - retains loaded entries outside prefetch window until budget exceeded" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // 10 images in list
    for (0..10) |idx| {
        const name = try std.fmt.allocPrint(allocator, "img{}.png", .{idx});
        defer allocator.free(name);
        const dup = try state.viewer.navigation.directory_arena.allocator().dupe(u8, name);
        try state.viewer.navigation.image_list.append(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;

    // Add slot 0 (current) as loaded_cpu so neighbors can populate
    _ = try state.cache.appendSlot(allocator, 0, .{
        .loaded_cpu = .{
            .surface = undefined,
            .w = 100,
            .h = 100,
            .size_bytes = 1000,
        },
    });

    // Add slot 6 (outside desired 0, 1, 2, 9, 8 window) as loaded_gpu
    _ = try state.cache.appendSlot(allocator, 6, .{
        .loaded_gpu = .{
            .gpu_texture = undefined,
            .w = 100,
            .h = 100,
            .size_bytes = 1000,
            .memory_size_bytes = 500 * 1024 * 1024,
        },
    });

    // Also add slot 7 as failed (outside window)
    _ = try state.cache.appendSlot(allocator, 7, .failed);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Slot 7 (.failed outside window) should be evicted
    try std.testing.expect(state.cache.get(state.cache.activeKey(7)) == null);

    // Slot 6 (.loaded_gpu outside window) should be RETAINED under default budget!
    try std.testing.expect(state.cache.get(state.cache.activeKey(6)) != null);

    // Now enforce a small VRAM budget (less than slot 6's 500MB)
    state.cache.enforceVramBudget(state.gpu_device, 0, null, 10, 100);

    // Slot 6 should now be pruned by enforceVramBudget
    try std.testing.expect(state.cache.get(state.cache.activeKey(6)) == null);

    // Reset slot 0 to .failed to prevent calling destroy() on mock undefined surface
    // during defer state.deinit()
    _ = state.cache.updateStatus(state.cache.activeKey(0), .failed);
}

test "sysUpdateCache max decode threads telemetry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dup = try state.viewer.navigation.directory_arena.allocator().dupe(u8, "img0.png");
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = dup } });
    state.viewer.navigation.current_index = 0;

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);
    try std.testing.expectEqual(
        state.workers.getMaxConcurrentDecodes(),
        state.viewer.stats.max_decode_threads,
    );
    try std.testing.expect(state.viewer.stats.max_decode_threads >= 1);
}

test "sysUpdateCache - directional speculative preloading during fast scrolling" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Populate mock image list with 5 images
    const paths = [_][]const u8{ "img0.png", "img1.png", "img2.png", "img3.png", "img4.png" };
    for (paths) |p| {
        const dup = try state.viewer.navigation.directory_arena.allocator().dupe(u8, p);
        try state.viewer.navigation.image_list.append(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;
    state.viewer.navigation.direction = .forward;
    // Set last_nav_time_ms to now so is_fast_scrolling is true
    state.viewer.navigation.last_nav_time_ms = sdl.timer.getTicks();

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };

    // Case 1: Active slot 0 is decoding without thumbnail yet.
    // In this state, is_active_thumb_ready is false, so NO neighbor should be preloaded.
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(0)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(1)) == null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(4)) == null);

    // Case 2: Active slot 0 receives thumbnail.
    // In headless mode (no GPU device), .not_available simulates thumbnail phase completion.
    var cur = state.cache.get(state.cache.activeKey(0)).?;
    cur.thumbnail = .not_available;

    // Run sysUpdateCache: because direction is .forward, speculative_idx is 1.
    // Slot 1 should be populated for speculative preloading,
    // but slot 4 (backward neighbor) should NOT!
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(1)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(4)) == null);

    // Case 3: Reverse direction to .backward.
    state.viewer.navigation.direction = .backward;
    state.viewer.navigation.last_nav_time_ms = sdl.timer.getTicks();

    // Run sysUpdateCache: speculative_idx is now 4 (wrap around from 0).
    // Slot 4 should be populated for speculative preloading!
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(4)) != null);
}

test "sysUpdateCache - synchronous presence probe sets thumbnail state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Add a real PNG (no embedded thumbnail) to navigation list
    const dup = try state.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = dup } });
    state.viewer.navigation.current_index = 0;

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    const entry = state.cache.get(state.cache.activeKey(0));
    try std.testing.expect(entry != null);
    // Because test_0_init.png has no embedded thumbnail, synchronous probe
    // on Frame 1 sets .not_available!
    try std.testing.expectEqual(state_pkg.ThumbnailState.not_available, entry.?.thumbnail);
}

test "sysUpdateCache - active image without thumbnail spawns full decode during fast scrolling" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Add image with no thumbnail
    const dup = try state.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = dup } });
    state.viewer.navigation.current_index = 0;
    // Fast scrolling is active
    state.viewer.navigation.last_nav_time_ms = sdl.timer.getTicks();

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    const entry = state.cache.get(state.cache.activeKey(0));
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(state_pkg.ThumbnailState.not_available, entry.?.thumbnail);
    // Active slot 0 should have has_thread = true (decode worker was spawned, not skipped!)
    switch (entry.?.status) {
        .decoding => |dec| try std.testing.expect(dec.has_thread),
        else => unreachable,
    }
}
