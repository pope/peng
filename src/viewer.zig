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
const SoftwarePresenter = sdl.SoftwarePresenter;
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
    resources_opt: ?*RenderResources,
    measure_data: *MeasureTextUserData,
    sw_presenter: ?*SoftwarePresenter,
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
    app_state.updateServerIdleShutdown(
        input.now_ms,
        bg_events_processed or post_wait_events,
    );

    // Phase 3: Render Phase
    if (app_state.gpu_device == null or resources_opt == null) {
        if (parsed_headless or
            app_state.viewer.ui.screenshot_mode == .capturing)
        {
            app_state.handleScreenshotPostRender(error.GpuNotInitialized);
            return error.GpuNotInitialized;
        }
        switch (app_state.display) {
            .hidden => return,
            .visible => {},
        }
        if (app_state.display.isSuspended()) return;
        renderSoftwareFrame(app_state, window, sw_presenter);
        return;
    }
    const resources = resources_opt.?;
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
    app_state.frame_metrics.present.settle(input.now_ms);
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
    }, pass_timings.swapchain_present_ts);

    // Lazily warm the RGB24 compute unpack pipeline after Frame 0 has been
    // presented so cold-start time-to-first-pixel is never blocked on it.
    if (resources.frame_index == 1 and
        resources.unpack_compute_pipeline == .uninitialized)
    {
        app_state.unpack_compute_pipeline =
            resources.ensureUnpackComputePipeline();
    }
}

/// Blits the background and current decoded CPU surface (or staged thumbnail)
/// aspect-fitted into `dst_surf` using the exact same layout math, thumbnail
/// UV crop, pre-orientation handling, and pixel-center rasterization bounds as
/// the GPU viewport so handoff to Vulkan has zero pixel shift.
fn blitSoftwareScene(
    app_state: *const AppState,
    window: sdl.Window,
    dst_surf: sdl.Surface,
) void {
    const win_w = dst_surf.w();
    const win_h = dst_surf.h();
    if (win_w <= 0 or win_h <= 0) return;

    // Fill with Catppuccin Mocha mantle (#181825) to match GPU clear color.
    _ = dst_surf.fillRgb(0x18, 0x18, 0x25);

    if (app_state.getCurrentEntry()) |entry| {
        const SrcChoice = struct {
            surface: sdl.Surface,
            is_thumb: bool,
            thumb_dct_snapped: bool = false,
            thumb_pre_oriented: bool = false,
        };
        const src_choice: SrcChoice = switch (entry.resident.asset) {
            .loaded_cpu => |cpu| .{
                .surface = cpu.cpu.surface,
                .is_thumb = false,
            },
            .promoting_gpu => |p| .{
                .surface = p.staged.cpu.surface,
                .is_thumb = false,
            },
            .none, .loaded_gpu, .failed => switch (entry.resident.thumbnail) {
                .staged_cpu => |t| .{
                    .surface = t.surface,
                    .is_thumb = true,
                    .thumb_dct_snapped = t.dct_snapped,
                    .thumb_pre_oriented = t.source.isPreOriented(),
                },
                .none,
                .pending,
                .loaded,
                .not_available,
                .unloaded,
                => return,
            },
        };

        const view_angle = app_state.viewer.viewport.rotation_angle;
        const effective_angle = if (src_choice.is_thumb and
            src_choice.thumb_pre_oriented)
            @mod(
                view_angle - entry.metadata.orientation.toDegrees() + 360.0,
                360.0,
            )
        else
            view_angle;
        const angle_i: i32 = @intFromFloat(@round(effective_angle));
        const turns: u2 = @intCast(@mod(@divFloor(angle_i + 45, 90), 4));
        const rotated_opt = if (turns != 0)
            src_choice.surface.rotateOrthogonal(turns)
        else
            null;
        defer if (rotated_opt) |r| r.destroy();
        const active = rotated_opt orelse src_choice.surface;

        const src_w = active.w();
        const src_h = active.h();
        if (src_w <= 0 or src_h <= 0) return;

        const log_sz = window.getSize();
        const pix_sz = window.getSizeInPixels();
        const log_w: f32 = @floatFromInt(@max(1, log_sz.w));
        const log_h: f32 = @floatFromInt(@max(1, log_sz.h));
        const dpi_x: f32 = @as(f32, @floatFromInt(@max(1, pix_sz.w))) / log_w;
        const dpi_y: f32 = @as(f32, @floatFromInt(@max(1, pix_sz.h))) / log_h;
        const buf_scale_x: f32 = @as(f32, @floatFromInt(win_w)) / log_w;
        const buf_scale_y: f32 = @as(f32, @floatFromInt(win_h)) / log_h;

        const draw_logical = ui.layout.computeDrawDims(
            entry,
            .{ .w = log_w, .h = log_h },
            .{ .x = dpi_x, .y = dpi_y },
            view_angle,
            app_state.viewer.viewport.fit_mode,
        );
        if (draw_logical.w <= 0.0 or draw_logical.h <= 0.0) return;
        const draw_w_px = draw_logical.w * buf_scale_x;
        const draw_h_px = draw_logical.h * buf_scale_y;
        const win_w_f: f32 = @floatFromInt(win_w);
        const win_h_f: f32 = @floatFromInt(win_h);

        // Match Vulkan top-left pixel-center rasterization bounds
        // (pixel center `p + 0.5` covered iff `x1 <= p + 0.5 < x2`).
        const x1 = (win_w_f - draw_w_px) * 0.5;
        const x2 = (win_w_f + draw_w_px) * 0.5;
        const y1 = (win_h_f - draw_h_px) * 0.5;
        const y2 = (win_h_f + draw_h_px) * 0.5;
        const dst_x: i32 = @intFromFloat(@ceil(x1 - 0.5));
        const dst_x2: i32 = @intFromFloat(@ceil(x2 - 0.5));
        const dst_y: i32 = @intFromFloat(@ceil(y1 - 0.5));
        const dst_y2: i32 = @intFromFloat(@ceil(y2 - 0.5));
        const dst_w: i32 = dst_x2 - dst_x;
        const dst_h: i32 = dst_y2 - dst_y;
        if (dst_w <= 0 or dst_h <= 0) return;

        // Avoid huge temporary allocations when fill/1:1 zoom exceeds window.
        const fits_in_window = dst_w <= win_w and dst_h <= win_h;

        if (src_choice.is_thumb) {
            const pre_swapped = src_choice.thumb_pre_oriented and
                entry.metadata.orientation.isDimensionSwapped();
            const active_swapped = pre_swapped != ((turns & 1) != 0);
            const PhysDims = @TypeOf(entry.metadata.full_dims.?);
            const known_full = entry.metadata.full_dims orelse
                entry.metadata.raw_metadata.getSensorDims();
            const ref_full: PhysDims = if (known_full) |fd|
                (if (active_swapped) .{ .w = fd.h, .h = fd.w } else fd)
            else
                .{ .w = 0.0, .h = 0.0 };
            const uv = state_pkg.view_transform.computeThumbnailUvCrop(
                ref_full,
                .{
                    .w = @floatFromInt(src_w),
                    .h = @floatFromInt(src_h),
                },
                src_choice.thumb_dct_snapped,
            );
            const cropped_opt = if (fits_in_window)
                active.scaleUvRectRgba32(
                    uv.u_min,
                    uv.v_min,
                    uv.u_max,
                    uv.v_max,
                    dst_w,
                    dst_h,
                )
            else
                null;
            if (cropped_opt) |cropped| {
                defer cropped.destroy();
                _ = cropped.blitScaledTo(
                    dst_surf,
                    dst_x,
                    dst_y,
                    dst_w,
                    dst_h,
                    .nearest,
                );
            } else {
                _ = active.blitScaledTo(
                    dst_surf,
                    dst_x,
                    dst_y,
                    dst_w,
                    dst_h,
                    .linear,
                );
            }
            return;
        }

        // Use 4x4/2x2 box-filter downsampling when shrinking within window
        // bounds to match GPU mipmapped trilinear quality.
        const is_downscale = fits_in_window and
            (src_w > dst_w or src_h > dst_h);
        const smooth_opt = if (is_downscale)
            active.scaleRgba32Smooth(dst_w, dst_h)
        else
            null;
        defer if (smooth_opt) |s| s.destroy();
        const blit_src = smooth_opt orelse active;
        const blit_mode: sdl.surface.ScaleMode = if (smooth_opt != null)
            .nearest
        else
            .linear;
        _ = blit_src.blitScaledTo(
            dst_surf,
            dst_x,
            dst_y,
            dst_w,
            dst_h,
            blit_mode,
        );
    }
}

fn computeSoftwareFrameKey(
    app_state: *const AppState,
    window: sdl.Window,
) u64 {
    const log_sz = window.getSize();
    const pix_sz = window.getSizeInPixels();
    const src_ptr: usize = if (app_state.getCurrentEntry()) |entry| blk: {
        const surf_opt: ?sdl.Surface = switch (entry.resident.asset) {
            .loaded_cpu => |cpu| cpu.cpu.surface,
            .promoting_gpu => |p| p.staged.cpu.surface,
            .none, .loaded_gpu, .failed => switch (entry.resident.thumbnail) {
                .staged_cpu => |t| t.surface,
                .none, .pending, .loaded, .not_available, .unloaded => null,
            },
        };
        break :blk if (surf_opt) |s| @intFromPtr(s.ptr) else 0;
    } else 0;
    var auth_w: f32 = 0.0;
    var auth_h: f32 = 0.0;
    var orient_u64: u64 = 0;
    if (app_state.getCurrentEntry()) |entry| {
        const auth = entry.getAuthoritativeDims();
        auth_w = auth.w;
        auth_h = auth.h;
        orient_u64 = @backingInt(entry.metadata.orientation);
    }
    const media_id: u64 =
        if (app_state.viewer.navigation.getCurrentMediaId()) |id|
            @backingInt(id)
        else
            0;
    const angle_i: i32 = @intFromFloat(
        @round(app_state.viewer.viewport.rotation_angle),
    );
    const key_data = [_]u64{
        src_ptr,
        media_id,
        orient_u64,
        @bitCast(@as(i64, log_sz.w)),
        @bitCast(@as(i64, log_sz.h)),
        @bitCast(@as(i64, pix_sz.w)),
        @bitCast(@as(i64, pix_sz.h)),
        @as(u32, @bitCast(auth_w)),
        @as(u32, @bitCast(auth_h)),
        @bitCast(@as(i64, angle_i)),
        @backingInt(app_state.viewer.viewport.fit_mode),
    };
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&key_data));
}

/// Software-first presentation fallback used during cold-start while
/// `SDL_CreateGPUDevice` initializes asynchronously on a background thread.
fn renderSoftwareFrame(
    app_state: *const AppState,
    window: sdl.Window,
    sw_presenter: ?*SoftwarePresenter,
) void {
    const presenter = sw_presenter orelse return;
    const frame_key = computeSoftwareFrameKey(app_state, window);
    if (presenter.isFrameCurrent(frame_key)) return;
    const frame = presenter.acquireFrame(window) orelse return;
    blitSoftwareScene(app_state, window, frame.surface);
    presenter.presentFrame(window, frame, frame_key);
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
    resources_opt: ?*RenderResources,
    measure_data: *MeasureTextUserData,
    sw_presenter: ?*SoftwarePresenter,
    parsed_headless: bool,
    parsed_test_mode: bool,
    frame_arena: *std.heap.ArenaAllocator,
    last_time: *u64,
) callconv(.c) void {
    updateFrame(
        app_state,
        window,
        resources_opt,
        measure_data,
        sw_presenter,
        parsed_headless,
        parsed_test_mode,
        frame_arena,
        last_time,
    ) catch |err| {
        std.log.err("Viewer update frame error: {}", .{err});
    };
}
