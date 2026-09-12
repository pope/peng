const app = @import("app");
const clay = @import("zclay");
const input_pkg = @import("input");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const ui = @import("ui");

/// Entry point for loading dynamic UI resources / assets.
pub fn loadAssets() !void {
    clay.cdefs.Clay_ResetMeasureTextCache();
}

/// Entry point for unloading dynamic UI resources / assets upon library reload.
pub fn unloadAssets() void {}

/// Sequential execution of all systems during the Update Phase of the event loop.
/// Guaranteed: All systems run in deterministic order, use frame_allocator, and
/// do NOT call each other.
fn runUpdatePhase(
    app_state: *app.state.AppState,
    input: state_pkg.FrameInput,
    frame_allocator: std.mem.Allocator,
    parsed_test_mode: bool,
) !void {
    const ctx = app.systems.FrameContext{
        .state = app_state,
        .frame_allocator = frame_allocator,
        .input = input,
        .delta_time_ms = input.delta_time_ms,
    };

    // Data-Oriented Animation System (ticks active SoA animation channels from previous frame)
    app.systems.sysUpdateAnimations(ctx);

    // Socket Command Ingestion System (parses IPC commands -> pending_intents)
    app.systems.sysExecuteIpcCommands(ctx);

    // Command Palette Input System (typing query updates, selection, click-outside, item clicks)
    const palette_closed_this_frame = try app.systems.sysProcessPaletteInput(ctx);

    // Keyboard & File Drop Input System (maps keypresses -> pending_intents)
    try app.systems.sysProcessInput(ctx, palette_closed_this_frame);

    // UI Discrete Interactions (overlay close buttons)
    try app.systems.sysProcessUiInteractions(ctx);

    // Viewport & Motion Systems (mouse drag/zoom & slideshow timer)
    app.systems.sysUpdateViewport(ctx, palette_closed_this_frame);
    try app.systems.sysUpdateSlideshow(ctx);

    // Window Management System (synchronizes window title and display properties)
    app.systems.sysSyncWindow(ctx);

    // Execute All Ingested & Generated Intents (IPC, Keyboard, Palette & Slideshow intents)
    try app.systems.sysExecuteIntents(ctx);

    // Asset Upload & Texture Pipeline System
    app.systems.sysProcessAssetUploads(ctx);

    // Cache Slot Management System (evicts slots & spawns prefetch workers)
    app.systems.sysUpdateCache(ctx) catch |err| std.log.err("Failed to update cache: {}", .{err});

    // Metrics & Telemetry System
    app.systems.sysSyncMetrics(ctx);

    if (parsed_test_mode) {
        app_state.viewer.animations.settleAll();
    }
}

/// Main frame update function encapsulated within the hot-reloadable viewer library.
pub fn updateFrame(
    app_state: *app.state.AppState,
    window: sdl.Window,
    resources: *ui.graphics.RenderResources,
    measure_data: *state_pkg.MeasureTextUserData,
    ipc_server: ?*ipc.IpcServer,
    parsed_headless: bool,
    parsed_test_mode: bool,
    frame_arena: *std.heap.ArenaAllocator,
    last_time: *u64,
) !void {
    _ = ipc_server;
    // Re-bind Clay measure text function pointer to the reloaded code address
    clay.setMeasureTextFunction(
        *const state_pkg.MeasureTextUserData,
        measure_data,
        ui.graphics.sdl3MeasureText,
    );

    // Phase 1: Background Event & Input Ingestion
    if (parsed_test_mode or parsed_headless) {
        app_state.viewer.animations.settleAll();
    }
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
        const cur_idx = app_state.viewer.navigation.current_index orelse break :blk false;
        const has_gpu = app_state.gpu_device != null;
        break :blk app_state.cache.hasUnreadyPrefetchSlots(cur_idx, len, has_gpu);
    };
    const cur_win_size = window.getSize();
    const cur_win_w = @as(f32, @floatFromInt(cur_win_size.w));
    const cur_win_h = @as(f32, @floatFromInt(cur_win_size.h));
    const last_w = app_state.viewer.last_win_w;
    const last_h = app_state.viewer.last_win_h;
    const window_resized = (last_w != 0 and (last_w != cur_win_w or last_h != cur_win_h));
    const is_busy = app_state.isBusy() or
        is_current_loading or
        bg_events_processed or
        (app_state.viewer.drag_state != .none) or
        has_unpopulated_cache or
        window_resized;
    const wait_timeout_ms =
        if (!is_busy) app_state.getWaitTimeoutMs(sdl.timer.getTicks()) else null;
    const frame_allocator = frame_arena.allocator();
    const input = try input_pkg.pollFrameInput(
        window,
        frame_allocator,
        last_time,
        app_state.viewer.mouse_inside,
        app_state.viewer.ui.palette.mode != .inactive,
        parsed_test_mode or parsed_headless,
        is_busy,
        wait_timeout_ms,
    );

    app_state.viewer.mouse_inside = input.mouse_inside;

    // Clay Pointer & Scroll State Updates
    clay.setLayoutDimensions(.{ .w = input.win_w, .h = input.win_h });
    app_state.viewer.last_win_w = input.win_w;
    app_state.viewer.last_win_h = input.win_h;

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

    var update_input = input;
    if (clay.isDebugModeEnabled()) {
        const debug_w: f32 = @floatFromInt(clay.Clay__debugViewWidth);
        update_input.is_pointer_in_debug_panel = input.mouse_x >= (input.win_w - debug_w);
    }

    // Phase 2: Update Phase — Run all systems sequentially
    try runUpdatePhase(
        app_state,
        update_input,
        frame_allocator,
        parsed_test_mode or parsed_headless,
    );

    // Phase 3: Render Phase
    if (app_state.gpu_device == null) return error.GpuNotInitialized;

    const nav_items = app_state.viewer.navigation.image_list.items;
    const ui_model = state_pkg.UiViewModel{
        .is_fullscreen = app_state.viewer.isFullscreen(),
        .total_images = nav_items.len,
        .image_list = nav_items,
        .current_index = app_state.viewer.navigation.current_index,
        .current_image_entry = if (app_state.viewer.navigation.current_index) |idx|
            if (idx < nav_items.len) nav_items[idx] else null
        else
            null,
        .current_entry = app_state.getCurrentEntry(),
        .is_loading_files = app_state.viewer.navigation.is_loading_files.load(.acquire),
        .slideshow = app_state.viewer.navigation.slideshow,
        .manga_mode = app_state.viewer.navigation.manga_mode,
        .overlays = app_state.viewer.ui.overlays,
        .window_title = blk: {
            if (app_state.viewer.navigation.current_index) |idx| {
                if (idx < app_state.viewer.navigation.image_list.items.len) {
                    break :blk app_state.viewer.navigation.image_list.items[idx].getBasename();
                }
            }
            break :blk "Peng Image Viewer";
        },
        .viewport = app_state.viewer.viewport,
        .palette = &app_state.viewer.ui.palette,
        .snackbar = blk: {
            const reveal = app_state.viewer.animations.get(.snackbar);
            const msg = app_state.viewer.ui.snackbar.getMessage();
            if (reveal > 0.001 and msg.len > 0) {
                break :blk .{ .active = .{
                    .reveal = reveal,
                    .message = msg,
                } };
            }
            break :blk .none;
        },
        .anim_values = app_state.viewer.animations.values,
        .debug_show_thumb = app_state.viewer.ui.overlays.debug_show_thumb,
        .is_thumb_crossfading = blk: {
            const cur_entry = app_state.getCurrentEntry() orelse break :blk false;
            break :blk (cur_entry.status == .loaded_gpu) and
                (cur_entry.thumbnail == .loaded) and
                !app_state.viewer.ui.overlays.debug_show_thumb and
                !app_state.viewer.isSlideshowActive() and
                (app_state.viewer.image_transition == .none) and
                (app_state.viewer.animations.get(.thumb_crossfade) < 0.999);
        },
        .image_dissolve = blk: {
            const progress = app_state.viewer.animations.get(.image_crossfade);
            if (progress >= 0.999) break :blk .none;
            const cur = app_state.getCurrentEntry() orelse break :blk .none;
            if (cur.status != .loaded_gpu) break :blk .none;

            switch (app_state.viewer.image_transition) {
                .none => break :blk .none,
                .active => |t| {
                    const prev = app_state.getTransitionPrevEntry() orelse break :blk .none;
                    if (prev.status != .loaded_gpu) break :blk .none;
                    break :blk .{ .active = .{
                        .prev_entry = prev,
                        .prev_rotation = t.prev_rotation,
                    } };
                },
            }
        },
        .current_time_ms = sdl.timer.getTicks(),
        .stats = app_state.viewer.stats,
        .render_metrics = app_state.viewer.ui.metrics.toSnapshot(),
    };

    // Draw / Render
    const capture_filename = switch (app_state.viewer.ui.screenshot_mode) {
        .idle => null,
        .capturing => |s| s.path,
    };
    const target_window = if (app_state.viewer.display.isClaimed()) window else null;
    ui.layout.renderFrame(
        ui_model,
        resources,
        input,
        app_state.allocator,
        frame_allocator,
        resources.fonts[0..],
        measure_data,
        target_window,
        &app_state.viewer.ui.metrics,
        capture_filename,
    ) catch |err| {
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
    window: sdl.Window,
    resources: *ui.graphics.RenderResources,
    measure_data: *state_pkg.MeasureTextUserData,
    ipc_server: ?*ipc.IpcServer,
    parsed_headless: bool,
    parsed_test_mode: bool,
    frame_arena: *std.heap.ArenaAllocator,
    last_time: *u64,
) callconv(.c) void {
    updateFrame(
        app_state,
        window,
        resources,
        measure_data,
        ipc_server,
        parsed_headless,
        parsed_test_mode,
        frame_arena,
        last_time,
    ) catch |err| {
        std.log.err("Viewer update frame error: {}", .{err});
    };
}
