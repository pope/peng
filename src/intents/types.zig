//! Pure Intent Data Types & Enums
//!
//! Defines intent data structures, scaling modes, palette modes,
//! bounds, and command payloads with zero dependencies on other modules.

const std = @import("std");

/// Tri-state classification for image triage (inspired by Adobe Lightroom).
/// Uses enum(u2) for high-density flat array storage (fits in 1 byte per
/// entry, 10 KB for 10k images).
pub const Classification = enum(u2) {
    unflagged = 0,
    pick = 1,
    reject = 2,

    /// Human-readable display label.
    pub inline fn label(self: Classification) []const u8 {
        return switch (self) {
            .unflagged => "Unflagged",
            .pick => "Pick",
            .reject => "Reject",
        };
    }

    /// Tab-separated prefix used for stdout triage export, or null if
    /// unflagged.
    pub inline fn exportPrefix(self: Classification) ?[]const u8 {
        return switch (self) {
            .pick => "PICK",
            .reject => "REJECT",
            .unflagged => null,
        };
    }
};

/// Active filter view mode defining which classified images are visible.
pub const ViewMode = enum(u8) {
    /// Default mode: shows unflagged images and picks; hides rejects.
    default = 0,
    /// Shows only unflagged images.
    unflagged = 1,
    /// Shows only picks.
    picks = 2,
    /// Shows only rejects.
    rejects = 3,
    /// Shows all images regardless of classification.
    all = 4,

    /// Exhaustive evaluation determining whether an image with
    /// classification `c` is visible.
    pub inline fn matches(self: ViewMode, c: Classification) bool {
        return switch (self) {
            .default => switch (c) {
                .unflagged, .pick => true,
                .reject => false,
            },
            .unflagged => c == .unflagged,
            .picks => c == .pick,
            .rejects => c == .reject,
            .all => switch (c) {
                .unflagged, .pick, .reject => true,
            },
        };
    }

    /// Cycles sequentially to the next view mode.
    pub inline fn cycle(self: ViewMode) ViewMode {
        return switch (self) {
            .default => .picks,
            .picks => .rejects,
            .rejects => .unflagged,
            .unflagged => .all,
            .all => .default,
        };
    }

    /// Human-readable title of the view filter mode.
    pub inline fn label(self: ViewMode) []const u8 {
        return switch (self) {
            .default => "Default (Hide Rejects)",
            .unflagged => "Unflagged Only",
            .picks => "Picks Only",
            .rejects => "Rejects Only",
            .all => "All Files",
        };
    }

    /// Optional badge text for UI overlays when a non-default filter is active.
    pub inline fn badgeText(self: ViewMode) ?[]const u8 {
        return switch (self) {
            .default => null,
            .unflagged => "UNFLAGGED",
            .picks => "PICKS ONLY",
            .rejects => "REJECTS ONLY",
            .all => "ALL FILES",
        };
    }
};

/// Image viewport scaling and fitting modes.
pub const ScaleMode = enum {
    none,
    shrink,
    full,
    crop,
    fit_width,
    fit_height,
};

/// High-quality GPU texture resampling and reconstruction filter algorithms.
pub const TextureScaleMode = enum {
    nearest,
    linear,
    pixel_art,
    mitchell,
    lanczos3,
    fsr,
    tiny_cnn,
};

/// Comptime-generated comma-separated list of all valid ScaleMode names
/// via reflection.
pub const scale_modes_string: []const u8 = blk: {
    var str: []const u8 = "";
    const fields = @typeInfo(ScaleMode).@"enum".fields;
    for (fields, 0..) |field, i| {
        str = if (i > 0) str ++ ", " ++ field.name else field.name;
    }
    break :blk str;
};

/// Comptime-generated comma-separated list of all valid TextureScaleMode names
/// via reflection.
pub const filter_modes_string: []const u8 = blk: {
    var str: []const u8 = "";
    const fields = @typeInfo(TextureScaleMode).@"enum".fields;
    for (fields, 0..) |field, i| {
        str = if (i > 0) str ++ ", " ++ field.name else field.name;
    }
    break :blk str;
};

/// Min and max numeric bounds for validated text input dialogs.
pub const TextInputBounds = struct {
    min: f32,
    max: f32,
};

/// Target parameter identifier for image editing controls and sliders.
pub const EditParam = enum(u8) {
    brightness = 0,
    contrast = 1,
    contrast_blend = 2,
    highlights = 3,
    shadows = 4,
    whites = 5,
    blacks = 6,
    temperature = 7,
    tint = 8,
    vibrance = 9,
    saturation = 10,

    pub const count = std.enums.values(EditParam).len;
};

/// Direction increment for stepped parameter adjustments.
pub const StepDirection = enum(i8) {
    up = 1,
    down = -1,
};

/// Tagged union representing all photographic adjustment commands.
pub const AdjustIntent = union(enum) {
    /// Set a parameter to an absolute value (clamped to parameter descriptor
    /// bounds).
    set: struct {
        param: EditParam,
        value: f32,
    },
    /// Step a parameter by a relative increment (+step or -step)
    step: struct {
        param: EditParam,
        direction: StepDirection,
    },
    /// Batch update for tone quad (atomic IPC / preset application)
    batch_tone: struct {
        highlights: f32,
        shadows: f32,
        whites: f32,
        blacks: f32,
    },
    /// Batch update for color & white balance
    batch_color: struct {
        temperature: f32,
        tint: f32,
        vibrance: f32,
        saturation: f32,
    },
    /// Reset a single parameter to its neutral default
    reset_param: EditParam,
    /// Reset all photographic adjustments
    reset_all,
    /// Toggle Before/After comparison
    toggle_compare,
    /// Explicitly set comparison mode
    set_compare: bool,
};

/// Active modal command palette or interactive numeric dialog mode.
pub const PaletteMode = enum {
    inactive,
    files,
    actions,
    set_brightness,
    set_contrast,
    set_contrast_blend,
    set_highlights,
    set_shadows,
    set_whites,
    set_blacks,
    set_temperature,
    set_tint,
    set_vibrance,
    set_saturation,
    go_to_image,
    directory_navigator,
    set_slideshow_interval,

    /// Returns the associated EditParam if this mode adjusts a photographic
    /// parameter, or null otherwise.
    pub fn toEditParam(self: PaletteMode) ?EditParam {
        return switch (self) {
            .set_brightness => .brightness,
            .set_contrast => .contrast,
            .set_contrast_blend => .contrast_blend,
            .set_highlights => .highlights,
            .set_shadows => .shadows,
            .set_whites => .whites,
            .set_blacks => .blacks,
            .set_temperature => .temperature,
            .set_tint => .tint,
            .set_vibrance => .vibrance,
            .set_saturation => .saturation,
            .inactive,
            .files,
            .actions,
            .go_to_image,
            .directory_navigator,
            .set_slideshow_interval,
            => null,
        };
    }

    /// Returns true if this palette mode requires single-line text/numeric
    /// input validation.
    pub fn isTextInputDialog(self: PaletteMode) bool {
        return switch (self) {
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
            .go_to_image,
            .set_slideshow_interval,
            => true,
            .inactive, .files, .actions, .directory_navigator => false,
        };
    }

    /// Returns valid numeric bounds for input dialogs, or null if non-numeric
    /// or search palette.
    pub fn getTextInputBounds(self: PaletteMode) ?TextInputBounds {
        return switch (self) {
            .set_brightness,
            .set_highlights,
            .set_shadows,
            .set_whites,
            .set_blacks,
            .set_temperature,
            .set_tint,
            .set_vibrance,
            .set_saturation,
            => .{ .min = -1.0, .max = 1.0 },
            .set_contrast => .{ .min = 0.0, .max = 3.0 },
            .set_contrast_blend => .{ .min = 0.0, .max = 1.0 },
            .set_slideshow_interval => .{ .min = 0.1, .max = 3600.0 },
            .go_to_image,
            .inactive,
            .files,
            .actions,
            .directory_navigator,
            => null,
        };
    }
};

/// Serialized intent union representing discrete user commands dispatched
/// by keybindings, mouse clicks, command palettes, or remote IPC sockets.
pub const AppIntent = union(enum) {
    // Viewport spatial transforms & adjustments
    set_zoom: f32,
    zoom_in,
    zoom_out,
    set_pan: struct { x: f32, y: f32 },
    pan_by: struct { dx: f32, dy: f32 },
    reset_zoom,

    // Image scaling modes & GPU filters
    set_scale: ScaleMode,
    cycle_scale_mode,
    set_filter: TextureScaleMode,
    cycle_filter,
    cycle_filter_prev,

    // Photographic color & tonal adjustments (unified tagged union)
    adjust: AdjustIntent,

    // Image orientation
    rotate_cw,
    rotate_ccw,
    reset_rotation,

    // Image navigation
    open_path: []const u8,
    next_image,
    prev_image,
    first_image,
    last_image,
    go_to_image: usize,
    refresh_directory,

    // Image triage & classification
    mark_pick,
    mark_reject,
    unflag,
    cycle_view_mode,
    set_view_mode: ViewMode,

    // Palettes & Overlays
    set_palette: struct {
        mode: PaletteMode,
        query: ?[]const u8 = null,
    },
    toggle_info,
    set_info: bool,
    toggle_stats,
    set_stats: bool,
    toggle_edit_panel,
    set_edit_panel: bool,
    dismiss_overlays,
    toggle_title,
    set_title: bool,
    toggle_snackbar,
    set_snackbar: bool,
    toggle_blur,
    set_blur: bool,
    toggle_fullscreen,
    set_fullscreen: bool,
    toggle_windowless,
    set_windowless: bool,
    toggle_debug_mode,
    set_debug_mode: bool,
    toggle_debug_thumb,
    set_debug_thumb: bool,

    // Slideshow controls
    start_slideshow,
    stop_slideshow,

    // Manga mode controls
    toggle_manga_mode,
    set_manga_mode: bool,

    // Image transition controls
    toggle_crossfade,
    set_crossfade: bool,

    // Application lifecycle
    quit,
};
