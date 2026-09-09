const std = @import("std");
const ScaleMode = @import("intents").ScaleMode;
const types = @import("types.zig");
const ZoomFactor = types.ZoomFactor;
const UvRect = types.UvRect;

/// Returns `true` if the normalized rotation angle is approximately 90 or
/// 270 degrees (swapping width and height).
pub fn isAngle90or270(angle: f32) bool {
    const norm = @mod(@mod(angle, 360.0) + 360.0, 360.0);
    return std.math.approxEqAbs(f32, norm, 90.0, 0.1) or
        std.math.approxEqAbs(f32, norm, 270.0, 0.1);
}

/// Computed visual dimensions of an image, its destination layout bounds,
/// and its base scale factor.
pub const ViewDims = struct {
    img_w: f32,
    img_h: f32,
    draw_w: f32,
    draw_h: f32,
    base_scale: f32,
};

/// Calculates rotated image dimensions, fitted screen rectangle bounds,
/// and base scale according to `ScaleMode`.
pub fn computeViewDims(
    raw_w: f32,
    raw_h: f32,
    rotation_angle: f32,
    view_w: f32,
    view_h: f32,
    scale_mode: ScaleMode,
) ViewDims {
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
        .fit_width => {
            draw_w = view_w;
            draw_h = view_w / r_img;
        },
        .fit_height => {
            draw_h = view_h;
            draw_w = view_h * r_img;
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

/// Restricts zoom factor within safe bounds derived from `base_scale`
/// to avoid excessive under- or over-magnification.
pub fn clampZoomFactor(base_scale: f32, factor: f32) ZoomFactor {
    const min_factor = if (base_scale > 0.0) 0.1 / base_scale else 0.1;
    const max_factor = if (base_scale > 0.0) 10.0 / base_scale else 10.0;
    return ZoomFactor.init(std.math.clamp(factor, min_factor, max_factor));
}

/// Computes normalized UV crop boundaries to remove letterbox/pillarbox padding
/// in embedded thumbnails.
/// When `dct_snapped` is true, letterbox/pillarbox margins are aligned to
/// 8-pixel DCT block boundaries as encoded by camera hardware preview
/// generators (e.g. Fujifilm RAF, Ricoh GR IIIx JPEG).
/// When `dct_snapped` is false (e.g. Sony ARW, standard Fujifilm JPEG), exact
/// theoretical aspect-ratio padding is preserved to prevent over-cropping real
/// image pixels and vertical stretch distortion.
pub fn computeThumbnailUvCrop(
    full_w: f32,
    full_h: f32,
    thumb_w: f32,
    thumb_h: f32,
    dct_snapped: bool,
) UvRect {
    if (!std.math.isFinite(full_w) or
        !std.math.isFinite(full_h) or
        !std.math.isFinite(thumb_w) or
        !std.math.isFinite(thumb_h) or
        full_w <= 0.0 or full_h <= 0.0 or thumb_w <= 0.0 or thumb_h <= 0.0)
    {
        return .{};
    }

    const ar_full = full_w / full_h;
    const ar_thumb = thumb_w / thumb_h;

    if (std.math.approxEqAbs(f32, ar_full, ar_thumb, 0.01)) {
        return .{};
    }

    if (ar_full > ar_thumb) {
        // Full image is wider than thumbnail container -> Letterboxing (black bars top/bottom)
        const raw_pad_px = (thumb_h - (thumb_w / ar_full)) / 2.0;
        const pad_px = if (dct_snapped) blk: {
            // Camera hardware RAW preview JPEG encoders align active image
            // and padding to 8-pixel DCT block boundaries.
            const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;
            const can_snap = nearest_block_px > 0.0 and
                nearest_block_px * 2.0 < thumb_h and
                @abs(raw_pad_px - nearest_block_px) <= 2.0;
            break :blk if (can_snap) nearest_block_px else raw_pad_px;
        } else raw_pad_px;

        const v_pad = pad_px / thumb_h;
        const v_min = std.math.clamp(v_pad, 0.0, 0.49);
        return .{ .u_min = 0.0, .v_min = v_min, .u_max = 1.0, .v_max = 1.0 - v_min };
    } else {
        // Full image is taller than thumbnail container -> Pillarboxing (black bars left/right)
        const raw_pad_px = (thumb_w - (thumb_h * ar_full)) / 2.0;
        const pad_px = if (dct_snapped) blk: {
            const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;
            const can_snap = nearest_block_px > 0.0 and
                nearest_block_px * 2.0 < thumb_w and
                @abs(raw_pad_px - nearest_block_px) <= 2.0;
            break :blk if (can_snap) nearest_block_px else raw_pad_px;
        } else raw_pad_px;

        const u_pad = pad_px / thumb_w;
        const u_min = std.math.clamp(u_pad, 0.0, 0.49);
        return .{ .u_min = u_min, .v_min = 0.0, .u_max = 1.0 - u_min, .v_max = 1.0 };
    }
}

test "computeThumbnailUvCrop letterboxing (3:2 in 4:3 thumb snaps to 8px DCT block)" {
    // 8192x5461 (3:2 = 1.50) in 160x120 (4:3 = 1.333)
    // Theoretical padding is 6.67px; camera hardware preview encoder aligns
    // to 8px DCT block boundary.
    const crop = computeThumbnailUvCrop(8192.0, 5461.0, 160.0, 120.0, true);
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 / 120.0), crop.v_min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - (8.0 / 120.0)), crop.v_max, 0.001);
}

test "computeThumbnailUvCrop letterboxing (3:2 in 4:3 thumb when dct_snapped is false)" {
    // 7728x5152 (3:2 = 1.50) in 160x120 (4:3 = 1.333)
    // In-camera JPEGs or non-snapped RAW previews downscale directly to exact
    // aspect ratio with 6.67px padding.
    const crop = computeThumbnailUvCrop(7728.0, 5152.0, 160.0, 120.0, false);
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectApproxEqAbs(@as(f32, 6.66667 / 120.0), crop.v_min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - (6.66667 / 120.0)), crop.v_max, 0.001);
}

test "computeThumbnailUvCrop letterboxing (16:9 in 4:3 thumb snaps to 16px DCT block)" {
    // 3840x2160 (16:9 = 1.7778) in 160x120 (4:3 = 1.333)
    // Theoretical padding is 15.0px; snaps to nearest 16px DCT block boundary
    // (88px active image).
    const crop = computeThumbnailUvCrop(3840.0, 2160.0, 160.0, 120.0, true);
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 120.0), crop.v_min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - (16.0 / 120.0)), crop.v_max, 0.001);
}

test "computeThumbnailUvCrop pillarboxing (3:4 portrait in 4:3 thumb)" {
    // 3000x4000 (3:4 = 0.75) in 160x120 (4:3 = 1.333)
    const crop = computeThumbnailUvCrop(3000.0, 4000.0, 160.0, 120.0, false);
    try std.testing.expectEqual(@as(f32, 0.0), crop.v_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.v_max);
    try std.testing.expectApproxEqAbs(@as(f32, 0.21875), crop.u_min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.78125), crop.u_max, 0.001);
}

test "computeViewDims fit_width and fit_height" {
    // 800x1600 image (1:2 aspect ratio) in 1000x1000 viewport
    const fw = computeViewDims(800.0, 1600.0, 0.0, 1000.0, 1000.0, .fit_width);
    try std.testing.expectEqual(@as(f32, 1000.0), fw.draw_w);
    try std.testing.expectEqual(@as(f32, 2000.0), fw.draw_h);

    const fh = computeViewDims(800.0, 1600.0, 0.0, 1000.0, 1000.0, .fit_height);
    try std.testing.expectEqual(@as(f32, 500.0), fh.draw_w);
    try std.testing.expectEqual(@as(f32, 1000.0), fh.draw_h);
}

test "computeThumbnailUvCrop matching aspect ratios" {
    const crop = computeThumbnailUvCrop(1600.0, 1200.0, 160.0, 120.0, false);
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 0.0), crop.v_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectEqual(@as(f32, 1.0), crop.v_max);
}
