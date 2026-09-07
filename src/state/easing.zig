const std = @import("std");

/// Mathematical curve algorithms for smooth animation interpolation.
pub const EasingType = enum {
    linear,
    ease_out_cubic,
    ease_in_cubic,
    ease_in_out_cubic,
    ease_out_quad,

    /// Evaluates the easing function for normalized time `t` (clamped to 0.0 .. 1.0).
    pub inline fn eval(self: EasingType, t: f32) f32 {
        if (std.math.isNan(t)) return 0.0;
        const ct = std.math.clamp(t, 0.0, 1.0);
        return switch (self) {
            .linear => ct,
            .ease_out_cubic => blk: {
                const inv = 1.0 - ct;
                break :blk 1.0 - inv * inv * inv;
            },
            .ease_in_cubic => ct * ct * ct,
            .ease_in_out_cubic => if (ct < 0.5)
                4.0 * ct * ct * ct
            else blk: {
                const inv = -2.0 * ct + 2.0;
                break :blk 1.0 - (inv * inv * inv) * 0.5;
            },
            .ease_out_quad => blk: {
                const inv = 1.0 - ct;
                break :blk 1.0 - inv * inv;
            },
        };
    }
};

test "easing boundary conditions" {
    inline for (std.meta.tags(EasingType)) |e| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), e.eval(0.0), 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), e.eval(1.0), 0.0001);
        // Clamping out-of-bounds
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), e.eval(-0.5), 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), e.eval(1.5), 0.0001);
    }
}

test "easing midpoint monotonicity" {
    const t: f32 = 0.5;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), EasingType.linear.eval(t), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), EasingType.ease_in_out_cubic.eval(t), 0.0001);

    // Ease-out decelerates (higher at t=0.5 than linear)
    try std.testing.expect(EasingType.ease_out_cubic.eval(t) > 0.5);
    try std.testing.expect(EasingType.ease_out_quad.eval(t) > 0.5);

    // Ease-in accelerates (lower at t=0.5 than linear)
    try std.testing.expect(EasingType.ease_in_cubic.eval(t) < 0.5);
}
