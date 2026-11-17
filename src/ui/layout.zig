const cache = @import("cache");
const edit_panel = @import("edit_panel.zig");
const geom = @import("geom");
const gpu_pkg = @import("gpu");
const intents = @import("intents");
const palette = @import("palette.zig");
const palette_pkg = @import("palette");
const renderer = @import("renderer.zig");
const state = @import("state");
const stats = @import("stats.zig");
const std = @import("std");
const text_utils = @import("text_utils.zig");
const theme = @import("theme.zig");
const view_model = @import("view_model.zig");

const CacheEntry = cache.CacheEntry;
const DpiScale = geom.DpiScale;
const FrameInput = state.FrameInput;
const FrameTargetOptions = gpu_pkg.pass.FrameTargetOptions;
const FRect = geom.FRect;
const LogicalDims = geom.LogicalDims;
const measureText = text_utils.measureText;
const MeasureTextUserData = text_utils.MeasureTextUserData;
const PacketBuildContext = gpu_pkg.pass.PacketBuildContext;
const PaletteState = palette_pkg.PaletteState;
const PhysicalDims = geom.PhysicalDims;
const renderEditPanel = edit_panel.renderEditPanel;
const RenderPacket = gpu_pkg.pass.RenderPacket;
const renderPalette = palette.renderPalette;
const RenderResources = gpu_pkg.graphics.RenderResources;
const renderStatsOverlay = stats.renderStatsOverlay;
const truncateFilename = text_utils.truncateFilename;
const UiDrawList = renderer.UiDrawList;
const UiViewModel = view_model.UiViewModel;
const UvRect = geom.UvRect;
const view_transform = state.view_transform;

/// Computes fitted layout dimensions in logical UI points (`LogicalDims`) for
/// an image cache entry within available logical viewport bounds, evaluating
/// preset fit modes in physical framebuffer space via `scale`.
pub fn computeDrawDims(
    entry_opt: ?CacheEntry,
    available_dims: LogicalDims,
    scale: DpiScale,
    rotation_angle: f32,
    fit_mode: intents.ZoomPreset,
) LogicalDims {
    const entry = entry_opt orelse return .{ .w = 0, .h = 0 };
    const auth = entry.getAuthoritativeDims();

    if (auth.w > 0 and auth.h > 0) {
        const is_loading = !entry.resident.asset.isLoaded();
        const has_thumb = switch (entry.resident.thumbnail) {
            .none => false,
            .pending,
            .staged_cpu,
            .not_available,
            .unloaded,
            .loaded,
            => true,
        };
        const only_has_thumb = entry.metadata.full_dims == null and
            entry.metadata.raw_metadata.getSensorDims() == null and
            has_thumb;
        const effective_fit_mode: intents.ZoomPreset =
            if (fit_mode == .shrink and is_loading and only_has_thumb)
                .full
            else
                fit_mode;
        return view_transform.computeLogicalDrawDims(
            auth,
            available_dims,
            scale,
            rotation_angle,
            effective_fit_mode,
        );
    }
    return .{ .w = 0, .h = 0 };
}

/// Builds the complete UI layout hierarchy, accumulates immediate-mode draw
/// commands, and submits the frame render pass.
pub fn renderFrame(
    interaction: *state.InteractionState,
    ui_model: UiViewModel,
    gpu_res: *RenderResources,
    input: FrameInput,
    gpa_allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    measure_data: *MeasureTextUserData,
    target: FrameTargetOptions,
) !void {
    const width = input.win_w;
    const height = input.win_h;
    const dpi_scale = input.dpiScale();
    const current_entry = ui_model.current_entry;
    const total_images = ui_model.total_images;

    interaction.beginFrameLayout();

    const edit_progress = ui_model.anim(.edit_panel);
    const docked_w = edit_panel.PANEL_WIDTH * edit_progress;

    const available_width = @max(width - docked_w, 1.0);

    const padding: f32 = 0.0;
    const view_dims = LogicalDims{
        .w = @max(available_width - padding * 2.0, 1.0),
        .h = @max(height - padding * 2.0, 1.0),
    };

    const draw_dims = computeDrawDims(
        current_entry,
        view_dims,
        dpi_scale,
        ui_model.viewport.rotation_angle,
        ui_model.viewport.fit_mode,
    );

    var draw_list = UiDrawList{ .allocator = frame_allocator };

    try draw_list.addRect(
        FRect{ .x = 0.0, .y = 0.0, .w = width, .h = height },
        .{ .background_color = theme.mantle },
    );

    try renderViewport(
        interaction,
        &draw_list,
        ui_model,
        current_entry,
        draw_dims,
        view_dims,
        dpi_scale,
        total_images,
        frame_allocator,
        measure_data,
    );

    if (edit_progress > 0.001) {
        try renderEditPanel(
            interaction,
            &draw_list,
            ui_model,
            FRect{
                .x = width - docked_w,
                .y = 0.0,
                .w = docked_w,
                .h = height,
            },
            edit_progress,
            frame_allocator,
            measure_data,
        );
    }

    try renderBottomOverlayBar(
        &draw_list,
        ui_model,
        available_width,
        height,
        frame_allocator,
        measure_data,
    );

    try renderStatsOverlay(
        interaction,
        &draw_list,
        ui_model,
        view_dims,
        draw_dims,
        frame_allocator,
        measure_data,
    );

    try renderPalette(
        interaction,
        &draw_list,
        ui_model,
        LogicalDims{ .w = width, .h = height },
        frame_allocator,
        measure_data,
    );

    const RenderContext = struct {
        view_params: state.ViewportParams,
        render_commands: []const renderer.UiCommand,

        fn buildPacket(
            ctx: @This(),
            build_ctx: PacketBuildContext,
        ) anyerror!RenderPacket {
            return renderer.buildRenderPacket(
                ctx.view_params,
                build_ctx,
                ctx.render_commands,
            );
        }
    };

    var frame_target = target;
    frame_target.needs_blur =
        renderer.hasBlurredSurface(draw_list.commands.items);

    try gpu_pkg.pass.executeFrame(
        gpu_res,
        ui_model.viewport,
        gpa_allocator,
        frame_allocator,
        frame_target,
        RenderContext{
            .view_params = ui_model.viewport,
            .render_commands = draw_list.commands.items,
        },
        RenderContext.buildPacket,
    );
}

fn renderPillBadge(
    list: *UiDrawList,
    x: f32,
    center_y: f32,
    text: []const u8,
    bg_color: theme.Color,
    color: theme.Color,
    progress: f32,
    measure_data: *const MeasureTextUserData,
) !f32 {
    const dims = measureText(text, 0, 11, measure_data);
    const bw = dims.w + 12.0;
    const bh = if (dims.h > 0.0) dims.h + 4.0 else 17.0;
    const y = center_y - bh * 0.5;
    const rect = FRect{ .x = x, .y = y, .w = bw, .h = bh };

    try list.addRect(rect, .{
        .background_color = bg_color,
        .corner_radius = .all(4),
    });
    try list.addBorder(rect, .{
        .color = theme.withAlpha(color, progress),
        .width = .all(1),
        .corner_radius = .all(4),
    });
    try list.addText(.{
        .x = x + 6.0,
        .y = y + 2.0,
        .w = dims.w,
        .h = dims.h,
    }, .{
        .text = text,
        .color = theme.withAlpha(color, progress),
        .font_size = 11,
        .font_id = 0,
    });
    return bw;
}

fn renderTitlePill(
    list: *UiDrawList,
    rect: FRect,
    ui_model: UiViewModel,
    title_display: []const u8,
    count_str: ?[]const u8,
    progress: f32,
    measure_data: *const MeasureTextUserData,
) !void {
    try list.addRect(rect, .{
        .background_color = theme.withAlpha(theme.mantle, 0.75 * progress),
        .corner_radius = .all(10),
        .tag = if (ui_model.overlays.enable_blur) .blurred_surface else .none,
    });
    try list.addBorder(rect, .{
        .width = .all(1),
        .color = theme.withAlpha(theme.surface0, 0.7 * progress),
        .corner_radius = .all(10),
    });

    var cur_x = rect.x + 18.0;
    const badge_center_y = rect.y + rect.h * 0.5;

    const title_dims = measureText(title_display, 0, 15, measure_data);
    try list.addText(.{
        .x = cur_x,
        .y = rect.y + (rect.h - title_dims.h) * 0.5,
        .w = title_dims.w,
        .h = title_dims.h,
    }, .{
        .text = title_display,
        .color = theme.withAlpha(theme.text, progress),
        .font_size = 15,
        .font_id = 0,
    });
    cur_x += title_dims.w + 14.0;

    if (ui_model.current_classification == .pick) {
        const bw = try renderPillBadge(
            list,
            cur_x,
            badge_center_y,
            "PICK",
            theme.withAlpha(theme.green, 0.25 * progress),
            theme.green,
            progress,
            measure_data,
        );
        cur_x += bw + 14.0;
    } else if (ui_model.current_classification == .reject) {
        const bw = try renderPillBadge(
            list,
            cur_x,
            badge_center_y,
            "REJECT",
            theme.withAlpha(theme.red, 0.25 * progress),
            theme.red,
            progress,
            measure_data,
        );
        cur_x += bw + 14.0;
    }

    if (ui_model.view_mode.badgeText()) |mode_txt| {
        const bw = try renderPillBadge(
            list,
            cur_x,
            badge_center_y,
            mode_txt,
            theme.withAlpha(theme.crust, progress),
            theme.blue,
            progress,
            measure_data,
        );
        cur_x += bw + 14.0;
    }

    if (ui_model.manga_mode) {
        const bw = try renderPillBadge(
            list,
            cur_x,
            badge_center_y,
            "RTL",
            theme.withAlpha(theme.crust, progress),
            theme.peach,
            progress,
            measure_data,
        );
        cur_x += bw + 14.0;
    }

    const is_pair_item = (ui_model.current_image_entry != null and
        ui_model.current_image_entry.?.isPair());
    if (is_pair_item) {
        const bw = try renderPillBadge(
            list,
            cur_x,
            badge_center_y,
            "RAW+JPG",
            theme.withAlpha(theme.crust, progress),
            theme.mauve,
            progress,
            measure_data,
        );
        cur_x += bw + 14.0;
    }

    if (count_str) |cstr| {
        const count_dims = measureText(cstr, 0, 12, measure_data);
        try list.addText(.{
            .x = cur_x,
            .y = rect.y + (rect.h - count_dims.h) * 0.5,
            .w = count_dims.w,
            .h = count_dims.h,
        }, .{
            .text = cstr,
            .color = theme.withAlpha(theme.subtext0, progress),
            .font_size = 12,
            .font_id = 0,
        });
    }
}

fn renderSnackbarPill(
    list: *UiDrawList,
    rect: FRect,
    message: []const u8,
    progress: f32,
    enable_blur: bool,
    measure_data: *const MeasureTextUserData,
) !void {
    try list.addRect(rect, .{
        .background_color = theme.withAlpha(theme.mantle, 0.75 * progress),
        .corner_radius = .all(10),
        .tag = if (enable_blur) .blurred_surface else .none,
    });
    try list.addBorder(rect, .{
        .width = .all(1),
        .color = theme.withAlpha(theme.surface0, 0.7 * progress),
        .corner_radius = .all(10),
    });

    const dims = measureText(message, 0, 14, measure_data);
    try list.addText(.{
        .x = rect.x + 18.0,
        .y = rect.y + (rect.h - dims.h) * 0.5,
        .w = dims.w,
        .h = dims.h,
    }, .{
        .text = message,
        .color = theme.withAlpha(theme.text, progress),
        .font_size = 14,
        .font_id = 0,
    });
}

fn renderBottomOverlayBar(
    list: *UiDrawList,
    ui_model: UiViewModel,
    available_width: f32,
    win_h: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const title_progress = ui_model.anim(.title_overlay);
    const has_title = title_progress > 0.001;
    const snackbar_active = ui_model.snackbar.getActive();

    if (!has_title and snackbar_active == null) return;

    var snackbar_reservation: f32 = 0.0;
    var snackbar_w: f32 = 0.0;
    if (snackbar_active) |snack| {
        const text_w = measureText(snack.message, 0, 14, measure_data).w;
        snackbar_w = text_w + 36.0;
        snackbar_reservation = snackbar_w + 12.0;
    }

    const raw_title = ui_model.window_title;
    const is_loading = ui_model.is_loading_files;
    const total_images = ui_model.total_images;
    var count_str: ?[]const u8 = null;
    if (total_images > 0) {
        if (ui_model.current_index) |raw_idx| {
            const count_buf = try frame_allocator.alloc(u8, 128);
            const is_filtered = switch (ui_model.view_mode) {
                .default, .all => false,
                .unflagged, .picks, .rejects => true,
            };
            const vis_pos = ui_model.visible_position orelse (raw_idx + 1);
            const vis_cnt = ui_model.visible_count;

            switch (ui_model.slideshow) {
                .active => |s| {
                    if (is_filtered) {
                        count_str = try std.mem.print(
                            count_buf,
                            "Image {} of {} ({} total) [Slide Show {d:.1}s]",
                            .{ vis_pos, vis_cnt, total_images, s.interval_s },
                        );
                    } else {
                        count_str = try std.mem.print(
                            count_buf,
                            "Image {} of {} [Slide Show {d:.1}s]",
                            .{ vis_pos, vis_cnt, s.interval_s },
                        );
                    }
                },
                .inactive => {
                    if (is_filtered) {
                        count_str = try std.mem.print(
                            count_buf,
                            "Image {} of {} ({} total)",
                            .{ vis_pos, vis_cnt, total_images },
                        );
                    } else if (is_loading) {
                        count_str = try std.mem.print(
                            count_buf,
                            "Image {} of {}...",
                            .{ vis_pos, vis_cnt },
                        );
                    } else {
                        count_str = try std.mem.print(
                            count_buf,
                            "Image {} of {}",
                            .{ vis_pos, vis_cnt },
                        );
                    }
                },
            }
        }
    } else if (is_loading) {
        count_str = "Loading images...";
    }

    var count_w: f32 = 0.0;
    if (count_str) |cstr| {
        count_w = measureText(cstr, 0, 12, measure_data).w;
    }

    var extra_w: f32 = 0.0;
    const is_pair_item = (ui_model.current_image_entry != null and
        ui_model.current_image_entry.?.isPair());
    if (is_pair_item) {
        extra_w += measureText("RAW+JPG", 0, 11, measure_data).w + 26.0;
    }
    if (ui_model.manga_mode) {
        extra_w += measureText("RTL", 0, 11, measure_data).w + 26.0;
    }
    if (ui_model.current_classification == .pick) {
        extra_w += measureText("PICK", 0, 11, measure_data).w + 26.0;
    } else if (ui_model.current_classification == .reject) {
        extra_w += measureText("REJECT", 0, 11, measure_data).w + 26.0;
    }
    if (ui_model.view_mode.badgeText()) |mode_txt| {
        extra_w += measureText(mode_txt, 0, 11, measure_data).w + 26.0;
    }
    if (count_str != null) extra_w += count_w + 14.0;

    const pill_padding_w: f32 = 36.0;
    const max_capsule_w =
        @max(available_width - 40.0 - snackbar_reservation, 100.0);
    const title_budget = max_capsule_w - pill_padding_w - extra_w;
    const max_title_w = if (title_budget > 30.0) title_budget else 30.0;

    const font_size_u16: u16 = 15;
    const title_display = truncateFilename(
        frame_allocator,
        raw_title,
        max_title_w,
        font_size_u16,
        measure_data,
    );
    const actual_title_w =
        measureText(title_display, 0, font_size_u16, measure_data).w;
    const title_pill_w = actual_title_w + pill_padding_w + extra_w;

    var total_bar_w: f32 = 0.0;
    if (has_title and snackbar_active != null) {
        total_bar_w = title_pill_w + 12.0 + snackbar_w;
    } else if (has_title) {
        total_bar_w = title_pill_w;
    } else {
        total_bar_w = snackbar_w;
    }

    const start_x = (available_width - total_bar_w) * 0.5;
    const bar_y = win_h - 48.0;
    const bar_h: f32 = 34.0;

    if (has_title) {
        try renderTitlePill(
            list,
            FRect{
                .x = start_x,
                .y = bar_y,
                .w = title_pill_w,
                .h = bar_h,
            },
            ui_model,
            title_display,
            count_str,
            title_progress,
            measure_data,
        );
    }

    if (snackbar_active) |snack| {
        const snack_x =
            if (has_title) start_x + title_pill_w + 12.0 else start_x;
        try renderSnackbarPill(
            list,
            FRect{
                .x = snack_x,
                .y = bar_y,
                .w = snackbar_w,
                .h = bar_h,
            },
            snack.message,
            snack.reveal,
            ui_model.overlays.enable_blur,
            measure_data,
        );
    }
}

fn renderEmptyState(
    list: *UiDrawList,
    view_dims: LogicalDims,
    measure_data: *const MeasureTextUserData,
) !void {
    const title_text = "No Images Loaded";
    const sub_text = "Drag & Drop images or directories here to view them.";

    const dims1 = measureText(title_text, 0, 22, measure_data);
    const dims2 = measureText(sub_text, 0, 14, measure_data);

    const pad_x: f32 = 40.0;
    const pad_y: f32 = 32.0;
    const gap: f32 = 16.0;

    const box_w = @max(dims1.w, dims2.w) + pad_x * 2.0;
    const box_h = pad_y * 2.0 + dims1.h + gap + dims2.h;

    const box_x = (view_dims.w - box_w) * 0.5;
    const box_y = (view_dims.h - box_h) * 0.5;
    const box_rect = FRect{ .x = box_x, .y = box_y, .w = box_w, .h = box_h };

    try list.addBorder(box_rect, .{
        .color = theme.overlay0,
        .width = .all(2),
        .corner_radius = .all(12),
        .tag = .drop_zone_box,
    });

    try list.addText(.{
        .x = (view_dims.w - dims1.w) * 0.5,
        .y = box_y + pad_y,
        .w = dims1.w,
        .h = dims1.h,
    }, .{
        .text = title_text,
        .color = theme.text,
        .font_size = 22,
        .font_id = 0,
    });

    try list.addText(.{
        .x = (view_dims.w - dims2.w) * 0.5,
        .y = box_y + pad_y + dims1.h + gap,
        .w = dims2.w,
        .h = dims2.h,
    }, .{
        .text = sub_text,
        .color = theme.subtext0,
        .font_size = 14,
        .font_id = 0,
    });
}

/// Formats the loading indicator text with the filename, middle-truncating
/// the filename if it exceeds available width.
fn formatLoadingText(
    allocator: std.mem.Allocator,
    filename_opt: ?[]const u8,
    max_w: f32,
    font_size: u16,
    measure_data: *const MeasureTextUserData,
) []const u8 {
    const fallback = if (max_w < 140.0) "Loading..." else "Loading image...";

    const fname = filename_opt orelse return fallback;
    if (fname.len == 0) return fallback;

    if (!measure_data.measurer.hasPrimaryFont()) {
        return allocator.print("Loading {s}...", .{fname}) catch |err| {
            std.log.warn(
                "Failed to format loading text fallback: {any}",
                .{err},
            );
            return fallback;
        };
    }

    const prefix = "Loading ";
    const prefix_w = measure_data.measurer.measure(
        0,
        @floatFromInt(font_size),
        prefix,
    ).w;

    if (max_w <= prefix_w + 30.0) {
        return fallback;
    }

    const avail_fname_w = max_w - prefix_w;
    const truncated_fname = truncateFilename(
        allocator,
        fname,
        avail_fname_w,
        font_size,
        measure_data,
    );

    if (std.mem.eql(u8, truncated_fname, "...")) {
        return fallback;
    }

    const is_middle_truncated =
        std.mem.find(u8, truncated_fname, "...") != null;
    if (is_middle_truncated) {
        return allocator.print("Loading {s}", .{truncated_fname}) catch |err| {
            std.log.warn("Failed to format loading text: {any}", .{err});
            return fallback;
        };
    }

    return allocator.print("Loading {s}...", .{truncated_fname}) catch |err| {
        std.log.warn("Failed to format loading text: {any}", .{err});
        return fallback;
    };
}

fn buildThumbnailUvRect(
    entry: CacheEntry,
    thumb_info: state.ThumbnailInfo,
    auth: PhysicalDims,
    rotation_angle: f32,
) UvRect {
    const pre_oriented = thumb_info.source.isPreOriented();
    const swapped = pre_oriented and
        entry.metadata.orientation.isDimensionSwapped();
    const ref_full: PhysicalDims = if (entry.metadata.full_dims) |fd|
        (if (swapped) .{ .w = fd.h, .h = fd.w } else fd)
    else
        .{ .w = 0.0, .h = 0.0 };
    var uv = view_transform.computeThumbnailUvCrop(
        ref_full,
        .{ .w = thumb_info.w, .h = thumb_info.h },
        thumb_info.dct_snapped,
    );
    uv.alpha = 1.0;
    uv.rotation_angle = if (pre_oriented)
        @mod(
            rotation_angle - entry.metadata.orientation.toDegrees() + 360.0,
            360.0,
        )
    else
        rotation_angle;
    uv.source_w = if (swapped) auth.h else auth.w;
    uv.source_h = if (swapped) auth.w else auth.h;
    return uv;
}

fn renderImageCanvas(
    list: *UiDrawList,
    ui_model: UiViewModel,
    entry: CacheEntry,
    draw_dims: LogicalDims,
    view_dims: LogicalDims,
    rotation_angle: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const draw_w = draw_dims.w;
    const draw_h = draw_dims.h;
    const is_image_dissolve = switch (ui_model.image_dissolve) {
        .active => true,
        .none => false,
    };
    if (is_image_dissolve and !entry.resident.asset.hasGpuTexture()) {
        return;
    }
    const is_thumb_crossfade = ui_model.is_thumb_crossfading;
    const auth = entry.getAuthoritativeDims();

    const canvas_x = (view_dims.w - draw_w) * 0.5;
    const canvas_y = (view_dims.h - draw_h) * 0.5;
    const canvas_rect =
        FRect{ .x = canvas_x, .y = canvas_y, .w = draw_w, .h = draw_h };

    if (is_thumb_crossfade) {
        switch (entry.resident.thumbnail) {
            .loaded => |thumb| {
                const thumb_tex = thumb.texture;
                const thumb_uv = buildThumbnailUvRect(
                    entry,
                    thumb.info,
                    auth,
                    rotation_angle,
                );
                try list.addImage(canvas_rect, .{
                    .image_data = thumb_tex.asOpaque(),
                    .uv = thumb_uv,
                });
            },
            .none, .pending, .staged_cpu, .not_available, .unloaded => {},
        }
    }

    var drew_thumb = false;
    switch (entry.resident.thumbnail) {
        .loaded => |thumb| {
            const show_thumb = ui_model.debug_show_thumb or
                (!entry.resident.asset.hasGpuTexture() and
                    !is_thumb_crossfade);
            if (show_thumb) {
                drew_thumb = true;
                const thumb_tex = thumb.texture;
                const uv_crop = buildThumbnailUvRect(
                    entry,
                    thumb.info,
                    auth,
                    rotation_angle,
                );
                try list.addImage(canvas_rect, .{
                    .image_data = thumb_tex.asOpaque(),
                    .uv = uv_crop,
                });
            }
        },
        .none, .pending, .staged_cpu, .not_available, .unloaded => {},
    }

    if (!drew_thumb) switch (entry.resident.asset) {
        .loaded_gpu, .promoting_gpu => {
            const gpu = switch (entry.resident.asset) {
                .loaded_gpu => |g| g,
                .promoting_gpu => |promo| promo.active,
                .loaded_cpu, .none, .failed => unreachable,
            };
            const tex = gpu.gpu_texture;
            const full_alpha = if (is_image_dissolve)
                std.math.clamp(ui_model.anim(.image_crossfade), 0.0, 1.0)
            else if (is_thumb_crossfade)
                ui_model.anim(.thumb_crossfade)
            else
                1.0;
            const uv = UvRect{
                .alpha = full_alpha,
                .rotation_angle = rotation_angle,
                .source_w = auth.w,
                .source_h = auth.h,
            };
            try list.addImage(canvas_rect, .{
                .image_data = tex.asOpaque(),
                .uv = uv,
            });
        },
        .loaded_cpu => {},
        .none => {
            if (entry.inflight) |dec| {
                const elapsed = ui_model.current_time_ms -| dec.start_time_ms;
                const show_loading = elapsed > state.LOADING_GRACE_PERIOD_MS;
                const font_size: u16 = 22;

                if (show_loading) {
                    const filename_opt: ?[]const u8 =
                        if (ui_model.current_image_entry) |entry_item|
                            entry_item.getBasename()
                        else if (ui_model.current_index) |idx|
                            (if (ui_model.getMediaEntry(idx)) |media|
                                media.getBasename()
                            else
                                null)
                        else
                            null;

                    const container_w = if (draw_w > 0)
                        @min(draw_w, view_dims.w)
                    else
                        view_dims.w;
                    const max_text_w = @max(container_w - 40.0, 0.0);
                    const loading_text = formatLoadingText(
                        frame_allocator,
                        filename_opt,
                        max_text_w,
                        font_size,
                        measure_data,
                    );
                    const dims =
                        measureText(loading_text, 0, font_size, measure_data);
                    const text_x = (view_dims.w - dims.w) * 0.5;
                    const text_y = (view_dims.h - dims.h) * 0.5;
                    try list.addText(.{
                        .x = text_x,
                        .y = text_y,
                        .w = dims.w,
                        .h = dims.h,
                    }, .{
                        .text = loading_text,
                        .color = theme.pink,
                        .font_size = font_size,
                        .font_id = 0,
                    });
                }
            }
        },
        .failed => {
            const fail_msg = "Failed to Load Image";
            const dims = measureText(fail_msg, 0, 22, measure_data);
            try list.addText(.{
                .x = (view_dims.w - dims.w) * 0.5,
                .y = (view_dims.h - dims.h) * 0.5,
                .w = dims.w,
                .h = dims.h,
            }, .{
                .text = fail_msg,
                .color = theme.red,
                .font_size = 22,
                .font_id = 0,
            });
        },
    };
}

fn renderDissolvePrevQuad(
    list: *UiDrawList,
    ui_model: UiViewModel,
    view_dims: LogicalDims,
    scale: DpiScale,
) !void {
    const dissolve = switch (ui_model.image_dissolve) {
        .none => return,
        .active => |d| d,
    };
    const prev_entry = dissolve.prev_entry;
    const gpu = switch (prev_entry.resident.asset) {
        .loaded_gpu => |g| g,
        .promoting_gpu => |promo| promo.active,
        .loaded_cpu, .none, .failed => return,
    };

    const prev_auth = prev_entry.getAuthoritativeDims();
    const prev_dims = computeDrawDims(
        prev_entry,
        view_dims,
        scale,
        dissolve.prev_rotation,
        ui_model.viewport.fit_mode,
    );
    const progress = std.math.clamp(ui_model.anim(.image_crossfade), 0.0, 1.0);
    const prev_alpha = 1.0 - (progress * progress);
    const prev_tex = gpu.gpu_texture;

    const prev_uv = UvRect{
        .alpha = prev_alpha,
        .rotation_angle = dissolve.prev_rotation,
        .override_zoom = dissolve.prev_zoom,
        .override_pan_x = dissolve.prev_pan_x,
        .override_pan_y = dissolve.prev_pan_y,
        .source_w = prev_auth.w,
        .source_h = prev_auth.h,
    };

    const quad_x = (view_dims.w - prev_dims.w) * 0.5;
    const quad_y = (view_dims.h - prev_dims.h) * 0.5;
    try list.addImage(.{
        .x = quad_x,
        .y = quad_y,
        .w = prev_dims.w,
        .h = prev_dims.h,
    }, .{
        .image_data = prev_tex.asOpaque(),
        .uv = prev_uv,
    });
}

fn renderViewport(
    interaction: *state.InteractionState,
    list: *UiDrawList,
    ui_model: UiViewModel,
    current_entry: anytype,
    draw_dims: LogicalDims,
    view_dims: LogicalDims,
    scale: DpiScale,
    total_images: usize,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const viewport_rect =
        FRect{ .x = 0.0, .y = 0.0, .w = view_dims.w, .h = view_dims.h };
    interaction.viewport = viewport_rect;

    try list.pushScissor(viewport_rect);
    defer list.popScissor() catch {};

    try renderDissolvePrevQuad(
        list,
        ui_model,
        view_dims,
        scale,
    );

    if (current_entry) |entry| {
        try renderImageCanvas(
            list,
            ui_model,
            entry,
            draw_dims,
            view_dims,
            ui_model.viewport.rotation_angle,
            frame_allocator,
            measure_data,
        );
    } else if (ui_model.visible_state == .filtered_empty) {
        const fe = ui_model.visible_state.filtered_empty;
        const subtext = frame_allocator.print(
            "{s}: 0 of {} images match -- press 'v' to cycle filter",
            .{ fe.mode.label(), fe.total_count },
        ) catch "No images match current filter";

        const title_msg = "No matching images in active filter";
        const dims1 = measureText(title_msg, 0, 22, measure_data);
        const dims2 = measureText(subtext, 0, 14, measure_data);
        const total_h = dims1.h + 12.0 + dims2.h;
        const start_y = (view_dims.h - total_h) * 0.5;

        try list.addText(.{
            .x = (view_dims.w - dims1.w) * 0.5,
            .y = start_y,
            .w = dims1.w,
            .h = dims1.h,
        }, .{
            .text = title_msg,
            .color = theme.yellow,
            .font_size = 22,
            .font_id = 0,
        });

        try list.addText(.{
            .x = (view_dims.w - dims2.w) * 0.5,
            .y = start_y + dims1.h + 12.0,
            .w = dims2.w,
            .h = dims2.h,
        }, .{
            .text = subtext,
            .color = theme.subtext0,
            .font_size = 14,
            .font_id = 0,
        });
    } else if (ui_model.is_loading_files or total_images > 0) {
        const title_msg = "Loading Images...";
        const subtext = "Discovering files in background...";
        const dims1 = measureText(title_msg, 0, 22, measure_data);
        const dims2 = measureText(subtext, 0, 14, measure_data);
        const total_h = dims1.h + 12.0 + dims2.h;
        const start_y = (view_dims.h - total_h) * 0.5;

        try list.addText(.{
            .x = (view_dims.w - dims1.w) * 0.5,
            .y = start_y,
            .w = dims1.w,
            .h = dims1.h,
        }, .{
            .text = title_msg,
            .color = theme.pink,
            .font_size = 22,
            .font_id = 0,
        });

        try list.addText(.{
            .x = (view_dims.w - dims2.w) * 0.5,
            .y = start_y + dims1.h + 12.0,
            .w = dims2.w,
            .h = dims2.h,
        }, .{
            .text = subtext,
            .color = theme.subtext0,
            .font_size = 14,
            .font_id = 0,
        });
    } else {
        try renderEmptyState(list, view_dims, measure_data);
    }
}

test "formatLoadingText - fallback when no filename" {
    var data = MeasureTextUserData{};
    const res =
        formatLoadingText(std.testing.allocator, null, 400.0, 22, &data);
    try std.testing.expectEqualStrings("Loading image...", res);
}

test "formatLoadingText - with filename" {
    var data = MeasureTextUserData{};
    const res = formatLoadingText(
        std.testing.allocator,
        "photo.jpg",
        400.0,
        22,
        &data,
    );
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("Loading photo.jpg...", res);
}

test "formatLoadingText - fallback when empty filename" {
    var data = MeasureTextUserData{};
    const res = formatLoadingText(
        std.testing.allocator,
        "",
        400.0,
        22,
        &data,
    );
    try std.testing.expectEqualStrings("Loading image...", res);
}

test "formatLoadingText - narrow viewport fallback" {
    var data = MeasureTextUserData{};
    const res =
        formatLoadingText(std.testing.allocator, null, 100.0, 22, &data);
    try std.testing.expectEqualStrings("Loading...", res);
}

test "computeDrawDims - matches physical DPI scale in shrink and none modes" {
    const entry = CacheEntry{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .cpu = .{
                        .surface = .{ .ptr = undefined },
                        .w = 1200,
                        .h = 900,
                        .size_bytes = 1000,
                    },
                },
            },
        },
        .metadata = .{ .full_dims = .{ .w = 1200, .h = 900 } },
    };

    const view_dims = LogicalDims{ .w = 1000.0, .h = 800.0 };
    const retina_scale = DpiScale.init(2.0, 2.0);

    const shrink_dims = computeDrawDims(
        entry,
        view_dims,
        retina_scale,
        0.0,
        .shrink,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 600.0), shrink_dims.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 450.0), shrink_dims.h, 0.001);

    const none_dims = computeDrawDims(
        entry,
        view_dims,
        retina_scale,
        0.0,
        .none,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 600.0), none_dims.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 450.0), none_dims.h, 0.001);

    const full_dims = computeDrawDims(
        entry,
        view_dims,
        retina_scale,
        0.0,
        .full,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0), full_dims.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 750.0), full_dims.h, 0.001);
}

test "renderViewport - floating crossfade quads allow Viewport hit-testing" {
    var interaction_inst: state.InteractionState = .{};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var data = MeasureTextUserData{};
    const entry = CacheEntry.stubLoadedGpuForTest(
        .{ .w = 800.0, .h = 600.0 },
        .{ .w = 160.0, .h = 120.0 },
    );
    var pal_state = try PaletteState.init(std.testing.allocator);
    defer pal_state.deinit(std.testing.allocator);
    const model = UiViewModel{
        .is_fullscreen = false,
        .total_images = 2,
        .current_index = 1,
        .current_image_entry = null,
        .current_entry = entry,
        .current_classification = .unflagged,
        .view_mode = .default,
        .visible_state = .empty_directory,
        .visible_count = 2,
        .visible_position = 2,
        .is_loading_files = false,
        .slideshow = .inactive,
        .manga_mode = false,
        .overlays = .{},
        .window_title = "test",
        .viewport = .{},
        .palette = &pal_state,
        .snackbar = .none,
        .anim_values = @splat(0.5),
        .debug_show_thumb = false,
        .is_thumb_crossfading = true,
        .image_dissolve = .{
            .active = .{
                .prev_entry = entry,
                .prev_rotation = 0.0,
                .prev_zoom = 1.0,
                .prev_pan_x = 0.0,
                .prev_pan_y = 0.0,
            },
        },
        .current_time_ms = 100,
    };

    interaction_inst.beginFrameLayout();
    var draw_list = UiDrawList{ .allocator = arena.allocator() };
    try renderViewport(
        &interaction_inst,
        &draw_list,
        model,
        model.current_entry,
        .{ .w = 800.0, .h = 600.0 },
        .{ .w = 1000.0, .h = 800.0 },
        .{ .x = 1.0, .y = 1.0 },
        2,
        arena.allocator(),
        &data,
    );

    interaction_inst.setPointerStateForTest(.{ .x = 500.0, .y = 400.0 });
    try std.testing.expect(interaction_inst.isPointerOverViewport());
}

test "buildThumbnailUvRect handles pre-oriented Freedesktop cached thumbnails" {
    const entry = CacheEntry{
        .inflight = .{},
        .metadata = .{
            .full_dims = .{ .w = 6000.0, .h = 4000.0 },
            .orientation = .rotate_90,
        },
    };
    const auth = entry.getAuthoritativeDims();

    const embedded_uv = buildThumbnailUvRect(
        entry,
        .{ .w = 160.0, .h = 120.0, .source = .embedded_header },
        auth,
        90.0,
    );
    try std.testing.expectEqual(@as(f32, 90.0), embedded_uv.rotation_angle);
    try std.testing.expectEqual(@as(f32, 6000.0), embedded_uv.source_w);
    try std.testing.expectEqual(@as(f32, 4000.0), embedded_uv.source_h);

    const cached_uv = buildThumbnailUvRect(
        entry,
        .{ .w = 170.0, .h = 256.0, .source = .freedesktop_cache },
        auth,
        90.0,
    );
    try std.testing.expectEqual(@as(f32, 0.0), cached_uv.rotation_angle);
    try std.testing.expectEqual(@as(f32, 4000.0), cached_uv.source_w);
    try std.testing.expectEqual(@as(f32, 6000.0), cached_uv.source_h);
}
