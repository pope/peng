const std = @import("std");
const app_state = @import("state.zig");
const AppState = app_state.AppState;
const events = @import("core/events.zig");
const image = @import("core/image.zig");
const ipc = @import("ipc");
const sdl = @import("sdl");

/// Drains background thread events (`image_decoded`, `path_scanned`, `ipc_command`)
/// from `workers.event_queue` and updates cache slots, navigation list, and pending IPC lists.
pub fn drainWorkerEvents(state: *AppState) bool {
    state.event_batch.clearRetainingCapacity();
    state.workers.event_queue.drain(state.allocator, state.io, &state.event_batch) catch return false;
    if (state.event_batch.items.len == 0) return false;

    for (state.event_batch.items) |*evt| {
        defer evt.deinit(state.allocator);

        switch (evt.*) {
            .exif_orientation_parsed => |e| {
                if (state.cache.get(e.key)) |entry| {
                    entry.exif_orientation = e.orientation;
                }
                state.updateCurrentRotation();
            },
            .thumb_decoded => |t| handleExifThumbnailEvent(state, t),
            .image_decoded => |*d| handleImageDecodedEvent(state, d),
            .decode_failed => |f| {
                _ = state.cache.updateStatus(f.key, .failed);
            },
            .path_discovered => |p| handleDirScannedEvent(state, p),
            .directory_scan_result => |res| handleDirectoryScanResultEvent(state, res),
            .directory_scan_complete => {},
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
    const surf = thumb_data.surface orelse return;
    if (state.gpu_device) |gpu_dev| {
        if (image.uploadSurfaceToGpu(gpu_dev, surf, state.unpack_compute_pipeline)) |upload_res| {
            if (state.cache.get(thumb_data.key)) |entry| {
                entry.exif_orientation = thumb_data.exif_orientation;
                if (thumb_data.full_w > 0 and thumb_data.full_h > 0) {
                    entry.full_w = thumb_data.full_w;
                    entry.full_h = thumb_data.full_h;
                }
                switch (entry.thumbnail) {
                    .loaded => |old_thumb| gpu_dev.releaseTexture(old_thumb.texture),
                    else => {},
                }
                entry.thumbnail = .{
                    .loaded = .{
                        .texture = upload_res.gpu_texture,
                        .info = .{
                            .w = upload_res.w,
                            .h = upload_res.h,
                            .upload_time_ms = upload_res.upload_time_ms,
                        },
                    },
                };
                if (thumb_data.thumb_only) {
                    switch (entry.status) {
                        .decoding => |*dec| dec.has_thread = false,
                        else => {},
                    }
                }
            } else {
                gpu_dev.releaseTexture(upload_res.gpu_texture);
            }
            state.updateCurrentRotation();
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
        if (image.uploadSurfaceToGpu(gpu_dev, surf, state.unpack_compute_pipeline)) |full_res| {
            if (state.cache.get(decoded_data.key)) |entry| {
                switch (entry.status) {
                    .loaded_cpu => |cpu| cpu.surface.destroy(),
                    .loaded_gpu => |gpu| gpu_dev.releaseTexture(gpu.gpu_texture),
                    else => {},
                }
                entry.exif_orientation = decoded_data.exif_orientation;
                entry.status = .{
                    .loaded_gpu = .{
                        .gpu_texture = full_res.gpu_texture,
                        .w = decoded_data.w,
                        .h = decoded_data.h,
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
                state.cache.enforceVramBudget(gpu_dev, state.viewer.navigation.current_index, image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES);
            } else {
                gpu_dev.releaseTexture(full_res.gpu_texture);
            }
            state.updateCurrentRotation();
        }
    } else {
        if (state.cache.get(decoded_data.key)) |entry| {
            switch (entry.status) {
                .loaded_cpu => |cpu| cpu.surface.destroy(),
                else => {},
            }
            entry.exif_orientation = decoded_data.exif_orientation;
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

    try state.workers.event_queue.push(allocator, io, .{ .exif_orientation_parsed = .{ .key = state.cache.activeKey(0), .orientation = 90.0 } });
    const processed1 = drainWorkerEvents(&state);
    try std.testing.expect(processed1);
    try std.testing.expectEqual(@as(f32, 90.0), state.cache.slots.items(.entry)[0].exif_orientation);

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
            .exif_orientation = 0.0,
        },
    });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);

    // Slot 1 should be .loaded_cpu (not uploaded or destroyed) because current slot 0 was not yet loaded
    const entry1 = state.cache.get(state.cache.activeKey(1)).?;
    try std.testing.expect(entry1.status == .loaded_cpu);
}
