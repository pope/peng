const app = @import("app");
const gpu = @import("gpu");
const input_pkg = @import("input");
const sdl = @import("sdl");
const std = @import("std");
const ui = @import("ui");

const FrameTarget = gpu.pass.FrameTarget;
const MeasureTextUserData = ui.text_utils.MeasureTextUserData;
const RenderResources = gpu.graphics.RenderResources;

/// Entry point for loading dynamic UI resources / assets.
pub fn loadAssets() !void {}

/// Entry point for unloading dynamic UI resources / assets upon library reload.
pub fn unloadAssets() void {}

/// Main frame update function encapsulated within the hot-reloadable
/// viewer library.
pub fn updateFrame(
    app_state: *app.state.AppState,
    window: sdl.Window,
    resources: *RenderResources,
    measure_data: *MeasureTextUserData,
    parsed_headless: bool,
    parsed_test_mode: bool,
    frame_arena: *std.heap.ArenaAllocator,
    last_time: *u64,
) !void {
    // Phase 1: Background Event & Input Ingestion
    const skip_wait = (parsed_test_mode or parsed_headless) and
        !app_state.display.isHidden();
    if (skip_wait) {
        app_state.viewer.animations.settleAll();
    }
    const bg_events_processed = app.drainWorkerEvents(app_state);
    const cur_win_size = window.getSize();
    const cur_win_w = @as(f32, @floatFromInt(cur_win_size.w));
    const cur_win_h = @as(f32, @floatFromInt(cur_win_size.h));
    const wait_strategy = app_state.computeFrameWaitStrategy(
        cur_win_w,
        cur_win_h,
        bg_events_processed,
        skip_wait,
        sdl.timer.getTicks(),
    );
    const frame_allocator = frame_arena.allocator();
    const input = try input_pkg.pollFrameInput(
        window,
        frame_allocator,
        last_time,
        app_state.viewer.mouse_inside,
        wait_strategy,
    );

    // Drain any background worker or IPC events that arrived while waiting in
    // pollFrameInput (including the event that triggered sdl.pushWakeEvent()).
    const post_wait_events = app.drainWorkerEvents(app_state);
    if ((bg_events_processed or post_wait_events) and skip_wait) {
        app_state.viewer.animations.settleAll();
    }

    app_state.viewer.mouse_inside = input.mouse_inside;
    app_state.viewer.last_win_dims = input.logicalWinDims();

    const is_slider_active =
        (app_state.viewer.drag_state == .slider) or
        (app_state.viewer.ui.overlays.edit_panel.active_slider != null);

    ui.interaction.syncFrameInput(input, is_slider_active);

    // Phase 2: Update Phase — Run all systems sequentially
    const was_hidden = app_state.display.isHidden();
    try app.systems.runUpdatePhase(
        app_state,
        input,
        frame_allocator,
        parsed_test_mode or parsed_headless,
    );

    // Phase 3: Render Phase
    if (app_state.gpu_device == null) {
        app_state.handleScreenshotPostRender(error.GpuNotInitialized);
        return error.GpuNotInitialized;
    }
    switch (app_state.display) {
        .hidden => {
            _ = frame_arena.reset(.free_all);
            const released_ui = resources.releaseTransientResources(
                app_state.allocator,
            );
            if (!was_hidden or released_ui) {
                if (app_state.gpu_device) |dev| {
                    dev.reclaimMemory();
                }
                sdl.reclaimProcessHeap();
            }
            return;
        },
        .visible => {},
    }

    const ui_model = app_state.buildUiViewModel(input.now_ms);

    // Draw / Render
    const capture_filename = switch (app_state.viewer.ui.screenshot_mode) {
        .idle => null,
        .capturing => |s| s.path,
    };
    const target_window = app_state.display.visibleWindow();
    const frame_target: FrameTarget = if (target_window) |win|
        .{ .window = win }
    else
        .{ .headless = input.logicalWinDims().toPhysical(input.dpiScale()) };
    ui.layout.renderFrame(
        ui_model,
        resources,
        input,
        app_state.allocator,
        frame_allocator,
        measure_data,
        .{
            .target = frame_target,
            .scale = input.dpiScale(),
            .metrics = &app_state.viewer.ui.metrics,
            .capture_filename = capture_filename,
        },
    ) catch |err| {
        app_state.handleScreenshotPostRender(err);
        return err;
    };
    app_state.handleScreenshotPostRender(null);
}

//////////////////////////////////////////////////////////////////////////////
// C Exports for Hot Reloading Dynamic Library Boundary

/// Loads font and texture assets across dynamic library boundaries.
export fn viewer_load_assets() callconv(.c) void {
    loadAssets() catch |err| {
        std.log.err("Failed to load assets: {}", .{err});
    };
}

/// Unloads all font and texture assets upon module deinitialization.
export fn viewer_unload_assets() callconv(.c) void {
    unloadAssets();
}

/// Core exported frame loop entrypoint called per tick by the hot-reloading
/// host.
export fn viewer_update(
    app_state: *app.state.AppState,
    window: sdl.Window,
    resources: *RenderResources,
    measure_data: *MeasureTextUserData,
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
        parsed_headless,
        parsed_test_mode,
        frame_arena,
        last_time,
    ) catch |err| {
        std.log.err("Viewer update frame error: {}", .{err});
    };
}
