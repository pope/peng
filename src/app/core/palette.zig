const std = @import("std");
const state_pkg = @import("state");
const core_fs = @import("fs.zig");

const PaletteState = state_pkg.PaletteState;
const PaletteModeData = state_pkg.PaletteModeData;
const ScoredMatch = state_pkg.ScoredMatch;
const DirectoryEntry = state_pkg.DirectoryEntry;

pub fn loadDirectoryEntries(self: *PaletteState, io: std.Io, dir_path: []const u8) !void {
    const dir_path_copy = try self.allocator.dupe(u8, std.mem.trimEnd(u8, dir_path, "/\\"));
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
    } else {
        self.last_child_dir.clearRetainingCapacity();
    }

    self.current_nav_dir.clearRetainingCapacity();
    try self.current_nav_dir.appendSlice(self.allocator, dir_path_copy);

    self.last_nav_dir.clearRetainingCapacity();
    try self.last_nav_dir.appendSlice(self.allocator, dir_path_copy);

    self.current_dir_image_count = core_fs.countFolderImages(io, dir_path_copy);

    clearDirItems(self);
    core_fs.scanDirectoryEntries(self.allocator, io, dir_path_copy, &self.dir_items) catch |err| {
        std.log.warn("Failed to scan directory '{s}': {}", .{ dir_path_copy, err });
    };
    try rebuildDirectoryMatches(self);
    self.selection_dirty = true;
}

fn clearDirItems(self: *PaletteState) void {
    self.clearDirItems();
}

pub inline fn rebuildDirectoryMatches(self: *PaletteState) !void {
    try self.rebuildDirectoryMatches();
}

pub inline fn rebuildFileMatches(self: *PaletteState, image_list: []const []const u8) !void {
    try self.rebuildFileMatches(image_list);
}
