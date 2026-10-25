const context = @import("context.zig");
const core_fs = @import("../core/fs.zig");
const events = @import("../core/events.zig");
const manager = @import("manager.zig");
const state_pkg = @import("state");
const std = @import("std");

const MediaEntry = state_pkg.MediaEntry;
const WorkerManager = manager.WorkerManager;

/// Arguments for spawning a background file path or directory scanner worker thread.
pub const PathScanArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    target_path: []const u8,
    is_dir: bool,
    active_file_scans: *std.atomic.Value(usize),
    stack_raw_jpeg: bool = true,
    generation: usize = 0,
    current_generation: ?*const std.atomic.Value(usize) = null,

    /// Builds a cooperative cancellation token for this path scan task.
    pub inline fn cancelToken(
        self: *const PathScanArgs,
    ) context.CancellationToken {
        return .{
            .exiting = &self.workers.exiting,
            .generation = self.generation,
            .current_generation = self.current_generation,
        };
    }
};

/// Thread-safely duplicates a path string and pushes a `.path_discovered`
/// event onto the worker event queue.
pub fn appendPathThreadSafe(
    workers: *WorkerManager,
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) void {
    if (workers.exiting.load(.acquire)) return;
    const dup = gpa.dupe(u8, path) catch |err| {
        std.log.err("Failed to duplicate path '{s}': {}", .{ path, err });
        return;
    };
    workers.event_queue.push(gpa, io, .{
        .path_discovered = .{
            .entry = .{ .filesystem = .{ .path = dup } },
        },
    }) catch |err| {
        std.log.err("Failed to push path_discovered event for '{s}': {}", .{ path, err });
        gpa.free(dup);
        return;
    };
    context.wakeUpMainThread();
}

/// Scans image files within `dir_path`, sorts them alphabetically
/// (case-insensitive), and pushes discovery events.
pub fn scanDirectoryThreadSafe(
    workers: *WorkerManager,
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    stack_raw_jpeg: bool,
) void {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn(
            "scanDirectoryThreadSafe: openDir failed for '{s}': {any}",
            .{ dir_path, err },
        );
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (dir_entries.items) |item| item.deinit(gpa);
        dir_entries.deinit(gpa);
    }

    while (it.next(io) catch |err| blk: {
        std.log.warn(
            "scanDirectoryThreadSafe: iterate next failed for '{s}': {any}",
            .{ dir_path, err },
        );
        break :blk null;
    }) |entry| {
        if (workers.exiting.load(.acquire)) return;
        if (core_fs.isImageFile(entry.name)) {
            if (core_fs.resolveEntryKind(dir, io, entry) == .file) {
                const full_path = std.Io.Dir.path.join(
                    gpa,
                    &.{ dir_path, entry.name },
                ) catch |err| {
                    std.log.err(
                        "Failed to join path for '{s}': {}",
                        .{ entry.name, err },
                    );
                    continue;
                };
                dir_entries.append(
                    gpa,
                    .{ .filesystem = .{ .path = full_path } },
                ) catch |err| {
                    std.log.err(
                        "Failed to append path '{s}': {}",
                        .{ full_path, err },
                    );
                    gpa.free(full_path);
                    continue;
                };
            }
        }
    }

    std.mem.sort(MediaEntry, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: MediaEntry, b: MediaEntry) bool {
            return std.ascii.lessThanIgnoreCase(a.getBasename(), b.getBasename());
        }
    }.lessThan);

    core_fs.consolidateRawJpegPairs(&dir_entries, stack_raw_jpeg);

    if (workers.exiting.load(.acquire)) return;

    for (dir_entries.items) |item| {
        if (workers.exiting.load(.acquire)) return;
        const dup_entry = item.dupe(gpa) catch |err| {
            std.log.err("Failed to duplicate item: {}", .{err});
            continue;
        };
        workers.event_queue.push(gpa, io, .{
            .path_discovered = .{ .entry = dup_entry },
        }) catch |err| {
            std.log.err("Failed to push path_discovered event: {}", .{err});
            dup_entry.deinit(gpa);
        };
        context.wakeUpMainThread();
    }
}

/// Background thread entry point executing full path scan (directory or archive)
/// and notifying completion.
pub fn pathScanWorker(args: *PathScanArgs) void {
    const workers = args.workers;
    const io = args.io;
    const gpa = args.allocator;
    const target_path = args.target_path;
    const is_dir = args.is_dir;

    defer {
        _ = args.active_file_scans.fetchSub(1, .release);
        gpa.free(target_path);
        gpa.destroy(args);
        _ = workers.active_threads.fetchSub(1, .release);
        context.wakeUpMainThread();
    }

    const cancel = args.cancelToken();
    if (cancel.isCanceled()) return;

    var dir_entries: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (dir_entries.items) |item| item.deinit(gpa);
        dir_entries.deinit(gpa);
    }

    if (core_fs.isCbzFile(target_path)) {
        core_fs.scanCbzImageEntries(gpa, io, target_path, &dir_entries) catch |err| {
            std.log.err("pathScanWorker: failed to scan CBZ '{s}': {}", .{ target_path, err });
            return;
        };
    } else {
        const dir_path = if (is_dir)
            target_path
        else
            (std.Io.Dir.path.dirname(target_path) orelse ".");

        var dir = std.Io.Dir.openDir(
            std.Io.Dir.cwd(),
            io,
            dir_path,
            .{ .iterate = true },
        ) catch |err| {
            std.log.err("Failed to open dir '{s}': {}", .{ dir_path, err });
            return;
        };
        defer dir.close(io);

        var it = dir.iterate();

        while (!cancel.isCanceled()) {
            const entry = (it.next(io) catch |err| switch (err) {
                error.Canceled => break,
                else => {
                    std.log.warn("pathScanWorker iterate failed for '{s}': {}", .{ dir_path, err });
                    break;
                },
            }) orelse break;
            if (core_fs.isImageFile(entry.name)) {
                if (core_fs.resolveEntryKind(dir, io, entry) == .file) {
                    const full_path = std.Io.Dir.path.join(
                        gpa,
                        &.{ dir_path, entry.name },
                    ) catch |err| {
                        std.log.err(
                            "Failed to join path for '{s}': {}",
                            .{ entry.name, err },
                        );
                        continue;
                    };
                    dir_entries.append(
                        gpa,
                        .{ .filesystem = .{ .path = full_path } },
                    ) catch |err| {
                        std.log.err(
                            "Failed to append path '{s}': {}",
                            .{ full_path, err },
                        );
                        gpa.free(full_path);
                        continue;
                    };
                }
            }
        }
    }

    if (cancel.isCanceled()) return;

    // Sort entries alphabetically by basename
    std.mem.sort(MediaEntry, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: MediaEntry, b: MediaEntry) bool {
            return std.ascii.lessThanIgnoreCase(a.getBasename(), b.getBasename());
        }
    }.lessThan);

    // Consolidate RAW + JPEG pairs sharing the same stem into unified .pair entries
    core_fs.consolidateRawJpegPairs(&dir_entries, args.stack_raw_jpeg);

    if (cancel.isCanceled()) return;

    const dup_target = gpa.dupe(u8, target_path) catch return;
    const paths_slice = dir_entries.toOwnedSlice(gpa) catch {
        gpa.free(dup_target);
        return;
    };

    workers.event_queue.push(gpa, io, .{
        .directory_scan_result = cancel.wrap(events.DirectoryScanResultPayload{
            .target_path = dup_target,
            .is_dir = is_dir,
            .paths = paths_slice,
        }),
    }) catch |err| {
        std.log.err("Failed to push directory_scan_result event: {}", .{err});
        gpa.free(dup_target);
        for (paths_slice) |item| item.deinit(gpa);
        gpa.free(paths_slice);
    };
}

test "scanDirectoryThreadSafe - discovers and sorts images, ignores non-images" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    scanDirectoryThreadSafe(&workers, allocator, io, "testfiles/images", true);

    var batch: std.ArrayList(events.BackgroundEvent) = .empty;
    defer {
        for (batch.items) |*ev| ev.deinit(allocator);
        batch.deinit(allocator);
    }
    try workers.event_queue.drain(allocator, io, &batch);

    try std.testing.expect(batch.items.len > 0);
    // Verify first event is 000_0_1024x682.jpg
    const first_path = batch.items[0].path_discovered.entry.filesystem.path;
    try std.testing.expect(std.mem.endsWith(u8, first_path, "000_0_1024x682.jpg"));

    // Verify non-image files like CREDITS.txt are never pushed
    for (batch.items) |ev| {
        const p = ev.path_discovered.entry.filesystem.path;
        try std.testing.expect(!std.mem.endsWith(u8, p, "CREDITS.txt"));
    }
}

test "pathScanWorker - directory scan result event generation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    var active_scans = std.atomic.Value(usize).init(1);
    var cur_gen = std.atomic.Value(usize).init(7);
    const target = try allocator.dupe(u8, "testfiles/images");
    const args = try allocator.create(PathScanArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .target_path = target,
        .is_dir = true,
        .active_file_scans = &active_scans,
        .generation = 7,
        .current_generation = &cur_gen,
    };

    _ = workers.active_threads.fetchAdd(1, .monotonic);
    pathScanWorker(args);

    try std.testing.expectEqual(@as(usize, 0), active_scans.load(.acquire));

    var batch: std.ArrayList(events.BackgroundEvent) = .empty;
    defer {
        for (batch.items) |*ev| ev.deinit(allocator);
        batch.deinit(allocator);
    }
    try workers.event_queue.drain(allocator, io, &batch);

    try std.testing.expectEqual(@as(usize, 1), batch.items.len);
    switch (batch.items[0]) {
        .directory_scan_result => |res| {
            try std.testing.expectEqual(@as(usize, 7), res.generation);
            const payload = res.resolve(&cur_gen).?;
            try std.testing.expect(payload.is_dir);
            try std.testing.expectEqualStrings(
                "testfiles/images",
                payload.target_path,
            );
            try std.testing.expect(payload.paths.len > 0);
            try std.testing.expectEqualStrings(
                "000_0_1024x682.jpg",
                payload.paths[0].getBasename(),
            );
        },
        else => return error.ExpectedDirectoryScanResult,
    }

    // Stale generation scan aborts without pushing directory_scan_result
    for (batch.items) |*ev| ev.deinit(allocator);
    batch.clearRetainingCapacity();
    active_scans.store(1, .release);
    cur_gen.store(8, .release);
    const stale_target = try allocator.dupe(u8, "testfiles/images");
    const stale_args = try allocator.create(PathScanArgs);
    stale_args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .target_path = stale_target,
        .is_dir = true,
        .active_file_scans = &active_scans,
        .generation = 7,
        .current_generation = &cur_gen,
    };
    _ = workers.active_threads.fetchAdd(1, .monotonic);
    pathScanWorker(stale_args);
    try std.testing.expectEqual(@as(usize, 0), active_scans.load(.acquire));
    try workers.event_queue.drain(allocator, io, &batch);
    try std.testing.expectEqual(@as(usize, 0), batch.items.len);
}
