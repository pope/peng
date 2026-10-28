//! Standalone Virtual File System (VFS) Module
//!
//! Provides pure, zero-SDL filesystem and archive navigation primitives,
//! container abstractions (MediaEntry, DirectoryEntry, FilePair), comic
//! archive (CBZ/ZIP) directory indexing, RAW+JPEG pair consolidation, and
//! directory scanning.

const std = @import("std");

/// Pre-discovered byte offsets and compression parameters for O(1) instant
/// seeking in ZIP/CBZ archives.
pub const ZipSeekOffsets = struct {
    header_zip_offset: u64,
    file_offset: u64,
    uncompressed_size: u64,
    compression_method: std.zip.CompressionMethod,
};

/// Tagged union representing indexing status of an archive media entry.
pub const ArchiveSeekInfo = union(enum) {
    unindexed,
    indexed: ZipSeekOffsets,
};

/// Media entry descriptor for an image stored inside a compressed or
/// uncompressed archive (CBZ, CBR, ZIP).
pub const ArchiveMediaEntry = struct {
    archive_path: []const u8,
    entry_name: []const u8,
    seek_info: ArchiveSeekInfo = .unindexed,
};

/// Holds paths to paired RAW and JPEG files sharing the same base stem.
pub const FilePair = struct {
    raw_path: []const u8,
    jpeg_path: []const u8,
};

/// Discriminated union representing either a filesystem path, a virtual entry
/// inside an archive, or a stacked RAW+JPEG file pair.
pub const MediaEntry = union(enum) {
    /// Standard file on local filesystem
    filesystem: struct {
        path: []const u8,
    },

    /// Virtual file entry inside an archive (CBZ, CBR, ZIP)
    archive_entry: ArchiveMediaEntry,

    /// Stacked RAW and companion JPEG file pair
    pair: FilePair,

    /// Returns the leaf filename of the media entry (file basename or archive
    /// entry basename).
    pub fn getBasename(self: MediaEntry) []const u8 {
        return switch (self) {
            .filesystem => |f| std.Io.Dir.path.basename(f.path),
            .archive_entry => |a| std.Io.Dir.path.basename(a.entry_name),
            .pair => |p| std.Io.Dir.path.basename(p.raw_path),
        };
    }

    /// Returns the directory containing this media file or archive container.
    pub fn getContainerName(self: MediaEntry) []const u8 {
        const raw_dir = switch (self) {
            .filesystem => |f| f.path,
            .archive_entry => |a| a.archive_path,
            .pair => |p| p.raw_path,
        };
        return std.Io.Dir.path.dirname(raw_dir) orelse ".";
    }

    /// Returns the file path or archive internal member path string.
    pub fn getPath(self: MediaEntry) []const u8 {
        return switch (self) {
            .filesystem => |f| f.path,
            .archive_entry => |a| a.entry_name,
            .pair => |p| p.raw_path,
        };
    }

    /// Returns the filesystem source path (or containing archive path for
    /// `.archive_entry`) suitable for reopening or refreshing on disk.
    pub fn getSourcePath(self: MediaEntry) []const u8 {
        return switch (self) {
            .filesystem => |f| f.path,
            .archive_entry => |a| a.archive_path,
            .pair => |p| p.raw_path,
        };
    }

    /// Returns `true` if this media item resides inside an archive container
    /// (e.g. CBZ).
    pub fn isArchive(self: MediaEntry) bool {
        return self == .archive_entry;
    }

    /// Returns `true` if this media item is a stacked RAW + JPEG pair.
    pub fn isPair(self: MediaEntry) bool {
        return self == .pair;
    }

    /// Returns the raw file path if this is a pair, or null.
    pub fn getRawPath(self: MediaEntry) ?[]const u8 {
        return switch (self) {
            .pair => |p| p.raw_path,
            .filesystem, .archive_entry => null,
        };
    }

    /// Returns the companion JPEG file path if this is a pair, or null.
    pub fn getJpegPath(self: MediaEntry) ?[]const u8 {
        return switch (self) {
            .pair => |p| p.jpeg_path,
            .filesystem, .archive_entry => null,
        };
    }

    /// Compares two path strings, normalizing any leading `"./"` prefix.
    pub fn pathsMatch(path: []const u8, target: []const u8) bool {
        if (std.mem.eql(u8, path, target)) return true;
        const p = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
        const t = if (std.mem.startsWith(u8, target, "./"))
            target[2..]
        else
            target;
        return std.mem.eql(u8, p, t);
    }

    /// Returns `true` if this media entry matches `target_path` (accounting for
    /// `./` prefixes and matching either member of a RAW+JPEG `.pair`).
    pub fn matchesTarget(self: MediaEntry, target_path: []const u8) bool {
        return switch (self) {
            .filesystem => |f| pathsMatch(f.path, target_path),
            .archive_entry => |a| pathsMatch(a.archive_path, target_path),
            .pair => |p| pathsMatch(p.raw_path, target_path) or
                pathsMatch(p.jpeg_path, target_path),
        };
    }

    /// Deeply duplicates string paths belonging to this media entry using
    /// `allocator`.
    pub fn dupe(self: MediaEntry, allocator: std.mem.Allocator) !MediaEntry {
        return switch (self) {
            .filesystem => |f| .{
                .filesystem = .{ .path = try allocator.dupe(u8, f.path) },
            },
            .archive_entry => |a| .{
                .archive_entry = .{
                    .archive_path = try allocator.dupe(u8, a.archive_path),
                    .entry_name = try allocator.dupe(u8, a.entry_name),
                    .seek_info = a.seek_info,
                },
            },
            .pair => |p| blk: {
                const raw = try allocator.dupe(u8, p.raw_path);
                errdefer allocator.free(raw);
                const jpeg = try allocator.dupe(u8, p.jpeg_path);
                break :blk .{
                    .pair = .{
                        .raw_path = raw,
                        .jpeg_path = jpeg,
                    },
                };
            },
        };
    }

    /// Frees allocated path strings for this media entry.
    pub fn deinit(self: MediaEntry, allocator: std.mem.Allocator) void {
        switch (self) {
            .filesystem => |f| allocator.free(f.path),
            .archive_entry => |a| {
                allocator.free(a.archive_path);
                allocator.free(a.entry_name);
            },
            .pair => |p| {
                allocator.free(p.raw_path);
                allocator.free(p.jpeg_path);
            },
        }
    }
};

/// Container holding image and subdirectory counts for a directory or archive
/// entry.
pub const EntryScanCounts = struct {
    image_count: usize = 0,
    subdir_count: usize = 0,
};

/// Scan status and discovery metrics for a directory or archive entry.
pub const EntryScanState = union(enum) {
    /// Entry has not yet been scanned.
    unscanned,
    /// Partial count available during incremental background scanning.
    partial_counted: EntryScanCounts,
    /// Background scan finished with complete image and subdirectory counts.
    scanned: EntryScanCounts,
    /// Counts retrieved from in-memory or on-disk metadata cache.
    cached: EntryScanCounts,
    /// Background scan failed due to I/O or decode error.
    failed,
    /// Background scan failed due to filesystem permissions.
    permission_denied,
};

/// Supported comic / compressed container formats for directory navigation.
pub const ArchiveType = enum {
    cbz,
    zip,
};

/// Tagged union representing a single item in directory navigator listings.
pub const DirectoryEntry = union(enum) {
    parent: struct {
        name: []const u8,
        full_path: []const u8 = "",
    },
    directory: struct {
        name: []const u8,
        full_path: []const u8 = "",
        scan: EntryScanState = .unscanned,
    },
    archive_file: struct {
        name: []const u8,
        full_path: []const u8 = "",
        scan: EntryScanState = .unscanned,
        archive_type: ArchiveType = .cbz,
    },
    image_file: struct {
        name: []const u8,
        full_path: []const u8 = "",
    },

    /// Returns the display basename of this directory item.
    pub fn getName(self: DirectoryEntry) []const u8 {
        return switch (self) {
            .parent => |p| p.name,
            .directory => |d| d.name,
            .archive_file => |a| a.name,
            .image_file => |f| f.name,
        };
    }

    /// Returns the full filesystem path of this directory item.
    pub fn getFullPath(self: DirectoryEntry) []const u8 {
        return switch (self) {
            .parent => |p| p.full_path,
            .directory => |d| d.full_path,
            .archive_file => |a| a.full_path,
            .image_file => |f| f.full_path,
        };
    }

    /// Returns `true` if this entry represents an archive file (e.g. CBZ/ZIP).
    pub fn isArchive(self: DirectoryEntry) bool {
        return self == .archive_file;
    }

    /// Returns the active `EntryScanState` if this entry is a directory or
    /// archive; otherwise `null`.
    pub fn getScanState(self: DirectoryEntry) ?EntryScanState {
        return switch (self) {
            .directory => |d| d.scan,
            .archive_file => |a| a.scan,
            .parent, .image_file => null,
        };
    }
};

/// Lightweight callback wrapper allowing cooperative cancellation checks
/// during long-running VFS scan operations without coupling to worker types.
pub const CancelCheck = struct {
    ctx: ?*const anyopaque = null,
    is_canceled_fn: ?*const fn (?*const anyopaque) bool = null,

    /// Queries whether the underlying cancellation source has signaled cancel.
    pub inline fn isCanceled(self: CancelCheck) bool {
        if (self.is_canceled_fn) |f| return f(self.ctx);
        return false;
    }
};

/// Returns `true` if filename is an AppleDouble metadata file starting with
/// `._`.
fn isAppleDouble(filename: []const u8) bool {
    const basename = std.Io.Dir.path.basename(filename);
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
fn isRawExtension(ext: []const u8) bool {
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
    return isRawExtension(std.Io.Dir.path.extension(filename));
}

/// Returns `true` if the file extension is `.cbz` (case-insensitive).
fn isCbzExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".cbz");
}

/// Returns `true` if the path points to a valid comic archive (`.cbz`) file
/// and is not AppleDouble metadata.
pub fn isCbzFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isCbzExtension(std.Io.Dir.path.extension(filename));
}

/// Returns `true` if the path points to a supported image file and is not
/// AppleDouble metadata.
pub fn isImageFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isImageExtension(std.Io.Dir.path.extension(filename));
}

/// Returns `true` if the path points to any supported image or CBZ archive
/// file and is not AppleDouble metadata.
fn isSupportedFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isImageFile(filename) or isCbzFile(filename);
}

/// Returns the stem of `path` (the leaf basename without its file extension).
fn getPathStem(path: []const u8) []const u8 {
    const base = std.Io.Dir.path.basename(path);
    const ext = std.Io.Dir.path.extension(base);
    return base[0 .. base.len - ext.len];
}

/// Returns `true` if the file extension matches a standard JPEG format.
fn isJpegExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg");
}

/// Returns `true` if the path points to a standard JPEG file and is not
/// AppleDouble metadata.
fn isJpegFile(filename: []const u8) bool {
    if (isAppleDouble(filename)) return false;
    return isJpegExtension(std.Io.Dir.path.extension(filename));
}

/// Consolidates adjacent sorted RAW and companion JPEG entries sharing the same
/// base filename stem into unified `.pair` entries when `stack_enabled` is
/// true. Inspects contiguous blocks of entries sharing identical stems,
/// correctly handling interleaved non-JPEG/non-RAW formats (e.g. .ARW, .bmp,
/// .JPG).
fn consolidateRawJpegPairs(
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
    if (std.mem.find(u8, path, "::")) |sep_idx| {
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
    allocator: std.mem.Allocator,
    io: std.Io,
    cbz_path: []const u8,
    list: *std.ArrayList(MediaEntry),
) !void {
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, cbz_path, .{});
    defer file.close(io);

    // Sized to 64KB:
    // Parsing central directory records involves repeated seek and struct
    // reads. A 64KB stack buffer caches adjacent directory headers, reducing
    // positional pread syscalls during archive indexing from 7 down to 3 on
    // typical multi-hundred-page archives.
    var reader_buf: [64 * 1024]u8 = undefined;
    var f_reader = file.reader(io, &reader_buf);

    var iterator = try std.zip.Iterator.init(&f_reader);

    var stack_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fb: std.heap.BufferFirstAllocator = .init(&stack_buf, allocator);
    const temp_alloc = fb.allocator();

    var entries: std.ArrayList(MediaEntry) = .empty;
    errdefer {
        for (entries.items) |item| item.deinit(allocator);
        entries.deinit(allocator);
    }

    while (try iterator.next()) |entry| {
        if (entry.filename_len == 0) continue;

        try f_reader.seekTo(
            entry.header_zip_offset +|
                @sizeOf(std.zip.CentralDirectoryFileHeader),
        );
        const entry_name = try temp_alloc.alloc(u8, entry.filename_len);
        defer temp_alloc.free(entry_name);
        try f_reader.interface.readSliceAll(entry_name);

        if (!isImageFile(entry_name)) continue;

        const arch_path_dup = try allocator.dupe(u8, cbz_path);
        errdefer allocator.free(arch_path_dup);

        const entry_name_dup = try allocator.dupe(u8, entry_name);
        errdefer allocator.free(entry_name_dup);

        try entries.append(allocator, .{
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
            return std.ascii.lessThanIgnoreCase(
                a.getPath(),
                b.getPath(),
            );
        }
    }.lessThan);

    try list.appendSlice(allocator, entries.items);
    entries.deinit(allocator);
}

/// Sorts media entries alphabetically by basename (case-insensitive) and
/// consolidates matching RAW and JPEG pairs into unified `.pair` entries.
fn sortAndConsolidateMediaEntries(
    entries: *std.ArrayList(MediaEntry),
    stack_raw_jpeg: bool,
) void {
    std.mem.sort(MediaEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: MediaEntry, b: MediaEntry) bool {
            return std.ascii.lessThanIgnoreCase(
                a.getBasename(),
                b.getBasename(),
            );
        }
    }.lessThan);
    consolidateRawJpegPairs(entries, stack_raw_jpeg);
}

/// Scans image files within `dir_path`, verifies their file kinds, appends
/// filesystem entries, and performs alphabetical sorting and RAW+JPEG pair
/// consolidation. Respects cooperative cancellation via `cancel`.
pub fn scanDirectoryMediaEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    entries: *std.ArrayList(MediaEntry),
    stack_raw_jpeg: bool,
    cancel: CancelCheck,
) !void {
    if (cancel.isCanceled()) return error.Canceled;

    var dir = try std.Io.Dir.openDir(
        std.Io.Dir.cwd(),
        io,
        dir_path,
        .{ .iterate = true },
    );
    defer dir.close(io);

    var it = dir.iterate();

    while (!cancel.isCanceled()) {
        const entry = (it.next(io) catch |err| switch (err) {
            error.Canceled => break,
            else => {
                std.log.warn(
                    "scanDirectoryMediaEntries iterate failed for '{s}': {}",
                    .{ dir_path, err },
                );
                break;
            },
        }) orelse break;
        if (isImageFile(entry.name)) {
            if (resolveEntryKind(dir, io, entry) == .file) {
                const full_path = try std.Io.Dir.path.join(
                    allocator,
                    &.{ dir_path, entry.name },
                );
                errdefer allocator.free(full_path);
                try entries.append(
                    allocator,
                    .{ .filesystem = .{ .path = full_path } },
                );
            }
        }
    }

    if (cancel.isCanceled()) return error.Canceled;

    sortAndConsolidateMediaEntries(entries, stack_raw_jpeg);
}

/// Dispatches media scanning across either a `.cbz` comic archive or a
/// filesystem target (directory or individual image file path), performing
/// sorting and RAW+JPEG pair consolidation.
pub fn scanTargetMediaEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    target_path: []const u8,
    is_dir: bool,
    entries: *std.ArrayList(MediaEntry),
    stack_raw_jpeg: bool,
    cancel: CancelCheck,
) !void {
    if (cancel.isCanceled()) return error.Canceled;
    if (isCbzFile(target_path)) {
        try scanCbzImageEntries(allocator, io, target_path, entries);
        if (cancel.isCanceled()) return error.Canceled;
    } else {
        const dir_path = if (is_dir)
            target_path
        else
            (std.Io.Dir.path.dirname(target_path) orelse ".");
        try scanDirectoryMediaEntries(
            allocator,
            io,
            dir_path,
            entries,
            stack_raw_jpeg,
            cancel,
        );
    }
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

/// Strips trailing `/` and `\` path separators from `path` while preserving
/// filesystem roots (`"/"`, `"\\"`, or Windows drive roots such as `"C:\\"`).
pub fn trimTrailingSeparators(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    if (trimmed.len == 0) {
        return path[0..1];
    }
    if (trimmed.len == 2 and
        std.ascii.isAlphabetic(trimmed[0]) and
        trimmed[1] == ':' and
        path.len > 2)
    {
        return path[0..3];
    }
    return trimmed;
}

/// Computes the parent directory path of `dir` and writes it into `buf`,
/// handling root paths, relative `..` path chains, and forward/backward slash
/// separators. Returns `null` if at filesystem root.
pub fn getParentDirBuf(dir: []const u8, buf: []u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, dir, "/\\");
    if (trimmed.len == 0) return null;

    if (isAllDotDots(trimmed)) {
        const sep = if (std.mem.findScalar(u8, trimmed, '\\') != null)
            "\\"
        else
            "/";
        return std.mem.print(buf, "{s}{s}..", .{ trimmed, sep }) catch |err| {
            std.log.warn(
                "Failed to format parent directory for '{s}': {}",
                .{ trimmed, err },
            );
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
        if (sep_idx == 2 and
            std.ascii.isAlphabetic(trimmed[0]) and
            trimmed[1] == ':')
        {
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
fn mapScanError(err: anyerror) EntryScanState {
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
) EntryScanState {
    if (isCbzFile(folder_path)) {
        var counts: EntryScanCounts = .{};
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

        var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

    var counts: EntryScanCounts = .{};
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

/// Frees each owned string element in `slice` and then frees `slice`
/// itself using `allocator`.
pub fn freeOwnedStringSlice(
    allocator: std.mem.Allocator,
    slice: []const []const u8,
) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

/// Collects and duplicates the full filesystem paths of all `.unscanned`
/// directory and archive entries in `items` with non-empty `full_path`.
/// Returns `null` without allocating if no unscanned entries are present.
pub fn collectUnscannedDirectoryPaths(
    allocator: std.mem.Allocator,
    items: []const DirectoryEntry,
) !?[][]const u8 {
    if (items.len == 0) return null;

    var count: usize = 0;
    for (items) |entry| {
        if (entry.getScanState()) |scan| {
            if (scan == .unscanned and entry.getFullPath().len > 0) {
                count += 1;
            }
        }
    }
    if (count == 0) return null;

    const paths = try allocator.alloc([]const u8, count);
    var filled: usize = 0;
    errdefer {
        for (paths[0..filled]) |p| allocator.free(p);
        allocator.free(paths);
    }
    for (items) |entry| {
        if (entry.getScanState()) |scan| {
            if (scan == .unscanned and entry.getFullPath().len > 0) {
                paths[filled] = try allocator.dupe(
                    u8,
                    entry.getFullPath(),
                );
                filled += 1;
            }
        }
    }
    std.debug.assert(filled == count);
    return paths;
}

/// Scans immediate non-hidden child subdirectories and CBZ archives within
/// `dir_path`, populates `entries` with initialized `.unscanned`
/// DirectoryEntry records, and returns the count of image files directly
/// present in `dir_path`.
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

    var dir = try std.Io.Dir.openDir(
        std.Io.Dir.cwd(),
        io,
        dir_path,
        .{ .iterate = true },
    );
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

            const full_path = try std.Io.Dir.path.join(
                gpa,
                &.{ dir_path, entry.name },
            );
            errdefer gpa.free(full_path);
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);

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

/// Resolves and returns the leaf basename of `path`. If `path` ends in `.` or
/// `..`, resolves the real filesystem path into `buf` to return the actual
/// directory name.
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
                std.log.debug(
                    "realPath failed for '{s}': {}",
                    .{ trimmed, err },
                );
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
    const dot_path = try std.mem.print(
        &dot_path_buf,
        ".zig-cache/tmp/{s}/child_dir/.",
        .{tmp.sub_path},
    );

    var dotdot_path_buf: [128]u8 = undefined;
    const dotdot_path = try std.mem.print(
        &dotdot_path_buf,
        ".zig-cache/tmp/{s}/child_dir/nested/..",
        .{tmp.sub_path},
    );

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

    try std.testing.expectEqual(
        null,
        parseArchiveEntryPath("regular_path.jpg"),
    );
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
    try std.testing.expect(
        entries.items[0].archive_entry.seek_info == .indexed,
    );
}

test "vfs scanCbzImageEntries O(1) central directory seek" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var entries: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    try scanCbzImageEntries(allocator, io, "testfiles/sample.cbz", &entries);
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);

    const first = entries.items[0].archive_entry;
    try std.testing.expect(first.seek_info == .indexed);
    try std.testing.expect(first.seek_info.indexed.uncompressed_size > 0);
    try std.testing.expect(first.seek_info.indexed.header_zip_offset > 0);

    const second = entries.items[1].archive_entry;
    try std.testing.expect(second.seek_info.indexed.file_offset > 0);
}

test "scanCbzImageEntries utilizes scan arena" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var scan_arena = std.heap.ArenaAllocator.init(allocator);
    defer scan_arena.deinit();
    const scan_alloc = scan_arena.allocator();

    var entries: std.ArrayList(MediaEntry) = .empty;
    defer entries.deinit(scan_alloc);

    try scanCbzImageEntries(
        scan_alloc,
        io,
        "testfiles/sample.cbz",
        &entries,
    );
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings(
        "000_0_1024x682.jpg",
        entries.items[0].archive_entry.entry_name,
    );
    try std.testing.expect(
        entries.items[0].archive_entry.seek_info == .indexed,
    );
}

test "scanDirectoryEntries includes CBZ and scanFolderContents counts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    try std.testing.expectEqual(
        @as(usize, 2),
        scanFolderContents(io, "testfiles/sample.cbz").scanned.image_count,
    );

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
            try std.testing.expectEqual(
                EntryScanState.unscanned,
                e.getScanState().?,
            );
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
    const tmp_dir_path = try std.mem.print(
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

    const img_count = try scanDirectoryEntries(
        allocator,
        io,
        tmp_dir_path,
        &entries,
    );

    try std.testing.expectEqual(@as(usize, 1), img_count);
    try std.testing.expectEqual(@as(usize, 3), entries.items.len);

    var exp_buf: [160]u8 = undefined;

    // Index 0: sub_a
    try std.testing.expectEqualStrings("sub_a", entries.items[0].getName());
    try std.testing.expectEqualStrings(
        try std.mem.print(&exp_buf, "{s}/sub_a", .{tmp_dir_path}),
        entries.items[0].getFullPath(),
    );
    try std.testing.expectEqual(
        EntryScanState.unscanned,
        entries.items[0].directory.scan,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        scanFolderContents(
            io,
            entries.items[0].getFullPath(),
        ).scanned.image_count,
    );

    // Index 1: sub_b
    try std.testing.expectEqualStrings("sub_b", entries.items[1].getName());
    try std.testing.expectEqualStrings(
        try std.mem.print(&exp_buf, "{s}/sub_b", .{tmp_dir_path}),
        entries.items[1].getFullPath(),
    );
    try std.testing.expectEqual(
        EntryScanState.unscanned,
        entries.items[1].directory.scan,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        scanFolderContents(
            io,
            entries.items[1].getFullPath(),
        ).scanned.image_count,
    );

    // Index 2: sub_empty
    try std.testing.expectEqualStrings("sub_empty", entries.items[2].getName());
    try std.testing.expectEqualStrings(
        try std.mem.print(&exp_buf, "{s}/sub_empty", .{tmp_dir_path}),
        entries.items[2].getFullPath(),
    );
    try std.testing.expectEqual(
        EntryScanState.unscanned,
        entries.items[2].directory.scan,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        scanFolderContents(
            io,
            entries.items[2].getFullPath(),
        ).scanned.image_count,
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
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // Relative nested path
    try std.testing.expectEqualStrings("a", getParentDirBuf("a/b", &buf).?);
    try std.testing.expectEqualStrings("a/b", getParentDirBuf("a/b/c", &buf).?);

    // Trailing slashes
    try std.testing.expectEqualStrings("a", getParentDirBuf("a/b/", &buf).?);
    try std.testing.expectEqualStrings(
        "a/b",
        getParentDirBuf("a/b/c/", &buf).?,
    );

    // Single-component relative path steps up to "."
    try std.testing.expectEqualStrings(".", getParentDirBuf("photos", &buf).?);

    // Current directory "." steps up to ".."
    try std.testing.expectEqualStrings("..", getParentDirBuf(".", &buf).?);

    // Parent directory ".." steps up to "../.."
    try std.testing.expectEqualStrings("../..", getParentDirBuf("..", &buf).?);
    try std.testing.expectEqualStrings(
        "../../..",
        getParentDirBuf("../..", &buf).?,
    );

    // Root directory returns null
    try std.testing.expect(getParentDirBuf("/", &buf) == null);
    try std.testing.expect(getParentDirBuf("///", &buf) == null);

    // Empty path returns null
    try std.testing.expect(getParentDirBuf("", &buf) == null);
}

test "vfs trimTrailingSeparators and getParentDirBuf" {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/", trimTrailingSeparators("/"));
    try std.testing.expectEqualStrings(".", getParentDirBuf("photo", &buf).?);
    try std.testing.expectEqualStrings(
        "photos",
        getParentDirBuf("photos/item.png", &buf).?,
    );
    try std.testing.expect(getParentDirBuf("/", &buf) == null);
}

test "getPathStem and isJpegFile" {
    try std.testing.expectEqualStrings("photo", getPathStem("photo.jpg"));
    try std.testing.expectEqualStrings("photo", getPathStem("photo.ARW"));
    try std.testing.expectEqualStrings(
        "photo",
        getPathStem("sub/dir/photo.nef"),
    );
    try std.testing.expectEqualStrings(
        "test.archive",
        getPathStem("test.archive.jpeg"),
    );

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
    try std.testing.expectEqualStrings(
        "DSC00941.ARW",
        list.items[0].getRawPath().?,
    );
    try std.testing.expectEqualStrings(
        "DSC00941.JPG",
        list.items[0].getJpegPath().?,
    );

    // Pair 2: DSC_0002 (NEF + JPG)
    try std.testing.expect(list.items[1].isPair());
    try std.testing.expectEqualStrings(
        "DSC_0002.NEF",
        list.items[1].getRawPath().?,
    );
    try std.testing.expectEqualStrings(
        "DSC_0002.JPG",
        list.items[1].getJpegPath().?,
    );

    // Standalone 3: single.png
    try std.testing.expect(!list.items[2].isPair());
    try std.testing.expectEqualStrings("single.png", list.items[2].getPath());

    // Standalone 4: lone.raf
    try std.testing.expect(!list.items[3].isPair());
    try std.testing.expectEqualStrings("lone.raf", list.items[3].getPath());
}

test "vfs consolidateRawJpegPairs case insensitivity" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(MediaEntry) = .empty;
    defer {
        for (list.items) |item| item.deinit(allocator);
        list.deinit(allocator);
    }

    const raw = try allocator.dupe(u8, "img.CR2");
    const jpg = try allocator.dupe(u8, "img.jpg");
    try list.append(allocator, .{ .filesystem = .{ .path = raw } });
    try list.append(allocator, .{ .filesystem = .{ .path = jpg } });

    consolidateRawJpegPairs(&list, true);

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expect(list.items[0].isPair());
    try std.testing.expectEqualStrings(
        "img.CR2",
        list.items[0].getRawPath().?,
    );
    try std.testing.expectEqualStrings(
        "img.jpg",
        list.items[0].getJpegPath().?,
    );
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
    try std.testing.expectEqualStrings(
        "DSC001.ARW",
        list.items[0].getRawPath().?,
    );
    try std.testing.expectEqualStrings(
        "DSC001.JPG",
        list.items[0].getJpegPath().?,
    );

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
        EntryScanState.permission_denied,
        mapScanError(error.AccessDenied),
    );
    try std.testing.expectEqual(
        EntryScanState.permission_denied,
        mapScanError(error.PermissionDenied),
    );
    try std.testing.expectEqual(
        EntryScanState.failed,
        mapScanError(error.FileNotFound),
    );

    // Non-existent directory -> .failed
    try std.testing.expectEqual(
        EntryScanState.failed,
        scanFolderContents(io, "testfiles/does_not_exist_dir"),
    );

    // Corrupt CBZ archive -> .failed
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const corrupt_cbz = try std.mem.print(
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
        EntryScanState.failed,
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
    const scan_root = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/scan_root",
        .{tmp.sub_path},
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        scanFolderContents(io, scan_root).scanned.image_count,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        scanFolderContents(io, scan_root).scanned.subdir_count,
    );

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

test "trimTrailingSeparators preserves root paths and strips trailing slashes" {
    try std.testing.expectEqualStrings("", trimTrailingSeparators(""));
    try std.testing.expectEqualStrings("/", trimTrailingSeparators("/"));
    try std.testing.expectEqualStrings("/", trimTrailingSeparators("///"));
    try std.testing.expectEqualStrings("\\", trimTrailingSeparators("\\"));
    try std.testing.expectEqualStrings(
        "/usr/local",
        trimTrailingSeparators("/usr/local/"),
    );
    try std.testing.expectEqualStrings(
        "/usr/local",
        trimTrailingSeparators("/usr/local"),
    );
    try std.testing.expectEqualStrings("C:\\", trimTrailingSeparators("C:\\"));
    try std.testing.expectEqualStrings("C:/", trimTrailingSeparators("C:/"));
    try std.testing.expectEqualStrings("C:", trimTrailingSeparators("C:"));
    try std.testing.expectEqualStrings(
        "C:\\Users",
        trimTrailingSeparators("C:\\Users\\"),
    );
}

test "MediaEntry - pair dupe, deinit, and accessors" {
    const allocator = std.testing.allocator;
    const raw = try allocator.dupe(u8, "photos/DSC00941.ARW");
    errdefer allocator.free(raw);
    const jpg = try allocator.dupe(u8, "photos/DSC00941.JPG");
    errdefer allocator.free(jpg);

    const entry = MediaEntry{
        .pair = .{
            .raw_path = raw,
            .jpeg_path = jpg,
        },
    };
    defer entry.deinit(allocator);

    try std.testing.expect(entry.isPair());
    try std.testing.expect(!entry.isArchive());
    try std.testing.expectEqualStrings("DSC00941.ARW", entry.getBasename());
    try std.testing.expectEqualStrings("photos", entry.getContainerName());
    try std.testing.expectEqualStrings("photos/DSC00941.ARW", entry.getPath());
    try std.testing.expectEqualStrings(
        "photos/DSC00941.ARW",
        entry.getSourcePath(),
    );
    try std.testing.expectEqualStrings(
        "photos/DSC00941.ARW",
        entry.getRawPath().?,
    );
    try std.testing.expectEqualStrings(
        "photos/DSC00941.JPG",
        entry.getJpegPath().?,
    );

    const duped = try entry.dupe(allocator);
    defer duped.deinit(allocator);

    try std.testing.expect(duped.isPair());
    try std.testing.expectEqualStrings(
        "photos/DSC00941.ARW",
        duped.getRawPath().?,
    );
    try std.testing.expectEqualStrings(
        "photos/DSC00941.JPG",
        duped.getJpegPath().?,
    );

    const archive_item = MediaEntry{
        .archive_entry = .{
            .archive_path = "comics/issue1.cbz",
            .entry_name = "pages/001.jpg",
            .seek_info = .unindexed,
        },
    };
    try std.testing.expectEqualStrings("pages/001.jpg", archive_item.getPath());
    try std.testing.expectEqualStrings(
        "comics/issue1.cbz",
        archive_item.getSourcePath(),
    );
}

test "DirectoryEntry accessors and scan state" {
    const p = DirectoryEntry{
        .parent = .{ .name = "..", .full_path = "/home/pope" },
    };
    try std.testing.expectEqualStrings("..", p.getName());
    try std.testing.expectEqualStrings("/home/pope", p.getFullPath());
    try std.testing.expect(!p.isArchive());
    try std.testing.expect(p.getScanState() == null);

    const d = DirectoryEntry{
        .directory = .{
            .name = "photos",
            .full_path = "/photos",
            .scan = .{
                .scanned = .{ .image_count = 42, .subdir_count = 3 },
            },
        },
    };
    try std.testing.expectEqualStrings("photos", d.getName());
    try std.testing.expectEqualStrings("/photos", d.getFullPath());
    try std.testing.expect(!d.isArchive());
    try std.testing.expect(d.getScanState() != null);
    try std.testing.expectEqual(
        @as(usize, 42),
        d.getScanState().?.scanned.image_count,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        d.getScanState().?.scanned.subdir_count,
    );

    const a = DirectoryEntry{
        .archive_file = .{
            .name = "comic.cbz",
            .full_path = "/comic.cbz",
            .scan = .unscanned,
        },
    };
    try std.testing.expectEqualStrings("comic.cbz", a.getName());
    try std.testing.expect(a.isArchive());
    try std.testing.expectEqual(EntryScanState.unscanned, a.getScanState().?);

    const f = DirectoryEntry{
        .image_file = .{ .name = "img.png", .full_path = "/img.png" },
    };
    try std.testing.expectEqualStrings("img.png", f.getName());
    try std.testing.expect(!f.isArchive());
    try std.testing.expect(f.getScanState() == null);
}

test "vfs scanDirectoryMediaEntries and scanTargetMediaEntries" {
    const io = std.Io.Threaded.global_single_threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 1. scanDirectoryMediaEntries on testfiles/images
    {
        var entries: std.ArrayList(MediaEntry) = .empty;
        try scanDirectoryMediaEntries(
            alloc,
            io,
            "testfiles/images",
            &entries,
            true,
            .{},
        );
        try std.testing.expect(entries.items.len > 0);
        for (
            entries.items[0 .. entries.items.len - 1],
            entries.items[1..],
        ) |a, b| {
            try std.testing.expect(
                std.ascii.lessThanIgnoreCase(
                    a.getBasename(),
                    b.getBasename(),
                ) or std.mem.eql(u8, a.getBasename(), b.getBasename()),
            );
        }
    }

    // 2. scanTargetMediaEntries on CBZ archive
    {
        var entries: std.ArrayList(MediaEntry) = .empty;
        try scanTargetMediaEntries(
            alloc,
            io,
            "testfiles/sample.cbz",
            false,
            &entries,
            true,
            .{},
        );
        try std.testing.expectEqual(@as(usize, 2), entries.items.len);
        for (entries.items) |item| {
            try std.testing.expect(item == .archive_entry);
        }
    }

    // 3. scanTargetMediaEntries on directory target
    {
        var entries: std.ArrayList(MediaEntry) = .empty;
        try scanTargetMediaEntries(
            alloc,
            io,
            "testfiles/images",
            true,
            &entries,
            true,
            .{},
        );
        try std.testing.expect(entries.items.len > 0);
    }

    // 4. CancelCheck returning error.Canceled
    {
        var entries: std.ArrayList(MediaEntry) = .empty;
        var cancel_flag = true;
        const cancel: CancelCheck = .{
            .ctx = &cancel_flag,
            .is_canceled_fn = struct {
                fn check(ctx: ?*const anyopaque) bool {
                    const f: *const bool = @ptrCast(@alignCast(ctx.?));
                    return f.*;
                }
            }.check,
        };
        const res = scanDirectoryMediaEntries(
            alloc,
            io,
            "testfiles/images",
            &entries,
            true,
            cancel,
        );
        try std.testing.expectError(error.Canceled, res);
    }
}

test "collectUnscannedDirectoryPaths - empty items returns null" {
    const items = [_]DirectoryEntry{};
    const res = try collectUnscannedDirectoryPaths(
        std.testing.allocator,
        &items,
    );
    try std.testing.expect(res == null);
}

test "collectUnscannedDirectoryPaths - no unscanned entries returns null" {
    const items = [_]DirectoryEntry{
        .{ .parent = .{ .name = "..", .full_path = "/path/to/parent" } },
        .{
            .image_file = .{
                .name = "pic.jpg",
                .full_path = "/path/to/pic.jpg",
            },
        },
        .{
            .directory = .{
                .name = "scanned_dir",
                .full_path = "/path/to/scanned_dir",
                .scan = .{ .scanned = .{} },
            },
        },
        .{
            .archive_file = .{
                .name = "sample.cbz",
                .full_path = "/path/to/sample.cbz",
                .scan = .{ .scanned = .{} },
            },
        },
        .{
            .directory = .{
                .name = "empty_path",
                .full_path = "",
                .scan = .unscanned,
            },
        },
    };
    const res = try collectUnscannedDirectoryPaths(
        std.testing.allocator,
        &items,
    );
    try std.testing.expect(res == null);
}

test "collectUnscannedDirectoryPaths - unscanned dirs and archives" {
    const items = [_]DirectoryEntry{
        .{ .parent = .{ .name = "..", .full_path = "/a" } },
        .{
            .directory = .{
                .name = "sub1",
                .full_path = "/a/sub1",
                .scan = .unscanned,
            },
        },
        .{
            .image_file = .{
                .name = "pic.png",
                .full_path = "/a/pic.png",
            },
        },
        .{
            .archive_file = .{
                .name = "book.cbz",
                .full_path = "/a/book.cbz",
                .scan = .unscanned,
            },
        },
        .{
            .directory = .{
                .name = "sub2",
                .full_path = "/a/sub2",
                .scan = .{ .scanned = .{} },
            },
        },
    };
    const maybe_paths = try collectUnscannedDirectoryPaths(
        std.testing.allocator,
        &items,
    );
    try std.testing.expect(maybe_paths != null);
    const paths = maybe_paths.?;
    defer freeOwnedStringSlice(std.testing.allocator, paths);

    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/a/sub1", paths[0]);
    try std.testing.expectEqualStrings("/a/book.cbz", paths[1]);
}

fn testCollectUnscannedOom(
    allocator: std.mem.Allocator,
    items: []const DirectoryEntry,
) !void {
    const paths = (try collectUnscannedDirectoryPaths(
        allocator,
        items,
    )) orelse return;
    freeOwnedStringSlice(allocator, paths);
}

test "collectUnscannedDirectoryPaths - OOM checkAllAllocationFailures" {
    const items = [_]DirectoryEntry{
        .{
            .directory = .{
                .name = "sub1",
                .full_path = "/a/sub1",
                .scan = .unscanned,
            },
        },
        .{
            .archive_file = .{
                .name = "book.cbz",
                .full_path = "/a/book.cbz",
                .scan = .unscanned,
            },
        },
        .{
            .directory = .{
                .name = "sub2",
                .full_path = "/a/sub2",
                .scan = .unscanned,
            },
        },
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testCollectUnscannedOom,
        .{&items},
    );
}

test "freeOwnedStringSlice - frees slices and individual strings" {
    const allocator = std.testing.allocator;
    const slice = try allocator.alloc([]const u8, 2);
    slice[0] = try allocator.dupe(u8, "hello");
    slice[1] = try allocator.dupe(u8, "world");
    freeOwnedStringSlice(allocator, slice);
}
