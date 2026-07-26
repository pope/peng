const std = @import("std");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const sdl = @import("sdl");

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

pub fn isImageExtension(ext: []const u8) bool {
    const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".webp" };
    for (extensions) |e| {
        if (eqlIgnoreCase(ext, e)) return true;
    }
    return false;
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

pub const DirectoryEntryKind = union(enum) {
    parent,
    current,
    directory: FolderCounts,
    file,
};

pub const DirectoryEntry = struct {
    name: []const u8,
    full_path: []const u8,
    kind: DirectoryEntryKind = .{ .directory = .{} },

    pub fn isParent(self: DirectoryEntry) bool {
        return self.kind == .parent;
    }

    pub fn isCurrent(self: DirectoryEntry) bool {
        return self.kind == .current;
    }

    pub fn getImageCount(self: DirectoryEntry) usize {
        return switch (self.kind) {
            .directory => |c| c.image_count,
            else => 0,
        };
    }

    pub fn getSubdirCount(self: DirectoryEntry) usize {
        return switch (self.kind) {
            .directory => |c| c.subdir_count,
            else => 0,
        };
    }
};

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
            const ext = std.fs.path.extension(entry.name);
            if (isImageExtension(ext)) {
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
                .kind = .{ .directory = counts },
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
    var dir_entries = std.ArrayList([]const u8).empty;
    defer dir_entries.deinit(gpa);

    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (isImageExtension(ext)) {
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

const StdinArgs = struct {
    state: *ViewerState,
    io: std.Io,
    gpa: std.mem.Allocator,
};

pub fn wakeUpMainThread() void {
    _ = sdl.events.pushUserEvent();
}

fn appendPathThreadSafe(state: *ViewerState, gpa: std.mem.Allocator, path: []const u8, initial_gen: usize) void {
    state.image_list_mutex.lockUncancelable(state.io);
    defer state.image_list_mutex.unlock(state.io);

    if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) return;
    const dup = state.directory_arena.allocator().dupe(u8, path) catch |err| {
        std.log.err("Failed to duplicate path '{s}': {}", .{ path, err });
        return;
    };
    state.image_list.append(gpa, dup) catch |err| {
        std.log.err("Failed to append path '{s}' to image_list: {}", .{ path, err });
        return;
    };
    if (state.current_index == null) {
        state.current_index = 0;
    }
    wakeUpMainThread();
}

fn scanDirectoryThreadSafe(state: *ViewerState, gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, initial_gen: usize) void {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("scanDirectoryThreadSafe: openDir failed for '{s}': {any}", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries = std.ArrayList([]const u8).empty;
    defer {
        for (dir_entries.items) |name| gpa.free(name);
        dir_entries.deinit(gpa);
    }

    while (it.next(io) catch |err| blk: {
        std.log.warn("scanDirectoryThreadSafe: iterate next failed for '{s}': {any}", .{ dir_path, err });
        break :blk null;
    }) |entry| {
        if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) return;
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (isImageExtension(ext)) {
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

    state.image_list_mutex.lockUncancelable(io);
    defer state.image_list_mutex.unlock(io);
    if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) return;

    for (dir_entries.items) |name| {
        const full_path = std.fs.path.join(state.directory_arena.allocator(), &.{ dir_path, name }) catch |err| {
            std.log.err("Failed to join path for '{s}': {}", .{ name, err });
            continue;
        };
        state.image_list.append(gpa, full_path) catch |err| {
            std.log.err("Failed to append entry '{s}': {}", .{ full_path, err });
        };
    }
    if (state.current_index == null and state.image_list.items.len > 0) {
        state.current_index = 0;
    }
    wakeUpMainThread();
}

fn stdinWorker(args: *StdinArgs) void {
    const state = args.state;
    const io = args.io;
    const gpa = args.gpa;
    const initial_gen = state.generation.load(.acquire);
    defer {
        state.is_loading_files.store(false, .release);
        wakeUpMainThread();
        state.allocator.destroy(args);
        _ = state.active_threads.fetchSub(1, .release);
    }

    var read_buf: [4096]u8 = undefined;
    var stdin_file_reader = std.Io.File.Reader.init(std.Io.File.stdin(), io, &read_buf);
    const stdin = &stdin_file_reader.interface;

    while (!state.exiting.load(.acquire) and state.generation.load(.acquire) == initial_gen) {
        const line = (stdin.takeDelimiter('\n') catch break) orelse break;
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (trimmed.len > 0) {
            if (std.Io.Dir.statFile(std.Io.Dir.cwd(), io, trimmed, .{})) |s| {
                if (s.kind == .directory) {
                    scanDirectoryThreadSafe(state, gpa, io, trimmed, initial_gen);
                } else if (isImageExtension(std.fs.path.extension(trimmed))) {
                    appendPathThreadSafe(state, gpa, trimmed, initial_gen);
                }
            } else |err| {
                std.log.debug("statFile failed for '{s}': {any}, treating as file path", .{ trimmed, err });
                appendPathThreadSafe(state, gpa, trimmed, initial_gen);
            }
        }
    }
}

pub fn readPipedStdin(state: *ViewerState, io: std.Io, gpa: std.mem.Allocator) !void {
    const is_stdin_piped = !(std.Io.File.stdin().isTty(io) catch false);
    if (is_stdin_piped) {
        const args = try state.allocator.create(StdinArgs);
        args.* = .{
            .state = state,
            .io = io,
            .gpa = gpa,
        };

        _ = state.active_threads.fetchAdd(1, .monotonic);
        state.is_loading_files.store(true, .release);

        if (std.Thread.spawn(.{}, stdinWorker, .{args})) |t| {
            t.detach();
        } else |err| {
            std.log.err("std.Thread.spawn stdin worker failed: {}", .{err});
            _ = state.active_threads.fetchSub(1, .monotonic);
            state.is_loading_files.store(false, .release);
            state.allocator.destroy(args);
        }
    }
}

pub const PathScanArgs = struct {
    state: *ViewerState,
    io: std.Io,
    gpa: std.mem.Allocator,
    target_path: []const u8,
    is_dir: bool,
};

fn pathScanWorker(args: *PathScanArgs) void {
    const state = args.state;
    const io = args.io;
    const gpa = args.gpa;
    const target_path = args.target_path;
    const is_dir = args.is_dir;
    const initial_gen = state.generation.load(.acquire);

    defer {
        state.is_loading_files.store(false, .release);
        wakeUpMainThread();
        gpa.free(target_path);
        gpa.destroy(args);
        _ = state.active_threads.fetchSub(1, .release);
    }

    const dir_path = if (is_dir) target_path else (std.fs.path.dirname(target_path) orelse ".");

    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open dir '{s}': {}", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries = std.ArrayList([]const u8).empty;
    defer {
        for (dir_entries.items) |item| gpa.free(item);
        dir_entries.deinit(gpa);
    }

    while (!state.exiting.load(.acquire) and state.generation.load(.acquire) == initial_gen) {
        const entry = (it.next(io) catch |err| {
            std.log.warn("pathScanWorker iterate failed for '{s}': {}", .{ dir_path, err });
            break;
        }) orelse break;
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (isImageExtension(ext)) {
                const full_path = std.fs.path.join(gpa, &.{ dir_path, entry.name }) catch |err| {
                    std.log.err("Failed to join path for '{s}': {}", .{ entry.name, err });
                    continue;
                };
                dir_entries.append(gpa, full_path) catch |err| {
                    std.log.err("Failed to append path '{s}': {}", .{ full_path, err });
                    gpa.free(full_path);
                    continue;
                };
            }
        }
    }

    if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) return;

    // Sort entries alphabetically
    std.mem.sort([]const u8, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lessThan);

    state.lockImageList();
    defer state.unlockImageList();

    if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) return;

    if (is_dir) {
        for (dir_entries.items) |item| {
            const dup = state.directory_arena.allocator().dupe(u8, item) catch |err| {
                std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                continue;
            };
            state.image_list.append(gpa, dup) catch |err| {
                std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
            };
        }
        if (state.current_index == null and state.image_list.items.len > 0) {
            state.current_index = 0;
        }
    } else {
        var target_idx_in_dir: ?usize = null;
        for (dir_entries.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, target_path)) {
                target_idx_in_dir = i;
                break;
            }
        }

        _ = state.directory_arena.reset(.retain_capacity);
        state.image_list.clearRetainingCapacity();
        for (dir_entries.items, 0..) |item, i| {
            const dup = state.directory_arena.allocator().dupe(u8, item) catch |err| {
                std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                continue;
            };
            state.image_list.append(gpa, dup) catch |err| {
                std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
            };
            if (target_idx_in_dir == null and std.mem.eql(u8, item, target_path)) {
                target_idx_in_dir = i;
            }
        }

        if (target_idx_in_dir) |target_i| {
            if (target_i < state.image_list.items.len) {
                state.current_index = target_i;
            }
        } else {
            state.current_index = 0;
        }
    }
}

pub fn startAsyncPathScan(state: *ViewerState, path: []const u8, is_dir: bool) !void {
    const dup_path = try state.allocator.dupe(u8, path);
    errdefer state.allocator.free(dup_path);

    const args = try state.allocator.create(PathScanArgs);
    args.* = .{
        .state = state,
        .io = state.io,
        .gpa = state.allocator,
        .target_path = dup_path,
        .is_dir = is_dir,
    };

    _ = state.active_threads.fetchAdd(1, .monotonic);
    state.is_loading_files.store(true, .release);

    if (std.Thread.spawn(.{}, pathScanWorker, .{args})) |t| {
        t.detach();
    } else |err| {
        std.log.err("std.Thread.spawn path scan worker failed: {}", .{err});
        _ = state.active_threads.fetchSub(1, .monotonic);
        state.is_loading_files.store(false, .release);
        state.allocator.free(dup_path);
        state.allocator.destroy(args);
    }
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

    var entries = std.ArrayList(DirectoryEntry).empty;
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
