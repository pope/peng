const core_fs = @import("fs.zig");
const state_pkg = @import("state");
const std = @import("std");

const DirectoryEntry = state_pkg.DirectoryEntry;
const PaletteState = state_pkg.PaletteState;
const ScoredMatch = state_pkg.ScoredMatch;

/// Populates directory entries for `dir_path` into `PaletteState`, tracks
/// directory navigation history (including last-child directory tracking for
/// upward navigation), increments scan generation, and rebuilds fuzzy directory
/// matches.
pub fn loadDirectoryEntries(
    self: *PaletteState,
    io: std.Io,
    dir_path: []const u8,
) !void {
    const raw_target = core_fs.trimTrailingSeparators(dir_path);
    const target = if (core_fs.isCbzFile(raw_target))
        (std.fs.path.dirname(raw_target) orelse ".")
    else
        raw_target;

    var fb = std.heap.stackFallback(std.fs.max_path_bytes, self.allocator);
    const temp_alloc = fb.get();
    const dir_path_copy = try temp_alloc.dupe(u8, target);
    defer temp_alloc.free(dir_path_copy);

    var path_scratch_buf: [std.fs.max_path_bytes]u8 = undefined;

    var navigated_up = false;
    if (self.current_nav_dir.items.len > 0) {
        if (core_fs.getParentDirBuf(
            self.current_nav_dir.items,
            &path_scratch_buf,
        )) |parent_dir| {
            if (std.mem.eql(u8, dir_path_copy, parent_dir)) {
                navigated_up = true;
            }
        }
    }

    if (navigated_up) {
        const child_base = core_fs.getChildBasename(
            io,
            self.current_nav_dir.items,
            &path_scratch_buf,
        );
        self.last_child_dir.clearRetainingCapacity();
        try self.last_child_dir.appendSlice(self.allocator, child_base);
    } else if (self.current_nav_dir.items.len > 0) {
        self.last_child_dir.clearRetainingCapacity();
    }

    self.current_nav_dir.clearRetainingCapacity();
    try self.current_nav_dir.appendSlice(self.allocator, dir_path_copy);

    self.last_nav_dir.clearRetainingCapacity();
    try self.last_nav_dir.appendSlice(self.allocator, dir_path_copy);

    _ = self.dir_scan_generation.fetchAdd(1, .release);

    self.clearDirItems();
    self.current_dir_image_count = core_fs.scanDirectoryEntries(
        self.allocator,
        io,
        dir_path_copy,
        &self.dir_items,
    ) catch |err| blk: {
        std.log.warn(
            "Failed to scan directory '{s}': {}",
            .{ dir_path_copy, err },
        );
        break :blk 0;
    };
    try self.rebuildDirectoryMatches();
    self.selection_dirty = true;
}

test "loadDirectoryEntries preserves root path '/' when navigating up from '/home'" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var palette = try PaletteState.init(allocator);
    defer palette.deinit();

    palette.current_nav_dir.clearRetainingCapacity();
    try palette.current_nav_dir.appendSlice(allocator, "/home");

    try loadDirectoryEntries(&palette, io, "/");

    try std.testing.expectEqualStrings("/", palette.current_nav_dir.items);
    try std.testing.expectEqualStrings("/", palette.last_nav_dir.items);
    try std.testing.expectEqualStrings("home", palette.last_child_dir.items);
}
