const std = @import("std");
pub const clay = @import("zclay");
const renderer = @import("renderer.zig");
const commands = @import("commands.zig");
const app_config = @import("config.zig");
const app = @import("app.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_gpu.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
    @cInclude("SDL3_image/SDL_image.h");
});

pub const vert_spv = @embedFile("shaders/vert.spv");
pub const frag_spv = @embedFile("shaders/frag.spv");

const MeasureTextUserData = struct {
    text_engine: ?*c.TTF_TextEngine,
    fonts: []const ?*c.TTF_Font,
    allocator: std.mem.Allocator,
};

pub const FrameInput = struct {
    win_w: f32,
    win_h: f32,
    pix_w: f32,
    pix_h: f32,
    scale_x: f32,
    scale_y: f32,
    dpi_scale: f32,

    mouse_x: f32,
    mouse_y: f32,
    mouse_left_down: bool,
    mouse_left_clicked: bool,
    mouse_inside: bool,
    scroll_delta_x: f32,
    scroll_delta_y: f32,

    keys_pressed: std.ArrayList(c.SDL_Keycode),
    key_modifiers: c.SDL_Keymod,
    text_input: ?[]const u8,
    dropped_path: ?[]const u8,

    ticks: u64,
    delta_time_ms: f32,
};

fn sdl3MeasureText(text: []const u8, config: *clay.TextElementConfig, data: *const MeasureTextUserData) clay.Dimensions {
    if (config.font_id >= data.fonts.len) return .{ .w = 0, .h = 0 };
    const font = data.fonts[config.font_id] orelse return .{ .w = 0, .h = 0 };
    const target_size = @as(f32, @floatFromInt(config.font_size));
    if (c.TTF_GetFontSize(font) != target_size) {
        if (!c.TTF_SetFontSize(font, target_size)) {
            std.log.err("TTF_SetFontSize failed: {s}", .{c.SDL_GetError()});
        }
    }

    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.TTF_GetStringSize(font, text.ptr, text.len, &w, &h)) {
        return .{ .w = 0, .h = 0 };
    }

    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

pub const eqlIgnoreCase = app.state.eqlIgnoreCase;
pub const isImageExtension = app.state.isImageExtension;
pub const scanDirectory = app.state.scanDirectory;
pub const detectMimeType = app.state.detectMimeType;

fn renderStatRow(label: []const u8, value: []const u8, scale_x: f32, scale_y: f32, dpi_scale: f32) !void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(20 * scale_y) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(110 * scale_x), .h = .grow } } })({
            clay.text(label, .{
                .color = .{ 166, 173, 200, 255 }, // Subtext0
                .font_size = @intFromFloat(13.0 * dpi_scale),
                .font_id = 0,
            });
        });

        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({
            clay.text(value, .{
                .color = .{ 205, 214, 244, 255 }, // Text
                .font_size = @intFromFloat(13.0 * dpi_scale),
                .font_id = 0,
            });
        });
    });
}

pub const CacheEntry = app.state.CacheEntry;
pub const DecodeArgs = app.state.DecodeArgs;
pub const decodeWorker = app.state.decodeWorker;
pub const matchesQueryLower = app.state.matchesQueryLower;
pub const startTextInput = app.state.startTextInput;
pub const stopTextInput = app.state.stopTextInput;

pub const AppActionId = commands.actions.AppActionId;
pub const KeyboardShortcut = commands.actions.KeyboardShortcut;
pub const ActionMetadata = commands.actions.ActionMetadata;
pub const getActionMetadata = commands.actions.getActionMetadata;
pub const app_actions = commands.actions.app_actions;
pub const FlatShortcut = commands.actions.FlatShortcut;
pub const flat_shortcuts = commands.actions.flat_shortcuts;

pub const PaletteType = app.state.PaletteType;
pub const PaletteState = app.state.PaletteState;
pub const ScaleMode = app.state.ScaleMode;
pub const TextureScaleMode = app.state.TextureScaleMode;
pub const ElementTag = app.state.ElementTag;
pub const ViewerState = app.state.ViewerState;

fn getSdlScaleMode(self: *ViewerState) c.SDL_ScaleMode {
    return switch (self.texture_scale_mode) {
        .nearest => c.SDL_SCALEMODE_NEAREST,
        .linear => c.SDL_SCALEMODE_LINEAR,
        .pixel_art => c.SDL_SCALEMODE_PIXELART,
        .mitchell, .lanczos3 => c.SDL_SCALEMODE_NEAREST,
    };
}

fn renderPalette(
    state: *ViewerState,
    scale_x: f32,
    scale_y: f32,
    dpi_scale: f32,
    mouse_clicked: bool,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const palette = &state.palette;
    if (!palette.show) return;

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

    const cfg = switch (palette.active_type) {
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
                .color = switch (palette.active_type) {
                    .files => clay.Color{ 245, 194, 231, 255 }, // Catppuccin Pink
                    .actions => clay.Color{ 137, 180, 250, 255 }, // Catppuccin Blue
                    .set_brightness, .set_contrast => clay.Color{ 250, 179, 135, 255 }, // Catppuccin Peach
                    .go_to_image => clay.Color{ 166, 227, 161, 255 }, // Catppuccin Green
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

        if (palette.active_type == .set_brightness or palette.active_type == .set_contrast or palette.active_type == .go_to_image) {
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
                if (palette.active_type == .go_to_image) {
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
                        const range_str = if (palette.active_type == .set_brightness) "Allowed range: -1.0 to 1.0 (default: 0.0)" else "Allowed range: 0.0 to 5.0 (default: 1.0)";
                        clay.text(range_str, .{
                            .color = .{ 108, 112, 134, 255 }, // Subtext
                            .font_size = @intFromFloat(11.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else {
                        const parsed_val_opt = std.fmt.parseFloat(f32, raw_str) catch null;
                        if (parsed_val_opt) |val| {
                            const min_val: f32 = if (palette.active_type == .set_brightness) -1.0 else 0.0;
                            const max_val: f32 = if (palette.active_type == .set_brightness) 1.0 else 5.0;
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
                            clay.text("Invalid number format. Use digits and decimal point (e.g. 0.5 or -0.2).", .{
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

            const matching_indices = palette.matches;

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

                const top_spacer_h = @as(f32, @floatFromInt(start_visible_idx)) * item_height;
                const bottom_spacer_h = @as(f32, @floatFromInt(matching_indices.items.len - end_visible_idx)) * item_height;

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

                    const item_id_str = try std.fmt.allocPrint(frame_allocator, "{s}{}", .{ cfg.item_prefix, real_idx });

                    const item_hovered = clay.pointerOver(clay.getElementId(item_id_str));

                    // Item Container
                    clay.UI()(.{
                        .id = clay.getElementId(item_id_str),
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fixed(switch (palette.active_type) {
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
                        switch (palette.active_type) {
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
                        const old_type = palette.active_type;
                        switch (palette.active_type) {
                            .files => {
                                state.current_index = real_idx;
                                try state.updateCache();
                                palette.show = false;
                                stopTextInput(state.window);
                            },
                            .actions => {
                                const action_id = app_actions[real_idx];
                                try state.triggerAction(action_id);
                                if (palette.active_type == old_type) {
                                    palette.show = false;
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
                        const no_match_msg = switch (palette.active_type) {
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

fn truncateFilename(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) []const u8 {
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

fn truncateDirectory(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) []const u8 {
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

fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    const mb = kb / 1024.0;
    return std.fmt.allocPrint(allocator, "{d:.1} MB", .{mb});
}

pub const ParsedArgs = app_config.cli.ParsedArgs;
pub const parseCommandLineArgs = app_config.cli.parseCommandLineArgs;

const GraphicsSetup = struct {
    window: *c.SDL_Window,
    gpu_device: *c.SDL_GPUDevice,
    initial_dpi_scale: f32,
};

fn initGraphicsAndWindow(window_title: [:0]const u8, test_mode: bool) !GraphicsSetup {
    _ = test_mode;
    // Initialize SDL3
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) {
        std.log.err("SDL_Init Error: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    errdefer c.SDL_Quit();

    // Initialize SDL3_ttf
    if (!c.TTF_Init()) {
        std.log.err("TTF_Init Error: {s}", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }
    errdefer c.TTF_Quit();

    // Create window
    const window = c.SDL_CreateWindow(window_title.ptr, 1024, 768, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse {
        std.log.err("SDL_CreateWindow Error: {s}", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    // Get scales
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    if (!c.SDL_GetWindowSize(window, &win_w, &win_h)) {
        std.log.err("SDL_GetWindowSize failed: {s}", .{c.SDL_GetError()});
    }
    var pix_w: c_int = 0;
    var pix_h: c_int = 0;
    if (!c.SDL_GetWindowSizeInPixels(window, &pix_w, &pix_h)) {
        std.log.err("SDL_GetWindowSizeInPixels failed: {s}", .{c.SDL_GetError()});
    }
    const initial_dpi_scale = if (win_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;

    // Create GPU Device
    const gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, true, null) orelse {
        std.log.err("SDL_CreateGPUDevice Error: {s}", .{c.SDL_GetError()});
        return error.DeviceCreationFailed;
    };
    errdefer c.SDL_DestroyGPUDevice(gpu_device);

    if (!c.SDL_ClaimWindowForGPUDevice(gpu_device, window)) {
        std.log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
        return error.ClaimWindowFailed;
    }

    return GraphicsSetup{
        .window = window,
        .gpu_device = gpu_device,
        .initial_dpi_scale = initial_dpi_scale,
    };
}

const GpuResources = struct {
    text_engine: *c.TTF_TextEngine,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    white_texture: *c.SDL_GPUTexture,
    fonts: [2]?*c.TTF_Font,
};

fn initGpuResources(gpu_device: *c.SDL_GPUDevice, window: *c.SDL_Window, initial_dpi_scale: f32) !GpuResources {
    // Load Font from Memory using SDL_IOStream (scaled by DPI scale)
    const roboto_font_bytes = @embedFile("resources/Roboto-Regular.ttf");
    const stream = c.SDL_IOFromConstMem(roboto_font_bytes.ptr, roboto_font_bytes.len) orelse {
        std.log.err("SDL_IOFromConstMem Error: {s}", .{c.SDL_GetError()});
        return error.SDLMemIOFailed;
    };
    errdefer _ = c.SDL_CloseIO(stream);
    const font = c.TTF_OpenFontIO(stream, true, 20.0 * initial_dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{c.SDL_GetError()});
        return error.TTFOpenFontFailed;
    };
    errdefer c.TTF_CloseFont(font);

    // Create TTF GPU Text Engine
    const text_engine = c.TTF_CreateGPUTextEngine(gpu_device) orelse {
        std.log.err("TTF_CreateGPUTextEngine Error: {s}", .{c.SDL_GetError()});
        return error.TTFCreateEngineFailed;
    };
    errdefer c.TTF_DestroyGPUTextEngine(text_engine);

    // Re-load font at smaller size for stat rows
    const stream2 = c.SDL_IOFromConstMem(roboto_font_bytes.ptr, roboto_font_bytes.len) orelse {
        std.log.err("SDL_IOFromConstMem Error: {s}", .{c.SDL_GetError()});
        return error.SDLMemIOFailed;
    };
    errdefer _ = c.SDL_CloseIO(stream2);
    const font_small = c.TTF_OpenFontIO(stream2, true, 14.0 * initial_dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{c.SDL_GetError()});
        return error.TTFOpenFontFailed;
    };
    errdefer c.TTF_CloseFont(font_small);

    const fonts = [2]?*c.TTF_Font{ font, font_small };

    // Compile Shaders
    const vert_code = @embedFile("shaders/vert.spv");
    const frag_code = @embedFile("shaders/frag.spv");

    const vert_info = c.SDL_GPUShaderCreateInfo{
        .code_size = vert_code.len,
        .code = vert_code.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
        .num_samplers = 0,
        .num_storage_buffers = 0,
        .num_storage_textures = 0,
        .num_uniform_buffers = 0,
        .props = 0,
    };
    const vert_shader = c.SDL_CreateGPUShader(gpu_device, &vert_info) orelse {
        std.log.err("Failed to create vertex shader: {s}", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(gpu_device, vert_shader);

    const frag_info = c.SDL_GPUShaderCreateInfo{
        .code_size = frag_code.len,
        .code = frag_code.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = 1,
        .num_storage_buffers = 0,
        .num_storage_textures = 0,
        .num_uniform_buffers = 1,
        .props = 0,
    };
    const frag_shader = c.SDL_CreateGPUShader(gpu_device, &frag_info) orelse {
        std.log.err("Failed to create fragment shader: {s}", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(gpu_device, frag_shader);

    // Create sampler
    const sampler_info = c.SDL_GPUSamplerCreateInfo{
        .min_filter = c.SDL_GPU_FILTER_LINEAR,
        .mag_filter = c.SDL_GPU_FILTER_LINEAR,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0.0,
        .max_anisotropy = 1.0,
        .compare_op = c.SDL_GPU_COMPAREOP_NEVER,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .props = 0,
    };
    const sampler = c.SDL_CreateGPUSampler(gpu_device, &sampler_info) orelse {
        std.log.err("Failed to create GPU sampler: {s}", .{c.SDL_GetError()});
        return error.SamplerCreationFailed;
    };
    errdefer c.SDL_ReleaseGPUSampler(gpu_device, sampler);

    // Create 1x1 white texture
    const texture_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
        .width = 1,
        .height = 1,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };
    const white_texture = c.SDL_CreateGPUTexture(gpu_device, &texture_info) orelse {
        std.log.err("Failed to create white texture: {s}", .{c.SDL_GetError()});
        return error.TextureCreationFailed;
    };
    errdefer c.SDL_ReleaseGPUTexture(gpu_device, white_texture);

    // Upload white pixel
    {
        const cmd_buf = c.SDL_AcquireGPUCommandBuffer(gpu_device) orelse return error.CommandBufferAcquisitionFailed;
        const transfer_buf = c.SDL_CreateGPUTransferBuffer(gpu_device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = 4,
            .props = 0,
        }) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            return error.TransferBufferCreationFailed;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(gpu_device, transfer_buf);

        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(gpu_device, transfer_buf, false) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            return error.MapFailed;
        });
        mapped[0] = 255;
        mapped[1] = 255;
        mapped[2] = 255;
        mapped[3] = 255;
        c.SDL_UnmapGPUTransferBuffer(gpu_device, transfer_buf);

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            return error.CopyPassFailed;
        };
        c.SDL_UploadToGPUTexture(copy_pass, &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer_buf,
            .offset = 0,
            .pixels_per_row = 1,
            .rows_per_layer = 1,
        }, &c.SDL_GPUTextureRegion{
            .texture = white_texture,
            .w = 1,
            .h = 1,
            .d = 1,
        }, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    }

    // Create Graphics Pipeline
    const vertex_attribs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(renderer.Vertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(renderer.Vertex, "u") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(renderer.Vertex, "r") },
    };
    const vertex_buf_descs = [_]c.SDL_GPUVertexBufferDescription{
        .{ .slot = 0, .pitch = @sizeOf(renderer.Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
    };

    var pipeline_info = c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .num_vertex_attributes = vertex_attribs.len,
            .vertex_attributes = &vertex_attribs,
            .num_vertex_buffers = vertex_buf_descs.len,
            .vertex_buffer_descriptions = &vertex_buf_descs,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = .{
            .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS,
            .back_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS, .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP },
            .front_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS, .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP },
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = false,
            .enable_depth_write = false,
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .num_color_targets = 1,
            .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{.{
                .format = c.SDL_GetGPUSwapchainTextureFormat(gpu_device, window),
                .blend_state = .{
                    .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                    .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                    .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
                    .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                    .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .enable_blend = true,
                    .enable_color_write_mask = false,
                    .padding1 = 0,
                    .padding2 = 0,
                },
            }},
            .has_depth_stencil_target = false,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
            .padding1 = 0,
            .padding2 = 0,
        },
        .props = 0,
    };
    const pipeline = c.SDL_CreateGPUGraphicsPipeline(gpu_device, &pipeline_info) orelse {
        std.log.err("Failed to create graphics pipeline: {s}", .{c.SDL_GetError()});
        return error.PipelineCreationFailed;
    };

    return GpuResources{
        .text_engine = text_engine,
        .pipeline = pipeline,
        .sampler = sampler,
        .white_texture = white_texture,
        .fonts = fonts,
    };
}

fn readPipedStdin(state: *ViewerState, io: std.Io, gpa: std.mem.Allocator) !void {
    const is_stdin_piped = !(std.Io.File.stdin().isTty(io) catch false);
    if (is_stdin_piped) {
        var read_buf: [4096]u8 = undefined;
        var stdin_file_reader = std.Io.File.Reader.init(std.Io.File.stdin(), io, &read_buf);
        const stdin = &stdin_file_reader.interface;

        while (try stdin.takeDelimiter('\n')) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n ");
            if (trimmed.len > 0) {
                if (std.Io.Dir.statFile(std.Io.Dir.cwd(), io, trimmed, .{})) |s| {
                    if (s.kind == .directory) {
                        try scanDirectory(gpa, io, trimmed, &state.image_list);
                    } else if (isImageExtension(std.fs.path.extension(trimmed))) {
                        const dup = try gpa.dupe(u8, trimmed);
                        errdefer gpa.free(dup);
                        try state.image_list.append(gpa, dup);
                    }
                } else |_| {
                    const dup = try gpa.dupe(u8, trimmed);
                    errdefer gpa.free(dup);
                    try state.image_list.append(gpa, dup);
                }
            }
        }
        if (state.image_list.items.len > 0 and state.current_index == null) {
            state.current_index = 0;
            try state.updateCache();
        }
    }
}

fn pollFrameInput(
    window: *c.SDL_Window,
    frame_allocator: std.mem.Allocator,
    last_time: *u64,
    mouse_inside: *bool,
    running: *bool,
    palette_show: bool,
) !FrameInput {
    const current_ticks = c.SDL_GetTicks();
    const delta_time_ms = @as(f32, @floatFromInt(current_ticks - last_time.*));
    last_time.* = current_ticks;

    // Get window sizes and scale
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    if (!c.SDL_GetWindowSize(window, &win_w, &win_h)) {
        std.log.err("SDL_GetWindowSize failed: {s}", .{c.SDL_GetError()});
    }
    var pix_w: c_int = 0;
    var pix_h: c_int = 0;
    if (!c.SDL_GetWindowSizeInPixels(window, &pix_w, &pix_h)) {
        std.log.err("SDL_GetWindowSizeInPixels failed: {s}", .{c.SDL_GetError()});
    }

    const width = @as(f32, @floatFromInt(pix_w));
    const height = @as(f32, @floatFromInt(pix_h));
    const scale_x = if (win_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;
    const scale_y = if (win_h > 0) @as(f32, @floatFromInt(pix_h)) / @as(f32, @floatFromInt(win_h)) else 1.0;
    const dpi_scale = scale_x;

    var keys_pressed = std.ArrayList(c.SDL_Keycode).empty;
    errdefer keys_pressed.deinit(frame_allocator);
    var text_input_opt: ?[]const u8 = null;
    var dropped_path_opt: ?[]const u8 = null;
    var scroll_delta_x: f32 = 0;
    var scroll_delta_y: f32 = 0;
    var mouse_left_clicked = false;

    var event: c.SDL_Event = undefined;
    const wait_success = if (palette_show)
        c.SDL_WaitEventTimeout(&event, 8)
    else
        c.SDL_WaitEvent(&event);

    if (!wait_success) {
        event.type = 0;
    }

    var has_event = wait_success;
    while (has_event) {
        switch (event.type) {
            c.SDL_EVENT_QUIT => running.* = false,
            c.SDL_EVENT_WINDOW_MOUSE_ENTER => {
                mouse_inside.* = true;
            },
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                mouse_inside.* = false;
            },
            c.SDL_EVENT_KEY_DOWN => {
                try keys_pressed.append(frame_allocator, event.key.key);
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (event.text.text) |ptr| {
                    const len = std.mem.len(ptr);
                    const dup = try frame_allocator.dupe(u8, ptr[0..len]);
                    text_input_opt = dup;
                }
            },
            c.SDL_EVENT_DROP_FILE => {
                if (event.drop.data) |ptr| {
                    const len = std.mem.len(ptr);
                    const dup = try frame_allocator.dupe(u8, ptr[0..len]);
                    dropped_path_opt = dup;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    mouse_left_clicked = true;
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const multiplier: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1.0 else 1.0;
                scroll_delta_x += event.wheel.x * multiplier * 6.0;
                scroll_delta_y += event.wheel.y * multiplier * 6.0;
            },
            else => {},
        }
        has_event = c.SDL_PollEvent(&event);
    }

    var mouse_x_raw: f32 = 0;
    var mouse_y_raw: f32 = 0;
    const mouse_buttons = c.SDL_GetMouseState(&mouse_x_raw, &mouse_y_raw);
    const mouse_left_down = (mouse_buttons & c.SDL_BUTTON_MASK(c.SDL_BUTTON_LEFT)) != 0;

    return FrameInput{
        .win_w = @as(f32, @floatFromInt(win_w)),
        .win_h = @as(f32, @floatFromInt(win_h)),
        .pix_w = width,
        .pix_h = height,
        .scale_x = scale_x,
        .scale_y = scale_y,
        .dpi_scale = dpi_scale,
        .mouse_x = mouse_x_raw * scale_x,
        .mouse_y = mouse_y_raw * scale_y,
        .mouse_left_down = mouse_left_down,
        .mouse_left_clicked = mouse_left_clicked,
        .mouse_inside = mouse_inside.*,
        .scroll_delta_x = scroll_delta_x,
        .scroll_delta_y = scroll_delta_y,
        .keys_pressed = keys_pressed,
        .key_modifiers = c.SDL_GetModState(),
        .text_input = text_input_opt,
        .dropped_path = dropped_path_opt,
        .ticks = current_ticks,
        .delta_time_ms = delta_time_ms,
    };
}

fn compareScreenshots(base_path: [:0]const u8, run_path: [:0]const u8, diff_path: [:0]const u8) !void {
    const raw_base_surf = c.IMG_Load(base_path.ptr) orelse {
        std.log.err("Failed to load baseline screenshot: {s}. Run with --update-baselines to create it.", .{base_path});
        return error.BaselineMissing;
    };
    defer c.SDL_DestroySurface(raw_base_surf);

    const raw_run_surf = c.IMG_Load(run_path.ptr) orelse {
        std.log.err("Failed to load run screenshot: {s}", .{run_path});
        return error.RunScreenshotMissing;
    };
    defer c.SDL_DestroySurface(raw_run_surf);

    if (raw_base_surf.*.w != raw_run_surf.*.w or raw_base_surf.*.h != raw_run_surf.*.h) {
        std.log.err("Dimension mismatch: baseline is {d}x{d}, run is {d}x{d}", .{ raw_base_surf.*.w, raw_base_surf.*.h, raw_run_surf.*.w, raw_run_surf.*.h });
        return error.DimensionMismatch;
    }

    const width = @as(u32, @intCast(raw_base_surf.*.w));
    const height = @as(u32, @intCast(raw_base_surf.*.h));

    // Convert both surfaces to a canonical RGBA32 format to guarantee alignment, pitch, and byte order matching
    const base_surf = c.SDL_ConvertSurface(raw_base_surf, c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.err("Failed to convert baseline to RGBA32: {s}", .{c.SDL_GetError()});
        return error.SurfaceConversionFailed;
    };
    defer c.SDL_DestroySurface(base_surf);

    const run_surf = c.SDL_ConvertSurface(raw_run_surf, c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.err("Failed to convert run to RGBA32: {s}", .{c.SDL_GetError()});
        return error.SurfaceConversionFailed;
    };
    defer c.SDL_DestroySurface(run_surf);

    const diff_surf = c.SDL_CreateSurface(@intCast(width), @intCast(height), c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.err("Failed to create diff surface: {s}", .{c.SDL_GetError()});
        return error.DiffSurfaceCreationFailed;
    };
    defer c.SDL_DestroySurface(diff_surf);

    const pixels_base = @as([*]const u32, @ptrCast(@alignCast(base_surf.*.pixels)));
    const pixels_run = @as([*]const u32, @ptrCast(@alignCast(run_surf.*.pixels)));
    const pixels_diff = @as([*]u32, @ptrCast(@alignCast(diff_surf.*.pixels)));

    const pitch_words_base = @as(usize, @intCast(base_surf.*.pitch)) / 4;
    const pitch_words_run = @as(usize, @intCast(run_surf.*.pitch)) / 4;
    const pitch_words_diff = @as(usize, @intCast(diff_surf.*.pitch)) / 4;

    var mismatched_pixels: u32 = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx_base = y * pitch_words_base + x;
            const idx_run = y * pitch_words_run + x;
            const idx_diff = y * pitch_words_diff + x;

            const p_base = pixels_base[idx_base];
            const p_run = pixels_run[idx_run];
            if (p_base != p_run) {
                mismatched_pixels += 1;
                // Paint mismatched pixel as bright red (0xFF0000FF in RGBA32 format)
                pixels_diff[idx_diff] = 0xFF0000FF;
            } else {
                // Dim color channels (divides by 4) and preserve alpha safely without channel bleeding
                const b0 = (p_base >> 0) & 0xFF;
                const b1 = (p_base >> 8) & 0xFF;
                const b2 = (p_base >> 16) & 0xFF;
                const b3 = (p_base >> 24) & 0xFF;
                pixels_diff[idx_diff] = (b0 / 4) | ((b1 / 4) << 8) | ((b2 / 4) << 16) | (b3 << 24);
            }
        }
    }

    if (mismatched_pixels > 0) {
        const total_pixels = width * height;
        const pct = (@as(f64, @floatFromInt(mismatched_pixels)) / @as(f64, @floatFromInt(total_pixels))) * 100.0;
        std.log.err("Visual regression found: {d} pixels differ ({d:.3}%)", .{ mismatched_pixels, pct });
        if (!c.IMG_SavePNG(diff_surf, diff_path.ptr)) {
            std.log.err("Failed to save diff image: {s}", .{c.SDL_GetError()});
        } else {
            std.log.info("Diff image saved to: {s}", .{diff_path});
        }
        return error.VisualRegressionMismatch;
    }
}

fn getTextureFormatElementSize(format: c.SDL_GPUTextureFormat) u32 {
    return switch (format) {
        c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM, c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB => 4,
        c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT => 8,
        c.SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT => 16,
        else => 4, // Fallback safe default
    };
}

fn saveTextureToPng(
    device: *c.SDL_GPUDevice,
    cmd_buf: *c.SDL_GPUCommandBuffer,
    texture: *c.SDL_GPUTexture,
    width: u32,
    height: u32,
    texture_format: c.SDL_GPUTextureFormat,
    filename: [:0]const u8,
) !void {
    const bpp = getTextureFormatElementSize(texture_format);
    const pitch = width * bpp;
    const size = pitch * height;

    const transfer_buf = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = size,
        .props = 0,
    }) orelse {
        std.log.err("Failed to create download transfer buffer: {s}", .{c.SDL_GetError()});
        return error.TransferBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse return error.CopyPassCreationFailed;
    c.SDL_DownloadFromGPUTexture(copy_pass, &c.SDL_GPUTextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = width,
        .h = height,
        .d = 1,
    }, &c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = width,
        .rows_per_layer = height,
    });
    c.SDL_EndGPUCopyPass(copy_pass);

    _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    _ = c.SDL_WaitForGPUIdle(device);

    const data_ptr = c.SDL_MapGPUTransferBuffer(device, transfer_buf, false) orelse return error.MapBufferFailed;
    defer c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);

    var sdl_format: c.SDL_PixelFormat = c.SDL_PIXELFORMAT_RGBA32;
    if (texture_format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM or
        texture_format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB)
    {
        sdl_format = c.SDL_PIXELFORMAT_BGRA32;
    }

    const surface = c.SDL_CreateSurfaceFrom(@intCast(width), @intCast(height), sdl_format, data_ptr, @intCast(pitch)) orelse {
        std.log.err("SDL_CreateSurfaceFrom failed: {s}", .{c.SDL_GetError()});
        return error.SurfaceCreationFailed;
    };
    defer c.SDL_DestroySurface(surface);

    if (!c.IMG_SavePNG(surface, filename.ptr)) {
        std.log.err("IMG_SavePNG failed: {s}", .{c.SDL_GetError()});
        return error.SavePngFailed;
    }
}

fn renderFrame(
    state: *ViewerState,
    input: FrameInput,
    frame_allocator: std.mem.Allocator,
    fonts: []const ?*c.TTF_Font,
    measure_data: *const MeasureTextUserData,
    capture_filename: ?[:0]const u8,
) !void {
    const width = input.pix_w;
    const height = input.pix_h;
    const scale_x = input.scale_x;
    const scale_y = input.scale_y;
    const dpi_scale = input.dpi_scale;
    state.prepareCacheTextures();
    const current_entry = state.getCurrentEntry();

    // Calculate Image Fitting Layout Boundaries
    var title_bar_h: f32 = 60.0;
    const nav_bar_h: f32 = 0.0;
    if (state.is_fullscreen) {
        title_bar_h = 0;
    }

    var available_width = width;
    if (clay.isDebugModeEnabled()) {
        available_width = @max(width - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0);
    }

    var draw_w: f32 = 0;
    var draw_h: f32 = 0;

    if (current_entry) |entry| {
        if (entry.gpu_texture != null) {
            const padding: f32 = 0.0;
            const view_w = @max(available_width - padding * 2.0, 1.0);
            const view_h = @max(height - (title_bar_h + nav_bar_h) * scale_y - padding * 2.0, 1.0);

            const angle = state.rotation_angle;
            const is_90_or_270 = (std.math.approxEqAbs(f32, angle, 90.0, 0.1) or
                std.math.approxEqAbs(f32, angle, 270.0, 0.1) or
                std.math.approxEqAbs(f32, angle, -90.0, 0.1) or
                std.math.approxEqAbs(f32, angle, -270.0, 0.1));
            const img_w = if (is_90_or_270) entry.h else entry.w;
            const img_h = if (is_90_or_270) entry.w else entry.h;

            if (img_w > 0 and img_h > 0) {
                const r_img = img_w / img_h;
                const r_view = view_w / view_h;
                switch (state.scale_mode) {
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
                            draw_h = view_w / r_img;
                        }
                    },
                }
            }
        }
    }

    clay.beginLayout();

    // Main Layout Container
    clay.UI()(.{
        .id = clay.getElementId("MainLayout"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
            .direction = .top_to_bottom,
        },
        .background_color = .{ 24, 24, 37, 255 }, // Catppuccin Base (Mocha Mantle/Base)
    })({
        try renderPalette(
            state,
            scale_x,
            scale_y,
            dpi_scale,
            input.mouse_left_clicked,
            frame_allocator,
            measure_data,
        );

        if (state.show_stats_overlay) {
            const idx = state.current_index;
            const path = if (idx != null and state.image_list.items.len > idx.?) state.image_list.items[idx.?] else "";
            const filename = if (path.len > 0) std.fs.path.basename(path) else "None";
            const dirname = if (path.len > 0) (std.fs.path.dirname(path) orelse ".") else "None";

            const display_dir = if (dirname.len > 35) try std.fmt.allocPrint(frame_allocator, "...{s}", .{dirname[dirname.len - 32 ..]}) else dirname;

            var disk_size_str: []const u8 = "Loading...";
            var mem_size_str: []const u8 = "Loading...";
            var mime_type: []const u8 = "Loading...";
            var res_str: []const u8 = "Loading...";
            var decode_str: []const u8 = "Loading...";
            var convert_str: []const u8 = "Loading...";
            var process_str: []const u8 = "Loading...";
            var screen_str: []const u8 = "Loading...";

            if (current_entry) |entry| {
                mime_type = entry.mime_type;
                if (entry.status == .loaded or entry.gpu_texture != null) {
                    disk_size_str = try formatSize(frame_allocator, entry.size_bytes);
                    mem_size_str = try formatSize(frame_allocator, entry.memory_size_bytes);

                    const megapixels = (entry.w * entry.h) / 1_000_000.0;
                    res_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} ({d:.2} MP)", .{ entry.w, entry.h, megapixels });
                    decode_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{entry.decode_time_ms});
                    convert_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{entry.conversion_time_ms});
                    process_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{entry.upload_time_ms});
                    screen_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} px", .{ draw_w, draw_h });
                } else if (entry.status == .failed) {
                    disk_size_str = "Failed";
                    mem_size_str = "Failed";
                    mime_type = "Failed";
                    res_str = "Failed";
                    decode_str = "Failed";
                    convert_str = "Failed";
                    process_str = "Failed";
                    screen_str = "Failed";
                }
            }

            var zoom_str: []const u8 = "1.0x";
            if (current_entry) |entry| {
                if (entry.w > 0) {
                    const pixel_zoom_pct = ((draw_w * state.zoom_factor) / entry.w) * 100.0;
                    zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x ({d:.0}%)", .{ state.zoom_factor, pixel_zoom_pct });
                } else {
                    zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.zoom_factor});
                }
            } else {
                zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.zoom_factor});
            }

            const pan_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}, {d:.0} px", .{ state.pan_x, state.pan_y });
            const rot_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}°", .{state.rotation_angle});

            clay.UI()(.{
                .id = clay.getElementId("StatsPanel"),
                .layout = .{
                    .sizing = .{ .w = .fixed(380 * scale_x), .h = .fit },
                    .direction = .top_to_bottom,
                    .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
                    .child_gap = 10,
                },
                .background_color = .{ 30, 30, 46, 220 },
                .corner_radius = .all(10),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = .{ 49, 50, 68, 255 },
                },
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_top, .parent = .left_top },
                    .offset = .{ .x = state.stats_offset_x, .y = state.stats_offset_y },
                    .z_index = 100,
                },
            })({
                // Header row
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fixed(24 * scale_y) },
                        .direction = .left_to_right,
                        .child_alignment = .{ .x = .left, .y = .center },
                    },
                })({
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({
                        clay.text("Stats for Nerds", .{
                            .color = .{ 245, 194, 231, 255 },
                            .font_size = @intFromFloat(16.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                    clay.UI()(.{
                        .id = clay.getElementId("StatsCloseBtn"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(24 * scale_x), .h = .fixed(24 * scale_y) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                        .background_color = .{ 49, 50, 68, 255 },
                        .corner_radius = .all(12),
                    })({
                        clay.text("x", .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(12.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                });

                // Stats details
                if (filename.len > 0) {
                    try renderStatRow("File Name", filename, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Directory", display_dir, scale_x, scale_y, dpi_scale);
                    try renderStatRow("MIME Type", mime_type, scale_x, scale_y, dpi_scale);
                    const hit_str = if (state.current_image_cache_hit) "Yes" else "No";
                    try renderStatRow("Cache Hit", hit_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Size on Disk", disk_size_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Resolution", res_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Decode Time", decode_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Convert Time", convert_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Upload Time", process_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Memory Size", mem_size_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Viewport Size", screen_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Zoom Level", zoom_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Pan Offset", pan_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Rotation", rot_str, scale_x, scale_y, dpi_scale);
                    const scale_mode_str = switch (state.scale_mode) {
                        .none => "Original size (100%)",
                        .shrink => "Fit if larger",
                        .full => "Fit to screen (Aspect Fit)",
                        .crop => "Fill screen (Aspect Fill)",
                    };
                    try renderStatRow("Scale Mode", scale_mode_str, scale_x, scale_y, dpi_scale);
                    const filter_str = switch (state.texture_scale_mode) {
                        .nearest => "Nearest Neighbor",
                        .linear => "Bilinear Filter",
                        .pixel_art => "Pixel Art Scaling",
                        .mitchell => "Mitchell-Netravali",
                        .lanczos3 => "Lanczos3 Resampler",
                    };
                    try renderStatRow("Scaling Filter", filter_str, scale_x, scale_y, dpi_scale);

                    const brightness_val = state.brightness * 100.0;
                    const brightness_str = try std.fmt.allocPrint(frame_allocator, "{s}{d:.0}%", .{ if (brightness_val > 0) "+" else "", brightness_val });
                    const contrast_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.contrast});
                    try renderStatRow("Brightness", brightness_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Contrast", contrast_str, scale_x, scale_y, dpi_scale);
                }
            });
        }

        // Header/Title bar UI
        if (!state.is_fullscreen) {
            clay.UI()(.{
                .id = clay.getElementId("TitleBar"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(title_bar_h * scale_y) },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{
                        .left = @intFromFloat(20 * scale_x),
                        .right = @intFromFloat(20 * scale_x),
                    },
                },
                .background_color = .{ 17, 17, 27, 255 },
                .border = .{ .width = .{ .bottom = 1 }, .color = .{ 49, 50, 68, 255 } },
            })({
                clay.text("Peng Image Viewer", .{
                    .color = .{ 205, 214, 244, 255 },
                    .font_size = @intFromFloat(16.0 * dpi_scale),
                    .font_id = 0,
                });

                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({});

                if (state.image_list.items.len > 0) {
                    const idx = (state.current_index orelse 0) + 1;
                    const count_buf = try frame_allocator.alloc(u8, 64);
                    const count_str = try std.fmt.bufPrint(count_buf, "Image {} of {}", .{ idx, state.image_list.items.len });
                    clay.text(count_str, .{
                        .color = .{ 166, 173, 200, 255 },
                        .font_size = @intFromFloat(12.0 * dpi_scale),
                        .font_id = 0,
                    });
                }
            });
        }

        // Center Viewport Area
        clay.UI()(.{
            .id = clay.getElementId("Viewport"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .clip = .{ .horizontal = true, .vertical = true },
        })({
            if (current_entry) |entry| {
                if (entry.gpu_texture) |tex| {
                    clay.UI()(.{
                        .id = clay.getElementId("ImageCanvas"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(draw_w), .h = .fixed(draw_h) },
                        },
                        .image = .{
                            .image_data = @ptrCast(tex),
                        },
                    })({});
                } else if (entry.status == .decoding) {
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .grow },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = @intFromFloat(10 * scale_y),
                        },
                    })({
                        clay.text("Loading image...", .{
                            .color = .{ 245, 194, 231, 255 },
                            .font_size = @intFromFloat(22.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                } else {
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .grow },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = @intFromFloat(10 * scale_y),
                        },
                    })({
                        clay.text("Failed to Load Image", .{
                            .color = .{ 243, 139, 168, 255 },
                            .font_size = @intFromFloat(22.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                }
            } else {
                // Empty state screen
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .grow },
                        .direction = .top_to_bottom,
                        .child_alignment = .{ .x = .center, .y = .center },
                    },
                })({
                    clay.UI()(.{
                        .id = clay.ElementId.ID("DropZoneBox"),
                        .layout = .{
                            .sizing = .{ .w = .fit, .h = .fit },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = @intFromFloat(16 * scale_y),
                            .padding = .{
                                .left = @intFromFloat(40 * scale_x),
                                .right = @intFromFloat(40 * scale_x),
                                .top = @intFromFloat(32 * scale_y),
                                .bottom = @intFromFloat(32 * scale_y),
                            },
                        },
                        .border = .{ .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 }, .color = .{ 79, 79, 97, 255 } },
                        .corner_radius = .all(12),
                        .user_data = @ptrFromInt(@intFromEnum(ElementTag.drop_zone_box)),
                    })({
                        clay.text("No Images Loaded", .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(22.0 * dpi_scale),
                            .font_id = 0,
                        });

                        clay.text("Drag & Drop images or directories here to view them.", .{
                            .color = .{ 166, 173, 200, 255 },
                            .font_size = @intFromFloat(14.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                });
            }
        });
    });

    const render_commands = clay.endLayout();

    // Render Frame
    const cmd_buf = c.SDL_AcquireGPUCommandBuffer(state.gpu_device) orelse return error.CommandBufferAcquisitionFailed;
    errdefer _ = c.SDL_CancelGPUCommandBuffer(cmd_buf); // Cancel command buffer on early errors to avoid leaks

    var swap_tex: ?*c.SDL_GPUTexture = null;
    var swap_w: u32 = 0;
    var swap_h: u32 = 0;

    var temp_textures = std.ArrayList(*c.SDL_GPUTexture).empty;
    defer temp_textures.deinit(frame_allocator);
    errdefer {
        for (temp_textures.items) |tex| {
            c.SDL_ReleaseGPUTexture(state.gpu_device, tex);
        }
    }

    var temp_buffers = std.ArrayList(*c.SDL_GPUTransferBuffer).empty;
    defer temp_buffers.deinit(frame_allocator);
    errdefer {
        for (temp_buffers.items) |buf| {
            c.SDL_ReleaseGPUTransferBuffer(state.gpu_device, buf);
        }
    }

    if (c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buf, state.window, &swap_tex, &swap_w, &swap_h)) {
        try renderer.renderClayCommands(
            state.gpu_device,
            cmd_buf,
            swap_tex,
            state.gpu_pipeline,
            state.gpu_sampler,
            state.white_texture,
            state.gpu_text_engine,
            fonts,
            render_commands,
            frame_allocator,
            &temp_textures,
            &temp_buffers,
            .{
                .zoom_factor = state.zoom_factor,
                .pan_x = state.pan_x,
                .pan_y = state.pan_y,
                .rotation_angle = state.rotation_angle,
            },
            @intCast(swap_w),
            @intCast(swap_h),
            state.brightness,
            state.contrast,
            state.texture_scale_mode,
        );
        if (capture_filename) |filename| {
            const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(state.gpu_device.?, state.window);
            try saveTextureToPng(state.gpu_device.?, cmd_buf, swap_tex.?, swap_w, swap_h, swapchain_format, filename);
        } else {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
        }

        // Defer release of text textures until command buffer completes
        for (temp_textures.items) |tex| {
            c.SDL_ReleaseGPUTexture(state.gpu_device, tex);
        }
        for (temp_buffers.items) |buf| {
            c.SDL_ReleaseGPUTransferBuffer(state.gpu_device, buf);
        }
    } else {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Phase 1: Parse command line arguments
    const parsed = try parseCommandLineArgs(init, gpa);
    defer if (parsed.arg_path) |p| gpa.free(p);

    // Phase 2: Graphics and Window Setup
    const setup = try initGraphicsAndWindow("Peng Image Viewer", parsed.test_mode);
    defer {
        c.SDL_DestroyWindow(setup.window);
        c.SDL_Quit();
        c.TTF_Quit();
    }

    // Phase 3: GPU Pipeline and Resources Setup
    const resources = try initGpuResources(setup.gpu_device, setup.window, setup.initial_dpi_scale);
    var own_resources = true;
    defer {
        if (own_resources) {
            c.SDL_ReleaseGPUGraphicsPipeline(setup.gpu_device, resources.pipeline);
            c.SDL_ReleaseGPUSampler(setup.gpu_device, resources.sampler);
            c.SDL_ReleaseGPUTexture(setup.gpu_device, resources.white_texture);
            c.TTF_DestroyGPUTextEngine(resources.text_engine);
        }
        for (resources.fonts) |f| {
            if (f) |font| c.TTF_CloseFont(font);
        }
    }

    const cache_mutex = c.SDL_CreateMutex() orelse {
        std.log.err("SDL_CreateMutex failed: {s}", .{c.SDL_GetError()});
        return error.SDLCreateMutexFailed;
    };

    // Phase 4: State Initialization
    var state = ViewerState{
        .gpu_device = setup.gpu_device,
        .gpu_pipeline = resources.pipeline,
        .gpu_sampler = resources.sampler,
        .white_texture = resources.white_texture,
        .gpu_text_engine = resources.text_engine,
        .image_list = std.ArrayList([]const u8).empty,
        .cache = std.ArrayList(CacheEntry).empty,
        .cache_mutex = cache_mutex,
        .allocator = gpa,
        .io = init.io,
        .window_pixel_format = c.SDL_PIXELFORMAT_RGBA32,
        .palette = PaletteState.init(gpa),
        .scale_mode = parsed.default_scale,
        .rotation_angle = 0.0,
        .rotation_map = std.StringHashMap(f32).init(gpa),
        .brightness = 0.0,
        .contrast = 1.0,
        .adjustments_dirty = false,
        .window = setup.window,
        .is_fullscreen = false,
        .running = true,
        .show_stats_overlay = false,
        .test_mode = parsed.test_mode,
        .update_baselines = parsed.update_baselines,
    };
    defer state.deinit();
    own_resources = false;

    // Populate initial image list from arguments and piped stdin
    if (parsed.arg_path) |path| {
        try state.handlePathSelection(path);
    }
    try readPipedStdin(&state, init.io, gpa);

    // Initialize Clay UI Layout Engine
    const clay_memory_size = clay.minMemorySize();
    const clay_memory = try gpa.alloc(u8, clay_memory_size);
    defer gpa.free(clay_memory);
    const clay_arena = clay.Arena.init(clay_memory);
    _ = clay.initialize(clay_arena, .{
        .w = @as(f32, @floatFromInt(1024)),
        .h = @as(f32, @floatFromInt(768)),
    }, .{});

    var measure_data = MeasureTextUserData{
        .text_engine = resources.text_engine,
        .fonts = resources.fonts[0..],
        .allocator = gpa,
    };
    clay.setMeasureTextFunction(*const MeasureTextUserData, &measure_data, sdl3MeasureText);

    // Per-frame arena allocator
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();

    var last_time = c.SDL_GetTicks();

    // Phase 5: The Main Loop / Test Mode
    if (state.test_mode) {
        if (std.Io.Dir.openDir(std.Io.Dir.cwd(), state.io, "testfiles/current-run", .{ .iterate = true })) |dir| {
            var it = std.Io.Dir.iterate(dir);
            while (it.next(state.io) catch null) |entry| {
                std.Io.Dir.deleteFile(dir, state.io, entry.name) catch {};
            }
            std.Io.Dir.close(dir, state.io);
        } else |_| {}

        std.Io.Dir.createDirPath(std.Io.Dir.cwd(), state.io, "testfiles/golden-screenshots") catch {};
        std.Io.Dir.createDirPath(std.Io.Dir.cwd(), state.io, "testfiles/current-run") catch {};

        var test_frame: u32 = 0;
        const filenames = [_][]const u8{
            "test_0_init.png",
            "test_1_zoom.png",
            "test_2_adjust.png",
            "test_3_filter.png",
            "test_4_action_palette.png",
            "test_5_files_palette.png",
            "test_6_next_image.png",
        };
        while (test_frame < 7) : (test_frame += 1) {
            // Pump event loop to prevent OS "Application Unresponsive" warnings
            var event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&event)) {}

            _ = frame_arena.reset(.retain_capacity);

            var win_w: c_int = 0;
            var win_h: c_int = 0;
            _ = c.SDL_GetWindowSize(setup.window, &win_w, &win_h);

            var pix_w: c_int = 0;
            var pix_h: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(setup.window, &pix_w, &pix_h);

            const width = @as(f32, @floatFromInt(pix_w));
            const height = @as(f32, @floatFromInt(pix_h));
            const scale_x = if (win_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;
            const scale_y = if (win_h > 0) @as(f32, @floatFromInt(pix_h)) / @as(f32, @floatFromInt(win_h)) else 1.0;
            const dpi_scale = scale_x;

            const input = FrameInput{
                .win_w = @as(f32, @floatFromInt(win_w)),
                .win_h = @as(f32, @floatFromInt(win_h)),
                .pix_w = width,
                .pix_h = height,
                .scale_x = scale_x,
                .scale_y = scale_y,
                .dpi_scale = dpi_scale,
                .mouse_x = -1.0,
                .mouse_y = -1.0,
                .mouse_left_down = false,
                .mouse_left_clicked = false,
                .mouse_inside = false,
                .scroll_delta_x = 0.0,
                .scroll_delta_y = 0.0,
                .keys_pressed = std.ArrayList(c.SDL_Keycode).empty,
                .key_modifiers = 0,
                .text_input = null,
                .dropped_path = null,
                .ticks = 0,
                .delta_time_ms = 16.666,
            };

            switch (test_frame) {
                0 => {
                    std.log.info("Test Mode Frame 0: Initial Render", .{});
                },
                1 => {
                    std.log.info("Test Mode Frame 1: Apply Zoom & Pan", .{});
                    state.zoom_factor = 2.0;
                    state.pan_x = 50.0;
                    state.pan_y = -30.0;
                },
                2 => {
                    std.log.info("Test Mode Frame 2: Apply Brightness & Contrast", .{});
                    state.zoom_factor = 1.0;
                    state.pan_x = 0.0;
                    state.pan_y = 0.0;
                    state.brightness = 0.3;
                    state.contrast = 1.4;
                    state.adjustments_dirty = true;
                },
                3 => {
                    std.log.info("Test Mode Frame 3: Apply Mitchell Filter", .{});
                    state.brightness = 0.0;
                    state.contrast = 1.0;
                    state.adjustments_dirty = true;
                    state.texture_scale_mode = .mitchell;
                    state.applyTextureScaleMode();
                },
                4 => {
                    std.log.info("Test Mode Frame 4: Open Action Palette", .{});
                    state.texture_scale_mode = .linear;
                    state.applyTextureScaleMode();

                    state.palette.show = true;
                    state.palette.active_type = .actions;
                    state.palette.reset();
                    try state.rebuildActionMatches();
                },
                5 => {
                    std.log.info("Test Mode Frame 5: Open Files Palette", .{});
                    state.palette.show = true;
                    state.palette.active_type = .files;
                    state.palette.reset();
                    try state.rebuildPaletteMatches();
                },
                6 => {
                    std.log.info("Test Mode Frame 6: Navigate to Next Image", .{});
                    state.palette.show = false;
                    try state.next();
                },
                else => unreachable,
            }

            // Busy wait until the background loader finishes decoding the image
            var wait_attempts: u32 = 0;
            while (wait_attempts < 1000) : (wait_attempts += 1) {
                // Pump event loop during wait to keep window manager happy
                var ev: c.SDL_Event = undefined;
                while (c.SDL_PollEvent(&ev)) {}

                if (state.getCurrentEntry()) |entry| {
                    if (entry.status != .decoding) {
                        break;
                    }
                }
                c.SDL_Delay(10);
            }
            if (state.getCurrentEntry() == null or state.getCurrentEntry().?.status == .failed) {
                std.log.err("Timed out or failed waiting for test image to load in cache.", .{});
                return error.TestImageLoadTimeout;
            }

            clay.setLayoutDimensions(.{ .w = input.pix_w, .h = input.pix_h });
            clay.setPointerState(.{ .x = -1.0, .y = -1.0 }, false);

            const base_filename = try frame_allocator.dupeZ(u8, try std.fmt.allocPrint(frame_allocator, "testfiles/golden-screenshots/{s}", .{filenames[test_frame]}));
            const run_filename = try frame_allocator.dupeZ(u8, try std.fmt.allocPrint(frame_allocator, "testfiles/current-run/{s}", .{filenames[test_frame]}));
            const diff_filename = try frame_allocator.dupeZ(u8, try std.fmt.allocPrint(frame_allocator, "testfiles/current-run/diff_{s}", .{filenames[test_frame]}));

            const capture_path = if (state.update_baselines) base_filename else run_filename;

            try renderFrame(&state, input, frame_allocator, resources.fonts[0..], &measure_data, capture_path);

            if (!state.update_baselines) {
                try compareScreenshots(base_filename, run_filename, diff_filename);
            }
        }
        std.log.info("Test Mode completed successfully!", .{});
    } else {
        while (state.running) {
            // Phase 5a: Input Accumulation
            _ = frame_arena.reset(.retain_capacity);
            const input = try pollFrameInput(
                setup.window,
                frame_allocator,
                &last_time,
                &state.mouse_inside,
                &state.running,
                state.palette.show,
            );

            // Phase 5b: State Update
            try state.update(input, gpa);

            clay.setLayoutDimensions(.{ .w = input.pix_w, .h = input.pix_h });

            if (input.mouse_inside) {
                clay.setPointerState(
                    .{ .x = input.mouse_x, .y = input.mouse_y },
                    input.mouse_left_down,
                );
            } else {
                clay.setPointerState(
                    .{ .x = -1.0, .y = -1.0 },
                    false,
                );
            }

            clay.updateScrollContainers(
                true,
                .{ .x = input.scroll_delta_x, .y = input.scroll_delta_y },
                input.delta_time_ms / 1000.0,
            );

            if (input.mouse_left_clicked) {
                if (state.show_stats_overlay and clay.pointerOver(clay.getElementId("StatsCloseBtn"))) {
                    state.show_stats_overlay = false;
                }
            }

            // Phase 5c: Draw / Render
            try renderFrame(&state, input, frame_allocator, resources.fonts[0..], &measure_data, null);
        }
    }
}

test "ElementTag.fromInt" {
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0));
    try std.testing.expectEqual(ElementTag.drop_zone_box, ElementTag.fromInt(1337));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(9999));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0x7fffffffd000));
}
