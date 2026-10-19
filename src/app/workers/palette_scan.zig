const context = @import("context.zig");
const core_fs = @import("../core/fs.zig");
const events = @import("../core/events.zig");
const manager = @import("manager.zig");
const state_pkg = @import("state");
const std = @import("std");

const DirectoryEntry = state_pkg.DirectoryEntry;
const WorkerManager = manager.WorkerManager;

/// Spawns a background paletteScanWorker task to count directory images and subfolders.
pub fn spawnPaletteScan(args: *PaletteScanArgs) !void {
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    args.workers.group.async(args.io, paletteScanWorker, .{args});
}

/// Arguments passed to the background palette directory scan worker thread.
pub const PaletteScanArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    generation: usize,
    current_generation: *const std.atomic.Value(usize),
    paths: [][]const u8,

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

/// Background worker task that iterates through candidate directory and
/// archive paths, counts their images and subdirectories, and posts
/// `.palette_folder_count` events back to the main thread event queue.
pub fn paletteScanWorker(args: *PaletteScanArgs) void {
    const workers = args.workers;
    const gpa = args.allocator;
    const io = args.io;
    const cancel = args.cancelToken();

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
        if (cancel.isCanceled()) return;

        const scan = core_fs.scanFolderContents(io, path);

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
        context.wakeUpMainThread();
    }
}

/// Filters unscanned directory and archive items, duplicates their full
/// paths, allocates task arguments, and dispatches the asynchronous
/// background palette scan task.
pub fn spawnPaletteScanForItems(
    workers: *WorkerManager,
    gpa: std.mem.Allocator,
    io: std.Io,
    current_generation: *const std.atomic.Value(usize),
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
    errdefer gpa.destroy(args);

    args.* = .{
        .workers = workers,
        .allocator = gpa,
        .io = io,
        .generation = current_generation.load(.acquire),
        .current_generation = current_generation,
        .paths = paths,
    };

    try spawnPaletteScan(args);
}

test "paletteScanWorker - counts directory contents and pushes events" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const test_dir = "testfiles/images";
    const dir_path = try allocator.dupe(u8, test_dir);

    const paths = try allocator.alloc([]const u8, 1);
    paths[0] = dir_path;

    var current_gen: std.atomic.Value(usize) = .init(42);
    const args = try allocator.create(PaletteScanArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .generation = 42,
        .current_generation = &current_gen,
        .paths = paths,
    };

    _ = workers.active_threads.fetchAdd(1, .monotonic);
    paletteScanWorker(args);

    var batch: std.ArrayList(events.BackgroundEvent) = .empty;
    defer {
        for (batch.items) |*ev| ev.deinit(allocator);
        batch.deinit(allocator);
    }
    try workers.event_queue.drain(allocator, io, &batch);

    var event_seen = false;
    for (batch.items) |ev| {
        switch (ev) {
            .palette_folder_count => |cnt| {
                event_seen = true;
                try std.testing.expectEqual(@as(usize, 42), cnt.generation);
                const payload = cnt.resolve(&current_gen).?;
                try std.testing.expectEqualStrings(test_dir, payload.path);
                try std.testing.expect(payload.scan.scanned.image_count > 0);
            },
            else => {},
        }
    }
    try std.testing.expect(event_seen);
}

test "paletteScanWorker - prunes early when current_generation increments" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const test_dir = "testfiles/images";
    const dir_path = try allocator.dupe(u8, test_dir);

    const paths = try allocator.alloc([]const u8, 1);
    paths[0] = dir_path;

    var current_gen: std.atomic.Value(usize) = .init(43);
    const args = try allocator.create(PaletteScanArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .generation = 42,
        .current_generation = &current_gen,
        .paths = paths,
    };

    _ = workers.active_threads.fetchAdd(1, .monotonic);
    paletteScanWorker(args);

    var batch: std.ArrayList(events.BackgroundEvent) = .empty;
    defer {
        for (batch.items) |*ev| ev.deinit(allocator);
        batch.deinit(allocator);
    }
    try workers.event_queue.drain(allocator, io, &batch);

    try std.testing.expectEqual(@as(usize, 0), batch.items.len);
}
