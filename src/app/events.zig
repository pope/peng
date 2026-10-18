const app_state = @import("state.zig");
const events = @import("core/events.zig");
const image = @import("core/image.zig");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const MediaEntry = state_pkg.MediaEntry;
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

    for (state.event_batch.items) |*evt| {
        defer evt.deinit(state.allocator);

        switch (evt.*) {
            .exif_orientation_parsed => |*e| if (e.resolve(&state.cache)) |r| {
                r.entry.orientation = r.payload.orientation;
                state.updateCurrentRotation();
            },
            .dimensions_probed => |*d| if (d.resolve(&state.cache)) |r| {
                handleDimensionsProbedEvent(state, r.entry, r.payload.*);
            },
            .thumb_decoded => |*t| if (t.resolve(&state.cache)) |r| {
                handleExifThumbnailEvent(state, r.entry, r.payload.*);
            },
            .image_decoded => |*d| if (d.resolve(&state.cache)) |r| {
                handleImageDecodedEvent(state, r.key, r.entry, r.payload);
            },
            .decode_failed => |*f| if (f.resolve(&state.cache)) |r| {
                const is_current =
                    state.viewer.navigation.current_index == r.key.index;
                handleDecodeFailedEvent(state, r.entry, is_current);
            },
            .path_discovered => |p| handleDirScannedEvent(state, p),
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
            .ipc_command => |cmd_data| handleIpcCommandEvent(state, cmd_data),
        }
    }
    return true;
}

fn handleDecodeFailedEvent(
    state: *AppState,
    entry: *state_pkg.CacheEntry,
    is_current: bool,
) void {
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

        const counts = state_pkg.EntryScanCounts{
            .image_count = cnt.image_count,
            .subdir_count = cnt.subdir_count,
        };
        switch (item.*) {
            .directory => |*d| d.scan = .{ .scanned = counts },
            .archive_file => |*a| a.scan = .{ .scanned = counts },
            else => {},
        }
        state.viewer.ui.palette.selection_dirty = true;
        break;
    }
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
    entry: *state_pkg.CacheEntry,
    probed: events.DimensionsProbedPayload,
) void {
    entry.applyProbedMetadata(
        probed.full_w,
        probed.full_h,
        probed.orientation,
        probed.raw_metadata,
    );
    if (probed.thumb_only) {
        switch (entry.status) {
            .decoding => |*dec| dec.has_thread = false,
            else => {},
        }
    }
    state.updateCurrentRotation();

    if (entry.thumbnail == .none or entry.thumbnail == .pending) {
        entry.thumbnail = .not_available;
    }
}

fn handleExifThumbnailEvent(
    state: *AppState,
    entry: *state_pkg.CacheEntry,
    thumb_data: events.ThumbDecodedPayload,
) void {
    entry.applyProbedMetadata(
        thumb_data.full_w,
        thumb_data.full_h,
        thumb_data.orientation,
        thumb_data.raw_metadata,
    );
    if (thumb_data.thumb_only) {
        switch (entry.status) {
            .decoding => |*dec| dec.has_thread = false,
            else => {},
        }
    }
    state.updateCurrentRotation();

    const surf = thumb_data.surface;
    if (state.gpu_device) |gpu_dev| {
        if (image.uploadSurfaceToGpu(
            gpu_dev,
            surf,
            state.unpack_compute_pipeline,
            &state.upload_staging,
        )) |upload_res| {
            switch (entry.thumbnail) {
                .loaded => |old_thumb| {
                    gpu_dev.releaseTexture(old_thumb.texture);
                },
                else => {},
            }
            entry.thumbnail = .{
                .loaded = .{
                    .texture = upload_res.gpu_texture,
                    .info = .{
                        .w = upload_res.w,
                        .h = upload_res.h,
                        .upload_time_ms = upload_res.upload_time_ms,
                        .dct_snapped = thumb_data.dct_snapped,
                    },
                },
            };
            state.updateCurrentRotation();
        } else {
            if (entry.thumbnail == .none or entry.thumbnail == .pending) {
                entry.thumbnail = .not_available;
            }
        }
    } else {
        if (entry.thumbnail == .none or entry.thumbnail == .pending) {
            entry.thumbnail = .not_available;
        }
    }
}

fn handleImageDecodedEvent(
    state: *AppState,
    key: image.CacheKey,
    entry: *state_pkg.CacheEntry,
    decoded_data: *events.ImageDecodedPayload,
) void {
    const surf = decoded_data.surface orelse return;

    const is_current = if (state.viewer.navigation.current_index) |cur|
        key.index == cur
    else
        true;

    // Check if the current image is already loaded on GPU (or failed)
    const is_current_ready = blk: {
        const cur_idx = state.viewer.navigation.current_index orelse break :blk true;
        const cur_key = state.cache.activeKey(cur_idx);
        if (state.cache.get(cur_key)) |cur_entry| {
            break :blk switch (cur_entry.status) {
                .loaded_gpu, .failed => true,
                else => false,
            };
        }
        break :blk false;
    };

    // Demand-first GPU upload gating:
    // Only upload immediately to the GPU if this IS the active image, OR if the active
    // image is already on the GPU. If a neighbor decode finishes while the active image
    // is still decoding or uploading, keep the neighbor in RAM (.loaded_cpu) to preserve
    // 100% of PCIe bus bandwidth and GPU mipmap downsampling for the active image.
    const should_upload_gpu = (state.gpu_device != null) and (is_current or is_current_ready);

    if (should_upload_gpu) {
        const gpu_dev = state.gpu_device.?;
        if (image.uploadSurfaceToGpu(
            gpu_dev,
            surf,
            state.unpack_compute_pipeline,
            &state.upload_staging,
        )) |full_res| {
            applyDecodedGpuTexture(
                state,
                entry,
                decoded_data,
                full_res,
                is_current,
                gpu_dev,
            );
            state.updateCurrentRotation();
        } else {
            std.log.err(
                "handleImageDecodedEvent: failed to upload surface to GPU for key {any}",
                .{key},
            );
            handleDecodeFailedEvent(state, entry, is_current);
        }
    } else {
        switch (entry.status) {
            .loaded_cpu => |cpu| cpu.surface.destroy(),
            .loaded_gpu => |gpu| {
                if (state.gpu_device) |gpu_dev| {
                    gpu_dev.releaseTexture(gpu.gpu_texture);
                }
            },
            else => {},
        }
        applyDecodedMetadata(entry, decoded_data);
        if (entry.thumbnail == .pending or entry.thumbnail == .none) {
            entry.thumbnail = .not_available;
        }
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
                .cbz_decompress_time_ms = decoded_data.cbz_decompress_time_ms,
                .compressed_size_bytes = decoded_data.compressed_size_bytes,
            },
        };
        decoded_data.surface = null;
        state.updateCurrentRotation();
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
    entry.updateFullDims(decoded_data.w, decoded_data.h);
    entry.raw_metadata = if (decoded_data.raw_metadata.isRaw())
        if (entry.full_w > 0.0 and entry.full_h > 0.0)
            state_pkg.RawMetadata.init(entry.full_w, entry.full_h)
        else
            decoded_data.raw_metadata
    else
        .none;
}

fn triggerDecodedGpuCrossfades(
    state: *AppState,
    is_current: bool,
    entry: *state_pkg.CacheEntry,
) void {
    if (!is_current) return;

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
    entry: *state_pkg.CacheEntry,
    decoded_data: *events.ImageDecodedPayload,
    full_res: image.GpuUploadResult,
    is_current: bool,
    gpu_dev: sdl.gpu.Device,
) void {
    switch (entry.status) {
        .loaded_cpu => |cpu| cpu.surface.destroy(),
        .loaded_gpu => |gpu| gpu_dev.releaseTexture(gpu.gpu_texture),
        else => {},
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
    triggerDecodedGpuCrossfades(state, is_current, entry);
    state.cache.enforceVramBudget(
        gpu_dev,
        state.viewer.navigation.getVisibleNeighbors(),
        state.viewer.getTransitionPrevIndex(),
        state.viewer.navigation.count(),
        image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES,
    );
}

fn handleDirScannedEvent(state: *AppState, scanned_data: events.PathDiscoveredPayload) void {
    const dup = scanned_data.entry.dupe(
        state.viewer.navigation.directory_arena.allocator(),
    ) catch |err| {
        std.log.err("Failed to duplicate path in directory arena: {}", .{err});
        return;
    };
    state.viewer.navigation.appendEntry(state.allocator, dup) catch |err| {
        std.log.err("Failed to append discovered path to image_list: {}", .{err});
    };
    if (state.viewer.navigation.current_index == null and
        state.viewer.navigation.count() > 0)
    {
        _ = state.viewer.navigation.adjustIndexForVisibility();
    }
}

fn pathMatchesTarget(path: []const u8, target: []const u8) bool {
    if (std.mem.eql(u8, path, target)) return true;
    const p = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    const t = if (std.mem.startsWith(u8, target, "./")) target[2..] else target;
    return std.mem.eql(u8, p, t);
}

fn entryMatchesTarget(item: MediaEntry, target: []const u8) bool {
    return switch (item) {
        .filesystem => |f| pathMatchesTarget(f.path, target),
        .archive_entry => |a| pathMatchesTarget(a.archive_path, target),
        .pair => |p| pathMatchesTarget(p.raw_path, target) or
            pathMatchesTarget(p.jpeg_path, target),
    };
}

fn reconcileSingleFileScanCache(
    state: *AppState,
    had_single_fs: bool,
    target_idx: ?usize,
) void {
    const active_decodes = state.workers.active_decode_threads.load(.acquire);
    if (state.cache.count() == 0 and active_decodes == 0) return;

    if (target_idx) |target_i| {
        const target_entry = state.viewer.navigation.getMediaEntry(target_i);
        const is_target_fs = if (target_entry) |e| e == .filesystem else false;
        if (had_single_fs and is_target_fs) {
            if (target_i == 0 and state.cache.count() <= 1) {
                if (state.cache.count() == 0 or
                    state.cache.slots.items(.key)[0].index == 0)
                {
                    return;
                }
            } else if (target_i != 0 and
                state.cache.count() == 1 and
                active_decodes == 0)
            {
                const key0 = state.cache.slots.items(.key)[0];
                const entry0 = state.cache.slots.items(.entry)[0];
                const cur_gen = state.cache.generation.load(.acquire);
                const is_loaded = entry0.status == .loaded_gpu or
                    entry0.status == .loaded_cpu;
                if (key0.index == 0 and
                    key0.generation == cur_gen and
                    is_loaded and
                    !entry0.is_promoting and
                    entry0.thumbnail != .pending)
                {
                    state.cache.slots.items(.key)[0].index = target_i;
                    state.cache.vram_capped_neighbors = null;
                    state.cache.vram_capped_prev_index = null;
                    state.cache.max_prefetch_dist = 2;
                    return;
                }
            }
        }
    }

    _ = state.cache.advanceGeneration();
    state.clearCache();
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
            state.viewer.navigation.appendEntry(state.allocator, dup) catch |err| {
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

        var target_idx_in_dir: ?usize = null;
        _ = state.viewer.navigation.directory_arena.reset(.retain_capacity);
        state.viewer.navigation.clearEntries();
        for (result_data.paths) |item| {
            const dup = item.dupe(arena_alloc) catch |err| {
                std.log.err("Failed to duplicate directory item: {}", .{err});
                continue;
            };
            state.viewer.navigation.appendEntry(state.allocator, dup) catch |err| {
                std.log.err("Failed to append image to list: {}", .{err});
                continue;
            };
            if (target_idx_in_dir == null and
                entryMatchesTarget(item, result_data.target_path))
            {
                target_idx_in_dir = state.viewer.navigation.count() - 1;
            }
        }

        reconcileSingleFileScanCache(state, had_single_fs, target_idx_in_dir);

        if (target_idx_in_dir) |target_i| {
            _ = state.viewer.navigation.goToIndex(target_i);
        } else {
            _ = state.viewer.navigation.adjustIndexForVisibility();
        }
    }
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

    _ = try state.cache.appendSlot(allocator, 0, .{
        .decoding = .{ .has_thread = true },
    });

    try state.workers.event_queue.push(allocator, io, .{
        .exif_orientation_parsed = .init(
            state.cache.activeKey(0),
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
        .decode_failed = .init(state.cache.activeKey(0), .{}),
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

    // Slot 0 is decoding
    _ = try state.cache.appendSlot(allocator, 0, .{
        .decoding = .{ .has_thread = true },
    });

    // Slot 1 is decoding
    _ = try state.cache.appendSlot(allocator, 1, .{
        .decoding = .{ .has_thread = true },
    });

    const surf = sdl.Surface.create(
        10,
        10,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;

    // Neighbor index 1 finishes decoding before index 0
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(state.cache.activeKey(1), .{
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
    const entry1 = state.cache.get(state.cache.activeKey(1)).?;
    try std.testing.expect(entry1.status == .loaded_cpu);
}

test "drainWorkerEvents - dimensions_probed sets dimensions and clears has_thread" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    _ = try state.cache.appendSlot(allocator, 0, .{
        .decoding = .{ .has_thread = true },
    });

    try state.workers.event_queue.push(allocator, io, .{
        .dimensions_probed = .init(state.cache.activeKey(0), .{
            .w = 1920.0,
            .h = 1080.0,
            .full_w = 1920.0,
            .full_h = 1080.0,
            .orientation = .normal,
            .thumb_only = true,
        }),
    });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);

    const entry = state.cache.get(state.cache.activeKey(0)).?;
    try std.testing.expectEqual(@as(f32, 1920.0), entry.full_w);
    try std.testing.expectEqual(@as(f32, 1080.0), entry.full_h);
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
            .image_count = 999,
            .subdir_count = 999,
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
            .image_count = 12,
            .subdir_count = 3,
        }),
    });

    const evt_cbz_path = try allocator.dupe(u8, "/path/to/comic.cbz");
    try state.workers.event_queue.push(allocator, io, .{
        .palette_folder_count = .init(1, .{
            .path = evt_cbz_path,
            .image_count = 45,
            .subdir_count = 0,
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
}

test "drainWorkerEvents - pair promotion preserves VRAM and loaded status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.navigation.current_index = 0;

    // Slot 0 is currently decoding; slot 1 is already .loaded_gpu and promoting
    _ = try state.cache.appendSlot(allocator, 0, .{
        .decoding = .{ .has_thread = true },
    });
    const key1 = try state.cache.appendSlot(allocator, 1, .{
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
    handleDecodeFailedEvent(&state, entry1, true);
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
    const key0 = state.cache.activeKey(0);
    const entry0 = state.cache.get(key0).?;
    handleDecodeFailedEvent(&state, entry0, true);
    try std.testing.expect(entry0.status == .failed);
}

test "drainWorkerEvents - monotonic full_w and full_h on pair promotion" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.navigation.current_index = 0;
    const key0 = try state.cache.appendSlot(allocator, 0, .{
        .decoding = .{ .has_thread = true },
    });
    const entry0 = state.cache.get(key0).?;

    // 1. Initial preview decode at 1616x1080 sets full_w/full_h to 1616x1080
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
    try std.testing.expectEqual(@as(f32, 1616), entry0.full_w);
    try std.testing.expectEqual(@as(f32, 1080), entry0.full_h);
    try std.testing.expect(entry0.raw_metadata.isRaw());

    // 2. Promotion to 6000x4000 standalone JPEG upgrades full_w/full_h
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
    try std.testing.expectEqual(@as(f32, 6000), entry0.full_w);
    try std.testing.expectEqual(@as(f32, 4000), entry0.full_h);
    try std.testing.expect(!entry0.raw_metadata.isRaw());
    const auth = entry0.getAuthoritativeDims();
    try std.testing.expectEqual(@as(f32, 6000), auth.w);
    try std.testing.expectEqual(@as(f32, 4000), auth.h);

    // 3. Toggling back to 1616x1080 preview does not regress full_w/full_h
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
    try std.testing.expectEqual(@as(f32, 6000), entry0.full_w);
    try std.testing.expectEqual(@as(f32, 4000), entry0.full_h);
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
    // at index 2 -> slot 0 is remapped in-place to index 2 without re-decoding.
    const arena_alloc = state.viewer.navigation.directory_arena.allocator();
    const init_p = try arena_alloc.dupe(u8, "c.jpg");
    try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = init_p } },
    );
    state.viewer.navigation.current_index = 0;

    const surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    _ = try state.cache.appendSlot(allocator, 0, .{
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
    try std.testing.expect(state.cache.get(state.cache.activeKey(0)) == null);
    try std.testing.expect(state.cache.get(state.cache.activeKey(2)) != null);

    // Case 2: Initial single-file entry at 0 is still .decoding in-flight when
    // scan places it at index 1 -> cache generation advances and cache clears.
    state.clearCache();
    state.viewer.navigation.clearEntries();
    const init_p2 = try arena_alloc.dupe(u8, "b.jpg");
    try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = init_p2 } },
    );
    state.viewer.navigation.current_index = 0;
    _ = try state.cache.appendSlot(allocator, 0, .{
        .decoding = .{ .has_thread = true },
    });

    const paths2 = try allocator.alloc(MediaEntry, 2);
    paths2[0] = .{ .filesystem = .{ .path = try allocator.dupe(u8, "a.jpg") } };
    paths2[1] = .{ .filesystem = .{ .path = try allocator.dupe(u8, "b.jpg") } };
    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(0, .{
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
        gen_before + 1,
        state.cache.generation.load(.acquire),
    );
    try std.testing.expectEqual(@as(usize, 0), state.cache.count());
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
    try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, "a.jpg") } },
    );
    try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = try dir_alloc.dupe(u8, "b.jpg") } },
    );
    state.viewer.navigation.current_index = 1;

    const key1 = try state.cache.appendSlot(allocator, 1, .{
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
