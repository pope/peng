const std = @import("std");
const clay = @import("zclay");
const state_mod = @import("state.zig");
const types_mod = @import("types.zig");
const actions_mod = @import("actions.zig");
const ViewerState = state_mod.ViewerState;
const FrameInput = types_mod.FrameInput;
const AppIntent = @import("intents").AppIntent;

/// System Pass 1: Execute queued discrete intents
pub fn sysExecuteIntents(state: *ViewerState) !void {
    while (state.pending_intents.items.len > 0) {
        const intent = state.pending_intents.orderedRemove(0);
        try actions_mod.executeIntent(state, intent);
    }
}

/// System Pass 2: Update slideshow timer
pub fn sysUpdateSlideshow(state: *ViewerState, delta_time_ms: f64) !void {
    if (state.navigation.slideshow.tick(@floatCast(delta_time_ms))) {
        try state.next();
    }
}

/// System Pass 3: Viewport input processing (Mouse Drag & Scroll-Zoom at Cursor)
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
            const is_in_debug_panel = state.isPointerInDebugPanel(input);
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
        if (state.ui.palette.mode == .inactive and !state.isPointerInDebugPanel(input) and clay.pointerOver(clay.getElementId("Viewport"))) {
            const old_zoom = state.viewport.zoom_factor;
            state.viewport.zoom_factor = state.clampZoomFactor(state.viewport.zoom_factor + input.scroll_delta_y * 0.1);

            const available_width = if (clay.isDebugModeEnabled()) @max(input.win_w - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0) else input.win_w;
            const cx = available_width / 2.0;
            var title_bar_h: f32 = 60.0;
            if (state.isFullscreen()) {
                title_bar_h = 0;
            }
            const cy = title_bar_h + ((input.win_h - title_bar_h) / 2.0);

            const rel_x = (input.mouse_x - cx) * input.scale_x;
            const rel_y = (input.mouse_y - cy) * input.scale_y;

            state.viewport.pan_x = rel_x - (rel_x - state.viewport.pan_x) * (state.viewport.zoom_factor / old_zoom);
            state.viewport.pan_y = rel_y - (rel_y - state.viewport.pan_y) * (state.viewport.zoom_factor / old_zoom);
        }
    }
}

/// System Pass 4: Asset Upload & Preload Pipeline
pub fn sysProcessAssetUploads(state: *ViewerState) void {
    state.updateCurrentRotation();
    state.prepareCacheTextures();
    _ = state.processBackgroundEvents();

    const needs_cache_update = blk: {
        if (state.getCurrentEntry()) |entry| {
            switch (entry.status) {
                .decoding => |d| break :blk !d.has_thread,
                else => break :blk false,
            }
        }
        break :blk (state.navigation.current_index != null);
    };
    if (needs_cache_update and state.active_decode_threads.load(.acquire) < ViewerState.getMaxConcurrentDecodes()) {
        const count = state.navigation.image_list.items.len;
        if (count > 0) {
            if (state.navigation.current_index == null) state.navigation.current_index = 0;
            state.updateCache() catch |err| std.log.err("Failed to update cache: {}", .{err});
        }
    }

    state.checkIdlePreload();
}
