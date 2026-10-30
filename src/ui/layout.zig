const clay = @import("zclay");
const core = @import("core");
const edit_panel = @import("edit_panel.zig");
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

const CacheEntry = core.image.CacheEntry;
const ElementTag = state.ElementTag;
const empty_fonts = gpu_pkg.text_cache.empty_fonts;
const FontSet = gpu_pkg.text_cache.FontSet;
const FrameInput = state.FrameInput;
const GpuTexture = gpu_pkg.graphics.GpuTexture;
const hasPrimaryFont = gpu_pkg.text_cache.hasPrimaryFont;
const MeasureTextUserData = text_utils.MeasureTextUserData;
const measureFontText = gpu_pkg.text_cache.measureText;
const measureText = text_utils.measureText;
const PacketBuildContext = gpu_pkg.pass.PacketBuildContext;
const PaletteState = palette_pkg.PaletteState;
const renderEditPanel = edit_panel.renderEditPanel;
const renderPalette = palette.renderPalette;
const RenderPacket = gpu_pkg.pass.RenderPacket;
const RenderResources = gpu_pkg.graphics.RenderResources;
const renderStatsOverlay = stats.renderStatsOverlay;
const truncateFilename = text_utils.truncateFilename;
const UiRenderMetrics = state.UiRenderMetrics;
const UiViewModel = view_model.UiViewModel;
const view_transform = state.view_transform;
const WindowHandle = gpu_pkg.graphics.WindowHandle;

/// Computes fitted layout dimensions in logical UI points (`LogicalDims`) for
/// an image cache entry within available logical viewport bounds, evaluating
/// preset fit modes in physical framebuffer space via `scale`.
pub fn computeDrawDims(
    entry_opt: ?CacheEntry,
    available_dims: state.LogicalDims,
    scale: state.DpiScale,
    rotation_angle: f32,
    fit_mode: intents.ZoomPreset,
) state.LogicalDims {
    const entry = entry_opt orelse return .{ .w = 0, .h = 0 };
    const auth = entry.getAuthoritativeDims();

    if (auth.w > 0 and auth.h > 0) {
        const is_loading = entry.resident.asset != .loaded_gpu and
            entry.resident.asset != .loaded_cpu;
        const only_has_thumb = entry.metadata.full_dims == null and
            entry.metadata.raw_metadata.getSensorDims() == null and
            entry.resident.thumbnail != .none;
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

/// Builds the complete UI layout hierarchy via Clay, tessellates geometry,
/// and records draw commands for the frame.
pub fn renderFrame(
    ui_model: UiViewModel,
    gpu_res: *RenderResources,
    input: FrameInput,
    gpa_allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    fonts: FontSet,
    measure_data: *MeasureTextUserData,
    target_window: ?WindowHandle,
    render_metrics: ?*UiRenderMetrics,
    capture_filename: ?[:0]const u8,
) !void {
    const width = input.win_w;
    const height = input.win_h;
    const scale_x = input.scale_x;
    const scale_y = input.scale_y;
    const dpi_scale = input.dpiScale();
    const current_entry = ui_model.current_entry;

    const total_images = ui_model.total_images;

    // Calculate Image Fitting Layout Boundaries
    const edit_progress = ui_model.anim(.edit_panel);
    const docked_w = edit_panel.PANEL_WIDTH * edit_progress;

    const debug_w: f32 = if (clay.isDebugModeEnabled())
        @as(f32, @floatFromInt(clay.Clay__debugViewWidth))
    else
        0.0;

    // Main workspace width (window width minus Clay debug inspector)
    const main_layout_w = @max(width - debug_w, 1.0);

    // Viewport bounds for image scaling (workspace minus docked edit panel)
    const available_width = @max(main_layout_w - docked_w, 1.0);

    const padding: f32 = 0.0;
    const view_dims = state.LogicalDims{
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

    clay.beginLayout();

    // Main Layout Container
    clay.UI()(.{
        .id = clay.getElementId("MainLayout"),
        .layout = .{
            .sizing = .{
                .w = if (clay.isDebugModeEnabled())
                    .fixed(main_layout_w)
                else
                    .grow,
                .h = .grow,
            },
            .direction = .left_to_right,
        },
        .background_color = theme.mantle,
    })({
        try renderPalette(
            ui_model,
            frame_allocator,
            measure_data,
        );

        try renderStatsOverlay(
            ui_model,
            draw_dims.w,
            draw_dims.h,
            frame_allocator,
            measure_data,
        );

        try renderBottomOverlayBar(
            ui_model,
            available_width,
            docked_w,
            frame_allocator,
            measure_data,
        );

        renderViewport(
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
                ui_model,
                docked_w,
                edit_progress,
                frame_allocator,
            );
        }
    });

    // Clay's internal debug panel layout elements are generated inside
    // clay.endLayout(). Flag measure_data so measureText scales debug text down
    // (16px -> 12px) during layout.
    measure_data.is_debug_measuring = clay.isDebugModeEnabled();
    const render_commands = clay.endLayout();
    measure_data.is_debug_measuring = false;

    // Render Frame
    const RenderContext = struct {
        view_params: state.ViewportParams,
        fonts: FontSet,
        render_commands: []const clay.RenderCommand,

        fn buildPacket(
            ctx: @This(),
            build_ctx: PacketBuildContext,
        ) anyerror!RenderPacket {
            return renderer.buildRenderPacket(
                ctx.view_params,
                build_ctx,
                ctx.fonts,
                ctx.render_commands,
            );
        }
    };

    try gpu_pkg.pass.executeFrame(
        gpu_res,
        ui_model.viewport,
        gpa_allocator,
        frame_allocator,
        .{
            .window = target_window,
            .width = @intFromFloat(width),
            .height = @intFromFloat(height),
            .scale_x = scale_x,
            .scale_y = scale_y,
            .needs_blur = renderer.hasBlurredSurface(render_commands),
            .metrics = render_metrics,
            .capture_filename = capture_filename,
        },
        RenderContext{
            .view_params = ui_model.viewport,
            .fonts = fonts,
            .render_commands = render_commands,
        },
        RenderContext.buildPacket,
    );
}

fn renderTitlePill(
    ui_model: UiViewModel,
    available_width: f32,
    snackbar_reservation: f32,
    progress: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const raw_title = ui_model.window_title;

    const is_loading = ui_model.is_loading_files;
    const total_images = ui_model.total_images;
    var count_str: ?[]const u8 = null;
    if (total_images > 0) {
        if (ui_model.current_index) |raw_idx| {
            const count_buf = try frame_allocator.alloc(u8, 128);
            const is_filtered = ui_model.view_mode != .all and ui_model.view_mode != .default;
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
        var count_cfg = clay.TextElementConfig{
            .font_id = 0,
            .font_size = 12,
        };
        count_w = measureText(cstr, &count_cfg, measure_data).w;
    }

    var extra_w: f32 = 0.0;
    const is_pair_item = (ui_model.current_image_entry != null and
        ui_model.current_image_entry.?.isPair());
    if (is_pair_item) {
        extra_w += 78.0; // RAW+JPG badge width + gap 14
    }
    if (ui_model.manga_mode) {
        extra_w += 48.0; // RTL badge width (padding 12 + border 2 + text ~20) + gap 14
    }
    if (ui_model.current_classification != .unflagged) {
        extra_w += 58.0; // Classification badge width + gap 14
    }
    if (ui_model.view_mode.badgeText() != null) {
        extra_w += 84.0; // Filter mode badge width + gap 14
    }
    if (count_str != null) {
        extra_w += count_w + 14.0; // count text + 14px gap
    }

    const pill_padding_w: f32 = 36.0; // 18 left + 18 right
    const max_capsule_w = @max(available_width - 40.0 - snackbar_reservation, 100.0);
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

    clay.UI()(.{
        .id = clay.getElementId("TitleOverlay"),
        .layout = .{
            .sizing = .{
                .w = .fit,
                .h = .fit,
            },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .center, .y = .center },
            .child_gap = 14,
            .padding = .{
                .left = 18,
                .right = 18,
                .top = 8,
                .bottom = 8,
            },
        },
        .background_color = theme.withAlpha(theme.mantle, 0.75 * progress),
        .corner_radius = .all(10),
        .user_data = if (ui_model.overlays.enable_blur)
            @ptrFromInt(ElementTag.blurred_surface.toInt())
        else
            null,
        .border = .{
            .width = .all(1),
            .color = theme.withAlpha(theme.surface0, 0.7 * progress),
        },
    })({
        clay.text(title_display, .{
            .color = theme.withAlpha(theme.text, progress),
            .font_size = font_size_u16,
            .font_id = 0,
        });

        if (ui_model.current_classification == .pick) {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                },
                .background_color = theme.withAlpha(theme.green, 0.25 * progress),
                .corner_radius = .all(4),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = theme.withAlpha(theme.green, progress),
                },
            })({
                clay.text("PICK", .{
                    .color = theme.withAlpha(theme.green, progress),
                    .font_size = 11,
                    .font_id = 0,
                });
            });
        } else if (ui_model.current_classification == .reject) {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                },
                .background_color = theme.withAlpha(theme.red, 0.25 * progress),
                .corner_radius = .all(4),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = theme.withAlpha(theme.red, progress),
                },
            })({
                clay.text("REJECT", .{
                    .color = theme.withAlpha(theme.red, progress),
                    .font_size = 11,
                    .font_id = 0,
                });
            });
        }

        if (ui_model.view_mode.badgeText()) |mode_txt| {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                },
                .background_color = theme.withAlpha(theme.crust, progress),
                .corner_radius = .all(4),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = theme.withAlpha(theme.blue, progress),
                },
            })({
                clay.text(mode_txt, .{
                    .color = theme.withAlpha(theme.blue, progress),
                    .font_size = 11,
                    .font_id = 0,
                });
            });
        }

        if (ui_model.manga_mode) {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                },
                .background_color = theme.withAlpha(theme.crust, progress),
                .corner_radius = .all(4),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = theme.withAlpha(theme.peach, progress),
                },
            })({
                clay.text("RTL", .{
                    .color = theme.withAlpha(theme.peach, progress),
                    .font_size = 11,
                    .font_id = 0,
                });
            });
        }

        if (is_pair_item) {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                },
                .background_color = theme.withAlpha(theme.crust, progress),
                .corner_radius = .all(4),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = theme.withAlpha(theme.mauve, progress),
                },
            })({
                clay.text("RAW+JPG", .{
                    .color = theme.withAlpha(theme.mauve, progress),
                    .font_size = 11,
                    .font_id = 0,
                });
            });
        }

        if (count_str) |cstr| {
            clay.text(cstr, .{
                .color = theme.withAlpha(theme.subtext0, progress),
                .font_size = 12,
                .font_id = 0,
            });
        }
    });
}

fn renderSnackbarPill(
    message: []const u8,
    progress: f32,
    enable_blur: bool,
) void {
    clay.UI()(.{
        .id = clay.getElementId("SnackbarOverlay"),
        .layout = .{
            .sizing = .{
                .w = .fit,
                .h = .fit,
            },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .center, .y = .center },
            .child_gap = 8,
            .padding = .{
                .left = 18,
                .right = 18,
                .top = 8,
                .bottom = 8,
            },
        },
        .background_color = theme.withAlpha(theme.mantle, 0.75 * progress),
        .corner_radius = .all(10),
        .user_data = if (enable_blur) @ptrFromInt(ElementTag.blurred_surface.toInt()) else null,
        .border = .{
            .width = .all(1),
            .color = theme.withAlpha(theme.surface0, 0.7 * progress),
        },
    })({
        clay.text(message, .{
            .color = theme.withAlpha(theme.text, progress),
            .font_size = 14,
            .font_id = 0,
            .wrap_mode = .none,
        });
    });
}

fn renderBottomOverlayBar(
    ui_model: UiViewModel,
    available_width: f32,
    docked_w: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const title_progress = ui_model.anim(.title_overlay);
    const has_title = title_progress > 0.001;
    const snackbar_active = ui_model.snackbar.getActive();

    if (!has_title and snackbar_active == null) return;

    var snackbar_reservation: f32 = 0.0;
    if (snackbar_active) |snack| {
        var snack_cfg = clay.TextElementConfig{
            .font_id = 0,
            .font_size = 14,
        };
        const text_w = measureText(snack.message, &snack_cfg, measure_data).w;
        snackbar_reservation = text_w + 36.0 + 12.0; // pill padding (36) + child_gap (12)
    }

    clay.UI()(.{
        .id = clay.getElementId("BottomOverlayBar"),
        .layout = .{
            .sizing = .{
                .w = .fit,
                .h = .fit,
            },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .center, .y = .center },
            .child_gap = 12,
        },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{
                .element = .center_bottom,
                .parent = .center_bottom,
            },
            .offset = .{
                .x = -docked_w * 0.5,
                .y = -14,
            },
            .z_index = 50,
            .pointer_capture_mode = .passthrough,
        },
    })({
        if (has_title) {
            try renderTitlePill(
                ui_model,
                available_width,
                snackbar_reservation,
                title_progress,
                frame_allocator,
                measure_data,
            );
        }

        if (snackbar_active) |snack| {
            renderSnackbarPill(
                snack.message,
                snack.reveal,
                ui_model.overlays.enable_blur,
            );
        }
    });
}

fn renderEmptyState() void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
            .direction = .top_to_bottom,
            .child_alignment = .{ .x = .center, .y = .center },
        },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID("DropZoneBox"),
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .direction = .top_to_bottom,
                .child_alignment = .{ .x = .center, .y = .center },
                .child_gap = 16,
                .padding = .{
                    .left = 40,
                    .right = 40,
                    .top = 32,
                    .bottom = 32,
                },
            },
            .border = .{
                .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
                .color = theme.overlay0,
            },
            .corner_radius = .all(12),
            .user_data = @ptrFromInt(@backingInt(ElementTag.drop_zone_box)),
        })({
            clay.text("No Images Loaded", .{
                .color = theme.text,
                .font_size = 22,
                .font_id = 0,
            });

            clay.text("Drag & Drop images or directories here to view them.", .{
                .color = theme.subtext0,
                .font_size = 14,
                .font_id = 0,
            });
        });
    });
}

/// Formats the loading indicator text with the filename, middle-truncating
/// the filename if it exceeds available width.
///
/// Parameters:
/// - `allocator`: Frame arena allocator used for temporary string construction.
/// - `filename_opt`: Basename of the file being decoded, or null.
/// - `max_w`: Maximum available width in logical pixels.
/// - `font_size`: Point size of the font used for measurement and display.
/// - `measure_data`: Active font and text measurement context.
///
/// Returns:
/// A string slice valid for the current frame lifetime.
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

    if (!hasPrimaryFont(measure_data.fonts)) {
        // Fallback for headless test environments without loaded TTF fonts
        return allocator.print("Loading {s}...", .{fname}) catch |err| {
            std.log.warn(
                "Failed to format loading text fallback: {any}",
                .{err},
            );
            return fallback;
        };
    }

    // Measure the prefix "Loading "
    const prefix = "Loading ";
    const prefix_w = measureFontText(
        measure_data.fonts,
        0,
        @floatFromInt(font_size),
        prefix,
    ).w;

    // If available width cannot comfortably fit prefix plus a minimal
    // filename, fall back
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

    // If truncation collapsed to just "...", avoid "Loading ......" by returning fallback
    if (std.mem.eql(u8, truncated_fname, "...")) {
        return fallback;
    }

    // If already middle-truncated ("..."), avoid double ellipsis at the end
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
    auth: state.PhysicalDims,
    rotation_angle: f32,
) state.UvRect {
    const pre_oriented = thumb_info.source.isPreOriented();
    const swapped = pre_oriented and
        entry.metadata.orientation.isDimensionSwapped();
    const ref_full: state.PhysicalDims = if (entry.metadata.full_dims) |fd|
        (if (swapped) .{ .w = fd.h, .h = fd.w } else fd)
    else
        .{ .w = 0.0, .h = 0.0 };
    var uv = state.computeThumbnailUvCrop(
        ref_full.w,
        ref_full.h,
        thumb_info.w,
        thumb_info.h,
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
    ui_model: UiViewModel,
    entry: CacheEntry,
    draw_w: f32,
    draw_h: f32,
    view_w: f32,
    rotation_angle: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) void {
    if (ui_model.image_dissolve == .active and
        entry.resident.asset != .loaded_gpu)
    {
        return;
    }
    const is_thumb_crossfade = ui_model.is_thumb_crossfading;
    const auth = entry.getAuthoritativeDims();

    if (is_thumb_crossfade) {
        const thumb = entry.resident.thumbnail.loaded;
        const thumb_tex = thumb.texture;
        const thumb_uv = buildThumbnailUvRect(
            entry,
            thumb.info,
            auth,
            rotation_angle,
        );
        const thumb_uv_ptr = frame_allocator.create(state.UvRect) catch |err|
            blk: {
                std.log.warn(
                    "Failed to allocate UvRect for thumbnail underlay: {any}",
                    .{err},
                );
                break :blk null;
            };
        if (thumb_uv_ptr) |ptr| {
            ptr.* = thumb_uv;
        }
        clay.UI()(.{
            .id = clay.getElementId("ThumbCrossfadeUnderlay"),
            .layout = .{
                .sizing = .{
                    .w = .fixed(draw_w),
                    .h = .fixed(draw_h),
                },
            },
            .floating = .{
                .attach_to = .to_parent,
                .clip_to = .to_attached_parent,
                .attach_points = .{
                    .element = .center_center,
                    .parent = .center_center,
                },
                .offset = .{ .x = 0.0, .y = 0.0 },
                .z_index = 0,
                .pointer_capture_mode = .passthrough,
            },
            .image = .{
                .image_data = thumb_tex.asOpaque(),
            },
            .user_data = if (thumb_uv_ptr) |ptr| @ptrCast(ptr) else null,
        })({});
    }

    var drew_thumb = false;
    switch (entry.resident.thumbnail) {
        .loaded => |thumb| {
            const show_thumb = ui_model.debug_show_thumb or
                (entry.resident.asset != .loaded_gpu and !is_thumb_crossfade);
            if (show_thumb) {
                drew_thumb = true;
                const thumb_tex = thumb.texture;
                const uv_crop = buildThumbnailUvRect(
                    entry,
                    thumb.info,
                    auth,
                    rotation_angle,
                );
                const uv_crop_ptr =
                    frame_allocator.create(state.UvRect) catch |err| blk: {
                        std.log.warn(
                            "Failed to allocate UvRect for thumbnail: {any}",
                            .{err},
                        );
                        break :blk null;
                    };
                if (uv_crop_ptr) |ptr| {
                    ptr.* = uv_crop;
                }
                clay.UI()(.{
                    .id = clay.getElementId("ImageCanvas"),
                    .layout = .{
                        .sizing = .{
                            .w = .fixed(draw_w),
                            .h = .fixed(draw_h),
                        },
                    },
                    .image = .{
                        .image_data = thumb_tex.asOpaque(),
                    },
                    .user_data = if (uv_crop_ptr) |ptr| @ptrCast(ptr) else null,
                })({});
            }
        },
        .none, .pending, .not_available, .unloaded => {},
    }

    if (!drew_thumb) switch (entry.resident.asset) {
        .loaded_gpu => |gpu| {
            const tex = gpu.gpu_texture;
            const is_image_dissolve = ui_model.image_dissolve == .active;
            const full_alpha = if (is_image_dissolve)
                std.math.clamp(ui_model.anim(.image_crossfade), 0.0, 1.0)
            else if (is_thumb_crossfade)
                ui_model.anim(.thumb_crossfade)
            else
                1.0;
            const uv_ptr = frame_allocator.create(state.UvRect) catch |err|
                blk: {
                    std.log.warn("Failed to allocate UvRect: {any}", .{err});
                    break :blk null;
                };
            if (uv_ptr) |ptr| {
                ptr.* = .{
                    .alpha = full_alpha,
                    .rotation_angle = rotation_angle,
                    .source_w = auth.w,
                    .source_h = auth.h,
                };
            }
            clay.UI()(.{
                .id = clay.getElementId("ImageCanvas"),
                .layout = .{
                    .sizing = .{
                        .w = .fixed(draw_w),
                        .h = .fixed(draw_h),
                    },
                },
                .floating = if (is_image_dissolve or is_thumb_crossfade) .{
                    .attach_to = .to_parent,
                    .clip_to = .to_attached_parent,
                    .attach_points = .{
                        .element = .center_center,
                        .parent = .center_center,
                    },
                    .offset = .{ .x = 0.0, .y = 0.0 },
                    .z_index = 1,
                    .pointer_capture_mode = .passthrough,
                } else .{},
                .image = .{
                    .image_data = tex.asOpaque(),
                },
                .user_data = if (uv_ptr) |ptr| @ptrCast(ptr) else null,
            })({});
        },
        .loaded_cpu => {
            clay.UI()(.{
                .id = clay.getElementId("ImageCanvas"),
                .layout = .{
                    .sizing = .{
                        .w = .fixed(draw_w),
                        .h = .fixed(draw_h),
                    },
                },
            })({});
        },
        .none => {
            if (entry.inflight) |dec| {
                const elapsed = ui_model.current_time_ms -| dec.start_time_ms;
                const show_loading = elapsed > state.LOADING_GRACE_PERIOD_MS;
                const font_size: u16 = 22;

                const loading_text = if (show_loading) blk: {
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

                    const container_w =
                        if (draw_w > 0) @min(draw_w, view_w) else view_w;
                    const max_text_w = @max(container_w - 40.0, 0.0);
                    break :blk formatLoadingText(
                        frame_allocator,
                        filename_opt,
                        max_text_w,
                        font_size,
                        measure_data,
                    );
                } else "";

                if (draw_w > 0 and draw_h > 0) {
                    clay.UI()(.{
                        .id = clay.getElementId("ImageCanvas"),
                        .layout = .{
                            .sizing = .{
                                .w = .fixed(draw_w),
                                .h = .fixed(draw_h),
                            },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = 10,
                        },
                    })({
                        if (show_loading) {
                            clay.text(loading_text, .{
                                .color = theme.pink,
                                .font_size = font_size,
                                .font_id = 0,
                                .wrap_mode = .none,
                            });
                        }
                    });
                } else {
                    clay.UI()(.{
                        .id = clay.getElementId("ImageCanvas"),
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .grow },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = 10,
                        },
                    })({
                        if (show_loading) {
                            clay.text(loading_text, .{
                                .color = theme.pink,
                                .font_size = font_size,
                                .font_id = 0,
                                .wrap_mode = .none,
                            });
                        }
                    });
                }
            }
        },
        .failed => {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .grow },
                    .direction = .top_to_bottom,
                    .child_alignment = .{ .x = .center, .y = .center },
                    .child_gap = 10,
                },
            })({
                clay.text("Failed to Load Image", .{
                    .color = theme.red,
                    .font_size = 22,
                    .font_id = 0,
                });
            });
        },
    };
}

fn renderDissolvePrevQuad(
    ui_model: UiViewModel,
    frame_allocator: std.mem.Allocator,
    view_dims: state.LogicalDims,
    scale: state.DpiScale,
) void {
    const dissolve = switch (ui_model.image_dissolve) {
        .none => return,
        .active => |d| d,
    };
    const prev_entry = dissolve.prev_entry;
    const gpu = switch (prev_entry.resident.asset) {
        .loaded_gpu => |g| g,
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

    const prev_uv_ptr = frame_allocator.create(state.UvRect) catch |err| blk: {
        std.log.warn(
            "Failed to allocate UvRect for image dissolve: {any}",
            .{err},
        );
        break :blk null;
    };
    if (prev_uv_ptr) |ptr| {
        ptr.* = .{
            .alpha = prev_alpha,
            .rotation_angle = dissolve.prev_rotation,
            .override_zoom = dissolve.prev_zoom,
            .override_pan_x = dissolve.prev_pan_x,
            .override_pan_y = dissolve.prev_pan_y,
            .source_w = prev_auth.w,
            .source_h = prev_auth.h,
        };
    }

    clay.UI()(.{
        .id = clay.getElementId("ImageTransitionPrevQuad"),
        .layout = .{
            .sizing = .{
                .w = .fixed(prev_dims.w),
                .h = .fixed(prev_dims.h),
            },
        },
        .floating = .{
            .attach_to = .to_parent,
            .clip_to = .to_attached_parent,
            .attach_points = .{
                .element = .center_center,
                .parent = .center_center,
            },
            .offset = .{ .x = 0.0, .y = 0.0 },
            .z_index = 0,
            .pointer_capture_mode = .passthrough,
        },
        .image = .{
            .image_data = prev_tex.asOpaque(),
        },
        .user_data = if (prev_uv_ptr) |ptr| @ptrCast(ptr) else null,
    })({});
}

fn renderViewport(
    ui_model: UiViewModel,
    current_entry: anytype,
    draw_dims: state.LogicalDims,
    view_dims: state.LogicalDims,
    scale: state.DpiScale,
    total_images: usize,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) void {
    clay.UI()(.{
        .id = clay.getElementId("Viewport"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .clip = .{ .horizontal = true, .vertical = true },
    })({
        renderDissolvePrevQuad(
            ui_model,
            frame_allocator,
            view_dims,
            scale,
        );

        if (current_entry) |entry| {
            renderImageCanvas(
                ui_model,
                entry,
                draw_dims.w,
                draw_dims.h,
                view_dims.w,
                ui_model.viewport.rotation_angle,
                frame_allocator,
                measure_data,
            );
        } else if (ui_model.visible_state == .filtered_empty) {
            // Informative empty filter canvas
            const fe = ui_model.visible_state.filtered_empty;
            const subtext = frame_allocator.print(
                "{s}: 0 of {} images match -- press 'v' to cycle filter",
                .{ fe.mode.label(), fe.total_count },
            ) catch "No images match current filter";

            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .grow },
                    .direction = .top_to_bottom,
                    .child_alignment = .{ .x = .center, .y = .center },
                    .child_gap = 12,
                },
            })({
                clay.text("No matching images in active filter", .{
                    .color = theme.yellow,
                    .font_size = 22,
                    .font_id = 0,
                });
                clay.text(subtext, .{
                    .color = theme.subtext0,
                    .font_size = 14,
                    .font_id = 0,
                });
            });
        } else if (ui_model.is_loading_files or total_images > 0) {
            // Centered viewport loading screen while file discovery is active
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .grow },
                    .direction = .top_to_bottom,
                    .child_alignment = .{ .x = .center, .y = .center },
                    .child_gap = 12,
                },
            })({
                clay.text("Loading Images...", .{
                    .color = theme.pink,
                    .font_size = 22,
                    .font_id = 0,
                });
                clay.text("Discovering files in background...", .{
                    .color = theme.subtext0,
                    .font_size = 14,
                    .font_id = 0,
                });
            });
        } else {
            // Empty state screen
            renderEmptyState();
        }
    });
}

test "formatLoadingText - fallback when no filename" {
    var data = MeasureTextUserData{
        .allocator = std.testing.allocator,
        .fonts = &empty_fonts,
    };
    const res =
        formatLoadingText(std.testing.allocator, null, 400.0, 22, &data);
    try std.testing.expectEqualStrings("Loading image...", res);
}

test "formatLoadingText - with filename" {
    var data = MeasureTextUserData{
        .allocator = std.testing.allocator,
        .fonts = &empty_fonts,
    };
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
    var data = MeasureTextUserData{
        .allocator = std.testing.allocator,
        .fonts = &empty_fonts,
    };
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
    var data = MeasureTextUserData{
        .allocator = std.testing.allocator,
        .fonts = &empty_fonts,
    };
    const res =
        formatLoadingText(std.testing.allocator, null, 100.0, 22, &data);
    try std.testing.expectEqualStrings("Loading...", res);
}

test "computeDrawDims - matches physical DPI scale in shrink and none modes" {
    const entry = CacheEntry{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .surface = .{ .ptr = undefined },
                    .w = 1200,
                    .h = 900,
                    .size_bytes = 1000,
                },
            },
        },
        .metadata = .{ .full_dims = .{ .w = 1200, .h = 900 } },
    };

    const view_dims = state.LogicalDims{ .w = 1000.0, .h = 800.0 };
    const retina_scale = state.DpiScale.init(2.0, 2.0);

    // Logical viewport 1000x800 on 2.0x Retina display -> physical 2000x1600.
    // A 1200x900 image fits inside the 2000x1600 physical viewport without
    // shrinking (base_scale = 1.0 in physical pixels -> 600x450 logical).
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

    // In .full mode, physical 1200x900 scales up to 2000x1500 physical ->
    // 1000x750 logical.
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
    const dummyMeasure = struct {
        fn measure(
            text: []const u8,
            config: *clay.TextElementConfig,
            _: void,
        ) clay.Dimensions {
            _ = config;
            return .{ .w = @floatFromInt(text.len * 8), .h = 16.0 };
        }
    }.measure;
    const setNullCtx = @as(
        *const fn (?*clay.Context) callconv(.c) void,
        @ptrCast(&clay.cdefs.Clay_SetCurrentContext),
    );
    setNullCtx(null);
    defer setNullCtx(null);
    const clay_mem = try std.testing.allocator.alloc(u8, clay.minMemorySize());
    defer std.testing.allocator.free(clay_mem);
    _ = clay.initialize(
        clay.Arena.init(clay_mem),
        .{ .w = 1000, .h = 800 },
        .{},
    );
    clay.setMeasureTextFunction(void, {}, dummyMeasure);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var data = MeasureTextUserData{
        .allocator = std.testing.allocator,
        .fonts = &empty_fonts,
    };
    const dummy_tex: GpuTexture = .{ .ptr = @ptrFromInt(0x1000) };
    const entry = CacheEntry{
        .resident = .{
            .asset = .{
                .loaded_gpu = .{
                    .gpu_texture = dummy_tex,
                    .w = 800,
                    .h = 600,
                    .size_bytes = 1000,
                    .ingest = .{ .memory_size_bytes = 1920000 },
                },
            },
            .thumbnail = .{
                .loaded = .{
                    .texture = dummy_tex,
                    .info = .{ .w = 160, .h = 120, .dct_snapped = false },
                },
            },
        },
        .metadata = .{ .full_dims = .{ .w = 800, .h = 600 } },
    };
    var pal_state = try PaletteState.init(std.testing.allocator);
    defer pal_state.deinit();
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

    clay.beginLayout();
    renderViewport(
        model,
        model.current_entry,
        .{ .w = 800.0, .h = 600.0 },
        .{ .w = 1000.0, .h = 800.0 },
        .{ .x = 1.0, .y = 1.0 },
        2,
        arena.allocator(),
        &data,
    );
    _ = clay.endLayout();
    clay.setPointerState(.{ .x = 500, .y = 400 }, false);

    try std.testing.expect(clay.pointerOver(clay.getElementId("Viewport")));
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

    // 1. Embedded EXIF thumbnail (unrotated 160x120 landscape) with 90°
    // viewport rotation: shader must rotate by 90°.
    const embedded_uv = buildThumbnailUvRect(
        entry,
        .{ .w = 160.0, .h = 120.0, .source = .embedded_header },
        auth,
        90.0,
    );
    try std.testing.expectEqual(@as(f32, 90.0), embedded_uv.rotation_angle);
    try std.testing.expectEqual(@as(f32, 6000.0), embedded_uv.source_w);
    try std.testing.expectEqual(@as(f32, 4000.0), embedded_uv.source_h);

    // 2. Freedesktop cached PNG thumbnail (already oriented 170x256 portrait)
    // with 90° viewport rotation: shader rotation must be 0° (90° - 90°) and
    // reference dimensions swapped (4000x6000).
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
