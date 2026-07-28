const std = @import("std");
const clay = @import("zclay");
const theme = @import("theme.zig");
const app_state = @import("app").state;
const ViewerState = app_state.ViewerState;
const CacheEntry = app_state.CacheEntry;
const formatSize = @import("text_utils.zig").formatSize;
const MeasureTextUserData = @import("app").types.MeasureTextUserData;

pub fn renderStatRow(label: []const u8, value: []const u8) !void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(20) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.UI()(.{ .layout = .{
            .sizing = .{ .w = .fixed(145), .h = .grow },
        } })({
            clay.text(label, .{
                .color = theme.subtext0,
                .font_size = 13,
                .font_id = 0,
            });
        });

        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({
            clay.text(value, .{
                .color = theme.text,
                .font_size = 13,
                .font_id = 0,
            });
        });
    });
}

pub fn renderInfoOverlay(
    state: *ViewerState,
    draw_w: f32,
    draw_h: f32,
    frame_allocator: std.mem.Allocator,
) !void {
    if (!state.overlays.show_info) return;

    var filename: []const u8 = "None";
    var display_dir: []const u8 = "N/A";
    const current_entry = state.getCurrentEntry();

    if (state.current_index) |idx| {
        if (idx < state.image_list.items.len) {
            const path = state.image_list.items[idx];
            filename = std.fs.path.basename(path);
            const dirname = std.fs.path.dirname(path) orelse ".";
            display_dir = if (dirname.len > 35) try std.fmt.allocPrint(frame_allocator, "...{s}", .{dirname[dirname.len - 32 ..]}) else dirname;
        }
    }

    var disk_size_str: []const u8 = "N/A";
    var mime_type: []const u8 = "N/A";
    var res_str: []const u8 = "N/A";
    const screen_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} px", .{ draw_w, draw_h });

    if (current_entry) |entry| {
        switch (entry.status) {
            .loaded_cpu => |cpu| {
                mime_type = cpu.mime_type;
                disk_size_str = try formatSize(frame_allocator, cpu.size_bytes);
                const megapixels = (cpu.w * cpu.h) / 1_000_000.0;
                res_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} ({d:.2} MP)", .{ cpu.w, cpu.h, megapixels });
            },
            .loaded_gpu => |gpu| {
                mime_type = gpu.mime_type;
                disk_size_str = try formatSize(frame_allocator, gpu.size_bytes);
                const megapixels = (gpu.w * gpu.h) / 1_000_000.0;
                res_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} ({d:.2} MP)", .{ gpu.w, gpu.h, megapixels });
            },
            .decoding => {
                disk_size_str = "Loading...";
                mime_type = "Loading...";
                res_str = "Loading...";
            },
            .failed => {
                disk_size_str = "Failed";
                mime_type = "Failed";
                res_str = "Failed";
            },
            else => {},
        }
    }

    var zoom_str: []const u8 = "1.0x";
    if (current_entry) |entry| {
        const entry_w = switch (entry.status) {
            .loaded_cpu => |cpu| cpu.w,
            .loaded_gpu => |gpu| gpu.w,
            else => 0.0,
        };
        if (entry_w > 0) {
            const effective_zoom = (draw_w * state.viewport.zoom_factor) / entry_w;
            const pixel_zoom_pct = effective_zoom * 100.0;
            zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x ({d:.0}%)", .{ effective_zoom, pixel_zoom_pct });
        } else {
            zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.viewport.zoom_factor});
        }
    } else {
        zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.viewport.zoom_factor});
    }

    const pan_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}, {d:.0} px", .{ state.viewport.pan_x, state.viewport.pan_y });
    const rot_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}°", .{state.viewport.rotation_angle});

    var thumb_info_str: []const u8 = "N/A";
    if (current_entry) |entry| {
        var is_jpeg = std.mem.eql(u8, mime_type, "image/jpeg");
        if (state.current_index) |idx| {
            if (idx < state.image_list.items.len) {
                const ext = std.fs.path.extension(state.image_list.items[idx]);
                if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) {
                    is_jpeg = true;
                }
            }
        }
        const has_thumb = switch (entry.status) {
            .loaded_gpu => |gpu| gpu.has_thumb,
            .loaded_cpu => |cpu| cpu.has_thumb,
            else => entry.has_thumb,
        };
        const t_w = switch (entry.status) {
            .loaded_gpu => |gpu| gpu.thumb_w,
            .loaded_cpu => |cpu| cpu.thumb_w,
            else => entry.thumb_w,
        };
        const t_h = switch (entry.status) {
            .loaded_gpu => |gpu| gpu.thumb_h,
            .loaded_cpu => |cpu| cpu.thumb_h,
            else => entry.thumb_h,
        };

        if (has_thumb) {
            thumb_info_str = try std.fmt.allocPrint(frame_allocator, "Present ({d:.0}x{d:.0} px)", .{ t_w, t_h });
        } else if (is_jpeg) {
            thumb_info_str = "None (No EXIF Thumb)";
        } else {
            thumb_info_str = "N/A (Non-JPEG)";
        }
    }

    clay.UI()(.{
        .id = clay.getElementId("InfoPanel"),
        .layout = .{
            .sizing = .{ .w = .fixed(380), .h = .fit },
            .direction = .top_to_bottom,
            .padding = .{ .top = 16, .bottom = 16, .left = 16, .right = 16 },
            .child_gap = 10,
        },
        .background_color = theme.base_overlay,
        .corner_radius = .all(10),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.surface0,
        },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .offset = .{
                .x = state.overlays.info_offset_x,
                .y = state.overlays.info_offset_y,
            },
            .z_index = 100,
        },
    })({
        // Header row
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(24) },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
            },
        })({
            clay.UI()(.{ .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
            } })({
                clay.text("Info Overlay", .{
                    .color = theme.mauve,
                    .font_size = 16,
                    .font_id = 0,
                });
            });
            clay.UI()(.{
                .id = clay.getElementId("InfoCloseBtn"),
                .layout = .{
                    .sizing = .{
                        .w = .fixed(24),
                        .h = .fixed(24),
                    },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = theme.surface0,
                .corner_radius = .all(12),
            })({
                clay.text("x", .{
                    .color = theme.text,
                    .font_size = 12,
                    .font_id = 0,
                });
            });
        });

        // Info details
        try renderStatRow("File Name", filename);
        try renderStatRow("Directory", display_dir);
        try renderStatRow("MIME Type", mime_type);
        try renderStatRow("Resolution", res_str);
        try renderStatRow("Size on Disk", disk_size_str);
        try renderStatRow("Viewport Size", screen_str);
        const scale_mode_str = switch (state.viewport.scale_mode) {
            .none => "Original size (100%)",
            .shrink => "Fit if larger",
            .full => "Fit to screen (Aspect Fit)",
            .crop => "Fill screen (Aspect Fill)",
        };
        try renderStatRow("Scale Mode", scale_mode_str);
        try renderStatRow("Zoom Level", zoom_str);
        try renderStatRow("Pan Offset", pan_str);
        try renderStatRow("Rotation", rot_str);
        const filter_str = switch (state.adjustments.texture_scale_mode) {
            .nearest => "Nearest Neighbor",
            .linear => "Bilinear Filter",
            .pixel_art => "Pixel Art Scaling",
            .mitchell => "Mitchell-Netravali",
            .lanczos3 => "Lanczos3 Resampler",
        };
        try renderStatRow("Scaling Filter", filter_str);

        const brightness_val = state.adjustments.brightness * 100.0;
        const brightness_str = try std.fmt.allocPrint(frame_allocator, "{s}{d:.0}%", .{ if (brightness_val > 0) "+" else "", brightness_val });
        const contrast_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.adjustments.contrast});
        try renderStatRow("Brightness", brightness_str);
        try renderStatRow("Contrast", contrast_str);
        try renderStatRow("EXIF Thumbnail", thumb_info_str);
    });
}

pub fn renderStatsOverlay(
    state: *ViewerState,
    draw_w: f32,
    draw_h: f32,
    frame_allocator: std.mem.Allocator,
) !void {
    try renderInfoOverlay(state, draw_w, draw_h, frame_allocator);

    if (!state.overlays.show_stats) return;

    const current_entry = state.getCurrentEntry();

    var mem_size_str: []const u8 = "N/A";
    var decode_str: []const u8 = "N/A";
    var convert_str: []const u8 = "N/A";
    var upload_str: []const u8 = "N/A";

    if (current_entry) |entry| {
        switch (entry.status) {
            .loaded_cpu => |cpu| {
                decode_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{cpu.decode_time_ms});
                convert_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{cpu.conversion_time_ms});
            },
            .loaded_gpu => |gpu| {
                mem_size_str = try formatSize(frame_allocator, gpu.memory_size_bytes);
                decode_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{gpu.decode_time_ms});
                convert_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{gpu.conversion_time_ms});
                upload_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{gpu.upload_time_ms});
            },
            .decoding => {
                mem_size_str = "Loading...";
                decode_str = "Loading...";
                convert_str = "Loading...";
                upload_str = "Loading...";
            },
            .failed => {
                mem_size_str = "Failed";
                decode_str = "Failed";
                convert_str = "Failed";
                upload_str = "Failed";
            },
            else => {},
        }
    }

    clay.UI()(.{
        .id = clay.getElementId("StatsPanel"),
        .layout = .{
            .sizing = .{ .w = .fixed(380), .h = .fit },
            .direction = .top_to_bottom,
            .padding = .{ .top = 16, .bottom = 16, .left = 16, .right = 16 },
            .child_gap = 10,
        },
        .background_color = theme.base_overlay,
        .corner_radius = .all(10),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.surface0,
        },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .right_top, .parent = .right_top },
            .offset = .{
                .x = state.overlays.stats_offset_x,
                .y = state.overlays.stats_offset_y,
            },
            .z_index = 100,
        },
    })({
        // Header row
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(24) },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
            },
        })({
            clay.UI()(.{ .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
            } })({
                clay.text("Stats for Nerds", .{
                    .color = theme.pink,
                    .font_size = 16,
                    .font_id = 0,
                });
            });
            clay.UI()(.{
                .id = clay.getElementId("StatsCloseBtn"),
                .layout = .{
                    .sizing = .{
                        .w = .fixed(24),
                        .h = .fixed(24),
                    },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = theme.surface0,
                .corner_radius = .all(12),
            })({
                clay.text("x", .{
                    .color = theme.text,
                    .font_size = 12,
                    .font_id = 0,
                });
            });
        });

        // Stats details
        const hit_str = if (state.current_image_cache_hit) "Yes" else "No";
        try renderStatRow("Cache Hit", hit_str);
        try renderStatRow("Memory Size", mem_size_str);

        const total_vram_bytes = state.cache.getTotalVramBytes();
        const formatted_total_vram = try formatSize(frame_allocator, total_vram_bytes);
        const total_vram_str = try std.fmt.allocPrint(frame_allocator, "{s} / 1024 MB ({d} slots)", .{ formatted_total_vram, state.cache.entries.items.len });
        try renderStatRow("Total Cache VRAM", total_vram_str);

        try renderStatRow("Decode Time", decode_str);
        try renderStatRow("Convert Time", convert_str);
        try renderStatRow("GPU Upload", upload_str);

        var upload_mode_str: []const u8 = if (current_entry != null) "Direct VRAM" else "N/A";
        var fallback_time_str: []const u8 = "N/A";
        if (current_entry) |entry| {
            switch (entry.status) {
                .loaded_gpu => |gpu| {
                    if (gpu.was_fallback) {
                        upload_mode_str = "CPU Downscale Fallback";
                        fallback_time_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{gpu.fallback_time_ms});
                    }
                },
                else => {},
            }
        }
        try renderStatRow("GPU Upload Mode", upload_mode_str);
        if (std.mem.eql(u8, upload_mode_str, "CPU Downscale Fallback")) {
            try renderStatRow("CPU Fallback Time", fallback_time_str);
        }

        var thumb_time_str: []const u8 = "N/A";
        if (current_entry) |entry| {
            const has_thumb = switch (entry.status) {
                .loaded_gpu => |gpu| gpu.has_thumb,
                .loaded_cpu => |cpu| cpu.has_thumb,
                else => entry.has_thumb,
            };
            const t_time = switch (entry.status) {
                .loaded_gpu => |gpu| gpu.thumb_upload_time_ms,
                .loaded_cpu => |cpu| cpu.thumb_upload_time_ms,
                else => entry.thumb_upload_time_ms,
            };

            if (has_thumb) {
                thumb_time_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{t_time});
            }
        }
        try renderStatRow("Thumb Load Time", thumb_time_str);

        var mipmap_status_str: []const u8 = if (current_entry != null) "Disabled (1 Level)" else "N/A";
        var mipmap_time_str: []const u8 = if (current_entry != null) "0.00 ms" else "N/A";
        if (current_entry) |entry| {
            switch (entry.status) {
                .loaded_gpu => |gpu| {
                    if (gpu.num_mip_levels > 1) {
                        mipmap_status_str = try std.fmt.allocPrint(frame_allocator, "Enabled ({d} Levels)", .{gpu.num_mip_levels});
                        mipmap_time_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{gpu.mipmap_time_ms});
                    }
                },
                else => {},
            }
        }
        try renderStatRow("Mipmap Status", mipmap_status_str);
        try renderStatRow("Mipmap Gen", mipmap_time_str);

        const render_stats = state.metrics.ui_render_stats.getMeanAndStdev();
        const ui_render_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ± {d:.2} ms", .{ render_stats.mean, render_stats.stdev });
        const ui_batches_str = try std.fmt.allocPrint(frame_allocator, "{d}", .{state.metrics.last_ui_batch_count});
        const ui_verts_str = try std.fmt.allocPrint(frame_allocator, "{d}", .{state.metrics.last_ui_vertex_count});
        try renderStatRow("UI Render Pass", ui_render_str);
        try renderStatRow("UI Batches", ui_batches_str);
        try renderStatRow("UI Vertices", ui_verts_str);
    });
}
