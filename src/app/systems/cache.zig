const app_state = @import("../state.zig");
const context = @import("context.zig");
const core = @import("core");
const decode_mod = @import("../workers/decode.zig");
const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const vfs = @import("vfs");

const AppState = app_state.AppState;
const CacheEntry = state_pkg.CacheEntry;
const DecodeArgs = decode_mod.DecodeArgs;
const FrameContext = context.FrameContext;
const image = core.image;
const ImageCache = image.ImageCache;
const MediaEntry = vfs.MediaEntry;
const MediaId = vfs.MediaId;
const PairStreamTarget = vfs.PairStreamTarget;
const RawMetadata = probe.RawMetadata;

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
/// - `id`: Stable media ID being decoded.
/// - `entry_item`: Media entry being decoded.
/// - `thumb_only`: If true, restricts decoding to low-resolution thumbnail
///   for rapid scrolling.
/// - `pair_target`: Stream target for stacked RAW+JPEG pairs.
/// - `now_ms`: Timestamp in milliseconds used to stamp inflight decode.
fn spawnCacheDecodeSlot(
    state: *AppState,
    id: MediaId,
    entry_item: MediaEntry,
    thumb_only: bool,
    pair_target: PairStreamTarget,
    now_ms: u64,
) !void {
    const ticket = state.cache.allocJob() orelse return error.OutOfMemory;
    errdefer state.cache.cancelJob(ticket.job_id);

    const dup_entry = entry_item.dupe(state.allocator) catch |err| {
        std.log.err("Failed to dupe MediaEntry for decode worker: {}", .{err});
        return err;
    };
    errdefer dup_entry.deinit(state.allocator);

    const args = try state.allocator.create(DecodeArgs);
    errdefer state.allocator.destroy(args);

    const key = state.cache.activeKey(id);
    if (state.cache.get(key)) |entry| {
        if (entry.inflight) |*inf| {
            inf.has_thread = true;
            inf.job_id = ticket.job_id;
            inf.job_epoch = ticket.epoch;
        } else {
            entry.inflight = .{
                .stage = .decoding,
                .has_thread = true,
                .start_time_ms = now_ms,
                .target = pair_target,
                .job_id = ticket.job_id,
                .job_epoch = ticket.epoch,
            };
        }
    }
    errdefer {
        if (state.cache.get(key)) |entry| {
            if (entry.inflight) |*inf| {
                inf.has_thread = false;
                inf.job_id = 0;
                inf.job_epoch = 0;
            }
        }
    }

    args.* = DecodeArgs{
        .workers = &state.workers,
        .allocator = state.allocator,
        .io = state.io,
        .key = key,
        .job_id = ticket.job_id,
        .job_epoch = ticket.epoch,
        .current_job_epoch = &state.cache.job_epochs[ticket.job_id],
        .entry = dup_entry,
        .has_gpu_device = state.gpu_device != null,
        .pixel_format = state.display.getPixelFormat(),
        .thumb_only = thumb_only,
        .pair_target = pair_target,
        .current_generation = &state.cache.generation,
    };

    try decode_mod.spawnDecode(args);
}

fn probeActiveSlotMetadata(
    state: *AppState,
    key: image.ImageCacheKey,
) void {
    const media_item = state.viewer.navigation.getMediaEntryById(key.id) orelse
        return;
    const meta = image.probeMediaMetadata(state.io, media_item) orelse {
        if (state.cache.get(key)) |entry| {
            if (entry.resident.thumbnail == .none) {
                entry.resident.thumbnail = .not_available;
            }
        }
        return;
    };
    {
        const entry = state.cache.get(key) orelse return;
        entry.applyProbedMetadata(
            state_pkg.PhysicalDims.initPositive(meta.dims.w, meta.dims.h),
            meta.orientation,
            meta.raw_metadata,
        );
        if (entry.resident.thumbnail == .none) {
            const can_use_thumb_cache =
                state.workers.thumb_cache_config != .disabled and
                !media_item.isArchive();
            entry.resident.thumbnail =
                if (meta.has_embedded_thumbnail or can_use_thumb_cache)
                    .pending
                else
                    .not_available;
        }
    }
    if (state.viewer.navigation.getCurrentMediaId()) |cur_id| {
        if (key.id == cur_id) {
            state.updateCurrentRotation();
        }
    }
}

fn checkPairPromotion(
    state: *AppState,
    key: image.ImageCacheKey,
    now: u64,
) void {
    const media_item = state.viewer.navigation.getMediaEntryById(key.id) orelse
        return;
    if (!media_item.isPair()) return;
    const entry_val = state.cache.getEntry(key) orelse return;
    if (entry_val.inflight != null) return;
    if (entry_val.resident.asset != .loaded_gpu and
        entry_val.resident.asset != .loaded_cpu)
    {
        return;
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
        (now -| state.viewer.navigation.last_nav_time_ms > 250) and
        (tex_demand > 1.15);

    if ((is_inspecting or is_settled_fit) and state.workers.canSpawnDecode()) {
        if (state.cache.get(key)) |entry| {
            if (entry.inflight) |inf| {
                if (inf.has_thread) {
                    state.cache.cancelJob(inf.job_id);
                }
            }
            entry.inflight = .{
                .stage = .decoding,
                .start_time_ms = now,
                .target = .standalone_jpeg,
            };
        }
        spawnCacheDecodeSlot(
            state,
            key.id,
            media_item,
            false,
            .standalone_jpeg,
            now,
        ) catch |err| {
            if (state.cache.get(key)) |entry| {
                entry.inflight = null;
            }
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
    if (len == 0) return;

    const neighbors = state.viewer.navigation.getVisibleNeighbors() orelse
        return;
    const cur_id = state.viewer.navigation.getCurrentMediaId() orelse return;
    const dev_opt = state.gpu_device;

    state.cache.enforceVramBudget(
        dev_opt,
        &state.viewer.navigation,
        neighbors,
        state.viewer.getTransitionPrevIndex(),
        len,
        image.ImageCache.DEFAULT_MAX_VRAM_BYTES,
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

        if (in_desired) {
            i += 1;
        } else if (entry.resident.asset == .loaded_gpu) {
            // Retain loaded GPU textures beyond ±2 window until VRAM budget
            // requires eviction
            i += 1;
        } else if (dev_opt == null and entry.resident.asset == .loaded_cpu) {
            // Retain loaded CPU surfaces in headless mode
            i += 1;
        } else {
            state.cache.removeAndDeinit(i, dev_opt);
        }
    }

    // Fast-scrolling check: only active if navigation has actually occurred
    // and no IPC `wait_load` barrier is actively waiting for full resolution.
    const now = ctx.now_ms;
    const is_fast_scrolling =
        state.pending_wait_load_streams.items.len == 0 and
        state.viewer.navigation.last_nav_time_ms > 0 and
        (now -| state.viewer.navigation.last_nav_time_ms <
            FAST_SCROLL_THRESHOLD_MS);

    state.viewer.stats.max_decode_threads =
        state.workers.getMaxConcurrentDecodes();

    // Resource protection: check whether the current image is fully ready or
    // failed. When false, background decode workers are restricted strictly
    // to the active image `cur_id`. In headless/mock mode (no GPU device),
    // .loaded_cpu is terminal ready; with GPU, .loaded_gpu is required.
    const is_current_ready = blk: {
        const cur_key = state.cache.activeKey(cur_id);
        if (state.cache.get(cur_key)) |cur_entry| {
            break :blk switch (cur_entry.resident.asset) {
                .loaded_gpu, .failed => true,
                .loaded_cpu => state.gpu_device == null,
                .none => false,
            };
        }
        break :blk false;
    };

    // Fast-scrolling thumbnail readiness: check whether active image has
    // thumbnail or full texture ready. Speculative thumbnail preloading for
    // next image only runs if active image thumbnail is already ready.
    const is_active_thumb_ready = blk: {
        const cur_key = state.cache.activeKey(cur_id);
        if (state.cache.get(cur_key)) |cur_entry| {
            break :blk switch (cur_entry.resident.thumbnail) {
                .loaded, .not_available => true,
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
    const SpawnRequest = struct {
        id: MediaId,
        entry: MediaEntry,
    };
    var to_spawn = try std.ArrayList(SpawnRequest).initCapacity(
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
            if (d == neighbors.current and
                (entry.resident.asset == .loaded_cpu or
                    entry.resident.asset == .loaded_gpu))
            {
                hit = true;
            }
        } else {
            _ = try state.cache.appendSlot(
                state.allocator,
                d_id,
                .{
                    .inflight = .{
                        .stage = .decoding,
                        .start_time_ms = now,
                    },
                },
            );
        }

        if (state.cache.getEntry(key)) |entry| {
            const needs_dimensions = entry.metadata.full_dims == null and
                entry.resident.thumbnail == .none;
            if (needs_dimensions) {
                probeActiveSlotMetadata(state, key);
            }
        }

        if (state.cache.getEntry(key)) |entry| {
            const is_active_slot = (d_id == cur_id);
            const is_decoding = if (entry.inflight) |inf|
                inf.stage == .decoding and !inf.has_thread
            else
                false;
            if (is_decoding) {
                const thumb_ready =
                    entry.resident.thumbnail == .not_available or
                    entry.resident.thumbnail == .loaded;
                const skip_neighbor = d != neighbors.current and
                    is_fast_scrolling and
                    thumb_ready;
                const skip_active = d == neighbors.current and
                    is_fast_scrolling and
                    entry.resident.thumbnail == .loaded;
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
                checkPairPromotion(state, key, now);
            }
        }
    }
    state.viewer.stats.current_image_cache_hit = hit;

    // 4. Spawn worker threads
    for (to_spawn.items) |req| {
        if (!state.workers.canSpawnDecode()) continue;

        const key = state.cache.activeKey(req.id);
        const entry = state.cache.get(key) orelse continue;
        const inf = entry.inflight orelse continue;
        if (inf.has_thread or inf.stage != .decoding) continue;

        const thumb_only = is_fast_scrolling and
            entry.resident.thumbnail != .not_available;

        spawnCacheDecodeSlot(
            state,
            req.id,
            req.entry,
            thumb_only,
            inf.target,
            now,
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
            .surface = surf,
            .w = 100,
            .h = 100,
            .size_bytes = 1000,
        },
    }, null);
    state.cache.setInFlight(state.cache.activeKey(id0), null);

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
                    .surface = surf,
                    .w = 100,
                    .h = 100,
                    .size_bytes = 1000,
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
    // Set last_nav_time_ms to non-zero recent timestamp for fast scrolling
    state.viewer.navigation.last_nav_time_ms = 1000;

    // Pre-populate active slot 0 as decoding without thumbnail yet
    _ = try state.cache.appendSlot(allocator, id0, .{
        .inflight = .{ .stage = .decoding, .has_thread = true },
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
    state.viewer.navigation.last_nav_time_ms = 1000;

    // Run sysUpdateCache: speculative_idx is now 4 (wrap around from 0).
    // Slot 4 should be populated for speculative preloading!
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(state.cache.activeKey(id4)) != null);
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
    // Because test_0_init.png has no embedded thumbnail, synchronous probe
    // on Frame 1 sets .not_available!
    try std.testing.expectEqual(
        state_pkg.ThumbnailState.not_available,
        entry.?.resident.thumbnail,
    );
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
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = dup } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    // Fast scrolling is active
    state.viewer.navigation.last_nav_time_ms = 1000;

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1000,
    };
    try sysUpdateCache(ctx);

    const entry = state.cache.get(state.cache.activeKey(id0));
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(
        state_pkg.ThumbnailState.not_available,
        entry.?.resident.thumbnail,
    );
    // Active slot 0 should have has_thread = true (decode worker was spawned, not skipped!)
    try std.testing.expect(entry.?.inflight != null);
    try std.testing.expect(entry.?.inflight.?.has_thread);
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
                    .surface = surf,
                    .w = 1616.0,
                    .h = 1080.0,
                    .size_bytes = 500_000,
                },
            },
        },
    });
    if (state.cache.get(key)) |entry| {
        entry.metadata.full_dims = .{ .w = 1616.0, .h = 1080.0 };
        entry.metadata.raw_metadata =
            RawMetadata.init(6000.0, 4000.0);
    }

    // When zoom is 1.0x, inflight remains null
    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(key).?.inflight == null);
    try std.testing.expect(
        state.cache.get(key).?.resident.asset == .loaded_cpu,
    );

    // When zoom > 1.0x, zoom promotion sets inflight while preserving
    // resident asset
    state.viewer.viewport.mode = .manual;
    state.viewer.viewport.zoom_factor = state_pkg.clampZoomFactor(2.0);
    try sysUpdateCache(ctx);
    try std.testing.expect(state.cache.get(key).?.inflight != null);
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
    state.cache.setInFlight(state.cache.activeKey(id4), null);
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

    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .inflight = .{
            .stage = .decoding,
            .has_thread = true,
            .target = .standalone_jpeg,
        },
    });
    const entry0 = state.cache.get(key0).?;

    // 1. While inflight != null, checkPairPromotion must not spawn a duplicate
    // promotion worker.
    checkPairPromotion(&state, key0, 1000);
    try std.testing.expect(entry0.inflight != null);
    try std.testing.expectEqual(
        PairStreamTarget.standalone_jpeg,
        entry0.inflight.?.target,
    );
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
    try std.testing.expect(entry0.inflight != null);
    try std.testing.expectEqual(
        PairStreamTarget.standalone_jpeg,
        entry0.inflight.?.target,
    );
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

    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_gpu = .{
                    .gpu_texture = .{ .ptr = @ptrFromInt(0x1234) },
                    .w = 1616.0,
                    .h = 1080.0,
                    .size_bytes = 500_000,
                    .ingest = .{ .memory_size_bytes = 7_000_000 },
                },
            },
        },
        .inflight = null,
    });
    if (state.cache.get(key0)) |entry| {
        entry.metadata.full_dims = .{ .w = 1616.0, .h = 1080.0 };
        entry.metadata.raw_metadata =
            RawMetadata.init(6000.0, 4000.0);
    }

    state.viewer.viewport.mode = .manual;
    state.viewer.viewport.zoom_factor = state_pkg.clampZoomFactor(2.0);

    checkPairPromotion(&state, key0, 1000);

    const entry = state.cache.get(key0).?;
    try std.testing.expect(entry.resident.asset == .loaded_gpu);
    try std.testing.expectEqual(
        @as(f32, 1616.0),
        entry.resident.asset.loaded_gpu.w,
    );
    try std.testing.expect(entry.inflight != null);
    try std.testing.expectEqual(
        state_pkg.InFlightStage.decoding,
        entry.inflight.?.stage,
    );
    try std.testing.expectEqual(
        PairStreamTarget.standalone_jpeg,
        entry.inflight.?.target,
    );
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
    state.viewer.navigation.last_nav_time_ms = 980;
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

test "spawnCacheDecodeSlot stamps now_ms on inflight entry" {
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

    try spawnCacheDecodeSlot(
        &state,
        id0,
        .{ .filesystem = .{ .path = dup } },
        false,
        .adaptive,
        4200,
    );

    const entry = state.cache.get(key0).?;
    try std.testing.expect(entry.inflight != null);
    try std.testing.expectEqual(@as(u64, 4200), entry.inflight.?.start_time_ms);
}
