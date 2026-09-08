const std = @import("std");
const sdl = @import("sdl");
const types = @import("types.zig");
const palette_state = @import("palette_state.zig");
const animation_state = @import("animation_state.zig");

const MediaEntry = types.MediaEntry;
const CacheEntry = types.CacheEntry;
const SlideshowMode = types.SlideshowMode;
const OverlayState = types.OverlayState;
const ViewportParams = types.ViewportParams;
const ViewerStats = types.ViewerStats;
const UiRenderMetricsSnapshot = types.UiRenderMetricsSnapshot;
const SnackbarDisplay = types.SnackbarDisplay;
const AnimationChannel = animation_state.AnimationChannel;

/// Complete read-only UI frame snapshot separating the application update phase from the render phase.
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
    palette_reveal: f32 = 1.0,
    thumb_crossfade: f32 = 1.0,
    title_overlay_reveal: f32 = 0.0,
    snackbar: SnackbarDisplay = .none,
    anim_values: [32]f32 = [_]f32{0.0} ** 32,
    debug_show_thumb: bool,
    is_thumb_crossfading: bool = false,
    current_time_ms: u64 = 0,
    stats: ViewerStats = .{},
    render_metrics: UiRenderMetricsSnapshot = .{},

    /// Returns the animated scalar value for the specified channel.
    pub inline fn anim(self: UiViewModel, channel: AnimationChannel) f32 {
        return self.anim_values[@intFromEnum(channel)];
    }
};

/// User data context passed to Clay text measurement callbacks containing font handles and debug flags.
pub const MeasureTextUserData = struct {
    fonts: []const ?sdl.Font,
    is_debug_measuring: bool = false,
    allocator: std.mem.Allocator = undefined,
};

test "UiViewModel current_time_ms and default values" {
    var palette = try palette_state.PaletteState.init(std.testing.allocator);
    defer palette.deinit();
    const model = UiViewModel{
        .is_fullscreen = false,
        .total_images = 0,
        .current_index = null,
        .is_loading_files = false,
        .overlays = .{},
        .viewport = .{},
        .palette = &palette,
        .debug_show_thumb = false,
    };
    try std.testing.expectEqual(@as(u64, 0), model.current_time_ms);
    try std.testing.expectEqual(@as(f32, 0.0), model.anim(.palette_reveal));
    try std.testing.expect(model.snackbar == .none);
}
