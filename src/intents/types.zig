//! Pure Intent Data Types & Enums
//!
//! Defines intent data structures, scaling modes, palette modes, bounds,
//! and command payloads without depending on UI, hardware, or state structs.

const geom = @import("geom");
const std = @import("std");
const triage = @import("triage");

const PhysicalPoint = geom.PhysicalPoint;
const ViewMode = triage.ViewMode;

/// Target zoom presets for instant snapping and responsive tracking.
pub const ZoomPreset = enum {
    none,
    shrink,
    full,
    crop,
    fit_width,
    fit_height,

    pub inline fn isFit(self: ZoomPreset) bool {
        return self == .full;
    }

    pub inline fn isFill(self: ZoomPreset) bool {
        return self == .crop;
    }

    /// Parses a scale mode name or alias (`fit`, `fill`, `1:1`, `actual`,
    /// `width`, `height`) into a `ZoomPreset`.
    pub fn parse(val: []const u8) ?ZoomPreset {
        if (std.mem.eql(u8, val, "fit")) return .full;
        if (std.mem.eql(u8, val, "fill")) return .crop;
        if (std.mem.eql(u8, val, "1:1") or
            std.mem.eql(u8, val, "actual")) return .none;
        if (std.mem.eql(u8, val, "width")) return .fit_width;
        if (std.mem.eql(u8, val, "height")) return .fit_height;
        return std.meta.stringToEnum(ZoomPreset, val);
    }
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

/// Comptime-generated comma-separated list of all valid ZoomPreset names
/// via reflection.
pub const scale_modes_string: []const u8 = blk: {
    var str: []const u8 = "";
    const field_names = @typeInfo(ZoomPreset).@"enum".field_names;
    for (field_names, 0..) |name, i| {
        str = if (i > 0) str ++ ", " ++ name else name;
    }
    break :blk str;
};

/// Comptime-generated comma-separated list of all valid TextureScaleMode names
/// via reflection.
pub const filter_modes_string: []const u8 = blk: {
    var str: []const u8 = "";
    const field_names = @typeInfo(TextureScaleMode).@"enum".field_names;
    for (field_names, 0..) |name, i| {
        str = if (i > 0) str ++ ", " ++ name else name;
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
    texture = 11,
    clarity = 12,

    /// Total number of photographic grading adjustment parameters.
    pub const count = std.enums.values(EditParam).len;
};

/// Domain category for grouping photographic adjustments.
pub const EditDomain = enum(u2) {
    tone = 0,
    color = 1,
    presence = 2,

    /// Returns human-readable section title for UI headings.
    pub fn label(self: EditDomain) []const u8 {
        return switch (self) {
            .tone => "LIGHT & TONE",
            .color => "COLOR & BALANCE",
            .presence => "PRESENCE & DETAIL",
        };
    }
};

/// Formatting mode for value readouts across UI, snackbar, and stats.
pub const DisplayKind = enum(u3) {
    percent,
    multiplier,
    temperature,
    tint,
    ratio_percent,
};

/// Canonical compile-time specification for a photographic grading parameter.
pub const ParamSpec = struct {
    param: EditParam,
    domain: EditDomain,
    slug: []const u8,
    label: []const u8,
    min: f32,
    max: f32,
    default: f32,
    step: f32,
    snap_radius: f32,
    display_kind: DisplayKind,
    placeholder_example: []const u8,
    prompt_label: []const u8,
    prompt_placeholder: []const u8,

    /// Clamps value to parameter bounds, defaulting on NaN/Inf.
    pub fn clamp(self: ParamSpec, val: f32) f32 {
        if (std.math.isNan(val) or std.math.isInf(val)) return self.default;
        return std.math.clamp(val, self.min, self.max);
    }

    /// Snaps value to default within snap_radius, then clamps.
    pub fn snap(self: ParamSpec, val: f32) f32 {
        if (@abs(val - self.default) < self.snap_radius) {
            return self.default;
        }
        return self.clamp(val);
    }
};

/// Compile-time table of specifications for all 13 photographic adjustments.
pub const specs = [EditParam.count]ParamSpec{
    .{
        .param = .brightness,
        .domain = .tone,
        .slug = "brightness",
        .label = "Exposure",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
        .placeholder_example = "0.2",
        .prompt_label = "Set Brightness",
        .prompt_placeholder = "Enter brightness (-1.0 to 1.0, e.g. 0.2)...",
    },
    .{
        .param = .contrast,
        .domain = .tone,
        .slug = "contrast",
        .label = "Contrast",
        .min = 0.0,
        .max = 3.0,
        .default = 1.0,
        .step = 0.05,
        .snap_radius = 0.035,
        .display_kind = .multiplier,
        .placeholder_example = "1.5",
        .prompt_label = "Set Contrast",
        .prompt_placeholder = "Enter contrast (0.0 to 3.0, e.g. 1.5)...",
    },
    .{
        .param = .contrast_blend,
        .domain = .tone,
        .slug = "contrast_blend",
        .label = "Contrast Blend",
        .min = 0.0,
        .max = 1.0,
        .default = 1.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .ratio_percent,
        .placeholder_example = "0.5",
        .prompt_label = "Set Contrast Blend",
        .prompt_placeholder = "Enter contrast blend " ++
            "(0.0 Luma to 1.0 RGB, e.g. 0.5)...",
    },
    .{
        .param = .highlights,
        .domain = .tone,
        .slug = "highlights",
        .label = "Highlights",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
        .placeholder_example = "-0.3",
        .prompt_label = "Set Highlights",
        .prompt_placeholder = "Enter highlights (-1.0 to 1.0, e.g. -0.3)...",
    },
    .{
        .param = .shadows,
        .domain = .tone,
        .slug = "shadows",
        .label = "Shadows",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
        .placeholder_example = "0.2",
        .prompt_label = "Set Shadows",
        .prompt_placeholder = "Enter shadows (-1.0 to 1.0, e.g. 0.2)...",
    },
    .{
        .param = .whites,
        .domain = .tone,
        .slug = "whites",
        .label = "Whites",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
        .placeholder_example = "0.1",
        .prompt_label = "Set Whites",
        .prompt_placeholder = "Enter whites (-1.0 to 1.0, e.g. 0.1)...",
    },
    .{
        .param = .blacks,
        .domain = .tone,
        .slug = "blacks",
        .label = "Blacks",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
        .placeholder_example = "-0.1",
        .prompt_label = "Set Blacks",
        .prompt_placeholder = "Enter blacks (-1.0 to 1.0, e.g. -0.1)...",
    },
    .{
        .param = .temperature,
        .domain = .color,
        .slug = "temperature",
        .label = "Temperature",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .temperature,
        .placeholder_example = "0.2",
        .prompt_label = "Set Temperature",
        .prompt_placeholder = "Enter temperature (-1.0 to 1.0, e.g. 0.2)...",
    },
    .{
        .param = .tint,
        .domain = .color,
        .slug = "tint",
        .label = "Tint",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .tint,
        .placeholder_example = "0.05",
        .prompt_label = "Set Tint",
        .prompt_placeholder = "Enter tint (-1.0 to 1.0, e.g. 0.05)...",
    },
    .{
        .param = .vibrance,
        .domain = .color,
        .slug = "vibrance",
        .label = "Vibrance",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
        .placeholder_example = "0.25",
        .prompt_label = "Set Vibrance",
        .prompt_placeholder = "Enter vibrance (-1.0 to 1.0, e.g. 0.25)...",
    },
    .{
        .param = .saturation,
        .domain = .color,
        .slug = "saturation",
        .label = "Saturation",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
        .placeholder_example = "0.1",
        .prompt_label = "Set Saturation",
        .prompt_placeholder = "Enter saturation (-1.0 to 1.0, e.g. 0.1)...",
    },
    .{
        .param = .texture,
        .domain = .presence,
        .slug = "texture",
        .label = "Texture",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
        .placeholder_example = "0.25",
        .prompt_label = "Set Texture",
        .prompt_placeholder = "Enter texture (-1.0 to 1.0, e.g. 0.25)...",
    },
    .{
        .param = .clarity,
        .domain = .presence,
        .slug = "clarity",
        .label = "Clarity",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
        .placeholder_example = "0.3",
        .prompt_label = "Set Clarity",
        .prompt_placeholder = "Enter clarity (-1.0 to 1.0, e.g. 0.3)...",
    },
};

comptime {
    std.debug.assert(specs.len == EditParam.count);
    for (0..specs.len) |i| {
        const p: EditParam = @fromBackingInt(@intCast(i));
        std.debug.assert(specs[i].param == p);
        std.debug.assert(specs[i].min < specs[i].max);
        std.debug.assert(specs[i].default >= specs[i].min);
        std.debug.assert(specs[i].default <= specs[i].max);
        std.debug.assert(specs[i].step > 0.0);
    }
}

/// Returns the specification for the given EditParam.
pub inline fn getSpec(param: EditParam) ParamSpec {
    return specs[@backingInt(param)];
}

/// Looks up an EditParam by its IPC/configuration slug.
pub fn fromSlug(slug: []const u8) ?EditParam {
    inline for (specs) |spec| {
        if (std.mem.eql(u8, spec.slug, slug)) return spec.param;
    }
    return null;
}

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
    /// Batch update for clarity & texture (presence & detail)
    batch_presence: struct {
        clarity: f32,
        texture: f32,
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

/// Sub-mode for single-line text or numeric input prompt dialogs.
pub const PromptKind = union(enum) {
    go_to_image,
    slideshow_interval,
    edit_param: EditParam,
};

/// Active modal command palette or interactive numeric dialog mode.
pub const PaletteMode = union(enum) {
    inactive,
    files,
    actions,
    directory_navigator,
    prompt: PromptKind,

    /// Returns the associated EditParam if this mode adjusts a photographic
    /// parameter, or null otherwise.
    pub fn toEditParam(self: PaletteMode) ?EditParam {
        return switch (self) {
            .prompt => |kind| switch (kind) {
                .edit_param => |param| param,
                .go_to_image, .slideshow_interval => null,
            },
            .inactive, .files, .actions, .directory_navigator => null,
        };
    }

    /// Returns true if this palette mode requires single-line text/numeric
    /// input validation.
    pub fn isTextInputDialog(self: PaletteMode) bool {
        return switch (self) {
            .prompt => true,
            .inactive, .files, .actions, .directory_navigator => false,
        };
    }

    /// Returns valid numeric bounds for input dialogs, or null if non-numeric
    /// or search palette.
    pub fn getTextInputBounds(self: PaletteMode) ?TextInputBounds {
        return switch (self) {
            .prompt => |kind| switch (kind) {
                .edit_param => |param| blk: {
                    const spec = getSpec(param);
                    break :blk .{ .min = spec.min, .max = spec.max };
                },
                .slideshow_interval => .{ .min = 0.1, .max = 3600.0 },
                .go_to_image => null,
            },
            .inactive, .files, .actions, .directory_navigator => null,
        };
    }
};

/// Serialized intent union representing discrete user commands dispatched
/// by keybindings, mouse clicks, command palettes, or remote IPC sockets.
pub const AppIntent = union(enum) {
    // Viewport spatial transforms & adjustments
    set_zoom: f32,
    zoom_by: struct { ratio: f32 },
    zoom_in,
    zoom_out,
    set_pan: PhysicalPoint,
    pan_by: struct { dx: f32, dy: f32 },
    reset_zoom,

    // Image scaling modes & GPU filters
    set_scale: ZoomPreset,
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
    open_window,
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
    clear_classifications,
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
    toggle_atlas,
    set_atlas: bool,
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

    toggle_debug_thumb,
    set_debug_thumb: bool,

    // Slideshow controls
    start_slideshow,
    start_slideshow_interval: f32,
    stop_slideshow,

    // Manga mode controls
    toggle_manga_mode,
    set_manga_mode: bool,

    // Image transition controls
    toggle_crossfade,
    set_crossfade: bool,

    // RAW + JPEG stacking controls
    toggle_raw_jpeg_stacking,
    set_raw_jpeg_stacking: bool,
    toggle_pair_stream,

    // Thumbnail cache maintenance
    precache_directory,

    // Application lifecycle
    quit,
    quit_server,
};

test "ParamSpec - Compile-time assertions verify all 13 parameters" {
    try std.testing.expectEqual(EditParam.count, specs.len);
    inline for (specs, 0..) |spec, i| {
        const expected_param: EditParam = @fromBackingInt(@intCast(i));
        try std.testing.expectEqual(expected_param, spec.param);
        try std.testing.expect(spec.min < spec.max);
        try std.testing.expect(spec.default >= spec.min);
        try std.testing.expect(spec.default <= spec.max);
        try std.testing.expect(spec.step > 0.0);
        try std.testing.expect(spec.snap_radius > 0.0);
        try std.testing.expect(spec.slug.len > 0);
        try std.testing.expect(spec.label.len > 0);
    }
}

test "ParamSpec - clamp and snap behavior around defaults" {
    for (specs) |spec| {
        // Clamp out-of-bounds
        try std.testing.expectEqual(spec.min, spec.clamp(spec.min - 10.0));
        try std.testing.expectEqual(spec.max, spec.clamp(spec.max + 10.0));
        try std.testing.expectEqual(spec.default, spec.clamp(spec.default));

        // Snap near default
        const near_def = spec.default + spec.snap_radius * 0.5;
        try std.testing.expectEqual(spec.default, spec.snap(near_def));

        // Beyond snap radius, does not snap to default
        const far_def = spec.default + spec.snap_radius * 1.5;
        if (far_def <= spec.max) {
            try std.testing.expect(spec.snap(far_def) != spec.default);
        }

        // NaN and Inf clamp to default
        try std.testing.expectEqual(
            spec.default,
            spec.clamp(std.math.nan(f32)),
        );
        try std.testing.expectEqual(
            spec.default,
            spec.clamp(std.math.inf(f32)),
        );
    }
}

test "ParamSpec - fromSlug lookup returns exact EditParam for all 13 slugs" {
    for (specs) |spec| {
        const found = fromSlug(spec.slug);
        try std.testing.expect(found != null);
        try std.testing.expectEqual(spec.param, found.?);
    }
    try std.testing.expect(fromSlug("nonexistent") == null);
    try std.testing.expect(fromSlug("") == null);
}

test "PaletteMode - PromptKind methods cover all variants" {
    const bright: PaletteMode = .{ .prompt = .{ .edit_param = .brightness } };
    const contrast: PaletteMode = .{ .prompt = .{ .edit_param = .contrast } };
    const goto: PaletteMode = .{ .prompt = .go_to_image };
    const slide: PaletteMode = .{ .prompt = .slideshow_interval };
    const inactive: PaletteMode = .inactive;
    const files: PaletteMode = .files;
    const actions: PaletteMode = .actions;
    const dir_nav: PaletteMode = .directory_navigator;

    try std.testing.expectEqual(
        @as(?EditParam, .brightness),
        bright.toEditParam(),
    );
    try std.testing.expectEqual(
        @as(?EditParam, .contrast),
        contrast.toEditParam(),
    );
    try std.testing.expectEqual(@as(?EditParam, null), goto.toEditParam());
    try std.testing.expectEqual(@as(?EditParam, null), slide.toEditParam());
    try std.testing.expectEqual(@as(?EditParam, null), files.toEditParam());

    try std.testing.expect(bright.isTextInputDialog());
    try std.testing.expect(goto.isTextInputDialog());
    try std.testing.expect(slide.isTextInputDialog());
    try std.testing.expect(!inactive.isTextInputDialog());
    try std.testing.expect(!files.isTextInputDialog());
    try std.testing.expect(!actions.isTextInputDialog());
    try std.testing.expect(!dir_nav.isTextInputDialog());

    const c_bounds = contrast.getTextInputBounds().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c_bounds.min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), c_bounds.max, 0.001);
    const s_bounds = slide.getTextInputBounds().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), s_bounds.min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3600.0), s_bounds.max, 0.001);
    try std.testing.expect(goto.getTextInputBounds() == null);
    try std.testing.expect(actions.getTextInputBounds() == null);
}
