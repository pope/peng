//! Unified Action & Capability Registry
//!
//! Centralized single source of truth for application capabilities, keybindings,
//! UI Command Palette entries, command-line flags, and remote IPC verbs.

const std = @import("std");
const root = @import("root.zig");

const AppIntent = root.AppIntent;
const Key = root.Key;
const KeyModifiers = root.KeyModifiers;
const KeyboardShortcut = root.KeyboardShortcut;
const PaletteMode = root.PaletteMode;
const ScaleMode = root.ScaleMode;
const TextureScaleMode = root.TextureScaleMode;
const scale_modes_string = root.scale_modes_string;
const filter_modes_string = root.filter_modes_string;

/// Target application scope for a command-line option or command.
pub const CliTarget = enum {
    main,
    ipc,
    both,

    /// Returns true if this target applies to the given scope.
    pub fn appliesTo(self: CliTarget, scope: CliTarget) bool {
        if (self == .both or scope == .both) return true;
        return self == scope;
    }
};

/// Enumeration of distinct command-line option identifiers.
pub const OptionId = enum {
    help,
    scale,
    blur,
    no_blur,
    ipc,
    headless,
    test_mode,
    update_baselines,
};

/// Declarative schema describing a command-line option, its target app, aliases, placeholder, and description.
pub const CliOption = struct {
    id: OptionId,
    target: CliTarget = .both,
    short: ?[]const u8 = null,
    long: []const u8,
    aliases: []const []const u8 = &.{},
    arg_name: ?[]const u8 = null,
    description: []const u8,

    /// Returns true if the given argument matches this option's short flag, long flag, or any alias.
    pub fn matches(self: CliOption, arg: []const u8) bool {
        if (self.short) |s| {
            if (std.mem.eql(u8, arg, s)) return true;
        }
        if (std.mem.eql(u8, arg, self.long)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, arg, alias)) return true;
        }
        return false;
    }
};

/// Declarative schema describing an IPC message command word and its usage.
pub const IpcCommandDesc = struct {
    name: []const u8,
    args: ?[]const u8 = null,
    description: []const u8,
};

/// Metadata describing an action executable from the Command Palette, including its shortcut and intent.
pub const ActionMetadata = struct {
    name: []const u8,
    shortcut_text: []const u8,
    show_in_palette: bool,
    shortcuts: []const KeyboardShortcut,
    intent: AppIntent,
};

/// Flattened keyboard shortcut entry mapping a specific key and modifier combination directly to an AppIntent.
pub const FlatShortcut = struct {
    key: Key,
    mod: KeyModifiers,
    intent: AppIntent,
};

/// Unique identifier for each capability or action in the application.
pub const ActionId = enum {
    // Navigation
    next_image,
    prev_image,
    first_image,
    last_image,
    go_to_image_dialog,

    // Overlays & UI
    toggle_info,
    toggle_manga_mode,
    toggle_stats,
    toggle_fullscreen,
    file_finder,
    directory_navigator,
    toggle_debug_mode,
    toggle_debug_thumb,
    command_palette,
    start_slideshow_dialog,
    stop_slideshow,
    toggle_blur,

    // Spatial & Viewport
    zoom_in,
    zoom_out,
    reset_zoom,
    rotate_cw,
    rotate_ccw,
    reset_rotation,

    // Scaling Modes (individual palette items)
    scale_none,
    scale_shrink,
    scale_full,
    scale_crop,
    scale_fit_width,
    scale_fit_height,

    // Resampling Filters (individual palette items)
    filter_nearest,
    filter_linear,
    filter_pixel_art,
    filter_mitchell,
    filter_lanczos3,
    filter_lanczos3_spline,

    // Color adjustments
    increase_brightness,
    decrease_brightness,
    increase_contrast,
    decrease_contrast,
    reset_adjustments,
    set_brightness_dialog,
    set_contrast_dialog,

    // Lifecycle
    quit,

    // Non-palette capabilities (CLI / IPC parameters)
    scale_config,
    zoom_config,
    pan_config,
    adjust_config,
    filter_config,
    palette_config,
    wait_load,
};

/// Master declaration record uniting UI metadata, shortcuts, intent, CLI flags, and IPC verbs.
pub const ActionDef = struct {
    id: ActionId,
    title: []const u8,
    shortcut_text: []const u8 = "",
    description: []const u8 = "",
    show_in_palette: bool = true,
    shortcuts: []const KeyboardShortcut = &.{},
    intent: ?AppIntent = null,
    cli: []const CliOption = &.{},
    ipc: ?IpcCommandDesc = null,
};

/// Master unified capabilities and actions registry.
/// Items 0..42 correspond to the standard UI Command Palette items.
pub const actions = [_]ActionDef{
    .{
        .id = .next_image,
        .title = "Next Image",
        .shortcut_text = "Space / Right Arrow",
        .description = "Advance to the next image in the active queue",
        .show_in_palette = true,
        .shortcuts = &.{ .{ .key = .space }, .{ .key = .right } },
        .intent = .next_image,
        .ipc = .{ .name = "next / prev", .description = "Navigate images" },
    },
    .{
        .id = .prev_image,
        .title = "Previous Image",
        .shortcut_text = "Backspace / Left Arrow",
        .description = "Return to the previous image in the active queue",
        .show_in_palette = true,
        .shortcuts = &.{ .{ .key = .backspace }, .{ .key = .left } },
        .intent = .prev_image,
    },
    .{
        .id = .toggle_info,
        .title = "Toggle Image Info",
        .shortcut_text = "I",
        .description = "Toggle image metadata and file info overlay",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_i }},
        .intent = .toggle_info,
    },
    .{
        .id = .toggle_manga_mode,
        .title = "Toggle Manga Mode (RTL)",
        .shortcut_text = "M",
        .description = "Toggle right-to-left manga reading mode",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_m }},
        .intent = .toggle_manga_mode,
        .ipc = .{ .name = "manga", .args = "<true|false>", .description = "Toggle RTL manga reading mode" },
    },
    .{
        .id = .toggle_stats,
        .title = "Toggle Performance Overlay",
        .shortcut_text = "Shift+I",
        .description = "Toggle rendering FPS and frame timing statistics",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_i, .mod = .{ .shift = true } }},
        .intent = .toggle_stats,
    },
    .{
        .id = .toggle_fullscreen,
        .title = "Toggle Fullscreen",
        .shortcut_text = "F / F11",
        .description = "Toggle borderless fullscreen mode",
        .show_in_palette = true,
        .shortcuts = &.{ .{ .key = .char_f }, .{ .key = .f11 } },
        .intent = .toggle_fullscreen,
    },
    .{
        .id = .file_finder,
        .title = "Open File Finder...",
        .shortcut_text = "Ctrl+P",
        .description = "Open fuzzy file search palette",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_p, .mod = .{ .ctrl = true } }},
        .intent = .{ .set_palette = .{ .mode = .files } },
    },
    .{
        .id = .directory_navigator,
        .title = "Navigate Directories...",
        .shortcut_text = "Ctrl+O",
        .description = "Open directory navigation palette",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_o, .mod = .{ .ctrl = true } }},
        .intent = .{ .set_palette = .{ .mode = .directory_navigator } },
    },
    .{
        .id = .toggle_debug_mode,
        .title = "Toggle Clay Debug Mode",
        .shortcut_text = "Ctrl+D",
        .description = "Toggle Clay UI layout debug borders and metrics",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_d, .mod = .{ .ctrl = true } }},
        .intent = .toggle_debug_mode,
        .ipc = .{ .name = "debug", .args = "<true|false>", .description = "Toggle Clay UI layout debug borders" },
    },
    .{
        .id = .toggle_debug_thumb,
        .title = "Toggle Debug Thumbnail Overlay",
        .shortcut_text = "Ctrl+T",
        .description = "Toggle embedded thumbnail preview overlay",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_t, .mod = .{ .ctrl = true } }},
        .intent = .toggle_debug_thumb,
        .ipc = .{ .name = "thumb", .args = "<toggle|true|false>", .description = "Toggle embedded thumbnail preview" },
    },
    .{
        .id = .quit,
        .title = "Quit",
        .shortcut_text = "Q / Esc",
        .description = "Exit the viewer",
        .show_in_palette = true,
        .shortcuts = &.{ .{ .key = .char_q }, .{ .key = .escape } },
        .intent = .quit,
        .ipc = .{ .name = "quit", .description = "Quit the viewer" },
    },
    .{
        .id = .first_image,
        .title = "First Image",
        .shortcut_text = "Home",
        .description = "Jump to first image in directory",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .home }},
        .intent = .first_image,
    },
    .{
        .id = .last_image,
        .title = "Last Image",
        .shortcut_text = "End",
        .description = "Jump to last image in directory",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .end }},
        .intent = .last_image,
    },
    .{
        .id = .zoom_in,
        .title = "Zoom In",
        .shortcut_text = "= / +",
        .description = "Zoom in by scaling viewport",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .equals }},
        .intent = .zoom_in,
    },
    .{
        .id = .zoom_out,
        .title = "Zoom Out",
        .shortcut_text = "-",
        .description = "Zoom out by scaling viewport",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .minus }},
        .intent = .zoom_out,
    },
    .{
        .id = .reset_zoom,
        .title = "Reset Zoom & Pan",
        .shortcut_text = "R / 0",
        .description = "Reset zoom factor and pan offset back to center",
        .show_in_palette = true,
        .shortcuts = &.{ .{ .key = .char_r }, .{ .key = .char_0 } },
        .intent = .reset_zoom,
    },
    .{
        .id = .scale_none,
        .title = "Set Scale Mode: 100% (Actual Size)",
        .description = "Display image at native 1:1 pixel resolution",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_scale = .none },
    },
    .{
        .id = .scale_shrink,
        .title = "Set Scale Mode: Fit if Larger (Shrink)",
        .description = "Downscale image to fit viewport only if larger than window",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_scale = .shrink },
    },
    .{
        .id = .scale_full,
        .title = "Set Scale Mode: Fit Window (Full)",
        .description = "Scale image to fit within window while preserving aspect ratio",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_scale = .full },
    },
    .{
        .id = .scale_crop,
        .title = "Set Scale Mode: Fill Window (Crop)",
        .description = "Scale image to completely fill window, cropping overflow",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_scale = .crop },
    },
    .{
        .id = .scale_fit_width,
        .title = "Set Scale Mode: Fit Width",
        .description = "Scale image width to match window width",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_scale = .fit_width },
    },
    .{
        .id = .scale_fit_height,
        .title = "Set Scale Mode: Fit Height",
        .description = "Scale image height to match window height",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_scale = .fit_height },
    },
    .{
        .id = .rotate_cw,
        .title = "Rotate Clockwise (90°)",
        .shortcut_text = "]",
        .description = "Rotate viewport clockwise by 90 degrees",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .right_bracket }},
        .intent = .rotate_cw,
    },
    .{
        .id = .rotate_ccw,
        .title = "Rotate Counter-Clockwise (90°)",
        .shortcut_text = "[",
        .description = "Rotate viewport counter-clockwise by 90 degrees",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .left_bracket }},
        .intent = .rotate_ccw,
    },
    .{
        .id = .reset_rotation,
        .title = "Reset Rotation",
        .description = "Reset rotation back to 0 degrees",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .reset_rotation,
    },
    .{
        .id = .filter_nearest,
        .title = "Set Scaling Filter: Nearest Neighbor",
        .description = "Sharp point sampling filter for pixel art",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_filter = .nearest },
    },
    .{
        .id = .filter_linear,
        .title = "Set Scaling Filter: Bilinear (Smooth)",
        .description = "Standard bilinear hardware texture filtering",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_filter = .linear },
    },
    .{
        .id = .filter_pixel_art,
        .title = "Set Scaling Filter: Pixel Art (Crisp)",
        .description = "Smooth pixel art scaling without blur or distortion",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_filter = .pixel_art },
    },
    .{
        .id = .filter_mitchell,
        .title = "Set Scaling Filter: Mitchell-Netravali (HQ Bicubic)",
        .description = "High-quality cubic filter balancing sharpness and ringing",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_filter = .mitchell },
    },
    .{
        .id = .filter_lanczos3,
        .title = "Set Scaling Filter: Lanczos3 (Ultra HQ Resampler)",
        .description = "Ultra high quality 3-lobe sinc reconstruction resampler",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_filter = .lanczos3 },
    },
    .{
        .id = .filter_lanczos3_spline,
        .title = "Set Scaling Filter: Lanczos3 Spline (Fast FMA Resampler)",
        .description = "Fast polynomial spline approximation of Lanczos3 filter",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_filter = .lanczos3_spline },
    },
    .{
        .id = .increase_brightness,
        .title = "Increase Brightness (+10%)",
        .shortcut_text = "P",
        .description = "Brighten image exposure by 10%",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_p }},
        .intent = .increase_brightness,
    },
    .{
        .id = .decrease_brightness,
        .title = "Decrease Brightness (-10%)",
        .shortcut_text = "O",
        .description = "Darken image exposure by 10%",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_o }},
        .intent = .decrease_brightness,
    },
    .{
        .id = .increase_contrast,
        .title = "Increase Contrast (+10%)",
        .shortcut_text = "L",
        .description = "Increase dynamic contrast by 10%",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_l }},
        .intent = .increase_contrast,
    },
    .{
        .id = .decrease_contrast,
        .title = "Decrease Contrast (-10%)",
        .shortcut_text = "K",
        .description = "Decrease dynamic contrast by 10%",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_k }},
        .intent = .decrease_contrast,
    },
    .{
        .id = .reset_adjustments,
        .title = "Reset Brightness & Contrast",
        .shortcut_text = "Shift+R",
        .description = "Reset color adjustments back to default (0 brightness, 1 contrast)",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_r, .mod = .{ .shift = true } }},
        .intent = .reset_adjustments,
    },
    .{
        .id = .set_brightness_dialog,
        .title = "Set Brightness (Type Value)...",
        .shortcut_text = "Shift+B",
        .description = "Open numeric input dialog to set exact brightness value (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_b, .mod = .{ .shift = true } }},
        .intent = .{ .set_palette = .{ .mode = .set_brightness } },
    },
    .{
        .id = .set_contrast_dialog,
        .title = "Set Contrast (Type Value)...",
        .shortcut_text = "Shift+C",
        .description = "Open numeric input dialog to set exact contrast value (0.0 to 5.0)",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_c, .mod = .{ .shift = true } }},
        .intent = .{ .set_palette = .{ .mode = .set_contrast } },
    },
    .{
        .id = .go_to_image_dialog,
        .title = "Go to Image...",
        .shortcut_text = "Shift+G",
        .description = "Open numeric input dialog to jump to image number",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_g, .mod = .{ .shift = true } }},
        .intent = .{ .set_palette = .{ .mode = .go_to_image } },
    },
    .{
        .id = .command_palette,
        .title = "Search Actions (Command Palette)",
        .shortcut_text = "F1 / Ctrl+Shift+P",
        .description = "Open interactive searchable command palette",
        .show_in_palette = true,
        .shortcuts = &.{ .{ .key = .f1 }, .{ .key = .char_p, .mod = .{ .ctrl = true, .shift = true } } },
        .intent = .{ .set_palette = .{ .mode = .actions } },
    },
    .{
        .id = .start_slideshow_dialog,
        .title = "Start Slide Show...",
        .description = "Open slideshow interval dialog and start automatic playback",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_slideshow_interval } },
    },
    .{
        .id = .stop_slideshow,
        .title = "Stop Slide Show",
        .description = "Pause or terminate automatic slideshow playback",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .stop_slideshow,
    },
    .{
        .id = .toggle_blur,
        .title = "Toggle Background Blur",
        .description = "Enable or disable glassmorphism background blur behind overlays",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .toggle_blur,
        .cli = &.{
            .{
                .id = .blur,
                .target = .main,
                .long = "--blur",
                .aliases = &.{"--enable-blur"},
                .description = "Enable glassmorphism background blur behind overlays (default)",
            },
            .{
                .id = .no_blur,
                .target = .main,
                .long = "--no-blur",
                .aliases = &.{"--disable-blur"},
                .description = "Disable glassmorphism background blur behind overlays",
            },
        },
    },

    // --- Non-Palette Capabilities (CLI flags and IPC verbs) ---
    .{
        .id = .scale_config,
        .title = "Scale Mode Configuration",
        .description = "Set fit mode (" ++ scale_modes_string ++ ")",
        .show_in_palette = false,
        .cli = &.{
            .{
                .id = .scale,
                .target = .main,
                .long = "--scale",
                .arg_name = "<mode>",
                .description = "Default image scaling mode (default: full)\n                             Modes: " ++ scale_modes_string,
            },
        },
        .ipc = .{
            .name = "scale",
            .args = "<mode>",
            .description = "Set fit mode (" ++ scale_modes_string ++ ")",
        },
    },
    .{
        .id = .zoom_config,
        .title = "Zoom Configuration",
        .description = "Set zoom factor (0.1 - 10.0)",
        .show_in_palette = false,
        .ipc = .{
            .name = "zoom",
            .args = "<factor>",
            .description = "Set zoom factor (0.1 - 10.0)",
        },
    },
    .{
        .id = .pan_config,
        .title = "Pan Configuration",
        .description = "Set pan offset in pixels",
        .show_in_palette = false,
        .ipc = .{
            .name = "pan",
            .args = "<x> <y>",
            .description = "Set pan offset in pixels",
        },
    },
    .{
        .id = .adjust_config,
        .title = "Color Adjustment Configuration",
        .description = "Adjust brightness and contrast",
        .show_in_palette = false,
        .ipc = .{
            .name = "adjust",
            .args = "<bright> <contrast>",
            .description = "Adjust brightness and contrast",
        },
    },
    .{
        .id = .filter_config,
        .title = "Resampling Filter Configuration",
        .description = "Apply resampling shader (" ++ filter_modes_string ++ ")",
        .show_in_palette = false,
        .ipc = .{
            .name = "filter",
            .args = "<name>",
            .description = "Apply resampling shader (" ++ filter_modes_string ++ ")",
        },
    },
    .{
        .id = .palette_config,
        .title = "Palette Mode Toggle",
        .description = "Toggle command/file palette",
        .show_in_palette = false,
        .ipc = .{
            .name = "palette",
            .args = "<action|files|none>",
            .description = "Toggle command/file palette",
        },
    },
    .{
        .id = .wait_load,
        .title = "Wait for Load",
        .description = "Wait for image decoding to complete",
        .show_in_palette = false,
        .ipc = .{
            .name = "wait_load",
            .description = "Wait for image decoding to complete",
        },
    },
};

/// Comptime-projected table of Command Palette items.
pub const palette_action_items = blk: {
    var count: usize = 0;
    for (actions) |a| {
        if (a.show_in_palette and a.intent != null) count += 1;
    }
    var result: [count]ActionMetadata = undefined;
    var idx: usize = 0;
    for (actions) |a| {
        if (a.show_in_palette) {
            if (a.intent) |intent| {
                result[idx] = .{
                    .name = a.title,
                    .shortcut_text = a.shortcut_text,
                    .show_in_palette = a.show_in_palette,
                    .shortcuts = a.shortcuts,
                    .intent = intent,
                };
                idx += 1;
            }
        }
    }
    break :blk result;
};

/// Comptime-projected flattened table of keyboard shortcuts directly mapped to AppIntent.
pub const flat_shortcuts = blk: {
    var count: usize = 0;
    for (actions) |a| {
        if (a.intent != null) {
            count += a.shortcuts.len;
        }
    }
    var list: [count]FlatShortcut = undefined;
    var idx: usize = 0;
    for (actions) |a| {
        if (a.intent) |intent| {
            for (a.shortcuts) |sc| {
                list[idx] = .{
                    .key = sc.key,
                    .mod = sc.mod,
                    .intent = intent,
                };
                idx += 1;
            }
        }
    }
    break :blk list;
};

/// Comptime-projected list of CLI options declared across capabilities.
pub const action_cli_options = blk: {
    var count: usize = 0;
    for (actions) |a| {
        count += a.cli.len;
    }
    var list: [count]CliOption = undefined;
    var idx: usize = 0;
    for (actions) |a| {
        for (a.cli) |opt| {
            list[idx] = opt;
            idx += 1;
        }
    }
    break :blk list;
};

/// Comptime-projected list of IPC commands declared across capabilities.
pub const ipc_commands = blk: {
    var count: usize = 0;
    for (actions) |a| {
        if (a.ipc != null) count += 1;
    }
    var list: [count]IpcCommandDesc = undefined;
    var idx: usize = 0;
    for (actions) |a| {
        if (a.ipc) |cmd| {
            list[idx] = cmd;
            idx += 1;
        }
    }
    break :blk list;
};

test "actions registry projections" {
    const testing = std.testing;

    // Palette count matches original 43 items
    try testing.expectEqual(@as(usize, 43), palette_action_items.len);

    // Exact index preservation
    try testing.expectEqualStrings("Navigate Directories...", palette_action_items[7].name);
    try testing.expectEqualStrings("Ctrl+O", palette_action_items[7].shortcut_text);

    // Shortcuts projection
    var total_sc: usize = 0;
    for (palette_action_items) |item| {
        total_sc += item.shortcuts.len;
    }
    try testing.expectEqual(total_sc, flat_shortcuts.len);

    // CLI options projection
    try testing.expectEqual(@as(usize, 3), action_cli_options.len);
    try testing.expectEqual(OptionId.blur, action_cli_options[0].id);
    try testing.expectEqual(OptionId.no_blur, action_cli_options[1].id);
    try testing.expectEqual(OptionId.scale, action_cli_options[2].id);

    // IPC commands projection
    try testing.expectEqual(@as(usize, 12), ipc_commands.len);
}

test "actions registry invariants and consistency" {
    const testing = std.testing;

    // 1. Verify ActionId uniqueness across all actions
    for (actions, 0..) |a1, i| {
        for (actions[i + 1 ..]) |a2| {
            try testing.expect(a1.id != a2.id);
        }
    }

    // 2. Verify all palette actions have non-empty titles and valid intents
    for (palette_action_items) |item| {
        try testing.expect(item.name.len > 0);
        try testing.expect(item.show_in_palette);
    }

    // 3. Verify all CLI options have valid prefixes and descriptions
    for (action_cli_options) |opt| {
        try testing.expect(std.mem.startsWith(u8, opt.long, "--"));
        if (opt.short) |s| {
            try testing.expect(std.mem.startsWith(u8, s, "-"));
        }
        for (opt.aliases) |alias| {
            try testing.expect(std.mem.startsWith(u8, alias, "--") or std.mem.startsWith(u8, alias, "-"));
        }
        try testing.expect(opt.description.len > 0);
    }

    // 4. Verify all IPC command descriptors have valid names and descriptions
    for (ipc_commands) |cmd| {
        try testing.expect(cmd.name.len > 0);
        try testing.expect(cmd.description.len > 0);
    }

    // 5. Verify shortcut resolution for Ctrl+P (File Finder)
    var found_ctrl_p = false;
    for (flat_shortcuts) |sc| {
        if (sc.key == .char_p and sc.mod.ctrl and !sc.mod.shift and !sc.mod.alt) {
            found_ctrl_p = true;
            try testing.expectEqual(PaletteMode.files, sc.intent.set_palette.mode);
        }
    }
    try testing.expect(found_ctrl_p);
}
