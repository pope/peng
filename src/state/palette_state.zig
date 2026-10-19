const fuzzig = @import("fuzzig");
const intents = @import("intents");
const std = @import("std");
const types = @import("types.zig");

const MediaEntry = types.MediaEntry;
const PaletteMode = intents.PaletteMode;
const TextInputBounds = intents.TextInputBounds;

/// Represents a search result item paired with its fuzzy matching score.
pub const ScoredMatch = struct {
    index: usize,
    score: i32,
};

/// Container holding image and subdirectory counts for a directory or archive entry.
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
            else => null,
        };
    }
};

/// Main state model for command palette modals, directory navigation, and fuzzy searching.
pub const PaletteState = struct {
    mode: PaletteMode = .inactive,
    is_closing: bool = false,
    query: std.ArrayListUnmanaged(u8) = .empty,
    selected_idx: usize = 0,
    matches: std.ArrayListUnmanaged(usize) = .empty,
    scored_matches: std.ArrayListUnmanaged(ScoredMatch) = .empty,
    selection_dirty: bool = false,
    current_nav_dir: std.ArrayListUnmanaged(u8) = .empty,
    last_nav_dir: std.ArrayListUnmanaged(u8) = .empty,
    last_child_dir: std.ArrayListUnmanaged(u8) = .empty,
    dir_items: std.ArrayListUnmanaged(DirectoryEntry) = .empty,
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
        // 64 items: initial filtered match index capacity before dynamic resizing
        try self.matches.ensureTotalCapacity(allocator, 64);
        // 64 items: initial fuzzy search score entry capacity
        try self.scored_matches.ensureTotalCapacity(allocator, 64);
        // 128 bytes: accommodates active directory path strings (most paths are < 128 bytes)
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

    /// Frees all dynamically allocated memory, string arrays, searcher state, and directory items.
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

    /// Releases heap strings owned by directory items and clears the list while retaining capacity.
    pub fn clearDirItems(self: *PaletteState) void {
        for (self.dir_items.items) |entry| {
            self.allocator.free(entry.getName());
            if (entry.getFullPath().len > 0) self.allocator.free(entry.getFullPath());
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
        self.dir_scan_generation.store(0, .release);
        self.mode = .inactive;
        self.is_closing = false;
        self.selected_idx = 0;
        self.selection_dirty = true;
    }

    /// Returns whether the palette is currently active and accepting user input (not closing).
    pub inline fn isAcceptingInput(self: *const PaletteState) bool {
        return self.mode != .inactive and !self.is_closing;
    }

    /// Returns a lazily initialized or resized ASCII fuzzy searcher matching
    /// the requested haystack and needle lengths.
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

    /// Rebuilds fuzzy match results for action palette items.
    ///
    /// Optimizations:
    /// - Short-circuits when query is empty, populating `matches` directly
    ///   without searcher allocation or fuzzy scoring.
    /// - Pre-allocates `scored_matches` and `matches` capacities to allow
    ///   `appendAssumeCapacity` writes during scoring.
    fn sortAndExtractMatches(self: *PaletteState) !void {
        std.mem.sort(ScoredMatch, self.scored_matches.items, {}, struct {
            fn lessThan(_: void, a: ScoredMatch, b: ScoredMatch) bool {
                return a.score > b.score;
            }
        }.lessThan);

        try self.matches.ensureTotalCapacity(self.allocator, self.scored_matches.items.len);
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
            try self.matches.ensureTotalCapacity(self.allocator, types.palette_action_items.len);
            for (types.palette_action_items, 0..) |_, idx| {
                self.matches.appendAssumeCapacity(idx);
            }
            return;
        }

        var max_h: usize = 0;
        for (types.palette_action_items) |item| {
            max_h = @max(max_h, item.name.len);
        }

        const searcher_ptr = try self.getSearcher(max_h, query_str.len);

        try self.scored_matches.ensureTotalCapacity(self.allocator, types.palette_action_items.len);

        for (types.palette_action_items, 0..) |item, idx| {
            if (searcher_ptr.score(item.name, query_str)) |score| {
                self.scored_matches.appendAssumeCapacity(.{ .index = idx, .score = score });
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
            try self.matches.ensureTotalCapacity(self.allocator, self.dir_items.items.len);
            for (self.dir_items.items, 0..) |_, idx| {
                self.matches.appendAssumeCapacity(idx);
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

        try self.scored_matches.ensureTotalCapacity(self.allocator, self.dir_items.items.len);

        for (self.dir_items.items, 0..) |entry, idx| {
            if (searcher_ptr.score(entry.getName(), query_str)) |score| {
                self.scored_matches.appendAssumeCapacity(.{ .index = idx, .score = score });
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
                const jpeg_base = std.fs.path.basename(jpeg_p);
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
                const jpeg_base = std.fs.path.basename(jpeg_p);
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
            const item_top = @as(f32, @floatFromInt(clamped_sel)) * item_height;
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

/// Returns the static layout configuration struct for a given palette mode.
pub fn getPaletteConfig(mode: PaletteMode) PaletteConfig {
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
        .set_brightness => .{
            .title = "Set Brightness",
            .placeholder = "Enter brightness (-1.0 to 1.0, e.g. 0.2)...",
            .element_id = "BrightnessPalette",
            .list_id = "BrightnessPaletteList",
            .item_prefix = "BrightnessItem_",
            .top_spacer_id = "BrightnessTopSpacer",
            .bottom_spacer_id = "BrightnessBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_contrast => .{
            .title = "Set Contrast",
            .placeholder = "Enter contrast (0.0 to 5.0, e.g. 1.5)...",
            .element_id = "ContrastPalette",
            .list_id = "ContrastPaletteList",
            .item_prefix = "ContrastItem_",
            .top_spacer_id = "ContrastTopSpacer",
            .bottom_spacer_id = "ContrastBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_contrast_blend => .{
            .title = "Set Contrast Blend",
            .placeholder = "Enter contrast blend (0.0 Luma to 1.0 RGB, e.g. 0.5)...",
            .element_id = "ContrastBlendPalette",
            .list_id = "ContrastBlendPaletteList",
            .item_prefix = "ContrastBlendItem_",
            .top_spacer_id = "ContrastBlendTopSpacer",
            .bottom_spacer_id = "ContrastBlendBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_highlights => .{
            .title = "Set Highlights",
            .placeholder = "Enter highlights (-1.0 to 1.0, e.g. -0.3)...",
            .element_id = "HighlightsPalette",
            .list_id = "HighlightsPaletteList",
            .item_prefix = "HighlightsItem_",
            .top_spacer_id = "HighlightsTopSpacer",
            .bottom_spacer_id = "HighlightsBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_shadows => .{
            .title = "Set Shadows",
            .placeholder = "Enter shadows (-1.0 to 1.0, e.g. 0.2)...",
            .element_id = "ShadowsPalette",
            .list_id = "ShadowsPaletteList",
            .item_prefix = "ShadowsItem_",
            .top_spacer_id = "ShadowsTopSpacer",
            .bottom_spacer_id = "ShadowsBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_whites => .{
            .title = "Set Whites",
            .placeholder = "Enter whites (-1.0 to 1.0, e.g. 0.1)...",
            .element_id = "WhitesPalette",
            .list_id = "WhitesPaletteList",
            .item_prefix = "WhitesItem_",
            .top_spacer_id = "WhitesTopSpacer",
            .bottom_spacer_id = "WhitesBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_blacks => .{
            .title = "Set Blacks",
            .placeholder = "Enter blacks (-1.0 to 1.0, e.g. -0.1)...",
            .element_id = "BlacksPalette",
            .list_id = "BlacksPaletteList",
            .item_prefix = "BlacksItem_",
            .top_spacer_id = "BlacksTopSpacer",
            .bottom_spacer_id = "BlacksBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_temperature => .{
            .title = "Set Temperature",
            .placeholder = "Enter temperature (-1.0 to 1.0, e.g. 0.2)...",
            .element_id = "TemperaturePalette",
            .list_id = "TemperaturePaletteList",
            .item_prefix = "TemperatureItem_",
            .top_spacer_id = "TemperatureTopSpacer",
            .bottom_spacer_id = "TemperatureBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_tint => .{
            .title = "Set Tint",
            .placeholder = "Enter tint (-1.0 to 1.0, e.g. 0.05)...",
            .element_id = "TintPalette",
            .list_id = "TintPaletteList",
            .item_prefix = "TintItem_",
            .top_spacer_id = "TintTopSpacer",
            .bottom_spacer_id = "TintBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_vibrance => .{
            .title = "Set Vibrance",
            .placeholder = "Enter vibrance (-1.0 to 1.0, e.g. 0.25)...",
            .element_id = "VibrancePalette",
            .list_id = "VibrancePaletteList",
            .item_prefix = "VibranceItem_",
            .top_spacer_id = "VibranceTopSpacer",
            .bottom_spacer_id = "VibranceBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_saturation => .{
            .title = "Set Saturation",
            .placeholder = "Enter saturation (-1.0 to 1.0, e.g. 0.1)...",
            .element_id = "SaturationPalette",
            .list_id = "SaturationPaletteList",
            .item_prefix = "SaturationItem_",
            .top_spacer_id = "SaturationTopSpacer",
            .bottom_spacer_id = "SaturationBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_clarity => .{
            .title = "Set Clarity",
            .placeholder = "Enter clarity (-1.0 to 1.0, e.g. 0.3)...",
            .element_id = "ClarityPalette",
            .list_id = "ClarityPaletteList",
            .item_prefix = "ClarityItem_",
            .top_spacer_id = "ClarityTopSpacer",
            .bottom_spacer_id = "ClarityBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_texture => .{
            .title = "Set Texture",
            .placeholder = "Enter texture (-1.0 to 1.0, e.g. 0.25)...",
            .element_id = "TexturePalette",
            .list_id = "TexturePaletteList",
            .item_prefix = "TextureItem_",
            .top_spacer_id = "TextureTopSpacer",
            .bottom_spacer_id = "TextureBottomSpacer",
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

test "DirectoryEntry accessors and scan state" {
    const p = DirectoryEntry{ .parent = .{ .name = "..", .full_path = "/home/pope" } };
    try std.testing.expectEqualStrings("..", p.getName());
    try std.testing.expectEqualStrings("/home/pope", p.getFullPath());
    try std.testing.expect(!p.isArchive());
    try std.testing.expect(p.getScanState() == null);

    const d = DirectoryEntry{
        .directory = .{
            .name = "photos",
            .full_path = "/photos",
            .scan = .{ .scanned = .{ .image_count = 42, .subdir_count = 3 } },
        },
    };
    try std.testing.expectEqualStrings("photos", d.getName());
    try std.testing.expectEqualStrings("/photos", d.getFullPath());
    try std.testing.expect(!d.isArchive());
    try std.testing.expect(d.getScanState() != null);
    try std.testing.expectEqual(@as(usize, 42), d.getScanState().?.scanned.image_count);
    try std.testing.expectEqual(@as(usize, 3), d.getScanState().?.scanned.subdir_count);

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

    const f = DirectoryEntry{ .image_file = .{ .name = "img.png", .full_path = "/img.png" } };
    try std.testing.expectEqualStrings("img.png", f.getName());
    try std.testing.expect(!f.isArchive());
    try std.testing.expect(f.getScanState() == null);
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
