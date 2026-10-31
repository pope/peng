const animation_state = @import("animation_state.zig");
const geom = @import("geom");
const navigation = @import("navigation.zig");
const std = @import("std");
const telemetry = @import("telemetry.zig");
const types = @import("types.zig");
const ui_state = @import("ui_state.zig");
const viewport = @import("viewport.zig");

const AnimationState = animation_state.AnimationState;
const DragState = types.DragState;
const ImageTransition = types.ImageTransition;
const LogicalDims = geom.LogicalDims;
const NavigationState = navigation.NavigationState;
const PanController = viewport.PanController;
const UiState = ui_state.UiState;
const ViewerStats = telemetry.ViewerStats;
const ViewportParams = viewport.ViewportParams;
const ZoomController = viewport.ZoomController;

/// Pure Visual & UI Data Container for UI Layout & Rendering Passes.
///
/// Contains zero hardware device pointers, zero thread pools, zero memory
/// allocators, and zero I/O contexts. Safe for UI rendering, testing, and
/// layout calculation.
pub const ViewerState = struct {
    viewport: ViewportParams = .{},
    navigation: NavigationState,
    ui: UiState,
    animations: AnimationState,
    stats: ViewerStats = .{},
    rotation_map: std.StringHashMapUnmanaged(f32) = .empty,

    drag_state: DragState = .none,

    image_transition: ImageTransition = .none,

    mouse_inside: bool = true,
    pan_controller: PanController = .{},
    zoom_controller: ZoomController = .{},
    last_win_dims: LogicalDims = .{},

    server_mode: bool = false,
    running: bool = true,

    /// Returns the protected previous image index if an image dissolve
    /// transition is active.
    pub inline fn getTransitionPrevIndex(self: *const ViewerState) ?usize {
        return self.image_transition.getPrevIndex();
    }

    /// Initializes a headless `ViewerState` instance for CLI, testing, and
    /// batch processing.
    pub fn initHeadless(allocator: std.mem.Allocator) !ViewerState {
        var nav = try NavigationState.init(allocator);
        errdefer nav.deinit(allocator);

        var ui = try UiState.init(allocator);
        errdefer ui.palette.deinit();

        return .{
            .navigation = nav,
            .ui = ui,
            .animations = .{},
            .rotation_map = .empty,
        };
    }

    /// Releases navigation, UI, animations, and rotation map resources.
    pub fn deinit(
        self: *ViewerState,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) void {
        self.navigation.deinit(allocator);
        self.ui.deinit(io, allocator);
        self.clearRotationMap(allocator);
        self.rotation_map.deinit(allocator);
    }

    /// Returns `true` if slideshow mode is active and advancing images on
    /// a timer.
    pub inline fn isSlideshowActive(self: *const ViewerState) bool {
        return self.navigation.isSlideshowActive();
    }

    /// Returns `true` if any animation channel is currently in progress.
    pub inline fn hasActiveAnimation(self: *const ViewerState) bool {
        return self.animations.hasActiveAnimations();
    }

    /// Resets pan offsets and zoom level to default viewport framing.
    pub fn resetZoomPan(self: *ViewerState) void {
        self.viewport.reset();
    }

    /// Associates an override rotation angle with an image file path in the
    /// rotation map.
    pub fn putRotation(
        self: *ViewerState,
        allocator: std.mem.Allocator,
        path: []const u8,
        angle: f32,
    ) !void {
        const duped_key = try allocator.dupe(u8, path);
        errdefer allocator.free(duped_key);

        const gop = try self.rotation_map.getOrPut(allocator, duped_key);
        if (gop.found_existing) {
            allocator.free(duped_key);
        }
        gop.value_ptr.* = angle;
    }

    /// Frees all duplicated path keys stored in the rotation map and clears
    /// its table.
    pub fn clearRotationMap(
        self: *ViewerState,
        allocator: std.mem.Allocator,
    ) void {
        var it = self.rotation_map.keyIterator();
        while (it.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        self.rotation_map.clearRetainingCapacity();
    }
};
