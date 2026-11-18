const app = @import("app");
const gpu = @import("gpu");
const input_pkg = @import("input");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const ui = @import("ui");

const AppState = app.state.AppState;
const FrameTarget = gpu.pass.FrameTarget;
const MeasureTextUserData = ui.text_utils.MeasureTextUserData;
const RenderResources = gpu.graphics.RenderResources;
const UiViewModel = ui.UiViewModel;
const VisibleState = state_pkg.VisibleState;

/// Entry point for loading dynamic UI resources / assets.
pub fn loadAssets() !void {}

/// Entry point for unloading dynamic UI resources / assets upon library reload.
pub fn unloadAssets() void {}

/// Main frame update function encapsulated within the hot-reloadable
/// viewer library.
pub fn updateFrame(
    app_state: *AppState,
    window: sdl.Window,
    resources: *RenderResources,
    measure_data: *MeasureTextUserData,
    parsed_headless: bool,
    parsed_test_mode: bool,
    frame_arena: *std.heap.ArenaAllocator,
    last_time: *u64,
) !void {
    // Phase 1: Background Event & Input Ingestion
    const pre_ingest_start = std.Io.Clock.awake.now(app_state.io);
    const pre_wait_ms = state_pkg.timestampToMs(pre_ingest_start);
    const skip_wait = (parsed_test_mode or parsed_headless) and
        !app_state.display.isHidden();
    if (skip_wait) {
        app_state.viewer.animations.settleAll();
    }
    const bg_events_processed = app.drainWorkerEvents(
        app_state,
        pre_wait_ms,
    );
    const cur_win_size = window.getSize();
    const cur_win_w = @as(f32, @floatFromInt(cur_win_size.w));
    const cur_win_h = @as(f32, @floatFromInt(cur_win_size.h));
    const was_frame_paced = app_state.isFramePaced(cur_win_w, cur_win_h);
    const wait_strategy = app_state.computeFrameWaitStrategy(
        cur_win_w,
        cur_win_h,
        bg_events_processed,
        skip_wait,
        pre_wait_ms,
    );
    const frame_allocator = frame_arena.allocator();
    const pre_ingest_end = std.Io.Clock.awake.now(app_state.io);
    const input = try input_pkg.pollFrameInput(
        app_state.io,
        window,
        frame_allocator,
        last_time,
        app_state.viewer.mouse_inside,
        app_state.viewer.touch_tracker,
        wait_strategy,
    );

    const post_ingest_start = std.Io.Clock.awake.now(app_state.io);
    // Drain any background worker or IPC events that arrived while waiting in
    // pollFrameInput (including the event that triggered sdl.pushWakeEvent()).
    const post_wait_events = app.drainWorkerEvents(app_state, input.now_ms);
    if ((bg_events_processed or post_wait_events) and skip_wait) {
        app_state.viewer.animations.settleAll();
    }
    const was_passive_wait = switch (wait_strategy) {
        .poll => false,
        .wait_indefinite => true,
        .wait_timeout_ms => !was_frame_paced,
    };
    const is_paced_step = !was_passive_wait or state_pkg.isPassiveStepPaced(
        input.wait_sleep_ms,
        input.wait_woke_on_event,
        post_wait_events,
    );

    app_state.viewer.mouse_inside = input.mouse_inside;
    app_state.viewer.touch_tracker = input.touch_tracker;
    app_state.viewer.last_win_dims = input.logicalWinDims();

    const was_hidden = app_state.display.isHidden();
    if (!was_hidden and !app_state.display.isSuspended()) {
        const is_slider_active =
            (app_state.viewer.drag_state == .slider) or
            (app_state.viewer.ui.overlays.edit_panel.active_slider != null);

        app_state.viewer.ui.interaction.syncFrameInput(
            input,
            is_slider_active,
        );
    }
    const post_ingest_end = std.Io.Clock.awake.now(app_state.io);
    const pre_ingest_ms = state_pkg.durationToMs(
        pre_ingest_start.durationTo(pre_ingest_end),
    );
    const post_ingest_ms = state_pkg.durationToMs(
        post_ingest_start.durationTo(post_ingest_end),
    );
    const ingest_ms = pre_ingest_ms + post_ingest_ms + input.poll_cpu_ms;

    // Phase 2: Update Phase — Run all systems sequentially
    const update_timings = try app.systems.runUpdatePhase(
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
            app_state.frame_metrics.reset();
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
    if (app_state.display.isSuspended() and
        app_state.viewer.ui.screenshot_mode == .idle)
    {
        return;
    }

    const phase3_start = std.Io.Clock.awake.now(app_state.io);
    app_state.frame_metrics.present.settleBeforeRender(
        input.now_ms,
        is_paced_step,
    );
    const ui_model = buildUiViewModel(app_state, resources, input.now_ms);

    // Draw / Render
    const capture_filename = switch (app_state.viewer.ui.screenshot_mode) {
        .idle => null,
        .capturing => |s| s.path,
    };
    const is_screenshot = (capture_filename != null);
    const target_window = if (app_state.display.isSuspended())
        null
    else
        app_state.display.visibleWindow();
    const frame_target: FrameTarget = if (target_window) |win|
        .{ .window = win }
    else
        .{ .headless = input.logicalWinDims().toPhysical(input.dpiScale()) };
    const pass_timings = ui.layout.renderFrame(
        &app_state.viewer.ui.interaction,
        ui_model,
        resources,
        input,
        app_state.allocator,
        frame_allocator,
        measure_data,
        .{
            .target = frame_target,
            .scale = input.dpiScale(),
            .capture_filename = capture_filename,
        },
    ) catch |err| {
        app_state.handleScreenshotPostRender(err);
        return err;
    };
    const phase3_end = if (is_screenshot) blk: {
        const end_ts = std.Io.Clock.awake.now(app_state.io);
        app_state.handleScreenshotPostRender(null);
        break :blk end_ts;
    } else blk: {
        app_state.handleScreenshotPostRender(null);
        break :blk std.Io.Clock.awake.now(app_state.io);
    };
    const phase3_total_ms = state_pkg.durationToMs(
        phase3_start.durationTo(phase3_end),
    );
    const ui_layout_ms = @max(
        0.0,
        phase3_total_ms - pass_timings.total_pass_ms,
    );
    app_state.frame_metrics.record(.{
        .ingest_ms = ingest_ms,
        .intents_ms = update_timings.intents_ms,
        .sync_ms = update_timings.sync_ms,
        .ui_layout_ms = ui_layout_ms,
        .gpu_encode_ms = pass_timings.gpu_encode_ms,
        .swapchain_wait_ms = pass_timings.swapchain_wait_ms,
    }, phase3_end, input.now_ms, is_paced_step);
}

/// Constructs a read-only snapshot view-model consumed by the UI layout
/// and rendering subsystems for the current frame.
fn buildUiViewModel(
    app_state: *const AppState,
    resources: *const RenderResources,
    now_ms: u64,
) UiViewModel {
    const nav = &app_state.viewer.navigation;
    const nav_slice = nav.items.slice();
    const visible_cnt = nav.getVisibleCount();
    const visible_pos = nav.getVisiblePosition();
    const visible_st: VisibleState = blk: {
        if (nav_slice.len == 0) {
            break :blk .empty_directory;
        } else if (visible_cnt == 0) {
            break :blk .{ .filtered_empty = .{
                .mode = nav.getViewMode(),
                .total_count = nav_slice.len,
            } };
        } else if (nav.current_index) |idx| {
            break :blk .{ .selected = .{
                .raw_index = idx,
                .visible_index = visible_pos orelse 1,
                .visible_count = visible_cnt,
                .total_count = nav_slice.len,
                .classification = nav.getCurrentClassification(),
            } };
        } else {
            break :blk .empty_directory;
        }
    };

    const overlays = &app_state.viewer.ui.overlays;
    return .{
        .is_fullscreen = app_state.isFullscreen(),
        .total_images = nav_slice.len,
        .items = nav_slice,
        .current_index = nav.current_index,
        .current_image_entry = nav.getCurrentImageEntry(),
        .current_entry = app_state.getCurrentEntry(),
        .current_classification = nav.getCurrentClassification(),
        .view_mode = nav.getViewMode(),
        .visible_state = visible_st,
        .visible_count = visible_cnt,
        .visible_position = visible_pos,
        .is_loading_files = nav.isLoadingFiles(),
        .slideshow = app_state.viewer.navigation.slideshow,
        .manga_mode = app_state.viewer.navigation.manga_mode,
        .overlays = app_state.viewer.ui.overlays,
        .window_title = blk: {
            if (nav.getCurrentImageEntry()) |media| {
                break :blk media.getBasename();
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
            const cur_entry =
                app_state.getCurrentEntry() orelse break :blk false;
            const thumb_loaded = switch (cur_entry.resident.thumbnail) {
                .loaded => true,
                .none,
                .pending,
                .staged_cpu,
                .not_available,
                .unloaded,
                => false,
            };
            const is_dissolve_none =
                switch (app_state.viewer.image_transition) {
                    .none => true,
                    .active => false,
                };
            break :blk cur_entry.resident.asset.hasGpuTexture() and
                thumb_loaded and
                !app_state.viewer.ui.overlays.debug_show_thumb and
                !app_state.viewer.isSlideshowActive() and
                is_dissolve_none and
                (app_state.viewer.animations.get(.thumb_crossfade) < 0.999);
        },
        .image_dissolve = blk: {
            const progress = app_state.viewer.animations.get(.image_crossfade);
            if (progress >= 0.999) break :blk .none;
            if (app_state.getCurrentEntry()) |cur| {
                if (cur.resident.asset.isFailed()) break :blk .none;
            }

            switch (app_state.viewer.image_transition) {
                .none => break :blk .none,
                .active => |t| {
                    const prev = app_state.getTransitionPrevEntry() orelse
                        break :blk .none;
                    if (!prev.resident.asset.hasGpuTexture()) {
                        break :blk .none;
                    }
                    break :blk .{ .active = .{
                        .prev_entry = prev,
                        .prev_rotation = t.prev_rotation,
                        .prev_zoom = t.prev_zoom,
                        .prev_pan_x = t.prev_pan_x,
                        .prev_pan_y = t.prev_pan_y,
                    } };
                },
            }
        },
        .current_time_ms = now_ms,
        .stats = if (overlays.stats_panel.visible)
            app_state.snapshotStats()
        else
            .{},
        .render_metrics = if (overlays.stats_panel.visible or
            overlays.atlas_panel.visible)
            resources.snapshotMetrics()
        else
            .{},
    };
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
    app_state: *AppState,
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
