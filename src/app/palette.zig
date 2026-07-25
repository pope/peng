const std = @import("std");
const fuzzig = @import("fuzzig");
const commands = @import("../commands/actions.zig");

pub const PaletteMode = enum {
    inactive,
    files,
    actions,
    set_brightness,
    set_contrast,
    go_to_image,
};

pub const ScoredMatch = struct {
    index: usize,
    score: i32,
};

pub const PaletteState = struct {
    mode: PaletteMode = .inactive,
    query: std.ArrayList(u8),
    selected_idx: usize = 0,
    selection_dirty: bool = false,
    matches: std.ArrayList(usize),
    scored_matches: std.ArrayList(ScoredMatch),
    allocator: std.mem.Allocator,
    searcher: ?fuzzig.Ascii = null,
    max_haystack_len: usize = 64,

    pub fn init(allocator: std.mem.Allocator) PaletteState {
        return .{
            .query = std.ArrayList(u8).empty,
            .matches = std.ArrayList(usize).empty,
            .scored_matches = std.ArrayList(ScoredMatch).empty,
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
    }

    pub fn reset(self: *PaletteState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        self.mode = .inactive;
        self.selected_idx = 0;
        self.selection_dirty = true;
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

    var b_matches = std.ArrayList(usize).empty;
    defer b_matches.deinit(std.testing.allocator);
    var d_matches = std.ArrayList(usize).empty;
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
