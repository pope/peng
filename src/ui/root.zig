//! UI & Rendering Subsystem Module
//!
//! Provides Clay layout integration, geometry transformation passes,
//! text caching, overlay panels, and SDL3 GPU rendering pipelines.

pub const renderer = @import("renderer.zig");
pub const render_image = @import("render_image.zig");
pub const layout = @import("layout.zig");
pub const palette = @import("palette.zig");
pub const palette_items = @import("palette_items.zig");
pub const palette_scroll = @import("palette_scroll.zig");
pub const palette_layout = @import("palette_layout.zig");
pub const stats = @import("stats.zig");
pub const graphics = @import("graphics.zig");
pub const units = @import("units.zig");
pub const layout_helpers = @import("layout_helpers.zig");
pub const text_utils = @import("text_utils.zig");
pub const theme = @import("theme.zig");
pub const geometry = @import("geometry.zig");
pub const text_cache = @import("text_cache.zig");
