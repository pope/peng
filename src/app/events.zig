const app_state = @import("state.zig");
const events = @import("core/events.zig");
const image = @import("core/image.zig");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const Orientation = state_pkg.Orientation;

/// Drains all background thread events (e.g. image decodes, thumbnail extractions, directory scans,
/// folder count updates, and IPC commands) from `workers.event_queue`.
/// Dispatches each event to update texture cache entries, image lists, rotation maps, and Command Palette state.
/// Returns `true` if at least one event was drained and processed; otherwise `false`.
pub fn drainWorkerEvents(state: *AppState) bool {
    state.event_batch.clearRetainingCapacity();
    state.workers.event_queue.drain(state.allocator, state.io, &state.event_batch) catch return false;
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
            .thumb_decoded => |t| handleExifThumbnailEvent(state, t),
            .image_decoded => |*d| handleImageDecodedEvent(state, d),
            .decode_failed => |f| {
                _ = state.cache.updateStatus(f.key, .failed);
                if (state.cache.get(f.key)) |entry| {
                    if (entry.thumbnail == .pending or entry.thumbnail == .none) {
                        entry.thumbnail = .not_available;
                    }
                }
            },
            .path_discovered => |p| handleDirScannedEvent(state, p),
            .directory_scan_result => |res| handleDirectoryScanResultEvent(state, res),
            .directory_scan_complete => {},
            .palette_folder_count => |cnt| {
                if (cnt.generation == state.viewer.ui.palette.dir_scan_generation.load(.acquire)) {
                    for (state.viewer.ui.palette.dir_items.items) |*item| {
                        if (std.mem.eql(u8, item.getFullPath(), cnt.path)) {
                            switch (item.*) {
                                .directory => |*d| {
                                    d.scan = .{
                                        .scanned = .{
                                            .image_count = cnt.image_count,
                                            .subdir_count = cnt.subdir_count,
                                        },
                                    };
                                },
                                .archive_file => |*a| {
                                    a.scan = .{
                                        .scanned = .{
                                            .image_count = cnt.image_count,
                                            .subdir_count = cnt.subdir_count,
                                        },
                                    };
                                },
                                else => {},
                            }
                            state.viewer.ui.palette.selection_dirty = true;
                            break;
                        }
                    }
                }
            },
            .ipc_command => |cmd_data| {
                state.pending_ipc_commands.append(state.allocator, cmd_data) catch |err| {
                    std.log.err("Failed to append IPC command to pending list: {}", .{err});
                    cmd_data.client_stream.close(state.io);
                    state.allocator.free(cmd_data.command);
                    state.allocator.destroy(cmd_data);
                };
            },
        }
    }
    return true;
}

fn handleExifThumbnailEvent(state: *AppState, thumb_data: events.ThumbDecodedPayload) void {
    const entry = state.cache.get(thumb_data.key) orelse return;

    if (thumb_data.orientation != .normal) {
        entry.orientation = thumb_data.orientation;
    }
    if (thumb_data.full_w > 0 and thumb_data.full_h > 0) {
        entry.full_w = thumb_data.full_w;
        entry.full_h = thumb_data.full_h;
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

    const surf = thumb_data.surface orelse {
        if (entry.thumbnail == .none or entry.thumbnail == .pending) {
            entry.thumbnail = .not_available;
        }
        return;
    };
    if (state.gpu_device) |gpu_dev| {
        if (image.uploadSurfaceToGpu(gpu_dev, surf, state.unpack_compute_pipeline, &state.upload_staging)) |upload_res| {
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
    // Only upload immediately to the GPU if this IS the active image, OR if the active image is already on the GPU.
    // If a neighbor decode finishes while the active image is still decoding or uploading, keep the neighbor in
    // RAM (.loaded_cpu) to preserve 100% of PCIe bus bandwidth and GPU mipmap downsampling for the active image.
    const should_upload_gpu = (state.gpu_device != null) and (is_current or is_current_ready);

    if (should_upload_gpu) {
        const gpu_dev = state.gpu_device.?;
        if (image.uploadSurfaceToGpu(gpu_dev, surf, state.unpack_compute_pipeline, &state.upload_staging)) |full_res| {
            if (state.cache.get(decoded_data.key)) |entry| {
                switch (entry.status) {
                    .loaded_cpu => |cpu| cpu.surface.destroy(),
                    .loaded_gpu => |gpu| gpu_dev.releaseTexture(gpu.gpu_texture),
                    else => {},
                }
                entry.raw_metadata = decoded_data.raw_metadata;
                entry.orientation = decoded_data.orientation;
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
                        .w = decoded_data.w,
                        .h = decoded_data.h,
                        .size_bytes = decoded_data.size_bytes,
                        .mime_type = decoded_data.mime_type,
                        .raw_metadata = decoded_data.raw_metadata,
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
                state.cache.enforceVramBudget(gpu_dev, state.viewer.navigation.current_index, state.viewer.navigation.image_list.items.len, image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES);
                if (entry.thumbnail == .pending or entry.thumbnail == .none) {
                    entry.thumbnail = .not_available;
                }
                if (is_current and entry.thumbnail == .loaded and !state.viewer.ui.overlays.debug_show_thumb) {
                    state.viewer.animations.startFrom(.thumb_crossfade, 0.0, 1.0, state_pkg.DURATION_THUMB_CROSSFADE_MS, .ease_out_quad);
                }
            } else {
                gpu_dev.releaseTexture(full_res.gpu_texture);
            }
            state.updateCurrentRotation();
        } else {
            std.log.err("handleImageDecodedEvent: failed to upload surface to GPU for key {any}", .{decoded_data.key});
            _ = state.cache.updateStatus(decoded_data.key, .failed);
            if (state.cache.get(decoded_data.key)) |entry| {
                if (entry.thumbnail == .pending or entry.thumbnail == .none) {
                    entry.thumbnail = .not_available;
                }
            }
        }
    } else {
        if (state.cache.get(decoded_data.key)) |entry| {
            switch (entry.status) {
                .loaded_cpu => |cpu| cpu.surface.destroy(),
                else => {},
            }
            entry.raw_metadata = decoded_data.raw_metadata;
            entry.orientation = decoded_data.orientation;
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
                    .raw_metadata = decoded_data.raw_metadata,
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

fn handleDirScannedEvent(state: *AppState, scanned_data: events.PathDiscoveredPayload) void {
    const dup = scanned_data.entry.dupe(state.viewer.navigation.directory_arena.allocator()) catch |err| {
        std.log.err("Failed to duplicate path in directory arena: {}", .{err});
        return;
    };
    state.viewer.navigation.image_list.append(state.allocator, dup) catch |err| std.log.err("Failed to append discovered path to image_list: {}", .{err});
    if (state.viewer.navigation.current_index == null and state.viewer.navigation.image_list.items.len > 0) {
        state.viewer.navigation.current_index = 0;
    }
}

fn handleDirectoryScanResultEvent(state: *AppState, result_data: events.DirectoryScanResultPayload) void {
    const arena_alloc = state.viewer.navigation.directory_arena.allocator();
    if (result_data.is_dir) {
        for (result_data.paths) |item| {
            const dup = item.dupe(arena_alloc) catch |err| {
                std.log.err("Failed to duplicate directory item: {}", .{err});
                continue;
            };
            state.viewer.navigation.image_list.append(state.allocator, dup) catch |err| {
                std.log.err("Failed to append image to list: {}", .{err});
            };
        }
        if (state.viewer.navigation.current_index == null and state.viewer.navigation.image_list.items.len > 0) {
            state.viewer.navigation.current_index = 0;
        }
    } else {
        var target_idx_in_dir: ?usize = null;
        for (result_data.paths, 0..) |item, i| {
            switch (item) {
                .filesystem => |f| {
                    if (std.mem.eql(u8, f.path, result_data.target_path)) {
                        target_idx_in_dir = i;
                        break;
                    }
                },
                else => {},
            }
        }

        _ = state.viewer.navigation.directory_arena.reset(.retain_capacity);
        state.viewer.navigation.image_list.clearRetainingCapacity();
        for (result_data.paths, 0..) |item, i| {
            const dup = item.dupe(arena_alloc) catch |err| {
                std.log.err("Failed to duplicate directory item: {}", .{err});
                continue;
            };
            state.viewer.navigation.image_list.append(state.allocator, dup) catch |err| {
                std.log.err("Failed to append image to list: {}", .{err});
            };
            if (target_idx_in_dir == null and item == .filesystem and std.mem.eql(u8, item.filesystem.path, result_data.target_path)) {
                target_idx_in_dir = i;
            }
        }

        if (target_idx_in_dir) |target_i| {
            if (target_i < state.viewer.navigation.image_list.items.len) {
                state.viewer.navigation.current_index = target_i;
            }
        } else {
            state.viewer.navigation.current_index = 0;
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
    try state.workers.event_queue.push(allocator, io, .{ .path_discovered = .{ .path = path_dup } });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);
    try std.testing.expect(state.viewer.dirty);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.navigation.image_list.items.len);
    try std.testing.expectEqual(@as(?usize, 0), state.viewer.navigation.current_index);
}

test "drainWorkerEvents - exif_orientation_parsed & decode_failed" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.cache.appendWithKey(allocator, .{
        .index = 0,
        .generation = state.cache.getGeneration(),
    }, .{
        .status = .{ .decoding = .{ .has_thread = true } },
    });

    try state.workers.event_queue.push(allocator, io, .{ .exif_orientation_parsed = .{ .key = state.cache.activeKey(0), .orientation = .rotate_90 } });
    const processed1 = drainWorkerEvents(&state);
    try std.testing.expect(processed1);
    try std.testing.expectEqual(Orientation.rotate_90, state.cache.slots.items(.entry)[0].orientation);

    try state.workers.event_queue.push(allocator, io, .{ .decode_failed = .{ .key = state.cache.activeKey(0) } });
    const processed2 = drainWorkerEvents(&state);
    try std.testing.expect(processed2);
    try std.testing.expectEqual(@as(@TypeOf(state.cache.slots.items(.entry)[0].status), .failed), state.cache.slots.items(.entry)[0].status);
}

test "drainWorkerEvents - directory_scan_result and ipc_command" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const target_path = try allocator.dupe(u8, "/imgs/b.jpg");
    const path0 = try allocator.dupe(u8, "/imgs/a.jpg");
    const path1 = try allocator.dupe(u8, "/imgs/b.jpg");
    const paths_slice = try allocator.alloc([]const u8, 2);
    paths_slice[0] = path0;
    paths_slice[1] = path1;

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
    try std.testing.expectEqual(@as(usize, 2), state.viewer.navigation.image_list.items.len);
    try std.testing.expectEqual(@as(?usize, 1), state.viewer.navigation.current_index);
    try std.testing.expectEqual(@as(usize, 1), state.pending_ipc_commands.items.len);
}

test "drainWorkerEvents - neighbor image_decoded stays loaded_cpu while current is decoding" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Set up navigation with current_index = 0
    state.viewer.navigation.current_index = 0;

    // Slot 0 is decoding
    try state.cache.appendWithKey(allocator, .{
        .index = 0,
        .generation = state.cache.getGeneration(),
    }, .{
        .status = .{ .decoding = .{ .has_thread = true } },
    });

    // Slot 1 is decoding
    try state.cache.appendWithKey(allocator, .{
        .index = 1,
        .generation = state.cache.getGeneration(),
    }, .{
        .status = .{ .decoding = .{ .has_thread = true } },
    });

    const surf = sdl.Surface.create(10, 10, sdl.PixelFormat.rgba32) orelse return error.SurfaceFailed;

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

    // Slot 1 should be .loaded_cpu (not uploaded or destroyed) because current slot 0 was not yet loaded
    const entry1 = state.cache.get(state.cache.activeKey(1)).?;
    try std.testing.expect(entry1.status == .loaded_cpu);
}

test "drainWorkerEvents - thumb_decoded without surface sets dimensions and clears has_thread" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.cache.appendWithKey(allocator, .{
        .index = 0,
        .generation = state.cache.getGeneration(),
    }, .{
        .status = .{ .decoding = .{ .has_thread = true } },
    });

    try state.workers.event_queue.push(allocator, io, .{
        .thumb_decoded = .{
            .key = state.cache.activeKey(0),
            .surface = null,
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

    defer {
        for (state.viewer.ui.palette.dir_items.items) |item| {
            allocator.free(item.getName());
            allocator.free(item.getFullPath());
        }
        state.viewer.ui.palette.dir_items.deinit(allocator);
    }

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
    try std.testing.expectEqual(state_pkg.EntryScanState.unscanned, state.viewer.ui.palette.dir_items.items[0].directory.scan);

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
    try std.testing.expectEqual(@as(?usize, 12), state.viewer.ui.palette.dir_items.items[0].getImageCount());
    try std.testing.expectEqual(@as(?usize, 3), state.viewer.ui.palette.dir_items.items[0].getSubdirCount());
    try std.testing.expectEqual(@as(?usize, 45), state.viewer.ui.palette.dir_items.items[1].getImageCount());
    try std.testing.expectEqual(state_pkg.EntryScanState{ .scanned = .{ .image_count = 45, .subdir_count = 0 } }, state.viewer.ui.palette.dir_items.items[1].archive_file.scan);
}
