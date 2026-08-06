const std = @import("std");
const state_pkg = @import("state");
const DirectoryEntry = state_pkg.DirectoryEntry;

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
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
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
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
            gpa.free(entry.getName());
            if (entry.getFullPath().len > 0) gpa.free(entry.getFullPath());
        }
        entries.shrinkRetainingCapacity(start_len);
    }

    // Reserve initial unused capacity for up to 32 subfolder entries to avoid heap reallocation churn during directory scanning.
    try entries.ensureUnusedCapacity(gpa, 32);

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
                .directory = .{
                    .name = name,
                    .full_path = full_path,
                    .scan = .{
                        .scanned = .{
                            .image_count = counts.image_count,
                            .subdir_count = counts.subdir_count,
                        },
                    },
                },
            });
        }
    }

    std.mem.sort(DirectoryEntry, entries.items[start_len..], {}, struct {
        fn lessThan(_: void, a: DirectoryEntry, b: DirectoryEntry) bool {
            return std.ascii.lessThanIgnoreCase(a.getName(), b.getName());
        }
    }.lessThan);
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

test "getChildBasename" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const b = getChildBasename(io, ".", &buf);
    try std.testing.expectEqualStrings("peng", b);
}
