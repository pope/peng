const std = @import("std");
const clay = @import("zclay");
const sdl = @import("sdl");
const app_state = @import("../app/state.zig");
const ViewerState = app_state.ViewerState;
const PaletteState = app_state.PaletteState;
const stopTextInput = app_state.stopTextInput;
const app_actions = @import("../commands/actions.zig").app_actions;
const getActionMetadata = @import("../commands/actions.zig").getActionMetadata;
const types = @import("../app/types.zig");
const MeasureTextUserData = types.MeasureTextUserData;
const sdl3MeasureText = @import("graphics.zig").sdl3MeasureText;
const layout_helpers = @import("layout_helpers.zig");
const DpiScale = @import("units.zig").DpiScale;
const text_utils = @import("text_utils.zig");
const truncateFilename = text_utils.truncateFilename;
const truncateFilenameMiddle = text_utils.truncateFilenameMiddle;
const remapMiddleTruncatedMatches = text_utils.remapMiddleTruncatedMatches;
const truncateDirectory = text_utils.truncateDirectory;
const formatSize = text_utils.formatSize;
const theme = @import("theme.zig");

const PaletteMode = app_state.PaletteMode;

pub const TextChunk = struct {
    slice: []const u8,
    is_matched: bool,
};

fn appendOrMergeChunk(list: *std.ArrayList(TextChunk), allocator: std.mem.Allocator, slice: []const u8, is_matched: bool) !void {
    if (slice.len == 0) return;
    if (list.items.len > 0 and list.items[list.items.len - 1].is_matched == is_matched) {
        const last = &list.items[list.items.len - 1];
        const combined_len = last.slice.len + slice.len;
        last.slice = last.slice.ptr[0..combined_len];
    } else {
        try list.append(allocator, .{
            .slice = slice,
            .is_matched = is_matched,
        });
    }
}

pub fn partitionHighlightedText(
    allocator: std.mem.Allocator,
    text: []const u8,
    match_indices: []const usize,
) ![]TextChunk {
    if (text.len == 0 or match_indices.len == 0) {
        if (text.len == 0) return &.{};
        var list = try std.ArrayList(TextChunk).initCapacity(allocator, 1);
        list.appendAssumeCapacity(.{ .slice = text, .is_matched = false });
        return list.toOwnedSlice(allocator);
    }

    for (match_indices) |m_idx| {
        if (m_idx >= text.len) {
            std.log.warn("Fuzzy highlight match index {} out of bounds for string '{s}' (length {})", .{ m_idx, text, text.len });
        }
    }

    var list = std.ArrayList(TextChunk).empty;
    errdefer list.deinit(allocator);

    var idx: usize = 0;
    var match_ptr: usize = 0;

    while (idx < text.len) {
        while (match_ptr < match_indices.len and match_indices[match_ptr] < idx) {
            match_ptr += 1;
        }
        const is_matched = (match_ptr < match_indices.len and match_indices[match_ptr] == idx);

        const start = idx;
        idx += 1;
        while (idx < text.len and (text[idx] & 0xC0) == 0x80) {
            idx += 1;
        }

        if (is_matched) {
            match_ptr += 1;
            while (idx < text.len and match_ptr < match_indices.len and match_indices[match_ptr] == idx) {
                idx += 1;
                while (idx < text.len and (text[idx] & 0xC0) == 0x80) {
                    idx += 1;
                }
                match_ptr += 1;
            }

            var match_start = start;
            var match_end = idx;

            while (match_start < match_end and std.ascii.isWhitespace(text[match_start])) {
                match_start += 1;
            }
            while (match_end > match_start and std.ascii.isWhitespace(text[match_end - 1])) {
                match_end -= 1;
            }

            if (match_start >= match_end) {
                try appendOrMergeChunk(&list, allocator, text[start..idx], false);
            } else {
                if (match_start > start) {
                    try appendOrMergeChunk(&list, allocator, text[start..match_start], false);
                }
                try appendOrMergeChunk(&list, allocator, text[match_start..match_end], true);
                if (idx > match_end) {
                    try appendOrMergeChunk(&list, allocator, text[match_end..idx], false);
                }
            }
        } else {
            while (idx < text.len) {
                while (match_ptr < match_indices.len and match_indices[match_ptr] < idx) {
                    match_ptr += 1;
                }
                if (match_ptr < match_indices.len and match_indices[match_ptr] == idx) {
                    break;
                }
                idx += 1;
            }

            try appendOrMergeChunk(&list, allocator, text[start..idx], false);
        }
    }

    return try list.toOwnedSlice(allocator);
}

pub fn renderFuzzyMatchText(
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

    const chunks = partitionHighlightedText(allocator, text, match_indices) catch |err| {
        std.log.err("partitionHighlightedText failed for '{s}': {}", .{ text, err });
        clay.text(text, .{ .color = normal_color, .font_size = font_size, .font_id = 0, .wrap_mode = .none });
        return;
    };

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        for (chunks) |chunk| {
            clay.text(chunk.slice, .{
                .color = if (chunk.is_matched) highlight_color else normal_color,
                .font_size = font_size,
                .font_id = 0,
                .wrap_mode = .none,
            });
        }
    });
}

pub const renderHighlightedText = renderFuzzyMatchText;

pub const PaletteConfig = struct {
    title: []const u8,
    placeholder: []const u8,
    element_id: []const u8,
    list_id: []const u8,
    item_prefix: []const u8,
    top_spacer_id: []const u8,
    bottom_spacer_id: []const u8,
    base_item_height: f32,
};

pub fn getPaletteConfig(mode: PaletteMode) PaletteConfig {
    return switch (mode) {
        .files => .{
            .title = "Search Files",
            .placeholder = "Type file name to search...",
            .element_id = "CommandPalette",
            .list_id = "CommandPaletteList",
            .item_prefix = "PaletteItem_",
            .top_spacer_id = "PaletteTopSpacer",
            .bottom_spacer_id = "PaletteBottomSpacer",
            .base_item_height = 58.0,
        },
        .actions => .{
            .title = "Command Palette",
            .placeholder = "Type a command to run...",
            .element_id = "ActionPalette",
            .list_id = "ActionPaletteList",
            .item_prefix = "ActionItem_",
            .top_spacer_id = "ActionTopSpacer",
            .bottom_spacer_id = "ActionBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_brightness => .{
            .title = "Set Brightness",
            .placeholder = "Enter brightness (-1.0 to 1.0, e.g. 0.2)...",
            .element_id = "BrightnessPalette",
            .list_id = "BrightnessPaletteList",
            .item_prefix = "BrightnessItem_",
            .top_spacer_id = "BrightnessTopSpacer",
            .bottom_spacer_id = "BrightnessBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_contrast => .{
            .title = "Set Contrast",
            .placeholder = "Enter contrast (0.0 to 5.0, e.g. 1.5)...",
            .element_id = "ContrastPalette",
            .list_id = "ContrastPaletteList",
            .item_prefix = "ContrastItem_",
            .top_spacer_id = "ContrastTopSpacer",
            .bottom_spacer_id = "ContrastBottomSpacer",
            .base_item_height = 50.0,
        },
        .go_to_image => .{
            .title = "Go to Image",
            .placeholder = "Enter image number...",
            .element_id = "GoToImagePalette",
            .list_id = "GoToImageList",
            .item_prefix = "GoToImageItem_",
            .top_spacer_id = "GoToImageTopSpacer",
            .bottom_spacer_id = "GoToImageBottomSpacer",
            .base_item_height = 50.0,
        },
        .directory_navigator => .{
            .title = "Directory Navigator",
            .placeholder = "Search subfolders...",
            .element_id = "DirectoryNavigatorPalette",
            .list_id = "DirectoryNavigatorList",
            .item_prefix = "DirItem_",
            .top_spacer_id = "DirTopSpacer",
            .bottom_spacer_id = "DirBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_slideshow_interval => .{
            .title = "Start Slide Show",
            .placeholder = "Enter delay in seconds (e.g. 3 or 2.5)...",
            .element_id = "SlideshowPalette",
            .list_id = "SlideshowPaletteList",
            .item_prefix = "SlideshowItem_",
            .top_spacer_id = "SlideshowTopSpacer",
            .bottom_spacer_id = "SlideshowBottomSpacer",
            .base_item_height = 50.0,
        },
        .inactive => getPaletteConfig(.files),
    };
}

fn renderHeader(mode: PaletteMode, title: []const u8) void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(title, .{
            .color = switch (mode) {
                .files => theme.pink,
                .actions => theme.blue,
                .set_brightness, .set_contrast => theme.peach,
                .go_to_image => theme.green,
                .directory_navigator => theme.mauve,
                .set_slideshow_interval => theme.yellow,
                .inactive => theme.text,
            },
            .font_size = 13,
            .font_id = 0,
        });
    });
}

fn renderDirectoryBreadcrumbs(
    palette: *const PaletteState,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const display_dir = truncateDirectory(frame_allocator, palette.current_nav_dir.items, 320.0, 12, measure_data);
    const curr_img_count = palette.current_dir_image_count;
    const count_str = try std.fmt.allocPrint(frame_allocator, "{} image{s}", .{ curr_img_count, if (curr_img_count == 1) "" else "s" });
    const count_color = if (curr_img_count == 0) theme.subtext1 else theme.green;

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fit },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .padding = .{ .top = 4, .bottom = 4, .left = 8, .right = 8 },
            .child_gap = 8,
        },
        .background_color = theme.crust,
        .corner_radius = .all(6),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.surface0,
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
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                },
                .background_color = theme.crust,
                .corner_radius = .all(4),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = theme.mauve,
                },
            })({
                clay.text("DIR", .{
                    .color = theme.mauve,
                    .font_size = 11,
                    .font_id = 0,
                });
            });

            clay.text(display_dir, .{
                .color = theme.mauve,
                .font_size = 12,
                .font_id = 0,
            });
        });

        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
            },
            .background_color = theme.crust,
            .corner_radius = .all(4),
            .border = .{
                .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                .color = if (curr_img_count == 0) theme.surface0 else theme.green,
            },
        })({
            clay.text(count_str, .{
                .color = count_color,
                .font_size = 11,
                .font_id = 0,
            });
        });
    });
}

fn renderSearchInput(palette: *const PaletteState, placeholder: []const u8) void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(38) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .padding = .{ .left = 12, .right = 12 },
        },
        .background_color = theme.crust,
        .corner_radius = .all(6),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.blue,
        },
    })({
        const query_str = if (palette.query.items.len > 0) palette.query.items else placeholder;
        const query_color = if (palette.query.items.len > 0) theme.text else theme.subtext1;
        clay.text(query_str, .{
            .color = query_color,
            .font_size = 14,
            .font_id = 0,
        });
    });
}

pub fn renderTextInputDialog(
    state: *ViewerState,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const palette = &state.palette;
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(64) },
            .direction = .top_to_bottom,
            .child_alignment = .{ .x = .left, .y = .center },
            .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 },
            .child_gap = 6,
        },
        .background_color = theme.crust,
        .corner_radius = .all(6),
    })({
        const raw_str = palette.query.items;
        state.lockImageList();
        const total_count = state.image_list.items.len;
        state.unlockImageList();
        switch (palette.mode) {
            .go_to_image => {
                if (total_count == 0) {
                    clay.text("No images loaded.", .{
                        .color = theme.red,
                        .font_size = 13,
                        .font_id = 0,
                    });
                } else if (raw_str.len == 0) {
                    clay.text("Enter image number, then press Enter to apply.", .{
                        .color = theme.subtext0,
                        .font_size = 13,
                        .font_id = 0,
                    });
                    const range_str = try std.fmt.allocPrint(frame_allocator, "Allowed range: 1 to {} (current: {})", .{ total_count, (state.current_index orelse 0) + 1 });
                    clay.text(range_str, .{
                        .color = theme.subtext1,
                        .font_size = 11,
                        .font_id = 0,
                    });
                } else {
                    if (std.fmt.parseInt(usize, raw_str, 10)) |val| {
                        if (val >= 1 and val <= total_count) {
                            const target_path = blk: {
                                state.lockImageList();
                                defer state.unlockImageList();
                                break :blk if (val - 1 < state.image_list.items.len) state.image_list.items[val - 1] else "";
                            };
                            const raw_basename = std.fs.path.basename(target_path);
                            const display_filename = truncateFilename(frame_allocator, raw_basename, 492.0, 12, measure_data);
                            const success_str = try std.fmt.allocPrint(frame_allocator, "Press Enter to go to {}: {s}", .{ val, display_filename });
                            clay.text(success_str, .{
                                .color = theme.green,
                                .font_size = 13,
                                .font_id = 0,
                            });
                        } else {
                            const err_str = try std.fmt.allocPrint(frame_allocator, "Out of bounds: must be between 1 and {}", .{total_count});
                            clay.text(err_str, .{
                                .color = theme.red,
                                .font_size = 13,
                                .font_id = 0,
                            });
                        }
                    } else |err| {
                        std.log.debug("Failed to parse integer in palette input '{s}': {}", .{ raw_str, err });
                        clay.text("Invalid number format. Enter a positive integer.", .{
                            .color = theme.red,
                            .font_size = 13,
                            .font_id = 0,
                        });
                    }
                }
            },
            .set_slideshow_interval => {
                if (raw_str.len == 0) {
                    clay.text("Enter delay in seconds, then press Enter to start.", .{
                        .color = theme.subtext0,
                        .font_size = 13,
                        .font_id = 0,
                    });
                    clay.text("Example: 3 for 3 seconds per slide", .{
                        .color = theme.subtext1,
                        .font_size = 11,
                        .font_id = 0,
                    });
                } else {
                    var is_valid = false;
                    if (std.fmt.parseFloat(f32, raw_str)) |val| {
                        if (!std.math.isNan(val) and !std.math.isInf(val) and val > 0.0) {
                            is_valid = true;
                            const success_str = try std.fmt.allocPrint(frame_allocator, "Press Enter to start slide show ({d:.1}s per slide)", .{val});
                            clay.text(success_str, .{
                                .color = theme.green,
                                .font_size = 13,
                                .font_id = 0,
                            });
                        }
                    } else |err| {
                        std.log.debug("Failed to parse slideshow float '{s}': {}", .{ raw_str, err });
                    }
                    if (!is_valid) {
                        clay.text("Invalid duration. Must be greater than 0 seconds.", .{
                            .color = theme.red,
                            .font_size = 13,
                            .font_id = 0,
                        });
                    }
                }
            },
            .set_brightness, .set_contrast => {
                if (raw_str.len == 0) {
                    clay.text("Enter a number, then press Enter to apply.", .{
                        .color = theme.subtext0,
                        .font_size = 13,
                        .font_id = 0,
                    });
                    const range_str = if (palette.mode == .set_brightness) "Allowed range: -1.0 to 1.0 (default: 0.0)" else "Allowed range: 0.0 to 5.0 (default: 1.0)";
                    clay.text(range_str, .{
                        .color = theme.subtext1,
                        .font_size = 11,
                        .font_id = 0,
                    });
                } else {
                    var is_valid_float = false;
                    if (std.fmt.parseFloat(f32, raw_str)) |val| {
                        if (!std.math.isNan(val) and !std.math.isInf(val)) {
                            is_valid_float = true;
                            const bounds = palette.mode.getTextInputBounds() orelse app_state.palette_module.TextInputBounds{ .min = 0.0, .max = 1.0 };
                            const min_val = bounds.min;
                            const max_val = bounds.max;
                            if (val >= min_val and val <= max_val) {
                                const success_str = try std.fmt.allocPrint(frame_allocator, "Press Enter to set value to: {d:.2}", .{val});
                                clay.text(success_str, .{
                                    .color = theme.green,
                                    .font_size = 13,
                                    .font_id = 0,
                                });
                            } else {
                                const err_str = try std.fmt.allocPrint(frame_allocator, "Out of bounds: must be between {d:.1} and {d:.1}", .{ min_val, max_val });
                                clay.text(err_str, .{
                                    .color = theme.red,
                                    .font_size = 13,
                                    .font_id = 0,
                                });
                            }
                        }
                    } else |err| {
                        std.log.debug("Failed to parse adjustment float '{s}': {}", .{ raw_str, err });
                    }
                    if (!is_valid_float) {
                        clay.text("Invalid float format. Enter a number.", .{
                            .color = theme.red,
                            .font_size = 13,
                            .font_id = 0,
                        });
                    }
                }
            },
            else => {},
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
/// 3. Top & Bottom Spacers:
///    Replaces non-rendered items outside the window with single empty
///    container elements (`top_spacer_h` and `bottom_spacer_h`), properly
///    accounting for layout child gaps to preserve total scrollable height.
pub const VirtualWindow = struct {
    start_idx: usize,
    end_idx: usize,
    top_spacer_h: f32,
    bottom_spacer_h: f32,

    pub fn compute(
        total_items: usize,
        scroll_offset_y: f32,
        viewport_height: f32,
        item_height: f32,
        gap: f32,
    ) VirtualWindow {
        if (total_items == 0) {
            return .{ .start_idx = 0, .end_idx = 0, .top_spacer_h = 0, .bottom_spacer_h = 0 };
        }

        const visible_top = -scroll_offset_y;
        const visible_bottom = visible_top + viewport_height;

        var start_idx = @as(usize, @intFromFloat(@max(0.0, @floor(visible_top / item_height))));
        var end_idx = @as(usize, @intFromFloat(@max(0.0, @ceil(visible_bottom / item_height))));

        start_idx = if (start_idx > 0) start_idx - 1 else 0;
        end_idx = end_idx + 1;

        if (end_idx > total_items) end_idx = total_items;
        if (start_idx > end_idx) start_idx = end_idx;

        const top_spacer_h = if (start_idx > 0)
            @as(f32, @floatFromInt(start_idx)) * item_height - gap
        else
            0.0;

        const bottom_spacer_h = if (total_items - end_idx > 0)
            @as(f32, @floatFromInt(total_items - end_idx)) * item_height - gap
        else
            0.0;

        return .{
            .start_idx = start_idx,
            .end_idx = end_idx,
            .top_spacer_h = top_spacer_h,
            .bottom_spacer_h = bottom_spacer_h,
        };
    }
};

pub fn renderSelectionList(
    state: *ViewerState,
    cfg: PaletteConfig,
    mouse_clicked: bool,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const palette = &state.palette;
    const scroll_data = clay.cdefs.Clay_GetScrollContainerData(clay.getElementId(cfg.list_id));
    var scroll_offset = if (scroll_data.found) scroll_data.scroll_position.* else clay.Vector2{ .x = 0, .y = 0 };

    const item_height = cfg.base_item_height;
    const viewport_height = 320.0;

    if (scroll_data.found and palette.selection_dirty) {
        const item_top = @as(f32, @floatFromInt(palette.selected_idx)) * item_height;
        const item_bottom = item_top + item_height;
        const visible_top = -scroll_data.scroll_position.y;
        const visible_bottom = visible_top + viewport_height;

        if (item_top < visible_top) {
            scroll_data.scroll_position.y = -item_top;
            scroll_offset.y = -item_top;
        } else if (item_bottom > visible_bottom) {
            scroll_data.scroll_position.y = -(item_bottom - viewport_height);
            scroll_offset.y = -(item_bottom - viewport_height);
        }
        palette.selection_dirty = false;
    }

    const matching_indices = &palette.matches;
    const window = VirtualWindow.compute(
        matching_indices.items.len,
        scroll_offset.y,
        viewport_height,
        item_height,
        4.0,
    );

    clay.UI()(.{
        .id = clay.getElementId(cfg.list_id),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(320) },
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

        if (palette.mode == .files) {
            state.lockImageList();
        }
        defer if (palette.mode == .files) {
            state.unlockImageList();
        };

        var match_count = window.start_idx;
        for (matching_indices.items[window.start_idx..window.end_idx]) |real_idx| {
            const is_selected = (match_count == palette.selected_idx);

            var item_id_buf: [64]u8 = undefined;
            const item_id_str = std.fmt.bufPrint(&item_id_buf, "{s}{}", .{ cfg.item_prefix, real_idx }) catch cfg.item_prefix;
            const item_id = clay.getElementId(item_id_str);
            const item_hovered = clay.pointerOver(item_id);

            clay.UI()(.{
                .id = item_id,
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(switch (palette.mode) {
                        .files => 54.0,
                        .actions, .directory_navigator => 46.0,
                        else => 0.0,
                    }) },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{ .left = 12, .right = 12 },
                },
                .background_color = if (is_selected)
                    theme.surface0
                else if (item_hovered)
                    theme.base
                else
                    clay.Color{ 0, 0, 0, 0 },
                .corner_radius = .all(6),
            })({
                switch (palette.mode) {
                    .files => {
                        const path = if (real_idx < state.image_list.items.len) state.image_list.items[real_idx] else "";
                        const basename = std.fs.path.basename(path);
                        const dirname = std.fs.path.dirname(path) orelse ".";
                        const query_str = palette.query.items;

                        var basename_matches = std.ArrayList(usize).empty;
                        var dirname_matches = std.ArrayList(usize).empty;

                        if (query_str.len > 0 and path.len > 0) {
                            const searcher_opt = palette.getSearcher(@max(path.len, 64), query_str.len) catch |err| blk: {
                                std.log.err("getSearcher failed: {}", .{err});
                                break :blk null;
                            };
                            if (searcher_opt) |searcher_ptr| {
                                const has_slash = std.mem.indexOfScalar(u8, query_str, '/') != null or std.mem.indexOfScalar(u8, query_str, '\\') != null;
                                var matched_base = false;
                                if (!has_slash) {
                                    const base_res = searcher_ptr.scoreMatches(basename, query_str);
                                    if (base_res.score != null) {
                                        basename_matches.appendSlice(frame_allocator, base_res.matches) catch |err| {
                                            std.log.err("appendSlice failed: {}", .{err});
                                        };
                                        matched_base = true;
                                    }
                                }
                                if (!matched_base) {
                                    const full_res = searcher_ptr.scoreMatches(path, query_str);
                                    if (full_res.score != null) {
                                        const basename_offset = path.len - basename.len;
                                        for (full_res.matches) |m_idx| {
                                            if (m_idx >= basename_offset) {
                                                const b_idx = m_idx - basename_offset;
                                                if (b_idx < basename.len) {
                                                    basename_matches.append(frame_allocator, b_idx) catch |err| {
                                                        std.log.err("append failed: {}", .{err});
                                                    };
                                                }
                                            } else if (m_idx < dirname.len) {
                                                dirname_matches.append(frame_allocator, m_idx) catch |err| {
                                                    std.log.err("append failed: {}", .{err});
                                                };
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        const trunc_filename = truncateFilenameMiddle(frame_allocator, basename, 492.0, 13, measure_data);
                        const display_filename = trunc_filename.display;
                        const final_basename_matches = remapMiddleTruncatedMatches(frame_allocator, basename_matches.items, trunc_filename.head_len, trunc_filename.tail_start_idx) catch basename_matches.items;

                        const display_dir = truncateDirectory(frame_allocator, dirname, 488.0, 11, measure_data);

                        var final_dir_matches = std.ArrayList(usize).empty;
                        if (display_dir.ptr != dirname.ptr and display_dir.len > 0 and std.mem.startsWith(u8, display_dir, "...")) {
                            const kept_len = display_dir.len - 3;
                            const start_offset = if (dirname.len > kept_len) dirname.len - kept_len else 0;
                            for (dirname_matches.items) |m_idx| {
                                if (m_idx >= start_offset) {
                                    final_dir_matches.append(frame_allocator, (m_idx - start_offset) + 3) catch |err| {
                                        std.log.err("append final_dir_matches failed: {}", .{err});
                                    };
                                }
                            }
                        } else {
                            final_dir_matches = dirname_matches;
                        }

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
                                    .background_color = if (is_selected) theme.blue else theme.subtext1,
                                    .corner_radius = .all(3),
                                })({});

                                renderFuzzyMatchText(
                                    frame_allocator,
                                    display_filename,
                                    final_basename_matches,
                                    13,
                                    if (is_selected) theme.blue else theme.text,
                                    theme.yellow,
                                );
                            });

                            clay.UI()(.{
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fit },
                                    .direction = .left_to_right,
                                    .padding = .{ .left = 14 },
                                },
                            })({
                                renderFuzzyMatchText(
                                    frame_allocator,
                                    display_dir,
                                    final_dir_matches.items,
                                    11,
                                    theme.subtext0,
                                    theme.yellow,
                                );
                            });
                        });
                    },
                    .actions => {
                        const action_id = app_actions[real_idx];
                        const meta = getActionMetadata(action_id);
                        const query_str = palette.query.items;

                        var action_matches: []const usize = &.{};
                        if (query_str.len > 0) {
                            const searcher_opt = palette.getSearcher(meta.name.len, query_str.len) catch |err| blk: {
                                std.log.err("getSearcher failed: {}", .{err});
                                break :blk null;
                            };
                            if (searcher_opt) |searcher_ptr| {
                                const res = searcher_ptr.scoreMatches(meta.name, query_str);
                                if (res.score != null) {
                                    action_matches = res.matches;
                                }
                            }
                        }

                        clay.UI()(.{
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fit },
                                .direction = .left_to_right,
                                .child_alignment = .{ .x = .left, .y = .center },
                            },
                        })({
                            renderFuzzyMatchText(
                                frame_allocator,
                                meta.name,
                                action_matches,
                                13,
                                if (is_selected) theme.blue else theme.text,
                                theme.yellow,
                            );
                        });

                        if (meta.shortcut_text.len > 0) {
                            clay.UI()(.{
                                .layout = .{
                                    .sizing = .{ .w = .fit, .h = .fit },
                                    .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                                },
                                .background_color = theme.crust,
                                .corner_radius = .all(4),
                                .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = theme.surface0 },
                            })({
                                clay.text(meta.shortcut_text, .{
                                    .color = theme.subtext0,
                                    .font_size = 11,
                                    .font_id = 0,
                                });
                            });
                        }
                    },
                    .directory_navigator => {
                        if (real_idx < palette.dir_items.items.len) {
                            const entry = palette.dir_items.items[real_idx];
                            var dir_matches = std.ArrayList(usize).empty;
                            const query_str = palette.query.items;

                            if (query_str.len > 0 and entry.name.len > 0) {
                                const searcher_opt = palette.getSearcher(entry.name.len, query_str.len) catch |err| blk: {
                                    std.log.err("getSearcher failed: {}", .{err});
                                    break :blk null;
                                };
                                if (searcher_opt) |searcher_ptr| {
                                    const res = searcher_ptr.scoreMatches(entry.name, query_str);
                                    if (res.score != null) {
                                        dir_matches.appendSlice(frame_allocator, res.matches) catch |err| {
                                            std.log.err("appendSlice dir_matches failed: {}", .{err});
                                        };
                                    }
                                }
                            }

                            clay.UI()(.{
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fit },
                                    .direction = .left_to_right,
                                    .child_alignment = .{ .x = .left, .y = .center },
                                    .child_gap = 8,
                                },
                            })({
                                clay.UI()(.{
                                    .layout = .{
                                        .sizing = .{ .w = .fit, .h = .fit },
                                        .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                                    },
                                    .background_color = theme.crust,
                                    .corner_radius = .all(4),
                                    .border = .{
                                        .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                                        .color = theme.blue,
                                    },
                                })({
                                    clay.text("DIR", .{
                                        .color = theme.blue,
                                        .font_size = 11,
                                        .font_id = 0,
                                    });
                                });

                                const trunc_folder = truncateFilenameMiddle(frame_allocator, entry.name, 350.0, 13, measure_data);
                                const display_foldername = trunc_folder.display;
                                const final_folder_matches = remapMiddleTruncatedMatches(frame_allocator, dir_matches.items, trunc_folder.head_len, trunc_folder.tail_start_idx) catch dir_matches.items;

                                renderFuzzyMatchText(
                                    frame_allocator,
                                    display_foldername,
                                    final_folder_matches,
                                    13,
                                    if (is_selected) theme.blue else theme.text,
                                    theme.yellow,
                                );
                            });

                            const image_count = entry.getImageCount();
                            const subdir_count = entry.getSubdirCount();
                            const count_str = try std.fmt.allocPrint(frame_allocator, "{} image{s}", .{ image_count, if (image_count == 1) "" else "s" });
                            const count_color = if (image_count == 0) theme.subtext1 else theme.green;

                            const sub_str = try std.fmt.allocPrint(frame_allocator, "{} subfolder{s}", .{ subdir_count, if (subdir_count == 1) "" else "s" });
                            const sub_color = if (subdir_count == 0) theme.subtext1 else theme.blue;

                            clay.UI()(.{
                                .layout = .{
                                    .sizing = .{ .w = .fit, .h = .fit },
                                    .direction = .left_to_right,
                                    .child_gap = 6,
                                },
                            })({
                                clay.UI()(.{
                                    .layout = .{
                                        .sizing = .{ .w = .fit, .h = .fit },
                                        .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                                    },
                                    .background_color = theme.crust,
                                    .corner_radius = .all(4),
                                    .border = .{
                                        .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                                        .color = if (image_count == 0) theme.surface0 else theme.green,
                                    },
                                })({
                                    clay.text(count_str, .{
                                        .color = count_color,
                                        .font_size = 11,
                                        .font_id = 0,
                                    });
                                });

                                clay.UI()(.{
                                    .layout = .{
                                        .sizing = .{ .w = .fit, .h = .fit },
                                        .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                                    },
                                    .background_color = theme.crust,
                                    .corner_radius = .all(4),
                                    .border = .{
                                        .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                                        .color = if (subdir_count == 0) theme.surface0 else theme.blue,
                                    },
                                })({
                                    clay.text(sub_str, .{
                                        .color = sub_color,
                                        .font_size = 11,
                                        .font_id = 0,
                                    });
                                });
                            });
                        }
                    },
                    else => {},
                }
            });

            if (mouse_clicked and item_hovered) {
                const old_type = palette.mode;
                switch (palette.mode) {
                    .files => {
                        state.current_index = real_idx;
                        try state.updateCache();
                        palette.mode = .inactive;
                        stopTextInput(state.window);
                    },
                    .actions => {
                        const action_id = app_actions[real_idx];
                        try state.triggerAction(action_id);
                        if (palette.mode == old_type) {
                            palette.mode = .inactive;
                            stopTextInput(state.window);
                        }
                    },
                    .directory_navigator => {
                        if (real_idx < palette.dir_items.items.len) {
                            const entry = palette.dir_items.items[real_idx];
                            const path_copy = try frame_allocator.dupe(u8, entry.full_path);
                            try palette.loadDirectoryEntries(state.io, path_copy);
                            palette.query.clearRetainingCapacity();
                        }
                    },
                    else => {},
                }
            }

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
                    .directory_navigator => if (palette.query.items.len > 0) "No matching subfolders found" else "0 subfolders found",
                    else => "",
                };
                clay.text(no_match_msg, .{
                    .color = theme.subtext1,
                    .font_size = 13,
                    .font_id = 0,
                });
            });
        }
    });
}

fn renderDirectoryLegend() void {
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
                .background_color = theme.crust,
                .corner_radius = .all(4),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = theme.surface0,
                },
            })({
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .fit, .h = .fit },
                        .padding = .{ .left = 4, .right = 4, .top = 1, .bottom = 1 },
                    },
                    .background_color = theme.surface0,
                    .corner_radius = .all(3),
                })({
                    clay.text(item.key, .{
                        .color = theme.mauve,
                        .font_size = 10,
                        .font_id = 0,
                    });
                });

                clay.text(item.label, .{
                    .color = theme.subtext0,
                    .font_size = 11,
                    .font_id = 0,
                });
            });
        }
    });
}

pub fn renderPalette(
    state: *ViewerState,
    mouse_clicked: bool,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const palette = &state.palette;
    if (palette.mode == .inactive) return;

    const cfg = getPaletteConfig(palette.mode);

    // Render Floating Card container
    clay.UI()(.{
        .id = clay.getElementId(cfg.element_id),
        .layout = .{
            .sizing = .{ .w = .fixed(550), .h = .fit },
            .direction = .top_to_bottom,
            .padding = .{ .top = 12, .bottom = 12, .left = 12, .right = 12 },
            .child_gap = 10,
        },
        .background_color = theme.base_translucent, // Catppuccin Base with opacity
        .corner_radius = .all(10),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.overlay0,
        },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{
                .element = .center_center,
                .parent = .center_center,
            },
            .z_index = 200,
        },
    })({
        // Title / Header
        renderHeader(palette.mode, cfg.title);

        // Breadcrumb box for directory_navigator
        if (palette.mode == .directory_navigator) {
            try renderDirectoryBreadcrumbs(palette, frame_allocator, measure_data);
        }

        // Search Input Box
        renderSearchInput(palette, cfg.placeholder);

        if (palette.mode.isTextInputDialog()) {
            try renderTextInputDialog(state, frame_allocator, measure_data);
        } else {
            try renderSelectionList(state, cfg, mouse_clicked, frame_allocator, measure_data);
        }

        // Footer Legend for Directory Navigator
        if (palette.mode == .directory_navigator) {
            renderDirectoryLegend();
        }
    });
}

test "renderHighlightedText whitespace boundary handling" {
    renderHighlightedText(std.testing.allocator, "Scale Nearest Neighbor", &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, 13, theme.text, theme.yellow);
    renderHighlightedText(std.testing.allocator, "Scale Mode: Fit", &.{ 0, 1, 2, 3, 4, 5 }, 13, theme.text, theme.yellow);
    renderHighlightedText(std.testing.allocator, "   leading and trailing   ", &.{ 3, 4, 5 }, 13, theme.text, theme.yellow);
}

test "partitionHighlightedText filterh query on Set Scaling Filter: Bilinear (Smooth)" {
    var palette = PaletteState.init(std.testing.allocator);
    defer palette.deinit();

    const searcher = try palette.getSearcher(64, 16);
    const text = "Set Scaling Filter: Bilinear (Smooth)";
    const res = searcher.scoreMatches(text, "filterh");
    std.debug.print("\n=== MATCHES for filterh: {any} ===\n", .{res.matches});

    const chunks = try partitionHighlightedText(std.testing.allocator, text, res.matches);
    defer std.testing.allocator.free(chunks);
    for (chunks, 0..) |chunk, i| {
        std.debug.print("Chunk {d}: '{s}' (matched={})\n", .{ i, chunk.slice, chunk.is_matched });
    }
}

test "partitionHighlightedText correctly partitions matched and unmatched chunks" {
    // Scenario 1: Query "sc" matching "Set Contrast" (indices 0 and 4)
    const text1 = "Set Contrast";
    const matches1 = [_]usize{ 0, 4 };

    const chunks1 = try partitionHighlightedText(std.testing.allocator, text1, &matches1);
    defer std.testing.allocator.free(chunks1);

    try std.testing.expectEqual(@as(usize, 4), chunks1.len);
    try std.testing.expectEqualStrings("S", chunks1[0].slice);
    try std.testing.expect(chunks1[0].is_matched);
    try std.testing.expectEqualStrings("et ", chunks1[1].slice);
    try std.testing.expect(!chunks1[1].is_matched);
    try std.testing.expectEqualStrings("C", chunks1[2].slice);
    try std.testing.expect(chunks1[2].is_matched);
    try std.testing.expectEqualStrings("ontrast", chunks1[3].slice);
    try std.testing.expect(!chunks1[3].is_matched);
}

test "partitionHighlightedText merges isolated whitespace matches back into unmatched text" {
    // Scenario 2: Query "sc " matching "Set Contrast (Type Value)..."
    // (indices 0, 4, and 12)
    const text2 = "Set Contrast (Type Value)...";
    const matches2 = [_]usize{ 0, 4, 12 };

    const chunks2 = try partitionHighlightedText(std.testing.allocator, text2, &matches2);
    defer std.testing.allocator.free(chunks2);

    try std.testing.expectEqual(@as(usize, 4), chunks2.len);
    try std.testing.expectEqualStrings("S", chunks2[0].slice);
    try std.testing.expect(chunks2[0].is_matched);
    try std.testing.expectEqualStrings("et ", chunks2[1].slice);
    try std.testing.expect(!chunks2[1].is_matched);
    try std.testing.expectEqualStrings("C", chunks2[2].slice);
    try std.testing.expect(chunks2[2].is_matched);
    try std.testing.expectEqualStrings("ontrast (Type Value)...", chunks2[3].slice);
    try std.testing.expect(!chunks2[3].is_matched);
}

test "partitionHighlightedText edge cases" {
    // Empty text
    const empty_chunks = try partitionHighlightedText(std.testing.allocator, "", &[_]usize{0});
    try std.testing.expectEqual(@as(usize, 0), empty_chunks.len);

    // Empty matches
    const no_match_chunks = try partitionHighlightedText(std.testing.allocator, "text", &[_]usize{});
    defer std.testing.allocator.free(no_match_chunks);
    try std.testing.expectEqual(@as(usize, 1), no_match_chunks.len);
    try std.testing.expectEqualStrings("text", no_match_chunks[0].slice);
    try std.testing.expect(!no_match_chunks[0].is_matched);

    // Out-of-bounds matches (should be ignored gracefully)
    const oob_chunks = try partitionHighlightedText(std.testing.allocator, "abc", &[_]usize{ 0, 5, 10 });
    defer std.testing.allocator.free(oob_chunks);
    try std.testing.expectEqual(@as(usize, 2), oob_chunks.len);
    try std.testing.expectEqualStrings("a", oob_chunks[0].slice);
    try std.testing.expect(oob_chunks[0].is_matched);
    try std.testing.expectEqualStrings("bc", oob_chunks[1].slice);
    try std.testing.expect(!oob_chunks[1].is_matched);

    // Internal whitespace should NOT be stripped
    const internal_ws_chunks = try partitionHighlightedText(std.testing.allocator, "a  b", &[_]usize{ 0, 1, 2, 3 });
    defer std.testing.allocator.free(internal_ws_chunks);
    try std.testing.expectEqual(@as(usize, 1), internal_ws_chunks.len);
    try std.testing.expectEqualStrings("a  b", internal_ws_chunks[0].slice);
    try std.testing.expect(internal_ws_chunks[0].is_matched);

    // Leading and trailing whitespace should be stripped
    const edge_ws_chunks = try partitionHighlightedText(std.testing.allocator, " a ", &[_]usize{ 0, 1, 2 });
    defer std.testing.allocator.free(edge_ws_chunks);
    try std.testing.expectEqual(@as(usize, 3), edge_ws_chunks.len);
    try std.testing.expectEqualStrings(" ", edge_ws_chunks[0].slice);
    try std.testing.expect(!edge_ws_chunks[0].is_matched);
    try std.testing.expectEqualStrings("a", edge_ws_chunks[1].slice);
    try std.testing.expect(edge_ws_chunks[1].is_matched);
    try std.testing.expectEqualStrings(" ", edge_ws_chunks[2].slice);
    try std.testing.expect(!edge_ws_chunks[2].is_matched);
}

test "PaletteState directory_navigator mode configuration and item matching" {
    var palette = PaletteState.init(std.testing.allocator);
    defer palette.deinit();

    palette.mode = .directory_navigator;
    try palette.current_nav_dir.appendSlice(std.testing.allocator, "/home/user/Pictures");

    try palette.dir_items.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, ".."),
        .full_path = try std.testing.allocator.dupe(u8, "/home/user"),
        .kind = .parent,
    });
    try palette.dir_items.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "Vacation"),
        .full_path = try std.testing.allocator.dupe(u8, "/home/user/Pictures/Vacation"),
        .kind = .{ .directory = .{ .image_count = 12 } },
    });

    try palette.rebuildDirectoryMatches();
    try std.testing.expectEqual(@as(usize, 2), palette.matches.items.len);

    try palette.query.appendSlice(std.testing.allocator, "Vac");
    try palette.rebuildDirectoryMatches();
    try std.testing.expectEqual(@as(usize, 2), palette.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), palette.matches.items[0]);
}

test "getPaletteConfig metadata lookup helper" {
    const files_cfg = getPaletteConfig(.files);
    try std.testing.expectEqualStrings("Search Files", files_cfg.title);
    try std.testing.expectEqualStrings("CommandPalette", files_cfg.element_id);

    const actions_cfg = getPaletteConfig(.actions);
    try std.testing.expectEqualStrings("Command Palette", actions_cfg.title);
    try std.testing.expectEqualStrings("ActionPalette", actions_cfg.element_id);

    const bright_cfg = getPaletteConfig(.set_brightness);
    try std.testing.expectEqualStrings("Set Brightness", bright_cfg.title);

    const contrast_cfg = getPaletteConfig(.set_contrast);
    try std.testing.expectEqualStrings("Set Contrast", contrast_cfg.title);

    const goto_cfg = getPaletteConfig(.go_to_image);
    try std.testing.expectEqualStrings("Go to Image", goto_cfg.title);

    const dir_cfg = getPaletteConfig(.directory_navigator);
    try std.testing.expectEqualStrings("Directory Navigator", dir_cfg.title);

    const slide_cfg = getPaletteConfig(.set_slideshow_interval);
    try std.testing.expectEqualStrings("Start Slide Show", slide_cfg.title);
}

test "partitionHighlightedText with middle-truncated remapped matches" {
    const long_text = "DSC_2026_Yosemite_National_Park_High_Resolution_Sunset_Panorama_HDR_Final.jpg";
    // Suppose head_len = 25 ("DSC_2026_Yosemite_National")
    // tail_start_idx = 50 ("Sunset_Panorama_HDR_Final.jpg")
    const head_len: usize = 25;
    const tail_start_idx: usize = 50;
    const display = try std.fmt.allocPrint(std.testing.allocator, "{s}...{s}", .{ long_text[0..head_len], long_text[tail_start_idx..] });
    defer std.testing.allocator.free(display);

    // Matches at index 2 ('C' in DSC), index 57 ('P' in Panorama)
    const matches = [_]usize{ 2, 57 };
    const remapped = try remapMiddleTruncatedMatches(std.testing.allocator, &matches, head_len, tail_start_idx);
    defer std.testing.allocator.free(remapped);

    // remapped should be index 2 and (57 - 50) + 25 + 3 = 35
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 35 }, remapped);

    const chunks = try partitionHighlightedText(std.testing.allocator, display, remapped);
    defer std.testing.allocator.free(chunks);

    try std.testing.expect(chunks.len > 0);
    // Ensure all matches lie within display bounds without warning
    for (remapped) |m_idx| {
        try std.testing.expect(m_idx < display.len);
    }
}

test "partitionHighlightedText multi-byte UTF-8 character boundary safety" {
    // "café" -> 'c' (0), 'a' (1), 'f' (2), 'é' (3..4: 0xC3 0xA9)
    const utf8_text = "café_au_lait.jpg";
    // Match index 3 points to start of 'é' (0xC3)
    const matches = [_]usize{3};

    const chunks = try partitionHighlightedText(std.testing.allocator, utf8_text, &matches);
    defer std.testing.allocator.free(chunks);

    // Chunks should be: "caf" (unmatched), "é" (matched, full 2-byte UTF-8
    // code point), "_au_lait.jpg" (unmatched)
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqualStrings("caf", chunks[0].slice);
    try std.testing.expect(!chunks[0].is_matched);
    try std.testing.expectEqualStrings("é", chunks[1].slice);
    try std.testing.expect(chunks[1].is_matched);
    try std.testing.expectEqualStrings("_au_lait.jpg", chunks[2].slice);
    try std.testing.expect(!chunks[2].is_matched);
}

test "untruncated directory starting with dots preserves matches" {
    const dirname = ".../my_photos";
    const display_dir = dirname; // untruncated (same pointer)
    const dirname_matches = [_]usize{ 0, 1, 2, 4 }; // matches '...', 'm'

    var final_dir_matches = std.ArrayList(usize).empty;
    defer final_dir_matches.deinit(std.testing.allocator);

    if (display_dir.ptr != dirname.ptr and display_dir.len > 0 and std.mem.startsWith(u8, display_dir, "...")) {
        const kept_len = display_dir.len - 3;
        const start_offset = if (dirname.len > kept_len) dirname.len - kept_len else 0;
        for (dirname_matches) |m_idx| {
            if (m_idx >= start_offset) {
                try final_dir_matches.append(std.testing.allocator, (m_idx - start_offset) + 3);
            }
        }
    } else {
        try final_dir_matches.appendSlice(std.testing.allocator, &dirname_matches);
    }

    try std.testing.expectEqualSlices(usize, &dirname_matches, final_dir_matches.items);
}

test "VirtualWindow compute calculations and edge cases" {
    const item_height: f32 = 50.0;
    const viewport_h: f32 = 320.0;
    const gap: f32 = 4.0;

    // Case 1: Empty list
    const w0 = VirtualWindow.compute(0, 0.0, viewport_h, item_height, gap);
    try std.testing.expectEqual(@as(usize, 0), w0.start_idx);
    try std.testing.expectEqual(@as(usize, 0), w0.end_idx);
    try std.testing.expectEqual(@as(f32, 0.0), w0.top_spacer_h);
    try std.testing.expectEqual(@as(f32, 0.0), w0.bottom_spacer_h);

    // Case 2: At top of 100-item list (scroll = 0)
    // visible top = 0, visible bottom = 320.
    // floor(0/50) = 0, ceil(320/50) = 7.
    // overscan: start = 0, end = 8.
    const w1 = VirtualWindow.compute(100, 0.0, viewport_h, item_height, gap);
    try std.testing.expectEqual(@as(usize, 0), w1.start_idx);
    try std.testing.expectEqual(@as(usize, 8), w1.end_idx);
    try std.testing.expectEqual(@as(f32, 0.0), w1.top_spacer_h);
    // bottom spacer = (100 - 8) * 50 - 4 = 4600 - 4 = 4596
    try std.testing.expectEqual(@as(f32, 4596.0), w1.bottom_spacer_h);

    // Case 3: Middle of list (scroll = -500.0, 10 items scrolled off-screen)
    // visible top = 500, visible bottom = 820.
    // floor(500/50) = 10, ceil(820/50) = 17.
    // overscan: start = 9, end = 18.
    const w2 = VirtualWindow.compute(100, -500.0, viewport_h, item_height, gap);
    try std.testing.expectEqual(@as(usize, 9), w2.start_idx);
    try std.testing.expectEqual(@as(usize, 18), w2.end_idx);
    // top spacer = 9 * 50 - 4 = 446.0
    try std.testing.expectEqual(@as(f32, 446.0), w2.top_spacer_h);
    // bottom spacer = (100 - 18) * 50 - 4 = 82 * 50 - 4 = 4096.0
    try std.testing.expectEqual(@as(f32, 4096.0), w2.bottom_spacer_h);
}
