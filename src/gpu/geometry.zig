const geom = @import("geom");
const std = @import("std");

const PhysicalDims = geom.PhysicalDims;

/// 2D textured colored vertex layout matching GPU pipeline vertex buffer
/// layout.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    color: u32,
};

/// Compact 64-byte per-instance GPU descriptor for analytic SDF UI quads
/// (filled rounded rectangles, frosted-glass panels, and outlined borders).
pub const UiQuadInstance = extern struct {
    /// Physical pixel rectangle `(x, y, w, h)` in top-left origin space.
    rect: [4]f32,
    /// Per-corner radii `(top_right, bottom_right, top_left, bottom_left)`
    /// in physical pixels.
    radii: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    /// Edge stroke widths `(left, top, right, bottom)` in physical pixels.
    border: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    /// Packed RGBA8 fill/tint color (`0xAABBGGRR`).
    fill_color: u32 = 0,
    /// Packed RGBA8 border stroke color (`0xAABBGGRR`).
    border_color: u32 = 0,
    /// Softness / shadow blur radius in physical pixels (`0.0` = crisp AA).
    softness: f32 = 0.0,
    /// Bitmask flags: bit 0 (`1.0`) = frosted glass, bit 1 (`2.0`) =
    /// border-only (skip interior fill), bit 2 (`4.0`) = dashed border.
    flags: f32 = 0.0,

    pub const flag_blur: f32 = 1.0;
    pub const flag_border_only: f32 = 2.0;
    pub const flag_dashed: f32 = 4.0;
};

comptime {
    std.debug.assert(@sizeOf(UiQuadInstance) == 64);
    std.debug.assert(@offsetOf(UiQuadInstance, "rect") == 0);
    std.debug.assert(@offsetOf(UiQuadInstance, "radii") == 16);
    std.debug.assert(@offsetOf(UiQuadInstance, "border") == 32);
    std.debug.assert(@offsetOf(UiQuadInstance, "fill_color") == 48);
    std.debug.assert(@offsetOf(UiQuadInstance, "border_color") == 52);
    std.debug.assert(@offsetOf(UiQuadInstance, "softness") == 56);
    std.debug.assert(@offsetOf(UiQuadInstance, "flags") == 60);
}

/// Vertex shader push uniform block for the instanced SDF UI pipeline.
pub const UiSdfVertUniforms = extern struct {
    win_dims: [2]f32,
    padding: [2]f32 = .{ 0.0, 0.0 },
};

comptime {
    std.debug.assert(@sizeOf(UiSdfVertUniforms) == 16);
}

/// Packs 8-bit integer RGBA channels into a 32-bit color word.
pub inline fn packRgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, r) |
        (@as(u32, g) << 8) |
        (@as(u32, b) << 16) |
        (@as(u32, a) << 24);
}

/// Clamps and packs float RGBA channels (0.0–255.0) into a 32-bit color word.
pub inline fn packRgba255(color: [4]f32) u32 {
    const ur: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 255.0)));
    const ug: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 255.0)));
    const ub: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 255.0)));
    const ua: u32 = @intFromFloat(@round(std.math.clamp(color[3], 0.0, 255.0)));
    return ur | (ug << 8) | (ub << 16) | (ua << 24);
}

/// Clamps and packs normalized float RGBA channels (0.0–1.0) into a 32-bit
/// color word.
pub inline fn packRgbaF(r: f32, g: f32, b: f32, a: f32) u32 {
    const ur: u32 =
        @intFromFloat(@round(std.math.clamp(r * 255.0, 0.0, 255.0)));
    const ug: u32 =
        @intFromFloat(@round(std.math.clamp(g * 255.0, 0.0, 255.0)));
    const ub: u32 =
        @intFromFloat(@round(std.math.clamp(b * 255.0, 0.0, 255.0)));
    const ua: u32 =
        @intFromFloat(@round(std.math.clamp(a * 255.0, 0.0, 255.0)));
    return ur | (ug << 8) | (ub << 16) | (ua << 24);
}

/// 2D point expressed in Normalized Device Coordinates [-1.0, 1.0].
pub const NdcPoint = struct {
    x: f32,
    y: f32,
};

/// Converts screen pixel coordinates into Normalized Device Coordinates
/// [-1.0, 1.0].
pub inline fn toNdc(x: f32, y: f32, win_dims: PhysicalDims) NdcPoint {
    return .{
        .x = (x / win_dims.w) * 2.0 - 1.0,
        .y = 1.0 - (y / win_dims.h) * 2.0,
    };
}

test "packRgba and packRgbaF packing and clamping" {
    // Exact byte packing
    const c1 = packRgba(0x12, 0x34, 0x56, 0x78);
    try std.testing.expectEqual(@as(u32, 0x78563412), c1);

    // Float packing (0.0 - 1.0)
    const c2 = packRgbaF(1.0, 0.0, 0.5, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFF8000FF), c2);

    // Clamping behavior (< 0.0 clamped to 0, > 1.0 clamped to 255)
    const c_clamped = packRgbaF(-0.5, 2.0, 0.0, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), c_clamped);

    // RGBA 255 color packing (0.0 - 255.0)
    const c_255 = packRgba255(.{ 255.0, 128.0, 64.0, 255.0 });
    try std.testing.expectEqual(@as(u32, 0xFF4080FF), c_255);
}

test "toNdc - coordinate conversion" {
    const win_dims = PhysicalDims{ .w = 800.0, .h = 600.0 };

    // Top-left (0, 0) maps to (-1.0, 1.0)
    const p_tl = toNdc(0.0, 0.0, win_dims);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p_tl.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p_tl.y, 0.0001);

    // Bottom-right (800, 600) maps to (1.0, -1.0)
    const p_br = toNdc(800.0, 600.0, win_dims);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p_br.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p_br.y, 0.0001);

    // Center (400, 300) maps to (0.0, 0.0)
    const p_c = toNdc(400.0, 300.0, win_dims);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), p_c.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), p_c.y, 0.0001);
}
