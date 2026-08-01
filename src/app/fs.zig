const std = @import("std");
const state_pkg = @import("state");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const sdl = @import("sdl");
const workers_mod = @import("workers/root.zig");
const DirectoryEntry = state_pkg.DirectoryEntry;

pub const core_fs = @import("core/fs.zig");

pub fn scanDirectory(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, dir_path: []const u8, list: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open directory '{s}': {}", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries: std.ArrayList([]const u8) = .empty;
    defer dir_entries.deinit(gpa);

    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            if (core_fs.isImageFile(entry.name)) {
                const full_path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                try dir_entries.append(gpa, full_path);
            }
        }
    }

    // Sort entries alphabetically ignoring case
    std.mem.sort([]const u8, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lessThan);

    try list.appendSlice(gpa, dir_entries.items);
}

pub fn wakeUpMainThread() void {
    _ = sdl.events.pushUserEvent();
}

const AppState = app_state.AppState;

pub fn readPipedStdin(state: *AppState, io: std.Io, gpa: std.mem.Allocator) !void {
    const is_stdin_piped = !(std.Io.File.stdin().isTty(io) catch false);
    if (is_stdin_piped) {
        const args = try gpa.create(workers_mod.StdinArgs);
        errdefer gpa.destroy(args);

        args.* = .{
            .workers = &state.workers,
            .allocator = gpa,
            .io = io,
            .is_loading_files = &state.viewer.navigation.is_loading_files,
        };

        errdefer state.viewer.navigation.is_loading_files.store(false, .release);

        try workers_mod.spawnStdin(args);
    }
}

pub fn startAsyncPathScan(state: *AppState, path: []const u8, is_dir: bool) !void {
    const dup_path = try state.allocator.dupe(u8, path);
    errdefer state.allocator.free(dup_path);

    const args = try state.allocator.create(workers_mod.PathScanArgs);
    errdefer state.allocator.destroy(args);

    args.* = .{
        .workers = &state.workers,
        .allocator = state.allocator,
        .io = state.io,
        .target_path = dup_path,
        .is_dir = is_dir,
        .is_loading_files = &state.viewer.navigation.is_loading_files,
    };

    errdefer state.viewer.navigation.is_loading_files.store(false, .release);

    try workers_mod.spawnPathScan(args);
}

test "scanDirectoryEntries" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir_path = "testfiles/tmp_scan_nav_test";

    // Setup directory structure
    std.Io.Dir.createDirPath(cwd, io, tmp_dir_path ++ "/sub_b") catch {};
    std.Io.Dir.createDirPath(cwd, io, tmp_dir_path ++ "/sub_a") catch {};
    std.Io.Dir.createDirPath(cwd, io, tmp_dir_path ++ "/sub_empty") catch {};

    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir_path) catch {};
    }

    // Create test files
    {
        var f0 = try std.Io.Dir.createFile(cwd, io, tmp_dir_path ++ "/root.png", .{});
        f0.close(io);

        var f1 = try std.Io.Dir.createFile(cwd, io, tmp_dir_path ++ "/sub_b/img1.png", .{});
        f1.close(io);
        var f2 = try std.Io.Dir.createFile(cwd, io, tmp_dir_path ++ "/sub_b/img2.jpg", .{});
        f2.close(io);
        var f3 = try std.Io.Dir.createFile(cwd, io, tmp_dir_path ++ "/sub_b/txt1.txt", .{});
        f3.close(io);

        var f4 = try std.Io.Dir.createFile(cwd, io, tmp_dir_path ++ "/sub_a/pic.webp", .{});
        f4.close(io);
    }

    var entries: std.ArrayList(DirectoryEntry) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.full_path);
        }
        entries.deinit(allocator);
    }

    try core_fs.scanDirectoryEntries(allocator, io, tmp_dir_path, &entries);

    try std.testing.expectEqual(@as(usize, 3), entries.items.len);

    // Index 0: sub_a
    try std.testing.expectEqualStrings("sub_a", entries.items[0].name);
    try std.testing.expectEqualStrings(tmp_dir_path ++ "/sub_a", entries.items[0].full_path);
    try std.testing.expectEqual(@as(usize, 1), entries.items[0].getImageCount());

    // Index 1: sub_b
    try std.testing.expectEqualStrings("sub_b", entries.items[1].name);
    try std.testing.expectEqualStrings(tmp_dir_path ++ "/sub_b", entries.items[1].full_path);
    try std.testing.expectEqual(@as(usize, 2), entries.items[1].getImageCount());

    // Index 2: sub_empty
    try std.testing.expectEqualStrings("sub_empty", entries.items[2].name);
    try std.testing.expectEqualStrings(tmp_dir_path ++ "/sub_empty", entries.items[2].full_path);
    try std.testing.expectEqual(@as(usize, 0), entries.items[2].getImageCount());
}
