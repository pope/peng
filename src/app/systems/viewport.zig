const app_state = @import("../state.zig");
const clay = @import("zclay");
const context = @import("context.zig");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;

/// System Pass: Viewport input processing (Mouse Drag & Scroll-Zoom at Cursor)
pub fn sysUpdateViewport(
    ctx: FrameContext,
    palette_closed_this_frame: bool,
) void {
    const state = ctx.state;
    const input = ctx.input orelse return;

    const palette_blocking = state.viewer.ui.palette.isAcceptingInput() or
        palette_closed_this_frame;

    // 1. Mouse Drag state machine
    var next_drag_state = state.viewer.drag_state;
    switch (next_drag_state) {
        .none => {},
        .slider => {},
        .viewport => |v| {
            if (input.mouse_left_down and !palette_blocking) {
                const dx = input.pixMouseX() - v.last_x;
                const dy = input.pixMouseY() - v.last_y;
                state.viewer.viewport.pan_x += dx;
                state.viewer.viewport.pan_y += dy;
                next_drag_state = .{
                    .viewport = .{
                        .last_x = input.pixMouseX(),
                        .last_y = input.pixMouseY(),
                    },
                };
            } else {
                next_drag_state = .none;
            }
        },
        .info => |inf| {
            if (input.mouse_left_down and
                !palette_blocking and
                state.viewer.ui.overlays.info_panel.visible)
            {
                state.viewer.ui.overlays.info_panel.offset_x =
                    input.mouse_x - inf.start_x;
                state.viewer.ui.overlays.info_panel.offset_y =
                    input.mouse_y - inf.start_y;
            } else {
                next_drag_state = .none;
            }
        },
        .stats => |st| {
            if (input.mouse_left_down and
                !palette_blocking and
                state.viewer.ui.overlays.stats_panel.visible)
            {
                state.viewer.ui.overlays.stats_panel.offset_x =
                    input.mouse_x - st.start_x;
                state.viewer.ui.overlays.stats_panel.offset_y =
                    input.mouse_y - st.start_y;
            } else {
                next_drag_state = .none;
            }
        },
    }

    if (next_drag_state == .none and input.mouse_left_clicked and
        !palette_blocking)
    {
        const is_in_debug_panel = input.isPointerInDebugPanel();
        const over_close_btn = !is_in_debug_panel and
            ((state.viewer.ui.overlays.info_panel.visible and
                clay.pointerOver(clay.getElementId("InfoCloseBtn"))) or
                (state.viewer.ui.overlays.stats_panel.visible and
                    clay.pointerOver(clay.getElementId("StatsCloseBtn"))));
        const over_info = state.viewer.ui.overlays.info_panel.visible and
            !is_in_debug_panel and
            clay.pointerOver(clay.getElementId("InfoOverlayCard"));
        const over_stats = state.viewer.ui.overlays.stats_panel.visible and
            !is_in_debug_panel and
            clay.pointerOver(clay.getElementId("StatsPanel"));
        const over_edit = (state.viewer.ui.overlays.edit_panel.visible or
            state.viewer.animations.get(.edit_panel) > 0.001) and
            !is_in_debug_panel and
            clay.pointerOver(clay.getElementId("EditSidePanel"));

        if (over_close_btn) {
            // Handled in sysProcessUiInteractions
        } else if (over_info) {
            const off_x = state.viewer.ui.overlays.info_panel.offset_x;
            const off_y = state.viewer.ui.overlays.info_panel.offset_y;
            next_drag_state = .{
                .info = .{
                    .start_x = input.mouse_x - off_x,
                    .start_y = input.mouse_y - off_y,
                },
            };
        } else if (over_stats) {
            const off_x = state.viewer.ui.overlays.stats_panel.offset_x;
            const off_y = state.viewer.ui.overlays.stats_panel.offset_y;
            next_drag_state = .{
                .stats = .{
                    .start_x = input.mouse_x - off_x,
                    .start_y = input.mouse_y - off_y,
                },
            };
        } else if (over_edit) {
            // Handled in sysProcessUiInteractions
        } else {
            next_drag_state = .{
                .viewport = .{
                    .last_x = input.pixMouseX(),
                    .last_y = input.pixMouseY(),
                },
            };
        }
    }
    state.viewer.drag_state = next_drag_state;

    // Synchronize viewport zoom factor when tracking active preset
    // (.fit / .fill)
    if (state.viewer.viewport.mode != .manual) {
        state.viewer.viewport.zoom_factor =
            state_pkg.ZoomFactor.init(state.getBaseScale());
    }

    // 2. Mouse Wheel & Touchpad Scroll Panning
    const has_scroll_x = input.scroll_delta_x != 0.0;
    const has_scroll_y = input.scroll_delta_y != 0.0;
    const is_ctrl_down = input.key_modifiers.ctrl;
    const over_viewport = !state.viewer.ui.palette.isAcceptingInput() and
        !input.isPointerInDebugPanel() and
        clay.pointerOver(clay.getElementId("Viewport"));

    if ((has_scroll_x or has_scroll_y) and !is_ctrl_down) {
        if (over_viewport) {
            state.viewer.viewport.pan_x +=
                input.scroll_delta_x * input.scale_x * 5.0;
            state.viewer.viewport.pan_y +=
                input.scroll_delta_y * input.scale_y * 5.0;
        }
    }

    // 3. Touch Pinch & Ctrl+Scroll Zoom at cursor / touch midpoint
    const has_pinch = input.pinch_delta != 0.0;
    const is_ctrl_scroll = is_ctrl_down and has_scroll_y;
    if (has_pinch or is_ctrl_scroll) {
        if (over_viewport) {
            const old_zoom = if (state.viewer.viewport.mode == .manual)
                state.viewer.viewport.zoom_factor
            else
                state_pkg.clampZoomFactor(state.getBaseScale());

            const zoom_mult = if (has_pinch)
                @max(0.01, 1.0 + input.pinch_delta * 0.5)
            else
                @exp(input.scroll_delta_y * 0.05);

            const new_zoom =
                state_pkg.clampZoomFactor(old_zoom.get() * zoom_mult);

            const scale = input.dpiScale();
            const focus = if (has_pinch)
                (state_pkg.LogicalPoint{
                    .x = input.pinch_center_x,
                    .y = input.pinch_center_y,
                }).toPhysical(scale)
            else
                input.physicalMousePos();

            const vp_data = clay.getElementData(clay.getElementId("Viewport"));
            const logical_center: state_pkg.LogicalPoint = if (vp_data.found) .{
                .x = vp_data.bounding_box.x + vp_data.bounding_box.width * 0.5,
                .y = vp_data.bounding_box.y + vp_data.bounding_box.height * 0.5,
            } else blk: {
                const debug_w: f32 = if (clay.isDebugModeEnabled())
                    @as(f32, @floatFromInt(clay.Clay__debugViewWidth))
                else
                    0.0;
                const edit_progress = state.viewer.animations.get(.edit_panel);
                const edit_open = state.viewer.ui.overlays.edit_panel.visible;
                const docked_w: f32 = if (edit_open or edit_progress > 0.001)
                    state_pkg.EDIT_PANEL_WIDTH * edit_progress
                else
                    0.0;
                const available_width =
                    @max(input.win_w - debug_w - docked_w, 1.0);
                break :blk .{
                    .x = available_width * 0.5,
                    .y = input.win_h * 0.5,
                };
            };

            state.viewer.viewport.zoomAtPoint(
                new_zoom,
                focus,
                logical_center.toPhysical(scale),
            );
        }
    }
}

test "sysUpdateViewport cancels active panel drag when panel hides" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.ui.overlays.info_panel.visible = false;
    app_st.viewer.drag_state = .{
        .info = .{ .start_x = 10.0, .start_y = 20.0 },
    };

    const frame_input = state_pkg.FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 50.0,
        .mouse_y = 60.0,
        .mouse_left_down = true,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };

    sysUpdateViewport(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    }, false);

    try std.testing.expectEqual(
        state_pkg.DragState.none,
        app_st.viewer.drag_state,
    );
}
