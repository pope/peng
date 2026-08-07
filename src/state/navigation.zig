const std = @import("std");
const sdl = @import("sdl");
const types = @import("types.zig");
const SlideshowMode = types.SlideshowMode;

const MediaEntry = types.MediaEntry;

pub const NavigationState = struct {
    image_list: std.ArrayList(MediaEntry) = .empty,
    current_index: ?usize = null,
    slideshow: SlideshowMode = .inactive,
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
        self.last_scanned_dir.deinit(allocator);
        self.directory_arena.deinit();
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
