const geom = @import("geom");
const intents = @import("intents");
const std = @import("std");
const viewport = @import("viewport.zig");

const DpiScale = geom.DpiScale;
const LogicalDims = geom.LogicalDims;
const PhysicalDims = geom.PhysicalDims;
const UvRect = geom.UvRect;
const ZoomFactor = viewport.ZoomFactor;
const ZoomPreset = intents.ZoomPreset;

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
    draw_dims: PhysicalDims = .{},
    base_scale: f32,
};

/// Calculates rotated image dimensions, fitted screen rectangle bounds,
/// and base scale according to `ZoomPreset`.
pub fn computeViewDims(
    raw_dims: PhysicalDims,
    rotation_angle: f32,
    view_dims: PhysicalDims,
    scale_mode: ZoomPreset,
) ViewDims {
    if (raw_dims.w <= 0.0 or raw_dims.h <= 0.0 or
        view_dims.w <= 0.0 or view_dims.h <= 0.0)
    {
        return .{
            .draw_dims = .{},
            .base_scale = 1.0,
        };
    }

    const is_90_or_270 = isAngle90or270(rotation_angle);
    const img_w = if (is_90_or_270) raw_dims.h else raw_dims.w;
    const img_h = if (is_90_or_270) raw_dims.w else raw_dims.h;

    const r_img = img_w / img_h;
    const r_view = view_dims.w / view_dims.h;

    var draw_w: f32 = img_w;
    var draw_h: f32 = img_h;

    switch (scale_mode) {
        .none => {
            draw_w = img_w;
            draw_h = img_h;
        },
        .shrink => {
            if (img_w <= view_dims.w and img_h <= view_dims.h) {
                draw_w = img_w;
                draw_h = img_h;
            } else {
                if (r_img > r_view) {
                    draw_w = view_dims.w;
                    draw_h = view_dims.w / r_img;
                } else {
                    draw_h = view_dims.h;
                    draw_w = view_dims.h * r_img;
                }
            }
        },
        .full => {
            if (r_img > r_view) {
                draw_w = view_dims.w;
                draw_h = view_dims.w / r_img;
            } else {
                draw_h = view_dims.h;
                draw_w = view_dims.h * r_img;
            }
        },
        .crop => {
            if (r_img > r_view) {
                draw_h = view_dims.h;
                draw_w = view_dims.h * r_img;
            } else {
                draw_w = view_dims.w;
                draw_h = view_dims.w / r_img;
            }
        },
        .fit_width => {
            draw_w = view_dims.w;
            draw_h = view_dims.w / r_img;
        },
        .fit_height => {
            draw_h = view_dims.h;
            draw_w = view_dims.h * r_img;
        },
    }

    return .{
        .draw_dims = .{ .w = draw_w, .h = draw_h },
        .base_scale = draw_w / img_w,
    };
}

/// Evaluates `computeViewDims` in physical framebuffer space (`viewport`
/// converted via `scale`) and converts the resulting draw bounds back into
/// logical UI points (`LogicalDims`) for UI layout.
pub fn computeLogicalDrawDims(
    src_phys: PhysicalDims,
    viewport_logical: LogicalDims,
    scale: DpiScale,
    rotation_angle: f32,
    scale_mode: ZoomPreset,
) LogicalDims {
    if (src_phys.w <= 0.0 or src_phys.h <= 0.0 or
        viewport_logical.w <= 0.0 or viewport_logical.h <= 0.0)
    {
        return .{ .w = 0.0, .h = 0.0 };
    }
    const phys_view = viewport_logical.toPhysical(scale);
    const dims = computeViewDims(
        src_phys,
        rotation_angle,
        .{ .w = @max(phys_view.w, 1.0), .h = @max(phys_view.h, 1.0) },
        scale_mode,
    );
    return dims.draw_dims.toLogical(scale);
}

/// Computes the universal pixel zoom factor Z for a target preset.
pub fn computePresetZoom(
    raw_dims: PhysicalDims,
    rotation_angle: f32,
    view_dims: PhysicalDims,
    preset: ZoomPreset,
) f32 {
    if (raw_dims.w <= 0.0 or raw_dims.h <= 0.0 or
        view_dims.w <= 0.0 or view_dims.h <= 0.0)
    {
        return 1.0;
    }
    const is_90_or_270 = isAngle90or270(rotation_angle);
    const img_w = if (is_90_or_270) raw_dims.h else raw_dims.w;
    const img_h = if (is_90_or_270) raw_dims.w else raw_dims.h;

    return switch (preset) {
        .none => 1.0,
        .shrink => if (img_w <= view_dims.w and img_h <= view_dims.h)
            1.0
        else
            @min(view_dims.w / img_w, view_dims.h / img_h),
        .full => @min(view_dims.w / img_w, view_dims.h / img_h),
        .crop => @max(view_dims.w / img_w, view_dims.h / img_h),
        .fit_width => view_dims.w / img_w,
        .fit_height => view_dims.h / img_h,
    };
}

/// Restricts zoom factor within safe universal bounds [ZoomFactor.MIN,
/// ZoomFactor.MAX] to avoid excessive under- or over-magnification.
pub fn clampZoomFactor(factor: f32) ZoomFactor {
    return ZoomFactor.init(factor);
}

/// Mutually exclusive thumbnail letterbox or pillarbox padding result.
/// Mathematically guarantees:
/// 1. Letterbox and pillarbox padding are mutually exclusive.
/// 2. Active image axes are centered symmetrically (e.g. v_max == 1.0 - v_min).
/// 3. Unpadded axis stays normalized to full span [0.0, 1.0].
pub const ThumbnailPadding = union(enum) {
    none,
    letterbox: struct {
        v_min: f32,
        v_max: f32,
        pad_px: f32,
    },
    pillarbox: struct {
        u_min: f32,
        u_max: f32,
        pad_px: f32,
    },

    /// Converts thumbnail padding boundaries into a normalized UvRect for GPU rendering.
    pub fn toUvRect(self: ThumbnailPadding) UvRect {
        return switch (self) {
            .none => .{},
            .letterbox => |lb| .{
                .u_min = 0.0,
                .v_min = lb.v_min,
                .u_max = 1.0,
                .v_max = lb.v_max,
            },
            .pillarbox => |pb| .{
                .u_min = pb.u_min,
                .v_min = 0.0,
                .u_max = pb.u_max,
                .v_max = 1.0,
            },
        };
    }

    /// Returns the pixel margin padding applied to container boundaries.
    pub fn getPaddingPx(self: ThumbnailPadding) f32 {
        return switch (self) {
            .none => 0.0,
            .letterbox => |lb| lb.pad_px,
            .pillarbox => |pb| pb.pad_px,
        };
    }
};

/// Computes normalized thumbnail padding to remove letterbox/pillarbox margins
/// in embedded camera thumbnails.
pub fn computeThumbnailPadding(
    full_dims: PhysicalDims,
    thumb_dims: PhysicalDims,
    dct_snapped: bool,
) ThumbnailPadding {
    if (!std.math.isFinite(full_dims.w) or
        !std.math.isFinite(full_dims.h) or
        !std.math.isFinite(thumb_dims.w) or
        !std.math.isFinite(thumb_dims.h) or
        full_dims.w <= 0.0 or full_dims.h <= 0.0 or
        thumb_dims.w <= 0.0 or thumb_dims.h <= 0.0)
    {
        return .none;
    }

    const ar_full = full_dims.w / full_dims.h;
    const ar_thumb = thumb_dims.w / thumb_dims.h;

    if (std.math.approxEqAbs(f32, ar_full, ar_thumb, 0.01)) {
        return .none;
    }

    if (ar_full > ar_thumb) {
        // Full image is wider than thumbnail container -> Letterboxing
        const raw_pad_px = (thumb_dims.h - (thumb_dims.w / ar_full)) / 2.0;
        const pad_px = if (dct_snapped) blk: {
            // Camera hardware RAW preview JPEG encoders align active image
            // and padding to 8-pixel DCT block boundaries.
            const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;
            const can_snap = nearest_block_px > 0.0 and
                nearest_block_px * 2.0 < thumb_dims.h and
                @abs(raw_pad_px - nearest_block_px) <= 2.0;
            break :blk if (can_snap) nearest_block_px else raw_pad_px;
        } else raw_pad_px;

        const v_pad = pad_px / thumb_dims.h;
        const v_min = std.math.clamp(v_pad, 0.0, 0.49);
        return .{
            .letterbox = .{
                .v_min = v_min,
                .v_max = 1.0 - v_min,
                .pad_px = pad_px,
            },
        };
    } else {
        // Full image is taller than thumbnail container -> Pillarboxing
        const raw_pad_px = (thumb_dims.w - (thumb_dims.h * ar_full)) / 2.0;
        const pad_px = if (dct_snapped) blk: {
            const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;
            const can_snap = nearest_block_px > 0.0 and
                nearest_block_px * 2.0 < thumb_dims.w and
                @abs(raw_pad_px - nearest_block_px) <= 2.0;
            break :blk if (can_snap) nearest_block_px else raw_pad_px;
        } else raw_pad_px;

        const u_pad = pad_px / thumb_dims.w;
        const u_min = std.math.clamp(u_pad, 0.0, 0.49);
        return .{
            .pillarbox = .{
                .u_min = u_min,
                .u_max = 1.0 - u_min,
                .pad_px = pad_px,
            },
        };
    }
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
    full_dims: PhysicalDims,
    thumb_dims: PhysicalDims,
    dct_snapped: bool,
) UvRect {
    return computeThumbnailPadding(
        full_dims,
        thumb_dims,
        dct_snapped,
    ).toUvRect();
}

test "computeThumbnailUvCrop letterboxing (3:2 in 4:3 thumb snaps to 8px DCT block)" {
    // 8192x5461 (3:2 = 1.50) in 160x120 (4:3 = 1.333)
    // Theoretical padding is 6.67px; camera hardware preview encoder aligns
    // to 8px DCT block boundary.
    const crop = computeThumbnailUvCrop(
        .{ .w = 8192.0, .h = 5461.0 },
        .{ .w = 160.0, .h = 120.0 },
        true,
    );
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 / 120.0), crop.v_min, 0.001);
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0 - (8.0 / 120.0)),
        crop.v_max,
        0.001,
    );
}

test "computeThumbnailUvCrop letterboxing (3:2 in 4:3 thumb when dct_snapped is false)" {
    // 7728x5152 (3:2 = 1.50) in 160x120 (4:3 = 1.333)
    // In-camera JPEGs or non-snapped RAW previews downscale directly to exact
    // aspect ratio with 6.67px padding.
    const crop = computeThumbnailUvCrop(
        .{ .w = 7728.0, .h = 5152.0 },
        .{ .w = 160.0, .h = 120.0 },
        false,
    );
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectApproxEqAbs(
        @as(f32, 6.66667 / 120.0),
        crop.v_min,
        0.001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0 - (6.66667 / 120.0)),
        crop.v_max,
        0.001,
    );
}

test "computeThumbnailUvCrop letterboxing (16:9 in 4:3 thumb snaps to 16px DCT block)" {
    // 3840x2160 (16:9 = 1.7778) in 160x120 (4:3 = 1.333)
    // Theoretical padding is 15.0px; snaps to nearest 16px DCT block boundary
    // (88px active image).
    const crop = computeThumbnailUvCrop(
        .{ .w = 3840.0, .h = 2160.0 },
        .{ .w = 160.0, .h = 120.0 },
        true,
    );
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectApproxEqAbs(
        @as(f32, 16.0 / 120.0),
        crop.v_min,
        0.001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0 - (16.0 / 120.0)),
        crop.v_max,
        0.001,
    );
}

test "computeThumbnailUvCrop pillarboxing (3:4 portrait in 4:3 thumb)" {
    // 3000x4000 (3:4 = 0.75) in 160x120 (4:3 = 1.333)
    const crop = computeThumbnailUvCrop(
        .{ .w = 3000.0, .h = 4000.0 },
        .{ .w = 160.0, .h = 120.0 },
        false,
    );
    try std.testing.expectEqual(@as(f32, 0.0), crop.v_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.v_max);
    try std.testing.expectApproxEqAbs(@as(f32, 0.21875), crop.u_min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.78125), crop.u_max, 0.001);
}

test "computeViewDims fit_width, fit_height, and crop" {
    // 800x1600 portrait image (1:2 aspect ratio) in 1000x800 viewport
    const fw = computeViewDims(
        .{ .w = 800.0, .h = 1600.0 },
        0.0,
        .{ .w = 1000.0, .h = 800.0 },
        .fit_width,
    );
    try std.testing.expectEqual(@as(f32, 1000.0), fw.draw_dims.w);
    try std.testing.expectEqual(@as(f32, 2000.0), fw.draw_dims.h);

    const fh = computeViewDims(
        .{ .w = 800.0, .h = 1600.0 },
        0.0,
        .{ .w = 1000.0, .h = 800.0 },
        .fit_height,
    );
    try std.testing.expectEqual(@as(f32, 400.0), fh.draw_dims.w);
    try std.testing.expectEqual(@as(f32, 800.0), fh.draw_dims.h);

    // Portrait image (r_img = 0.5 <= r_view = 1.25) in .crop mode fills width
    // (draw_w = 1000) and preserves 1:2 aspect ratio (draw_h = 2000).
    const crop_portrait = computeViewDims(
        .{ .w = 800.0, .h = 1600.0 },
        0.0,
        .{ .w = 1000.0, .h = 800.0 },
        .crop,
    );
    try std.testing.expectEqual(
        @as(f32, 1000.0),
        crop_portrait.draw_dims.w,
    );
    try std.testing.expectEqual(
        @as(f32, 2000.0),
        crop_portrait.draw_dims.h,
    );
    try std.testing.expectEqual(@as(f32, 1.25), crop_portrait.base_scale);

    // Landscape image (1600x800, r_img = 2.0 > r_view = 1.25) in .crop mode
    // fills height (draw_h = 800) and preserves 2:1 aspect (draw_w = 1600).
    const crop_landscape = computeViewDims(
        .{ .w = 1600.0, .h = 800.0 },
        0.0,
        .{ .w = 1000.0, .h = 800.0 },
        .crop,
    );
    try std.testing.expectEqual(
        @as(f32, 1600.0),
        crop_landscape.draw_dims.w,
    );
    try std.testing.expectEqual(
        @as(f32, 800.0),
        crop_landscape.draw_dims.h,
    );
    try std.testing.expectEqual(@as(f32, 1.0), crop_landscape.base_scale);
}

test "computeThumbnailUvCrop matching aspect ratios" {
    const crop = computeThumbnailUvCrop(
        .{ .w = 1600.0, .h = 1200.0 },
        .{ .w = 160.0, .h = 120.0 },
        false,
    );
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 0.0), crop.v_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectEqual(@as(f32, 1.0), crop.v_max);
}

test "computeThumbnailPadding tagged union variants" {
    // Letterbox test
    const lb_pad = computeThumbnailPadding(
        .{ .w = 8192.0, .h = 5461.0 },
        .{ .w = 160.0, .h = 120.0 },
        true,
    );
    switch (lb_pad) {
        .letterbox => |lb| {
            try std.testing.expectEqual(@as(f32, 8.0), lb.pad_px);
            try std.testing.expectApproxEqAbs(
                @as(f32, 8.0 / 120.0),
                lb.v_min,
                0.001,
            );
            try std.testing.expectApproxEqAbs(
                @as(f32, 1.0 - (8.0 / 120.0)),
                lb.v_max,
                0.001,
            );
        },
        else => unreachable,
    }
    try std.testing.expectEqual(@as(f32, 8.0), lb_pad.getPaddingPx());

    // Pillarbox test
    const pb_pad = computeThumbnailPadding(
        .{ .w = 3000.0, .h = 4000.0 },
        .{ .w = 160.0, .h = 120.0 },
        false,
    );
    switch (pb_pad) {
        .pillarbox => |pb| {
            try std.testing.expectApproxEqAbs(@as(f32, 35.0), pb.pad_px, 0.01);
            try std.testing.expectApproxEqAbs(
                @as(f32, 0.21875),
                pb.u_min,
                0.001,
            );
            try std.testing.expectApproxEqAbs(
                @as(f32, 0.78125),
                pb.u_max,
                0.001,
            );
        },
        else => unreachable,
    }

    // None test
    const none_pad = computeThumbnailPadding(
        .{ .w = 1600.0, .h = 1200.0 },
        .{ .w = 160.0, .h = 120.0 },
        false,
    );
    try std.testing.expectEqual(ThumbnailPadding.none, none_pad);
    try std.testing.expectEqual(@as(f32, 0.0), none_pad.getPaddingPx());
}

test "computePresetZoom calculations" {
    // 1024x682 image in 1024x768 viewport
    const z_fit = computePresetZoom(
        .{ .w = 1024.0, .h = 682.0 },
        0.0,
        .{ .w = 1024.0, .h = 768.0 },
        .full,
    );
    try std.testing.expectEqual(@as(f32, 1.0), z_fit);

    const z_crop = computePresetZoom(
        .{ .w = 1024.0, .h = 682.0 },
        0.0,
        .{ .w = 1024.0, .h = 768.0 },
        .crop,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 768.0 / 682.0), z_crop, 0.0001);

    const z_none = computePresetZoom(
        .{ .w = 1024.0, .h = 682.0 },
        0.0,
        .{ .w = 1024.0, .h = 768.0 },
        .none,
    );
    try std.testing.expectEqual(@as(f32, 1.0), z_none);

    // Rotated 90 degrees (becomes 682x1024)
    const z_fit_rot = computePresetZoom(
        .{ .w = 1024.0, .h = 682.0 },
        90.0,
        .{ .w = 1024.0, .h = 768.0 },
        .full,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 768.0 / 1024.0),
        z_fit_rot,
        0.0001,
    );

    const z_crop_rot = computePresetZoom(
        .{ .w = 1024.0, .h = 682.0 },
        90.0,
        .{ .w = 1024.0, .h = 768.0 },
        .crop,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 1024.0 / 682.0),
        z_crop_rot,
        0.0001,
    );
}

test "clampZoomFactor bounds" {
    try std.testing.expectEqual(@as(f32, 100.0), clampZoomFactor(150.0).get());
    try std.testing.expectEqual(@as(f32, 0.001), clampZoomFactor(0.0001).get());
    try std.testing.expectEqual(@as(f32, 1.5), clampZoomFactor(1.5).get());
}
