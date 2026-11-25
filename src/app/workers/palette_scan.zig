const context = @import("context.zig");
const events = @import("events.zig");
const manager = @import("manager.zig");
const std = @import("std");
const vfs = @import("vfs");

const collectUnscannedDirectoryPaths = vfs.collectUnscannedDirectoryPaths;
const DirectoryEntry = vfs.DirectoryEntry;
const freeOwnedStringSlice = vfs.freeOwnedStringSlice;
const getChildBasename = vfs.getChildBasename;
const getParentDirBuf = vfs.getParentDirBuf;
const scanDirectoryEntries = vfs.scanDirectoryEntries;
const scanFolderContents = vfs.scanFolderContents;
const WorkerManager = manager.WorkerManager;

/// Maximum memory bytes retained across Stage 1 walk-up arena resets (64 KiB).
const MAX_RETAINED_STAGE1_ARENA_BYTES: usize = 64 * 1024;

/// Arguments passed to the background palette directory scan worker thread.
pub const PaletteScanArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    generation: usize,
    current_generation: *const std.atomic.Value(usize),
    active_dir_scans: *std.atomic.Value(usize),
    target_dir: []const u8,
    resolve_child_from: ?[]const u8 = null,
    walk_up_if_empty: bool = false,

    /// Builds a cooperative cancellation token for this palette scan task.
    pub inline fn cancelToken(
        self: *const PaletteScanArgs,
    ) context.CancellationToken {
        return .{
            .exiting = &self.workers.exiting,
            .generation = self.generation,
            .current_generation = self.current_generation,
        };
    }
};

/// Duplicates `target_dir` (and optional `resolve_child_from`), allocates task
/// parameters, and dispatches a two-stage background `paletteScanWorker` task.
pub fn spawnPaletteScan(
    workers: *WorkerManager,
    gpa: std.mem.Allocator,
    io: std.Io,
    generation: usize,
    current_generation: *const std.atomic.Value(usize),
    active_dir_scans: *std.atomic.Value(usize),
    target_dir: []const u8,
    resolve_child_from: ?[]const u8,
    walk_up_if_empty: bool,
) !void {
    const dup_dir = try gpa.dupe(u8, target_dir);
    errdefer gpa.free(dup_dir);

    const dup_resolve = if (resolve_child_from) |src|
        try gpa.dupe(u8, src)
    else
        null;
    errdefer if (dup_resolve) |p| gpa.free(p);

    const args = try gpa.create(PaletteScanArgs);
    errdefer gpa.destroy(args);

    args.* = .{
        .workers = workers,
        .allocator = gpa,
        .io = io,
        .generation = generation,
        .current_generation = current_generation,
        .active_dir_scans = active_dir_scans,
        .target_dir = dup_dir,
        .resolve_child_from = dup_resolve,
        .walk_up_if_empty = walk_up_if_empty,
    };

    _ = active_dir_scans.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);
    workers.group.async(io, paletteScanWorker, .{args});
}

/// Background worker task executing two-stage Command Palette directory
/// loading:
/// 1. Stage 1: Scans `args.target_dir` (walking up parent directories when
///    `walk_up_if_empty` is `true` and zero entries are found) into a worker
///    arena and pushes `.palette_dir_loaded` for O(1) main-thread handoff.
/// 2. Stage 2: Iterates collected unscanned subdirectories and archives,
///    counting their contents and pushing `.palette_folder_count` events.
pub fn paletteScanWorker(args: *PaletteScanArgs) void {
    const workers = args.workers;
    const gpa = args.allocator;
    const io = args.io;
    const active_dir_scans = args.active_dir_scans;
    const cancel = args.cancelToken();

    defer {
        if (args.resolve_child_from) |p| gpa.free(p);
        gpa.free(args.target_dir);
        gpa.destroy(args);
        _ = active_dir_scans.fetchSub(1, .release);
        _ = workers.active_threads.fetchSub(1, .release);
        workers.wakeMainThread();
    }

    if (cancel.isCanceled()) return;

    var arena = std.heap.ArenaAllocator.init(gpa);
    var owns_arena = true;
    defer if (owns_arena) arena.deinit();

    var entries: std.ArrayList(DirectoryEntry) = .empty;
    var curr_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var curr_dir_sfa: std.heap.BufferFirstAllocator = .init(
        &curr_dir_buf,
        gpa,
    );
    const dir_alloc = curr_dir_sfa.allocator();
    var owned_curr_dir: ?[]const u8 = null;
    defer if (owned_curr_dir) |d| dir_alloc.free(d);

    var preselect_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var preselect_sfa: std.heap.BufferFirstAllocator = .init(
        &preselect_buf,
        gpa,
    );
    const pre_alloc = preselect_sfa.allocator();
    var preselect: ?[]const u8 = null;
    defer if (preselect) |p| pre_alloc.free(p);

    var parent_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var child_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    var curr_dir: []const u8 = args.target_dir;
    var current_dir_image_count: usize = 0;

    while (true) {
        if (cancel.isCanceled()) return;

        current_dir_image_count = scanDirectoryEntries(
            arena.allocator(),
            io,
            curr_dir,
            &entries,
        ) catch |err| blk: {
            std.log.warn(
                "Failed to scan palette directory '{s}': {}",
                .{ curr_dir, err },
            );
            entries = .empty;
            _ = arena.reset(.{
                .retain_with_limit = MAX_RETAINED_STAGE1_ARENA_BYTES,
            });
            break :blk 0;
        };

        if (cancel.isCanceled()) return;
        if (!args.walk_up_if_empty or entries.items.len > 0) break;

        const parent = getParentDirBuf(curr_dir, &parent_buf) orelse break;
        if (std.mem.eql(u8, parent, curr_dir)) break;

        const child_base = getChildBasename(io, curr_dir, &child_buf);
        if (preselect) |old_pre| {
            pre_alloc.free(old_pre);
            preselect = null;
        }
        if (child_base.len > 0) {
            preselect = pre_alloc.dupe(u8, child_base) catch |err| {
                std.log.err(
                    "Failed to duplicate palette preselect child: {}",
                    .{err},
                );
                return;
            };
        }

        const next_dir = dir_alloc.dupe(u8, parent) catch |err| {
            std.log.err(
                "Failed to duplicate parent palette dir '{s}': {}",
                .{ parent, err },
            );
            return;
        };
        if (owned_curr_dir) |old_dir| dir_alloc.free(old_dir);
        owned_curr_dir = next_dir;
        curr_dir = next_dir;
        entries = .empty;
        _ = arena.reset(.{
            .retain_with_limit = MAX_RETAINED_STAGE1_ARENA_BYTES,
        });
    }

    if (cancel.isCanceled()) return;

    if (preselect == null) {
        if (args.resolve_child_from) |prev_dir| {
            const child_base = getChildBasename(io, prev_dir, &child_buf);
            if (child_base.len > 0) {
                preselect = pre_alloc.dupe(u8, child_base) catch |err| {
                    std.log.err(
                        "Failed to duplicate palette preselect child: {}",
                        .{err},
                    );
                    return;
                };
            }
        }
    }

    const unscanned_paths = collectUnscannedDirectoryPaths(
        gpa,
        entries.items,
    ) catch |err| {
        std.log.err(
            "Failed to collect unscanned palette paths for '{s}': {}",
            .{ curr_dir, err },
        );
        return;
    };
    defer if (unscanned_paths) |p| freeOwnedStringSlice(gpa, p);

    const arena_alloc = arena.allocator();
    const resolved_dir = arena_alloc.dupe(u8, curr_dir) catch |err| {
        std.log.err(
            "Failed to duplicate resolved palette dir '{s}': {}",
            .{ curr_dir, err },
        );
        return;
    };
    const preselect_child: ?[]const u8 = if (preselect) |p|
        arena_alloc.dupe(u8, p) catch |err| {
            std.log.err(
                "Failed to duplicate palette preselect child: {}",
                .{err},
            );
            return;
        }
    else
        null;

    if (cancel.isCanceled()) return;

    workers.event_queue.push(gpa, io, .{
        .palette_dir_loaded = cancel.wrap(events.PaletteDirLoadedPayload{
            .arena = arena,
            .entries = entries,
            .resolved_dir = resolved_dir,
            .preselect_child = preselect_child,
            .current_dir_image_count = current_dir_image_count,
        }),
    }) catch |err| {
        std.log.err(
            "Failed to push palette_dir_loaded event for '{s}': {}",
            .{ curr_dir, err },
        );
        return;
    };
    owns_arena = false;
    workers.wakeMainThread();

    const paths = unscanned_paths orelse return;
    for (paths) |path| {
        if (cancel.isCanceled()) return;

        const scan = scanFolderContents(io, path);

        if (cancel.isCanceled()) return;

        const path_dup = gpa.dupe(u8, path) catch |err| {
            std.log.err(
                "Failed to duplicate path for palette_folder_count '{s}': {}",
                .{ path, err },
            );
            continue;
        };
        workers.event_queue.push(gpa, io, .{
            .palette_folder_count = cancel.wrap(
                events.PaletteFolderCountPayload{
                    .path = path_dup,
                    .scan = scan,
                },
            ),
        }) catch |err| {
            std.log.err(
                "Failed to push palette_folder_count event for '{s}': {}",
                .{ path, err },
            );
            gpa.free(path_dup);
            continue;
        };
        workers.wakeMainThread();
    }
}

test "paletteScanWorker - Stage 1 dir load and Stage 2 folder counts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub_a");
    try tmp.dir.createDirPath(io, "sub_b");
    var f = try tmp.dir.createFile(io, "sub_a/img.png", .{});
    f.close(io);
    var top_f = try tmp.dir.createFile(io, "top.jpg", .{});
    top_f.close(io);

    var path_buf: [128]u8 = undefined;
    const tmp_dir = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    var current_gen: std.atomic.Value(usize) = .init(42);
    var active_scans: std.atomic.Value(usize) = .init(0);
    try spawnPaletteScan(
        &workers,
        allocator,
        io,
        42,
        &current_gen,
        &active_scans,
        tmp_dir,
        null,
        false,
    );
    try workers.group.await(io);
    try std.testing.expectEqual(@as(usize, 0), active_scans.load(.acquire));

    var batch: std.ArrayList(events.BackgroundEvent) = .empty;
    defer {
        for (batch.items) |*ev| ev.deinit(allocator);
        batch.deinit(allocator);
    }
    workers.event_queue.drain(io, &batch);

    var dir_loaded_seen = false;
    var count_events_seen: usize = 0;
    for (batch.items) |ev| {
        switch (ev) {
            .palette_dir_loaded => |loaded| {
                dir_loaded_seen = true;
                try std.testing.expectEqual(@as(usize, 42), loaded.generation);
                const payload = loaded.resolve(&current_gen).?;
                try std.testing.expectEqualStrings(
                    tmp_dir,
                    payload.resolved_dir,
                );
                try std.testing.expectEqual(
                    @as(usize, 2),
                    payload.entries.items.len,
                );
                try std.testing.expectEqual(
                    @as(usize, 1),
                    payload.current_dir_image_count,
                );
                try std.testing.expect(payload.preselect_child == null);
            },
            .palette_folder_count => |cnt| {
                count_events_seen += 1;
                try std.testing.expectEqual(@as(usize, 42), cnt.generation);
                const payload = cnt.resolve(&current_gen).?;
                if (std.mem.endsWith(u8, payload.path, "sub_a")) {
                    try std.testing.expectEqual(
                        @as(usize, 1),
                        payload.scan.scanned.image_count,
                    );
                }
            },
            .exif_orientation_parsed,
            .dimensions_probed,
            .thumb_decoded,
            .image_decoded,
            .decode_failed,
            .path_discovered,
            .directory_scan_result,
            .precache_completed,
            .ipc_command,
            => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(dir_loaded_seen);
    try std.testing.expectEqual(@as(usize, 2), count_events_seen);
}

test "paletteScanWorker - walk_up_if_empty steps up and sets preselect" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "leaf_dir");
    var f = try tmp.dir.createFile(io, "leaf_dir/photo.png", .{});
    f.close(io);

    var tmp_buf: [128]u8 = undefined;
    const tmp_dir = try std.mem.print(
        &tmp_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    var leaf_buf: [160]u8 = undefined;
    const leaf_dir = try std.mem.print(
        &leaf_buf,
        "{s}/leaf_dir",
        .{tmp_dir},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    var current_gen: std.atomic.Value(usize) = .init(7);
    var active_scans: std.atomic.Value(usize) = .init(0);
    try spawnPaletteScan(
        &workers,
        allocator,
        io,
        7,
        &current_gen,
        &active_scans,
        leaf_dir,
        null,
        true,
    );
    try workers.group.await(io);
    try std.testing.expectEqual(@as(usize, 0), active_scans.load(.acquire));

    var batch: std.ArrayList(events.BackgroundEvent) = .empty;
    defer {
        for (batch.items) |*ev| ev.deinit(allocator);
        batch.deinit(allocator);
    }
    workers.event_queue.drain(io, &batch);

    try std.testing.expect(batch.items.len >= 1);
    switch (batch.items[0]) {
        .palette_dir_loaded => |loaded| {
            const payload = loaded.resolve(&current_gen).?;
            try std.testing.expectEqualStrings(tmp_dir, payload.resolved_dir);
            try std.testing.expectEqualStrings(
                "leaf_dir",
                payload.preselect_child.?,
            );
            try std.testing.expectEqual(
                @as(usize, 1),
                payload.entries.items.len,
            );
        },
        .exif_orientation_parsed,
        .dimensions_probed,
        .thumb_decoded,
        .image_decoded,
        .decode_failed,
        .path_discovered,
        .directory_scan_result,
        .palette_folder_count,
        .precache_completed,
        .ipc_command,
        => return error.TestUnexpectedResult,
    }
}

test "paletteScanWorker - prunes early when current_generation increments" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    var current_gen: std.atomic.Value(usize) = .init(43);
    var active_scans: std.atomic.Value(usize) = .init(0);
    try spawnPaletteScan(
        &workers,
        allocator,
        io,
        42,
        &current_gen,
        &active_scans,
        "testfiles/images",
        null,
        false,
    );
    try workers.group.await(io);
    try std.testing.expectEqual(@as(usize, 0), active_scans.load(.acquire));

    var batch: std.ArrayList(events.BackgroundEvent) = .empty;
    defer {
        for (batch.items) |*ev| ev.deinit(allocator);
        batch.deinit(allocator);
    }
    workers.event_queue.drain(io, &batch);

    try std.testing.expectEqual(@as(usize, 0), batch.items.len);
}

test "paletteScanWorker - multi-step walk_up and resolve_child_from" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub_dir");
    var f = try tmp.dir.createFile(io, "sub_dir/img.png", .{});
    f.close(io);

    var tmp_buf: [128]u8 = undefined;
    const tmp_dir = try std.mem.print(
        &tmp_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    var missing_buf: [192]u8 = undefined;
    const missing_dir = try std.mem.print(
        &missing_buf,
        "{s}/missing_a/missing_b",
        .{tmp_dir},
    );
    var dot_buf: [160]u8 = undefined;
    const dot_dir = try std.mem.print(
        &dot_buf,
        "{s}/sub_dir/.",
        .{tmp_dir},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    var current_gen: std.atomic.Value(usize) = .init(1);
    var active_scans: std.atomic.Value(usize) = .init(0);
    try spawnPaletteScan(
        &workers,
        allocator,
        io,
        1,
        &current_gen,
        &active_scans,
        missing_dir,
        null,
        true,
    );
    try workers.group.await(io);

    var batch: std.ArrayList(events.BackgroundEvent) = .empty;
    defer {
        for (batch.items) |*ev| ev.deinit(allocator);
        batch.deinit(allocator);
    }
    workers.event_queue.drain(io, &batch);
    try std.testing.expect(batch.items.len >= 1);
    switch (batch.items[0]) {
        .palette_dir_loaded => |loaded| {
            const payload = loaded.resolve(&current_gen).?;
            try std.testing.expectEqualStrings(tmp_dir, payload.resolved_dir);
            try std.testing.expectEqualStrings(
                "missing_a",
                payload.preselect_child.?,
            );
        },
        .exif_orientation_parsed,
        .dimensions_probed,
        .thumb_decoded,
        .image_decoded,
        .decode_failed,
        .path_discovered,
        .directory_scan_result,
        .palette_folder_count,
        .precache_completed,
        .ipc_command,
        => return error.TestUnexpectedResult,
    }

    for (batch.items) |*ev| ev.deinit(allocator);
    batch.clearRetainingCapacity();

    try spawnPaletteScan(
        &workers,
        allocator,
        io,
        1,
        &current_gen,
        &active_scans,
        tmp_dir,
        dot_dir,
        false,
    );
    try workers.group.await(io);
    workers.event_queue.drain(io, &batch);
    try std.testing.expect(batch.items.len >= 1);
    switch (batch.items[0]) {
        .palette_dir_loaded => |loaded| {
            const payload = loaded.resolve(&current_gen).?;
            try std.testing.expectEqualStrings(tmp_dir, payload.resolved_dir);
            try std.testing.expectEqualStrings(
                "sub_dir",
                payload.preselect_child.?,
            );
        },
        .exif_orientation_parsed,
        .dimensions_probed,
        .thumb_decoded,
        .image_decoded,
        .decode_failed,
        .path_discovered,
        .directory_scan_result,
        .palette_folder_count,
        .precache_completed,
        .ipc_command,
        => return error.TestUnexpectedResult,
    }
}
