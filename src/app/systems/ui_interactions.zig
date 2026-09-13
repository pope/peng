const clay = @import("zclay");
const FrameContext = @import("context.zig").FrameContext;
const state = @import("state");
const std = @import("std");

/// System Pass: Process discrete UI component pointer interactions
/// (close buttons, controls, sliders).
///
/// Responsibilities:
/// 1. Updates continuous slider dragging state while mouse button is held.
/// 2. Tests mouse clicks against interactive buttons (close, compare, reset).
/// 3. Initiates slider dragging when clicking on track or knob.
pub fn sysProcessUiInteractions(ctx: FrameContext) !void {
    const self = ctx.state;
    const input = ctx.input orelse return;

    // 1. Continuous Slider Dragging Update
    switch (self.viewer.drag_state) {
        .slider => |s| {
            if (input.mouse_left_down) {
                const desc = state.getDescriptor(s.param);
                const knob_d: f32 = 16.0;
                const usable_w = @max(s.track_w - knob_d, 1.0);
                const rel_x = input.mouse_x - s.track_x;
                const offset_x = rel_x - (knob_d * 0.5);
                const t = std.math.clamp(offset_x / usable_w, 0.0, 1.0);
                const raw_val = desc.min + t * (desc.max - desc.min);
                const val = desc.snap(raw_val);
                try self.pushIntent(.{
                    .adjust = .{
                        .set = .{ .param = s.param, .value = val },
                    },
                });
            } else {
                self.viewer.drag_state = .none;
                self.viewer.ui.overlays.edit_panel.active_slider = null;
            }
        },
        else => {},
    }

    // 2. Discrete Clicks (Buttons & Initial Slider Click)
    if (input.mouse_left_clicked and !input.isPointerInDebugPanel()) {
        // Floating Overlays Close Buttons
        if (self.viewer.ui.overlays.info_panel.visible and
            clay.pointerOver(clay.getElementId("InfoCloseBtn")))
        {
            try self.pushIntent(.{ .set_info = false });
        }
        if (self.viewer.ui.overlays.stats_panel.visible and
            clay.pointerOver(clay.getElementId("StatsCloseBtn")))
        {
            try self.pushIntent(.{ .set_stats = false });
        }

        // Edit Side Panel Controls
        if (self.viewer.ui.overlays.edit_panel.visible) {
            const panel_w = state.EDIT_PANEL_WIDTH;
            const padding = state.EDIT_PANEL_PADDING;
            const fallback_track_w = panel_w - (padding * 2.0);
            const debug_w: f32 = if (clay.isDebugModeEnabled())
                @as(f32, @floatFromInt(clay.Clay__debugViewWidth))
            else
                0.0;
            const fallback_track_x = input.win_w - debug_w - panel_w + padding;

            if (clay.pointerOver(clay.getElementId("EditCloseBtn"))) {
                try self.pushIntent(.{ .set_edit_panel = false });
            } else if (clay.pointerOver(clay.getElementId("EditResetBtn"))) {
                try self.pushIntent(.{ .adjust = .reset_all });
            } else if (clay.pointerOver(clay.getElementId("EditCompareBtn"))) {
                try self.pushIntent(.{ .adjust = .toggle_compare });
            } else {
                inline for (std.enums.values(state.EditParam)) |param| {
                    const desc = state.getDescriptor(param);
                    const names = state.getSliderElementNames(param);

                    if (clay.pointerOver(clay.getElementId(names.reset))) {
                        try self.pushIntent(.{
                            .adjust = .{ .reset_param = param },
                        });
                        return;
                    }

                    const track_id = clay.getElementId(names.track);
                    const knob_id = clay.getElementId(names.knob);
                    if (clay.pointerOver(track_id) or
                        clay.pointerOver(knob_id))
                    {
                        const elem_data = clay.getElementData(track_id);
                        const track_x = if (elem_data.found)
                            elem_data.bounding_box.x
                        else
                            fallback_track_x;
                        const track_w = if (elem_data.found)
                            elem_data.bounding_box.width
                        else
                            fallback_track_w;

                        self.viewer.drag_state = .{
                            .slider = .{
                                .param = param,
                                .track_x = track_x,
                                .track_w = track_w,
                            },
                        };
                        self.viewer.ui.overlays.edit_panel.active_slider =
                            param;

                        const knob_d: f32 = 16.0;
                        const usable_w = @max(track_w - knob_d, 1.0);
                        const rel_x = input.mouse_x - track_x;
                        const offset_x = rel_x - (knob_d * 0.5);
                        const t = std.math.clamp(offset_x / usable_w, 0.0, 1.0);
                        const raw_val = desc.min + t * (desc.max - desc.min);
                        const val = desc.snap(raw_val);
                        try self.pushIntent(.{
                            .adjust = .{
                                .set = .{ .param = param, .value = val },
                            },
                        });
                        return;
                    }
                }
            }
        }
    }
}
