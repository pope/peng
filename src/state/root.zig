//! Data State Module
//!
//! Encapsulates application domain state models, view parameters,
//! type wrappers, input data structures, and view transform calculations.
//! Has zero dependencies on UI rendering or app logic.

pub const fuzzig = @import("fuzzig");
pub const navigation = @import("navigation.zig");
pub const palette_state = @import("palette_state.zig");
pub const types = @import("types.zig");
pub const ui_state = @import("ui_state.zig");
pub const viewer_state = @import("viewer_state.zig");
pub const view_transform = @import("view_transform.zig");

pub const ActionMetadata = types.ActionMetadata;
pub const ActiveWindow = types.ActiveWindow;
pub const ArchiveMediaEntry = types.ArchiveMediaEntry;
pub const CacheEntry = types.CacheEntry;
pub const CacheStatus = types.CacheStatus;
pub const computeThumbnailUvCrop = view_transform.computeThumbnailUvCrop;
pub const CpuSurfaceComponent = types.CpuSurfaceComponent;
pub const DirectoryEntry = palette_state.DirectoryEntry;
pub const DisplayState = types.DisplayState;
pub const DragState = types.DragState;
pub const ElementTag = types.ElementTag;
pub const EntryScanCounts = palette_state.EntryScanCounts;
pub const EntryScanState = palette_state.EntryScanState;
pub const flat_shortcuts = types.flat_shortcuts;
pub const FolderScanState = palette_state.FolderScanState;
pub const FrameInput = types.FrameInput;
pub const getPaletteConfig = palette_state.getPaletteConfig;
pub const GpuTextureComponent = types.GpuTextureComponent;
pub const Key = types.Key;
pub const KeyModifiers = types.KeyModifiers;
pub const KeyboardShortcut = types.KeyboardShortcut;
pub const MeasureTextUserData = types.MeasureTextUserData;
pub const MediaEntry = types.MediaEntry;
pub const NavigationState = navigation.NavigationState;
pub const Orientation = types.Orientation;
pub const OverlayState = types.OverlayState;
pub const palette_action_items = types.palette_action_items;
pub const PaletteConfig = palette_state.PaletteConfig;
pub const PaletteState = palette_state.PaletteState;
pub const RawMetadata = types.RawMetadata;
pub const ScoredMatch = palette_state.ScoredMatch;
pub const SlideshowMode = types.SlideshowMode;
pub const stopTextInput = types.stopTextInput;
pub const ThumbComponent = types.ThumbComponent;
pub const UiRenderMetrics = types.UiRenderMetrics;
pub const UiRenderMetricsSnapshot = types.UiRenderMetricsSnapshot;
pub const UiState = ui_state.UiState;
pub const UiViewModel = types.UiViewModel;
pub const UvRect = types.UvRect;
pub const ViewerState = viewer_state.ViewerState;
pub const ViewParams = types.ViewParams;
pub const ViewportParams = types.ViewportParams;
pub const ZoomFactor = types.ZoomFactor;

test {
    _ = types;
    _ = view_transform;
    _ = palette_state;
    _ = viewer_state;
    _ = navigation;
    _ = ui_state;
}
