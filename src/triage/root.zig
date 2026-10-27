const intents = @import("intents");
const std = @import("std");
const vfs = @import("vfs");

const Classification = intents.Classification;
const MediaEntry = vfs.MediaEntry;
const ViewMode = intents.ViewMode;

const Vec32 = @Vector(32, u8);

const MAX_RETAINED_CLASS_ARENA_BYTES: usize = 64 * 1024;

/// Finds the next index in `[start, end)` matching the active view mode
/// using 256-bit SIMD.
fn findNextVisibleInRange(
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

/// Finds the previous index in `[min_idx, max_idx]` matching the active
/// view mode using 256-bit SIMD.
fn findPrevVisibleInRange(
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

/// Computes the count of visible items in `[0, count_limit)` using hardware
/// POPCNT and SIMD.
fn countVisibleInRangeSimd(
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

/// Computes the 1-based index of `cur_idx` among currently visible items
/// matching `mode` using SIMD hardware POPCNT. Returns `null` if `cur_idx` is
/// out of bounds or not visible in `mode`.
pub fn visiblePosition(
    classifications: []const Classification,
    cur_idx: usize,
    mode: ViewMode,
) ?usize {
    if (cur_idx >= classifications.len) return null;
    if (!mode.matches(classifications[cur_idx])) return null;
    if (mode == .all) return cur_idx + 1;
    const pos = countVisibleInRangeSimd(classifications, cur_idx + 1, mode);
    return if (pos > 0) pos else null;
}

/// Finds the nearest visible index to `start_idx` in `mode`, searching forward
/// first, then backward using SIMD. Returns `null` if no visible items exist.
pub fn findClosestVisible(
    classifications: []const Classification,
    start_idx: usize,
    visible_count: usize,
    mode: ViewMode,
) ?usize {
    const len = classifications.len;
    if (len == 0 or visible_count == 0) return null;
    const clamped = @min(start_idx, len - 1);

    // Forward search from clamped to len
    if (findNextVisibleInRange(classifications, clamped, len, mode)) |idx| {
        return idx;
    }

    // Backward search from 0 to clamped - 1
    if (clamped > 0) {
        if (findPrevVisibleInRange(
            classifications,
            0,
            clamped - 1,
            mode,
        )) |idx| {
            return idx;
        }
    }

    return null;
}

/// Returns the next circularly visible index after `from_idx` in `mode`,
/// or `null` if no visible items exist.
pub fn peekNextVisible(
    classifications: []const Classification,
    from_idx: usize,
    visible_count: usize,
    mode: ViewMode,
) ?usize {
    const len = classifications.len;
    if (len == 0 or visible_count == 0) return null;
    const cur = @min(from_idx, len - 1);
    const start = (cur + 1) % len;

    // Forward scan from [start..len]
    if (findNextVisibleInRange(classifications, start, len, mode)) |idx| {
        return idx;
    }

    // Circular wrap-around scan from [0..start]
    if (start > 0) {
        if (findNextVisibleInRange(classifications, 0, start, mode)) |idx| {
            return idx;
        }
    }

    return null;
}

/// Returns the previous circularly visible index before `from_idx` in `mode`,
/// or `null` if no visible items exist.
pub fn peekPrevVisible(
    classifications: []const Classification,
    from_idx: usize,
    visible_count: usize,
    mode: ViewMode,
) ?usize {
    const len = classifications.len;
    if (len == 0 or visible_count == 0) return null;
    const cur = @min(from_idx, len - 1);
    const start = if (cur == 0) len - 1 else cur - 1;

    // Backward scan from [0..start]
    if (findPrevVisibleInRange(classifications, 0, start, mode)) |idx| {
        return idx;
    }

    // Circular wrap-around scan from [start+1..len-1]
    if (start + 1 < len) {
        if (findPrevVisibleInRange(
            classifications,
            start + 1,
            len - 1,
            mode,
        )) |idx| {
            return idx;
        }
    }

    return null;
}

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

    /// Computes the visible ±1 and ±2 neighbor indices around `cur_idx` in
    /// `mode`, or `null` if empty or no items are visible.
    pub fn compute(
        classifications: []const Classification,
        cur_idx: usize,
        visible_count: usize,
        mode: ViewMode,
    ) ?VisibleNeighbors {
        const len = classifications.len;
        if (cur_idx >= len or visible_count == 0) return null;
        if (visible_count == len) {
            return VisibleNeighbors.fromRawIndex(cur_idx, len);
        }
        const next_1 = peekNextVisible(
            classifications,
            cur_idx,
            visible_count,
            mode,
        ) orelse cur_idx;
        const prev_1 = peekPrevVisible(
            classifications,
            cur_idx,
            visible_count,
            mode,
        ) orelse cur_idx;
        const next_2 = peekNextVisible(
            classifications,
            next_1,
            visible_count,
            mode,
        ) orelse next_1;
        const prev_2 = peekPrevVisible(
            classifications,
            prev_1,
            visible_count,
            mode,
        ) orelse prev_1;
        return .{
            .current = cur_idx,
            .next_1 = next_1,
            .prev_1 = prev_1,
            .next_2 = next_2,
            .prev_2 = prev_2,
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

    /// Returns `true` if `index` is within the visible ±2 neighborhood.
    pub fn contains(self: VisibleNeighbors, index: usize) bool {
        return self.stepDistance(index) != null;
    }

    /// Populates `out` with unique visible indices ordered by `direction` and
    /// capped by `max_step_dist` (`0..2`), returning the active slice.
    pub fn collectUnique(
        self: VisibleNeighbors,
        direction: anytype,
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

fn writeEntriesTsv(
    writer: *std.Io.Writer,
    entries: []const MediaEntry,
    classes: []const Classification,
    pick_count: usize,
    reject_count: usize,
) !void {
    if (pick_count == 0 and reject_count == 0) return;
    for (entries, classes) |entry, c| {
        const prefix = c.exportPrefix() orelse continue;
        switch (entry) {
            .filesystem => |f| {
                try writer.print("{s}\t{s}\n", .{ prefix, f.path });
            },
            .archive_entry => |a| {
                try writer.print(
                    "{s}\t{s}#{s}\n",
                    .{ prefix, a.archive_path, a.entry_name },
                );
            },
            .pair => |p| {
                try writer.print("{s}\t{s}\n", .{ prefix, p.raw_path });
                try writer.print("{s}\t{s}\n", .{ prefix, p.jpeg_path });
            },
        }
    }
}

/// Encapsulates persistent triage flag storage, arena-backed path keys,
/// and JSON export serialization.
pub const TriageMap = struct {
    path_classifications: std.StringArrayHashMapUnmanaged(Classification) =
        .empty,
    classification_arena: std.heap.ArenaAllocator,

    /// Initializes triage map with an initial capacity of 64 path entries.
    pub fn init(allocator: std.mem.Allocator) !TriageMap {
        var map = TriageMap{
            .classification_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer map.classification_arena.deinit();
        try map.path_classifications.ensureTotalCapacity(allocator, 64);
        return map;
    }

    /// Releases persistent path hash map and arena allocations.
    pub fn deinit(self: *TriageMap, allocator: std.mem.Allocator) void {
        self.path_classifications.deinit(allocator);
        self.classification_arena.deinit();
    }

    /// Resets classification arena retaining at most 64 KiB of memory pages.
    pub fn resetArena(self: *TriageMap) void {
        _ = self.classification_arena.reset(.{
            .retain_with_limit = MAX_RETAINED_CLASS_ARENA_BYTES,
        });
    }

    /// Returns the number of persisted path classifications.
    pub fn count(self: *const TriageMap) usize {
        return self.path_classifications.count();
    }

    /// Retrieves the classification for `key`, or `null` if unrecorded.
    pub fn get(self: *const TriageMap, key: []const u8) ?Classification {
        return self.path_classifications.get(key);
    }

    /// Looks up the classification for `entry`, returning `.unflagged` if
    /// not found.
    pub fn lookupEntry(
        self: *const TriageMap,
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

    /// Stores or removes a single classification key in the hash table.
    pub fn storeKey(
        self: *TriageMap,
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

    /// Synchronizes all paths associated with `entry` to `new_class`.
    pub fn syncEntryKeys(
        self: *TriageMap,
        gpa: std.mem.Allocator,
        entry: MediaEntry,
        new_class: Classification,
    ) !void {
        switch (entry) {
            .filesystem => |f| {
                try self.storeKey(gpa, f.path, new_class);
            },
            .pair => |p| {
                try self.storeKey(gpa, p.raw_path, new_class);
                try self.storeKey(gpa, p.jpeg_path, new_class);
            },
            .archive_entry => |a| {
                var stack_buf: [1024]u8 = undefined;
                if (std.mem.print(
                    &stack_buf,
                    "{s}#{s}",
                    .{ a.archive_path, a.entry_name },
                )) |composite_key| {
                    try self.storeKey(
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

    /// Clears all classification records while retaining capacity and resets
    /// the arena.
    pub fn clearRetainingCapacity(self: *TriageMap) void {
        self.path_classifications.clearRetainingCapacity();
        self.resetArena();
    }

    /// Serializes pick and reject selections as a single-line JSON object
    /// (`{"ok":true,"picks":[...],"rejects":[...]}\n`) to `writer`.
    pub fn writeSelectionsJson(
        self: *const TriageMap,
        writer: *std.Io.Writer,
        entries: []const MediaEntry,
        classes: []const Classification,
        pick_count: usize,
        reject_count: usize,
    ) !void {
        var jw: std.json.Stringify = .{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("ok");
        try jw.write(true);

        var active_key_count: usize = 0;
        if (pick_count > 0 or reject_count > 0) {
            for (entries, classes) |entry, c| {
                if (c != .unflagged) active_key_count += entryKeyCount(entry);
            }
        }
        const has_external_keys =
            self.path_classifications.count() > active_key_count;

        try jw.objectField("picks");
        try jw.beginArray();
        if (pick_count > 0) {
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
        if (reject_count > 0) {
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

    /// Serializes pick and reject selections as tab-separated rows
    /// (`PICK\t<path>\n` or `REJECT\t<path>\n`) to `writer`.
    pub fn writeSelectionsTsv(
        self: *const TriageMap,
        writer: *std.Io.Writer,
        entries: []const MediaEntry,
        classes: []const Classification,
        pick_count: usize,
        reject_count: usize,
    ) !void {
        try writeEntriesTsv(
            writer,
            entries,
            classes,
            pick_count,
            reject_count,
        );

        var active_key_count: usize = 0;
        if (pick_count > 0 or reject_count > 0) {
            for (entries, classes) |entry, c| {
                if (c != .unflagged) active_key_count += entryKeyCount(entry);
            }
        }
        if (self.path_classifications.count() > active_key_count) {
            for (
                self.path_classifications.keys(),
                self.path_classifications.values(),
            ) |k, c| {
                const prefix = c.exportPrefix() orelse continue;
                if (!containsItemWithKey(entries, k)) {
                    try writer.print("{s}\t{s}\n", .{ prefix, k });
                }
            }
        }
    }
};

test "triage - SIMD 256-bit vector scan boundary offsets" {
    var classes: [70]Classification = @splat(.unflagged);
    const boundaries = [_]usize{ 0, 31, 32, 33, 63, 64, 65 };

    for (boundaries) |b| {
        classes[b] = .pick;

        // Forward search from index 0
        try std.testing.expectEqual(
            @as(?usize, b),
            findNextVisibleInRange(&classes, 0, classes.len, .picks),
        );
        // Forward search from boundary itself
        try std.testing.expectEqual(
            @as(?usize, b),
            findNextVisibleInRange(&classes, b, classes.len, .picks),
        );
        // Forward search past boundary should yield null
        if (b + 1 < classes.len) {
            try std.testing.expectEqual(
                @as(?usize, null),
                findNextVisibleInRange(&classes, b + 1, classes.len, .picks),
            );
        }

        // Backward search from end
        try std.testing.expectEqual(
            @as(?usize, b),
            findPrevVisibleInRange(&classes, 0, classes.len - 1, .picks),
        );
        // Backward search from boundary itself
        try std.testing.expectEqual(
            @as(?usize, b),
            findPrevVisibleInRange(&classes, 0, b, .picks),
        );
        // Backward search before boundary should yield null
        if (b > 0) {
            try std.testing.expectEqual(
                @as(?usize, null),
                findPrevVisibleInRange(&classes, 0, b - 1, .picks),
            );
        }

        // SIMD population count
        try std.testing.expectEqual(
            @as(usize, 0),
            countVisibleInRangeSimd(&classes, b, .picks),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            countVisibleInRangeSimd(&classes, b + 1, .picks),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            countVisibleInRangeSimd(&classes, classes.len, .picks),
        );

        classes[b] = .unflagged;
    }

    // Test default mode (matching anything not marked reject)
    classes[32] = .reject;
    try std.testing.expectEqual(
        @as(?usize, 0),
        findNextVisibleInRange(&classes, 0, classes.len, .default),
    );
    try std.testing.expectEqual(
        @as(?usize, 33),
        findNextVisibleInRange(&classes, 32, classes.len, .default),
    );
    try std.testing.expectEqual(
        @as(usize, classes.len - 1),
        countVisibleInRangeSimd(&classes, classes.len, .default),
    );
}

test "triage - TriageMap lookup and sync" {
    const allocator = std.testing.allocator;
    var map = try TriageMap.init(allocator);
    defer map.deinit(allocator);

    const fs_entry: MediaEntry = .{
        .filesystem = .{ .path = "test/img1.png" },
    };
    try std.testing.expectEqual(
        Classification.unflagged,
        map.lookupEntry(fs_entry),
    );

    try map.syncEntryKeys(allocator, fs_entry, .pick);
    try std.testing.expectEqual(
        Classification.pick,
        map.lookupEntry(fs_entry),
    );
    try std.testing.expectEqual(
        @as(?Classification, .pick),
        map.get("test/img1.png"),
    );
    try std.testing.expectEqual(@as(usize, 1), map.count());

    // Pair entry
    const pair_entry: MediaEntry = .{
        .pair = .{
            .raw_path = "photos/shot.ARW",
            .jpeg_path = "photos/shot.JPG",
        },
    };
    try std.testing.expectEqual(
        Classification.unflagged,
        map.lookupEntry(pair_entry),
    );
    try map.syncEntryKeys(allocator, pair_entry, .reject);
    try std.testing.expectEqual(
        Classification.reject,
        map.lookupEntry(pair_entry),
    );
    try std.testing.expectEqual(
        @as(?Classification, .reject),
        map.get("photos/shot.ARW"),
    );
    try std.testing.expectEqual(
        @as(?Classification, .reject),
        map.get("photos/shot.JPG"),
    );
    try std.testing.expectEqual(@as(usize, 3), map.count());

    // Archive entry
    const arch_entry: MediaEntry = .{
        .archive_entry = .{
            .archive_path = "comics/book.cbz",
            .entry_name = "page01.jpg",
            .seek_info = .unindexed,
        },
    };
    try std.testing.expectEqual(
        Classification.unflagged,
        map.lookupEntry(arch_entry),
    );
    try map.syncEntryKeys(allocator, arch_entry, .pick);
    try std.testing.expectEqual(
        Classification.pick,
        map.lookupEntry(arch_entry),
    );
    try std.testing.expectEqual(
        @as(?Classification, .pick),
        map.get("comics/book.cbz#page01.jpg"),
    );

    // Unflag archive entry
    try map.syncEntryKeys(allocator, arch_entry, .unflagged);
    try std.testing.expectEqual(
        Classification.unflagged,
        map.lookupEntry(arch_entry),
    );
    try std.testing.expectEqual(
        @as(?Classification, null),
        map.get("comics/book.cbz#page01.jpg"),
    );

    // Clear retaining capacity
    map.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), map.count());
    try std.testing.expectEqual(
        Classification.unflagged,
        map.lookupEntry(fs_entry),
    );
}

test "triage - TriageMap resetArena 64 KiB cap" {
    const allocator = std.testing.allocator;
    var map = try TriageMap.init(allocator);
    defer map.deinit(allocator);

    const arena_alloc = map.classification_arena.allocator();
    const big_buf = try arena_alloc.alloc(u8, 512 * 1024 + 1024);
    @memset(big_buf, 0xbb);

    try std.testing.expect(
        map.classification_arena.queryCapacity() >
            MAX_RETAINED_CLASS_ARENA_BYTES,
    );

    map.resetArena();

    try std.testing.expect(
        map.classification_arena.queryCapacity() <=
            MAX_RETAINED_CLASS_ARENA_BYTES,
    );
}

test "triage - TriageMap writeSelectionsJson output format and escaping" {
    const allocator = std.testing.allocator;
    var map = try TriageMap.init(allocator);
    defer map.deinit(allocator);

    const pick_path = "photos/test \"special\"\n\t.jpg";
    const reject_path = "photos/bad.png";
    const entries = [_]MediaEntry{
        .{ .filesystem = .{ .path = pick_path } },
        .{ .filesystem = .{ .path = reject_path } },
    };
    const classes = [_]Classification{ .pick, .reject };

    try map.syncEntryKeys(allocator, entries[0], .pick);
    try map.syncEntryKeys(allocator, entries[1], .reject);

    // Add an external key not in entries list
    try map.storeKey(allocator, "photos/external_pick.jpg", .pick);

    var buf: [1024]u8 = undefined;
    var fixed_writer: std.Io.Writer = .fixed(&buf);

    try map.writeSelectionsJson(
        &fixed_writer,
        &entries,
        &classes,
        1,
        1,
    );

    const output = fixed_writer.buffered();
    try std.testing.expect(output.len > 0);
    try std.testing.expect(output[output.len - 1] == '\n');

    // Parse the JSON output with std.json to verify syntax validity
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        output[0 .. output.len - 1],
        .{},
    );
    defer parsed.deinit();

    const root_obj = parsed.value.object;
    try std.testing.expect(root_obj.get("ok").?.bool == true);
    const picks = root_obj.get("picks").?.array;
    try std.testing.expectEqual(@as(usize, 2), picks.items.len);
    try std.testing.expectEqualStrings(pick_path, picks.items[0].string);
    try std.testing.expectEqualStrings(
        "photos/external_pick.jpg",
        picks.items[1].string,
    );

    const rejects = root_obj.get("rejects").?.array;
    try std.testing.expectEqual(@as(usize, 1), rejects.items.len);
    try std.testing.expectEqualStrings(reject_path, rejects.items[0].string);
}

test "triage - VisibleNeighbors fromRawIndex, stepDistance, and contains" {
    const vn = VisibleNeighbors.fromRawIndex(2, 5);
    try std.testing.expectEqual(@as(usize, 2), vn.current);
    try std.testing.expectEqual(@as(usize, 3), vn.next_1);
    try std.testing.expectEqual(@as(usize, 1), vn.prev_1);
    try std.testing.expectEqual(@as(usize, 4), vn.next_2);
    try std.testing.expectEqual(@as(usize, 0), vn.prev_2);

    try std.testing.expectEqual(@as(?usize, 0), vn.stepDistance(2));
    try std.testing.expect(vn.contains(2));
    try std.testing.expectEqual(@as(?usize, 1), vn.stepDistance(3));
    try std.testing.expect(vn.contains(3));
    try std.testing.expectEqual(@as(?usize, 1), vn.stepDistance(1));
    try std.testing.expect(vn.contains(1));
    try std.testing.expectEqual(@as(?usize, 2), vn.stepDistance(4));
    try std.testing.expect(vn.contains(4));
    try std.testing.expectEqual(@as(?usize, 2), vn.stepDistance(0));
    try std.testing.expect(vn.contains(0));
    try std.testing.expectEqual(@as(?usize, null), vn.stepDistance(5));
    try std.testing.expect(!vn.contains(5));
    try std.testing.expectEqual(@as(?usize, null), vn.stepDistance(99));
    try std.testing.expect(!vn.contains(99));

    // Single item list
    const vn1 = VisibleNeighbors.fromRawIndex(0, 1);
    try std.testing.expectEqual(@as(usize, 0), vn1.current);
    try std.testing.expectEqual(@as(usize, 0), vn1.next_1);
    try std.testing.expectEqual(@as(usize, 0), vn1.prev_1);
    try std.testing.expectEqual(@as(usize, 0), vn1.next_2);
    try std.testing.expectEqual(@as(usize, 0), vn1.prev_2);
    try std.testing.expectEqual(@as(?usize, 0), vn1.stepDistance(0));
    try std.testing.expect(vn1.contains(0));
    try std.testing.expectEqual(@as(?usize, null), vn1.stepDistance(1));
    try std.testing.expect(!vn1.contains(1));

    // Two item list
    const vn2 = VisibleNeighbors.fromRawIndex(0, 2);
    try std.testing.expectEqual(@as(usize, 0), vn2.current);
    try std.testing.expectEqual(@as(usize, 1), vn2.next_1);
    try std.testing.expectEqual(@as(usize, 1), vn2.prev_1);
    try std.testing.expectEqual(@as(usize, 0), vn2.next_2);
    try std.testing.expectEqual(@as(usize, 0), vn2.prev_2);
}

test "triage - VisibleNeighbors collectUnique ordering and deduplication" {
    const Direction = enum { forward, backward };
    var out_buf: [5]usize = undefined;

    // 1. 5-item list, current = 2 (unique neighbors: 2, 3, 1, 4, 0)
    const vn5 = VisibleNeighbors.fromRawIndex(2, 5);

    // .forward ordering: [current, next_1, prev_1, next_2, prev_2]
    const fwd_0 = vn5.collectUnique(Direction.forward, 0, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{2}, fwd_0);

    const fwd_1 = vn5.collectUnique(Direction.forward, 1, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 3, 1 }, fwd_1);

    const fwd_2 = vn5.collectUnique(Direction.forward, 2, &out_buf);
    try std.testing.expectEqualSlices(
        usize,
        &[_]usize{ 2, 3, 1, 4, 0 },
        fwd_2,
    );

    // .backward ordering: [current, prev_1, next_1, prev_2, next_2]
    const bwd_0 = vn5.collectUnique(Direction.backward, 0, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{2}, bwd_0);

    const bwd_1 = vn5.collectUnique(Direction.backward, 1, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 1, 3 }, bwd_1);

    const bwd_2 = vn5.collectUnique(Direction.backward, 2, &out_buf);
    try std.testing.expectEqualSlices(
        usize,
        &[_]usize{ 2, 1, 3, 0, 4 },
        bwd_2,
    );

    // 2. 2-item list, current = 0 (overlapping indices:
    // next_1=1, prev_1=1, next_2=0, prev_2=0)
    const vn2 = VisibleNeighbors.fromRawIndex(0, 2);

    const fwd2_0 = vn2.collectUnique(Direction.forward, 0, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{0}, fwd2_0);

    const fwd2_1 = vn2.collectUnique(Direction.forward, 1, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1 }, fwd2_1);

    const fwd2_2 = vn2.collectUnique(Direction.forward, 2, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1 }, fwd2_2);

    const bwd2_1 = vn2.collectUnique(Direction.backward, 1, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1 }, bwd2_1);

    const bwd2_2 = vn2.collectUnique(Direction.backward, 2, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1 }, bwd2_2);

    // 3. 1-item list, current = 0 (all neighbors index 0)
    const vn1 = VisibleNeighbors.fromRawIndex(0, 1);
    const fwd1_2 = vn1.collectUnique(Direction.forward, 2, &out_buf);
    try std.testing.expectEqualSlices(usize, &[_]usize{0}, fwd1_2);
}

test "triage - visiblePosition calculation and bounds" {
    const classes = [_]Classification{
        .pick, // 0: visible in picks (pos 1), all (pos 1)
        .unflagged, // 1: visible in all (pos 2), not picks
        .pick, // 2: visible in picks (pos 2), all (pos 3)
        .reject, // 3: visible in all (pos 4), not picks
        .pick, // 4: visible in picks (pos 3), all (pos 5)
    };

    // Mode .picks
    try std.testing.expectEqual(
        @as(?usize, 1),
        visiblePosition(&classes, 0, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        visiblePosition(&classes, 1, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, 2),
        visiblePosition(&classes, 2, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        visiblePosition(&classes, 3, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, 3),
        visiblePosition(&classes, 4, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        visiblePosition(&classes, 5, .picks),
    );

    // Mode .all
    try std.testing.expectEqual(
        @as(?usize, 1),
        visiblePosition(&classes, 0, .all),
    );
    try std.testing.expectEqual(
        @as(?usize, 5),
        visiblePosition(&classes, 4, .all),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        visiblePosition(&classes, 10, .all),
    );
}

test "triage - findClosestVisible, peekNextVisible, and peekPrevVisible" {
    const classes = [_]Classification{
        .unflagged, // 0
        .pick, // 1
        .unflagged, // 2
        .reject, // 3
        .pick, // 4
    };
    // 2 picks: indices 1 and 4

    // findClosestVisible
    try std.testing.expectEqual(
        @as(?usize, 1),
        findClosestVisible(&classes, 0, 2, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        findClosestVisible(&classes, 1, 2, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, 4),
        findClosestVisible(&classes, 2, 2, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, 4),
        findClosestVisible(&classes, 3, 2, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, 4),
        findClosestVisible(&classes, 4, 2, .picks),
    );
    // Backward fallback when starting past last match
    const single_pick = [_]Classification{ .unflagged, .pick, .unflagged };
    try std.testing.expectEqual(
        @as(?usize, 1),
        findClosestVisible(&single_pick, 2, 1, .picks),
    );
    // Empty / zero visible count
    try std.testing.expectEqual(
        @as(?usize, null),
        findClosestVisible(&classes, 0, 0, .picks),
    );

    // peekNextVisible circular scan
    try std.testing.expectEqual(
        @as(?usize, 4),
        peekNextVisible(&classes, 1, 2, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        peekNextVisible(&classes, 4, 2, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        peekNextVisible(&classes, 0, 0, .picks),
    );

    // peekPrevVisible circular scan
    try std.testing.expectEqual(
        @as(?usize, 4),
        peekPrevVisible(&classes, 1, 2, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        peekPrevVisible(&classes, 4, 2, .picks),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        peekPrevVisible(&classes, 0, 0, .picks),
    );
}

test "triage - VisibleNeighbors.compute filtered and unfiltered windows" {
    const classes = [_]Classification{
        .pick, // 0
        .unflagged, // 1
        .pick, // 2
        .unflagged, // 3
        .pick, // 4
    };

    // Filtered mode: only 0, 2, 4 visible
    const vn_filt = VisibleNeighbors.compute(&classes, 0, 3, .picks);
    try std.testing.expect(vn_filt != null);
    if (vn_filt) |vn| {
        try std.testing.expectEqual(@as(usize, 0), vn.current);
        try std.testing.expectEqual(@as(usize, 2), vn.next_1);
        try std.testing.expectEqual(@as(usize, 4), vn.prev_1);
        try std.testing.expectEqual(@as(usize, 4), vn.next_2);
        try std.testing.expectEqual(@as(usize, 2), vn.prev_2);
    }

    // Unfiltered mode (all visible)
    const vn_all = VisibleNeighbors.compute(&classes, 2, 5, .all);
    try std.testing.expect(vn_all != null);
    if (vn_all) |vn| {
        try std.testing.expectEqual(@as(usize, 2), vn.current);
        try std.testing.expectEqual(@as(usize, 3), vn.next_1);
        try std.testing.expectEqual(@as(usize, 1), vn.prev_1);
        try std.testing.expectEqual(@as(usize, 4), vn.next_2);
        try std.testing.expectEqual(@as(usize, 0), vn.prev_2);
    }

    // Zero visible items returns null
    try std.testing.expectEqual(
        @as(?VisibleNeighbors, null),
        VisibleNeighbors.compute(&classes, 0, 0, .picks),
    );

    // Out of bounds index returns null
    try std.testing.expectEqual(
        @as(?VisibleNeighbors, null),
        VisibleNeighbors.compute(&classes, 99, 3, .picks),
    );
}

test "triage - writeSelectionsTsv format and external keys" {
    const allocator = std.testing.allocator;
    var map = try TriageMap.init(allocator);
    defer map.deinit(allocator);

    const entries = [_]MediaEntry{
        .{ .filesystem = .{ .path = "photos/img1.jpg" } },
        .{
            .archive_entry = .{
                .archive_path = "bundle.zip",
                .entry_name = "sub/img2.png",
            },
        },
        .{
            .pair = .{
                .raw_path = "photos/shot.raw",
                .jpeg_path = "photos/shot.jpg",
            },
        },
        .{ .filesystem = .{ .path = "photos/skip.jpg" } },
    };
    const classes = [_]Classification{ .pick, .reject, .pick, .unflagged };

    var buf: [1024]u8 = undefined;
    var fixed_writer: std.Io.Writer = .fixed(&buf);

    // 1. TriageMap.writeSelectionsTsv without external keys
    try map.writeSelectionsTsv(&fixed_writer, &entries, &classes, 2, 1);
    const expected_top =
        "PICK\tphotos/img1.jpg\n" ++
        "REJECT\tbundle.zip#sub/img2.png\n" ++
        "PICK\tphotos/shot.raw\n" ++
        "PICK\tphotos/shot.jpg\n";
    try std.testing.expectEqualStrings(expected_top, fixed_writer.buffered());

    // 2. TriageMap.writeSelectionsTsv with external key
    try map.syncEntryKeys(allocator, entries[0], .pick);
    try map.syncEntryKeys(allocator, entries[1], .reject);
    try map.syncEntryKeys(allocator, entries[2], .pick);
    try map.storeKey(allocator, "photos/external.jpg", .pick);

    var map_buf: [1024]u8 = undefined;
    var map_writer: std.Io.Writer = .fixed(&map_buf);
    try map.writeSelectionsTsv(&map_writer, &entries, &classes, 2, 1);
    const expected_map =
        "PICK\tphotos/img1.jpg\n" ++
        "REJECT\tbundle.zip#sub/img2.png\n" ++
        "PICK\tphotos/shot.raw\n" ++
        "PICK\tphotos/shot.jpg\n" ++
        "PICK\tphotos/external.jpg\n";
    try std.testing.expectEqualStrings(expected_map, map_writer.buffered());
}
