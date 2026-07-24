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
const truncateDirectory = text_utils.truncateDirectory;
const formatSize = text_utils.formatSize;
const theme = @import("theme.zig");

pub fn renderPalette(
    state: *ViewerState,
    scale_x: f32,
    scale_y: f32,
    dpi_scale: f32,
    mouse_clicked: bool,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const palette = &state.palette;
    if (palette.mode == .inactive) return;

    const PaletteConfig = struct {
        title: []const u8,
        placeholder: []const u8,
        element_id: []const u8,
        list_id: []const u8,
        item_prefix: []const u8,
        top_spacer_id: []const u8,
        bottom_spacer_id: []const u8,
        base_item_height: f32,
    };

    const cfg = switch (palette.mode) {
        .files => PaletteConfig{
            .title = "Search Files",
            .placeholder = "Type file name to search...",
            .element_id = "CommandPalette",
            .list_id = "CommandPaletteList",
            .item_prefix = "PaletteItem_",
            .top_spacer_id = "PaletteTopSpacer",
            .bottom_spacer_id = "PaletteBottomSpacer",
            .base_item_height = 58.0,
        },
        .actions => PaletteConfig{
            .title = "Command Palette",
            .placeholder = "Type a command to run...",
            .element_id = "ActionPalette",
            .list_id = "ActionPaletteList",
            .item_prefix = "ActionItem_",
            .top_spacer_id = "ActionTopSpacer",
            .bottom_spacer_id = "ActionBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_brightness => PaletteConfig{
            .title = "Set Brightness",
            .placeholder = "Enter brightness (-1.0 to 1.0, e.g. 0.2)...",
            .element_id = "BrightnessPalette",
            .list_id = "BrightnessPaletteList",
            .item_prefix = "BrightnessItem_",
            .top_spacer_id = "BrightnessTopSpacer",
            .bottom_spacer_id = "BrightnessBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_contrast => PaletteConfig{
            .title = "Set Contrast",
            .placeholder = "Enter contrast (0.0 to 5.0, e.g. 1.5)...",
            .element_id = "ContrastPalette",
            .list_id = "ContrastPaletteList",
            .item_prefix = "ContrastItem_",
            .top_spacer_id = "ContrastTopSpacer",
            .bottom_spacer_id = "ContrastBottomSpacer",
            .base_item_height = 50.0,
        },
        .go_to_image => PaletteConfig{
            .title = "Go to Image",
            .placeholder = "Enter image number...",
            .element_id = "GoToImagePalette",
            .list_id = "GoToImageList",
            .item_prefix = "GoToImageItem_",
            .top_spacer_id = "GoToImageTopSpacer",
            .bottom_spacer_id = "GoToImageBottomSpacer",
            .base_item_height = 50.0,
        },
        .inactive => unreachable,
    };

    // Render Floating Card container
    const scale = DpiScale.init(dpi_scale);
    clay.UI()(.{
        .id = clay.getElementId(cfg.element_id),
        .layout = .{
            .sizing = .{ .w = .fixed(550 * scale_x), .h = .fit },
            .direction = .top_to_bottom,
            .padding = layout_helpers.scalePadding(12, 12, 12, 12, scale),
            .child_gap = @intFromFloat(10 * dpi_scale),
        },
        .background_color = theme.base_translucent, // Catppuccin Base with opacity
        .corner_radius = layout_helpers.scaleCornerRadius(10, scale),
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
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
            },
        })({
            clay.text(cfg.title, .{
                .color = switch (palette.mode) {
                    .files => theme.pink, // Catppuccin Pink
                    .actions => theme.blue, // Catppuccin Blue
                    .set_brightness, .set_contrast => theme.peach, // Catppuccin Peach
                    .go_to_image => theme.green, // Catppuccin Green
                    .inactive => unreachable,
                },
                .font_size = @intFromFloat(13.0 * dpi_scale),
                .font_id = 0,
            });
        });

        // Search Input Box
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(38 * scale_y) },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
                .padding = layout_helpers.scalePadding(0, 0, 12, 12, scale),
            },
            .background_color = theme.crust, // Catppuccin Crust (input background)
            .corner_radius = layout_helpers.scaleCornerRadius(6, scale),
            .border = .{
                .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                .color = theme.blue,
            }, // Blue active border
        })({
            const query_str = if (palette.query.items.len > 0) palette.query.items else cfg.placeholder;
            const query_color = if (palette.query.items.len > 0) theme.text else theme.subtext1;
            clay.text(query_str, .{
                .color = query_color,
                .font_size = @intFromFloat(14.0 * dpi_scale),
                .font_id = 0,
            });
        });

        if (palette.mode == .set_brightness or palette.mode == .set_contrast or palette.mode == .go_to_image) {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(64 * scale_y) },
                    .direction = .top_to_bottom,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 },
                    .child_gap = 6,
                },
                .background_color = theme.crust, // Catppuccin Crust
                .corner_radius = .all(6),
            })({
                const raw_str = palette.query.items;
                state.lockImageList();
                const total_count = state.image_list.items.len;
                state.unlockImageList();
                if (palette.mode == .go_to_image) {
                    if (total_count == 0) {
                        clay.text("No images loaded.", .{
                            .color = theme.red, // Red
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else if (raw_str.len == 0) {
                        clay.text("Enter image number, then press Enter to apply.", .{
                            .color = theme.subtext0,
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                        const range_str = try std.fmt.allocPrint(frame_allocator, "Allowed range: 1 to {} (current: {})", .{ total_count, (state.current_index orelse 0) + 1 });
                        clay.text(range_str, .{
                            .color = theme.subtext1, // Subtext
                            .font_size = @intFromFloat(11.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else {
                        const parsed_val_opt = std.fmt.parseInt(usize, raw_str, 10) catch null;
                        if (parsed_val_opt) |val| {
                            if (val >= 1 and val <= total_count) {
                                state.lockImageList();
                                const target_path = if (val - 1 < state.image_list.items.len) state.image_list.items[val - 1] else "";
                                state.unlockImageList();
                                const raw_basename = std.fs.path.basename(target_path);
                                const display_filename = truncateFilename(frame_allocator, raw_basename, 492.0 * scale_x, @intFromFloat(12.0 * dpi_scale), measure_data);
                                const success_str = try std.fmt.allocPrint(frame_allocator, "Press Enter to go to {}: {s}", .{ val, display_filename });
                                clay.text(success_str, .{
                                    .color = theme.green, // Green
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            } else {
                                const err_str = try std.fmt.allocPrint(frame_allocator, "Out of bounds: must be between 1 and {}", .{total_count});
                                clay.text(err_str, .{
                                    .color = theme.red, // Red
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            }
                        } else {
                            clay.text("Invalid number format. Enter a positive integer.", .{
                                .color = theme.red, // Red
                                .font_size = @intFromFloat(13.0 * dpi_scale),
                                .font_id = 0,
                            });
                        }
                    }
                } else {
                    if (raw_str.len == 0) {
                        clay.text("Enter a number, then press Enter to apply.", .{
                            .color = theme.subtext0,
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                        const range_str = if (palette.mode == .set_brightness) "Allowed range: -1.0 to 1.0 (default: 0.0)" else "Allowed range: 0.0 to 5.0 (default: 1.0)";
                        clay.text(range_str, .{
                            .color = theme.subtext1, // Subtext
                            .font_size = @intFromFloat(11.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else {
                        const parsed_val_opt = std.fmt.parseFloat(f32, raw_str) catch null;
                        var is_valid_float = false;
                        if (parsed_val_opt) |val| {
                            if (!std.math.isNan(val) and !std.math.isInf(val)) {
                                is_valid_float = true;
                                const min_val: f32 = if (palette.mode == .set_brightness) -1.0 else 0.0;
                                const max_val: f32 = if (palette.mode == .set_brightness) 1.0 else 5.0;
                                if (val >= min_val and val <= max_val) {
                                    const success_str = try std.fmt.allocPrint(frame_allocator, "Press Enter to set value to: {d:.2}", .{val});
                                    clay.text(success_str, .{
                                        .color = theme.green, // Green
                                        .font_size = @intFromFloat(13.0 * dpi_scale),
                                        .font_id = 0,
                                    });
                                } else {
                                    const err_str = try std.fmt.allocPrint(frame_allocator, "Out of bounds: must be between {d:.1} and {d:.1}", .{ min_val, max_val });
                                    clay.text(err_str, .{
                                        .color = theme.red, // Red
                                        .font_size = @intFromFloat(13.0 * dpi_scale),
                                        .font_id = 0,
                                    });
                                }
                            }
                        }
                        if (!is_valid_float) {
                            clay.text("Invalid float format. Enter a number.", .{
                                .color = theme.red, // Red
                                .font_size = @intFromFloat(13.0 * dpi_scale),
                                .font_id = 0,
                            });
                        }
                    }
                }
            });
        } else {
            // Results list scroll container
            const scroll_data = clay.cdefs.Clay_GetScrollContainerData(clay.getElementId(cfg.list_id));
            var scroll_offset = if (scroll_data.found) scroll_data.scroll_position.* else clay.Vector2{ .x = 0, .y = 0 };

            // Auto-scroll logic during keyboard navigation
            const item_height = cfg.base_item_height * scale_y;
            const viewport_height = 320.0 * scale_y;

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

            clay.UI()(.{
                .id = clay.getElementId(cfg.list_id),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(320 * scale_y) },
                    .direction = .top_to_bottom,
                    .child_gap = @intFromFloat(4 * scale_y),
                },
                .clip = .{
                    .horizontal = false,
                    .vertical = true,
                    .child_offset = scroll_offset,
                },
            })({
                const visible_top = -scroll_offset.y;
                const visible_bottom = visible_top + viewport_height;

                var start_visible_idx = @as(usize, @intFromFloat(@max(0.0, @floor(visible_top / item_height))));
                var end_visible_idx = @as(usize, @intFromFloat(@max(0.0, @ceil(visible_bottom / item_height))));

                start_visible_idx = if (start_visible_idx > 0) start_visible_idx - 1 else 0;
                end_visible_idx = end_visible_idx + 1;

                if (end_visible_idx > matching_indices.items.len) {
                    end_visible_idx = matching_indices.items.len;
                }
                if (start_visible_idx > end_visible_idx) {
                    start_visible_idx = end_visible_idx;
                }

                const gap = 4.0 * scale_y;
                const top_spacer_h = if (start_visible_idx > 0)
                    @as(f32, @floatFromInt(start_visible_idx)) * item_height - gap
                else
                    0.0;
                const bottom_spacer_h = if (matching_indices.items.len - end_visible_idx > 0)
                    @as(f32, @floatFromInt(matching_indices.items.len - end_visible_idx)) * item_height - gap
                else
                    0.0;

                // Render Top Spacer if needed
                if (top_spacer_h > 0) {
                    clay.UI()(.{
                        .id = clay.getElementId(cfg.top_spacer_id),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(top_spacer_h) } },
                    })({});
                }

                // Render visible items
                var match_count = start_visible_idx;
                for (matching_indices.items[start_visible_idx..end_visible_idx]) |real_idx| {
                    const is_selected = (match_count == palette.selected_idx);

                    var item_id_buf: [64]u8 = undefined;
                    const item_id_str = std.fmt.bufPrint(&item_id_buf, "{s}{}", .{ cfg.item_prefix, real_idx }) catch cfg.item_prefix;
                    const item_id = clay.getElementId(item_id_str);
                    const item_hovered = clay.pointerOver(item_id);

                    // Item Container
                    clay.UI()(.{
                        .id = item_id,
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fixed(switch (palette.mode) {
                                .files => 54 * scale_y,
                                .actions => 46 * scale_y,
                                else => 0.0,
                            }) },
                            .direction = .left_to_right,
                            .child_alignment = .{ .x = .left, .y = .center },
                            .padding = .{ .left = 12, .right = 12 },
                        },
                        .background_color = if (is_selected)
                            theme.surface0 // Catppuccin Surface0
                        else if (item_hovered)
                            theme.base // Catppuccin Base (lighter hover)
                        else
                            clay.Color{ 0, 0, 0, 0 },
                        .corner_radius = .all(6),
                    })({
                        switch (palette.mode) {
                            .files => {
                                state.lockImageList();
                                const path = if (real_idx < state.image_list.items.len) state.image_list.items[real_idx] else "";
                                state.unlockImageList();
                                const display_filename = truncateFilename(frame_allocator, std.fs.path.basename(path), 492.0 * scale_x, @intFromFloat(13.0 * dpi_scale), measure_data);
                                const display_dir = truncateDirectory(frame_allocator, std.fs.path.dirname(path) orelse ".", 488.0 * scale_x, @intFromFloat(11.0 * dpi_scale), measure_data);

                                clay.UI()(.{
                                    .layout = .{
                                        .sizing = .{ .w = .grow, .h = .fit },
                                        .direction = .top_to_bottom,
                                        .child_gap = 2,
                                    },
                                })({
                                    // Row 1: Category Pill + Filename
                                    clay.UI()(.{
                                        .layout = .{
                                            .sizing = .{ .w = .grow, .h = .fit },
                                            .direction = .left_to_right,
                                            .child_alignment = .{ .x = .left, .y = .center },
                                            .child_gap = 6,
                                        },
                                    })({
                                        // Small colored indicator tag representing category / type
                                        clay.UI()(.{
                                            .layout = .{
                                                .sizing = .{ .w = .fixed(4 * scale_x), .h = .fixed(12 * scale_y) },
                                            },
                                            .background_color = if (is_selected) theme.blue else theme.subtext1,
                                            .corner_radius = .all(3),
                                        })({});

                                        // Filename
                                        clay.text(display_filename, .{
                                            .color = if (is_selected) theme.blue else theme.text,
                                            .font_size = @intFromFloat(13.0 * dpi_scale),
                                            .font_id = 0,
                                        });
                                    });

                                    // Row 2: Parent folder path (indented slightly for alignment with filename)
                                    clay.UI()(.{
                                        .layout = .{
                                            .sizing = .{ .w = .grow, .h = .fit },
                                            .direction = .left_to_right,
                                            .padding = .{ .left = 14 },
                                        },
                                    })({
                                        clay.text(display_dir, .{
                                            .color = theme.subtext0, // Subtext
                                            .font_size = @intFromFloat(11.0 * dpi_scale),
                                            .font_id = 0,
                                        });
                                    });
                                });
                            },
                            .actions => {
                                const action_id = app_actions[real_idx];
                                const meta = getActionMetadata(action_id);

                                // Action Name (Left aligned)
                                clay.UI()(.{
                                    .layout = .{
                                        .sizing = .{ .w = .grow, .h = .fit },
                                    },
                                })({
                                    clay.text(meta.name, .{
                                        .color = if (is_selected) theme.blue else theme.text,
                                        .font_size = @intFromFloat(13.0 * dpi_scale),
                                        .font_id = 0,
                                    });
                                });

                                // Keyboard Shortcut (Right aligned)
                                if (meta.shortcut_text.len > 0) {
                                    clay.UI()(.{
                                        .layout = .{
                                            .sizing = .{ .w = .fit, .h = .fit },
                                            .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                                        },
                                        .background_color = theme.crust, // Catppuccin Crust
                                        .corner_radius = .all(4),
                                        .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = theme.surface0 },
                                    })({
                                        clay.text(meta.shortcut_text, .{
                                            .color = theme.subtext0,
                                            .font_size = @intFromFloat(11.0 * dpi_scale),
                                            .font_id = 0,
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
                            else => {},
                        }
                    }

                    match_count += 1;
                }

                // Render Bottom Spacer if needed
                if (bottom_spacer_h > 0) {
                    clay.UI()(.{
                        .id = clay.getElementId(cfg.bottom_spacer_id),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(bottom_spacer_h) } },
                    })({});
                }

                if (matching_indices.items.len == 0) {
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fixed(36 * scale_y) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                    })({
                        const no_match_msg = switch (palette.mode) {
                            .files => "No matching files found",
                            .actions => "No matching commands found",
                            else => "",
                        };
                        clay.text(no_match_msg, .{
                            .color = theme.subtext1,
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                }
            });
        }
    });
}
