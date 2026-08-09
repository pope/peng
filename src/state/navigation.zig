const std = @import("std");
const sdl = @import("sdl");
const types = @import("types.zig");
const SlideshowMode = types.SlideshowMode;

const MediaEntry = types.MediaEntry;

pub const NavigationState = struct {
    image_list: std.ArrayList(MediaEntry) = .empty,
    current_index: ?usize = null,
    slideshow: SlideshowMode = .inactive,
    manga_mode: bool = false,
    view_mode: types.ViewLayoutMode = .single_page,
    strip_spans: std.ArrayList(types.ImageSpan) = .empty,
    visible_frustum: types.VisibleFrustum = .{},
    known_aspect_ratios: std.ArrayList(f32) = .empty,
    is_loading_files: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_nav_time_ms: u64 = 0,
    last_scanned_dir: std.ArrayList(u8) = .empty,
    directory_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) !NavigationState {
        var self = NavigationState{
            .directory_arena = std.heap.ArenaAllocator.init(allocator),
        };
        // 32 image path pointers: avoids reallocations when loading CLI args or medium-sized directory lists
        try self.image_list.ensureTotalCapacity(allocator, 32);
        // 128 bytes: accommodates standard file directory path strings (most paths are < 128 bytes)
        try self.last_scanned_dir.ensureTotalCapacity(allocator, 128);
        return self;
    }

    pub fn deinit(self: *NavigationState, allocator: std.mem.Allocator) void {
        self.image_list.deinit(allocator);
        self.strip_spans.deinit(allocator);
        self.known_aspect_ratios.deinit(allocator);
        self.last_scanned_dir.deinit(allocator);
        self.directory_arena.deinit();
    }

    /// Sets or updates the persistent measured aspect ratio (W / H) for image at `idx`.
    pub fn setKnownAspectRatio(self: *NavigationState, allocator: std.mem.Allocator, idx: usize, ratio: f32) void {
        if (ratio <= 0.0) return;
        if (idx >= self.known_aspect_ratios.items.len) {
            self.known_aspect_ratios.appendNTimes(allocator, 0.0, (idx + 1) - self.known_aspect_ratios.items.len) catch return;
        }
        self.known_aspect_ratios.items[idx] = ratio;
    }

    /// Returns the persistent measured aspect ratio for image at `idx`, or 0.0 if not yet measured.
    pub fn getKnownAspectRatio(self: *const NavigationState, idx: usize) f32 {
        if (idx < self.known_aspect_ratios.items.len) {
            return self.known_aspect_ratios.items[idx];
        }
        return 0.0;
    }

    pub inline fn isSlideshowActive(self: *const NavigationState) bool {
        return self.slideshow == .active;
    }

    pub fn count(self: *const NavigationState) usize {
        return self.image_list.items.len;
    }

    pub fn getCurrentImageEntry(self: *const NavigationState) ?MediaEntry {
        const idx = self.current_index orelse return null;
        if (idx < self.image_list.items.len) {
            return self.image_list.items[idx];
        }
        return null;
    }

    pub fn nextIndex(self: *NavigationState) ?usize {
        self.slideshow.resetTimer();
        self.last_nav_time_ms = sdl.timer.getTicks();
        const len = self.image_list.items.len;
        if (len == 0) return null;
        if (self.current_index) |idx| {
            self.current_index = (idx + 1) % len;
        } else {
            self.current_index = 0;
        }
        return self.current_index;
    }

    pub fn prevIndex(self: *NavigationState) ?usize {
        self.slideshow.resetTimer();
        self.last_nav_time_ms = sdl.timer.getTicks();
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

    pub fn goToIndex(self: *NavigationState, idx: usize) ?usize {
        self.slideshow.resetTimer();
        self.last_nav_time_ms = sdl.timer.getTicks();
        const len = self.image_list.items.len;
        if (len == 0) return null;
        self.current_index = @min(idx, len - 1);
        return self.current_index;
    }
};

test "NavigationState setKnownAspectRatio and getKnownAspectRatio" {
    const allocator = std.testing.allocator;
    var nav = try NavigationState.init(allocator);
    defer nav.deinit(allocator);

    try std.testing.expectEqual(@as(f32, 0.0), nav.getKnownAspectRatio(0));
    try std.testing.expectEqual(@as(f32, 0.0), nav.getKnownAspectRatio(5));

    nav.setKnownAspectRatio(allocator, 2, 1.777);
    try std.testing.expectEqual(@as(f32, 0.0), nav.getKnownAspectRatio(0));
    try std.testing.expectEqual(@as(f32, 0.0), nav.getKnownAspectRatio(1));
    try std.testing.expectApproxEqAbs(@as(f32, 1.777), nav.getKnownAspectRatio(2), 0.001);

    // Overwriting index 2
    nav.setKnownAspectRatio(allocator, 2, 1.333);
    try std.testing.expectApproxEqAbs(@as(f32, 1.333), nav.getKnownAspectRatio(2), 0.001);
}
