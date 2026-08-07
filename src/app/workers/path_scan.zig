const std = @import("std");
const core_fs = @import("../core/fs.zig");
const context = @import("context.zig");
const root = @import("root.zig");
const WorkerManager = root.WorkerManager;

pub const PathScanArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    target_path: []const u8,
    is_dir: bool,
    is_loading_files: ?*std.atomic.Value(bool) = null,
};

pub fn appendPathThreadSafe(workers: *WorkerManager, gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
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

pub fn scanDirectoryThreadSafe(workers: *WorkerManager, gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) void {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("scanDirectoryThreadSafe: openDir failed for '{s}': {any}", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries: std.ArrayList([]const u8) = .empty;
    defer {
        for (dir_entries.items) |name| gpa.free(name);
        dir_entries.deinit(gpa);
    }

    while (it.next(io) catch |err| blk: {
        std.log.warn("scanDirectoryThreadSafe: iterate next failed for '{s}': {any}", .{ dir_path, err });
        break :blk null;
    }) |entry| {
        if (workers.exiting.load(.acquire)) return;
        if (entry.kind == .file) {
            if (core_fs.isImageFile(entry.name)) {
                const name_dup = gpa.dupe(u8, entry.name) catch |err| {
                    std.log.err("Failed to dupe entry name '{s}': {}", .{ entry.name, err });
                    continue;
                };
                dir_entries.append(gpa, name_dup) catch |err| {
                    std.log.err("Failed to append entry name '{s}': {}", .{ entry.name, err });
                    gpa.free(name_dup);
                    continue;
                };
            }
        }
    }

    std.mem.sort([]const u8, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lessThan);

    if (workers.exiting.load(.acquire)) return;

    for (dir_entries.items) |name| {
        const full_path = std.fs.path.join(gpa, &.{ dir_path, name }) catch |err| {
            std.log.err("Failed to join path for '{s}': {}", .{ name, err });
            continue;
        };
        workers.event_queue.push(gpa, io, .{
            .path_discovered = .{
                .entry = .{ .filesystem = .{ .path = full_path } },
            },
        }) catch |err| {
            std.log.err("Failed to push path_discovered event for '{s}': {}", .{ full_path, err });
            gpa.free(full_path);
        };
        context.wakeUpMainThread();
    }
}

pub fn pathScanWorker(args: *PathScanArgs) void {
    const workers = args.workers;
    const io = args.io;
    const gpa = args.allocator;
    const target_path = args.target_path;
    const is_dir = args.is_dir;

    defer {
        if (args.is_loading_files) |flag| flag.store(false, .release);
        context.wakeUpMainThread();
        gpa.free(target_path);
        gpa.destroy(args);
        _ = workers.active_threads.fetchSub(1, .release);
    }

    const MediaEntry = @import("state").MediaEntry;
    var dir_entries: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (dir_entries.items) |item| item.deinit(gpa);
        dir_entries.deinit(gpa);
    }

    if (!is_dir and core_fs.isCbzFile(target_path)) {
        core_fs.scanCbzImageEntries(gpa, io, target_path, &dir_entries) catch |err| {
            std.log.err("Failed to scan CBZ image entries for '{s}': {}", .{ target_path, err });
        };
    } else {
        const dir_path = if (is_dir) target_path else (std.fs.path.dirname(target_path) orelse ".");

        var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
            std.log.err("Failed to open dir '{s}': {}", .{ dir_path, err });
            return;
        };
        defer dir.close(io);

        var it = dir.iterate();

        while (!workers.exiting.load(.acquire)) {
            const entry = (it.next(io) catch |err| switch (err) {
                error.Canceled => break,
                else => {
                    std.log.warn("pathScanWorker iterate failed for '{s}': {}", .{ dir_path, err });
                    break;
                },
            }) orelse break;
            if (entry.kind == .file) {
                if (core_fs.isImageFile(entry.name)) {
                    const full_path = std.fs.path.join(gpa, &.{ dir_path, entry.name }) catch |err| {
                        std.log.err("Failed to join path for '{s}': {}", .{ entry.name, err });
                        continue;
                    };
                    dir_entries.append(gpa, .{ .filesystem = .{ .path = full_path } }) catch |err| {
                        std.log.err("Failed to append path '{s}': {}", .{ full_path, err });
                        gpa.free(full_path);
                        continue;
                    };
                }
            }
        }
    }

    if (workers.exiting.load(.acquire)) return;

    // Sort entries alphabetically by basename
    std.mem.sort(MediaEntry, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: MediaEntry, b: MediaEntry) bool {
            return std.ascii.lessThanIgnoreCase(a.getBasename(), b.getBasename());
        }
    }.lessThan);

    if (workers.exiting.load(.acquire)) return;

    const dup_target = gpa.dupe(u8, target_path) catch return;
    const paths_slice = dir_entries.toOwnedSlice(gpa) catch {
        gpa.free(dup_target);
        return;
    };

    workers.event_queue.push(gpa, io, .{
        .directory_scan_result = .{
            .target_path = dup_target,
            .is_dir = is_dir,
            .paths = paths_slice,
        },
    }) catch |err| {
        std.log.err("Failed to push directory_scan_result event: {}", .{err});
        gpa.free(dup_target);
        for (paths_slice) |item| item.deinit(gpa);
        gpa.free(paths_slice);
    };
    context.wakeUpMainThread();
}
