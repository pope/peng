const std = @import("std");
const clay = @import("zclay");
const ui = @import("ui");
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
    _ = ipc_server;
    // Re-bind Clay measure text function pointer to the reloaded code address
    clay.setMeasureTextFunction(*const app.types.MeasureTextUserData, measure_data, ui.graphics.sdl3MeasureText);

    const frame_allocator = frame_arena.allocator();
    const bg_events_processed = state.processBackgroundEvents();

    // Input Accumulation
    const is_current_loading = blk: {
        if (state.getCurrentEntry()) |entry| {
            break :blk (entry.status == .decoding or entry.status == .uploading);
        }
        break :blk (state.navigation.current_index != null);
    };
    const is_busy = state.navigation.is_loading_files.load(.acquire) or (state.active_threads.load(.acquire) > 0) or is_current_loading or bg_events_processed or state.isSlideshowActive();
    const input = try app.input.pollFrameInput(
        window,
        frame_allocator,
        last_time,
        state.ui.overlays.mouse_inside,
        state.ui.palette.mode != .inactive,
        parsed_test_mode or parsed_headless,
        is_busy,
    );

    if (input.quit_requested) {
        state.running = false;
    }
    state.ui.overlays.mouse_inside = input.mouse_inside;

    // Process any pending IPC commands collected during event processing
    state.processIpcCommands(app.actions.handleIpcCommand);

    // Stage 1: Asset Uploads & Preload Pre-pass
    app.systems.sysProcessAssetUploads(state);

    // Stage 2: System Ticks & State Updates (Execute intents, update slideshow, update viewport)
    try state.update(input);

    // Stage 3: Clay Pointer & Scroll State Updates
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

    if (input.mouse_left_clicked) {
        if (state.ui.overlays.show_info and !state.isPointerInDebugPanel(input) and clay.pointerOver(clay.getElementId("InfoCloseBtn"))) {
            state.ui.overlays.show_info = false;
        }
        if (state.ui.overlays.show_stats and !state.isPointerInDebugPanel(input) and clay.pointerOver(clay.getElementId("StatsCloseBtn"))) {
            state.ui.overlays.show_stats = false;
        }
    }

    // Construct view parameters and UI view model snapshots
    const view_params = app.types.ViewParams{
        .viewport = state.viewport,
        .win_w = input.win_w,
        .win_h = input.win_h,
        .scale_x = input.scale_x,
        .scale_y = input.scale_y,
        .is_fullscreen = state.isFullscreen(),
    };

    const gpu_res = if (state.gpu) |*g| g else return error.GpuNotInitialized;

    const ui_model = app.types.UiViewModel{
        .is_fullscreen = state.isFullscreen(),
        .total_images = state.navigation.image_list.items.len,
        .current_index = state.navigation.current_index,
        .current_image_path = if (state.navigation.current_index) |idx|
            if (idx < state.navigation.image_list.items.len) state.navigation.image_list.items[idx] else null
        else
            null,
        .current_entry = state.getCurrentEntry(),
        .is_loading_files = state.navigation.is_loading_files.load(.acquire),
        .slideshow = state.navigation.slideshow,
        .overlays = state.ui.overlays,
        .metrics = &state.ui.metrics,
        .viewport = state.viewport,
        .palette = &state.ui.palette,
        .display = &state.display,
        .gpa_allocator = state.allocator,
        .io = state.io,
        .cache_slot_map = &state.cache,
        .navigation = &state.navigation,
        .pending_intents = &state.pending_intents,
        .current_image_cache_hit = state.current_image_cache_hit,
        .debug_show_thumb = state.ui.overlays.debug_show_thumb,
    };

    // Draw / Render
    const capture_filename = switch (state.ui.screenshot_mode) {
        .idle => null,
        .capturing => |s| s.path,
    };
    ui.layout.renderFrame(view_params, ui_model, gpu_res, input, frame_allocator, resources.fonts[0..], measure_data, capture_filename) catch |err| {
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
