const std = @import("std");
const sdl = @import("sdl");
const types = @import("types.zig");
const SlideshowMode = types.SlideshowMode;

const MediaEntry = types.MediaEntry;

const Classification = types.Classification;
const ViewMode = types.ViewMode;

const Vec32 = @Vector(32, u8);

/// Finds the next index in `[start, end)` matching the active view mode using 256-bit SIMD.
pub fn findNextVisibleInRange(
    classifications: []const Classification,
    start: usize,
    end: usize,
    mode: ViewMode,
) ?usize {
    if (start >= end or start >= classifications.len) return null;
    const raw: []const u8 = @ptrCast(classifications);
    const limit = @min(end, raw.len);

    if (mode == .all) return start;

    const target_byte: u8 = switch (mode) {
        .picks => @intFromEnum(Classification.pick),
        .rejects => @intFromEnum(Classification.reject),
        .unflagged => @intFromEnum(Classification.unflagged),
        .default => @intFromEnum(Classification.reject),
        .all => unreachable,
    };
    const target_vec: Vec32 = @splat(target_byte);
    var i = start;

    // 32-element SIMD vector loop
    while (i + 32 <= limit) : (i += 32) {
        const chunk: Vec32 = raw[i..][0..32].*;
        const matches: @Vector(32, bool) = if (mode == .default)
            chunk != target_vec
        else
            chunk == target_vec;
        const mask: u32 = @bitCast(matches);
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }

    // Scalar tail for remainder
    while (i < limit) : (i += 1) {
        if (mode.matches(classifications[i])) return i;
    }

    return null;
}

/// Finds the previous index in `[min_idx, max_idx]` matching the active view mode using 256-bit SIMD.
pub fn findPrevVisibleInRange(
    classifications: []const Classification,
    min_idx: usize,
    max_idx: usize,
    mode: ViewMode,
) ?usize {
    if (min_idx > max_idx or max_idx >= classifications.len) return null;
    const raw: []const u8 = @ptrCast(classifications);
    if (mode == .all) return max_idx;

    const target_byte: u8 = switch (mode) {
        .picks => @intFromEnum(Classification.pick),
        .rejects => @intFromEnum(Classification.reject),
        .unflagged => @intFromEnum(Classification.unflagged),
        .default => @intFromEnum(Classification.reject),
        .all => unreachable,
    };
    const target_vec: Vec32 = @splat(target_byte);
    var cur = max_idx;

    // Small range optimization: use scalar loop if fewer than 32 elements
    if (cur - min_idx + 1 < 32) {
        while (true) {
            if (mode.matches(classifications[cur])) return cur;
            if (cur == min_idx) break;
            cur -= 1;
        }
        return null;
    }

    // Align backwards to a 32-byte boundary relative to min_idx
    while ((cur - min_idx + 1) % 32 != 0) : (cur -= 1) {
        if (mode.matches(classifications[cur])) return cur;
    }

    // 32-element backwards SIMD vector loop
    while (cur >= min_idx + 31) {
        const chunk_start = cur - 31;
        const chunk: Vec32 = raw[chunk_start..][0..32].*;
        const matches: @Vector(32, bool) = if (mode == .default)
            chunk != target_vec
        else
            chunk == target_vec;
        const mask: u32 = @bitCast(matches);
        if (mask != 0) {
            const highest_bit = 31 - @clz(mask);
            return chunk_start + highest_bit;
        }
        if (chunk_start == 0) return null;
        cur -= 32;
    }

    // Scalar remainder between min_idx and cur
    if (cur >= min_idx) {
        while (true) {
            if (mode.matches(classifications[cur])) return cur;
            if (cur == min_idx) break;
            cur -= 1;
        }
    }

    return null;
}

/// Computes the count of visible items in `[0, count_limit)` using hardware POPCNT and SIMD.
pub fn countVisibleInRangeSimd(
    classifications: []const Classification,
    count_limit: usize,
    mode: ViewMode,
) usize {
    if (count_limit == 0 or classifications.len == 0) return 0;
    const limit = @min(count_limit, classifications.len);
    if (mode == .all) return limit;

    const raw: []const u8 = @ptrCast(classifications);
    const target_byte: u8 = switch (mode) {
        .picks => @intFromEnum(Classification.pick),
        .rejects => @intFromEnum(Classification.reject),
        .unflagged => @intFromEnum(Classification.unflagged),
        .default => @intFromEnum(Classification.reject),
        .all => unreachable,
    };
    const target_vec: Vec32 = @splat(target_byte);
    var total: usize = 0;
    var i: usize = 0;

    while (i + 32 <= limit) : (i += 32) {
        const chunk: Vec32 = raw[i..][0..32].*;
        const matches: @Vector(32, bool) = if (mode == .default)
            chunk != target_vec
        else
            chunk == target_vec;
        const mask: u32 = @bitCast(matches);
        total += @popCount(mask);
    }

    while (i < limit) : (i += 1) {
        if (mode.matches(classifications[i])) total += 1;
    }

    return total;
}

/// Unified media list element stored contiguously in Structure-of-Arrays (SoA) layout.
pub const MediaItem = struct {
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

/// Tracks the active media list, current image index, slideshow progression, and directory cache.
pub const NavigationState = struct {
    items: std.MultiArrayList(MediaItem) = .empty,
    path_classifications: std.StringHashMapUnmanaged(Classification) = .empty,
    classification_arena: std.heap.ArenaAllocator,
    view_mode: ViewMode = .default,
    pick_count: usize = 0,
    reject_count: usize = 0,
    anchor_index: usize = 0,
    current_index: ?usize = null,
    slideshow: SlideshowMode = .inactive,
    manga_mode: bool = false,
    crossfade: bool = true,
    stack_raw_jpeg: bool = true,
    is_loading_files: std.atomic.Value(bool) = .init(false),
    last_nav_time_ms: u64 = 0,
    direction: NavDirection = .forward,
    last_scanned_dir: std.ArrayList(u8) = .empty,
    directory_arena: std.heap.ArenaAllocator,

    /// Initializes navigation state with pre-allocated buffer capacities.
    pub fn init(allocator: std.mem.Allocator) !NavigationState {
        var self = NavigationState{
            .directory_arena = std.heap.ArenaAllocator.init(allocator),
            .classification_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.deinit(allocator);
        // 32 media items: single allocation partitions entry and classification arrays
        try self.items.ensureTotalCapacity(allocator, 32);
        // 64 classifications: fast initial allocation for steady-state triage
        try self.path_classifications.ensureTotalCapacity(allocator, 64);
        // 128 bytes: accommodates standard file directory path strings
        try self.last_scanned_dir.ensureTotalCapacity(allocator, 128);
        return self;
    }

    /// Releases media list items, directory string buffer, and arenas.
    pub fn deinit(self: *NavigationState, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.path_classifications.deinit(allocator);
        self.last_scanned_dir.deinit(allocator);
        self.directory_arena.deinit();
        self.classification_arena.deinit();
    }

    /// Appends a media entry in lockstep with its classification in a single allocation.
    pub fn appendEntry(self: *NavigationState, gpa: std.mem.Allocator, entry: MediaEntry) !void {
        const initial_class = blk: {
            const path = entry.getPath();
            if (self.path_classifications.get(path)) |c| break :blk c;
            if (entry.getJpegPath()) |jp| {
                if (self.path_classifications.get(jp)) |c| break :blk c;
            }
            break :blk .unflagged;
        };
        try self.items.append(gpa, .{
            .entry = entry,
            .classification = initial_class,
        });
        if (initial_class == .pick) self.pick_count += 1;
        if (initial_class == .reject) self.reject_count += 1;
    }

    /// Clears active media list, preserving persistent path flags and allocated capacities.
    pub fn clearEntries(self: *NavigationState) void {
        self.items.clearRetainingCapacity();
        self.pick_count = 0;
        self.reject_count = 0;
        self.current_index = null;
        self.anchor_index = 0;
    }

    /// Returns `true` if slideshow playback mode is active.
    pub inline fn isSlideshowActive(self: *const NavigationState) bool {
        return self.slideshow == .active;
    }

    /// Returns the total count of discovered images in the current media list.
    pub inline fn count(self: *const NavigationState) usize {
        return self.items.len;
    }

    /// Alias for total count of images.
    pub inline fn totalImages(self: *const NavigationState) usize {
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

    /// Returns `true` if the item at `idx` is visible in the active `view_mode`.
    pub inline fn isIndexVisible(self: *const NavigationState, idx: usize) bool {
        if (idx >= self.items.len) return false;
        return self.view_mode.matches(self.items.items(.classification)[idx]);
    }

    /// O(1) branchless count of visible images in the current media list.
    pub inline fn getVisibleCount(self: *const NavigationState) usize {
        const total = self.items.len;
        return switch (self.view_mode) {
            .default => total -| self.reject_count,
            .unflagged => total -| (self.pick_count + self.reject_count),
            .picks => self.pick_count,
            .rejects => self.reject_count,
            .all => total,
        };
    }

    /// Computes the 1-based index of `current_index` among currently visible items using SIMD.
    pub fn getVisiblePosition(self: *const NavigationState) ?usize {
        const cur = self.current_index orelse return null;
        if (cur >= self.items.len) return null;
        if (self.view_mode == .all) return cur + 1;
        const pos = countVisibleInRangeSimd(self.items.items(.classification), cur + 1, self.view_mode);
        return if (pos > 0) pos else null;
    }

    /// Retrieves the `MediaEntry` at `current_index`, or `null` if empty or invalid.
    pub inline fn getCurrentImageEntry(self: *const NavigationState) ?MediaEntry {
        const idx = self.current_index orelse return null;
        return self.getMediaEntry(idx);
    }

    /// Returns the classification of the currently viewed image.
    pub inline fn getCurrentClassification(self: *const NavigationState) Classification {
        const idx = self.current_index orelse return .unflagged;
        if (idx < self.items.len) {
            return self.items.items(.classification)[idx];
        }
        return .unflagged;
    }

    /// Updates classification of current image, updates running counters, and persists in path table.
    pub fn markClassification(
        self: *NavigationState,
        gpa: std.mem.Allocator,
        new_class: Classification,
    ) !bool {
        const idx = self.current_index orelse return false;
        if (idx >= self.items.len) return false;
        const classes = self.items.items(.classification);
        const old_class = classes[idx];
        if (old_class == new_class) return false;

        classes[idx] = new_class;
        if (old_class == .pick) self.pick_count -= 1;
        if (old_class == .reject) self.reject_count -= 1;
        if (new_class == .pick) self.pick_count += 1;
        if (new_class == .reject) self.reject_count += 1;

        const entry = self.items.items(.entry)[idx];
        const path = entry.getPath();
        if (new_class == .unflagged) {
            _ = self.path_classifications.remove(path);
            if (entry.getJpegPath()) |jp| {
                _ = self.path_classifications.remove(jp);
            }
        } else {
            if (self.path_classifications.getPtr(path)) |ptr| {
                ptr.* = new_class;
            } else {
                const owned_path = try self.classification_arena.allocator().dupe(u8, path);
                try self.path_classifications.put(gpa, owned_path, new_class);
            }
            if (entry.getJpegPath()) |jp| {
                if (self.path_classifications.getPtr(jp)) |ptr| {
                    ptr.* = new_class;
                } else {
                    const owned_jp = try self.classification_arena.allocator().dupe(u8, jp);
                    try self.path_classifications.put(gpa, owned_jp, new_class);
                }
            }
        }
        return true;
    }

    pub fn markCurrentPick(self: *NavigationState, gpa: std.mem.Allocator) !bool {
        return self.markClassification(gpa, .pick);
    }

    pub fn markCurrentReject(self: *NavigationState, gpa: std.mem.Allocator) !bool {
        return self.markClassification(gpa, .reject);
    }

    pub fn unflagCurrent(self: *NavigationState, gpa: std.mem.Allocator) !bool {
        return self.markClassification(gpa, .unflagged);
    }

    /// Finds the nearest visible index to `start_idx`, searching forward first, then backward with SIMD.
    pub fn findClosestVisible(self: *const NavigationState, start_idx: usize) ?usize {
        const len = self.items.len;
        if (len == 0 or self.getVisibleCount() == 0) return null;
        const clamped = @min(start_idx, len - 1);
        const classes = self.items.items(.classification);

        // Forward search from clamped to len
        if (findNextVisibleInRange(classes, clamped, len, self.view_mode)) |idx| {
            return idx;
        }

        // Backward search from 0 to clamped - 1
        if (clamped > 0) {
            if (findPrevVisibleInRange(classes, 0, clamped - 1, self.view_mode)) |idx| {
                return idx;
            }
        }

        return null;
    }

    /// Adjusts `current_index` so it points to a visible item in the current view mode,
    /// preserving `anchor_index` if the current filter contains zero visible images.
    pub fn adjustIndexForVisibility(self: *NavigationState) bool {
        if (self.getVisibleCount() == 0) {
            const changed = self.current_index != null;
            self.current_index = null;
            return changed;
        }
        if (self.current_index) |cur| {
            if (self.isIndexVisible(cur)) return false;
            self.current_index = self.findClosestVisible(cur);
            if (self.current_index) |idx| self.anchor_index = idx;
            return true;
        } else {
            self.current_index = self.findClosestVisible(self.anchor_index);
            return self.current_index != null;
        }
    }

    /// Sets the active view mode and adjusts index if the current selection is hidden.
    pub fn setViewMode(self: *NavigationState, mode: ViewMode) bool {
        if (self.view_mode == mode) return false;
        self.view_mode = mode;
        _ = self.adjustIndexForVisibility();
        return true;
    }

    /// Cycles sequentially to the next view mode.
    pub fn cycleViewMode(self: *NavigationState) bool {
        return self.setViewMode(self.view_mode.cycle());
    }

    /// Advances the selection to the next visible image using circular SIMD scanning.
    pub fn nextIndex(self: *NavigationState) ?usize {
        self.slideshow.resetTimer();
        self.last_nav_time_ms = sdl.timer.getTicks();
        self.direction = .forward;
        const len = self.items.len;
        if (len == 0 or self.getVisibleCount() == 0) return null;

        const cur = self.current_index orelse self.anchor_index;
        const start = (cur + 1) % len;
        const classes = self.items.items(.classification);

        // Forward scan from [start..len]
        if (findNextVisibleInRange(classes, start, len, self.view_mode)) |idx| {
            self.current_index = idx;
            self.anchor_index = idx;
            return idx;
        }

        // Circular wrap-around scan from [0..start]
        if (start > 0) {
            if (findNextVisibleInRange(classes, 0, start, self.view_mode)) |idx| {
                self.current_index = idx;
                self.anchor_index = idx;
                return idx;
            }
        }

        return null;
    }

    /// Moves the selection to the previous visible image using circular SIMD scanning.
    pub fn prevIndex(self: *NavigationState) ?usize {
        self.slideshow.resetTimer();
        self.last_nav_time_ms = sdl.timer.getTicks();
        self.direction = .backward;
        const len = self.items.len;
        if (len == 0 or self.getVisibleCount() == 0) return null;

        const cur = self.current_index orelse self.anchor_index;
        const start = if (cur == 0) len - 1 else cur - 1;
        const classes = self.items.items(.classification);

        // Backward scan from [0..start]
        if (findPrevVisibleInRange(classes, 0, start, self.view_mode)) |idx| {
            self.current_index = idx;
            self.anchor_index = idx;
            return idx;
        }

        // Circular wrap-around scan from [start+1..len-1]
        if (start + 1 < len) {
            if (findPrevVisibleInRange(classes, start + 1, len - 1, self.view_mode)) |idx| {
                self.current_index = idx;
                self.anchor_index = idx;
                return idx;
            }
        }

        return null;
    }

    /// Directly sets the image selection to `idx` (or closest visible), clamped to valid bounds.
    pub fn goToIndex(self: *NavigationState, idx: usize) ?usize {
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
        self.last_nav_time_ms = sdl.timer.getTicks();
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
    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "a.jpg" } });
    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "b.jpg" } });
    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "c.jpg" } });
    nav.current_index = 0;

    _ = nav.nextIndex();
    try std.testing.expectEqual(@as(?usize, 1), nav.current_index);
    try std.testing.expectEqual(NavDirection.forward, nav.direction);

    _ = nav.prevIndex();
    try std.testing.expectEqual(@as(?usize, 0), nav.current_index);
    try std.testing.expectEqual(NavDirection.backward, nav.direction);

    _ = nav.goToIndex(2);
    try std.testing.expectEqual(@as(?usize, 2), nav.current_index);
    try std.testing.expectEqual(NavDirection.forward, nav.direction);

    _ = nav.goToIndex(0);
    try std.testing.expectEqual(@as(?usize, 0), nav.current_index);
    try std.testing.expectEqual(NavDirection.backward, nav.direction);
}

test "NavigationState - triage mutations and visibility filtering" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "1.jpg" } });
    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "2.jpg" } });
    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "3.jpg" } });
    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "4.jpg" } });
    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "5.jpg" } });
    nav.current_index = 0;

    try std.testing.expectEqual(@as(usize, 5), nav.getVisibleCount());

    // Flag #1 as pick, #3 as reject
    nav.current_index = 1;
    _ = try nav.markCurrentPick(allocator);
    nav.current_index = 3;
    _ = try nav.markCurrentReject(allocator);

    try std.testing.expectEqual(@as(usize, 1), nav.pick_count);
    try std.testing.expectEqual(@as(usize, 1), nav.reject_count);

    // In default view mode: 4 visible (1, 2, 3, 5; 4 is hidden)
    try std.testing.expectEqual(@as(usize, 4), nav.getVisibleCount());
    try std.testing.expect(nav.isIndexVisible(0));
    try std.testing.expect(nav.isIndexVisible(1));
    try std.testing.expect(nav.isIndexVisible(2));
    try std.testing.expect(!nav.isIndexVisible(3)); // rejected
    try std.testing.expect(nav.isIndexVisible(4));

    // Stepping skips rejected item #3: 2 -> 4 -> 0
    nav.current_index = 2;
    _ = nav.nextIndex();
    try std.testing.expectEqual(@as(?usize, 4), nav.current_index);
    _ = nav.nextIndex();
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

    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "photo.jpg" } });
    nav.current_index = 0;
    _ = try nav.markCurrentPick(allocator);
    try std.testing.expectEqual(Classification.pick, nav.getCurrentClassification());

    // Rescan clears entries
    nav.clearEntries();
    try std.testing.expectEqual(@as(usize, 0), nav.count());

    // Re-adding the same path restores its pick status
    try nav.appendEntry(allocator, .{ .filesystem = .{ .path = "photo.jpg" } });
    nav.current_index = 0;
    try std.testing.expectEqual(Classification.pick, nav.getCurrentClassification());
    try std.testing.expectEqual(@as(usize, 1), nav.pick_count);
}

test "NavigationState - SIMD skipping and popcount across large list" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    // Populate 100 entries
    var buf: [32]u8 = undefined;
    for (0..100) |i| {
        const path = try std.fmt.bufPrint(&buf, "img_{d}.jpg", .{i});
        try nav.appendEntry(allocator, .{ .filesystem = .{ .path = path } });
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
    _ = nav.nextIndex();
    try std.testing.expectEqual(@as(?usize, 45), nav.current_index);
    _ = nav.nextIndex();
    try std.testing.expectEqual(@as(?usize, 80), nav.current_index);
    _ = nav.nextIndex();
    try std.testing.expectEqual(@as(?usize, 10), nav.current_index);

    // Verify backward SIMD scanning across > 32 elements: 10 -> 80 -> 45 -> 10
    _ = nav.prevIndex();
    try std.testing.expectEqual(@as(?usize, 80), nav.current_index);
    _ = nav.prevIndex();
    try std.testing.expectEqual(@as(?usize, 45), nav.current_index);
    _ = nav.prevIndex();
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

    try nav.appendEntry(allocator, pair_entry);
    nav.current_index = 0;

    try std.testing.expectEqual(Classification.unflagged, nav.getCurrentClassification());
    _ = try nav.markCurrentPick(allocator);
    try std.testing.expectEqual(Classification.pick, nav.getCurrentClassification());

    // Verify both raw_path and jpeg_path are registered in path_classifications table
    try std.testing.expectEqual(
        Classification.pick,
        nav.path_classifications.get("photos/DSC00941.ARW").?,
    );
    try std.testing.expectEqual(
        Classification.pick,
        nav.path_classifications.get("photos/DSC00941.JPG").?,
    );

    // Unflagging clears both paths from table
    _ = try nav.unflagCurrent(allocator);
    try std.testing.expectEqual(Classification.unflagged, nav.getCurrentClassification());
    try std.testing.expect(nav.path_classifications.get("photos/DSC00941.ARW") == null);
    try std.testing.expect(nav.path_classifications.get("photos/DSC00941.JPG") == null);
}
