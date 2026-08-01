const std = @import("std");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;
const events = @import("events");
const image = @import("../image.zig");
const cache_system = @import("cache.zig");
const ipc = @import("ipc");

/// System function that drains background thread events (`image_decoded`, `path_scanned`, `ipc_command`)
/// from `workers.event_queue` and updates cache slots, navigation list, and pending IPC lists.
pub fn sysProcessBackgroundEvents(state: *AppState) bool {
    state.event_batch.clearRetainingCapacity();
    state.workers.event_queue.drain(state.allocator, state.io, &state.event_batch) catch return false;
    if (state.event_batch.items.len == 0) return false;
    const current_gen = state.viewer.generation;

    for (state.event_batch.items) |*evt| {
        defer evt.deinit(state.allocator);

        switch (evt.*) {
            .exif_orientation_parsed => |e| {
                if (state.cache.getWithGeneration(e.index, current_gen)) |entry| {
                    entry.exif_orientation = e.orientation;
                }
                state.updateCurrentRotation();
            },
            .thumb_decoded => |t| handleExifThumbnailEvent(state, t),
            .image_decoded => |*d| handleImageDecodedEvent(state, d),
            .decode_failed => |f| {
                _ = state.cache.updateStatus(f.index, current_gen, .failed);
            },
            .path_discovered => |p| handleDirScannedEvent(state, p),
            .directory_scan_result => |res| handleDirectoryScanResultEvent(state, res),
            .directory_scan_complete => {},
            .ipc_command => |cmd_data| {
                state.pending_ipc_commands.append(state.allocator, cmd_data) catch |err| {
                    std.log.err("Failed to append IPC command to pending list: {}", .{err});
                };
            },
        }
    }
    return true;
}

fn handleExifThumbnailEvent(state: *AppState, thumb_data: events.ThumbDecodedPayload) void {
    const surf = thumb_data.surface orelse return;
    const current_gen = state.viewer.generation;
    if (state.gpu_device) |gpu_dev| {
        if (image.uploadSurfaceToGpu(gpu_dev, surf, state.unpack_compute_pipeline)) |upload_res| {
            if (state.cache.getWithGeneration(thumb_data.index, current_gen)) |entry| {
                entry.thumb_gpu_texture = upload_res.gpu_texture;
                entry.thumb_w = upload_res.w;
                entry.thumb_h = upload_res.h;
                entry.exif_orientation = thumb_data.exif_orientation;
                if (thumb_data.full_w > 0 and thumb_data.full_h > 0) {
                    entry.full_w = thumb_data.full_w;
                    entry.full_h = thumb_data.full_h;
                }
                entry.has_thumb = true;
                entry.thumb_upload_time_ms = upload_res.upload_time_ms;
            } else {
                gpu_dev.releaseTexture(upload_res.gpu_texture);
            }
            state.updateCurrentRotation();
        }
    }
}

fn handleImageDecodedEvent(state: *AppState, decoded_data: *events.ImageDecodedPayload) void {
    const surf = decoded_data.surface orelse return;
    const current_gen = state.viewer.generation;
    if (state.gpu_device) |gpu_dev| {
        if (image.uploadSurfaceToGpu(gpu_dev, surf, state.unpack_compute_pipeline)) |full_res| {
            if (state.cache.getWithGeneration(decoded_data.index, current_gen)) |entry| {
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
                        .decode_time_ms = decoded_data.decode_time_ms,
                        .conversion_time_ms = full_res.conversion_time_ms,
                        .upload_time_ms = full_res.upload_time_ms,
                        .memory_size_bytes = full_res.memory_size_bytes,
                        .num_mip_levels = full_res.num_mip_levels,
                        .mipmap_time_ms = full_res.mipmap_time_ms,
                        .was_fallback = full_res.was_fallback,
                        .fallback_time_ms = full_res.fallback_time_ms,
                        .has_thumb = entry.has_thumb,
                        .thumb_w = entry.thumb_w,
                        .thumb_h = entry.thumb_h,
                        .thumb_upload_time_ms = entry.thumb_upload_time_ms,
                    },
                };
                state.cache.enforceVramBudget(gpu_dev, state.viewer.navigation.current_index, image.CacheSlotMap.DEFAULT_MAX_VRAM_BYTES);
            } else {
                gpu_dev.releaseTexture(full_res.gpu_texture);
            }
            state.updateCurrentRotation();
        }
    } else {
        if (state.cache.getWithGeneration(decoded_data.index, current_gen)) |entry| {
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
                    .decode_time_ms = decoded_data.decode_time_ms,
                    .conversion_time_ms = decoded_data.conversion_time_ms,
                    .has_thumb = entry.has_thumb,
                    .thumb_w = entry.thumb_w,
                    .thumb_h = entry.thumb_h,
                    .thumb_upload_time_ms = entry.thumb_upload_time_ms,
                },
            };
            decoded_data.surface = null;
        }
        state.updateCurrentRotation();
    }
}

fn handleDirScannedEvent(state: *AppState, scanned_data: events.PathDiscoveredPayload) void {
    const dup = state.viewer.navigation.directory_arena.allocator().dupe(u8, scanned_data.path) catch |err| {
        std.log.err("Failed to duplicate path '{s}' in directory arena: {}", .{ scanned_data.path, err });
        return;
    };
    state.viewer.navigation.image_list.append(state.allocator, dup) catch |err| std.log.err("Failed to append discovered path to image_list: {}", .{err});
    if (state.viewer.navigation.current_index == null and state.viewer.navigation.image_list.items.len > 0) {
        state.viewer.navigation.current_index = 0;
    }
}

fn handleDirectoryScanResultEvent(state: *AppState, result_data: events.DirectoryScanResultPayload) void {
    if (result_data.is_dir) {
        for (result_data.paths) |item| {
            const dup = state.viewer.navigation.directory_arena.allocator().dupe(u8, item) catch |err| {
                std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                continue;
            };
            state.viewer.navigation.image_list.append(state.allocator, dup) catch |err| {
                std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
            };
        }
        if (state.viewer.navigation.current_index == null and state.viewer.navigation.image_list.items.len > 0) {
            state.viewer.navigation.current_index = 0;
        }
    } else {
        var target_idx_in_dir: ?usize = null;
        for (result_data.paths, 0..) |item, i| {
            if (std.mem.eql(u8, item, result_data.target_path)) {
                target_idx_in_dir = i;
                break;
            }
        }

        _ = state.viewer.navigation.directory_arena.reset(.retain_capacity);
        state.viewer.navigation.image_list.clearRetainingCapacity();
        for (result_data.paths, 0..) |item, i| {
            const dup = state.viewer.navigation.directory_arena.allocator().dupe(u8, item) catch |err| {
                std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                continue;
            };
            state.viewer.navigation.image_list.append(state.allocator, dup) catch |err| {
                std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
            };
            if (target_idx_in_dir == null and std.mem.eql(u8, item, result_data.target_path)) {
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

test "sysProcessBackgroundEvents - empty queue" {
    const allocator = std.testing.allocator;
    var state = try AppState.initHeadless(allocator, std.Io.Threaded.global_single_threaded.io());
    defer state.deinit();

    const processed = sysProcessBackgroundEvents(&state);
    try std.testing.expect(!processed);
}

test "sysProcessBackgroundEvents - path_discovered" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const path_dup = try allocator.dupe(u8, "/test/path.jpg");
    try state.workers.event_queue.push(allocator, io, .{ .path_discovered = .{ .path = path_dup } });

    const processed = sysProcessBackgroundEvents(&state);
    try std.testing.expect(processed);
    try std.testing.expect(state.viewer.dirty);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.navigation.image_list.items.len);
    try std.testing.expectEqual(@as(?usize, 0), state.viewer.navigation.current_index);
}

test "sysProcessBackgroundEvents - exif_orientation_parsed & decode_failed" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.cache.append(allocator, .{
        .index = 0,
        .generation = state.viewer.generation,
        .status = .{ .decoding = .{ .has_thread = true } },
    });

    try state.workers.event_queue.push(allocator, io, .{ .exif_orientation_parsed = .{ .index = 0, .orientation = 90.0 } });
    const processed1 = sysProcessBackgroundEvents(&state);
    try std.testing.expect(processed1);
    try std.testing.expectEqual(@as(f32, 90.0), state.cache.entries.items[0].exif_orientation);

    try state.workers.event_queue.push(allocator, io, .{ .decode_failed = .{ .index = 0 } });
    const processed2 = sysProcessBackgroundEvents(&state);
    try std.testing.expect(processed2);
    try std.testing.expectEqual(@as(@TypeOf(state.cache.entries.items[0].status), .failed), state.cache.entries.items[0].status);
}

test "sysProcessBackgroundEvents - directory_scan_result and ipc_command" {
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

    const processed = sysProcessBackgroundEvents(&state);
    try std.testing.expect(processed);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.navigation.image_list.items.len);
    try std.testing.expectEqual(@as(?usize, 1), state.viewer.navigation.current_index);
    try std.testing.expectEqual(@as(usize, 1), state.pending_ipc_commands.items.len);
}
