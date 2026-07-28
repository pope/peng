const std = @import("std");
const fuzzig = @import("fuzzig");
const commands = @import("../commands/actions.zig");
const fs = @import("fs.zig");

pub const TextInputBounds = struct {
    min: f32,
    max: f32,
};

pub const PaletteMode = enum {
    inactive,
    files,
    actions,
    set_brightness,
    set_contrast,
    go_to_image,
    directory_navigator,
    set_slideshow_interval,

    pub fn isTextInputDialog(self: PaletteMode) bool {
        return switch (self) {
            .set_brightness, .set_contrast, .go_to_image, .set_slideshow_interval => true,
            .inactive, .files, .actions, .directory_navigator => false,
        };
    }

    pub fn getTextInputBounds(self: PaletteMode) ?TextInputBounds {
        return switch (self) {
            .set_brightness => .{ .min = -1.0, .max = 1.0 },
            .set_contrast => .{ .min = 0.0, .max = 5.0 },
            .set_slideshow_interval => .{ .min = 0.1, .max = 3600.0 },
            .go_to_image, .inactive, .files, .actions, .directory_navigator => null,
        };
    }
};

pub const ScoredMatch = struct {
    index: usize,
    score: i32,
};

pub const PaletteModeData = union(enum) {
    inactive,
    files: struct {
        matches: []const usize,
    },
    actions: struct {
        scored_matches: []const ScoredMatch,
    },
    directory_navigator: struct {
        current_dir: []const u8,
        dir_items: []const fs.DirectoryEntry,
    },
    text_input: struct {
        bounds: ?TextInputBounds,
    },
};

pub const PaletteState = struct {
    mode: PaletteMode = .inactive,
    query: std.ArrayList(u8),
    selected_idx: usize = 0,
    selection_dirty: bool = false,
    matches: std.ArrayList(usize),
    scored_matches: std.ArrayList(ScoredMatch),
    current_nav_dir: std.ArrayList(u8),
    last_nav_dir: std.ArrayList(u8),
    last_child_dir: std.ArrayList(u8),
    dir_items: std.ArrayList(fs.DirectoryEntry),
    current_dir_image_count: usize = 0,
    allocator: std.mem.Allocator,
    searcher: ?fuzzig.Ascii = null,
    max_haystack_len: usize = 64,

    pub fn getModeData(self: *const PaletteState) PaletteModeData {
        return switch (self.mode) {
            .inactive => .inactive,
            .files => .{ .files = .{ .matches = self.matches.items } },
            .actions => .{ .actions = .{ .scored_matches = self.scored_matches.items } },
            .directory_navigator => .{
                .directory_navigator = .{
                    .current_dir = self.current_nav_dir.items,
                    .dir_items = self.dir_items.items,
                },
            },
            .set_brightness, .set_contrast, .go_to_image, .set_slideshow_interval => .{
                .text_input = .{
                    .bounds = self.mode.getTextInputBounds(),
                },
            },
        };
    }

    pub fn init(allocator: std.mem.Allocator) PaletteState {
        return .{
            .query = .empty,
            .matches = .empty,
            .scored_matches = .empty,
            .current_nav_dir = .empty,
            .last_nav_dir = .empty,
            .last_child_dir = .empty,
            .dir_items = .empty,
            .current_dir_image_count = 0,
            .allocator = allocator,
            .searcher = null,
            .max_haystack_len = 64,
        };
    }

    pub fn deinit(self: *PaletteState) void {
        if (self.searcher) |*s| {
            s.deinit();
        }
        self.query.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.scored_matches.deinit(self.allocator);
        self.current_nav_dir.deinit(self.allocator);
        self.last_nav_dir.deinit(self.allocator);
        self.last_child_dir.deinit(self.allocator);
        self.clearDirItems();
        self.dir_items.deinit(self.allocator);
    }

    fn clearDirItems(self: *PaletteState) void {
        for (self.dir_items.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.full_path);
        }
        self.dir_items.clearRetainingCapacity();
    }

    pub fn reset(self: *PaletteState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        self.current_nav_dir.clearRetainingCapacity();
        self.last_child_dir.clearRetainingCapacity();
        self.clearDirItems();
        self.mode = .inactive;
        self.selected_idx = 0;
        self.selection_dirty = true;
    }

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

        self.clearDirItems();
        fs.scanDirectoryEntries(self.allocator, io, dir_path_copy, &self.dir_items) catch |err| {
            std.log.warn("Failed to scan directory '{s}': {}", .{ dir_path_copy, err });
        };
        try self.rebuildDirectoryMatches();
        self.selection_dirty = true;
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

    pub fn getSearcher(self: *PaletteState, max_haystack: usize, max_needle: usize) !*fuzzig.Ascii {
        const req_haystack = @max(max_haystack, 64);
        const req_needle = @max(max_needle, 16);
        if (self.searcher) |*s| {
            if (!s.hasSize(req_haystack, req_needle)) {
                const new_h = @max(s.alg.max_haystack * 2, req_haystack);
                const new_n = @max(s.alg.max_needle * 2, req_needle);
                try s.resize(new_h, new_n);
            }
            return s;
        } else {
            self.searcher = try fuzzig.Ascii.init(self.allocator, req_haystack, req_needle, .{
                .case_sensitive = false,
            });
            return &self.searcher.?;
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

    pub fn rebuildActionMatches(self: *PaletteState, app_actions: []const commands.AppActionId) !void {
        self.matches.clearRetainingCapacity();
        const query_str = self.query.items;
        if (query_str.len == 0) {
            for (app_actions, 0..) |_, idx| {
                try self.matches.append(self.allocator, idx);
            }
            return;
        }

        var max_h: usize = 0;
        for (app_actions) |action_id| {
            const meta = commands.getActionMetadata(action_id);
            max_h = @max(max_h, meta.name.len);
        }

        const searcher_ptr = try self.getSearcher(max_h, query_str.len);

        self.scored_matches.clearRetainingCapacity();

        for (app_actions, 0..) |action_id, idx| {
            const meta = commands.getActionMetadata(action_id);
            if (searcher_ptr.score(meta.name, query_str)) |score| {
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
};

test "PaletteState.rebuildActionMatches fuzzy search" {
    var palette = PaletteState.init(std.testing.allocator);
    defer palette.deinit();

    try palette.query.appendSlice(std.testing.allocator, "zin");
    try palette.rebuildActionMatches(commands.app_actions);

    try std.testing.expect(palette.matches.items.len > 0);
    const top_action_id = commands.app_actions[palette.matches.items[0]];
    const top_meta = commands.getActionMetadata(top_action_id);
    try std.testing.expectEqualStrings("Zoom In", top_meta.name);
}

test "PaletteState.rebuildFileMatches fuzzy search" {
    var palette = PaletteState.init(std.testing.allocator);
    defer palette.deinit();

    const image_list = [_][]const u8{
        "/photos/sunset_beach.jpg",
        "/photos/mountain_hike.png",
        "/photos/cat_photo.jpg",
    };

    try palette.query.appendSlice(std.testing.allocator, "sntbch");
    try palette.rebuildFileMatches(&image_list);

    try std.testing.expectEqual(@as(usize, 1), palette.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), palette.matches.items[0]);
}

test "PaletteState scoreMatches character indices and partitioning" {
    var palette = PaletteState.init(std.testing.allocator);
    defer palette.deinit();

    const searcher = try palette.getSearcher(64, 16);

    // Test action name match indices
    const action_name = "Zoom In";
    const action_res = searcher.scoreMatches(action_name, "zin");
    try std.testing.expect(action_res.score != null);
    try std.testing.expect(action_res.matches.len > 0);

    // Test file path match partitioning
    const item_path = "/photos/sunset_beach.jpg";
    const basename = std.fs.path.basename(item_path);
    const dirname = std.fs.path.dirname(item_path) orelse ".";
    const basename_offset = item_path.len - basename.len;

    const full_res = searcher.scoreMatches(item_path, "photos/beach");
    try std.testing.expect(full_res.score != null);

    var b_matches: std.ArrayList(usize) = .empty;
    defer b_matches.deinit(std.testing.allocator);
    var d_matches: std.ArrayList(usize) = .empty;
    defer d_matches.deinit(std.testing.allocator);

    for (full_res.matches) |m_idx| {
        if (m_idx >= basename_offset) {
            const b_idx = m_idx - basename_offset;
            if (b_idx < basename.len) {
                try b_matches.append(std.testing.allocator, b_idx);
            }
        } else if (m_idx < dirname.len) {
            try d_matches.append(std.testing.allocator, m_idx);
        }
    }

    try std.testing.expect(d_matches.items.len > 0);
    try std.testing.expect(b_matches.items.len > 0);
}

test "PaletteState.loadDirectoryEntries" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_nav_test";
    std.Io.Dir.createDirPath(cwd, io, tmp_dir ++ "/folder1") catch {};
    std.Io.Dir.createDirPath(cwd, io, tmp_dir ++ "/folder2") catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var palette = PaletteState.init(allocator);
    defer palette.deinit();

    try palette.loadDirectoryEntries(io, tmp_dir);

    try std.testing.expectEqualStrings(tmp_dir, palette.current_nav_dir.items);
    try std.testing.expect(palette.dir_items.items.len >= 2);
    try std.testing.expectEqual(palette.dir_items.items.len, palette.matches.items.len);
}

test "PaletteState.rebuildDirectoryMatches" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_rebuild_test";
    std.Io.Dir.createDirPath(cwd, io, tmp_dir ++ "/sub_alpha") catch {};
    std.Io.Dir.createDirPath(cwd, io, tmp_dir ++ "/sub_beta") catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var palette = PaletteState.init(allocator);
    defer palette.deinit();

    try palette.loadDirectoryEntries(io, tmp_dir);

    // Empty query matches all entries
    try std.testing.expectEqual(palette.dir_items.items.len, palette.matches.items.len);

    // Query "alpha" should match sub_alpha as top match
    try palette.query.appendSlice(allocator, "alpha");
    try palette.rebuildDirectoryMatches();

    try std.testing.expect(palette.matches.items.len > 0);
    const top_idx = palette.matches.items[0];
    try std.testing.expectEqualStrings("sub_alpha", palette.dir_items.items[top_idx].name);

    // Reset query and test "beta"
    palette.query.clearRetainingCapacity();
    try palette.query.appendSlice(allocator, "beta");
    try palette.rebuildDirectoryMatches();

    try std.testing.expect(palette.matches.items.len > 0);
    const top_beta_idx = palette.matches.items[0];
    try std.testing.expectEqualStrings("sub_beta", palette.dir_items.items[top_beta_idx].name);

    // Reset palette to verify reset clears directory state properly
    palette.reset();
    try std.testing.expectEqual(@as(usize, 0), palette.current_nav_dir.items.len);
    try std.testing.expectEqual(@as(usize, 0), palette.dir_items.items.len);
}

test "PaletteState.navigating_up_remembers_previous_folder" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_nav_up_test";
    const sub_dir = tmp_dir ++ "/child_folder";
    std.Io.Dir.createDirPath(cwd, io, sub_dir) catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var palette = PaletteState.init(allocator);
    defer palette.deinit();

    // 1. Load root tmp_dir
    try palette.loadDirectoryEntries(io, tmp_dir);
    try std.testing.expectEqualStrings("", palette.last_child_dir.items);
    try std.testing.expectEqual(@as(usize, 0), palette.selected_idx);

    // 2. Navigate down into child_folder
    try palette.loadDirectoryEntries(io, sub_dir);
    try std.testing.expectEqualStrings("", palette.last_child_dir.items);
    try std.testing.expectEqual(@as(usize, 0), palette.selected_idx);

    // 3. Navigate up back to tmp_dir
    try palette.loadDirectoryEntries(io, tmp_dir);
    try std.testing.expectEqualStrings("child_folder", palette.last_child_dir.items);

    // Find the index of child_folder in dir_items
    var expected_idx: usize = 0;
    for (palette.dir_items.items, 0..) |item, i| {
        if (std.mem.eql(u8, item.name, "child_folder")) {
            expected_idx = i;
            break;
        }
    }
    try std.testing.expectEqual(expected_idx, palette.selected_idx);
}

test "PaletteMode.getTextInputBounds" {
    const brightness_bounds = PaletteMode.set_brightness.getTextInputBounds().?;
    try std.testing.expectEqual(@as(f32, -1.0), brightness_bounds.min);
    try std.testing.expectEqual(@as(f32, 1.0), brightness_bounds.max);

    const contrast_bounds = PaletteMode.set_contrast.getTextInputBounds().?;
    try std.testing.expectEqual(@as(f32, 0.0), contrast_bounds.min);
    try std.testing.expectEqual(@as(f32, 5.0), contrast_bounds.max);

    try std.testing.expect(PaletteMode.files.getTextInputBounds() == null);
}

test "PaletteState.getModeData" {
    var palette = PaletteState.init(std.testing.allocator);
    defer palette.deinit();

    try std.testing.expect(palette.getModeData() == .inactive);

    palette.mode = .files;
    switch (palette.getModeData()) {
        .files => |f| try std.testing.expectEqual(@as(usize, 0), f.matches.len),
        else => @panic("expected .files mode data"),
    }

    palette.mode = .set_brightness;
    switch (palette.getModeData()) {
        .text_input => |t| {
            const bounds = t.bounds.?;
            try std.testing.expectEqual(@as(f32, -1.0), bounds.min);
            try std.testing.expectEqual(@as(f32, 1.0), bounds.max);
        },
        else => @panic("expected .text_input mode data"),
    }
}
