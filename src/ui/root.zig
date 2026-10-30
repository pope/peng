//! UI & Rendering Subsystem Module
//!
//! Provides Clay layout integration, geometry transformation passes,
//! text measurement, overlay panels, and 2-pass UI render pipelines.

/// Image adjustment and EXIF metadata editing panels.
pub const edit_panel = @import("edit_panel.zig");

/// Clay layout interaction, context encapsulation, and hit-testing.
pub const interaction = @import("interaction.zig");

/// Clay layout generation and UI element hierarchy declaration.
pub const layout = @import("layout.zig");

/// Command palette modal and quick-action menu rendering.
pub const palette = @import("palette.zig");

/// Clay render commands to GPU vertex batch translator.
pub const renderer = @import("renderer.zig");

/// Image metadata, histogram, and statistics display overlay.
pub const stats = @import("stats.zig");

/// Text truncation, sizing, and font measure helpers.
pub const text_utils = @import("text_utils.zig");

/// Color palette, styling constants, and theme definitions.
pub const theme = @import("theme.zig");

/// UI view model state and layout data structures.
pub const view_model = @import("view_model.zig");

/// Active image dissolve crossfade state.
pub const ActiveImageDissolve = view_model.ActiveImageDissolve;

/// Image dissolve parameters and animation progress.
pub const ImageDissolve = view_model.ImageDissolve;

/// Primary UI view model containing active layout state and flags.
pub const UiViewModel = view_model.UiViewModel;

test {
    _ = edit_panel;
    _ = interaction;
    _ = layout;
    _ = palette;
    _ = renderer;
    _ = stats;
    _ = text_utils;
    _ = theme;
    _ = view_model;
}
