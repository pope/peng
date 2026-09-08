//! Data State Module
//!
//! Encapsulates application domain state models, view parameters,
//! type wrappers, input data structures, and view transform calculations.
//! Has zero dependencies on UI rendering or app logic.

pub const animation_state = @import("animation_state.zig");
pub const easing = @import("easing.zig");
pub const fuzzig = @import("fuzzig");
pub const navigation = @import("navigation.zig");
pub const palette_state = @import("palette_state.zig");
pub const snackbar = @import("snackbar.zig");
pub const types = @import("types.zig");
pub const ui_state = @import("ui_state.zig");
pub const view_model = @import("view_model.zig");
pub const viewer_state = @import("viewer_state.zig");
pub const view_transform = @import("view_transform.zig");

pub const ActionMetadata = types.ActionMetadata;
pub const ActiveSlideshowDissolve = view_model.ActiveSlideshowDissolve;
pub const ActiveSlideshowTransition = types.ActiveSlideshowTransition;
pub const ActiveSnackbar = types.ActiveSnackbar;
pub const ActiveWindow = types.ActiveWindow;
pub const AnimationChannel = animation_state.AnimationChannel;
pub const AnimationState = animation_state.AnimationState;
pub const ArchiveMediaEntry = types.ArchiveMediaEntry;
pub const CacheEntry = types.CacheEntry;
pub const CacheStatus = types.CacheStatus;
pub const computeThumbnailUvCrop = view_transform.computeThumbnailUvCrop;
pub const CpuSurfaceComponent = types.CpuSurfaceComponent;
pub const DirectoryEntry = palette_state.DirectoryEntry;
pub const DisplayState = types.DisplayState;
pub const DragState = types.DragState;
pub const DURATION_PALETTE_CLOSE_MS = animation_state.DURATION_PALETTE_CLOSE_MS;
pub const DURATION_PALETTE_OPEN_MS = animation_state.DURATION_PALETTE_OPEN_MS;
pub const DURATION_SLIDESHOW_DISSOLVE_MS = animation_state.DURATION_SLIDESHOW_DISSOLVE_MS;
pub const DURATION_SNACKBAR_CLOSE_MS = animation_state.DURATION_SNACKBAR_CLOSE_MS;
pub const DURATION_SNACKBAR_OPEN_MS = animation_state.DURATION_SNACKBAR_OPEN_MS;
pub const DURATION_THUMB_CROSSFADE_MS = animation_state.DURATION_THUMB_CROSSFADE_MS;
pub const DURATION_TITLE_OVERLAY_CLOSE_MS = animation_state.DURATION_TITLE_OVERLAY_CLOSE_MS;
pub const DURATION_TITLE_OVERLAY_OPEN_MS = animation_state.DURATION_TITLE_OVERLAY_OPEN_MS;
pub const EasingType = easing.EasingType;
pub const ElementTag = types.ElementTag;
pub const EntryScanCounts = palette_state.EntryScanCounts;
pub const EntryScanState = palette_state.EntryScanState;
pub const flat_shortcuts = types.flat_shortcuts;
pub const FrameInput = types.FrameInput;
pub const getPaletteConfig = palette_state.getPaletteConfig;
pub const GpuTextureComponent = types.GpuTextureComponent;
pub const LOADING_GRACE_PERIOD_MS = types.LOADING_GRACE_PERIOD_MS;
pub const MeasureTextUserData = view_model.MeasureTextUserData;
pub const MediaEntry = types.MediaEntry;
pub const MIN_SLIDESHOW_DISSOLVE_INTERVAL_S = animation_state.MIN_SLIDESHOW_DISSOLVE_INTERVAL_S;
pub const NavDirection = navigation.NavDirection;
pub const NavigationState = navigation.NavigationState;
pub const Orientation = types.Orientation;
pub const OverlayState = types.OverlayState;
pub const palette_action_items = types.palette_action_items;
pub const PaletteConfig = palette_state.PaletteConfig;
pub const PaletteState = palette_state.PaletteState;
pub const RawMetadata = types.RawMetadata;
pub const ScoredMatch = palette_state.ScoredMatch;
pub const SlideshowDissolve = view_model.SlideshowDissolve;
pub const SlideshowMode = types.SlideshowMode;
pub const SlideshowTransition = types.SlideshowTransition;
pub const SnackbarDisplay = types.SnackbarDisplay;
pub const SnackbarRule = snackbar.SnackbarRule;
pub const SnackbarState = snackbar.SnackbarState;
pub const SnackbarTrigger = snackbar.SnackbarTrigger;
pub const stopTextInput = types.stopTextInput;
pub const ThumbComponent = types.ThumbComponent;
pub const ThumbnailState = types.ThumbnailState;
pub const UiRenderMetrics = types.UiRenderMetrics;
pub const UiRenderMetricsSnapshot = types.UiRenderMetricsSnapshot;
pub const UiState = ui_state.UiState;
pub const UiViewModel = view_model.UiViewModel;
pub const UvRect = types.UvRect;
pub const ViewerState = viewer_state.ViewerState;
pub const ViewParams = types.ViewParams;
pub const ViewportParams = types.ViewportParams;
pub const ZoomFactor = types.ZoomFactor;

test {
    _ = animation_state;
    _ = easing;
    _ = navigation;
    _ = palette_state;
    _ = snackbar;
    _ = types;
    _ = ui_state;
    _ = view_model;
    _ = view_transform;
    _ = viewer_state;
}
