const std = @import("std");
const clay = @import("zclay");
const main = @import("../main.zig");
const c = main.c;
const app_state = @import("../app/state.zig");
const ViewerState = app_state.ViewerState;
const PaletteState = app_state.PaletteState;
const stopTextInput = app_state.stopTextInput;
const app_actions = @import("../commands/actions.zig").app_actions;
const getActionMetadata = @import("../commands/actions.zig").getActionMetadata;
const MeasureTextUserData = main.MeasureTextUserData;
const sdl3MeasureText = main.sdl3MeasureText;

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
    clay.UI()(.{
        .id = clay.getElementId(cfg.element_id),
        .layout = .{
            .sizing = .{ .w = .fixed(550 * scale_x), .h = .fit },
            .direction = .top_to_bottom,
            .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 },
            .child_gap = 10,
        },
        .background_color = .{ 30, 30, 46, 245 }, // Catppuccin Base with opacity
        .corner_radius = .all(10),
        .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = .{ 79, 79, 97, 255 } },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .center_center, .parent = .center_center },
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
                    .files => clay.Color{ 245, 194, 231, 255 }, // Catppuccin Pink
                    .actions => clay.Color{ 137, 180, 250, 255 }, // Catppuccin Blue
                    .set_brightness, .set_contrast => clay.Color{ 250, 179, 135, 255 }, // Catppuccin Peach
                    .go_to_image => clay.Color{ 166, 227, 161, 255 }, // Catppuccin Green
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
                .padding = .{ .left = 12, .right = 12 },
            },
            .background_color = .{ 17, 17, 27, 255 }, // Catppuccin Crust (input background)
            .corner_radius = .all(6),
            .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = .{ 137, 180, 250, 255 } }, // Blue active border
        })({
            const query_str = if (palette.query.items.len > 0) palette.query.items else cfg.placeholder;
            const query_color = if (palette.query.items.len > 0) clay.Color{ 205, 214, 244, 255 } else clay.Color{ 108, 112, 134, 255 };
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
                .background_color = .{ 17, 17, 27, 255 }, // Catppuccin Crust
                .corner_radius = .all(6),
            })({
                const raw_str = palette.query.items;
                const total_count = state.image_list.items.len;
                if (palette.mode == .go_to_image) {
                    if (total_count == 0) {
                        clay.text("No images loaded.", .{
                            .color = .{ 243, 139, 168, 255 }, // Red
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else if (raw_str.len == 0) {
                        clay.text("Enter image number, then press Enter to apply.", .{
                            .color = .{ 166, 173, 200, 255 },
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                        const range_str = try std.fmt.allocPrint(frame_allocator, "Allowed range: 1 to {} (current: {})", .{ total_count, (state.current_index orelse 0) + 1 });
                        clay.text(range_str, .{
                            .color = .{ 108, 112, 134, 255 }, // Subtext
                            .font_size = @intFromFloat(11.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else {
                        const parsed_val_opt = std.fmt.parseInt(usize, raw_str, 10) catch null;
                        if (parsed_val_opt) |val| {
                            if (val >= 1 and val <= total_count) {
                                const target_path = state.image_list.items[val - 1];
                                const raw_basename = std.fs.path.basename(target_path);
                                const display_filename = truncateFilename(frame_allocator, raw_basename, 492.0 * scale_x, @intFromFloat(12.0 * dpi_scale), measure_data);
                                const success_str = try std.fmt.allocPrint(frame_allocator, "Press Enter to go to {}: {s}", .{ val, display_filename });
                                clay.text(success_str, .{
                                    .color = .{ 166, 227, 161, 255 }, // Green
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            } else {
                                const err_str = try std.fmt.allocPrint(frame_allocator, "Out of bounds: must be between 1 and {}", .{total_count});
                                clay.text(err_str, .{
                                    .color = .{ 243, 139, 168, 255 }, // Red
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            }
                        } else {
                            clay.text("Invalid number format. Enter a positive integer.", .{
                                .color = .{ 243, 139, 168, 255 }, // Red
                                .font_size = @intFromFloat(13.0 * dpi_scale),
                                .font_id = 0,
                            });
                        }
                    }
                } else {
                    if (raw_str.len == 0) {
                        clay.text("Enter a number, then press Enter to apply.", .{
                            .color = .{ 166, 173, 200, 255 },
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                        const range_str = if (palette.mode == .set_brightness) "Allowed range: -1.0 to 1.0 (default: 0.0)" else "Allowed range: 0.0 to 5.0 (default: 1.0)";
                        clay.text(range_str, .{
                            .color = .{ 108, 112, 134, 255 }, // Subtext
                            .font_size = @intFromFloat(11.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else {
                        const parsed_val_opt = std.fmt.parseFloat(f32, raw_str) catch null;
                        if (parsed_val_opt) |val| {
                            const min_val: f32 = if (palette.mode == .set_brightness) -1.0 else 0.0;
                            const max_val: f32 = if (palette.mode == .set_brightness) 1.0 else 5.0;
                            if (val >= min_val and val <= max_val) {
                                const success_str = try std.fmt.allocPrint(frame_allocator, "Press Enter to set value to: {d:.2}", .{val});
                                clay.text(success_str, .{
                                    .color = .{ 166, 227, 161, 255 }, // Green
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            } else {
                                const err_str = try std.fmt.allocPrint(frame_allocator, "Out of bounds: must be between {d:.1} and {d:.1}", .{ min_val, max_val });
                                clay.text(err_str, .{
                                    .color = .{ 243, 139, 168, 255 }, // Red
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            }
                        } else {
                            clay.text("Invalid float format. Enter a number.", .{
                                .color = .{ 243, 139, 168, 255 }, // Red
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
                            clay.Color{ 49, 50, 68, 255 } // Catppuccin Surface0
                        else if (item_hovered)
                            clay.Color{ 30, 30, 46, 255 } // Catppuccin Base (lighter hover)
                        else
                            clay.Color{ 0, 0, 0, 0 },
                        .corner_radius = .all(6),
                    })({
                        switch (palette.mode) {
                            .files => {
                                const path = state.image_list.items[real_idx];
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
                                            .background_color = if (is_selected) .{ 137, 180, 250, 255 } else .{ 108, 112, 134, 255 },
                                            .corner_radius = .all(3),
                                        })({});

                                        // Filename
                                        clay.text(display_filename, .{
                                            .color = if (is_selected) .{ 137, 180, 250, 255 } else .{ 205, 214, 244, 255 },
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
                                            .color = .{ 166, 173, 200, 255 }, // Subtext
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
                                        .color = if (is_selected) clay.Color{ 137, 180, 250, 255 } else clay.Color{ 205, 214, 244, 255 },
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
                                        .background_color = .{ 17, 17, 27, 255 }, // Catppuccin Crust
                                        .corner_radius = .all(4),
                                        .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = .{ 49, 50, 68, 255 } },
                                    })({
                                        clay.text(meta.shortcut_text, .{
                                            .color = .{ 166, 173, 200, 255 },
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
                            .color = .{ 108, 112, 134, 255 },
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                }
            });
        }
    });
}

pub fn truncateFilename(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) []const u8 {
    const font = data.fonts[0] orelse return text;
    const target_size = @as(f32, @floatFromInt(font_size));
    if (c.TTF_GetFontSize(font) != target_size) {
        _ = c.TTF_SetFontSize(font, target_size);
    }

    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.TTF_GetStringSize(font, text.ptr, text.len, &w, &h)) {
        return text;
    }
    if (@as(f32, @floatFromInt(w)) <= max_w) {
        return text;
    }

    var dots_w: c_int = 0;
    var dots_h: c_int = 0;
    _ = c.TTF_GetStringSize(font, "...", 3, &dots_w, &dots_h);

    const available_w = max_w - @as(f32, @floatFromInt(dots_w));
    if (available_w <= 0) return "...";

    var measured_w: c_int = 0;
    var measured_len: usize = 0;
    if (c.TTF_MeasureString(font, text.ptr, text.len, @intFromFloat(available_w), &measured_w, &measured_len)) {
        var best_len = measured_len;
        while (best_len > 0 and best_len < text.len and (text[best_len] & 0xC0) == 0x80) {
            best_len -= 1;
        }
        return std.fmt.allocPrint(allocator, "{s}...", .{text[0..best_len]}) catch text;
    }
    return text;
}

pub fn truncateDirectory(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) []const u8 {
    var text_config = clay.TextElementConfig{
        .font_id = 0,
        .font_size = font_size,
    };

    const initial_dim = sdl3MeasureText(text, &text_config, data);
    if (initial_dim.w <= max_w) {
        return text;
    }

    const dots_w = sdl3MeasureText("...", &text_config, data).w;

    var low: usize = 0;
    var high: usize = text.len;
    var best_len: usize = 0;

    while (low <= high) {
        const mid = (low + high) / 2;
        const start_idx = text.len - mid;
        // Verify UTF-8 boundary
        var byte_start = start_idx;
        while (byte_start < text.len and (text[byte_start] & 0xC0) == 0x80) {
            byte_start += 1;
        }

        const part_w = sdl3MeasureText(text[byte_start..], &text_config, data).w;

        if (part_w + dots_w <= max_w) {
            best_len = text.len - byte_start;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }

    return std.fmt.allocPrint(allocator, "...{s}", .{text[text.len - best_len ..]}) catch text;
}

pub fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    const mb = kb / 1024.0;
    return std.fmt.allocPrint(allocator, "{d:.1} MB", .{mb});
}
