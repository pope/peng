const clay = @import("zclay");
const graphics = @import("graphics.zig");
const intents = @import("intents");
const palette_pkg = @import("palette");
const sdl = @import("sdl");
const state = @import("state");
const std = @import("std");
const text_utils = @import("text_utils.zig");
const theme = @import("theme.zig");

const ElementTag = types.ElementTag;
const FuzzyHighlighter = palette_pkg.FuzzyHighlighter;
const getPaletteConfig = palette_pkg.getPaletteConfig;
const MeasureTextUserData = graphics.MeasureTextUserData;
const PaletteConfig = palette_pkg.PaletteConfig;
const PaletteMode = intents.PaletteMode;
const PaletteState = palette_pkg.PaletteState;
const partitionHighlightedText = palette_pkg.partitionHighlightedText;
const remapMiddleTruncatedMatches = palette_pkg.remapMiddleTruncatedMatches;
const truncateDirectory = text_utils.truncateDirectory;
const truncateFilename = text_utils.truncateFilename;
const truncateFilenameMiddle = text_utils.truncateFilenameMiddle;
const types = state.types;
const UiViewModel = state.UiViewModel;
const VirtualWindow = palette_pkg.VirtualWindow;

/// Scales the alpha of a theme color by the modal animation progress (0.0 .. 1.0).
inline fn a(color: clay.Color, progress: f32) clay.Color {
    return theme.withAlpha(color, progress);
}

/// Emits Clay text elements partitioning characters into alternating normal
/// and highlighted segments based on fuzzy match indices.
fn renderFuzzyMatchText(
    allocator: std.mem.Allocator,
    text: []const u8,
    match_indices: []const usize,
    font_size: u16,
    normal_color: clay.Color,
    highlight_color: clay.Color,
) void {
    if (text.len == 0) return;
    if (match_indices.len == 0) {
        clay.text(text, .{
            .color = normal_color,
            .font_size = font_size,
            .font_id = 0,
            .wrap_mode = .none,
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
        clay.text(text, .{
            .color = normal_color,
            .font_size = font_size,
            .font_id = 0,
            .wrap_mode = .none,
        });
        return;
    };
    defer allocator.free(chunks);

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        for (chunks) |chunk| {
            const chunk_color =
                if (chunk.is_matched) highlight_color else normal_color;
            clay.text(chunk.slice, .{
                .color = chunk_color,
                .font_size = font_size,
                .font_id = 0,
                .wrap_mode = .none,
            });
        }
    });
}

fn renderHeader(mode: PaletteMode, title: []const u8, progress: f32) void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(title, .{
            .color = a(switch (mode) {
                .files => theme.pink,
                .actions => theme.blue,
                .set_brightness,
                .set_contrast,
                .set_contrast_blend,
                .set_highlights,
                .set_shadows,
                .set_whites,
                .set_blacks,
                .set_temperature,
                .set_tint,
                .set_vibrance,
                .set_saturation,
                .set_clarity,
                .set_texture,
                => theme.peach,
                .go_to_image => theme.green,
                .directory_navigator => theme.mauve,
                .set_slideshow_interval => theme.yellow,
                .inactive => theme.text,
            }, progress),
            .font_size = 13,
            .font_id = 0,
        });
    });
}

fn renderBadge(
    text: []const u8,
    text_color: clay.Color,
    border_color: clay.Color,
    progress: f32,
) void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
        },
        .background_color = a(theme.crust, progress),
        .corner_radius = .all(4),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = a(border_color, progress),
        },
    })({
        clay.text(text, .{
            .color = a(text_color, progress),
            .font_size = 11,
            .font_id = 0,
        });
    });
}

fn renderDirectoryBreadcrumbs(
    palette: *const PaletteState,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    const display_dir = truncateDirectory(
        frame_allocator,
        palette.current_nav_dir.items,
        320.0,
        12,
        measure_data,
    );
    const curr_img_count = palette.current_dir_image_count;
    const s_suffix = if (curr_img_count == 1) "" else "s";
    const count_str = try frame_allocator.print(
        "{} image{s}",
        .{ curr_img_count, s_suffix },
    );
    const count_color = if (curr_img_count == 0) theme.subtext1 else theme.green;

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .padding = .{ .top = 4, .bottom = 4, .left = 8, .right = 8 },
            .child_gap = 8,
        },
        .background_color = a(theme.crust, progress),
        .corner_radius = .all(6),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = a(theme.surface0, progress),
        },
    })({
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 8,
            },
        })({
            renderBadge("DIR", theme.mauve, theme.mauve, progress);

            clay.text(display_dir, .{
                .color = a(theme.mauve, progress),
                .font_size = 12,
                .font_id = 0,
            });
        });

        const border_color = if (curr_img_count == 0) theme.surface0 else theme.green;
        renderBadge(count_str, count_color, border_color, progress);
    });
}

fn renderSearchInput(palette: *const PaletteState, placeholder: []const u8, progress: f32) void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(38) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .padding = .{ .left = 12, .right = 12 },
        },
        .background_color = a(theme.crust, progress),
        .corner_radius = .all(6),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = a(theme.blue, progress),
        },
    })({
        const query_str = if (palette.query.items.len > 0) palette.query.items else placeholder;
        const query_color = if (palette.query.items.len > 0) theme.text else theme.subtext1;
        clay.text(query_str, .{
            .color = a(query_color, progress),
            .font_size = 14,
            .font_id = 0,
        });
    });
}

fn renderGoToImageFeedback(
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
        clay.text("Invalid number format. Enter a positive integer.", .{
            .color = a(theme.red, progress),
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
        clay.text(err_str, .{
            .color = a(theme.red, progress),
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
        492.0,
        12,
        measure_data,
    );
    const success_str = try frame_allocator.print(
        "Press Enter to go to {}: {s}",
        .{ val, display_filename },
    );
    clay.text(success_str, .{
        .color = a(theme.green, progress),
        .font_size = 13,
        .font_id = 0,
    });
}

fn renderSlideshowIntervalFeedback(
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
            clay.text(success_str, .{
                .color = a(theme.green, progress),
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
        clay.text("Invalid duration. Must be greater than 0 seconds.", .{
            .color = a(theme.red, progress),
            .font_size = 13,
            .font_id = 0,
        });
    }
}

fn renderFloatInputFeedback(
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
        clay.text("Invalid float format. Enter a number.", .{
            .color = a(theme.red, progress),
            .font_size = 13,
            .font_id = 0,
        });
        return;
    };

    if (std.math.isNan(val) or std.math.isInf(val)) {
        clay.text("Invalid float format. Enter a number.", .{
            .color = a(theme.red, progress),
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
        clay.text(success_str, .{
            .color = a(theme.green, progress),
            .font_size = 13,
            .font_id = 0,
        });
    } else {
        const err_str = try frame_allocator.print(
            "Out of bounds: must be between {d:.1} and {d:.1}",
            .{ bounds.min, bounds.max },
        );
        clay.text(err_str, .{
            .color = a(theme.red, progress),
            .font_size = 13,
            .font_id = 0,
        });
    }
}

/// Renders the centered single-line modal dialog used for scalar numeric and text inputs
/// (brightness, contrast, jump-to-image index, and slideshow timer intervals).
fn renderTextInputDialog(
    ui_model: UiViewModel,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    const palette = ui_model.palette;
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(64) },
            .direction = .top_to_bottom,
            .child_alignment = .{ .x = .left, .y = .center },
            .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 },
            .child_gap = 6,
        },
        .background_color = a(theme.crust, progress),
        .corner_radius = .all(6),
    })({
        const raw_str = palette.query.items;
        const total_count = ui_model.total_images;
        switch (palette.mode) {
            .go_to_image => {
                if (total_count == 0) {
                    clay.text("No images loaded.", .{
                        .color = a(theme.red, progress),
                        .font_size = 13,
                        .font_id = 0,
                    });
                } else if (raw_str.len == 0) {
                    clay.text("Enter image number, then press Enter to apply.", .{
                        .color = a(theme.subtext0, progress),
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
                    clay.text(range_str, .{
                        .color = a(theme.subtext1, progress),
                        .font_size = 11,
                        .font_id = 0,
                    });
                } else {
                    try renderGoToImageFeedback(
                        raw_str,
                        total_count,
                        ui_model,
                        frame_allocator,
                        measure_data,
                        progress,
                    );
                }
            },
            .set_slideshow_interval => {
                if (raw_str.len == 0) {
                    clay.text("Enter delay in seconds, then press Enter to start.", .{
                        .color = a(theme.subtext0, progress),
                        .font_size = 13,
                        .font_id = 0,
                    });
                    clay.text("Example: 3 for 3 seconds per slide", .{
                        .color = a(theme.subtext1, progress),
                        .font_size = 11,
                        .font_id = 0,
                    });
                } else {
                    try renderSlideshowIntervalFeedback(
                        raw_str,
                        frame_allocator,
                        progress,
                    );
                }
            },
            .set_brightness,
            .set_contrast,
            .set_contrast_blend,
            .set_highlights,
            .set_shadows,
            .set_whites,
            .set_blacks,
            .set_temperature,
            .set_tint,
            .set_vibrance,
            .set_saturation,
            .set_clarity,
            .set_texture,
            => {
                if (raw_str.len == 0) {
                    clay.text("Enter a number, then press Enter to apply.", .{
                        .color = a(theme.subtext0, progress),
                        .font_size = 13,
                        .font_id = 0,
                    });
                    const bounds = palette.mode.getTextInputBounds() orelse
                        intents.TextInputBounds{
                            .min = -1.0,
                            .max = 1.0,
                        };
                    const range_str = try frame_allocator.print(
                        "Allowed range: {d:.1} to {d:.1}",
                        .{ bounds.min, bounds.max },
                    );
                    clay.text(range_str, .{
                        .color = a(theme.subtext1, progress),
                        .font_size = 11,
                        .font_id = 0,
                    });
                } else {
                    try renderFloatInputFeedback(
                        raw_str,
                        palette.mode,
                        frame_allocator,
                        progress,
                    );
                }
            },
            .files, .actions, .directory_navigator, .inactive => {},
        }
    });
}

/// Strategy and calculation for virtualized list windowing in Clay
/// immediate mode UI.
///
/// Immediate Mode Virtualization Strategy:
/// 1. Window Calculation:
///    Computes the visible item slice `[start_idx..end_idx]` based on
///    current scroll position (`scroll_offset.y`), viewport height, and
///    fixed item stride (`item_height`).
/// 2. Overscan Guard Band:
///    Adds a 1-item overscan buffer above and below the visible viewport
///    slice (`start_idx - 1` and `end_idx + 1`). Because Clay layout tree
///    generation and GPU rendering occur synchronously in the exact same
///    frame pass, `@floor` and `@ceil` math captures all visible elements.
///    The 1-item overscan serves as a guard band for sub-pixel `child_gap`
///    offsets, border widths, and viewport edge hit-testing
///    (`clay.pointerOver`).
fn renderDirectoryScanBadges(
    entry: anytype,
    scan: anytype,
    frame_allocator: std.mem.Allocator,
    progress: f32,
) !void {
    switch (scan) {
        .unscanned => {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .direction = .left_to_right,
                    .child_gap = 6,
                },
            })({
                renderBadge("...", theme.subtext1, theme.surface0, progress);
            });
        },
        .partial_counted => |p| {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .direction = .left_to_right,
                    .child_gap = 6,
                },
            })({
                if (entry == .archive_file) {
                    const count_str = try frame_allocator.print(
                        "{}+ pages",
                        .{p.image_count},
                    );
                    renderBadge(
                        count_str,
                        theme.yellow,
                        theme.yellow,
                        progress,
                    );
                } else {
                    const count_str = try frame_allocator.print(
                        "{}+ images",
                        .{p.image_count},
                    );
                    const sub_str = try frame_allocator.print(
                        "{}+ subfolders",
                        .{p.subdir_count},
                    );
                    renderBadge(
                        count_str,
                        theme.yellow,
                        theme.yellow,
                        progress,
                    );
                    renderBadge(
                        sub_str,
                        theme.yellow,
                        theme.yellow,
                        progress,
                    );
                }
            });
        },
        .scanned, .cached => |s| {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .direction = .left_to_right,
                    .child_gap = 6,
                },
            })({
                if (entry == .archive_file) {
                    const s_suffix = if (s.image_count == 1) "" else "s";
                    const count_str = try frame_allocator.print(
                        "{} page{s}",
                        .{ s.image_count, s_suffix },
                    );
                    const count_color = if (s.image_count == 0)
                        theme.subtext1
                    else
                        theme.green;
                    const border_color = if (s.image_count == 0)
                        theme.surface0
                    else
                        theme.green;
                    renderBadge(
                        count_str,
                        count_color,
                        border_color,
                        progress,
                    );
                } else {
                    const img_suffix = if (s.image_count == 1) "" else "s";
                    const count_str = try frame_allocator.print(
                        "{} image{s}",
                        .{ s.image_count, img_suffix },
                    );
                    const count_color = if (s.image_count == 0)
                        theme.subtext1
                    else
                        theme.green;
                    const count_border = if (s.image_count == 0)
                        theme.surface0
                    else
                        theme.green;

                    const sub_suffix = if (s.subdir_count == 1) "" else "s";
                    const sub_str = try frame_allocator.print(
                        "{} subfolder{s}",
                        .{ s.subdir_count, sub_suffix },
                    );
                    const sub_color = if (s.subdir_count == 0)
                        theme.subtext1
                    else
                        theme.blue;
                    const sub_border = if (s.subdir_count == 0)
                        theme.surface0
                    else
                        theme.blue;

                    renderBadge(
                        count_str,
                        count_color,
                        count_border,
                        progress,
                    );
                    renderBadge(
                        sub_str,
                        sub_color,
                        sub_border,
                        progress,
                    );
                }
            });
        },
        .failed => {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .direction = .left_to_right,
                    .child_gap = 6,
                },
            })({
                renderBadge("Error", theme.red, theme.red, progress);
            });
        },
        .permission_denied => {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .direction = .left_to_right,
                    .child_gap = 6,
                },
            })({
                renderBadge("Locked", theme.red, theme.red, progress);
            });
        },
    }
}

fn renderDirectoryListItem(
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

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 8,
        },
    })({
        const badge_text, const badge_color = switch (entry) {
            .parent => .{ "UP", theme.subtext0 },
            .directory => .{ "DIR", theme.blue },
            .archive_file => |arch| switch (arch.archive_type) {
                .cbz => .{ "CBZ", theme.peach },
                .zip => .{ "ZIP", theme.peach },
            },
            .image_file => .{ "IMG", theme.green },
        };
        renderBadge(badge_text, badge_color, badge_color, progress);

        const trunc_folder = truncateFilenameMiddle(
            frame_allocator,
            entry.getName(),
            350.0,
            13,
            measure_data,
        );
        const display_foldername = trunc_folder.display;
        const final_folder_matches = remapMiddleTruncatedMatches(
            frame_allocator,
            dir_matches,
            trunc_folder.head_len,
            trunc_folder.tail_start_idx,
        ) catch &.{};

        const text_color = if (is_selected)
            a(theme.blue, progress)
        else
            a(theme.text, progress);
        renderFuzzyMatchText(
            frame_allocator,
            display_foldername,
            final_folder_matches,
            13,
            text_color,
            a(theme.yellow, progress),
        );
    });

    if (entry.getScanState()) |scan| {
        try renderDirectoryScanBadges(entry, scan, frame_allocator, progress);
    }
}

fn renderActionListItem(
    palette: *const PaletteState,
    real_idx: usize,
    is_selected: bool,
    frame_allocator: std.mem.Allocator,
    highlighter: *FuzzyHighlighter,
    progress: f32,
) !void {
    const meta = types.palette_action_items[real_idx];
    const query_str = palette.query.items;

    const action_matches = highlighter.matchText(meta.name, query_str);

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        const text_color = if (is_selected)
            a(theme.blue, progress)
        else
            a(theme.text, progress);
        renderFuzzyMatchText(
            frame_allocator,
            meta.name,
            action_matches,
            13,
            text_color,
            a(theme.yellow, progress),
        );
    });

    if (meta.shortcut_text.len > 0) {
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
            },
            .background_color = a(theme.crust, progress),
            .corner_radius = .all(4),
            .border = .{
                .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                .color = a(theme.surface0, progress),
            },
        })({
            clay.text(meta.shortcut_text, .{
                .color = a(theme.subtext0, progress),
                .font_size = 11,
                .font_id = 0,
            });
        });
    }
}

fn renderClassificationBadge(
    label: []const u8,
    color: clay.Color,
    progress: f32,
) void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .{
                .left = 6,
                .right = 6,
                .top = 2,
                .bottom = 2,
            },
        },
        .background_color = theme.withAlpha(color, 0.25 * progress),
        .border = .{
            .color = a(color, progress),
            .width = .{
                .left = 1,
                .right = 1,
                .top = 1,
                .bottom = 1,
            },
        },
        .corner_radius = .all(4),
    })({
        clay.text(label, .{
            .color = a(color, progress),
            .font_size = 11,
            .font_id = 0,
        });
    });
}

fn renderFileListItem(
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
    var max_fn_w: f32 = 492.0;
    var max_dir_w: f32 = 488.0;
    if (classification != .unflagged) {
        max_fn_w -= 64.0;
        max_dir_w -= 64.0;
    }
    if (is_pair) {
        max_fn_w -= 72.0;
        max_dir_w -= 72.0;
    }

    const trunc_filename = truncateFilenameMiddle(
        frame_allocator,
        basename,
        max_fn_w,
        13,
        measure_data,
    );
    const display_filename = trunc_filename.display;
    const final_basename_matches = remapMiddleTruncatedMatches(
        frame_allocator,
        basename_matches.items,
        trunc_filename.head_len,
        trunc_filename.tail_start_idx,
    ) catch &.{};

    const display_dir = truncateDirectory(
        frame_allocator,
        dirname,
        max_dir_w,
        11,
        measure_data,
    );

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fit },
            .direction = .top_to_bottom,
            .child_gap = 2,
        },
    })({
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 6,
            },
        })({
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(4), .h = .fixed(12) },
                },
                .background_color = if (is_selected)
                    a(theme.blue, progress)
                else
                    a(theme.subtext1, progress),
                .corner_radius = .all(3),
            })({});

            const text_color = if (is_selected)
                a(theme.blue, progress)
            else
                a(theme.text, progress);
            renderFuzzyMatchText(
                frame_allocator,
                display_filename,
                final_basename_matches,
                13,
                text_color,
                a(theme.yellow, progress),
            );
        });

        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .direction = .left_to_right,
                .padding = .{ .left = 14 },
            },
        })({
            clay.text(display_dir, .{
                .color = a(theme.subtext0, progress),
                .font_size = 11,
                .font_id = 0,
                .wrap_mode = .none,
            });
        });
    });

    if (is_pair or classification != .unflagged) {
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .right, .y = .center },
                .child_gap = 6,
            },
        })({
            if (is_pair) {
                renderBadge("RAW+JPG", theme.mauve, theme.mauve, progress);
            }
            switch (classification) {
                .pick => renderClassificationBadge(
                    "PICK",
                    theme.green,
                    progress,
                ),
                .reject => renderClassificationBadge(
                    "REJECT",
                    theme.red,
                    progress,
                ),
                .unflagged => {},
            }
        });
    }
}

fn renderSelectionList(
    ui_model: UiViewModel,
    cfg: PaletteConfig,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
    progress: f32,
) !void {
    const palette = ui_model.palette;
    const matching_indices = &palette.matches;
    const list_id = clay.getElementId(cfg.list_id);
    const scroll_data = clay.cdefs.Clay_GetScrollContainerData(list_id);
    const item_height = cfg.base_item_height;
    const viewport_height = cfg.viewport_height_logical;

    const current_scroll_y = if (scroll_data.found)
        scroll_data.scroll_position.y
    else
        0.0;
    const resolved_scroll_y = cfg.resolveScrollOffsetY(
        current_scroll_y,
        matching_indices.items.len,
        palette.selected_idx,
        palette.selection_dirty,
    );
    if (scroll_data.found) {
        scroll_data.scroll_position.y = resolved_scroll_y;
    }
    const scroll_offset = clay.Vector2{
        .x = if (scroll_data.found) scroll_data.scroll_position.x else 0.0,
        .y = resolved_scroll_y,
    };

    const window = VirtualWindow.compute(
        matching_indices.items.len,
        scroll_offset.y,
        viewport_height,
        item_height,
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

    clay.UI()(.{
        .id = clay.getElementId(cfg.list_id),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(viewport_height) },
            .direction = .top_to_bottom,
            .child_gap = 4,
        },
        .clip = .{
            .horizontal = false,
            .vertical = true,
            .child_offset = scroll_offset,
        },
    })({
        if (window.top_spacer_h > 0) {
            clay.UI()(.{
                .id = clay.getElementId(cfg.top_spacer_id),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(window.top_spacer_h) } },
            })({});
        }

        var match_count = window.start_idx;
        for (visible_indices) |real_idx| {
            const is_selected = (match_count == palette.selected_idx);

            var item_id_buf: [64]u8 = undefined;
            const item_id_str = std.mem.print(
                &item_id_buf,
                "{s}{}",
                .{ cfg.item_prefix, real_idx },
            ) catch cfg.item_prefix;
            const item_id = clay.getElementId(item_id_str);
            const item_hovered = clay.pointerOver(item_id);

            clay.UI()(.{
                .id = item_id,
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(switch (palette.mode) {
                        .files => 54.0,
                        .actions, .directory_navigator => 46.0,
                        .set_brightness,
                        .set_contrast,
                        .set_contrast_blend,
                        .set_highlights,
                        .set_shadows,
                        .set_whites,
                        .set_blacks,
                        .set_temperature,
                        .set_tint,
                        .set_vibrance,
                        .set_saturation,
                        .set_clarity,
                        .set_texture,
                        .go_to_image,
                        .set_slideshow_interval,
                        .inactive,
                        => 0.0,
                    }) },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{ .left = 12, .right = 12 },
                    .child_gap = switch (palette.mode) {
                        .files => 8,
                        .actions,
                        .directory_navigator,
                        .set_brightness,
                        .set_contrast,
                        .set_contrast_blend,
                        .set_highlights,
                        .set_shadows,
                        .set_whites,
                        .set_blacks,
                        .set_temperature,
                        .set_tint,
                        .set_vibrance,
                        .set_saturation,
                        .set_clarity,
                        .set_texture,
                        .go_to_image,
                        .set_slideshow_interval,
                        .inactive,
                        => 0,
                    },
                },
                .background_color = if (is_selected and item_hovered)
                    a(theme.row_selected_hover, progress)
                else if (is_selected)
                    a(theme.row_selected, progress)
                else if (item_hovered)
                    a(theme.row_hover, progress)
                else
                    clay.Color{ 0, 0, 0, 0 },
                .corner_radius = .all(6),
            })({
                switch (palette.mode) {
                    .files => try renderFileListItem(
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
                        palette,
                        real_idx,
                        is_selected,
                        frame_allocator,
                        &highlighter,
                        progress,
                    ),
                    .directory_navigator => try renderDirectoryListItem(
                        palette,
                        real_idx,
                        is_selected,
                        frame_allocator,
                        &highlighter,
                        measure_data,
                        progress,
                    ),
                    .set_brightness,
                    .set_contrast,
                    .set_contrast_blend,
                    .set_highlights,
                    .set_shadows,
                    .set_whites,
                    .set_blacks,
                    .set_temperature,
                    .set_tint,
                    .set_vibrance,
                    .set_saturation,
                    .set_clarity,
                    .set_texture,
                    .go_to_image,
                    .set_slideshow_interval,
                    .inactive,
                    => {},
                }
            });

            match_count += 1;
        }

        if (window.bottom_spacer_h > 0) {
            clay.UI()(.{
                .id = clay.getElementId(cfg.bottom_spacer_id),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(window.bottom_spacer_h) } },
            })({});
        }

        if (matching_indices.items.len == 0) {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(36) },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            })({
                const no_match_msg = switch (palette.mode) {
                    .files => "No matching files found",
                    .actions => "No matching commands found",
                    .directory_navigator => if (palette.query.items.len > 0)
                        "No matching subfolders found"
                    else
                        "0 subfolders found",
                    .set_brightness,
                    .set_contrast,
                    .set_contrast_blend,
                    .set_highlights,
                    .set_shadows,
                    .set_whites,
                    .set_blacks,
                    .set_temperature,
                    .set_tint,
                    .set_vibrance,
                    .set_saturation,
                    .set_clarity,
                    .set_texture,
                    .go_to_image,
                    .set_slideshow_interval,
                    .inactive,
                    => "",
                };
                clay.text(no_match_msg, .{
                    .color = a(theme.subtext1, progress),
                    .font_size = 13,
                    .font_id = 0,
                });
            });
        }
    });
}

fn renderDirectoryLegend(progress: f32) void {
    const LegendItem = struct { key: []const u8, label: []const u8 };
    const legend_items = [_]LegendItem{
        .{ .key = "Right", .label = "Open" },
        .{ .key = "Enter", .label = "Load Selected" },
        .{ .key = "Shift+Enter", .label = "Load Current" },
        .{ .key = "Left", .label = "Up" },
        .{ .key = "Esc", .label = "Close" },
    };

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .center, .y = .center },
            .padding = .{ .top = 6, .bottom = 2 },
            .child_gap = 6,
        },
    })({
        inline for (legend_items) |item| {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{ .left = 5, .right = 7, .top = 3, .bottom = 3 },
                    .child_gap = 5,
                },
                .background_color = a(theme.crust, progress),
                .corner_radius = .all(4),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = a(theme.surface0, progress),
                },
            })({
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .fit, .h = .fit },
                        .padding = .{ .left = 4, .right = 4, .top = 1, .bottom = 1 },
                    },
                    .background_color = a(theme.surface0, progress),
                    .corner_radius = .all(3),
                })({
                    clay.text(item.key, .{
                        .color = a(theme.mauve, progress),
                        .font_size = 10,
                        .font_id = 0,
                    });
                });

                clay.text(item.label, .{
                    .color = a(theme.subtext0, progress),
                    .font_size = 11,
                    .font_id = 0,
                });
            });
        }
    });
}

/// Renders the complete Command Palette floating modal overlay (search input box, header title,
/// match counter, and virtualized scrollable result list) corresponding to the active palette mode.
pub fn renderPalette(
    ui_model: UiViewModel,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const palette = ui_model.palette;
    if (palette.mode == .inactive and !palette.is_closing) return;
    const progress = std.math.clamp(ui_model.anim(.palette_reveal), 0.0, 1.0);
    if (progress <= 0.001) return;

    const cfg = getPaletteConfig(palette.mode);
    const y_offset: f32 = (1.0 - progress) * -18.0;

    // Render Floating Card container
    clay.UI()(.{
        .id = clay.getElementId(cfg.element_id),
        .layout = .{
            .sizing = .{ .w = .fixed(550), .h = .fit },
            .direction = .top_to_bottom,
            .padding = .{ .top = 12, .bottom = 12, .left = 12, .right = 12 },
            .child_gap = 10,
        },
        .background_color = theme.withAlpha(theme.base_translucent, progress),
        .corner_radius = .all(10),
        .user_data = if (ui_model.overlays.enable_blur)
            @ptrFromInt(ElementTag.blurred_surface.toInt())
        else
            null,
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.withAlpha(theme.overlay0, progress),
        },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{
                .element = .center_center,
                .parent = .center_center,
            },
            .offset = .{
                .x = 0.0,
                .y = y_offset,
            },
            .z_index = 200,
            .pointer_capture_mode = if (palette.is_closing)
                .passthrough
            else
                .capture,
        },
    })({
        // Title / Header
        renderHeader(palette.mode, cfg.title, progress);

        // Breadcrumb box for directory_navigator
        if (palette.mode == .directory_navigator) {
            try renderDirectoryBreadcrumbs(palette, frame_allocator, measure_data, progress);
        }

        // Search Input Box
        renderSearchInput(palette, cfg.placeholder, progress);

        if (palette.mode.isTextInputDialog()) {
            try renderTextInputDialog(ui_model, frame_allocator, measure_data, progress);
        } else {
            try renderSelectionList(ui_model, cfg, frame_allocator, measure_data, progress);
        }

        // Footer Legend for Directory Navigator
        if (palette.mode == .directory_navigator) {
            renderDirectoryLegend(progress);
        }
    });
}

test "renderPalette - closing palette passes pointer through to parent" {
    const dummyMeasure = struct {
        fn measure(
            text: []const u8,
            config: *clay.TextElementConfig,
            _: void,
        ) clay.Dimensions {
            _ = config;
            return .{ .w = @floatFromInt(text.len * 8), .h = 16.0 };
        }
    }.measure;
    const setNullCtx = @as(
        *const fn (?*clay.Context) callconv(.c) void,
        @ptrCast(&clay.cdefs.Clay_SetCurrentContext),
    );
    setNullCtx(null);
    defer setNullCtx(null);
    const clay_mem = try std.testing.allocator.alloc(u8, clay.minMemorySize());
    defer std.testing.allocator.free(clay_mem);
    _ = clay.initialize(
        clay.Arena.init(clay_mem),
        .{ .w = 1000, .h = 800 },
        .{},
    );
    clay.setMeasureTextFunction(void, {}, dummyMeasure);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var data = MeasureTextUserData{
        .allocator = std.testing.allocator,
        .fonts = &(@as([2]?sdl.Font, @splat(null))),
    };
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

    // 1. Open palette captures pointer over center -> parent is not hit
    clay.beginLayout();
    clay.UI()(.{
        .id = clay.getElementId("RootHost"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
    })({
        try renderPalette(model, arena.allocator(), &data);
    });
    _ = clay.endLayout();
    clay.setPointerState(.{ .x = 500, .y = 350 }, false);
    try std.testing.expect(!clay.pointerOver(clay.getElementId("RootHost")));

    // 2. Closing palette passes pointer through -> parent is hit
    pal_state.is_closing = true;
    clay.beginLayout();
    clay.UI()(.{
        .id = clay.getElementId("RootHost"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
    })({
        try renderPalette(model, arena.allocator(), &data);
    });
    _ = clay.endLayout();
    clay.setPointerState(.{ .x = 500, .y = 350 }, false);
    try std.testing.expect(clay.pointerOver(clay.getElementId("RootHost")));
}
