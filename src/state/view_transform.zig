const std = @import("std");
const ScaleMode = @import("intents").ScaleMode;
const types = @import("types.zig");
const ZoomFactor = types.ZoomFactor;
const UvRect = types.UvRect;

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

pub fn clampZoomFactor(base_scale: f32, factor: f32) ZoomFactor {
    const min_factor = if (base_scale > 0.0) 0.1 / base_scale else 0.1;
    const max_factor = if (base_scale > 0.0) 10.0 / base_scale else 10.0;
    return ZoomFactor.init(std.math.clamp(factor, min_factor, max_factor));
}

pub fn computeThumbnailUvCrop(
    full_w: f32,
    full_h: f32,
    thumb_w: f32,
    thumb_h: f32,
) UvRect {
    if (full_w <= 0.0 or full_h <= 0.0 or thumb_w <= 0.0 or thumb_h <= 0.0) {
        return .{};
    }

    const ar_full = full_w / full_h;
    const ar_thumb = thumb_w / thumb_h;

    if (std.math.approxEqAbs(f32, ar_full, ar_thumb, 0.01)) {
        return .{};
    }

    if (ar_full > ar_thumb) {
        // Full image is wider than thumbnail container -> Letterboxing (black bars top/bottom)
        const v_pad = (1.0 - (ar_thumb / ar_full)) / 2.0;
        const v_min = std.math.clamp(v_pad, 0.0, 0.49);
        return .{ .u_min = 0.0, .v_min = v_min, .u_max = 1.0, .v_max = 1.0 - v_min };
    } else {
        // Full image is taller than thumbnail container -> Pillarboxing (black bars left/right)
        const u_pad = (1.0 - (ar_full / ar_thumb)) / 2.0;
        const u_min = std.math.clamp(u_pad, 0.0, 0.49);
        return .{ .u_min = u_min, .v_min = 0.0, .u_max = 1.0 - u_min, .v_max = 1.0 };
    }
}

/// Aspect ratio value and provenance source (e.g. decoded GPU texture, EXIF header, or fallback).
pub const AspectInfo = struct {
    ratio: f32,
    source: types.AspectSource,
};

/// Evaluates aspect ratio from active cache entry (GPU, CPU, EXIF, thumbnail, or fallback).
pub fn getAspectRatio(
    entry_opt: ?types.CacheEntry,
    fallback_aspect: f32,
) AspectInfo {
    if (entry_opt) |entry| {
        switch (entry.status) {
            .loaded_gpu => |gpu| {
                if (gpu.w > 0.0 and gpu.h > 0.0) {
                    return .{ .ratio = gpu.w / gpu.h, .source = .decoded_gpu };
                }
            },
            .loaded_cpu => |cpu| {
                if (cpu.w > 0.0 and cpu.h > 0.0) {
                    return .{ .ratio = cpu.w / cpu.h, .source = .decoded_gpu };
                }
            },
            else => {},
        }
        if (entry.full_w > 0.0 and entry.full_h > 0.0) {
            return .{ .ratio = entry.full_w / entry.full_h, .source = .exif_header };
        }
        if (entry.thumbnail.getInfo()) |info| {
            if (info.w > 0.0 and info.h > 0.0) {
                return .{ .ratio = info.w / info.h, .source = .exif_header };
            }
        }
    }
    return .{ .ratio = fallback_aspect, .source = .default_fallback };
}

/// Recalculates contiguous image spans for Continuous Comics Mode (vertical column or horizontal row).
/// Prioritizes `known_ratios` table entries over active cache lookups to ensure stable, immutable offsets.
pub fn recalculateStripSpans(
    spans: *std.ArrayList(types.ImageSpan),
    image_count: usize,
    cache_lookup_fn: *const fn (ctx: ?*const anyopaque, idx: usize) ?types.CacheEntry,
    lookup_ctx: ?*const anyopaque,
    known_ratios: []const f32,
    view_w: f32,
    view_h: f32,
    scale_mode: ScaleMode,
    allocator: std.mem.Allocator,
) !void {
    spans.clearRetainingCapacity();
    if (image_count == 0) return;

    var current_offset: f32 = 0.0;
    var last_known_aspect: f32 = 0.707; // Default portrait ratio fallback

    const is_horizontal = (scale_mode == .fit_height);

    for (0..image_count) |idx| {
        var aspect_info: AspectInfo = undefined;
        if (idx < known_ratios.len and known_ratios[idx] > 0.0) {
            aspect_info = .{ .ratio = known_ratios[idx], .source = .decoded_gpu };
        } else {
            const entry_opt = cache_lookup_fn(lookup_ctx, idx);
            aspect_info = getAspectRatio(entry_opt, last_known_aspect);
        }

        if (aspect_info.source != .default_fallback) {
            last_known_aspect = aspect_info.ratio;
        }

        var primary_sz: f32 = 0.0;
        var cross_sz: f32 = 0.0;

        if (is_horizontal) {
            // Fit height mode: cross = view_h, primary = view_h * aspect
            cross_sz = view_h;
            primary_sz = view_h * aspect_info.ratio;
        } else {
            // Fit width / vertical mode: cross = view_w, primary = view_w / aspect
            cross_sz = view_w;
            primary_sz = view_w / aspect_info.ratio;
        }

        try spans.append(allocator, .{
            .start_offset = current_offset,
            .primary_size = primary_sz,
            .cross_size = cross_sz,
            .aspect_ratio = aspect_info.ratio,
            .aspect_source = aspect_info.source,
        });

        current_offset += primary_sz;
    }
}

/// Performs binary search over `spans` to find the range of image indices (`first_index` .. `last_index`) currently overlapping the camera viewport (`view_min` .. `view_max`).
pub fn findVisibleFrustum(
    spans: []const types.ImageSpan,
    view_min: f32,
    view_max: f32,
) types.VisibleFrustum {
    if (spans.len == 0) return .{
        .first_index = 0,
        .last_index = 0,
        .total_strip_length = 0.0,
        .viewport_min = view_min,
        .viewport_max = view_max,
    };

    const total_length = spans[spans.len - 1].endOffset();

    // Binary search for first span where endOffset() > view_min
    var low: usize = 0;
    var high: usize = spans.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (spans[mid].endOffset() < view_min) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    const first = @min(low, spans.len - 1);

    // Scan until start_offset > view_max
    var last = first;
    while (last < spans.len and spans[last].start_offset <= view_max) {
        last += 1;
    }

    return .{
        .first_index = first,
        .last_index = if (last > 0) last - 1 else 0,
        .total_strip_length = total_length,
        .viewport_min = view_min,
        .viewport_max = view_max,
    };
}

/// Clamps viewport panning offsets (`pan_x`, `pan_y`) in Comic Strip mode to restrict scrolling within comic boundaries `[0, strip_length - view_h]`.
pub fn clampComicsViewportPan(
    pan_x: *f32,
    pan_y: *f32,
    view_w: f32,
    view_h: f32,
    strip_length: f32,
    scale_mode: ScaleMode,
    zoom_factor: f32,
) void {
    const is_horizontal = (scale_mode == .fit_height);

    if (is_horizontal) {
        // Lock Y cross-axis if zoom <= 1.0
        if (zoom_factor <= 1.0) {
            pan_y.* = 0.0;
        } else {
            const max_y = ((view_h * zoom_factor) - view_h) / 2.0;
            pan_y.* = std.math.clamp(pan_y.*, -max_y, max_y);
        }

        // Clamp X primary-axis
        const max_x = @max(0.0, strip_length - view_w);
        pan_x.* = std.math.clamp(pan_x.*, 0.0, max_x);
    } else {
        // Vertical mode: Lock X cross-axis if zoom <= 1.0
        if (zoom_factor <= 1.0) {
            pan_x.* = 0.0;
        } else {
            const max_x = ((view_w * zoom_factor) - view_w) / 2.0;
            pan_x.* = std.math.clamp(pan_x.*, -max_x, max_x);
        }

        // Clamp Y primary-axis
        const max_y = @max(0.0, strip_length - view_h);
        pan_y.* = std.math.clamp(pan_y.*, 0.0, max_y);
    }
}

test "computeThumbnailUvCrop letterboxing (3:2 in 4:3 thumb)" {
    // 8192x5461 (3:2 = 1.50) in 160x120 (4:3 = 1.333)
    const crop = computeThumbnailUvCrop(8192.0, 5461.0, 160.0, 120.0);
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectApproxEqAbs(@as(f32, 0.055582), crop.v_min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.944418), crop.v_max, 0.001);
}

test "computeThumbnailUvCrop pillarboxing (3:4 portrait in 4:3 thumb)" {
    // 3000x4000 (3:4 = 0.75) in 160x120 (4:3 = 1.333)
    const crop = computeThumbnailUvCrop(3000.0, 4000.0, 160.0, 120.0);
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
    const crop = computeThumbnailUvCrop(1600.0, 1200.0, 160.0, 120.0);
    try std.testing.expectEqual(@as(f32, 0.0), crop.u_min);
    try std.testing.expectEqual(@as(f32, 0.0), crop.v_min);
    try std.testing.expectEqual(@as(f32, 1.0), crop.u_max);
    try std.testing.expectEqual(@as(f32, 1.0), crop.v_max);
}

fn mockCacheLookup(_: ?*const anyopaque, idx: usize) ?types.CacheEntry {
    if (idx == 0) {
        return .{
            .status = .{
                .loaded_gpu = .{
                    .gpu_texture = undefined,
                    .w = 1000.0,
                    .h = 2000.0, // aspect 0.5
                },
            },
            .full_w = 1000,
            .full_h = 2000,
        };
    }
    return null; // fallback aspect 0.707
}

test "recalculateStripSpans and findVisibleFrustum" {
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(types.ImageSpan) = .empty;
    defer spans.deinit(allocator);

    try recalculateStripSpans(&spans, 3, mockCacheLookup, null, &.{}, 1000.0, 1000.0, .fit_width, allocator);

    try std.testing.expectEqual(@as(usize, 3), spans.items.len);

    // Image 0: aspect 0.5 -> h = 1000 / 0.5 = 2000. start_offset = 0, end = 2000
    try std.testing.expectEqual(@as(f32, 0.0), spans.items[0].start_offset);
    try std.testing.expectEqual(@as(f32, 2000.0), spans.items[0].primary_size);

    // Image 1: fallback aspect 0.707 -> h = 1000 / 0.707 ~ 1414.427. start_offset = 2000
    try std.testing.expectEqual(@as(f32, 2000.0), spans.items[1].start_offset);

    // Frustum test: view window [1500, 2500] overlaps Image 0 and Image 1
    const frustum = findVisibleFrustum(spans.items, 1500.0, 2500.0);
    try std.testing.expectEqual(@as(usize, 0), frustum.first_index);
    try std.testing.expectEqual(@as(usize, 1), frustum.last_index);
}

test "clampComicsViewportPan vertical and horizontal" {
    var px: f32 = 100.0;
    var py: f32 = 5000.0;

    // Vertical strip of length 3000 in 1000 viewport. Max Y = 2000. Zoom = 1.0 -> X locked to 0
    clampComicsViewportPan(&px, &py, 1000.0, 1000.0, 3000.0, .fit_width, 1.0);
    try std.testing.expectEqual(@as(f32, 0.0), px);
    try std.testing.expectEqual(@as(f32, 2000.0), py);
}

test "getAspectRatio source prioritization" {
    // 1. GPU loaded texture prioritization
    const gpu_entry = types.CacheEntry{
        .status = .{ .loaded_gpu = .{
            .gpu_texture = undefined,
            .w = 1920.0,
            .h = 1080.0,
            .size_bytes = 0,
            .memory_size_bytes = 0,
        } },
        .full_w = 4000.0,
        .full_h = 3000.0,
    };
    const gpu_info = getAspectRatio(gpu_entry, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), gpu_info.ratio, 0.001);
    try std.testing.expectEqual(types.AspectSource.decoded_gpu, gpu_info.source);

    // 2. EXIF full dimensions fallback when entry un-decoded
    const exif_entry = types.CacheEntry{
        .status = .{ .decoding = .{} },
        .full_w = 4000.0,
        .full_h = 2000.0,
    };
    const exif_info = getAspectRatio(exif_entry, 1.0);
    try std.testing.expectEqual(@as(f32, 2.0), exif_info.ratio);
    try std.testing.expectEqual(types.AspectSource.exif_header, exif_info.source);

    // 3. Default fallback
    const fallback_info = getAspectRatio(null, 0.707);
    try std.testing.expectEqual(@as(f32, 0.707), fallback_info.ratio);
    try std.testing.expectEqual(types.AspectSource.default_fallback, fallback_info.source);
}

test "recalculateStripSpans with known_ratios immutability" {
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(types.ImageSpan) = .empty;
    defer spans.deinit(allocator);

    const known = [_]f32{ 2.0, 1.5, 0.5 };
    try recalculateStripSpans(&spans, 3, mockCacheLookup, null, &known, 1000.0, 1000.0, .fit_width, allocator);

    try std.testing.expectEqual(@as(usize, 3), spans.items.len);

    // Image 0: ratio = 2.0 -> h = 1000 / 2.0 = 500
    try std.testing.expectEqual(@as(f32, 500.0), spans.items[0].primary_size);
    // Image 1: ratio = 1.5 -> h = 1000 / 1.5 = 666.666...
    try std.testing.expectApproxEqAbs(@as(f32, 666.666), spans.items[1].primary_size, 0.01);
    try std.testing.expectEqual(@as(f32, 500.0), spans.items[1].start_offset);
}
