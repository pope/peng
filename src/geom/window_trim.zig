//! Aspect-ratio window trimming calculation engine and coordinate math.
//!
//! Provides pure, zero-allocation algorithms for calculating aspect-hugging
//! window dimensions and center-preserving repositioning within display
//! ceilings and usable desktop work-area boundaries.
//!
//! INVARIANT: Pure `std` + `geom/root.zig` leaf module with zero SDL or C dependencies.

const std = @import("std");
const root = @import("root.zig");

/// Default logical window ceiling width when opening or resetting an image.
pub const DEFAULT_CEILING_W: i32 = 1024;

/// Default logical window ceiling height when opening or resetting an image.
pub const DEFAULT_CEILING_H: i32 = 768;

/// Minimum UI window width floor ensuring menu and toolbars remain usable.
pub const DEFAULT_MIN_W: i32 = 320;

/// Minimum UI window height floor ensuring bottom status bar remains usable.
pub const DEFAULT_MIN_H: i32 = 200;

/// 2D integer window dimensions in logical screen points.
pub const WindowDimsI32 = struct {
    w: i32 = DEFAULT_CEILING_W,
    h: i32 = DEFAULT_CEILING_H,
};

/// 2D integer window desktop coordinates in screen points.
pub const WindowPosI32 = struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// Returns `true` if the normalized rotation angle is approximately 90 or
/// 270 degrees (swapping image width and height).
pub fn isAngle90or270(angle: f32) bool {
    if (!std.math.isFinite(angle)) return false;
    const norm = @mod(@mod(angle, 360.0) + 360.0, 360.0);
    return std.math.approxEqAbs(f32, norm, 90.0, 0.1) or
        std.math.approxEqAbs(f32, norm, 270.0, 0.1);
}

/// Computes optimal aspect-hugging window dimensions for an image given its
/// raw dimensions, current rotation angle, default ceiling, display usable
/// bounds, and minimum UI floor.
///
/// Returns `null` if raw dimensions or ceiling are invalid (non-positive, zero,
/// or non-finite).
pub fn computeTrimmedWindowDims(
    raw_dims: root.PhysicalDims,
    rotation_angle: f32,
    default_ceiling: WindowDimsI32,
    usable_bounds: ?root.Rect,
    min_floor: WindowDimsI32,
) ?WindowDimsI32 {
    // 1. Validate raw dimensions: strictly positive and finite
    if (!std.math.isFinite(raw_dims.w) or !std.math.isFinite(raw_dims.h) or
        raw_dims.w <= 0.0 or raw_dims.h <= 0.0)
    {
        return null;
    }

    // 2. Validate default ceiling: strictly positive
    if (default_ceiling.w <= 0 or default_ceiling.h <= 0) {
        return null;
    }

    // 3. Compute effective ceiling clamped to usable display work area
    var ceil_w = default_ceiling.w;
    var ceil_h = default_ceiling.h;
    if (usable_bounds) |usable| {
        if (usable.w > 0 and usable.h > 0) {
            ceil_w = @max(1, @min(default_ceiling.w, usable.w));
            ceil_h = @max(1, @min(default_ceiling.h, usable.h));
        }
    }

    // 4. Compute safe minimum floor guaranteed not to exceed ceiling
    const floor_w = @max(1, @min(min_floor.w, ceil_w));
    const floor_h = @max(1, @min(min_floor.h, ceil_h));

    // 5. Apply rotation transposition (90° / 270° swaps width and height)
    const is_swapped = isAngle90or270(rotation_angle);
    const img_w: f64 = if (is_swapped) @floatCast(raw_dims.h) else @floatCast(raw_dims.w);
    const img_h: f64 = if (is_swapped) @floatCast(raw_dims.w) else @floatCast(raw_dims.h);

    // 6. Compare image aspect ratio against ceiling aspect ratio
    const ar = img_w / img_h;
    const ar_ceil = @as(f64, @floatFromInt(ceil_w)) / @as(f64, @floatFromInt(ceil_h));

    var target_w: i32 = undefined;
    var target_h: i32 = undefined;

    if (ar >= ar_ceil) {
        // Landscape or wider than ceiling: hug width, scale down height
        target_w = ceil_w;
        const raw_h = @round(@as(f64, @floatFromInt(target_w)) / ar);
        const clamped_h = std.math.clamp(
            raw_h,
            @as(f64, @floatFromInt(floor_h)),
            @as(f64, @floatFromInt(ceil_h)),
        );
        target_h = @intFromFloat(clamped_h);
    } else {
        // Portrait or taller than ceiling: hug height, scale down width
        target_h = ceil_h;
        const raw_w = @round(@as(f64, @floatFromInt(target_h)) * ar);
        const clamped_w = std.math.clamp(
            raw_w,
            @as(f64, @floatFromInt(floor_w)),
            @as(f64, @floatFromInt(ceil_w)),
        );
        target_w = @intFromFloat(clamped_w);
    }

    return WindowDimsI32{ .w = target_w, .h = target_h };
}

/// Computes window desktop position preserving the visual center point of the
/// current window when transitioning to new dimensions, clamped to keep the
/// window within usable display boundaries.
pub fn computeCenterPreservedPosition(
    curr_pos: WindowPosI32,
    curr_dims: WindowDimsI32,
    target_dims: WindowDimsI32,
    usable_bounds: ?root.Rect,
) WindowPosI32 {
    const curr_x: i64 = curr_pos.x;
    const curr_y: i64 = curr_pos.y;
    const curr_w: i64 = curr_dims.w;
    const curr_h: i64 = curr_dims.h;
    const target_w: i64 = target_dims.w;
    const target_h: i64 = target_dims.h;

    var x_target: i64 = curr_x + @divFloor(curr_w - target_w, 2);
    var y_target: i64 = curr_y + @divFloor(curr_h - target_h, 2);

    if (usable_bounds) |usable| {
        if (usable.w > 0 and usable.h > 0) {
            const u_x: i64 = usable.x;
            const u_y: i64 = usable.y;
            const u_w: i64 = usable.w;
            const u_h: i64 = usable.h;

            const min_x = u_x;
            const max_x = @max(u_x, u_x + u_w - target_w);
            x_target = std.math.clamp(x_target, min_x, max_x);

            const min_y = u_y;
            const max_y = @max(u_y, u_y + u_h - target_h);
            y_target = std.math.clamp(y_target, min_y, max_y);
        }
    }

    return WindowPosI32{
        .x = @intCast(std.math.clamp(
            x_target,
            @as(i64, std.math.minInt(i32)),
            @as(i64, std.math.maxInt(i32)),
        )),
        .y = @intCast(std.math.clamp(
            y_target,
            @as(i64, std.math.minInt(i32)),
            @as(i64, std.math.maxInt(i32)),
        )),
    };
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "isAngle90or270 angle normalization and tolerances" {
    // Cardinal angles
    try std.testing.expect(!isAngle90or270(0.0));
    try std.testing.expect(isAngle90or270(90.0));
    try std.testing.expect(!isAngle90or270(180.0));
    try std.testing.expect(isAngle90or270(270.0));
    try std.testing.expect(!isAngle90or270(360.0));

    // Multi-revolution angles
    try std.testing.expect(isAngle90or270(450.0)); // 360 + 90
    try std.testing.expect(isAngle90or270(630.0)); // 360 + 270
    try std.testing.expect(!isAngle90or270(720.0));

    // Negative angles
    try std.testing.expect(isAngle90or270(-90.0)); // 270
    try std.testing.expect(!isAngle90or270(-180.0));
    try std.testing.expect(isAngle90or270(-270.0)); // 90
    try std.testing.expect(!isAngle90or270(-360.0));

    // Approximate tolerance checks (within 0.1 deg)
    try std.testing.expect(isAngle90or270(89.95));
    try std.testing.expect(isAngle90or270(90.05));
    try std.testing.expect(isAngle90or270(269.95));
    try std.testing.expect(isAngle90or270(270.05));
    try std.testing.expect(!isAngle90or270(89.0));
    try std.testing.expect(!isAngle90or270(91.0));
    try std.testing.expect(!isAngle90or270(45.0));

    // Non-finite edge cases
    try std.testing.expect(!isAngle90or270(std.math.nan(f32)));
    try std.testing.expect(!isAngle90or270(std.math.inf(f32)));
    try std.testing.expect(!isAngle90or270(-std.math.inf(f32)));
}

test "computeTrimmedWindowDims standard aspect ratios" {
    const default_ceiling = WindowDimsI32{ .w = DEFAULT_CEILING_W, .h = DEFAULT_CEILING_H };
    const min_floor = WindowDimsI32{ .w = DEFAULT_MIN_W, .h = DEFAULT_MIN_H };

    // 16:9 landscape (1920x1080 -> 1024x576)
    const r_16_9 = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        0.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 1024, .h = 576 }, r_16_9.?);

    // 9:16 portrait (1080x1920 -> 432x768)
    const r_9_16 = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1080.0, .h = 1920.0 },
        0.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 432, .h = 768 }, r_9_16.?);

    // 3:2 classic photo (6000x4000 -> 1024x683)
    const r_3_2 = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 6000.0, .h = 4000.0 },
        0.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 1024, .h = 683 }, r_3_2.?);

    // 1:1 square (1200x1200 -> 768x768)
    const r_1_1 = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1200.0, .h = 1200.0 },
        0.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 768, .h = 768 }, r_1_1.?);

    // 21:9 ultrawide (2560x1080 -> 1024x432)
    const r_21_9 = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 2560.0, .h = 1080.0 },
        0.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 1024, .h = 432 }, r_21_9.?);
}

test "computeTrimmedWindowDims display bounds clamping" {
    const default_ceiling = WindowDimsI32{ .w = DEFAULT_CEILING_W, .h = DEFAULT_CEILING_H };
    const min_floor = WindowDimsI32{ .w = DEFAULT_MIN_W, .h = DEFAULT_MIN_H };

    // Constrained display bounds: 1920x1080 on 800x600 display -> 800x450
    const usable_800x600 = root.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const r_constrained = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        0.0,
        default_ceiling,
        usable_800x600,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 800, .h = 450 }, r_constrained.?);

    // Display larger than ceiling does not expand beyond default ceiling
    const usable_2560x1440 = root.Rect{ .x = 0, .y = 0, .w = 2560, .h = 1440 };
    const r_large_disp = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        0.0,
        default_ceiling,
        usable_2560x1440,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 1024, .h = 576 }, r_large_disp.?);

    // Empty or non-positive display bounds ignored in favor of default ceiling
    const usable_zero = root.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const r_zero_disp = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        0.0,
        default_ceiling,
        usable_zero,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 1024, .h = 576 }, r_zero_disp.?);
}

test "computeTrimmedWindowDims rotation transposition" {
    const default_ceiling = WindowDimsI32{ .w = DEFAULT_CEILING_W, .h = DEFAULT_CEILING_H };
    const min_floor = WindowDimsI32{ .w = DEFAULT_MIN_W, .h = DEFAULT_MIN_H };

    // 1920x1080 image rotated 90° behaves as 1080x1920 portrait -> 432x768
    const r_rot_90 = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        90.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 432, .h = 768 }, r_rot_90.?);

    // Rotated 270° also transposes -> 432x768
    const r_rot_270 = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        270.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 432, .h = 768 }, r_rot_270.?);

    // Rotated -90° (equivalent to 270°) -> 432x768
    const r_rot_neg90 = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        -90.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 432, .h = 768 }, r_rot_neg90.?);

    // Rotated 180° retains original orientation -> 1024x576
    const r_rot_180 = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        180.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 1024, .h = 576 }, r_rot_180.?);
}

test "computeTrimmedWindowDims extreme aspect ratio floor clamping" {
    const default_ceiling = WindowDimsI32{ .w = DEFAULT_CEILING_W, .h = DEFAULT_CEILING_H };
    const min_floor = WindowDimsI32{ .w = DEFAULT_MIN_W, .h = DEFAULT_MIN_H };

    // Extreme horizontal panorama (10000x200): height clamped to min_floor (200)
    const r_pano = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 10000.0, .h = 200.0 },
        0.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 1024, .h = 200 }, r_pano.?);

    // Extreme vertical strip (200x10000): width clamped to min_floor (320)
    const r_strip = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 200.0, .h = 10000.0 },
        0.0,
        default_ceiling,
        null,
        min_floor,
    );
    try std.testing.expectEqual(WindowDimsI32{ .w = 320, .h = 768 }, r_strip.?);
}

test "computeTrimmedWindowDims tiny display smaller than min_floor" {
    const default_ceiling = WindowDimsI32{ .w = DEFAULT_CEILING_W, .h = DEFAULT_CEILING_H };
    const min_floor = WindowDimsI32{ .w = DEFAULT_MIN_W, .h = DEFAULT_MIN_H };

    // Usable display 250x150 is smaller than 320x200 min_floor; ensure clamp does not panic
    const tiny_disp = root.Rect{ .x = 0, .y = 0, .w = 250, .h = 150 };
    const r_tiny = computeTrimmedWindowDims(
        root.PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        0.0,
        default_ceiling,
        tiny_disp,
        min_floor,
    );
    try std.testing.expect(r_tiny != null);
    try std.testing.expectEqual(WindowDimsI32{ .w = 250, .h = 150 }, r_tiny.?);
}

test "computeTrimmedWindowDims invalid and edge case inputs" {
    const default_ceiling = WindowDimsI32{ .w = DEFAULT_CEILING_W, .h = DEFAULT_CEILING_H };
    const min_floor = WindowDimsI32{ .w = DEFAULT_MIN_W, .h = DEFAULT_MIN_H };

    // Zero raw width or height
    try std.testing.expectEqual(
        @as(?WindowDimsI32, null),
        computeTrimmedWindowDims(root.PhysicalDims{ .w = 0.0, .h = 1080.0 }, 0.0, default_ceiling, null, min_floor),
    );
    try std.testing.expectEqual(
        @as(?WindowDimsI32, null),
        computeTrimmedWindowDims(root.PhysicalDims{ .w = 1920.0, .h = 0.0 }, 0.0, default_ceiling, null, min_floor),
    );

    // Negative raw width or height
    try std.testing.expectEqual(
        @as(?WindowDimsI32, null),
        computeTrimmedWindowDims(root.PhysicalDims{ .w = -1920.0, .h = 1080.0 }, 0.0, default_ceiling, null, min_floor),
    );
    try std.testing.expectEqual(
        @as(?WindowDimsI32, null),
        computeTrimmedWindowDims(root.PhysicalDims{ .w = 1920.0, .h = -1080.0 }, 0.0, default_ceiling, null, min_floor),
    );

    // Non-finite raw dimensions
    try std.testing.expectEqual(
        @as(?WindowDimsI32, null),
        computeTrimmedWindowDims(root.PhysicalDims{ .w = std.math.nan(f32), .h = 1080.0 }, 0.0, default_ceiling, null, min_floor),
    );
    try std.testing.expectEqual(
        @as(?WindowDimsI32, null),
        computeTrimmedWindowDims(root.PhysicalDims{ .w = 1920.0, .h = std.math.inf(f32) }, 0.0, default_ceiling, null, min_floor),
    );

    // Non-positive default ceiling
    try std.testing.expectEqual(
        @as(?WindowDimsI32, null),
        computeTrimmedWindowDims(root.PhysicalDims{ .w = 1920.0, .h = 1080.0 }, 0.0, WindowDimsI32{ .w = 0, .h = 768 }, null, min_floor),
    );
    try std.testing.expectEqual(
        @as(?WindowDimsI32, null),
        computeTrimmedWindowDims(root.PhysicalDims{ .w = 1920.0, .h = 1080.0 }, 0.0, WindowDimsI32{ .w = 1024, .h = -10 }, null, min_floor),
    );
}

test "computeCenterPreservedPosition centering and edge clamping" {
    // 1. Center preservation without display bounds
    const pos_no_bounds = computeCenterPreservedPosition(
        WindowPosI32{ .x = 100, .y = 100 },
        WindowDimsI32{ .w = 1024, .h = 768 },
        WindowDimsI32{ .w = 1024, .h = 576 },
        null,
    );
    // x: 100 + divFloor(1024 - 1024, 2) = 100
    // y: 100 + divFloor(768 - 576, 2) = 100 + 96 = 196
    try std.testing.expectEqual(WindowPosI32{ .x = 100, .y = 196 }, pos_no_bounds);

    // 2. Center preservation when window grows
    const pos_grow = computeCenterPreservedPosition(
        WindowPosI32{ .x = 500, .y = 300 },
        WindowDimsI32{ .w = 432, .h = 768 },
        WindowDimsI32{ .w = 1024, .h = 576 },
        null,
    );
    // x: 500 + divFloor(432 - 1024, 2) = 500 + (-296) = 204
    // y: 300 + divFloor(768 - 576, 2) = 300 + 96 = 396
    try std.testing.expectEqual(WindowPosI32{ .x = 204, .y = 396 }, pos_grow);

    // 3. Left edge underflow clamping
    const bounds_1080p = root.Rect{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const pos_left_underflow = computeCenterPreservedPosition(
        WindowPosI32{ .x = 100, .y = 300 },
        WindowDimsI32{ .w = 400, .h = 400 },
        WindowDimsI32{ .w = 1000, .h = 400 },
        bounds_1080p,
    );
    // unconstrained x: 100 + divFloor(400 - 1000, 2) = -200 -> clamped to 0
    try std.testing.expectEqual(@as(i32, 0), pos_left_underflow.x);

    // 4. Right edge overflow clamping
    const pos_right_overflow = computeCenterPreservedPosition(
        WindowPosI32{ .x = 1800, .y = 300 },
        WindowDimsI32{ .w = 400, .h = 400 },
        WindowDimsI32{ .w = 1000, .h = 400 },
        bounds_1080p,
    );
    // unconstrained x: 1800 - 300 = 1500 -> max_x = 1920 - 1000 = 920 -> clamped to 920
    try std.testing.expectEqual(@as(i32, 920), pos_right_overflow.x);

    // 5. Top edge underflow clamping
    const pos_top_underflow = computeCenterPreservedPosition(
        WindowPosI32{ .x = 500, .y = 50 },
        WindowDimsI32{ .w = 400, .h = 400 },
        WindowDimsI32{ .w = 400, .h = 800 },
        bounds_1080p,
    );
    // unconstrained y: 50 + divFloor(400 - 800, 2) = 50 - 200 = -150 -> clamped to 0
    try std.testing.expectEqual(@as(i32, 0), pos_top_underflow.y);

    // 6. Bottom edge overflow clamping
    const pos_bottom_overflow = computeCenterPreservedPosition(
        WindowPosI32{ .x = 500, .y = 900 },
        WindowDimsI32{ .w = 400, .h = 400 },
        WindowDimsI32{ .w = 400, .h = 800 },
        bounds_1080p,
    );
    // unconstrained y: 900 - 200 = 700 -> max_y = 1080 - 800 = 280 -> clamped to 280
    try std.testing.expectEqual(@as(i32, 280), pos_bottom_overflow.y);

    // 7. Multi-monitor offset (monitor 2 at x=1920, y=100, w=1920, h=1080)
    const bounds_mon2 = root.Rect{ .x = 1920, .y = 100, .w = 1920, .h = 1080 };
    const pos_mon2 = computeCenterPreservedPosition(
        WindowPosI32{ .x = 2200, .y = 300 },
        WindowDimsI32{ .w = 1024, .h = 768 },
        WindowDimsI32{ .w = 1024, .h = 576 },
        bounds_mon2,
    );
    // x: 2200 (within [1920, 1920 + 1920 - 1024 = 2816])
    // y: 300 + 96 = 396 (within [100, 100 + 1080 - 576 = 604])
    try std.testing.expectEqual(WindowPosI32{ .x = 2200, .y = 396 }, pos_mon2);

    const pos_mon2_clamped = computeCenterPreservedPosition(
        WindowPosI32{ .x = 1800, .y = 0 },
        WindowDimsI32{ .w = 1000, .h = 600 },
        WindowDimsI32{ .w = 1000, .h = 600 },
        bounds_mon2,
    );
    // x: 1800 < 1920 -> clamped to 1920
    // y: 0 < 100 -> clamped to 100
    try std.testing.expectEqual(WindowPosI32{ .x = 1920, .y = 100 }, pos_mon2_clamped);

    // 8. Target window larger than display bounds clamps to usable origin without panic
    const bounds_small = root.Rect{ .x = 50, .y = 50, .w = 600, .h = 400 };
    const pos_oversized = computeCenterPreservedPosition(
        WindowPosI32{ .x = 100, .y = 100 },
        WindowDimsI32{ .w = 500, .h = 300 },
        WindowDimsI32{ .w = 800, .h = 600 },
        bounds_small,
    );
    try std.testing.expectEqual(WindowPosI32{ .x = 50, .y = 50 }, pos_oversized);
}
