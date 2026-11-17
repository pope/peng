const animation_state = @import("animation_state.zig");
const geom = @import("geom");
const intents = @import("intents");
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
const TouchTracker = types.TouchTracker;
const UiState = ui_state.UiState;
const ViewerStats = telemetry.ViewerStats;
const ViewportParams = viewport.ViewportParams;
const ZoomController = viewport.ZoomController;
const ZoomPreset = intents.ZoomPreset;

/// Default startup configuration options restored whenever the viewer window
/// is closed/hidden in server mode.
pub const ViewerDefaults = struct {
    default_scale: ZoomPreset = .full,
    enable_blur: bool = true,
    show_title: bool = false,
    auto_title: bool = true,
    snackbar_enabled: bool = true,
    crossfade: bool = true,
    stack_raw_jpeg: bool = true,
    windowless: bool = false,
};

/// Pure Visual & UI Data Container for UI Layout & Rendering Passes.
///
/// Contains zero hardware device pointers, zero thread pools, zero memory
/// allocators, and zero I/O contexts. Safe for UI rendering, testing, and
/// layout calculation.
pub const ViewerState = struct {
    defaults: ViewerDefaults = .{},
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
    touch_tracker: TouchTracker = .{},
    last_win_dims: LogicalDims = .{},

    server_mode: bool = false,
    running: bool = true,

    /// Resets all viewport, adjustment, filter, overlay, snackbar, animation,
    /// and navigation session settings back to the configured startup defaults.
    pub fn resetToDefaults(self: *ViewerState) void {
        self.viewport = .{
            .fit_mode = self.defaults.default_scale,
        };
        self.viewport.reset();

        self.ui.overlays = .{
            .enable_blur = self.defaults.enable_blur,
            .title_display = if (self.defaults.show_title) .pinned else .hidden,
            .auto_title = self.defaults.auto_title,
        };
        self.ui.snackbar = .{
            .enabled = self.defaults.snackbar_enabled,
        };
        self.ui.metrics = .{};

        self.animations = .{};
        if (self.defaults.show_title) {
            self.animations.setImmediate(.title_overlay, 1.0);
        }

        self.navigation.slideshow = .inactive;
        self.navigation.manga_mode = false;
        self.navigation.crossfade = self.defaults.crossfade;
        self.navigation.stack_raw_jpeg = self.defaults.stack_raw_jpeg;
        self.navigation.last_nav_time_ms = 0;
        self.navigation.direction = .forward;
        self.navigation.triage.view_mode = .default;

        self.stats = .{};
        self.image_transition = .none;
        self.drag_state = .none;
        self.pan_controller.reset();
        self.zoom_controller.reset();
        self.touch_tracker.reset();
    }

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

        var vs = ViewerState{
            .navigation = nav,
            .ui = ui,
            .animations = .{},
            .rotation_map = .empty,
        };
        vs.resetToDefaults();
        return vs;
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

test "ViewerState.resetToDefaults restores configured startup defaults" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var viewer = try ViewerState.initHeadless(allocator);
    defer viewer.deinit(allocator, io);

    viewer.defaults = .{
        .default_scale = .shrink,
        .enable_blur = false,
        .show_title = true,
        .auto_title = false,
        .snackbar_enabled = false,
        .crossfade = false,
        .stack_raw_jpeg = false,
        .windowless = true,
    };

    // Mutate session settings away from defaults
    viewer.viewport.fit_mode = .crop;
    viewer.viewport.mode = .fill;
    viewer.viewport.scale_filter = .lanczos3;
    viewer.viewport.setAdjustments(0.4, 1.8);
    viewer.viewport.edits.set(.saturation, 0.5);
    viewer.viewport.compare_original = true;
    viewer.viewport.rotation_angle = 180.0;
    viewer.ui.overlays.enable_blur = true;
    viewer.ui.overlays.title_display = .hidden;
    viewer.ui.overlays.info_panel.visible = true;
    viewer.ui.overlays.stats_panel.visible = true;
    viewer.ui.overlays.atlas_panel.visible = true;
    viewer.ui.overlays.edit_panel.visible = true;
    viewer.ui.overlays.debug_show_thumb = true;
    viewer.ui.snackbar.enabled = true;
    viewer.ui.snackbar.show("Modified", 5000);
    viewer.animations.setImmediate(.edit_panel, 1.0);
    viewer.animations.setImmediate(.title_overlay, 0.0);
    viewer.navigation.manga_mode = true;
    viewer.navigation.crossfade = true;
    viewer.navigation.stack_raw_jpeg = true;
    viewer.navigation.triage.view_mode = .picks;
    viewer.touch_tracker.count = 2;
    viewer.touch_tracker.last_dist = 50.0;

    viewer.resetToDefaults();

    try std.testing.expectEqual(@as(u4, 0), viewer.touch_tracker.count);
    try std.testing.expectEqual(@as(f32, 0.0), viewer.touch_tracker.last_dist);
    try std.testing.expectEqual(ZoomPreset.shrink, viewer.viewport.fit_mode);
    try std.testing.expectEqual(viewport.ZoomMode.fit, viewer.viewport.mode);
    try std.testing.expectEqual(
        intents.TextureScaleMode.linear,
        viewer.viewport.scale_filter,
    );
    try std.testing.expect(!viewer.viewport.hasAdjustments());
    try std.testing.expect(!viewer.viewport.compare_original);
    try std.testing.expectEqual(@as(f32, 0.0), viewer.viewport.rotation_angle);
    try std.testing.expect(!viewer.ui.overlays.enable_blur);
    try std.testing.expectEqual(
        types.TitleDisplay.pinned,
        viewer.ui.overlays.title_display,
    );
    try std.testing.expect(!viewer.ui.overlays.auto_title);
    try std.testing.expect(!viewer.ui.overlays.hasVisibleFloatingPanels());
    try std.testing.expect(!viewer.ui.overlays.edit_panel.visible);
    try std.testing.expect(!viewer.ui.overlays.debug_show_thumb);
    try std.testing.expect(!viewer.ui.snackbar.enabled);
    try std.testing.expectEqual(
        @as(usize, 0),
        viewer.ui.snackbar.getMessage().len,
    );
    try std.testing.expectEqual(
        @as(f32, 0.0),
        viewer.animations.get(.edit_panel),
    );
    try std.testing.expectEqual(
        @as(f32, 1.0),
        viewer.animations.get(.title_overlay),
    );
    try std.testing.expect(!viewer.navigation.manga_mode);
    try std.testing.expect(!viewer.navigation.crossfade);
    try std.testing.expect(!viewer.navigation.stack_raw_jpeg);
    try std.testing.expectEqual(
        .default,
        viewer.navigation.triage.view_mode,
    );
}
