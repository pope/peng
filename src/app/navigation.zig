const std = @import("std");

pub const SlideshowMode = union(enum) {
    inactive,
    active: struct {
        interval_s: f32,
        timer_ms: f64,
    },

    pub fn tick(self: *SlideshowMode, delta_ms: f32) bool {
        switch (self.*) {
            .inactive => return false,
            .active => |*data| {
                if (data.interval_s <= 0.0) return false;
                data.timer_ms += delta_ms;
                if (data.timer_ms >= data.interval_s * 1000.0) {
                    data.timer_ms = 0.0;
                    return true;
                }
                return false;
            },
        }
    }

    pub fn resetTimer(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.timer_ms = 0.0,
        }
    }
};

pub const NavigationState = struct {
    image_list: std.ArrayList([]const u8) = .empty,
    current_index: ?usize = null,
    slideshow: SlideshowMode = .inactive,
    is_loading_files: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
