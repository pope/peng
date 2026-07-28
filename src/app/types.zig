const std = @import("std");
const sdl = @import("sdl");

pub const ScaleMode = enum {
    none,
    shrink,
    full,
    crop,
};

/// Defines GPU texture resampling algorithms supported by resampling shaders.
pub const TextureScaleMode = enum {
    nearest,
    linear,
    pixel_art,
    mitchell,
    lanczos3,

    /// Returns the corresponding integer identifier for GPU fragment shader uniform push constants.
    pub fn toScaleModeInt(self: TextureScaleMode) i32 {
        return switch (self) {
            .nearest => 0,
            .linear => 1,
            .pixel_art => 2,
            .mitchell => 3,
            .lanczos3 => 4,
        };
    }
};

/// Unified parameters describing image view transforms, color adjustments, and window fitting modes
/// passed down to rendering pipelines.
pub const ViewportParams = struct {
    zoom_factor: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    rotation_angle: f32 = 0.0,
    brightness: f32 = 0.0,
    contrast: f32 = 1.0,
    texture_scale_mode: TextureScaleMode = .linear,
    fit_mode: ScaleMode = .full,

    /// Resets 2D zoom factor and pan offsets back to default values.
    pub fn reset(self: *ViewportParams) void {
        self.zoom_factor = 1.0;
        self.pan_x = 0.0;
        self.pan_y = 0.0;
    }

    /// Returns the integer scale mode identifier required by fragment shader uniform push constants.
    pub inline fn getShaderScaleModeInt(self: ViewportParams) i32 {
        return self.texture_scale_mode.toScaleModeInt();
    }
};

/// Defines numeric boundaries (min/max range) for text input modal dialogs.
pub const TextInputBounds = struct {
    min: f32,
    max: f32,
};

/// Tagged enum representing active Command Palette and Modal Overlay view modes.
pub const PaletteMode = enum {
    inactive,
    files,
    actions,
    set_brightness,
    set_contrast,
    go_to_image,
    directory_navigator,
    set_slideshow_interval,

    /// Returns true if this palette mode represents an active text entry dialog.
    pub fn isTextInputDialog(self: PaletteMode) bool {
        return switch (self) {
            .set_brightness, .set_contrast, .go_to_image, .set_slideshow_interval => true,
            .inactive, .files, .actions, .directory_navigator => false,
        };
    }

    /// Returns the valid numeric range for text input dialogs, or null for search modes.
    pub fn getTextInputBounds(self: PaletteMode) ?TextInputBounds {
        return switch (self) {
            .set_brightness => .{ .min = -1.0, .max = 1.0 },
            .set_contrast => .{ .min = 0.0, .max = 5.0 },
            .set_slideshow_interval => .{ .min = 0.1, .max = 3600.0 },
            .go_to_image, .inactive, .files, .actions, .directory_navigator => null,
        };
    }
};

/// Data-driven event payload unifying keyboard shortcuts, IPC socket messages,
/// command palette triggers, and automated test instructions.
pub const AppEvent = union(enum) {
    action: AppActionId,
    set_zoom: f32,
    set_pan: struct { dx: f32, dy: f32 },
    set_adjustments: struct { brightness: f32, contrast: f32 },
    set_filter: TextureScaleMode,
    set_palette_mode: PaletteMode,
    set_debug: bool,
    wait_load,
    screenshot: struct { path: []const u8, stream: ?std.net.Stream = null },
    quit,
};

pub const MeasureTextUserData = struct {
    fonts: []const ?sdl.Font,
    allocator: std.mem.Allocator,
    /// Transient flag active only during clay.endLayout() when Clay's internal debug panel
    /// elements are being measured. Signals sdl3MeasureText to apply theme.debug_font_scale (0.75)
    /// so text bounding boxes match the smaller 12px debug font size.
    is_debug_measuring: bool = false,
};

pub const KeyModifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    gui: bool = false,
};

pub const Key = enum {
    escape,
    return_key,
    backspace,
    tab,
    space,
    left,
    right,
    up,
    down,
    equals,
    minus,
    left_bracket,
    right_bracket,
    home,
    end,
    page_up,
    page_down,
    f1,
    f11,
    char_0,
    char_1,
    char_2,
    char_3,
    char_4,
    char_5,
    char_6,
    char_7,
    char_8,
    char_9,
    char_a,
    char_b,
    char_c,
    char_d,
    char_e,
    char_f,
    char_g,
    char_h,
    char_i,
    char_j,
    char_k,
    char_l,
    char_m,
    char_n,
    char_o,
    char_p,
    char_q,
    char_r,
    char_s,
    char_t,
    char_u,
    char_v,
    char_w,
    char_x,
    char_y,
    char_z,
    unknown,
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
    quit_requested: bool,
    scroll_delta_x: f32,
    scroll_delta_y: f32,

    keys_pressed: std.ArrayList(Key),
    key_modifiers: KeyModifiers,
    text_input: ?[]const u8,
    dropped_path: ?[]const u8,

    ticks: u64,
    delta_time_ms: f32,

    pub fn pixMouseX(self: FrameInput) f32 {
        return self.mouse_x * self.scale_x;
    }

    pub fn pixMouseY(self: FrameInput) f32 {
        return self.mouse_y * self.scale_y;
    }
};

pub const AppActionId = enum {
    next_image,
    prev_image,
    toggle_info,
    toggle_stats,
    toggle_fullscreen,
    open_file_finder,
    open_directory_navigator,
    toggle_debug_mode,
    toggle_debug_thumb,
    exit,
    first_image,
    last_image,
    zoom_in,
    zoom_out,
    reset_zoom,
    set_scale_none,
    set_scale_shrink,
    set_scale_full,
    set_scale_crop,
    rotate_cw,
    rotate_ccw,
    reset_rotation,
    set_filter_nearest,
    set_filter_linear,
    set_filter_pixel_art,
    set_filter_mitchell,
    set_filter_lanczos3,
    increase_brightness,
    decrease_brightness,
    increase_contrast,
    decrease_contrast,
    reset_adjustments,
    set_brightness_value,
    set_contrast_value,
    go_to_image,
    open_action_palette,
    start_slideshow,
    stop_slideshow,
};

pub const KeyboardShortcut = struct {
    key: Key,
    mod: KeyModifiers = .{},
};

pub const ActionMetadata = struct {
    name: []const u8,
    shortcut_text: []const u8,
    show_in_palette: bool,
    shortcuts: []const KeyboardShortcut,
};

pub fn getActionMetadata(action_id: AppActionId) ActionMetadata {
    return switch (action_id) {
        .next_image => .{
            .name = "Next Image",
            .shortcut_text = "Space / Right",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .space },
                .{ .key = .right },
            },
        },
        .prev_image => .{
            .name = "Previous Image",
            .shortcut_text = "Backspace / Left",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .backspace },
                .{ .key = .left },
            },
        },
        .toggle_info => .{
            .name = "Toggle Image Info",
            .shortcut_text = "I",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_i },
            },
        },
        .toggle_stats => .{
            .name = "Toggle Stats for Nerds",
            .shortcut_text = "Shift+I",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_i, .mod = .{ .shift = true } },
            },
        },
        .toggle_fullscreen => .{
            .name = "Toggle Fullscreen",
            .shortcut_text = "F / F11",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_f },
                .{ .key = .f11 },
            },
        },
        .open_file_finder => .{
            .name = "Search Files (Go to File)",
            .shortcut_text = "Ctrl+P",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_p, .mod = .{ .ctrl = true } },
                .{ .key = .char_p, .mod = .{ .gui = true } },
            },
        },
        .open_directory_navigator => .{
            .name = "Navigate Directories...",
            .shortcut_text = "Ctrl+O",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_o, .mod = .{ .ctrl = true } },
            },
        },
        .toggle_debug_mode => .{
            .name = "Toggle Clay Debug Mode",
            .shortcut_text = "D",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_d },
            },
        },
        .toggle_debug_thumb => .{
            .name = "Toggle EXIF Thumbnail Debug View",
            .shortcut_text = "T",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_t },
            },
        },
        .exit => .{
            .name = "Exit Application",
            .shortcut_text = "Esc",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .escape },
            },
        },
        .first_image => .{
            .name = "First Image",
            .shortcut_text = "Home",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .home },
            },
        },
        .last_image => .{
            .name = "Last Image",
            .shortcut_text = "End",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .end },
            },
        },
        .zoom_in => .{
            .name = "Zoom In",
            .shortcut_text = "= / +",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .equals },
            },
        },
        .zoom_out => .{
            .name = "Zoom Out",
            .shortcut_text = "-",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .minus },
            },
        },
        .reset_zoom => .{
            .name = "Reset Zoom & Pan",
            .shortcut_text = "R / 0",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_r },
                .{ .key = .char_0 },
            },
        },
        .set_scale_none => .{
            .name = "Set Scale Mode: 100% (Actual Size)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_scale_shrink => .{
            .name = "Set Scale Mode: Fit if Larger (Shrink)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_scale_full => .{
            .name = "Set Scale Mode: Fit Window (Full)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_scale_crop => .{
            .name = "Set Scale Mode: Fill Window (Crop)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .rotate_cw => .{
            .name = "Rotate Clockwise (90°)",
            .shortcut_text = "]",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .right_bracket },
            },
        },
        .rotate_ccw => .{
            .name = "Rotate Counter-Clockwise (90°)",
            .shortcut_text = "[",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .left_bracket },
            },
        },
        .reset_rotation => .{
            .name = "Reset Rotation",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_nearest => .{
            .name = "Set Scaling Filter: Nearest Neighbor",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_linear => .{
            .name = "Set Scaling Filter: Bilinear (Smooth)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_pixel_art => .{
            .name = "Set Scaling Filter: Pixel Art (Crisp)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_mitchell => .{
            .name = "Set Scaling Filter: Mitchell-Netravali (HQ Bicubic)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .set_filter_lanczos3 => .{
            .name = "Set Scaling Filter: Lanczos3 (Ultra HQ Resampler)",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .increase_brightness => .{
            .name = "Increase Brightness (+10%)",
            .shortcut_text = "P",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_p },
            },
        },
        .decrease_brightness => .{
            .name = "Decrease Brightness (-10%)",
            .shortcut_text = "O",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_o },
            },
        },
        .increase_contrast => .{
            .name = "Increase Contrast (+10%)",
            .shortcut_text = "L",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_l },
            },
        },
        .decrease_contrast => .{
            .name = "Decrease Contrast (-10%)",
            .shortcut_text = "K",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_k },
            },
        },
        .reset_adjustments => .{
            .name = "Reset Brightness & Contrast",
            .shortcut_text = "Shift+R",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_r, .mod = .{ .shift = true } },
            },
        },
        .set_brightness_value => .{
            .name = "Set Brightness (Type Value)...",
            .shortcut_text = "Shift+B",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_b, .mod = .{ .shift = true } },
            },
        },
        .set_contrast_value => .{
            .name = "Set Contrast (Type Value)...",
            .shortcut_text = "Shift+C",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_c, .mod = .{ .shift = true } },
            },
        },
        .go_to_image => .{
            .name = "Go to Image...",
            .shortcut_text = "Shift+G",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .char_g, .mod = .{ .shift = true } },
            },
        },
        .open_action_palette => .{
            .name = "Search Actions (Command Palette)",
            .shortcut_text = "F1 / Ctrl+Shift+P",
            .show_in_palette = true,
            .shortcuts = &.{
                .{ .key = .f1 },
                .{ .key = .char_p, .mod = .{ .ctrl = true, .shift = true } },
                .{ .key = .char_p, .mod = .{ .gui = true, .shift = true } },
            },
        },
        .start_slideshow => .{
            .name = "Start Slide Show...",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
        .stop_slideshow => .{
            .name = "Stop Slide Show",
            .shortcut_text = "",
            .show_in_palette = true,
            .shortcuts = &.{},
        },
    };
}

pub const app_actions = std.enums.values(AppActionId);

pub const FlatShortcut = struct {
    key: Key,
    mod: KeyModifiers,
    action_id: AppActionId,
};

pub const flat_shortcuts = blk: {
    var count: usize = 0;
    for (app_actions) |action_id| {
        count += getActionMetadata(action_id).shortcuts.len;
    }
    var list: [count]FlatShortcut = undefined;
    var idx: usize = 0;
    for (app_actions) |action_id| {
        const meta = getActionMetadata(action_id);
        for (meta.shortcuts) |sc| {
            list[idx] = .{
                .key = sc.key,
                .mod = sc.mod,
                .action_id = action_id,
            };
            idx += 1;
        }
    }
    break :blk list;
};

test "PaletteMode.getTextInputBounds" {
    const brightness_bounds = PaletteMode.set_brightness.getTextInputBounds().?;
    try std.testing.expectEqual(@as(f32, -1.0), brightness_bounds.min);
    try std.testing.expectEqual(@as(f32, 1.0), brightness_bounds.max);

    const contrast_bounds = PaletteMode.set_contrast.getTextInputBounds().?;
    try std.testing.expectEqual(@as(f32, 0.0), contrast_bounds.min);
    try std.testing.expectEqual(@as(f32, 5.0), contrast_bounds.max);

    try std.testing.expect(PaletteMode.files.getTextInputBounds() == null);
}
