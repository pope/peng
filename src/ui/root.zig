//! UI & Rendering Subsystem Module
//!
//! Provides Clay layout integration, geometry transformation passes,
//! text caching, overlay panels, and SDL3 GPU rendering pipelines.

pub const edit_panel = @import("edit_panel.zig");
pub const geometry = @import("geometry.zig");
pub const graphics = @import("graphics.zig");
pub const layout = @import("layout.zig");
pub const palette = @import("palette.zig");
pub const render_image = @import("render_image.zig");
pub const renderer = @import("renderer.zig");
pub const stats = @import("stats.zig");
pub const text_cache = @import("text_cache.zig");
pub const text_utils = @import("text_utils.zig");
pub const theme = @import("theme.zig");
pub const view_model = @import("view_model.zig");

pub const ActiveImageDissolve = view_model.ActiveImageDissolve;
pub const ImageDissolve = view_model.ImageDissolve;
pub const UiViewModel = view_model.UiViewModel;

test {
    _ = edit_panel;
    _ = renderer;
    _ = render_image;
    _ = layout;
    _ = palette;
    _ = stats;
    _ = graphics;
    _ = text_utils;
    _ = theme;
    _ = geometry;
    _ = text_cache;
    _ = view_model;
}
