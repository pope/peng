const std = @import("std");
const sdl = @import("sdl");

const intents = @import("intents");

/// Unified parameters describing image view transforms, color adjustments, and window fitting modes
/// passed down to rendering pipelines.
pub const ViewportParams = struct {
    zoom_factor: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    rotation_angle: f32 = 0.0,
    brightness: f32 = 0.0,
    contrast: f32 = 1.0,
    texture_scale_mode: intents.TextureScaleMode = .linear,
    fit_mode: intents.ScaleMode = .full,

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

/// Plain data snapshot containing viewport dimensions, DPI scaling factors, and screen mode for frame layout/rendering.
pub const ViewParams = struct {
    viewport: ViewportParams = .{},
    win_w: f32 = 1024.0,
    win_h: f32 = 768.0,
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    is_fullscreen: bool = false,
};

/// Snapshot view-model containing read-only state data and sub-system references required for UI layout construction.
pub const UiViewModel = struct {
    is_fullscreen: bool = false,
    total_images: usize = 0,
    current_index: ?usize = null,
    current_image_path: ?[]const u8 = null,
    current_entry: ?@import("image.zig").CacheEntry = null,
    is_loading_files: bool = false,
    slideshow: @import("navigation.zig").SlideshowMode = .inactive,
    overlays: @import("ui_state.zig").OverlayState = .{},
    metrics: *@import("ui_state.zig").UiRenderMetrics,
    viewport: ViewportParams = .{},
    palette: *@import("palette.zig").PaletteState,
    display: *@import("state.zig").DisplayState,
    gpa_allocator: std.mem.Allocator,
    io: std.Io,
    cache_slot_map: *@import("image.zig").CacheSlotMap,
    navigation: *@import("navigation.zig").NavigationState,
    pending_intents: *std.ArrayListUnmanaged(intents.AppIntent),
    current_image_cache_hit: bool = false,
    debug_show_thumb: bool = false,
};

pub const TextInputBounds = intents.TextInputBounds;

/// Data-driven event payload unifying keyboard shortcuts, IPC socket messages,
/// command palette triggers, and automated test instructions.
pub const AppEvent = union(enum) {
    intent: intents.AppIntent,
    set_zoom: f32,
    set_pan: struct { dx: f32, dy: f32 },
    set_adjustments: struct { brightness: f32, contrast: f32 },
    set_filter: intents.TextureScaleMode,
    set_palette_mode: intents.PaletteMode,
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

pub const KeyboardShortcut = struct {
    key: Key,
    mod: KeyModifiers = .{},
};

pub const ActionMetadata = struct {
    name: []const u8,
    shortcut_text: []const u8,
    show_in_palette: bool,
    shortcuts: []const KeyboardShortcut,
    intent: intents.AppIntent,
};

pub const palette_action_items = [_]ActionMetadata{
    .{ .name = "Next Image", .shortcut_text = "Space / Right Arrow", .show_in_palette = true, .shortcuts = &.{ .{ .key = .space }, .{ .key = .right } }, .intent = .next_image },
    .{ .name = "Previous Image", .shortcut_text = "Backspace / Left Arrow", .show_in_palette = true, .shortcuts = &.{ .{ .key = .backspace }, .{ .key = .left } }, .intent = .prev_image },
    .{ .name = "Toggle Image Info", .shortcut_text = "I", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_i }}, .intent = .toggle_info },
    .{ .name = "Toggle Performance Overlay", .shortcut_text = "Shift+I", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_i, .mod = .{ .shift = true } }}, .intent = .toggle_stats },
    .{ .name = "Toggle Fullscreen", .shortcut_text = "F / F11", .show_in_palette = true, .shortcuts = &.{ .{ .key = .char_f }, .{ .key = .f11 } }, .intent = .toggle_fullscreen },
    .{ .name = "Open File Finder...", .shortcut_text = "Ctrl+P", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_p, .mod = .{ .ctrl = true } }}, .intent = .{ .set_palette = .{ .mode = .files } } },
    .{ .name = "Navigate Directories...", .shortcut_text = "Ctrl+O", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_o, .mod = .{ .ctrl = true } }}, .intent = .{ .set_palette = .{ .mode = .directory_navigator } } },
    .{ .name = "Toggle Clay Debug Mode", .shortcut_text = "Ctrl+D", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_d, .mod = .{ .ctrl = true } }}, .intent = .toggle_debug_mode },
    .{ .name = "Toggle Debug Thumbnail Overlay", .shortcut_text = "Ctrl+T", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_t, .mod = .{ .ctrl = true } }}, .intent = .toggle_debug_thumb },
    .{ .name = "Quit", .shortcut_text = "Q / Esc", .show_in_palette = true, .shortcuts = &.{ .{ .key = .char_q }, .{ .key = .escape } }, .intent = .quit },
    .{ .name = "First Image", .shortcut_text = "Home", .show_in_palette = true, .shortcuts = &.{.{ .key = .home }}, .intent = .first_image },
    .{ .name = "Last Image", .shortcut_text = "End", .show_in_palette = true, .shortcuts = &.{.{ .key = .end }}, .intent = .last_image },
    .{ .name = "Zoom In", .shortcut_text = "= / +", .show_in_palette = true, .shortcuts = &.{.{ .key = .equals }}, .intent = .zoom_in },
    .{ .name = "Zoom Out", .shortcut_text = "-", .show_in_palette = true, .shortcuts = &.{.{ .key = .minus }}, .intent = .zoom_out },
    .{ .name = "Reset Zoom & Pan", .shortcut_text = "R / 0", .show_in_palette = true, .shortcuts = &.{ .{ .key = .char_r }, .{ .key = .char_0 } }, .intent = .reset_zoom },
    .{ .name = "Set Scale Mode: 100% (Actual Size)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_scale = .none } },
    .{ .name = "Set Scale Mode: Fit if Larger (Shrink)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_scale = .shrink } },
    .{ .name = "Set Scale Mode: Fit Window (Full)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_scale = .full } },
    .{ .name = "Set Scale Mode: Fill Window (Crop)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_scale = .crop } },
    .{ .name = "Rotate Clockwise (90°)", .shortcut_text = "]", .show_in_palette = true, .shortcuts = &.{.{ .key = .right_bracket }}, .intent = .rotate_cw },
    .{ .name = "Rotate Counter-Clockwise (90°)", .shortcut_text = "[", .show_in_palette = true, .shortcuts = &.{.{ .key = .left_bracket }}, .intent = .rotate_ccw },
    .{ .name = "Reset Rotation", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .reset_rotation },
    .{ .name = "Set Scaling Filter: Nearest Neighbor", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .nearest } },
    .{ .name = "Set Scaling Filter: Bilinear (Smooth)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .linear } },
    .{ .name = "Set Scaling Filter: Pixel Art (Crisp)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .pixel_art } },
    .{ .name = "Set Scaling Filter: Mitchell-Netravali (HQ Bicubic)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .mitchell } },
    .{ .name = "Set Scaling Filter: Lanczos3 (Ultra HQ Resampler)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .lanczos3 } },
    .{ .name = "Increase Brightness (+10%)", .shortcut_text = "P", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_p }}, .intent = .increase_brightness },
    .{ .name = "Decrease Brightness (-10%)", .shortcut_text = "O", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_o }}, .intent = .decrease_brightness },
    .{ .name = "Increase Contrast (+10%)", .shortcut_text = "L", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_l }}, .intent = .increase_contrast },
    .{ .name = "Decrease Contrast (-10%)", .shortcut_text = "K", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_k }}, .intent = .decrease_contrast },
    .{ .name = "Reset Brightness & Contrast", .shortcut_text = "Shift+R", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_r, .mod = .{ .shift = true } }}, .intent = .reset_adjustments },
    .{ .name = "Set Brightness (Type Value)...", .shortcut_text = "Shift+B", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_b, .mod = .{ .shift = true } }}, .intent = .{ .set_palette = .{ .mode = .set_brightness } } },
    .{ .name = "Set Contrast (Type Value)...", .shortcut_text = "Shift+C", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_c, .mod = .{ .shift = true } }}, .intent = .{ .set_palette = .{ .mode = .set_contrast } } },
    .{ .name = "Go to Image...", .shortcut_text = "Shift+G", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_g, .mod = .{ .shift = true } }}, .intent = .{ .set_palette = .{ .mode = .go_to_image } } },
    .{ .name = "Search Actions (Command Palette)", .shortcut_text = "F1 / Ctrl+Shift+P", .show_in_palette = true, .shortcuts = &.{ .{ .key = .f1 }, .{ .key = .char_p, .mod = .{ .ctrl = true, .shift = true } } }, .intent = .{ .set_palette = .{ .mode = .actions } } },
    .{ .name = "Start Slide Show...", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_palette = .{ .mode = .set_slideshow_interval } } },
    .{ .name = "Stop Slide Show", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .stop_slideshow },
};

pub const FlatShortcut = struct {
    key: Key,
    mod: KeyModifiers,
    intent: intents.AppIntent,
};

pub const flat_shortcuts = blk: {
    var count: usize = 0;
    for (palette_action_items) |item| {
        count += item.shortcuts.len;
    }
    var list: [count]FlatShortcut = undefined;
    var idx: usize = 0;
    for (palette_action_items) |item| {
        for (item.shortcuts) |sc| {
            list[idx] = .{
                .key = sc.key,
                .mod = sc.mod,
                .intent = item.intent,
            };
            idx += 1;
        }
    }
    break :blk list;
};

test "PaletteMode.getTextInputBounds" {
    const brightness_bounds = intents.PaletteMode.set_brightness.getTextInputBounds().?;
    try std.testing.expectEqual(@as(f32, -1.0), brightness_bounds.min);
    try std.testing.expectEqual(@as(f32, 1.0), brightness_bounds.max);

    const contrast_bounds = intents.PaletteMode.set_contrast.getTextInputBounds().?;
    try std.testing.expectEqual(@as(f32, 0.0), contrast_bounds.min);
    try std.testing.expectEqual(@as(f32, 5.0), contrast_bounds.max);

    try std.testing.expect(intents.PaletteMode.files.getTextInputBounds() == null);
}
