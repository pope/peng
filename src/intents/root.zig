//! Pure Data-Driven Intent Schema Definition
//!
//! Defines high-level application intents, scaling modes, palette modes,
//! and command payloads without depending on UI, hardware, or state structs.

/// Image viewport scaling and fitting modes.
pub const ScaleMode = enum {
    none,
    shrink,
    full,
    crop,
};

/// High-quality GPU texture resampling and reconstruction filter algorithms.
pub const TextureScaleMode = enum {
    nearest,
    linear,
    pixel_art,
    mitchell,
    lanczos3,

    /// Maps the enum variant to the integer sampler index expected by fragment shaders.
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

/// Min and max numeric bounds for validated text input dialogs.
pub const TextInputBounds = struct {
    min: f32,
    max: f32,
};

/// Active modal command palette or interactive numeric dialog mode.
pub const PaletteMode = enum {
    inactive,
    files,
    actions,
    set_brightness,
    set_contrast,
    go_to_image,
    directory_navigator,
    set_slideshow_interval,

    /// Returns true if this palette mode requires single-line text/numeric input validation.
    pub fn isTextInputDialog(self: PaletteMode) bool {
        return switch (self) {
            .set_brightness, .set_contrast, .go_to_image, .set_slideshow_interval => true,
            .inactive, .files, .actions, .directory_navigator => false,
        };
    }

    /// Returns valid numeric bounds for input dialogs, or null if non-numeric/search palette.
    pub fn getTextInputBounds(self: PaletteMode) ?TextInputBounds {
        return switch (self) {
            .set_brightness => .{ .min = -1.0, .max = 1.0 },
            .set_contrast => .{ .min = 0.0, .max = 5.0 },
            .set_slideshow_interval => .{ .min = 0.1, .max = 3600.0 },
            .go_to_image, .inactive, .files, .actions, .directory_navigator => null,
        };
    }
};

/// Serialized intent union representing discrete user commands dispatched by keybindings,
/// mouse clicks, command palettes, or remote IPC sockets.
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
    set_filter: TextureScaleMode,

    // Color adjustments
    set_brightness: f32,
    increase_brightness,
    decrease_brightness,
    set_contrast: f32,
    increase_contrast,
    decrease_contrast,
    reset_adjustments,

    // Image orientation
    rotate_cw,
    rotate_ccw,
    reset_rotation,

    // Image navigation
    next_image,
    prev_image,
    first_image,
    last_image,
    go_to_image: usize,

    // Palettes & Overlays
    set_palette: struct {
        mode: PaletteMode,
        query: ?[]const u8 = null,
    },
    toggle_info,
    set_info: bool,
    toggle_stats,
    set_stats: bool,
    toggle_atlas_overlay,
    set_atlas_overlay: bool,
    toggle_fullscreen,
    set_fullscreen: bool,
    toggle_debug_mode,
    set_debug_mode: bool,
    toggle_debug_thumb,
    set_debug_thumb: bool,

    // Slideshow controls
    start_slideshow,
    stop_slideshow,

    // Application lifecycle
    quit,
};
