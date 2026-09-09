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
pub fn loadDirectoryEntries(self: *PaletteState, io: std.Io, dir_path: []const u8) !void {
    const raw_target = std.mem.trimEnd(u8, dir_path, "/\\");
    const target = if (core_fs.isCbzFile(raw_target))
        (std.fs.path.dirname(raw_target) orelse ".")
    else
        raw_target;

    const dir_path_copy = try self.allocator.dupe(u8, target);
    defer self.allocator.free(dir_path_copy);

    var navigated_up = false;
    if (self.current_nav_dir.items.len > 0) {
        var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (core_fs.getParentDirBuf(self.current_nav_dir.items, &parent_buf)) |parent_dir| {
            if (std.mem.eql(u8, dir_path_copy, parent_dir)) {
                navigated_up = true;
            }
        }
    }

    if (navigated_up) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const child_base = core_fs.getChildBasename(io, self.current_nav_dir.items, &buf);
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
        std.log.warn("Failed to scan directory '{s}': {}", .{ dir_path_copy, err });
        break :blk 0;
    };
    try self.rebuildDirectoryMatches();
    self.selection_dirty = true;
}
