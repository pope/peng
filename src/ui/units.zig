const std = @import("std");

pub const DpiScale = struct {
    value: f32,

    pub fn init(val: f32) DpiScale {
        return .{ .value = if (val > 0.0) val else 1.0 };
    }
};

pub const Pixels = struct {
    value: f32,

    pub fn init(val: f32) Pixels {
        return .{ .value = val };
    }

    pub fn toLogical(self: Pixels, scale: DpiScale) LogicalPoints {
        return .{ .value = self.value / scale.value };
    }

    pub fn toInt(self: Pixels, comptime T: type) T {
        return @intFromFloat(self.value);
    }
};

pub const LogicalPoints = struct {
    value: f32,

    pub fn init(val: f32) LogicalPoints {
        return .{ .value = val };
    }

    pub fn toPixels(self: LogicalPoints, scale: DpiScale) Pixels {
        return .{ .value = self.value * scale.value };
    }
};
