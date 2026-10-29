const intents = @import("intents");
const probe = @import("probe");
const std = @import("std");
const triage = @import("triage");
const view_transform = @import("view_transform.zig");

const Classification = triage.Classification;
const EditParam = intents.EditParam;
const getSpec = intents.getSpec;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;
const PositiveDimsU32 = probe.PositiveDimsU32;
const ViewMode = triage.ViewMode;

pub const ZoomPreset = intents.ZoomPreset;

/// Display DPI scale factor mapping between logical UI points and physical
/// framebuffer pixels (`physical = logical * scale`).
pub const DpiScale = struct {
    x: f32 = 1.0,
    y: f32 = 1.0,

    /// Returns a sanitized `DpiScale` where non-positive or non-finite scale
    /// axes fall back to `1.0`.
    pub inline fn init(scale_x: f32, scale_y: f32) DpiScale {
        return .{
            .x = if (scale_x > 0.0 and std.math.isFinite(scale_x))
                scale_x
            else
                1.0,
            .y = if (scale_y > 0.0 and std.math.isFinite(scale_y))
                scale_y
            else
                1.0,
        };
    }
};

/// 2D width and height expressed in logical UI points (Clay layout space).
pub const LogicalDims = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,

    /// Converts logical dimensions into physical framebuffer pixel dimensions
    /// using the display `DpiScale`.
    pub inline fn toPhysical(self: LogicalDims, scale: DpiScale) PhysicalDims {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .w = self.w * s.x,
            .h = self.h * s.y,
        };
    }
};

/// 2D width and height expressed in physical framebuffer or image texel pixels.
pub const PhysicalDims = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,

    /// Returns a `PhysicalDims` only when both `w` and `h` are strictly
    /// positive and finite, or `null` otherwise.
    pub inline fn initPositive(w: f32, h: f32) ?PhysicalDims {
        if (w > 0.0 and h > 0.0 and
            std.math.isFinite(w) and std.math.isFinite(h))
        {
            return .{ .w = w, .h = h };
        }
        return null;
    }

    /// Converts strictly positive finite physical dimensions to integer pixel
    /// dimensions, or returns `null` if either axis is non-positive or
    /// non-finite.
    pub inline fn toPositiveU32(self: PhysicalDims) ?PositiveDimsU32 {
        const valid = initPositive(self.w, self.h) orelse return null;
        const max_dim: f32 = @floatFromInt(std.math.maxInt(u24));
        const w_u32: u32 = @intFromFloat(@min(valid.w, max_dim));
        const h_u32: u32 = @intFromFloat(@min(valid.h, max_dim));
        if (w_u32 == 0 or h_u32 == 0) return null;
        return .{ .w = w_u32, .h = h_u32 };
    }

    /// Converts physical pixel dimensions into logical UI point dimensions
    /// using the display `DpiScale`.
    pub inline fn toLogical(self: PhysicalDims, scale: DpiScale) LogicalDims {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .w = self.w / s.x,
            .h = self.h / s.y,
        };
    }
};

/// 2D coordinates or offset expressed in logical UI points (window / Clay
/// layout space).
pub const LogicalPoint = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,

    /// Converts a logical UI point into physical framebuffer pixel coordinates
    /// using the display `DpiScale`.
    pub inline fn toPhysical(
        self: LogicalPoint,
        scale: DpiScale,
    ) PhysicalPoint {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .x = self.x * s.x,
            .y = self.y * s.y,
        };
    }
};

/// 2D coordinates or offset expressed in physical framebuffer pixels.
pub const PhysicalPoint = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,

    /// Converts physical framebuffer pixel coordinates into a logical UI point
    /// using the display `DpiScale`.
    pub inline fn toLogical(self: PhysicalPoint, scale: DpiScale) LogicalPoint {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .x = self.x / s.x,
            .y = self.y / s.y,
        };
    }
};

/// Complete per-quad render descriptor specifying UV sub-rectangles, alpha,
/// rotation, and dynamic geometry overrides for rendering and transitions.
pub const UvRect = struct {
    u_min: f32 = 0.0,
    v_min: f32 = 0.0,
    u_max: f32 = 1.0,
    v_max: f32 = 1.0,
    alpha: f32 = 1.0,
    rotation_angle: ?f32 = null,
    override_zoom: ?f32 = null,
    override_pan_x: ?f32 = null,
    override_pan_y: ?f32 = null,
    source_w: ?f32 = null,
    source_h: ?f32 = null,
};

/// Tagged union representing the visibility state of the current view.
/// Distinguishes empty directories, active filtered empty states, and valid image selections.
pub const VisibleState = union(enum) {
    /// No images discovered or loaded in the current directory.
    empty_directory,
    /// Filter mode active with zero matching images, preventing the stuck loading screen bug.
    filtered_empty: struct {
        mode: ViewMode,
        total_count: usize,
    },
    /// A visible image is actively selected.
    selected: struct {
        raw_index: usize,
        visible_index: usize,
        visible_count: usize,
        total_count: usize,
        classification: Classification,
    },
};

/// Type-safe zoom factor wrapper protecting against zero-initialization,
/// division-by-zero, and NaN.
pub const ZoomFactor = struct {
    value: f32 = 1.0,

    pub const MIN: f32 = 0.001;
    pub const MAX: f32 = 100.0;

    /// Initializes a sanitized zoom factor clamped to [MIN, MAX], defaulting to
    /// 1.0 on invalid or non-positive input.
    pub fn init(raw: f32) ZoomFactor {
        if (std.math.isNan(raw) or raw <= 0.0) {
            return .{ .value = 1.0 };
        }
        return .{ .value = std.math.clamp(raw, MIN, MAX) };
    }

    /// Returns the active zoom scalar, guaranteed to be positive and non-NaN.
    pub fn get(self: ZoomFactor) f32 {
        if (self.value <= 0.0 or std.math.isNan(self.value)) {
            return 1.0;
        }
        return self.value;
    }

    /// Computes the ratio of `new_zoom` relative to `self`.
    pub fn ratioTo(self: ZoomFactor, new_zoom: ZoomFactor) f32 {
        return new_zoom.get() / self.get();
    }
};

/// Dynamic zoom policy controlling automatic window-fitting vs static manual
/// inspection.
pub const ZoomMode = enum {
    fit, // Dynamic: Z tracks min(V_w / W_rot, V_h / H_rot)
    fill, // Dynamic: Z tracks max(V_w / W_rot, V_h / H_rot)
    manual, // Static:  Z is user-defined, pan is user-defined
};

/// Dynamic viewport display, scaling, pan offset, and color adjustment
/// parameters.
pub const ViewportParams = struct {
    mode: ZoomMode = .fit,
    fit_mode: ZoomPreset = .full,
    scale_filter: intents.TextureScaleMode = .linear,
    zoom_factor: ZoomFactor = .{},
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    rotation_angle: f32 = 0.0,
    edits: ImageEdits = .{},
    compare_original: bool = false,

    /// Resets zoom factor, pan offsets, and comparison mode back to default
    /// center positioning.
    pub fn reset(self: *ViewportParams) void {
        self.mode = if (self.fit_mode == .none)
            .manual
        else if (self.fit_mode.isFill())
            .fill
        else
            .fit;
        self.zoom_factor = .{ .value = 1.0 };
        self.pan_x = 0.0;
        self.pan_y = 0.0;
        self.compare_original = false;
    }

    /// Explicitly assigns the pan offset coordinates.
    pub fn setPan(self: *ViewportParams, px: f32, py: f32) void {
        self.pan_x = px;
        self.pan_y = py;
    }

    /// Displaces current pan offsets by relative delta increments (`dx`, `dy`).
    pub fn panBy(self: *ViewportParams, dx: f32, dy: f32) void {
        self.pan_x += dx;
        self.pan_y += dy;
    }

    /// Returns the effective physical zoom factor Z for the current frame.
    pub fn effectiveZoom(
        self: ViewportParams,
        view_w: f32,
        view_h: f32,
        raw_w: f32,
        raw_h: f32,
    ) f32 {
        if (raw_w <= 0.0 or raw_h <= 0.0 or view_w <= 0.0 or view_h <= 0.0) {
            return self.zoom_factor.get();
        }
        return switch (self.mode) {
            .fit => view_transform.computePresetZoom(
                raw_w,
                raw_h,
                self.rotation_angle,
                view_w,
                view_h,
                self.fit_mode,
            ),
            .fill => view_transform.computePresetZoom(
                raw_w,
                raw_h,
                self.rotation_angle,
                view_w,
                view_h,
                .crop,
            ),
            .manual => self.zoom_factor.get(),
        };
    }

    /// Returns true if image content overflows the viewport bounds.
    pub fn isOverflowing(
        self: ViewportParams,
        auth_w: f32,
        auth_h: f32,
        view_w: f32,
        view_h: f32,
    ) bool {
        if (auth_w <= 0.0 or auth_h <= 0.0 or view_w <= 0.0 or view_h <= 0.0) {
            return false;
        }
        const is_swapped = view_transform.isAngle90or270(self.rotation_angle);
        const img_w = if (is_swapped) auth_h else auth_w;
        const img_h = if (is_swapped) auth_w else auth_h;
        const z = self.effectiveZoom(view_w, view_h, auth_w, auth_h);
        return (img_w * z > view_w + 1.0) or (img_h * z > view_h + 1.0);
    }

    /// Returns true if non-neutral photographic exposure or contrast
    /// adjustments are applied.
    pub fn hasAdjustments(self: ViewportParams) bool {
        return self.edits.hasEdits();
    }

    /// Toggles Before/After comparison mode (original unadjusted image vs
    /// active adjustments). If no adjustments are applied, comparison mode
    /// remains inactive.
    pub fn toggleCompare(self: *ViewportParams) void {
        if (!self.hasAdjustments()) {
            self.compare_original = false;
            return;
        }
        self.compare_original = !self.compare_original;
    }

    /// Sets brightness in [-1.0, 1.0] and contrast in [0.0, 3.0].
    pub fn setAdjustments(self: *ViewportParams, br: f32, co: f32) void {
        self.edits.set(.brightness, br);
        self.edits.set(.contrast, co);
        self.compare_original = false;
    }

    /// Adjusts brightness by adding `delta`.
    pub fn adjustBrightness(self: *ViewportParams, delta: f32) void {
        self.edits.set(.brightness, self.edits.get(.brightness) + delta);
        self.compare_original = false;
    }

    /// Adjusts contrast by adding `delta`.
    pub fn adjustContrast(self: *ViewportParams, delta: f32) void {
        self.edits.set(.contrast, self.edits.get(.contrast) + delta);
        self.compare_original = false;
    }

    /// Rotates the viewport clockwise by 90 degrees with 360-degree
    /// normalization.
    pub fn rotateCw(self: *ViewportParams) void {
        var val = self.rotation_angle + 90.0;
        if (val >= 360.0) val -= 360.0;
        self.rotation_angle = val;
    }

    /// Rotates the viewport counter-clockwise by 90 degrees with 360-degree
    /// normalization.
    pub fn rotateCcw(self: *ViewportParams) void {
        var val = self.rotation_angle - 90.0;
        if (val < 0.0) val += 360.0;
        self.rotation_angle = val;
    }

    /// Zooms viewport to a new zoom factor while anchoring pan offsets relative
    /// to a physical framebuffer focus point and viewport center.
    pub fn zoomAtPoint(
        self: *ViewportParams,
        new_zoom: ZoomFactor,
        focus: PhysicalPoint,
        center: PhysicalPoint,
    ) void {
        self.mode = .manual;
        const old_zoom = self.zoom_factor;
        self.zoom_factor = new_zoom;
        const ratio = old_zoom.ratioTo(new_zoom);
        const rel_x = focus.x - center.x;
        const rel_y = focus.y - center.y;
        self.pan_x = rel_x - (rel_x - self.pan_x) * ratio;
        self.pan_y = rel_y - (rel_y - self.pan_y) * ratio;
    }

    /// Returns the integer uniform constant representing the active resampler
    /// filter for shader pipelines.
    pub fn getShaderScaleModeInt(self: ViewportParams) i32 {
        return switch (self.scale_filter) {
            .nearest => 0,
            .linear => 1,
            .pixel_art => 2,
            .mitchell => 3,
            .lanczos3 => 4,
            .fsr => 5,
            .tiny_cnn => 6,
        };
    }

    /// Returns true if viewport is zoomed or panned away from default
    /// fit-to-window view.
    pub inline fn isZoomed(self: ViewportParams) bool {
        return self.mode != .fit or self.pan_x != 0.0 or self.pan_y != 0.0;
    }
};

/// 4-bit directional bitmask for zero-allocation navigation tracking.
pub const DirectionFlags = packed struct(u4) {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,

    pub inline fn raw(self: DirectionFlags) u4 {
        return @backingInt(self);
    }

    pub inline fn fromRaw(val: u4) DirectionFlags {
        return @fromBackingInt(val);
    }

    pub inline fn hasAny(self: DirectionFlags) bool {
        return self.raw() != 0;
    }

    pub inline fn merge(
        self: DirectionFlags,
        other: DirectionFlags,
    ) DirectionFlags {
        return @fromBackingInt(self.raw() | other.raw());
    }
};

/// Dynamic state tracking for smooth directional keyboard viewport panning.
pub const PanController = struct {
    smooth_tap_remaining: f32 = 0.0,
    tap_direction: DirectionFlags = .{},
    prev_held: DirectionFlags = .{},
    suppressed_held: DirectionFlags = .{},

    pub const TAP_DISTANCE: f32 = 30.0;
    pub const GLIDE_SPEED: f32 = 800.0; // Physical pixels per second

    pub inline fn clearMotion(self: *PanController) void {
        self.smooth_tap_remaining = 0.0;
        self.tap_direction = .{};
        self.prev_held = .{};
    }

    pub inline fn reset(self: *PanController) void {
        self.clearMotion();
        self.suppressed_held = .{};
    }

    pub inline fn suppress(self: *PanController, held: DirectionFlags) void {
        self.clearMotion();
        self.suppressed_held = held;
    }

    pub inline fn isBusy(self: PanController) bool {
        return self.smooth_tap_remaining > 0.001 or self.prev_held.hasAny();
    }
};

/// Cardinal zoom direction for keyboard zooming.
pub const ZoomDirection = enum(u2) {
    none = 0,
    in = 1,
    out = 2,
};

/// 2-bit zoom direction bitmask for zero-allocation state tracking.
pub const ZoomFlags = packed struct(u2) {
    in: bool = false,
    out: bool = false,

    pub inline fn raw(self: ZoomFlags) u2 {
        return @backingInt(self);
    }

    pub inline fn fromRaw(val: u2) ZoomFlags {
        return @fromBackingInt(val);
    }

    pub inline fn hasAny(self: ZoomFlags) bool {
        return self.raw() != 0;
    }

    pub inline fn merge(self: ZoomFlags, other: ZoomFlags) ZoomFlags {
        return @fromBackingInt(self.raw() | other.raw());
    }
};

/// Dynamic state tracking for smooth keyboard viewport zooming.
pub const ZoomController = struct {
    smooth_tap_remaining: f32 = 0.0,
    tap_direction: ZoomDirection = .none,
    prev_held: ZoomFlags = .{},
    suppressed_held: ZoomFlags = .{},
    detent_pause_ms: f32 = 0.0,
    detent_target: ?f32 = null,

    pub const TAP_STEP_RATIO: f32 = 1.25;
    pub const TAP_LOG_DISTANCE: f32 = 0.22314355; // @log(1.25)
    pub const GLIDE_RATE: f32 = 1.5; // Log units/sec (~4.5x per sec on hold)
    pub const DETENT_PAUSE_MS: f32 = 150.0; // 150ms detent pause at 1.0x

    pub inline fn clearMotion(self: *ZoomController) void {
        self.smooth_tap_remaining = 0.0;
        self.tap_direction = .none;
        self.prev_held = .{};
        self.detent_pause_ms = 0.0;
        self.detent_target = null;
    }

    pub inline fn reset(self: *ZoomController) void {
        self.clearMotion();
        self.suppressed_held = .{};
    }

    pub inline fn suppress(self: *ZoomController, held: ZoomFlags) void {
        self.clearMotion();
        self.suppressed_held = held;
    }

    pub inline fn isBusy(self: ZoomController) bool {
        return self.smooth_tap_remaining > 0.0001 or
            self.prev_held.hasAny() or
            self.detent_pause_ms > 0.001;
    }

    pub fn triggerTap(
        self: *ZoomController,
        dir: ZoomDirection,
        current_zoom: f32,
    ) void {
        if (dir == .none) return;
        self.tap_direction = dir;
        self.smooth_tap_remaining = TAP_LOG_DISTANCE;
        const factor: f32 = if (dir == .in)
            TAP_STEP_RATIO
        else
            (1.0 / TAP_STEP_RATIO);
        const projected = current_zoom * factor;
        if (dir == .in and current_zoom < 1.0 and projected >= 1.0) {
            self.detent_target = 1.0;
        } else if (dir == .out and current_zoom > 1.0 and projected <= 1.0) {
            self.detent_target = 1.0;
        } else {
            self.detent_target = null;
        }
    }
};

/// Aggregated input events, mouse coordinates, keyboard actions, and window
/// metrics for a single frame iteration.
pub const FrameInput = struct {
    win_w: f32,
    win_h: f32,
    scale_x: f32,
    scale_y: f32,
    mouse_x: f32,
    mouse_y: f32,
    mouse_left_down: bool,
    mouse_left_clicked: bool,
    mouse_inside: bool,
    quit_requested: bool,
    scroll_delta_x: f32,
    scroll_delta_y: f32,
    pinch_delta: f32 = 0.0,
    pinch_center_x: f32 = 0.0,
    pinch_center_y: f32 = 0.0,
    keys_pressed: std.ArrayList(Key),
    key_modifiers: KeyModifiers,
    directional_held: DirectionFlags = .{},
    zoom_held: ZoomFlags = .{},
    text_input: ?[]const u8,
    dropped_path: ?[]const u8,
    delta_time_ms: f32,
    /// Current frame timestamp in milliseconds.
    now_ms: u64 = 0,
    is_pointer_in_debug_panel: bool = false,

    /// Returns the sanitized display DPI scale factor for this frame.
    pub inline fn dpiScale(self: FrameInput) DpiScale {
        return DpiScale.init(self.scale_x, self.scale_y);
    }

    /// Returns the window dimensions in logical UI points.
    pub inline fn logicalWinDims(self: FrameInput) LogicalDims {
        return .{ .w = self.win_w, .h = self.win_h };
    }

    /// Returns the mouse cursor coordinates in logical UI points.
    pub inline fn logicalMousePos(self: FrameInput) LogicalPoint {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    /// Returns the mouse cursor coordinates scaled to physical framebuffer
    /// pixels.
    pub inline fn physicalMousePos(self: FrameInput) PhysicalPoint {
        return self.logicalMousePos().toPhysical(self.dpiScale());
    }

    /// Returns the mouse X coordinate scaled to physical framebuffer pixels.
    pub inline fn pixMouseX(self: FrameInput) f32 {
        return self.physicalMousePos().x;
    }

    /// Returns the mouse Y coordinate scaled to physical framebuffer pixels.
    pub inline fn pixMouseY(self: FrameInput) f32 {
        return self.physicalMousePos().y;
    }

    /// Returns `true` if the cursor is positioned within Clay's debug sidebar
    /// panel.
    pub fn isPointerInDebugPanel(self: FrameInput) bool {
        return self.is_pointer_in_debug_panel;
    }
};

/// Metadata describing an action executable from the Command Palette,
/// including its shortcut and intent.
pub const ActionMetadata = intents.actions.ActionMetadata;

/// Command Palette items projected from the unified action registry.
pub const palette_action_items = intents.actions.palette_action_items;

/// Flattened keyboard shortcut entry mapping a specific key and modifier
/// combination directly to an AppIntent.
pub const FlatShortcut = intents.actions.FlatShortcut;

/// Flattened keyboard shortcuts projected from the unified action registry.
pub const flat_shortcuts = intents.actions.flat_shortcuts;

/// Unique identification tags for interactive Clay UI layout elements.
pub const ElementTag = enum(usize) {
    none = 0,
    image_viewer = 1,
    drop_zone_box = 2,
    blurred_surface = 3,

    /// Converts element tag enum to raw integer index.
    pub fn toInt(self: ElementTag) usize {
        return @backingInt(self);
    }

    /// Converts raw integer index to corresponding `ElementTag` enum variant.
    pub fn fromInt(val: usize) ElementTag {
        return switch (val) {
            1 => .image_viewer,
            2 => .drop_zone_box,
            3 => .blurred_surface,
            else => .none,
        };
    }
};

/// Title display visibility modes, unifying permanent pinned display and transient auto-hide timer.
pub const TitleDisplay = union(enum) {
    hidden,
    pinned,
    transient: struct {
        timeout_ms: u64,
    },

    pub fn isPinned(self: TitleDisplay) bool {
        return self == .pinned;
    }
};

/// Non-destructive photographic edit parameters.
pub const ImageEdits = struct {
    values: [EditParam.count]f32 = initDefaults(),

    fn initDefaults() [EditParam.count]f32 {
        var initial: [EditParam.count]f32 = undefined;
        for (std.enums.values(EditParam)) |p| {
            initial[@backingInt(p)] = getSpec(p).default;
        }
        return initial;
    }

    /// Gets the current value for the specified parameter.
    pub inline fn get(self: ImageEdits, param: EditParam) f32 {
        return self.values[@backingInt(param)];
    }

    /// Clamps and sets the specified parameter value.
    pub inline fn set(self: *ImageEdits, param: EditParam, val: f32) void {
        self.values[@backingInt(param)] = getSpec(param).clamp(val);
    }

    /// Resets the specified parameter to its default value.
    pub inline fn resetParam(self: *ImageEdits, param: EditParam) void {
        self.values[@backingInt(param)] = getSpec(param).default;
    }

    /// Resets all adjustments to neutral defaults.
    pub fn reset(self: *ImageEdits) void {
        for (std.enums.values(EditParam)) |p| {
            self.values[@backingInt(p)] = getSpec(p).default;
        }
    }

    /// Returns true if non-neutral adjustments are applied.
    pub fn hasEdits(self: ImageEdits) bool {
        for (std.enums.values(EditParam)) |p| {
            if (p == .contrast_blend) {
                // contrast_blend only has visual impact if contrast is
                // non-neutral
                const c_def = getSpec(.contrast).default;
                if (@abs(self.get(.contrast) - c_def) <= 1e-5) continue;
            }
            const def = getSpec(p).default;
            if (@abs(self.values[@backingInt(p)] - def) > 1e-5) return true;
        }
        return false;
    }

    /// Returns true if the specific parameter is at its neutral default value.
    pub fn isParamDefault(self: ImageEdits, param: EditParam) bool {
        const def = getSpec(param).default;
        return @abs(self.values[@backingInt(param)] - def) <= 1e-5;
    }
};

pub const EDIT_PANEL_WIDTH: f32 = 280.0;
pub const EDIT_PANEL_PADDING: f32 = 16.0;

/// Side panel state managing visibility and active slider interactions
/// for image adjustments.
pub const EditPanelState = struct {
    visible: bool = false,
    active_slider: ?EditParam = null,
    width: f32 = EDIT_PANEL_WIDTH,
};

/// Floating HUD panel state managing visibility and user-dragged 2D offset coordinates.
pub const FloatingPanel = struct {
    visible: bool = false,
    offset_x: f32 = 0.0,
    offset_y: f32 = 0.0,
};

/// Visibility modes, floating panel positions, and rendering flags for HUD overlays.
pub const OverlayState = struct {
    info_panel: FloatingPanel = .{ .visible = false, .offset_x = 20.0, .offset_y = 20.0 },
    stats_panel: FloatingPanel = .{ .visible = false, .offset_x = -20.0, .offset_y = 20.0 },
    edit_panel: EditPanelState = .{},
    title_display: TitleDisplay = .hidden,
    auto_title: bool = true,
    debug_show_thumb: bool = false,
    enable_blur: bool = true,

    /// Returns true if any floating HUD dialogs (Info or Stats) are visible.
    pub fn hasVisibleFloatingPanels(self: OverlayState) bool {
        return self.info_panel.visible or self.stats_panel.visible;
    }

    /// Dismisses all visible floating HUD dialogs.
    /// Returns true if at least one dialog was open; false otherwise.
    pub fn dismissFloatingPanels(self: *OverlayState) bool {
        const had_visible = self.hasVisibleFloatingPanels();
        self.info_panel.visible = false;
        self.stats_panel.visible = false;
        return had_visible;
    }
};

/// Rolling window of recent frame render duration samples computing mean and standard deviation.
pub const RenderStats = struct {
    samples: [60]f64 = @splat(0.0),
    head: usize = 0,
    count: usize = 0,

    /// Records a new duration sample in milliseconds into the 60-slot rolling ring buffer.
    pub fn addSample(self: *RenderStats, sample_ms: f64) void {
        self.samples[self.head] = sample_ms;
        self.head = (self.head + 1) % 60;
        if (self.count < 60) self.count += 1;
    }

    /// Computes the arithmetic mean and sample standard deviation across all
    /// recorded duration samples.
    pub fn getMeanAndStdev(self: RenderStats) struct { mean: f64, stdev: f64 } {
        if (self.count == 0) return .{ .mean = 0.0, .stdev = 0.0 };
        var sum: f64 = 0.0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            sum += self.samples[i];
        }
        const mean = sum / @as(f64, @floatFromInt(self.count));
        if (self.count < 2) return .{ .mean = mean, .stdev = 0.0 };

        var variance_sum: f64 = 0.0;
        i = 0;
        while (i < self.count) : (i += 1) {
            const diff = self.samples[i] - mean;
            variance_sum += diff * diff;
        }
        const variance = @max(0.0, variance_sum) / @as(f64, @floatFromInt(self.count - 1));
        return .{ .mean = mean, .stdev = @sqrt(variance) };
    }
};

/// Snapshot of UI rendering timing statistics, batch counts, and vertex counts
/// for on-screen telemetry.
pub const UiRenderMetricsSnapshot = struct {
    mean_render_time_ms: f64 = 0.0,
    stdev_render_time_ms: f64 = 0.0,
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,
};

/// UI frame rendering performance metrics, vertex counts, batch counts, and
/// rolling duration history.
pub const UiRenderMetrics = struct {
    ui_render_stats: RenderStats = .{},
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,

    /// Creates an immutable performance snapshot containing calculated
    /// mean/stdev and element counts.
    pub fn toSnapshot(self: UiRenderMetrics) UiRenderMetricsSnapshot {
        const stats = self.ui_render_stats.getMeanAndStdev();
        return .{
            .mean_render_time_ms = stats.mean,
            .stdev_render_time_ms = stats.stdev,
            .last_ui_vertex_count = self.last_ui_vertex_count,
            .last_ui_batch_count = self.last_ui_batch_count,
        };
    }
};

/// Container extraction metrics for compressed images (CBZ / ZIP archives).
pub const ArchiveTelemetry = union(enum) {
    none,
    archive: struct {
        decompress_time_ms: f64,
        compressed_size_bytes: usize,
    },

    /// Constructs an ArchiveTelemetry variant based on decompression stats.
    pub fn init(
        decompress_time_ms: f64,
        compressed_size_bytes: usize,
    ) ArchiveTelemetry {
        if (compressed_size_bytes > 0 or decompress_time_ms > 0.0) {
            return .{
                .archive = .{
                    .decompress_time_ms = decompress_time_ms,
                    .compressed_size_bytes = compressed_size_bytes,
                },
            };
        }
        return .none;
    }
};

/// Hardware upload strategy executed for GPU texture allocation.
pub const UploadMode = union(enum) {
    direct,
    fallback: struct {
        fallback_time_ms: f64,
    },

    /// Constructs an UploadMode variant indicating direct upload or fallback.
    pub fn init(was_fallback: bool, fallback_time_ms: f64) UploadMode {
        if (was_fallback) {
            return .{ .fallback = .{ .fallback_time_ms = fallback_time_ms } };
        }
        return .direct;
    }
};

/// Mipmap pyramid generation status and performance timing.
pub const MipmapTelemetry = union(enum) {
    disabled,
    generated: struct {
        num_levels: u32,
        generate_time_ms: f64,
    },

    /// Constructs a MipmapTelemetry variant for single or multi-level textures.
    pub fn init(num_levels: u32, generate_time_ms: f64) MipmapTelemetry {
        if (num_levels > 1) {
            return .{
                .generated = .{
                    .num_levels = num_levels,
                    .generate_time_ms = generate_time_ms,
                },
            };
        }
        return .disabled;
    }
};

/// Performance timing metrics common to all CPU image decompressions.
pub const DecodeTelemetry = struct {
    read_time_ms: f64 = 0.0,
    decode_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    archive: ArchiveTelemetry = .none,
};

/// Telemetry metrics specific to GPU texture upload, downscaling, and mipmaps.
pub const IngestTelemetry = struct {
    upload_time_ms: f64 = 0.0,
    memory_size_bytes: usize = 0,
    mode: UploadMode = .direct,
    mipmaps: MipmapTelemetry = .disabled,
};

/// Source from which a preview thumbnail was loaded.
pub const ThumbnailSource = enum {
    /// Extracted from the initial 256 KB header read (EXIF IFD1 or SubIFD).
    embedded_header,
    /// Extracted via positional read at an offset beyond the 256 KB header.
    embedded_positional,
    /// Loaded from the Freedesktop Shared Thumbnail Cache
    /// (`$XDG_CACHE_HOME/thumbnails/`).
    freedesktop_cache,

    /// Returns `true` if the thumbnail bitmap is already rotated into upright
    /// visual orientation on disk (true for Freedesktop cached PNGs, false for
    /// unrotated embedded EXIF thumbnails).
    pub inline fn isPreOriented(self: ThumbnailSource) bool {
        return switch (self) {
            .embedded_header, .embedded_positional => false,
            .freedesktop_cache => true,
        };
    }

    /// Short label for "Stats for Nerds" HUD rows.
    pub fn shortLabel(self: ThumbnailSource) []const u8 {
        return switch (self) {
            .embedded_header => "Header",
            .embedded_positional => "Positional",
            .freedesktop_cache => "XDG Cache",
        };
    }

    /// Descriptive label for "Info Overlay" HUD rows.
    pub fn infoLabel(self: ThumbnailSource) []const u8 {
        return switch (self) {
            .embedded_header, .embedded_positional => "Embedded",
            .freedesktop_cache => "Freedesktop",
        };
    }
};

/// Lightweight thumbnail dimension, GPU upload latency, source, and DCT block
/// snapping metadata.
pub const ThumbnailInfo = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,
    upload_time_ms: f64 = 0.0,
    dct_snapped: bool = false,
    source: ThumbnailSource = .embedded_header,
};

/// Automatic slideshow playback mode, advance interval, accumulated frame timer, and pause state.
pub const SlideshowMode = union(enum) {
    inactive,
    active: struct {
        interval_s: f32,
        timer_ms: f64 = 0.0,
        is_paused: bool = false,
    },

    pub const MIN_INTERVAL_S: f32 = 0.1;
    pub const MAX_INTERVAL_S: f32 = 3600.0;

    /// Advances the internal slideshow timer by `delta_ms`; returns `true`
    /// if the interval has elapsed. Does NOT advance when paused or inactive.
    pub fn tick(self: *SlideshowMode, delta_ms: f32) bool {
        switch (self.*) {
            .inactive => return false,
            .active => |*data| {
                if (data.is_paused or data.interval_s <= 0.0) return false;
                data.timer_ms += delta_ms;
                if (data.timer_ms >= data.interval_s * 1000.0) {
                    data.timer_ms = 0.0;
                    return true;
                }
                return false;
            },
        }
    }

    /// Resets the slideshow timer accumulator to zero without changing the interval or pause state.
    pub fn resetTimer(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.timer_ms = 0.0,
        }
    }

    /// Returns `true` if slideshow is active and currently paused.
    pub inline fn isPaused(self: *const SlideshowMode) bool {
        return switch (self.*) {
            .inactive => false,
            .active => |a| a.is_paused,
        };
    }

    /// Pauses timer accumulation without changing interval or resetting elapsed progress.
    pub fn pause(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.is_paused = true,
        }
    }

    /// Resumes timer accumulation from its current elapsed millisecond position.
    pub fn unpause(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.is_paused = false,
        }
    }
};

/// Active image transition payload tracking the outgoing image during a dissolve animation.
pub const ActiveImageTransition = struct {
    prev_index: usize,
    prev_rotation: f32,
    prev_zoom: f32 = 1.0,
    prev_pan_x: f32 = 0.0,
    prev_pan_y: f32 = 0.0,
};

/// Active image transition state tracking the outgoing image during a dissolve animation.
pub const ImageTransition = union(enum) {
    none,
    active: ActiveImageTransition,

    /// Returns the protected previous image index if a crossfade transition is active.
    pub inline fn getPrevIndex(self: ImageTransition) ?usize {
        return switch (self) {
            .none => null,
            .active => |t| t.prev_index,
        };
    }
};

/// Active payload for the action confirmation snackbar.
pub const ActiveSnackbar = struct {
    reveal: f32,
    message: []const u8,
};

/// Presentation state of the action confirmation snackbar in the UI view model.
pub const SnackbarDisplay = union(enum) {
    none,
    active: ActiveSnackbar,

    /// Returns the active payload if the snackbar is currently active, or null if none.
    pub inline fn getActive(self: SnackbarDisplay) ?ActiveSnackbar {
        return switch (self) {
            .none => null,
            .active => |a| a,
        };
    }
};

/// Active image performance telemetry for Stats for Nerds overlay.
pub const ActiveImageStats = struct {
    decode: ?DecodeTelemetry = null,
    ingest: ?IngestTelemetry = null,
    has_thumb: bool = false,
    thumb_upload_time_ms: f64 = 0.0,
    thumb_source: ThumbnailSource = .embedded_header,
};

/// Unified telemetry counters for thumbnail extraction, shared cache reads,
/// and background shared cache writes.
pub const ThumbnailStats = struct {
    header_hits: usize = 0,
    positional_hits: usize = 0,
    cache_hits: usize = 0,
    misses: usize = 0,
    cache_writes: usize = 0,
    cache_write_queued: usize = 0,

    /// Total number of thumbnail lookup attempts across all sources and misses.
    pub inline fn totalLookups(self: ThumbnailStats) usize {
        return self.header_hits +
            self.positional_hits +
            self.cache_hits +
            self.misses;
    }
};

/// Snapshot of application telemetry and diagnostic counters copied once per frame
/// for UI rendering ("Stats for Nerds") without reading live atomics.
pub const ViewerStats = struct {
    // Unified EXIF & Freedesktop thumbnail telemetry
    thumbs: ThumbnailStats = .{},

    // Cache telemetry
    current_image_cache_hit: bool = false,
    cached_slot_count: usize = 0,
    total_vram_bytes: usize = 0,

    // Worker telemetry (frame snapshot)
    active_decode_threads: usize = 0,
    max_decode_threads: usize = 0,

    // Active image GPU & decoder stats
    active_image: ActiveImageStats = .{},
};

/// Grace period threshold in milliseconds before displaying "Loading image..." in the UI.
/// Prevents text flickering when scrubbing through thumbnails or fast-decoding
/// formats (~2 frames at 60Hz).
pub const LOADING_GRACE_PERIOD_MS: u64 = 35;

/// Pending asynchronous screenshot request with target destination path and IPC stream.
pub const ActiveScreenshot = struct {
    path: [:0]const u8,
    stream: std.Io.net.Stream,

    /// Writes a JSON success confirmation (`{"ok":true}\n`) back to the client
    /// IPC stream and frees request resources.
    pub fn respondOk(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
    ) void {
        var write_buf: [128]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        std.json.Stringify.value(
            .{ .ok = true },
            .{},
            &writer.interface,
        ) catch |werr| {
            std.log.warn("Screenshot response failed: {}", .{werr});
        };
        writer.interface.writeByte('\n') catch |werr| {
            std.log.warn("Screenshot newline write failed: {}", .{werr});
        };
        writer.interface.flush() catch |ferr| {
            std.log.warn("Screenshot response flush failed: {}", .{ferr});
        };
        self.stream.close(io);
        gpa.free(self.path);
    }

    /// Writes a JSON error response (`{"ok":false,"error":"<name>"}\n`) back to
    /// the client IPC stream and frees request resources.
    pub fn respondErr(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
        err: anyerror,
    ) void {
        self.respondErrName(io, gpa, @errorName(err));
    }

    /// Sends an emergency `{"ok":false,"error":"quit"}\n` response to the
    /// client IPC stream when exiting unexpectedly.
    pub fn respondQuit(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
    ) void {
        self.respondErrName(io, gpa, "quit");
    }

    /// Writes a JSON error response (`{"ok":false,"error":"<err_name>"}\n`) to
    /// the client IPC stream and frees request resources.
    pub fn respondErrName(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
        err_name: []const u8,
    ) void {
        var write_buf: [160]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        std.json.Stringify.value(
            .{ .ok = false, .@"error" = err_name },
            .{},
            &writer.interface,
        ) catch |werr| {
            std.log.warn("Screenshot error response failed: {}", .{werr});
        };
        writer.interface.writeByte('\n') catch |werr| {
            std.log.warn("Screenshot error newline write failed: {}", .{werr});
        };
        writer.interface.flush() catch |ferr| {
            std.log.warn("Screenshot response flush failed: {}", .{ferr});
        };
        self.stream.close(io);
        gpa.free(self.path);
    }
};

/// Represents current active mouse drag interaction state across the viewer UI.
pub const DragState = union(enum) {
    none,
    viewport: struct {
        last_x: f32,
        last_y: f32,
    },
    info: struct {
        start_x: f32,
        start_y: f32,
    },
    stats: struct {
        start_x: f32,
        start_y: f32,
    },
    slider: struct {
        param: EditParam,
        track_x: f32,
        track_w: f32,
    },
};

test "ViewportParams.zoomAtPoint anchors zoom relative to focus point" {
    var vp = ViewportParams{};
    try std.testing.expectEqual(@as(f32, 1.0), vp.zoom_factor.get());
    try std.testing.expectEqual(@as(f32, 0.0), vp.pan_x);
    try std.testing.expectEqual(@as(f32, 0.0), vp.pan_y);

    // Zoom in 2x focused at (100, 100) relative to viewport center (500, 400)
    // -> rel = (-400, -300)
    vp.zoomAtPoint(
        ZoomFactor.init(2.0),
        .{ .x = 100.0, .y = 100.0 },
        .{ .x = 500.0, .y = 400.0 },
    );
    try std.testing.expectEqual(@as(f32, 2.0), vp.zoom_factor.get());
    try std.testing.expectEqual(@as(f32, 400.0), vp.pan_x);
    try std.testing.expectEqual(@as(f32, 300.0), vp.pan_y);
}

test "LogicalDims, PhysicalDims, LogicalPoint, and PhysicalPoint conversions" {
    const scale = DpiScale.init(2.0, 2.0);
    const log_dims = LogicalDims{ .w = 1000.0, .h = 800.0 };
    const phys_dims = log_dims.toPhysical(scale);
    try std.testing.expectApproxEqAbs(@as(f32, 2000.0), phys_dims.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1600.0), phys_dims.h, 0.001);

    const roundtrip_dims = phys_dims.toLogical(scale);
    try std.testing.expectApproxEqAbs(
        @as(f32, 1000.0),
        roundtrip_dims.w,
        0.001,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 800.0), roundtrip_dims.h, 0.001);

    const log_pt = LogicalPoint{ .x = 250.0, .y = 150.0 };
    const phys_pt = log_pt.toPhysical(scale);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), phys_pt.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), phys_pt.y, 0.001);

    // Invalid / non-positive scale sanitizes to 1.0
    const bad_scale = DpiScale.init(0.0, std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 1.0), bad_scale.x);
    try std.testing.expectEqual(@as(f32, 1.0), bad_scale.y);
}

test "ViewportParams isOverflowing and effectiveZoom" {
    var vp = ViewportParams{};
    // 1024x682 in 1024x768 with .fit (.full) mode does not overflow
    try std.testing.expect(!vp.isOverflowing(1024.0, 682.0, 1024.0, 768.0));

    // .fit_width on a tall portrait image (800x1600 in 1000x800) overflows Y
    vp.fit_mode = .fit_width;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.25),
        vp.effectiveZoom(1000.0, 800.0, 800.0, 1600.0),
        0.0001,
    );
    try std.testing.expect(vp.isOverflowing(800.0, 1600.0, 1000.0, 800.0));

    // .fit_height on a wide landscape image (1600x800 in 1000x800) overflows X
    vp.fit_mode = .fit_height;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        vp.effectiveZoom(1000.0, 800.0, 1600.0, 800.0),
        0.0001,
    );
    try std.testing.expect(vp.isOverflowing(1600.0, 800.0, 1000.0, 800.0));

    // .shrink on a small image (400x300 in 1000x800) keeps 1.0x and does not
    // overflow
    vp.fit_mode = .shrink;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        vp.effectiveZoom(1000.0, 800.0, 400.0, 300.0),
        0.0001,
    );
    try std.testing.expect(!vp.isOverflowing(400.0, 300.0, 1000.0, 800.0));

    // Rotated 90 degrees in .fit_width (1600x800 -> 800x1600 in 1000x800)
    vp.fit_mode = .fit_width;
    vp.rotation_angle = 90.0;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.25),
        vp.effectiveZoom(1000.0, 800.0, 1600.0, 800.0),
        0.0001,
    );
    try std.testing.expect(vp.isOverflowing(1600.0, 800.0, 1000.0, 800.0));
    vp.rotation_angle = 0.0;

    // .fill mode (crop) causes overflow
    vp.fit_mode = .crop;
    vp.mode = .fill;
    try std.testing.expect(vp.isOverflowing(1024.0, 682.0, 1024.0, 768.0));

    // .manual mode at 2.0x causes overflow
    vp.mode = .manual;
    vp.zoom_factor = ZoomFactor.init(2.0);
    try std.testing.expect(vp.isOverflowing(1024.0, 682.0, 1024.0, 768.0));

    // .manual mode at 0.5x fits inside
    vp.zoom_factor = ZoomFactor.init(0.5);
    try std.testing.expect(!vp.isOverflowing(1024.0, 682.0, 1024.0, 768.0));
}

test "FrameInput.pixMouseX and pixMouseY scale mouse position by display scale factor" {
    const input = FrameInput{
        .win_w = 1000.0,
        .win_h = 800.0,
        .scale_x = 2.0,
        .scale_y = 2.0,
        .mouse_x = 150.0,
        .mouse_y = 250.0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0.0,
        .scroll_delta_y = 0.0,
        .keys_pressed = undefined,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };
    try std.testing.expectEqual(@as(f32, 300.0), input.pixMouseX());
    try std.testing.expectEqual(@as(f32, 500.0), input.pixMouseY());
}

test "ViewportParams.getShaderScaleModeInt maps filters including lanczos3" {
    var params = ViewportParams{};
    params.scale_filter = .lanczos3;
    try std.testing.expectEqual(@as(i32, 4), params.getShaderScaleModeInt());

    params.scale_filter = .mitchell;
    try std.testing.expectEqual(@as(i32, 3), params.getShaderScaleModeInt());

    params.scale_filter = .fsr;
    try std.testing.expectEqual(@as(i32, 5), params.getShaderScaleModeInt());

    params.scale_filter = .tiny_cnn;
    try std.testing.expectEqual(@as(i32, 6), params.getShaderScaleModeInt());
}

test "ElementTag.fromInt" {
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0));
    try std.testing.expectEqual(ElementTag.drop_zone_box, ElementTag.fromInt(2));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(1337));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(9999));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0x7fffffffd000));
}

test "SnackbarDisplay getActive" {
    const none_display: SnackbarDisplay = .none;
    try std.testing.expect(none_display.getActive() == null);

    const active_display: SnackbarDisplay = .{
        .active = .{ .reveal = 0.85, .message = "Filter: Lanczos3" },
    };
    const payload = active_display.getActive().?;
    try std.testing.expectEqual(@as(f32, 0.85), payload.reveal);
    try std.testing.expectEqualStrings("Filter: Lanczos3", payload.message);
}

test "SlideshowMode lifecycle, pause, and unpause" {
    // Inactive mode does not tick
    var mode: SlideshowMode = .inactive;
    try std.testing.expect(!mode.isPaused());
    try std.testing.expect(!mode.tick(1000.0));

    // Active mode ticking
    mode = .{ .active = .{ .interval_s = 2.0 } };
    try std.testing.expect(!mode.isPaused());

    // Advance 1s (halfway) -> returns false
    try std.testing.expect(!mode.tick(1000.0));
    try std.testing.expectEqual(@as(f64, 1000.0), mode.active.timer_ms);

    // Pause slideshow -> tick returns false and timer DOES NOT advance
    mode.pause();
    try std.testing.expect(mode.isPaused());
    try std.testing.expect(!mode.tick(1000.0));
    try std.testing.expectEqual(@as(f64, 1000.0), mode.active.timer_ms);

    // Resume -> timer continues from 1000ms
    mode.unpause();
    try std.testing.expect(!mode.isPaused());
    try std.testing.expect(mode.tick(1000.0)); // 1000 + 1000 = 2000ms >= 2.0s -> fires and resets
    try std.testing.expectEqual(@as(f64, 0.0), mode.active.timer_ms);
}

test "ImageTransition getPrevIndex and variants" {
    var trans: ImageTransition = .none;
    try std.testing.expectEqual(@as(?usize, null), trans.getPrevIndex());

    trans = .{ .active = .{ .prev_index = 42, .prev_rotation = 180.0 } };
    try std.testing.expectEqual(@as(?usize, 42), trans.getPrevIndex());
    try std.testing.expectEqual(@as(f32, 180.0), trans.active.prev_rotation);

    trans = .none;
    try std.testing.expectEqual(@as(?usize, null), trans.getPrevIndex());
}

test "OverlayState floating panel dismissal" {
    var overlays = OverlayState{};
    try std.testing.expect(!overlays.hasVisibleFloatingPanels());
    try std.testing.expect(!overlays.dismissFloatingPanels());

    // Show info panel
    overlays.info_panel.visible = true;
    try std.testing.expect(overlays.hasVisibleFloatingPanels());

    // Show stats panel as well
    overlays.stats_panel.visible = true;
    try std.testing.expect(overlays.hasVisibleFloatingPanels());

    // Dismiss should close both and return true
    try std.testing.expect(overlays.dismissFloatingPanels());
    try std.testing.expect(!overlays.info_panel.visible);
    try std.testing.expect(!overlays.stats_panel.visible);
    try std.testing.expect(!overlays.hasVisibleFloatingPanels());

    // Subsequent dismissal returns false
    try std.testing.expect(!overlays.dismissFloatingPanels());
}

test "ViewportParams Before/After comparison lifecycle" {
    var vp = ViewportParams{};
    try std.testing.expect(!vp.hasAdjustments());
    try std.testing.expect(!vp.compare_original);

    // Toggling without adjustments remains false
    vp.toggleCompare();
    try std.testing.expect(!vp.compare_original);

    // Apply adjustments
    vp.adjustBrightness(0.2);
    try std.testing.expect(vp.hasAdjustments());
    try std.testing.expect(!vp.compare_original);

    // Toggle on
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);

    // Toggle off
    vp.toggleCompare();
    try std.testing.expect(!vp.compare_original);

    // Toggle on then verify adjustBrightness resets compare_original
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);
    vp.adjustBrightness(-0.1);
    try std.testing.expect(!vp.compare_original);

    // Toggle on then verify adjustContrast resets compare_original
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);
    vp.adjustContrast(0.1);
    try std.testing.expect(!vp.compare_original);

    // Toggle on then verify setAdjustments resets compare_original
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);
    vp.setAdjustments(0.0, 1.0);
    try std.testing.expect(!vp.compare_original);
    try std.testing.expect(!vp.hasAdjustments());

    // Toggle on then verify reset() resets compare_original
    vp.setAdjustments(0.1, 1.2);
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);
    vp.reset();
    try std.testing.expect(!vp.compare_original);
}

test "ImageEdits and ParamSpec exhaustive verification" {
    var edits = ImageEdits{};
    try std.testing.expect(!edits.hasEdits());

    for (std.enums.values(EditParam)) |param| {
        try std.testing.expect(edits.isParamDefault(param));
        const spec = getSpec(param);
        try std.testing.expectEqual(spec.default, edits.get(param));

        // Test clamping
        edits.set(param, spec.min - 10.0);
        try std.testing.expectEqual(spec.min, edits.get(param));
        edits.set(param, spec.max + 10.0);
        try std.testing.expectEqual(spec.max, edits.get(param));

        // Test snapping
        const snapped = spec.snap(spec.default + spec.snap_radius * 0.5);
        try std.testing.expectEqual(spec.default, snapped);

        // Test resetParam
        edits.resetParam(param);
        try std.testing.expect(edits.isParamDefault(param));
    }

    try std.testing.expect(!edits.hasEdits());
    edits.set(.highlights, 0.4);
    try std.testing.expect(edits.hasEdits());
    edits.reset();
    try std.testing.expect(!edits.hasEdits());
}

test "ArchiveTelemetry - init returns .none for normal and .archive for CBZ" {
    const none_val = ArchiveTelemetry.init(0.0, 0);
    try std.testing.expectEqual(ArchiveTelemetry.none, none_val);

    const arch_time = ArchiveTelemetry.init(14.5, 0);
    switch (arch_time) {
        .none => return error.TestExpectedArchive,
        .archive => |a| {
            try std.testing.expectEqual(@as(f64, 14.5), a.decompress_time_ms);
            try std.testing.expectEqual(@as(usize, 0), a.compressed_size_bytes);
        },
    }

    const arch_size = ArchiveTelemetry.init(0.0, 1024);
    switch (arch_size) {
        .none => return error.TestExpectedArchive,
        .archive => |a| {
            try std.testing.expectEqual(@as(f64, 0.0), a.decompress_time_ms);
            try std.testing.expectEqual(
                @as(usize, 1024),
                a.compressed_size_bytes,
            );
        },
    }
}

test "UploadMode - init distinguishes direct VRAM from fallback" {
    const direct_mode = UploadMode.init(false, 0.0);
    try std.testing.expectEqual(UploadMode.direct, direct_mode);

    const fallback_mode = UploadMode.init(true, 12.5);
    switch (fallback_mode) {
        .direct => return error.TestExpectedFallback,
        .fallback => |fb| {
            try std.testing.expectEqual(@as(f64, 12.5), fb.fallback_time_ms);
        },
    }
}

test "MipmapTelemetry - init distinguishes disabled from multi-level" {
    const disabled_mip = MipmapTelemetry.init(1, 0.0);
    try std.testing.expectEqual(MipmapTelemetry.disabled, disabled_mip);

    const gen_mip = MipmapTelemetry.init(4, 5.2);
    switch (gen_mip) {
        .disabled => return error.TestExpectedGenerated,
        .generated => |g| {
            try std.testing.expectEqual(@as(u32, 4), g.num_levels);
            try std.testing.expectEqual(@as(f64, 5.2), g.generate_time_ms);
        },
    }
}
