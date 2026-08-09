const std = @import("std");
const clay = @import("zclay");
const state_pkg = @import("state");
const ui = @import("ui");
const app = @import("app");
const ipc = @import("ipc");
const input_pkg = @import("input");
const sdl = @import("sdl");

/// Entry point for loading dynamic UI resources / assets.
pub fn loadAssets() !void {
    clay.cdefs.Clay_ResetMeasureTextCache();
}

/// Entry point for unloading dynamic UI resources / assets upon library reload.
pub fn unloadAssets() void {}

fn viewerCacheLookup(ctx: *anyopaque, idx: usize) ?state_pkg.CacheEntry {
    const app_st: *app.state.AppState = @ptrCast(@alignCast(ctx));
    return app_st.getEntryForIndex(idx);
}

/// Sequential execution of all systems during the Update Phase of the event loop.
/// Guaranteed: All systems run in deterministic order, use frame_allocator, and do NOT call each other.
pub fn runUpdatePhase(
    app_state: *app.state.AppState,
    input: state_pkg.FrameInput,
    frame_allocator: std.mem.Allocator,
) !void {
    const ctx = app.systems.FrameContext{
        .state = app_state,
        .frame_allocator = frame_allocator,
        .input = input,
        .delta_time_ms = input.delta_time_ms,
    };

    // Socket Command Ingestion System (parses IPC commands -> pending_intents)
    app.systems.sysExecuteIpcCommands(ctx);

    // Keyboard Input System (maps keypresses -> pending_intents)
    try app.systems.sysProcessInput(ctx);

    // Command Palette Input System (typing query updates, selection, click-outside)
    const palette_closed_this_frame = try app.systems.sysProcessPaletteInput(ctx);

    // Viewport & Motion Systems (mouse drag/zoom & slideshow timer)
    app.systems.sysUpdateViewport(ctx, palette_closed_this_frame);
    try app.systems.sysUpdateSlideshow(ctx);

    // Execute All Ingested & Generated Intents (IPC, Keyboard, Palette & Slideshow intents)
    try app.systems.sysExecuteIntents(ctx);

    // Asset Upload & Texture Pipeline System
    app.systems.sysProcessAssetUploads(ctx);

    // Cache Slot Management System (evicts slots & spawns prefetch workers)
    app.systems.sysUpdateCache(ctx) catch |err| std.log.err("Failed to update cache: {}", .{err});

    // Metrics & Telemetry System
    app.systems.sysSyncMetrics(ctx);
}

/// Main frame update function encapsulated within the hot-reloadable viewer library.
pub fn updateFrame(
    app_state: *app.state.AppState,
    window: sdl.Window,
    resources: *ui.graphics.GpuResources,
    measure_data: *state_pkg.MeasureTextUserData,
    ipc_server: ?*ipc.IpcServer,
    parsed_headless: bool,
    parsed_test_mode: bool,
    frame_arena: *std.heap.ArenaAllocator,
    last_time: *u64,
) !void {
    _ = ipc_server;
    // Re-bind Clay measure text function pointer to the reloaded code address
    clay.setMeasureTextFunction(*const state_pkg.MeasureTextUserData, measure_data, ui.graphics.sdl3MeasureText);

    // Phase 1: Background Event & Input Ingestion
    const bg_events_processed = app.drainWorkerEvents(app_state);

    const is_current_loading = blk: {
        if (app_state.getCurrentEntry()) |entry| {
            break :blk (entry.status == .decoding or entry.status == .uploading);
        }
        break :blk (app_state.viewer.navigation.current_index != null);
    };
    const has_unpopulated_cache = blk: {
        const len = app_state.viewer.navigation.image_list.items.len;
        if (len <= 1) break :blk false;
        break :blk (app_state.cache.count() < @min(5, len));
    };
    const cur_win_size = window.getSize();
    const cur_win_w = @as(f32, @floatFromInt(cur_win_size.w));
    const cur_win_h = @as(f32, @floatFromInt(cur_win_size.h));
    const window_resized = (app_state.viewer.ui.overlays.last_win_w != 0 and (app_state.viewer.ui.overlays.last_win_w != cur_win_w or app_state.viewer.ui.overlays.last_win_h != cur_win_h));
    const is_busy = app_state.isBusy() or is_current_loading or bg_events_processed or (app_state.viewer.drag_state != .none) or has_unpopulated_cache or window_resized;
    const frame_allocator = frame_arena.allocator();
    const input = try input_pkg.pollFrameInput(
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

    // Clay Pointer & Scroll State Updates
    clay.setLayoutDimensions(.{ .w = input.win_w, .h = input.win_h });
    app_state.viewer.ui.overlays.last_win_w = input.win_w;
    app_state.viewer.ui.overlays.last_win_h = input.win_h;

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

    app_state.viewer.ui.overlays.last_mouse_x = input.mouse_x;
    app_state.viewer.ui.overlays.last_mouse_y = input.mouse_y;

    if (input.mouse_left_clicked) {
        if (app_state.viewer.ui.overlays.show_info and !input.isPointerInDebugPanel() and clay.pointerOver(clay.getElementId("InfoCloseBtn"))) {
            app_state.viewer.ui.overlays.show_info = false;
        }
        if (app_state.viewer.ui.overlays.show_stats and !input.isPointerInDebugPanel() and clay.pointerOver(clay.getElementId("StatsCloseBtn"))) {
            app_state.viewer.ui.overlays.show_stats = false;
        }
    }

    // Phase 2: Update Phase — Run all systems sequentially
    try runUpdatePhase(app_state, input, frame_allocator);

    // Phase 3: Render Phase
    const view_params = state_pkg.ViewParams{
        .viewport = app_state.viewer.viewport,
        .win_w = input.win_w,
        .win_h = input.win_h,
        .scale_x = input.scale_x,
        .scale_y = input.scale_y,
        .is_fullscreen = app_state.viewer.isFullscreen(),
    };

    if (app_state.gpu_device == null) return error.GpuNotInitialized;

    const ui_model = state_pkg.UiViewModel{
        .is_fullscreen = app_state.viewer.isFullscreen(),
        .total_images = app_state.viewer.navigation.image_list.items.len,
        .image_list = app_state.viewer.navigation.image_list.items,
        .current_index = app_state.viewer.navigation.current_index,
        .current_image_entry = if (app_state.viewer.navigation.current_index) |idx|
            if (idx < app_state.viewer.navigation.image_list.items.len) app_state.viewer.navigation.image_list.items[idx] else null
        else
            null,
        .current_entry = app_state.getCurrentEntry(),
        .is_loading_files = app_state.viewer.navigation.is_loading_files.load(.acquire),
        .slideshow = app_state.viewer.navigation.slideshow,
        .manga_mode = app_state.viewer.navigation.manga_mode,
        .view_mode = app_state.viewer.navigation.view_mode,
        .strip_spans = app_state.viewer.navigation.strip_spans.items,
        .visible_frustum = app_state.viewer.navigation.visible_frustum,
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
        .get_entry_fn = viewerCacheLookup,
        .cache_context = app_state,
    };

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
    const ipc_server: ?*ipc.IpcServer = if (ipc_server_ptr) |ptr| @ptrCast(@alignCast(ptr)) else null;
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
