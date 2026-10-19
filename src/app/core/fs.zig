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

/// Returns `true` if the path points to a supported Camera RAW file and
/// is not AppleDouble metadata.
pub fn isRawFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isRawExtension(std.fs.path.extension(filename));
}

/// Returns `true` if the file extension is `.cbz` (case-insensitive).
fn isCbzExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".cbz");
}

/// Returns `true` if the path points to a valid comic archive (`.cbz`) file
/// and is not AppleDouble metadata.
pub fn isCbzFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isCbzExtension(std.fs.path.extension(filename));
}

/// Returns `true` if the path points to a supported image file and is not AppleDouble metadata.
pub fn isImageFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isImageExtension(std.fs.path.extension(filename));
}

/// Returns `true` if the path points to any supported image or CBZ archive
/// file and is not AppleDouble metadata.
fn isSupportedFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isImageFile(filename) or isCbzFile(filename);
}

/// Returns the stem of `path` (the leaf basename without its file extension).
pub fn getPathStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    return base[0 .. base.len - ext.len];
}

/// Returns `true` if the file extension matches a standard JPEG format.
pub fn isJpegExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg");
}

/// Returns `true` if the path points to a standard JPEG file and is not AppleDouble metadata.
pub fn isJpegFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isJpegExtension(std.fs.path.extension(filename));
}

/// Consolidates adjacent sorted RAW and companion JPEG entries sharing the same
/// base filename stem into unified `.pair` entries when `stack_enabled` is true.
/// Consolidates matching (RAW, JPEG) file pairs sharing the same stem into `.pair` MediaEntries.
/// Inspects contiguous blocks of entries sharing identical stems, correctly handling
/// interleaved non-JPEG/non-RAW formats (e.g. .ARW, .bmp, .JPG).
pub fn consolidateRawJpegPairs(
    entries: *std.ArrayList(MediaEntry),
    stack_enabled: bool,
) void {
    if (!stack_enabled or entries.items.len < 2) return;

    var i: usize = 0;
    while (i < entries.items.len) {
        const item = entries.items[i];
        const p = switch (item) {
            .filesystem => |f| f.path,
            else => {
                i += 1;
                continue;
            },
        };
        const stem = getPathStem(p);

        // Find the extent of the contiguous block of entries sharing this stem
        var end = i + 1;
        while (end < entries.items.len) {
            const next_item = entries.items[end];
            const next_p = switch (next_item) {
                .filesystem => |f| f.path,
                else => break,
            };
            if (!std.ascii.eqlIgnoreCase(stem, getPathStem(next_p))) break;
            end += 1;
        }

        // Within entries[i .. end], find a RAW file and a JPEG file
        var raw_idx: ?usize = null;
        var jpeg_idx: ?usize = null;
        for (entries.items[i..end], i..) |cand_item, cand_idx| {
            const cand_p = cand_item.filesystem.path;
            if (raw_idx == null and isRawFile(cand_p)) {
                raw_idx = cand_idx;
            } else if (jpeg_idx == null and isJpegFile(cand_p)) {
                jpeg_idx = cand_idx;
            }
        }

        if (raw_idx != null and jpeg_idx != null) {
            const r_idx = raw_idx.?;
            const j_idx = jpeg_idx.?;
            const raw_p = entries.items[r_idx].filesystem.path;
            const jpeg_p = entries.items[j_idx].filesystem.path;

            const primary_idx = @min(r_idx, j_idx);
            const secondary_idx = @max(r_idx, j_idx);

            entries.items[primary_idx] = .{
                .pair = .{
                    .raw_path = raw_p,
                    .jpeg_path = jpeg_p,
                },
            };
            _ = entries.orderedRemove(secondary_idx);
            // Re-examine the same group in case multiple pairs share the stem
            continue;
        }

        // No more pairs can be formed in this stem group; advance to next group
        i = end;
    }
}

/// Holds parsed components of an archive entry virtual path
/// (e.g. `path/to/archive.cbz::entry.jpg`).
const ArchiveEntryPath = struct {
    archive_path: []const u8,
    entry_name: []const u8,
};

/// Splits a compound path of the form `archive_path::entry_name` into an
/// `ArchiveEntryPath` struct, or returns `null`.
fn parseArchiveEntryPath(path: []const u8) ?ArchiveEntryPath {
    if (std.mem.indexOf(u8, path, "::")) |sep_idx| {
        return .{
            .archive_path = path[0..sep_idx],
            .entry_name = path[sep_idx + 2 ..],
        };
    }
    return null;
}

/// Scans central directory headers in a CBZ ZIP archive, appending all
/// discovered image entries to `list`.
pub fn scanCbzImageEntries(
    gpa: std.mem.Allocator,
    io: std.Io,
    cbz_path: []const u8,
    list: *std.ArrayList(MediaEntry),
) !void {
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, cbz_path, .{});
    defer file.close(io);

    // Sized to 64KB:
    // Parsing central directory records involves repeated seek and struct reads.
    // A 64KB stack buffer caches adjacent directory headers, reducing positional pread
    // syscalls during archive indexing from 7 down to 3 on typical multi-hundred-page archives.
    var reader_buf: [64 * 1024]u8 = undefined;
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

        try f_reader.seekTo(
            entry.header_zip_offset +|
                @sizeOf(std.zip.CentralDirectoryFileHeader),
        );
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
                .seek_info = .{
                    .indexed = .{
                        .header_zip_offset = entry.header_zip_offset,
                        .file_offset = entry.file_offset,
                        .uncompressed_size = entry.uncompressed_size,
                        .compression_method = entry.compression_method,
                    },
                },
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
/// relative `..` path chains, and forward/backward slash separators.
/// Returns `null` if at filesystem root.
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

    const is_win_drive = trimmed.len == 2 and
        std.ascii.isAlphabetic(trimmed[0]) and
        trimmed[1] == ':';
    if (std.mem.eql(u8, trimmed, "/") or is_win_drive) {
        return null;
    }

    return ".";
}

/// Aggregated count of image files and child subdirectories inside a directory or CBZ container.
pub const FolderCounts = struct {
    image_count: usize = 0,
    subdir_count: usize = 0,
};

/// Resolves `entry.kind`, following symbolic links via `dir.statFile` when
/// `entry.kind == .sym_link`. Returns `null` if a symbolic link is hidden,
/// broken, or inaccessible.
pub inline fn resolveEntryKind(
    dir: std.Io.Dir,
    io: std.Io,
    entry: std.Io.Dir.Entry,
) ?std.Io.File.Kind {
    if (entry.kind != .sym_link) return entry.kind;
    if (std.mem.startsWith(u8, entry.name, ".")) return null;
    const s = dir.statFile(io, entry.name, .{}) catch return null;
    return s.kind;
}

/// Maps a filesystem or archive I/O error into the corresponding
/// `EntryScanState` badge variant (`.permission_denied` vs `.failed`).
pub fn mapScanError(err: anyerror) state_pkg.EntryScanState {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        else => .failed,
    };
}

/// Scans `folder_path` (either a filesystem directory or `.cbz` archive) and
/// returns its `EntryScanState`: `.scanned` with image and subdirectory counts,
/// `.permission_denied` when access is denied, or `.failed` on I/O or archive
/// corruption errors.
pub fn scanFolderContents(
    io: std.Io,
    folder_path: []const u8,
) state_pkg.EntryScanState {
    if (isCbzFile(folder_path)) {
        var counts: state_pkg.EntryScanCounts = .{};
        var file = std.Io.Dir.openFile(
            std.Io.Dir.cwd(),
            io,
            folder_path,
            .{},
        ) catch |err| return mapScanError(err);
        defer file.close(io);

        // Sized to 64KB to minimize positional pread syscalls during rapid
        // central directory traversal when counting archive pages.
        var reader_buf: [64 * 1024]u8 = undefined;
        var f_reader = file.reader(io, &reader_buf);
        var iterator = std.zip.Iterator.init(&f_reader) catch |err| {
            return mapScanError(err);
        };

        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (true) {
            const entry = (iterator.next() catch |err| {
                return mapScanError(err);
            }) orelse break;
            if (entry.filename_len == 0 or
                entry.filename_len > name_buf.len) continue;
            const hdr_size = @sizeOf(std.zip.CentralDirectoryFileHeader);
            f_reader.seekTo(entry.header_zip_offset +| hdr_size) catch |err| {
                return mapScanError(err);
            };
            const entry_name = name_buf[0..entry.filename_len];
            f_reader.interface.readSliceAll(entry_name) catch |err| {
                return mapScanError(err);
            };
            if (isImageFile(entry_name)) {
                counts.image_count += 1;
            }
        }
        return .{ .scanned = counts };
    }

    var dir = std.Io.Dir.openDir(
        std.Io.Dir.cwd(),
        io,
        folder_path,
        .{ .iterate = true },
    ) catch |err| {
        std.log.debug(
            "scanFolderContents openDir failed for '{s}': {}",
            .{ folder_path, err },
        );
        return mapScanError(err);
    };
    defer dir.close(io);

    var counts: state_pkg.EntryScanCounts = .{};
    var it = dir.iterate();
    while (true) {
        const entry = (it.next(io) catch |err| {
            std.log.debug(
                "scanFolderContents iterate failed for '{s}': {}",
                .{ folder_path, err },
            );
            return mapScanError(err);
        }) orelse break;
        const kind = resolveEntryKind(dir, io, entry) orelse continue;
        if (kind == .file) {
            if (isImageFile(entry.name) or isCbzFile(entry.name)) {
                counts.image_count += 1;
            }
        } else if (kind == .directory) {
            if (!std.mem.startsWith(u8, entry.name, ".")) {
                counts.subdir_count += 1;
            }
        }
    }
    return .{ .scanned = counts };
}

/// Counts supported image files and non-hidden subdirectories inside
/// `folder_path`. Inspects CBZ central directory tables directly if
/// `folder_path` points to a comic archive.
pub fn countFolderContents(io: std.Io, folder_path: []const u8) FolderCounts {
    return switch (scanFolderContents(io, folder_path)) {
        .scanned, .partial_counted, .cached => |c| .{
            .image_count = c.image_count,
            .subdir_count = c.subdir_count,
        },
        .unscanned, .failed, .permission_denied => .{},
    };
}

/// Scans immediate non-hidden child subdirectories and CBZ archives within `dir_path`,
/// populates `entries` with initialized `.unscanned` DirectoryEntry records,
/// and returns the count of image files directly present in `dir_path`.
pub fn scanDirectoryEntries(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    entries: *std.ArrayList(DirectoryEntry),
) !usize {
    const start_len = entries.items.len;
    errdefer {
        for (entries.items[start_len..]) |entry| {
            gpa.free(entry.getName());
            if (entry.getFullPath().len > 0) gpa.free(entry.getFullPath());
        }
        entries.shrinkRetainingCapacity(start_len);
    }

    // Reserve initial unused capacity for up to 32 subfolder entries to avoid
    // heap reallocation churn during directory scanning.
    try entries.ensureUnusedCapacity(gpa, 32);

    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var current_dir_images: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const kind = resolveEntryKind(dir, io, entry) orelse continue;
        if (kind == .file and isSupportedFile(entry.name)) {
            current_dir_images += 1;
        }

        const is_dir_entry = (kind == .directory);
        const is_cbz_entry = (kind == .file and isCbzFile(entry.name));

        if (is_dir_entry or is_cbz_entry) {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;

            const full_path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            errdefer gpa.free(full_path);
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);

            // TODO: Option 3 - Implement an in-memory path-to-count cache (LRU / hash map)
            // to restore folder counts instantly on back/forth navigation.
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

/// Resolves and returns the leaf basename of `path`. If `path` ends in `.` or `..`,
/// resolves the real filesystem path into `buf` to return the actual directory name.
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "child_dir/nested");

    var dot_path_buf: [128]u8 = undefined;
    const dot_path = try std.fmt.bufPrint(
        &dot_path_buf,
        ".zig-cache/tmp/{s}/child_dir/.",
        .{tmp.sub_path},
    );

    var dotdot_path_buf: [128]u8 = undefined;
    const dotdot_path = try std.fmt.bufPrint(
        &dotdot_path_buf,
        ".zig-cache/tmp/{s}/child_dir/nested/..",
        .{tmp.sub_path},
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "child_dir",
        getChildBasename(io, dot_path, &buf),
    );
    try std.testing.expectEqualStrings(
        "child_dir",
        getChildBasename(io, dotdot_path, &buf),
    );
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

    try scanCbzImageEntries(allocator, io, "testfiles/sample.cbz", &entries);
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings(
        "000_0_1024x682.jpg",
        entries.items[0].archive_entry.entry_name,
    );
    try std.testing.expect(entries.items[0].archive_entry.seek_info == .indexed);
}

test "scanDirectoryEntries includes CBZ files and countFolderContents counts CBZ images" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const counts = countFolderContents(io, "testfiles/sample.cbz");
    try std.testing.expectEqual(@as(usize, 2), counts.image_count);

    var dir_entries: std.ArrayList(DirectoryEntry) = .empty;
    defer {
        for (dir_entries.items) |e| {
            allocator.free(e.getName());
            if (e.getFullPath().len > 0) allocator.free(e.getFullPath());
        }
        dir_entries.deinit(allocator);
    }

    _ = try scanDirectoryEntries(allocator, io, "testfiles", &dir_entries);
    var found_cbz = false;
    for (dir_entries.items) |e| {
        if (std.mem.eql(u8, e.getName(), "sample.cbz")) {
            found_cbz = true;
            try std.testing.expectEqual(state_pkg.EntryScanState.unscanned, e.getScanState().?);
            break;
        }
    }
    try std.testing.expect(found_cbz);
}

test "scanDirectoryEntries - nested directory hierarchy" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const tmp_dir_path = try std.fmt.bufPrint(
        &path_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    // Setup directory structure
    try tmp.dir.createDirPath(io, "sub_b");
    try tmp.dir.createDirPath(io, "sub_a");
    try tmp.dir.createDirPath(io, "sub_empty");

    // Create test files
    {
        var f0 = try tmp.dir.createFile(io, "root.png", .{});
        f0.close(io);

        var f1 = try tmp.dir.createFile(io, "sub_b/img1.png", .{});
        f1.close(io);
        var f2 = try tmp.dir.createFile(io, "sub_b/img2.jpg", .{});
        f2.close(io);
        var f3 = try tmp.dir.createFile(io, "sub_b/txt1.txt", .{});
        f3.close(io);

        var f4 = try tmp.dir.createFile(io, "sub_a/pic.webp", .{});
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

    var exp_buf: [160]u8 = undefined;

    // Index 0: sub_a
    try std.testing.expectEqualStrings("sub_a", entries.items[0].getName());
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&exp_buf, "{s}/sub_a", .{tmp_dir_path}),
        entries.items[0].getFullPath(),
    );
    try std.testing.expectEqual(
        state_pkg.EntryScanState.unscanned,
        entries.items[0].directory.scan,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countFolderContents(io, entries.items[0].getFullPath()).image_count,
    );

    // Index 1: sub_b
    try std.testing.expectEqualStrings("sub_b", entries.items[1].getName());
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&exp_buf, "{s}/sub_b", .{tmp_dir_path}),
        entries.items[1].getFullPath(),
    );
    try std.testing.expectEqual(
        state_pkg.EntryScanState.unscanned,
        entries.items[1].directory.scan,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countFolderContents(io, entries.items[1].getFullPath()).image_count,
    );

    // Index 2: sub_empty
    try std.testing.expectEqualStrings("sub_empty", entries.items[2].getName());
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&exp_buf, "{s}/sub_empty", .{tmp_dir_path}),
        entries.items[2].getFullPath(),
    );
    try std.testing.expectEqual(
        state_pkg.EntryScanState.unscanned,
        entries.items[2].directory.scan,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countFolderContents(io, entries.items[2].getFullPath()).image_count,
    );
}

test "scanCbzImageEntries - scans archive entries using 64KB reader buffer" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const cbz_path = "testfiles/sample.cbz";
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, cbz_path, .{});
    file.close(io);

    var entries: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    try scanCbzImageEntries(allocator, io, cbz_path, &entries);
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings(
        "000_0_1024x682.jpg",
        entries.items[0].archive_entry.entry_name,
    );
}

test "getParentDirBuf - path variations and edge cases" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // Relative nested path
    try std.testing.expectEqualStrings("a", getParentDirBuf("a/b", &buf).?);
    try std.testing.expectEqualStrings("a/b", getParentDirBuf("a/b/c", &buf).?);

    // Trailing slashes
    try std.testing.expectEqualStrings("a", getParentDirBuf("a/b/", &buf).?);
    try std.testing.expectEqualStrings("a/b", getParentDirBuf("a/b/c/", &buf).?);

    // Single-component relative path steps up to "."
    try std.testing.expectEqualStrings(".", getParentDirBuf("photos", &buf).?);

    // Current directory "." steps up to ".."
    try std.testing.expectEqualStrings("..", getParentDirBuf(".", &buf).?);

    // Parent directory ".." steps up to "../.."
    try std.testing.expectEqualStrings("../..", getParentDirBuf("..", &buf).?);
    try std.testing.expectEqualStrings("../../..", getParentDirBuf("../..", &buf).?);

    // Root directory returns null
    try std.testing.expect(getParentDirBuf("/", &buf) == null);
    try std.testing.expect(getParentDirBuf("///", &buf) == null);

    // Empty path returns null
    try std.testing.expect(getParentDirBuf("", &buf) == null);
}

test "getPathStem and isJpegFile" {
    try std.testing.expectEqualStrings("photo", getPathStem("photo.jpg"));
    try std.testing.expectEqualStrings("photo", getPathStem("photo.ARW"));
    try std.testing.expectEqualStrings("photo", getPathStem("sub/dir/photo.nef"));
    try std.testing.expectEqualStrings("test.archive", getPathStem("test.archive.jpeg"));

    try std.testing.expect(isJpegFile("img.jpg"));
    try std.testing.expect(isJpegFile("img.JPEG"));
    try std.testing.expect(!isJpegFile("img.arw"));
    try std.testing.expect(!isJpegFile("._img.jpg"));
}

test "consolidateRawJpegPairs - bidirectional pairing and unmatched isolation" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (list.items) |item| item.deinit(allocator);
        list.deinit(allocator);
    }

    // 1. Sony ARW (< .JPG in alphabetical order)
    const arw1 = try allocator.dupe(u8, "DSC00941.ARW");
    const jpg1 = try allocator.dupe(u8, "DSC00941.JPG");
    try list.append(allocator, .{ .filesystem = .{ .path = arw1 } });
    try list.append(allocator, .{ .filesystem = .{ .path = jpg1 } });

    // 2. Nikon NEF (> .JPG in alphabetical order)
    const jpg2 = try allocator.dupe(u8, "DSC_0002.JPG");
    const nef2 = try allocator.dupe(u8, "DSC_0002.NEF");
    try list.append(allocator, .{ .filesystem = .{ .path = jpg2 } });
    try list.append(allocator, .{ .filesystem = .{ .path = nef2 } });

    // 3. Unmatched standalone PNG
    const png3 = try allocator.dupe(u8, "single.png");
    try list.append(allocator, .{ .filesystem = .{ .path = png3 } });

    // 4. Unmatched standalone RAW
    const raw4 = try allocator.dupe(u8, "lone.raf");
    try list.append(allocator, .{ .filesystem = .{ .path = raw4 } });

    try std.testing.expectEqual(@as(usize, 6), list.items.len);

    consolidateRawJpegPairs(&list, true);

    // Should collapse 6 entries to 4 entries (2 pairs + 2 standalone)
    try std.testing.expectEqual(@as(usize, 4), list.items.len);

    // Pair 1: DSC00941 (ARW + JPG)
    try std.testing.expect(list.items[0].isPair());
    try std.testing.expectEqualStrings("DSC00941.ARW", list.items[0].getRawPath().?);
    try std.testing.expectEqualStrings("DSC00941.JPG", list.items[0].getJpegPath().?);

    // Pair 2: DSC_0002 (NEF + JPG)
    try std.testing.expect(list.items[1].isPair());
    try std.testing.expectEqualStrings("DSC_0002.NEF", list.items[1].getRawPath().?);
    try std.testing.expectEqualStrings("DSC_0002.JPG", list.items[1].getJpegPath().?);

    // Standalone 3: single.png
    try std.testing.expect(!list.items[2].isPair());
    try std.testing.expectEqualStrings("single.png", list.items[2].getPath());

    // Standalone 4: lone.raf
    try std.testing.expect(!list.items[3].isPair());
    try std.testing.expectEqualStrings("lone.raf", list.items[3].getPath());
}

test "consolidateRawJpegPairs - interleaved formats with identical stem" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (list.items) |item| item.deinit(allocator);
        list.deinit(allocator);
    }

    // Alphabetical order: .ARW < .bmp < .JPG
    const arw = try allocator.dupe(u8, "DSC001.ARW");
    const bmp = try allocator.dupe(u8, "DSC001.bmp");
    const jpg = try allocator.dupe(u8, "DSC001.JPG");
    try list.append(allocator, .{ .filesystem = .{ .path = arw } });
    try list.append(allocator, .{ .filesystem = .{ .path = bmp } });
    try list.append(allocator, .{ .filesystem = .{ .path = jpg } });

    consolidateRawJpegPairs(&list, true);

    // Should collapse 3 entries to 2 (1 pair + 1 standalone bmp)
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(list.items[0].isPair());
    try std.testing.expectEqualStrings("DSC001.ARW", list.items[0].getRawPath().?);
    try std.testing.expectEqualStrings("DSC001.JPG", list.items[0].getJpegPath().?);

    try std.testing.expect(!list.items[1].isPair());
    try std.testing.expectEqualStrings("DSC001.bmp", list.items[1].getPath());
}

test "consolidateRawJpegPairs - disabled stacking leaves entries unchanged" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (list.items) |item| item.deinit(allocator);
        list.deinit(allocator);
    }

    const arw = try allocator.dupe(u8, "DSC001.ARW");
    const jpg = try allocator.dupe(u8, "DSC001.JPG");
    try list.append(allocator, .{ .filesystem = .{ .path = arw } });
    try list.append(allocator, .{ .filesystem = .{ .path = jpg } });

    consolidateRawJpegPairs(&list, false);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(!list.items[0].isPair());
    try std.testing.expect(!list.items[1].isPair());
}

test "scanFolderContents and mapScanError classify errors and corrupt CBZ" {
    const io = std.Io.Threaded.global_single_threaded.io();

    try std.testing.expectEqual(
        state_pkg.EntryScanState.permission_denied,
        mapScanError(error.AccessDenied),
    );
    try std.testing.expectEqual(
        state_pkg.EntryScanState.permission_denied,
        mapScanError(error.PermissionDenied),
    );
    try std.testing.expectEqual(
        state_pkg.EntryScanState.failed,
        mapScanError(error.FileNotFound),
    );

    // Non-existent directory -> .failed
    try std.testing.expectEqual(
        state_pkg.EntryScanState.failed,
        scanFolderContents(io, "testfiles/does_not_exist_dir"),
    );

    // Corrupt CBZ archive -> .failed
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const corrupt_cbz = try std.fmt.bufPrint(
        &path_buf,
        ".zig-cache/tmp/{s}/corrupt.cbz",
        .{tmp.sub_path},
    );
    {
        var f = try tmp.dir.createFile(io, "corrupt.cbz", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "not a valid zip archive");
    }
    try std.testing.expectEqual(
        state_pkg.EntryScanState.failed,
        scanFolderContents(io, corrupt_cbz),
    );
}

test "scanDirectoryEntries and scanFolderContents follow symlinks" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "target_dir");
    {
        var f = try tmp.dir.createFile(io, "target_dir/real.jpg", .{});
        f.close(io);
    }
    try tmp.dir.createDirPath(io, "scan_root");

    try tmp.dir.symLink(io, "../target_dir", "scan_root/linked_dir", .{
        .is_directory = true,
    });
    try tmp.dir.symLink(
        io,
        "../target_dir/real.jpg",
        "scan_root/linked.jpg",
        .{},
    );
    try tmp.dir.symLink(
        io,
        "../target_dir/real.jpg",
        "scan_root/.hidden_link.jpg",
        .{},
    );
    try tmp.dir.symLink(io, "../missing.jpg", "scan_root/broken.jpg", .{});

    var path_buf: [128]u8 = undefined;
    const scan_root = try std.fmt.bufPrint(
        &path_buf,
        ".zig-cache/tmp/{s}/scan_root",
        .{tmp.sub_path},
    );

    const counts = countFolderContents(io, scan_root);
    try std.testing.expectEqual(@as(usize, 1), counts.image_count);
    try std.testing.expectEqual(@as(usize, 1), counts.subdir_count);

    var entries: std.ArrayList(DirectoryEntry) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.getName());
            if (e.getFullPath().len > 0) allocator.free(e.getFullPath());
        }
        entries.deinit(allocator);
    }
    const direct_imgs = try scanDirectoryEntries(
        allocator,
        io,
        scan_root,
        &entries,
    );
    try std.testing.expectEqual(@as(usize, 1), direct_imgs);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings(
        "linked_dir",
        entries.items[0].getName(),
    );
}
