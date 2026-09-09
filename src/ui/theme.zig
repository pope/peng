const clay = @import("zclay");
const std = @import("std");

/// Returns a copy of the input color with its alpha channel multiplied by the factor (0.0 .. 1.0).
pub inline fn withAlpha(color: clay.Color, factor: f32) clay.Color {
    const clamped = std.math.clamp(factor, 0.0, 1.0);
    return .{
        color[0],
        color[1],
        color[2],
        color[3] * clamped,
    };
}

pub const mantle = clay.Color{ 24, 24, 37, 255 };
pub const crust = clay.Color{ 17, 17, 27, 255 };
pub const base = clay.Color{ 30, 30, 46, 255 };
pub const base_translucent = clay.Color{ 30, 30, 46, 245 };
pub const base_overlay = clay.Color{ 30, 30, 46, 220 };
pub const surface0 = clay.Color{ 49, 50, 68, 255 };
pub const overlay0 = clay.Color{ 79, 79, 97, 255 };

/// Palette list row background colors with translucency to reveal frosted glass backdrops.
pub const row_selected = clay.Color{ 137, 180, 250, 40 };
pub const row_selected_hover = clay.Color{ 137, 180, 250, 50 };
pub const row_hover = clay.Color{ 205, 214, 244, 25 };
pub const subtext0 = clay.Color{ 166, 173, 200, 255 };
pub const subtext1 = clay.Color{ 108, 112, 134, 255 };
pub const text = clay.Color{ 205, 214, 244, 255 };
pub const blue = clay.Color{ 137, 180, 250, 255 };
pub const green = clay.Color{ 166, 227, 161, 255 };
pub const red = clay.Color{ 243, 139, 168, 255 };
pub const pink = clay.Color{ 245, 194, 231, 255 };
pub const peach = clay.Color{ 250, 179, 135, 255 };
pub const yellow = clay.Color{ 249, 226, 175, 255 };
pub const mauve = clay.Color{ 203, 166, 247, 255 };

/// Scale factor for text rendered inside the Clay debug inspector panel.
/// Clay hardcodes .fontSize = 16 in clay.h for all internal debug UI text.
/// Scaling by 0.75 reduces this text from 16px down to 12px to match our
/// compact UI text scale (11–13px), preventing oversized labels and fit
/// issues in the debug sidebar.
pub const debug_font_scale: f32 = 0.75;
