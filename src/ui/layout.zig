const std = @import("std");
const clay = @import("zclay");
const sdl = @import("sdl");
const theme = @import("theme.zig");
const state = @import("state");
const types = state.types;
const ViewParams = types.ViewParams;
const UiViewModel = types.UiViewModel;
const FrameInput = types.FrameInput;
const MeasureTextUserData = types.MeasureTextUserData;
const renderPalette = @import("palette.zig").renderPalette;
const renderStatsOverlay = @import("stats.zig").renderStatsOverlay;
const renderer = @import("renderer.zig");
const saveTextureToPng = @import("graphics.zig").saveTextureToPng;
const ElementTag = types.ElementTag;
const view_transform = state.view_transform;
const truncateFilename = @import("text_utils.zig").truncateFilename;
const sdl3MeasureText = @import("graphics.zig").sdl3MeasureText;
const RenderResources = @import("graphics.zig").RenderResources;

pub fn renderFrame(
    view_params: ViewParams,
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
    var title_bar_h: f32 = 60.0;
    const nav_bar_h: f32 = 0.0;
    if (view_params.is_fullscreen) {
        title_bar_h = 0;
    }

    var available_width = width;
    if (clay.isDebugModeEnabled()) {
        available_width = @max(width - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0);
    }

    var draw_w: f32 = 0;
    var draw_h: f32 = 0;

    if (current_entry) |entry| {
        var src_w: f32 = 0;
        var src_h: f32 = 0;
        switch (entry.status) {
            .loaded_gpu => |gpu| {
                src_w = gpu.w;
                src_h = gpu.h;
            },
            .loaded_cpu => |cpu| {
                src_w = cpu.w;
                src_h = cpu.h;
            },
            else => {
                if (entry.full_w > 0 and entry.full_h > 0) {
                    src_w = entry.full_w;
                    src_h = entry.full_h;
                } else if (entry.thumbnail.getInfo()) |info| {
                    src_w = info.w;
                    src_h = info.h;
                }
            },
        }

        if (src_w > 0 and src_h > 0) {
            const padding: f32 = 0.0;
            const view_w = @max(available_width - padding * 2.0, 1.0);
            const view_h = @max(height - (title_bar_h + nav_bar_h) - padding * 2.0, 1.0);

            const dims = view_transform.computeViewDims(src_w, src_h, view_params.viewport.rotation_angle, view_w, view_h, view_params.viewport.fit_mode);
            draw_w = dims.draw_w;
            draw_h = dims.draw_h;
        }
    }

    clay.beginLayout();

    // Main Layout Container
    clay.UI()(.{
        .id = clay.getElementId("MainLayout"),
        .layout = .{
            .sizing = .{
                .w = if (clay.isDebugModeEnabled()) .fixed(available_width) else .grow,
                .h = .grow,
            },
            .direction = .top_to_bottom,
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
        );

        try renderHeaderBar(
            ui_model,
            available_width,
            title_bar_h,
            frame_allocator,
            measure_data,
        );

        renderViewport(
            ui_model,
            current_entry,
            draw_w,
            draw_h,
            total_images,
            frame_allocator,
        );
    });

    // Clay's internal debug panel layout elements are generated inside clay.endLayout().
    // Flag measure_data so sdl3MeasureText scales debug text down (16px -> 12px) during layout.
    measure_data.is_debug_measuring = clay.isDebugModeEnabled();
    const render_commands = clay.endLayout();
    measure_data.is_debug_measuring = false;

    // Render Frame
    const dev = gpu_res.device;
    const cmd_wrapper = dev.acquireCommandBuffer() orelse return error.CommandBufferAcquisitionFailed;
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
            view_params.viewport,
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
            render_metrics,
        );
        if (capture_filename) |filename| {
            cmd_buf_submitted = true;
            try saveTextureToPng(dev, cmd_wrapper, tex, target_w, target_h, target_format, filename);
        } else if (use_headless) {
            cmd_buf_submitted = true;
            const fence_opt = cmd_wrapper.submitAndAcquireFence();
            if (fence_opt) |fence| {
                _ = dev.waitForFence(fence);
                dev.releaseFence(fence);
            } else {
                std.log.err("Failed to acquire GPU fence for headless render: {s}", .{sdl.getError()});
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

fn renderHeaderBar(
    ui_model: UiViewModel,
    available_width: f32,
    title_bar_h: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    if (ui_model.is_fullscreen) return;

    const raw_title = ui_model.window_title;

    const is_loading = ui_model.is_loading_files;
    const total_images = ui_model.total_images;
    var count_str: ?[]const u8 = null;
    if (total_images > 0) {
        const idx = (ui_model.current_index orelse 0) + 1;
        const count_buf = try frame_allocator.alloc(u8, 128);
        switch (ui_model.slideshow) {
            .active => |s| {
                count_str = try std.fmt.bufPrint(count_buf, "Image {} of {} [Slide Show {d:.1}s]", .{ idx, total_images, s.interval_s });
            },
            .inactive => {
                if (is_loading) {
                    count_str = try std.fmt.bufPrint(count_buf, "Image {} of {}...", .{ idx, total_images });
                } else {
                    count_str = try std.fmt.bufPrint(count_buf, "Image {} of {}", .{ idx, total_images });
                }
            },
        }
    } else if (is_loading) {
        count_str = "Loading images...";
    }

    var right_text_w: f32 = 0.0;
    if (count_str) |cstr| {
        var count_cfg = clay.TextElementConfig{
            .font_id = 0,
            .font_size = 12,
        };
        right_text_w = sdl3MeasureText(cstr, &count_cfg, measure_data).w;
    }

    const padding_w = 40.0;
    const gap_w = 20.0;
    const max_title_w = @max(available_width - padding_w - right_text_w - gap_w, 40.0);

    const font_size_u16: u16 = 16;
    const title_display = truncateFilename(frame_allocator, raw_title, max_title_w, font_size_u16, measure_data);

    clay.UI()(.{
        .id = clay.getElementId("TitleBar"),
        .layout = .{
            .sizing = .{
                .w = .grow,
                .h = .fixed(title_bar_h),
            },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 12,
            .padding = .{
                .left = 20,
                .right = 20,
            },
        },
        .background_color = theme.crust,
        .border = .{
            .width = .{ .bottom = 1 },
            .color = theme.surface0,
        },
    })({
        clay.text(title_display, .{
            .color = theme.text,
            .font_size = font_size_u16,
            .font_id = 0,
        });

        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({});

        if (ui_model.manga_mode) {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                },
                .background_color = theme.crust,
                .corner_radius = .all(4),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = theme.peach,
                },
            })({
                clay.text("RTL", .{
                    .color = theme.peach,
                    .font_size = 11,
                    .font_id = 0,
                });
            });
        }

        if (count_str) |cstr| {
            clay.text(cstr, .{
                .color = theme.subtext0,
                .font_size = 12,
                .font_id = 0,
            });
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

fn renderViewport(
    ui_model: UiViewModel,
    current_entry: anytype,
    draw_w: f32,
    draw_h: f32,
    total_images: usize,
    frame_allocator: std.mem.Allocator,
) void {
    clay.UI()(.{
        .id = clay.getElementId("Viewport"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .clip = .{ .horizontal = true, .vertical = true },
    })({
        if (current_entry) |entry| {
            var drew_thumb = false;
            switch (entry.thumbnail) {
                .loaded => |thumb| {
                    if (ui_model.debug_show_thumb or entry.status != .loaded_gpu) {
                        drew_thumb = true;
                        const thumb_tex = thumb.texture;
                        const uv_crop = state.computeThumbnailUvCrop(
                            entry.full_w,
                            entry.full_h,
                            thumb.info.w,
                            thumb.info.h,
                        );
                        const uv_ptr = frame_allocator.create(state.UvRect) catch |err| blk: {
                            std.log.warn("Failed to allocate thumbnail UvRect: {any}", .{err});
                            break :blk null;
                        };
                        if (uv_ptr) |ptr| {
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
                            .user_data = if (uv_ptr) |ptr| @ptrCast(ptr) else null,
                        })({});
                    }
                },
                else => {},
            }
            if (!drew_thumb) switch (entry.status) {
                .loaded_gpu => |gpu| {
                    const tex = gpu.gpu_texture;
                    clay.UI()(.{
                        .id = clay.getElementId("ImageCanvas"),
                        .layout = .{
                            .sizing = .{
                                .w = .fixed(draw_w),
                                .h = .fixed(draw_h),
                            },
                        },
                        .image = .{
                            .image_data = tex.asOpaque(),
                        },
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
                .decoding => {
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
                            clay.text("Loading image...", .{
                                .color = theme.pink,
                                .font_size = 22,
                                .font_id = 0,
                            });
                        });
                    } else {
                        clay.UI()(.{
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .grow },
                                .direction = .top_to_bottom,
                                .child_alignment = .{ .x = .center, .y = .center },
                                .child_gap = 10,
                            },
                        })({
                            clay.text("Loading image...", .{
                                .color = theme.pink,
                                .font_size = 22,
                                .font_id = 0,
                            });
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
