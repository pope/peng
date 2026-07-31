const std = @import("std");
const clay = @import("zclay");
const state_pkg = @import("state");
const ui = @import("ui");
const app = @import("app");
const sdl = @import("sdl");

/// Entry point for loading dynamic UI resources / assets.
pub fn loadAssets() !void {
    clay.cdefs.Clay_ResetMeasureTextCache();
}

/// Entry point for unloading dynamic UI resources / assets upon library reload.
pub fn unloadAssets() void {}

/// Main frame update function encapsulated within the hot-reloadable viewer library.
pub fn updateFrame(
    app_state: *app.state.AppState,
    window: sdl.Window,
    resources: *ui.graphics.GpuResources,
    measure_data: *state_pkg.MeasureTextUserData,
    ipc_server: ?*app.ipc.IpcServer,
    parsed_headless: bool,
    parsed_test_mode: bool,
    frame_arena: *std.heap.ArenaAllocator,
    last_time: *u64,
) !void {
    _ = ipc_server;
    // Re-bind Clay measure text function pointer to the reloaded code address
    clay.setMeasureTextFunction(*const state_pkg.MeasureTextUserData, measure_data, ui.graphics.sdl3MeasureText);

    // 1. Background Event Ingestion System
    const bg_events_processed = app.systems.sysProcessBackgroundEvents(app_state);

    // 2. Socket Command Ingestion System
    app.systems.sysExecuteIpcCommands(app_state);

    // Input Accumulation
    const is_current_loading = blk: {
        if (app_state.getCurrentEntry()) |entry| {
            break :blk (entry.status == .decoding or entry.status == .uploading);
        }
        break :blk (app_state.viewer.navigation.current_index != null);
    };
    const is_busy = app_state.isBusy() or is_current_loading or bg_events_processed;
    const frame_allocator = frame_arena.allocator();
    const input = try app.input.pollFrameInput(
        window,
        frame_allocator,
        last_time,
        app_state.viewer.ui.overlays.mouse_inside,
        app_state.viewer.ui.palette.mode != .inactive,
        parsed_test_mode or parsed_headless,
        is_busy,
    );

    if (input.quit_requested) {
        app_state.viewer.running = false;
    }
    app_state.viewer.ui.overlays.mouse_inside = input.mouse_inside;

    // 3. Logic & Intent Systems (sysExecuteIntents, sysUpdateSlideshow, sysUpdateViewport)
    try app_state.update(input);

    // 4. Asset Upload & Texture Pipeline System
    app.systems.sysProcessAssetUploads(app_state);

    // 5. Cache Slot Management System
    app.systems.sysUpdateCache(app_state) catch |err| std.log.err("Failed to update cache: {}", .{err});

    // 6. Idle Cache Preloading System
    app.systems.sysCheckIdlePreload(app_state);

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
        if (app_state.viewer.ui.overlays.show_info and !input.isPointerInDebugPanel() and clay.pointerOver(clay.getElementId("InfoCloseBtn"))) {
            app_state.viewer.ui.overlays.show_info = false;
        }
        if (app_state.viewer.ui.overlays.show_stats and !input.isPointerInDebugPanel() and clay.pointerOver(clay.getElementId("StatsCloseBtn"))) {
            app_state.viewer.ui.overlays.show_stats = false;
        }
    }

    // Construct view parameters and UI view model snapshots
    const view_params = state_pkg.ViewParams{
        .viewport = app_state.viewer.viewport,
        .win_w = input.win_w,
        .win_h = input.win_h,
        .scale_x = input.scale_x,
        .scale_y = input.scale_y,
        .is_fullscreen = app_state.viewer.isFullscreen(),
    };

    if (app_state.gpu_device == null) return error.GpuNotInitialized;

    app.systems.sysSyncMetrics(app_state);

    const ui_model = state_pkg.UiViewModel{
        .is_fullscreen = app_state.viewer.isFullscreen(),
        .total_images = app_state.viewer.navigation.image_list.items.len,
        .image_list = app_state.viewer.navigation.image_list.items,
        .current_index = app_state.viewer.navigation.current_index,
        .current_image_path = if (app_state.viewer.navigation.current_index) |idx|
            if (idx < app_state.viewer.navigation.image_list.items.len) app_state.viewer.navigation.image_list.items[idx] else null
        else
            null,
        .current_entry = app_state.getCurrentEntry(),
        .is_loading_files = app_state.viewer.navigation.is_loading_files.load(.acquire),
        .slideshow = app_state.viewer.navigation.slideshow,
        .overlays = app_state.viewer.ui.overlays,
        .metrics = &app_state.viewer.ui.metrics,
        .viewport = app_state.viewer.viewport,
        .palette = &app_state.viewer.ui.palette,
        .display = &app_state.viewer.display,
        .total_vram_bytes = app_state.viewer.stats.total_vram_bytes,
        .cached_slot_count = app_state.viewer.stats.cached_slot_count,
        .gpa_allocator = app_state.allocator,
        .io = app_state.io,
        .cache_slot_map = &app_state.cache,
        .navigation = &app_state.viewer.navigation,
        .pending_intents = &app_state.pending_intents,
        .debug_show_thumb = app_state.viewer.ui.overlays.debug_show_thumb,
        .stats = app_state.viewer.stats,
    };

    // Skip layout construction and rendering if state is clean and idle
    const is_dirty = app_state.viewer.dirty or
        input.mouse_left_down or input.mouse_left_clicked or
        input.scroll_delta_x != 0 or input.scroll_delta_y != 0 or
        input.keys_pressed.items.len > 0 or input.text_input != null or
        input.dropped_path != null or app_state.viewer.navigation.slideshow == .active or
        app_state.viewer.ui.palette.mode != .inactive or app_state.viewer.ui.screenshot_mode != .idle;

    if (!is_dirty and !parsed_test_mode and !parsed_headless) {
        return;
    }

    // Draw / Render
    const capture_filename = switch (app_state.viewer.ui.screenshot_mode) {
        .idle => null,
        .capturing => |s| s.path,
    };
    ui.layout.renderFrame(view_params, ui_model, resources, input, frame_allocator, resources.fonts[0..], measure_data, capture_filename) catch |err| {
        app_state.handleScreenshotPostRender(err);
        return err;
    };
    app_state.handleScreenshotPostRender(null);
    app_state.viewer.dirty = false;
}

//////////////////////////////////////////////////////////////////////////////
// C Exports for Hot Reloading Dynamic Library Boundary

export fn viewer_load_assets() callconv(.c) void {
    loadAssets() catch |err| {
        std.log.err("Failed to load assets: {}", .{err});
    };
}

export fn viewer_unload_assets() callconv(.c) void {
    unloadAssets();
}

export fn viewer_update(
    app_state: *app.state.AppState,
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
    const measure_data: *state_pkg.MeasureTextUserData = @ptrCast(@alignCast(measure_data_ptr));
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
