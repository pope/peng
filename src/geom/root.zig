//! 2D Geometry & Coordinate Space Primitives Module
//!
//! Provides zero-dependency 2D coordinate, dimension, DPI scaling, and
//! rectangle primitives shared across image header probing, viewport math,
//! GPU rasterization, and UI layout.
//!
//! INVARIANT: `src/geom/` is a pure `std` leaf module with zero internal or C
//! module dependencies.

const std = @import("std");

/// Strictly positive (`>= 1`) integer 2D pixel dimensions (`w x h`).
pub const PositiveDimsU32 = struct {
    w: u32 = 800,
    h: u32 = 600,

    /// Constructs `PositiveDimsU32` when both `w_i` and `h_i` are strictly
    /// positive (`> 0`), clamping each axis to `max_dim`, or returns `null`.
    pub inline fn initClamped(
        w_i: i64,
        h_i: i64,
        max_dim: u32,
    ) ?PositiveDimsU32 {
        if (w_i <= 0 or h_i <= 0 or max_dim == 0) return null;
        const max_i64: i64 = @intCast(max_dim);
        return .{
            .w = @intCast(@min(w_i, max_i64)),
            .h = @intCast(@min(h_i, max_i64)),
        };
    }
};

/// Display DPI scale factor mapping between logical UI points and physical
/// framebuffer pixels (`physical = logical * scale`).
pub const DpiScale = struct {
    x: f32 = 1.0,
    y: f32 = 1.0,

    /// Returns a sanitized `DpiScale` where non-positive or non-finite scale
    /// axes fall back to `1.0`.
    pub inline fn init(scale_x: f32, scale_y: f32) DpiScale {
        return .{
            .x = if (scale_x > 0.0 and std.math.isFinite(scale_x))
                scale_x
            else
                1.0,
            .y = if (scale_y > 0.0 and std.math.isFinite(scale_y))
                scale_y
            else
                1.0,
        };
    }
};

/// 2D width and height expressed in logical UI points (window layout space).
pub const LogicalDims = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,

    /// Converts logical dimensions into physical framebuffer pixel dimensions
    /// using the display `DpiScale`.
    pub inline fn toPhysical(self: LogicalDims, scale: DpiScale) PhysicalDims {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .w = self.w * s.x,
            .h = self.h * s.y,
        };
    }
};

/// 2D width and height expressed in physical framebuffer or image texel pixels.
pub const PhysicalDims = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,

    /// Returns a `PhysicalDims` only when both `w` and `h` are strictly
    /// positive and finite, or `null` otherwise.
    pub inline fn initPositive(w: f32, h: f32) ?PhysicalDims {
        if (w > 0.0 and h > 0.0 and
            std.math.isFinite(w) and std.math.isFinite(h))
        {
            return .{ .w = w, .h = h };
        }
        return null;
    }

    /// Returns this instance if both dimensions are strictly positive and
    /// finite, or `null` otherwise.
    pub inline fn asPositive(self: PhysicalDims) ?PhysicalDims {
        return initPositive(self.w, self.h);
    }

    /// Converts strictly positive finite physical dimensions to integer pixel
    /// dimensions, or returns `null` if either axis is non-positive or
    /// non-finite.
    pub inline fn toPositiveU32(self: PhysicalDims) ?PositiveDimsU32 {
        const valid = self.asPositive() orelse return null;
        const max_dim: f32 = @floatFromInt(std.math.maxInt(u24));
        const w_u32: u32 = @intFromFloat(@min(valid.w, max_dim));
        const h_u32: u32 = @intFromFloat(@min(valid.h, max_dim));
        if (w_u32 == 0 or h_u32 == 0) return null;
        return .{ .w = w_u32, .h = h_u32 };
    }

    /// Converts physical pixel dimensions into logical UI point dimensions
    /// using the display `DpiScale`.
    pub inline fn toLogical(self: PhysicalDims, scale: DpiScale) LogicalDims {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .w = self.w / s.x,
            .h = self.h / s.y,
        };
    }
};

/// 2D coordinates or offset expressed in logical UI points (window layout
/// space).
pub const LogicalPoint = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,

    /// Converts a logical UI point into physical framebuffer pixel coordinates
    /// using the display `DpiScale`.
    pub inline fn toPhysical(
        self: LogicalPoint,
        scale: DpiScale,
    ) PhysicalPoint {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .x = self.x * s.x,
            .y = self.y * s.y,
        };
    }
};

/// 2D coordinates or offset expressed in physical framebuffer pixels.
pub const PhysicalPoint = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,

    /// Converts physical framebuffer pixel coordinates into a logical UI point
    /// using the display `DpiScale`.
    pub inline fn toLogical(self: PhysicalPoint, scale: DpiScale) LogicalPoint {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .x = self.x / s.x,
            .y = self.y / s.y,
        };
    }
};

/// Integer pixel rectangle for scissor clipping and bounds.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Floating-point pixel rectangle for UI and viewport quad emission.
pub const FRect = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,

    /// Slices `amount` (clamped to `[0.0, self.w]`) off the left edge of this
    /// rectangle, advancing `self.x` and shrinking `self.w`, and returns the
    /// sliced-off left sub-rectangle.
    pub inline fn cutLeft(self: *FRect, amount: f32) FRect {
        const slice_w = std.math.clamp(amount, 0.0, self.w);
        const result = FRect{
            .x = self.x,
            .y = self.y,
            .w = slice_w,
            .h = self.h,
        };
        self.x += slice_w;
        self.w -= slice_w;
        return result;
    }

    /// Slices `amount` (clamped to `[0.0, self.w]`) off the right edge of this
    /// rectangle, shrinking `self.w`, and returns the sliced-off right
    /// sub-rectangle.
    pub inline fn cutRight(self: *FRect, amount: f32) FRect {
        const slice_w = std.math.clamp(amount, 0.0, self.w);
        self.w -= slice_w;
        return .{
            .x = self.x + self.w,
            .y = self.y,
            .w = slice_w,
            .h = self.h,
        };
    }

    /// Slices `amount` (clamped to `[0.0, self.h]`) off the top edge of this
    /// rectangle, advancing `self.y` and shrinking `self.h`, and returns the
    /// sliced-off top sub-rectangle.
    pub inline fn cutTop(self: *FRect, amount: f32) FRect {
        const slice_h = std.math.clamp(amount, 0.0, self.h);
        const result = FRect{
            .x = self.x,
            .y = self.y,
            .w = self.w,
            .h = slice_h,
        };
        self.y += slice_h;
        self.h -= slice_h;
        return result;
    }

    /// Slices `amount` (clamped to `[0.0, self.h]`) off the bottom edge of
    /// this rectangle, shrinking `self.h`, and returns the sliced-off bottom
    /// sub-rectangle.
    pub inline fn cutBottom(self: *FRect, amount: f32) FRect {
        const slice_h = std.math.clamp(amount, 0.0, self.h);
        self.h -= slice_h;
        return .{
            .x = self.x,
            .y = self.y + self.h,
            .w = self.w,
            .h = slice_h,
        };
    }

    /// Returns a new rectangle inset uniformly on all four edges by `pad`.
    pub inline fn inset(self: FRect, pad: f32) FRect {
        return self.insetXY(pad, pad);
    }

    /// Returns a new rectangle inset horizontally by `pad_x` and vertically
    /// by `pad_y`.
    pub inline fn insetXY(self: FRect, pad_x: f32, pad_y: f32) FRect {
        return self.insetEdges(pad_x, pad_x, pad_y, pad_y);
    }

    /// Returns a new rectangle inset by individual edge amounts, clamping
    /// resulting width and height to zero.
    pub inline fn insetEdges(
        self: FRect,
        left: f32,
        right: f32,
        top: f32,
        bottom: f32,
    ) FRect {
        return .{
            .x = self.x + left,
            .y = self.y + top,
            .w = @max(0.0, self.w - left - right),
            .h = @max(0.0, self.h - top - bottom),
        };
    }

    /// Returns the center point of this rectangle in logical coordinates.
    pub inline fn center(self: FRect) LogicalPoint {
        return .{
            .x = self.x + self.w * 0.5,
            .y = self.y + self.h * 0.5,
        };
    }

    /// Returns a new rectangle of dimensions `(target_w, target_h)` centered
    /// inside this rectangle.
    pub inline fn centered(self: FRect, target_w: f32, target_h: f32) FRect {
        return .{
            .x = self.x + (self.w - target_w) * 0.5,
            .y = self.y + (self.h - target_h) * 0.5,
            .w = target_w,
            .h = target_h,
        };
    }

    /// Returns `true` if `pt` falls within this rectangle's half-open bounds
    /// `[x, x + w)` and `[y, y + h)`.
    pub inline fn contains(self: FRect, pt: LogicalPoint) bool {
        return self.w > 0.0 and self.h > 0.0 and
            pt.x >= self.x and pt.x < self.x + self.w and
            pt.y >= self.y and pt.y < self.y + self.h;
    }
};

/// 2D floating-point coordinate in screen pixels.
pub const FPoint = struct {
    x: f32,
    y: f32,
};

/// Complete per-quad render descriptor specifying UV sub-rectangles, alpha,
/// rotation, and dynamic geometry overrides for rendering and transitions.
pub const UvRect = struct {
    u_min: f32 = 0.0,
    v_min: f32 = 0.0,
    u_max: f32 = 1.0,
    v_max: f32 = 1.0,
    alpha: f32 = 1.0,
    rotation_angle: ?f32 = null,
    override_zoom: ?f32 = null,
    override_pan_x: ?f32 = null,
    override_pan_y: ?f32 = null,
    source_w: ?f32 = null,
    source_h: ?f32 = null,
};

test "PositiveDimsU32.initClamped" {
    const valid = PositiveDimsU32.initClamped(800, 600, 4096);
    try std.testing.expect(valid != null);
    try std.testing.expectEqual(@as(u32, 800), valid.?.w);
    try std.testing.expectEqual(@as(u32, 600), valid.?.h);

    const clamped = PositiveDimsU32.initClamped(5000, 3000, 4096);
    try std.testing.expect(clamped != null);
    try std.testing.expectEqual(@as(u32, 4096), clamped.?.w);
    try std.testing.expectEqual(@as(u32, 3000), clamped.?.h);

    try std.testing.expect(PositiveDimsU32.initClamped(0, 600, 4096) == null);
    try std.testing.expect(PositiveDimsU32.initClamped(800, 0, 4096) == null);
    try std.testing.expect(PositiveDimsU32.initClamped(-10, 600, 4096) == null);
    try std.testing.expect(PositiveDimsU32.initClamped(800, -5, 4096) == null);
    try std.testing.expect(PositiveDimsU32.initClamped(-1, -1, 4096) == null);
    try std.testing.expect(PositiveDimsU32.initClamped(800, 600, 0) == null);
}

test "LogicalDims, PhysicalDims, LogicalPoint, and PhysicalPoint conversions" {
    const scale = DpiScale.init(2.0, 2.0);
    const log_dims = LogicalDims{ .w = 1000.0, .h = 800.0 };
    const phys_dims = log_dims.toPhysical(scale);
    try std.testing.expectApproxEqAbs(@as(f32, 2000.0), phys_dims.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1600.0), phys_dims.h, 0.001);

    const roundtrip_dims = phys_dims.toLogical(scale);
    try std.testing.expectApproxEqAbs(
        @as(f32, 1000.0),
        roundtrip_dims.w,
        0.001,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 800.0), roundtrip_dims.h, 0.001);

    const log_pt = LogicalPoint{ .x = 250.0, .y = 150.0 };
    const phys_pt = log_pt.toPhysical(scale);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), phys_pt.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), phys_pt.y, 0.001);

    const roundtrip_pt = phys_pt.toLogical(scale);
    try std.testing.expectApproxEqAbs(@as(f32, 250.0), roundtrip_pt.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), roundtrip_pt.y, 0.001);

    // Invalid / non-positive scale sanitizes to 1.0
    const bad_scale = DpiScale.init(0.0, std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 1.0), bad_scale.x);
    try std.testing.expectEqual(@as(f32, 1.0), bad_scale.y);
}

test "PhysicalDims.initPositive and asPositive validation" {
    // Valid strictly positive dimensions
    const valid = PhysicalDims.initPositive(100.0, 50.0);
    try std.testing.expect(valid != null);
    try std.testing.expectEqual(
        PhysicalDims{ .w = 100.0, .h = 50.0 },
        valid.?,
    );
    try std.testing.expectEqual(
        PhysicalDims{ .w = 100.0, .h = 50.0 },
        valid.?.asPositive().?,
    );

    // Zero dimensions
    try std.testing.expect(PhysicalDims.initPositive(0.0, 50.0) == null);
    try std.testing.expect(PhysicalDims.initPositive(100.0, 0.0) == null);
    try std.testing.expect(
        (PhysicalDims{ .w = 0.0, .h = 50.0 }).asPositive() == null,
    );
    try std.testing.expect(
        (PhysicalDims{ .w = 100.0, .h = 0.0 }).asPositive() == null,
    );

    // Negative dimensions
    try std.testing.expect(PhysicalDims.initPositive(-10.0, 50.0) == null);
    try std.testing.expect(PhysicalDims.initPositive(100.0, -10.0) == null);
    try std.testing.expect(
        (PhysicalDims{ .w = -10.0, .h = 50.0 }).asPositive() == null,
    );

    // NaN and Inf
    try std.testing.expect(
        PhysicalDims.initPositive(std.math.nan(f32), 50.0) == null,
    );
    try std.testing.expect(
        PhysicalDims.initPositive(100.0, std.math.nan(f32)) == null,
    );
    try std.testing.expect(
        PhysicalDims.initPositive(std.math.inf(f32), 50.0) == null,
    );
    try std.testing.expect(
        PhysicalDims.initPositive(100.0, std.math.inf(f32)) == null,
    );
}

test "FRect.cutLeft, cutRight, cutTop, cutBottom" {
    var rect = FRect{ .x = 10.0, .y = 20.0, .w = 100.0, .h = 50.0 };

    // Cut 20 off left
    const left = rect.cutLeft(20.0);
    try std.testing.expectEqual(
        FRect{ .x = 10.0, .y = 20.0, .w = 20.0, .h = 50.0 },
        left,
    );
    try std.testing.expectEqual(
        FRect{ .x = 30.0, .y = 20.0, .w = 80.0, .h = 50.0 },
        rect,
    );

    // Cut 15 off right
    const right = rect.cutRight(15.0);
    try std.testing.expectEqual(
        FRect{ .x = 95.0, .y = 20.0, .w = 15.0, .h = 50.0 },
        right,
    );
    try std.testing.expectEqual(
        FRect{ .x = 30.0, .y = 20.0, .w = 65.0, .h = 50.0 },
        rect,
    );

    // Cut 10 off top
    const top = rect.cutTop(10.0);
    try std.testing.expectEqual(
        FRect{ .x = 30.0, .y = 20.0, .w = 65.0, .h = 10.0 },
        top,
    );
    try std.testing.expectEqual(
        FRect{ .x = 30.0, .y = 30.0, .w = 65.0, .h = 40.0 },
        rect,
    );

    // Cut 10 off bottom
    const bottom = rect.cutBottom(10.0);
    try std.testing.expectEqual(
        FRect{ .x = 30.0, .y = 60.0, .w = 65.0, .h = 10.0 },
        bottom,
    );
    try std.testing.expectEqual(
        FRect{ .x = 30.0, .y = 30.0, .w = 65.0, .h = 30.0 },
        rect,
    );

    // Clamping: cutting more than available width
    const over_cut = rect.cutLeft(200.0);
    try std.testing.expectEqual(
        FRect{ .x = 30.0, .y = 30.0, .w = 65.0, .h = 30.0 },
        over_cut,
    );
    try std.testing.expectEqual(@as(f32, 0.0), rect.w);

    // Clamping: negative cut amounts are clamped to 0
    var zero_cut_rect = FRect{ .x = 5.0, .y = 5.0, .w = 50.0, .h = 50.0 };
    const neg_cut = zero_cut_rect.cutTop(-10.0);
    try std.testing.expectEqual(
        FRect{ .x = 5.0, .y = 5.0, .w = 50.0, .h = 0.0 },
        neg_cut,
    );
    try std.testing.expectEqual(
        FRect{ .x = 5.0, .y = 5.0, .w = 50.0, .h = 50.0 },
        zero_cut_rect,
    );
}

test "FRect.inset, insetXY, insetEdges, center, centered, contains" {
    const r = FRect{ .x = 10.0, .y = 20.0, .w = 100.0, .h = 60.0 };

    // Inset
    const in1 = r.inset(5.0);
    try std.testing.expectEqual(
        FRect{ .x = 15.0, .y = 25.0, .w = 90.0, .h = 50.0 },
        in1,
    );

    // InsetXY
    const in_xy = r.insetXY(10.0, 5.0);
    try std.testing.expectEqual(
        FRect{ .x = 20.0, .y = 25.0, .w = 80.0, .h = 50.0 },
        in_xy,
    );

    // InsetEdges with clamping
    const in_edges = r.insetEdges(5.0, 10.0, 15.0, 20.0);
    try std.testing.expectEqual(
        FRect{ .x = 15.0, .y = 35.0, .w = 85.0, .h = 25.0 },
        in_edges,
    );
    const in_over = r.inset(100.0);
    try std.testing.expectEqual(@as(f32, 0.0), in_over.w);
    try std.testing.expectEqual(@as(f32, 0.0), in_over.h);

    // Center and centered
    const c = r.center();
    try std.testing.expectEqual(LogicalPoint{ .x = 60.0, .y = 50.0 }, c);

    const ctr = r.centered(40.0, 20.0);
    try std.testing.expectEqual(
        FRect{ .x = 40.0, .y = 40.0, .w = 40.0, .h = 20.0 },
        ctr,
    );

    // Contains
    try std.testing.expect(r.contains(.{ .x = 10.0, .y = 20.0 }));
    try std.testing.expect(r.contains(.{ .x = 60.0, .y = 50.0 }));
    try std.testing.expect(!r.contains(.{ .x = 9.9, .y = 20.0 }));
    try std.testing.expect(!r.contains(.{ .x = 110.0, .y = 50.0 }));
    try std.testing.expect(!r.contains(.{ .x = 50.0, .y = 80.0 }));
    try std.testing.expect(!r.contains(.{ .x = 50.0, .y = 19.9 }));

    // Empty rect contains nothing
    const empty_rect = FRect{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 10.0 };
    try std.testing.expect(!empty_rect.contains(.{ .x = 0.0, .y = 5.0 }));
}
