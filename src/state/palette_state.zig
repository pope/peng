const std = @import("std");
const fuzzig = @import("fuzzig");
const intents = @import("intents");
const types = @import("types.zig");

pub const TextInputBounds = intents.TextInputBounds;
pub const PaletteMode = intents.PaletteMode;

pub const ScoredMatch = struct {
    index: usize,
    score: i32,
};

pub const FolderScanState = union(enum) {
    unscanned,
    permission_denied,
    scanned: struct {
        image_count: usize = 0,
        subdir_count: usize = 0,
    },
};

pub const DirectoryEntry = union(enum) {
    parent: struct {
        name: []const u8,
        full_path: []const u8 = "",
    },
    directory: struct {
        name: []const u8,
        full_path: []const u8 = "",
        scan: FolderScanState = .unscanned,
    },
    image_file: struct {
        name: []const u8,
        full_path: []const u8 = "",
    },

    pub fn getName(self: DirectoryEntry) []const u8 {
        return switch (self) {
            .parent => |p| p.name,
            .directory => |d| d.name,
            .image_file => |f| f.name,
        };
    }

    pub fn getFullPath(self: DirectoryEntry) []const u8 {
        return switch (self) {
            .parent => |p| p.full_path,
            .directory => |d| d.full_path,
            .image_file => |f| f.full_path,
        };
    }

    pub fn isDirectory(self: DirectoryEntry) bool {
        return self == .directory or self == .parent;
    }

    pub fn getImageCount(self: DirectoryEntry) ?usize {
        return switch (self) {
            .directory => |d| switch (d.scan) {
                .scanned => |s| s.image_count,
                else => null,
            },
            else => null,
        };
    }

    pub fn getSubdirCount(self: DirectoryEntry) ?usize {
        return switch (self) {
            .directory => |d| switch (d.scan) {
                .scanned => |s| s.subdir_count,
                else => null,
            },
            else => null,
        };
    }
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
        dir_items: []const DirectoryEntry,
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
    dir_items: std.ArrayList(DirectoryEntry),
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

    pub fn clearDirItems(self: *PaletteState) void {
        for (self.dir_items.items) |entry| {
            self.allocator.free(entry.getName());
            if (entry.getFullPath().len > 0) self.allocator.free(entry.getFullPath());
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

    pub fn rebuildActionMatches(self: *PaletteState) !void {
        self.matches.clearRetainingCapacity();
        const query_str = self.query.items;
        if (query_str.len == 0) {
            for (types.palette_action_items, 0..) |_, idx| {
                try self.matches.append(self.allocator, idx);
            }
            return;
        }

        var max_h: usize = 0;
        for (types.palette_action_items) |item| {
            max_h = @max(max_h, item.name.len);
        }

        const searcher_ptr = try self.getSearcher(max_h, query_str.len);

        self.scored_matches.clearRetainingCapacity();

        for (types.palette_action_items, 0..) |item, idx| {
            if (searcher_ptr.score(item.name, query_str)) |score| {
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
                    if (std.mem.eql(u8, entry.getName(), self.last_child_dir.items)) {
                        self.selected_idx = match_idx;
                        break;
                    }
                }
            }
            return;
        }

        var max_h: usize = self.max_haystack_len;
        for (self.dir_items.items) |entry| {
            max_h = @max(max_h, entry.getName().len);
        }
        self.max_haystack_len = max_h;

        const searcher_ptr = try self.getSearcher(max_h, query_str.len);

        for (self.dir_items.items, 0..) |entry, idx| {
            if (searcher_ptr.score(entry.getName(), query_str)) |score| {
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
};
