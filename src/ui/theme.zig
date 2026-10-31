const std = @import("std");

/// RGBA color tuple with channels in the 0.0..255.0 range.
pub const Color = [4]f32;

/// Fully transparent color.
pub const transparent = Color{ 0, 0, 0, 0 };

/// Returns a copy of the input color with its alpha channel multiplied by the
/// factor (0.0 .. 1.0).
pub inline fn withAlpha(color: Color, factor: f32) Color {
    const clamped = std.math.clamp(factor, 0.0, 1.0);
    return .{
        color[0],
        color[1],
        color[2],
        color[3] * clamped,
    };
}

/// Dark mantle background color.
pub const mantle = Color{ 24, 24, 37, 255 };
/// Dark crust background color.
pub const crust = Color{ 17, 17, 27, 255 };
/// Main base background color.
pub const base = Color{ 30, 30, 46, 255 };
/// Translucent base background color for frosted surfaces.
pub const base_translucent = Color{ 30, 30, 46, 191 };
/// Surface 0 border and separator color.
pub const surface0 = Color{ 49, 50, 68, 255 };
/// Surface 1 subtle highlight color.
pub const surface1 = Color{ 69, 71, 90, 255 };
/// Surface 2 elevated element color.
pub const surface2 = Color{ 88, 91, 112, 255 };
/// Overlay 0 subdued accent and border color.
pub const overlay0 = Color{ 79, 79, 97, 255 };

/// Palette list row background color when selected.
pub const row_selected = Color{ 137, 180, 250, 40 };
/// Palette list row background color when selected and hovered.
pub const row_selected_hover = Color{ 137, 180, 250, 50 };
/// Palette list row background color when hovered.
pub const row_hover = Color{ 205, 214, 244, 25 };
/// Secondary subtext color.
pub const subtext0 = Color{ 166, 173, 200, 255 };
/// Dimmer tertiary subtext color.
pub const subtext1 = Color{ 108, 112, 134, 255 };
/// Primary text foreground color.
pub const text = Color{ 205, 214, 244, 255 };
/// Blue accent color.
pub const blue = Color{ 137, 180, 250, 255 };
/// Green accent color.
pub const green = Color{ 166, 227, 161, 255 };
/// Red warning / reject accent color.
pub const red = Color{ 243, 139, 168, 255 };
/// Pink accent color.
pub const pink = Color{ 245, 194, 231, 255 };
/// Peach accent color.
pub const peach = Color{ 250, 179, 135, 255 };
/// Yellow accent color.
pub const yellow = Color{ 249, 226, 175, 255 };
/// Mauve title / header accent color.
pub const mauve = Color{ 203, 166, 247, 255 };
