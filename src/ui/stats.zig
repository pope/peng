const std = @import("std");
const clay = @import("zclay");
const c = @import("../app/c.zig").c;
const app_state = @import("../app/state.zig");
const ViewerState = app_state.ViewerState;
const CacheEntry = app_state.CacheEntry;
const formatSize = @import("palette.zig").formatSize;
const MeasureTextUserData = @import("../app/types.zig").MeasureTextUserData;
const layout_helpers = @import("layout_helpers.zig");
const DpiScale = @import("units.zig").DpiScale;

pub fn renderStatRow(label: []const u8, value: []const u8, scale_x: f32, scale_y: f32, dpi_scale: f32) !void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(20 * scale_y) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.UI()(.{ .layout = .{
            .sizing = .{ .w = .fixed(145 * scale_x), .h = .grow },
        } })({
            clay.text(label, .{
                .color = .{ 166, 173, 200, 255 }, // Subtext0
                .font_size = @intFromFloat(13.0 * dpi_scale),
                .font_id = 0,
            });
        });

        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({
            clay.text(value, .{
                .color = .{ 205, 214, 244, 255 }, // Text
                .font_size = @intFromFloat(13.0 * dpi_scale),
                .font_id = 0,
            });
        });
    });
}

pub fn renderStatsOverlay(
    state: *ViewerState,
    scale_x: f32,
    scale_y: f32,
    dpi_scale: f32,
    draw_w: f32,
    draw_h: f32,
    frame_allocator: std.mem.Allocator,
) !void {
    if (!state.show_stats_overlay) return;

    var filename: []const u8 = "";
    var display_dir: []const u8 = "";
    const current_entry = state.getCurrentEntry();

    if (state.current_index) |idx| {
        if (idx < state.image_list.items.len) {
            const path = state.image_list.items[idx];
            filename = std.fs.path.basename(path);
            const dirname = std.fs.path.dirname(path) orelse ".";
            display_dir = if (dirname.len > 35) try std.fmt.allocPrint(frame_allocator, "...{s}", .{dirname[dirname.len - 32 ..]}) else dirname;
        }
    }

    var disk_size_str: []const u8 = "Loading...";
    var mem_size_str: []const u8 = "Loading...";
    var mime_type: []const u8 = "Loading...";
    var res_str: []const u8 = "Loading...";
    var decode_str: []const u8 = "Loading...";
    var convert_str: []const u8 = "Loading...";
    var upload_str: []const u8 = "Loading...";
    var screen_str: []const u8 = "Loading...";

    if (current_entry) |entry| {
        switch (entry.status) {
            .loaded_cpu => |cpu| {
                mime_type = cpu.mime_type;
                disk_size_str = try formatSize(frame_allocator, cpu.size_bytes);
                const megapixels = (cpu.w * cpu.h) / 1_000_000.0;
                res_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} ({d:.2} MP)", .{ cpu.w, cpu.h, megapixels });
                decode_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{cpu.decode_time_ms});
                convert_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{cpu.conversion_time_ms});
            },
            .loaded_gpu => |gpu| {
                mime_type = gpu.mime_type;
                disk_size_str = try formatSize(frame_allocator, gpu.size_bytes);
                mem_size_str = try formatSize(frame_allocator, gpu.memory_size_bytes);

                const megapixels = (gpu.w * gpu.h) / 1_000_000.0;
                res_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} ({d:.2} MP)", .{ gpu.w, gpu.h, megapixels });
                decode_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{gpu.decode_time_ms});
                convert_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{gpu.conversion_time_ms});
                upload_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{gpu.upload_time_ms});
                screen_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} px", .{ draw_w, draw_h });
            },
            .failed => {
                disk_size_str = "Failed";
                mem_size_str = "Failed";
                mime_type = "Failed";
                res_str = "Failed";
                decode_str = "Failed";
                convert_str = "Failed";
                upload_str = "Failed";
                screen_str = "Failed";
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
            const effective_zoom = (draw_w * state.zoom_factor) / entry_w;
            const pixel_zoom_pct = effective_zoom * 100.0;
            zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x ({d:.0}%)", .{ effective_zoom, pixel_zoom_pct });
        } else {
            zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.zoom_factor});
        }
    } else {
        zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.zoom_factor});
    }

    const pan_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}, {d:.0} px", .{ state.pan_x, state.pan_y });
    const rot_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}°", .{state.rotation_angle});

    const scale = DpiScale.init(dpi_scale);

    clay.UI()(.{
        .id = clay.getElementId("StatsPanel"),
        .layout = .{
            .sizing = .{ .w = .fixed(420 * scale_x), .h = .fit },
            .direction = .top_to_bottom,
            .padding = layout_helpers.scalePadding(16, 16, 16, 16, scale),
            .child_gap = @intFromFloat(10.0 * dpi_scale),
        },
        .background_color = .{ 30, 30, 46, 220 },
        .corner_radius = layout_helpers.scaleCornerRadius(10, scale),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = .{ 49, 50, 68, 255 },
        },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .offset = .{
                .x = state.stats_offset_x * dpi_scale,
                .y = state.stats_offset_y * dpi_scale,
            },
            .z_index = 100,
        },
    })({
        // Header row
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(24 * scale_y) },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
            },
        })({
            clay.UI()(.{ .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
            } })({
                clay.text("Stats for Nerds", .{
                    .color = .{ 245, 194, 231, 255 },
                    .font_size = @intFromFloat(16.0 * dpi_scale),
                    .font_id = 0,
                });
            });
            clay.UI()(.{
                .id = clay.getElementId("StatsCloseBtn"),
                .layout = .{
                    .sizing = .{
                        .w = .fixed(24 * scale_x),
                        .h = .fixed(24 * scale_y),
                    },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = .{ 49, 50, 68, 255 },
                .corner_radius = layout_helpers.scaleCornerRadius(12, scale),
            })({
                clay.text("x", .{
                    .color = .{ 205, 214, 244, 255 },
                    .font_size = @intFromFloat(12.0 * dpi_scale),
                    .font_id = 0,
                });
            });
        });

        // Stats details
        if (filename.len > 0) {
            try renderStatRow("File Name", filename, scale_x, scale_y, dpi_scale);
            try renderStatRow("Directory", display_dir, scale_x, scale_y, dpi_scale);
            try renderStatRow("MIME Type", mime_type, scale_x, scale_y, dpi_scale);
            const hit_str = if (state.current_image_cache_hit) "Yes" else "No";
            try renderStatRow("Cache Hit", hit_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Size on Disk", disk_size_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Resolution", res_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Decode Time", decode_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Convert Time", convert_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("GPU Upload", upload_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Memory Size", mem_size_str, scale_x, scale_y, dpi_scale);

            const total_vram_bytes = state.cache.getTotalVramBytes();
            const formatted_total_vram = try formatSize(frame_allocator, total_vram_bytes);
            const total_vram_str = try std.fmt.allocPrint(frame_allocator, "{s} / 1024 MB ({d} slots)", .{ formatted_total_vram, state.cache.entries.items.len });
            try renderStatRow("Total Cache VRAM", total_vram_str, scale_x, scale_y, dpi_scale);

            var mipmap_status_str: []const u8 = "Disabled (1 Level)";
            var mipmap_time_str: []const u8 = "0.00 ms";
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
            try renderStatRow("Mipmap Status", mipmap_status_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Mipmap Gen", mipmap_time_str, scale_x, scale_y, dpi_scale);

            try renderStatRow("Viewport Size", screen_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Zoom Level", zoom_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Pan Offset", pan_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Rotation", rot_str, scale_x, scale_y, dpi_scale);
            const scale_mode_str = switch (state.scale_mode) {
                .none => "Original size (100%)",
                .shrink => "Fit if larger",
                .full => "Fit to screen (Aspect Fit)",
                .crop => "Fill screen (Aspect Fill)",
            };
            try renderStatRow("Scale Mode", scale_mode_str, scale_x, scale_y, dpi_scale);
            const filter_str = switch (state.texture_scale_mode) {
                .nearest => "Nearest Neighbor",
                .linear => "Bilinear Filter",
                .pixel_art => "Pixel Art Scaling",
                .mitchell => "Mitchell-Netravali",
                .lanczos3 => "Lanczos3 Resampler",
            };
            try renderStatRow("Scaling Filter", filter_str, scale_x, scale_y, dpi_scale);

            const brightness_val = state.brightness * 100.0;
            const brightness_str = try std.fmt.allocPrint(frame_allocator, "{s}{d:.0}%", .{ if (brightness_val > 0) "+" else "", brightness_val });
            const contrast_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.contrast});
            try renderStatRow("Brightness", brightness_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Contrast", contrast_str, scale_x, scale_y, dpi_scale);
        }
    });
}
