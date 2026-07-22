const std = @import("std");
const clay = @import("zclay");
const c = @import("../app/c.zig").c;
const app_state = @import("../app/state.zig");
const ViewerState = app_state.ViewerState;
const types = @import("../app/types.zig");
const FrameInput = types.FrameInput;
const MeasureTextUserData = types.MeasureTextUserData;
const renderPalette = @import("palette.zig").renderPalette;
const renderStatsOverlay = @import("stats.zig").renderStatsOverlay;
const renderer = @import("renderer.zig");
const saveTextureToPng = @import("graphics.zig").saveTextureToPng;
const ElementTag = app_state.ElementTag;

pub fn renderFrame(
    state: *ViewerState,
    input: FrameInput,
    frame_allocator: std.mem.Allocator,
    fonts: []const ?*c.TTF_Font,
    measure_data: *const MeasureTextUserData,
    capture_filename: ?[:0]const u8,
) !void {
    const width = input.pix_w;
    const height = input.pix_h;
    const scale_x = input.scale_x;
    const scale_y = input.scale_y;
    const dpi_scale = input.dpi_scale;
    state.prepareCacheTextures();
    const current_entry = state.getCurrentEntry();

    // Calculate Image Fitting Layout Boundaries
    var title_bar_h: f32 = 60.0;
    const nav_bar_h: f32 = 0.0;
    if (state.is_fullscreen) {
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
        if (entry.status == .loaded_gpu) {
            src_w = entry.status.loaded_gpu.w;
            src_h = entry.status.loaded_gpu.h;
        } else if (entry.status == .loaded_cpu) {
            src_w = entry.status.loaded_cpu.w;
            src_h = entry.status.loaded_cpu.h;
        } else if (entry.full_w > 0 and entry.full_h > 0) {
            src_w = entry.full_w;
            src_h = entry.full_h;
        } else if (entry.thumb_gpu_texture != null) {
            src_w = entry.thumb_w;
            src_h = entry.thumb_h;
        }

        if (src_w > 0 and src_h > 0) {
            const padding: f32 = 0.0;
            const view_w = @max(available_width - padding * 2.0, 1.0);
            const view_h = @max(height - (title_bar_h + nav_bar_h) * scale_y - padding * 2.0, 1.0);

            const angle = state.rotation_angle;
            const is_90_or_270 = (std.math.approxEqAbs(f32, angle, 90.0, 0.1) or
                std.math.approxEqAbs(f32, angle, 270.0, 0.1) or
                std.math.approxEqAbs(f32, angle, -90.0, 0.1) or
                std.math.approxEqAbs(f32, angle, -270.0, 0.1));
            const img_w = if (is_90_or_270) src_h else src_w;
            const img_h = if (is_90_or_270) src_w else src_h;

            if (img_w > 0 and img_h > 0) {
                const r_img = img_w / img_h;
                const r_view = view_w / view_h;
                switch (state.scale_mode) {
                    .none => {
                        draw_w = img_w;
                        draw_h = img_h;
                    },
                    .shrink => {
                        if (img_w <= view_w and img_h <= view_h) {
                            draw_w = img_w;
                            draw_h = img_h;
                        } else {
                            if (r_img > r_view) {
                                draw_w = view_w;
                                draw_h = view_w / r_img;
                            } else {
                                draw_h = view_h;
                                draw_w = view_h * r_img;
                            }
                        }
                    },
                    .full => {
                        if (r_img > r_view) {
                            draw_w = view_w;
                            draw_h = view_w / r_img;
                        } else {
                            draw_h = view_h;
                            draw_w = view_h * r_img;
                        }
                    },
                    .crop => {
                        if (r_img > r_view) {
                            draw_h = view_h;
                            draw_w = view_h * r_img;
                        } else {
                            draw_w = view_w;
                            draw_h = view_w / r_img;
                        }
                    },
                }
            }
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
        .background_color = .{ 24, 24, 37, 255 }, // Catppuccin Base (Mocha Mantle/Base)
    })({
        try renderPalette(
            state,
            scale_x,
            scale_y,
            dpi_scale,
            input.mouse_left_clicked,
            frame_allocator,
            measure_data,
        );

        try renderStatsOverlay(
            state,
            scale_x,
            scale_y,
            dpi_scale,
            draw_w,
            draw_h,
            frame_allocator,
        );

        // Header/Title bar UI
        if (!state.is_fullscreen) {
            clay.UI()(.{
                .id = clay.getElementId("TitleBar"),
                .layout = .{
                    .sizing = .{
                        .w = .grow,
                        .h = .fixed(title_bar_h * scale_y),
                    },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{
                        .left = @intFromFloat(20 * scale_x),
                        .right = @intFromFloat(20 * scale_x),
                    },
                },
                .background_color = .{ 17, 17, 27, 255 },
                .border = .{
                    .width = .{ .bottom = 1 },
                    .color = .{ 49, 50, 68, 255 },
                },
            })({
                clay.text("Peng Image Viewer", .{
                    .color = .{ 205, 214, 244, 255 },
                    .font_size = @intFromFloat(16.0 * dpi_scale),
                    .font_id = 0,
                });

                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({});

                if (state.image_list.items.len > 0) {
                    const idx = (state.current_index orelse 0) + 1;
                    const count_buf = try frame_allocator.alloc(u8, 64);
                    const count_str = try std.fmt.bufPrint(count_buf, "Image {} of {}", .{ idx, state.image_list.items.len });
                    clay.text(count_str, .{
                        .color = .{ 166, 173, 200, 255 },
                        .font_size = @intFromFloat(12.0 * dpi_scale),
                        .font_id = 0,
                    });
                }
            });
        }

        // Center Viewport Area
        clay.UI()(.{
            .id = clay.getElementId("Viewport"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .clip = .{ .horizontal = true, .vertical = true },
        })({
            if (current_entry) |entry| {
                const show_thumb = (state.debug_show_thumb or entry.status != .loaded_gpu) and (entry.thumb_gpu_texture != null);
                if (show_thumb) {
                    const thumb_tex = entry.thumb_gpu_texture.?;
                    clay.UI()(.{
                        .id = clay.getElementId("ImageCanvas"),
                        .layout = .{
                            .sizing = .{
                                .w = .fixed(draw_w),
                                .h = .fixed(draw_h),
                            },
                        },
                        .image = .{
                            .image_data = @ptrCast(thumb_tex),
                        },
                    })({});
                } else if (entry.status == .loaded_gpu) {
                    const tex = entry.status.loaded_gpu.gpu_texture;
                    clay.UI()(.{
                        .id = clay.getElementId("ImageCanvas"),
                        .layout = .{
                            .sizing = .{
                                .w = .fixed(draw_w),
                                .h = .fixed(draw_h),
                            },
                        },
                        .image = .{
                            .image_data = @ptrCast(tex),
                        },
                    })({});
                } else if (entry.status == .loaded_cpu) {
                    clay.UI()(.{
                        .id = clay.getElementId("ImageCanvas"),
                        .layout = .{
                            .sizing = .{
                                .w = .fixed(draw_w),
                                .h = .fixed(draw_h),
                            },
                        },
                    })({});
                } else if (entry.status == .decoding) {
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .grow },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = @intFromFloat(10 * scale_y),
                        },
                    })({
                        clay.text("Loading image...", .{
                            .color = .{ 245, 194, 231, 255 },
                            .font_size = @intFromFloat(22.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                } else {
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .grow },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = @intFromFloat(10 * scale_y),
                        },
                    })({
                        clay.text("Failed to Load Image", .{
                            .color = .{ 243, 139, 168, 255 },
                            .font_size = @intFromFloat(22.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                }
            } else {
                // Empty state screen
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
                            .child_gap = @intFromFloat(16 * scale_y),
                            .padding = .{
                                .left = @intFromFloat(40 * scale_x),
                                .right = @intFromFloat(40 * scale_x),
                                .top = @intFromFloat(32 * scale_y),
                                .bottom = @intFromFloat(32 * scale_y),
                            },
                        },
                        .border = .{
                            .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
                            .color = .{ 79, 79, 97, 255 },
                        },
                        .corner_radius = .all(12),
                        .user_data = @ptrFromInt(@intFromEnum(ElementTag.drop_zone_box)),
                    })({
                        clay.text("No Images Loaded", .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(22.0 * dpi_scale),
                            .font_id = 0,
                        });

                        clay.text("Drag & Drop images or directories here to view them.", .{
                            .color = .{ 166, 173, 200, 255 },
                            .font_size = @intFromFloat(14.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                });
            }
        });
    });

    const render_commands = clay.endLayout();

    // Render Frame
    const cmd_buf = c.SDL_AcquireGPUCommandBuffer(state.gpu_device) orelse return error.CommandBufferAcquisitionFailed;
    var cmd_buf_submitted = false;
    errdefer if (!cmd_buf_submitted) {
        _ = c.SDL_CancelGPUCommandBuffer(cmd_buf);
    };

    var temp_buffers = std.ArrayList(*c.SDL_GPUTransferBuffer).empty;
    defer temp_buffers.deinit(frame_allocator);
    errdefer {
        for (temp_buffers.items) |buf| {
            c.SDL_ReleaseGPUTransferBuffer(state.gpu_device.?, buf);
        }
    }

    const use_headless = !state.window_claimed;

    var target_tex: ?*c.SDL_GPUTexture = null;
    var target_w: u32 = 0;
    var target_h: u32 = 0;
    var target_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_INVALID;

    if (use_headless) {
        target_w = @intFromFloat(width);
        target_h = @intFromFloat(height);
        target_format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;

        const target_tex_info = c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = target_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
            .width = target_w,
            .height = target_h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        };
        target_tex = c.SDL_CreateGPUTexture(state.gpu_device.?, &target_tex_info) orelse {
            std.log.err("Failed to create offscreen target texture: {s}", .{c.SDL_GetError()});
            return error.OffscreenTargetTextureCreationFailed;
        };
    } else {
        var swap_tex: ?*c.SDL_GPUTexture = null;
        var swap_w: u32 = 0;
        var swap_h: u32 = 0;
        if (c.SDL_WaitAndAcquireGPUSwapchainTexture(
            cmd_buf,
            state.window,
            &swap_tex,
            &swap_w,
            &swap_h,
        )) {
            target_tex = swap_tex;
            target_w = swap_w;
            target_h = swap_h;
            target_format = c.SDL_GetGPUSwapchainTextureFormat(state.gpu_device.?, state.window);
        }
    }

    if (target_tex) |tex| {
        if (target_w == 0 or target_h == 0) {
            cmd_buf_submitted = true;
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            if (use_headless) {
                c.SDL_ReleaseGPUTexture(state.gpu_device.?, tex);
            }
            return;
        }
        try renderer.renderClayCommands(
            state,
            cmd_buf,
            tex,
            fonts,
            render_commands,
            frame_allocator,
            &temp_buffers,
            @intCast(target_w),
            @intCast(target_h),
        );
        if (capture_filename) |filename| {
            cmd_buf_submitted = true;
            try saveTextureToPng(state.gpu_device.?, cmd_buf, tex, target_w, target_h, target_format, filename);
        } else {
            cmd_buf_submitted = true;
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
        }

        for (temp_buffers.items) |buf| {
            c.SDL_ReleaseGPUTransferBuffer(state.gpu_device.?, buf);
        }

        if (use_headless) {
            _ = c.SDL_WaitForGPUIdle(state.gpu_device.?);
            c.SDL_ReleaseGPUTexture(state.gpu_device.?, tex);
        }
    } else {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    }
}
