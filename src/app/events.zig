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
            .exif_orientation_parsed => |e| {
                if (state.cache.get(e.key)) |entry| {
                    entry.orientation = e.orientation;
                }
                state.updateCurrentRotation();
            },
            .dimensions_probed => |d| handleDimensionsProbedEvent(state, d),
            .thumb_decoded => |t| handleExifThumbnailEvent(state, t),
            .image_decoded => |*d| handleImageDecodedEvent(state, d),
            .decode_failed => |f| handleDecodeFailedEvent(state, f),
            .path_discovered => |p| handleDirScannedEvent(state, p),
            .directory_scan_result => |res| handleDirectoryScanResultEvent(state, res),
            .directory_scan_complete => {},
            .palette_folder_count => |cnt| {
                handlePaletteFolderCountEvent(state, cnt);
            },
            .ipc_command => |cmd_data| handleIpcCommandEvent(state, cmd_data),
        }
    }
    return true;
}

fn handleDecodeFailedEvent(
    state: *AppState,
    f: events.DecodeFailedPayload,
) void {
    const entry = state.cache.get(f.key) orelse {
        _ = state.cache.updateStatus(f.key, .failed);
        return;
    };
    entry.is_promoting = false;
    if (entry.status != .loaded_gpu and entry.status != .loaded_cpu) {
        entry.status = .failed;
    }
    if (entry.thumbnail == .pending or entry.thumbnail == .none) {
        entry.thumbnail = .not_available;
    }
}

fn handlePaletteFolderCountEvent(
    state: *AppState,
    cnt: events.PaletteFolderCountPayload,
) void {
    const palette = &state.viewer.ui.palette;
    const active_gen = palette.dir_scan_generation.load(.acquire);
    if (cnt.generation != active_gen) return;

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
    probed: events.DimensionsProbedPayload,
) void {
    const entry = state.cache.get(probed.key) orelse return;

    if (probed.orientation != .normal) {
        entry.orientation = probed.orientation;
    }
    if (probed.full_w > 0 and probed.full_h > 0) {
        const cur_area = entry.full_w * entry.full_h;
        const new_area = probed.full_w * probed.full_h;
        if (cur_area <= 0.0 or new_area > cur_area) {
            entry.full_w = probed.full_w;
            entry.full_h = probed.full_h;
        }
    }
    if (probed.raw_metadata.isRaw()) {
        entry.raw_metadata = probed.raw_metadata;
    }
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
    thumb_data: events.ThumbDecodedPayload,
) void {
    const entry = state.cache.get(thumb_data.key) orelse return;

    if (thumb_data.orientation != .normal) {
        entry.orientation = thumb_data.orientation;
    }
    if (thumb_data.full_w > 0 and thumb_data.full_h > 0) {
        const cur_area = entry.full_w * entry.full_h;
        const new_area = thumb_data.full_w * thumb_data.full_h;
        if (cur_area <= 0.0 or new_area > cur_area) {
            entry.full_w = thumb_data.full_w;
            entry.full_h = thumb_data.full_h;
        }
    }
    if (thumb_data.raw_metadata.isRaw()) {
        entry.raw_metadata = thumb_data.raw_metadata;
    }
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
            if (state.cache.get(thumb_data.key)) |current_entry| {
                switch (current_entry.thumbnail) {
                    .loaded => |old_thumb| gpu_dev.releaseTexture(old_thumb.texture),
                    else => {},
                }
                current_entry.thumbnail = .{
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
            } else {
                gpu_dev.releaseTexture(upload_res.gpu_texture);
            }
            state.updateCurrentRotation();
        } else {
            if (state.cache.get(thumb_data.key)) |current_entry| {
                if (current_entry.thumbnail == .none or current_entry.thumbnail == .pending) {
                    current_entry.thumbnail = .not_available;
                }
            }
        }
    } else {
        if (entry.thumbnail == .none or entry.thumbnail == .pending) {
            entry.thumbnail = .not_available;
        }
    }
}

fn handleImageDecodedEvent(state: *AppState, decoded_data: *events.ImageDecodedPayload) void {
    const surf = decoded_data.surface orelse return;
    if (state.cache.get(decoded_data.key) == null) return;

    const is_current = if (state.viewer.navigation.current_index) |cur|
        decoded_data.key.index == cur
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
                decoded_data,
                full_res,
                is_current,
                gpu_dev,
            );
            state.updateCurrentRotation();
        } else {
            std.log.err(
                "handleImageDecodedEvent: failed to upload surface to GPU for key {any}",
                .{decoded_data.key},
            );
            handleDecodedGpuUploadFailure(state, decoded_data.key, is_current);
        }
    } else {
        if (state.cache.get(decoded_data.key)) |entry| {
            switch (entry.status) {
                .loaded_cpu => |cpu| cpu.surface.destroy(),
                .loaded_gpu => |gpu| {
                    if (state.gpu_device) |gpu_dev| {
                        gpu_dev.releaseTexture(gpu.gpu_texture);
                    }
                },
                else => {},
            }
            entry.raw_metadata = decoded_data.raw_metadata;
            entry.orientation = decoded_data.orientation;
            entry.is_promoting = false;
            if (entry.full_w <= 0.0 or entry.full_h <= 0.0) {
                if (decoded_data.raw_metadata.getSensorDims()) |s_dims| {
                    entry.full_w = s_dims.w;
                    entry.full_h = s_dims.h;
                } else {
                    entry.full_w = decoded_data.w;
                    entry.full_h = decoded_data.h;
                }
            }
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
        }
        state.updateCurrentRotation();
    }
}

fn handleDecodedGpuUploadFailure(
    state: *AppState,
    key: image.CacheKey,
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
    decoded_data: *events.ImageDecodedPayload,
    full_res: image.GpuUploadResult,
    is_current: bool,
    gpu_dev: sdl.gpu.Device,
) void {
    const entry = state.cache.get(decoded_data.key) orelse {
        gpu_dev.releaseTexture(full_res.gpu_texture);
        return;
    };
    switch (entry.status) {
        .loaded_cpu => |cpu| cpu.surface.destroy(),
        .loaded_gpu => |gpu| gpu_dev.releaseTexture(gpu.gpu_texture),
        else => {},
    }
    entry.raw_metadata = decoded_data.raw_metadata;
    entry.orientation = decoded_data.orientation;
    entry.is_promoting = false;
    if (entry.full_w <= 0.0 or entry.full_h <= 0.0) {
        if (decoded_data.raw_metadata.getSensorDims()) |s_dims| {
            entry.full_w = s_dims.w;
            entry.full_h = s_dims.h;
        } else {
            entry.full_w = decoded_data.w;
            entry.full_h = decoded_data.h;
        }
    }
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
    state.cache.enforceVramBudget(
        gpu_dev,
        state.viewer.navigation.current_index,
        state.viewer.getTransitionPrevIndex(),
        state.viewer.navigation.count(),
        image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES,
    );
    if (entry.thumbnail == .pending or entry.thumbnail == .none) {
        entry.thumbnail = .not_available;
    }
    triggerDecodedGpuCrossfades(state, is_current, entry);
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
        var target_idx_in_dir: ?usize = null;
        for (result_data.paths, 0..) |item, i| {
            if (entryMatchesTarget(item, result_data.target_path)) {
                target_idx_in_dir = i;
                break;
            }
        }

        _ = state.viewer.navigation.directory_arena.reset(.retain_capacity);
        state.viewer.navigation.clearEntries();
        for (result_data.paths, 0..) |item, i| {
            const dup = item.dupe(arena_alloc) catch |err| {
                std.log.err("Failed to duplicate directory item: {}", .{err});
                continue;
            };
            state.viewer.navigation.appendEntry(state.allocator, dup) catch |err| {
                std.log.err("Failed to append image to list: {}", .{err});
            };
            if (target_idx_in_dir == null and entryMatchesTarget(item, result_data.target_path)) {
                target_idx_in_dir = i;
            }
        }

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
        .exif_orientation_parsed = .{
            .key = state.cache.activeKey(0),
            .orientation = .rotate_90,
        },
    });
    const processed1 = drainWorkerEvents(&state);
    try std.testing.expect(processed1);
    try std.testing.expectEqual(
        Orientation.rotate_90,
        state.cache.slots.items(.entry)[0].orientation,
    );

    try state.workers.event_queue.push(allocator, io, .{
        .decode_failed = .{ .key = state.cache.activeKey(0) },
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
        .directory_scan_result = .{
            .target_path = target_path,
            .is_dir = false,
            .paths = paths_slice,
        },
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
        .image_decoded = .{
            .key = state.cache.activeKey(1),
            .surface = surf,
            .w = 10,
            .h = 10,
            .mime_type = "image/png",
            .size_bytes = 100,
            .read_time_ms = 1.0,
            .decode_time_ms = 2.0,
            .conversion_time_ms = 0.0,
            .orientation = .normal,
        },
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
        .dimensions_probed = .{
            .key = state.cache.activeKey(0),
            .w = 1920.0,
            .h = 1080.0,
            .full_w = 1920.0,
            .full_h = 1080.0,
            .orientation = .normal,
            .thumb_only = true,
        },
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
        .palette_folder_count = .{
            .generation = 0,
            .path = stale_path,
            .image_count = 999,
            .subdir_count = 999,
        },
    });

    _ = drainWorkerEvents(&state);
    try std.testing.expectEqual(
        state_pkg.EntryScanState.unscanned,
        state.viewer.ui.palette.dir_items.items[0].directory.scan,
    );

    // Push matching events for directory and archive
    const evt_dir_path = try allocator.dupe(u8, "/path/to/folder_a");
    try state.workers.event_queue.push(allocator, io, .{
        .palette_folder_count = .{
            .generation = 1,
            .path = evt_dir_path,
            .image_count = 12,
            .subdir_count = 3,
        },
    });

    const evt_cbz_path = try allocator.dupe(u8, "/path/to/comic.cbz");
    try state.workers.event_queue.push(allocator, io, .{
        .palette_folder_count = .{
            .generation = 1,
            .path = evt_cbz_path,
            .image_count = 45,
            .subdir_count = 0,
        },
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
    handleDecodedGpuUploadFailure(&state, key1, true);
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
        .image_decoded = .{
            .key = key1,
            .surface = promoted_surf,
            .w = 32,
            .h = 24,
            .mime_type = "image/jpeg",
            .size_bytes = 3072,
            .read_time_ms = 1.0,
            .decode_time_ms = 2.0,
            .conversion_time_ms = 0.0,
            .orientation = .normal,
        },
    });

    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expect(!entry1.is_promoting);
    try std.testing.expect(entry1.status == .loaded_cpu);
    try std.testing.expectEqual(@as(usize, 0), state.cache.getTotalVramBytes());

    // 3. Initial decode upload failure on slot 0 transitions to .failed
    const key0 = state.cache.activeKey(0);
    handleDecodedGpuUploadFailure(&state, key0, true);
    try std.testing.expect(state.cache.get(key0).?.status == .failed);
}
