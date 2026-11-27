const app_state = @import("../state.zig");
const builtin = @import("builtin");
const cache_pkg = @import("cache");
const context = @import("context.zig");
const geom = @import("geom");
const gpu = @import("gpu");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const workers_mod = @import("../workers/root.zig");

const AppState = app_state.AppState;
const BeginAsyncUploadResult = gpu.BeginAsyncUploadResult;
const CacheEntry = cache_pkg.CacheEntry;
const calcCyclicDistance = cache_pkg.calcCyclicDistance;
const CpuAsset = cache_pkg.CpuAsset;
const EventWaker = workers_mod.EventWaker;
const FrameContext = context.FrameContext;
const ImageCache = cache_pkg.ImageCache;
const ImageCacheKey = cache_pkg.ImageCacheKey;
const PendingThumbWrite = app_state.PendingThumbWrite;
const PendingUploadMetadata = app_state.PendingUploadMetadata;
const PhysicalDims = geom.PhysicalDims;
const StagedTransferJob = gpu.StagedTransferJob;
const SurfaceOwnership = gpu.SurfaceOwnership;
const ThumbnailState = cache_pkg.ThumbnailState;
const uploadSurfaceToGpu = gpu.uploadSurfaceToGpu;

fn stageCopyWorker(
    io: std.Io,
    result_out: *?f64,
    done_flag: *std.atomic.Value(bool),
    waker: EventWaker,
    job: StagedTransferJob,
) void {
    var local_job = job;
    result_out.* = local_job.executeStagingCopy(io);
    done_flag.store(true, .release);
    waker.wake();
}

/// System Pass: Uploads decoded CPU surfaces in cache slots to GPU textures
/// and decays oversized staging buffers after idle cooldown.
pub fn sysProcessAssetUploads(ctx: FrameContext) void {
    const state = ctx.state;
    state.updateCurrentRotation();
    const did_upload = prepareCacheTextures(state, ctx.now_ms);
    if (state.gpu_device) |gpu_dev| {
        const is_idle = !did_upload and
            !state.pending_gpu_upload.isActive() and
            !state.cache.hasPendingCpuUploads(true) and
            state.workers.active_decode_threads.load(.acquire) == 0;
        _ = state.upload_staging.maybeShrinkIdle(
            gpu_dev,
            ctx.now_ms,
            is_idle,
        );
    }
}

fn uploadActivePendingThumb(
    io: std.Io,
    cache: *ImageCache,
    staging: *gpu.UploadStagingBuffer,
    gpu_dev: sdl.gpu.Device,
    unpack_pipeline: ?sdl.gpu.ComputePipeline,
    debug_show_thumb: bool,
    cur_key: ImageCacheKey,
) bool {
    var staged = blk: {
        const entry = cache.get(cur_key) orelse return false;
        const staged_thumb = switch (entry.resident.thumbnail) {
            .staged_cpu => |st| st,
            .none, .pending, .not_available, .unloaded, .loaded => {
                return false;
            },
        };

        const superseded = !debug_show_thumb and
            entry.resident.asset.isLoaded();
        if (superseded) {
            entry.resident.thumbnail.unloadSuperseded(false);
            return false;
        }
        entry.resident.thumbnail = .not_available;
        break :blk staged_thumb;
    };
    defer staged.deinit();

    const upload_res = uploadSurfaceToGpu(
        io,
        gpu_dev,
        staged.surface,
        unpack_pipeline,
        staging,
    ) orelse return false;

    const entry = cache.get(cur_key) orelse {
        gpu_dev.releaseTexture(upload_res.gpu_texture);
        return false;
    };
    entry.resident.thumbnail.deinit(gpu_dev);
    entry.resident.thumbnail = .{
        .loaded = .{
            .texture = upload_res.gpu_texture,
            .upload_id = cache.nextUploadId(),
            .info = .{
                .w = upload_res.w,
                .h = upload_res.h,
                .upload_time_ms = upload_res.ingest.upload_time_ms,
                .dct_snapped = staged.dct_snapped,
                .source = staged.source,
            },
        },
    };
    return true;
}

fn takeStagedCpuAsset(
    entry: *CacheEntry,
    now_ms: u64,
) ?CpuAsset {
    const asset = switch (entry.resident.asset) {
        .loaded_cpu => |cpu_asset| blk: {
            entry.resident.asset = .none;
            break :blk cpu_asset;
        },
        .promoting_gpu => |promo| blk: {
            entry.resident.asset = .{ .loaded_gpu = promo.active };
            break :blk promo.staged;
        },
        .loaded_gpu, .none, .failed => return null,
    };
    switch (entry.inflight) {
        .idle => entry.inflight = .{
            .uploading = .{ .start_time_ms = now_ms },
        },
        .queued_decode, .decoding, .uploading => {},
    }
    return asset;
}

fn prepareCacheTextures(state: *AppState, now_ms: u64) bool {
    {
        const entries = state.cache.slots.items(.entry);
        const keys = state.cache.slots.items(.key);

        for (entries, keys) |*entry, key| {
            const is_cur =
                if (state.viewer.navigation.getCurrentMediaId()) |cur_id|
                    cur_id == key.id
                else
                    false;
            const is_crossfading =
                state.viewer.animations.isActive(.thumb_crossfade) and
                is_cur;
            const keep_debug_thumb =
                state.viewer.ui.overlays.debug_show_thumb and
                is_cur;
            switch (entry.resident.asset) {
                .failed => {
                    entry.resident.thumbnail.discardStagedAndMarkUnavailable();
                },
                .loaded_gpu, .promoting_gpu => {
                    if (!is_crossfading and !keep_debug_thumb) {
                        const thumb = &entry.resident.thumbnail;
                        switch (thumb.*) {
                            .staged_cpu => thumb.unloadSuperseded(false),
                            .loaded => |loaded| {
                                if (state.gpu_device) |gpu_dev| {
                                    gpu_dev.releaseTexture(loaded.texture);
                                }
                                thumb.* = .{ .unloaded = loaded.info };
                            },
                            .none, .pending, .not_available, .unloaded => {},
                        }
                    }
                },
                .loaded_cpu => {
                    if (!keep_debug_thumb) {
                        entry.resident.thumbnail.unloadSuperseded(false);
                    }
                },
                .none => {},
            }
        }
    }

    const gpu_dev = state.gpu_device orelse return false;
    var did_upload = false;

    switch (state.pending_gpu_upload) {
        .idle => {},
        .copying => |pending| {
            if (!state.upload_stage_done.load(.acquire)) return false;
            state.upload_group.cancel(state.io);
            state.upload_stage_done.store(false, .monotonic);
            const conv_ms = state.upload_stage_result;
            state.upload_stage_result = null;
            state.pending_gpu_upload = .idle;
            var surface_transferred = false;
            defer {
                if (pending.thumb_write) |tw| {
                    if (!surface_transferred) {
                        tw.surface.destroy();
                    }
                }
                if (state.workers.active_decode_threads.load(.acquire) == 0) {
                    sdl.reclaimProcessHeap();
                }
            }
            if (gpu.finishAsyncUpload(
                state.io,
                gpu_dev,
                pending.prepared,
                conv_ms,
            )) |res| {
                did_upload = true;
                completeGpuUpload(
                    state,
                    pending.key,
                    pending.meta,
                    pending.thumb_write,
                    res,
                    gpu_dev,
                    ImageCache.DEFAULT_MAX_VRAM_BYTES,
                    &surface_transferred,
                );
            } else {
                handleGpuUploadFailure(state, pending.key);
            }
        },
    }

    const cur_id_opt = state.viewer.navigation.getCurrentMediaId();
    const cur_key_opt = if (cur_id_opt) |ci|
        state.cache.activeKey(ci)
    else
        null;

    if (cur_key_opt) |cur_key| {
        if (uploadActivePendingThumb(
            state.io,
            &state.cache,
            &state.upload_staging,
            gpu_dev,
            state.unpack_compute_pipeline,
            state.viewer.ui.overlays.debug_show_thumb,
            cur_key,
        )) {
            state.updateCurrentRotation();
            did_upload = true;
        }
    }

    var upload_target: ?struct {
        key: ImageCacheKey,
        asset: CpuAsset,
        prefer_sync: bool,
    } = null;

    const cur_entry_opt = if (cur_key_opt) |ck|
        state.cache.get(ck)
    else
        null;

    var can_upload_neighbors = true;
    if (cur_entry_opt) |cur_entry| {
        const thumb = cur_entry.resident.thumbnail;
        const cur_has_visible_gpu = switch (cur_entry.resident.asset) {
            .promoting_gpu, .loaded_gpu => true,
            .loaded_cpu, .none, .failed => switch (thumb) {
                .loaded => true,
                .none,
                .pending,
                .staged_cpu,
                .not_available,
                .unloaded,
                => false,
            },
        };
        const is_transition_active = switch (state.viewer.image_transition) {
            .active => true,
            .none => false,
        };
        if (takeStagedCpuAsset(cur_entry, now_ms)) |asset| {
            upload_target = .{
                .key = cur_key_opt.?,
                .asset = asset,
                .prefer_sync = !cur_has_visible_gpu and !is_transition_active,
            };
            can_upload_neighbors = false;
        } else switch (cur_entry.resident.asset) {
            .loaded_gpu, .failed => can_upload_neighbors = true,
            .none => can_upload_neighbors = false,
            .loaded_cpu, .promoting_gpu => unreachable,
        }
    }

    if (upload_target == null and can_upload_neighbors) {
        const entries = state.cache.slots.items(.entry);
        const keys = state.cache.slots.items(.key);
        const total_items = state.viewer.navigation.count();
        const neighbors_opt = state.viewer.navigation.getVisibleNeighbors();
        var best_idx: ?usize = null;
        var min_dist: usize = std.math.maxInt(usize);

        for (entries, keys, 0..) |entry, key, i| {
            if (!entry.resident.asset.hasPendingCpuUpload()) continue;
            const pos = state.viewer.navigation.posOfId(key.id) orelse
                continue;
            const dist = blk: {
                if (neighbors_opt) |neighbors| {
                    break :blk neighbors.stepDistance(pos) orelse
                        (3 + calcCyclicDistance(
                            pos,
                            neighbors.current,
                            total_items,
                        ));
                } else if (state.viewer.navigation.current_index) |cur| {
                    break :blk calcCyclicDistance(
                        pos,
                        cur,
                        total_items,
                    );
                } else {
                    break :blk i;
                }
            };

            if (dist < min_dist) {
                min_dist = dist;
                best_idx = i;
            }
        }

        if (best_idx) |bi| {
            if (takeStagedCpuAsset(&entries[bi], now_ms)) |asset| {
                upload_target = .{
                    .key = keys[bi],
                    .asset = asset,
                    .prefer_sync = false,
                };
            }
        }
    }

    if (upload_target) |target| {
        const meta = PendingUploadMetadata{
            .w = target.asset.cpu.w,
            .h = target.asset.cpu.h,
            .size_bytes = target.asset.cpu.size_bytes,
            .mime_type = target.asset.cpu.mime_type,
            .decode = target.asset.cpu.decode,
        };
        const thumb_write: ?PendingThumbWrite =
            if (target.asset.thumb_write) |tw|
                .{
                    .surface = target.asset.cpu.surface,
                    .source_mtime_sec = tw.source_mtime_sec,
                }
            else
                null;
        const surface_ownership: SurfaceOwnership = if (thumb_write != null)
            .{ .borrowed_for_thumb_write = target.asset.cpu.surface }
        else
            .{ .owned_by_worker = target.asset.cpu.surface };

        if (gpu.beginAsyncUpload(
            state.io,
            gpu_dev,
            surface_ownership,
            state.unpack_compute_pipeline,
            &state.upload_staging,
        )) |started| {
            if (target.prefer_sync) {
                if (finishSyncStagedUpload(
                    state,
                    gpu_dev,
                    target.key,
                    meta,
                    thumb_write,
                    started,
                )) {
                    did_upload = true;
                }
            } else {
                state.upload_stage_done.store(false, .monotonic);
                state.upload_stage_result = null;
                if (state.upload_group.concurrent(
                    state.io,
                    stageCopyWorker,
                    .{
                        state.io,
                        &state.upload_stage_result,
                        &state.upload_stage_done,
                        state.workers.waker,
                        started.job,
                    },
                )) |_| {
                    state.pending_gpu_upload = .{
                        .copying = .{
                            .key = target.key,
                            .meta = meta,
                            .thumb_write = thumb_write,
                            .prepared = started.prepared,
                        },
                    };
                } else |_| {
                    if (finishSyncStagedUpload(
                        state,
                        gpu_dev,
                        target.key,
                        meta,
                        thumb_write,
                        started,
                    )) {
                        did_upload = true;
                    }
                }
            }
        } else {
            target.asset.cpu.surface.destroy();
            if (state.workers.active_decode_threads.load(.acquire) == 0) {
                sdl.reclaimProcessHeap();
            }
            handleGpuUploadFailure(state, target.key);
        }
    }

    return did_upload;
}

fn finishSyncStagedUpload(
    state: *AppState,
    gpu_dev: sdl.gpu.Device,
    key: ImageCacheKey,
    meta: PendingUploadMetadata,
    thumb_write: ?PendingThumbWrite,
    started: BeginAsyncUploadResult,
) bool {
    var job = started.job;
    const conv_ms = job.executeStagingCopy(state.io);
    var surface_transferred = false;
    defer {
        if (thumb_write) |tw| {
            if (!surface_transferred) {
                tw.surface.destroy();
            }
        }
        if (state.workers.active_decode_threads.load(.acquire) == 0) {
            sdl.reclaimProcessHeap();
        }
    }
    if (gpu.finishAsyncUpload(
        state.io,
        gpu_dev,
        started.prepared,
        conv_ms,
    )) |res| {
        completeGpuUpload(
            state,
            key,
            meta,
            thumb_write,
            res,
            gpu_dev,
            ImageCache.DEFAULT_MAX_VRAM_BYTES,
            &surface_transferred,
        );
        return true;
    }
    handleGpuUploadFailure(state, key);
    return false;
}

fn enqueueDecodedThumbWrite(
    state: *AppState,
    key: ImageCacheKey,
    meta: PendingUploadMetadata,
    tw: PendingThumbWrite,
) bool {
    if (state.workers.thumb_cache_config == .disabled) return false;
    const entry = state.cache.getEntry(key) orelse return false;
    const media = state.viewer.navigation.getMediaEntryById(key.id) orelse
        return false;
    const path_slice: []const u8 = switch (media) {
        .archive_entry => return false,
        .filesystem => |f| f.path,
        .pair => |p| if (entry.metadata.raw_metadata.isRaw())
            p.raw_path
        else
            p.jpeg_path,
    };
    const owned_path = state.allocator.dupe(u8, path_slice) catch
        return false;
    const auth = entry.getAuthoritativeDims();
    const source_dims =
        auth.asPositive() orelse
        PhysicalDims.initPositive(meta.w, meta.h);

    state.workers.enqueueThumbWrite(state.allocator, state.io, .{
        .surface = tw.surface,
        .source_path = owned_path,
        .mime_type = meta.mime_type,
        .file_size = meta.size_bytes,
        .mtime_sec = tw.source_mtime_sec,
        .orientation = entry.metadata.orientation,
        .source_dims = source_dims,
    });
    return true;
}

fn completeGpuUpload(
    state: *AppState,
    key: ImageCacheKey,
    meta: PendingUploadMetadata,
    thumb_write: ?PendingThumbWrite,
    res: gpu.GpuUploadResult,
    gpu_dev: ?sdl.gpu.Device,
    max_vram_bytes: usize,
    surface_transferred: *bool,
) void {
    const was_loaded_gpu = blk: {
        const entry = state.cache.get(key) orelse {
            if (gpu_dev) |dev| dev.releaseTexture(res.gpu_texture);
            return;
        };
        const prev_gpu = entry.resident.asset.hasGpuTexture();
        entry.resident.asset.replaceGpuTexture(.{
            .gpu_texture = res.gpu_texture,
            .upload_id = state.cache.nextUploadId(),
            .w = res.w,
            .h = res.h,
            .size_bytes = meta.size_bytes,
            .mime_type = meta.mime_type,
            .decode = meta.decode,
            .ingest = res.ingest,
        }, gpu_dev);
        switch (entry.inflight) {
            .uploading => entry.inflight = .idle,
            .idle, .queued_decode, .decoding => {},
        }
        entry.resident.thumbnail.markNotAvailableIfUnresolved();
        break :blk prev_gpu;
    };

    if (!was_loaded_gpu) {
        checkLoadedGpuCrossfade(state, key);
    }
    state.updateCurrentRotation();
    state.cache.enforceVramBudget(
        gpu_dev,
        &state.viewer.navigation,
        state.viewer.navigation.getVisibleNeighbors(),
        state.viewer.getTransitionPrevIndex(),
        state.viewer.navigation.count(),
        max_vram_bytes,
    );
    if (thumb_write) |tw| {
        if (enqueueDecodedThumbWrite(state, key, meta, tw)) {
            surface_transferred.* = true;
        }
    }
}

fn checkLoadedGpuCrossfade(
    state: *AppState,
    target_key: ImageCacheKey,
) void {
    const cur_id = state.viewer.navigation.getCurrentMediaId() orelse return;
    if (target_key.id != cur_id) return;
    const entry = state.cache.getEntry(target_key) orelse return;

    const thumb_loaded = switch (entry.resident.thumbnail) {
        .loaded => true,
        .none, .pending, .staged_cpu, .not_available, .unloaded => false,
    };
    const is_dissolve_none = switch (state.viewer.image_transition) {
        .none => true,
        .active => false,
    };
    const can_crossfade = thumb_loaded and
        !state.viewer.ui.overlays.debug_show_thumb and
        !state.viewer.isSlideshowActive() and
        is_dissolve_none;
    if (can_crossfade) {
        state.viewer.animations.startFrom(
            .thumb_crossfade,
            0.0,
            1.0,
            state_pkg.DURATION_THUMB_CROSSFADE_MS,
            .ease_out_quad,
        );
    }
    switch (state.viewer.image_transition) {
        .none => {},
        .active => {
            if (state.viewer.animations.get(.image_crossfade) < 0.001) {
                state.viewer.animations.startFrom(
                    .image_crossfade,
                    0.0,
                    1.0,
                    state_pkg.DURATION_IMAGE_DISSOLVE_MS,
                    .ease_in_out_cubic,
                );
            }
        },
    }
}

fn handleGpuUploadFailure(state: *AppState, target_key: ImageCacheKey) void {
    const entry = state.cache.get(target_key) orelse return;
    switch (entry.inflight) {
        .uploading => entry.inflight = .idle,
        .idle => {},
        .queued_decode, .decoding => return,
    }
    switch (entry.resident.asset) {
        .loaded_gpu, .loaded_cpu, .promoting_gpu => {},
        .none, .failed => {
            entry.resident.asset = .failed;
            entry.resident.thumbnail.discardStagedAndMarkUnavailable();
            const cur_id =
                state.viewer.navigation.getCurrentMediaId() orelse return;
            if (target_key.id == cur_id) {
                state.viewer.image_transition = .none;
                state.viewer.animations.setImmediate(.image_crossfade, 1.0);
            }
        },
    }
}

test "sysProcessAssetUploads - safe execution on headless state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1000,
    };
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
    _ = try state.cache.appendSlot(
        allocator,
        id0,
        CacheEntry.stubLoadedGpuForTest(
            .{ .w = 800, .h = 600 },
            .{ .w = 160, .h = 120 },
        ),
    );

    // Case 1: thumb_crossfade is active -> prepareCacheTextures MUST NOT evict thumbnail
    state.viewer.animations.startFrom(
        .thumb_crossfade,
        0.0,
        1.0,
        120.0,
        .ease_out_quad,
    );
    _ = prepareCacheTextures(&state, 1000);
    var entry = state.cache.get(state.cache.activeKey(id0)).?;
    switch (entry.resident.thumbnail) {
        .loaded => {},
        .none, .pending, .staged_cpu, .not_available, .unloaded => {
            return error.TestExpectedLoadedThumb;
        },
    }

    // Case 2: thumb_crossfade settles -> prepareCacheTextures evicts thumbnail
    state.viewer.animations.settle(.thumb_crossfade);
    _ = prepareCacheTextures(&state, 1000);
    entry = state.cache.get(state.cache.activeKey(id0)).?;
    switch (entry.resident.thumbnail) {
        .unloaded => {},
        .none, .pending, .staged_cpu, .not_available, .loaded => {
            return error.TestExpectedUnloadedThumb;
        },
    }
}

test "prepareCacheTextures - uploads loaded_cpu without double free" {
    _ = sdl.init(sdl.init_flags.video);
    defer sdl.quit();

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var state = try AppState.initHeadless(allocator, io);
    state.gpu_device = dev;
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "test.jpg" },
    });
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const surf = sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse
        return;
    const key = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 64.0,
                        .h = 64.0,
                        .size_bytes = 64 * 64 * 4,
                    },
                },
            },
        },
    });

    _ = prepareCacheTextures(&state, 1000);

    // Verify upload transitioned to loaded_gpu and inflight is cleared
    const entry = state.cache.get(key).?;
    switch (entry.resident.asset) {
        .loaded_gpu => {},
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }
    try std.testing.expect(entry.inflight.isIdle());
}

test "completeGpuUpload - enqueues thumb write before swapRemove" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    var cache_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cache_path = try std.mem.print(
        &cache_path_buf,
        "{s}/thumbnails",
        .{dir_buf[0..dir_len]},
    );
    const cache_dir = try allocator.dupe(u8, cache_path);
    state.workers.thumb_cache_config = .{
        .enabled = .{
            .cache_dir = cache_dir,
            .write_policy = .all_missing,
            .write_tier = .large,
        },
    };

    try tmp.dir.writeFile(io, .{
        .sub_path = "img_5.arw",
        .data = "dummy",
    });

    const arena = state.viewer.navigation.directory_arena.allocator();
    for (0..6) |idx| {
        var p_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const p = try std.mem.print(
            &p_buf,
            "{s}/img_{d}.arw",
            .{ dir_buf[0..dir_len], idx },
        );
        _ = try state.viewer.navigation.appendEntry(allocator, .{
            .filesystem = .{ .path = try arena.dupe(u8, p) },
        });
    }
    state.viewer.navigation.current_index = 5;

    // Slot 0: distant GPU texture that will be evicted via swapRemove(0)
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id5 = state.viewer.navigation.getIdAt(5).?;
    const stub0 = CacheEntry.stubLoadedGpuForTest(
        .{ .w = 10.0, .h = 10.0 },
        .{ .w = 0.0, .h = 0.0 },
    );
    const dummy_tex = switch (stub0.resident.asset) {
        .loaded_gpu => |g| g.gpu_texture,
        .none, .loaded_cpu, .promoting_gpu, .failed => unreachable,
    };
    _ = try state.cache.appendSlot(allocator, id0, stub0);

    // Slot 1 (tail of state.cache.slots): active index 5 being uploaded
    const key5 = try state.cache.appendSlot(allocator, id5, .{
        .inflight = .{ .uploading = .{} },
    });

    const surf = sdl.Surface.create(32, 24, sdl.PixelFormat.rgba32) orelse
        return;
    var surface_transferred = false;
    defer if (!surface_transferred) surf.destroy();

    const asset = CpuAsset{
        .cpu = .{
            .surface = surf,
            .w = 1616.0,
            .h = 1080.0,
            .size_bytes = 4096,
            .mime_type = "image/x-sony-arw",
            .decode = .{
                .read_time_ms = 0.1,
                .decode_time_ms = 1.0,
                .conversion_time_ms = 0.0,
            },
        },
        .thumb_write = .{ .source_mtime_sec = 1700000000 },
    };
    const e5 = state.cache.get(key5).?;
    e5.metadata.orientation = .rotate_270;
    e5.metadata.raw_metadata = @import("probe").RawMetadata.init(
        6000.0,
        4000.0,
    );
    e5.updateFullDims(.{ .w = 6000.0, .h = 4000.0 });

    const full_res = gpu.GpuUploadResult{
        .gpu_texture = dummy_tex,
        .w = 1616.0,
        .h = 1080.0,
        .ingest = .{
            .upload_time_ms = 0.1,
            .memory_size_bytes = 400,
        },
    };

    // Budget is 600 bytes; 400 + 400 = 800 > 600, so enforceVramBudget will
    // evict slot 0 via swapRemove(0), moving tail slot (key5) into index 0
    // before enqueueDecodedThumbWrite resolves key5 via getEntry(key5).
    const meta5 = PendingUploadMetadata{
        .w = asset.cpu.w,
        .h = asset.cpu.h,
        .size_bytes = asset.cpu.size_bytes,
        .mime_type = asset.cpu.mime_type,
        .decode = asset.cpu.decode,
    };
    const tw5: ?PendingThumbWrite = if (asset.thumb_write) |tw|
        .{
            .surface = asset.cpu.surface,
            .source_mtime_sec = tw.source_mtime_sec,
        }
    else
        null;
    completeGpuUpload(
        &state,
        key5,
        meta5,
        tw5,
        full_res,
        null,
        600,
        &surface_transferred,
    );

    try std.testing.expect(surface_transferred);
    try std.testing.expectEqual(@as(usize, 1), state.cache.count());
    try std.testing.expectEqual(
        @as(u64, 1),
        state.workers.snapshotThumbStats().cache_writes,
    );

    // If a slot has expired or been evicted, enqueueDecodedThumbWrite safely
    // returns false via getEntry(expired_key).
    const expired_surf = sdl.Surface.create(8, 8, sdl.PixelFormat.rgba32) orelse
        return;
    defer expired_surf.destroy();
    const expired_key = ImageCacheKey{
        .id = id0,
        .generation = key5.generation,
    };
    try std.testing.expect(!enqueueDecodedThumbWrite(
        &state,
        expired_key,
        meta5,
        .{
            .surface = expired_surf,
            .source_mtime_sec = 1700000000,
        },
    ));
}

test "prepareCacheTextures - uploads staged_cpu and paces pending uploads" {
    _ = sdl.init(sdl.init_flags.video);
    defer sdl.quit();

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var state = try AppState.initHeadless(allocator, io);
    state.gpu_device = dev;
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    for (0..3) |idx| {
        const name = try dir_alloc.print("img_{d}.jpg", .{idx});
        _ = try state.viewer.navigation.appendEntry(allocator, .{
            .filesystem = .{ .path = name },
        });
    }
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;
    const id2 = state.viewer.navigation.getIdAt(2).?;

    // Slot 0 has staged_cpu thumb + .none asset; slot 1 & 2 have .loaded_cpu
    // waiting in neighbor slots.
    const t0 = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse return;
    const k0 = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .thumbnail = .{
                .staged_cpu = .{ .surface = t0, .dct_snapped = true },
            },
        },
    });
    const s1 = sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse return;
    const k1 = try state.cache.appendSlot(allocator, id1, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = s1,
                        .w = 32.0,
                        .h = 32.0,
                        .size_bytes = 4096,
                    },
                },
            },
        },
    });
    const s2 = sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse return;
    const k2 = try state.cache.appendSlot(allocator, id2, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = s2,
                        .w = 32.0,
                        .h = 32.0,
                        .size_bytes = 4096,
                    },
                },
            },
        },
    });

    // Frame 1: active thumbnail uploads, neighbors wait while active is .none
    _ = prepareCacheTextures(&state, 1000);
    switch (state.cache.get(k0).?.resident.thumbnail) {
        .loaded => {},
        .none, .pending, .staged_cpu, .not_available, .unloaded => {
            return error.TestExpectedLoadedThumb;
        },
    }
    try std.testing.expect(
        state.cache.get(k1).?.resident.asset.hasPendingCpuUpload(),
    );
    try std.testing.expect(
        state.cache.get(k2).?.resident.asset.hasPendingCpuUpload(),
    );

    // Active full image arrives: uploads active first, neighbors still wait
    const s0 = sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
    state.cache.get(k0).?.resident.asset = .{
        .loaded_cpu = .{
            .cpu = .{
                .surface = s0,
                .w = 64.0,
                .h = 64.0,
                .size_bytes = 16384,
            },
        },
    };
    _ = prepareCacheTextures(&state, 1016);
    switch (state.cache.get(k0).?.resident.asset) {
        .loaded_gpu => |active_gpu| {
            // Active promotion arrives while slot 1 is waiting: active wins
            const s0_promo =
                sdl.Surface.create(96, 96, sdl.PixelFormat.rgba32) orelse
                return;
            state.cache.get(k0).?.resident.asset = .{
                .promoting_gpu = .{
                    .active = active_gpu,
                    .staged = .{
                        .cpu = .{
                            .surface = s0_promo,
                            .w = 96.0,
                            .h = 96.0,
                            .size_bytes = 36864,
                        },
                    },
                },
            };
        },
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }
    try std.testing.expect(
        state.cache.get(k1).?.resident.asset.hasPendingCpuUpload(),
    );

    _ = prepareCacheTextures(&state, 1032);
    switch (state.cache.get(k0).?.resident.asset) {
        .loaded_gpu => |g| try std.testing.expectEqual(@as(f32, 96.0), g.w),
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }
    try std.testing.expect(
        state.cache.get(k1).?.resident.asset.hasPendingCpuUpload(),
    );

    // Next frame: closest neighbor (slot 1) uploads, slot 2 stays pending
    _ = prepareCacheTextures(&state, 1048);
    switch (state.cache.get(k1).?.resident.asset) {
        .loaded_gpu => {},
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }
    try std.testing.expect(
        state.cache.get(k2).?.resident.asset.hasPendingCpuUpload(),
    );
}

test "prepareCacheTextures - clears stranded staged_cpu on failed slots" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    for (0..2) |idx| {
        const name = try dir_alloc.print("img_{d}.jpg", .{idx});
        _ = try state.viewer.navigation.appendEntry(allocator, .{
            .filesystem = .{ .path = name },
        });
    }
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;

    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{ .asset = .failed },
    });
    const thumb_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
        return;
    const k1 = try state.cache.appendSlot(allocator, id1, .{
        .resident = .{
            .asset = .failed,
            .thumbnail = .{ .staged_cpu = .{ .surface = thumb_surf } },
        },
    });

    _ = prepareCacheTextures(&state, 1000);
    try std.testing.expectEqual(
        ThumbnailState.not_available,
        state.cache.get(k1).?.resident.thumbnail,
    );
}

test "sysProcessAssetUploads - stamps and decays oversized staging buffer" {
    _ = sdl.init(sdl.init_flags.video);
    defer sdl.quit();

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var state = try AppState.initHeadless(allocator, io);
    state.gpu_device = dev;
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "huge.jpg" },
    });
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    // 5024x5024 RGBA32 (> 96 MiB) expands transfer staging past warm cap
    const huge_surf = sdl.Surface.create(
        5024,
        5024,
        sdl.PixelFormat.rgba32,
    ) orelse return;
    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = huge_surf,
                        .w = 5024.0,
                        .h = 5024.0,
                        .size_bytes = 5024 * 5024 * 4,
                    },
                },
            },
        },
    });

    // Frame 1: upload occurs -> oversized_since_ms stamped at 1000
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1000,
    });
    try std.testing.expectEqual(
        @as(?u64, 1000),
        state.upload_staging.oversized_since_ms,
    );
    switch (state.upload_staging.transfer) {
        .allocated => |a| try std.testing.expect(
            a.capacity > gpu.UploadStagingBuffer.WARM_STAGING_CAP_BYTES,
        ),
        .unallocated => return error.TestExpectedAllocatedTransfer,
    }

    // Frame 2: busy decode worker refreshes timer to 3000
    state.workers.active_decode_threads.store(1, .release);
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 3000,
    });
    try std.testing.expectEqual(
        @as(?u64, 3000),
        state.upload_staging.oversized_since_ms,
    );

    // Frame 3: idle just before IDLE_DECAY_MS elapsed -> retained
    const decay_ms = gpu.UploadStagingBuffer.IDLE_DECAY_MS;
    state.workers.active_decode_threads.store(0, .release);
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 3000 + decay_ms - 1,
    });
    try std.testing.expectEqual(
        @as(?u64, 3000),
        state.upload_staging.oversized_since_ms,
    );
    switch (state.upload_staging.transfer) {
        .allocated => {},
        .unallocated => return error.TestExpectedAllocatedTransfer,
    }

    // Frame 4: idle at IDLE_DECAY_MS elapsed -> decayed to .unallocated
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 3000 + decay_ms,
    });
    try std.testing.expectEqual(
        @as(?u64, null),
        state.upload_staging.oversized_since_ms,
    );
    switch (state.upload_staging.transfer) {
        .unallocated => {},
        .allocated => return error.TestExpectedUnallocatedTransfer,
    }
}

test "toggle_pair_stream on loaded_cpu survives GPU upload and failure" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const intents_sys = @import("intents.zig");
    const probe_pkg = @import("probe");
    const vfs_pkg = @import("vfs");

    // 1. Headless verification of takeStagedCpuAsset -> completeGpuUpload and
    //    takeStagedCpuAsset -> handleGpuUploadFailure with .queued_decode
    {
        var state = try AppState.initHeadless(allocator, io);
        defer state.deinit();

        const dir_alloc = state.viewer.navigation.directory_arena.allocator();
        const raw_p = try dir_alloc.dupe(u8, "shot0.arw");
        const jpg_p = try dir_alloc.dupe(u8, "shot0.jpg");
        _ = try state.viewer.navigation.appendEntry(allocator, .{
            .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p },
        });
        const raw_p1 = try dir_alloc.dupe(u8, "shot1.arw");
        const jpg_p1 = try dir_alloc.dupe(u8, "shot1.jpg");
        _ = try state.viewer.navigation.appendEntry(allocator, .{
            .pair = .{ .raw_path = raw_p1, .jpeg_path = jpg_p1 },
        });
        state.viewer.navigation.current_index = 0;

        const id0 = state.viewer.navigation.getIdAt(0).?;
        const id1 = state.viewer.navigation.getIdAt(1).?;
        const surf0 = sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse
            return;
        const key0 = state.cache.appendSlot(allocator, id0, .{
            .metadata = .{
                .raw_metadata = probe_pkg.RawMetadata.init(6000.0, 4000.0),
            },
            .resident = .{
                .asset = .{
                    .loaded_cpu = .{
                        .cpu = .{
                            .surface = surf0,
                            .w = 32.0,
                            .h = 32.0,
                            .size_bytes = 32 * 32 * 4,
                        },
                    },
                },
            },
        }) catch |err| {
            surf0.destroy();
            return err;
        };

        try state.pushIntent(.toggle_pair_stream);
        try intents_sys.sysExecuteIntents(.{
            .state = &state,
            .frame_allocator = allocator,
            .now_ms = 1000,
        });

        const asset0 = takeStagedCpuAsset(state.cache.get(key0).?, 1005).?;
        var transferred0 = false;
        defer if (!transferred0) asset0.cpu.surface.destroy();

        const stub = CacheEntry.stubLoadedGpuForTest(
            .{ .w = 32.0, .h = 32.0 },
            .{ .w = 0.0, .h = 0.0 },
        );
        const dummy_tex = switch (stub.resident.asset) {
            .loaded_gpu => |g| g.gpu_texture,
            .none, .loaded_cpu, .promoting_gpu, .failed => unreachable,
        };
        completeGpuUpload(
            &state,
            key0,
            .{
                .w = asset0.cpu.w,
                .h = asset0.cpu.h,
                .size_bytes = asset0.cpu.size_bytes,
                .mime_type = asset0.cpu.mime_type,
                .decode = asset0.cpu.decode,
            },
            null,
            .{
                .gpu_texture = dummy_tex,
                .w = 32.0,
                .h = 32.0,
                .ingest = .{ .upload_time_ms = 0.1, .memory_size_bytes = 4096 },
            },
            null,
            ImageCache.DEFAULT_MAX_VRAM_BYTES,
            &transferred0,
        );

        switch (state.cache.get(key0).?.inflight) {
            .queued_decode => |q| {
                try std.testing.expectEqual(@as(u64, 1000), q.start_time_ms);
                try std.testing.expectEqual(
                    vfs_pkg.PairStreamTarget.standalone_jpeg,
                    q.target,
                );
            },
            .idle, .decoding, .uploading => {
                return error.TestExpectedQueuedDecode;
            },
        }

        // Failure path on a .loaded_cpu + .queued_decode slot preserves queue
        const surf1 = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
            return;
        const thumb1 = sdl.Surface.create(8, 8, sdl.PixelFormat.rgba32) orelse {
            surf1.destroy();
            return;
        };
        const key1 = state.cache.appendSlot(allocator, id1, .{
            .resident = .{
                .thumbnail = .{
                    .staged_cpu = .{ .surface = thumb1 },
                },
                .asset = .{
                    .loaded_cpu = .{
                        .cpu = .{
                            .surface = surf1,
                            .w = 16.0,
                            .h = 16.0,
                            .size_bytes = 16 * 16 * 4,
                        },
                    },
                },
            },
            .inflight = .{
                .queued_decode = .{
                    .start_time_ms = 2500,
                    .target = .raw_preview,
                },
            },
        }) catch |err| {
            surf1.destroy();
            thumb1.destroy();
            return err;
        };
        state.viewer.navigation.current_index = 1;
        state.viewer.image_transition = .{
            .active = .{ .prev_index = 0, .prev_rotation = 0.0 },
        };
        const asset1 = takeStagedCpuAsset(state.cache.get(key1).?, 2510).?;
        defer asset1.cpu.surface.destroy();
        handleGpuUploadFailure(&state, key1);

        const entry1 = state.cache.get(key1).?;
        switch (entry1.resident.asset) {
            .none => {},
            .loaded_cpu, .loaded_gpu, .promoting_gpu, .failed => {
                return error.TestExpectedNoneAsset;
            },
        }
        try std.testing.expect(entry1.resident.thumbnail.isStagedCpu());
        switch (state.viewer.image_transition) {
            .active => {},
            .none => return error.TestExpectedActiveTransition,
        }
        switch (entry1.inflight) {
            .queued_decode => |q| {
                try std.testing.expectEqual(@as(u64, 2500), q.start_time_ms);
                try std.testing.expectEqual(
                    vfs_pkg.PairStreamTarget.raw_preview,
                    q.target,
                );
            },
            .idle, .decoding, .uploading => {
                return error.TestExpectedQueuedDecode;
            },
        }
        try std.testing.expect(state.isCurrentSlideLoading());
        try std.testing.expect(!state.isWaitLoadReady());

        // Failure while .uploading clears inflight and transitions to .failed
        entry1.inflight = .{ .uploading = .{ .start_time_ms = 2600 } };
        handleGpuUploadFailure(&state, key1);
        try std.testing.expect(entry1.inflight.isIdle());
        switch (entry1.resident.asset) {
            .failed => {},
            .none, .loaded_cpu, .loaded_gpu, .promoting_gpu => {
                return error.TestExpectedFailedAsset;
            },
        }
        switch (entry1.resident.thumbnail) {
            .not_available => {},
            .none, .pending, .staged_cpu, .unloaded, .loaded => {
                return error.TestExpectedUnavailableThumb;
            },
        }
        switch (state.viewer.image_transition) {
            .none => {},
            .active => return error.TestExpectedNoneTransition,
        }
        try std.testing.expect(!state.isCurrentSlideLoading());
        try std.testing.expect(state.isWaitLoadReady());
    }

    // 2. End-to-end GPU sysExecuteIntents -> sysProcessAssetUploads
    _ = sdl.init(sdl.init_flags.video);
    defer sdl.quit();

    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var state = try AppState.initHeadless(allocator, io);
    state.gpu_device = dev;
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const raw_p = try dir_alloc.dupe(u8, "gpu_shot.arw");
    const jpg_p = try dir_alloc.dupe(u8, "gpu_shot.jpg");
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .pair = .{ .raw_path = raw_p, .jpeg_path = jpg_p },
    });
    state.viewer.navigation.current_index = 0;

    const id0 = state.viewer.navigation.getIdAt(0).?;
    const surf = sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse
        return;
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .metadata = .{
            .raw_metadata = probe_pkg.RawMetadata.init(6000.0, 4000.0),
        },
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 64.0,
                        .h = 64.0,
                        .size_bytes = 64 * 64 * 4,
                    },
                },
            },
        },
    });

    try state.pushIntent(.toggle_pair_stream);
    try intents_sys.sysExecuteIntents(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 3000,
    });
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 3000,
    });

    const entry0 = state.cache.get(key0).?;
    switch (entry0.resident.asset) {
        .loaded_gpu => {},
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }
    switch (entry0.inflight) {
        .queued_decode => |q| {
            try std.testing.expectEqual(@as(u64, 3000), q.start_time_ms);
            try std.testing.expectEqual(
                vfs_pkg.PairStreamTarget.standalone_jpeg,
                q.target,
            );
        },
        .idle, .decoding, .uploading => return error.TestExpectedQueuedDecode,
    }
}

test "neighbor loaded_cpu with decoding ticket preserves ticket on upload" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const events_mod = @import("../events.zig");
    const vfs_pkg = @import("vfs");

    // 1. Headless verification of completeGpuUpload and handleGpuUploadFailure
    {
        var state = try AppState.initHeadless(allocator, io);
        defer state.deinit();

        const dir_alloc = state.viewer.navigation.directory_arena.allocator();
        const p0 = try dir_alloc.dupe(u8, "n0.jpg");
        const p1 = try dir_alloc.dupe(u8, "n1.jpg");
        _ = try state.viewer.navigation.appendEntry(allocator, .{
            .filesystem = .{ .path = p0 },
        });
        _ = try state.viewer.navigation.appendEntry(allocator, .{
            .filesystem = .{ .path = p1 },
        });
        state.viewer.navigation.current_index = 1;

        const id0 = state.viewer.navigation.getIdAt(0).?;
        const id1 = state.viewer.navigation.getIdAt(1).?;
        const ticket0 = state.cache.allocJob().?;
        const surf0 = sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse
            return;
        const key0 = state.cache.appendSlot(allocator, id0, .{
            .resident = .{
                .asset = .{
                    .loaded_cpu = .{
                        .cpu = .{
                            .surface = surf0,
                            .w = 32.0,
                            .h = 32.0,
                            .size_bytes = 32 * 32 * 4,
                        },
                    },
                },
            },
            .inflight = .{
                .decoding = .{
                    .start_time_ms = 555,
                    .target = .standalone_jpeg,
                    .ticket = ticket0,
                },
            },
        }) catch |err| {
            surf0.destroy();
            return err;
        };

        const ticket1 = state.cache.allocJob().?;
        const surf1 = sdl.Surface.create(24, 24, sdl.PixelFormat.rgba32) orelse
            return;
        const key1 = state.cache.appendSlot(allocator, id1, .{
            .resident = .{
                .asset = .{
                    .loaded_cpu = .{
                        .cpu = .{
                            .surface = surf1,
                            .w = 24.0,
                            .h = 24.0,
                            .size_bytes = 24 * 24 * 4,
                        },
                    },
                },
            },
            .inflight = .{
                .decoding = .{
                    .start_time_ms = 777,
                    .target = .raw_preview,
                    .ticket = ticket1,
                },
            },
        }) catch |err| {
            surf1.destroy();
            return err;
        };

        // Upload completion on slot 0 preserves .decoding and ticket0
        const asset0 = takeStagedCpuAsset(state.cache.get(key0).?, 2000).?;
        var transferred0 = false;
        defer if (!transferred0) asset0.cpu.surface.destroy();

        const stub = CacheEntry.stubLoadedGpuForTest(
            .{ .w = 32.0, .h = 32.0 },
            .{ .w = 0.0, .h = 0.0 },
        );
        const dummy_tex = switch (stub.resident.asset) {
            .loaded_gpu => |g| g.gpu_texture,
            .none, .loaded_cpu, .promoting_gpu, .failed => unreachable,
        };
        completeGpuUpload(
            &state,
            key0,
            .{
                .w = asset0.cpu.w,
                .h = asset0.cpu.h,
                .size_bytes = asset0.cpu.size_bytes,
                .mime_type = asset0.cpu.mime_type,
                .decode = asset0.cpu.decode,
            },
            null,
            .{
                .gpu_texture = dummy_tex,
                .w = 32.0,
                .h = 32.0,
                .ingest = .{ .upload_time_ms = 0.1, .memory_size_bytes = 4096 },
            },
            null,
            ImageCache.DEFAULT_MAX_VRAM_BYTES,
            &transferred0,
        );

        switch (state.cache.get(key0).?.inflight) {
            .decoding => |dec| {
                try std.testing.expectEqual(@as(u64, 555), dec.start_time_ms);
                try std.testing.expectEqual(
                    vfs_pkg.PairStreamTarget.standalone_jpeg,
                    dec.target,
                );
                try std.testing.expectEqual(ticket0, dec.ticket);
            },
            .idle, .queued_decode, .uploading => {
                return error.TestExpectedDecoding;
            },
        }

        // Upload failure on slot 1 preserves .decoding and ticket1
        const asset1 = takeStagedCpuAsset(state.cache.get(key1).?, 2005).?;
        defer asset1.cpu.surface.destroy();
        handleGpuUploadFailure(&state, key1);

        const entry1_after_fail = state.cache.get(key1).?;
        switch (entry1_after_fail.resident.asset) {
            .none => {},
            .loaded_cpu, .loaded_gpu, .promoting_gpu, .failed => {
                return error.TestExpectedNoneAsset;
            },
        }
        switch (entry1_after_fail.inflight) {
            .decoding => |dec| {
                try std.testing.expectEqual(@as(u64, 777), dec.start_time_ms);
                try std.testing.expectEqual(
                    vfs_pkg.PairStreamTarget.raw_preview,
                    dec.target,
                );
                try std.testing.expectEqual(ticket1, dec.ticket);
            },
            .idle, .queued_decode, .uploading => {
                return error.TestExpectedDecoding;
            },
        }
        try std.testing.expect(state.isCurrentSlideLoading());
        try std.testing.expect(!state.isWaitLoadReady());

        // Worker completions release both tickets -> job_alloc_mask == 0
        const dec_surf0 =
            sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
        try state.workers.event_queue.push(allocator, io, .{
            .image_decoded = .init(key0, ticket0.epoch, .{
                .surface = dec_surf0,
                .w = 64.0,
                .h = 64.0,
                .size_bytes = 64 * 64 * 4,
                .mime_type = "image/jpeg",
                .orientation = .normal,
                .raw_metadata = .none,
                .decode = .{},
            }),
        });
        const dec_surf1 =
            sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
        try state.workers.event_queue.push(allocator, io, .{
            .image_decoded = .init(key1, ticket1.epoch, .{
                .surface = dec_surf1,
                .w = 64.0,
                .h = 64.0,
                .size_bytes = 64 * 64 * 4,
                .mime_type = "image/jpeg",
                .orientation = .normal,
                .raw_metadata = .none,
                .decode = .{},
            }),
        });
        try std.testing.expect(events_mod.drainWorkerEvents(&state, 1000));
        try std.testing.expect(state.cache.get(key0).?.inflight.isIdle());
        try std.testing.expect(state.cache.get(key1).?.inflight.isIdle());
        try std.testing.expectEqual(@as(u16, 0), state.cache.job_alloc_mask);
    }

    // 2. End-to-end GPU sysProcessAssetUploads on neighbor + drainWorkerEvents
    _ = sdl.init(sdl.init_flags.video);
    defer sdl.quit();

    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var state = try AppState.initHeadless(allocator, io);
    state.gpu_device = dev;
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const p0 = try dir_alloc.dupe(u8, "gpu_neighbor.arw");
    const p1 = try dir_alloc.dupe(u8, "gpu_active.jpg");
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = p0 },
    });
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = p1 },
    });
    state.viewer.navigation.current_index = 1;

    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;
    const active_surf =
        sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse return;
    _ = try state.cache.appendSlot(allocator, id1, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = active_surf,
                        .w = 32.0,
                        .h = 32.0,
                        .size_bytes = 32 * 32 * 4,
                    },
                },
            },
        },
    });
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1000,
    });

    const ticket0 = state.cache.allocJob().?;
    const neighbor_surf =
        sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse return;
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = neighbor_surf,
                        .w = 32.0,
                        .h = 32.0,
                        .size_bytes = 32 * 32 * 4,
                    },
                },
            },
        },
        .inflight = .{
            .decoding = .{
                .start_time_ms = 1000,
                .target = .standalone_jpeg,
                .ticket = ticket0,
            },
        },
    });

    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1016,
    });

    const entry0 = state.cache.get(key0).?;
    switch (entry0.resident.asset) {
        .loaded_gpu => {},
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }
    switch (entry0.inflight) {
        .decoding => |dec| try std.testing.expectEqual(ticket0, dec.ticket),
        .idle, .queued_decode, .uploading => return error.TestExpectedDecoding,
    }

    const dec_surf =
        sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, ticket0.epoch, .{
            .surface = dec_surf,
            .w = 64.0,
            .h = 64.0,
            .size_bytes = 64 * 64 * 4,
            .mime_type = "image/jpeg",
            .orientation = .normal,
            .raw_metadata = .none,
            .decode = .{},
        }),
    });
    try std.testing.expect(events_mod.drainWorkerEvents(&state, 1032));
    try std.testing.expect(state.cache.get(key0).?.inflight.isIdle());
    try std.testing.expectEqual(@as(u16, 0), state.cache.job_alloc_mask);
}

test "async GPU upload stages on worker thread and completes cleanly" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var state = try AppState.initHeadless(allocator, io);
    state.gpu_device = dev;
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "async0.jpg" },
    });
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "async1.jpg" },
    });
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;

    const surf0 =
        sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf0,
                        .w = 64.0,
                        .h = 64.0,
                        .size_bytes = 64 * 64 * 4,
                    },
                },
            },
        },
    });

    // Pass 1: active slide without a visible GPU texture or active transition
    // uploads synchronously so GPU Frame 0 never flashes a blank frame.
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1000,
    });
    try std.testing.expect(!state.pending_gpu_upload.isActive());
    switch (state.cache.get(key0).?.resident.asset) {
        .loaded_gpu => {},
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }

    // Pass 2: neighbor upload stages asynchronously on worker thread and
    // completes cleanly.
    const surf1 =
        sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
    const key1 = try state.cache.appendSlot(allocator, id1, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf1,
                        .w = 64.0,
                        .h = 64.0,
                        .size_bytes = 64 * 64 * 4,
                    },
                    .thumb_write = .{ .source_mtime_sec = 1700000000 },
                },
            },
        },
    });
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1016,
    });
    try std.testing.expect(state.pending_gpu_upload.isActive());

    // Wait for worker completion via infallible atomic flag
    state.upload_group.cancel(io);
    try std.testing.expect(state.upload_stage_done.load(.acquire));

    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1032,
    });
    try std.testing.expect(!state.pending_gpu_upload.isActive());
    switch (state.cache.get(key1).?.resident.asset) {
        .loaded_gpu => {},
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    }

    // Verify active slide with an active transition stages asynchronously and
    // cancelPendingGpuUploadForKey cancels only the matching slot.
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "async2.jpg" },
    });
    state.viewer.navigation.current_index = 2;
    state.viewer.image_transition = .{
        .active = .{
            .prev_index = 0,
            .prev_rotation = 0.0,
        },
    };
    const id2 = state.viewer.navigation.getIdAt(2).?;
    const surf2_active =
        sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
    const key2 = try state.cache.appendSlot(allocator, id2, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf2_active,
                        .w = 64.0,
                        .h = 64.0,
                        .size_bytes = 64 * 64 * 4,
                    },
                    .thumb_write = .{ .source_mtime_sec = 1700000000 },
                },
            },
        },
    });
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1048,
    });
    try std.testing.expect(state.pending_gpu_upload.isActive());
    state.cancelPendingGpuUploadForKey(key0);
    try std.testing.expect(state.pending_gpu_upload.isActive());
    state.cancelPendingGpuUploadForKey(key2);
    try std.testing.expect(!state.pending_gpu_upload.isActive());

    // Verify active slide with `.promoting_gpu` (no transition) stages
    // asynchronously while keeping its active GPU texture visible.
    state.viewer.navigation.current_index = 0;
    state.viewer.image_transition = .none;
    const active_gpu = switch (state.cache.get(key0).?.resident.asset) {
        .loaded_gpu => |g| g,
        .none, .loaded_cpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedGpu;
        },
    };
    const surf_promo =
        sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
    state.cache.get(key0).?.resident.asset = .{
        .promoting_gpu = .{
            .active = active_gpu,
            .staged = .{
                .cpu = .{
                    .surface = surf_promo,
                    .w = 64.0,
                    .h = 64.0,
                    .size_bytes = 64 * 64 * 4,
                },
            },
        },
    };
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1064,
    });
    try std.testing.expect(state.pending_gpu_upload.isActive());
    state.cancelPendingGpuUploadForKey(key0);
    try std.testing.expect(!state.pending_gpu_upload.isActive());

    // Verify active slide with a `.loaded` GPU thumbnail (no transition)
    // stages asynchronously while keeping the thumbnail visible.
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "async3.jpg" },
    });
    state.viewer.navigation.current_index = 3;
    const id3 = state.viewer.navigation.getIdAt(3).?;
    const thumb_surf =
        sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse return;
    const key3 = try state.cache.appendSlot(allocator, id3, .{
        .resident = .{
            .thumbnail = .{
                .staged_cpu = .{
                    .surface = thumb_surf,
                },
            },
        },
    });
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1080,
    });
    switch (state.cache.get(key3).?.resident.thumbnail) {
        .loaded => {},
        .none, .pending, .staged_cpu, .not_available, .unloaded => {
            return error.TestExpectedLoadedThumbnail;
        },
    }
    const surf3 =
        sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
    state.cache.get(key3).?.resident.asset = .{
        .loaded_cpu = .{
            .cpu = .{
                .surface = surf3,
                .w = 64.0,
                .h = 64.0,
                .size_bytes = 64 * 64 * 4,
            },
        },
    };
    sysProcessAssetUploads(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 1096,
    });
    try std.testing.expect(state.pending_gpu_upload.isActive());
    state.cancelPendingGpuUploadForKey(key3);
    try std.testing.expect(!state.pending_gpu_upload.isActive());

    // Verify conversion_time_ms == null fails cleanly without leaking texture
    const surf2 =
        sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse return;
    const started = gpu.beginAsyncUpload(
        io,
        dev,
        .{ .owned_by_worker = surf2 },
        null,
        &state.upload_staging,
    ).?;
    var job2 = started.job;
    _ = job2.executeStagingCopy(io);
    try std.testing.expect(
        gpu.finishAsyncUpload(io, dev, started.prepared, null) == null,
    );
}
