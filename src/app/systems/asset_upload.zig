const app_state = @import("../state.zig");
const context = @import("context.zig");
const core = @import("core");
const gpu = @import("gpu");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;
const image = core.image;
const ImageCacheKey = image.ImageCacheKey;
const uploadSurfaceToGpu = gpu.uploadSurfaceToGpu;

/// System Pass: Uploads decoded CPU surfaces in cache slots to GPU textures.
pub fn sysProcessAssetUploads(ctx: FrameContext) void {
    const state = ctx.state;
    state.updateCurrentRotation();
    prepareCacheTextures(state, ctx.now_ms);
}

fn ensureCurrentThumbnailLoaded(state: *AppState) void {
    const cur_id = state.viewer.navigation.getCurrentMediaId() orelse return;
    const key = state.cache.activeKey(cur_id);
    const cur = state.cache.getEntry(key) orelse return;
    if (cur.resident.thumbnail == .loaded or
        cur.resident.thumbnail == .not_available) return;

    const media = state.viewer.navigation.getCurrentImageEntry() orelse {
        if (state.cache.get(key)) |e| e.resident.thumbnail = .not_available;
        return;
    };
    const extracted = image.loadThumbnailSurface(
        state.io,
        state.allocator,
        media,
    ) orelse {
        if (state.cache.get(key)) |e| e.resident.thumbnail = .not_available;
        return;
    };
    defer extracted.surface.destroy();

    const dev = state.gpu_device orelse return;
    const upload_res = uploadSurfaceToGpu(
        dev,
        extracted.surface,
        state.unpack_compute_pipeline,
        &state.upload_staging,
    ) orelse {
        if (state.cache.get(key)) |e| e.resident.thumbnail = .not_available;
        return;
    };

    {
        const e = state.cache.get(key) orelse {
            dev.releaseTexture(upload_res.gpu_texture);
            return;
        };
        switch (e.resident.thumbnail) {
            .loaded => |thumb| dev.releaseTexture(thumb.texture),
            .none, .pending, .not_available, .unloaded => {},
        }

        e.applyProbedMetadata(
            extracted.source_dims,
            extracted.orientation,
            extracted.raw_metadata,
        );

        e.resident.thumbnail = .{
            .loaded = .{
                .texture = upload_res.gpu_texture,
                .info = .{
                    .w = upload_res.w,
                    .h = upload_res.h,
                    .upload_time_ms = upload_res.ingest.upload_time_ms,
                    .dct_snapped = extracted.dct_snapped,
                },
            },
        };
    }
    state.updateCurrentRotation();
}

fn prepareCacheTextures(state: *AppState, now_ms: u64) void {
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
            if (!is_crossfading and
                entry.resident.asset == .loaded_gpu and
                !state.viewer.ui.overlays.debug_show_thumb)
            {
                switch (entry.resident.thumbnail) {
                    .loaded => |thumb| {
                        if (state.gpu_device) |gpu_dev| {
                            gpu_dev.releaseTexture(thumb.texture);
                        }
                        entry.resident.thumbnail = .{
                            .unloaded = thumb.info,
                        };
                    },
                    .none, .pending, .not_available, .unloaded => {},
                }
            }
        }
    }

    if (state.gpu_device == null) return;

    var upload_target: ?struct {
        key: ImageCacheKey,
        cpu: image.CpuSurfaceComponent,
    } = null;

    if (state.viewer.ui.overlays.debug_show_thumb) {
        if (state.getCurrentEntry()) |cur_e| {
            if (cur_e.resident.thumbnail != .loaded and
                cur_e.resident.thumbnail != .not_available)
            {
                ensureCurrentThumbnailLoaded(state);
            }
        }
    }

    const cur_id_opt = state.viewer.navigation.getCurrentMediaId();
    const cur_key_opt = if (cur_id_opt) |ci|
        state.cache.activeKey(ci)
    else
        null;
    const cur_entry_opt = if (cur_key_opt) |ck|
        state.cache.get(ck)
    else
        null;

    var can_upload_neighbors = true;
    if (cur_entry_opt) |cur_entry| {
        switch (cur_entry.resident.asset) {
            .loaded_gpu, .failed => {
                can_upload_neighbors = true;
            },
            .loaded_cpu => |cpu| {
                cur_entry.inflight = .{
                    .stage = .uploading,
                    .start_time_ms = now_ms,
                };
                upload_target = .{
                    .key = cur_key_opt.?,
                    .cpu = cpu,
                };
                cur_entry.resident.asset = .none;
                can_upload_neighbors = false;
            },
            .none => {
                can_upload_neighbors = false;
            },
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
            if (entry.resident.asset != .loaded_cpu) continue;
            const pos = state.viewer.navigation.posOfId(key.id) orelse
                continue;
            const dist = blk: {
                if (neighbors_opt) |neighbors| {
                    break :blk neighbors.stepDistance(pos) orelse
                        (3 + image.calcCyclicDistance(
                            pos,
                            neighbors.current,
                            total_items,
                        ));
                } else if (state.viewer.navigation.current_index) |cur| {
                    break :blk image.calcCyclicDistance(
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
            const entry = &entries[bi];
            switch (entry.resident.asset) {
                .loaded_cpu => |cpu| {
                    entry.inflight = .{
                        .stage = .uploading,
                        .start_time_ms = now_ms,
                    };
                    upload_target = .{
                        .key = keys[bi],
                        .cpu = cpu,
                    };
                    entry.resident.asset = .none;
                },
                .loaded_gpu, .none, .failed => {},
            }
        }
    }

    if (upload_target) |target| {
        defer {
            target.cpu.surface.destroy();
            if (state.workers.active_decode_threads.load(.acquire) == 0) {
                sdl.reclaimProcessHeap();
            }
        }
        if (state.gpu_device) |gpu_dev| {
            if (uploadSurfaceToGpu(
                gpu_dev,
                target.cpu.surface,
                state.unpack_compute_pipeline,
                &state.upload_staging,
            )) |res| {
                const loaded_gpu_asset = image.ResidentAsset{
                    .loaded_gpu = .{
                        .gpu_texture = res.gpu_texture,
                        .w = res.w,
                        .h = res.h,
                        .size_bytes = target.cpu.size_bytes,
                        .mime_type = target.cpu.mime_type,
                        .decode = target.cpu.decode,
                        .ingest = res.ingest,
                    },
                };
                if (state.cache.get(target.key)) |entry| {
                    entry.resident.asset.replaceGpuTexture(
                        loaded_gpu_asset.loaded_gpu,
                        gpu_dev,
                    );
                    entry.inflight = null;
                    state.cache.enforceVramBudget(
                        gpu_dev,
                        &state.viewer.navigation,
                        state.viewer.navigation.getVisibleNeighbors(),
                        state.viewer.getTransitionPrevIndex(),
                        state.viewer.navigation.count(),
                        image.ImageCache.DEFAULT_MAX_VRAM_BYTES,
                    );
                    checkLoadedGpuCrossfade(state, target.key);
                } else {
                    gpu_dev.releaseTexture(res.gpu_texture);
                }
            } else {
                handleGpuUploadFailure(state, target.key);
            }
        }
    }
}

fn checkLoadedGpuCrossfade(
    state: *AppState,
    target_key: ImageCacheKey,
) void {
    const cur_id = state.viewer.navigation.getCurrentMediaId() orelse return;
    if (target_key.id != cur_id) return;
    const entry = state.cache.get(target_key) orelse return;

    const can_crossfade = entry.resident.thumbnail == .loaded and
        !state.viewer.ui.overlays.debug_show_thumb and
        !state.viewer.isSlideshowActive() and
        state.viewer.image_transition == .none;
    if (can_crossfade) {
        state.viewer.animations.startFrom(
            .thumb_crossfade,
            0.0,
            1.0,
            state_pkg.DURATION_THUMB_CROSSFADE_MS,
            .ease_out_quad,
        );
    }
    if (state.viewer.image_transition != .none) {
        if (state.viewer.animations.get(.image_crossfade) < 0.001) {
            state.viewer.animations.startFrom(
                .image_crossfade,
                0.0,
                1.0,
                state_pkg.DURATION_IMAGE_DISSOLVE_MS,
                .ease_in_out_cubic,
            );
        }
    }
}

fn handleGpuUploadFailure(state: *AppState, target_key: ImageCacheKey) void {
    state.cache.setResidentAsset(target_key, .failed, state.gpu_device);
    state.cache.setInFlight(target_key, null);
    const cur_id = state.viewer.navigation.getCurrentMediaId() orelse return;
    if (target_key.id == cur_id) {
        state.viewer.image_transition = .none;
        state.viewer.animations.setImmediate(.image_crossfade, 1.0);
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
    prepareCacheTextures(&state, 1000);
    var entry = state.cache.get(state.cache.activeKey(id0)).?;
    try std.testing.expect(entry.resident.thumbnail == .loaded);

    // Case 2: thumb_crossfade settles -> prepareCacheTextures evicts thumbnail
    state.viewer.animations.settle(.thumb_crossfade);
    prepareCacheTextures(&state, 1000);
    entry = state.cache.get(state.cache.activeKey(id0)).?;
    try std.testing.expect(entry.resident.thumbnail == .unloaded);
}

test "prepareCacheTextures - uploads loaded_cpu without double free" {
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
                    .surface = surf,
                    .w = 64.0,
                    .h = 64.0,
                    .size_bytes = 64 * 64 * 4,
                },
            },
        },
    });

    prepareCacheTextures(&state, 1000);

    // Verify upload transitioned to loaded_gpu and inflight is cleared
    const entry = state.cache.get(key).?;
    try std.testing.expect(entry.resident.asset == .loaded_gpu);
    try std.testing.expect(entry.inflight == null);
}
