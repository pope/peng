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
    state: *app.state.ViewerState,
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
    const bg_events_processed = app.systems.sysProcessBackgroundEvents(state);

    // 2. Socket Command Ingestion System
    app.systems.sysExecuteIpcCommands(state);

    // Input Accumulation
    const is_current_loading = blk: {
        if (state.getCurrentEntry()) |entry| {
            break :blk (entry.status == .decoding or entry.status == .uploading);
        }
        break :blk (state.navigation.current_index != null);
    };
    const is_busy = state.isBusy() or is_current_loading or bg_events_processed;
    const frame_allocator = frame_arena.allocator();
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

    // 3. Logic & Intent Systems (sysExecuteIntents, sysUpdateSlideshow, sysUpdateViewport)
    try state.update(input);

    // 4. Asset Upload & Texture Pipeline System
    app.systems.sysProcessAssetUploads(state);

    // 5. Cache Slot Management System
    app.systems.sysUpdateCache(state) catch |err| std.log.err("Failed to update cache: {}", .{err});

    // 6. Idle Cache Preloading System
    app.systems.sysCheckIdlePreload(state);

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
        if (state.ui.overlays.show_info and !input.isPointerInDebugPanel() and clay.pointerOver(clay.getElementId("InfoCloseBtn"))) {
            state.ui.overlays.show_info = false;
        }
        if (state.ui.overlays.show_stats and !input.isPointerInDebugPanel() and clay.pointerOver(clay.getElementId("StatsCloseBtn"))) {
            state.ui.overlays.show_stats = false;
        }
    }

    // Construct view parameters and UI view model snapshots
    const view_params = state_pkg.ViewParams{
        .viewport = state.viewport,
        .win_w = input.win_w,
        .win_h = input.win_h,
        .scale_x = input.scale_x,
        .scale_y = input.scale_y,
        .is_fullscreen = state.isFullscreen(),
    };

    if (state.gpu_device == null) return error.GpuNotInitialized;

    app.systems.sysSyncMetrics(state);

    const ui_model = state_pkg.UiViewModel{
        .is_fullscreen = state.isFullscreen(),
        .total_images = state.navigation.image_list.items.len,
        .image_list = state.navigation.image_list.items,
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
        .total_vram_bytes = state.stats.total_vram_bytes,
        .cached_slot_count = state.stats.cached_slot_count,
        .gpa_allocator = state.allocator,
        .io = state.io,
        .cache_slot_map = &state.cache,
        .navigation = &state.navigation,
        .pending_intents = &state.pending_intents,
        .debug_show_thumb = state.ui.overlays.debug_show_thumb,
        .stats = state.stats,
    };

    // Skip layout construction and rendering if state is clean and idle
    const is_dirty = state.dirty or
        input.mouse_left_down or input.mouse_left_clicked or
        input.scroll_delta_x != 0 or input.scroll_delta_y != 0 or
        input.keys_pressed.items.len > 0 or input.text_input != null or
        input.dropped_path != null or state.navigation.slideshow == .active or
        state.ui.palette.mode != .inactive or state.ui.screenshot_mode != .idle;

    if (!is_dirty and !parsed_test_mode and !parsed_headless) {
        return;
    }

    // Draw / Render
    const capture_filename = switch (state.ui.screenshot_mode) {
        .idle => null,
        .capturing => |s| s.path,
    };
    ui.layout.renderFrame(view_params, ui_model, resources, input, frame_allocator, resources.fonts[0..], measure_data, capture_filename) catch |err| {
        state.handleScreenshotPostRender(err);
        return err;
    };
    state.handleScreenshotPostRender(null);
    state.dirty = false;
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
