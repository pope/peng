const std = @import("std");
const state_pkg = @import("state");
const DirectoryEntry = state_pkg.DirectoryEntry;
const core_fs = @import("../core/fs.zig");
const context = @import("context.zig");
const root = @import("root.zig");
const WorkerManager = root.WorkerManager;

/// Arguments passed to the background palette directory scan worker thread.
pub const PaletteScanArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    generation: usize,
    paths: [][]const u8,
};

/// Background worker task that iterates through candidate directory and archive paths, counts their images
/// and subdirectories, and posts `.palette_folder_count` events back to the main thread event queue.
pub fn paletteScanWorker(args: *PaletteScanArgs) void {
    const workers = args.workers;
    const gpa = args.allocator;
    const io = args.io;

    defer {
        for (args.paths) |p| {
            gpa.free(p);
        }
        gpa.free(args.paths);
        gpa.destroy(args);
        _ = workers.active_threads.fetchSub(1, .release);
        context.wakeUpMainThread();
    }

    for (args.paths) |path| {
        if (workers.exiting.load(.acquire)) return;

        const counts = core_fs.countFolderContents(io, path);

        if (workers.exiting.load(.acquire)) return;

        const path_dup = gpa.dupe(u8, path) catch |err| {
            std.log.err("Failed to duplicate path for palette_folder_count '{s}': {}", .{ path, err });
            continue;
        };
        workers.event_queue.push(gpa, io, .{
            .palette_folder_count = .{
                .generation = args.generation,
                .path = path_dup,
                .image_count = counts.image_count,
                .subdir_count = counts.subdir_count,
            },
        }) catch |err| {
            std.log.err("Failed to push palette_folder_count event for '{s}': {}", .{ path, err });
            gpa.free(path_dup);
            continue;
        };
        context.wakeUpMainThread();
    }
}

/// Filters unscanned directory and archive items, duplicates their full paths, allocates task arguments,
/// and dispatches the asynchronous background palette scan task.
pub fn spawnPaletteScanForItems(
    workers: *WorkerManager,
    gpa: std.mem.Allocator,
    io: std.Io,
    generation: usize,
    items: []const DirectoryEntry,
) !void {
    if (items.len == 0) return;

    var count: usize = 0;
    for (items) |entry| {
        if (entry.getScanState()) |scan| {
            if (scan == .unscanned and entry.getFullPath().len > 0) {
                count += 1;
            }
        }
    }
    if (count == 0) return;

    const paths = try gpa.alloc([]const u8, count);
    var filled: usize = 0;
    errdefer {
        for (paths[0..filled]) |p| gpa.free(p);
        gpa.free(paths);
    }
    for (items) |entry| {
        if (entry.getScanState()) |scan| {
            if (scan == .unscanned and entry.getFullPath().len > 0) {
                paths[filled] = try gpa.dupe(u8, entry.getFullPath());
                filled += 1;
            }
        }
    }

    const args = try gpa.create(PaletteScanArgs);
    errdefer {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
        gpa.destroy(args);
    }

    args.* = .{
        .workers = workers,
        .allocator = gpa,
        .io = io,
        .generation = generation,
        .paths = paths,
    };

    try root.spawnPaletteScan(args);
}

test "paletteScanWorker - counts directory contents and pushes events" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.group.wait(io);

    const test_dir = "testfiles/images";
    const dir_path = try allocator.dupe(u8, test_dir);

    const paths = try allocator.alloc([]const u8, 1);
    paths[0] = dir_path;

    const args = try allocator.create(PaletteScanArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .generation = 42,
        .paths = paths,
    };

    _ = workers.active_threads.fetchAdd(1, .monotonic);
    paletteScanWorker(args);

    var event_seen = false;
    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .palette_folder_count => |cnt| {
                event_seen = true;
                try std.testing.expectEqual(@as(usize, 42), cnt.generation);
                try std.testing.expectEqualStrings(test_dir, cnt.path);
                try std.testing.expect(cnt.image_count > 0);
            },
            else => {},
        }
    }
    try std.testing.expect(event_seen);
}
