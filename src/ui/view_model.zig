const cache = @import("cache");
const palette_pkg = @import("palette");
const state = @import("state");
const triage = @import("triage");
const vfs = @import("vfs");

const AnimationChannel = state.AnimationChannel;
const CacheEntry = cache.CacheEntry;
const Classification = triage.Classification;
const MediaEntry = vfs.MediaEntry;
const MediaItemSlice = state.MediaItemSlice;
const OverlayState = state.OverlayState;
const PaletteState = palette_pkg.PaletteState;
const SlideshowMode = state.SlideshowMode;
const SnackbarDisplay = state.SnackbarDisplay;
const UiRenderMetricsSnapshot = state.UiRenderMetricsSnapshot;
const ViewerStats = state.ViewerStats;
const ViewMode = triage.ViewMode;
const ViewportParams = state.ViewportParams;
const VisibleState = state.VisibleState;

/// Active dissolve payload for image transitions between frames.
pub const ActiveImageDissolve = struct {
    prev_entry: CacheEntry,
    prev_rotation: f32,
    prev_zoom: f32 = 1.0,
    prev_pan_x: f32 = 0.0,
    prev_pan_y: f32 = 0.0,
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
    items: MediaItemSlice = .empty,
    current_index: ?usize,
    current_image_entry: ?MediaEntry = null,
    current_entry: ?CacheEntry = null,
    current_classification: Classification = .unflagged,
    view_mode: ViewMode = .default,
    visible_state: VisibleState = .empty_directory,
    visible_count: usize = 0,
    visible_position: ?usize = null,
    is_loading_files: bool,
    slideshow: SlideshowMode = .inactive,
    manga_mode: bool = false,
    overlays: OverlayState,
    window_title: []const u8 = "Peng Image Viewer",
    viewport: ViewportParams,
    palette: *const PaletteState,
    snackbar: SnackbarDisplay = .none,
    anim_values: [32]f32 = @splat(0.0),
    debug_show_thumb: bool,
    is_thumb_crossfading: bool = false,
    image_dissolve: ImageDissolve = .none,
    current_time_ms: u64 = 0,
    stats: ViewerStats = .{},
    render_metrics: UiRenderMetricsSnapshot = .{},

    /// Returns the animated scalar value for the specified channel.
    pub inline fn anim(self: UiViewModel, channel: AnimationChannel) f32 {
        return self.anim_values[@backingInt(channel)];
    }

    /// Safely retrieves the media entry at `idx` if within bounds.
    pub inline fn getMediaEntry(self: UiViewModel, idx: usize) ?MediaEntry {
        if (idx < self.items.len) {
            return self.items.items(.entry)[idx];
        }
        return null;
    }

    /// Safely retrieves the classification at `idx`, defaulting to `.unflagged`
    /// if out of bounds.
    pub inline fn getClassification(
        self: UiViewModel,
        idx: usize,
    ) Classification {
        if (idx < self.items.len) {
            return self.items.items(.classification)[idx];
        }
        return .unflagged;
    }
};
