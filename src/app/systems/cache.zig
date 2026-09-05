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

    state.cache.enforceVramBudget(dev_opt, idx, len, image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES);

    // Fast-scrolling check: only active if navigation has actually occurred
    const now = sdl.timer.getTicks();
    const is_fast_scrolling = state.viewer.navigation.last_nav_time_ms > 0 and (now - state.viewer.navigation.last_nav_time_ms < 150);

    // Resource protection: check whether the current image is fully ready or failed.
    // When false, background decode workers are restricted strictly to the active image `idx`.
    // In headless/mock mode (no GPU device), .loaded_cpu is terminal ready; with GPU, .loaded_gpu is required.
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

    // 3. Mark missing slots as decoding in cache map
    var to_spawn_indices: [5]usize = undefined;
    var to_spawn_entries: [5]?MediaEntry = [1]?MediaEntry{null} ** 5;
    var to_spawn_count: usize = 0;
    var hit = false;

    for (desired[0..desired_count]) |d| {
        if (d >= state.viewer.navigation.image_list.items.len) continue;

        if (is_fast_scrolling and d != idx) continue;

        // Demand-first gating: Do not spawn background decodes for neighbor slots
        // until the active image is loaded on GPU (or failed).
        if (!is_current_ready and d != idx) continue;

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
                            to_spawn_entries[to_spawn_count] = state.viewer.navigation.image_list.items[d];
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
        const entry_opt = to_spawn_entries[s_idx];
        if (entry_opt == null or !state.workers.canSpawnDecode()) continue;

        spawnCacheDecodeSlot(state, d, entry_opt.?, is_fast_scrolling) catch |err| {
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
        try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = dup } });
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
    try state.cache.appendWithKey(allocator, state.cache.activeKey(6), .{
        .status = .{
            .loaded_gpu = .{
                .gpu_texture = undefined,
                .w = 100,
                .h = 100,
                .size_bytes = 1000,
                .memory_size_bytes = 500 * 1024 * 1024,
            },
        },
    });

    // Also add slot 7 as failed (outside window)
    try state.cache.appendWithKey(allocator, state.cache.activeKey(7), .{
        .status = .failed,
    });

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Slot 7 (.failed outside window) should be evicted
    try std.testing.expect(state.cache.get(state.cache.activeKey(7)) == null);

    // Slot 6 (.loaded_gpu outside window) should be RETAINED under default budget!
    try std.testing.expect(state.cache.get(state.cache.activeKey(6)) != null);

    // Now enforce a small VRAM budget (less than slot 6's 500MB)
    state.cache.enforceVramBudget(state.gpu_device, 0, 10, 100);

    // Slot 6 should now be pruned by enforceVramBudget
    try std.testing.expect(state.cache.get(state.cache.activeKey(6)) == null);

    // Reset slot 0 to .failed to prevent calling destroy() on mock undefined surface during defer state.deinit()
    _ = state.cache.updateStatus(state.cache.activeKey(0), .failed);
}
