const clay = @import("zclay");
const state = @import("state");
const std = @import("std");
const theme = @import("theme.zig");

const EditParam = state.EditParam;
const MeasureTextUserData = state.MeasureTextUserData;
const UiViewModel = state.UiViewModel;

/// Scales a theme color by the animation progress alpha for smooth
/// fade-in/fade-out.
inline fn a(color: clay.Color, progress: f32) clay.Color {
    return theme.withAlpha(color, progress);
}

pub const PANEL_WIDTH: f32 = state.EDIT_PANEL_WIDTH;
pub const PANEL_PADDING: f32 = state.EDIT_PANEL_PADDING;
pub const CONTENT_WIDTH: f32 = PANEL_WIDTH - (PANEL_PADDING * 2.0);

/// Formats brightness float value into a signed integer percentage string.
pub fn formatBrightness(allocator: std.mem.Allocator, val: f32) ![]const u8 {
    if (std.math.isNan(val) or std.math.isInf(val)) {
        return "0%";
    }
    const pct = @as(i32, @intFromFloat(@round(val * 100.0)));
    if (pct > 0) {
        return try std.fmt.allocPrint(allocator, "+{d}%", .{pct});
    } else if (pct < 0) {
        return try std.fmt.allocPrint(allocator, "{d}%", .{pct});
    } else {
        return "0%";
    }
}

/// Formats contrast float value into a decimal multiplier string.
pub fn formatContrast(allocator: std.mem.Allocator, val: f32) ![]const u8 {
    if (std.math.isNan(val) or std.math.isInf(val)) {
        return "1.00x";
    }
    if (@abs(val - 1.0) < 1e-4) {
        return "1.00x";
    }
    return try std.fmt.allocPrint(allocator, "{d:.2}x", .{val});
}

/// Renders an interactive slider row with parameter title, value readout,
/// background groove, relative fill bar, landmark notch, and thumb knob.
pub fn renderSlider(
    param: EditParam,
    label: []const u8,
    current_val: f32,
    min_val: f32,
    max_val: f32,
    neutral_val: f32,
    formatted_value: []const u8,
    progress: f32,
    is_active: bool,
) void {
    const track_id_str = switch (param) {
        .brightness => "SliderTrack_Brightness",
        .contrast => "SliderTrack_Contrast",
    };
    const reset_id_str = switch (param) {
        .brightness => "SliderReset_Brightness",
        .contrast => "SliderReset_Contrast",
    };
    const track_id = clay.getElementId(track_id_str);
    const is_hovered = clay.pointerOver(track_id);
    const is_modified = @abs(current_val - neutral_val) > 1e-4;

    const span = max_val - min_val;
    const is_non_finite =
        std.math.isNan(current_val) or std.math.isInf(current_val);
    const safe_val = if (is_non_finite) neutral_val else current_val;
    const t = if (span > 0.0)
        std.math.clamp((safe_val - min_val) / span, 0.0, 1.0)
    else
        0.0;
    const t_neutral = if (span > 0.0)
        std.math.clamp((neutral_val - min_val) / span, 0.0, 1.0)
    else
        0.0;

    const track_w = CONTENT_WIDTH;
    const knob_d: f32 = if (is_active or is_hovered) 16.0 else 14.0;
    const usable_w = @max(track_w - knob_d, 1.0);
    const knob_x = t * usable_w;

    const knob_center_x = (knob_d * 0.5) + (t * usable_w);
    const neutral_center_x = (knob_d * 0.5) + (t_neutral * usable_w);

    const fill_left = @min(knob_center_x, neutral_center_x);
    const fill_w = @abs(knob_center_x - neutral_center_x);

    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .fixed(track_w), .h = .fit },
            .direction = .top_to_bottom,
            .child_gap = 6,
        },
    })({
        // Top row: Label and Value Readout / Reset target
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(20) },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
            },
        })({
            // Label
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
            })({
                const lbl_color =
                    if (is_modified) theme.text else theme.subtext0;
                clay.text(label, .{
                    .color = a(lbl_color, progress),
                    .font_size = 13,
                    .font_id = 0,
                });
            });

            // Value / Reset button
            const reset_elem_id = clay.getElementId(reset_id_str);
            const reset_hovered = clay.pointerOver(reset_elem_id);
            clay.UI()(.{
                .id = reset_elem_id,
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .{
                        .left = 6,
                        .right = 6,
                        .top = 2,
                        .bottom = 2,
                    },
                },
                .background_color = if (is_modified and reset_hovered)
                    a(theme.surface1, progress)
                else if (is_modified)
                    a(theme.surface0, progress)
                else
                    clay.Color{ 0, 0, 0, 0 },
                .corner_radius = .all(4),
            })({
                clay.text(formatted_value, .{
                    .color = if (is_modified)
                        a(theme.mauve, progress)
                    else
                        a(theme.subtext1, progress),
                    .font_size = 12,
                    .font_id = 0,
                });
            });
        });

        // Bottom row: Interactive Slider Track
        clay.UI()(.{
            .id = track_id,
            .layout = .{
                .sizing = .{ .w = .fixed(track_w), .h = .fixed(20) },
                .child_alignment = .{ .x = .left, .y = .center },
            },
        })({
            // 1. Background Groove Bar
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(track_w), .h = .fixed(4) },
                },
                .background_color = a(theme.surface0, progress),
                .corner_radius = .all(2),
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{
                        .element = .left_center,
                        .parent = .left_center,
                    },
                    .z_index = 0,
                    .pointer_capture_mode = .passthrough,
                },
            })({});

            // 2. Center Landmark Notch
            const notch_x = neutral_center_x - 1.0;
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(2), .h = .fixed(8) },
                },
                .background_color = a(theme.overlay0, progress),
                .corner_radius = .all(1),
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{
                        .element = .left_center,
                        .parent = .left_center,
                    },
                    .offset = .{ .x = notch_x, .y = 0.0 },
                    .z_index = 1,
                    .pointer_capture_mode = .passthrough,
                },
            })({});

            // 3. Colored Adjustment Fill Bar
            if (fill_w > 0.5) {
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .fixed(fill_w), .h = .fixed(4) },
                    },
                    .background_color = a(theme.mauve, progress),
                    .corner_radius = .all(2),
                    .floating = .{
                        .attach_to = .to_parent,
                        .attach_points = .{
                            .element = .left_center,
                            .parent = .left_center,
                        },
                        .offset = .{ .x = fill_left, .y = 0.0 },
                        .z_index = 2,
                        .pointer_capture_mode = .passthrough,
                    },
                })({});
            }

            // 4. Thumb Knob Handle
            clay.UI()(.{
                .id = clay.getElementId(switch (param) {
                    .brightness => "SliderKnob_Brightness",
                    .contrast => "SliderKnob_Contrast",
                }),
                .layout = .{
                    .sizing = .{ .w = .fixed(knob_d), .h = .fixed(knob_d) },
                },
                .background_color = a(theme.text, progress),
                .corner_radius = .all(knob_d / 2.0),
                .border = .{
                    .width = .all(1),
                    .color = a(theme.crust, progress),
                },
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{
                        .element = .left_center,
                        .parent = .left_center,
                    },
                    .offset = .{ .x = knob_x, .y = 0.0 },
                    .z_index = 3,
                    .pointer_capture_mode = .passthrough,
                },
            })({});
        });
    });
}

/// Renders the complete Edit Side Panel layout tree including header,
/// quick action buttons, and adjustment sliders.
pub fn renderEditPanel(
    ui_model: UiViewModel,
    docked_w: f32,
    progress: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    _ = measure_data;
    const vp = ui_model.viewport;
    const has_adjustments = vp.hasAdjustments();
    const is_comparing = vp.compare_original;

    const b_str = try formatBrightness(frame_allocator, vp.brightness);
    const c_str = try formatContrast(frame_allocator, vp.contrast);

    clay.UI()(.{
        .id = clay.getElementId("EditSidePanel"),
        .layout = .{
            .sizing = .{
                .w = .fixed(docked_w),
                .h = .grow,
            },
            .direction = .top_to_bottom,
            .padding = .{
                .left = @intFromFloat(PANEL_PADDING),
                .right = @intFromFloat(PANEL_PADDING),
                .top = 20,
                .bottom = 20,
            },
            .child_gap = 18,
        },
        .clip = .{ .horizontal = true, .vertical = true },
        .background_color = a(theme.mantle, progress),
        .border = .{
            .width = .{ .left = 1, .right = 0, .top = 0, .bottom = 0 },
            .color = a(theme.surface0, progress),
        },
    })({
        // =====================================================================
        // Header Row: Title & Action Buttons
        // =====================================================================
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .fixed(CONTENT_WIDTH), .h = .fixed(28) },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 8,
            },
        })({
            // Panel Title
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .grow },
                    .child_alignment = .{ .x = .left, .y = .center },
                },
            })({
                clay.text("Adjustments", .{
                    .color = a(theme.mauve, progress),
                    .font_size = 16,
                    .font_id = 0,
                });
            });

            // Before / After Comparison Toggle Button
            const cmp_elem_id = clay.getElementId("EditCompareBtn");
            const cmp_hovered = clay.pointerOver(cmp_elem_id);
            clay.UI()(.{
                .id = cmp_elem_id,
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fixed(24) },
                    .padding = .{ .left = 8, .right = 8 },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = if (is_comparing)
                    a(theme.mauve, progress * 0.3)
                else if (has_adjustments and cmp_hovered)
                    a(theme.surface1, progress)
                else
                    a(theme.surface0, progress),
                .corner_radius = .all(6),
                .border = if (is_comparing) .{
                    .width = .all(1),
                    .color = a(theme.mauve, progress),
                } else .{},
            })({
                clay.text(if (is_comparing) "Original" else "Compare", .{
                    .color = if (is_comparing)
                        a(theme.mauve, progress)
                    else if (has_adjustments)
                        a(theme.text, progress)
                    else
                        a(theme.subtext1, progress),
                    .font_size = 11,
                    .font_id = 0,
                });
            });

            // Reset All Adjustments Button
            const reset_elem_id = clay.getElementId("EditResetBtn");
            const reset_hovered = clay.pointerOver(reset_elem_id);
            clay.UI()(.{
                .id = reset_elem_id,
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fixed(24) },
                    .padding = .{ .left = 8, .right = 8 },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = if (has_adjustments and reset_hovered)
                    a(theme.surface1, progress)
                else
                    a(theme.surface0, progress),
                .corner_radius = .all(6),
            })({
                const reset_col = if (has_adjustments)
                    a(theme.text, progress)
                else
                    a(theme.subtext1, progress);
                clay.text("Reset", .{
                    .color = reset_col,
                    .font_size = 11,
                    .font_id = 0,
                });
            });

            // Close Side Panel Button ('✕')
            const close_elem_id = clay.getElementId("EditCloseBtn");
            const close_hovered = clay.pointerOver(close_elem_id);
            clay.UI()(.{
                .id = close_elem_id,
                .layout = .{
                    .sizing = .{ .w = .fixed(24), .h = .fixed(24) },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = if (close_hovered)
                    a(theme.surface1, progress)
                else
                    a(theme.surface0, progress),
                .corner_radius = .all(12),
            })({
                clay.text("x", .{
                    .color = a(theme.text, progress),
                    .font_size = 12,
                    .font_id = 0,
                });
            });
        });

        // Divider
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .fixed(CONTENT_WIDTH), .h = .fixed(1) },
            },
            .background_color = a(theme.surface0, progress),
        })({});

        // =====================================================================
        // Section: Light & Exposure
        // =====================================================================
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .fixed(CONTENT_WIDTH), .h = .fit },
                .direction = .top_to_bottom,
                .child_gap = 14,
            },
        })({
            // Section Category Label
            clay.text("LIGHT & EXPOSURE", .{
                .color = a(theme.subtext0, progress),
                .font_size = 11,
                .font_id = 0,
            });

            const active_sl = ui_model.overlays.edit_panel.active_slider;
            const b_active = !vp.compare_original and active_sl == .brightness;
            const c_active = !vp.compare_original and active_sl == .contrast;

            // Brightness Slider
            renderSlider(
                .brightness,
                "Brightness",
                vp.brightness,
                -1.0,
                1.0,
                0.0,
                b_str,
                progress,
                b_active,
            );

            // Contrast Slider
            renderSlider(
                .contrast,
                "Contrast",
                vp.contrast,
                0.0,
                3.0,
                1.0,
                c_str,
                progress,
                c_active,
            );
        });
    });
}

test "formatBrightness and formatContrast string lifetimes" {
    const b0 = try formatBrightness(std.testing.allocator, 0.0);
    try std.testing.expectEqualStrings("0%", b0);

    const bp = try formatBrightness(std.testing.allocator, 0.25);
    defer std.testing.allocator.free(bp);
    try std.testing.expectEqualStrings("+25%", bp);

    const bn = try formatBrightness(std.testing.allocator, -0.40);
    defer std.testing.allocator.free(bn);
    try std.testing.expectEqualStrings("-40%", bn);

    const b_nan =
        try formatBrightness(std.testing.allocator, std.math.nan(f32));
    try std.testing.expectEqualStrings("0%", b_nan);

    const c1 = try formatContrast(std.testing.allocator, 1.0);
    try std.testing.expectEqualStrings("1.00x", c1);

    const c2 = try formatContrast(std.testing.allocator, 1.5);
    defer std.testing.allocator.free(c2);
    try std.testing.expectEqualStrings("1.50x", c2);

    const c3 = try formatContrast(std.testing.allocator, 0.75);
    defer std.testing.allocator.free(c3);
    try std.testing.expectEqualStrings("0.75x", c3);

    const c_inf = try formatContrast(std.testing.allocator, std.math.inf(f32));
    try std.testing.expectEqualStrings("1.00x", c_inf);
}
