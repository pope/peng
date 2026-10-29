const std = @import("std");
const triage = @import("triage");
const types = @import("types.zig");
const vfs = @import("vfs");

const Classification = triage.Classification;
const MediaEntry = vfs.MediaEntry;
const MediaId = vfs.MediaId;
const SlideshowMode = types.SlideshowMode;
const TriageMap = triage.TriageMap;
const ViewMode = triage.ViewMode;
const VisibleNeighbors = triage.VisibleNeighbors;

/// Unified media list element stored contiguously in Structure-of-Arrays (SoA) layout.
pub const MediaItem = struct {
    id: MediaId,
    entry: MediaEntry,
    classification: Classification = .unflagged,
};

/// Slice view of MultiArrayList(MediaItem) stored in SoA layout.
pub const MediaItemSlice = std.MultiArrayList(MediaItem).Slice;

/// Direction of user navigation travel across the image list.
pub const NavDirection = enum {
    forward,
    backward,
};

/// Maximum memory bytes retained across directory arena resets (256 KiB).
const MAX_RETAINED_DIR_ARENA_BYTES: usize = 256 * 1024;

/// Tracks the active media list, current image index, slideshow progression, and directory cache.
pub const NavigationState = struct {
    items: std.MultiArrayList(MediaItem) = .empty,
    next_media_id: u32 = 1,
    triage: TriageMap,
    anchor_index: usize = 0,
    current_index: ?usize = null,
    slideshow: SlideshowMode = .inactive,
    manga_mode: bool = false,
    crossfade: bool = true,
    stack_raw_jpeg: bool = true,
    active_file_scans: std.atomic.Value(usize) = .init(0),
    last_nav_time_ms: u64 = 0,
    direction: NavDirection = .forward,
    last_scanned_dir: std.ArrayList(u8) = .empty,
    directory_arena: std.heap.ArenaAllocator,

    /// Initializes navigation state with pre-allocated buffer capacities.
    pub fn init(allocator: std.mem.Allocator) !NavigationState {
        const triage_map = try TriageMap.init(allocator);
        var self = NavigationState{
            .directory_arena = std.heap.ArenaAllocator.init(allocator),
            .triage = triage_map,
        };
        errdefer self.deinit(allocator);
        // 32 media items: single allocation partitions entry and classification arrays
        try self.items.ensureTotalCapacity(allocator, 32);
        // 128 bytes: accommodates standard file directory path strings
        try self.last_scanned_dir.ensureTotalCapacity(allocator, 128);
        return self;
    }

    /// Releases media list items, directory string buffer, and arenas.
    pub fn deinit(self: *NavigationState, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.triage.deinit(allocator);
        self.last_scanned_dir.deinit(allocator);
        self.directory_arena.deinit();
    }

    /// Resets directory arena retaining at most 256 KiB of memory pages.
    pub fn resetDirectoryArena(self: *NavigationState) void {
        _ = self.directory_arena.reset(.{
            .retain_with_limit = MAX_RETAINED_DIR_ARENA_BYTES,
        });
    }

    /// Reclaims over-allocated capacity in `items` if capacity exceeds 2x
    /// length and exceeds 64 elements, preventing memory retention after
    /// navigating away from massive directories.
    pub fn trimExcessCapacity(
        self: *NavigationState,
        gpa: std.mem.Allocator,
    ) void {
        if (self.items.capacity > @max(64, self.items.len *| 2)) {
            const target_cap = @max(64, self.items.len);
            if (self.items.len == 0) {
                self.items.clearAndFree(gpa);
            } else {
                self.items.setCapacity(gpa, target_cap) catch {};
            }
        }
    }

    /// Allocates a new unique non-zero MediaId for this session.
    pub fn allocMediaId(self: *NavigationState) MediaId {
        const id = MediaId.fromU32(self.next_media_id);
        self.next_media_id +%= 1;
        if (self.next_media_id == 0) self.next_media_id = 1;
        return id;
    }

    /// Appends a new media entry with an automatically allocated MediaId.
    pub fn appendEntry(
        self: *NavigationState,
        gpa: std.mem.Allocator,
        entry: MediaEntry,
    ) !MediaId {
        const id = self.allocMediaId();
        try self.appendEntryWithId(gpa, id, entry);
        return id;
    }

    /// Appends a new media entry with an explicit MediaId.
    pub fn appendEntryWithId(
        self: *NavigationState,
        gpa: std.mem.Allocator,
        id: MediaId,
        entry: MediaEntry,
    ) !void {
        const initial_class = self.triage.lookupEntry(entry);
        try self.items.append(gpa, .{
            .id = id,
            .entry = entry,
            .classification = initial_class,
        });
        errdefer _ = self.items.pop();

        try self.triage.registerEntry(gpa, entry, initial_class);
        if (id.toU32() >= self.next_media_id) {
            self.next_media_id = id.toU32() +% 1;
            if (self.next_media_id == 0) self.next_media_id = 1;
        }
    }

    /// Clears active media list, preserving persistent path flags and
    /// allocated capacities.
    pub fn clearEntries(self: *NavigationState) void {
        self.items.clearRetainingCapacity();
        self.triage.resetActiveCounts();
        self.current_index = null;
        self.anchor_index = 0;
    }

    /// Returns the effective navigation prefetch direction. If no user
    /// navigation has occurred yet (`last_nav_time_ms == 0`), respects
    /// `manga_mode` (.backward for RTL reading order, .forward otherwise).
    pub fn getEffectiveDirection(self: *const NavigationState) NavDirection {
        if (self.last_nav_time_ms == 0) {
            return if (self.manga_mode) .backward else .forward;
        }
        return self.direction;
    }

    /// Returns `true` if any background directory or stdin file scan is active.
    pub inline fn isLoadingFiles(self: *const NavigationState) bool {
        return self.active_file_scans.load(.acquire) > 0;
    }

    /// Returns `true` if slideshow playback mode is active.
    pub inline fn isSlideshowActive(self: *const NavigationState) bool {
        return self.slideshow == .active;
    }

    /// Returns the total count of discovered images in the current media list.
    pub inline fn count(self: *const NavigationState) usize {
        return self.items.len;
    }

    /// Returns a contiguous slice of all media entries.
    pub inline fn getEntries(self: *const NavigationState) []const MediaEntry {
        return self.items.items(.entry);
    }

    /// Returns a contiguous slice of all image classifications.
    pub inline fn getClassifications(self: *const NavigationState) []const Classification {
        return self.items.items(.classification);
    }

    /// Returns the `MediaEntry` at `idx` if within bounds.
    pub inline fn getMediaEntry(self: *const NavigationState, idx: usize) ?MediaEntry {
        if (idx < self.items.len) {
            return self.items.items(.entry)[idx];
        }
        return null;
    }

    /// Returns the classification at `idx` if within bounds, or `.unflagged`.
    pub inline fn getClassification(
        self: *const NavigationState,
        idx: usize,
    ) Classification {
        if (idx < self.items.len) {
            return self.items.items(.classification)[idx];
        }
        return .unflagged;
    }

    /// Returns the stable MediaId at the specified playlist index if valid.
    pub fn getIdAt(self: *const NavigationState, idx: usize) ?MediaId {
        if (idx >= self.items.len) return null;
        return self.items.items(.id)[idx];
    }

    /// Returns the active MediaId of the currently displayed slide.
    pub fn getCurrentMediaId(self: *const NavigationState) ?MediaId {
        const cur = self.current_index orelse return null;
        return self.getIdAt(cur);
    }

    /// Searches for the playlist index currently associated with `id`.
    pub fn posOfId(self: *const NavigationState, id: MediaId) ?usize {
        if (!id.isValid()) return null;
        const ids = self.items.items(.id);
        for (ids, 0..) |cand, i| {
            if (cand == id) return i;
        }
        return null;
    }

    /// Returns a copy of the MediaEntry matching `id`.
    pub fn getMediaEntryById(
        self: *const NavigationState,
        id: MediaId,
    ) ?MediaEntry {
        const idx = self.posOfId(id) orelse return null;
        return self.items.items(.entry)[idx];
    }

    /// Searches the current media list for an entry matching `target_path`,
    /// returning its index or `null` if not found.
    pub fn findMatchingIndex(
        self: *const NavigationState,
        target_path: []const u8,
    ) ?usize {
        for (self.items.items(.entry), 0..) |item, i| {
            if (item.matchesTarget(target_path)) return i;
        }
        return null;
    }

    /// Returns `true` if the item at `idx` is visible in the active
    /// `view_mode`.
    pub inline fn isIndexVisible(
        self: *const NavigationState,
        idx: usize,
    ) bool {
        if (idx >= self.items.len) return false;
        return self.triage.isVisible(self.items.items(.classification)[idx]);
    }

    /// O(1) branchless count of visible images in the current media list.
    pub inline fn getVisibleCount(self: *const NavigationState) usize {
        return self.triage.visibleCount(self.items.len);
    }

    /// Computes the 1-based index of `current_index` among currently visible
    /// items using SIMD.
    pub fn getVisiblePosition(self: *const NavigationState) ?usize {
        const cur = self.current_index orelse return null;
        return self.triage.visiblePosition(
            self.items.items(.classification),
            cur,
        );
    }

    /// Retrieves the `MediaEntry` at `current_index`, or `null` if empty or
    /// invalid.
    pub inline fn getCurrentImageEntry(
        self: *const NavigationState,
    ) ?MediaEntry {
        const idx = self.current_index orelse return null;
        return self.getMediaEntry(idx);
    }

    /// Returns the classification of the currently viewed image.
    pub inline fn getCurrentClassification(
        self: *const NavigationState,
    ) Classification {
        const idx = self.current_index orelse return .unflagged;
        if (idx < self.items.len) {
            return self.items.items(.classification)[idx];
        }
        return .unflagged;
    }

    /// Updates classification of current image, updates running counters, and
    /// persists in path table.
    pub fn markClassification(
        self: *NavigationState,
        gpa: std.mem.Allocator,
        new_class: Classification,
    ) !bool {
        const idx = self.current_index orelse return false;
        if (idx >= self.items.len) return false;
        return self.triage.updateClassification(
            gpa,
            self.items.items(.entry)[idx],
            &self.items.items(.classification)[idx],
            new_class,
        );
    }

    /// Marks the currently selected image as a pick.
    pub fn markCurrentPick(
        self: *NavigationState,
        gpa: std.mem.Allocator,
    ) !bool {
        return self.markClassification(gpa, .pick);
    }

    /// Marks the currently selected image as a reject.
    pub fn markCurrentReject(
        self: *NavigationState,
        gpa: std.mem.Allocator,
    ) !bool {
        return self.markClassification(gpa, .reject);
    }

    /// Clears the classification flag on the currently selected image.
    pub fn unflagCurrent(
        self: *NavigationState,
        gpa: std.mem.Allocator,
    ) !bool {
        return self.markClassification(gpa, .unflagged);
    }

    /// Clears all pick and reject classifications across both the active media
    /// list and persistent path table. Returns `true` if any flags were
    /// cleared.
    pub fn clearAllClassifications(self: *NavigationState) bool {
        return self.triage.clearAll(self.items.items(.classification));
    }

    /// Serializes current pick and reject selections as a single-line JSON
    /// object (`{"ok":true,"picks":[...],"rejects":[...]}\n`) to `writer`.
    pub fn writeSelectionsJson(
        self: *const NavigationState,
        writer: *std.Io.Writer,
    ) !void {
        const slice = self.items.slice();
        return self.triage.writeSelectionsJson(
            writer,
            slice.items(.entry),
            slice.items(.classification),
        );
    }

    /// Serializes current pick and reject selections as tab-separated rows
    /// (`PICK\t<path>\n` or `REJECT\t<path>\n`) to `writer`.
    pub fn writeSelectionsTsv(
        self: *const NavigationState,
        writer: *std.Io.Writer,
    ) !void {
        const slice = self.items.slice();
        return self.triage.writeSelectionsTsv(
            writer,
            slice.items(.entry),
            slice.items(.classification),
        );
    }

    /// Finds the nearest visible index to `start_idx`, searching forward
    /// first, then backward with SIMD.
    pub fn findClosestVisible(
        self: *const NavigationState,
        start_idx: usize,
    ) ?usize {
        return self.triage.findClosestVisible(
            self.items.items(.classification),
            start_idx,
        );
    }

    /// Adjusts `current_index` so it points to a visible item in the current
    /// view mode, preserving `anchor_index` if the current filter contains
    /// zero visible images.
    pub fn adjustIndexForVisibility(self: *NavigationState) bool {
        if (self.getVisibleCount() == 0) {
            const changed = self.current_index != null;
            self.current_index = null;
            return changed;
        }
        if (self.current_index) |cur| {
            if (self.isIndexVisible(cur)) {
                self.anchor_index = cur;
                return false;
            }
            self.current_index = self.findClosestVisible(cur);
            if (self.current_index) |idx| self.anchor_index = idx;
            return true;
        } else {
            self.current_index = self.findClosestVisible(self.anchor_index);
            if (self.current_index) |idx| self.anchor_index = idx;
            return self.current_index != null;
        }
    }

    /// Returns the active triage view filter mode.
    pub inline fn getViewMode(self: *const NavigationState) ViewMode {
        return self.triage.view_mode;
    }

    /// Sets active view mode and adjusts index if current selection is hidden.
    pub fn setViewMode(self: *NavigationState, mode: ViewMode) bool {
        if (self.triage.view_mode == mode) return false;
        self.triage.view_mode = mode;
        _ = self.adjustIndexForVisibility();
        return true;
    }

    /// Cycles sequentially to the next view mode.
    pub fn cycleViewMode(self: *NavigationState) bool {
        return self.setViewMode(self.triage.view_mode.cycle());
    }

    /// Returns the next circularly visible index after `from_idx` without
    /// mutating navigation state, or `null` if no visible items exist.
    pub fn peekNextVisible(
        self: *const NavigationState,
        from_idx: usize,
    ) ?usize {
        return self.triage.peekNextVisible(
            self.items.items(.classification),
            from_idx,
        );
    }

    /// Returns the previous circularly visible index before `from_idx` without
    /// mutating navigation state, or `null` if no visible items exist.
    pub fn peekPrevVisible(
        self: *const NavigationState,
        from_idx: usize,
    ) ?usize {
        return self.triage.peekPrevVisible(
            self.items.items(.classification),
            from_idx,
        );
    }

    /// Computes the visible ±1 and ±2 neighbor indices around `current_index`
    /// in the active `view_mode`.
    pub fn getVisibleNeighbors(
        self: *const NavigationState,
    ) ?VisibleNeighbors {
        const cur = self.current_index orelse return null;
        return self.triage.computeVisibleNeighbors(
            self.items.items(.classification),
            cur,
        );
    }

    /// Advances selection to the next visible image using circular SIMD scan.
    /// Updates `last_nav_time_ms` to `@max(1, now_ms)` for fast-scroll
    /// throttling.
    pub fn nextIndex(self: *NavigationState, now_ms: u64) ?usize {
        const cur = self.current_index orelse self.anchor_index;
        const idx = self.peekNextVisible(cur) orelse return null;
        self.slideshow.resetTimer();
        self.last_nav_time_ms = @max(1, now_ms);
        self.direction = .forward;
        self.current_index = idx;
        self.anchor_index = idx;
        return idx;
    }

    /// Moves selection to the previous visible image using circular SIMD scan.
    /// Updates `last_nav_time_ms` to `@max(1, now_ms)` for fast-scroll
    /// throttling.
    pub fn prevIndex(self: *NavigationState, now_ms: u64) ?usize {
        const cur = self.current_index orelse self.anchor_index;
        const idx = self.peekPrevVisible(cur) orelse return null;
        self.slideshow.resetTimer();
        self.last_nav_time_ms = @max(1, now_ms);
        self.direction = .backward;
        self.current_index = idx;
        self.anchor_index = idx;
        return idx;
    }

    /// Directly sets the image selection to `idx` (or closest visible), clamped
    /// to valid bounds. Updates `last_nav_time_ms` to `@max(1, now_ms)`.
    pub fn goToIndex(self: *NavigationState, idx: usize, now_ms: u64) ?usize {
        const len = self.items.len;
        if (len == 0 or self.getVisibleCount() == 0) return null;
        const target = self.findClosestVisible(idx) orelse return null;
        if (self.current_index) |cur| {
            if (target == cur) return self.current_index;
            if (target > cur) {
                self.direction = .forward;
            } else if (target < cur) {
                self.direction = .backward;
            }
        }
        self.slideshow.resetTimer();
        self.last_nav_time_ms = @max(1, now_ms);
        self.current_index = target;
        self.anchor_index = target;
        return self.current_index;
    }
};

test "NavigationState - direction tracking" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    try std.testing.expectEqual(NavDirection.forward, nav.direction);

    // Populate mock image list with 3 entries
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "a.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "b.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "c.jpg" } });
    nav.current_index = 0;

    _ = nav.nextIndex(5500);
    try std.testing.expectEqual(@as(?usize, 1), nav.current_index);
    try std.testing.expectEqual(NavDirection.forward, nav.direction);
    try std.testing.expectEqual(@as(u64, 5500), nav.last_nav_time_ms);

    _ = nav.prevIndex(6200);
    try std.testing.expectEqual(@as(?usize, 0), nav.current_index);
    try std.testing.expectEqual(NavDirection.backward, nav.direction);
    try std.testing.expectEqual(@as(u64, 6200), nav.last_nav_time_ms);

    _ = nav.goToIndex(2, 7000);
    try std.testing.expectEqual(@as(?usize, 2), nav.current_index);
    try std.testing.expectEqual(NavDirection.forward, nav.direction);
    try std.testing.expectEqual(@as(u64, 7000), nav.last_nav_time_ms);

    _ = nav.goToIndex(0, 0);
    try std.testing.expectEqual(@as(?usize, 0), nav.current_index);
    try std.testing.expectEqual(NavDirection.backward, nav.direction);
    try std.testing.expectEqual(@as(u64, 1), nav.last_nav_time_ms);
}

test "NavigationState - triage mutations and visibility filtering" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "1.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "2.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "3.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "4.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "5.jpg" } });
    nav.current_index = 0;

    try std.testing.expectEqual(@as(usize, 5), nav.getVisibleCount());

    // Flag #1 as pick, #3 as reject
    nav.current_index = 1;
    _ = try nav.markCurrentPick(allocator);
    nav.current_index = 3;
    _ = try nav.markCurrentReject(allocator);

    try std.testing.expectEqual(@as(usize, 1), nav.triage.pick_count);
    try std.testing.expectEqual(@as(usize, 1), nav.triage.reject_count);

    // In default view mode: 4 visible (1, 2, 3, 5; 4 is hidden)
    try std.testing.expectEqual(@as(usize, 4), nav.getVisibleCount());
    try std.testing.expect(nav.isIndexVisible(0));
    try std.testing.expect(nav.isIndexVisible(1));
    try std.testing.expect(nav.isIndexVisible(2));
    try std.testing.expect(!nav.isIndexVisible(3)); // rejected
    try std.testing.expect(nav.isIndexVisible(4));

    // Stepping skips rejected item #3: 2 -> 4 -> 0
    nav.current_index = 2;
    _ = nav.nextIndex(100);
    try std.testing.expectEqual(@as(?usize, 4), nav.current_index);
    _ = nav.nextIndex(100);
    try std.testing.expectEqual(@as(?usize, 0), nav.current_index);

    // Switching to picks mode
    _ = nav.setViewMode(.picks);
    try std.testing.expectEqual(@as(usize, 1), nav.getVisibleCount());
    try std.testing.expectEqual(@as(?usize, 1), nav.current_index);

    // Switching to rejects mode
    _ = nav.setViewMode(.rejects);
    try std.testing.expectEqual(@as(usize, 1), nav.getVisibleCount());
    try std.testing.expectEqual(@as(?usize, 3), nav.current_index);

    // Switching to empty filter: unflag and verify anchor preservation
    _ = nav.setViewMode(.picks);
    nav.current_index = 1;
    _ = try nav.unflagCurrent(allocator);
    try std.testing.expectEqual(@as(usize, 0), nav.getVisibleCount());
    _ = nav.adjustIndexForVisibility();
    try std.testing.expectEqual(@as(?usize, null), nav.current_index);

    // Cycle to all: restores anchor position
    _ = nav.setViewMode(.all);
    try std.testing.expectEqual(@as(?usize, 1), nav.current_index);
}

test "NavigationState - rescan persistence across clearEntries" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    _ = try nav.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "photo.jpg" } },
    );
    nav.current_index = 0;
    _ = try nav.markCurrentPick(allocator);
    try std.testing.expectEqual(Classification.pick, nav.getCurrentClassification());

    // Rescan clears entries
    nav.clearEntries();
    try std.testing.expectEqual(@as(usize, 0), nav.count());

    // Re-adding the same path restores its pick status
    _ = try nav.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "photo.jpg" } },
    );
    nav.current_index = 0;
    try std.testing.expectEqual(
        Classification.pick,
        nav.getCurrentClassification(),
    );
    try std.testing.expectEqual(@as(usize, 1), nav.triage.pick_count);
}

test "NavigationState - SIMD skipping and popcount across large list" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    // Populate 100 entries
    var buf: [32]u8 = undefined;
    for (0..100) |i| {
        const path = try std.mem.print(&buf, "img_{d}.jpg", .{i});
        _ = try nav.appendEntry(
            allocator,
            .{ .filesystem = .{ .path = path } },
        );
    }
    try std.testing.expectEqual(@as(usize, 100), nav.count());

    // Flag indices 10, 45, 80 as picks
    nav.current_index = 10;
    _ = try nav.markCurrentPick(allocator);
    nav.current_index = 45;
    _ = try nav.markCurrentPick(allocator);
    nav.current_index = 80;
    _ = try nav.markCurrentPick(allocator);

    _ = nav.setViewMode(.picks);
    try std.testing.expectEqual(@as(usize, 3), nav.getVisibleCount());

    // Verify SIMD position counting
    nav.current_index = 10;
    try std.testing.expectEqual(@as(?usize, 1), nav.getVisiblePosition());
    nav.current_index = 45;
    try std.testing.expectEqual(@as(?usize, 2), nav.getVisiblePosition());
    nav.current_index = 80;
    try std.testing.expectEqual(@as(?usize, 3), nav.getVisiblePosition());

    // Verify forward SIMD scanning across > 32 elements: 10 -> 45 -> 80 -> 10 (wrap)
    nav.current_index = 10;
    _ = nav.nextIndex(100);
    try std.testing.expectEqual(@as(?usize, 45), nav.current_index);
    _ = nav.nextIndex(100);
    try std.testing.expectEqual(@as(?usize, 80), nav.current_index);
    _ = nav.nextIndex(100);
    try std.testing.expectEqual(@as(?usize, 10), nav.current_index);

    // Verify backward SIMD scanning across > 32 elements: 10 -> 80 -> 45 -> 10
    _ = nav.prevIndex(100);
    try std.testing.expectEqual(@as(?usize, 80), nav.current_index);
    _ = nav.prevIndex(100);
    try std.testing.expectEqual(@as(?usize, 45), nav.current_index);
    _ = nav.prevIndex(100);
    try std.testing.expectEqual(@as(?usize, 10), nav.current_index);
}

test "NavigationState - pair classification synchronization" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    const raw_p = try allocator.dupe(u8, "photos/DSC00941.ARW");
    errdefer allocator.free(raw_p);
    const jpg_p = try allocator.dupe(u8, "photos/DSC00941.JPG");
    errdefer allocator.free(jpg_p);

    const pair_entry = MediaEntry{
        .pair = .{
            .raw_path = raw_p,
            .jpeg_path = jpg_p,
        },
    };
    defer pair_entry.deinit(allocator);

    _ = try nav.appendEntry(allocator, pair_entry);
    nav.current_index = 0;

    try std.testing.expectEqual(Classification.unflagged, nav.getCurrentClassification());
    _ = try nav.markCurrentPick(allocator);
    try std.testing.expectEqual(Classification.pick, nav.getCurrentClassification());

    // Verify both raw_path and jpeg_path are registered in triage table
    try std.testing.expectEqual(
        Classification.pick,
        nav.triage.get("photos/DSC00941.ARW").?,
    );
    try std.testing.expectEqual(
        Classification.pick,
        nav.triage.get("photos/DSC00941.JPG").?,
    );

    // Unflagging clears both paths from table
    _ = try nav.unflagCurrent(allocator);
    try std.testing.expectEqual(
        Classification.unflagged,
        nav.getCurrentClassification(),
    );
    try std.testing.expect(
        nav.triage.get("photos/DSC00941.ARW") == null,
    );
    try std.testing.expect(
        nav.triage.get("photos/DSC00941.JPG") == null,
    );
}

test "NavigationState - unstacked to stacked pair flag propagation" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    // 1. Mark standalone JPEG as pick while unstacked
    _ = try nav.appendEntry(allocator, .{
        .filesystem = .{ .path = "photos/shot.JPG" },
    });
    nav.current_index = 0;
    _ = try nav.markCurrentPick(allocator);
    try std.testing.expectEqual(
        Classification.pick,
        nav.getCurrentClassification(),
    );

    // 2. Clear and reload as stacked pair: pair must inherit pick and register
    // the RAW companion path in triage table
    nav.clearEntries();
    _ = try nav.appendEntry(allocator, .{
        .pair = .{
            .raw_path = "photos/shot.ARW",
            .jpeg_path = "photos/shot.JPG",
        },
    });
    nav.current_index = 0;
    try std.testing.expectEqual(
        Classification.pick,
        nav.getCurrentClassification(),
    );
    try std.testing.expectEqual(
        Classification.pick,
        nav.triage.get("photos/shot.ARW").?,
    );

    // 3. Clear and reload as standalone RAW: must inherit pick
    nav.clearEntries();
    _ = try nav.appendEntry(allocator, .{
        .filesystem = .{ .path = "photos/shot.ARW" },
    });
    nav.current_index = 0;
    try std.testing.expectEqual(
        Classification.pick,
        nav.getCurrentClassification(),
    );
}

test "NavigationState - adjustIndexForVisibility syncs anchor_index" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "0.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "1.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "2.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "3.jpg" } });
    nav.current_index = 2;

    // In .all mode with current_index = 2, adjustIndexForVisibility must sync
    // anchor_index to 2
    _ = nav.adjustIndexForVisibility();
    try std.testing.expectEqual(@as(usize, 2), nav.anchor_index);

    // Switch to .picks mode with 0 picks: current_index becomes null,
    // anchor_index preserved as 2
    _ = nav.setViewMode(.picks);
    try std.testing.expectEqual(@as(?usize, null), nav.current_index);
    try std.testing.expectEqual(@as(usize, 2), nav.anchor_index);

    // Switch back to .all: current_index restores to anchor_index (2), not 0
    _ = nav.setViewMode(.all);
    try std.testing.expectEqual(@as(?usize, 2), nav.current_index);
    try std.testing.expectEqual(@as(usize, 2), nav.anchor_index);
}

test "NavigationState - getEffectiveDirection respects initial manga_mode" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    // Initial state: last_nav_time_ms == 0, manga_mode == false -> forward
    try std.testing.expectEqual(
        NavDirection.forward,
        nav.getEffectiveDirection(),
    );

    // Manga mode enabled at startup: last_nav_time_ms == 0 -> backward
    nav.manga_mode = true;
    try std.testing.expectEqual(
        NavDirection.backward,
        nav.getEffectiveDirection(),
    );

    // Navigating forward: last_nav_time_ms > 0 -> tracks user direction
    nav.last_nav_time_ms = 100;
    nav.direction = .forward;
    try std.testing.expectEqual(
        NavDirection.forward,
        nav.getEffectiveDirection(),
    );

    // Navigating backward: last_nav_time_ms > 0 -> tracks user direction
    nav.direction = .backward;
    try std.testing.expectEqual(
        NavDirection.backward,
        nav.getEffectiveDirection(),
    );
}

test "NavigationState - writeSelectionsJson and clearAllClassifications" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    _ = try nav.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "photos/a.jpg" } },
    );
    _ = try nav.appendEntry(
        allocator,
        .{ .pair = .{
            .raw_path = "photos/b.ARW",
            .jpeg_path = "photos/b.JPG",
        } },
    );
    _ = try nav.appendEntry(
        allocator,
        .{ .archive_entry = .{
            .archive_path = "comics/vol1.cbz",
            .entry_name = "p01.png",
            .seek_info = .unindexed,
        } },
    );

    nav.current_index = 1;
    _ = try nav.markCurrentPick(allocator);
    nav.current_index = 2;
    _ = try nav.markCurrentReject(allocator);

    var buf: [512]u8 = undefined;
    var fixed_writer: std.Io.Writer = .fixed(&buf);
    try nav.writeSelectionsJson(&fixed_writer);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"picks\":[\"photos/b.ARW\",\"photos/b.JPG\"]," ++
            "\"rejects\":[\"comics/vol1.cbz#p01.png\"]}\n",
        fixed_writer.buffered(),
    );

    // Verify cross-directory / cross-archive persistence after clearEntries()
    nav.clearEntries();
    _ = try nav.appendEntry(
        allocator,
        .{ .archive_entry = .{
            .archive_path = "comics/vol2.cbz",
            .entry_name = "p01.png",
            .seek_info = .unindexed,
        } },
    );
    // vol2.cbz#p01.png must NOT inherit vol1.cbz#p01.png's reject flag
    try std.testing.expectEqual(@as(usize, 0), nav.triage.reject_count);
    // Prior directory selections remain visible in writeSelectionsJson
    var cross_writer: std.Io.Writer = .fixed(&buf);
    try nav.writeSelectionsJson(&cross_writer);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"picks\":[\"photos/b.ARW\",\"photos/b.JPG\"]," ++
            "\"rejects\":[\"comics/vol1.cbz#p01.png\"]}\n",
        cross_writer.buffered(),
    );

    try std.testing.expect(nav.clearAllClassifications());
    try std.testing.expect(!nav.clearAllClassifications());
    try std.testing.expectEqual(@as(usize, 0), nav.triage.pick_count);
    try std.testing.expectEqual(@as(usize, 0), nav.triage.reject_count);

    var empty_writer: std.Io.Writer = .fixed(&buf);
    try nav.writeSelectionsJson(&empty_writer);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"picks\":[],\"rejects\":[]}\n",
        empty_writer.buffered(),
    );
}

test "NavigationState - MediaId allocation and persistence across reset" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    const id1 = nav.allocMediaId();
    try std.testing.expectEqual(@as(u32, 1), id1.toU32());
    const id2 = nav.allocMediaId();
    try std.testing.expectEqual(@as(u32, 2), id2.toU32());

    const id3 = try nav.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "test1.jpg" } },
    );
    try std.testing.expectEqual(@as(u32, 3), id3.toU32());
    try std.testing.expectEqual(id3, nav.getIdAt(0).?);

    // Monotonic counter must NOT be reset on clearEntries()
    nav.clearEntries();
    const id4 = try nav.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "test2.jpg" } },
    );
    try std.testing.expectEqual(@as(u32, 4), id4.toU32());
    try std.testing.expectEqual(id4, nav.getIdAt(0).?);

    // appendEntryWithId with a higher MediaId must advance next_media_id
    const high_id = MediaId.fromU32(50);
    try nav.appendEntryWithId(
        allocator,
        high_id,
        .{ .filesystem = .{ .path = "test3.jpg" } },
    );
    try std.testing.expectEqual(
        @as(u32, 51),
        nav.allocMediaId().toU32(),
    );
}

test "NavigationState - getMediaEntryById and posOfId lookup" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "a.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "b.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "c.jpg" } });

    const id_a = nav.getIdAt(0).?;
    const id_b = nav.getIdAt(1).?;
    const id_c = nav.getIdAt(2).?;

    try std.testing.expectEqual(@as(?usize, 0), nav.posOfId(id_a));
    try std.testing.expectEqual(@as(?usize, 1), nav.posOfId(id_b));
    try std.testing.expectEqual(@as(?usize, 2), nav.posOfId(id_c));
    try std.testing.expectEqual(@as(?usize, null), nav.posOfId(MediaId.none));
    try std.testing.expectEqual(
        @as(?usize, null),
        nav.posOfId(MediaId.fromU32(999)),
    );

    const entry_b = nav.getMediaEntryById(id_b).?;
    try std.testing.expectEqualStrings("b.jpg", entry_b.getPath());
    try std.testing.expectEqual(
        @as(?MediaEntry, null),
        nav.getMediaEntryById(MediaId.fromU32(999)),
    );
}

test "NavigationState - nextIndex and prevIndex record explicit now_ms" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "a.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "b.jpg" } });
    nav.current_index = 0;

    _ = nav.nextIndex(5500);
    try std.testing.expectEqual(@as(?usize, 1), nav.current_index);
    try std.testing.expectEqual(@as(u64, 5500), nav.last_nav_time_ms);

    _ = nav.prevIndex(6200);
    try std.testing.expectEqual(@as(?usize, 0), nav.current_index);
    try std.testing.expectEqual(@as(u64, 6200), nav.last_nav_time_ms);
}

test "NavigationState - goToIndex now_ms zero clamp" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "a.jpg" } });
    _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "b.jpg" } });
    nav.current_index = 1;

    _ = nav.goToIndex(0, 0);
    try std.testing.expectEqual(@as(?usize, 0), nav.current_index);
    try std.testing.expectEqual(@as(u64, 1), nav.last_nav_time_ms);
}

test "NavigationState - empty playlist returns null, keeps last_nav_time_ms 0" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    try std.testing.expectEqual(@as(?usize, null), nav.nextIndex(5500));
    try std.testing.expectEqual(@as(u64, 0), nav.last_nav_time_ms);

    try std.testing.expectEqual(@as(?usize, null), nav.prevIndex(6200));
    try std.testing.expectEqual(@as(u64, 0), nav.last_nav_time_ms);

    try std.testing.expectEqual(@as(?usize, null), nav.goToIndex(0, 7000));
    try std.testing.expectEqual(@as(u64, 0), nav.last_nav_time_ms);
}

test "NavigationState resetDirectoryArena bounds page retention" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    const arena_alloc = nav.directory_arena.allocator();
    const big_buf = try arena_alloc.alloc(u8, 1024 * 1024 + 1024);
    @memset(big_buf, 0xaa);

    try std.testing.expect(
        nav.directory_arena.queryCapacity() > MAX_RETAINED_DIR_ARENA_BYTES,
    );

    nav.resetDirectoryArena();

    try std.testing.expect(
        nav.directory_arena.queryCapacity() <= MAX_RETAINED_DIR_ARENA_BYTES,
    );
}

test "NavigationState trimExcessCapacity downscales excess capacity" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    try nav.items.ensureTotalCapacity(allocator, 1200);
    try std.testing.expect(nav.items.capacity >= 1200);

    const test_paths = [_][]const u8{
        "0.jpg", "1.jpg", "2.jpg", "3.jpg", "4.jpg",
        "5.jpg", "6.jpg", "7.jpg", "8.jpg", "9.jpg",
    };
    for (test_paths) |p| {
        _ = try nav.appendEntry(allocator, .{ .filesystem = .{ .path = p } });
    }
    try std.testing.expectEqual(@as(usize, 10), nav.items.len);
    try std.testing.expect(nav.items.capacity >= 1200);

    nav.trimExcessCapacity(allocator);

    try std.testing.expectEqual(@as(usize, 64), nav.items.capacity);
    try std.testing.expectEqual(@as(usize, 10), nav.items.len);
}

test "NavigationState trimExcessCapacity safely handles 0 items" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    try nav.items.ensureTotalCapacity(allocator, 1200);
    try std.testing.expect(nav.items.capacity >= 1200);
    try std.testing.expectEqual(@as(usize, 0), nav.items.len);

    nav.trimExcessCapacity(allocator);

    try std.testing.expectEqual(@as(usize, 0), nav.items.capacity);
    try std.testing.expectEqual(@as(usize, 0), nav.items.len);
}
