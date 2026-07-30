const std = @import("std");
const clay = @import("zclay");
const state_pkg = @import("state");
const app_state = @import("../state.zig");
const ViewerState = app_state.ViewerState;
const FrameInput = state_pkg.FrameInput;

/// System Pass: Viewport input processing (Mouse Drag & Scroll-Zoom at Cursor)
pub fn sysUpdateViewport(state: *ViewerState, input: FrameInput, palette_closed_this_frame: bool) void {
    // 1. Mouse Drag state machine
    var next_drag_state = state.drag_state;
    switch (next_drag_state) {
        .none => {},
        .viewport => |v| {
            if (input.mouse_left_down) {
                const dx = input.pixMouseX() - v.last_x;
                const dy = input.pixMouseY() - v.last_y;
                state.viewport.pan_x += dx;
                state.viewport.pan_y += dy;
                next_drag_state = .{ .viewport = .{ .last_x = input.pixMouseX(), .last_y = input.pixMouseY() } };
            } else {
                next_drag_state = .none;
            }
        },
        .info => |inf| {
            if (input.mouse_left_down) {
                state.ui.overlays.info_offset_x = input.mouse_x - inf.start_x;
                state.ui.overlays.info_offset_y = input.mouse_y - inf.start_y;
            } else {
                next_drag_state = .none;
            }
        },
        .stats => |st| {
            if (input.mouse_left_down) {
                state.ui.overlays.stats_offset_x = input.mouse_x - st.start_x;
                state.ui.overlays.stats_offset_y = input.mouse_y - st.start_y;
            } else {
                next_drag_state = .none;
            }
        },
    }

    if (next_drag_state == .none and input.mouse_left_clicked and !palette_closed_this_frame) {
        if (state.ui.palette.mode == .inactive) {
            const is_in_debug_panel = input.isPointerInDebugPanel();
            if (state.ui.overlays.show_info and !is_in_debug_panel and clay.pointerOver(clay.getElementId("InfoCard"))) {
                next_drag_state = .{ .info = .{ .start_x = input.mouse_x - state.ui.overlays.info_offset_x, .start_y = input.mouse_y - state.ui.overlays.info_offset_y } };
            } else if (state.ui.overlays.show_stats and !is_in_debug_panel and clay.pointerOver(clay.getElementId("StatsCard"))) {
                next_drag_state = .{ .stats = .{ .start_x = input.mouse_x - state.ui.overlays.stats_offset_x, .start_y = input.mouse_y - state.ui.overlays.stats_offset_y } };
            } else if (!is_in_debug_panel and clay.pointerOver(clay.getElementId("Viewport"))) {
                next_drag_state = .{ .viewport = .{ .last_x = input.pixMouseX(), .last_y = input.pixMouseY() } };
            }
        }
    }
    state.drag_state = next_drag_state;

    // 2. Mouse Wheel Zoom at cursor
    if (input.scroll_delta_y != 0) {
        if (state.ui.palette.mode == .inactive and !input.isPointerInDebugPanel() and clay.pointerOver(clay.getElementId("Viewport"))) {
            const old_zoom = state.viewport.zoom_factor;
            state.viewport.zoom_factor = state.clampZoomFactor(old_zoom.get() + input.scroll_delta_y * 0.1);
            const ratio = old_zoom.ratioTo(state.viewport.zoom_factor);

            const available_width = if (clay.isDebugModeEnabled()) @max(input.win_w - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0) else input.win_w;
            const cx = available_width / 2.0;
            var title_bar_h: f32 = 60.0;
            if (state.isFullscreen()) {
                title_bar_h = 0;
            }
            const cy = title_bar_h + ((input.win_h - title_bar_h) / 2.0);

            const rel_x = (input.mouse_x - cx) * input.scale_x;
            const rel_y = (input.mouse_y - cy) * input.scale_y;

            state.viewport.pan_x = rel_x - (rel_x - state.viewport.pan_x) * ratio;
            state.viewport.pan_y = rel_y - (rel_y - state.viewport.pan_y) * ratio;
        }
    }
}
