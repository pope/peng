//! Data State Module
//!
//! Encapsulates application domain state models, view parameters,
//! type wrappers, input data structures, and view transform calculations.
//! Has zero dependencies on UI rendering or app logic.

pub const animation_state = @import("animation_state.zig");
pub const easing = @import("easing.zig");
pub const interaction = @import("interaction.zig");
pub const navigation = @import("navigation.zig");
pub const snackbar = @import("snackbar.zig");
pub const telemetry = @import("telemetry.zig");
pub const types = @import("types.zig");
pub const ui_state = @import("ui_state.zig");
pub const viewer_state = @import("viewer_state.zig");
pub const view_transform = @import("view_transform.zig");
pub const viewport = @import("viewport.zig");

pub const activeDurationMs = telemetry.activeDurationMs;
pub const ActiveImageTransition = types.ActiveImageTransition;
pub const ActiveNotification = snackbar.ActiveNotification;
pub const ActivePanTap = viewport.ActivePanTap;
pub const ActiveScreenshot = types.ActiveScreenshot;
pub const ActiveSnackbar = types.ActiveSnackbar;
pub const ActiveZoomTap = viewport.ActiveZoomTap;
pub const AnimationChannel = animation_state.AnimationChannel;
pub const AnimationState = animation_state.AnimationState;
pub const ArchiveTelemetry = telemetry.ArchiveTelemetry;
pub const clampZoomFactor = view_transform.clampZoomFactor;
pub const computeThumbnailUvCrop = view_transform.computeThumbnailUvCrop;
pub const DecodeTelemetry = telemetry.DecodeTelemetry;
pub const DirectionFlags = viewport.DirectionFlags;
pub const DragState = types.DragState;
pub const durationToMs = telemetry.durationToMs;
pub const DURATION_EDIT_PANEL_CLOSE_MS =
    animation_state.DURATION_EDIT_PANEL_CLOSE_MS;
pub const DURATION_EDIT_PANEL_OPEN_MS =
    animation_state.DURATION_EDIT_PANEL_OPEN_MS;
pub const DURATION_IMAGE_DISSOLVE_MS =
    animation_state.DURATION_IMAGE_DISSOLVE_MS;
pub const DURATION_PALETTE_CLOSE_MS = animation_state.DURATION_PALETTE_CLOSE_MS;
pub const DURATION_PALETTE_OPEN_MS = animation_state.DURATION_PALETTE_OPEN_MS;
pub const DURATION_SNACKBAR_CLOSE_MS =
    animation_state.DURATION_SNACKBAR_CLOSE_MS;
pub const DURATION_SNACKBAR_OPEN_MS = animation_state.DURATION_SNACKBAR_OPEN_MS;
pub const DURATION_THUMB_CROSSFADE_MS =
    animation_state.DURATION_THUMB_CROSSFADE_MS;
pub const DURATION_TITLE_OVERLAY_CLOSE_MS =
    animation_state.DURATION_TITLE_OVERLAY_CLOSE_MS;
pub const DURATION_TITLE_OVERLAY_OPEN_MS =
    animation_state.DURATION_TITLE_OVERLAY_OPEN_MS;
pub const EasingType = easing.EasingType;
pub const EDIT_PANEL_PADDING = types.EDIT_PANEL_PADDING;
pub const EDIT_PANEL_WIDTH = types.EDIT_PANEL_WIDTH;
pub const EditPanelHit = interaction.EditPanelHit;
pub const EditPanelState = types.EditPanelState;
pub const ElementTag = types.ElementTag;
pub const FloatingPanel = types.FloatingPanel;
pub const FrameInput = types.FrameInput;
pub const FrameMetrics = telemetry.FrameMetrics;
pub const FrameMetricsSnapshot = telemetry.FrameMetricsSnapshot;
pub const FrameSample = telemetry.FrameSample;
pub const ImageEdits = viewport.ImageEdits;
pub const ImageTransition = types.ImageTransition;
pub const IngestTelemetry = telemetry.IngestTelemetry;
pub const InteractionState = interaction.InteractionState;
pub const LOADING_GRACE_PERIOD_MS = types.LOADING_GRACE_PERIOD_MS;
pub const MediaItem = navigation.MediaItem;
pub const MediaItemSlice = navigation.MediaItemSlice;
pub const MipmapTelemetry = telemetry.MipmapTelemetry;
pub const MIN_SLIDESHOW_DISSOLVE_INTERVAL_S =
    animation_state.MIN_SLIDESHOW_DISSOLVE_INTERVAL_S;
pub const NavDirection = navigation.NavDirection;
pub const NavigationState = navigation.NavigationState;
pub const OverlayState = types.OverlayState;
pub const PaletteClickHit = interaction.PaletteClickHit;
pub const PaletteItemHit = interaction.PaletteItemHit;
pub const PanController = viewport.PanController;
pub const PanTap = viewport.PanTap;
pub const PRESENT_IDLE_GAP_MS = telemetry.PRESENT_IDLE_GAP_MS;
pub const PresentCadence = telemetry.PresentCadence;
pub const PresentTracker = telemetry.PresentTracker;
pub const QuitRequest = types.QuitRequest;
pub const RenderStats = telemetry.RenderStats;
pub const ScrollCadence = types.ScrollCadence;
pub const SlideshowClock = types.SlideshowClock;
pub const SlideshowMode = types.SlideshowMode;
pub const SnackbarDisplay = types.SnackbarDisplay;
pub const SnackbarNotification = snackbar.SnackbarNotification;
pub const SnackbarRule = snackbar.SnackbarRule;
pub const SnackbarState = snackbar.SnackbarState;
pub const SnackbarTrigger = snackbar.SnackbarTrigger;
pub const StatsSummary = telemetry.StatsSummary;
pub const ThumbnailInfo = telemetry.ThumbnailInfo;
pub const ThumbnailSource = telemetry.ThumbnailSource;
pub const ThumbnailStats = telemetry.ThumbnailStats;
pub const timestampToMs = telemetry.timestampToMs;
pub const TitleDisplay = types.TitleDisplay;
pub const TouchFinger = types.TouchFinger;
pub const TouchTracker = types.TouchTracker;
pub const UiRenderMetrics = telemetry.UiRenderMetrics;
pub const UiRenderMetricsSnapshot = telemetry.UiRenderMetricsSnapshot;
pub const UiState = ui_state.UiState;
pub const UploadMode = telemetry.UploadMode;
pub const ViewerDefaults = viewer_state.ViewerDefaults;
pub const ViewerState = viewer_state.ViewerState;
pub const ViewerStats = telemetry.ViewerStats;
pub const ViewportParams = viewport.ViewportParams;
pub const VisibleState = types.VisibleState;
pub const ZoomController = viewport.ZoomController;
pub const ZoomDirection = viewport.ZoomDirection;
pub const ZoomFactor = viewport.ZoomFactor;
pub const ZoomFlags = viewport.ZoomFlags;
pub const ZoomMode = viewport.ZoomMode;
pub const ZoomPhase = viewport.ZoomPhase;

test {
    _ = animation_state;
    _ = easing;
    _ = interaction;
    _ = navigation;
    _ = snackbar;
    _ = telemetry;
    _ = types;
    _ = ui_state;
    _ = viewer_state;
    _ = view_transform;
    _ = viewport;
}
