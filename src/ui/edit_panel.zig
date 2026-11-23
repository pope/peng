//! Image Adjustment Side Panel Layout & Sliders
//!
//! Provides the layout and slider widgets for tone, color, and presence
//! photographic adjustments in the docked edit side panel.

const geom = @import("geom");
const intents = @import("intents");
const renderer = @import("renderer.zig");
const state = @import("state");
const std = @import("std");
const text_utils = @import("text_utils.zig");
const theme = @import("theme.zig");
const view_model = @import("view_model.zig");

const EditParam = intents.EditParam;
const FRect = geom.FRect;
const measureText = text_utils.measureText;
const MeasureTextUserData = text_utils.MeasureTextUserData;
const ParamSpec = intents.ParamSpec;
const UiDrawList = renderer.UiDrawList;
const UiViewModel = view_model.UiViewModel;
const withAlpha = theme.withAlpha;

/// Default docked width of the edit panel in logical UI points.
pub const PANEL_WIDTH: f32 = state.EDIT_PANEL_WIDTH;
/// Inset padding inside the edit panel in logical UI points.
pub const PANEL_PADDING: f32 = state.EDIT_PANEL_PADDING;
/// Usable content width for adjustment sliders and controls.
pub const CONTENT_WIDTH: f32 = PANEL_WIDTH - (PANEL_PADDING * 2.0);

/// Formats an edit parameter value into its display string.
/// Uses static string literals for neutral defaults (zero-allocation)
/// and allocates formatted strings in frame_allocator for active values.
pub fn formatValue(
    allocator: std.mem.Allocator,
    spec: ParamSpec,
    val: f32,
) ![]const u8 {
    if (std.math.isNan(val) or std.math.isInf(val)) {
        return switch (spec.display_kind) {
            .percent => "0%",
            .multiplier => "1.00x",
            .temperature, .tint => "0",
            .ratio_percent => "100%",
        };
    }

    switch (spec.display_kind) {
        .percent => {
            const pct = @as(i32, @intFromFloat(@round(val * 100.0)));
            if (pct == 0) return "0%";
            if (pct > 0) {
                return try allocator.print("+{d}%", .{pct});
            }
            return try allocator.print("{d}%", .{pct});
        },
        .multiplier => {
            if (@abs(val - 1.0) < 1e-4) return "1.00x";
            return try allocator.print("{d:.2}x", .{val});
        },
        .ratio_percent => {
            const pct = @as(i32, @intFromFloat(@round(val * 100.0)));
            if (pct == 100) return "100%";
            if (pct == 50) return "50%";
            if (pct == 0) return "0%";
            return try allocator.print("{d}%", .{pct});
        },
        .temperature => {
            const val_int = @as(i32, @intFromFloat(@round(val * 100.0)));
            if (val_int == 0) return "0";
            if (val_int > 0) {
                return try allocator.print(
                    "+{d} (Warm)",
                    .{val_int},
                );
            }
            return try allocator.print(
                "{d} (Cool)",
                .{val_int},
            );
        },
        .tint => {
            const val_int = @as(i32, @intFromFloat(@round(val * 100.0)));
            if (val_int == 0) return "0";
            if (val_int > 0) {
                return try allocator.print(
                    "+{d} (Magenta)",
                    .{val_int},
                );
            }
            return try allocator.print(
                "{d} (Green)",
                .{val_int},
            );
        },
    }
}

/// Convenience formatter for brightness parameter.
pub fn formatBrightness(allocator: std.mem.Allocator, val: f32) ![]const u8 {
    return formatValue(allocator, intents.getSpec(.brightness), val);
}

/// Convenience formatter for contrast parameter.
pub fn formatContrast(allocator: std.mem.Allocator, val: f32) ![]const u8 {
    return formatValue(allocator, intents.getSpec(.contrast), val);
}

fn clipRect(r: FRect, sc: FRect) FRect {
    const rx = @max(r.x, sc.x);
    const ry = @max(r.y, sc.y);
    const r_right = @min(r.x + r.w, sc.x + sc.w);
    const r_bot = @min(r.y + r.h, sc.y + sc.h);
    return .{
        .x = rx,
        .y = ry,
        .w = @max(0.0, r_right - rx),
        .h = @max(0.0, r_bot - ry),
    };
}

/// Renders an interactive slider row with parameter title, value readout,
/// background groove, relative fill bar, landmark notch, and thumb knob.
pub fn renderSlider(
    interaction: *state.InteractionState,
    list: *UiDrawList,
    param: EditParam,
    current_val: f32,
    formatted_value: []const u8,
    progress: f32,
    is_active: bool,
    cur_x: f32,
    cur_y: f32,
    scroll_rect: FRect,
    measure_data: *const MeasureTextUserData,
) !void {
    const spec = intents.getSpec(param);
    const track_w = CONTENT_WIDTH;
    const track_rect = FRect{
        .x = cur_x,
        .y = cur_y + 26.0,
        .w = track_w,
        .h = 20.0,
    };
    const is_hovered = interaction.isHovered(track_rect);
    const is_modified = @abs(current_val - spec.default) > 1e-4;

    const span = spec.max - spec.min;
    const is_non_finite =
        std.math.isNan(current_val) or std.math.isInf(current_val);
    const safe_val = if (is_non_finite) spec.default else current_val;
    const t = if (span > 0.0)
        std.math.clamp((safe_val - spec.min) / span, 0.0, 1.0)
    else
        0.0;
    const t_neutral = if (span > 0.0)
        std.math.clamp((spec.default - spec.min) / span, 0.0, 1.0)
    else
        0.0;

    const knob_d: f32 = if (is_active or is_hovered) 16.0 else 14.0;
    const usable_w = @max(track_w - knob_d, 1.0);
    const knob_x = t * usable_w;

    const knob_center_x = (knob_d * 0.5) + (t * usable_w);
    const neutral_center_x = (knob_d * 0.5) + (t_neutral * usable_w);

    const fill_left = @min(knob_center_x, neutral_center_x);
    const fill_w = @abs(knob_center_x - neutral_center_x);

    // Top row: Label and Value / Reset button
    const reset_dims = measureText(formatted_value, 0, 12, measure_data);
    const reset_w = reset_dims.w + 12.0;
    const reset_h = reset_dims.h + 4.0;
    const reset_rect = FRect{
        .x = cur_x + track_w - reset_w,
        .y = cur_y + @round((20.0 - reset_h) * 0.5),
        .w = reset_w,
        .h = reset_h,
    };

    const lbl_color = if (is_modified) theme.text else theme.subtext0;
    const lbl_dims = measureText(spec.label, 0, 13, measure_data);
    const lbl_rect = FRect{
        .x = cur_x,
        .y = cur_y + @round((20.0 - lbl_dims.h) * 0.5),
        .w = @max(0.0, track_w - reset_w),
        .h = lbl_dims.h,
    };
    try list.addText(lbl_rect, .{
        .text = spec.label,
        .color = withAlpha(lbl_color, progress),
        .font_size = 13,
        .font_id = 0,
    });

    const reset_hovered = interaction.isHovered(reset_rect);
    const reset_bg = if (is_modified and reset_hovered)
        withAlpha(theme.surface1, progress)
    else if (is_modified)
        withAlpha(theme.surface0, progress)
    else
        theme.transparent;
    try list.addRect(reset_rect, .{
        .background_color = reset_bg,
        .corner_radius = .all(4),
    });

    const reset_col = if (is_modified)
        withAlpha(theme.mauve, progress)
    else
        withAlpha(theme.subtext1, progress);
    const reset_txt_rect = reset_rect.centered(reset_dims.w, reset_dims.h);
    try list.addText(reset_txt_rect, .{
        .text = formatted_value,
        .color = reset_col,
        .font_size = 12,
        .font_id = 0,
    });

    // Bottom row: Interactive Slider Track
    // 1. Background Track Groove
    const groove_rect = FRect{
        .x = cur_x,
        .y = track_rect.y + 8.0,
        .w = track_w,
        .h = 4.0,
    };
    try list.addRect(groove_rect, .{
        .background_color = withAlpha(theme.surface0, progress),
        .corner_radius = .all(2),
    });

    // 2. Center/Neutral Landmark Notch
    const notch_w: f32 = 2.0;
    const notch_h: f32 = 8.0;
    const notch_x = cur_x + neutral_center_x - (notch_w * 0.5);
    const notch_y = track_rect.y + 6.0;
    try list.addRect(.{
        .x = notch_x,
        .y = notch_y,
        .w = notch_w,
        .h = notch_h,
    }, .{
        .background_color = withAlpha(theme.surface1, progress),
        .corner_radius = .all(1),
    });

    // 3. Relative Fill Bar
    if (fill_w > 0.5) {
        try list.addRect(.{
            .x = cur_x + fill_left,
            .y = track_rect.y + 8.0,
            .w = fill_w,
            .h = 4.0,
        }, .{
            .background_color = withAlpha(theme.mauve, progress * 0.7),
            .corner_radius = .all(2),
        });
    }

    // 4. Thumb Knob Handle
    const knob_rect = FRect{
        .x = cur_x + knob_x,
        .y = track_rect.y + @round((20.0 - knob_d) * 0.5),
        .w = knob_d,
        .h = knob_d,
    };
    try list.addRect(knob_rect, .{
        .background_color = withAlpha(theme.text, progress),
        .corner_radius = .all(knob_d * 0.5),
    });
    try list.addBorder(knob_rect, .{
        .color = withAlpha(theme.crust, progress),
        .width = .all(1),
        .corner_radius = .all(knob_d * 0.5),
    });

    interaction.setSliderRects(
        param,
        clipRect(track_rect, scroll_rect),
        clipRect(knob_rect, scroll_rect),
        clipRect(reset_rect, scroll_rect),
    );
}

/// Renders the complete Edit Side Panel layout tree including header,
/// quick action buttons, and adjustment sliders.
pub fn renderEditPanel(
    interaction: *state.InteractionState,
    list: *UiDrawList,
    ui_model: UiViewModel,
    panel_rect: FRect,
    progress: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const vp = ui_model.viewport;
    const has_adjustments = vp.hasAdjustments();
    const is_comparing = vp.compare_original;

    try list.pushScissor(panel_rect);
    defer list.popScissor() catch {};

    try list.addRect(panel_rect, .{
        .background_color = withAlpha(theme.mantle, progress),
    });
    try list.addBorder(panel_rect, .{
        .color = withAlpha(theme.surface0, progress),
        .width = .{ .left = 1 },
    });

    const content_x = panel_rect.x + PANEL_PADDING;

    // Header Row: Title & Action Buttons
    var header_rect = FRect{
        .x = content_x,
        .y = panel_rect.y + 20.0,
        .w = CONTENT_WIDTH,
        .h = 28.0,
    };

    // Close Side Panel Button ('x')
    const close_slot = header_rect.cutRight(24.0);
    const close_btn_rect = close_slot.centered(24.0, 24.0);
    const close_hovered = interaction.isHovered(close_btn_rect);
    try list.addRect(close_btn_rect, .{
        .background_color = if (close_hovered)
            withAlpha(theme.surface1, progress)
        else
            withAlpha(theme.surface0, progress),
        .corner_radius = .all(12),
    });
    try list.addCloseIcon(close_btn_rect.centered(7.0, 7.0), .{
        .color = withAlpha(theme.text, progress),
        .stroke_width = 1.25,
    });

    _ = header_rect.cutRight(8.0);

    // Reset All Adjustments Button
    const reset_w = measureText("Reset", 0, 11, measure_data).w + 16.0;
    const reset_slot = header_rect.cutRight(reset_w);
    const reset_btn_rect = reset_slot.centered(reset_w, 24.0);
    const reset_hovered = interaction.isHovered(reset_btn_rect);
    try list.addRect(reset_btn_rect, .{
        .background_color = if (has_adjustments and reset_hovered)
            withAlpha(theme.surface1, progress)
        else
            withAlpha(theme.surface0, progress),
        .corner_radius = .all(6),
    });
    const reset_col = if (has_adjustments)
        withAlpha(theme.text, progress)
    else
        withAlpha(theme.subtext1, progress);
    const reset_txt_dims = measureText("Reset", 0, 11, measure_data);
    const reset_txt_rect = reset_btn_rect.centered(
        reset_txt_dims.w,
        reset_txt_dims.h,
    );
    try list.addText(reset_txt_rect, .{
        .text = "Reset",
        .color = reset_col,
        .font_size = 11,
        .font_id = 0,
    });

    _ = header_rect.cutRight(8.0);

    // Before / After Comparison Toggle Button
    const cmp_label = if (is_comparing) "Original" else "Compare";
    const cmp_w = measureText(cmp_label, 0, 11, measure_data).w + 16.0;
    const cmp_slot = header_rect.cutRight(cmp_w);
    const cmp_btn_rect = cmp_slot.centered(cmp_w, 24.0);
    const cmp_hovered = interaction.isHovered(cmp_btn_rect);
    const cmp_bg = if (is_comparing)
        withAlpha(theme.mauve, progress * 0.3)
    else if (has_adjustments and cmp_hovered)
        withAlpha(theme.surface1, progress)
    else
        withAlpha(theme.surface0, progress);
    try list.addRect(cmp_btn_rect, .{
        .background_color = cmp_bg,
        .corner_radius = .all(6),
    });
    if (is_comparing) {
        try list.addBorder(cmp_btn_rect, .{
            .color = withAlpha(theme.mauve, progress),
            .width = .all(1),
            .corner_radius = .all(6),
        });
    }
    const cmp_col = if (is_comparing)
        withAlpha(theme.mauve, progress)
    else if (has_adjustments)
        withAlpha(theme.text, progress)
    else
        withAlpha(theme.subtext1, progress);
    const cmp_txt_dims = measureText(cmp_label, 0, 11, measure_data);
    const cmp_txt_rect = cmp_btn_rect.centered(
        cmp_txt_dims.w,
        cmp_txt_dims.h,
    );
    try list.addText(cmp_txt_rect, .{
        .text = cmp_label,
        .color = cmp_col,
        .font_size = 11,
        .font_id = 0,
    });

    // Panel Title
    const title_dims = measureText("Adjustments", 0, 16, measure_data);
    const title_rect = FRect{
        .x = header_rect.x,
        .y = header_rect.y + @round((28.0 - title_dims.h) * 0.5),
        .w = header_rect.w,
        .h = title_dims.h,
    };
    try list.addText(title_rect, .{
        .text = "Adjustments",
        .color = withAlpha(theme.mauve, progress),
        .font_size = 16,
        .font_id = 0,
    });

    // Divider
    try list.addRect(.{
        .x = content_x,
        .y = panel_rect.y + 64.0,
        .w = CONTENT_WIDTH,
        .h = 1.0,
    }, .{
        .background_color = withAlpha(theme.surface0, progress),
    });

    // Scrollable Adjustments List
    const scroll_rect = FRect{
        .x = content_x,
        .y = panel_rect.y + 81.0,
        .w = CONTENT_WIDTH,
        .h = @max(0.0, panel_rect.h - 81.0 - 20.0),
    };

    interaction.setEditPanelRects(
        panel_rect,
        close_btn_rect,
        reset_btn_rect,
        cmp_btn_rect,
        scroll_rect,
    );

    try list.pushScissor(scroll_rect);
    defer list.popScissor() catch {};

    var cur_y = scroll_rect.y + interaction.edit_scroll_y;
    const active_sl = ui_model.overlays.edit_panel.active_slider;

    inline for (
        std.enums.values(intents.EditDomain),
        0..,
    ) |domain, domain_idx| {
        // Section Category Label
        cur_y += 10.0;
        const dom_dims = measureText(domain.label(), 0, 11, measure_data);
        try list.addText(.{
            .x = content_x,
            .y = cur_y,
            .w = CONTENT_WIDTH,
            .h = dom_dims.h,
        }, .{
            .text = domain.label(),
            .color = withAlpha(theme.subtext0, progress),
            .font_size = 11,
            .font_id = 0,
        });
        cur_y += dom_dims.h + 26.0;

        var is_first_slider = true;
        inline for (intents.specs) |spec| {
            if (spec.domain == domain) {
                if (!is_first_slider) {
                    cur_y += 12.0;
                }
                is_first_slider = false;
                const val = vp.edits.get(spec.param);
                const str = try formatValue(
                    frame_allocator,
                    spec,
                    val,
                );
                const is_active = !is_comparing and active_sl == spec.param;
                try renderSlider(
                    interaction,
                    list,
                    spec.param,
                    val,
                    str,
                    progress,
                    is_active,
                    content_x,
                    cur_y,
                    scroll_rect,
                    measure_data,
                );
                cur_y += 46.0;
            }
        }

        // Divider between sections
        if (domain_idx + 1 < std.enums.values(intents.EditDomain).len) {
            cur_y += 16.0;
            try list.addRect(.{
                .x = content_x,
                .y = cur_y,
                .w = CONTENT_WIDTH,
                .h = 1.0,
            }, .{
                .background_color = withAlpha(theme.surface0, progress),
            });
            cur_y += 1.0 + 16.0;
        }
    }

    cur_y += 16.0 + 16.0;
    const total_content_h = cur_y -
        (scroll_rect.y + interaction.edit_scroll_y);
    interaction.edit_content_h = total_content_h;
}

test "formatValue string lifetimes" {
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

    // Test temperature & tint formatting
    const temp_desc = intents.getSpec(.temperature);
    const t0 = try formatValue(std.testing.allocator, temp_desc, 0.0);
    try std.testing.expectEqualStrings("0", t0);
    const tw = try formatValue(std.testing.allocator, temp_desc, 0.35);
    defer std.testing.allocator.free(tw);
    try std.testing.expectEqualStrings("+35 (Warm)", tw);

    const tint_desc = intents.getSpec(.tint);
    const m0 = try formatValue(std.testing.allocator, tint_desc, 0.0);
    try std.testing.expectEqualStrings("0", m0);
    const mg = try formatValue(std.testing.allocator, tint_desc, -0.20);
    defer std.testing.allocator.free(mg);
    try std.testing.expectEqualStrings("-20 (Green)", mg);

    // Test contrast_blend formatting
    const cb_desc = intents.getSpec(.contrast_blend);
    const cb1 = try formatValue(std.testing.allocator, cb_desc, 1.0);
    try std.testing.expectEqualStrings("100%", cb1);
    const cb0 = try formatValue(std.testing.allocator, cb_desc, 0.0);
    try std.testing.expectEqualStrings("0%", cb0);
    const cb50 = try formatValue(std.testing.allocator, cb_desc, 0.5);
    try std.testing.expectEqualStrings("50%", cb50);
    const cb75 = try formatValue(std.testing.allocator, cb_desc, 0.75);
    defer std.testing.allocator.free(cb75);
    try std.testing.expectEqualStrings("75%", cb75);

    // Test clarity and texture formatting
    const clar_desc = intents.getSpec(.clarity);
    const cl0 = try formatValue(std.testing.allocator, clar_desc, 0.0);
    try std.testing.expectEqualStrings("0%", cl0);
    const cl_pos = try formatValue(std.testing.allocator, clar_desc, 0.35);
    defer std.testing.allocator.free(cl_pos);
    try std.testing.expectEqualStrings("+35%", cl_pos);

    const tex_desc = intents.getSpec(.texture);
    const tx_neg = try formatValue(std.testing.allocator, tex_desc, -0.25);
    defer std.testing.allocator.free(tx_neg);
    try std.testing.expectEqualStrings("-25%", tx_neg);
}

test "floating slider knob commands are clipped by scroll container scissor" {
    const allocator = std.testing.allocator;
    var list = renderer.UiDrawList{ .allocator = allocator };
    defer list.commands.deinit(allocator);

    const data = text_utils.MeasureTextUserData{};
    const scroll_rect = FRect{
        .x = 16,
        .y = 81,
        .w = CONTENT_WIDTH,
        .h = 400,
    };

    var interaction_inst: state.InteractionState = .{};

    try list.pushScissor(scroll_rect);
    try renderSlider(
        &interaction_inst,
        &list,
        .brightness,
        0.5,
        "+50%",
        1.0,
        false,
        16.0,
        100.0,
        scroll_rect,
        &data,
    );
    try list.popScissor();

    var scissor_start_count: u32 = 0;
    var scissor_end_count: u32 = 0;
    var has_commands_inside = false;

    for (list.commands.items) |cmd| {
        switch (cmd.payload) {
            .scissor_start => scissor_start_count += 1,
            .scissor_end => scissor_end_count += 1,
            else => {
                if (scissor_start_count > scissor_end_count) {
                    has_commands_inside = true;
                }
            },
        }
    }

    try std.testing.expect(has_commands_inside);
    try std.testing.expect(scissor_start_count > 0);
    try std.testing.expectEqual(scissor_start_count, scissor_end_count);
}
