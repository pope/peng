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
/// - `pair_target`: Stream target for stacked RAW+JPEG pairs.
fn spawnCacheDecodeSlot(
    state: *AppState,
    index: usize,
    entry_item: MediaEntry,
    thumb_only: bool,
    pair_target: state_pkg.PairStreamTarget,
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
        .pair_target = pair_target,
        .current_generation = &state.cache.generation,
    };

    try decode_mod.spawnDecode(args);
}

fn probeActiveSlotMetadata(
    state: *AppState,
    idx: usize,
    entry: anytype,
) void {
    const media_item = state.viewer.navigation.getMediaEntry(idx) orelse return;
    const meta = image.probeMediaMetadata(state.io, media_item) orelse {
        if (entry.thumbnail == .none) {
            entry.thumbnail = .not_available;
        }
        return;
    };
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
    if (idx == state.viewer.navigation.current_index) {
        state.updateCurrentRotation();
    }
}

fn checkPairPromotion(
    state: *AppState,
    idx: usize,
    entry: anytype,
    now: u64,
) void {
    const media_item = state.viewer.navigation.getMediaEntry(idx) orelse return;
    if (!media_item.isPair()) return;

    if (entry.requested_target) |target| {
        if (!state.workers.canSpawnDecode()) return;
        entry.requested_target = null;
        entry.is_promoting = true;
        spawnCacheDecodeSlot(
            state,
            idx,
            media_item,
            false,
            target,
        ) catch |err| {
            entry.is_promoting = false;
            std.log.err("Failed to spawn requested pair decode: {}", .{err});
        };
        return;
    }

    if (entry.is_promoting or !entry.raw_metadata.isRaw()) return;

    const loaded_w = entry.getLoadedWidth() orelse 0.0;
    const loaded_h = entry.getLoadedHeight() orelse 0.0;
    const auth = entry.getAuthoritativeDims();
    if (loaded_w <= 0.0 or loaded_h <= 0.0) return;
    if (auth.w <= 0.0 or auth.h <= 0.0) return;

    const is_downscaled = (loaded_w < auth.w * 0.85) or
        (loaded_h < auth.h * 0.85);
    if (!is_downscaled) return;

    const z = if (state.viewer.viewport.mode == .manual)
        state.viewer.viewport.zoom_factor.get()
    else
        state.getBaseScale();
    const tex_demand = z * @max(auth.w / loaded_w, auth.h / loaded_h);
    const is_inspecting =
        (state.viewer.viewport.mode != .fit or state.isImageOverflowing()) and
        (tex_demand > 1.05);
    const is_settled_fit = (state.viewer.viewport.mode == .fit) and
        (now -| state.viewer.navigation.last_nav_time_ms > 250) and
        (tex_demand > 1.15);

    if ((is_inspecting or is_settled_fit) and state.workers.canSpawnDecode()) {
        entry.is_promoting = true;
        spawnCacheDecodeSlot(
            state,
            idx,
            media_item,
            false,
            .standalone_jpeg,
        ) catch |err| {
            entry.is_promoting = false;
            std.log.err("Failed to spawn zoom promotion decode: {}", .{err});
        };
    }
}

/// System Pass: Update image RAM/GPU texture cache and background preloading window.
pub fn sysUpdateCache(ctx: FrameContext) !void {
    const state = ctx.state;
    state.updateCurrentRotation();

    const len = state.viewer.navigation.count();
    if (len == 0) return;

    const idx = state.viewer.navigation.current_index orelse return;
    const dev_opt = state.gpu_device;

    state.cache.enforceVramBudget(
        dev_opt,
        idx,
        state.viewer.getTransitionPrevIndex(),
        len,
        image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES,
    );

    const max_dist = state.cache.getMaxPrefetchDist(idx);

    // 1. Gather desired indices (prefetch window: idx, prioritized along
    // travel direction within the active VRAM prefetch radius)
    const next_idx = (idx + 1) % len;
    const prev_idx = (idx + len - 1) % len;
    const next_2 = (idx + 2) % len;
    const prev_2 = if (len >= 2) (idx + len - 2) % len else idx;

    const candidates = if (state.viewer.navigation.direction == .backward)
        [_]usize{ prev_idx, next_idx, prev_2, next_2 }
    else
        [_]usize{ next_idx, prev_idx, next_2, prev_2 };

    var desired = try std.ArrayList(usize).initCapacity(
        ctx.frame_allocator,
        1 + candidates.len,
    );
    defer desired.deinit(ctx.frame_allocator);
    desired.appendAssumeCapacity(idx);

    for (candidates) |d| {
        if (image.calcCyclicDistance(d, idx, len) > max_dist) continue;
        var unique = true;
        for (desired.items) |existing| {
            if (existing == d) {
                unique = false;
                break;
            }
        }
        if (unique) {
            desired.appendAssumeCapacity(d);
        }
    }

    // 2. Evict cache entries that are no longer wanted, decoupling prefetch from retention
    var i: usize = 0;
    while (i < state.cache.count()) {
        const keys = state.cache.slots.items(.key);
        const entries = state.cache.slots.items(.entry);
        const key = keys[i];
        const entry = entries[i];

        var in_desired = false;
        for (desired.items) |d| {
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
    const SpawnRequest = struct {
        index: usize,
        entry: MediaEntry,
    };
    var to_spawn = try std.ArrayList(SpawnRequest).initCapacity(
        ctx.frame_allocator,
        desired.items.len,
    );
    defer to_spawn.deinit(ctx.frame_allocator);
    var hit = false;

    for (desired.items) |d| {
        if (d >= state.viewer.navigation.count()) continue;

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
            const needs_dimensions = (entry.full_w <= 0.0 or
                entry.full_h <= 0.0) and entry.thumbnail == .none;
            if (needs_dimensions) {
                probeActiveSlotMetadata(state, d, entry);
            }

            const is_decoding = entry.status == .decoding and
                !entry.status.decoding.has_thread;
            if (is_decoding) {
                const thumb_ready = entry.thumbnail == .not_available or
                    entry.thumbnail == .loaded;
                const skip_neighbor = d != idx and is_fast_scrolling and
                    thumb_ready;
                const skip_active = d == idx and is_fast_scrolling and
                    entry.thumbnail == .loaded;
                if (!skip_neighbor and !skip_active) {
                    if (state.viewer.navigation.getMediaEntry(d)) |e| {
                        to_spawn.appendAssumeCapacity(.{
                            .index = d,
                            .entry = e,
                        });
                    }
                }
            }

            if (is_active_slot) {
                checkPairPromotion(state, idx, entry, now);
            }
        }
    }
    state.viewer.stats.current_image_cache_hit = hit;

    // 4. Spawn worker threads
    for (to_spawn.items) |req| {
        if (!state.workers.canSpawnDecode()) continue;

        const key = state.cache.activeKey(req.index);
        const thumb_only = is_fast_scrolling and blk: {
            if (state.cache.get(key)) |entry| {
                if (entry.thumbnail == .not_available) break :blk false;
            }
            break :blk true;
        };

        spawnCacheDecodeSlot(
            state,
            req.index,
            req.entry,
            thumb_only,
            .adaptive,
        ) catch |err| {
            std.log.err(
                "Failed to spawn decode worker for index {}: {}",
                .{ req.index, err },
            );
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

    // Populate image list with 5 valid image paths
    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    for (0..5) |_| {
        const dup = try dir_alloc.dupe(
            u8,
            "testfiles/golden-screenshots/init.png",
        );
        try state.viewer.navigation.appendEntry(
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

    // Simulate index 0 finishing decode
    const surf = sdl.Surface.create(10, 10, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    _ = state.cache.updateStatus(state.cache.activeKey(0), .{
        .loaded_cpu = .{
            .surface = surf,
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
    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    for (0..10) |_| {
        const dup = try dir_alloc.dupe(
            u8,
            "testfiles/golden-screenshots/init.png",
        );
        try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;

    const surf = sdl.Surface.create(10, 10, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    // Add slot 0 (current) as loaded_cpu so neighbors can populate
    _ = try state.cache.appendSlot(allocator, 0, .{
        .loaded_cpu = .{
            .surface = surf,
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
}

test "sysUpdateCache max decode threads telemetry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dup = try state.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    try state.viewer.navigation.appendEntry(allocator, .{ .filesystem = .{ .path = dup } });
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

    // Populate image list with 5 valid image paths
    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    for (0..5) |_| {
        const dup = try dir_alloc.dupe(
            u8,
            "testfiles/golden-screenshots/init.png",
        );
        try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;
    state.viewer.navigation.direction = .forward;
    // Set last_nav_time_ms to non-zero recent timestamp for fast scrolling
    state.viewer.navigation.last_nav_time_ms = @max(1, sdl.timer.getTicks());

    // Pre-populate active slot 0 as decoding without thumbnail yet
    _ = try state.cache.appendSlot(allocator, 0, .{
        .decoding = .{ .has_thread = true },
    });

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };

    // Case 1: Active slot 0 is decoding without thumbnail yet.
    // In this state, is_active_thumb_ready is false, so NO neighbor should be preloaded.
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(0)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(1)) == null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(4)) == null);

    // Case 2: Active slot 0 receives thumbnail.
    // In headless mode (no GPU device), .not_available simulates thumbnail phase completion.
    const cur = state.cache.get(state.cache.activeKey(0)).?;
    cur.thumbnail = .not_available;

    // Run sysUpdateCache: because direction is .forward, speculative_idx is 1.
    // Slot 1 should be populated for speculative preloading,
    // but slot 4 (backward neighbor) should NOT!
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(1)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(4)) == null);

    // Case 3: Reverse direction to .backward.
    state.viewer.navigation.direction = .backward;
    state.viewer.navigation.last_nav_time_ms = @max(1, sdl.timer.getTicks());

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
    try state.viewer.navigation.appendEntry(allocator, .{ .filesystem = .{ .path = dup } });
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
    try state.viewer.navigation.appendEntry(allocator, .{ .filesystem = .{ .path = dup } });
    state.viewer.navigation.current_index = 0;
    // Fast scrolling is active
    state.viewer.navigation.last_nav_time_ms = @max(1, sdl.timer.getTicks());

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

test "sysUpdateCache - zoom promotion on downscaled RAW preview" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const raw_p = try state.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    const jpg_p = try state.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    try state.viewer.navigation.appendEntry(
        allocator,
        .{ .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p } },
    );
    state.viewer.navigation.current_index = 0;

    const surf = sdl.Surface.create(1616, 1080, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    // Slot 0 is loaded with a downscaled preview (1616x1080) on a 6000x4000 sensor
    const key = try state.cache.appendSlot(allocator, 0, .{
        .loaded_cpu = .{
            .surface = surf,
            .w = 1616.0,
            .h = 1080.0,
            .size_bytes = 500_000,
        },
    });
    if (state.cache.get(key)) |entry| {
        entry.full_w = 1616.0;
        entry.full_h = 1080.0;
        entry.raw_metadata = state_pkg.RawMetadata.init(6000.0, 4000.0);
    }

    // When zoom is 1.0x, is_promoting remains false
    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);
    try std.testing.expect(!state.cache.get(key).?.is_promoting);

    // When zoom > 1.0x, zoom promotion triggers is_promoting = true
    state.viewer.viewport.mode = .manual;
    state.viewer.viewport.zoom_factor = state_pkg.clampZoomFactor(2.0);
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(key).?.is_promoting);
}

test "sysUpdateCache - caps prefetch radius when window exceeds VRAM budget" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    for (0..5) |_| {
        const dup = try dir_alloc.dupe(
            u8,
            "testfiles/golden-screenshots/init.png",
        );
        try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 1;

    // Populate all 5 slots with 300 MiB .loaded_gpu textures
    // (total 1500 MiB > 1 GiB)
    for (0..5) |idx| {
        _ = try state.cache.appendSlot(allocator, idx, .{
            .loaded_gpu = .{
                .gpu_texture = undefined,
                .w = 8000,
                .h = 6000,
                .size_bytes = 10_000_000,
                .memory_size_bytes = 300 * 1024 * 1024,
            },
        });
    }

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Distance 2 slots (indices 3 and 4 relative to 1) should be evicted,
    // and NOT re-inserted as .decoding slots.
    try std.testing.expectEqual(
        @as(usize, 1),
        state.cache.getMaxPrefetchDist(1),
    );
    try std.testing.expect(state.cache.get(state.cache.activeKey(0)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(1)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(2)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(3)) == null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(4)) == null);
    try std.testing.expect(!state.cache.hasUnreadyPrefetchSlots(1, 5, true));

    // Navigating to a new slide resets the prefetch distance cap for the new
    // index
    state.viewer.navigation.current_index = 2;
    try std.testing.expectEqual(
        @as(usize, 2),
        state.cache.getMaxPrefetchDist(2),
    );
}
