const std = @import("std");
const state_pkg = @import("state");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const sdl = @import("sdl");
const workers_mod = @import("workers/root.zig");

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |char_a, index| {
        if (std.ascii.toLower(char_a) != std.ascii.toLower(b[index])) return false;
    }
    return true;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn isAppleDouble(filename: []const u8) bool {
    const basename = std.fs.path.basename(filename);
    return std.mem.startsWith(u8, basename, "._");
}

pub fn isImageExtension(ext: []const u8) bool {
    const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".webp" };
    for (extensions) |e| {
        if (eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

pub fn isImageFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isImageExtension(std.fs.path.extension(filename));
}

fn isAllDotDots(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    var count: usize = 0;
    while (it.next()) |comp| {
        if (!std.mem.eql(u8, comp, "..")) return false;
        count += 1;
    }
    return count > 0;
}

pub fn getParentDirBuf(dir: []const u8, buf: []u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, dir, "/\\");
    if (trimmed.len == 0) return null;

    if (isAllDotDots(trimmed)) {
        const sep = if (std.mem.indexOfScalar(u8, trimmed, '\\') != null) "\\" else "/";
        return std.fmt.bufPrint(buf, "{s}{s}..", .{ trimmed, sep }) catch |err| {
            std.log.warn("Failed to format parent directory for '{s}': {}", .{ trimmed, err });
            return null;
        };
    }

    var last_sep: ?usize = null;
    var i: usize = trimmed.len;
    while (i > 0) {
        i -= 1;
        if (trimmed[i] == '/' or trimmed[i] == '\\') {
            last_sep = i;
            break;
        }
    }

    if (last_sep) |sep_idx| {
        if (sep_idx == 0) {
            return trimmed[0..1];
        }
        if (sep_idx == 2 and std.ascii.isAlphabetic(trimmed[0]) and trimmed[1] == ':') {
            return trimmed[0..3];
        }
        return trimmed[0..sep_idx];
    }

    if (std.mem.eql(u8, trimmed, ".")) {
        return "..";
    }

    if (std.mem.eql(u8, trimmed, "/") or (trimmed.len == 2 and std.ascii.isAlphabetic(trimmed[0]) and trimmed[1] == ':')) {
        return null;
    }

    return ".";
}

pub const FolderCounts = struct {
    image_count: usize = 0,
    subdir_count: usize = 0,
};

const DirectoryEntry = state_pkg.DirectoryEntry;

pub fn countFolderContents(io: std.Io, folder_path: []const u8) FolderCounts {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, folder_path, .{ .iterate = true }) catch |err| {
        std.log.debug("countFolderContents openDir failed for '{s}': {}", .{ folder_path, err });
        return .{};
    };
    defer dir.close(io);

    var counts: FolderCounts = .{};
    var it = dir.iterate();
    while ((it.next(io) catch |err| {
        std.log.debug("countFolderContents iterate failed for '{s}': {}", .{ folder_path, err });
        return counts;
    })) |entry| {
        if (entry.kind == .file) {
            if (isImageFile(entry.name)) {
                counts.image_count += 1;
            }
        } else if (entry.kind == .directory) {
            if (!std.mem.startsWith(u8, entry.name, ".")) {
                counts.subdir_count += 1;
            }
        }
    }
    return counts;
}

pub fn countFolderImages(io: std.Io, folder_path: []const u8) usize {
    return countFolderContents(io, folder_path).image_count;
}

pub fn countFolderSubdirs(io: std.Io, folder_path: []const u8) usize {
    return countFolderContents(io, folder_path).subdir_count;
}

pub fn scanDirectoryEntries(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, entries: *std.ArrayList(DirectoryEntry)) !void {
    const start_len = entries.items.len;
    errdefer {
        for (entries.items[start_len..]) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.full_path);
        }
        entries.shrinkRetainingCapacity(start_len);
    }

    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;

            const full_path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            errdefer gpa.free(full_path);
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);

            const counts = countFolderContents(io, full_path);

            try entries.append(gpa, .{
                .name = name,
                .full_path = full_path,
                .kind = .directory,
                .image_count = counts.image_count,
                .subdir_count = counts.subdir_count,
            });
        }
    }

    std.mem.sort(DirectoryEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: DirectoryEntry, b: DirectoryEntry) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);
}

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
            if (isImageFile(entry.name)) {
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
        args.* = .{
            .workers = &state.workers,
            .allocator = gpa,
            .io = io,
            .is_loading_files = &state.viewer.navigation.is_loading_files,
        };

        workers_mod.spawnStdin(args) catch |err| {
            std.log.err("workers.spawnStdin failed: {}", .{err});
            state.viewer.navigation.is_loading_files.store(false, .release);
            gpa.destroy(args);
        };
    }
}

pub fn startAsyncPathScan(state: *AppState, path: []const u8, is_dir: bool) !void {
    const dup_path = try state.allocator.dupe(u8, path);
    errdefer state.allocator.free(dup_path);

    const args = try state.allocator.create(workers_mod.PathScanArgs);
    args.* = .{
        .workers = &state.workers,
        .allocator = state.allocator,
        .io = state.io,
        .target_path = dup_path,
        .is_dir = is_dir,
        .is_loading_files = &state.viewer.navigation.is_loading_files,
    };

    workers_mod.spawnPathScan(args) catch |err| {
        std.log.err("workers.spawnPathScan failed: {}", .{err});
        state.allocator.free(dup_path);
        state.viewer.navigation.is_loading_files.store(false, .release);
        state.allocator.destroy(args);
    };
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

    try scanDirectoryEntries(allocator, io, tmp_dir_path, &entries);

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

pub fn getChildBasename(io: std.Io, path: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    const base = blk: {
        var i = trimmed.len;
        while (i > 0) {
            i -= 1;
            if (trimmed[i] == '/' or trimmed[i] == '\\') {
                break :blk trimmed[i + 1 ..];
            }
        }
        break :blk trimmed;
    };
    if (std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        if (std.Io.Dir.openDir(std.Io.Dir.cwd(), io, trimmed, .{})) |dir| {
            var mut_dir = dir;
            defer mut_dir.close(io);
            if (mut_dir.realPath(io, buf)) |len| {
                const real_trimmed = std.mem.trimEnd(u8, buf[0..len], "/\\");
                var i = real_trimmed.len;
                while (i > 0) {
                    i -= 1;
                    if (real_trimmed[i] == '/' or real_trimmed[i] == '\\') {
                        return real_trimmed[i + 1 ..];
                    }
                }
                return real_trimmed;
            } else |err| {
                std.log.debug("realPath failed for '{s}': {}", .{ trimmed, err });
            }
        } else |err| {
            std.log.debug("openDir failed for '{s}': {}", .{ trimmed, err });
        }
    }
    return base;
}

test "getParentDirBuf" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings(".", getParentDirBuf("5 Centimeters per Second", &buf).?);
    try std.testing.expectEqualStrings("foo", getParentDirBuf("foo/bar", &buf).?);
    try std.testing.expectEqualStrings("foo", getParentDirBuf("foo/bar/", &buf).?);
    try std.testing.expectEqualStrings("foo", getParentDirBuf("foo\\bar", &buf).?);
    try std.testing.expectEqualStrings("foo", getParentDirBuf("foo\\bar\\", &buf).?);
    try std.testing.expectEqualStrings(".", getParentDirBuf("./foo", &buf).?);
    try std.testing.expectEqualStrings("..", getParentDirBuf(".", &buf).?);
    try std.testing.expectEqualStrings("../..", getParentDirBuf("..", &buf).?);
    try std.testing.expectEqualStrings("../../..", getParentDirBuf("../..", &buf).?);
    try std.testing.expectEqualStrings("..\\..\\..", getParentDirBuf("..\\..", &buf).?);
    try std.testing.expect(getParentDirBuf("/", &buf) == null);
    try std.testing.expect(getParentDirBuf("C:", &buf) == null);
    try std.testing.expect(getParentDirBuf("C:\\", &buf) == null);
    try std.testing.expect(getParentDirBuf("C:/", &buf) == null);
    try std.testing.expect(getParentDirBuf("", &buf) == null);
}

test "getChildBasename" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const b = getChildBasename(io, ".", &buf);
    try std.testing.expectEqualStrings("peng", b);
}
