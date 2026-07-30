//! Data State Module
//!
//! Encapsulates application domain state models, view parameters,
//! type wrappers, input data structures, and view transform calculations.
//! Has zero dependencies on UI rendering or app logic.

pub const types = @import("types.zig");
pub const view_transform = @import("view_transform.zig");
pub const palette_state = @import("palette_state.zig");

pub const ZoomFactor = types.ZoomFactor;
pub const ViewportParams = types.ViewportParams;
pub const ViewParams = types.ViewParams;
pub const UiViewModel = types.UiViewModel;
pub const FrameInput = types.FrameInput;
pub const Key = types.Key;
pub const KeyModifiers = types.KeyModifiers;
pub const KeyboardShortcut = types.KeyboardShortcut;
pub const ActionMetadata = types.ActionMetadata;
pub const palette_action_items = types.palette_action_items;
pub const flat_shortcuts = types.flat_shortcuts;
pub const MeasureTextUserData = types.MeasureTextUserData;
pub const ElementTag = types.ElementTag;
pub const OverlayState = types.OverlayState;
pub const UiRenderMetrics = types.UiRenderMetrics;
pub const PaletteState = palette_state.PaletteState;
pub const PaletteModeData = palette_state.PaletteModeData;
pub const ScoredMatch = palette_state.ScoredMatch;
pub const DirectoryEntry = palette_state.DirectoryEntry;
pub const DirectoryEntryType = palette_state.DirectoryEntryType;
pub const CacheEntry = types.CacheEntry;
pub const CacheStatus = types.CacheStatus;
pub const CpuSurfaceComponent = types.CpuSurfaceComponent;
pub const GpuTextureComponent = types.GpuTextureComponent;
pub const ThumbComponent = types.ThumbComponent;
pub const ActiveWindow = types.ActiveWindow;
pub const DisplayState = types.DisplayState;
pub const SlideshowMode = types.SlideshowMode;
pub const stopTextInput = types.stopTextInput;
