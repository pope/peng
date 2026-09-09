//! Declarative Snackbar Notification System
//!
//! Provides a declarative registry of snackbar notification rules, formatting functions,
//! and a zero-heap-allocation fixed buffer state container for visual user confirmations.

const intents = @import("intents");
const std = @import("std");
const types = @import("types.zig");

const AppIntent = intents.AppIntent;
const ScaleMode = intents.ScaleMode;
const TextureScaleMode = intents.TextureScaleMode;
const ViewportParams = types.ViewportParams;

/// Maximum length of a snackbar notification message in bytes.
pub const MAX_SNACKBAR_LEN: usize = 64;

/// Category of action or function triggering a snackbar notification.
pub const SnackbarTrigger = enum(u8) {
    filter = 0,
    scale_mode = 1,
    brightness = 2,
    contrast = 3,
    reset_adjustments = 4,
    zoom = 5,
    rotation = 6,
    manga_mode = 7,
    crossfade = 8,
};

pub const TRIGGER_COUNT: usize = @typeInfo(SnackbarTrigger).@"enum".fields.len;

/// Read-only snapshot of viewport and navigation state passed to formatters.
pub const SnackbarContext = struct {
    viewport: *const ViewportParams,
    manga_mode: bool = false,
    crossfade: bool = true,
};

/// Signature for declarative notification message formatters.
pub const FormatFn = *const fn (ctx: SnackbarContext, buf: []u8) []const u8;

/// Declarative schema defining what actions trigger a snack bar and how their message is formatted.
pub const SnackbarRule = struct {
    trigger: SnackbarTrigger,
    label: []const u8,
    enabled: bool = true,
    duration_ms: u32 = 1800,
    intents: []const std.meta.Tag(AppIntent),
    format_fn: FormatFn,
};

fn formatFilter(ctx: SnackbarContext, buf: []u8) []const u8 {
    const filter_name = switch (ctx.viewport.scale_filter) {
        .nearest => "Nearest Neighbor",
        .linear => "Bilinear",
        .pixel_art => "Pixel Art",
        .mitchell => "Mitchell-Netravali",
        .lanczos3 => "Lanczos3",
        .lanczos3_spline => "Lanczos3 Spline",
    };
    return std.fmt.bufPrint(buf, "Filter: {s}", .{filter_name}) catch filter_name;
}

fn formatScaleMode(ctx: SnackbarContext, buf: []u8) []const u8 {
    const mode_name = switch (ctx.viewport.fit_mode) {
        .shrink => "Fit if Larger",
        .full => "Fit Window",
        .crop => "Fill Window (Crop)",
        .none => "Original (1:1)",
        .fit_width => "Fit Width",
        .fit_height => "Fit Height",
    };
    return std.fmt.bufPrint(buf, "Scale: {s}", .{mode_name}) catch mode_name;
}

fn formatBrightness(ctx: SnackbarContext, buf: []u8) []const u8 {
    const b = ctx.viewport.brightness;
    const b_pct: i32 = @intFromFloat(@round(b * 100.0));
    if (b_pct > 0) {
        return std.fmt.bufPrint(buf, "Brightness: +{d}%", .{b_pct}) catch "Brightness";
    } else {
        return std.fmt.bufPrint(buf, "Brightness: {d}%", .{b_pct}) catch "Brightness";
    }
}

fn formatContrast(ctx: SnackbarContext, buf: []u8) []const u8 {
    const c = ctx.viewport.contrast;
    return std.fmt.bufPrint(buf, "Contrast: {d:.2}x", .{c}) catch "Contrast";
}

fn formatResetAdjustments(_: SnackbarContext, _: []u8) []const u8 {
    return "Adjustments: Reset";
}

fn formatZoom(ctx: SnackbarContext, buf: []u8) []const u8 {
    const z_pct: u32 = @intFromFloat(@round(ctx.viewport.zoom_factor.get() * 100.0));
    return std.fmt.bufPrint(buf, "Zoom: {d}%", .{z_pct}) catch "Zoom";
}

fn formatRotation(ctx: SnackbarContext, buf: []u8) []const u8 {
    const deg: i32 = @intFromFloat(@round(ctx.viewport.rotation_angle));
    return std.fmt.bufPrint(buf, "Rotation: {d}°", .{@mod(deg, 360)}) catch "Rotation";
}

fn formatMangaMode(ctx: SnackbarContext, _: []u8) []const u8 {
    return if (ctx.manga_mode) "Manga Mode: ON (RTL)" else "Manga Mode: OFF";
}

fn formatCrossfade(ctx: SnackbarContext, _: []u8) []const u8 {
    return if (ctx.crossfade) "Crossfade: ON" else "Crossfade: OFF";
}

/// Master declarative table of snackbar notification rules.
pub const DEFAULT_SNACKBAR_RULES = [_]SnackbarRule{
    .{
        .trigger = .filter,
        .label = "Filter",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .set_filter, .cycle_filter },
        .format_fn = formatFilter,
    },
    .{
        .trigger = .scale_mode,
        .label = "Scale Mode",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .set_scale, .cycle_scale_mode },
        .format_fn = formatScaleMode,
    },
    .{
        .trigger = .brightness,
        .label = "Brightness",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .set_brightness, .increase_brightness, .decrease_brightness },
        .format_fn = formatBrightness,
    },
    .{
        .trigger = .contrast,
        .label = "Contrast",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .set_contrast, .increase_contrast, .decrease_contrast },
        .format_fn = formatContrast,
    },
    .{
        .trigger = .reset_adjustments,
        .label = "Reset Adjustments",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{.reset_adjustments},
        .format_fn = formatResetAdjustments,
    },
    .{
        .trigger = .zoom,
        .label = "Zoom",
        .enabled = true,
        .duration_ms = 1500,
        .intents = &.{ .set_zoom, .zoom_in, .zoom_out, .reset_zoom },
        .format_fn = formatZoom,
    },
    .{
        .trigger = .rotation,
        .label = "Rotation",
        .enabled = true,
        .duration_ms = 1500,
        .intents = &.{ .rotate_cw, .rotate_ccw, .reset_rotation },
        .format_fn = formatRotation,
    },
    .{
        .trigger = .manga_mode,
        .label = "Manga Mode",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .toggle_manga_mode, .set_manga_mode },
        .format_fn = formatMangaMode,
    },
    .{
        .trigger = .crossfade,
        .label = "Crossfade",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .toggle_crossfade, .set_crossfade },
        .format_fn = formatCrossfade,
    },
};

/// Looks up the matching declarative snackbar rule for an executed intent.
pub fn findRule(intent: AppIntent) ?SnackbarRule {
    const intent_tag = std.meta.activeTag(intent);
    inline for (DEFAULT_SNACKBAR_RULES) |rule| {
        if (rule.enabled) {
            for (rule.intents) |tag| {
                if (tag == intent_tag) return rule;
            }
        }
    }
    return null;
}

/// Notification payload stored in the active variant of `SnackbarNotification`.
pub const ActiveNotification = struct {
    message_buf: [MAX_SNACKBAR_LEN]u8 = [_]u8{0} ** MAX_SNACKBAR_LEN,
    message_len: u8 = 0,
    timeout_ms: u64 = 0,
};

/// Tagged union representing either no active notification or an in-flight
/// visual confirmation message.
pub const SnackbarNotification = union(enum) {
    none,
    active: ActiveNotification,
};

/// Zero-heap-allocation snackbar state container managing message buffers, auto-hide deadlines,
/// and per-trigger bitmasks.
pub const SnackbarState = struct {
    enabled: bool = true,
    notification: SnackbarNotification = .none,
    enabled_mask: u32 = 0xFFFF_FFFF,

    /// Copies message string into static buffer with bounds safety and resets timeout to 0.
    pub fn setMessage(self: *SnackbarState, text: []const u8) void {
        var active = ActiveNotification{};
        const copy_len = @min(text.len, MAX_SNACKBAR_LEN);
        @memcpy(active.message_buf[0..copy_len], text[0..copy_len]);
        active.message_len = @intCast(copy_len);
        self.notification = .{ .active = active };
    }

    /// Sets both message text and auto-hide deadline in a single call.
    pub fn show(self: *SnackbarState, text: []const u8, timeout_ms: u64) void {
        var active = ActiveNotification{ .timeout_ms = timeout_ms };
        const copy_len = @min(text.len, MAX_SNACKBAR_LEN);
        @memcpy(active.message_buf[0..copy_len], text[0..copy_len]);
        active.message_len = @intCast(copy_len);
        self.notification = .{ .active = active };
    }

    /// Returns the active message slice, or empty slice if none active.
    pub fn getMessage(self: *const SnackbarState) []const u8 {
        return switch (self.notification) {
            .none => "",
            .active => |*a| a.message_buf[0..a.message_len],
        };
    }

    /// Returns the active auto-hide deadline timestamp, or 0 if none active.
    pub fn getTimeoutMs(self: *const SnackbarState) u64 {
        return switch (self.notification) {
            .none => 0,
            .active => |a| a.timeout_ms,
        };
    }

    /// Sets the timeout deadline on an active notification.
    pub fn setTimeoutMs(self: *SnackbarState, timeout_ms: u64) void {
        switch (self.notification) {
            .none => {},
            .active => |*a| a.timeout_ms = timeout_ms,
        }
    }

    /// Clears active message and resets notification to `.none`.
    pub fn clear(self: *SnackbarState) void {
        self.notification = .none;
    }

    /// Returns true if notifications for `trigger` are enabled in the bitmask.
    pub inline fn isTriggerEnabled(self: *const SnackbarState, trigger: SnackbarTrigger) bool {
        const bit = @as(u32, 1) << @intCast(@intFromEnum(trigger));
        return (self.enabled_mask & bit) != 0;
    }

    /// Sets or clears the enabled bit for `trigger`.
    pub fn setTriggerEnabled(self: *SnackbarState, trigger: SnackbarTrigger, enabled: bool) void {
        const bit = @as(u32, 1) << @intCast(@intFromEnum(trigger));
        if (enabled) {
            self.enabled_mask |= bit;
        } else {
            self.enabled_mask &= ~bit;
        }
    }
};

test "Snackbar formatters produce expected text" {
    var vp = ViewportParams{};
    var buf: [MAX_SNACKBAR_LEN]u8 = undefined;

    // Filter
    vp.scale_filter = .mitchell;
    const filter_str = formatFilter(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Filter: Mitchell-Netravali", filter_str);

    // Scale Mode
    vp.fit_mode = .crop;
    const scale_str = formatScaleMode(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Scale: Fill Window (Crop)", scale_str);

    // Brightness positive & negative
    vp.brightness = 0.2;
    const b_pos = formatBrightness(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Brightness: +20%", b_pos);

    vp.brightness = -0.1;
    const b_neg = formatBrightness(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Brightness: -10%", b_neg);

    // Contrast
    vp.contrast = 1.25;
    const c_str = formatContrast(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Contrast: 1.25x", c_str);

    // Adjustments reset
    const reset_str = formatResetAdjustments(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Adjustments: Reset", reset_str);

    // Rotation
    vp.rotation_angle = 90.0;
    const rot_str = formatRotation(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Rotation: 90°", rot_str);

    // Manga Mode
    const manga_on = formatMangaMode(.{ .viewport = &vp, .manga_mode = true }, &buf);
    try std.testing.expectEqualStrings("Manga Mode: ON (RTL)", manga_on);
    const manga_off = formatMangaMode(.{ .viewport = &vp, .manga_mode = false }, &buf);
    try std.testing.expectEqualStrings("Manga Mode: OFF", manga_off);

    // Crossfade
    const cf_on = formatCrossfade(.{ .viewport = &vp, .crossfade = true }, &buf);
    try std.testing.expectEqualStrings("Crossfade: ON", cf_on);
    const cf_off = formatCrossfade(.{ .viewport = &vp, .crossfade = false }, &buf);
    try std.testing.expectEqualStrings("Crossfade: OFF", cf_off);
}

test "findRule maps intents to declarative rules" {
    const filter_rule = findRule(.{ .set_filter = .lanczos3 });
    try std.testing.expect(filter_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.filter, filter_rule.?.trigger);

    const scale_rule = findRule(.cycle_scale_mode);
    try std.testing.expect(scale_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.scale_mode, scale_rule.?.trigger);

    const bright_rule = findRule(.increase_brightness);
    try std.testing.expect(bright_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.brightness, bright_rule.?.trigger);

    const crossfade_rule = findRule(.toggle_crossfade);
    try std.testing.expect(crossfade_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.crossfade, crossfade_rule.?.trigger);

    const unmapped_rule = findRule(.next_image);
    try std.testing.expect(unmapped_rule == null);
}

test "SnackbarState buffer operations and bitmask" {
    var state = SnackbarState{};
    try std.testing.expectEqual(@as(usize, 0), state.getMessage().len);
    try std.testing.expect(state.notification == .none);
    try std.testing.expect(state.isTriggerEnabled(.filter));

    state.setMessage("Test Notification");
    try std.testing.expectEqualStrings("Test Notification", state.getMessage());
    try std.testing.expect(state.notification == .active);

    state.setTimeoutMs(5000);
    try std.testing.expectEqual(@as(u64, 5000), state.getTimeoutMs());

    state.setTriggerEnabled(.filter, false);
    try std.testing.expect(!state.isTriggerEnabled(.filter));
    try std.testing.expect(state.isTriggerEnabled(.scale_mode));

    state.clear();
    try std.testing.expectEqual(@as(usize, 0), state.getMessage().len);
    try std.testing.expectEqual(@as(u64, 0), state.getTimeoutMs());
    try std.testing.expect(state.notification == .none);
}
