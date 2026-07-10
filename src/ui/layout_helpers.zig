const clay = @import("zclay");
const units = @import("units.zig");
const DpiScale = units.DpiScale;

pub fn scalePadding(top: f32, bottom: f32, left: f32, right: f32, scale: DpiScale) clay.Padding {
    const s = scale.value;
    return .{
        .top = @intFromFloat(top * s),
        .bottom = @intFromFloat(bottom * s),
        .left = @intFromFloat(left * s),
        .right = @intFromFloat(right * s),
    };
}

pub fn scaleCornerRadius(radius: f32, scale: DpiScale) clay.CornerRadius {
    const r = @as(u16, @intFromFloat(radius * scale.value));
    return .{
        .top_left = r,
        .top_right = r,
        .bottom_left = r,
        .bottom_right = r,
    };
}
