const std = @import("std");
const state_pkg = @import("state");
const SlideshowMode = state_pkg.SlideshowMode;

pub const NavigationState = struct {
    image_list: std.ArrayList([]const u8) = .empty,
    current_index: ?usize = null,
    slideshow: SlideshowMode = .inactive,
    is_loading_files: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_nav_time_ms: u64 = 0,
    last_scanned_dir: std.ArrayList(u8) = .empty,
    directory_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) NavigationState {
        return .{
            .directory_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *NavigationState, allocator: std.mem.Allocator) void {
        self.image_list.deinit(allocator);
        self.last_scanned_dir.deinit(allocator);
        self.directory_arena.deinit();
    }

    pub inline fn isSlideshowActive(self: *const NavigationState) bool {
        return self.slideshow == .active;
    }

    pub fn count(self: *const NavigationState) usize {
        return self.image_list.items.len;
    }

    pub fn getCurrentImagePath(self: *const NavigationState) ?[]const u8 {
        const idx = self.current_index orelse return null;
        if (idx < self.image_list.items.len) {
            return self.image_list.items[idx];
        }
        return null;
    }

    pub fn nextIndex(self: *NavigationState) ?usize {
        self.slideshow.resetTimer();
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
        const len = self.image_list.items.len;
        if (len == 0) return null;
        self.current_index = @min(idx, len - 1);
        return self.current_index;
    }
};
