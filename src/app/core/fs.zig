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

pub fn isCbzExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".cbz");
}

pub fn isCbzFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isCbzExtension(std.fs.path.extension(filename));
}

pub fn isImageFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isImageExtension(std.fs.path.extension(filename));
}

pub fn isSupportedFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isImageFile(filename) or isCbzFile(filename);
}

pub const ArchiveEntryPath = struct {
    archive_path: []const u8,
    entry_name: []const u8,
};

pub fn parseArchiveEntryPath(path: []const u8) ?ArchiveEntryPath {
    if (std.mem.indexOf(u8, path, "::")) |sep_idx| {
        return .{
            .archive_path = path[0..sep_idx],
            .entry_name = path[sep_idx + 2 ..],
        };
    }
    return null;
}

const MediaEntry = @import("state").MediaEntry;

pub fn scanCbzImageEntries(gpa: std.mem.Allocator, io: std.Io, cbz_path: []const u8, list: *std.ArrayList(MediaEntry)) !void {
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, cbz_path, .{});
    defer file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var f_reader = file.reader(io, &reader_buf);

    var iterator = try std.zip.Iterator.init(&f_reader);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var entries: std.ArrayList(MediaEntry) = .empty;
    errdefer {
        for (entries.items) |item| item.deinit(gpa);
        entries.deinit(gpa);
    }

    while (try iterator.next()) |entry| {
        if (entry.filename_len == 0) continue;
        _ = arena.reset(.retain_capacity);
        const temp_alloc = arena.allocator();

        try f_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const entry_name = try temp_alloc.alloc(u8, entry.filename_len);
        try f_reader.interface.readSliceAll(entry_name);

        if (!isImageFile(entry_name)) continue;

        const arch_path_dup = try gpa.dupe(u8, cbz_path);
        errdefer gpa.free(arch_path_dup);

        const entry_name_dup = try gpa.dupe(u8, entry_name);
        errdefer gpa.free(entry_name_dup);

        try entries.append(gpa, .{
            .archive_entry = .{
                .archive_path = arch_path_dup,
                .entry_name = entry_name_dup,
                .header_zip_offset = entry.header_zip_offset,
                .file_offset = entry.file_offset,
                .uncompressed_size = entry.uncompressed_size,
                .compression_method = @intFromEnum(entry.compression_method),
            },
        });
    }

    std.mem.sort(MediaEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: MediaEntry, b: MediaEntry) bool {
            return std.ascii.lessThanIgnoreCase(a.getBasename(), b.getBasename());
        }
    }.lessThan);

    try list.appendSlice(gpa, entries.items);
    entries.deinit(gpa);
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
    if (isCbzFile(folder_path)) {
        var counts: FolderCounts = .{};
        var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, folder_path, .{}) catch return counts;
        defer file.close(io);

        var reader_buf: [4096]u8 = undefined;
        var f_reader = file.reader(io, &reader_buf);
        var iterator = std.zip.Iterator.init(&f_reader) catch return counts;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        while (iterator.next() catch null) |entry| {
            if (entry.filename_len == 0) continue;
            _ = arena.reset(.retain_capacity);
            const temp_alloc = arena.allocator();
            f_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch continue;
            const entry_name = temp_alloc.alloc(u8, entry.filename_len) catch continue;
            f_reader.interface.readSliceAll(entry_name) catch continue;
            if (isImageFile(entry_name)) {
                counts.image_count += 1;
            }
        }
        return counts;
    }

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
            if (isImageFile(entry.name) or isCbzFile(entry.name)) {
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
        const is_dir_entry = (entry.kind == .directory);
        const is_cbz_entry = (entry.kind == .file and isCbzFile(entry.name));

        if (is_dir_entry or is_cbz_entry) {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;

            const full_path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            errdefer gpa.free(full_path);
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);

            const counts = countFolderContents(io, full_path);
            if (is_cbz_entry) {
                try entries.append(gpa, .{
                    .archive_file = .{
                        .name = name,
                        .full_path = full_path,
                        .image_count = counts.image_count,
                        .archive_type = .cbz,
                    },
                });
            } else {
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

test "CBZ file functions and archive path parsing" {
    try std.testing.expect(isCbzFile("comic.cbz"));
    try std.testing.expect(isCbzFile("path/to/manga.CBZ"));
    try std.testing.expect(!isCbzFile("image.png"));
    try std.testing.expect(isSupportedFile("comic.cbz"));

    const parsed = parseArchiveEntryPath("comic.cbz::pages/page01.jpg");
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualStrings("comic.cbz", parsed.?.archive_path);
    try std.testing.expectEqualStrings("pages/page01.jpg", parsed.?.entry_name);

    try std.testing.expectEqual(null, parseArchiveEntryPath("regular_path.jpg"));
}

test "scanCbzImageEntries on sample archive" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var entries: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    try scanCbzImageEntries(allocator, io, "5 Centimeters per Second.cbz", &entries);
    try std.testing.expect(entries.items.len > 0);
    try std.testing.expectEqualStrings("5 Centimeters per Second/page000.jpeg", entries.items[0].archive_entry.entry_name);
    try std.testing.expect(entries.items[0].archive_entry.file_offset != null);
}

test "scanDirectoryEntries includes CBZ files and countFolderContents counts CBZ images" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const counts = countFolderContents(io, "5 Centimeters per Second.cbz");
    try std.testing.expect(counts.image_count > 0);

    var dir_entries: std.ArrayList(DirectoryEntry) = .empty;
    defer {
        for (dir_entries.items) |e| {
            allocator.free(e.getName());
            if (e.getFullPath().len > 0) allocator.free(e.getFullPath());
        }
        dir_entries.deinit(allocator);
    }

    try scanDirectoryEntries(allocator, io, ".", &dir_entries);
    var found_cbz = false;
    for (dir_entries.items) |e| {
        if (std.mem.eql(u8, e.getName(), "5 Centimeters per Second.cbz")) {
            found_cbz = true;
            break;
        }
    }
    try std.testing.expect(found_cbz);
}
