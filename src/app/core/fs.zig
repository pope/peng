const state_pkg = @import("state");
const std = @import("std");

const DirectoryEntry = state_pkg.DirectoryEntry;
const MediaEntry = state_pkg.MediaEntry;

/// Returns `true` if filename is an AppleDouble metadata file starting with `._`.
fn isAppleDouble(filename: []const u8) bool {
    const basename = std.fs.path.basename(filename);
    return std.mem.startsWith(u8, basename, "._");
}

/// Returns `true` if the file extension matches a supported image format.
fn isImageExtension(ext: []const u8) bool {
    const extensions = [_][]const u8{
        ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".webp",
        ".arw", ".raf", ".cr2",  ".nef", ".dng", ".orf", ".rw2",
        ".pef",
    };
    for (extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// Returns `true` if the file extension matches a supported Camera RAW format.
pub fn isRawExtension(ext: []const u8) bool {
    const raw_extensions = [_][]const u8{
        ".arw", ".raf", ".cr2", ".nef", ".dng", ".orf", ".rw2", ".pef",
    };
    for (raw_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// Returns `true` if the path points to a supported Camera RAW file and is not AppleDouble metadata.
pub fn isRawFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isRawExtension(std.fs.path.extension(filename));
}

/// Returns `true` if the file extension is `.cbz` (case-insensitive).
fn isCbzExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".cbz");
}

/// Returns `true` if the path points to a valid comic archive (`.cbz`) file and is not AppleDouble metadata.
pub fn isCbzFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isCbzExtension(std.fs.path.extension(filename));
}

/// Returns `true` if the path points to a supported image file and is not AppleDouble metadata.
pub fn isImageFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isImageExtension(std.fs.path.extension(filename));
}

/// Returns `true` if the path points to any supported image or CBZ archive file and is not AppleDouble metadata.
fn isSupportedFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isImageFile(filename) or isCbzFile(filename);
}

/// Holds parsed components of an archive entry virtual path (e.g. `path/to/archive.cbz::entry.jpg`).
const ArchiveEntryPath = struct {
    archive_path: []const u8,
    entry_name: []const u8,
};

/// Splits a compound path of the form `archive_path::entry_name` into an `ArchiveEntryPath` struct, or returns `null`.
fn parseArchiveEntryPath(path: []const u8) ?ArchiveEntryPath {
    if (std.mem.indexOf(u8, path, "::")) |sep_idx| {
        return .{
            .archive_path = path[0..sep_idx],
            .entry_name = path[sep_idx + 2 ..],
        };
    }
    return null;
}

/// Scans central directory headers in a CBZ ZIP archive, appending all discovered image entries to `list`.
pub fn scanCbzImageEntries(gpa: std.mem.Allocator, io: std.Io, cbz_path: []const u8, list: *std.ArrayList(MediaEntry)) !void {
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, cbz_path, .{});
    defer file.close(io);

    // Sized to 64KB:
    // Parsing central directory records involves repeated seek and struct reads.
    // A 64KB stack buffer caches adjacent directory headers, reducing positional pread
    // syscalls during archive indexing from 7 down to 3 on typical multi-hundred-page archives.
    var reader_buf: [65536]u8 = undefined;
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

/// Computes the parent directory path of `dir` and writes it into `buf`, handling root paths,
/// relative `..` path chains, and forward/backward slash separators. Returns `null` if at filesystem root.
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

/// Aggregated count of image files and child subdirectories inside a directory or CBZ container.
pub const FolderCounts = struct {
    image_count: usize = 0,
    subdir_count: usize = 0,
};

/// Counts supported image files and non-hidden subdirectories inside `folder_path`.
/// Inspects CBZ central directory tables directly if `folder_path` points to a comic archive.
pub fn countFolderContents(io: std.Io, folder_path: []const u8) FolderCounts {
    if (isCbzFile(folder_path)) {
        var counts: FolderCounts = .{};
        var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, folder_path, .{}) catch return counts;
        defer file.close(io);

        // Sized to 64KB to minimize positional pread syscalls during rapid central directory traversal when counting archive pages.
        var reader_buf: [65536]u8 = undefined;
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

/// Scans immediate non-hidden child subdirectories and CBZ archives within `dir_path`,
/// populates `entries` with initialized `.unscanned` DirectoryEntry records,
/// and returns the count of image files directly present in `dir_path`.
pub fn scanDirectoryEntries(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, entries: *std.ArrayList(DirectoryEntry)) !usize {
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

    var current_dir_images: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and (isImageFile(entry.name) or isCbzFile(entry.name))) {
            current_dir_images += 1;
        }

        const is_dir_entry = (entry.kind == .directory);
        const is_cbz_entry = (entry.kind == .file and isCbzFile(entry.name));

        if (is_dir_entry or is_cbz_entry) {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;

            const full_path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            errdefer gpa.free(full_path);
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);

            // TODO: Option 3 - Implement an in-memory path-to-count cache (LRU / hash map) to restore folder counts instantly on back/forth navigation.
            if (is_cbz_entry) {
                try entries.append(gpa, .{
                    .archive_file = .{
                        .name = name,
                        .full_path = full_path,
                        .scan = .unscanned,
                        .archive_type = .cbz,
                    },
                });
            } else {
                try entries.append(gpa, .{
                    .directory = .{
                        .name = name,
                        .full_path = full_path,
                        .scan = .unscanned,
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

    return current_dir_images;
}

/// Resolves and returns the leaf basename of `path`. If `path` ends in `.` or `..`, resolves the real
/// filesystem path into `buf` to return the actual directory name.
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

test "isRawFile and isImageExtension recognition" {
    try std.testing.expect(isRawFile("photo.arw"));
    try std.testing.expect(isRawFile("photo.ARW"));
    try std.testing.expect(isRawFile("photo.raf"));
    try std.testing.expect(isRawFile("photo.RAF"));
    try std.testing.expect(isRawFile("photo.cr2"));
    try std.testing.expect(isRawFile("photo.nef"));
    try std.testing.expect(isRawFile("photo.dng"));
    try std.testing.expect(isRawFile("photo.orf"));
    try std.testing.expect(isRawFile("photo.rw2"));
    try std.testing.expect(isRawFile("photo.pef"));

    try std.testing.expect(!isRawFile("photo.jpg"));
    try std.testing.expect(!isRawFile("photo.png"));
    try std.testing.expect(!isRawFile("._photo.arw")); // AppleDouble ignored

    try std.testing.expect(isImageFile("photo.arw"));
    try std.testing.expect(isImageFile("photo.raf"));
    try std.testing.expect(isSupportedFile("photo.arw"));
    try std.testing.expect(isSupportedFile("photo.raf"));
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

    _ = try scanDirectoryEntries(allocator, io, ".", &dir_entries);
    var found_cbz = false;
    for (dir_entries.items) |e| {
        if (std.mem.eql(u8, e.getName(), "5 Centimeters per Second.cbz")) {
            found_cbz = true;
            try std.testing.expect(e.getImageCount() == null);
            try std.testing.expectEqual(state_pkg.EntryScanState.unscanned, e.getScanState().?);
            break;
        }
    }
    try std.testing.expect(found_cbz);
}

test "scanDirectoryEntries - nested directory hierarchy" {
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
            allocator.free(e.getName());
            if (e.getFullPath().len > 0) allocator.free(e.getFullPath());
        }
        entries.deinit(allocator);
    }

    const img_count = try scanDirectoryEntries(allocator, io, tmp_dir_path, &entries);

    try std.testing.expectEqual(@as(usize, 1), img_count);
    try std.testing.expectEqual(@as(usize, 3), entries.items.len);

    // Index 0: sub_a
    try std.testing.expectEqualStrings("sub_a", entries.items[0].getName());
    try std.testing.expectEqualStrings(tmp_dir_path ++ "/sub_a", entries.items[0].getFullPath());
    try std.testing.expectEqual(state_pkg.FolderScanState.unscanned, entries.items[0].directory.scan);
    try std.testing.expect(entries.items[0].getImageCount() == null);
    try std.testing.expectEqual(@as(usize, 1), countFolderContents(io, entries.items[0].getFullPath()).image_count);

    // Index 1: sub_b
    try std.testing.expectEqualStrings("sub_b", entries.items[1].getName());
    try std.testing.expectEqualStrings(tmp_dir_path ++ "/sub_b", entries.items[1].getFullPath());
    try std.testing.expectEqual(state_pkg.FolderScanState.unscanned, entries.items[1].directory.scan);
    try std.testing.expect(entries.items[1].getImageCount() == null);
    try std.testing.expectEqual(@as(usize, 2), countFolderContents(io, entries.items[1].getFullPath()).image_count);

    // Index 2: sub_empty
    try std.testing.expectEqualStrings("sub_empty", entries.items[2].getName());
    try std.testing.expectEqualStrings(tmp_dir_path ++ "/sub_empty", entries.items[2].getFullPath());
    try std.testing.expectEqual(state_pkg.FolderScanState.unscanned, entries.items[2].directory.scan);
    try std.testing.expect(entries.items[2].getImageCount() == null);
    try std.testing.expectEqual(@as(usize, 0), countFolderContents(io, entries.items[2].getFullPath()).image_count);
}

test "scanCbzImageEntries - scans archive entries using 64KB reader buffer" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const cbz_path = "5 Centimeters per Second.cbz";
    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, cbz_path, .{}) catch return;
    file.close(io);

    var entries: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    try scanCbzImageEntries(allocator, io, cbz_path, &entries);
    try std.testing.expect(entries.items.len > 0);
    try std.testing.expectEqualStrings("5 Centimeters per Second/page000.jpeg", entries.items[0].archive_entry.entry_name);
}
