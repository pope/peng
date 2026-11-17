const geom = @import("geom");
const intents = @import("intents");
const palette_pkg = @import("palette");
const renderer = @import("renderer.zig");
const state = @import("state");
const std = @import("std");
const text_utils = @import("text_utils.zig");
const theme = @import("theme.zig");
const view_model = @import("view_model.zig");

const Color = theme.Color;
const FRect = geom.FRect;
const FuzzyHighlighter = palette_pkg.FuzzyHighlighter;
const getPaletteConfig = palette_pkg.getPaletteConfig;
const LogicalDims = geom.LogicalDims;
const MeasureTextUserData = text_utils.MeasureTextUserData;
const PaletteConfig = palette_pkg.PaletteConfig;
const palette_action_items = intents.actions.palette_action_items;
const PaletteMode = intents.PaletteMode;
const PaletteState = palette_pkg.PaletteState;
const partitionHighlightedText = palette_pkg.partitionHighlightedText;
const remapMiddleTruncatedMatches = palette_pkg.remapMiddleTruncatedMatches;
const TextSpan = renderer.TextSpan;
const truncateDirectory = text_utils.truncateDirectory;
const truncateFilename = text_utils.truncateFilename;
const truncateFilenameMiddle = text_utils.truncateFilenameMiddle;
const UiDrawList = renderer.UiDrawList;
const UiViewModel = view_model.UiViewModel;
const VirtualWindow = palette_pkg.VirtualWindow;
const withAlpha = theme.withAlpha;

/// Emits text spans partitioning characters into alternating normal
/// and highlighted segments based on fuzzy match indices.
fn renderFuzzyMatchText(
    list: *UiDrawList,
    allocator: std.mem.Allocator,
    rect: FRect,
    text: []const u8,
    match_indices: []const usize,
    font_size: u16,
    normal_color: Color,
    highlight_color: Color,
) !void {
    if (text.len == 0) return;
    if (match_indices.len == 0) {
        try list.addText(rect, .{
            .text = text,
            .color = normal_color,
            .font_size = font_size,
            .font_id = 0,
        });
        return;
    }

    const chunks = partitionHighlightedText(
        allocator,
        text,
        match_indices,
    ) catch |err| {
        std.log.err(
            "partitionHighlightedText failed for '{s}': {}",
            .{ text, err },
        );
        try list.addText(rect, .{
            .text = text,
            .color = normal_color,
            .font_size = font_size,
            .font_id = 0,
        });
        return;
    };
    defer allocator.free(chunks);

    const spans = try allocator.alloc(TextSpan, chunks.len);
    for (chunks, 0..) |chunk, i| {
        spans[i] = .{
            .text = chunk.slice,
            .color = if (chunk.is_matched) highlight_color else normal_color,
        };
    }
    try list.addTextRuns(rect, .{
        .spans = spans,
        .font_size = font_size,
        .font_id = 0,
    });
}

fn renderHeader(
    list: *UiDrawList,
    rect: FRect,
    mode: PaletteMode,
    title: []const u8,
    progress: f32,
) !void {
    const text_color = withAlpha(switch (mode) {
        .files => theme.pink,
        .actions => theme.blue,
        .directory_navigator => theme.mauve,
        .prompt => |kind| switch (kind) {
            .edit_param => theme.peach,
            .go_to_image => theme.green,
            .slideshow_interval => theme.yellow,
        },
        .inactive => theme.text,
    }, progress);

    try list.addText(rect, .{
        .text = title,
        .color = text_color,
        .font_size = 13,
        .font_id = 0,
    });
}

fn renderBadge(
    list: *UiDrawList,
    x: f32,
    center_y: f32,
    text: []const u8,
    text_color: Color,
    border_color: Color,
    progress: f32,
    measure_data: *const MeasureTextUserData,
) !f32 {
    const dims = text_utils.measureText(text, 0, 11, measure_data);
    const badge_w = dims.w + 12.0;
    const badge_h = if (dims.h > 0.0) dims.h + 4.0 else 17.0;
    const y = center_y - badge_h * 0.5;
    const badge_rect = FRect{ .x = x, .y = y, .w = badge_w, .h = badge_h };

    try list.addRect(badge_rect, .{
        .background_color = withAlpha(theme.crust, progress),
        .corner_radius = .all(4),
    });
    try list.addBorder(badge_rect, .{
        .color = withAlpha(border_color, progress),
        .width = .all(1),
        .corner_radius = .all(4),
    });
    try list.addText(.{
        .x = x + 6.0,
        .y = y + 2.0,
        .w = dims.w,
        .h = dims.h,
    }, .{
        .text = text,
        .color = withAlpha(text_color, progress),
        .font_size = 11,
        .font_id = 0,
    });
    return badge_w;
}

fn renderShortcutBadge(
    list: *UiDrawList,
    x: f32,
    center_y: f32,
    text: []const u8,
    progress: f32,
    measure_data: *const MeasureTextUserData,
) !f32 {
    const dims = text_utils.measureText(text, 0, 11, measure_data);
    const badge_w = dims.w + 16.0;
    const badge_h = if (dims.h > 0.0) dims.h + 6.0 else 19.0;
    const y = center_y - badge_h * 0.5;
    const badge_rect = FRect{ .x = x, .y = y, .w = badge_w, .h = badge_h };

    try list.addRect(badge_rect, .{
        .background_color = withAlpha(theme.crust, progress),
        .corner_radius = .all(4),
    });
    try list.addBorder(badge_rect, .{
        .color = withAlpha(theme.surface0, progress),
        .width = .all(1),
        .corner_radius = .all(4),
    });
    try list.addText(.{
        .x = x + 8.0,
        .y = y + 3.0,
        .w = dims.w,
        .h = dims.h,
    }, .{
        .text = text,
        .color = withAlpha(theme.subtext0, progress),
        .font_size = 11,
        .font_id = 0,
    });
    return badge_w;
}

fn renderClassificationBadge(
    list: *UiDrawList,
    x: f32,
    center_y: f32,
    label: []const u8,
    color: Color,
    progress: f32,
    measure_data: *const MeasureTextUserData,
) !f32 {
    const dims = text_utils.measureText(label, 0, 11, measure_data);
    const badge_w = dims.w + 12.0;
    const badge_h = if (dims.h > 0.0) dims.h + 4.0 else 17.0;
    const y = center_y - badge_h * 0.5;
    const badge_rect = FRect{ .x = x, .y = y, .w = badge_w, .h = badge_h };

    try list.addRect(badge_rect, .{
        .background_color = theme.withAlpha(color, 0.25 * progress),
        .corner_radius = .all(4),
    });
    try list.addBorder(badge_rect, .{
        .color = withAlpha(color, progress),
        .width = .all(1),
        .corner_radius = .all(4),
    });
    try list.addText(.{
        .x = x + 6.0,
        .y = y + 2.0,
        .w = dims.w,
        .h = dims.h,
    }, .{
        .text = label,
        .color = withAlpha(color, progress),
        .font_size = 11,
        .font_id = 0,
    });
    return badge_w;
}

fn renderDirectoryBreadcrumbs(
    list: *UiDrawList,
    rect: FRect,
    palette: *const PaletteState,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    try list.addRect(rect, .{
        .background_color = withAlpha(theme.crust, progress),
        .corner_radius = .all(6),
    });
    try list.addBorder(rect, .{
        .color = withAlpha(theme.surface0, progress),
        .width = .all(1),
        .corner_radius = .all(6),
    });

    const display_dir = truncateDirectory(
        frame_allocator,
        palette.current_nav_dir.items,
        rect.w - 180.0,
        12,
        measure_data,
    );
    const curr_img_count = palette.current_dir_image_count;
    const s_suffix = if (curr_img_count == 1) "" else "s";
    const count_str = try frame_allocator.print(
        "{} image{s}",
        .{ curr_img_count, s_suffix },
    );
    const count_color =
        if (curr_img_count == 0) theme.subtext1 else theme.green;
    const border_color =
        if (curr_img_count == 0) theme.surface0 else theme.green;

    var cur_x = rect.x + 8.0;
    const badge_center_y = rect.y + rect.h * 0.5;
    const dir_badge_w = try renderBadge(
        list,
        cur_x,
        badge_center_y,
        "DIR",
        theme.mauve,
        theme.mauve,
        progress,
        measure_data,
    );
    cur_x += dir_badge_w + 8.0;

    const dir_dims = text_utils.measureText(display_dir, 0, 12, measure_data);
    try list.addText(.{
        .x = cur_x,
        .y = rect.y + (rect.h - dir_dims.h) * 0.5,
        .w = dir_dims.w,
        .h = dir_dims.h,
    }, .{
        .text = display_dir,
        .color = withAlpha(theme.mauve, progress),
        .font_size = 12,
        .font_id = 0,
    });

    const count_dims = text_utils.measureText(count_str, 0, 11, measure_data);
    const count_badge_w = count_dims.w + 12.0;
    const right_x = rect.x + rect.w - 8.0 - count_badge_w;
    _ = try renderBadge(
        list,
        right_x,
        badge_center_y,
        count_str,
        count_color,
        border_color,
        progress,
        measure_data,
    );
}

fn renderSearchInput(
    list: *UiDrawList,
    rect: FRect,
    palette: *const PaletteState,
    placeholder: []const u8,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    try list.addRect(rect, .{
        .background_color = withAlpha(theme.crust, progress),
        .corner_radius = .all(6),
    });
    try list.addBorder(rect, .{
        .color = withAlpha(theme.blue, progress),
        .width = .all(1),
        .corner_radius = .all(6),
    });

    const query_str =
        if (palette.query.items.len > 0) palette.query.items else placeholder;
    const query_color =
        if (palette.query.items.len > 0) theme.text else theme.subtext1;
    const dims = text_utils.measureText(query_str, 0, 14, measure_data);

    try list.addText(.{
        .x = rect.x + 12.0,
        .y = rect.y + (rect.h - dims.h) * 0.5,
        .w = dims.w,
        .h = dims.h,
    }, .{
        .text = query_str,
        .color = withAlpha(query_color, progress),
        .font_size = 14,
        .font_id = 0,
    });
}

fn renderGoToImageFeedback(
    list: *UiDrawList,
    rect: FRect,
    raw_str: []const u8,
    total_count: usize,
    ui_model: UiViewModel,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    const val = std.fmt.parseInt(usize, raw_str, 10) catch |err| {
        std.log.debug(
            "Failed to parse integer in palette input '{s}': {}",
            .{ raw_str, err },
        );
        try list.addText(rect, .{
            .text = "Invalid number format. Enter a positive integer.",
            .color = withAlpha(theme.red, progress),
            .font_size = 13,
            .font_id = 0,
        });
        return;
    };

    if (val < 1 or val > total_count) {
        const err_str = try frame_allocator.print(
            "Out of bounds: must be between 1 and {}",
            .{total_count},
        );
        try list.addText(rect, .{
            .text = err_str,
            .color = withAlpha(theme.red, progress),
            .font_size = 13,
            .font_id = 0,
        });
        return;
    }

    const cur_idx = ui_model.current_index orelse 0;
    const is_cur = val - 1 < total_count and
        ui_model.current_image_entry != null and
        val - 1 == cur_idx;
    const target_entry = if (is_cur) ui_model.current_image_entry.? else null;
    const raw_basename = if (target_entry) |e| e.getBasename() else "";
    const display_filename = truncateFilename(
        frame_allocator,
        raw_basename,
        rect.w,
        12,
        measure_data,
    );
    const success_str = try frame_allocator.print(
        "Press Enter to go to {}: {s}",
        .{ val, display_filename },
    );
    try list.addText(rect, .{
        .text = success_str,
        .color = withAlpha(theme.green, progress),
        .font_size = 13,
        .font_id = 0,
    });
}

fn renderSlideshowIntervalFeedback(
    list: *UiDrawList,
    rect: FRect,
    raw_str: []const u8,
    frame_allocator: std.mem.Allocator,
    progress: f32,
) !void {
    var is_valid = false;
    if (std.fmt.parseFloat(f32, raw_str)) |val| {
        if (!std.math.isNan(val) and !std.math.isInf(val) and val > 0.0) {
            is_valid = true;
            const success_str = try frame_allocator.print(
                "Press Enter to start slide show ({d:.1}s per slide)",
                .{val},
            );
            try list.addText(rect, .{
                .text = success_str,
                .color = withAlpha(theme.green, progress),
                .font_size = 13,
                .font_id = 0,
            });
        }
    } else |err| {
        std.log.debug(
            "Failed to parse slideshow float '{s}': {}",
            .{ raw_str, err },
        );
    }
    if (!is_valid) {
        try list.addText(rect, .{
            .text = "Invalid duration. Must be greater than 0 seconds.",
            .color = withAlpha(theme.red, progress),
            .font_size = 13,
            .font_id = 0,
        });
    }
}

fn renderFloatInputFeedback(
    list: *UiDrawList,
    rect: FRect,
    raw_str: []const u8,
    mode: PaletteMode,
    frame_allocator: std.mem.Allocator,
    progress: f32,
) !void {
    const val = std.fmt.parseFloat(f32, raw_str) catch |err| {
        std.log.debug(
            "Failed to parse adjustment float '{s}': {}",
            .{ raw_str, err },
        );
        try list.addText(rect, .{
            .text = "Invalid float format. Enter a number.",
            .color = withAlpha(theme.red, progress),
            .font_size = 13,
            .font_id = 0,
        });
        return;
    };

    if (std.math.isNan(val) or std.math.isInf(val)) {
        try list.addText(rect, .{
            .text = "Invalid float format. Enter a number.",
            .color = withAlpha(theme.red, progress),
            .font_size = 13,
            .font_id = 0,
        });
        return;
    }

    const default_bounds = intents.TextInputBounds{ .min = 0.0, .max = 1.0 };
    const bounds = mode.getTextInputBounds() orelse default_bounds;
    if (val >= bounds.min and val <= bounds.max) {
        const success_str = try frame_allocator.print(
            "Press Enter to set value to: {d:.2}",
            .{val},
        );
        try list.addText(rect, .{
            .text = success_str,
            .color = withAlpha(theme.green, progress),
            .font_size = 13,
            .font_id = 0,
        });
    } else {
        const err_str = try frame_allocator.print(
            "Out of bounds: must be between {d:.1} and {d:.1}",
            .{ bounds.min, bounds.max },
        );
        try list.addText(rect, .{
            .text = err_str,
            .color = withAlpha(theme.red, progress),
            .font_size = 13,
            .font_id = 0,
        });
    }
}

fn renderTextInputDialog(
    list: *UiDrawList,
    rect: FRect,
    ui_model: UiViewModel,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    const palette = ui_model.palette;
    try list.addRect(rect, .{
        .background_color = withAlpha(theme.crust, progress),
        .corner_radius = .all(6),
    });

    const raw_str = palette.query.items;
    const total_count = ui_model.total_images;
    const content_x = rect.x + 12.0;
    const content_w = rect.w - 24.0;
    const line1_y = rect.y + 12.0;
    const line2_y = rect.y + 34.0;
    const center_y = rect.y + (rect.h - 16.0) * 0.5;

    switch (palette.mode) {
        .prompt => |kind| switch (kind) {
            .go_to_image => {
                if (total_count == 0) {
                    try list.addText(.{
                        .x = content_x,
                        .y = center_y,
                        .w = content_w,
                        .h = 16.0,
                    }, .{
                        .text = "No images loaded.",
                        .color = withAlpha(theme.red, progress),
                        .font_size = 13,
                        .font_id = 0,
                    });
                } else if (raw_str.len == 0) {
                    try list.addText(.{
                        .x = content_x,
                        .y = line1_y,
                        .w = content_w,
                        .h = 16.0,
                    }, .{
                        .text = "Enter image number, " ++
                            "then press Enter to apply.",
                        .color = withAlpha(theme.subtext0, progress),
                        .font_size = 13,
                        .font_id = 0,
                    });
                    const range_str = if (ui_model.current_index) |idx|
                        try frame_allocator.print(
                            "Allowed range: 1 to {} (current: {})",
                            .{ total_count, idx + 1 },
                        )
                    else
                        try frame_allocator.print(
                            "Allowed range: 1 to {} (current: none)",
                            .{total_count},
                        );
                    try list.addText(.{
                        .x = content_x,
                        .y = line2_y,
                        .w = content_w,
                        .h = 14.0,
                    }, .{
                        .text = range_str,
                        .color = withAlpha(theme.subtext1, progress),
                        .font_size = 11,
                        .font_id = 0,
                    });
                } else {
                    try renderGoToImageFeedback(
                        list,
                        .{
                            .x = content_x,
                            .y = center_y,
                            .w = content_w,
                            .h = 16.0,
                        },
                        raw_str,
                        total_count,
                        ui_model,
                        frame_allocator,
                        measure_data,
                        progress,
                    );
                }
            },
            .slideshow_interval => {
                if (raw_str.len == 0) {
                    try list.addText(.{
                        .x = content_x,
                        .y = line1_y,
                        .w = content_w,
                        .h = 16.0,
                    }, .{
                        .text = "Enter delay in seconds, " ++
                            "then press Enter to start.",
                        .color = withAlpha(theme.subtext0, progress),
                        .font_size = 13,
                        .font_id = 0,
                    });
                    try list.addText(.{
                        .x = content_x,
                        .y = line2_y,
                        .w = content_w,
                        .h = 14.0,
                    }, .{
                        .text = "Example: 3 for 3 seconds per slide",
                        .color = withAlpha(theme.subtext1, progress),
                        .font_size = 11,
                        .font_id = 0,
                    });
                } else {
                    try renderSlideshowIntervalFeedback(
                        list,
                        .{
                            .x = content_x,
                            .y = center_y,
                            .w = content_w,
                            .h = 16.0,
                        },
                        raw_str,
                        frame_allocator,
                        progress,
                    );
                }
            },
            .edit_param => |param| {
                if (raw_str.len == 0) {
                    try list.addText(.{
                        .x = content_x,
                        .y = line1_y,
                        .w = content_w,
                        .h = 16.0,
                    }, .{
                        .text = "Enter a number, then press Enter to apply.",
                        .color = withAlpha(theme.subtext0, progress),
                        .font_size = 13,
                        .font_id = 0,
                    });
                    const spec = intents.getSpec(param);
                    const range_str = try frame_allocator.print(
                        "Allowed range: {d:.1} to {d:.1}",
                        .{ spec.min, spec.max },
                    );
                    try list.addText(.{
                        .x = content_x,
                        .y = line2_y,
                        .w = content_w,
                        .h = 14.0,
                    }, .{
                        .text = range_str,
                        .color = withAlpha(theme.subtext1, progress),
                        .font_size = 11,
                        .font_id = 0,
                    });
                } else {
                    try renderFloatInputFeedback(
                        list,
                        .{
                            .x = content_x,
                            .y = center_y,
                            .w = content_w,
                            .h = 16.0,
                        },
                        raw_str,
                        palette.mode,
                        frame_allocator,
                        progress,
                    );
                }
            },
        },
        .files, .actions, .directory_navigator, .inactive => {},
    }
}

fn renderDirectoryScanBadges(
    list: *UiDrawList,
    right_edge: f32,
    badge_y: f32,
    entry: anytype,
    scan: anytype,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !f32 {
    var cur_right = right_edge;
    switch (scan) {
        .unscanned => {
            const dims = text_utils.measureText("...", 0, 11, measure_data);
            const bw = dims.w + 12.0;
            cur_right -= bw;
            _ = try renderBadge(
                list,
                cur_right,
                badge_y,
                "...",
                theme.subtext1,
                theme.surface0,
                progress,
                measure_data,
            );
        },
        .partial_counted => |p| {
            if (entry == .archive_file) {
                const count_str = try frame_allocator.print(
                    "{}+ pages",
                    .{p.image_count},
                );
                const dims =
                    text_utils.measureText(count_str, 0, 11, measure_data);
                const bw = dims.w + 12.0;
                cur_right -= bw;
                _ = try renderBadge(
                    list,
                    cur_right,
                    badge_y,
                    count_str,
                    theme.yellow,
                    theme.yellow,
                    progress,
                    measure_data,
                );
            } else {
                const sub_str = try frame_allocator.print(
                    "{}+ subfolders",
                    .{p.subdir_count},
                );
                const sub_dims =
                    text_utils.measureText(sub_str, 0, 11, measure_data);
                const sub_bw = sub_dims.w + 12.0;
                cur_right -= sub_bw;
                _ = try renderBadge(
                    list,
                    cur_right,
                    badge_y,
                    sub_str,
                    theme.yellow,
                    theme.yellow,
                    progress,
                    measure_data,
                );

                cur_right -= 6.0;
                const count_str = try frame_allocator.print(
                    "{}+ images",
                    .{p.image_count},
                );
                const cnt_dims =
                    text_utils.measureText(count_str, 0, 11, measure_data);
                const cnt_bw = cnt_dims.w + 12.0;
                cur_right -= cnt_bw;
                _ = try renderBadge(
                    list,
                    cur_right,
                    badge_y,
                    count_str,
                    theme.yellow,
                    theme.yellow,
                    progress,
                    measure_data,
                );
            }
        },
        .scanned, .cached => |s| {
            if (entry == .archive_file) {
                const s_suffix = if (s.image_count == 1) "" else "s";
                const count_str = try frame_allocator.print(
                    "{} page{s}",
                    .{ s.image_count, s_suffix },
                );
                const count_color =
                    if (s.image_count == 0) theme.subtext1 else theme.green;
                const border_color =
                    if (s.image_count == 0) theme.surface0 else theme.green;
                const dims =
                    text_utils.measureText(count_str, 0, 11, measure_data);
                const bw = dims.w + 12.0;
                cur_right -= bw;
                _ = try renderBadge(
                    list,
                    cur_right,
                    badge_y,
                    count_str,
                    count_color,
                    border_color,
                    progress,
                    measure_data,
                );
            } else {
                const sub_suffix = if (s.subdir_count == 1) "" else "s";
                const sub_str = try frame_allocator.print(
                    "{} subfolder{s}",
                    .{ s.subdir_count, sub_suffix },
                );
                const sub_color =
                    if (s.subdir_count == 0) theme.subtext1 else theme.blue;
                const sub_border =
                    if (s.subdir_count == 0) theme.surface0 else theme.blue;
                const sub_dims =
                    text_utils.measureText(sub_str, 0, 11, measure_data);
                const sub_bw = sub_dims.w + 12.0;
                cur_right -= sub_bw;
                _ = try renderBadge(
                    list,
                    cur_right,
                    badge_y,
                    sub_str,
                    sub_color,
                    sub_border,
                    progress,
                    measure_data,
                );

                cur_right -= 6.0;
                const img_suffix = if (s.image_count == 1) "" else "s";
                const count_str = try frame_allocator.print(
                    "{} image{s}",
                    .{ s.image_count, img_suffix },
                );
                const count_color =
                    if (s.image_count == 0) theme.subtext1 else theme.green;
                const count_border =
                    if (s.image_count == 0) theme.surface0 else theme.green;
                const cnt_dims =
                    text_utils.measureText(count_str, 0, 11, measure_data);
                const cnt_bw = cnt_dims.w + 12.0;
                cur_right -= cnt_bw;
                _ = try renderBadge(
                    list,
                    cur_right,
                    badge_y,
                    count_str,
                    count_color,
                    count_border,
                    progress,
                    measure_data,
                );
            }
        },
        .failed => {
            const dims = text_utils.measureText("Error", 0, 11, measure_data);
            const bw = dims.w + 12.0;
            cur_right -= bw;
            _ = try renderBadge(
                list,
                cur_right,
                badge_y,
                "Error",
                theme.red,
                theme.red,
                progress,
                measure_data,
            );
        },
        .permission_denied => {
            const dims = text_utils.measureText("Locked", 0, 11, measure_data);
            const bw = dims.w + 12.0;
            cur_right -= bw;
            _ = try renderBadge(
                list,
                cur_right,
                badge_y,
                "Locked",
                theme.red,
                theme.red,
                progress,
                measure_data,
            );
        },
    }
    return cur_right;
}

fn renderDirectoryListItem(
    list: *UiDrawList,
    rect: FRect,
    palette: *const PaletteState,
    real_idx: usize,
    is_selected: bool,
    frame_allocator: std.mem.Allocator,
    highlighter: *FuzzyHighlighter,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    if (real_idx >= palette.dir_items.items.len) return;
    const entry = palette.dir_items.items[real_idx];
    const query_str = palette.query.items;
    const dir_matches = highlighter.matchText(entry.getName(), query_str);

    const badge_center_y = rect.y + rect.h * 0.5;
    var right_limit = rect.x + rect.w - 12.0;

    if (entry.getScanState()) |scan| {
        right_limit = try renderDirectoryScanBadges(
            list,
            right_limit,
            badge_center_y,
            entry,
            scan,
            frame_allocator,
            measure_data,
            progress,
        );
        right_limit -= 8.0;
    }

    var cur_x = rect.x + 12.0;
    const badge_text, const badge_color = switch (entry) {
        .parent => .{ "UP", theme.subtext0 },
        .directory => .{ "DIR", theme.blue },
        .archive_file => |arch| switch (arch.archive_type) {
            .cbz => .{ "CBZ", theme.peach },
            .zip => .{ "ZIP", theme.peach },
        },
        .image_file => .{ "IMG", theme.green },
    };
    const badge_w = try renderBadge(
        list,
        cur_x,
        badge_center_y,
        badge_text,
        badge_color,
        badge_color,
        progress,
        measure_data,
    );
    cur_x += badge_w + 8.0;

    const available_text_w = @max(right_limit - cur_x, 10.0);
    const trunc_folder = truncateFilenameMiddle(
        frame_allocator,
        entry.getName(),
        available_text_w,
        13,
        measure_data,
    );
    const final_folder_matches = remapMiddleTruncatedMatches(
        frame_allocator,
        dir_matches,
        trunc_folder.head_len,
        trunc_folder.tail_start_idx,
    ) catch &.{};

    const text_color = if (is_selected)
        withAlpha(theme.blue, progress)
    else
        withAlpha(theme.text, progress);

    try renderFuzzyMatchText(
        list,
        frame_allocator,
        .{
            .x = cur_x,
            .y = rect.y + (rect.h - 16.0) * 0.5,
            .w = available_text_w,
            .h = 16.0,
        },
        trunc_folder.display,
        final_folder_matches,
        13,
        text_color,
        withAlpha(theme.yellow, progress),
    );
}

fn renderActionListItem(
    list: *UiDrawList,
    rect: FRect,
    palette: *const PaletteState,
    real_idx: usize,
    is_selected: bool,
    frame_allocator: std.mem.Allocator,
    highlighter: *FuzzyHighlighter,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    const meta = palette_action_items[real_idx];
    const query_str = palette.query.items;
    const action_matches = highlighter.matchText(meta.name, query_str);

    var right_limit = rect.x + rect.w - 12.0;
    if (meta.shortcut_text.len > 0) {
        const dims =
            text_utils.measureText(meta.shortcut_text, 0, 11, measure_data);
        const bw = dims.w + 16.0;
        right_limit -= bw;
        _ = try renderShortcutBadge(
            list,
            right_limit,
            rect.y + rect.h * 0.5,
            meta.shortcut_text,
            progress,
            measure_data,
        );
        right_limit -= 8.0;
    }

    const text_x = rect.x + 12.0;
    const text_w = @max(right_limit - text_x, 10.0);
    const text_color = if (is_selected)
        withAlpha(theme.blue, progress)
    else
        withAlpha(theme.text, progress);

    try renderFuzzyMatchText(
        list,
        frame_allocator,
        .{
            .x = text_x,
            .y = rect.y + (rect.h - 16.0) * 0.5,
            .w = text_w,
            .h = 16.0,
        },
        meta.name,
        action_matches,
        13,
        text_color,
        withAlpha(theme.yellow, progress),
    );
}

fn renderFileListItem(
    list: *UiDrawList,
    rect: FRect,
    ui_model: UiViewModel,
    palette: *const PaletteState,
    real_idx: usize,
    is_selected: bool,
    frame_allocator: std.mem.Allocator,
    highlighter: *FuzzyHighlighter,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    const media_opt = ui_model.getMediaEntry(real_idx);
    const basename = if (media_opt) |m| m.getBasename() else "";
    const dirname = if (media_opt) |m| m.getContainerName() else ".";
    const jpeg_path_opt = if (media_opt) |m| m.getJpegPath() else null;
    const is_pair = if (media_opt) |m| m.isPair() else false;
    const query_str = palette.query.items;

    var basename_matches = try highlighter.matchFileItem(
        frame_allocator,
        basename,
        jpeg_path_opt,
        is_pair,
        query_str,
    );
    defer basename_matches.deinit(frame_allocator);

    const classification = ui_model.getClassification(real_idx);
    var right_limit = rect.x + rect.w - 12.0;
    const badge_center_y = rect.y + rect.h * 0.5;

    switch (classification) {
        .pick => {
            const bw =
                text_utils.measureText("PICK", 0, 11, measure_data).w + 12.0;
            right_limit -= bw;
            _ = try renderClassificationBadge(
                list,
                right_limit,
                badge_center_y,
                "PICK",
                theme.green,
                progress,
                measure_data,
            );
            right_limit -= 6.0;
        },
        .reject => {
            const bw =
                text_utils.measureText("REJECT", 0, 11, measure_data).w + 12.0;
            right_limit -= bw;
            _ = try renderClassificationBadge(
                list,
                right_limit,
                badge_center_y,
                "REJECT",
                theme.red,
                progress,
                measure_data,
            );
            right_limit -= 6.0;
        },
        .unflagged => {},
    }

    if (is_pair) {
        const bw =
            text_utils.measureText("RAW+JPG", 0, 11, measure_data).w + 12.0;
        right_limit -= bw;
        _ = try renderBadge(
            list,
            right_limit,
            badge_center_y,
            "RAW+JPG",
            theme.mauve,
            theme.mauve,
            progress,
            measure_data,
        );
        right_limit -= 6.0;
    }

    // Left indicator bar
    const bar_color = if (is_selected)
        withAlpha(theme.blue, progress)
    else
        withAlpha(theme.subtext1, progress);
    try list.addRect(.{
        .x = rect.x + 12.0,
        .y = rect.y + 13.5,
        .w = 4.0,
        .h = 12.0,
    }, .{
        .background_color = bar_color,
        .corner_radius = .all(3),
    });

    const text_x = rect.x + 22.0;
    const text_w = @max(right_limit - text_x, 10.0);

    const trunc_filename = truncateFilenameMiddle(
        frame_allocator,
        basename,
        text_w,
        13,
        measure_data,
    );
    const final_basename_matches = remapMiddleTruncatedMatches(
        frame_allocator,
        basename_matches.items,
        trunc_filename.head_len,
        trunc_filename.tail_start_idx,
    ) catch &.{};

    const display_dir = truncateDirectory(
        frame_allocator,
        dirname,
        text_w,
        11,
        measure_data,
    );

    const text_color = if (is_selected)
        withAlpha(theme.blue, progress)
    else
        withAlpha(theme.text, progress);

    try renderFuzzyMatchText(
        list,
        frame_allocator,
        .{ .x = text_x, .y = rect.y + 11.5, .w = text_w, .h = 16.0 },
        trunc_filename.display,
        final_basename_matches,
        13,
        text_color,
        withAlpha(theme.yellow, progress),
    );

    try list.addText(.{
        .x = rect.x + 26.0,
        .y = rect.y + 29.5,
        .w = @max(right_limit - (rect.x + 26.0), 10.0),
        .h = 13.0,
    }, .{
        .text = display_dir,
        .color = withAlpha(theme.subtext0, progress),
        .font_size = 11,
        .font_id = 0,
    });
}

fn renderSelectionList(
    interaction: *state.InteractionState,
    list: *UiDrawList,
    list_rect: FRect,
    ui_model: UiViewModel,
    cfg: PaletteConfig,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    const palette = ui_model.palette;
    const matching_indices = &palette.matches;
    const item_stride = cfg.base_item_height;
    const actual_item_h: f32 = if (palette.mode == .files) 54.0 else 46.0;
    const viewport_height = list_rect.h;

    const current_scroll_y = interaction.palette_scroll_y;
    const resolved_scroll_y = cfg.resolveScrollOffsetY(
        current_scroll_y,
        matching_indices.items.len,
        palette.selected_idx,
        palette.selection_dirty,
    );
    interaction.palette_scroll_y = resolved_scroll_y;

    try list.pushScissor(list_rect);
    defer list.popScissor() catch {};

    if (matching_indices.items.len == 0) {
        const no_match_msg = switch (palette.mode) {
            .files => "No matching files found",
            .actions => "No matching commands found",
            .directory_navigator => if (palette.query.items.len > 0)
                "No matching subfolders found"
            else
                "0 subfolders found",
            .prompt, .inactive => "",
        };
        const msg_dims =
            text_utils.measureText(no_match_msg, 0, 13, measure_data);
        try list.addText(.{
            .x = list_rect.x + (list_rect.w - msg_dims.w) * 0.5,
            .y = list_rect.y + (list_rect.h - msg_dims.h) * 0.5,
            .w = msg_dims.w,
            .h = msg_dims.h,
        }, .{
            .text = no_match_msg,
            .color = withAlpha(theme.subtext1, progress),
            .font_size = 13,
            .font_id = 0,
        });
        return;
    }

    const window = VirtualWindow.compute(
        matching_indices.items.len,
        resolved_scroll_y,
        viewport_height,
        item_stride,
        4.0,
    );

    const visible_indices =
        matching_indices.items[window.start_idx..window.end_idx];
    var highlighter = palette.initWindowHighlighter(
        frame_allocator,
        ui_model.items.items(.entry),
        visible_indices,
    );
    defer highlighter.deinit();

    var match_count = window.start_idx;
    for (visible_indices) |real_idx| {
        const is_selected = (match_count == palette.selected_idx);
        const item_y = list_rect.y + resolved_scroll_y +
            @as(f32, @floatFromInt(match_count)) * item_stride;
        const item_rect = FRect{
            .x = list_rect.x,
            .y = item_y,
            .w = list_rect.w,
            .h = actual_item_h,
        };

        interaction.recordPaletteItem(item_rect, real_idx);

        const item_hovered = interaction.isHovered(item_rect);
        const bg_color: ?Color = if (is_selected and item_hovered)
            withAlpha(theme.row_selected_hover, progress)
        else if (is_selected)
            withAlpha(theme.row_selected, progress)
        else if (item_hovered)
            withAlpha(theme.row_hover, progress)
        else
            null;

        if (bg_color) |bg| {
            try list.addRect(item_rect, .{
                .background_color = bg,
                .corner_radius = .all(6),
            });
        }

        switch (palette.mode) {
            .files => try renderFileListItem(
                list,
                item_rect,
                ui_model,
                palette,
                real_idx,
                is_selected,
                frame_allocator,
                &highlighter,
                measure_data,
                progress,
            ),
            .actions => try renderActionListItem(
                list,
                item_rect,
                palette,
                real_idx,
                is_selected,
                frame_allocator,
                &highlighter,
                measure_data,
                progress,
            ),
            .directory_navigator => try renderDirectoryListItem(
                list,
                item_rect,
                palette,
                real_idx,
                is_selected,
                frame_allocator,
                &highlighter,
                measure_data,
                progress,
            ),
            .prompt, .inactive => {},
        }

        match_count += 1;
    }
}

fn renderDirectoryLegend(
    list: *UiDrawList,
    rect: FRect,
    progress: f32,
    measure_data: *const MeasureTextUserData,
) !void {
    const LegendItem = struct { key: []const u8, label: []const u8 };
    const legend_items = [_]LegendItem{
        .{ .key = "Right", .label = "Open" },
        .{ .key = "Enter", .label = "Load Selected" },
        .{ .key = "Shift+Enter", .label = "Load Current" },
        .{ .key = "Left", .label = "Up" },
        .{ .key = "Esc", .label = "Close" },
    };

    var total_w: f32 = 0.0;
    var item_widths: [legend_items.len]f32 = undefined;
    var key_widths: [legend_items.len]f32 = undefined;
    var label_widths: [legend_items.len]f32 = undefined;

    for (legend_items, 0..) |item, i| {
        key_widths[i] =
            text_utils.measureText(item.key, 0, 10, measure_data).w;
        label_widths[i] =
            text_utils.measureText(item.label, 0, 11, measure_data).w;
        const key_badge_w = key_widths[i] + 8.0;
        item_widths[i] = 5.0 + key_badge_w + 5.0 + label_widths[i] + 7.0;
        total_w += item_widths[i];
        if (i + 1 < legend_items.len) total_w += 6.0;
    }

    var cur_x = rect.x + (rect.w - total_w) * 0.5;
    const pill_h: f32 = 20.0;
    const pill_y = rect.y + (rect.h - pill_h) * 0.5;

    for (legend_items, 0..) |item, i| {
        const item_w = item_widths[i];
        const pill_rect =
            FRect{ .x = cur_x, .y = pill_y, .w = item_w, .h = pill_h };
        try list.addRect(pill_rect, .{
            .background_color = withAlpha(theme.crust, progress),
            .corner_radius = .all(4),
        });
        try list.addBorder(pill_rect, .{
            .color = withAlpha(theme.surface0, progress),
            .width = .all(1),
            .corner_radius = .all(4),
        });

        const key_w = key_widths[i];
        const key_badge_w = key_w + 8.0;
        const key_badge_h: f32 = 14.0;
        const key_badge_rect = FRect{
            .x = cur_x + 5.0,
            .y = pill_y + (pill_h - key_badge_h) * 0.5,
            .w = key_badge_w,
            .h = key_badge_h,
        };
        try list.addRect(key_badge_rect, .{
            .background_color = withAlpha(theme.surface0, progress),
            .corner_radius = .all(3),
        });
        try list.addText(.{
            .x = key_badge_rect.x + 4.0,
            .y = key_badge_rect.y + 1.0,
            .w = key_w,
            .h = 12.0,
        }, .{
            .text = item.key,
            .color = withAlpha(theme.mauve, progress),
            .font_size = 10,
            .font_id = 0,
        });

        const label_x = key_badge_rect.x + key_badge_w + 5.0;
        try list.addText(.{
            .x = label_x,
            .y = pill_y + 3.0,
            .w = label_widths[i],
            .h = 14.0,
        }, .{
            .text = item.label,
            .color = withAlpha(theme.subtext0, progress),
            .font_size = 11,
            .font_id = 0,
        });

        cur_x += item_w + 6.0;
    }
}

/// Renders the complete Command Palette floating modal overlay (search input
/// box, header title, match counter, and virtualized scrollable result list)
/// corresponding to the active palette mode.
pub fn renderPalette(
    interaction: *state.InteractionState,
    list: *UiDrawList,
    ui_model: UiViewModel,
    win_dims: LogicalDims,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const palette = ui_model.palette;
    if (palette.mode == .inactive and !palette.is_closing) return;
    const progress = std.math.clamp(ui_model.anim(.palette_reveal), 0.0, 1.0);
    if (progress <= 0.001) return;

    const cfg = getPaletteConfig(palette.mode);

    const pad_y: f32 = 24.0;
    const header_h: f32 = 16.0;
    const breadcrumb_h: f32 =
        if (palette.mode == .directory_navigator) 26.0 else 0.0;
    const breadcrumb_gap: f32 =
        if (palette.mode == .directory_navigator) 10.0 else 0.0;
    const search_h: f32 = 38.0;
    const content_h: f32 = if (palette.mode.isTextInputDialog())
        64.0
    else
        cfg.viewport_height_logical;
    const legend_h: f32 =
        if (palette.mode == .directory_navigator) 26.0 else 0.0;
    const legend_gap: f32 =
        if (palette.mode == .directory_navigator) 10.0 else 0.0;
    const gaps: f32 = 20.0 + breadcrumb_gap + legend_gap;
    const modal_h: f32 = pad_y + header_h + breadcrumb_h + search_h +
        content_h + legend_h + gaps;

    const modal_w: f32 = 550.0;
    const modal_x: f32 = (win_dims.w - modal_w) * 0.5;
    const modal_y: f32 =
        (win_dims.h - modal_h) * 0.5 + (1.0 - progress) * -18.0;
    const modal_rect =
        FRect{ .x = modal_x, .y = modal_y, .w = modal_w, .h = modal_h };

    interaction.setPaletteModalRect(modal_rect, !palette.is_closing);

    try list.addRect(modal_rect, .{
        .background_color = theme.withAlpha(theme.base_translucent, progress),
        .corner_radius = .all(10),
        .tag = if (ui_model.overlays.enable_blur) .blurred_surface else .none,
    });
    try list.addBorder(modal_rect, .{
        .color = theme.withAlpha(theme.overlay0, progress),
        .width = .all(1),
        .corner_radius = .all(10),
    });

    var cur_y = modal_rect.y + 12.0;
    const content_x = modal_rect.x + 12.0;
    const content_w = modal_rect.w - 24.0;

    try renderHeader(
        list,
        .{ .x = content_x, .y = cur_y, .w = content_w, .h = header_h },
        palette.mode,
        cfg.title,
        progress,
    );
    cur_y += header_h + 10.0;

    if (palette.mode == .directory_navigator) {
        try renderDirectoryBreadcrumbs(
            list,
            .{ .x = content_x, .y = cur_y, .w = content_w, .h = breadcrumb_h },
            palette,
            frame_allocator,
            measure_data,
            progress,
        );
        cur_y += breadcrumb_h + 10.0;
    }

    try renderSearchInput(
        list,
        .{ .x = content_x, .y = cur_y, .w = content_w, .h = search_h },
        palette,
        cfg.placeholder,
        measure_data,
        progress,
    );
    cur_y += search_h + 10.0;

    const list_rect =
        FRect{ .x = content_x, .y = cur_y, .w = content_w, .h = content_h };
    if (palette.mode.isTextInputDialog()) {
        try renderTextInputDialog(
            list,
            list_rect,
            ui_model,
            frame_allocator,
            measure_data,
            progress,
        );
    } else {
        try renderSelectionList(
            interaction,
            list,
            list_rect,
            ui_model,
            cfg,
            frame_allocator,
            measure_data,
            progress,
        );
    }
    cur_y += content_h;

    if (palette.mode == .directory_navigator) {
        cur_y += 10.0;
        try renderDirectoryLegend(
            list,
            .{ .x = content_x, .y = cur_y, .w = content_w, .h = legend_h },
            progress,
            measure_data,
        );
    }
}

test "renderPalette - closing palette passes pointer through to parent" {
    var interaction_inst: state.InteractionState = .{};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var data = MeasureTextUserData{};
    var pal_state = try PaletteState.init(std.testing.allocator);
    defer pal_state.deinit();
    pal_state.mode = .actions;
    pal_state.is_closing = false;

    const model = UiViewModel{
        .is_fullscreen = false,
        .total_images = 0,
        .current_index = null,
        .current_image_entry = null,
        .current_entry = null,
        .current_classification = .unflagged,
        .view_mode = .default,
        .visible_state = .empty_directory,
        .visible_count = 0,
        .visible_position = null,
        .is_loading_files = false,
        .slideshow = .inactive,
        .manga_mode = false,
        .overlays = .{},
        .window_title = "test",
        .viewport = .{},
        .palette = &pal_state,
        .snackbar = .none,
        .anim_values = @splat(0.5),
        .debug_show_thumb = false,
        .is_thumb_crossfading = false,
        .image_dissolve = .none,
        .current_time_ms = 100,
    };

    const win_dims = LogicalDims{ .w = 1000.0, .h = 800.0 };

    // 1. Open palette captures pointer over center -> viewport is not hit
    {
        interaction_inst.beginFrameLayout();
        interaction_inst.viewport =
            .{ .x = 0.0, .y = 0.0, .w = 1000.0, .h = 800.0 };
        var draw_list = UiDrawList{ .allocator = arena.allocator() };
        try renderPalette(
            &interaction_inst,
            &draw_list,
            model,
            win_dims,
            arena.allocator(),
            &data,
        );

        interaction_inst.setPointerStateForTest(.{ .x = 500.0, .y = 350.0 });
        try std.testing.expect(!interaction_inst.isPointerOverViewport());
    }

    // 2. Closing palette passes pointer through -> viewport is hit
    {
        pal_state.is_closing = true;
        interaction_inst.beginFrameLayout();
        interaction_inst.viewport =
            .{ .x = 0.0, .y = 0.0, .w = 1000.0, .h = 800.0 };
        var draw_list = UiDrawList{ .allocator = arena.allocator() };
        try renderPalette(
            &interaction_inst,
            &draw_list,
            model,
            win_dims,
            arena.allocator(),
            &data,
        );

        interaction_inst.setPointerStateForTest(.{ .x = 500.0, .y = 350.0 });
        try std.testing.expect(interaction_inst.isPointerOverViewport());
    }
}
