const animation_state = @import("animation_state.zig");
const palette_state = @import("palette_state.zig");
const sdl = @import("sdl");
const std = @import("std");
const types = @import("types.zig");

const AnimationChannel = animation_state.AnimationChannel;
const CacheEntry = types.CacheEntry;
const MediaEntry = types.MediaEntry;
const OverlayState = types.OverlayState;
const SlideshowMode = types.SlideshowMode;
const SnackbarDisplay = types.SnackbarDisplay;
const UiRenderMetricsSnapshot = types.UiRenderMetricsSnapshot;
const ViewerStats = types.ViewerStats;
const ViewportParams = types.ViewportParams;

/// Active dissolve payload for image transitions between frames.
pub const ActiveImageDissolve = struct {
    prev_entry: CacheEntry,
    prev_rotation: f32,
};

/// Active dissolve state for image transitions between frames.
pub const ImageDissolve = union(enum) {
    none,
    active: ActiveImageDissolve,
};

/// Complete read-only UI frame snapshot separating the application update
/// phase from the render phase.
pub const UiViewModel = struct {
    is_fullscreen: bool,
    total_images: usize,
    image_list: []const MediaEntry = &.{},
    current_index: ?usize,
    current_image_entry: ?MediaEntry = null,
    current_entry: ?CacheEntry = null,
    is_loading_files: bool,
    slideshow: SlideshowMode = .inactive,
    manga_mode: bool = false,
    overlays: OverlayState,
    window_title: []const u8 = "Peng Image Viewer",
    viewport: ViewportParams,
    palette: *const palette_state.PaletteState,
    snackbar: SnackbarDisplay = .none,
    anim_values: [32]f32 = [_]f32{0.0} ** 32,
    debug_show_thumb: bool,
    is_thumb_crossfading: bool = false,
    image_dissolve: ImageDissolve = .none,
    current_time_ms: u64 = 0,
    stats: ViewerStats = .{},
    render_metrics: UiRenderMetricsSnapshot = .{},

    /// Returns the animated scalar value for the specified channel.
    pub inline fn anim(self: UiViewModel, channel: AnimationChannel) f32 {
        return self.anim_values[@intFromEnum(channel)];
    }
};

/// User data context passed to Clay text measurement callbacks containing font
/// handles and debug flags.
pub const MeasureTextUserData = struct {
    fonts: []const ?sdl.Font,
    is_debug_measuring: bool = false,
    allocator: std.mem.Allocator = undefined,
};
