//! Declarative Snackbar Notification System
//!
//! Provides a declarative registry of snackbar notification rules,
//! formatting functions, and a zero-heap-allocation fixed buffer state
//! container for visual user confirmations.

const intents = @import("intents");
const std = @import("std");
const triage = @import("triage");
const viewport = @import("viewport.zig");

const AppIntent = intents.AppIntent;
const Classification = triage.Classification;
const EditParam = intents.EditParam;
const ViewMode = triage.ViewMode;
const ViewportParams = viewport.ViewportParams;

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
    compare = 9,
    /// Synthetic trigger used for integration tests and visual overlay verification
    testing = 10,
    classification = 11,
    view_mode = 12,
    adjust = 13,
};

pub const TRIGGER_COUNT: usize =
    @typeInfo(SnackbarTrigger).@"enum".field_names.len;

/// Read-only snapshot of viewport and navigation state passed to formatters.
pub const SnackbarContext = struct {
    viewport: *const ViewportParams,
    manga_mode: bool = false,
    crossfade: bool = true,
    snackbar_enabled: bool = true,
    classification: Classification = .unflagged,
    classification_advanced: bool = false,
    has_target_image: bool = true,
    view_mode: ViewMode = .default,
    last_param: ?EditParam = null,
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
        .fsr => "AMD FSR 1.0 (EASU + RCAS)",
        .tiny_cnn => "Tiny CNN (Neural SR)",
    };
    return std.mem.print(buf, "Filter: {s}", .{filter_name}) catch filter_name;
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
    return std.mem.print(buf, "Scale: {s}", .{mode_name}) catch mode_name;
}

fn formatBrightness(ctx: SnackbarContext, buf: []u8) []const u8 {
    const b = ctx.viewport.edits.get(.brightness);
    const b_pct: i32 = @intFromFloat(@round(b * 100.0));
    if (b_pct > 0) {
        return std.mem.print(
            buf,
            "Brightness: +{d}%",
            .{b_pct},
        ) catch "Brightness";
    } else {
        return std.mem.print(
            buf,
            "Brightness: {d}%",
            .{b_pct},
        ) catch "Brightness";
    }
}

fn formatContrast(ctx: SnackbarContext, buf: []u8) []const u8 {
    const c = ctx.viewport.edits.get(.contrast);
    return std.mem.print(buf, "Contrast: {d:.2}x", .{c}) catch "Contrast";
}

fn formatAdjustParam(ctx: SnackbarContext, buf: []u8) []const u8 {
    const param = ctx.last_param orelse return "";
    const spec = intents.getSpec(param);
    const val = ctx.viewport.edits.get(param);
    return switch (spec.display_kind) {
        .percent => {
            const pct: i32 = @intFromFloat(@round(val * 100.0));
            if (pct > 0) {
                return std.mem.print(
                    buf,
                    "{s}: +{d}%",
                    .{ spec.label, pct },
                ) catch spec.label;
            } else {
                return std.mem.print(
                    buf,
                    "{s}: {d}%",
                    .{ spec.label, pct },
                ) catch spec.label;
            }
        },
        .multiplier => {
            return std.mem.print(
                buf,
                "{s}: {d:.2}x",
                .{ spec.label, val },
            ) catch spec.label;
        },
        .ratio_percent => {
            const pct: i32 = @intFromFloat(@round(val * 100.0));
            return std.mem.print(
                buf,
                "{s}: {d}%",
                .{ spec.label, pct },
            ) catch spec.label;
        },
        .temperature => {
            const deg: i32 = @intFromFloat(@round(val * 2000.0));
            if (deg > 0) {
                return std.mem.print(
                    buf,
                    "{s}: +{d}K",
                    .{ spec.label, deg },
                ) catch spec.label;
            } else {
                return std.mem.print(
                    buf,
                    "{s}: {d}K",
                    .{ spec.label, deg },
                ) catch spec.label;
            }
        },
        .tint => {
            const pct: i32 = @intFromFloat(@round(val * 100.0));
            if (pct > 0) {
                return std.mem.print(
                    buf,
                    "{s}: +{d} (Magenta)",
                    .{ spec.label, pct },
                ) catch spec.label;
            } else if (pct < 0) {
                return std.mem.print(
                    buf,
                    "{s}: {d} (Green)",
                    .{ spec.label, pct },
                ) catch spec.label;
            } else {
                return std.mem.print(
                    buf,
                    "{s}: 0",
                    .{spec.label},
                ) catch spec.label;
            }
        },
    };
}

fn formatResetAdjustments(_: SnackbarContext, _: []u8) []const u8 {
    return "Adjustments: Reset";
}

fn formatZoom(ctx: SnackbarContext, buf: []u8) []const u8 {
    const z_pct: u32 = @intFromFloat(@round(ctx.viewport.zoom_factor.get() * 100.0));
    return std.mem.print(buf, "Zoom: {d}%", .{z_pct}) catch "Zoom";
}

fn formatRotation(ctx: SnackbarContext, buf: []u8) []const u8 {
    const deg: i32 = @intFromFloat(@round(ctx.viewport.rotation_angle));
    return std.mem.print(
        buf,
        "Rotation: {d}°",
        .{@mod(deg, 360)},
    ) catch "Rotation";
}

fn formatMangaMode(ctx: SnackbarContext, _: []u8) []const u8 {
    return if (ctx.manga_mode) "Manga Mode: ON (RTL)" else "Manga Mode: OFF";
}

fn formatCrossfade(ctx: SnackbarContext, _: []u8) []const u8 {
    return if (ctx.crossfade) "Crossfade: ON" else "Crossfade: OFF";
}

fn formatCompare(ctx: SnackbarContext, _: []u8) []const u8 {
    if (!ctx.viewport.hasAdjustments()) {
        return "Before / After: No Adjustments";
    }
    return if (ctx.viewport.compare_original) "Before (Original)" else "After (Adjusted)";
}

fn formatTesting(ctx: SnackbarContext, _: []u8) []const u8 {
    return if (ctx.snackbar_enabled) "Test Notification" else "";
}

fn formatClassification(ctx: SnackbarContext, _: []u8) []const u8 {
    if (!ctx.has_target_image) {
        return "No image to classify";
    }
    if (ctx.classification_advanced) {
        return switch (ctx.classification) {
            .reject => "Previous image flagged as rejected",
            .pick => "Previous image flagged as picked",
            .unflagged => "Previous image unflagged",
        };
    }
    return switch (ctx.classification) {
        .pick => "Flagged as Pick",
        .reject => "Flagged as Reject",
        .unflagged => "Unflagged",
    };
}

fn formatViewMode(ctx: SnackbarContext, buf: []u8) []const u8 {
    const lbl = ctx.view_mode.label();
    return std.mem.print(buf, "Filter: {s}", .{lbl}) catch lbl;
}

/// Master declarative table of snackbar notification rules.
pub const DEFAULT_SNACKBAR_RULES = [_]SnackbarRule{
    .{
        .trigger = .filter,
        .label = "Filter",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .set_filter, .cycle_filter, .cycle_filter_prev },
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
        .intents = &.{},
        .format_fn = formatBrightness,
    },
    .{
        .trigger = .contrast,
        .label = "Contrast",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{},
        .format_fn = formatContrast,
    },
    .{
        .trigger = .reset_adjustments,
        .label = "Reset Adjustments",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{},
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
    .{
        .trigger = .compare,
        .label = "Compare Adjustments",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{},
        .format_fn = formatCompare,
    },
    .{
        .trigger = .testing,
        .label = "Testing",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .toggle_snackbar, .set_snackbar },
        .format_fn = formatTesting,
    },
    .{
        .trigger = .classification,
        .label = "Classification",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .mark_pick, .mark_reject, .unflag },
        .format_fn = formatClassification,
    },
    .{
        .trigger = .view_mode,
        .label = "View Filter",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{ .cycle_view_mode, .set_view_mode },
        .format_fn = formatViewMode,
    },
    .{
        .trigger = .adjust,
        .label = "Photo Adjustments",
        .enabled = true,
        .duration_ms = 1800,
        .intents = &.{},
        .format_fn = formatAdjustParam,
    },
};

/// Looks up the matching declarative snackbar rule for an executed intent.
pub fn findRule(intent: AppIntent) ?SnackbarRule {
    switch (intent) {
        .adjust => |adj| switch (adj) {
            .toggle_compare, .set_compare => return SnackbarRule{
                .trigger = .compare,
                .label = "Compare Adjustments",
                .enabled = true,
                .duration_ms = 1800,
                .intents = &.{},
                .format_fn = formatCompare,
            },
            .reset_all => return SnackbarRule{
                .trigger = .reset_adjustments,
                .label = "Reset Adjustments",
                .enabled = true,
                .duration_ms = 1800,
                .intents = &.{},
                .format_fn = formatResetAdjustments,
            },
            .step => |s| {
                const trigger: SnackbarTrigger = switch (s.param) {
                    .brightness => .brightness,
                    .contrast => .contrast,
                    else => .adjust,
                };
                return SnackbarRule{
                    .trigger = trigger,
                    .label = "Photo Adjustments",
                    .enabled = true,
                    .duration_ms = 1800,
                    .intents = &.{},
                    .format_fn = formatAdjustParam,
                };
            },
            .set => |s| {
                const trigger: SnackbarTrigger = switch (s.param) {
                    .brightness => .brightness,
                    .contrast => .contrast,
                    else => .adjust,
                };
                return SnackbarRule{
                    .trigger = trigger,
                    .label = "Photo Adjustments",
                    .enabled = true,
                    .duration_ms = 1800,
                    .intents = &.{},
                    .format_fn = formatAdjustParam,
                };
            },
            .reset_param => |p| {
                const trigger: SnackbarTrigger = switch (p) {
                    .brightness => .brightness,
                    .contrast => .contrast,
                    else => .adjust,
                };
                return SnackbarRule{
                    .trigger = trigger,
                    .label = "Photo Adjustments",
                    .enabled = true,
                    .duration_ms = 1800,
                    .intents = &.{},
                    .format_fn = formatAdjustParam,
                };
            },
            .batch_tone, .batch_color, .batch_presence => return null,
        },
        else => {
            const intent_tag = std.meta.activeTag(intent);
            inline for (DEFAULT_SNACKBAR_RULES) |rule| {
                if (rule.enabled) {
                    for (rule.intents) |tag| {
                        if (tag == intent_tag) return rule;
                    }
                }
            }
            return null;
        },
    }
}

/// Notification payload stored in the active variant of `SnackbarNotification`.
pub const ActiveNotification = struct {
    message_buf: [MAX_SNACKBAR_LEN]u8 = @splat(0),
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

    /// Clears active message and resets notification to `.none`.
    pub fn clear(self: *SnackbarState) void {
        self.notification = .none;
    }

    /// Returns true if notifications for `trigger` are enabled in the bitmask.
    pub inline fn isTriggerEnabled(self: *const SnackbarState, trigger: SnackbarTrigger) bool {
        const bit = @as(u32, 1) << @intCast(@backingInt(trigger));
        return (self.enabled_mask & bit) != 0;
    }

    /// Sets or clears the enabled bit for `trigger`.
    pub fn setTriggerEnabled(self: *SnackbarState, trigger: SnackbarTrigger, enabled: bool) void {
        const bit = @as(u32, 1) << @intCast(@backingInt(trigger));
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

    vp.scale_filter = .fsr;
    const fsr_str = formatFilter(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Filter: AMD FSR 1.0 (EASU + RCAS)", fsr_str);

    vp.scale_filter = .tiny_cnn;
    const cnn_str = formatFilter(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Filter: Tiny CNN (Neural SR)", cnn_str);

    // Scale Mode
    vp.fit_mode = .crop;
    const scale_str = formatScaleMode(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Scale: Fill Window (Crop)", scale_str);

    // Brightness positive & negative
    vp.edits.set(.brightness, 0.2);
    const b_pos = formatBrightness(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Brightness: +20%", b_pos);

    vp.edits.set(.brightness, -0.1);
    const b_neg = formatBrightness(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Brightness: -10%", b_neg);

    // Contrast
    vp.edits.set(.contrast, 1.25);
    const c_str = formatContrast(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Contrast: 1.25x", c_str);

    // General parameter formatting
    vp.edits.set(.contrast_blend, 0.75);
    const blend_str = formatAdjustParam(
        .{ .viewport = &vp, .last_param = .contrast_blend },
        &buf,
    );
    try std.testing.expectEqualStrings("Contrast Blend: 75%", blend_str);

    vp.edits.set(.highlights, -0.3);
    const hl_str = formatAdjustParam(
        .{ .viewport = &vp, .last_param = .highlights },
        &buf,
    );
    try std.testing.expectEqualStrings("Highlights: -30%", hl_str);

    vp.edits.set(.temperature, 0.5);
    const temp_str = formatAdjustParam(
        .{ .viewport = &vp, .last_param = .temperature },
        &buf,
    );
    try std.testing.expectEqualStrings("Temperature: +1000K", temp_str);

    // Adjustments reset
    const reset_str = formatResetAdjustments(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Adjustments: Reset", reset_str);

    // Compare adjustments
    vp.edits.reset();
    const cmp_no_adj = formatCompare(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Before / After: No Adjustments", cmp_no_adj);
    vp.edits.set(.brightness, 0.3);
    vp.compare_original = true;
    const cmp_before = formatCompare(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("Before (Original)", cmp_before);
    vp.compare_original = false;
    const cmp_after = formatCompare(.{ .viewport = &vp }, &buf);
    try std.testing.expectEqualStrings("After (Adjusted)", cmp_after);
    vp.edits.reset();

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

    // Testing trigger
    const sb_on = formatTesting(.{ .viewport = &vp, .snackbar_enabled = true }, &buf);
    try std.testing.expectEqualStrings("Test Notification", sb_on);
    const sb_off = formatTesting(.{ .viewport = &vp, .snackbar_enabled = false }, &buf);
    try std.testing.expectEqualStrings("", sb_off);
}

test "findRule maps intents to declarative rules" {
    const filter_rule = findRule(.{ .set_filter = .lanczos3 });
    try std.testing.expect(filter_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.filter, filter_rule.?.trigger);

    const filter_prev_rule = findRule(.cycle_filter_prev);
    try std.testing.expect(filter_prev_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.filter, filter_prev_rule.?.trigger);

    const scale_rule = findRule(.cycle_scale_mode);
    try std.testing.expect(scale_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.scale_mode, scale_rule.?.trigger);

    const bright_rule = findRule(.{
        .adjust = .{
            .step = .{ .param = .brightness, .direction = .up },
        },
    });
    try std.testing.expect(bright_rule != null);
    try std.testing.expectEqual(
        SnackbarTrigger.brightness,
        bright_rule.?.trigger,
    );

    const hl_rule = findRule(.{
        .adjust = .{
            .step = .{ .param = .highlights, .direction = .up },
        },
    });
    try std.testing.expect(hl_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.adjust, hl_rule.?.trigger);

    const compare_rule = findRule(.{ .adjust = .toggle_compare });
    try std.testing.expect(compare_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.compare, compare_rule.?.trigger);

    const compare_set_rule = findRule(.{ .adjust = .{ .set_compare = true } });
    try std.testing.expect(compare_set_rule != null);
    try std.testing.expectEqual(
        SnackbarTrigger.compare,
        compare_set_rule.?.trigger,
    );

    const reset_rule = findRule(.{ .adjust = .reset_all });
    try std.testing.expect(reset_rule != null);
    try std.testing.expectEqual(
        SnackbarTrigger.reset_adjustments,
        reset_rule.?.trigger,
    );

    const crossfade_rule = findRule(.toggle_crossfade);
    try std.testing.expect(crossfade_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.crossfade, crossfade_rule.?.trigger);

    const testing_rule = findRule(.{ .set_snackbar = true });
    try std.testing.expect(testing_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.testing, testing_rule.?.trigger);

    const pick_rule = findRule(.mark_pick);
    try std.testing.expect(pick_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.classification, pick_rule.?.trigger);

    const view_rule = findRule(.cycle_view_mode);
    try std.testing.expect(view_rule != null);
    try std.testing.expectEqual(SnackbarTrigger.view_mode, view_rule.?.trigger);

    const unmapped_rule = findRule(.next_image);
    try std.testing.expect(unmapped_rule == null);
}

test "SnackbarState buffer operations and bitmask" {
    var state = SnackbarState{};
    try std.testing.expectEqual(@as(usize, 0), state.getMessage().len);
    try std.testing.expect(state.notification == .none);
    try std.testing.expect(state.isTriggerEnabled(.filter));

    state.show("Test Notification", 5000);
    try std.testing.expectEqualStrings("Test Notification", state.getMessage());
    try std.testing.expectEqual(@as(u64, 5000), state.getTimeoutMs());
    try std.testing.expect(state.notification == .active);

    state.setTriggerEnabled(.filter, false);
    try std.testing.expect(!state.isTriggerEnabled(.filter));
    try std.testing.expect(state.isTriggerEnabled(.scale_mode));

    state.clear();
    try std.testing.expectEqual(@as(usize, 0), state.getMessage().len);
    try std.testing.expectEqual(@as(u64, 0), state.getTimeoutMs());
    try std.testing.expect(state.notification == .none);
}

test "formatClassification without and with advance" {
    var vp = ViewportParams{};
    var buf: [64]u8 = undefined;

    // Normal (non-advancing) formatting
    try std.testing.expectEqualStrings("Flagged as Pick", formatClassification(.{
        .viewport = &vp,
        .classification = .pick,
        .classification_advanced = false,
    }, &buf));
    try std.testing.expectEqualStrings("Flagged as Reject", formatClassification(.{
        .viewport = &vp,
        .classification = .reject,
        .classification_advanced = false,
    }, &buf));
    try std.testing.expectEqualStrings("Unflagged", formatClassification(.{
        .viewport = &vp,
        .classification = .unflagged,
        .classification_advanced = false,
    }, &buf));

    // Advancing (filtered out) formatting
    try std.testing.expectEqualStrings("Previous image flagged as picked", formatClassification(.{
        .viewport = &vp,
        .classification = .pick,
        .classification_advanced = true,
    }, &buf));
    try std.testing.expectEqualStrings("Previous image flagged as rejected", formatClassification(.{
        .viewport = &vp,
        .classification = .reject,
        .classification_advanced = true,
    }, &buf));
    try std.testing.expectEqualStrings("Previous image unflagged", formatClassification(.{
        .viewport = &vp,
        .classification = .unflagged,
        .classification_advanced = true,
    }, &buf));

    // Empty filter / no image selected
    try std.testing.expectEqualStrings("No image to classify", formatClassification(.{
        .viewport = &vp,
        .classification = .pick,
        .has_target_image = false,
    }, &buf));
    try std.testing.expectEqualStrings("No image to classify", formatClassification(.{
        .viewport = &vp,
        .classification = .reject,
        .has_target_image = false,
    }, &buf));
}
