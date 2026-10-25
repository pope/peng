const sdl = @import("sdl");
const std = @import("std");
const types = @import("types.zig");

const Classification = types.Classification;
const MediaEntry = types.MediaEntry;
const MediaId = types.MediaId;
const SlideshowMode = types.SlideshowMode;
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
        .picks => @backingInt(Classification.pick),
        .rejects => @backingInt(Classification.reject),
        .unflagged => @backingInt(Classification.unflagged),
        .default => @backingInt(Classification.reject),
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
        .picks => @backingInt(Classification.pick),
        .rejects => @backingInt(Classification.reject),
        .unflagged => @backingInt(Classification.unflagged),
        .default => @backingInt(Classification.reject),
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
        .picks => @backingInt(Classification.pick),
        .rejects => @backingInt(Classification.reject),
        .unflagged => @backingInt(Classification.unflagged),
        .default => @backingInt(Classification.reject),
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

fn writeJsonStringSlice(jw: *std.json.Stringify, bytes: []const u8) !void {
    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    try std.json.Stringify.encodeJsonStringChars(bytes, .{}, jw.writer);
    try jw.writer.writeByte('"');
    jw.endWriteRaw();
}

fn writeEntryPathsJson(jw: *std.json.Stringify, entry: MediaEntry) !void {
    switch (entry) {
        .filesystem => |f| try writeJsonStringSlice(jw, f.path),
        .archive_entry => |a| {
            try jw.beginWriteRaw();
            try jw.writer.writeByte('"');
            try std.json.Stringify.encodeJsonStringChars(
                a.archive_path,
                .{},
                jw.writer,
            );
            try jw.writer.writeByte('#');
            try std.json.Stringify.encodeJsonStringChars(
                a.entry_name,
                .{},
                jw.writer,
            );
            try jw.writer.writeByte('"');
            jw.endWriteRaw();
        },
        .pair => |p| {
            try writeJsonStringSlice(jw, p.raw_path);
            try writeJsonStringSlice(jw, p.jpeg_path);
        },
    }
}

fn entryKeyCount(entry: MediaEntry) usize {
    return switch (entry) {
        .filesystem, .archive_entry => 1,
        .pair => 2,
    };
}

fn entryMatchesKey(entry: MediaEntry, key: []const u8) bool {
    return switch (entry) {
        .filesystem => |f| std.mem.eql(u8, f.path, key),
        .pair => |p| std.mem.eql(u8, p.raw_path, key) or
            std.mem.eql(u8, p.jpeg_path, key),
        .archive_entry => |a| key.len ==
            a.archive_path.len + 1 + a.entry_name.len and
            std.mem.startsWith(u8, key, a.archive_path) and
            key[a.archive_path.len] == '#' and
            std.mem.endsWith(u8, key, a.entry_name),
    };
}

fn containsItemWithKey(entries: []const MediaEntry, key: []const u8) bool {
    for (entries) |entry| {
        if (entryMatchesKey(entry, key)) return true;
    }
    return false;
}

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

/// Tracks the active media list, current image index, slideshow progression, and directory cache.
pub const NavigationState = struct {
    items: std.MultiArrayList(MediaItem) = .empty,
    next_media_id: u32 = 1,
    path_classifications: std.StringArrayHashMapUnmanaged(Classification) =
        .empty,
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
    active_file_scans: std.atomic.Value(usize) = .init(0),
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

    fn lookupEntryClassification(
        self: *const NavigationState,
        entry: MediaEntry,
    ) Classification {
        switch (entry) {
            .filesystem => |f| {
                return self.path_classifications.get(f.path) orelse .unflagged;
            },
            .pair => |p| {
                if (self.path_classifications.get(p.raw_path)) |c| return c;
                if (self.path_classifications.get(p.jpeg_path)) |c| return c;
                return .unflagged;
            },
            .archive_entry => |a| {
                var stack_buf: [1024]u8 = undefined;
                if (std.mem.print(
                    &stack_buf,
                    "{s}#{s}",
                    .{ a.archive_path, a.entry_name },
                )) |composite_key| {
                    return self.path_classifications.get(composite_key) orelse
                        .unflagged;
                } else |_| {
                    return .unflagged;
                }
            },
        }
    }

    fn storeKeyClassification(
        self: *NavigationState,
        gpa: std.mem.Allocator,
        key: []const u8,
        new_class: Classification,
    ) !void {
        if (new_class == .unflagged) {
            _ = self.path_classifications.orderedRemove(key);
            return;
        }
        if (self.path_classifications.getPtr(key)) |ptr| {
            ptr.* = new_class;
        } else {
            const owned = try self.classification_arena.allocator().dupe(
                u8,
                key,
            );
            try self.path_classifications.put(gpa, owned, new_class);
        }
    }

    fn syncEntryClassificationKeys(
        self: *NavigationState,
        gpa: std.mem.Allocator,
        entry: MediaEntry,
        new_class: Classification,
    ) !void {
        switch (entry) {
            .filesystem => |f| {
                try self.storeKeyClassification(gpa, f.path, new_class);
            },
            .pair => |p| {
                try self.storeKeyClassification(gpa, p.raw_path, new_class);
                try self.storeKeyClassification(gpa, p.jpeg_path, new_class);
            },
            .archive_entry => |a| {
                var stack_buf: [1024]u8 = undefined;
                if (std.mem.print(
                    &stack_buf,
                    "{s}#{s}",
                    .{ a.archive_path, a.entry_name },
                )) |composite_key| {
                    try self.storeKeyClassification(
                        gpa,
                        composite_key,
                        new_class,
                    );
                } else |_| {
                    const owned = try self.classification_arena
                        .allocator()
                        .print("{s}#{s}", .{ a.archive_path, a.entry_name });
                    if (new_class == .unflagged) {
                        _ = self.path_classifications.orderedRemove(owned);
                    } else {
                        try self.path_classifications.put(
                            gpa,
                            owned,
                            new_class,
                        );
                    }
                }
            },
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
        const initial_class = self.lookupEntryClassification(entry);
        try self.items.append(gpa, .{
            .id = id,
            .entry = entry,
            .classification = initial_class,
        });
        errdefer _ = self.items.pop();

        if (initial_class != .unflagged) {
            try self.syncEntryClassificationKeys(gpa, entry, initial_class);
        }
        if (initial_class == .pick) self.pick_count += 1;
        if (initial_class == .reject) self.reject_count += 1;
        if (id.toU32() >= self.next_media_id) {
            self.next_media_id = id.toU32() +% 1;
            if (self.next_media_id == 0) self.next_media_id = 1;
        }
    }

    /// Clears active media list, preserving persistent path flags and allocated capacities.
    pub fn clearEntries(self: *NavigationState) void {
        self.items.clearRetainingCapacity();
        self.pick_count = 0;
        self.reject_count = 0;
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

        const entry = self.items.items(.entry)[idx];
        try self.syncEntryClassificationKeys(gpa, entry, new_class);

        classes[idx] = new_class;
        if (old_class == .pick) self.pick_count -= 1;
        if (old_class == .reject) self.reject_count -= 1;
        if (new_class == .pick) self.pick_count += 1;
        if (new_class == .reject) self.reject_count += 1;
        return true;
    }

    /// Marks the currently selected image as a pick.
    pub fn markCurrentPick(self: *NavigationState, gpa: std.mem.Allocator) !bool {
        return self.markClassification(gpa, .pick);
    }

    /// Marks the currently selected image as a reject.
    pub fn markCurrentReject(self: *NavigationState, gpa: std.mem.Allocator) !bool {
        return self.markClassification(gpa, .reject);
    }

    /// Clears the classification flag on the currently selected image.
    pub fn unflagCurrent(self: *NavigationState, gpa: std.mem.Allocator) !bool {
        return self.markClassification(gpa, .unflagged);
    }

    /// Clears all pick and reject classifications across both the active media
    /// list and persistent path table. Returns `true` if any flags were
    /// cleared.
    pub fn clearAllClassifications(self: *NavigationState) bool {
        const had_flags = (self.pick_count > 0 or
            self.reject_count > 0 or
            self.path_classifications.count() > 0);
        @memset(self.items.items(.classification), .unflagged);
        self.pick_count = 0;
        self.reject_count = 0;
        self.path_classifications.clearRetainingCapacity();
        _ = self.classification_arena.reset(.retain_capacity);
        return had_flags;
    }

    /// Serializes current pick and reject selections as a single-line JSON
    /// object (`{"ok":true,"picks":[...],"rejects":[...]}\n`) to `writer`.
    pub fn writeSelectionsJson(
        self: *const NavigationState,
        writer: *std.Io.Writer,
    ) !void {
        var jw: std.json.Stringify = .{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("ok");
        try jw.write(true);

        const slice = self.items.slice();
        const entries = slice.items(.entry);
        const classes = slice.items(.classification);

        var active_key_count: usize = 0;
        if (self.pick_count > 0 or self.reject_count > 0) {
            for (entries, classes) |entry, c| {
                if (c != .unflagged) active_key_count += entryKeyCount(entry);
            }
        }
        const has_external_keys =
            self.path_classifications.count() > active_key_count;

        try jw.objectField("picks");
        try jw.beginArray();
        if (self.pick_count > 0) {
            for (entries, classes) |entry, c| {
                if (c != .pick) continue;
                try writeEntryPathsJson(&jw, entry);
            }
        }
        if (has_external_keys) {
            for (
                self.path_classifications.keys(),
                self.path_classifications.values(),
            ) |k, c| {
                if (c != .pick) continue;
                if (!containsItemWithKey(entries, k)) {
                    try writeJsonStringSlice(&jw, k);
                }
            }
        }
        try jw.endArray();

        try jw.objectField("rejects");
        try jw.beginArray();
        if (self.reject_count > 0) {
            for (entries, classes) |entry, c| {
                if (c != .reject) continue;
                try writeEntryPathsJson(&jw, entry);
            }
        }
        if (has_external_keys) {
            for (
                self.path_classifications.keys(),
                self.path_classifications.values(),
            ) |k, c| {
                if (c != .reject) continue;
                if (!containsItemWithKey(entries, k)) {
                    try writeJsonStringSlice(&jw, k);
                }
            }
        }
        try jw.endArray();

        try jw.endObject();
        try writer.writeByte('\n');
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

    /// Returns the next circularly visible index after `from_idx` without
    /// mutating navigation state, or `null` if no visible items exist.
    pub fn peekNextVisible(
        self: *const NavigationState,
        from_idx: usize,
    ) ?usize {
        const len = self.items.len;
        if (len == 0 or self.getVisibleCount() == 0) return null;
        const cur = @min(from_idx, len - 1);
        const start = (cur + 1) % len;
        const classes = self.items.items(.classification);

        // Forward scan from [start..len]
        if (findNextVisibleInRange(classes, start, len, self.view_mode)) |idx| {
            return idx;
        }

        // Circular wrap-around scan from [0..start]
        if (start > 0) {
            if (findNextVisibleInRange(
                classes,
                0,
                start,
                self.view_mode,
            )) |idx| {
                return idx;
            }
        }

        return null;
    }

    /// Returns the previous circularly visible index before `from_idx` without
    /// mutating navigation state, or `null` if no visible items exist.
    pub fn peekPrevVisible(
        self: *const NavigationState,
        from_idx: usize,
    ) ?usize {
        const len = self.items.len;
        if (len == 0 or self.getVisibleCount() == 0) return null;
        const cur = @min(from_idx, len - 1);
        const start = if (cur == 0) len - 1 else cur - 1;
        const classes = self.items.items(.classification);

        // Backward scan from [0..start]
        if (findPrevVisibleInRange(classes, 0, start, self.view_mode)) |idx| {
            return idx;
        }

        // Circular wrap-around scan from [start+1..len-1]
        if (start + 1 < len) {
            if (findPrevVisibleInRange(
                classes,
                start + 1,
                len - 1,
                self.view_mode,
            )) |idx| {
                return idx;
            }
        }

        return null;
    }

    /// Computes the visible ±1 and ±2 neighbor indices around `current_index`
    /// in the active `view_mode`.
    pub fn getVisibleNeighbors(
        self: *const NavigationState,
    ) ?VisibleNeighbors {
        const cur = self.current_index orelse return null;
        const len = self.items.len;
        if (cur >= len) return null;
        const vis_count = self.getVisibleCount();
        if (vis_count == 0) return null;
        if (vis_count == len) {
            return VisibleNeighbors.fromRawIndex(cur, len);
        }
        const next_1 = self.peekNextVisible(cur) orelse cur;
        const prev_1 = self.peekPrevVisible(cur) orelse cur;
        const next_2 = self.peekNextVisible(next_1) orelse next_1;
        const prev_2 = self.peekPrevVisible(prev_1) orelse prev_1;
        return .{
            .current = cur,
            .next_1 = next_1,
            .prev_1 = prev_1,
            .next_2 = next_2,
            .prev_2 = prev_2,
        };
    }

    /// Advances selection to the next visible image using circular SIMD scan.
    pub fn nextIndex(self: *NavigationState) ?usize {
        self.slideshow.resetTimer();
        self.last_nav_time_ms = @max(1, sdl.timer.getTicks());
        self.direction = .forward;
        const cur = self.current_index orelse self.anchor_index;
        if (self.peekNextVisible(cur)) |idx| {
            self.current_index = idx;
            self.anchor_index = idx;
            return idx;
        }
        return null;
    }

    /// Moves selection to the previous visible image using circular SIMD scan.
    pub fn prevIndex(self: *NavigationState) ?usize {
        self.slideshow.resetTimer();
        self.last_nav_time_ms = @max(1, sdl.timer.getTicks());
        self.direction = .backward;
        const cur = self.current_index orelse self.anchor_index;
        if (self.peekPrevVisible(cur)) |idx| {
            self.current_index = idx;
            self.anchor_index = idx;
            return idx;
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
        self.last_nav_time_ms = @max(1, sdl.timer.getTicks());
        self.current_index = target;
        self.anchor_index = target;
        return self.current_index;
    }
};

/// Visible neighbor indices around `current` at steps ±1 and ±2 in the active
/// `ViewMode`.
pub const VisibleNeighbors = struct {
    current: usize,
    next_1: usize,
    prev_1: usize,
    next_2: usize,
    prev_2: usize,

    /// Constructs circular ±1 and ±2 neighbors around `idx` in an unfiltered
    /// list of length `len` (`len > 0`).
    pub fn fromRawIndex(idx: usize, len: usize) VisibleNeighbors {
        std.debug.assert(len > 0);
        return .{
            .current = idx,
            .next_1 = (idx + 1) % len,
            .prev_1 = (idx + len - 1) % len,
            .next_2 = (idx + 2) % len,
            .prev_2 = if (len >= 2) (idx + len - 2) % len else idx,
        };
    }

    /// Returns the step distance (`0`, `1`, or `2`) if `index` is in the
    /// visible ±2 window, or `null` if it is outside the window.
    pub fn stepDistance(self: VisibleNeighbors, index: usize) ?usize {
        if (index == self.current) return 0;
        if (index == self.next_1 or index == self.prev_1) return 1;
        if (index == self.next_2 or index == self.prev_2) return 2;
        return null;
    }

    /// Populates `out` with unique visible indices ordered by `direction` and
    /// capped by `max_step_dist` (`0..2`), returning the active slice.
    pub fn collectUnique(
        self: VisibleNeighbors,
        direction: NavDirection,
        max_step_dist: usize,
        out: *[5]usize,
    ) []const usize {
        out[0] = self.current;
        var count: usize = 1;

        const Candidate = struct { idx: usize, dist: usize };
        const candidates = if (direction == .backward)
            [_]Candidate{
                .{ .idx = self.prev_1, .dist = 1 },
                .{ .idx = self.next_1, .dist = 1 },
                .{ .idx = self.prev_2, .dist = 2 },
                .{ .idx = self.next_2, .dist = 2 },
            }
        else
            [_]Candidate{
                .{ .idx = self.next_1, .dist = 1 },
                .{ .idx = self.prev_1, .dist = 1 },
                .{ .idx = self.next_2, .dist = 2 },
                .{ .idx = self.prev_2, .dist = 2 },
            };

        for (candidates) |cand| {
            if (cand.dist > max_step_dist) continue;
            var unique = true;
            for (out[0..count]) |existing| {
                if (existing == cand.idx) {
                    unique = false;
                    break;
                }
            }
            if (unique) {
                out[count] = cand.idx;
                count += 1;
            }
        }
        return out[0..count];
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

    _ = try nav.appendEntry(allocator, pair_entry);
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
    try std.testing.expectEqual(
        Classification.unflagged,
        nav.getCurrentClassification(),
    );
    try std.testing.expect(
        nav.path_classifications.get("photos/DSC00941.ARW") == null,
    );
    try std.testing.expect(
        nav.path_classifications.get("photos/DSC00941.JPG") == null,
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
    // the RAW companion path in path_classifications
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
        nav.path_classifications.get("photos/shot.ARW").?,
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
    try std.testing.expectEqual(@as(usize, 0), nav.reject_count);
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
    try std.testing.expectEqual(@as(usize, 0), nav.pick_count);
    try std.testing.expectEqual(@as(usize, 0), nav.reject_count);

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
