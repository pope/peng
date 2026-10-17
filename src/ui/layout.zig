const clay = @import("zclay");
const edit_panel = @import("edit_panel.zig");
const graphics = @import("graphics.zig");
const intents = @import("intents");
const palette = @import("palette.zig");
const renderer = @import("renderer.zig");
const sdl = @import("sdl");
const state = @import("state");
const stats = @import("stats.zig");
const std = @import("std");
const text_utils = @import("text_utils.zig");
const theme = @import("theme.zig");

const ElementTag = types.ElementTag;
const FrameInput = types.FrameInput;
const MeasureTextUserData = state.MeasureTextUserData;
const RenderResources = graphics.RenderResources;
const UiViewModel = state.UiViewModel;
const renderEditPanel = edit_panel.renderEditPanel;
const renderPalette = palette.renderPalette;
const renderStatsOverlay = stats.renderStatsOverlay;
const saveTextureToPng = graphics.saveTextureToPng;
const sdl3MeasureText = graphics.sdl3MeasureText;
const truncateFilename = text_utils.truncateFilename;
const types = state.types;
const view_transform = state.view_transform;

/// Computes fitted layout dimensions for an image cache entry within
/// available viewport bounds.
pub fn computeDrawDims(
    entry_opt: ?state.CacheEntry,
    available_width: f32,
    available_height: f32,
    rotation_angle: f32,
    fit_mode: intents.ZoomPreset,
) struct { w: f32, h: f32 } {
    const entry = entry_opt orelse return .{ .w = 0, .h = 0 };
    const auth = entry.getAuthoritativeDims();
    const src_w = auth.w;
    const src_h = auth.h;

    if (src_w > 0 and src_h > 0) {
        const view_w = @max(available_width, 1.0);
        const view_h = @max(available_height, 1.0);
        const is_loading = entry.status != .loaded_gpu and
            entry.status != .loaded_cpu;
        const only_has_thumb = entry.full_w <= 0.0 and
            entry.raw_metadata.getSensorDims() == null and
            entry.thumbnail != .none;
        const effective_fit_mode: intents.ZoomPreset =
            if (fit_mode == .shrink and is_loading and only_has_thumb)
                .full
            else
                fit_mode;
        const dims = view_transform.computeViewDims(
            src_w,
            src_h,
            rotation_angle,
            view_w,
            view_h,
            effective_fit_mode,
        );
        return .{ .w = dims.draw_w, .h = dims.draw_h };
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
    fonts: []const ?sdl.Font,
    measure_data: *MeasureTextUserData,
    target_window: ?sdl.Window,
    render_metrics: ?*types.UiRenderMetrics,
    capture_filename: ?[:0]const u8,
) !void {
    const width = input.win_w;
    const height = input.win_h;
    const scale_x = input.scale_x;
    const scale_y = input.scale_y;
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
    const view_w = @max(available_width - padding * 2.0, 1.0);
    const view_h = @max(height - padding * 2.0, 1.0);

    const dims = computeDrawDims(
        current_entry,
        view_w,
        view_h,
        ui_model.viewport.rotation_angle,
        ui_model.viewport.fit_mode,
    );
    const draw_w = dims.w;
    const draw_h = dims.h;

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
            draw_w,
            draw_h,
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
            draw_w,
            draw_h,
            view_w,
            view_h,
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

    // Clay's internal debug panel layout elements are generated inside clay.endLayout().
    // Flag measure_data so sdl3MeasureText scales debug text down (16px -> 12px) during layout.
    measure_data.is_debug_measuring = clay.isDebugModeEnabled();
    const render_commands = clay.endLayout();
    measure_data.is_debug_measuring = false;

    // Render Frame
    const dev = gpu_res.device;
    const cmd_wrapper = dev.acquireCommandBuffer() orelse
        return error.CommandBufferAcquisitionFailed;
    var cmd_buf_submitted = false;
    errdefer if (!cmd_buf_submitted) {
        _ = cmd_wrapper.cancel();
    };

    var temp_buffers: std.ArrayList(sdl.gpu.TransferBuffer) = .empty;
    defer temp_buffers.deinit(frame_allocator);
    errdefer {
        for (temp_buffers.items) |buf| {
            dev.releaseTransferBuffer(buf);
        }
    }

    const use_headless = (target_window == null);

    var target_tex: ?sdl.gpu.Texture = null;
    var target_w: u32 = 0;
    var target_h: u32 = 0;
    var target_format: sdl.gpu.TextureFormat = .invalid;

    if (use_headless) {
        target_w = @intFromFloat(width);
        target_h = @intFromFloat(height);
        target_format = .rgba8_unorm;

        const target_tex_info = sdl.gpu.TextureCreateInfo{
            .type = .type_2d,
            .format = .rgba8_unorm,
            .usage = sdl.gpu.TextureUsage.color_target,
            .width = target_w,
            .height = target_h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = .count_1,
            .props = 0,
        };
        target_tex = dev.createTexture(&target_tex_info) orelse {
            std.log.err("Failed to create offscreen target texture: {s}", .{sdl.getError()});
            return error.OffscreenTargetTextureCreationFailed;
        };
    } else {
        var swap_w: u32 = 0;
        var swap_h: u32 = 0;
        const win = target_window.?;
        if (win.waitAndAcquireSwapchainTexture(cmd_wrapper, &swap_w, &swap_h)) |swap_tex| {
            target_tex = swap_tex;
            target_w = swap_w;
            target_h = swap_h;
            target_format = dev.getSwapchainTextureFormat(win);
        }
    }

    errdefer if (use_headless) {
        if (target_tex) |tex| {
            dev.releaseTexture(tex);
        }
    };

    if (target_tex) |tex| {
        if (target_w == 0 or target_h == 0) {
            cmd_buf_submitted = true;
            _ = cmd_wrapper.submit();
            if (use_headless) {
                dev.releaseTexture(tex);
            }
            return;
        }
        try renderer.renderClayCommands(
            ui_model.viewport,
            gpu_res,
            cmd_wrapper,
            tex,
            fonts,
            render_commands,
            gpa_allocator,
            frame_allocator,
            &temp_buffers,
            @intCast(target_w),
            @intCast(target_h),
            scale_x,
            scale_y,
            target_format,
            render_metrics,
        );
        if (capture_filename) |filename| {
            cmd_buf_submitted = true;
            try saveTextureToPng(
                dev,
                cmd_wrapper,
                tex,
                target_w,
                target_h,
                target_format,
                filename,
            );
        } else if (use_headless) {
            cmd_buf_submitted = true;
            const fence_opt = cmd_wrapper.submitAndAcquireFence();
            if (fence_opt) |fence| {
                _ = dev.waitForFence(fence);
                dev.releaseFence(fence);
            } else {
                std.log.err(
                    "Failed to acquire GPU fence for headless render: {s}",
                    .{sdl.getError()},
                );
                return error.FenceAcquisitionFailed;
            }
        } else {
            cmd_buf_submitted = true;
            _ = cmd_wrapper.submit();
        }

        for (temp_buffers.items) |buf| {
            dev.releaseTransferBuffer(buf);
        }

        if (use_headless) {
            dev.releaseTexture(tex);
        }
    } else {
        _ = cmd_wrapper.submit();
    }
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
                        count_str = try std.fmt.bufPrint(
                            count_buf,
                            "Image {} of {} ({} total) [Slide Show {d:.1}s]",
                            .{ vis_pos, vis_cnt, total_images, s.interval_s },
                        );
                    } else {
                        count_str = try std.fmt.bufPrint(
                            count_buf,
                            "Image {} of {} [Slide Show {d:.1}s]",
                            .{ vis_pos, vis_cnt, s.interval_s },
                        );
                    }
                },
                .inactive => {
                    if (is_filtered) {
                        count_str = try std.fmt.bufPrint(
                            count_buf,
                            "Image {} of {} ({} total)",
                            .{ vis_pos, vis_cnt, total_images },
                        );
                    } else if (is_loading) {
                        count_str = try std.fmt.bufPrint(
                            count_buf,
                            "Image {} of {}...",
                            .{ vis_pos, vis_cnt },
                        );
                    } else {
                        count_str = try std.fmt.bufPrint(
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
        count_w = sdl3MeasureText(cstr, &count_cfg, measure_data).w;
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
        extra_w += count_w + 29.0; // count text + 1px divider + 2x 14px gaps
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
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fixed(1), .h = .fixed(14) },
                },
                .background_color = theme.withAlpha(theme.surface0, progress),
            })({});

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
        const text_w = sdl3MeasureText(snack.message, &snack_cfg, measure_data).w;
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
            .user_data = @ptrFromInt(@intFromEnum(ElementTag.drop_zone_box)),
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

    const font = measure_data.fonts[0] orelse {
        // Fallback for headless test environments without loaded TTF fonts
        return std.fmt.allocPrint(allocator, "Loading {s}...", .{fname}) catch |err| {
            std.log.warn("Failed to format loading text fallback: {any}", .{err});
            return fallback;
        };
    };

    const target_size = @as(f32, @floatFromInt(font_size));
    if (font.getFontSize() != target_size) {
        _ = font.setFontSize(target_size);
    }

    // Measure the prefix "Loading "
    const prefix = "Loading ";
    const prefix_size = font.getStringSize(prefix) orelse
        sdl.Font.TextSize{ .w = 0, .h = 0 };
    const prefix_w = @as(f32, @floatFromInt(prefix_size.w));

    // If available width cannot comfortably fit prefix plus a minimal filename, fall back
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
    const is_middle_truncated = std.mem.indexOf(u8, truncated_fname, "...") != null;
    if (is_middle_truncated) {
        return std.fmt.allocPrint(allocator, "Loading {s}", .{truncated_fname}) catch |err| {
            std.log.warn("Failed to format loading text: {any}", .{err});
            return fallback;
        };
    }

    return std.fmt.allocPrint(allocator, "Loading {s}...", .{truncated_fname}) catch |err| {
        std.log.warn("Failed to format loading text: {any}", .{err});
        return fallback;
    };
}

fn renderImageCanvas(
    ui_model: UiViewModel,
    entry: state.CacheEntry,
    draw_w: f32,
    draw_h: f32,
    view_w: f32,
    rotation_angle: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) void {
    const is_thumb_crossfade = ui_model.is_thumb_crossfading;
    const auth = entry.getAuthoritativeDims();

    if (is_thumb_crossfade) {
        const thumb = entry.thumbnail.loaded;
        const thumb_tex = thumb.texture;
        var thumb_uv = state.computeThumbnailUvCrop(
            entry.full_w,
            entry.full_h,
            thumb.info.w,
            thumb.info.h,
            thumb.info.dct_snapped,
        );
        thumb_uv.alpha = 1.0;
        thumb_uv.rotation_angle = rotation_angle;
        thumb_uv.source_w = auth.w;
        thumb_uv.source_h = auth.h;
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
            },
            .image = .{
                .image_data = thumb_tex.asOpaque(),
            },
            .user_data = if (thumb_uv_ptr) |ptr| @ptrCast(ptr) else null,
        })({});
    }

    var drew_thumb = false;
    switch (entry.thumbnail) {
        .loaded => |thumb| {
            const show_thumb = ui_model.debug_show_thumb or
                (entry.status != .loaded_gpu and !is_thumb_crossfade);
            if (show_thumb) {
                drew_thumb = true;
                const thumb_tex = thumb.texture;
                var uv_crop = state.computeThumbnailUvCrop(
                    entry.full_w,
                    entry.full_h,
                    thumb.info.w,
                    thumb.info.h,
                    thumb.info.dct_snapped,
                );
                uv_crop.alpha = 1.0;
                uv_crop.rotation_angle = rotation_angle;
                uv_crop.source_w = auth.w;
                uv_crop.source_h = auth.h;
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
        else => {},
    }

    if (!drew_thumb) switch (entry.status) {
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
        .decoding => |dec| {
            const elapsed = ui_model.current_time_ms -| dec.start_time_ms;
            const show_loading = elapsed > state.LOADING_GRACE_PERIOD_MS;
            const font_size: u16 = 22;

            const loading_text = if (show_loading) blk: {
                const filename_opt: ?[]const u8 = if (ui_model.current_image_entry) |entry_item|
                    entry_item.getBasename()
                else if (ui_model.current_index) |idx|
                    (if (ui_model.getMediaEntry(idx)) |media|
                        media.getBasename()
                    else
                        null)
                else
                    null;

                const container_w = if (draw_w > 0) @min(draw_w, view_w) else view_w;
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
        },
        else => {
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
    view_w: f32,
    view_h: f32,
) void {
    const dissolve = switch (ui_model.image_dissolve) {
        .none => return,
        .active => |d| d,
    };
    const prev_entry = dissolve.prev_entry;
    const gpu = switch (prev_entry.status) {
        .loaded_gpu => |g| g,
        else => return,
    };

    const prev_auth = prev_entry.getAuthoritativeDims();
    const prev_dims = computeDrawDims(
        prev_entry,
        view_w,
        view_h,
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
    draw_w: f32,
    draw_h: f32,
    view_w: f32,
    view_h: f32,
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
        renderDissolvePrevQuad(ui_model, frame_allocator, view_w, view_h);

        if (current_entry) |entry| {
            renderImageCanvas(
                ui_model,
                entry,
                draw_w,
                draw_h,
                view_w,
                ui_model.viewport.rotation_angle,
                frame_allocator,
                measure_data,
            );
        } else if (ui_model.visible_state == .filtered_empty) {
            // Informative empty filter canvas
            const fe = ui_model.visible_state.filtered_empty;
            const subtext = std.fmt.allocPrint(
                frame_allocator,
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
        .fonts = &([_]?sdl.Font{null} ** 2),
    };
    const res = formatLoadingText(std.testing.allocator, null, 400.0, 22, &data);
    try std.testing.expectEqualStrings("Loading image...", res);
}

test "formatLoadingText - with filename" {
    var data = MeasureTextUserData{
        .allocator = std.testing.allocator,
        .fonts = &([_]?sdl.Font{null} ** 2),
    };
    const res = formatLoadingText(std.testing.allocator, "photo.jpg", 400.0, 22, &data);
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("Loading photo.jpg...", res);
}

test "formatLoadingText - fallback when empty filename" {
    var data = MeasureTextUserData{
        .allocator = std.testing.allocator,
        .fonts = &([_]?sdl.Font{null} ** 2),
    };
    const res = formatLoadingText(std.testing.allocator, "", 400.0, 22, &data);
    try std.testing.expectEqualStrings("Loading image...", res);
}

test "formatLoadingText - narrow viewport fallback" {
    var data = MeasureTextUserData{
        .allocator = std.testing.allocator,
        .fonts = &([_]?sdl.Font{null} ** 2),
    };
    const res = formatLoadingText(std.testing.allocator, null, 100.0, 22, &data);
    try std.testing.expectEqualStrings("Loading...", res);
}
