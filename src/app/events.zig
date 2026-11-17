const app_state = @import("state.zig");
const core = @import("core");
const geom = @import("geom");
const ipc = @import("ipc");
const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const vfs = @import("vfs");
const workers = @import("workers/root.zig");

const AppState = app_state.AppState;
const EntryScanState = vfs.EntryScanState;
const events = workers.events;
const image = core.image;
const MediaEntry = vfs.MediaEntry;
const MediaId = vfs.MediaId;
const Orientation = probe.Orientation;
const PhysicalDims = geom.PhysicalDims;
const RawMetadata = probe.RawMetadata;

/// Drains all background thread events (e.g. image decodes, thumbnail
/// extractions, directory scans, folder count updates, and IPC commands) from
/// `workers.event_queue`. Dispatches each event to update texture cache
/// entries, image lists, rotation maps, and Command Palette state.
/// Returns `true` if at least one event was drained and processed;
/// otherwise `false`.
pub fn drainWorkerEvents(state: *AppState) bool {
    state.event_batch.clearRetainingCapacity();
    state.workers.event_queue.drain(state.io, &state.event_batch);
    if (state.event_batch.items.len == 0) return false;

    var destroyed_full_surface = state.display.isHidden();
    for (state.event_batch.items, 0..) |*evt, evt_idx| {
        var keep_event_resources = false;
        defer if (!keep_event_resources) evt.deinit(state.allocator);

        switch (evt.*) {
            .exif_orientation_parsed => |*e| if (e.resolve(&state.cache)) |r| {
                if (state.cache.get(r.key)) |entry| {
                    entry.metadata.orientation = r.payload.orientation;
                }
                state.updateCurrentRotation();
            },
            .dimensions_probed => |*d| if (d.resolve(&state.cache)) |r| {
                handleDimensionsProbedEvent(state, r.key, r.payload.*);
            },
            .thumb_decoded => |*t| {
                if (t.resolve(&state.cache)) |r| {
                    const skip_staging = hasSubsequentImageDecoded(
                        state.event_batch.items[evt_idx + 1 ..],
                        r.key,
                        t.job_epoch,
                    );
                    keep_event_resources = handleExifThumbnailEvent(
                        state,
                        r.key,
                        r.payload.*,
                        skip_staging,
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
                if (!state.display.isHidden()) {
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
        (state.display.isHidden() or
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
    if (entry.inflight) |inf| {
        if (inf.has_thread) {
            state.cache.releaseJob(inf.job_id);
        }
    }
    entry.inflight = null;
    switch (entry.resident.asset) {
        .loaded_gpu, .loaded_cpu, .promoting_gpu => {
            entry.resident.thumbnail.markNotAvailableIfUnresolved();
        },
        .none, .failed => {
            entry.resident.asset = .failed;
            entry.resident.thumbnail.discardStagedAndMarkUnavailable();
            if (is_current) {
                state.viewer.image_transition = .none;
                state.viewer.animations.setImmediate(.image_crossfade, 1.0);
            }
        },
    }
}

fn handlePaletteFolderCountEvent(
    state: *AppState,
    cnt: events.PaletteFolderCountPayload,
) void {
    _ = state.viewer.ui.palette.applyFolderScan(cnt.path, cnt.scan);
}

fn handlePrecacheCompletedEvent(
    state: *AppState,
    res: events.PrecacheCompletedPayload,
) void {
    if (!state.viewer.ui.snackbar.enabled or state.display.isHidden()) return;

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
            if (entry.inflight) |*dec| {
                if (dec.has_thread) {
                    state.cache.releaseJob(dec.job_id);
                    dec.has_thread = false;
                }
            }
        }
        entry.resident.thumbnail.markNotAvailableIfUnresolved();
    }
    state.updateCurrentRotation();
}

fn hasSubsequentImageDecoded(
    remaining: []const events.BackgroundEvent,
    key: image.ImageCacheKey,
    job_epoch: u32,
) bool {
    for (remaining) |*evt| {
        switch (evt.*) {
            .image_decoded => |*d| {
                if (d.key.eql(key) and d.job_epoch == job_epoch) {
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
    skip_staging: bool,
) bool {
    const already_loaded = blk: {
        const entry = state.cache.get(key) orelse return false;
        entry.applyProbedMetadata(
            thumb_data.source_dims,
            thumb_data.orientation,
            thumb_data.raw_metadata,
        );
        if (thumb_data.thumb_only) {
            if (entry.inflight) |*dec| {
                if (dec.has_thread) {
                    state.cache.releaseJob(dec.job_id);
                    dec.has_thread = false;
                }
            }
        }
        break :blk entry.resident.asset.isLoaded();
    };
    state.updateCurrentRotation();
    if (skip_staging or already_loaded) {
        return false;
    }

    const entry = state.cache.get(key) orelse return false;
    if (state.gpu_enabled or state.gpu_device != null) {
        entry.resident.thumbnail.deinit(state.gpu_device);
        entry.resident.thumbnail = .{
            .staged_cpu = .{
                .surface = thumb_data.surface,
                .dct_snapped = thumb_data.dct_snapped,
                .source = thumb_data.source,
            },
        };
        return true;
    }

    entry.resident.thumbnail.markNotAvailableIfUnresolved();
    return false;
}

fn handleImageDecodedEvent(
    state: *AppState,
    key: image.ImageCacheKey,
    decoded_data: *events.ImageDecodedPayload,
) void {
    const entry = state.cache.get(key) orelse return;
    if (entry.inflight) |*inf| {
        if (inf.has_thread) {
            state.cache.releaseJob(inf.job_id);
            inf.has_thread = false;
        }
    }
    const surf = decoded_data.surface orelse return;
    entry.inflight = null;
    applyDecodedMetadata(entry, decoded_data);
    entry.resident.thumbnail.discardStagedAndMarkUnavailable();

    const thumb_write: ?image.DeferredThumbWrite =
        if (decoded_data.thumb_write_mtime_sec) |mtime_sec|
            .{ .source_mtime_sec = mtime_sec }
        else
            null;

    const cpu_asset = image.CpuAsset{
        .cpu = .{
            .surface = surf,
            .w = decoded_data.w,
            .h = decoded_data.h,
            .size_bytes = decoded_data.size_bytes,
            .mime_type = decoded_data.mime_type,
            .decode = decoded_data.decode,
        },
        .thumb_write = thumb_write,
    };

    switch (entry.resident.asset) {
        .none, .failed => {
            entry.resident.asset = .{ .loaded_cpu = cpu_asset };
        },
        .loaded_cpu => |*old_cpu| {
            old_cpu.deinit();
            entry.resident.asset = .{ .loaded_cpu = cpu_asset };
        },
        .loaded_gpu => |gpu| {
            entry.resident.asset = .{
                .promoting_gpu = .{
                    .active = gpu,
                    .staged = cpu_asset,
                },
            };
        },
        .promoting_gpu => |*promo| {
            promo.staged.deinit();
            promo.staged = cpu_asset;
        },
    }
    decoded_data.surface = null;
    state.updateCurrentRotation();
}

fn applyDecodedMetadata(
    entry: *image.CacheEntry,
    decoded_data: *const events.ImageDecodedPayload,
) void {
    entry.metadata.orientation = decoded_data.orientation;
    entry.inflight = null;
    if (decoded_data.raw_metadata.getSensorDims()) |s_dims| {
        entry.updateFullDims(s_dims);
    }
    if (decoded_data.source_dims) |s_dims| {
        entry.updateFullDims(s_dims);
    }
    entry.updateFullDims(.{ .w = decoded_data.w, .h = decoded_data.h });
    entry.metadata.raw_metadata = if (decoded_data.raw_metadata.isRaw())
        if (entry.metadata.full_dims) |fd|
            RawMetadata.fromDims(fd)
        else
            decoded_data.raw_metadata
    else
        .none;
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
        state.viewer.ui.palette.rebuildFileMatches(
            state.allocator,
            state.viewer.navigation.getEntries(),
        ) catch |err| {
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
        state.viewer.navigation.resetDirectoryArena();
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
            _ = state.viewer.navigation.goToIndex(
                target_i,
                sdl.timer.getTicks(),
            );
        } else {
            _ = state.viewer.navigation.adjustIndexForVisibility();
        }
    }
    state.viewer.navigation.trimExcessCapacity(state.allocator);
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
        .inflight = .{ .has_thread = true },
    });

    try state.workers.event_queue.push(allocator, io, .{
        .exif_orientation_parsed = .init(
            state.cache.activeKey(id0),
            0,
            .{ .orientation = .rotate_90 },
        ),
    });
    const processed1 = drainWorkerEvents(&state);
    try std.testing.expect(processed1);
    try std.testing.expectEqual(
        Orientation.rotate_90,
        state.cache.slots.items(.entry)[0].metadata.orientation,
    );

    try state.workers.event_queue.push(allocator, io, .{
        .decode_failed = .init(state.cache.activeKey(id0), 0, .{}),
    });
    const processed2 = drainWorkerEvents(&state);
    try std.testing.expect(processed2);
    const fail_asset = state.cache.slots.items(.entry)[0].resident.asset;
    try std.testing.expectEqual(@as(@TypeOf(fail_asset), .failed), fail_asset);
}

test "drainWorkerEvents - directory_scan_result and ipc_command" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var scan_arena = std.heap.ArenaAllocator.init(allocator);
    const scan_alloc = scan_arena.allocator();
    const target_path = try scan_alloc.dupe(u8, "/imgs/b.jpg");
    const path0 = try scan_alloc.dupe(u8, "/imgs/a.jpg");
    const path1 = try scan_alloc.dupe(u8, "/imgs/b.jpg");
    const paths_slice = try scan_alloc.alloc(MediaEntry, 2);
    paths_slice[0] = .{ .filesystem = .{ .path = path0 } };
    paths_slice[1] = .{ .filesystem = .{ .path = path1 } };

    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(0, .{
            .arena = scan_arena,
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

test "drainWorkerEvents - directory_scan_result is_dir trims excess capacity" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Pre-allocate large capacity simulating prior massive directory scan.
    try state.viewer.navigation.items.ensureTotalCapacity(allocator, 1000);
    try std.testing.expect(state.viewer.navigation.items.capacity >= 1000);

    var scan_arena = std.heap.ArenaAllocator.init(allocator);
    const scan_alloc = scan_arena.allocator();
    const target_path = try scan_alloc.dupe(u8, "/imgs");
    const path0 = try scan_alloc.dupe(u8, "/imgs/a.jpg");
    const path1 = try scan_alloc.dupe(u8, "/imgs/b.jpg");
    const paths_slice = try scan_alloc.alloc(MediaEntry, 2);
    paths_slice[0] = .{ .filesystem = .{ .path = path0 } };
    paths_slice[1] = .{ .filesystem = .{ .path = path1 } };

    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(0, .{
            .arena = scan_arena,
            .target_path = target_path,
            .is_dir = true,
            .paths = paths_slice,
        }),
    });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);
    try std.testing.expectEqual(
        @as(usize, 2),
        state.viewer.navigation.count(),
    );
    try std.testing.expectEqual(
        @as(usize, 64),
        state.viewer.navigation.items.capacity,
    );
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
        .inflight = .{ .has_thread = true },
    });

    // Slot 1 is decoding
    _ = try state.cache.appendSlot(allocator, id1, .{
        .inflight = .{ .has_thread = true },
    });

    const surf = sdl.Surface.create(
        10,
        10,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;

    // Neighbor index 1 finishes decoding before index 0
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(state.cache.activeKey(id1), 0, .{
            .surface = surf,
            .w = 10,
            .h = 10,
            .mime_type = "image/png",
            .size_bytes = 100,
            .orientation = .normal,
            .decode = .{
                .read_time_ms = 1.0,
                .decode_time_ms = 2.0,
                .conversion_time_ms = 0.0,
            },
        }),
    });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);

    // Slot 1 should be .loaded_cpu (not uploaded or destroyed) because current
    // slot 0 was not yet loaded
    const entry1 = state.cache.get(state.cache.activeKey(id1)).?;
    try std.testing.expect(entry1.resident.asset == .loaded_cpu);
}

test "drainWorkerEvents - dimensions_probed sets dimensions and clears has_thread" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const id0 = MediaId.fromU32(1);
    _ = try state.cache.appendSlot(allocator, id0, .{
        .inflight = .{ .has_thread = true },
    });

    try state.workers.event_queue.push(allocator, io, .{
        .dimensions_probed = .init(state.cache.activeKey(id0), 0, .{
            .source_dims = .{ .w = 1920.0, .h = 1080.0 },
            .orientation = .normal,
            .thumb_only = true,
        }),
    });

    const processed = drainWorkerEvents(&state);
    try std.testing.expect(processed);

    const entry = state.cache.get(state.cache.activeKey(id0)).?;
    try std.testing.expectEqual(
        PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        entry.metadata.full_dims.?,
    );
    try std.testing.expect(!entry.inflight.?.has_thread);
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
        EntryScanState.unscanned,
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
    const expected_dir_scan = EntryScanState{
        .scanned = .{ .image_count = 12, .subdir_count = 3 },
    };
    try std.testing.expectEqual(
        expected_dir_scan,
        state.viewer.ui.palette.dir_items.items[0].directory.scan,
    );
    const expected_archive_scan = EntryScanState{
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
        EntryScanState.permission_denied,
        state.viewer.ui.palette.dir_items.items[0].directory.scan,
    );
    try std.testing.expectEqual(
        EntryScanState.failed,
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
        .inflight = .{ .has_thread = true },
    });
    const key1 = try state.cache.appendSlot(
        allocator,
        id1,
        image.CacheEntry.stubLoadedGpuForTest(
            .{ .w = 1600, .h = 1200 },
            .{ .w = 0, .h = 0 },
        ),
    );
    const expected_vram: usize = 1600 * 1200 * 4;
    const entry1 = state.cache.get(key1).?;
    entry1.inflight = .{ .stage = .decoding };
    try std.testing.expectEqual(expected_vram, state.cache.getTotalVramBytes());

    // 1. If decode fails while .loaded_gpu, keep .loaded_gpu and clear
    // inflight instead of clobbering with .failed.
    handleDecodeFailedEvent(&state, key1, true);
    try std.testing.expect(entry1.inflight == null);
    try std.testing.expect(entry1.resident.asset.hasGpuTexture());
    try std.testing.expectEqual(expected_vram, state.cache.getTotalVramBytes());

    // 2. When a promotion finishes decoding on CPU, .loaded_gpu transitions
    // to .promoting_gpu, keeping the active GPU texture and VRAM intact.
    entry1.inflight = .{ .stage = .decoding };
    const promoted_surf = sdl.Surface.create(
        32,
        24,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;

    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key1, 0, .{
            .surface = promoted_surf,
            .w = 32,
            .h = 24,
            .mime_type = "image/jpeg",
            .size_bytes = 3072,
            .orientation = .normal,
            .decode = .{
                .read_time_ms = 1.0,
                .decode_time_ms = 2.0,
                .conversion_time_ms = 0.0,
            },
        }),
    });

    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expect(entry1.inflight == null);
    switch (entry1.resident.asset) {
        .promoting_gpu => |*promo| {
            try std.testing.expectEqual(@as(f32, 32.0), promo.staged.cpu.w);
            promo.staged.deinit();
            entry1.resident.asset = .none;
        },
        .none, .loaded_cpu, .loaded_gpu, .failed => {
            return error.TestExpectedPromotingGpu;
        },
    }
    try std.testing.expectEqual(@as(usize, 0), state.cache.getTotalVramBytes());

    // 3. Initial decode failure on slot 0 transitions to .failed
    const key0 = state.cache.activeKey(id0);
    const entry0 = state.cache.get(key0).?;
    handleDecodeFailedEvent(&state, key0, true);
    try std.testing.expect(entry0.resident.asset.isFailed());
}

test "drainWorkerEvents - monotonic full_dims on pair promotion" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.navigation.current_index = 0;
    const id0 = MediaId.fromU32(1);
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .inflight = .{ .has_thread = true },
    });
    const entry0 = state.cache.get(key0).?;

    // 1. Initial preview decode at 1616x1080 sets full_dims to 1616x1080
    const preview_surf = sdl.Surface.create(
        16,
        10,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, 0, .{
            .surface = preview_surf,
            .w = 1616,
            .h = 1080,
            .mime_type = "image/jpeg",
            .size_bytes = 500_000,
            .orientation = .normal,
            .raw_metadata = RawMetadata.init(1616, 1080),
            .decode = .{
                .read_time_ms = 1.0,
                .decode_time_ms = 2.0,
                .conversion_time_ms = 0.0,
            },
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        PhysicalDims{ .w = 1616, .h = 1080 },
        entry0.metadata.full_dims.?,
    );
    try std.testing.expect(entry0.metadata.raw_metadata.isRaw());

    // 2. Promotion to 6000x4000 standalone JPEG upgrades full_dims
    entry0.inflight = .{ .stage = .decoding };
    const full_surf = sdl.Surface.create(
        60,
        40,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, 0, .{
            .surface = full_surf,
            .w = 6000,
            .h = 4000,
            .mime_type = "image/jpeg",
            .size_bytes = 4_000_000,
            .orientation = .normal,
            .raw_metadata = .none,
            .decode = .{
                .read_time_ms = 2.0,
                .decode_time_ms = 5.0,
                .conversion_time_ms = 0.0,
            },
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        PhysicalDims{ .w = 6000, .h = 4000 },
        entry0.metadata.full_dims.?,
    );
    try std.testing.expect(!entry0.metadata.raw_metadata.isRaw());
    const auth = entry0.getAuthoritativeDims();
    try std.testing.expectEqual(@as(f32, 6000), auth.w);
    try std.testing.expectEqual(@as(f32, 4000), auth.h);

    // 3. Toggling back to 1616x1080 preview does not regress full_dims
    entry0.inflight = .{ .stage = .decoding };
    const toggle_surf = sdl.Surface.create(
        16,
        10,
        sdl.PixelFormat.rgba32,
    ) orelse return error.SurfaceFailed;
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, 0, .{
            .surface = toggle_surf,
            .w = 1616,
            .h = 1080,
            .mime_type = "image/jpeg",
            .size_bytes = 500_000,
            .orientation = .normal,
            .raw_metadata = RawMetadata.init(1616, 1080),
            .decode = .{
                .read_time_ms = 1.0,
                .decode_time_ms = 2.0,
                .conversion_time_ms = 0.0,
            },
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        PhysicalDims{ .w = 6000, .h = 4000 },
        entry0.metadata.full_dims.?,
    );
    try std.testing.expect(entry0.metadata.raw_metadata.isRaw());
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
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = surf,
                        .w = 16,
                        .h = 16,
                        .size_bytes = 1024,
                    },
                },
            },
        },
    });
    const gen_before = state.cache.generation.load(.acquire);

    var scan_arena1 = std.heap.ArenaAllocator.init(allocator);
    const scan_alloc1 = scan_arena1.allocator();
    const paths1 = try scan_alloc1.alloc(MediaEntry, 3);
    paths1[0] = .{
        .filesystem = .{ .path = try scan_alloc1.dupe(u8, "a.jpg") },
    };
    paths1[1] = .{
        .filesystem = .{ .path = try scan_alloc1.dupe(u8, "b.jpg") },
    };
    paths1[2] = .{
        .filesystem = .{ .path = try scan_alloc1.dupe(u8, "c.jpg") },
    };
    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(0, .{
            .arena = scan_arena1,
            .target_path = try scan_alloc1.dupe(u8, "c.jpg"),
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
        .inflight = .{ .has_thread = true },
    });

    var scan_arena2 = std.heap.ArenaAllocator.init(allocator);
    const scan_alloc2 = scan_arena2.allocator();
    const paths2 = try scan_alloc2.alloc(MediaEntry, 2);
    paths2[0] = .{
        .filesystem = .{ .path = try scan_alloc2.dupe(u8, "a.jpg") },
    };
    paths2[1] = .{
        .filesystem = .{ .path = try scan_alloc2.dupe(u8, "b.jpg") },
    };
    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(gen_before, .{
            .arena = scan_arena2,
            .target_path = try scan_alloc2.dupe(u8, "b.jpg"),
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
    var scan_arena = std.heap.ArenaAllocator.init(allocator);
    const scan_alloc = scan_arena.allocator();
    const stale_paths = try scan_alloc.alloc(MediaEntry, 1);
    stale_paths[0] = .{
        .filesystem = .{ .path = try scan_alloc.dupe(u8, "stale.jpg") },
    };
    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(cur_gen - 1, .{
            .arena = scan_arena,
            .target_path = try scan_alloc.dupe(u8, "."),
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
        .inflight = .{ .has_thread = true },
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
        .decode_failed = .init(key1, 0, .{}),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        image.ResidentAsset.failed,
        state.cache.get(key1).?.resident.asset,
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

    var scan_arena = std.heap.ArenaAllocator.init(allocator);
    const scan_alloc = scan_arena.allocator();
    const items = try scan_alloc.alloc(MediaEntry, 2);
    items[0] = .{
        .filesystem = .{ .path = try scan_alloc.dupe(u8, "a.jpg") },
    };
    items[1] = .{
        .filesystem = .{ .path = try scan_alloc.dupe(u8, "b.jpg") },
    };
    const target_dup = try scan_alloc.dupe(u8, "/test");

    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(
            state.cache.generation.load(.acquire),
            .{
                .arena = scan_arena,
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
        .inflight = .{ .has_thread = true },
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = main_surf,
                        .w = 32.0,
                        .h = 32.0,
                        .size_bytes = 4096,
                        .mime_type = "image/jpeg",
                        .decode = .{},
                    },
                },
            },
            .thumbnail = .{ .unloaded = .{
                .w = 16.0,
                .h = 16.0,
                .upload_time_ms = 0.0,
                .dct_snapped = false,
            } },
        },
    });
    const entry = state.cache.get(key0).?;

    const thumb_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32).?;
    try state.workers.event_queue.push(allocator, io, .{
        .thumb_decoded = .init(key0, 0, .{
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
        PhysicalDims{ .w = 6000.0, .h = 4000.0 },
        entry.metadata.full_dims.?,
    );
    try std.testing.expectEqual(
        Orientation.rotate_90,
        entry.metadata.orientation,
    );
    try std.testing.expect(entry.resident.thumbnail == .unloaded);
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
        .inflight = .{ .has_thread = true },
    });
    const cur_gen = state.cache.generation.load(.acquire);

    // 2. Directory scan result returns 100 files with img_050.jpg at index 49
    var scan_arena = std.heap.ArenaAllocator.init(allocator);
    const scan_alloc = scan_arena.allocator();
    const paths = try scan_alloc.alloc(MediaEntry, 100);
    for (paths, 0..) |*p, i| {
        var buf: [32]u8 = undefined;
        const name = try std.mem.print(&buf, "img_{d:0>3}.jpg", .{i + 1});
        p.* = .{ .filesystem = .{ .path = try scan_alloc.dupe(u8, name) } };
    }

    try state.workers.event_queue.push(allocator, io, .{
        .directory_scan_result = .init(cur_gen, .{
            .arena = scan_arena,
            .target_path = try scan_alloc.dupe(u8, "img_050.jpg"),
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
        .image_decoded = .init(key0, 0, .{
            .surface = surf,
            .w = 10.0,
            .h = 10.0,
            .size_bytes = 400,
            .mime_type = "image/jpeg",
            .orientation = .normal,
            .raw_metadata = .none,
            .decode = .{},
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expect(
        state.cache.get(key0).?.resident.asset == .loaded_cpu,
    );
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
        .inflight = .{ .has_thread = true },
    });
    const entry = state.cache.get(key0).?;

    const thumb_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32).?;
    const full_surf = sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32).?;

    // Push both thumb_decoded and image_decoded in same batch
    try state.workers.event_queue.push(allocator, io, .{
        .thumb_decoded = .init(key0, 0, .{
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
        .image_decoded = .init(key0, 0, .{
            .surface = full_surf,
            .w = 64.0,
            .h = 64.0,
            .size_bytes = 4096,
            .mime_type = "image/jpeg",
            .orientation = .normal,
            .raw_metadata = .none,
            .decode = .{},
        }),
    });

    try std.testing.expect(drainWorkerEvents(&state));

    // Thumbnail upload was skipped, so entry.thumbnail is not .loaded
    try std.testing.expect(entry.resident.thumbnail != .loaded);
    // Full image is loaded
    try std.testing.expect(entry.resident.asset == .loaded_cpu);
    // thumb_crossfade animation is NOT active
    try std.testing.expect(!state.viewer.animations.isActive(.thumb_crossfade));
}

test "handleImageDecodedEvent - keeps loaded_gpu and stages promoting_gpu" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = try dir_alloc.dupe(u8, "active.jpg") },
    });
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = try dir_alloc.dupe(u8, "promoted.jpg") },
    });
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;

    // Slide 0 (current) is still decoding in-flight (not ready)
    _ = try state.cache.appendSlot(allocator, id0, .{
        .inflight = .{ .has_thread = true },
    });

    // Slide 1 (non-current) already has a loaded GPU texture
    const key1 = try state.cache.appendSlot(
        allocator,
        id1,
        image.CacheEntry.stubLoadedGpuForTest(
            .{ .w = 16.0, .h = 16.0 },
            .{ .w = 0.0, .h = 0.0 },
        ),
    );
    defer {
        if (state.cache.get(key1)) |e| {
            switch (e.resident.asset) {
                .promoting_gpu => |*promo| promo.staged.deinit(),
                .none, .loaded_cpu, .loaded_gpu, .failed => {},
            }
            e.resident.asset = .none;
        }
    }

    // Promotion finishes decoding on CPU for slide 1
    const promo_surf = sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse
        return;
    var decoded = events.ImageDecodedPayload{
        .surface = promo_surf,
        .w = 32.0,
        .h = 32.0,
        .size_bytes = 32 * 32 * 4,
        .mime_type = "image/jpeg",
        .orientation = .normal,
        .raw_metadata = .none,
        .decode = .{
            .read_time_ms = 1.0,
            .decode_time_ms = 1.0,
            .conversion_time_ms = 1.0,
        },
    };
    defer if (decoded.surface) |s| s.destroy();

    handleImageDecodedEvent(&state, key1, &decoded);

    // Slide 1 transitions to .promoting_gpu keeping 16x16 active GPU and
    // staging 32x32 CPU surface
    const entry1 = state.cache.get(key1).?;
    try std.testing.expect(decoded.surface == null);
    switch (entry1.resident.asset) {
        .promoting_gpu => |promo| {
            try std.testing.expectEqual(@as(f32, 16.0), promo.active.w);
            try std.testing.expectEqual(@as(f32, 32.0), promo.staged.cpu.w);
        },
        .none, .loaded_cpu, .loaded_gpu, .failed => {
            return error.TestExpectedPromotingGpu;
        },
    }
}

test "drainWorkerEvents - stages staged_cpu and cancels on image_decoded" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();
    state.gpu_enabled = true;

    const id0 = MediaId.fromU32(1);
    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .inflight = .{ .has_thread = true },
    });

    const thumb_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    try state.workers.event_queue.push(allocator, io, .{
        .thumb_decoded = .init(key0, 0, .{
            .surface = thumb_surf,
            .w = 16.0,
            .h = 16.0,
            .source_dims = .{ .w = 64.0, .h = 64.0 },
            .orientation = .normal,
            .thumb_only = false,
            .dct_snapped = true,
        }),
    });

    try std.testing.expect(drainWorkerEvents(&state));
    const entry0 = state.cache.get(key0).?;
    switch (entry0.resident.thumbnail) {
        .staged_cpu => |st| try std.testing.expect(st.dct_snapped),
        .none, .pending, .not_available, .unloaded, .loaded => {
            return error.TestExpectedStagedCpu;
        },
    }

    // Subsequent image_decoded discards staged_cpu and sets .loaded_cpu
    const full_surf = sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    try state.workers.event_queue.push(allocator, io, .{
        .image_decoded = .init(key0, 0, .{
            .surface = full_surf,
            .w = 64.0,
            .h = 64.0,
            .size_bytes = 4096,
            .mime_type = "image/jpeg",
            .orientation = .normal,
            .raw_metadata = .none,
            .decode = .{},
            .thumb_write_mtime_sec = 12345,
        }),
    });

    try std.testing.expect(drainWorkerEvents(&state));
    try std.testing.expectEqual(
        image.ThumbnailState.not_available,
        entry0.resident.thumbnail,
    );
    switch (entry0.resident.asset) {
        .loaded_cpu => |asset| {
            try std.testing.expectEqual(
                @as(i64, 12345),
                asset.thumb_write.?.source_mtime_sec,
            );
        },
        .none, .loaded_gpu, .promoting_gpu, .failed => {
            return error.TestExpectedLoadedCpu;
        },
    }
}

test "drainWorkerEvents - neighbor thumb_decoded then decode_failed" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();
    state.gpu_enabled = true;

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = try dir_alloc.dupe(u8, "active.jpg") },
    });
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = try dir_alloc.dupe(u8, "corrupt.jpg") },
    });
    state.viewer.navigation.current_index = 0;

    const id0 = state.viewer.navigation.getIdAt(0).?;
    const id1 = state.viewer.navigation.getIdAt(1).?;
    const key0 = try state.cache.appendSlot(
        allocator,
        id0,
        image.CacheEntry.stubLoadedGpuForTest(
            .{ .w = 16.0, .h = 16.0 },
            .{ .w = 0.0, .h = 0.0 },
        ),
    );
    defer {
        if (state.cache.get(key0)) |e| {
            e.resident.asset = .none;
        }
    }

    const key1 = try state.cache.appendSlot(allocator, id1, .{
        .inflight = .{ .has_thread = true },
    });

    const thumb_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;
    try state.workers.event_queue.push(allocator, io, .{
        .thumb_decoded = .init(key1, 0, .{
            .surface = thumb_surf,
            .w = 16.0,
            .h = 16.0,
            .source_dims = .{ .w = 64.0, .h = 64.0 },
            .orientation = .normal,
            .thumb_only = false,
            .dct_snapped = false,
        }),
    });
    try std.testing.expect(drainWorkerEvents(&state));

    const neighbors = state.viewer.navigation.getVisibleNeighbors().?;
    const entry1_thumb = state.cache.get(key1).?.resident.thumbnail;
    try std.testing.expect(entry1_thumb.isStagedCpu());
    try std.testing.expect(state.cache.hasPendingCpuUploads(true));
    try std.testing.expect(state.cache.hasUnreadyPrefetchSlots(
        &state.viewer.navigation,
        neighbors,
        true,
    ));

    try state.workers.event_queue.push(allocator, io, .{
        .decode_failed = .init(key1, 0, .{}),
    });
    try std.testing.expect(drainWorkerEvents(&state));

    const entry1 = state.cache.get(key1).?;
    try std.testing.expectEqual(
        image.ResidentAsset.failed,
        entry1.resident.asset,
    );
    try std.testing.expectEqual(
        image.ThumbnailState.not_available,
        entry1.resident.thumbnail,
    );
    try std.testing.expect(!state.cache.hasPendingCpuUploads(true));
    try std.testing.expect(!state.cache.hasUnreadyPrefetchSlots(
        &state.viewer.navigation,
        neighbors,
        true,
    ));
}
