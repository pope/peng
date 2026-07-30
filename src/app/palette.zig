const std = @import("std");
const state_pkg = @import("state");
const fs = @import("fs.zig");

const PaletteState = state_pkg.PaletteState;
const PaletteModeData = state_pkg.PaletteModeData;
const ScoredMatch = state_pkg.ScoredMatch;
const DirectoryEntry = state_pkg.DirectoryEntry;
const DirectoryEntryType = state_pkg.DirectoryEntryType;

pub fn loadDirectoryEntries(self: *PaletteState, io: std.Io, dir_path: []const u8) !void {
    const dir_path_copy = try self.allocator.dupe(u8, std.mem.trimEnd(u8, dir_path, "/\\"));
    defer self.allocator.free(dir_path_copy);

    var navigated_up = false;
    if (self.current_nav_dir.items.len > 0) {
        var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (fs.getParentDirBuf(self.current_nav_dir.items, &parent_buf)) |parent_dir| {
            if (std.mem.eql(u8, dir_path_copy, parent_dir)) {
                navigated_up = true;
            }
        }
    }

    if (navigated_up) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const child_base = fs.getChildBasename(io, self.current_nav_dir.items, &buf);
        self.last_child_dir.clearRetainingCapacity();
        try self.last_child_dir.appendSlice(self.allocator, child_base);
    } else {
        self.last_child_dir.clearRetainingCapacity();
    }

    self.current_nav_dir.clearRetainingCapacity();
    try self.current_nav_dir.appendSlice(self.allocator, dir_path_copy);

    self.last_nav_dir.clearRetainingCapacity();
    try self.last_nav_dir.appendSlice(self.allocator, dir_path_copy);

    self.current_dir_image_count = fs.countFolderImages(io, dir_path_copy);

    clearDirItems(self);
    fs.scanDirectoryEntries(self.allocator, io, dir_path_copy, &self.dir_items) catch |err| {
        std.log.warn("Failed to scan directory '{s}': {}", .{ dir_path_copy, err });
    };
    try rebuildDirectoryMatches(self);
    self.selection_dirty = true;
}

fn clearDirItems(self: *PaletteState) void {
    for (self.dir_items.items) |entry| {
        self.allocator.free(entry.name);
        if (entry.full_path.len > 0) self.allocator.free(entry.full_path);
    }
    self.dir_items.clearRetainingCapacity();
}

pub fn rebuildDirectoryMatches(self: *PaletteState) !void {
    self.matches.clearRetainingCapacity();
    self.scored_matches.clearRetainingCapacity();
    self.selected_idx = 0;
    const query_str = self.query.items;

    if (query_str.len == 0) {
        for (self.dir_items.items, 0..) |_, idx| {
            try self.matches.append(self.allocator, idx);
        }
        if (self.last_child_dir.items.len > 0) {
            for (self.dir_items.items, 0..) |entry, match_idx| {
                if (std.mem.eql(u8, entry.name, self.last_child_dir.items)) {
                    self.selected_idx = match_idx;
                    break;
                }
            }
        }
        return;
    }

    var max_h: usize = self.max_haystack_len;
    for (self.dir_items.items) |entry| {
        max_h = @max(max_h, entry.name.len);
    }
    self.max_haystack_len = max_h;

    const searcher_ptr = try self.getSearcher(max_h, query_str.len);

    for (self.dir_items.items, 0..) |entry, idx| {
        if (searcher_ptr.score(entry.name, query_str)) |score| {
            try self.scored_matches.append(self.allocator, .{ .index = idx, .score = score });
        }
    }

    std.mem.sort(ScoredMatch, self.scored_matches.items, {}, struct {
        fn lessThan(_: void, a: ScoredMatch, b: ScoredMatch) bool {
            return a.score > b.score;
        }
    }.lessThan);

    for (self.scored_matches.items) |item| {
        try self.matches.append(self.allocator, item.index);
    }
}

pub fn rebuildFileMatches(self: *PaletteState, image_list: []const []const u8) !void {
    self.matches.clearRetainingCapacity();
    const query_str = self.query.items;
    if (query_str.len == 0) {
        for (image_list, 0..) |_, real_idx| {
            try self.matches.append(self.allocator, real_idx);
        }
        return;
    }

    var max_h: usize = self.max_haystack_len;
    for (image_list) |item_path| {
        const basename = std.fs.path.basename(item_path);
        max_h = @max(max_h, basename.len);
        max_h = @max(max_h, item_path.len);
    }
    self.max_haystack_len = max_h;

    const searcher_ptr = try self.getSearcher(max_h, query_str.len);

    self.scored_matches.clearRetainingCapacity();

    const has_slash = std.mem.indexOfScalar(u8, query_str, '/') != null or std.mem.indexOfScalar(u8, query_str, '\\') != null;

    for (image_list, 0..) |item_path, real_idx| {
        const basename = std.fs.path.basename(item_path);
        var best_score: ?i32 = null;

        if (searcher_ptr.score(basename, query_str)) |s| {
            best_score = s;
        }

        if (has_slash or best_score == null) {
            if (searcher_ptr.score(item_path, query_str)) |s| {
                best_score = if (best_score) |prev| @max(prev, s) else s;
            }
        }

        if (best_score) |score| {
            try self.scored_matches.append(self.allocator, .{ .index = real_idx, .score = score });
        }
    }

    std.mem.sort(ScoredMatch, self.scored_matches.items, {}, struct {
        fn lessThan(_: void, a: ScoredMatch, b: ScoredMatch) bool {
            return a.score > b.score;
        }
    }.lessThan);

    for (self.scored_matches.items) |item| {
        try self.matches.append(self.allocator, item.index);
    }
}
