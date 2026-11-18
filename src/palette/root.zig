//! Palette Module
//!
//! Encapsulates command palette state, fuzzy match scoring via `fuzzig`,
//! Zero SDL and zero C dependencies.

const builtin = @import("builtin");
const fuzzig = @import("fuzzig");
const intents = @import("intents");
const std = @import("std");
const vfs = @import("vfs");

const ActivePaletteMode = intents.ActivePaletteMode;
const DirectoryEntry = vfs.DirectoryEntry;
const EditParam = intents.EditParam;
const EntryScanState = vfs.EntryScanState;
const getParentDirBuf = vfs.getParentDirBuf;
const getStaticChildBasename = vfs.getStaticChildBasename;
const isCbzFile = vfs.isCbzFile;
const MediaEntry = vfs.MediaEntry;
const palette_action_items = intents.actions.palette_action_items;
const trimTrailingSeparators = vfs.trimTrailingSeparators;

/// Maximum memory bytes retained across directory arena resets (64 KiB).
const MAX_RETAINED_DIR_ARENA_BYTES: usize = 64 * 1024;

/// Lifecycle state of the command palette modal, coupling visibility and
/// active mode so closed palettes cannot be closing and vice versa.
pub const PaletteLifecycle = union(enum) {
    closed,
    open: ActivePaletteMode,
    closing: ActivePaletteMode,
};

/// Represents a search result item paired with its fuzzy matching score.
pub const ScoredMatch = struct {
    index: usize,
    score: i32,
};

/// Normalized target directory, scan generation, and child preselection
/// metadata returned by `PaletteState.beginDirectoryLoad`.
pub const DirectoryLoadSpec = struct {
    target_dir: []const u8,
    generation: usize,
    preselect_child: ?[]const u8,
    needs_child_resolve: bool = false,
};

/// Main state model for command palette modals, directory navigation, and fuzzy
/// searching.
pub const PaletteState = struct {
    lifecycle: PaletteLifecycle = .closed,
    query: std.ArrayList(u8) = .empty,
    selected_idx: usize = 0,
    matches: std.ArrayList(usize) = .empty,
    scored_matches: std.ArrayList(ScoredMatch) = .empty,
    selection_dirty: bool = false,
    current_nav_dir: std.ArrayList(u8) = .empty,
    last_nav_dir: std.ArrayList(u8) = .empty,
    last_child_dir: std.ArrayList(u8) = .empty,
    /// Directory navigator items; both the backing buffer and entry strings are
    /// allocated from `dir_arena`.
    dir_items: std.ArrayList(DirectoryEntry) = .empty,
    dir_arena: std.heap.ArenaAllocator,
    current_dir_image_count: usize = 0,
    dir_scan_generation: std.atomic.Value(usize) = .init(0),
    active_dir_scans: std.atomic.Value(usize) = .init(0),
    searcher: ?fuzzig.Ascii = null,
    max_haystack_len: usize = 64,

    /// Initializes a new `PaletteState` instance, reserving initial
    /// capacities for queries, matches, and paths.
    pub fn init(allocator: std.mem.Allocator) !PaletteState {
        var self = PaletteState{
            .dir_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.deinit(allocator);
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
        return self;
    }

    /// Returns `true` if the palette is visible (open or closing dissolve).
    pub inline fn isOpen(self: *const PaletteState) bool {
        return switch (self.lifecycle) {
            .closed => false,
            .open, .closing => true,
        };
    }

    /// Returns the active mode when visible (open or closing), or `null` when
    /// closed.
    pub inline fn visibleMode(self: *const PaletteState) ?ActivePaletteMode {
        return switch (self.lifecycle) {
            .closed => null,
            .open, .closing => |m| m,
        };
    }

    /// Returns the active mode only while open and accepting input, or `null`
    /// when closed or closing.
    pub inline fn openMode(self: *const PaletteState) ?ActivePaletteMode {
        return switch (self.lifecycle) {
            .open => |m| m,
            .closed, .closing => null,
        };
    }

    /// Transitions an open palette into its closing dissolve state and
    /// invalidates any in-flight directory scan generation.
    pub inline fn beginClose(self: *PaletteState) void {
        switch (self.lifecycle) {
            .open => |m| {
                self.lifecycle = .{ .closing = m };
                _ = self.dir_scan_generation.fetchAdd(1, .release);
            },
            .closed, .closing => {},
        }
    }

    /// Frees all dynamically allocated memory, string arrays, searcher state,
    /// and directory items.
    pub fn deinit(self: *PaletteState, allocator: std.mem.Allocator) void {
        if (self.searcher) |*s| {
            s.deinit();
        }
        self.query.deinit(allocator);
        self.matches.deinit(allocator);
        self.scored_matches.deinit(allocator);
        self.current_nav_dir.deinit(allocator);
        self.last_nav_dir.deinit(allocator);
        self.last_child_dir.deinit(allocator);
        self.dir_items = .empty;
        self.dir_arena.deinit();
    }

    /// Clears directory items and resets the directory arena up to
    /// `MAX_RETAINED_DIR_ARENA_BYTES`.
    pub fn clearDirItems(self: *PaletteState) void {
        self.dir_items = .empty;
        _ = self.dir_arena.reset(.{
            .retain_with_limit = MAX_RETAINED_DIR_ARENA_BYTES,
        });
    }

    /// Clears search query, matched indexes, navigation directory, and
    /// restores palette to closed lifecycle state.
    pub fn reset(self: *PaletteState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        self.current_nav_dir.clearRetainingCapacity();
        self.last_child_dir.clearRetainingCapacity();
        self.clearDirItems();
        _ = self.dir_scan_generation.fetchAdd(1, .release);
        self.lifecycle = .closed;
        self.selected_idx = 0;
        self.selection_dirty = true;
    }

    /// Trims oversized backing arrays and fuzzy searcher allocations back to
    /// their warm initial footprint when hiding the window in server mode.
    pub fn shrinkToWarmCapacity(
        self: *PaletteState,
        allocator: std.mem.Allocator,
    ) void {
        if (self.matches.capacity > 64) {
            self.matches.clearAndFree(allocator);
        }
        if (self.scored_matches.capacity > 64) {
            self.scored_matches.clearAndFree(allocator);
        }
        self.dir_items = .empty;
        _ = self.dir_arena.reset(.free_all);
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
        return switch (self.lifecycle) {
            .open => true,
            .closed, .closing => false,
        };
    }

    /// Returns a lazily initialized or resized ASCII fuzzy searcher matching
    /// the requested haystack and needle lengths.
    fn getSearcher(
        self: *PaletteState,
        allocator: std.mem.Allocator,
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
                allocator,
                req_haystack,
                req_needle,
                .{ .case_sensitive = false },
            );
            return &self.searcher.?;
        }
    }

    /// Sorts `scored_matches` by score descending and extracts matching
    /// candidate indices into `matches`.
    fn sortAndExtractMatches(
        self: *PaletteState,
        allocator: std.mem.Allocator,
    ) !void {
        std.mem.sort(ScoredMatch, self.scored_matches.items, {}, struct {
            fn lessThan(_: void, a: ScoredMatch, b: ScoredMatch) bool {
                return a.score > b.score;
            }
        }.lessThan);

        try self.matches.ensureTotalCapacity(
            allocator,
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
    pub fn rebuildActionMatches(
        self: *PaletteState,
        allocator: std.mem.Allocator,
    ) !void {
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        const query_str = self.query.items;
        if (query_str.len == 0) {
            try self.matches.ensureTotalCapacity(
                allocator,
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

        const searcher_ptr = try self.getSearcher(
            allocator,
            max_h,
            query_str.len,
        );

        try self.scored_matches.ensureTotalCapacity(
            allocator,
            palette_action_items.len,
        );

        for (palette_action_items, 0..) |item, idx| {
            if (searcher_ptr.score(item.name, query_str)) |score| {
                self.scored_matches.appendAssumeCapacity(
                    .{ .index = idx, .score = score },
                );
            }
        }

        try self.sortAndExtractMatches(allocator);
    }

    /// Rebuilds fuzzy match results for directory navigator items.
    ///
    /// Optimizations:
    /// - Short-circuits when query is empty, populating `matches` directly
    ///   without searcher allocation or fuzzy scoring.
    /// - Pre-allocates `scored_matches` and `matches` capacities to allow
    ///   `appendAssumeCapacity` writes during scoring.
    pub fn rebuildDirectoryMatches(
        self: *PaletteState,
        allocator: std.mem.Allocator,
    ) !void {
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        self.selected_idx = 0;
        const query_str = self.query.items;

        if (query_str.len == 0) {
            try self.matches.ensureTotalCapacity(
                allocator,
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

        if (self.dir_items.items.len == 0) return;

        var searcher_ptr = try self.getSearcher(
            allocator,
            self.max_haystack_len,
            query_str.len,
        );

        try self.scored_matches.ensureTotalCapacity(
            allocator,
            self.dir_items.items.len,
        );

        for (self.dir_items.items, 0..) |entry, idx| {
            const name = entry.getName();
            if (name.len > self.max_haystack_len) {
                searcher_ptr = try self.getSearcher(
                    allocator,
                    name.len,
                    query_str.len,
                );
                self.max_haystack_len = name.len;
            }
            if (searcher_ptr.score(name, query_str)) |score| {
                self.scored_matches.appendAssumeCapacity(
                    .{ .index = idx, .score = score },
                );
            }
        }

        try self.sortAndExtractMatches(allocator);
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
        allocator: std.mem.Allocator,
        image_list: []const MediaEntry,
    ) !void {
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        const query_str = self.query.items;
        if (query_str.len == 0) {
            try self.matches.ensureTotalCapacity(
                allocator,
                image_list.len,
            );
            for (image_list, 0..) |_, real_idx| {
                self.matches.appendAssumeCapacity(real_idx);
            }
            return;
        }

        if (image_list.len == 0) return;

        self.max_haystack_len = @max(self.max_haystack_len, "RAW+JPG".len);
        var searcher_ptr = try self.getSearcher(
            allocator,
            self.max_haystack_len,
            query_str.len,
        );
        const pair_tag_score = searcher_ptr.score("RAW+JPG", query_str);

        try self.scored_matches.ensureTotalCapacity(
            allocator,
            image_list.len,
        );

        for (image_list, 0..) |item, real_idx| {
            const basename = item.getBasename();
            if (basename.len > self.max_haystack_len) {
                searcher_ptr = try self.getSearcher(
                    allocator,
                    basename.len,
                    query_str.len,
                );
                self.max_haystack_len = basename.len;
            }
            var best_score = searcher_ptr.score(basename, query_str);
            if (item.getJpegPath()) |jpeg_p| {
                const jpeg_base = std.Io.Dir.path.basename(jpeg_p);
                if (jpeg_base.len > self.max_haystack_len) {
                    searcher_ptr = try self.getSearcher(
                        allocator,
                        jpeg_base.len,
                        query_str.len,
                    );
                    self.max_haystack_len = jpeg_base.len;
                }
                if (searcher_ptr.score(jpeg_base, query_str)) |jpeg_score| {
                    best_score = if (best_score) |s|
                        @max(s, jpeg_score)
                    else
                        jpeg_score;
                }
            }
            if (item.isPair()) {
                if (pair_tag_score) |tag_score| {
                    best_score = if (best_score) |s|
                        @max(s, tag_score)
                    else
                        tag_score;
                }
            }
            if (best_score) |score| {
                self.scored_matches.appendAssumeCapacity(.{
                    .index = real_idx,
                    .score = score,
                });
            }
        }

        try self.sortAndExtractMatches(allocator);
    }

    fn assignSliceOverlapSafe(
        list: *std.ArrayList(u8),
        src: []const u8,
    ) void {
        if (src.len == 0) {
            list.items.len = 0;
            return;
        }
        const alloc_slice = list.allocatedSlice();
        std.debug.assert(alloc_slice.len >= src.len);
        const buf_start = @intFromPtr(alloc_slice.ptr);
        const buf_end = buf_start + alloc_slice.len;
        const src_start = @intFromPtr(src.ptr);
        const src_end = src_start + src.len;
        if (src_start < buf_end and buf_start < src_end) {
            @memmove(alloc_slice[0..src.len], src);
            list.items.len = src.len;
        } else {
            list.clearRetainingCapacity();
            list.appendSliceAssumeCapacity(src);
        }
    }

    /// Normalizes `dir_path`, updates navigation history and `last_child_dir`,
    /// clears current directory items and fuzzy matches, increments
    /// `dir_scan_generation`, and returns metadata to spawn a scan worker.
    pub fn beginDirectoryLoad(
        self: *PaletteState,
        allocator: std.mem.Allocator,
        dir_path: []const u8,
        preselect_child: ?[]const u8,
    ) !DirectoryLoadSpec {
        const raw_target = trimTrailingSeparators(dir_path);
        const target = if (isCbzFile(raw_target))
            (std.Io.Dir.path.dirname(raw_target) orelse ".")
        else
            raw_target;

        var stack_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var fb: std.heap.BufferFirstAllocator = .init(
            &stack_buf,
            allocator,
        );
        const temp_alloc = fb.allocator();
        const dir_path_copy = try temp_alloc.dupe(u8, target);
        defer temp_alloc.free(dir_path_copy);
        const child_copy: ?[]const u8 = if (preselect_child) |child|
            try temp_alloc.dupe(u8, child)
        else
            null;
        defer if (child_copy) |c| temp_alloc.free(c);

        var path_scratch: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var navigated_up = false;
        if (child_copy == null and self.current_nav_dir.items.len > 0) {
            if (getParentDirBuf(
                self.current_nav_dir.items,
                &path_scratch,
            )) |parent_dir| {
                if (std.mem.eql(u8, dir_path_copy, parent_dir)) {
                    navigated_up = true;
                }
            }
        }

        var needs_child_resolve = false;
        var next_child: ?[]const u8 = null;
        if (child_copy) |child| {
            if (!std.mem.eql(u8, self.last_child_dir.items, child)) {
                next_child = child;
            }
        } else if (navigated_up) {
            const base = getStaticChildBasename(self.current_nav_dir.items);
            if (std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
                if (self.last_child_dir.items.len > 0) {
                    next_child = "";
                }
                needs_child_resolve = true;
            } else {
                next_child = base;
            }
        } else if (self.current_nav_dir.items.len > 0) {
            if (self.last_child_dir.items.len > 0) {
                next_child = "";
            }
        }

        if (next_child) |child| {
            try self.last_child_dir.ensureTotalCapacity(allocator, child.len);
        }
        try self.current_nav_dir.ensureTotalCapacity(
            allocator,
            dir_path_copy.len,
        );
        try self.last_nav_dir.ensureTotalCapacity(
            allocator,
            dir_path_copy.len,
        );

        if (next_child) |child| {
            assignSliceOverlapSafe(&self.last_child_dir, child);
        }

        assignSliceOverlapSafe(&self.current_nav_dir, dir_path_copy);
        assignSliceOverlapSafe(&self.last_nav_dir, dir_path_copy);

        const generation = self.dir_scan_generation.fetchAdd(
            1,
            .release,
        ) +% 1;

        self.clearDirItems();
        self.matches.clearRetainingCapacity();
        self.scored_matches.clearRetainingCapacity();
        self.current_dir_image_count = 0;
        self.selected_idx = 0;
        self.selection_dirty = true;

        return .{
            .target_dir = self.current_nav_dir.items,
            .generation = generation,
            .preselect_child = if (self.last_child_dir.items.len > 0)
                self.last_child_dir.items
            else
                null,
            .needs_child_resolve = needs_child_resolve,
        };
    }

    /// Transfers a worker-populated `dir_arena` and `dir_items` list into
    /// `PaletteState` in O(1), updates directory state and optional
    /// `preselect_child`, and rebuilds fuzzy directory matches.
    ///
    /// Reinitializes caller `dir_arena` to `.init(child_allocator)` and
    /// `dir_items` to `.empty` so `BackgroundEvent.deinit` is an O(1) no-op.
    pub fn applyLoadedDirectory(
        self: *PaletteState,
        allocator: std.mem.Allocator,
        dir_path: []const u8,
        dir_arena: *std.heap.ArenaAllocator,
        dir_items: *std.ArrayList(DirectoryEntry),
        image_count: usize,
        preselect_child: ?[]const u8,
    ) !void {
        var stack_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var fb: std.heap.BufferFirstAllocator = .init(
            &stack_buf,
            allocator,
        );
        const temp_alloc = fb.allocator();
        const dir_path_copy = try temp_alloc.dupe(u8, dir_path);
        defer temp_alloc.free(dir_path_copy);
        const child_copy: ?[]const u8 = if (preselect_child) |child|
            try temp_alloc.dupe(u8, child)
        else
            null;
        defer if (child_copy) |c| temp_alloc.free(c);

        if (!std.mem.eql(u8, self.current_nav_dir.items, dir_path_copy)) {
            try self.current_nav_dir.ensureTotalCapacity(
                allocator,
                dir_path_copy.len,
            );
        }
        if (!std.mem.eql(u8, self.last_nav_dir.items, dir_path_copy)) {
            try self.last_nav_dir.ensureTotalCapacity(
                allocator,
                dir_path_copy.len,
            );
        }
        if (child_copy) |child| {
            if (!std.mem.eql(u8, self.last_child_dir.items, child)) {
                try self.last_child_dir.ensureTotalCapacity(
                    allocator,
                    child.len,
                );
            }
        }

        self.dir_items = .empty;
        self.dir_arena.deinit();
        self.dir_arena = dir_arena.*;
        self.dir_items = dir_items.*;
        dir_arena.* = .init(self.dir_arena.child_allocator);
        dir_items.* = .empty;

        if (!std.mem.eql(u8, self.current_nav_dir.items, dir_path_copy)) {
            assignSliceOverlapSafe(&self.current_nav_dir, dir_path_copy);
        }
        if (!std.mem.eql(u8, self.last_nav_dir.items, dir_path_copy)) {
            assignSliceOverlapSafe(&self.last_nav_dir, dir_path_copy);
        }
        if (child_copy) |child| {
            if (!std.mem.eql(u8, self.last_child_dir.items, child)) {
                assignSliceOverlapSafe(&self.last_child_dir, child);
            }
        }

        self.current_dir_image_count = image_count;
        self.selection_dirty = true;
        try self.rebuildDirectoryMatches(allocator);
    }

    /// Rebuilds fuzzy search matches based on current palette mode and query.
    pub fn rebuildMatches(
        self: *PaletteState,
        allocator: std.mem.Allocator,
        entries: []const MediaEntry,
    ) !void {
        const mode = self.visibleMode() orelse return;
        switch (mode) {
            .files => try self.rebuildFileMatches(allocator, entries),
            .actions => try self.rebuildActionMatches(allocator),
            .directory_navigator => try self.rebuildDirectoryMatches(allocator),
            .prompt => |kind| switch (kind) {
                .go_to_image, .slideshow_interval, .edit_param => {},
            },
        }
    }

    /// Moves selection up by one item if not already at the top.
    pub fn moveSelectionUp(self: *PaletteState) void {
        if (self.selected_idx > 0) {
            self.selected_idx -= 1;
            self.selection_dirty = true;
        }
    }

    /// Moves selection down by one item if not already at the bottom.
    pub fn moveSelectionDown(self: *PaletteState) void {
        if (self.matches.items.len > 0 and
            self.selected_idx + 1 < self.matches.items.len)
        {
            self.selected_idx += 1;
            self.selection_dirty = true;
        }
    }

    /// Moves selection up by 5 items, clamping at zero.
    pub fn pageSelectionUp(self: *PaletteState) void {
        self.selected_idx = if (self.selected_idx >= 5)
            self.selected_idx - 5
        else
            0;
        self.selection_dirty = true;
    }

    /// Moves selection down by 5 items, clamping at the last item.
    pub fn pageSelectionDown(self: *PaletteState) void {
        if (self.matches.items.len > 0) {
            self.selected_idx = @min(
                self.selected_idx + 5,
                self.matches.items.len - 1,
            );
            self.selection_dirty = true;
        }
    }

    /// Deletes the word behind the cursor up to path or whitespace delimiters,
    /// rebuilding matches and returning `true` if any characters were removed.
    pub fn deleteWordBackward(
        self: *PaletteState,
        allocator: std.mem.Allocator,
        entries: []const MediaEntry,
    ) !bool {
        if (self.query.items.len == 0) return false;
        const initial_len = self.query.items.len;
        var q = self.query.items;
        while (q.len > 0 and (q[q.len - 1] == ' ' or q[q.len - 1] == '\t')) {
            _ = self.query.pop();
            q = self.query.items;
        }
        while (q.len > 0 and
            q[q.len - 1] != ' ' and
            q[q.len - 1] != '\t' and
            q[q.len - 1] != '/' and
            q[q.len - 1] != '\\')
        {
            _ = self.query.pop();
            q = self.query.items;
        }
        if (self.query.items.len == initial_len) return false;
        self.selected_idx = 0;
        self.selection_dirty = true;
        try self.rebuildMatches(allocator, entries);
        return true;
    }

    /// Clears the entire search query, rebuilding matches and returning `true`
    /// if any characters were removed.
    pub fn clearQuery(
        self: *PaletteState,
        allocator: std.mem.Allocator,
        entries: []const MediaEntry,
    ) !bool {
        if (self.query.items.len == 0) return false;
        self.query.clearRetainingCapacity();
        self.selected_idx = 0;
        self.selection_dirty = true;
        try self.rebuildMatches(allocator, entries);
        return true;
    }

    /// Removes the last UTF-8 codepoint from the query, rebuilding matches and
    /// returning `true` if a character was removed.
    pub fn deleteCharBackward(
        self: *PaletteState,
        allocator: std.mem.Allocator,
        entries: []const MediaEntry,
    ) !bool {
        if (self.query.items.len == 0) return false;
        while (self.query.items.len > 0) {
            const b = self.query.pop().?;
            if ((b & 0xC0) != 0x80) break;
        }
        self.selected_idx = 0;
        self.selection_dirty = true;
        try self.rebuildMatches(allocator, entries);
        return true;
    }

    /// Appends printable ASCII and UTF-8 characters to the search query,
    /// rebuilding matches and returning `true` if any bytes were appended.
    pub fn appendPrintableText(
        self: *PaletteState,
        allocator: std.mem.Allocator,
        text: []const u8,
        entries: []const MediaEntry,
    ) !bool {
        var any_appended = false;
        for (text) |ch| {
            if (ch >= 32 and ch != 127) {
                try self.query.append(allocator, ch);
                any_appended = true;
            }
        }
        if (any_appended) {
            self.selected_idx = 0;
            self.selection_dirty = true;
            try self.rebuildMatches(allocator, entries);
            return true;
        }
        return false;
    }

    /// Updates directory scan state for an item in the directory navigator
    /// list matching `path`, returning `true` if an item was found.
    pub fn applyFolderScan(
        self: *PaletteState,
        path: []const u8,
        scan: EntryScanState,
    ) bool {
        for (self.dir_items.items) |*item| {
            if (std.mem.eql(u8, item.getFullPath(), path)) {
                switch (item.*) {
                    .directory => |*d| d.scan = scan,
                    .archive_file => |*a| a.scan = scan,
                    .parent, .image_file => {},
                }
                self.selection_dirty = true;
                return true;
            }
        }
        return false;
    }

    /// Computes the maximum string length across visible item candidates in the
    /// active viewport window for allocating or sizing a fuzzy searcher.
    pub fn computeWindowMaxHaystack(
        self: *const PaletteState,
        entries: []const MediaEntry,
        visible_indices: []const usize,
    ) usize {
        const mode = self.visibleMode() orelse return 64;
        var max_h: usize = 64;
        for (visible_indices) |real_idx| {
            switch (mode) {
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
                .prompt => |kind| switch (kind) {
                    .go_to_image, .slideshow_interval, .edit_param => {},
                },
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
/// logical item and viewport heights).
pub const PaletteConfig = struct {
    title: []const u8,
    placeholder: []const u8,
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
        var basename_matches: std.ArrayList(usize) = try .initCapacity(
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
            .base_item_height = 50.0,
        };
    }
    break :blk cfgs;
};

/// Returns the static layout configuration struct for a given palette mode.
pub fn getPaletteConfig(mode: ActivePaletteMode) PaletteConfig {
    return switch (mode) {
        .files => .{
            .title = "Search Files",
            .placeholder = "Type file name to search...",
            .base_item_height = 58.0,
        },
        .actions => .{
            .title = "Command Palette",
            .placeholder = "Type a command to run...",
            .base_item_height = 50.0,
        },
        .directory_navigator => .{
            .title = "Directory Navigator",
            .placeholder = "Search subfolders...",
            .base_item_height = 50.0,
        },
        .prompt => |kind| switch (kind) {
            .go_to_image => .{
                .title = "Go to Image",
                .placeholder = "Enter image number...",
                .base_item_height = 50.0,
            },
            .slideshow_interval => .{
                .title = "Start Slide Show",
                .placeholder = "Enter delay in seconds (e.g. 3 or 2.5)...",
                .base_item_height = 50.0,
            },
            .edit_param => |param| palette_configs[@backingInt(param)],
        },
    };
}

/// Virtualized window computation for large palette item lists.
/// Calculates the visible index range and spacer element heights to restrict
/// UI element allocations to only items currently visible in the scroll
/// viewport.
pub const VirtualWindow = struct {
    start_idx: usize,
    end_idx: usize,
    top_spacer_h: f32,
    bottom_spacer_h: f32,

    /// Computes visible start/end item indices and top/bottom spacer heights
    /// for virtualized scrolling.
    pub fn compute(
        total_items: usize,
        scroll_offset_y: f32,
        viewport_height: f32,
        item_height: f32,
        gap: f32,
    ) VirtualWindow {
        if (total_items == 0) {
            return .{
                .start_idx = 0,
                .end_idx = 0,
                .top_spacer_h = 0,
                .bottom_spacer_h = 0,
            };
        }

        const visible_top = -scroll_offset_y;
        const visible_bottom = visible_top + viewport_height;

        var start_idx = @as(
            usize,
            @intFromFloat(@max(0.0, @floor(visible_top / item_height))),
        );
        var end_idx = @as(
            usize,
            @intFromFloat(@max(0.0, @ceil(visible_bottom / item_height))),
        );

        start_idx = if (start_idx > 0) start_idx - 1 else 0;
        end_idx = end_idx + 1;

        if (end_idx > total_items) end_idx = total_items;
        if (start_idx > end_idx) start_idx = end_idx;

        const top_spacer_h = if (start_idx > 0)
            @as(f32, @floatFromInt(start_idx)) * item_height - gap
        else
            0.0;

        const bottom_spacer_h = if (total_items - end_idx > 0)
            @as(f32, @floatFromInt(total_items - end_idx)) * item_height - gap
        else
            0.0;

        return .{
            .start_idx = start_idx,
            .end_idx = end_idx,
            .top_spacer_h = top_spacer_h,
            .bottom_spacer_h = bottom_spacer_h,
        };
    }
};

/// Represents a slice of text tagged with whether it matched a fuzzy search
/// query.
pub const TextChunk = struct {
    slice: []const u8,
    is_matched: bool,
};

fn appendOrMergeChunk(
    list: *std.ArrayList(TextChunk),
    allocator: std.mem.Allocator,
    slice: []const u8,
    is_matched: bool,
) !void {
    if (slice.len == 0) return;
    if (list.items.len > 0 and
        list.items[list.items.len - 1].is_matched == is_matched)
    {
        const last = &list.items[list.items.len - 1];
        const combined_len = last.slice.len + slice.len;
        last.slice = last.slice.ptr[0..combined_len];
    } else {
        try list.append(allocator, .{
            .slice = slice,
            .is_matched = is_matched,
        });
    }
}

/// Partitions a string into contiguous matched and unmatched TextChunk slices
/// for fuzzy search highlighting.
pub fn partitionHighlightedText(
    allocator: std.mem.Allocator,
    text: []const u8,
    match_indices: []const usize,
) ![]TextChunk {
    if (text.len == 0 or match_indices.len == 0) {
        if (text.len == 0) return &.{};
        var list: std.ArrayList(TextChunk) = try .initCapacity(allocator, 1);
        list.appendAssumeCapacity(.{ .slice = text, .is_matched = false });
        return list.toOwnedSlice(allocator);
    }

    for (match_indices) |m_idx| {
        if (m_idx >= text.len) {
            std.log.warn(
                "Fuzzy highlight match index {} out of bounds for " ++
                    "string '{s}' (length {})",
                .{ m_idx, text, text.len },
            );
        }
    }

    var list: std.ArrayList(TextChunk) = .empty;
    errdefer list.deinit(allocator);

    var idx: usize = 0;
    var match_ptr: usize = 0;

    while (idx < text.len) {
        while (match_ptr < match_indices.len and
            match_indices[match_ptr] < idx)
        {
            match_ptr += 1;
        }

        const start = idx;
        idx += 1;
        while (idx < text.len and (text[idx] & 0xC0) == 0x80) {
            idx += 1;
        }
        const is_matched = (match_ptr < match_indices.len and
            match_indices[match_ptr] < idx);

        if (is_matched) {
            while (match_ptr < match_indices.len and
                match_indices[match_ptr] < idx)
            {
                match_ptr += 1;
            }
            while (idx < text.len and match_ptr < match_indices.len) {
                var next_end = idx + 1;
                while (next_end < text.len and
                    (text[next_end] & 0xC0) == 0x80)
                {
                    next_end += 1;
                }
                if (match_indices[match_ptr] >= next_end) break;
                idx = next_end;
                while (match_ptr < match_indices.len and
                    match_indices[match_ptr] < idx)
                {
                    match_ptr += 1;
                }
            }

            var match_start = start;
            var match_end = idx;

            while (match_start < match_end and
                std.ascii.isWhitespace(text[match_start]))
            {
                match_start += 1;
            }
            while (match_end > match_start and
                std.ascii.isWhitespace(text[match_end - 1]))
            {
                match_end -= 1;
            }

            if (match_start > start) {
                try appendOrMergeChunk(
                    &list,
                    allocator,
                    text[start..match_start],
                    false,
                );
            }
            if (match_end > match_start) {
                try appendOrMergeChunk(
                    &list,
                    allocator,
                    text[match_start..match_end],
                    true,
                );
            }
            if (idx > match_end) {
                try appendOrMergeChunk(
                    &list,
                    allocator,
                    text[match_end..idx],
                    false,
                );
            }
        } else {
            try appendOrMergeChunk(
                &list,
                allocator,
                text[start..idx],
                false,
            );
        }
    }

    return try list.toOwnedSlice(allocator);
}

/// Remaps matched search character byte indices from the original filename to
/// the middle-truncated display string.
pub fn remapMiddleTruncatedMatches(
    allocator: std.mem.Allocator,
    matches: []const usize,
    head_len: usize,
    tail_start_idx: usize,
) ![]usize {
    if (matches.len == 0) return &.{};

    const actual_tail_start = @max(tail_start_idx, head_len);
    var list: std.ArrayList(usize) = try .initCapacity(allocator, matches.len);
    errdefer list.deinit(allocator);

    for (matches) |m_idx| {
        if (m_idx < head_len) {
            list.appendAssumeCapacity(m_idx);
        } else if (m_idx >= actual_tail_start) {
            list.appendAssumeCapacity(
                (m_idx - actual_tail_start) + head_len + 3,
            );
        }
    }
    return list.toOwnedSlice(allocator);
}

test "PaletteState - lifecycle, action matching, and reset" {
    const allocator = std.testing.allocator;
    var state = try PaletteState.init(allocator);
    defer state.deinit(allocator);

    state.lifecycle = .{ .open = .actions };
    try state.rebuildActionMatches(allocator);
    const all_count = state.matches.items.len;
    try std.testing.expect(all_count > 0);

    // Query search "zoom"
    try state.query.appendSlice(allocator, "zoom");
    try state.rebuildActionMatches(allocator);
    try std.testing.expect(state.matches.items.len > 0);
    try std.testing.expect(state.matches.items.len < all_count);

    // Reset clears state
    state.reset();
    try std.testing.expectEqual(PaletteLifecycle.closed, state.lifecycle);
    try std.testing.expectEqual(@as(usize, 0), state.query.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.selected_idx);
}

test "PaletteState - rebuildFileMatches with RAW+JPEG pair" {
    const allocator = std.testing.allocator;
    var state = try PaletteState.init(allocator);
    defer state.deinit(allocator);

    state.lifecycle = .{ .open = .files };
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
    try state.rebuildFileMatches(allocator, &entries);
    try std.testing.expectEqual(@as(usize, 3), state.matches.items.len);

    // 2. Searching RAW extension matches pair
    try state.query.appendSlice(allocator, "ARW");
    try state.rebuildFileMatches(allocator, &entries);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0]);

    // 3. Searching companion JPEG extension matches both pair and beach.jpg
    state.query.clearRetainingCapacity();
    try state.query.appendSlice(allocator, "JPG");
    try state.rebuildFileMatches(allocator, &entries);
    try std.testing.expectEqual(@as(usize, 2), state.matches.items.len);

    // 4. Searching RAW+JPG matches pair
    state.query.clearRetainingCapacity();
    try state.query.appendSlice(allocator, "RAW+JPG");
    try state.rebuildFileMatches(allocator, &entries);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0]);

    // 5. Searching non-pair file matches only that file
    state.query.clearRetainingCapacity();
    try state.query.appendSlice(allocator, "forest");
    try state.rebuildFileMatches(allocator, &entries);
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
    defer state.deinit(allocator);

    // 1. Initial allocation clamps to (64, 16)
    const s1 = try state.getSearcher(allocator, 10, 5);
    try std.testing.expectEqual(@as(usize, 64), s1.alg.max_haystack);
    try std.testing.expectEqual(@as(usize, 16), s1.alg.max_needle);

    // 2. Haystack exceeds capacity (100 > 64), needle fits (10 <= 16):
    // max_haystack doubles to 128, max_needle remains unchanged at 16
    const s2 = try state.getSearcher(allocator, 100, 10);
    try std.testing.expectEqual(@as(usize, 128), s2.alg.max_haystack);
    try std.testing.expectEqual(@as(usize, 16), s2.alg.max_needle);

    // 3. Needle exceeds capacity (20 > 16), haystack fits (80 <= 128):
    // max_needle doubles to 32, max_haystack remains unchanged at 128
    const s3 = try state.getSearcher(allocator, 80, 20);
    try std.testing.expectEqual(@as(usize, 128), s3.alg.max_haystack);
    try std.testing.expectEqual(@as(usize, 32), s3.alg.max_needle);
}

test "PaletteConfig - Contrast palette config displays 0.0 to 3.0 range" {
    const contrast_cfg = getPaletteConfig(.{
        .prompt = .{ .edit_param = .contrast },
    });
    try std.testing.expectEqualStrings("Set Contrast", contrast_cfg.title);
    try std.testing.expectEqualStrings(
        "Enter contrast (0.0 to 3.0, e.g. 1.5)...",
        contrast_cfg.placeholder,
    );
    try std.testing.expect(
        std.mem.find(u8, contrast_cfg.placeholder, "0.0 to 3.0") != null,
    );
}

test "beginDirectoryLoad preserves root path '/' on upward nav" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var palette = try PaletteState.init(allocator);
    defer palette.deinit(allocator);

    palette.current_nav_dir.clearRetainingCapacity();
    try palette.current_nav_dir.appendSlice(allocator, "/home");

    const spec = try palette.beginDirectoryLoad(allocator, "/", null);

    try std.testing.expectEqualStrings("/", spec.target_dir);
    try std.testing.expectEqual(@as(usize, 1), spec.generation);
    try std.testing.expectEqualStrings("home", spec.preselect_child.?);
    try std.testing.expect(!spec.needs_child_resolve);
    try std.testing.expectEqualStrings("/", palette.current_nav_dir.items);
    try std.testing.expectEqualStrings("/", palette.last_nav_dir.items);
    try std.testing.expectEqualStrings("home", palette.last_child_dir.items);
}

test "beginDirectoryLoad normalizes paths, aliases, and signals dot resolve" {
    const allocator = std.testing.allocator;

    var palette = try PaletteState.init(allocator);
    defer palette.deinit(allocator);

    palette.lifecycle = .{ .open = .directory_navigator };
    palette.current_dir_image_count = 9;
    palette.selected_idx = 3;
    try palette.matches.append(allocator, 0);

    // .cbz target normalizes to dirname and preserves explicit preselect_child
    const spec1 = try palette.beginDirectoryLoad(
        allocator,
        "/comics/vol1.cbz/",
        "vol1.cbz",
    );
    try std.testing.expectEqualStrings("/comics", spec1.target_dir);
    try std.testing.expectEqual(@as(usize, 1), spec1.generation);
    try std.testing.expectEqualStrings("vol1.cbz", spec1.preselect_child.?);
    try std.testing.expect(!spec1.needs_child_resolve);
    try std.testing.expectEqual(@as(usize, 0), palette.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), palette.current_dir_image_count);
    try std.testing.expectEqual(@as(usize, 0), palette.selected_idx);
    try std.testing.expect(palette.selection_dirty);

    // Reloading using an alias into palette.last_nav_dir.items succeeds
    const spec2 = try palette.beginDirectoryLoad(
        allocator,
        palette.last_nav_dir.items,
        null,
    );
    try std.testing.expectEqualStrings("/comics", spec2.target_dir);
    try std.testing.expectEqual(@as(usize, 2), spec2.generation);
    try std.testing.expect(spec2.preselect_child == null);
    try std.testing.expectEqual(
        @as(usize, 0),
        palette.last_child_dir.items.len,
    );

    // Upward step from "." requests off-thread child basename resolution
    palette.current_nav_dir.clearRetainingCapacity();
    try palette.current_nav_dir.appendSlice(allocator, ".");
    const spec3 = try palette.beginDirectoryLoad(allocator, "..", null);
    try std.testing.expectEqualStrings("..", spec3.target_dir);
    try std.testing.expectEqual(@as(usize, 3), spec3.generation);
    try std.testing.expect(spec3.needs_child_resolve);
    try std.testing.expect(spec3.preselect_child == null);

    // beginClose increments dir_scan_generation to cancel active workers
    palette.beginClose();
    try std.testing.expectEqual(
        @as(usize, 4),
        palette.dir_scan_generation.load(.acquire),
    );
}

test "applyLoadedDirectory transfers arena in O(1) and updates preselect" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "alpha_dir");
    try tmp.dir.createDirPath(io, "beta_dir");
    var f = try tmp.dir.createFile(io, "photo.png", .{});
    f.close(io);

    var path_buf: [128]u8 = undefined;
    const tmp_dir = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var palette = try PaletteState.init(allocator);
    defer palette.deinit(allocator);
    palette.lifecycle = .{ .open = .directory_navigator };
    _ = try palette.beginDirectoryLoad(allocator, tmp_dir, null);

    var worker_arena = std.heap.ArenaAllocator.init(allocator);
    defer worker_arena.deinit();
    var worker_items: std.ArrayList(DirectoryEntry) = .empty;
    const img_count = try vfs.scanDirectoryEntries(
        worker_arena.allocator(),
        io,
        tmp_dir,
        &worker_items,
    );
    const resolved_dir = try worker_arena.allocator().dupe(u8, tmp_dir);
    const preselect = try worker_arena.allocator().dupe(u8, "beta_dir");

    palette.selection_dirty = false;
    try palette.applyLoadedDirectory(
        allocator,
        resolved_dir,
        &worker_arena,
        &worker_items,
        img_count,
        preselect,
    );

    try std.testing.expectEqual(@as(usize, 0), worker_arena.queryCapacity());
    try std.testing.expectEqual(@as(usize, 0), worker_items.items.len);
    try std.testing.expectEqual(@as(usize, 2), palette.dir_items.items.len);
    try std.testing.expectEqual(@as(usize, 1), palette.current_dir_image_count);
    try std.testing.expectEqual(@as(usize, 1), palette.selected_idx);
    try std.testing.expectEqualStrings(
        "beta_dir",
        palette.last_child_dir.items,
    );
    try std.testing.expect(palette.selection_dirty);

    // Passing null preselect_child preserves existing last_child_dir
    var empty_arena = std.heap.ArenaAllocator.init(allocator);
    defer empty_arena.deinit();
    var empty_items: std.ArrayList(DirectoryEntry) = .empty;
    const same_dir = try empty_arena.allocator().dupe(u8, tmp_dir);
    try palette.applyLoadedDirectory(
        allocator,
        same_dir,
        &empty_arena,
        &empty_items,
        0,
        null,
    );
    try std.testing.expectEqualStrings(
        "beta_dir",
        palette.last_child_dir.items,
    );
}

test "beginDirectoryLoad and applyLoadedDirectory handle subslice aliasing" {
    const alloc = std.testing.allocator;
    var p = try PaletteState.init(alloc);
    defer p.deinit(alloc);

    // 1. Direct assignSliceOverlapSafe coverage (prefix, interior, empty)
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "0123456789abcdef");
    PaletteState.assignSliceOverlapSafe(&buf, buf.items[6..14]);
    try std.testing.expectEqualStrings("6789abcd", buf.items);
    PaletteState.assignSliceOverlapSafe(&buf, buf.items[0..4]);
    try std.testing.expectEqualStrings("6789", buf.items);
    PaletteState.assignSliceOverlapSafe(&buf, "");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);

    // 2. beginDirectoryLoad with subslice of last_child_dir and current_nav_dir
    try p.current_nav_dir.appendSlice(alloc, "/root/parent/child");
    try p.last_nav_dir.appendSlice(alloc, "/root/parent/child");
    try p.last_child_dir.appendSlice(alloc, "child_dir");

    const spec = try p.beginDirectoryLoad(
        alloc,
        p.current_nav_dir.items[0..12],
        p.last_child_dir.items[0..5],
    );
    try std.testing.expectEqualStrings("/root/parent", spec.target_dir);
    try std.testing.expectEqualStrings("child", spec.preselect_child.?);
    try std.testing.expectEqualStrings("/root/parent", p.current_nav_dir.items);
    try std.testing.expectEqualStrings("/root/parent", p.last_nav_dir.items);
    try std.testing.expectEqualStrings("child", p.last_child_dir.items);

    // 3. applyLoadedDirectory with subslices of current_nav_dir, last_nav_dir,
    //    and last_child_dir (including non-prefix subslices)
    const cases = [_]struct {
        seed_cur: []const u8,
        seed_last: []const u8,
        seed_child: []const u8,
        dir_src: enum { cur_prefix, cur_tail, last_prefix },
    }{
        .{
            .seed_cur = "/root/parent/child",
            .seed_last = "/other/path",
            .seed_child = "child_dir",
            .dir_src = .cur_prefix,
        },
        .{
            .seed_cur = "/root/parent/child",
            .seed_last = "/other/path",
            .seed_child = "child_dir",
            .dir_src = .cur_tail,
        },
        .{
            .seed_cur = "/other/path",
            .seed_last = "/root/parent/child",
            .seed_child = "child_dir",
            .dir_src = .last_prefix,
        },
    };

    for (cases) |tc| {
        p.current_nav_dir.clearRetainingCapacity();
        try p.current_nav_dir.appendSlice(alloc, tc.seed_cur);
        p.last_nav_dir.clearRetainingCapacity();
        try p.last_nav_dir.appendSlice(alloc, tc.seed_last);
        p.last_child_dir.clearRetainingCapacity();
        try p.last_child_dir.appendSlice(alloc, tc.seed_child);

        var w_arena = std.heap.ArenaAllocator.init(alloc);
        defer w_arena.deinit();
        var w_items: std.ArrayList(DirectoryEntry) = .empty;

        const dir_arg: []const u8 = switch (tc.dir_src) {
            .cur_prefix => p.current_nav_dir.items[0..12],
            .cur_tail => p.current_nav_dir.items[6..18],
            .last_prefix => p.last_nav_dir.items[0..12],
        };
        const exp_dir: []const u8 = switch (tc.dir_src) {
            .cur_prefix, .last_prefix => "/root/parent",
            .cur_tail => "parent/child",
        };
        try p.applyLoadedDirectory(
            alloc,
            dir_arg,
            &w_arena,
            &w_items,
            0,
            p.last_child_dir.items[0..5],
        );
        try std.testing.expectEqualStrings(exp_dir, p.current_nav_dir.items);
        try std.testing.expectEqualStrings(exp_dir, p.last_nav_dir.items);
        try std.testing.expectEqualStrings("child", p.last_child_dir.items);
    }
}

test "PaletteState directory_navigator mode configuration and item matching" {
    const alloc = std.testing.allocator;
    var palette = try PaletteState.init(alloc);
    defer palette.deinit(alloc);

    palette.lifecycle = .{ .open = .directory_navigator };
    try palette.current_nav_dir.appendSlice(alloc, "/home/user/Pictures");

    const dir_alloc = palette.dir_arena.allocator();
    try palette.dir_items.append(dir_alloc, .{
        .parent = .{
            .name = try dir_alloc.dupe(u8, ".."),
            .full_path = try dir_alloc.dupe(u8, "/home/user"),
        },
    });
    try palette.dir_items.append(dir_alloc, .{
        .directory = .{
            .name = try dir_alloc.dupe(u8, "Vacation"),
            .full_path = try dir_alloc.dupe(
                u8,
                "/home/user/Pictures/Vacation",
            ),
            .scan = .{ .scanned = .{ .image_count = 12 } },
        },
    });

    try palette.rebuildDirectoryMatches(alloc);
    try std.testing.expectEqual(@as(usize, 2), palette.matches.items.len);

    try palette.query.appendSlice(alloc, "Vac");
    try palette.rebuildDirectoryMatches(alloc);
    try std.testing.expectEqual(@as(usize, 1), palette.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), palette.matches.items[0]);
}

test "getPaletteConfig metadata lookup helper" {
    const files_cfg = getPaletteConfig(.files);
    try std.testing.expectEqualStrings("Search Files", files_cfg.title);
    try std.testing.expectEqualStrings(
        "Type file name to search...",
        files_cfg.placeholder,
    );

    const actions_cfg = getPaletteConfig(.actions);
    try std.testing.expectEqualStrings("Command Palette", actions_cfg.title);
    try std.testing.expectEqualStrings(
        "Type a command to run...",
        actions_cfg.placeholder,
    );

    const bright_cfg = getPaletteConfig(.{
        .prompt = .{ .edit_param = .brightness },
    });
    try std.testing.expectEqualStrings("Set Brightness", bright_cfg.title);

    const contrast_cfg = getPaletteConfig(.{
        .prompt = .{ .edit_param = .contrast },
    });
    try std.testing.expectEqualStrings("Set Contrast", contrast_cfg.title);

    const goto_cfg = getPaletteConfig(.{ .prompt = .go_to_image });
    try std.testing.expectEqualStrings("Go to Image", goto_cfg.title);

    const dir_cfg = getPaletteConfig(.directory_navigator);
    try std.testing.expectEqualStrings("Directory Navigator", dir_cfg.title);

    const slide_cfg = getPaletteConfig(.{ .prompt = .slideshow_interval });
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
    defer pal_state.deinit(alloc);
    pal_state.lifecycle = .{ .open = .directory_navigator };

    const dir_alloc = pal_state.dir_arena.allocator();
    const long_name: [96]u8 = @splat('a');
    try pal_state.dir_items.append(dir_alloc, .{
        .directory = .{
            .name = try dir_alloc.dupe(u8, "short"),
            .full_path = try dir_alloc.dupe(u8, "/tmp/short"),
            .scan = .unscanned,
        },
    });
    try pal_state.dir_items.append(dir_alloc, .{
        .directory = .{
            .name = try dir_alloc.dupe(u8, &long_name),
            .full_path = try dir_alloc.dupe(u8, "/tmp/" ++ long_name),
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

test "remapMiddleTruncatedMatches head, tail, and truncated middle" {
    const matches = [_]usize{ 2, 5, 20, 25, 60, 61 };
    const head_len: usize = 10;
    const tail_start_idx: usize = 50;

    const remapped = try remapMiddleTruncatedMatches(
        std.testing.allocator,
        &matches,
        head_len,
        tail_start_idx,
    );
    defer std.testing.allocator.free(remapped);

    // 2 < 10 -> 2
    // 5 < 10 -> 5
    // 20 and 25 are in [10, 50) -> dropped
    // 60 >= 50 -> (60 - 50) + 10 + 3 = 23
    // 61 >= 50 -> (61 - 50) + 10 + 3 = 24
    try std.testing.expectEqualSlices(
        usize,
        &[_]usize{ 2, 5, 23, 24 },
        remapped,
    );
}

test "remapMiddleTruncatedMatches clamps overlapping tail_start_idx" {
    const matches = [_]usize{ 3, 7, 12 };
    const head_len: usize = 10;
    const tail_start_idx: usize = 5; // tail_start_idx < head_len

    const remapped = try remapMiddleTruncatedMatches(
        std.testing.allocator,
        &matches,
        head_len,
        tail_start_idx,
    );
    defer std.testing.allocator.free(remapped);

    // actual_tail_start becomes max(5, 10) = 10
    // 3 < 10 -> 3
    // 7 < 10 -> 7
    // 12 >= 10 -> (12 - 10) + 10 + 3 = 15
    try std.testing.expectEqualSlices(usize, &[_]usize{ 3, 7, 15 }, remapped);
}

test "partitionHighlightedText partitions matched and unmatched chunks" {
    // Scenario 1: Query "sc" matching "Set Contrast" (indices 0 and 4)
    const text1 = "Set Contrast";
    const matches1 = [_]usize{ 0, 4 };

    const chunks1 = try partitionHighlightedText(
        std.testing.allocator,
        text1,
        &matches1,
    );
    defer std.testing.allocator.free(chunks1);

    try std.testing.expectEqual(@as(usize, 4), chunks1.len);
    try std.testing.expectEqualStrings("S", chunks1[0].slice);
    try std.testing.expect(chunks1[0].is_matched);
    try std.testing.expectEqualStrings("et ", chunks1[1].slice);
    try std.testing.expect(!chunks1[1].is_matched);
    try std.testing.expectEqualStrings("C", chunks1[2].slice);
    try std.testing.expect(chunks1[2].is_matched);
    try std.testing.expectEqualStrings("ontrast", chunks1[3].slice);
    try std.testing.expect(!chunks1[3].is_matched);
}

test "partitionHighlightedText merges isolated whitespace matches" {
    // Scenario 2: Query "sc " matching "Set Contrast (Type Value)..."
    // (indices 0, 4, and 12)
    const text2 = "Set Contrast (Type Value)...";
    const matches2 = [_]usize{ 0, 4, 12 };

    const chunks2 = try partitionHighlightedText(
        std.testing.allocator,
        text2,
        &matches2,
    );
    defer std.testing.allocator.free(chunks2);

    try std.testing.expectEqual(@as(usize, 4), chunks2.len);
    try std.testing.expectEqualStrings("S", chunks2[0].slice);
    try std.testing.expect(chunks2[0].is_matched);
    try std.testing.expectEqualStrings("et ", chunks2[1].slice);
    try std.testing.expect(!chunks2[1].is_matched);
    try std.testing.expectEqualStrings("C", chunks2[2].slice);
    try std.testing.expect(chunks2[2].is_matched);
    try std.testing.expectEqualStrings(
        "ontrast (Type Value)...",
        chunks2[3].slice,
    );
    try std.testing.expect(!chunks2[3].is_matched);
}

test "partitionHighlightedText edge cases" {
    // Empty text
    const empty_chunks = try partitionHighlightedText(
        std.testing.allocator,
        "",
        &[_]usize{0},
    );
    try std.testing.expectEqual(@as(usize, 0), empty_chunks.len);

    // Empty matches
    const no_match_chunks = try partitionHighlightedText(
        std.testing.allocator,
        "text",
        &[_]usize{},
    );
    defer std.testing.allocator.free(no_match_chunks);
    try std.testing.expectEqual(@as(usize, 1), no_match_chunks.len);
    try std.testing.expectEqualStrings("text", no_match_chunks[0].slice);
    try std.testing.expect(!no_match_chunks[0].is_matched);

    // Out-of-bounds matches (should be ignored gracefully)
    const oob_chunks = blk: {
        const prev_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = prev_level;
        break :blk try partitionHighlightedText(
            std.testing.allocator,
            "abc",
            &[_]usize{ 0, 5, 10 },
        );
    };
    defer std.testing.allocator.free(oob_chunks);
    try std.testing.expectEqual(@as(usize, 2), oob_chunks.len);
    try std.testing.expectEqualStrings("a", oob_chunks[0].slice);
    try std.testing.expect(oob_chunks[0].is_matched);
    try std.testing.expectEqualStrings("bc", oob_chunks[1].slice);
    try std.testing.expect(!oob_chunks[1].is_matched);

    // Internal whitespace should NOT be stripped
    const internal_ws_chunks = try partitionHighlightedText(
        std.testing.allocator,
        "a  b",
        &[_]usize{ 0, 1, 2, 3 },
    );
    defer std.testing.allocator.free(internal_ws_chunks);
    try std.testing.expectEqual(@as(usize, 1), internal_ws_chunks.len);
    try std.testing.expectEqualStrings("a  b", internal_ws_chunks[0].slice);
    try std.testing.expect(internal_ws_chunks[0].is_matched);

    // Leading and trailing whitespace should be stripped
    const edge_ws_chunks = try partitionHighlightedText(
        std.testing.allocator,
        " a ",
        &[_]usize{ 0, 1, 2 },
    );
    defer std.testing.allocator.free(edge_ws_chunks);
    try std.testing.expectEqual(@as(usize, 3), edge_ws_chunks.len);
    try std.testing.expectEqualStrings(" ", edge_ws_chunks[0].slice);
    try std.testing.expect(!edge_ws_chunks[0].is_matched);
    try std.testing.expectEqualStrings("a", edge_ws_chunks[1].slice);
    try std.testing.expect(edge_ws_chunks[1].is_matched);
    try std.testing.expectEqualStrings(" ", edge_ws_chunks[2].slice);
    try std.testing.expect(!edge_ws_chunks[2].is_matched);
}

test "partitionHighlightedText with middle-truncated remapped matches" {
    const long_text =
        "DSC_2026_Yosemite_National_Park_High_Resolution_Sunset_Panorama" ++
        "_HDR_Final.jpg";
    // Suppose head_len = 25 ("DSC_2026_Yosemite_National")
    // tail_start_idx = 50 ("Sunset_Panorama_HDR_Final.jpg")
    const head_len: usize = 25;
    const tail_start_idx: usize = 50;
    const display = try std.testing.allocator.print(
        "{s}...{s}",
        .{ long_text[0..head_len], long_text[tail_start_idx..] },
    );
    defer std.testing.allocator.free(display);

    // Matches at index 2 ('C' in DSC), index 57 ('P' in Panorama)
    const matches = [_]usize{ 2, 57 };
    const remapped = try remapMiddleTruncatedMatches(
        std.testing.allocator,
        &matches,
        head_len,
        tail_start_idx,
    );
    defer std.testing.allocator.free(remapped);

    // remapped should be index 2 and (57 - 50) + 25 + 3 = 35
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 35 }, remapped);

    const chunks = try partitionHighlightedText(
        std.testing.allocator,
        display,
        remapped,
    );
    defer std.testing.allocator.free(chunks);

    try std.testing.expect(chunks.len > 0);
    // Ensure all matches lie within display bounds without warning
    for (remapped) |m_idx| {
        try std.testing.expect(m_idx < display.len);
    }
}

test "partitionHighlightedText multi-byte UTF-8 character boundary safety" {
    // "café" -> 'c' (0), 'a' (1), 'f' (2), 'é' (3..4: 0xC3 0xA9)
    const utf8_text = "café_au_lait.jpg";
    // Match index 3 points to start of 'é' (0xC3)
    const matches = [_]usize{3};

    const chunks = try partitionHighlightedText(
        std.testing.allocator,
        utf8_text,
        &matches,
    );
    defer std.testing.allocator.free(chunks);

    // Chunks should be: "caf" (unmatched), "é" (matched, full 2-byte UTF-8
    // code point), "_au_lait.jpg" (unmatched)
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqualStrings("caf", chunks[0].slice);
    try std.testing.expect(!chunks[0].is_matched);
    try std.testing.expectEqualStrings("é", chunks[1].slice);
    try std.testing.expect(chunks[1].is_matched);
    try std.testing.expectEqualStrings("_au_lait.jpg", chunks[2].slice);
    try std.testing.expect(!chunks[2].is_matched);

    // Contiguous match across multi-byte 'é' (bytes 3, 4), space (5), and 'l'
    // (6) in "café lait.jpg" should keep internal space inside matched span.
    const spaced_utf8 = "café lait.jpg";
    const span_matches = [_]usize{ 3, 4, 5, 6 };
    const span_chunks = try partitionHighlightedText(
        std.testing.allocator,
        spaced_utf8,
        &span_matches,
    );
    defer std.testing.allocator.free(span_chunks);
    try std.testing.expectEqual(@as(usize, 3), span_chunks.len);
    try std.testing.expectEqualStrings("caf", span_chunks[0].slice);
    try std.testing.expect(!span_chunks[0].is_matched);
    try std.testing.expectEqualStrings("é l", span_chunks[1].slice);
    try std.testing.expect(span_chunks[1].is_matched);
    try std.testing.expectEqualStrings("ait.jpg", span_chunks[2].slice);
    try std.testing.expect(!span_chunks[2].is_matched);
}

test "VirtualWindow compute calculations and edge cases" {
    const item_height: f32 = 50.0;
    const viewport_h: f32 = 320.0;
    const gap: f32 = 4.0;

    // Case 1: Empty list
    const w0 = VirtualWindow.compute(0, 0.0, viewport_h, item_height, gap);
    try std.testing.expectEqual(@as(usize, 0), w0.start_idx);
    try std.testing.expectEqual(@as(usize, 0), w0.end_idx);
    try std.testing.expectEqual(@as(f32, 0.0), w0.top_spacer_h);
    try std.testing.expectEqual(@as(f32, 0.0), w0.bottom_spacer_h);

    // Case 2: At top of 100-item list (scroll = 0)
    // visible top = 0, visible bottom = 320.
    // floor(0/50) = 0, ceil(320/50) = 7.
    // overscan: start = 0, end = 8.
    const w1 = VirtualWindow.compute(100, 0.0, viewport_h, item_height, gap);
    try std.testing.expectEqual(@as(usize, 0), w1.start_idx);
    try std.testing.expectEqual(@as(usize, 8), w1.end_idx);
    try std.testing.expectEqual(@as(f32, 0.0), w1.top_spacer_h);
    // bottom spacer = (100 - 8) * 50 - 4 = 4600 - 4 = 4596
    try std.testing.expectEqual(@as(f32, 4596.0), w1.bottom_spacer_h);

    // Case 3: Middle of list (scroll = -500.0, 10 items scrolled off-screen)
    // visible top = 500, visible bottom = 820.
    // floor(500/50) = 10, ceil(820/50) = 17.
    // overscan: start = 9, end = 18.
    const w2 = VirtualWindow.compute(
        100,
        -500.0,
        viewport_h,
        item_height,
        gap,
    );
    try std.testing.expectEqual(@as(usize, 9), w2.start_idx);
    try std.testing.expectEqual(@as(usize, 18), w2.end_idx);
    // top spacer = 9 * 50 - 4 = 446.0
    try std.testing.expectEqual(@as(f32, 446.0), w2.top_spacer_h);
    // bottom spacer = (100 - 18) * 50 - 4 = 82 * 50 - 4 = 4096.0
    try std.testing.expectEqual(@as(f32, 4096.0), w2.bottom_spacer_h);
}

test "PaletteState - selection navigation and paging" {
    const alloc = std.testing.allocator;
    var state = try PaletteState.init(alloc);
    defer state.deinit(alloc);

    // With 12 dummy matches:
    for (0..12) |i| {
        try state.matches.append(alloc, i);
    }

    try std.testing.expectEqual(@as(usize, 0), state.selected_idx);

    // moveSelectionUp at top does nothing
    state.selection_dirty = false;
    state.moveSelectionUp();
    try std.testing.expectEqual(@as(usize, 0), state.selected_idx);
    try std.testing.expect(!state.selection_dirty);

    // moveSelectionDown increments
    state.moveSelectionDown();
    try std.testing.expectEqual(@as(usize, 1), state.selected_idx);
    try std.testing.expect(state.selection_dirty);

    // pageSelectionDown moves by 5
    state.pageSelectionDown();
    try std.testing.expectEqual(@as(usize, 6), state.selected_idx);

    // pageSelectionDown again moves by 5
    state.pageSelectionDown();
    try std.testing.expectEqual(@as(usize, 11), state.selected_idx);

    // pageSelectionDown clamps to max matches.len - 1 (11)
    state.pageSelectionDown();
    try std.testing.expectEqual(@as(usize, 11), state.selected_idx);

    // moveSelectionDown at end does nothing
    state.selection_dirty = false;
    state.moveSelectionDown();
    try std.testing.expectEqual(@as(usize, 11), state.selected_idx);
    try std.testing.expect(!state.selection_dirty);

    // pageSelectionUp moves backward by 5
    state.pageSelectionUp();
    try std.testing.expectEqual(@as(usize, 6), state.selected_idx);
    try std.testing.expect(state.selection_dirty);

    // pageSelectionUp again moves to 1
    state.pageSelectionUp();
    try std.testing.expectEqual(@as(usize, 1), state.selected_idx);

    // pageSelectionUp clamps to 0
    state.pageSelectionUp();
    try std.testing.expectEqual(@as(usize, 0), state.selected_idx);

    // moveSelectionUp at top does nothing
    state.selection_dirty = false;
    state.moveSelectionUp();
    try std.testing.expectEqual(@as(usize, 0), state.selected_idx);
    try std.testing.expect(!state.selection_dirty);
}

test "PaletteState - query editing operations and UTF-8 backspace" {
    const alloc = std.testing.allocator;
    var state = try PaletteState.init(alloc);
    defer state.deinit(alloc);
    state.lifecycle = .{ .open = .files };

    const entries = [_]MediaEntry{
        .{ .filesystem = .{ .path = "/photos/forest.png" } },
        .{ .filesystem = .{ .path = "/photos/beach.jpg" } },
        .{ .filesystem = .{ .path = "/photos/mountain.jpg" } },
    };

    // 1. appendPrintableText appends valid characters and rebuilds matches
    const appended = try state.appendPrintableText(alloc, "fore", &entries);
    try std.testing.expect(appended);
    try std.testing.expectEqualStrings("fore", state.query.items);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items.len);

    // Non-printable bytes return false and do not mutate query
    const non_printable = [_]u8{ 0x01, 0x1F, 0x7F };
    try std.testing.expect(
        !(try state.appendPrintableText(alloc, &non_printable, &entries)),
    );
    try std.testing.expectEqualStrings("fore", state.query.items);

    // 2. clearQuery resets query and rebuilds matches
    const cleared = try state.clearQuery(alloc, &entries);
    try std.testing.expect(cleared);
    try std.testing.expectEqual(@as(usize, 0), state.query.items.len);
    try std.testing.expectEqual(@as(usize, 3), state.matches.items.len);

    // clearQuery on empty returns false
    try std.testing.expect(!(try state.clearQuery(alloc, &entries)));

    // 3. deleteCharBackward handles multi-byte UTF-8
    _ = try state.appendPrintableText(alloc, "café", &entries);
    try std.testing.expectEqualStrings("café", state.query.items);
    // 'é' is 2 bytes (0xC3, 0xA9)
    try std.testing.expectEqual(@as(usize, 5), state.query.items.len);

    const char_deleted = try state.deleteCharBackward(alloc, &entries);
    try std.testing.expect(char_deleted);
    try std.testing.expectEqualStrings("caf", state.query.items);
    try std.testing.expectEqual(@as(usize, 3), state.query.items.len);

    // 4. deleteWordBackward removes trailing whitespace and words
    _ = try state.clearQuery(alloc, &entries);
    _ = try state.appendPrintableText(alloc, "path/to file   ", &entries);
    try std.testing.expectEqualStrings("path/to file   ", state.query.items);

    const word_deleted = try state.deleteWordBackward(alloc, &entries);
    try std.testing.expect(word_deleted);
    try std.testing.expectEqualStrings("path/to ", state.query.items);

    _ = try state.deleteWordBackward(alloc, &entries);
    try std.testing.expectEqualStrings("path/", state.query.items);

    // Calling deleteWordBackward on delimiter boundary returns false
    try std.testing.expect(
        !(try state.deleteWordBackward(alloc, &entries)),
    );
    try std.testing.expectEqualStrings("path/", state.query.items);

    _ = try state.clearQuery(alloc, &entries);
    try std.testing.expect(
        !(try state.deleteWordBackward(alloc, &entries)),
    );
    try std.testing.expect(
        !(try state.deleteCharBackward(alloc, &entries)),
    );
}

test "PaletteState - applyFolderScan updates matching directory entry" {
    const alloc = std.testing.allocator;
    var state = try PaletteState.init(alloc);
    defer state.deinit(alloc);

    const dir_alloc = state.dir_arena.allocator();
    try state.dir_items.append(dir_alloc, .{
        .directory = .{
            .name = try dir_alloc.dupe(u8, "photos"),
            .full_path = try dir_alloc.dupe(u8, "/media/photos"),
            .scan = .unscanned,
        },
    });
    try state.dir_items.append(dir_alloc, .{
        .archive_file = .{
            .name = try dir_alloc.dupe(u8, "archive.cbz"),
            .full_path = try dir_alloc.dupe(u8, "/media/archive.cbz"),
            .scan = .unscanned,
        },
    });

    state.selection_dirty = false;
    const applied = state.applyFolderScan(
        "/media/photos",
        .permission_denied,
    );
    try std.testing.expect(applied);
    try std.testing.expect(state.selection_dirty);
    try std.testing.expectEqual(
        EntryScanState.permission_denied,
        state.dir_items.items[0].directory.scan,
    );

    // Archive file scan update
    const archive_applied = state.applyFolderScan(
        "/media/archive.cbz",
        .failed,
    );
    try std.testing.expect(archive_applied);
    try std.testing.expectEqual(
        EntryScanState.failed,
        state.dir_items.items[1].archive_file.scan,
    );

    // Non-existent path returns false
    const non_existent = state.applyFolderScan(
        "/media/missing",
        .failed,
    );
    try std.testing.expect(!non_existent);
}

fn referenceBestScore(
    searcher: *fuzzig.Ascii,
    item: MediaEntry,
    query: []const u8,
) ?i32 {
    var best = searcher.score(item.getBasename(), query);
    if (item.getJpegPath()) |jpeg_p| {
        const jpeg_base = std.Io.Dir.path.basename(jpeg_p);
        if (searcher.score(jpeg_base, query)) |js| {
            best = if (best) |s| @max(s, js) else js;
        }
    }
    if (item.isPair()) {
        if (searcher.score("RAW+JPG", query)) |ts| {
            best = if (best) |s| @max(s, ts) else ts;
        }
    }
    return best;
}

test "PaletteState.rebuildFileMatches single-pass score parity and growth" {
    const alloc = std.testing.allocator;
    var state = try PaletteState.init(alloc);
    defer state.deinit(alloc);

    const s_a: [90]u8 = @splat('a');
    const s_b: [250]u8 = @splat('b');
    const s_c: [310]u8 = @splat('c');
    const long_single = "/d/" ++ s_a ++ "_alpha.png";
    const long_raw = "/d/" ++ s_b ++ "_alpha.ARW";
    const long_jpg = "/d/" ++ s_c ++ "_beta.JPG";
    const entries = [_]MediaEntry{
        .{ .filesystem = .{ .path = "/d/short_alpha.png" } },
        .{ .filesystem = .{ .path = long_single } },
        .{
            .pair = .{
                .raw_path = long_raw,
                .jpeg_path = long_jpg,
            },
        },
        .{
            .pair = .{
                .raw_path = "/d/other.ARW",
                .jpeg_path = "/d/other.JPG",
            },
        },
    };

    // Empty query and empty entry list must not allocate searcher
    try state.rebuildFileMatches(alloc, &entries);
    try std.testing.expect(state.searcher == null);
    try std.testing.expectEqual(@as(usize, 4), state.matches.items.len);

    try state.query.appendSlice(alloc, "alpha");
    try state.rebuildFileMatches(alloc, &.{});
    try std.testing.expect(state.searcher == null);
    try std.testing.expectEqual(@as(usize, 0), state.matches.items.len);

    var ref = try fuzzig.Ascii.init(
        alloc,
        320,
        16,
        .{ .case_sensitive = false },
    );
    defer ref.deinit();

    const queries = [_][]const u8{ "alpha", "beta", "RAW+JPG" };
    for (queries) |q| {
        state.query.clearRetainingCapacity();
        try state.query.appendSlice(alloc, q);
        try state.rebuildFileMatches(alloc, &entries);

        var expected: std.ArrayList(ScoredMatch) = .empty;
        defer expected.deinit(alloc);
        for (entries, 0..) |item, idx| {
            if (referenceBestScore(&ref, item, q)) |sc| {
                try expected.append(alloc, .{ .index = idx, .score = sc });
            }
        }
        std.mem.sort(ScoredMatch, expected.items, {}, struct {
            fn lessThan(_: void, a: ScoredMatch, b: ScoredMatch) bool {
                return a.score > b.score;
            }
        }.lessThan);

        try std.testing.expectEqual(
            expected.items.len,
            state.scored_matches.items.len,
        );
        for (expected.items, state.scored_matches.items) |exp, got| {
            try std.testing.expectEqual(exp.index, got.index);
            try std.testing.expectEqual(exp.score, got.score);
        }
    }
    const expected_max = std.Io.Dir.path.basename(long_jpg).len;
    try std.testing.expectEqual(expected_max, state.max_haystack_len);
    try std.testing.expect(
        state.searcher.?.alg.max_haystack >= expected_max,
    );
}

test "PaletteState.rebuildDirectoryMatches single-pass parity and growth" {
    const alloc = std.testing.allocator;
    var state = try PaletteState.init(alloc);
    defer state.deinit(alloc);

    // Empty dir_items with non-empty query must not allocate searcher
    try state.query.appendSlice(alloc, "alpha");
    try state.rebuildDirectoryMatches(alloc);
    try std.testing.expect(state.searcher == null);
    try std.testing.expectEqual(@as(usize, 0), state.matches.items.len);

    const dir_alloc = state.dir_arena.allocator();
    const s_x: [90]u8 = @splat('x');
    const s_y: [260]u8 = @splat('y');
    const names = [_][]const u8{
        "dir_alpha",
        s_x ++ "_alpha",
        s_y ++ "_alpha",
        "unrelated",
    };
    for (names) |name| {
        try state.dir_items.append(dir_alloc, .{
            .directory = .{
                .name = try dir_alloc.dupe(u8, name),
                .full_path = try dir_alloc.dupe(u8, name),
                .scan = .unscanned,
            },
        });
    }

    try state.rebuildDirectoryMatches(alloc);
    try std.testing.expectEqual(@as(usize, 266), state.max_haystack_len);

    var ref = try fuzzig.Ascii.init(
        alloc,
        266,
        16,
        .{ .case_sensitive = false },
    );
    defer ref.deinit();

    var expected: std.ArrayList(ScoredMatch) = .empty;
    defer expected.deinit(alloc);
    for (names, 0..) |name, idx| {
        if (ref.score(name, "alpha")) |sc| {
            try expected.append(alloc, .{ .index = idx, .score = sc });
        }
    }
    std.mem.sort(ScoredMatch, expected.items, {}, struct {
        fn lessThan(_: void, a: ScoredMatch, b: ScoredMatch) bool {
            return a.score > b.score;
        }
    }.lessThan);

    try std.testing.expectEqual(
        expected.items.len,
        state.scored_matches.items.len,
    );
    for (expected.items, state.scored_matches.items) |exp, got| {
        try std.testing.expectEqual(exp.index, got.index);
        try std.testing.expectEqual(exp.score, got.score);
    }
}

test "PaletteState.clearDirItems bounds arena and shrink frees all" {
    const alloc = std.testing.allocator;
    var state = try PaletteState.init(alloc);
    defer state.deinit(alloc);

    // PaletteState.init does not allocate dir_items on gpa.
    try std.testing.expectEqual(@as(usize, 0), state.dir_items.capacity);
    try std.testing.expectEqual(@as(usize, 0), state.dir_arena.queryCapacity());

    const dir_alloc = state.dir_arena.allocator();
    for (0..16) |_| {
        _ = try dir_alloc.alloc(u8, 16 * 1024);
    }
    try state.dir_items.append(dir_alloc, .{
        .directory = .{
            .name = try dir_alloc.dupe(u8, "folder"),
            .full_path = try dir_alloc.dupe(u8, "/tmp/folder"),
            .scan = .unscanned,
        },
    });
    try std.testing.expect(
        state.dir_arena.queryCapacity() > MAX_RETAINED_DIR_ARENA_BYTES,
    );

    state.clearDirItems();
    try std.testing.expectEqual(@as(usize, 0), state.dir_items.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.dir_items.capacity);
    try std.testing.expect(
        state.dir_arena.queryCapacity() <= MAX_RETAINED_DIR_ARENA_BYTES,
    );

    state.shrinkToWarmCapacity(alloc);
    try std.testing.expectEqual(@as(usize, 0), state.dir_items.capacity);
    try std.testing.expectEqual(@as(usize, 0), state.dir_arena.queryCapacity());
}

fn testPaletteInitOom(allocator: std.mem.Allocator) !void {
    var state = try PaletteState.init(allocator);
    state.deinit(allocator);
}

test "PaletteState OOM safety on init, rebuildFileMatches, and loadDir" {
    const base_alloc = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(
        base_alloc,
        testPaletteInitOom,
        .{},
    );

    // Mid-loop searcher growth OOM preserves max_haystack_len invariant
    const s_z: [300]u8 = @splat('z');
    const long_name = "/d/" ++ s_z ++ ".png";
    const entries = [_]MediaEntry{
        .{ .filesystem = .{ .path = "/d/short.png" } },
        .{ .filesystem = .{ .path = long_name } },
    };

    var fail_idx: usize = 0;
    while (fail_idx < 32) : (fail_idx += 1) {
        var fa = std.testing.FailingAllocator.init(base_alloc, .{
            .fail_index = fail_idx,
        });
        const falloc = fa.allocator();
        var state = PaletteState.init(falloc) catch continue;
        defer state.deinit(falloc);
        state.query.appendSlice(falloc, "zzz") catch continue;
        _ = state.getSearcher(falloc, 64, 3) catch continue;

        if (state.rebuildFileMatches(falloc, &entries)) |_| {
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 64), state.max_haystack_len);
        }
    }

    // beginDirectoryLoad and applyLoadedDirectory rollback under
    // FailingAllocator
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dir_one");
    try tmp.dir.createDirPath(io, "dir_two");

    var path_buf: [128]u8 = undefined;
    const tmp_dir_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var long_buf: [161]u8 = @splat('a');
    long_buf[0] = '/';
    const long_dir = &long_buf;
    var dir_fail_idx: usize = 0;
    while (dir_fail_idx < 32) : (dir_fail_idx += 1) {
        var fa = std.testing.FailingAllocator.init(base_alloc, .{
            .fail_index = dir_fail_idx,
        });
        const falloc = fa.allocator();
        var state = PaletteState.init(falloc) catch continue;
        defer state.deinit(falloc);

        if (state.beginDirectoryLoad(falloc, long_dir, null)) |spec| {
            try std.testing.expectEqualStrings(long_dir, spec.target_dir);
            try std.testing.expectEqual(
                @as(usize, 0),
                state.dir_items.items.len,
            );
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(
                @as(usize, 0),
                state.dir_items.items.len,
            );
        }
    }

    var apply_fail_idx: usize = 0;
    while (apply_fail_idx < 48) : (apply_fail_idx += 1) {
        var fa = std.testing.FailingAllocator.init(base_alloc, .{
            .fail_index = apply_fail_idx,
        });
        const falloc = fa.allocator();
        var state = PaletteState.init(falloc) catch continue;
        defer state.deinit(falloc);
        state.query.appendSlice(falloc, "dir") catch continue;

        var worker_arena = std.heap.ArenaAllocator.init(base_alloc);
        defer worker_arena.deinit();
        var worker_items: std.ArrayList(DirectoryEntry) = .empty;
        const img_count = try vfs.scanDirectoryEntries(
            worker_arena.allocator(),
            io,
            tmp_dir_path,
            &worker_items,
        );
        const resolved = try worker_arena.allocator().dupe(u8, tmp_dir_path);

        if (state.applyLoadedDirectory(
            falloc,
            resolved,
            &worker_arena,
            &worker_items,
            img_count,
            null,
        )) |_| {
            try std.testing.expectEqual(
                @as(usize, 0),
                worker_arena.queryCapacity(),
            );
            try std.testing.expectEqual(
                @as(usize, 2),
                state.dir_items.items.len,
            );
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
