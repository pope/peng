const std = @import("std");
const sdl = @import("sdl");
const types = @import("types.zig");
const SlideshowMode = types.SlideshowMode;

const MediaEntry = types.MediaEntry;

/// Direction of user navigation travel across the image list.
pub const NavDirection = enum {
    forward,
    backward,
};

/// Tracks the active media list, current image index, slideshow progression, and directory cache.
pub const NavigationState = struct {
    image_list: std.ArrayList(MediaEntry) = .empty,
    current_index: ?usize = null,
    slideshow: SlideshowMode = .inactive,
    manga_mode: bool = false,
    is_loading_files: std.atomic.Value(bool) = .init(false),
    last_nav_time_ms: u64 = 0,
    direction: NavDirection = .forward,
    last_scanned_dir: std.ArrayList(u8) = .empty,
    directory_arena: std.heap.ArenaAllocator,

    /// Initializes navigation state with pre-allocated buffer capacities.
    pub fn init(allocator: std.mem.Allocator) !NavigationState {
        var self = NavigationState{
            .directory_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.deinit(allocator);
        // 32 image path pointers: avoids reallocations when loading CLI args or medium-sized directory lists
        try self.image_list.ensureTotalCapacity(allocator, 32);
        // 128 bytes: accommodates standard file directory path strings (most paths are < 128 bytes)
        try self.last_scanned_dir.ensureTotalCapacity(allocator, 128);
        return self;
    }

    /// Releases the media list, directory string buffer, and directory arena allocator.
    pub fn deinit(self: *NavigationState, allocator: std.mem.Allocator) void {
        self.image_list.deinit(allocator);
        self.last_scanned_dir.deinit(allocator);
        self.directory_arena.deinit();
    }

    /// Returns `true` if slideshow playback mode is active.
    pub inline fn isSlideshowActive(self: *const NavigationState) bool {
        return self.slideshow == .active;
    }

    /// Returns the total count of discovered images in the current media list.
    pub fn count(self: *const NavigationState) usize {
        return self.image_list.items.len;
    }

    /// Retrieves the `MediaEntry` at `current_index`, or `null` if empty or invalid.
    pub fn getCurrentImageEntry(self: *const NavigationState) ?MediaEntry {
        const idx = self.current_index orelse return null;
        if (idx < self.image_list.items.len) {
            return self.image_list.items[idx];
        }
        return null;
    }

    /// Advances the selection to the next image with circular wraparound.
    pub fn nextIndex(self: *NavigationState) ?usize {
        self.slideshow.resetTimer();
        self.last_nav_time_ms = sdl.timer.getTicks();
        self.direction = .forward;
        const len = self.image_list.items.len;
        if (len == 0) return null;
        if (self.current_index) |idx| {
            self.current_index = (idx + 1) % len;
        } else {
            self.current_index = 0;
        }
        return self.current_index;
    }

    /// Moves the selection to the previous image with circular wraparound.
    pub fn prevIndex(self: *NavigationState) ?usize {
        self.slideshow.resetTimer();
        self.last_nav_time_ms = sdl.timer.getTicks();
        self.direction = .backward;
        const len = self.image_list.items.len;
        if (len == 0) return null;
        if (self.current_index) |idx| {
            if (idx == 0) {
                self.current_index = len - 1;
            } else {
                self.current_index = idx - 1;
            }
        } else {
            self.current_index = 0;
        }
        return self.current_index;
    }

    /// Directly sets the image selection to `idx`, clamped to valid bounds.
    pub fn goToIndex(self: *NavigationState, idx: usize) ?usize {
        const len = self.image_list.items.len;
        if (len == 0) return null;
        const target = @min(idx, len - 1);
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
        return self.current_index;
    }
};

test "NavigationState - direction tracking" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    try std.testing.expectEqual(NavDirection.forward, nav.direction);

    // Populate mock image list with 3 entries
    try nav.image_list.append(allocator, .{ .filesystem = .{ .path = "a.jpg" } });
    try nav.image_list.append(allocator, .{ .filesystem = .{ .path = "b.jpg" } });
    try nav.image_list.append(allocator, .{ .filesystem = .{ .path = "c.jpg" } });
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
