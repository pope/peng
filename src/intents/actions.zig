//! Unified Action & Capability Registry
//!
//! Centralized single source of truth for application capabilities, keybindings,
//! UI Command Palette entries, command-line flags, and remote IPC verbs.

const std = @import("std");
const keys = @import("keys.zig");
const types = @import("types.zig");

const AppIntent = types.AppIntent;
const Key = keys.Key;
const KeyModifiers = keys.KeyModifiers;
const KeyboardShortcut = keys.KeyboardShortcut;
const PaletteMode = types.PaletteMode;
const ScaleMode = types.ScaleMode;
const TextureScaleMode = types.TextureScaleMode;
const scale_modes_string = types.scale_modes_string;
const filter_modes_string = types.filter_modes_string;

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
    title,
    ipc,
    headless,
    test_mode,
    update_baselines,
    windowless,
};

/// Declarative schema describing a command-line option, its target app,
/// aliases, placeholder, and description.
pub const CliOption = struct {
    id: OptionId,
    target: CliTarget = .both,
    short: ?[]const u8 = null,
    long: []const u8,
    aliases: []const []const u8 = &.{},
    arg_name: ?[]const u8 = null,
    description: []const u8,

    /// Returns true if the given argument matches this option's short flag,
    /// long flag, or any alias.
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

/// Metadata describing an action executable from the Command Palette,
/// including its shortcut and intent.
pub const ActionMetadata = struct {
    name: []const u8,
    shortcut_text: []const u8,
    show_in_palette: bool,
    shortcuts: []const KeyboardShortcut,
    intent: AppIntent,
};

/// Flattened keyboard shortcut entry mapping a specific key and modifier
/// combination directly to an AppIntent.
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
    refresh_directory,

    // Image triage & classification
    mark_pick,
    mark_reject,
    unflag,
    cycle_view_mode,

    // Overlays & UI
    toggle_info,
    toggle_manga_mode,
    toggle_stats,
    toggle_edit_panel,
    toggle_title,
    toggle_snackbar,
    toggle_crossfade,
    toggle_fullscreen,
    toggle_windowless,
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
    cycle_scale_mode,
    scale_none,
    scale_shrink,
    scale_full,
    scale_crop,
    scale_fit_width,
    scale_fit_height,

    // Resampling Filters (individual palette items)
    cycle_filter,
    cycle_filter_prev,
    filter_nearest,
    filter_linear,
    filter_pixel_art,
    filter_mitchell,
    filter_lanczos3,
    filter_fsr,
    filter_tiny_cnn,

    // Color adjustments
    increase_brightness,
    decrease_brightness,
    increase_contrast,
    decrease_contrast,
    reset_adjustments,
    toggle_compare,
    set_brightness_dialog,
    set_contrast_dialog,
    set_contrast_blend_dialog,
    set_highlights_dialog,
    set_shadows_dialog,
    set_whites_dialog,
    set_blacks_dialog,
    set_temperature_dialog,
    set_tint_dialog,
    set_vibrance_dialog,
    set_saturation_dialog,
    set_clarity_dialog,
    set_texture_dialog,

    // Lifecycle
    quit,

    // Non-palette capabilities (CLI / IPC parameters)
    scale_config,
    zoom_config,
    pan_config,
    adjust_config,
    compare_config,
    filter_config,
    palette_config,
    view_config,
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
        .shortcut_text = "Space / n / ] / Right",
        .description = "Advance to the next image in the active queue",
        .show_in_palette = true,
        .shortcuts = &.{
            .{ .key = .space },
            .{ .key = .right },
            .{ .key = .char_n },
            .{ .key = .right_bracket },
        },
        .intent = .next_image,
        .ipc = .{ .name = "next / prev", .description = "Navigate images" },
    },
    .{
        .id = .prev_image,
        .title = "Previous Image",
        .shortcut_text = "Backspace / p / [ / Left",
        .description = "Return to the previous image in the active queue",
        .show_in_palette = true,
        .shortcuts = &.{
            .{ .key = .backspace },
            .{ .key = .left },
            .{ .key = .char_p },
            .{ .key = .left_bracket },
        },
        .intent = .prev_image,
    },
    .{
        .id = .toggle_info,
        .title = "Toggle Image Info",
        .shortcut_text = "D",
        .description = "Toggle image metadata and file info overlay",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_d }},
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
        .ipc = .{
            .name = "manga",
            .args = "<true|false>",
            .description = "Toggle RTL manga reading mode",
        },
    },
    .{
        .id = .toggle_stats,
        .title = "Toggle Stats for Nerds (Performance Overlay)",
        .shortcut_text = "Shift+D / Shift+I",
        .description = "Toggle rendering FPS, frame timing, and performance metrics",
        .show_in_palette = true,
        .shortcuts = &.{
            .{ .key = .char_d, .mod = .{ .shift = true } },
            .{ .key = .char_i, .mod = .{ .shift = true } },
        },
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
        .ipc = .{
            .name = "debug",
            .args = "<true|false>",
            .description = "Toggle Clay UI layout debug borders",
        },
    },
    .{
        .id = .toggle_debug_thumb,
        .title = "Toggle Debug Thumbnail Overlay",
        .shortcut_text = "Ctrl+T",
        .description = "Toggle embedded thumbnail preview overlay",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_t, .mod = .{ .ctrl = true } }},
        .intent = .toggle_debug_thumb,
        .ipc = .{
            .name = "thumb",
            .args = "<toggle|true|false>",
            .description = "Toggle embedded thumbnail preview",
        },
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
        .shortcut_text = "I / = / +",
        .description = "Zoom in by scaling viewport",
        .show_in_palette = true,
        .shortcuts = &.{ .{ .key = .char_i }, .{ .key = .equals } },
        .intent = .zoom_in,
    },
    .{
        .id = .zoom_out,
        .title = "Zoom Out",
        .shortcut_text = "O / -",
        .description = "Zoom out by scaling viewport",
        .show_in_palette = true,
        .shortcuts = &.{ .{ .key = .char_o }, .{ .key = .minus } },
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
        .shortcut_text = "A",
        .description = "Display image at native 1:1 pixel resolution",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_a }},
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
        .shortcut_text = ">",
        .description = "Rotate viewport clockwise by 90 degrees",
        .show_in_palette = true,
        .shortcuts = &.{
            .{ .key = .greater },
            .{ .key = .period, .mod = .{ .shift = true } },
        },
        .intent = .rotate_cw,
    },
    .{
        .id = .rotate_ccw,
        .title = "Rotate Counter-Clockwise (90°)",
        .shortcut_text = "<",
        .description = "Rotate viewport counter-clockwise by 90 degrees",
        .show_in_palette = true,
        .shortcuts = &.{
            .{ .key = .less },
            .{ .key = .comma, .mod = .{ .shift = true } },
        },
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
        .id = .filter_fsr,
        .title = "Set Scaling Filter: AMD FSR 1.0 (EASU + RCAS)",
        .description = "Directional edge reconstruction with contrast-adaptive sharpening",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_filter = .fsr },
    },
    .{
        .id = .filter_tiny_cnn,
        .title = "Set Scaling Filter: Tiny CNN (Neural Super-Resolution)",
        .description = "Learned sub-pixel convolutional neural network running in GPU registers",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_filter = .tiny_cnn },
    },
    .{
        .id = .toggle_edit_panel,
        .title = "Toggle Edit Panel",
        .shortcut_text = "E",
        .description = "Open or close image adjustments side panel",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_e }},
        .intent = .toggle_edit_panel,
        .ipc = .{
            .name = "edit",
            .args = "<on|off|toggle|reset>",
            .description = "Image adjustments side panel (on/off/toggle/reset)",
        },
    },
    .{
        .id = .increase_brightness,
        .title = "Increase Brightness (+5%)",
        .shortcut_text = "B",
        .description = "Brighten image exposure by 5%",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_b }},
        .intent = .{
            .adjust = .{
                .step = .{ .param = .brightness, .direction = .up },
            },
        },
    },
    .{
        .id = .decrease_brightness,
        .title = "Decrease Brightness (-5%)",
        .shortcut_text = "Shift+B",
        .description = "Darken image exposure by 5%",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_b, .mod = .{ .shift = true } }},
        .intent = .{
            .adjust = .{
                .step = .{ .param = .brightness, .direction = .down },
            },
        },
    },
    .{
        .id = .increase_contrast,
        .title = "Increase Contrast (+5%)",
        .shortcut_text = "C",
        .description = "Increase dynamic contrast by 5%",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_c }},
        .intent = .{
            .adjust = .{
                .step = .{ .param = .contrast, .direction = .up },
            },
        },
    },
    .{
        .id = .decrease_contrast,
        .title = "Decrease Contrast (-5%)",
        .shortcut_text = "Shift+C",
        .description = "Decrease dynamic contrast by 5%",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_c, .mod = .{ .shift = true } }},
        .intent = .{
            .adjust = .{
                .step = .{ .param = .contrast, .direction = .down },
            },
        },
    },
    .{
        .id = .reset_adjustments,
        .title = "Reset Adjustments",
        .shortcut_text = "Shift+R",
        .description = "Reset all color and tonal adjustments back to neutral defaults",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_r, .mod = .{ .shift = true } }},
        .intent = .{ .adjust = .reset_all },
    },
    .{
        .id = .toggle_compare,
        .title = "Toggle Before / After (Original vs Adjusted)",
        .shortcut_text = "\\",
        .description = "Compare original unadjusted image with current adjustments",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .backslash }},
        .intent = .{ .adjust = .toggle_compare },
    },
    .{
        .id = .set_brightness_dialog,
        .title = "Set Brightness (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set brightness (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_brightness } },
    },
    .{
        .id = .set_contrast_dialog,
        .title = "Set Contrast (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set exact contrast (0.0 to 3.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_contrast } },
    },
    .{
        .id = .set_contrast_blend_dialog,
        .title = "Set Contrast Blend (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog for contrast blend (0.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_contrast_blend } },
    },
    .{
        .id = .set_highlights_dialog,
        .title = "Set Highlights (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set highlights (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_highlights } },
    },
    .{
        .id = .set_shadows_dialog,
        .title = "Set Shadows (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set shadows (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_shadows } },
    },
    .{
        .id = .set_whites_dialog,
        .title = "Set Whites (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set exact whites (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_whites } },
    },
    .{
        .id = .set_blacks_dialog,
        .title = "Set Blacks (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set exact blacks (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_blacks } },
    },
    .{
        .id = .set_temperature_dialog,
        .title = "Set Temperature (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set temperature (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_temperature } },
    },
    .{
        .id = .set_tint_dialog,
        .title = "Set Tint (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set exact tint (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_tint } },
    },
    .{
        .id = .set_vibrance_dialog,
        .title = "Set Vibrance (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set vibrance (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_vibrance } },
    },
    .{
        .id = .set_saturation_dialog,
        .title = "Set Saturation (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set saturation (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_saturation } },
    },
    .{
        .id = .set_clarity_dialog,
        .title = "Set Clarity (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set clarity (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_clarity } },
    },
    .{
        .id = .set_texture_dialog,
        .title = "Set Texture (Type Value)...",
        .shortcut_text = "",
        .description = "Open numeric input dialog to set texture (-1.0 to 1.0)",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .{ .set_palette = .{ .mode = .set_texture } },
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
        .shortcut_text = ": / ? / F1 / Ctrl+Shift+P",
        .description = "Open interactive searchable command palette",
        .show_in_palette = true,
        .shortcuts = &.{
            .{ .key = .f1 },
            .{ .key = .char_p, .mod = .{ .ctrl = true, .shift = true } },
            .{ .key = .colon },
            .{ .key = .semicolon, .mod = .{ .shift = true } },
            .{ .key = .slash },
            .{ .key = .question },
            .{ .key = .slash, .mod = .{ .shift = true } },
        },
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
    .{
        .id = .toggle_title,
        .title = "Toggle Title Bar Overlay",
        .shortcut_text = "T",
        .description = "Toggle floating blurred title bar overlay on top of image",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_t }},
        .intent = .toggle_title,
        .cli = &.{
            .{
                .id = .title,
                .target = .main,
                .long = "--title",
                .aliases = &.{"--title-overlay"},
                .description = "Show floating title bar overlay on startup",
            },
        },
        .ipc = .{
            .name = "title",
            .args = "<toggle|true|false>",
            .description = "Toggle or set floating title bar overlay",
        },
    },
    .{
        .id = .toggle_snackbar,
        .title = "Toggle Snackbar Notifications",
        .shortcut_text = "",
        .description = "Toggle visual notification confirmations for app actions",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .toggle_snackbar,
        .ipc = .{
            .name = "snackbar",
            .args = "<toggle|true|false>",
            .description = "Toggle or set visual snackbar notifications",
        },
    },
    .{
        .id = .toggle_crossfade,
        .title = "Toggle Image Crossfade",
        .shortcut_text = "",
        .description = "Toggle smooth dissolve transitions during image navigation",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .toggle_crossfade,
        .ipc = .{
            .name = "crossfade",
            .args = "<on|off|toggle>",
            .description = "Toggle image navigation crossfade dissolve transition",
        },
    },
    .{
        .id = .cycle_scale_mode,
        .title = "Cycle Scale Mode",
        .shortcut_text = "S",
        .description = "Cycle through image scaling modes " ++
            "(Shrink, Full, Crop, Actual, Fit Width/Height)",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_s }},
        .intent = .cycle_scale_mode,
    },
    .{
        .id = .cycle_filter,
        .title = "Cycle Resampling Filter",
        .shortcut_text = "Shift+S",
        .description = "Cycle through GPU resampling shaders " ++
            "(Nearest, Linear, Mitchell, Lanczos3, etc.)",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_s, .mod = .{ .shift = true } }},
        .intent = .cycle_filter,
    },
    .{
        .id = .cycle_filter_prev,
        .title = "Cycle Resampling Filter (Previous)",
        .shortcut_text = "Alt+Shift+S",
        .description = "Cycle backward through GPU resampling shaders in reverse order",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_s, .mod = .{ .shift = true, .alt = true } }},
        .intent = .cycle_filter_prev,
    },
    .{
        .id = .refresh_directory,
        .title = "Refresh Directory",
        .shortcut_text = "F5 / Ctrl+R",
        .description = "Re-scan the current directory or archive to pick up added/removed files",
        .show_in_palette = true,
        .shortcuts = &.{
            .{ .key = .f5 },
            .{ .key = .char_r, .mod = .{ .ctrl = true } },
        },
        .intent = .refresh_directory,
    },
    .{
        .id = .toggle_windowless,
        .title = "Toggle Windowless Mode (Borderless)",
        .description = "Toggle window borders and decorations",
        .show_in_palette = true,
        .shortcuts = &.{},
        .intent = .toggle_windowless,
        .cli = &.{.{
            .id = .windowless,
            .target = .main,
            .short = "-W",
            .long = "--windowless",
            .aliases = &.{ "--borderless", "--undecorated" },
            .description = "Start in borderless/windowless mode (no titlebar chrome)",
        }},
        .ipc = .{
            .name = "windowless / borderless",
            .args = "<toggle|true|false>",
            .description = "Toggle windowless/borderless mode",
        },
    },
    .{
        .id = .mark_pick,
        .title = "Flag as Pick",
        .shortcut_text = "z",
        .description = "Flag current image as Pick",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_z }},
        .intent = .mark_pick,
        .ipc = .{ .name = "pick", .description = "Flag current image as Pick" },
    },
    .{
        .id = .mark_reject,
        .title = "Flag as Reject",
        .shortcut_text = "x",
        .description = "Flag current image as Reject",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_x }},
        .intent = .mark_reject,
        .ipc = .{ .name = "reject", .description = "Flag current image as Reject" },
    },
    .{
        .id = .unflag,
        .title = "Unflag Image",
        .shortcut_text = "u",
        .description = "Clear triage flag on current image",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_u }},
        .intent = .unflag,
        .ipc = .{ .name = "unflag", .description = "Clear triage flag on current image" },
    },
    .{
        .id = .cycle_view_mode,
        .title = "Cycle View Filter",
        .shortcut_text = "v",
        .description = "Cycle active view filter (Default, Picks, Rejects, Unflagged, All)",
        .show_in_palette = true,
        .shortcuts = &.{.{ .key = .char_v }},
        .intent = .cycle_view_mode,
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
                .description = "Default image scaling mode (default: full)\n" ++
                    "                             Modes: " ++ scale_modes_string,
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
        .id = .compare_config,
        .title = "Compare Mode Configuration",
        .description = "Toggle Before/After comparison mode",
        .show_in_palette = false,
        .ipc = .{
            .name = "compare",
            .args = "[on|off|toggle]",
            .description = "Toggle Before/After comparison mode",
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
        .id = .view_config,
        .title = "Set View Filter",
        .description = "Set active view filter mode",
        .show_in_palette = false,
        .ipc = .{
            .name = "view",
            .args = "<default|unflagged|picks|rejects|all>",
            .description = "Set active view filter mode",
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

    // Palette count: 58 previous + 11 photo adjustment dialogs = 69
    try testing.expectEqual(@as(usize, 69), palette_action_items.len);

    // Exact index preservation
    try testing.expectEqualStrings("Navigate Directories...", palette_action_items[7].name);
    try testing.expectEqualStrings("Ctrl+O", palette_action_items[7].shortcut_text);

    // Shortcuts: 54 previous + 4 triage keys (z, x, u, v) = 58
    try testing.expectEqual(@as(usize, 58), flat_shortcuts.len);
    var total_sc: usize = 0;
    for (palette_action_items) |item| {
        total_sc += item.shortcuts.len;
    }
    try testing.expectEqual(total_sc, flat_shortcuts.len);

    // CLI options projection
    try testing.expectEqual(@as(usize, 5), action_cli_options.len);
    try testing.expectEqual(OptionId.blur, action_cli_options[0].id);
    try testing.expectEqual(OptionId.no_blur, action_cli_options[1].id);
    try testing.expectEqual(OptionId.title, action_cli_options[2].id);
    try testing.expectEqual(OptionId.windowless, action_cli_options[3].id);
    try testing.expectEqual(OptionId.scale, action_cli_options[4].id);

    // IPC commands projection: 18 previous + 4 triage commands (pick, reject, unflag, view) = 22
    try testing.expectEqual(@as(usize, 22), ipc_commands.len);
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
            const has_prefix = std.mem.startsWith(u8, alias, "--") or
                std.mem.startsWith(u8, alias, "-");
            try testing.expect(has_prefix);
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
        if (sc.key == .char_p and sc.mod.eql(.{ .ctrl = true })) {
            found_ctrl_p = true;
            try testing.expectEqual(PaletteMode.files, sc.intent.set_palette.mode);
        }
    }
    try testing.expect(found_ctrl_p);

    // 6. Verify shortcut resolution for Shift+D and Shift+I (Toggle Stats for Nerds)
    var found_shift_d = false;
    var found_shift_i = false;
    for (flat_shortcuts) |sc| {
        if (sc.key == .char_d and sc.mod.eql(.{ .shift = true })) {
            if (sc.intent == .toggle_stats) found_shift_d = true;
        }
        if (sc.key == .char_i and sc.mod.eql(.{ .shift = true })) {
            if (sc.intent == .toggle_stats) found_shift_i = true;
        }
    }
    try testing.expect(found_shift_d);
    try testing.expect(found_shift_i);
}
