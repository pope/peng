const std = @import("std");
const clay = @import("zclay");
const ui = @import("ui");
const commands = @import("commands");
const app = @import("app");
const sdl = @import("sdl");

/// Entry point for loading dynamic UI resources / assets.
pub fn loadAssets(state: *app.state.ViewerState) !void {
    if (state.gpu) |*gpu_res| {
        gpu_res.text_cache.clearAll(state.allocator, gpu_res.device);
    }
    clay.cdefs.Clay_ResetMeasureTextCache();
}

/// Entry point for unloading dynamic UI resources / assets upon library reload.
pub fn unloadAssets(state: *app.state.ViewerState) void {
    if (state.gpu) |*gpu_res| {
        gpu_res.text_cache.clearAll(state.allocator, gpu_res.device);
    }
}

/// Main frame update function encapsulated within the hot-reloadable viewer library.
pub fn updateFrame(
    state: *app.state.ViewerState,
    window: sdl.Window,
    resources: *ui.graphics.GpuResources,
    measure_data: *app.types.MeasureTextUserData,
    ipc_server: ?*app.ipc.IpcServer,
    parsed_headless: bool,
    parsed_test_mode: bool,
    frame_arena: *std.heap.ArenaAllocator,
    last_time: *u64,
) !void {
    // Re-bind Clay measure text function pointer to the reloaded code address
    clay.setMeasureTextFunction(*const app.types.MeasureTextUserData, measure_data, ui.graphics.sdl3MeasureText);

    const frame_allocator = frame_arena.allocator();
    const bg_events_processed = state.processBackgroundEvents();

    // Input Accumulation
    const is_current_loading = blk: {
        if (state.getCurrentEntry()) |entry| {
            break :blk (entry.status == .decoding or entry.status == .uploading);
        }
        break :blk (state.current_index != null);
    };
    const is_busy = state.is_loading_files.load(.acquire) or (state.active_threads.load(.acquire) > 0) or is_current_loading or bg_events_processed or state.isSlideshowActive();
    const input = try app.input.pollFrameInput(
        window,
        frame_allocator,
        last_time,
        state.overlays.mouse_inside,
        state.palette.mode != .inactive,
        parsed_test_mode or parsed_headless,
        is_busy,
    );

    if (input.quit_requested) {
        state.running = false;
    }
    state.overlays.mouse_inside = input.mouse_inside;

    // Process any pending IPC commands collected during event processing
    state.processIpcCommands(ipc_server);

    // State Update
    const needs_cache_update = blk: {
        if (state.getCurrentEntry()) |entry| {
            switch (entry.status) {
                .decoding => |d| break :blk !d.has_thread,
                else => break :blk false,
            }
        }
        break :blk (state.current_index != null);
    };
    if (needs_cache_update and state.active_decode_threads.load(.acquire) < app.state.ViewerState.getMaxConcurrentDecodes()) {
        const count = state.image_list.items.len;
        if (count > 0) {
            if (state.current_index == null) state.current_index = 0;
            state.updateCache() catch |err| std.log.err("Failed to update cache: {}", .{err});
        }
    }

    try state.update(input);

    // Process any queued user actions
    for (state.action_queue.items) |action_id| {
        commands.actions.triggerAction(state, action_id) catch |err| {
            std.log.err("Failed to execute queued action {s}: {any}", .{ @tagName(action_id), err });
        };
    }
    state.action_queue.clearRetainingCapacity();

    clay.setLayoutDimensions(.{ .w = input.win_w, .h = input.win_h });

    if (input.mouse_inside) {
        clay.setPointerState(
            .{ .x = input.mouse_x, .y = input.mouse_y },
            input.mouse_left_down,
        );
    } else {
        clay.setPointerState(
            .{ .x = -1.0, .y = -1.0 },
            false,
        );
    }

    clay.updateScrollContainers(
        true,
        .{ .x = input.scroll_delta_x, .y = input.scroll_delta_y },
        input.delta_time_ms / 1000.0,
    );

    state.checkIdlePreload();

    if (input.mouse_left_clicked) {
        if (state.overlays.show_info and !state.isPointerInDebugPanel(input) and clay.pointerOver(clay.getElementId("InfoCloseBtn"))) {
            state.overlays.show_info = false;
        }
        if (state.overlays.show_stats and !state.isPointerInDebugPanel(input) and clay.pointerOver(clay.getElementId("StatsCloseBtn"))) {
            state.overlays.show_stats = false;
        }
    }

    // Draw / Render
    const capture_filename = switch (state.screenshot_mode) {
        .idle => null,
        .capturing => |s| s.path,
    };
    ui.layout.renderFrame(state, input, frame_allocator, resources.fonts[0..], measure_data, capture_filename) catch |err| {
        state.handleScreenshotPostRender(err);
        return err;
    };
    state.handleScreenshotPostRender(null);
}

//////////////////////////////////////////////////////////////////////////////
// C Exports for Hot Reloading Dynamic Library Boundary

export fn viewer_load_assets(app_state: *app.state.ViewerState) callconv(.c) void {
    loadAssets(app_state) catch |err| {
        std.log.err("Failed to load assets: {}", .{err});
    };
}

export fn viewer_unload_assets(app_state: *app.state.ViewerState) callconv(.c) void {
    unloadAssets(app_state);
}

export fn viewer_update(
    app_state: *app.state.ViewerState,
    window_ptr: *anyopaque,
    resources_ptr: *anyopaque,
    measure_data_ptr: *anyopaque,
    ipc_server_ptr: ?*anyopaque,
    parsed_headless: bool,
    parsed_test_mode: bool,
    frame_arena_ptr: *anyopaque,
    last_time_ptr: *u64,
) callconv(.c) void {
    const window: sdl.Window = .{ .ptr = @ptrCast(@alignCast(window_ptr)) };
    const resources: *ui.graphics.GpuResources = @ptrCast(@alignCast(resources_ptr));
    const measure_data: *app.types.MeasureTextUserData = @ptrCast(@alignCast(measure_data_ptr));
    const ipc_server: ?*app.ipc.IpcServer = if (ipc_server_ptr) |ptr| @ptrCast(@alignCast(ptr)) else null;
    const frame_arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(frame_arena_ptr));

    updateFrame(
        app_state,
        window,
        resources,
        measure_data,
        ipc_server,
        parsed_headless,
        parsed_test_mode,
        frame_arena,
        last_time_ptr,
    ) catch |err| {
        std.log.err("Viewer update frame error: {}", .{err});
    };
}
