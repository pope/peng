const app_state = @import("../state.zig");
const cache = @import("cache");
const context = @import("context.zig");
const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const vfs = @import("vfs");
const workers_mod = @import("../workers/root.zig");

const AppState = app_state.AppState;
const DecodeMode = workers_mod.DecodeMode;
const DecodePriority = workers_mod.DecodePriority;
const FrameContext = context.FrameContext;
const ImageCache = cache.ImageCache;
const MediaEntry = vfs.MediaEntry;
const MediaId = vfs.MediaId;
const PairStreamTarget = vfs.PairStreamTarget;
const RawMetadata = probe.RawMetadata;

fn checkPairPromotion(
    state: *AppState,
    key: cache.ImageCacheKey,
    now: u64,
) void {
    const media_item = state.viewer.navigation.getMediaEntryById(key.id) orelse
        return;
    if (!media_item.isPair()) return;
    const entry_val = state.cache.getEntry(key) orelse return;
    if (!entry_val.inflight.isIdle()) return;
    switch (entry_val.resident.asset) {
        .loaded_gpu, .loaded_cpu => {},
        .none, .promoting_gpu, .failed => return,
    }

    if (!entry_val.metadata.raw_metadata.isRaw()) return;

    const loaded_w = entry_val.getLoadedWidth() orelse 0.0;
    const loaded_h = entry_val.getLoadedHeight() orelse 0.0;
    const auth = entry_val.getAuthoritativeDims();
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
        state.viewer.navigation.cadence.isSettledForPromotion(now) and
        (tex_demand > 1.15);

    if ((is_inspecting or is_settled_fit) and
        state.workers.canSpawnDecode(.promotion))
    {
        state.spawnSlotDecode(
            key.id,
            media_item,
            .full,
            .standalone_jpeg,
            now,
        ) catch |err| {
            std.log.err("Failed to spawn zoom promotion decode: {}", .{err});
        };
    }
}

/// System Pass: Update image RAM/GPU texture cache and background preloading window.
pub fn sysUpdateCache(ctx: FrameContext) !void {
    const state = ctx.state;
    defer state.flushPendingWaitLoadStreams();
    state.updateCurrentRotation();

    const len = state.viewer.navigation.count();
    if (len == 0) {
        state.cache.current_image_cache_hit = false;
        return;
    }

    const neighbors = state.viewer.navigation.getVisibleNeighbors() orelse {
        state.cache.current_image_cache_hit = false;
        return;
    };
    const cur_id = state.viewer.navigation.getCurrentMediaId() orelse {
        state.cache.current_image_cache_hit = false;
        return;
    };
    const dev_opt = state.gpu_device;

    state.cache.enforceVramBudget(
        dev_opt,
        &state.viewer.navigation,
        neighbors,
        state.viewer.getTransitionPrevIndex(),
        len,
        ImageCache.DEFAULT_MAX_VRAM_BYTES,
    );

    const max_dist = state.cache.getMaxPrefetchDist(neighbors);

    // 1. Gather desired visible indices (prefetch window: idx, prioritized
    // along travel direction within the active VRAM prefetch radius)
    var desired_buf: [5]usize = undefined;
    const desired = neighbors.collectUnique(
        state.viewer.navigation.getEffectiveDirection(),
        max_dist,
        &desired_buf,
    );

    // 2. Evict cache entries that are no longer wanted, decoupling prefetch
    // from retention
    var i: usize = 0;
    while (i < state.cache.count()) {
        const keys = state.cache.slots.items(.key);
        const entries = state.cache.slots.items(.entry);
        const key = keys[i];
        const entry = entries[i];

        var in_desired = false;
        if (state.viewer.navigation.posOfId(key.id)) |pos| {
            for (desired) |d| {
                if (pos == d) {
                    in_desired = true;
                    break;
                }
            }
        }

        const keep_entry = in_desired or switch (entry.resident.asset) {
            .loaded_gpu, .promoting_gpu => true,
            .loaded_cpu => dev_opt == null,
            .none, .failed => false,
        };
        if (keep_entry) {
            i += 1;
        } else {
            state.cache.removeAndDeinit(i, dev_opt);
        }
    }

    // Fast-scrolling check: only active while navigation is active within the
    // fast-scroll window and no IPC `wait_load` barrier is awaiting full res.
    const is_fast_scrolling =
        state.pending_wait_load_streams.items.len == 0 and
        state.viewer.navigation.cadence.isFastScrolling(ctx.now_ms);

    // Resource protection: check whether the current image is fully ready or
    // failed. When false, background decode workers are restricted strictly
    // to the active image `cur_id`. In headless/mock mode (no GPU device),
    // .loaded_cpu is terminal ready; with GPU, .loaded_gpu or .promoting_gpu
    // is required.
    const is_current_ready = blk: {
        const cur_key = state.cache.activeKey(cur_id);
        if (state.cache.getEntry(cur_key)) |cur_entry| {
            break :blk switch (cur_entry.resident.asset) {
                .loaded_gpu, .promoting_gpu, .failed => true,
                .loaded_cpu => state.gpu_device == null,
                .none => false,
            };
        }
        break :blk false;
    };

    // Fast-scrolling thumbnail readiness: check whether active image has
    // thumbnail (loaded or staged on CPU) or full texture ready. Speculative
    // thumbnail preloading for next image only runs if active image thumbnail
    // is already ready.
    const is_active_thumb_ready = blk: {
        const cur_key = state.cache.activeKey(cur_id);
        if (state.cache.getEntry(cur_key)) |cur_entry| {
            break :blk switch (cur_entry.resident.thumbnail) {
                .loaded, .staged_cpu, .not_available => true,
                .none, .pending, .unloaded => is_current_ready,
            };
        }
        break :blk false;
    };

    const speculative_idx = if (state.viewer.navigation.direction == .backward)
        neighbors.prev_1
    else
        neighbors.next_1;

    // 3. Mark missing slots as decoding in cache map
    state.cache.current_image_cache_hit = false;
    const SpawnRequest = struct {
        id: MediaId,
        entry: MediaEntry,
    };
    var to_spawn: std.ArrayList(SpawnRequest) = try .initCapacity(
        ctx.frame_allocator,
        desired.len,
    );
    defer to_spawn.deinit(ctx.frame_allocator);
    var hit = false;

    for (desired) |d| {
        const d_id = state.viewer.navigation.getIdAt(d) orelse continue;

        if (d != neighbors.current) {
            if (is_fast_scrolling) {
                if (d != speculative_idx or !is_active_thumb_ready) continue;
            } else {
                if (!is_current_ready) continue;
            }
        }

        const key = state.cache.activeKey(d_id);
        if (state.cache.get(key)) |entry| {
            if (d == neighbors.current and entry.resident.asset.isLoaded()) {
                hit = true;
            }
        } else {
            _ = try state.cache.appendSlot(
                state.allocator,
                d_id,
                .{
                    .inflight = .{
                        .queued_decode = .{ .start_time_ms = ctx.now_ms },
                    },
                },
            );
        }

        if (state.cache.getEntry(key)) |entry| {
            const is_active_slot = (d_id == cur_id);
            const is_queued = switch (entry.inflight) {
                .queued_decode => true,
                .idle, .decoding, .uploading => false,
            };
            if (is_queued) {
                const thumb_ready = switch (entry.resident.thumbnail) {
                    .not_available, .staged_cpu, .loaded => true,
                    .none, .pending, .unloaded => false,
                };
                const has_active_thumb = switch (entry.resident.thumbnail) {
                    .loaded, .staged_cpu => true,
                    .none, .pending, .not_available, .unloaded => false,
                };
                const skip_neighbor = d != neighbors.current and
                    is_fast_scrolling and
                    thumb_ready;
                const skip_active = d == neighbors.current and
                    is_fast_scrolling and
                    has_active_thumb;
                if (!skip_neighbor and !skip_active) {
                    if (state.viewer.navigation.getMediaEntryById(d_id)) |e| {
                        to_spawn.appendAssumeCapacity(.{
                            .id = d_id,
                            .entry = e,
                        });
                    }
                }
            }

            if (is_active_slot) {
                checkPairPromotion(state, key, ctx.now_ms);
            }
        }
    }
    state.cache.current_image_cache_hit = hit;

    // 4. Spawn worker threads
    for (to_spawn.items) |req| {
        const priority: DecodePriority = if (req.id == cur_id)
            .foreground
        else
            .background;
        if (!state.workers.canSpawnDecode(priority)) continue;

        const key = state.cache.activeKey(req.id);
        const entry = state.cache.get(key) orelse continue;
        const queued = switch (entry.inflight) {
            .queued_decode => |q| q,
            .idle, .decoding, .uploading => continue,
        };

        const decode_mode: DecodeMode = if (is_fast_scrolling) blk: {
            if (req.id == cur_id) {
                const thumb_not_available = switch (entry.resident.thumbnail) {
                    .not_available => true,
                    .none, .pending, .staged_cpu, .unloaded, .loaded => false,
                };
                break :blk if (thumb_not_available)
                    .full
                else
                    .active_fast_scroll;
            }
            break :blk .speculative_thumb;
        } else .full;

        state.spawnSlotDecode(
            req.id,
            req.entry,
            decode_mode,
            queued.target,
            ctx.now_ms,
        ) catch |err| {
            std.log.err(
                "Failed to spawn decode worker for media {}: {}",
                .{ req.id, err },
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
        _ = try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;
    const out_id = MediaId.fromU32(99);

    // Add an out-of-window entry at index 99
    _ = try state.cache.appendSlot(
        allocator,
        out_id,
        .{ .resident = .{ .asset = .failed } },
    );
    try std.testing.expectEqual(@as(usize, 1), state.cache.count());

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Index 99 should have been evicted, and current index 0 should be present
    try std.testing.expect(
        state.cache.get(state.cache.activeKey(out_id)) == null,
    );
    try std.testing.expect(state.cache.get(state.cache.activeKey(id0)) != null);
    // While index 0 is decoding, neighbor index 1 should NOT be populated yet
    try std.testing.expect(state.cache.get(state.cache.activeKey(id1)) == null);

    // Simulate index 0 finishing decode
    const surf = sdl.Surface.create(10, 10, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    state.cache.setResidentAsset(state.cache.activeKey(id0), .{
        .loaded_cpu = .{
            .cpu = .{
                .surface = surf,
                .w = 100,
                .h = 100,
                .size_bytes = 1000,
            },
        },
    }, null);
    state.cache.setInFlight(state.cache.activeKey(id0), .idle);

    // Run sysUpdateCache again: now that index 0 is ready, neighbors should populate
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id1)) != null);
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
        _ = try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id6 = state.viewer.navigation.getIdAt(6).?;
    const id7 = state.viewer.navigation.getIdAt(7).?;

    const surf = sdl.Surface.create(10, 10, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    // Add slot 0 (current) as loaded_cpu so neighbors can populate
    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 100,
                        .h = 100,
                        .size_bytes = 1000,
                    },
                },
            },
        },
    });

    // Add slot 6 (outside desired 0, 1, 2, 9, 8 window) as loaded_gpu
    _ = try state.cache.appendSlot(allocator, id6, .{
        .resident = .{
            .asset = .{
                .loaded_gpu = .{
                    .gpu_texture = undefined,
                    .w = 100,
                    .h = 100,
                    .size_bytes = 1000,
                    .ingest = .{ .memory_size_bytes = 500 * 1024 * 1024 },
                },
            },
        },
    });

    // Also add slot 7 as failed (outside window)
    _ = try state.cache.appendSlot(
        allocator,
        id7,
        .{ .resident = .{ .asset = .failed } },
    );

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Slot 7 (.failed outside window) should be evicted
    try std.testing.expect(state.cache.get(state.cache.activeKey(id7)) == null);

    // Slot 6 (.loaded_gpu outside window) should be RETAINED under default budget!
    try std.testing.expect(state.cache.get(state.cache.activeKey(id6)) != null);

    // Now enforce a small VRAM budget (less than slot 6's 500MB)
    state.cache.enforceVramBudget(
        state.gpu_device,
        &state.viewer.navigation,
        state.viewer.navigation.getVisibleNeighbors(),
        null,
        10,
        100,
    );

    // Slot 6 should now be pruned by enforceVramBudget
    try std.testing.expect(state.cache.get(state.cache.activeKey(id6)) == null);
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
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = dup } },
    );
    state.viewer.navigation.current_index = 0;

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);
    const stats = state.snapshotStats();
    try std.testing.expectEqual(
        state.workers.getMaxConcurrentDecodes(),
        stats.max_decode_threads,
    );
    try std.testing.expect(stats.max_decode_threads >= 1);
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
        _ = try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;
    const id4 = state.viewer.navigation.getIdAt(4).?;
    state.viewer.navigation.direction = .forward;
    // Record recent navigation timestamp for fast-scrolling throttling
    state.viewer.navigation.cadence.recordNavigation(1000);

    // Pre-populate active slot 0 as decoding without thumbnail yet
    const ticket0 = state.cache.allocJob().?;
    _ = try state.cache.appendSlot(allocator, id0, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket0 },
        },
    });

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1000,
    };

    // Case 1: Active slot 0 is decoding without thumbnail yet.
    // In this state, is_active_thumb_ready is false, so NO neighbor should be preloaded.
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id0)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id1)) == null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id4)) == null);

    // Case 2: Active slot 0 receives thumbnail.
    // In headless mode (no GPU device), .not_available simulates thumbnail phase completion.
    const cur = state.cache.get(state.cache.activeKey(id0)).?;
    cur.resident.thumbnail = .not_available;

    // Run sysUpdateCache: because direction is .forward, speculative_idx is 1.
    // Slot 1 should be populated for speculative preloading,
    // but slot 4 (backward neighbor) should NOT!
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id1)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id4)) == null);

    // Case 3: Reverse direction to .backward.
    state.viewer.navigation.direction = .backward;
    state.viewer.navigation.cadence.recordNavigation(1000);

    // Run sysUpdateCache: speculative_idx is now 4 (wrap around from 0).
    // Slot 4 should be populated for speculative preloading!
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id4)) != null);
}

test "sysUpdateCache - defers header probing off render thread" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dup = try state.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = dup } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    const entry = state.cache.get(state.cache.activeKey(id0));
    try std.testing.expect(entry != null);
    // Main thread must not synchronously probe headers; thumbnail remains .none
    // until background decode worker completes and events are drained.
    try std.testing.expectEqual(
        cache.ThumbnailState.none,
        entry.?.resident.thumbnail,
    );
    switch (entry.?.inflight) {
        .decoding => {},
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }
}

test "sysUpdateCache - active image without thumb decodes in fast scroll" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Add image with no embedded thumbnail
    const dup = try state.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = dup } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    // Fast scrolling is active
    state.viewer.navigation.cadence.recordNavigation(1000);

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1000,
    };
    try sysUpdateCache(ctx);

    const entry = state.cache.get(state.cache.activeKey(id0));
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(
        cache.ThumbnailState.none,
        entry.?.resident.thumbnail,
    );
    switch (entry.?.inflight) {
        .decoding => {},
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }

    // Await the .active_fast_scroll worker and verify single-pass fallthrough
    state.workers.group.await(io) catch {};
    var image_seen = false;
    while (state.workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        if (ev.* == .image_decoded) image_seen = true;
    }
    try std.testing.expect(image_seen);
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
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const surf = sdl.Surface.create(1616, 1080, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    // Slot 0 is loaded with a downscaled preview (1616x1080) on a 6000x4000 sensor
    const key = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 1616.0,
                        .h = 1080.0,
                        .size_bytes = 500_000,
                    },
                },
            },
        },
    });
    if (state.cache.get(key)) |entry| {
        entry.metadata.full_dims = .{ .w = 1616.0, .h = 1080.0 };
        entry.metadata.raw_metadata =
            RawMetadata.init(6000.0, 4000.0);
    }

    // When zoom is 1.0x, inflight remains .idle
    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(key).?.inflight.isIdle());
    try std.testing.expect(
        state.cache.get(key).?.resident.asset == .loaded_cpu,
    );

    // When zoom > 1.0x, zoom promotion sets .decoding while preserving
    // resident asset
    state.viewer.viewport.mode = .manual;
    state.viewer.viewport.zoom_factor = state_pkg.clampZoomFactor(2.0);
    try sysUpdateCache(ctx);
    switch (state.cache.get(key).?.inflight) {
        .decoding => {},
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }
    try std.testing.expect(
        state.cache.get(key).?.resident.asset == .loaded_cpu,
    );
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
        _ = try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 1;

    // Populate all 5 slots with 300 MiB .loaded_gpu textures
    // (total 1500 MiB > 1 GiB)
    for (0..5) |idx| {
        const id = state.viewer.navigation.getIdAt(idx).?;
        _ = try state.cache.appendSlot(allocator, id, .{
            .resident = .{
                .asset = .{
                    .loaded_gpu = .{
                        .gpu_texture = undefined,
                        .w = 8000,
                        .h = 6000,
                        .size_bytes = 10_000_000,
                        .ingest = .{ .memory_size_bytes = 300 * 1024 * 1024 },
                    },
                },
            },
        });
    }

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Distance 2 slots (indices 3 and 4 relative to 1) should be evicted,
    // and NOT re-inserted as .decoding slots.
    const n1 = state.viewer.navigation.getVisibleNeighbors().?;
    try std.testing.expectEqual(
        @as(usize, 1),
        state.cache.getMaxPrefetchDist(n1),
    );
    for (0..3) |idx| {
        const id = state.viewer.navigation.getIdAt(idx).?;
        try std.testing.expect(
            state.cache.get(state.cache.activeKey(id)) != null,
        );
    }
    for (3..5) |idx| {
        const id = state.viewer.navigation.getIdAt(idx).?;
        try std.testing.expect(
            state.cache.get(state.cache.activeKey(id)) == null,
        );
    }
    try std.testing.expect(
        !state.cache.hasUnreadyPrefetchSlots(
            &state.viewer.navigation,
            n1,
            true,
        ),
    );

    // Navigating to a new slide resets the prefetch distance cap for the new
    // index
    state.viewer.navigation.current_index = 2;
    const n2 = state.viewer.navigation.getVisibleNeighbors().?;
    try std.testing.expectEqual(
        @as(usize, 2),
        state.cache.getMaxPrefetchDist(n2),
    );
}

test "sysUpdateCache - respects ViewMode visibility filtering" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // 6 images: only indices 0 and 4 are marked .pick; others are .unflagged
    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const paths = [_][]const u8{
        "testfiles/golden-screenshots/init.png",
        "testfiles/golden-screenshots/init.png",
        "testfiles/golden-screenshots/init.png",
        "testfiles/golden-screenshots/init.png",
        "testfiles/golden-screenshots/init.png",
        "testfiles/golden-screenshots/init.png",
    };
    for (paths) |p| {
        const dup = try dir_alloc.dupe(u8, p);
        _ = try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }

    state.viewer.navigation.current_index = 0;
    _ = try state.viewer.navigation.markCurrentPick(allocator);
    state.viewer.navigation.current_index = 4;
    _ = try state.viewer.navigation.markCurrentPick(allocator);
    state.viewer.navigation.current_index = 0;
    _ = state.viewer.navigation.setViewMode(.picks);

    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;
    const id2 = state.viewer.navigation.getIdAt(2).?;
    const id4 = state.viewer.navigation.getIdAt(4).?;

    // Pre-populate active slot 0 as loaded_gpu so neighbor prefetching runs,
    // plus hidden raw neighbor 1 and visible pick neighbor 4 (200 bytes each).
    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_gpu = .{
                    .gpu_texture = undefined,
                    .w = 100,
                    .h = 100,
                    .size_bytes = 100,
                    .ingest = .{ .memory_size_bytes = 200 },
                },
            },
        },
    });
    _ = try state.cache.appendSlot(allocator, id1, .{
        .resident = .{
            .asset = .{
                .loaded_gpu = .{
                    .gpu_texture = undefined,
                    .w = 100,
                    .h = 100,
                    .size_bytes = 100,
                    .ingest = .{ .memory_size_bytes = 200 },
                },
            },
        },
    });
    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);

    // Visible neighbor 4 must be populated, while hidden raw neighbor 2 is NOT!
    try std.testing.expect(state.cache.get(state.cache.activeKey(id4)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id2)) == null);

    // Mark visible neighbor 4 as loaded_gpu and enforce a 400-byte VRAM budget:
    // hidden raw neighbor 1 must be evicted BEFORE visible neighbor 4 (even
    // though index 4 has raw cyclic distance 2 > index 1's raw distance 1)!
    state.cache.setResidentAsset(state.cache.activeKey(id4), .{
        .loaded_gpu = .{
            .gpu_texture = undefined,
            .w = 100,
            .h = 100,
            .size_bytes = 100,
            .ingest = .{ .memory_size_bytes = 200 },
        },
    }, null);
    state.cache.setInFlight(state.cache.activeKey(id4), .idle);
    const vis = state.viewer.navigation.getVisibleNeighbors();
    state.cache.enforceVramBudget(
        null,
        &state.viewer.navigation,
        vis,
        null,
        6,
        400,
    );
    try std.testing.expect(state.cache.get(state.cache.activeKey(id1)) == null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id4)) != null);
    try std.testing.expect(
        !state.cache.hasUnreadyPrefetchSlots(
            &state.viewer.navigation,
            vis.?,
            true,
        ),
    );
}

test "checkPairPromotion - does not spawn while slot is decoding or promoting" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const img_path = "testfiles/golden-screenshots/init.png";
    const raw_p = try dir_alloc.dupe(u8, img_path);
    const jpg_p = try dir_alloc.dupe(u8, img_path);
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const ticket0 = state.cache.allocJob().?;
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .inflight = .{
            .decoding = .{
                .target = .standalone_jpeg,
                .ticket = ticket0,
            },
        },
    });
    const entry0 = state.cache.get(key0).?;

    // 1. While !isIdle(), checkPairPromotion must not spawn a duplicate
    // promotion worker.
    checkPairPromotion(&state, key0, 1000);
    switch (entry0.inflight) {
        .decoding => |dec| try std.testing.expectEqual(
            PairStreamTarget.standalone_jpeg,
            dec.target,
        ),
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        state.workers.active_decode_threads.load(.acquire),
    );

    // 2. While already promoting, checkPairPromotion must also not spawn again.
    entry0.resident.asset = .{
        .loaded_gpu = .{
            .gpu_texture = undefined,
            .w = 100,
            .h = 100,
            .size_bytes = 100,
            .ingest = .{ .memory_size_bytes = 200 },
        },
    };
    checkPairPromotion(&state, key0, 1000);
    switch (entry0.inflight) {
        .decoding => |dec| try std.testing.expectEqual(
            PairStreamTarget.standalone_jpeg,
            dec.target,
        ),
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        state.workers.active_decode_threads.load(.acquire),
    );
}

test "checkPairPromotion - preserves resident GPU during promotion" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const img_path = "testfiles/golden-screenshots/init.png";
    const raw_p = try dir_alloc.dupe(u8, img_path);
    const jpg_p = try dir_alloc.dupe(u8, img_path);
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const key0 = try state.cache.appendSlot(
        allocator,
        id0,
        cache.CacheEntry.stubLoadedGpuForTest(
            .{ .w = 1616.0, .h = 1080.0 },
            .{ .w = 0.0, .h = 0.0 },
        ),
    );
    if (state.cache.get(key0)) |entry| {
        entry.metadata.full_dims = .{ .w = 1616.0, .h = 1080.0 };
        entry.metadata.raw_metadata =
            RawMetadata.init(6000.0, 4000.0);
    }

    state.viewer.viewport.mode = .manual;
    state.viewer.viewport.zoom_factor = state_pkg.clampZoomFactor(2.0);

    checkPairPromotion(&state, key0, 1000);

    const entry = state.cache.get(key0).?;
    switch (entry.resident.asset) {
        .loaded_gpu => |g| try std.testing.expectEqual(@as(f32, 1616.0), g.w),
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }
    switch (entry.inflight) {
        .decoding => |dec| try std.testing.expectEqual(
            PairStreamTarget.standalone_jpeg,
            dec.target,
        ),
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }
}

test "sysUpdateCache fast-scroll throttling deterministic with ctx.now_ms" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    for (0..3) |_| {
        const dup = try dir_alloc.dupe(
            u8,
            "testfiles/golden-screenshots/init.png",
        );
        _ = try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;
    const id2 = state.viewer.navigation.getIdAt(2).?;
    state.viewer.navigation.direction = .forward;

    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .failed,
            .thumbnail = .not_available,
        },
    });

    // 1. diff 20ms < 35ms threshold: fast-scrolling active, only speculative
    state.viewer.navigation.cadence.recordNavigation(980);
    const ctx_fast = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1000,
    };
    try sysUpdateCache(ctx_fast);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id1)) != null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id2)) == null);

    // 2. diff 120ms >= 35ms: fast-scrolling inactive, settles neighbor slot 2
    const ctx_settled = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1100,
    };
    try sysUpdateCache(ctx_settled);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id2)) != null);
}

test "AppState.spawnSlotDecode stamps now_ms and job ticket on inflight" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const dup = try dir_alloc.dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = dup } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const key0 = try state.cache.appendSlot(allocator, id0, .{});

    try state.spawnSlotDecode(
        id0,
        .{ .filesystem = .{ .path = dup } },
        .full,
        .adaptive,
        4200,
    );

    const entry = state.cache.get(key0).?;
    switch (entry.inflight) {
        .decoding => |dec| {
            try std.testing.expectEqual(@as(u64, 4200), dec.start_time_ms);
            try std.testing.expect(dec.ticket.epoch >= 1);
        },
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }
}

test "checkPairPromotion - Fit mode waits until cadence settles past 250ms" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const img_path = "testfiles/golden-screenshots/init.png";
    const raw_p = try dir_alloc.dupe(u8, img_path);
    const jpg_p = try dir_alloc.dupe(u8, img_path);
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const key0 = try state.cache.appendSlot(
        allocator,
        id0,
        cache.CacheEntry.stubLoadedGpuForTest(
            .{ .w = 400.0, .h = 267.0 },
            .{ .w = 0.0, .h = 0.0 },
        ),
    );
    if (state.cache.get(key0)) |entry| {
        entry.metadata.full_dims = .{ .w = 400.0, .h = 267.0 };
        entry.metadata.raw_metadata =
            RawMetadata.init(6000.0, 4000.0);
    }
    state.viewer.viewport.mode = .fit;

    // At elapsed == 250ms, Fit-mode promotion is still throttled
    state.viewer.navigation.cadence.recordNavigation(1000);
    checkPairPromotion(&state, key0, 1250);
    try std.testing.expect(state.cache.get(key0).?.inflight.isIdle());

    // At elapsed == 251ms (> 250ms), Fit-mode promotion spawns
    checkPairPromotion(&state, key0, 1251);
    const promoted = state.cache.get(key0).?;
    switch (promoted.inflight) {
        .decoding => |dec| try std.testing.expectEqual(
            PairStreamTarget.standalone_jpeg,
            dec.target,
        ),
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }
}

test "sysUpdateCache - foreground burst spawns active when pool saturated" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // 4 cores -> background=2, concurrent/promotion=3, foreground=5
    state.workers.cached_cpu_count = 4;

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    for (0..3) |_| {
        const dup = try dir_alloc.dupe(
            u8,
            "testfiles/golden-screenshots/init.png",
        );
        _ = try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;
    state.viewer.navigation.direction = .forward;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;

    // Active slot has .not_available thumb and is awaiting decode while fast
    // scrolling, so both active id0 and speculative neighbor id1 enter
    // to_spawn in the same sysUpdateCache pass.
    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{ .thumbnail = .not_available },
        .inflight = .{ .queued_decode = .{} },
    });
    state.viewer.navigation.cadence.recordNavigation(1000);

    // Saturate the base pool at getMaxConcurrentDecodes() (3)
    state.workers.active_decode_threads.store(
        state.workers.getMaxConcurrentDecodes(),
        .release,
    );

    try sysUpdateCache(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1000,
    });

    // Active slide id0 must spawn via .foreground burst headroom (3 < 5)
    const entry0 = state.cache.get(state.cache.activeKey(id0)).?;
    switch (entry0.inflight) {
        .decoding => {},
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }

    // Speculative neighbor id1 must be skipped via .background limit (3 >= 2)
    const entry1 = state.cache.get(state.cache.activeKey(id1)).?;
    switch (entry1.inflight) {
        .queued_decode => {},
        .idle, .decoding, .uploading => {
            return error.TestExpectedQueuedDecode;
        },
    }
}

test "sysUpdateCache - brisk scroll keeps staged thumb until settled" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    for (0..4) |_| {
        const dup = try dir_alloc.dupe(
            u8,
            "testfiles/golden-screenshots/init.png",
        );
        _ = try state.viewer.navigation.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = dup } },
        );
    }
    state.viewer.navigation.current_index = 0;

    // Two brisk steps 120ms apart: t=1000 -> t=1120 (lands on index 2)
    _ = state.viewer.navigation.nextIndex(1000);
    _ = state.viewer.navigation.nextIndex(1120);
    try std.testing.expectEqual(
        @as(?usize, 2),
        state.viewer.navigation.current_index,
    );

    const id2 = state.viewer.navigation.getIdAt(2).?;
    const id3 = state.viewer.navigation.getIdAt(3).?;

    // Active slide 2 has a CPU-staged thumbnail awaiting GPU upload
    const th_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    _ = try state.cache.appendSlot(allocator, id2, .{
        .resident = .{
            .thumbnail = .{ .staged_cpu = .{ .surface = th_surf } },
        },
        .inflight = .{ .queued_decode = .{} },
    });

    // At t=1200 (> 35ms after 1120, < 200ms), brisk scroll remains active:
    // active slide stays thumbnail-only without spawning a full or duplicate
    // decode worker, while speculative neighbor id3 is populated.
    try std.testing.expect(
        state.viewer.navigation.cadence.isFastScrolling(1200),
    );
    try sysUpdateCache(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1200,
    });

    const entry2_brisk = state.cache.get(state.cache.activeKey(id2)).?;
    switch (entry2_brisk.inflight) {
        .queued_decode => {},
        .idle, .decoding, .uploading => {
            return error.TestExpectedQueuedDecode;
        },
    }
    try std.testing.expect(state.cache.get(state.cache.activeKey(id3)) != null);

    // At t=1320 (200ms after 1120), cadence settles and active slide spawns
    // .full
    try std.testing.expect(
        !state.viewer.navigation.cadence.isFastScrolling(1320),
    );
    try sysUpdateCache(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1320,
    });

    const entry2_settled = state.cache.get(state.cache.activeKey(id2)).?;
    switch (entry2_settled.inflight) {
        .decoding => {},
        .idle, .queued_decode, .uploading => {
            return error.TestExpectedDecoding;
        },
    }

    state.workers.group.await(io) catch {};
    var full_seen = false;
    while (state.workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        if (ev.* == .image_decoded) full_seen = true;
    }
    try std.testing.expect(full_seen);
}

test "sysUpdateCache clears current_image_cache_hit on OOM" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dup = try state.viewer.navigation.directory_arena.allocator().dupe(
        u8,
        "testfiles/golden-screenshots/init.png",
    );
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = dup } },
    );
    state.viewer.navigation.current_index = 0;
    state.cache.current_image_cache_hit = true;

    var failing = std.testing.FailingAllocator.init(
        allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        sysUpdateCache(.{
            .state = &state,
            .frame_allocator = failing.allocator(),
        }),
    );
    try std.testing.expect(!state.cache.current_image_cache_hit);
}
