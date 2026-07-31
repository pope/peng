const std = @import("std");
const types = @import("types.zig");
const palette_state = @import("palette_state.zig");
const DisplayState = types.DisplayState;
const DragState = types.DragState;
const ViewportParams = types.ViewportParams;
const ViewerStats = types.ViewerStats;
const NavigationState = @import("navigation.zig").NavigationState;
const UiState = @import("ui_state.zig").UiState;

/// Pure Visual & UI Data Container for UI Layout & Rendering Passes.
///
/// Contains zero hardware device pointers, zero thread pools, zero memory allocators,
/// and zero I/O contexts. Safe for UI rendering, testing, and layout calculation.
pub const ViewerState = struct {
    viewport: ViewportParams = .{},
    navigation: NavigationState,
    ui: UiState,
    stats: ViewerStats = .{},
    rotation_map: std.StringHashMap(f32),

    display: DisplayState = .headless,
    drag_state: DragState = .none,

    running: bool = true,
    dirty: bool = true,
    generation: usize = 0,

    pub fn initHeadless(allocator: std.mem.Allocator) ViewerState {
        return .{
            .navigation = NavigationState.init(allocator),
            .ui = UiState.init(allocator),
            .rotation_map = .init(allocator),
            .display = .headless,
        };
    }

    pub fn deinit(self: *ViewerState, allocator: std.mem.Allocator, io: std.Io) void {
        self.navigation.deinit(allocator);
        self.ui.deinit(io, allocator);
        self.display.deinit(allocator);
        self.clearRotationMap(allocator);
        self.rotation_map.deinit();
    }

    pub inline fn isFullscreen(self: *const ViewerState) bool {
        return self.display.isFullscreen();
    }

    pub inline fn isSlideshowActive(self: *const ViewerState) bool {
        return self.navigation.isSlideshowActive();
    }

    pub fn resetZoomPan(self: *ViewerState) void {
        self.viewport.reset();
    }

    pub fn putRotation(self: *ViewerState, allocator: std.mem.Allocator, path: []const u8, angle: f32) !void {
        const duped_key = try allocator.dupe(u8, path);
        errdefer allocator.free(duped_key);

        const gop = try self.rotation_map.getOrPut(duped_key);
        if (gop.found_existing) {
            allocator.free(duped_key);
        }
        gop.value_ptr.* = angle;
    }

    pub fn clearRotationMap(self: *ViewerState, allocator: std.mem.Allocator) void {
        var it = self.rotation_map.keyIterator();
        while (it.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        self.rotation_map.clearRetainingCapacity();
    }
};
