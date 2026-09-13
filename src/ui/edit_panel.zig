const clay = @import("zclay");
const state = @import("state");
const std = @import("std");
const theme = @import("theme.zig");

const EditParam = state.EditParam;
const UiViewModel = state.UiViewModel;

/// Scales a theme color by the animation progress alpha for smooth
/// fade-in/fade-out.
inline fn a(color: clay.Color, progress: f32) clay.Color {
    return theme.withAlpha(color, progress);
}

pub const PANEL_WIDTH: f32 = state.EDIT_PANEL_WIDTH;
pub const PANEL_PADDING: f32 = state.EDIT_PANEL_PADDING;
pub const CONTENT_WIDTH: f32 = PANEL_WIDTH - (PANEL_PADDING * 2.0);

/// Formats an edit parameter value into its display string.
/// Uses static string literals for neutral defaults (zero-allocation)
/// and allocates formatted strings in frame_allocator for active values.
pub fn formatValue(
    allocator: std.mem.Allocator,
    desc: state.ParamDescriptor,
    val: f32,
) ![]const u8 {
    if (std.math.isNan(val) or std.math.isInf(val)) {
        return switch (desc.display_kind) {
            .percent => "0%",
            .multiplier => "1.00x",
            .temperature, .tint => "0",
            .ratio_percent => "100%",
        };
    }

    switch (desc.display_kind) {
        .percent => {
            const pct = @as(i32, @intFromFloat(@round(val * 100.0)));
            if (pct == 0) return "0%";
            if (pct > 0) {
                return try std.fmt.allocPrint(allocator, "+{d}%", .{pct});
            }
            return try std.fmt.allocPrint(allocator, "{d}%", .{pct});
        },
        .multiplier => {
            if (@abs(val - 1.0) < 1e-4) return "1.00x";
            return try std.fmt.allocPrint(allocator, "{d:.2}x", .{val});
        },
        .ratio_percent => {
            const pct = @as(i32, @intFromFloat(@round(val * 100.0)));
            if (pct == 100) return "100%";
            if (pct == 50) return "50%";
            if (pct == 0) return "0%";
            return try std.fmt.allocPrint(allocator, "{d}%", .{pct});
        },
        .temperature => {
            const val_int = @as(i32, @intFromFloat(@round(val * 100.0)));
            if (val_int == 0) return "0";
            if (val_int > 0) {
                return try std.fmt.allocPrint(
                    allocator,
                    "+{d} (Warm)",
                    .{val_int},
                );
            }
            return try std.fmt.allocPrint(
                allocator,
                "{d} (Cool)",
                .{val_int},
            );
        },
        .tint => {
            const val_int = @as(i32, @intFromFloat(@round(val * 100.0)));
            if (val_int == 0) return "0";
            if (val_int > 0) {
                return try std.fmt.allocPrint(
                    allocator,
                    "+{d} (Magenta)",
                    .{val_int},
                );
            }
            return try std.fmt.allocPrint(
                allocator,
                "{d} (Green)",
                .{val_int},
            );
        },
    }
}

/// Convenience formatter for brightness parameter.
pub fn formatBrightness(allocator: std.mem.Allocator, val: f32) ![]const u8 {
    return formatValue(allocator, state.getDescriptor(.brightness), val);
}

/// Convenience formatter for contrast parameter.
pub fn formatContrast(allocator: std.mem.Allocator, val: f32) ![]const u8 {
    return formatValue(allocator, state.getDescriptor(.contrast), val);
}

pub const getSliderElementNames = state.getSliderElementNames;

/// Renders an interactive slider row with parameter title, value readout,
/// background groove, relative fill bar, landmark notch, and thumb knob.
pub fn renderSlider(
    param: EditParam,
    current_val: f32,
    formatted_value: []const u8,
    progress: f32,
    is_active: bool,
) void {
    const desc = state.getDescriptor(param);
    const names = getSliderElementNames(param);
    const track_id = clay.getElementId(names.track);
    const is_hovered = clay.pointerOver(track_id);
    const is_modified = @abs(current_val - desc.default) > 1e-4;

    const span = desc.max - desc.min;
    const is_non_finite =
        std.math.isNan(current_val) or std.math.isInf(current_val);
    const safe_val = if (is_non_finite) desc.default else current_val;
    const t = if (span > 0.0)
        std.math.clamp((safe_val - desc.min) / span, 0.0, 1.0)
    else
        0.0;
    const t_neutral = if (span > 0.0)
        std.math.clamp((desc.default - desc.min) / span, 0.0, 1.0)
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
                clay.text(desc.label, .{
                    .color = a(lbl_color, progress),
                    .font_size = 13,
                    .font_id = 0,
                });
            });

            // Value / Reset button
            const reset_elem_id = clay.getElementId(names.reset);
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
            // 1. Background Track Groove
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(track_w), .h = .fixed(4) },
                },
                .background_color = a(theme.surface0, progress),
                .corner_radius = .all(2),
            })({});

            // 2. Center/Neutral Landmark Notch
            const notch_w: f32 = 2.0;
            const notch_h: f32 = 8.0;
            const notch_x = neutral_center_x - (notch_w * 0.5);
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(notch_w), .h = .fixed(notch_h) },
                },
                .background_color = a(theme.surface1, progress),
                .corner_radius = .all(1),
                .floating = .{
                    .attach_to = .to_parent,
                    .clip_to = .to_attached_parent,
                    .attach_points = .{
                        .element = .left_center,
                        .parent = .left_center,
                    },
                    .offset = .{ .x = notch_x, .y = 0.0 },
                    .z_index = 1,
                    .pointer_capture_mode = .passthrough,
                },
            })({});

            // 3. Relative Fill Bar (neutral landmark to thumb center)
            if (fill_w > 0.5) {
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{
                            .w = .fixed(fill_w),
                            .h = .fixed(4),
                        },
                    },
                    .background_color = a(theme.mauve, progress * 0.7),
                    .corner_radius = .all(2),
                    .floating = .{
                        .attach_to = .to_parent,
                        .clip_to = .to_attached_parent,
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
                .id = clay.getElementId(names.knob),
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
                    .clip_to = .to_attached_parent,
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
) !void {
    const vp = ui_model.viewport;
    const has_adjustments = vp.hasAdjustments();
    const is_comparing = vp.compare_original;

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
            .child_gap = 16,
        },
        .clip = .{ .horizontal = true, .vertical = false },
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
        // Scrollable Adjustments List (Scrolls vertically when window is small)
        // =====================================================================
        const scroll_id = clay.getElementId("EditPanelScrollList");
        const scroll_data = clay.cdefs.Clay_GetScrollContainerData(scroll_id);
        const scroll_offset = if (scroll_data.found)
            scroll_data.scroll_position.*
        else
            clay.Vector2{ .x = 0, .y = 0 };

        clay.UI()(.{
            .id = scroll_id,
            .layout = .{
                .sizing = .{ .w = .fixed(CONTENT_WIDTH), .h = .grow },
                .direction = .top_to_bottom,
                .child_gap = 16,
            },
            .clip = .{
                .horizontal = false,
                .vertical = true,
                .child_offset = scroll_offset,
            },
        })({
            // -----------------------------------------------------------------
            // Section 1: Light & Tone
            // -----------------------------------------------------------------
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(CONTENT_WIDTH), .h = .fit },
                    .direction = .top_to_bottom,
                    .child_gap = 12,
                },
            })({
                // Section Category Label
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .padding = .{ .top = 10, .bottom = 14 },
                    },
                })({
                    clay.text("LIGHT & TONE", .{
                        .color = a(theme.subtext0, progress),
                        .font_size = 11,
                        .font_id = 0,
                    });
                });

                const active_sl = ui_model.overlays.edit_panel.active_slider;

                inline for (&[_]EditParam{
                    .brightness,
                    .contrast,
                    .contrast_blend,
                    .highlights,
                    .shadows,
                    .whites,
                    .blacks,
                }) |p| {
                    const desc = state.getDescriptor(p);
                    const str = try formatValue(
                        frame_allocator,
                        desc,
                        vp.edits.get(p),
                    );
                    const is_active = !is_comparing and active_sl == p;
                    renderSlider(p, vp.edits.get(p), str, progress, is_active);
                }
            });

            // Divider
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(CONTENT_WIDTH), .h = .fixed(1) },
                },
                .background_color = a(theme.surface0, progress),
            })({});

            // -----------------------------------------------------------------
            // Section 2: Color & Balance
            // -----------------------------------------------------------------
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(CONTENT_WIDTH), .h = .fit },
                    .direction = .top_to_bottom,
                    .child_gap = 12,
                },
            })({
                // Section Category Label
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .padding = .{ .top = 10, .bottom = 14 },
                    },
                })({
                    clay.text("COLOR & BALANCE", .{
                        .color = a(theme.subtext0, progress),
                        .font_size = 11,
                        .font_id = 0,
                    });
                });

                const active_sl = ui_model.overlays.edit_panel.active_slider;

                inline for (&[_]EditParam{
                    .temperature,
                    .tint,
                    .vibrance,
                    .saturation,
                }) |p| {
                    const desc = state.getDescriptor(p);
                    const str = try formatValue(
                        frame_allocator,
                        desc,
                        vp.edits.get(p),
                    );
                    const is_active = !is_comparing and active_sl == p;
                    renderSlider(p, vp.edits.get(p), str, progress, is_active);
                }
            });

            // Divider
            clay.UI()(.{
                .layout = .{
                    .sizing = .{
                        .w = .fixed(CONTENT_WIDTH),
                        .h = .fixed(1),
                    },
                },
                .background_color = a(theme.surface0, progress),
            })({});

            // -----------------------------------------------------------------
            // Section 3: Presence & Detail
            // -----------------------------------------------------------------
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(CONTENT_WIDTH), .h = .fit },
                    .direction = .top_to_bottom,
                    .child_gap = 12,
                },
            })({
                // Section Category Label
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .padding = .{ .top = 10, .bottom = 14 },
                    },
                })({
                    clay.text("PRESENCE & DETAIL", .{
                        .color = a(theme.subtext0, progress),
                        .font_size = 11,
                        .font_id = 0,
                    });
                });

                const active_sl = ui_model.overlays.edit_panel.active_slider;

                inline for (&[_]EditParam{
                    .texture,
                    .clarity,
                }) |p| {
                    const desc = state.getDescriptor(p);
                    const str = try formatValue(
                        frame_allocator,
                        desc,
                        vp.edits.get(p),
                    );
                    const is_active = !is_comparing and active_sl == p;
                    renderSlider(
                        p,
                        vp.edits.get(p),
                        str,
                        progress,
                        is_active,
                    );
                }
            });

            // Bottom spacer for comfortable scroll padding
            clay.UI()(.{
                .layout = .{
                    .sizing = .{
                        .w = .fixed(CONTENT_WIDTH),
                        .h = .fixed(16),
                    },
                },
            })({});
        });
    });
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
    const temp_desc = state.getDescriptor(.temperature);
    const t0 = try formatValue(std.testing.allocator, temp_desc, 0.0);
    try std.testing.expectEqualStrings("0", t0);
    const tw = try formatValue(std.testing.allocator, temp_desc, 0.35);
    defer std.testing.allocator.free(tw);
    try std.testing.expectEqualStrings("+35 (Warm)", tw);

    const tint_desc = state.getDescriptor(.tint);
    const m0 = try formatValue(std.testing.allocator, tint_desc, 0.0);
    try std.testing.expectEqualStrings("0", m0);
    const mg = try formatValue(std.testing.allocator, tint_desc, -0.20);
    defer std.testing.allocator.free(mg);
    try std.testing.expectEqualStrings("-20 (Green)", mg);

    // Test contrast_blend formatting
    const cb_desc = state.getDescriptor(.contrast_blend);
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
    const clar_desc = state.getDescriptor(.clarity);
    const cl0 = try formatValue(std.testing.allocator, clar_desc, 0.0);
    try std.testing.expectEqualStrings("0%", cl0);
    const cl_pos = try formatValue(std.testing.allocator, clar_desc, 0.35);
    defer std.testing.allocator.free(cl_pos);
    try std.testing.expectEqualStrings("+35%", cl_pos);

    const tex_desc = state.getDescriptor(.texture);
    const tx_neg = try formatValue(std.testing.allocator, tex_desc, -0.25);
    defer std.testing.allocator.free(tx_neg);
    try std.testing.expectEqualStrings("-25%", tx_neg);
}

var test_clay_mem: [1024 * 1024]u8 = undefined;

test "floating slider knob commands are clipped by scroll container scissor" {
    _ = clay.initialize(
        clay.Arena.init(&test_clay_mem),
        .{ .w = 1000, .h = 800 },
        .{},
    );
    clay.beginLayout();

    const scroll_id = clay.getElementId("TestScrollList");
    clay.UI()(.{
        .id = scroll_id,
        .layout = .{
            .sizing = .{ .w = .fixed(300), .h = .fixed(400) },
            .direction = .top_to_bottom,
        },
        .clip = .{
            .horizontal = false,
            .vertical = true,
            .child_offset = .{ .x = 0, .y = -100 },
        },
    })({
        // Use non-default value (0.5) so notch, fill bar (fill_w > 0.5),
        // and knob all render
        renderSlider(.brightness, 0.5, "+50%", 1.0, false);
    });

    const commands = clay.endLayout();
    const knob_names = getSliderElementNames(.brightness);
    const knob_id = clay.getElementId(knob_names.knob).id;

    var found_knob = false;
    var current_scissor: ?clay.BoundingBox = null;
    var scissor_start_count: u32 = 0;
    var scissor_end_count: u32 = 0;

    for (commands) |cmd| {
        if (cmd.command_type == .scissor_start) {
            current_scissor = cmd.bounding_box;
            scissor_start_count += 1;
        } else if (cmd.command_type == .scissor_end) {
            current_scissor = null;
            scissor_end_count += 1;
        } else if (cmd.id == knob_id) {
            found_knob = true;
            // The knob MUST be enclosed within an active scissor
            try std.testing.expect(current_scissor != null);
            const sc = current_scissor.?;
            try std.testing.expectEqual(@as(f32, 300), sc.width);
            try std.testing.expectEqual(@as(f32, 400), sc.height);
        }
    }

    try std.testing.expect(found_knob);
    // Every scissor_start must be balanced with a scissor_end
    try std.testing.expect(scissor_start_count > 0);
    try std.testing.expectEqual(scissor_start_count, scissor_end_count);
    // Scissor state must be cleanly closed by the end
    try std.testing.expect(current_scissor == null);
}
