const app_state = @import("state.zig");
const events = @import("core/events.zig");
const image = @import("core/image.zig");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const MediaEntry = state_pkg.MediaEntry;
const MediaId = state_pkg.types.MediaId;
const Orientation = state_pkg.Orientation;

/// Drains all background thread events (e.g. image decodes, thumbnail extractions,
/// directory scans, folder count updates, and IPC commands) from `workers.event_queue`.
/// Dispatches each event to update texture cache entries, image lists, rotation maps,
/// and Command Palette state.
/// Returns `true` if at least one event was drained and processed; otherwise `false`.
pub fn drainWorkerEvents(state: *AppState) bool {
    state.event_batch.clearRetainingCapacity();
    state.workers.event_queue.drain(state.allocator, state.io, &state.event_batch) catch |err| {
        std.log.err("Failed to drain worker event queue: {}", .{err});
        return false;
    };
    if (state.event_batch.items.len == 0) return false;

    var destroyed_full_surface = state.viewer.display.isHidden();
    for (state.event_batch.items, 0..) |*evt, evt_idx| {
        defer evt.deinit(state.allocator);

        switch (evt.*) {
            .exif_orientation_parsed => |*e| if (e.resolve(&state.cache)) |r| {
                if (state.cache.get(r.key)) |entry| {
                    entry.orientation = r.payload.orientation;
                }
                state.updateCurrentRotation();
            },
            .dimensions_probed => |*d| if (d.resolve(&state.cache)) |r| {
                handleDimensionsProbedEvent(state, r.key, r.payload.*);
            },
            .thumb_decoded => |*t| {
                if (t.resolve(&state.cache)) |r| {
                    const skip_upload = hasSubsequentImageDecoded(
                        state.event_batch.items[evt_idx + 1 ..],
                        r.key,
                    );
                    handleExifThumbnailEvent(
                        state,
                        r.key,
                        r.payload.*,
                        skip_upload,
                    );
                }
            },
            .image_decoded => |*d| {
                if (d.resolve(&state.cache)) |r| {
                    handleImageDecodedEvent(state, r.key, r.payload);
                    if (r.payload.surface != null) {
                        destroyed_full_surface = true;
                    }
                } else {
                    destroyed_full_surface = true;
                }
            },
            .decode_failed => |*f| if (f.resolve(&state.cache)) |r| {
                const is_current =
                    if (state.viewer.navigation.getCurrentMediaId()) |cur_id|
                        r.key.id == cur_id
                    else
                        false;
                handleDecodeFailedEvent(state, r.key, is_current);
            },
            .path_discovered => |p| {
                if (!state.viewer.display.isHidden()) {
                    handleDirScannedEvent(state, p);
                }
            },
            .directory_scan_result => |res| {
                if (res.resolve(&state.cache.generation)) |payload| {
                    handleDirectoryScanResultEvent(state, payload);
                }
            },
            .palette_folder_count => |cnt| {
                const active_gen = &state.viewer.ui.palette.dir_scan_generation;
                if (cnt.resolve(active_gen)) |payload| {
                    handlePaletteFolderCountEvent(state, payload);
                }
            },
            .precache_completed => |res| {
                const active_gen = &state.workers.precache_generation;
                if (res.resolve(active_gen)) |payload| {
                    handlePrecacheCompletedEvent(state, payload);
                }
            },
            .ipc_command => |cmd_data| handleIpcCommandEvent(state, cmd_data),
        }
    }
    if (destroyed_full_surface and
        (state.viewer.display.isHidden() or
            state.workers.active_decode_threads.load(.acquire) == 0))
    {
        sdl.reclaimProcessHeap();
    }
    return true;
}

fn handleDecodeFailedEvent(
    state: *AppState,
    key: image.ImageCacheKey,
    is_current: bool,
) void {
    const entry = state.cache.get(key) orelse return;
    entry.is_promoting = false;
    if (entry.status != .loaded_gpu and entry.status != .loaded_cpu) {
        entry.status = .failed;
        if (is_current) {
            state.viewer.image_transition = .none;
            state.viewer.animations.setImmediate(.image_crossfade, 1.0);
        }
    }
    if (entry.thumbnail == .pending or entry.thumbnail == .none) {
        entry.thumbnail = .not_available;
    }
}

fn handlePaletteFolderCountEvent(
    state: *AppState,
    cnt: events.PaletteFolderCountPayload,
) void {
    for (state.viewer.ui.palette.dir_items.items) |*item| {
        if (!std.mem.eql(u8, item.getFullPath(), cnt.path)) continue;

        switch (item.*) {
            .directory => |*d| d.scan = cnt.scan,
            .archive_file => |*a| a.scan = cnt.scan,
            .parent, .image_file => {},
        }
        state.viewer.ui.palette.selection_dirty = true;
        break;
    }
}

fn handlePrecacheCompletedEvent(
    state: *AppState,
    res: events.PrecacheCompletedPayload,
) void {
    if (!state.viewer.ui.snackbar.enabled) return;

    var buf: [state_pkg.snackbar.MAX_SNACKBAR_LEN]u8 = undefined;
    const msg = if (res.written > 0 and res.already_valid > 0)
        std.mem.print(
            &buf,
            "Pre-cached {d} thumbnails ({d} already cached)",
            .{ res.written, res.already_valid },
        ) catch return
    else if (res.written > 0)
        std.mem.print(
            &buf,
            "Pre-cached {d} thumbnails",
            .{res.written},
        ) catch return
    else if (res.already_valid > 0)
        std.mem.print(
            &buf,
            "All {d} thumbnails already cached",
            .{res.already_valid},
        ) catch return
    else
        "Thumbnail pre-cache finished";

    const now = sdl.timer.getTicks();
    state.viewer.ui.snackbar.show(msg, now + 2000);
    const progress = state.viewer.animations.get(.snackbar);
    const dur = @max(
        state_pkg.DURATION_SNACKBAR_OPEN_MS * (1.0 - progress),
        30.0,
    );
    state.viewer.animations.start(.snackbar, 1.0, dur, .ease_out_quad);
}

fn handleIpcCommandEvent(state: *AppState, cmd_data: *ipc.IpcCommandData) void {
    state.pending_ipc_commands.append(state.allocator, cmd_data) catch |err| {
        std.log.err("Failed to append IPC command to pending list: {}", .{err});
        cmd_data.client_stream.close(state.io);
        state.allocator.free(cmd_data.command);
        state.allocator.destroy(cmd_data);
    };
}

fn handleDimensionsProbedEvent(
    state: *AppState,
    key: image.ImageCacheKey,
    probed: events.DimensionsProbedPayload,
) void {
    {
        const entry = state.cache.get(key) orelse return;
        entry.applyProbedMetadata(
            probed.source_dims,
            probed.orientation,
            probed.raw_metadata,
        );
        if (probed.thumb_only) {
            switch (entry.status) {
                .decoding => |*dec| dec.has_thread = false,
                .loaded_cpu, .loaded_gpu, .uploading, .failed => {},
            }
        }
        if (entry.thumbnail == .none or entry.thumbnail == .pending) {
            entry.thumbnail = .not_available;
        }
    }
    state.updateCurrentRotation();
}

fn hasSubsequentImageDecoded(
    remaining: []const events.BackgroundEvent,
    key: image.ImageCacheKey,
) bool {
    for (remaining) |*evt| {
        switch (evt.*) {
            .image_decoded => |*d| {
                if (d.key.eql(key)) {
                    return true;
                }
            },
            .exif_orientation_parsed,
            .dimensions_probed,
            .thumb_decoded,
            .decode_failed,
            .path_discovered,
            .directory_scan_result,
            .palette_folder_count,
            .precache_completed,
            .ipc_command,
            => {},
        }
    }
    return false;
}

fn handleExifThumbnailEvent(
    state: *AppState,
    key: image.ImageCacheKey,
    thumb_data: events.ThumbDecodedPayload,
    skip_gpu_upload: bool,
) void {
    const already_loaded = blk: {
        const entry = state.cache.get(key) orelse return;
        entry.applyProbedMetadata(
            thumb_data.source_dims,
            thumb_data.orientation,
            thumb_data.raw_metadata,
        );
        if (thumb_data.thumb_only) {
            switch (entry.status) {
                .decoding => |*dec| dec.has_thread = false,
                .loaded_cpu, .loaded_gpu, .uploading, .failed => {},
            }
        }
        break :blk entry.status == .loaded_gpu or entry.status == .loaded_cpu;
    };
    state.updateCurrentRotation();
    if (skip_gpu_upload or already_loaded) {
        return;
    }

    const surf = thumb_data.surface;
    if (state.gpu_device) |gpu_dev| {
        if (image.uploadSurfaceToGpu(
            gpu_dev,
            surf,
            state.unpack_compute_pipeline,
            &state.upload_staging,
        )) |upload_res| {
            const entry = state.cache.get(key) orelse {
                gpu_dev.releaseTexture(upload_res.gpu_texture);
                return;
            };
            switch (entry.thumbnail) {
                .loaded => |old_thumb| {
                    gpu_dev.releaseTexture(old_thumb.texture);
                },
                .none, .pending, .not_available, .unloaded => {},
            }
            entry.thumbnail = .{
                .loaded = .{
                    .texture = upload_res.gpu_texture,
                    .info = .{
                        .w = upload_res.w,
                        .h = upload_res.h,
                        .upload_time_ms = upload_res.upload_time_ms,
                        .dct_snapped = thumb_data.dct_snapped,
                        .source = thumb_data.source,
                    },
                },
            };
            state.updateCurrentRotation();
        } else {
            if (state.cache.get(key)) |entry| {
                if (entry.thumbnail == .none or entry.thumbnail == .pending) {
                    entry.thumbnail = .not_available;
                }
            }
        }
    } else {
        if (state.cache.get(key)) |entry| {
            if (entry.thumbnail == .none or entry.thumbnail == .pending) {
                entry.thumbnail = .not_available;
            }
        }
    }
}

fn enqueueDecodedThumbWrite(
    state: *AppState,
    key: image.ImageCacheKey,
    decoded_data: *const events.ImageDecodedPayload,
    mtime_sec: i64,
    surf: sdl.Surface,
) bool {
    if (state.workers.thumb_cache_config == .disabled) return false;
    const entry = state.cache.getEntry(key) orelse return false;
    const media = state.viewer.navigation.getMediaEntryById(key.id) orelse
        return false;
    const path_slice: []const u8 = switch (media) {
        .archive_entry => return false,
        .filesystem => |f| f.path,
        .pair => |p| if (entry.raw_metadata.isRaw())
            p.raw_path
        else
            p.jpeg_path,
    };
    const owned_path = state.allocator.dupe(u8, path_slice) catch return false;
    const auth = entry.getAuthoritativeDims();
    const source_dims =
        state_pkg.PhysicalDims.initPositive(auth.w, auth.h) orelse
        decoded_data.source_dims orelse
        state_pkg.PhysicalDims.initPositive(decoded_data.w, decoded_data.h);

    state.workers.enqueueThumbWrite(state.allocator, state.io, .{
        .surface = surf,
        .source_path = owned_path,
        .mime_type = decoded_data.mime_type,
        .file_size = decoded_data.size_bytes,
        .mtime_sec = mtime_sec,
        .orientation = decoded_data.orientation,
        .source_dims = source_dims,
    });
    return true;
}

fn handleImageDecodedEvent(
    state: *AppState,
    key: image.ImageCacheKey,
    decoded_data: *events.ImageDecodedPayload,
) void {
    const surf = decoded_data.surface orelse return;

    const is_current =
        if (state.viewer.navigation.getCurrentMediaId()) |cur_id|
            key.id == cur_id
        else
            true;

    // Check if the current image is already loaded on GPU (or failed)
    const is_current_ready = blk: {
        const cur_id = state.viewer.navigation.getCurrentMediaId() orelse
            break :blk true;
        const cur_key = state.cache.activeKey(cur_id);
        if (state.cache.getEntry(cur_key)) |cur_entry| {
            break :blk switch (cur_entry.status) {
                .loaded_gpu, .failed => true,
                .loaded_cpu, .decoding, .uploading => false,
            };
        }
        break :blk false;
    };

    // Demand-first GPU upload gating:
    // Only upload immediately to the GPU if this IS the active image, OR if the active
    // image is already on the GPU. If a neighbor decode finishes while the active image
    // is still decoding or uploading, keep the neighbor in RAM (.loaded_cpu) to preserve
    // 100% of PCIe bus bandwidth and GPU mipmap downsampling for the active image.
    const should_upload_gpu = (state.gpu_device != null) and
        (is_current or is_current_ready);

    if (should_upload_gpu) {
        const gpu_dev = state.gpu_device.?;
        if (image.uploadSurfaceToGpu(
            gpu_dev,
            surf,
            state.unpack_compute_pipeline,
            &state.upload_staging,
        )) |full_res| {
            completeDecodedGpuUpload(
                state,
                key,
                decoded_data,
                surf,
                full_res,
                is_current,
                gpu_dev,
                image.ImageCache.DEFAULT_MAX_VRAM_BYTES,
            );
        } else {
            std.log.err(
                "handleImageDecodedEvent: failed to upload surface to GPU for key {any}",
                .{key},
            );
            handleDecodeFailedEvent(state, key, is_current);
        }
    } else {
        {
            const entry = state.cache.get(key) orelse return;
            switch (entry.status) {
                .loaded_cpu => |cpu| cpu.surface.destroy(),
                .loaded_gpu => |gpu| {
                    if (state.gpu_device) |gpu_dev| {
                        gpu_dev.releaseTexture(gpu.gpu_texture);
                    }
                },
                .decoding, .uploading, .failed => {},
            }
            applyDecodedMetadata(entry, decoded_data);
            if (entry.thumbnail == .pending or entry.thumbnail == .none) {
                entry.thumbnail = .not_available;
            }
            const cbz_ms = decoded_data.cbz_decompress_time_ms;
            const comp_bytes = decoded_data.compressed_size_bytes;
            entry.status = .{
                .loaded_cpu = .{
                    .surface = decoded_data.surface.?,
                    .w = decoded_data.w,
                    .h = decoded_data.h,
                    .size_bytes = decoded_data.size_bytes,
                    .mime_type = decoded_data.mime_type,
                    .read_time_ms = decoded_data.read_time_ms,
                    .decode_time_ms = decoded_data.decode_time_ms,
                    .conversion_time_ms = decoded_data.conversion_time_ms,
                    .cbz_decompress_time_ms = cbz_ms,
                    .compressed_size_bytes = comp_bytes,
                },
            };
            decoded_data.surface = null;
        }
        state.updateCurrentRotation();
        if (decoded_data.thumb_write_mtime_sec) |mtime_sec| {
            if (surf.scale(surf.w(), surf.h(), .nearest)) |cloned| {
                if (!enqueueDecodedThumbWrite(
                    state,
                    key,
                    decoded_data,
                    mtime_sec,
                    cloned,
                )) {
                    cloned.destroy();
                }
            }
        }
    }
}

fn applyDecodedMetadata(
    entry: *state_pkg.CacheEntry,
    decoded_data: *const events.ImageDecodedPayload,
) void {
    entry.orientation = decoded_data.orientation;
    entry.is_promoting = false;
    if (decoded_data.raw_metadata.getSensorDims()) |s_dims| {
        entry.updateFullDims(s_dims.w, s_dims.h);
    }
    if (decoded_data.source_dims) |s_dims| {
        entry.updateFullDims(s_dims.w, s_dims.h);
    }
    entry.updateFullDims(decoded_data.w, decoded_data.h);
    entry.raw_metadata = if (decoded_data.raw_metadata.isRaw())
        if (entry.full_dims) |fd|
            state_pkg.RawMetadata.init(fd.w, fd.h)
        else
            decoded_data.raw_metadata
    else
        .none;
}

fn triggerDecodedGpuCrossfades(
    state: *AppState,
    is_current: bool,
    key: image.ImageCacheKey,
) void {
    if (!is_current) return;
    const entry = state.cache.getEntry(key) orelse return;

    const can_crossfade = entry.thumbnail == .loaded and
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

fn applyDecodedGpuTexture(
    state: *AppState,
    key: image.ImageCacheKey,
    decoded_data: *events.ImageDecodedPayload,
    full_res: image.GpuUploadResult,
    is_current: bool,
    gpu_dev: ?sdl.gpu.Device,
) bool {
    const was_loaded_gpu = blk: {
        const entry = state.cache.get(key) orelse {
            if (gpu_dev) |dev| dev.releaseTexture(full_res.gpu_texture);
            return false;
        };
        const prev_gpu = entry.status == .loaded_gpu;
        switch (entry.status) {
            .loaded_cpu => |cpu| cpu.surface.destroy(),
            .loaded_gpu => |gpu| if (gpu_dev) |dev| {
                dev.releaseTexture(gpu.gpu_texture);
            },
            .decoding, .uploading, .failed => {},
        }
        applyDecodedMetadata(entry, decoded_data);
        entry.status = .{
            .loaded_gpu = .{
                .gpu_texture = full_res.gpu_texture,
                .w = full_res.w,
                .h = full_res.h,
                .size_bytes = decoded_data.size_bytes,
                .mime_type = decoded_data.mime_type,
                .read_time_ms = decoded_data.read_time_ms,
                .decode_time_ms = decoded_data.decode_time_ms,
                .conversion_time_ms = full_res.conversion_time_ms,
                .upload_time_ms = full_res.upload_time_ms,
                .memory_size_bytes = full_res.memory_size_bytes,
                .num_mip_levels = full_res.num_mip_levels,
                .mipmap_time_ms = full_res.mipmap_time_ms,
                .was_fallback = full_res.was_fallback,
                .fallback_time_ms = full_res.fallback_time_ms,
                .cbz_decompress_time_ms = decoded_data.cbz_decompress_time_ms,
                .compressed_size_bytes = decoded_data.compressed_size_bytes,
            },
        };
        if (entry.thumbnail == .pending or entry.thumbnail == .none) {
            entry.thumbnail = .not_available;
        }
        break :blk prev_gpu;
    };
    if (!was_loaded_gpu) {
        triggerDecodedGpuCrossfades(state, is_current, key);
    }
    return true;
}

fn completeDecodedGpuUpload(
    state: *AppState,
    key: image.ImageCacheKey,
    decoded_data: *events.ImageDecodedPayload,
    surf: sdl.Surface,
    full_res: image.GpuUploadResult,
    is_current: bool,
    gpu_dev: ?sdl.gpu.Device,
    max_vram_bytes: usize,
) void {
    if (!applyDecodedGpuTexture(
        state,
        key,
        decoded_data,
        full_res,
        is_current,
        gpu_dev,
    )) return;
    state.updateCurrentRotation();
    state.cache.enforceVramBudget(
        gpu_dev,
        &state.viewer.navigation,
        state.viewer.navigation.getVisibleNeighbors(),
        state.viewer.getTransitionPrevIndex(),
        state.viewer.navigation.count(),
        max_vram_bytes,
    );
    if (decoded_data.thumb_write_mtime_sec) |mtime_sec| {
        if (enqueueDecodedThumbWrite(
            state,
            key,
            decoded_data,
            mtime_sec,
            surf,
        )) {
            decoded_data.surface = null;
        }
    }
}

fn handleDirScannedEvent(state: *AppState, scanned_data: events.PathDiscoveredPayload) void {
    const dup = scanned_data.entry.dupe(
        state.viewer.navigation.directory_arena.allocator(),
    ) catch |err| {
        std.log.err("Failed to duplicate path in directory arena: {}", .{err});
        return;
    };
    _ = state.viewer.navigation.appendEntry(
        state.allocator,
        dup,
    ) catch |err| {
        std.log.err(
            "Failed to append discovered path to image_list: {}",
            .{err},
        );
    };
    if (state.viewer.navigation.current_index == null and
        state.viewer.navigation.count() > 0)
    {
        _ = state.viewer.navigation.adjustIndexForVisibility();
    }
    syncActiveFilePaletteMatches(state);
}

fn syncActiveFilePaletteMatches(state: *AppState) void {
    if (state.viewer.ui.palette.mode == .files and
        !state.viewer.ui.palette.is_closing)
    {
        state.rebuildPaletteMatches() catch |err| {
            std.log.err("Failed to rebuild palette file matches: {}", .{err});
        };
    }
}

fn handleDirectoryScanResultEvent(
    state: *AppState,
    result_data: events.DirectoryScanResultPayload,
) void {
    const arena_alloc = state.viewer.navigation.directory_arena.allocator();
    if (result_data.is_dir) {
        for (result_data.paths) |item| {
            const dup = item.dupe(arena_alloc) catch |err| {
                std.log.err("Failed to duplicate directory item: {}", .{err});
                continue;
            };
            _ = state.viewer.navigation.appendEntry(
                state.allocator,
                dup,
            ) catch |err| {
                std.log.err("Failed to append image to list: {}", .{err});
            };
        }
        if (state.viewer.navigation.current_index == null and
            state.viewer.navigation.count() > 0)
        {
            _ = state.viewer.navigation.adjustIndexForVisibility();
        }
    } else {
        const had_single_fs = state.viewer.navigation.count() == 1 and
            if (state.viewer.navigation.getMediaEntry(0)) |e|
                e == .filesystem
            else
                false;
        const initial_target_id = if (had_single_fs)
            state.viewer.navigation.getIdAt(0)
        else
            null;

        var target_idx_in_dir: ?usize = null;
        _ = state.viewer.navigation.directory_arena.reset(.retain_capacity);
        state.viewer.navigation.clearEntries();
        for (result_data.paths) |item| {
            const dup = item.dupe(arena_alloc) catch |err| {
                std.log.err("Failed to duplicate directory item: {}", .{err});
                continue;
            };
            const is_target = target_idx_in_dir == null and
                item.matchesTarget(result_data.target_path);
            if (is_target and initial_target_id != null) {
                state.viewer.navigation.appendEntryWithId(
                    state.allocator,
                    initial_target_id.?,
                    dup,
                ) catch |err| {
                    std.log.err("Failed to append image to list: {}", .{err});
                    continue;
                };
            } else {
                _ = state.viewer.navigation.appendEntry(
                    state.allocator,
                    dup,
                ) catch |err| {
                    std.log.err("Failed to append image to list: {}", .{err});
                    continue;
                };
            }
            if (is_target) {
                target_idx_in_dir = state.viewer.navigation.count() - 1;
            }
        }

        if (target_idx_in_dir) |target_i| {
            _ = state.viewer.navigation.goToIndex(target_i);
        } else {
            _ = state.viewer.navigation.adjustIndexForVisibility();
        }
    }
    syncActiveFilePaletteMatches(state);
}

test "drainWorkerEvents - empty queue" {
    const allocator = std.testing.allocator;
    var state = try AppState.initHeadless(allocator, std.Io.Threaded.global_single_threaded.io());
    defer state.deinit();

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(!processed);
}

test "drainWorkerEvents - path_discovered" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const path_dup = try allocator.dupe(u8, "/test/path.jpg");
    try state.workers.event_queue.push(allocator, io, .{
        .path_discovered = .{ .entry = .{ .filesystem = .{ .path = path_dup } } },
    });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.navigation.count());
    try std.testing.expectEqual(@as(?usize, 0), state.viewer.navigation.current_index);
}

test "drainWorkerEvents - exif_orientation_parsed & decode_failed" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const id0 = MediaId.fromU32(1);
    _ = try state.cache.appendSlot(allocator, id0, .{
        .decoding = .{ .has_thread = true },
    });

    try state.workers.event_queue.push(allocator, io, .{
        .exif_orientation_parsed = .init(
            state.cache.activeKey(id0),
            .{ .orientation = .rotate_90 },
        ),
    });
    const processed1 = drainWorkerEvents(&state);
    try std.testing.expect(processed1);
    try std.testing.expectEqual(
        Orientation.rotate_90,
        state.cache.slots.items(.entry)[0].orientation,
    );

    try state.workers.event_queue.push(allocator, io, .{
        .decode_failed = .init(state.cache.activeKey(id0), .{}),
    });
    const processed2 = drainWorkerEvents(&state);
    try std.testing.expect(processed2);
    const fail_status = state.cache.slots.items(.entry)[0].status;
    try std.testing.expectEqual(@as(@TypeOf(fail_status), .failed), fail_status);
}

test "drainWorkerEvents - directory_scan_result and ipc_command" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const target_path = try allocator.dupe(u8, "/imgs/b.jpg");
    const path0 = try allocator.dupe(u8, "/imgs/a.jpg");
    const path1 = try allocator.dupe(u8, "/imgs/b.jpg");
    const paths_slice = try allocator.alloc(MediaEntry, 2);
    paths_slice[0] = .{ .filesystem = .{ .path = path0 } };
    paths_slice[1] = .{ .filesystem = .{ .path = path1 } };

    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(0, .{
            .target_path = target_path,
            .is_dir = false,
            .paths = paths_slice,
        }),
    });

    const cmd_str = try allocator.dupe(u8, "next");
    const cmd_data = try allocator.create(ipc.IpcCommandData);
    cmd_data.* = .{ .command = cmd_str, .client_stream = undefined };
    try state.workers.event_queue.push(allocator, io, .{ .ipc_command = cmd_data });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.navigation.count());
    try std.testing.expectEqual(@as(?usize, 1), state.viewer.navigation.current_index);
    try std.testing.expectEqual(@as(usize, 1), state.pending_ipc_commands.items.len);

    const popped_cmd = state.pending_ipc_commands.pop().?;
    allocator.free(popped_cmd.command);
    allocator.destroy(popped_cmd);
}

test "drainWorkerEvents - neighbor image_decoded stays loaded_cpu while current is decoding" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Set up navigation with current_index = 0
    state.viewer.navigation.current_index = 0;
    const id0 = MediaId.fromU32(1);
    const id1 = MediaId.fromU32(2);

    // Slot 0 is decoding
    _ = try state.cache.appendSlot(allocator, id0, .{
        .decoding = .{ .has_thread = true },
    });

    // Slot 1 is decoding
    _ = try state.cache.appendSlot(allocator, id1, .{
        .decoding = .{ .has_thread = true },
    });

    const surf = sdl.Surface.create(
        10,
        10,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;

    // Neighbor index 1 finishes decoding before index 0
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(state.cache.activeKey(id1), .{
            .surface = surf,
            .w = 10,
            .h = 10,
            .mime_type = "image/png",
            .size_bytes = 100,
            .read_time_ms = 1.0,
            .decode_time_ms = 2.0,
            .conversion_time_ms = 0.0,
            .orientation = .normal,
        }),
    });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);

    // Slot 1 should be .loaded_cpu (not uploaded or destroyed) because current
    // slot 0 was not yet loaded
    const entry1 = state.cache.get(state.cache.activeKey(id1)).?;
    try std.testing.expect(entry1.status == .loaded_cpu);
}

test "drainWorkerEvents - dimensions_probed sets dimensions and clears has_thread" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const id0 = MediaId.fromU32(1);
    _ = try state.cache.appendSlot(allocator, id0, .{
        .decoding = .{ .has_thread = true },
    });

    try state.workers.event_queue.push(allocator, io, .{
        .dimensions_probed = .init(state.cache.activeKey(id0), .{
            .source_dims = .{ .w = 1920.0, .h = 1080.0 },
            .orientation = .normal,
            .thumb_only = true,
        }),
    });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);

    const entry = state.cache.get(state.cache.activeKey(id0)).?;
    try std.testing.expectEqual(
        state_pkg.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        entry.full_dims.?,
    );
    switch (entry.status) {
        .decoding => |dec| try std.testing.expect(!dec.has_thread),
        else => try std.testing.expect(false),
    }
}

test "drainWorkerEvents - palette_folder_count updates directory and archive entries" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.ui.palette.dir_scan_generation.store(1, .release);

    const dir_name = try allocator.dupe(u8, "folder_a");
    const dir_path = try allocator.dupe(u8, "/path/to/folder_a");
    try state.viewer.ui.palette.dir_items.append(allocator, .{
        .directory = .{
            .name = dir_name,
            .full_path = dir_path,
            .scan = .unscanned,
        },
    });

    const cbz_name = try allocator.dupe(u8, "comic.cbz");
    const cbz_path = try allocator.dupe(u8, "/path/to/comic.cbz");
    try state.viewer.ui.palette.dir_items.append(allocator, .{
        .archive_file = .{
            .name = cbz_name,
            .full_path = cbz_path,
            .scan = .unscanned,
        },
    });

    // Push event with mismatched generation (should be ignored)
    const stale_path = try allocator.dupe(u8, "/path/to/folder_a");
    try state.workers.event_queue.push(allocator, io, .{
        .palette_folder_count = .init(0, .{
            .path = stale_path,
            .scan = .{
                .scanned = .{ .image_count = 999, .subdir_count = 999 },
            },
        }),
    });

    _ = drainWorkerEvents(&state);
    try std.testing.expectEqual(
        state_pkg.EntryScanState.unscanned,
        state.viewer.ui.palette.dir_items.items[0].directory.scan,
    );

    // Push matching events for directory and archive
    const evt_dir_path = try allocator.dupe(u8, "/path/to/folder_a");
    try state.workers.event_queue.push(allocator, io, .{
        .palette_folder_count = .init(1, .{
            .path = evt_dir_path,
            .scan = .{
                .scanned = .{ .image_count = 12, .subdir_count = 3 },
            },
        }),
    });

    const evt_cbz_path = try allocator.dupe(u8, "/path/to/comic.cbz");
    try state.workers.event_queue.push(allocator, io, .{
        .palette_folder_count = .init(1, .{
            .path = evt_cbz_path,
            .scan = .{
                .scanned = .{ .image_count = 45, .subdir_count = 0 },
            },
        }),
    });

    _ = drainWorkerEvents(&state);

    try std.testing.expect(state.viewer.ui.palette.selection_dirty);
    const expected_dir_scan = state_pkg.EntryScanState{
        .scanned = .{ .image_count = 12, .subdir_count = 3 },
    };
    try std.testing.expectEqual(
        expected_dir_scan,
        state.viewer.ui.palette.dir_items.items[0].directory.scan,
    );
    const expected_archive_scan = state_pkg.EntryScanState{
        .scanned = .{ .image_count = 45, .subdir_count = 0 },
    };
    try std.testing.expectEqual(
        expected_archive_scan,
        state.viewer.ui.palette.dir_items.items[1].archive_file.scan,
    );

    // Push .permission_denied and .failed scan states
    const locked_dir_path = try allocator.dupe(u8, "/path/to/folder_a");
    try state.workers.event_queue.push(allocator, io, .{
        .palette_folder_count = .init(1, .{
            .path = locked_dir_path,
            .scan = .permission_denied,
        }),
    });
    const failed_cbz_path = try allocator.dupe(u8, "/path/to/comic.cbz");
    try state.workers.event_queue.push(allocator, io, .{
        .palette_folder_count = .init(1, .{
            .path = failed_cbz_path,
            .scan = .failed,
        }),
    });
    _ = drainWorkerEvents(&state);
    try std.testing.expectEqual(
        state_pkg.EntryScanState.permission_denied,
        state.viewer.ui.palette.dir_items.items[0].directory.scan,
    );
    try std.testing.expectEqual(
        state_pkg.EntryScanState.failed,
        state.viewer.ui.palette.dir_items.items[1].archive_file.scan,
    );
}

test "drainWorkerEvents - pair promotion preserves VRAM and loaded status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.navigation.current_index = 0;
    const id0 = MediaId.fromU32(1);
    const id1 = MediaId.fromU32(2);

    // Slot 0 is currently decoding; slot 1 is already .loaded_gpu and promoting
    _ = try state.cache.appendSlot(allocator, id0, .{
        .decoding = .{ .has_thread = true },
    });
    const key1 = try state.cache.appendSlot(allocator, id1, .{
        .loaded_gpu = .{
            .gpu_texture = .{ .ptr = @ptrFromInt(0x1000) },
            .w = 1600,
            .h = 1200,
            .size_bytes = 500_000,
            .mime_type = "image/jpeg",
            .read_time_ms = 1.0,
            .decode_time_ms = 2.0,
            .conversion_time_ms = 0.0,
            .upload_time_ms = 0.5,
            .memory_size_bytes = 8 * 1024 * 1024,
            .num_mip_levels = 1,
        },
    });
    const entry1 = state.cache.get(key1).?;
    entry1.is_promoting = true;
    try std.testing.expectEqual(
        @as(usize, 8 * 1024 * 1024),
        state.cache.getTotalVramBytes(),
    );

    // 1. If GPU upload of a promotion fails while .loaded_gpu, keep .loaded_gpu
    // and clear is_promoting instead of clobbering with .failed.
    handleDecodeFailedEvent(&state, key1, true);
    try std.testing.expect(!entry1.is_promoting);
    try std.testing.expect(entry1.status == .loaded_gpu);
    try std.testing.expectEqual(
        @as(usize, 8 * 1024 * 1024),
        state.cache.getTotalVramBytes(),
    );

    // 2. When a promotion finishes while should_upload_gpu is false, replacing
    // .loaded_gpu with .loaded_cpu clears is_promoting and drops VRAM bytes.
    entry1.is_promoting = true;
    const promoted_surf = sdl.Surface.create(
        32,
        24,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;

    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key1, .{
            .surface = promoted_surf,
            .w = 32,
            .h = 24,
            .mime_type = "image/jpeg",
            .size_bytes = 3072,
            .read_time_ms = 1.0,
            .decode_time_ms = 2.0,
            .conversion_time_ms = 0.0,
            .orientation = .normal,
        }),
    });

    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expect(!entry1.is_promoting);
    try std.testing.expect(entry1.status == .loaded_cpu);
    try std.testing.expectEqual(@as(usize, 0), state.cache.getTotalVramBytes());

    // 3. Initial decode upload failure on slot 0 transitions to .failed
    const key0 = state.cache.activeKey(id0);
    const entry0 = state.cache.get(key0).?;
    handleDecodeFailedEvent(&state, key0, true);
    try std.testing.expect(entry0.status == .failed);
}

test "drainWorkerEvents - monotonic full_dims on pair promotion" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.navigation.current_index = 0;
    const id0 = MediaId.fromU32(1);
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .decoding = .{ .has_thread = true },
    });
    const entry0 = state.cache.get(key0).?;

    // 1. Initial preview decode at 1616x1080 sets full_dims to 1616x1080
    const preview_surf = sdl.Surface.create(
        16,
        10,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, .{
            .surface = preview_surf,
            .w = 1616,
            .h = 1080,
            .mime_type = "image/jpeg",
            .size_bytes = 500_000,
            .read_time_ms = 1.0,
            .decode_time_ms = 2.0,
            .conversion_time_ms = 0.0,
            .orientation = .normal,
            .raw_metadata = state_pkg.RawMetadata.init(1616, 1080),
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        state_pkg.PhysicalDims{ .w = 1616, .h = 1080 },
        entry0.full_dims.?,
    );
    try std.testing.expect(entry0.raw_metadata.isRaw());

    // 2. Promotion to 6000x4000 standalone JPEG upgrades full_dims
    entry0.is_promoting = true;
    const full_surf = sdl.Surface.create(
        60,
        40,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, .{
            .surface = full_surf,
            .w = 6000,
            .h = 4000,
            .mime_type = "image/jpeg",
            .size_bytes = 4_000_000,
            .read_time_ms = 2.0,
            .decode_time_ms = 5.0,
            .conversion_time_ms = 0.0,
            .orientation = .normal,
            .raw_metadata = .none,
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        state_pkg.PhysicalDims{ .w = 6000, .h = 4000 },
        entry0.full_dims.?,
    );
    try std.testing.expect(!entry0.raw_metadata.isRaw());
    const auth = entry0.getAuthoritativeDims();
    try std.testing.expectEqual(@as(f32, 6000), auth.w);
    try std.testing.expectEqual(@as(f32, 4000), auth.h);

    // 3. Toggling back to 1616x1080 preview does not regress full_dims
    const toggle_surf = sdl.Surface.create(
        16,
        10,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, .{
            .surface = toggle_surf,
            .w = 1616,
            .h = 1080,
            .mime_type = "image/jpeg",
            .size_bytes = 500_000,
            .read_time_ms = 1.0,
            .decode_time_ms = 2.0,
            .conversion_time_ms = 0.0,
            .orientation = .normal,
            .raw_metadata = state_pkg.RawMetadata.init(1616, 1080),
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        state_pkg.PhysicalDims{ .w = 6000, .h = 4000 },
        entry0.full_dims.?,
    );
    try std.testing.expect(entry0.raw_metadata.isRaw());
    const toggle_auth = entry0.getAuthoritativeDims();
    try std.testing.expectEqual(@as(f32, 6000), toggle_auth.w);
    try std.testing.expectEqual(@as(f32, 4000), toggle_auth.h);
}

test "drainWorkerEvents - single-file scan remaps or invalidates slot 0" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Case 1: Initial single-file entry at 0 is already loaded; scan places it
    // at index 2 -> slot is retained with same MediaId without re-decoding.
    const arena_alloc = state.viewer.navigation.directory_arena.allocator();
    const init_p = try arena_alloc.dupe(u8, "c.jpg");
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = init_p } },
    );
    const id_c = state.viewer.navigation.getIdAt(0).?;
    state.viewer.navigation.current_index = 0;

    const surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    _ = try state.cache.appendSlot(allocator, id_c, .{
        .loaded_cpu = .{
            .surface = surf,
            .w = 16,
            .h = 16,
            .size_bytes = 1024,
        },
    });
    const gen_before = state.cache.generation.load(.acquire);

    const paths1 = try allocator.alloc(MediaEntry, 3);
    paths1[0] = .{ .filesystem = .{ .path = try allocator.dupe(u8, "a.jpg") } };
    paths1[1] = .{ .filesystem = .{ .path = try allocator.dupe(u8, "b.jpg") } };
    paths1[2] = .{ .filesystem = .{ .path = try allocator.dupe(u8, "c.jpg") } };
    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(0, .{
            .target_path = try allocator.dupe(u8, "c.jpg"),
            .is_dir = false,
            .paths = paths1,
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        @as(?usize, 2),
        state.viewer.navigation.current_index,
    );
    try std.testing.expectEqual(
        gen_before,
        state.cache.generation.load(.acquire),
    );
    try std.testing.expectEqual(id_c, state.viewer.navigation.getIdAt(2).?);
    try std.testing.expect(
        state.cache.get(state.cache.activeKey(id_c)) != null,
    );

    // Case 2: Initial single-file entry is still .decoding in-flight when
    // scan places it at index 1 -> slot retains id without advancing
    // generation or clearing cache.
    state.clearCache();
    state.viewer.navigation.clearEntries();
    const init_p2 = try arena_alloc.dupe(u8, "b.jpg");
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = init_p2 } },
    );
    const id_b = state.viewer.navigation.getIdAt(0).?;
    state.viewer.navigation.current_index = 0;
    _ = try state.cache.appendSlot(allocator, id_b, .{
        .decoding = .{ .has_thread = true },
    });

    const paths2 = try allocator.alloc(MediaEntry, 2);
    paths2[0] = .{ .filesystem = .{ .path = try allocator.dupe(u8, "a.jpg") } };
    paths2[1] = .{ .filesystem = .{ .path = try allocator.dupe(u8, "b.jpg") } };
    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(gen_before, .{
            .target_path = try allocator.dupe(u8, "b.jpg"),
            .is_dir = false,
            .paths = paths2,
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        @as(?usize, 1),
        state.viewer.navigation.current_index,
    );
    try std.testing.expectEqual(
        gen_before,
        state.cache.generation.load(.acquire),
    );
    try std.testing.expectEqual(@as(usize, 1), state.cache.count());
    try std.testing.expectEqual(id_b, state.viewer.navigation.getIdAt(1).?);
    try std.testing.expect(
        state.cache.get(state.cache.activeKey(id_b)) != null,
    );
}

test "drainWorkerEvents - discards stale directory_scan_result" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const cur_gen = state.cache.advanceGeneration();
    const stale_paths = try allocator.alloc(MediaEntry, 1);
    stale_paths[0] = .{
        .filesystem = .{ .path = try allocator.dupe(u8, "stale.jpg") },
    };
    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(cur_gen - 1, .{
            .target_path = try allocator.dupe(u8, "."),
            .is_dir = true,
            .paths = stale_paths,
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(@as(usize, 0), state.viewer.navigation.count());
}

test "drainWorkerEvents - decode_failed clears current image_transition" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, "a.jpg") } },
    );
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, "b.jpg") } },
    );
    state.viewer.navigation.current_index = 1;

    const id1 = state.viewer.navigation.getIdAt(1).?;
    const key1 = try state.cache.appendSlot(allocator, id1, .{
        .decoding = .{ .has_thread = true },
    });
    state.viewer.image_transition = .{ .active = .{
        .prev_index = 0,
        .prev_rotation = 0.0,
        .prev_zoom = 1.0,
        .prev_pan_x = 0.0,
        .prev_pan_y = 0.0,
    } };
    state.viewer.animations.setImmediate(.image_crossfade, 0.0);

    try state.workers.event_queue.push(allocator, io, .{
        .decode_failed = .init(key1, .{}),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        state_pkg.CacheStatus.failed,
        state.cache.get(key1).?.status,
    );
    try std.testing.expectEqual(
        state_pkg.ImageTransition.none,
        state.viewer.image_transition,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        state.viewer.animations.get(.image_crossfade),
        0.001,
    );
}

test "drainWorkerEvents - directory_scan_result updates open .files palette" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.openPalette(.files);
    try std.testing.expectEqual(
        @as(usize, 0),
        state.viewer.ui.palette.matches.items.len,
    );

    const items = try allocator.alloc(MediaEntry, 2);
    items[0] = .{ .filesystem = .{ .path = try allocator.dupe(u8, "a.jpg") } };
    items[1] = .{ .filesystem = .{ .path = try allocator.dupe(u8, "b.jpg") } };
    const target_dup = try allocator.dupe(u8, "/test");

    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(
            state.cache.generation.load(.acquire),
            .{
                .paths = items,
                .target_path = target_dup,
                .is_dir = true,
            },
        ),
    });

    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        @as(usize, 2),
        state.viewer.ui.palette.matches.items.len,
    );
}

test "drainWorkerEvents - ignores thumb_decoded when slot is already loaded" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const main_surf = sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32).?;
    const id0 = MediaId.fromU32(1);
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .loaded_cpu = .{
            .surface = main_surf,
            .w = 32.0,
            .h = 32.0,
            .size_bytes = 4096,
            .mime_type = "image/jpeg",
            .read_time_ms = 0.0,
            .decode_time_ms = 0.0,
            .conversion_time_ms = 0.0,
            .cbz_decompress_time_ms = 0.0,
            .compressed_size_bytes = 0,
        },
    });
    const entry = state.cache.get(key0).?;
    entry.thumbnail = .{ .unloaded = .{
        .w = 16.0,
        .h = 16.0,
        .upload_time_ms = 0.0,
        .dct_snapped = false,
    } };

    const thumb_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32).?;
    try state.workers.event_queue.push(allocator, io, .{
        .thumb_decoded = .init(key0, .{
            .surface = thumb_surf,
            .w = 16.0,
            .h = 16.0,
            .source_dims = .{ .w = 6000.0, .h = 4000.0 },
            .orientation = .rotate_90,
            .thumb_only = false,
            .dct_snapped = false,
        }),
    });

    try std.testing.expect(drainWorkerEvents(&state));
    // Metadata updates while thumbnail stays .unloaded and surface is freed
    try std.testing.expectEqual(
        state_pkg.PhysicalDims{ .w = 6000.0, .h = 4000.0 },
        entry.full_dims.?,
    );
    try std.testing.expectEqual(Orientation.rotate_90, entry.orientation);
    try std.testing.expect(entry.thumbnail == .unloaded);
}

test "DirectoryScanResultEvent - Preserves MediaId for initial target file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // 1. Single-file launch for target img_050.jpg
    const arena_alloc = state.viewer.navigation.directory_arena.allocator();
    const init_target = try arena_alloc.dupe(u8, "img_050.jpg");
    const target_id = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = init_target } },
    );
    try std.testing.expectEqual(@as(u32, 1), target_id.toU32());
    state.viewer.navigation.current_index = 0;

    const key0 = try state.cache.appendSlot(allocator, target_id, .{
        .decoding = .{ .has_thread = true },
    });
    const cur_gen = state.cache.generation.load(.acquire);

    // 2. Directory scan result returns 100 files with img_050.jpg at index 49
    const paths = try allocator.alloc(MediaEntry, 100);
    for (paths, 0..) |*p, i| {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "img_{d:0>3}.jpg", .{i + 1});
        p.* = .{ .filesystem = .{ .path = try allocator.dupe(u8, name) } };
    }

    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(cur_gen, .{
            .target_path = try allocator.dupe(u8, "img_050.jpg"),
            .is_dir = false,
            .paths = paths,
        }),
    });

    try std.testing.expect(drainWorkerEvents(&state));

    // 3. Verify single-file directory scan stability
    try std.testing.expectEqual(
        @as(?usize, 49),
        state.viewer.navigation.current_index,
    );
    try std.testing.expectEqual(
        @as(?usize, 49),
        state.viewer.navigation.posOfId(target_id),
    );
    try std.testing.expectEqual(
        target_id,
        state.viewer.navigation.getIdAt(49).?,
    );
    try std.testing.expectEqual(
        cur_gen,
        state.cache.generation.load(.acquire),
    );
    try std.testing.expectEqual(@as(usize, 1), state.cache.count());
    try std.testing.expect(state.cache.get(key0) != null);

    // 4. In-flight job resolution: a SlotBound created with key0 resolves
    const surf = sdl.Surface.create(10, 10, sdl.PixelFormat.rgba32).?;
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, .{
            .surface = surf,
            .w = 10.0,
            .h = 10.0,
            .size_bytes = 400,
            .mime_type = "image/jpeg",
            .read_time_ms = 0.0,
            .decode_time_ms = 0.0,
            .conversion_time_ms = 0.0,
            .cbz_decompress_time_ms = 0.0,
            .compressed_size_bytes = 0,
            .orientation = .normal,
            .raw_metadata = .none,
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expect(state.cache.get(key0).?.status == .loaded_cpu);
}

test "drainWorkerEvents - skips thumbnail upload when image_decoded is in same batch" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "dummy.jpg" } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .decoding = .{ .has_thread = true },
    });
    const entry = state.cache.get(key0).?;

    const thumb_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32).?;
    const full_surf = sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32).?;

    // Push both thumb_decoded and image_decoded in same batch
    try state.workers.event_queue.push(allocator, io, .{
        .thumb_decoded = .init(key0, .{
            .surface = thumb_surf,
            .w = 16.0,
            .h = 16.0,
            .source_dims = .{ .w = 64.0, .h = 64.0 },
            .orientation = .normal,
            .thumb_only = false,
            .dct_snapped = false,
        }),
    });
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, .{
            .surface = full_surf,
            .w = 64.0,
            .h = 64.0,
            .size_bytes = 4096,
            .mime_type = "image/jpeg",
            .read_time_ms = 0.0,
            .decode_time_ms = 0.0,
            .conversion_time_ms = 0.0,
            .cbz_decompress_time_ms = 0.0,
            .compressed_size_bytes = 0,
            .orientation = .normal,
            .raw_metadata = .none,
        }),
    });

    try std.testing.expect(drainWorkerEvents(&state));

    // Thumbnail upload was skipped, so entry.thumbnail is not .loaded
    try std.testing.expect(entry.thumbnail != .loaded);
    // Full image is loaded
    try std.testing.expect(entry.status == .loaded_cpu);
    // thumb_crossfade animation is NOT active
    try std.testing.expect(!state.viewer.animations.isActive(.thumb_crossfade));
}

test "completeDecodedGpuUpload - enqueues thumb write before swapRemove" {
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
    const dummy_tex: sdl.gpu.Texture = .{ .ptr = @ptrFromInt(0x1000) };
    _ = try state.cache.appendSlot(allocator, id0, .{
        .loaded_gpu = .{
            .gpu_texture = dummy_tex,
            .w = 100.0,
            .h = 100.0,
            .size_bytes = 500,
            .memory_size_bytes = 500,
        },
    });

    // Slot 1 (tail of state.cache.slots): active index 5 being uploaded
    const key5 = try state.cache.appendSlot(allocator, id5, .{
        .decoding = .{ .has_thread = true },
    });

    const surf = sdl.Surface.create(32, 24, sdl.PixelFormat.rgba32).?;
    var decoded = events.ImageDecodedPayload{
        .surface = surf,
        .w = 1616.0,
        .h = 1080.0,
        .size_bytes = 4096,
        .mime_type = "image/x-sony-arw",
        .read_time_ms = 0.1,
        .decode_time_ms = 1.0,
        .conversion_time_ms = 0.0,
        .cbz_decompress_time_ms = 0.0,
        .compressed_size_bytes = 0,
        .orientation = .rotate_270,
        .raw_metadata = state_pkg.RawMetadata.init(6000.0, 4000.0),
        .thumb_write_mtime_sec = 1700000000,
    };
    defer if (decoded.surface) |s| s.destroy();

    const full_res = image.GpuUploadResult{
        .gpu_texture = dummy_tex,
        .w = 1616.0,
        .h = 1080.0,
        .conversion_time_ms = 0.0,
        .upload_time_ms = 0.1,
        .memory_size_bytes = 500,
        .num_mip_levels = 1,
        .mipmap_time_ms = 0.0,
        .was_fallback = false,
        .fallback_time_ms = 0.0,
    };

    // Budget is 600 bytes; 500 + 500 = 1000 > 600, so enforceVramBudget will
    // evict slot 0 via swapRemove(0), moving tail slot (key5) into index 0
    // before enqueueDecodedThumbWrite resolves key5 via getEntry(key5).
    completeDecodedGpuUpload(
        &state,
        key5,
        &decoded,
        surf,
        full_res,
        true,
        null,
        600,
    );

    try std.testing.expect(decoded.surface == null);
    try std.testing.expectEqual(@as(usize, 1), state.cache.count());
    try std.testing.expectEqual(
        @as(u64, 1),
        state.workers.snapshotThumbStats().cache_writes,
    );

    // If a slot has expired or been evicted, enqueueDecodedThumbWrite safely
    // returns false via getEntry(expired_key).
    const expired_surf = sdl.Surface.create(8, 8, sdl.PixelFormat.rgba32).?;
    defer expired_surf.destroy();
    const expired_key = image.ImageCacheKey{
        .id = id0,
        .generation = key5.generation,
    };
    try std.testing.expect(!enqueueDecodedThumbWrite(
        &state,
        expired_key,
        &decoded,
        1700000000,
        expired_surf,
    ));
}
