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
                const knob_d: f32 = 16.0;
                const usable_w = @max(s.track_w - knob_d, 1.0);
                const rel_x = input.mouse_x - s.track_x;
                const offset_x = rel_x - (knob_d * 0.5);
                const t = std.math.clamp(offset_x / usable_w, 0.0, 1.0);
                var val = s.min_val + t * (s.max_val - s.min_val);
                switch (s.param) {
                    .brightness => {
                        if (@abs(val) < 0.025) val = 0.0;
                        const clamped = std.math.clamp(val, -1.0, 1.0);
                        try self.pushIntent(.{ .set_brightness = clamped });
                    },
                    .contrast => {
                        if (@abs(val - 1.0) < 0.035) val = 1.0;
                        const clamped = std.math.clamp(val, 0.0, 3.0);
                        try self.pushIntent(.{ .set_contrast = clamped });
                    },
                }
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
                try self.pushIntent(.reset_adjustments);
            } else if (clay.pointerOver(clay.getElementId("EditCompareBtn"))) {
                try self.pushIntent(.toggle_compare);
            } else if (clay.pointerOver(
                clay.getElementId("SliderReset_Brightness"),
            )) {
                try self.pushIntent(.{ .set_brightness = 0.0 });
            } else if (clay.pointerOver(
                clay.getElementId("SliderReset_Contrast"),
            )) {
                try self.pushIntent(.{ .set_contrast = 1.0 });
            } else if (clay.pointerOver(
                clay.getElementId("SliderTrack_Brightness"),
            ) or clay.pointerOver(
                clay.getElementId("SliderKnob_Brightness"),
            )) {
                const track_elem_id =
                    clay.getElementId("SliderTrack_Brightness");
                const elem_data = clay.getElementData(track_elem_id);
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
                        .param = .brightness,
                        .track_x = track_x,
                        .track_w = track_w,
                        .min_val = -1.0,
                        .max_val = 1.0,
                    },
                };
                self.viewer.ui.overlays.edit_panel.active_slider = .brightness;

                const knob_d: f32 = 16.0;
                const usable_w = @max(track_w - knob_d, 1.0);
                const rel_x = input.mouse_x - track_x;
                const offset_x = rel_x - (knob_d * 0.5);
                const t = std.math.clamp(offset_x / usable_w, 0.0, 1.0);
                var val = -1.0 + t * 2.0;
                if (@abs(val) < 0.025) val = 0.0;
                const clamped = std.math.clamp(val, -1.0, 1.0);
                try self.pushIntent(.{ .set_brightness = clamped });
            } else if (clay.pointerOver(
                clay.getElementId("SliderTrack_Contrast"),
            ) or clay.pointerOver(
                clay.getElementId("SliderKnob_Contrast"),
            )) {
                const track_elem_id =
                    clay.getElementId("SliderTrack_Contrast");
                const elem_data = clay.getElementData(track_elem_id);
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
                        .param = .contrast,
                        .track_x = track_x,
                        .track_w = track_w,
                        .min_val = 0.0,
                        .max_val = 3.0,
                    },
                };
                self.viewer.ui.overlays.edit_panel.active_slider = .contrast;

                const knob_d: f32 = 16.0;
                const usable_w = @max(track_w - knob_d, 1.0);
                const rel_x = input.mouse_x - track_x;
                const offset_x = rel_x - (knob_d * 0.5);
                const t = std.math.clamp(offset_x / usable_w, 0.0, 1.0);
                var val = t * 3.0;
                if (@abs(val - 1.0) < 0.035) val = 1.0;
                const clamped = std.math.clamp(val, 0.0, 3.0);
                try self.pushIntent(.{ .set_contrast = clamped });
            }
        }
    }
}
