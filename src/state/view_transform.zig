const std = @import("std");
const ScaleMode = @import("intents").ScaleMode;
const ZoomFactor = @import("types.zig").ZoomFactor;

pub fn isAngle90or270(angle: f32) bool {
    const norm = @mod(@mod(angle, 360.0) + 360.0, 360.0);
    return std.math.approxEqAbs(f32, norm, 90.0, 0.1) or
        std.math.approxEqAbs(f32, norm, 270.0, 0.1);
}

pub const ViewDims = struct {
    img_w: f32,
    img_h: f32,
    draw_w: f32,
    draw_h: f32,
    base_scale: f32,
};

pub fn computeViewDims(raw_w: f32, raw_h: f32, rotation_angle: f32, view_w: f32, view_h: f32, scale_mode: ScaleMode) ViewDims {
    if (raw_w <= 0.0 or raw_h <= 0.0) {
        return .{
            .img_w = 0.0,
            .img_h = 0.0,
            .draw_w = 0.0,
            .draw_h = 0.0,
            .base_scale = 1.0,
        };
    }

    const is_90_or_270 = isAngle90or270(rotation_angle);
    const img_w = if (is_90_or_270) raw_h else raw_w;
    const img_h = if (is_90_or_270) raw_w else raw_h;

    const r_img = img_w / img_h;
    const r_view = view_w / view_h;

    var draw_w: f32 = img_w;
    var draw_h: f32 = img_h;

    switch (scale_mode) {
        .none => {
            draw_w = img_w;
            draw_h = img_h;
        },
        .shrink => {
            if (img_w <= view_w and img_h <= view_h) {
                draw_w = img_w;
                draw_h = img_h;
            } else {
                if (r_img > r_view) {
                    draw_w = view_w;
                    draw_h = view_w / r_img;
                } else {
                    draw_h = view_h;
                    draw_w = view_h * r_img;
                }
            }
        },
        .full => {
            if (r_img > r_view) {
                draw_w = view_w;
                draw_h = view_w / r_img;
            } else {
                draw_h = view_h;
                draw_w = view_h * r_img;
            }
        },
        .crop => {
            if (r_img > r_view) {
                draw_h = view_h;
                draw_w = view_h * r_img;
            } else {
                draw_w = view_w;
                draw_h = view_h / r_img;
            }
        },
    }

    return .{
        .img_w = img_w,
        .img_h = img_h,
        .draw_w = draw_w,
        .draw_h = draw_h,
        .base_scale = draw_w / img_w,
    };
}

pub fn clampZoomFactor(base_scale: f32, factor: f32) ZoomFactor {
    const min_factor = if (base_scale > 0.0) 0.1 / base_scale else 0.1;
    const max_factor = if (base_scale > 0.0) 10.0 / base_scale else 10.0;
    return ZoomFactor.init(std.math.clamp(factor, min_factor, max_factor));
}
