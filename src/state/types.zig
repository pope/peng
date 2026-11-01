const geom = @import("geom");
const intents = @import("intents");
const std = @import("std");
const triage = @import("triage");
const viewport = @import("viewport.zig");

const Classification = triage.Classification;
const DirectionFlags = viewport.DirectionFlags;
const DpiScale = geom.DpiScale;
const EditParam = intents.EditParam;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;
const LogicalDims = geom.LogicalDims;
const LogicalPoint = geom.LogicalPoint;
const PhysicalPoint = geom.PhysicalPoint;
const ViewMode = triage.ViewMode;
const ZoomFlags = viewport.ZoomFlags;

/// Tagged union representing the visibility state of the current view.
/// Distinguishes empty directories, active filtered empty states, and valid
/// image selections.
pub const VisibleState = union(enum) {
    /// No images discovered or loaded in the current directory.
    empty_directory,
    /// Filter mode active with zero matching images, preventing the stuck
    /// loading screen bug.
    filtered_empty: struct {
        mode: ViewMode,
        total_count: usize,
    },
    /// A visible image is actively selected.
    selected: struct {
        raw_index: usize,
        visible_index: usize,
        visible_count: usize,
        total_count: usize,
        classification: Classification,
    },
};

/// Window close or process termination request accumulated during frame input
/// polling.
pub const QuitRequest = enum {
    none,
    /// User requested closing the window (`SDL_EVENT_WINDOW_CLOSE_REQUESTED`).
    /// Hides the window in `--server` mode; exits the process in normal mode.
    window_close,
    /// OS or signal requested process termination (`SDL_EVENT_QUIT`, `SIGINT`,
    /// `SIGTERM`). Unconditionally terminates the process even in `--server`
    /// mode.
    terminate,
};

/// Aggregated input events, mouse coordinates, keyboard actions, and window
/// metrics for a single frame iteration.
pub const FrameInput = struct {
    win_w: f32,
    win_h: f32,
    scale_x: f32,
    scale_y: f32,
    mouse_x: f32,
    mouse_y: f32,
    mouse_left_down: bool,
    mouse_left_clicked: bool,
    mouse_inside: bool,
    quit_request: QuitRequest = .none,
    scroll_delta_x: f32,
    scroll_delta_y: f32,
    pinch_delta: f32 = 0.0,
    pinch_center_x: f32 = 0.0,
    pinch_center_y: f32 = 0.0,
    keys_pressed: std.ArrayList(Key),
    key_modifiers: KeyModifiers,
    directional_held: DirectionFlags = .{},
    zoom_held: ZoomFlags = .{},
    text_input: ?[]const u8,
    dropped_path: ?[]const u8,
    delta_time_ms: f32,
    /// Current frame timestamp in milliseconds.
    now_ms: u64 = 0,

    /// Returns the sanitized display DPI scale factor for this frame.
    pub inline fn dpiScale(self: FrameInput) DpiScale {
        return DpiScale.init(self.scale_x, self.scale_y);
    }

    /// Returns the window dimensions in logical UI points.
    pub inline fn logicalWinDims(self: FrameInput) LogicalDims {
        return .{ .w = self.win_w, .h = self.win_h };
    }

    /// Returns the mouse cursor coordinates in logical UI points.
    pub inline fn logicalMousePos(self: FrameInput) LogicalPoint {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    /// Returns the mouse cursor coordinates scaled to physical framebuffer
    /// pixels.
    pub inline fn physicalMousePos(self: FrameInput) PhysicalPoint {
        return self.logicalMousePos().toPhysical(self.dpiScale());
    }

    /// Returns the mouse X coordinate scaled to physical framebuffer pixels.
    pub inline fn pixMouseX(self: FrameInput) f32 {
        return self.physicalMousePos().x;
    }

    /// Returns the mouse Y coordinate scaled to physical framebuffer pixels.
    pub inline fn pixMouseY(self: FrameInput) f32 {
        return self.physicalMousePos().y;
    }
};

/// Unique identification tags for interactive UI layout elements.
pub const ElementTag = enum(usize) {
    none = 0,
    image_viewer = 1,
    drop_zone_box = 2,
    blurred_surface = 3,

    /// Converts element tag enum to raw integer index.
    pub fn toInt(self: ElementTag) usize {
        return @backingInt(self);
    }

    /// Converts raw integer index to corresponding `ElementTag` enum variant.
    pub fn fromInt(val: usize) ElementTag {
        return switch (val) {
            1 => .image_viewer,
            2 => .drop_zone_box,
            3 => .blurred_surface,
            else => .none,
        };
    }
};

/// Title display visibility modes, unifying permanent pinned display and
/// transient auto-hide timer.
pub const TitleDisplay = union(enum) {
    hidden,
    pinned,
    transient: struct {
        timeout_ms: u64,
    },

    /// Returns true if title display is pinned open.
    pub fn isPinned(self: TitleDisplay) bool {
        return self == .pinned;
    }
};

pub const EDIT_PANEL_WIDTH: f32 = 280.0;
pub const EDIT_PANEL_PADDING: f32 = 16.0;

/// Side panel state managing visibility and active slider interactions
/// for image adjustments.
pub const EditPanelState = struct {
    visible: bool = false,
    active_slider: ?EditParam = null,
    width: f32 = EDIT_PANEL_WIDTH,

    /// Toggles edit panel visibility, clearing active slider interaction on
    /// close.
    pub fn toggle(self: *EditPanelState) void {
        self.visible = !self.visible;
        if (!self.visible) self.active_slider = null;
    }

    /// Explicitly closes the edit panel.
    pub fn close(self: *EditPanelState) void {
        self.visible = false;
        self.active_slider = null;
    }
};

/// Floating HUD panel state managing visibility and user-dragged 2D offset
/// coordinates.
pub const FloatingPanel = struct {
    visible: bool = false,
    offset_x: f32 = 0.0,
    offset_y: f32 = 0.0,
};

/// Automatic slideshow playback mode, advance interval, accumulated frame
/// timer, and pause state.
pub const SlideshowMode = union(enum) {
    inactive,
    active: struct {
        interval_s: f32,
        timer_ms: f64 = 0.0,
        is_paused: bool = false,
    },

    pub const MIN_INTERVAL_S: f32 = 0.1;
    pub const MAX_INTERVAL_S: f32 = 3600.0;

    /// Advances the internal slideshow timer by `delta_ms`; returns `true`
    /// if the interval has elapsed. Does NOT advance when paused or inactive.
    pub fn tick(self: *SlideshowMode, delta_ms: f32) bool {
        switch (self.*) {
            .inactive => return false,
            .active => |*data| {
                if (data.is_paused or data.interval_s <= 0.0) return false;
                data.timer_ms += delta_ms;
                if (data.timer_ms >= data.interval_s * 1000.0) {
                    data.timer_ms = 0.0;
                    return true;
                }
                return false;
            },
        }
    }

    /// Resets the slideshow timer accumulator to zero without changing the
    /// interval or pause state.
    pub fn resetTimer(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.timer_ms = 0.0,
        }
    }

    /// Returns `true` if slideshow is active and currently paused.
    pub inline fn isPaused(self: *const SlideshowMode) bool {
        return switch (self.*) {
            .inactive => false,
            .active => |a| a.is_paused,
        };
    }

    /// Pauses timer accumulation without changing interval or resetting
    /// elapsed progress.
    pub fn pause(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.is_paused = true,
        }
    }

    /// Resumes timer accumulation from its current elapsed position.
    pub fn unpause(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.is_paused = false,
        }
    }

    /// Toggles the pause state of an active slideshow. Has no effect when
    /// inactive.
    pub fn togglePause(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.is_paused = !a.is_paused,
        }
    }

    /// Returns `true` if the slideshow is currently running (active).
    pub inline fn isActive(self: SlideshowMode) bool {
        return self == .active;
    }
};

/// Transition state holding the previous image's index, orientation, zoom,
/// and pan for crossfade animation.
pub const ActiveImageTransition = struct {
    prev_index: usize,
    prev_rotation: f32,
    prev_zoom: f32 = 1.0,
    prev_pan_x: f32 = 0.0,
    prev_pan_y: f32 = 0.0,
};

/// Navigation image transition lifecycle state tracking crossfade source.
pub const ImageTransition = union(enum) {
    none,
    active: ActiveImageTransition,

    /// Safely retrieves previous index if transition is active.
    pub inline fn getPrevIndex(self: ImageTransition) ?usize {
        return switch (self) {
            .none => null,
            .active => |a| a.prev_index,
        };
    }
};

/// Grace period threshold in milliseconds before displaying "Loading image..."
/// in the UI. Prevents text flickering when scrubbing through thumbnails or
/// fast-decoding formats (~2 frames at 60Hz).
pub const LOADING_GRACE_PERIOD_MS: u64 = 35;

/// Pending asynchronous screenshot request with target destination path and
/// IPC stream.
pub const ActiveScreenshot = struct {
    path: [:0]const u8,
    stream: std.Io.net.Stream,

    /// Writes a JSON success confirmation (`{"ok":true}\n`) back to the client
    /// IPC stream and frees request resources.
    pub fn respondOk(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
    ) void {
        var write_buf: [128]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        std.json.Stringify.value(
            .{ .ok = true },
            .{},
            &writer.interface,
        ) catch |werr| {
            std.log.warn("Screenshot response failed: {}", .{werr});
        };
        writer.interface.writeByte('\n') catch |werr| {
            std.log.warn("Screenshot newline write failed: {}", .{werr});
        };
        writer.interface.flush() catch |ferr| {
            std.log.warn("Screenshot response flush failed: {}", .{ferr});
        };
        self.stream.close(io);
        gpa.free(self.path);
    }

    /// Writes a JSON error response (`{"ok":false,"error":"<name>"}\n`) back to
    /// the client IPC stream and frees request resources.
    pub fn respondErr(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
        err: anyerror,
    ) void {
        self.respondErrName(io, gpa, @errorName(err));
    }

    /// Sends an emergency `{"ok":false,"error":"quit"}\n` response to the
    /// client IPC stream when exiting unexpectedly.
    pub fn respondQuit(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
    ) void {
        self.respondErrName(io, gpa, "quit");
    }

    /// Writes a JSON error response (`{"ok":false,"error":"<err_name>"}\n`) to
    /// the client IPC stream and frees request resources.
    pub fn respondErrName(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
        err_name: []const u8,
    ) void {
        var write_buf: [160]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        std.json.Stringify.value(
            .{ .ok = false, .@"error" = err_name },
            .{},
            &writer.interface,
        ) catch |werr| {
            std.log.warn("Screenshot error response failed: {}", .{werr});
        };
        writer.interface.writeByte('\n') catch |werr| {
            std.log.warn("Screenshot error newline write failed: {}", .{werr});
        };
        writer.interface.flush() catch |ferr| {
            std.log.warn("Screenshot response flush failed: {}", .{ferr});
        };
        self.stream.close(io);
        gpa.free(self.path);
    }
};

/// Represents current active mouse drag interaction state across the viewer UI.
pub const DragState = union(enum) {
    none,
    viewport: struct {
        last_x: f32,
        last_y: f32,
    },
    info: struct {
        start_x: f32,
        start_y: f32,
    },
    stats: struct {
        start_x: f32,
        start_y: f32,
    },
    atlas: struct {
        start_x: f32,
        start_y: f32,
    },
    slider: struct {
        param: EditParam,
        track_x: f32,
        track_w: f32,
    },
};

/// Visibility modes, floating panel positions, and rendering flags for HUD
/// overlays.
pub const OverlayState = struct {
    info_panel: FloatingPanel = .{
        .visible = false,
        .offset_x = 20.0,
        .offset_y = 20.0,
    },
    stats_panel: FloatingPanel = .{
        .visible = false,
        .offset_x = -20.0,
        .offset_y = 20.0,
    },
    atlas_panel: FloatingPanel = .{
        .visible = false,
        .offset_x = 20.0,
        .offset_y = 20.0,
    },
    edit_panel: EditPanelState = .{},
    title_display: TitleDisplay = .hidden,
    auto_title: bool = true,
    debug_show_thumb: bool = false,
    enable_blur: bool = true,

    /// Returns true if any floating HUD dialogs (Info, Stats, or Atlas) are
    /// visible.
    pub fn hasVisibleFloatingPanels(self: OverlayState) bool {
        return self.info_panel.visible or
            self.stats_panel.visible or
            self.atlas_panel.visible;
    }

    /// Dismisses all visible floating HUD dialogs.
    /// Returns true if at least one dialog was open; false otherwise.
    pub fn dismissFloatingPanels(self: *OverlayState) bool {
        const had_visible = self.hasVisibleFloatingPanels();
        self.info_panel.visible = false;
        self.stats_panel.visible = false;
        self.atlas_panel.visible = false;
        return had_visible;
    }
};

/// Active transient notification message shown in the top-center HUD bar.
pub const ActiveSnackbar = struct {
    message: []const u8,
    reveal: f32,
};

/// Read-only snapshot of current snackbar notification state for UI
/// presentation.
pub const SnackbarDisplay = union(enum) {
    none,
    active: ActiveSnackbar,

    /// Safely retrieves active snackbar notification payload if present.
    pub fn getActive(self: SnackbarDisplay) ?ActiveSnackbar {
        return switch (self) {
            .none => null,
            .active => |a| a,
        };
    }
};

test "FrameInput.pixMouseX and pixMouseY scale mouse by display scale" {
    const input = FrameInput{
        .win_w = 1000.0,
        .win_h = 800.0,
        .scale_x = 2.0,
        .scale_y = 2.0,
        .mouse_x = 150.0,
        .mouse_y = 250.0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .scroll_delta_x = 0.0,
        .scroll_delta_y = 0.0,
        .keys_pressed = undefined,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };
    try std.testing.expectEqual(@as(f32, 300.0), input.pixMouseX());
    try std.testing.expectEqual(@as(f32, 500.0), input.pixMouseY());
}

test "ElementTag.fromInt" {
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0));
    try std.testing.expectEqual(
        ElementTag.drop_zone_box,
        ElementTag.fromInt(2),
    );
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(1337));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(9999));
    try std.testing.expectEqual(
        ElementTag.none,
        ElementTag.fromInt(0x7fffffffd000),
    );
}

test "SnackbarDisplay getActive" {
    const none_display: SnackbarDisplay = .none;
    try std.testing.expect(none_display.getActive() == null);

    const active_display: SnackbarDisplay = .{
        .active = .{ .reveal = 0.85, .message = "Filter: Lanczos3" },
    };
    const payload = active_display.getActive().?;
    try std.testing.expectEqual(@as(f32, 0.85), payload.reveal);
    try std.testing.expectEqualStrings("Filter: Lanczos3", payload.message);
}

test "SlideshowMode lifecycle, pause, and unpause" {
    // Inactive mode does not tick
    var mode: SlideshowMode = .inactive;
    try std.testing.expect(!mode.isPaused());
    try std.testing.expect(!mode.tick(1000.0));

    // Active mode ticking
    mode = .{ .active = .{ .interval_s = 2.0 } };
    try std.testing.expect(!mode.isPaused());

    // Advance 1s (halfway) -> returns false
    try std.testing.expect(!mode.tick(1000.0));
    try std.testing.expectEqual(@as(f64, 1000.0), mode.active.timer_ms);

    // Pause slideshow -> tick returns false and timer DOES NOT advance
    mode.pause();
    try std.testing.expect(mode.isPaused());
    try std.testing.expect(!mode.tick(1000.0));
    try std.testing.expectEqual(@as(f64, 1000.0), mode.active.timer_ms);

    // Resume -> timer continues from 1000ms
    mode.unpause();
    try std.testing.expect(!mode.isPaused());
    try std.testing.expect(mode.tick(1000.0));
    try std.testing.expectEqual(@as(f64, 0.0), mode.active.timer_ms);
}

test "ImageTransition getPrevIndex and variants" {
    var trans: ImageTransition = .none;
    try std.testing.expectEqual(@as(?usize, null), trans.getPrevIndex());

    trans = .{ .active = .{ .prev_index = 42, .prev_rotation = 180.0 } };
    try std.testing.expectEqual(@as(?usize, 42), trans.getPrevIndex());
    try std.testing.expectEqual(@as(f32, 180.0), trans.active.prev_rotation);

    trans = .none;
    try std.testing.expectEqual(@as(?usize, null), trans.getPrevIndex());
}

test "OverlayState floating panel dismissal" {
    var overlays = OverlayState{};
    try std.testing.expect(!overlays.hasVisibleFloatingPanels());
    try std.testing.expect(!overlays.dismissFloatingPanels());

    // Show info panel
    overlays.info_panel.visible = true;
    try std.testing.expect(overlays.hasVisibleFloatingPanels());

    // Show stats panel as well
    overlays.stats_panel.visible = true;
    try std.testing.expect(overlays.hasVisibleFloatingPanels());

    // Dismiss should close both and return true
    try std.testing.expect(overlays.dismissFloatingPanels());
    try std.testing.expect(!overlays.info_panel.visible);
    try std.testing.expect(!overlays.stats_panel.visible);
    try std.testing.expect(!overlays.hasVisibleFloatingPanels());

    // Subsequent dismissal returns false
    try std.testing.expect(!overlays.dismissFloatingPanels());
}
