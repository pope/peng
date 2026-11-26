const geom = @import("geom");
const intents = @import("intents");
const std = @import("std");
const view_transform = @import("view_transform.zig");

const EditParam = intents.EditParam;
const getSpec = intents.getSpec;
const PhysicalDims = geom.PhysicalDims;
const PhysicalPoint = geom.PhysicalPoint;
const ZoomPreset = intents.ZoomPreset;

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
        view_dims: PhysicalDims,
        raw_dims: PhysicalDims,
    ) f32 {
        if (raw_dims.w <= 0.0 or raw_dims.h <= 0.0 or
            view_dims.w <= 0.0 or view_dims.h <= 0.0)
        {
            return self.zoom_factor.get();
        }
        return switch (self.mode) {
            .fit => view_transform.computePresetZoom(
                raw_dims,
                self.rotation_angle,
                view_dims,
                self.fit_mode,
            ),
            .fill => view_transform.computePresetZoom(
                raw_dims,
                self.rotation_angle,
                view_dims,
                .crop,
            ),
            .manual => self.zoom_factor.get(),
        };
    }

    /// Applies a relative multiplicative zoom `ratio` (or optional absolute
    /// `snap_zoom` detent target), switching to `.manual` mode and scaling
    /// `pan_x`/`pan_y` proportionally around the viewport center.
    pub fn zoomBy(self: *ViewportParams, ratio: f32, snap_zoom: ?f32) void {
        if (ratio <= 0.0 or !std.math.isFinite(ratio)) return;
        if (snap_zoom) |snap| {
            if (snap <= 0.0 or !std.math.isFinite(snap)) return;
        }
        self.mode = .manual;
        const old_zoom = self.zoom_factor.get();
        const target = snap_zoom orelse @max(
            ZoomFactor.MIN,
            old_zoom * ratio,
        );
        const new_zoom = ZoomFactor.init(target);
        self.zoom_factor = new_zoom;
        const applied_ratio = new_zoom.get() / old_zoom;
        self.pan_x *= applied_ratio;
        self.pan_y *= applied_ratio;
    }

    /// Returns true if image content overflows the viewport bounds.
    pub fn isOverflowing(
        self: ViewportParams,
        auth_dims: PhysicalDims,
        view_dims: PhysicalDims,
    ) bool {
        if (auth_dims.w <= 0.0 or auth_dims.h <= 0.0 or
            view_dims.w <= 0.0 or view_dims.h <= 0.0)
        {
            return false;
        }
        const is_swapped = view_transform.isAngle90or270(self.rotation_angle);
        const img_w = if (is_swapped) auth_dims.h else auth_dims.w;
        const img_h = if (is_swapped) auth_dims.w else auth_dims.h;
        const z = self.effectiveZoom(view_dims, auth_dims);
        return (img_w * z > view_dims.w + 1.0) or
            (img_h * z > view_dims.h + 1.0);
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

    /// Converts directional flags into backing raw integer.
    pub inline fn raw(self: DirectionFlags) u4 {
        return @backingInt(self);
    }

    /// Reconstructs directional flags from backing raw integer.
    pub inline fn fromRaw(val: u4) DirectionFlags {
        return @fromBackingInt(val);
    }

    /// Returns true if any directional flag bit is set.
    pub inline fn hasAny(self: DirectionFlags) bool {
        return self.raw() != 0;
    }

    /// Merges two directional flags bitmasks via bitwise OR.
    pub inline fn merge(
        self: DirectionFlags,
        other: DirectionFlags,
    ) DirectionFlags {
        return @fromBackingInt(self.raw() | other.raw());
    }
};

/// Active discrete pan tap state tracking direction and remaining pixels.
pub const ActivePanTap = struct {
    direction: DirectionFlags,
    remaining_px: f32,
};

/// Mutually exclusive smooth pan tap lifecycle state.
pub const PanTap = union(enum) {
    idle,
    active: ActivePanTap,
};

/// Dynamic state tracking for smooth directional keyboard viewport panning.
pub const PanController = struct {
    tap: PanTap = .idle,
    prev_held: DirectionFlags = .{},
    suppressed_held: DirectionFlags = .{},

    pub const TAP_DISTANCE: f32 = 30.0;
    pub const TAP_EPSILON_PX: f32 = 0.001;
    pub const GLIDE_SPEED: f32 = 800.0; // Physical pixels per second

    /// Clears active smooth tap and held motion state.
    pub inline fn clearMotion(self: *PanController) void {
        self.tap = .idle;
        self.prev_held = .{};
    }

    /// Resets all pan controller state including suppressed directions.
    pub inline fn reset(self: *PanController) void {
        self.clearMotion();
        self.suppressed_held = .{};
    }

    /// Suppresses currently held directions until released.
    pub inline fn suppress(self: *PanController, held: DirectionFlags) void {
        self.clearMotion();
        self.suppressed_held = held;
    }

    /// Returns true if pan controller has an active tap or held input.
    pub inline fn isBusy(self: PanController) bool {
        return switch (self.tap) {
            .idle => false,
            .active => true,
        } or self.prev_held.hasAny();
    }

    /// Immediately settles any active discrete tap animation, returning the
    /// remaining `(dx, dy)` pixel delta and transitioning the controller to
    /// `.idle`. Returns `null` when idle or when opposing directions cancel.
    pub fn settleTap(self: *PanController) ?struct { dx: f32, dy: f32 } {
        return switch (self.tap) {
            .idle => null,
            .active => |tap| blk: {
                self.tap = .idle;
                if (!std.math.isFinite(tap.remaining_px) or
                    tap.remaining_px <= TAP_EPSILON_PX)
                {
                    break :blk null;
                }
                var vx: f32 = 0.0;
                var vy: f32 = 0.0;
                if (tap.direction.left) vx += 1.0;
                if (tap.direction.right) vx -= 1.0;
                if (tap.direction.up) vy += 1.0;
                if (tap.direction.down) vy -= 1.0;
                if (vx == 0.0 and vy == 0.0) break :blk null;
                if (vx != 0.0 and vy != 0.0) {
                    const inv_sqrt2: f32 = 0.70710678;
                    vx *= inv_sqrt2;
                    vy *= inv_sqrt2;
                }
                break :blk .{
                    .dx = vx * tap.remaining_px,
                    .dy = vy * tap.remaining_px,
                };
            },
        };
    }
};

/// Cardinal zoom direction for keyboard zooming.
pub const ZoomDirection = enum(u1) {
    in = 0,
    out = 1,
};

/// 2-bit zoom direction bitmask for zero-allocation state tracking.
pub const ZoomFlags = packed struct(u2) {
    in: bool = false,
    out: bool = false,

    /// Converts zoom flags into backing raw integer.
    pub inline fn raw(self: ZoomFlags) u2 {
        return @backingInt(self);
    }

    /// Reconstructs zoom flags from backing raw integer.
    pub inline fn fromRaw(val: u2) ZoomFlags {
        return @fromBackingInt(val);
    }

    /// Returns true if any zoom flag bit is set.
    pub inline fn hasAny(self: ZoomFlags) bool {
        return self.raw() != 0;
    }

    /// Merges two zoom flags bitmasks via bitwise OR.
    pub inline fn merge(self: ZoomFlags, other: ZoomFlags) ZoomFlags {
        return @fromBackingInt(self.raw() | other.raw());
    }
};

/// Active discrete zoom tap state operating in log-zoom space.
pub const ActiveZoomTap = struct {
    direction: ZoomDirection,
    remaining_log: f32,
    detent_target: ?f32 = null,
};

/// Mutually exclusive motion phase for keyboard zooming.
pub const ZoomPhase = union(enum) {
    idle,
    tap: ActiveZoomTap,
    detent_pause_ms: f32,
};

/// Dynamic state tracking for smooth keyboard viewport zooming.
pub const ZoomController = struct {
    phase: ZoomPhase = .idle,
    prev_held: ZoomFlags = .{},
    suppressed_held: ZoomFlags = .{},

    pub const TAP_STEP_RATIO: f32 = 1.25;
    pub const TAP_LOG_DISTANCE: f32 = 0.22314355; // @log(1.25)
    pub const TAP_EPSILON_LOG: f32 = 0.0001;
    pub const GLIDE_RATE: f32 = 1.5; // Log units/sec (~4.5x per sec on hold)
    pub const DETENT_PAUSE_MS: f32 = 150.0; // 150ms detent pause at 1.0x
    pub const DETENT_EPSILON_MS: f32 = 0.001;

    /// Clears active zoom tap, held motion, and detent pause state.
    pub inline fn clearMotion(self: *ZoomController) void {
        self.phase = .idle;
        self.prev_held = .{};
    }

    /// Resets all zoom controller state including suppressed directions.
    pub inline fn reset(self: *ZoomController) void {
        self.clearMotion();
        self.suppressed_held = .{};
    }

    /// Suppresses currently held zoom directions until released.
    pub inline fn suppress(self: *ZoomController, held: ZoomFlags) void {
        self.clearMotion();
        self.suppressed_held = held;
    }

    /// Returns true if zoom controller has an active phase or held input.
    pub inline fn isBusy(self: ZoomController) bool {
        return switch (self.phase) {
            .idle => false,
            .tap, .detent_pause_ms => true,
        } or self.prev_held.hasAny();
    }

    /// Triggers a discrete zoom step in the specified direction, latching a
    /// `1.0` detent snap target if the projected endpoint crosses `1.0`.
    pub fn triggerTap(
        self: *ZoomController,
        dir: ZoomDirection,
        current_zoom: f32,
    ) void {
        const factor: f32 = switch (dir) {
            .in => TAP_STEP_RATIO,
            .out => 1.0 / TAP_STEP_RATIO,
        };
        const proj_eps: f32 = 1e-5;
        const projected = current_zoom * factor;
        const detent_target: ?f32 = switch (dir) {
            .in => if (current_zoom < 1.0 and projected >= 1.0 - proj_eps)
                1.0
            else
                null,
            .out => if (current_zoom > 1.0 and projected <= 1.0 + proj_eps)
                1.0
            else
                null,
        };
        self.phase = .{
            .tap = .{
                .direction = dir,
                .remaining_log = TAP_LOG_DISTANCE,
                .detent_target = detent_target,
            },
        };
    }

    /// Immediately settles any active discrete zoom tap (or detent pause),
    /// returning the remaining multiplicative `ratio` and optional `snap_zoom`
    /// detent target and transitioning the controller to `.idle`.
    pub fn settleTap(
        self: *ZoomController,
    ) ?struct { ratio: f32, snap_zoom: ?f32 } {
        return switch (self.phase) {
            .idle => null,
            .detent_pause_ms => blk: {
                self.phase = .idle;
                break :blk null;
            },
            .tap => |tap| blk: {
                self.phase = .idle;
                if (!std.math.isFinite(tap.remaining_log) or
                    tap.remaining_log <= TAP_EPSILON_LOG)
                {
                    break :blk null;
                }
                const ratio: f32 = switch (tap.direction) {
                    .in => @exp(tap.remaining_log),
                    .out => @exp(-tap.remaining_log),
                };
                break :blk .{
                    .ratio = ratio,
                    .snap_zoom = tap.detent_target,
                };
            },
        };
    }
};

test "PanController and ZoomController settleTap complete motion in 1 step" {
    var pan = PanController{
        .tap = .{
            .active = .{
                .direction = .{ .left = true, .up = true },
                .remaining_px = 20.0,
            },
        },
    };
    const delta = pan.settleTap() orelse return error.TestUnexpectedNull;
    try std.testing.expect(!pan.isBusy());
    try std.testing.expectApproxEqAbs(
        @as(f32, 20.0 * 0.70710678),
        delta.dx,
        1e-4,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 20.0 * 0.70710678),
        delta.dy,
        1e-4,
    );
    try std.testing.expect(pan.settleTap() == null);

    var zoom = ZoomController{};
    zoom.triggerTap(.in, 0.9);
    const z_res = zoom.settleTap() orelse return error.TestUnexpectedNull;
    try std.testing.expect(!zoom.isBusy());
    try std.testing.expectApproxEqAbs(
        ZoomController.TAP_STEP_RATIO,
        z_res.ratio,
        1e-4,
    );
    try std.testing.expectEqual(@as(?f32, 1.0), z_res.snap_zoom);

    var vp = ViewportParams{ .zoom_factor = ZoomFactor.init(0.9) };
    vp.zoomBy(z_res.ratio, z_res.snap_zoom);
    try std.testing.expectEqual(ZoomMode.manual, vp.mode);
    try std.testing.expectEqual(@as(f32, 1.0), vp.zoom_factor.get());
}

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

test "ViewportParams isOverflowing and effectiveZoom" {
    var vp = ViewportParams{};
    // 1024x682 in 1024x768 with .fit (.full) mode does not overflow
    try std.testing.expect(!vp.isOverflowing(
        .{ .w = 1024.0, .h = 682.0 },
        .{ .w = 1024.0, .h = 768.0 },
    ));

    // .fit_width on a tall portrait image (800x1600 in 1000x800) overflows Y
    vp.fit_mode = .fit_width;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.25),
        vp.effectiveZoom(
            .{ .w = 1000.0, .h = 800.0 },
            .{ .w = 800.0, .h = 1600.0 },
        ),
        0.0001,
    );
    try std.testing.expect(vp.isOverflowing(
        .{ .w = 800.0, .h = 1600.0 },
        .{ .w = 1000.0, .h = 800.0 },
    ));

    // .fit_height on a wide landscape image (1600x800 in 1000x800) overflows X
    vp.fit_mode = .fit_height;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        vp.effectiveZoom(
            .{ .w = 1000.0, .h = 800.0 },
            .{ .w = 1600.0, .h = 800.0 },
        ),
        0.0001,
    );
    try std.testing.expect(vp.isOverflowing(
        .{ .w = 1600.0, .h = 800.0 },
        .{ .w = 1000.0, .h = 800.0 },
    ));

    // .shrink on a small image (400x300 in 1000x800) keeps 1.0x and does not
    // overflow
    vp.fit_mode = .shrink;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        vp.effectiveZoom(
            .{ .w = 1000.0, .h = 800.0 },
            .{ .w = 400.0, .h = 300.0 },
        ),
        0.0001,
    );
    try std.testing.expect(!vp.isOverflowing(
        .{ .w = 400.0, .h = 300.0 },
        .{ .w = 1000.0, .h = 800.0 },
    ));

    // Rotated 90 degrees in .fit_width (1600x800 -> 800x1600 in 1000x800)
    vp.fit_mode = .fit_width;
    vp.rotation_angle = 90.0;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.25),
        vp.effectiveZoom(
            .{ .w = 1000.0, .h = 800.0 },
            .{ .w = 1600.0, .h = 800.0 },
        ),
        0.0001,
    );
    try std.testing.expect(vp.isOverflowing(
        .{ .w = 1600.0, .h = 800.0 },
        .{ .w = 1000.0, .h = 800.0 },
    ));
    vp.rotation_angle = 0.0;

    // .fill mode (crop) causes overflow
    vp.fit_mode = .crop;
    vp.mode = .fill;
    try std.testing.expect(vp.isOverflowing(
        .{ .w = 1024.0, .h = 682.0 },
        .{ .w = 1024.0, .h = 768.0 },
    ));

    // .manual mode at 2.0x causes overflow
    vp.mode = .manual;
    vp.zoom_factor = ZoomFactor.init(2.0);
    try std.testing.expect(vp.isOverflowing(
        .{ .w = 1024.0, .h = 682.0 },
        .{ .w = 1024.0, .h = 768.0 },
    ));

    // .manual mode at 0.5x fits inside
    vp.zoom_factor = ZoomFactor.init(0.5);
    try std.testing.expect(!vp.isOverflowing(
        .{ .w = 1024.0, .h = 682.0 },
        .{ .w = 1024.0, .h = 768.0 },
    ));
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

test "PanController lifecycle: isBusy, clearMotion, suppress, and reset" {
    var ctrl: PanController = .{};
    try std.testing.expect(!ctrl.isBusy());

    ctrl.tap = .{
        .active = .{
            .direction = .{ .right = true },
            .remaining_px = 12.0,
        },
    };
    try std.testing.expect(ctrl.isBusy());

    ctrl.clearMotion();
    try std.testing.expectEqual(PanTap.idle, ctrl.tap);
    try std.testing.expect(!ctrl.isBusy());

    ctrl.prev_held = .{ .up = true };
    try std.testing.expect(ctrl.isBusy());

    ctrl.suppress(.{
        .up = true,
        .left = true,
    });
    try std.testing.expect(!ctrl.isBusy());
    try std.testing.expect(ctrl.suppressed_held.up);
    try std.testing.expect(ctrl.suppressed_held.left);

    ctrl.reset();
    try std.testing.expect(!ctrl.isBusy());
    try std.testing.expect(!ctrl.suppressed_held.hasAny());
}

test "ZoomController triggerTap detent latching, isBusy, and suppress" {
    var ctrl: ZoomController = .{};
    try std.testing.expect(!ctrl.isBusy());

    // 0.85 * 1.25 = 1.0625 >= 1.0 -> latches 1.0 detent
    ctrl.triggerTap(.in, 0.85);
    try std.testing.expect(ctrl.isBusy());
    switch (ctrl.phase) {
        .tap => |t| {
            try std.testing.expectEqual(ZoomDirection.in, t.direction);
            try std.testing.expectEqual(@as(?f32, 1.0), t.detent_target);
        },
        .idle, .detent_pause_ms => return error.TestUnexpectedResult,
    }

    // 0.5 * 1.25 = 0.625 < 1.0 -> no detent
    ctrl.triggerTap(.in, 0.5);
    switch (ctrl.phase) {
        .tap => |t| {
            try std.testing.expectEqual(@as(?f32, null), t.detent_target);
        },
        .idle, .detent_pause_ms => return error.TestUnexpectedResult,
    }

    // 1.1 / 1.25 = 0.88 <= 1.0 -> latches 1.0 detent
    ctrl.triggerTap(.out, 1.1);
    switch (ctrl.phase) {
        .tap => |t| {
            try std.testing.expectEqual(ZoomDirection.out, t.direction);
            try std.testing.expectEqual(@as(?f32, 1.0), t.detent_target);
        },
        .idle, .detent_pause_ms => return error.TestUnexpectedResult,
    }

    // 2.0 / 1.25 = 1.6 > 1.0 -> no detent
    ctrl.triggerTap(.out, 2.0);
    switch (ctrl.phase) {
        .tap => |t| {
            try std.testing.expectEqual(@as(?f32, null), t.detent_target);
        },
        .idle, .detent_pause_ms => return error.TestUnexpectedResult,
    }

    // Detent pause reports busy until suppressed or cleared
    ctrl.phase = .{ .detent_pause_ms = 50.0 };
    try std.testing.expect(ctrl.isBusy());
    ctrl.suppress(.{ .in = true });
    try std.testing.expectEqual(ZoomPhase.idle, ctrl.phase);
    try std.testing.expect(!ctrl.isBusy());
    try std.testing.expect(ctrl.suppressed_held.in);

    ctrl.prev_held = .{ .out = true };
    try std.testing.expect(ctrl.isBusy());
    ctrl.reset();
    try std.testing.expect(!ctrl.isBusy());
    try std.testing.expect(!ctrl.suppressed_held.hasAny());
}
