//! Palette Module
//!
//! Encapsulates command palette state, fuzzy match scoring via `fuzzig`,
//! readline text editing, and directory navigation history.
//! Zero SDL, zero Clay, and zero C dependencies.

const builtin = @import("builtin");
const fuzzig = @import("fuzzig");
const intents = @import("intents");
const std = @import("std");
const vfs = @import("vfs");

const DirectoryEntry = vfs.DirectoryEntry;
const EditParam = intents.EditParam;
const getChildBasename = vfs.getChildBasename;
const getParentDirBuf = vfs.getParentDirBuf;
const isCbzFile = vfs.isCbzFile;
const MediaEntry = vfs.MediaEntry;
const palette_action_items = intents.actions.palette_action_items;
const PaletteMode = intents.PaletteMode;
const scanDirectoryEntries = vfs.scanDirectoryEntries;
const trimTrailingSeparators = vfs.trimTrailingSeparators;

/// Represents a search result item paired with its fuzzy matching score.
pub const ScoredMatch = struct {
    index: usize,
    score: i32,
};

/// Main state model for command palette modals, directory navigation, and fuzzy
/// searching.
pub const PaletteState = struct {
    mode: PaletteMode = .inactive,
    is_closing: bool = false,
    query: std.ArrayList(u8) = .empty,
    selected_idx: usize = 0,
    matches: std.ArrayList(usize) = .empty,
    scored_matches: std.ArrayList(ScoredMatch) = .empty,
    selection_dirty: bool = false,
    current_nav_dir: std.ArrayList(u8) = .empty,
    last_nav_dir: std.ArrayList(u8) = .empty,
    last_child_dir: std.ArrayList(u8) = .empty,
    dir_items: std.ArrayList(DirectoryEntry) = .empty,
    current_dir_image_count: usize = 0,
    dir_scan_generation: std.atomic.Value(usize) = .init(0),
    allocator: std.mem.Allocator,
    searcher: ?fuzzig.Ascii = null,
    max_haystack_len: usize = 64,

    /// Initializes a new `PaletteState` instance, reserving initial
    /// capacities for queries, matches, and paths.
    pub fn init(allocator: std.mem.Allocator) !PaletteState {
        var self = PaletteState{
            .query = .empty,
            .matches = .empty,
            .scored_matches = .empty,
            .current_nav_dir = .empty,
            .last_nav_dir = .empty,
            .last_child_dir = .empty,
            .dir_items = .empty,
            .current_dir_image_count = 0,
            .dir_scan_generation = .init(0),
            .allocator = allocator,
            .searcher = null,
            .max_haystack_len = 64,
        };
        errdefer self.deinit();
        // 64 bytes: accommodates user search query input strings
        // (typical search queries are < 64 chars)
        try self.query.ensureTotalCapacity(allocator, 64);
        // 64 items: initial filtered match index capacity before dynamic
        // resizing
        try self.matches.ensureTotalCapacity(allocator, 64);
        // 64 items: initial fuzzy search score entry capacity
        try self.scored_matches.ensureTotalCapacity(allocator, 64);
        // 128 bytes: accommodates active directory path strings (most paths
        // are < 128 bytes)
        try self.current_nav_dir.ensureTotalCapacity(allocator, 128);
        // 128 bytes: accommodates last visited directory path strings
        try self.last_nav_dir.ensureTotalCapacity(allocator, 128);
        // 64 bytes: accommodates directory basename strings
        try self.last_child_dir.ensureTotalCapacity(allocator, 64);
        // 64 items: initial directory item entry capacity before directory scan
        try self.dir_items.ensureTotalCapacity(allocator, 64);
        return self;
    }

    /// Returns `true` if the palette is open in any active mode.
    pub inline fn isOpen(self: *const PaletteState) bool {
        return self.mode != .inactive;
    }

    /// Frees all dynamically allocated memory, string arrays, searcher state,
    /// and directory items.
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

    /// Releases heap strings owned by directory items and clears the list while
    /// retaining capacity.
    pub fn clearDirItems(self: *PaletteState) void {
        for (self.dir_items.items) |entry| {
            self.allocator.free(entry.getName());
            if (entry.getFullPath().len > 0) {
                self.allocator.free(entry.getFullPath());
            }
        }
        self.dir_items.clearRetainingCapacity();
    }

    /// Clears search query, matched indexes, navigation directory, and
    /// restores palette to inactive mode.
    pub fn reset(self: *PaletteState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        self.current_nav_dir.clearRetainingCapacity();
        self.last_child_dir.clearRetainingCapacity();
        self.clearDirItems();
        _ = self.dir_scan_generation.fetchAdd(1, .release);
        self.mode = .inactive;
        self.is_closing = false;
        self.selected_idx = 0;
        self.selection_dirty = true;
    }

    /// Trims oversized backing arrays and fuzzy searcher allocations back to
    /// their warm initial footprint when hiding the window in server mode.
    pub fn shrinkToWarmCapacity(self: *PaletteState) void {
        if (self.matches.capacity > 64) {
            self.matches.clearAndFree(self.allocator);
        }
        if (self.scored_matches.capacity > 64) {
            self.scored_matches.clearAndFree(self.allocator);
        }
        if (self.dir_items.capacity > 64) {
            self.clearDirItems();
            self.dir_items.clearAndFree(self.allocator);
        }
        if (self.searcher) |*s| {
            if (s.alg.max_haystack > 64) {
                s.deinit();
                self.searcher = null;
                self.max_haystack_len = 64;
            }
        }
    }

    /// Returns whether the palette is currently active and accepting user
    /// input (not closing).
    pub inline fn isAcceptingInput(self: *const PaletteState) bool {
        return self.mode != .inactive and !self.is_closing;
    }

    /// Returns a lazily initialized or resized ASCII fuzzy searcher matching
    /// the requested haystack and needle lengths.
    fn getSearcher(
        self: *PaletteState,
        max_haystack: usize,
        max_needle: usize,
    ) !*fuzzig.Ascii {
        const req_haystack = @max(max_haystack, 64);
        const req_needle = @max(max_needle, 16);
        if (self.searcher) |*s| {
            if (!s.hasSize(req_haystack, req_needle)) {
                const new_h = if (req_haystack > s.alg.max_haystack)
                    @max(s.alg.max_haystack * 2, req_haystack)
                else
                    s.alg.max_haystack;
                const new_n = if (req_needle > s.alg.max_needle)
                    @max(s.alg.max_needle * 2, req_needle)
                else
                    s.alg.max_needle;
                try s.resize(new_h, new_n);
            }
            return s;
        } else {
            self.searcher = try fuzzig.Ascii.init(
                self.allocator,
                req_haystack,
                req_needle,
                .{ .case_sensitive = false },
            );
            return &self.searcher.?;
        }
    }

    /// Sorts `scored_matches` by score descending and extracts matching
    /// candidate indices into `matches`.
    fn sortAndExtractMatches(self: *PaletteState) !void {
        std.mem.sort(ScoredMatch, self.scored_matches.items, {}, struct {
            fn lessThan(_: void, a: ScoredMatch, b: ScoredMatch) bool {
                return a.score > b.score;
            }
        }.lessThan);

        try self.matches.ensureTotalCapacity(
            self.allocator,
            self.scored_matches.items.len,
        );
        for (self.scored_matches.items) |item| {
            self.matches.appendAssumeCapacity(item.index);
        }
    }

    /// Rebuilds fuzzy match results for action palette items.
    ///
    /// Optimizations:
    /// - Short-circuits when query is empty, populating `matches` directly
    ///   without searcher allocation or fuzzy scoring.
    /// - Pre-allocates `scored_matches` and `matches` capacities to allow
    ///   `appendAssumeCapacity` writes during scoring.
    pub fn rebuildActionMatches(self: *PaletteState) !void {
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        const query_str = self.query.items;
        if (query_str.len == 0) {
            try self.matches.ensureTotalCapacity(
                self.allocator,
                palette_action_items.len,
            );
            for (palette_action_items, 0..) |_, idx| {
                self.matches.appendAssumeCapacity(idx);
            }
            return;
        }

        var max_h: usize = 0;
        for (palette_action_items) |item| {
            max_h = @max(max_h, item.name.len);
        }

        const searcher_ptr = try self.getSearcher(max_h, query_str.len);

        try self.scored_matches.ensureTotalCapacity(
            self.allocator,
            palette_action_items.len,
        );

        for (palette_action_items, 0..) |item, idx| {
            if (searcher_ptr.score(item.name, query_str)) |score| {
                self.scored_matches.appendAssumeCapacity(
                    .{ .index = idx, .score = score },
                );
            }
        }

        try self.sortAndExtractMatches();
    }

    /// Rebuilds fuzzy match results for directory navigator items.
    ///
    /// Optimizations:
    /// - Short-circuits when query is empty, populating `matches` directly
    ///   without searcher allocation or fuzzy scoring.
    /// - Pre-allocates `scored_matches` and `matches` capacities to allow
    ///   `appendAssumeCapacity` writes during scoring.
    pub fn rebuildDirectoryMatches(self: *PaletteState) !void {
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        self.selected_idx = 0;
        const query_str = self.query.items;

        if (query_str.len == 0) {
            try self.matches.ensureTotalCapacity(
                self.allocator,
                self.dir_items.items.len,
            );
            for (self.dir_items.items, 0..) |_, idx| {
                self.matches.appendAssumeCapacity(idx);
            }
            if (self.last_child_dir.items.len > 0) {
                for (self.dir_items.items, 0..) |entry, match_idx| {
                    if (std.mem.eql(
                        u8,
                        entry.getName(),
                        self.last_child_dir.items,
                    )) {
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

        try self.scored_matches.ensureTotalCapacity(
            self.allocator,
            self.dir_items.items.len,
        );

        for (self.dir_items.items, 0..) |entry, idx| {
            if (searcher_ptr.score(entry.getName(), query_str)) |score| {
                self.scored_matches.appendAssumeCapacity(
                    .{ .index = idx, .score = score },
                );
            }
        }

        try self.sortAndExtractMatches();
    }

    /// Rebuilds fuzzy match results for image file list items.
    ///
    /// Optimizations:
    /// - Short-circuits when query is empty, populating `matches` directly
    ///   without searcher allocation or fuzzy scoring.
    /// - Pre-allocates `scored_matches` and `matches` capacities to allow
    ///   `appendAssumeCapacity` writes during scoring.
    pub fn rebuildFileMatches(
        self: *PaletteState,
        image_list: []const MediaEntry,
    ) !void {
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        const query_str = self.query.items;
        if (query_str.len == 0) {
            try self.matches.ensureTotalCapacity(
                self.allocator,
                image_list.len,
            );
            for (image_list, 0..) |_, real_idx| {
                self.matches.appendAssumeCapacity(real_idx);
            }
            return;
        }

        var max_h: usize = self.max_haystack_len;
        for (image_list) |item| {
            const basename = item.getBasename();
            max_h = @max(max_h, basename.len);
            if (item.getJpegPath()) |jpeg_p| {
                const jpeg_base = std.Io.Dir.path.basename(jpeg_p);
                max_h = @max(max_h, jpeg_base.len);
            }
        }
        max_h = @max(max_h, "RAW+JPG".len);
        self.max_haystack_len = max_h;

        const searcher_ptr = try self.getSearcher(max_h, query_str.len);

        try self.scored_matches.ensureTotalCapacity(
            self.allocator,
            image_list.len,
        );

        for (image_list, 0..) |item, real_idx| {
            const basename = item.getBasename();
            var best_score = searcher_ptr.score(basename, query_str);
            if (item.getJpegPath()) |jpeg_p| {
                const jpeg_base = std.Io.Dir.path.basename(jpeg_p);
                if (searcher_ptr.score(jpeg_base, query_str)) |jpeg_score| {
                    if (best_score) |s| {
                        best_score = @max(s, jpeg_score);
                    } else {
                        best_score = jpeg_score;
                    }
                }
            }
            if (item.isPair()) {
                if (searcher_ptr.score("RAW+JPG", query_str)) |tag_score| {
                    if (best_score) |s| {
                        best_score = @max(s, tag_score);
                    } else {
                        best_score = tag_score;
                    }
                }
            }
            if (best_score) |score| {
                self.scored_matches.appendAssumeCapacity(.{
                    .index = real_idx,
                    .score = score,
                });
            }
        }

        try self.sortAndExtractMatches();
    }

    /// Populates directory entries for `dir_path` into `PaletteState`, tracks
    /// directory navigation history (including last-child directory tracking
    /// for upward navigation), increments scan generation, and rebuilds fuzzy
    /// directory matches.
    pub fn loadDirectoryEntries(
        self: *PaletteState,
        io: std.Io,
        dir_path: []const u8,
    ) !void {
        const raw_target = trimTrailingSeparators(dir_path);
        const target = if (isCbzFile(raw_target))
            (std.Io.Dir.path.dirname(raw_target) orelse ".")
        else
            raw_target;

        var stack_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var fb: std.heap.BufferFirstAllocator = .init(
            &stack_buf,
            self.allocator,
        );
        const temp_alloc = fb.allocator();
        const dir_path_copy = try temp_alloc.dupe(u8, target);
        defer temp_alloc.free(dir_path_copy);

        var path_scratch_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

        var navigated_up = false;
        if (self.current_nav_dir.items.len > 0) {
            if (getParentDirBuf(
                self.current_nav_dir.items,
                &path_scratch_buf,
            )) |parent_dir| {
                if (std.mem.eql(u8, dir_path_copy, parent_dir)) {
                    navigated_up = true;
                }
            }
        }

        if (navigated_up) {
            const child_base = getChildBasename(
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
        self.current_dir_image_count = scanDirectoryEntries(
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

    /// Computes the maximum string length across visible item candidates in the
    /// active viewport window for allocating or sizing a fuzzy searcher.
    pub fn computeWindowMaxHaystack(
        self: *const PaletteState,
        entries: []const MediaEntry,
        visible_indices: []const usize,
    ) usize {
        var max_h: usize = 64;
        for (visible_indices) |real_idx| {
            switch (self.mode) {
                .files => {
                    if (real_idx < entries.len) {
                        const m = entries[real_idx];
                        max_h = @max(max_h, m.getBasename().len);
                        if (m.getJpegPath()) |jp| {
                            max_h = @max(
                                max_h,
                                std.Io.Dir.path.basename(jp).len,
                            );
                        }
                        if (m.isPair()) {
                            max_h = @max(max_h, "RAW+JPG".len);
                        }
                    }
                },
                .actions => {
                    if (real_idx < palette_action_items.len) {
                        max_h = @max(
                            max_h,
                            palette_action_items[real_idx].name.len,
                        );
                    }
                },
                .directory_navigator => {
                    if (real_idx < self.dir_items.items.len) {
                        max_h = @max(
                            max_h,
                            self.dir_items.items[real_idx].getName().len,
                        );
                    }
                },
                .set_brightness,
                .set_contrast,
                .set_contrast_blend,
                .set_highlights,
                .set_shadows,
                .set_whites,
                .set_blacks,
                .set_temperature,
                .set_tint,
                .set_vibrance,
                .set_saturation,
                .set_clarity,
                .set_texture,
                .go_to_image,
                .set_slideshow_interval,
                .inactive,
                => {},
            }
        }
        return max_h;
    }

    /// Returns a windowed fuzzy highlighter configured for the current search
    /// query and visible item candidates.
    pub fn initWindowHighlighter(
        self: *const PaletteState,
        allocator: std.mem.Allocator,
        entries: []const MediaEntry,
        visible_indices: []const usize,
    ) FuzzyHighlighter {
        if (self.query.items.len > 0 and visible_indices.len > 0) {
            return .init(
                allocator,
                self.computeWindowMaxHaystack(entries, visible_indices),
                self.query.items.len,
            );
        }
        return .{};
    }
};

/// Height in logical UI points of the scrollable item list viewport inside the
/// command palette modal.
pub const PALETTE_VIEWPORT_HEIGHT_LOGICAL: f32 = 320.0;

/// Configuration metadata for palette modals (titles, placeholders,
/// element IDs, spacer IDs, logical item and viewport heights).
pub const PaletteConfig = struct {
    title: []const u8,
    placeholder: []const u8,
    element_id: []const u8,
    list_id: []const u8,
    item_prefix: []const u8,
    top_spacer_id: []const u8,
    bottom_spacer_id: []const u8,
    base_item_height: f32,
    viewport_height_logical: f32 = PALETTE_VIEWPORT_HEIGHT_LOGICAL,

    /// Clamps `current_scroll_y` to the valid logical content scroll range
    /// `[-max_scroll, 0.0]` and, when `selection_dirty` is true, adjusts the
    /// scroll offset so `selected_idx` is fully visible within
    /// `self.viewport_height_logical`.
    pub fn resolveScrollOffsetY(
        self: PaletteConfig,
        current_scroll_y: f32,
        total_items: usize,
        selected_idx: usize,
        selection_dirty: bool,
    ) f32 {
        const item_height = self.base_item_height;
        const viewport_height = self.viewport_height_logical;
        const total_content_h = @as(f32, @floatFromInt(total_items)) *
            item_height;
        const max_scroll = @max(0.0, total_content_h - viewport_height);
        var scroll_y = std.math.clamp(current_scroll_y, -max_scroll, 0.0);

        if (selection_dirty and total_items > 0) {
            const clamped_sel = @min(selected_idx, total_items - 1);
            const item_top = @as(f32, @floatFromInt(clamped_sel)) *
                item_height;
            const item_bottom = item_top + item_height;
            const visible_top = -scroll_y;
            const visible_bottom = visible_top + viewport_height;

            if (item_top < visible_top) {
                scroll_y = -item_top;
            } else if (item_bottom > visible_bottom) {
                scroll_y = -(item_bottom - viewport_height);
            }
            scroll_y = std.math.clamp(scroll_y, -max_scroll, 0.0);
        }

        return scroll_y;
    }
};

/// Encapsulates fuzzy substring match highlighting for palette items without
/// exposing fuzzy matching library details to UI renderers.
pub const FuzzyHighlighter = struct {
    searcher: ?fuzzig.Ascii = null,

    /// Initializes a fuzzy highlighter configured for the given haystack and
    /// needle bounds. If initialization fails, returns an empty highlighter.
    pub fn init(
        allocator: std.mem.Allocator,
        max_haystack: usize,
        max_needle: usize,
    ) FuzzyHighlighter {
        return .{
            .searcher = fuzzig.Ascii.init(
                allocator,
                max_haystack,
                max_needle,
                .{ .case_sensitive = false },
            ) catch null,
        };
    }

    /// Releases internal fuzzy searcher state and resources.
    pub fn deinit(self: *FuzzyHighlighter) void {
        if (self.searcher) |*s| {
            s.deinit();
        }
    }

    /// Returns matching byte indices within `haystack` matching `query`.
    pub fn matchText(
        self: *FuzzyHighlighter,
        haystack: []const u8,
        query: []const u8,
    ) []const usize {
        if (query.len == 0 or haystack.len == 0) return &.{};
        if (self.searcher) |*s| {
            const res = s.scoreMatches(haystack, query);
            if (res.score != null) {
                return res.matches;
            }
        }
        return &.{};
    }

    /// Computes matching character indices for image file list entries,
    /// matching against basename, companion JPEG, or RAW+JPG pair tag.
    pub fn matchFileItem(
        self: *FuzzyHighlighter,
        allocator: std.mem.Allocator,
        basename: []const u8,
        jpeg_path_opt: ?[]const u8,
        is_pair: bool,
        query_str: []const u8,
    ) !std.ArrayList(usize) {
        var basename_matches = try std.ArrayList(usize).initCapacity(
            allocator,
            16,
        );
        errdefer basename_matches.deinit(allocator);

        if (query_str.len == 0 or basename.len == 0) return basename_matches;
        const searcher = if (self.searcher) |*s|
            s
        else
            return basename_matches;

        const jpeg_base = if (jpeg_path_opt) |jp|
            std.Io.Dir.path.basename(jp)
        else
            "";

        var best_score: ?i32 = searcher.score(basename, query_str);
        var best_source: enum { base, jpeg, tag } = .base;

        if (jpeg_base.len > 0) {
            if (searcher.score(jpeg_base, query_str)) |jpeg_score| {
                if (best_score == null or jpeg_score > best_score.?) {
                    best_score = jpeg_score;
                    best_source = .jpeg;
                }
            }
        }
        if (is_pair) {
            if (searcher.score("RAW+JPG", query_str)) |tag_score| {
                if (best_score == null or tag_score > best_score.?) {
                    best_score = tag_score;
                    best_source = .tag;
                }
            }
        }

        if (best_score == null) return basename_matches;

        switch (best_source) {
            .base => {
                const base_res = searcher.scoreMatches(basename, query_str);
                if (base_res.score != null) {
                    try basename_matches.appendSlice(
                        allocator,
                        base_res.matches,
                    );
                }
            },
            .jpeg => {
                const jpeg_res = searcher.scoreMatches(jpeg_base, query_str);
                if (jpeg_res.score != null) {
                    var shared_len: usize = 0;
                    const min_len = @min(basename.len, jpeg_base.len);
                    while (shared_len < min_len and
                        std.ascii.toLower(basename[shared_len]) ==
                            std.ascii.toLower(jpeg_base[shared_len]))
                    {
                        shared_len += 1;
                    }
                    for (jpeg_res.matches) |idx| {
                        if (idx < shared_len) {
                            try basename_matches.append(allocator, idx);
                        }
                    }
                }
            },
            .tag => {},
        }

        return basename_matches;
    }
};

/// Precomputed command palette configurations for all 13 edit parameters.
const palette_configs: [EditParam.count]PaletteConfig = blk: {
    var cfgs: [EditParam.count]PaletteConfig = undefined;
    for (intents.specs, 0..) |spec, i| {
        cfgs[i] = .{
            .title = spec.prompt_label,
            .placeholder = spec.prompt_placeholder,
            .element_id = spec.pascal_name ++ "Palette",
            .list_id = spec.pascal_name ++ "PaletteList",
            .item_prefix = spec.pascal_name ++ "Item_",
            .top_spacer_id = spec.pascal_name ++ "TopSpacer",
            .bottom_spacer_id = spec.pascal_name ++ "BottomSpacer",
            .base_item_height = 50.0,
        };
    }
    break :blk cfgs;
};

/// Returns the static layout configuration struct for a given palette mode.
pub fn getPaletteConfig(mode: PaletteMode) PaletteConfig {
    if (mode.toEditParam()) |param| {
        return palette_configs[@backingInt(param)];
    }
    return switch (mode) {
        .files => .{
            .title = "Search Files",
            .placeholder = "Type file name to search...",
            .element_id = "CommandPalette",
            .list_id = "CommandPaletteList",
            .item_prefix = "PaletteItem_",
            .top_spacer_id = "PaletteTopSpacer",
            .bottom_spacer_id = "PaletteBottomSpacer",
            .base_item_height = 58.0,
        },
        .actions => .{
            .title = "Command Palette",
            .placeholder = "Type a command to run...",
            .element_id = "ActionPalette",
            .list_id = "ActionPaletteList",
            .item_prefix = "ActionItem_",
            .top_spacer_id = "ActionTopSpacer",
            .bottom_spacer_id = "ActionBottomSpacer",
            .base_item_height = 50.0,
        },
        .go_to_image => .{
            .title = "Go to Image",
            .placeholder = "Enter image number...",
            .element_id = "GoToImagePalette",
            .list_id = "GoToImageList",
            .item_prefix = "GoToImageItem_",
            .top_spacer_id = "GoToImageTopSpacer",
            .bottom_spacer_id = "GoToImageBottomSpacer",
            .base_item_height = 50.0,
        },
        .directory_navigator => .{
            .title = "Directory Navigator",
            .placeholder = "Search subfolders...",
            .element_id = "DirectoryNavigatorPalette",
            .list_id = "DirectoryNavigatorList",
            .item_prefix = "DirItem_",
            .top_spacer_id = "DirTopSpacer",
            .bottom_spacer_id = "DirBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_slideshow_interval => .{
            .title = "Start Slide Show",
            .placeholder = "Enter delay in seconds (e.g. 3 or 2.5)...",
            .element_id = "SlideshowPalette",
            .list_id = "SlideshowList",
            .item_prefix = "SlideshowItem_",
            .top_spacer_id = "SlideshowTopSpacer",
            .bottom_spacer_id = "SlideshowBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_brightness,
        .set_contrast,
        .set_contrast_blend,
        .set_highlights,
        .set_shadows,
        .set_whites,
        .set_blacks,
        .set_temperature,
        .set_tint,
        .set_vibrance,
        .set_saturation,
        .set_clarity,
        .set_texture,
        => unreachable,
        .inactive => getPaletteConfig(.files),
    };
}

test "PaletteState - lifecycle, action matching, and reset" {
    const allocator = std.testing.allocator;
    var state = try PaletteState.init(allocator);
    defer state.deinit();

    state.mode = .actions;
    try state.rebuildActionMatches();
    const all_count = state.matches.items.len;
    try std.testing.expect(all_count > 0);

    // Query search "zoom"
    try state.query.appendSlice(allocator, "zoom");
    try state.rebuildActionMatches();
    try std.testing.expect(state.matches.items.len > 0);
    try std.testing.expect(state.matches.items.len < all_count);

    // Reset clears state
    state.reset();
    try std.testing.expectEqual(PaletteMode.inactive, state.mode);
    try std.testing.expectEqual(@as(usize, 0), state.query.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.selected_idx);
}

test "PaletteState - rebuildFileMatches with RAW+JPEG pair" {
    const allocator = std.testing.allocator;
    var state = try PaletteState.init(allocator);
    defer state.deinit();

    state.mode = .files;
    const entries = [_]MediaEntry{
        .{ .filesystem = .{ .path = "/photos/forest.png" } },
        .{
            .pair = .{
                .raw_path = "/photos/DSC00941.ARW",
                .jpeg_path = "/photos/DSC00941.JPG",
            },
        },
        .{ .filesystem = .{ .path = "/photos/beach.jpg" } },
    };

    // 1. Empty query matches all items
    try state.rebuildFileMatches(&entries);
    try std.testing.expectEqual(@as(usize, 3), state.matches.items.len);

    // 2. Searching RAW extension matches pair
    try state.query.appendSlice(allocator, "ARW");
    try state.rebuildFileMatches(&entries);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0]);

    // 3. Searching companion JPEG extension matches both pair and beach.jpg
    state.query.clearRetainingCapacity();
    try state.query.appendSlice(allocator, "JPG");
    try state.rebuildFileMatches(&entries);
    try std.testing.expectEqual(@as(usize, 2), state.matches.items.len);

    // 4. Searching RAW+JPG matches pair
    state.query.clearRetainingCapacity();
    try state.query.appendSlice(allocator, "RAW+JPG");
    try state.rebuildFileMatches(&entries);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0]);

    // 5. Searching non-pair file matches only that file
    state.query.clearRetainingCapacity();
    try state.query.appendSlice(allocator, "forest");
    try state.rebuildFileMatches(&entries);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.matches.items[0]);
}

test "PaletteConfig.resolveScrollOffsetY clamps stale scroll and seeds mount" {
    const cfg = getPaletteConfig(.files); // base_item_height = 58.0

    // 1. Initial mount frame (current_scroll_y = 0.0, selection_dirty = true)
    // at deep index 50 of 100 items -> scrolls directly to item 50
    const y_initial = cfg.resolveScrollOffsetY(0.0, 100, 50, true);
    // item_bottom = 51 * 58 = 2958; -(2958 - 320) = -2638.0
    try std.testing.expectApproxEqAbs(@as(f32, -2638.0), y_initial, 0.001);

    // 2. Filtered item count shrinks below viewport height (4 items = 232px)
    // with stale scroll_position.y = -150.0 and selected_idx = 3 -> clamps 0.0
    const y_shrunk_dirty = cfg.resolveScrollOffsetY(-150.0, 4, 3, true);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), y_shrunk_dirty, 0.001);

    // 3. Filtered item count shrinks while selection_dirty is false -> clamps
    // stale scroll_position.y (-1000.0) to -max_scroll (10 * 58 - 320 = 260)
    const y_shrunk_clean = cfg.resolveScrollOffsetY(-1000.0, 10, 0, false);
    try std.testing.expectApproxEqAbs(@as(f32, -260.0), y_shrunk_clean, 0.001);
}

test "PaletteState.getSearcher resizes only dimensions that exceed capacity" {
    const allocator = std.testing.allocator;
    var state = try PaletteState.init(allocator);
    defer state.deinit();

    // 1. Initial allocation clamps to (64, 16)
    const s1 = try state.getSearcher(10, 5);
    try std.testing.expectEqual(@as(usize, 64), s1.alg.max_haystack);
    try std.testing.expectEqual(@as(usize, 16), s1.alg.max_needle);

    // 2. Haystack exceeds capacity (100 > 64), needle fits (10 <= 16):
    // max_haystack doubles to 128, max_needle remains unchanged at 16
    const s2 = try state.getSearcher(100, 10);
    try std.testing.expectEqual(@as(usize, 128), s2.alg.max_haystack);
    try std.testing.expectEqual(@as(usize, 16), s2.alg.max_needle);

    // 3. Needle exceeds capacity (20 > 16), haystack fits (80 <= 128):
    // max_needle doubles to 32, max_haystack remains unchanged at 128
    const s3 = try state.getSearcher(80, 20);
    try std.testing.expectEqual(@as(usize, 128), s3.alg.max_haystack);
    try std.testing.expectEqual(@as(usize, 32), s3.alg.max_needle);
}

test "PaletteConfig - Contrast palette config displays 0.0 to 3.0 range" {
    const contrast_cfg = getPaletteConfig(.set_contrast);
    try std.testing.expectEqualStrings("Set Contrast", contrast_cfg.title);
    try std.testing.expectEqualStrings(
        "Enter contrast (0.0 to 3.0, e.g. 1.5)...",
        contrast_cfg.placeholder,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, contrast_cfg.placeholder, "0.0 to 3.0") != null,
    );
}

test "loadDirectoryEntries preserves root path '/' on upward nav" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var palette = try PaletteState.init(allocator);
    defer palette.deinit();

    palette.current_nav_dir.clearRetainingCapacity();
    try palette.current_nav_dir.appendSlice(allocator, "/home");

    try palette.loadDirectoryEntries(io, "/");

    try std.testing.expectEqualStrings("/", palette.current_nav_dir.items);
    try std.testing.expectEqualStrings("/", palette.last_nav_dir.items);
    try std.testing.expectEqualStrings("home", palette.last_child_dir.items);
}

test "PaletteState directory_navigator mode configuration and item matching" {
    var palette = try PaletteState.init(std.testing.allocator);
    defer palette.deinit();

    palette.mode = .directory_navigator;
    try palette.current_nav_dir.appendSlice(
        std.testing.allocator,
        "/home/user/Pictures",
    );

    try palette.dir_items.append(std.testing.allocator, .{
        .parent = .{
            .name = try std.testing.allocator.dupe(u8, ".."),
            .full_path = try std.testing.allocator.dupe(u8, "/home/user"),
        },
    });
    try palette.dir_items.append(std.testing.allocator, .{
        .directory = .{
            .name = try std.testing.allocator.dupe(u8, "Vacation"),
            .full_path = try std.testing.allocator.dupe(
                u8,
                "/home/user/Pictures/Vacation",
            ),
            .scan = .{ .scanned = .{ .image_count = 12 } },
        },
    });

    try palette.rebuildDirectoryMatches();
    try std.testing.expectEqual(@as(usize, 2), palette.matches.items.len);

    try palette.query.appendSlice(std.testing.allocator, "Vac");
    try palette.rebuildDirectoryMatches();
    try std.testing.expectEqual(@as(usize, 1), palette.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), palette.matches.items[0]);
}

test "getPaletteConfig metadata lookup helper" {
    const files_cfg = getPaletteConfig(.files);
    try std.testing.expectEqualStrings("Search Files", files_cfg.title);
    try std.testing.expectEqualStrings("CommandPalette", files_cfg.element_id);

    const actions_cfg = getPaletteConfig(.actions);
    try std.testing.expectEqualStrings("Command Palette", actions_cfg.title);
    try std.testing.expectEqualStrings("ActionPalette", actions_cfg.element_id);

    const bright_cfg = getPaletteConfig(.set_brightness);
    try std.testing.expectEqualStrings("Set Brightness", bright_cfg.title);

    const contrast_cfg = getPaletteConfig(.set_contrast);
    try std.testing.expectEqualStrings("Set Contrast", contrast_cfg.title);

    const goto_cfg = getPaletteConfig(.go_to_image);
    try std.testing.expectEqualStrings("Go to Image", goto_cfg.title);

    const dir_cfg = getPaletteConfig(.directory_navigator);
    try std.testing.expectEqualStrings("Directory Navigator", dir_cfg.title);

    const slide_cfg = getPaletteConfig(.set_slideshow_interval);
    try std.testing.expectEqualStrings("Start Slide Show", slide_cfg.title);
}

test "FuzzyHighlighter.matchFileItem - stem match on jpeg pair" {
    const alloc = std.testing.allocator;
    var highlighter = FuzzyHighlighter.init(alloc, 64, 16);
    defer highlighter.deinit();

    // 1. Direct basename match on "DSC0001.ARW"
    var m1 = try highlighter.matchFileItem(
        alloc,
        "DSC0001.ARW",
        "/photos/DSC0001.JPG",
        true,
        "DSC0001.ARW",
    );
    defer m1.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 11), m1.items.len);

    // 2. JPEG sibling match ("DSC0001.JPG" query on "DSC0001.ARW" basename)
    // Shared prefix is "DSC0001." (length 8); ".JPG" indices >= 8 are dropped
    var m2 = try highlighter.matchFileItem(
        alloc,
        "DSC0001.ARW",
        "/photos/DSC0001.JPG",
        true,
        "DSC0001.JPG",
    );
    defer m2.deinit(alloc);
    try std.testing.expectEqualSlices(
        usize,
        &[_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 },
        m2.items,
    );

    // 3. Tag match ("RAW+JPG" query on "DSC0001.ARW" pair) -> no false-positive
    // highlights on basename characters ('R', 'A', 'W')
    var m3 = try highlighter.matchFileItem(
        alloc,
        "DSC0001.ARW",
        "/photos/DSC0001.JPG",
        true,
        "RAW+JPG",
    );
    defer m3.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), m3.items.len);
}

test "PaletteState.computeWindowMaxHaystack across visible rows" {
    const alloc = std.testing.allocator;
    var pal_state = try PaletteState.init(alloc);
    defer pal_state.deinit();
    pal_state.mode = .directory_navigator;

    const long_name: [96]u8 = @splat('a');
    try pal_state.dir_items.append(alloc, .{
        .directory = .{
            .name = try alloc.dupe(u8, "short"),
            .full_path = try alloc.dupe(u8, "/tmp/short"),
            .scan = .unscanned,
        },
    });
    try pal_state.dir_items.append(alloc, .{
        .directory = .{
            .name = try alloc.dupe(u8, &long_name),
            .full_path = try alloc.dupe(u8, "/tmp/" ++ long_name),
            .scan = .unscanned,
        },
    });

    try std.testing.expectEqual(
        @as(usize, 64),
        pal_state.computeWindowMaxHaystack(&.{}, &[_]usize{0}),
    );
    try std.testing.expectEqual(
        @as(usize, 96),
        pal_state.computeWindowMaxHaystack(&.{}, &[_]usize{ 0, 1 }),
    );
}
