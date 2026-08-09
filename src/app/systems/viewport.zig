const std = @import("std");
const clay = @import("zclay");
const state_pkg = @import("state");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;
const FrameContext = @import("root.zig").FrameContext;

/// System Pass: Viewport input processing (Mouse Drag & Scroll-Zoom at Cursor)
pub fn sysUpdateViewport(ctx: FrameContext, palette_closed_this_frame: bool) void {
    const state = ctx.state;
    const input = ctx.input orelse return;

    // 1. Mouse Drag state machine
    var next_drag_state = state.viewer.drag_state;
    switch (next_drag_state) {
        .none => {},
        .viewport => |v| {
            if (input.mouse_left_down) {
                const dx = input.pixMouseX() - v.last_x;
                const dy = input.pixMouseY() - v.last_y;
                switch (state.viewer.navigation.view_mode) {
                    .comics_strip => switch (state.viewer.viewport.fit_mode) {
                        .fit_height => {
                            state.viewer.viewport.pan_x += if (state.viewer.navigation.manga_mode) dx else -dx;
                            state.viewer.viewport.pan_y += dy;
                        },
                        else => {
                            state.viewer.viewport.pan_x += dx;
                            state.viewer.viewport.pan_y -= dy;
                        },
                    },
                    else => {
                        state.viewer.viewport.pan_x += dx;
                        state.viewer.viewport.pan_y += dy;
                    },
                }
                next_drag_state = .{ .viewport = .{ .last_x = input.pixMouseX(), .last_y = input.pixMouseY() } };
            } else {
                next_drag_state = .none;
            }
        },
        .info => |inf| {
            if (input.mouse_left_down) {
                state.viewer.ui.overlays.info_offset_x = input.mouse_x - inf.start_x;
                state.viewer.ui.overlays.info_offset_y = input.mouse_y - inf.start_y;
            } else {
                next_drag_state = .none;
            }
        },
        .stats => |st| {
            if (input.mouse_left_down) {
                state.viewer.ui.overlays.stats_offset_x = input.mouse_x - st.start_x;
                state.viewer.ui.overlays.stats_offset_y = input.mouse_y - st.start_y;
            } else {
                next_drag_state = .none;
            }
        },
    }

    if (next_drag_state == .none and input.mouse_left_clicked and !palette_closed_this_frame) {
        if (state.viewer.ui.palette.mode == .inactive) {
            const is_in_debug_panel = input.isPointerInDebugPanel();
            if (state.viewer.ui.overlays.show_info and !is_in_debug_panel and clay.pointerOver(clay.getElementId("InfoCard"))) {
                next_drag_state = .{ .info = .{ .start_x = input.mouse_x - state.viewer.ui.overlays.info_offset_x, .start_y = input.mouse_y - state.viewer.ui.overlays.info_offset_y } };
            } else if (state.viewer.ui.overlays.show_stats and !is_in_debug_panel and clay.pointerOver(clay.getElementId("StatsCard"))) {
                next_drag_state = .{ .stats = .{ .start_x = input.mouse_x - state.viewer.ui.overlays.stats_offset_x, .start_y = input.mouse_y - state.viewer.ui.overlays.stats_offset_y } };
            } else if (!is_in_debug_panel and clay.pointerOver(clay.getElementId("Viewport"))) {
                next_drag_state = .{ .viewport = .{ .last_x = input.pixMouseX(), .last_y = input.pixMouseY() } };
            }
        }
    }
    state.viewer.drag_state = next_drag_state;

    // 2. Mouse Wheel & Touchpad Scroll Panning
    const has_scroll_x = input.scroll_delta_x != 0.0;
    const has_scroll_y = input.scroll_delta_y != 0.0;
    const is_ctrl_down = input.key_modifiers.ctrl;

    if ((has_scroll_x or has_scroll_y) and !is_ctrl_down) {
        if (state.viewer.ui.palette.mode == .inactive and !input.isPointerInDebugPanel() and clay.pointerOver(clay.getElementId("Viewport"))) {
            switch (state.viewer.navigation.view_mode) {
                .comics_strip => {
                    const speed: f32 = 15.0;
                    switch (state.viewer.viewport.fit_mode) {
                        .fit_height => {
                            const scroll_dist = input.scroll_delta_y * input.scale_x * speed;
                            state.viewer.viewport.pan_x += if (state.viewer.navigation.manga_mode) scroll_dist else -scroll_dist;
                            state.viewer.viewport.pan_y += input.scroll_delta_x * input.scale_y * speed;
                        },
                        else => {
                            state.viewer.viewport.pan_y -= input.scroll_delta_y * input.scale_y * speed;
                            state.viewer.viewport.pan_x += input.scroll_delta_x * input.scale_x * speed;
                        },
                    }
                },
                else => {
                    state.viewer.viewport.pan_x += input.scroll_delta_x * input.scale_x * 5.0;
                    state.viewer.viewport.pan_y += input.scroll_delta_y * input.scale_y * 5.0;
                },
            }
        }
    }

    // 3. Touch Pinch & Ctrl+Scroll Zoom at cursor / touch midpoint
    const has_pinch = input.pinch_delta != 0.0;
    const is_ctrl_scroll = is_ctrl_down and has_scroll_y;
    if (has_pinch or is_ctrl_scroll) {
        if (state.viewer.ui.palette.mode == .inactive and !input.isPointerInDebugPanel() and clay.pointerOver(clay.getElementId("Viewport"))) {
            const old_zoom = state.viewer.viewport.zoom_factor;

            const zoom_delta = if (has_pinch)
                input.pinch_delta * 0.5
            else
                input.scroll_delta_y * 0.1;

            const new_zoom = state.clampZoomFactor(old_zoom.get() + zoom_delta);

            const focus_x = if (has_pinch) input.pinch_center_x * input.scale_x else input.pixMouseX();
            const focus_y = if (has_pinch) input.pinch_center_y * input.scale_y else input.pixMouseY();

            const available_width = if (clay.isDebugModeEnabled()) @max(input.win_w - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0) else input.win_w;
            const cx = available_width / 2.0;
            var title_bar_h: f32 = 60.0;
            if (state.viewer.isFullscreen()) {
                title_bar_h = 0;
            }
            const cy = title_bar_h + ((input.win_h - title_bar_h) / 2.0);

            state.viewer.viewport.zoomAtPoint(new_zoom, focus_x, focus_y, cx * input.scale_x, cy * input.scale_y);
        }
    }

    // 4. Continuous Comics Mode layout recalculation & boundary clamping
    const nav = &state.viewer.navigation;
    state.viewer.viewport.view_mode = nav.view_mode;
    if (nav.view_mode == .comics_strip) {
        state_pkg.view_transform.recalculateStripSpans(
            &nav.strip_spans,
            nav.image_list.items.len,
            appStateCacheLookup,
            state,
            nav.known_aspect_ratios.items,
            input.win_w,
            input.win_h,
            state.viewer.viewport.fit_mode,
            state.allocator,
        ) catch |err| std.log.err("Failed to recalculate strip spans: {}", .{err});

        const total_len = if (nav.strip_spans.items.len > 0)
            nav.strip_spans.items[nav.strip_spans.items.len - 1].endOffset()
        else
            0.0;

        var title_bar_h: f32 = 60.0;
        if (state.viewer.isFullscreen()) {
            title_bar_h = 0.0;
        }

        const is_horizontal = (state.viewer.viewport.fit_mode == .fit_height);
        const content_h = input.win_h - (if (is_horizontal) 0.0 else title_bar_h);

        state_pkg.view_transform.clampComicsViewportPan(
            &state.viewer.viewport.pan_x,
            &state.viewer.viewport.pan_y,
            input.win_w,
            content_h,
            total_len,
            state.viewer.viewport.fit_mode,
            state.viewer.viewport.zoom_factor.get(),
        );

        const view_min = if (is_horizontal) state.viewer.viewport.pan_x else state.viewer.viewport.pan_y;
        const view_max = view_min + (if (is_horizontal) input.win_w else content_h);

        nav.visible_frustum = state_pkg.view_transform.findVisibleFrustum(nav.strip_spans.items, view_min, view_max);

        // Synchronize current_index to the image dominating the viewport center
        if (nav.strip_spans.items.len > 0) {
            const center = view_min + (view_max - view_min) / 2.0;
            for (nav.strip_spans.items, 0..) |span, idx| {
                if (span.start_offset <= center and center < span.endOffset()) {
                    nav.current_index = idx;
                    break;
                }
            }
        }
    }
}

fn appStateCacheLookup(ctx: ?*const anyopaque, idx: usize) ?state_pkg.CacheEntry {
    if (ctx) |ptr| {
        const state: *AppState = @ptrCast(@alignCast(@constCast(ptr)));
        return state.getEntryForIndex(idx);
    }
    return null;
}
