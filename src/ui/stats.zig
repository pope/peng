const std = @import("std");
const clay = @import("zclay");
const main = @import("../main.zig");
const c = main.c;
const app_state = @import("../app/state.zig");
const ViewerState = app_state.ViewerState;
const CacheEntry = app_state.CacheEntry;
const formatSize = @import("palette.zig").formatSize;
const MeasureTextUserData = main.MeasureTextUserData;

pub fn renderStatRow(label: []const u8, value: []const u8, scale_x: f32, scale_y: f32, dpi_scale: f32) !void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(20 * scale_y) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(110 * scale_x), .h = .grow } } })({
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
    var process_str: []const u8 = "Loading...";
    var screen_str: []const u8 = "Loading...";

    if (current_entry) |entry| {
        mime_type = entry.mime_type;
        if (entry.status == .loaded or entry.gpu_texture != null) {
            disk_size_str = try formatSize(frame_allocator, entry.size_bytes);
            mem_size_str = try formatSize(frame_allocator, entry.memory_size_bytes);

            const megapixels = (entry.w * entry.h) / 1_000_000.0;
            res_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} ({d:.2} MP)", .{ entry.w, entry.h, megapixels });
            decode_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{entry.decode_time_ms});
            convert_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{entry.conversion_time_ms});
            process_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{entry.upload_time_ms});
            screen_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} px", .{ draw_w, draw_h });
        } else if (entry.status == .failed) {
            disk_size_str = "Failed";
            mem_size_str = "Failed";
            mime_type = "Failed";
            res_str = "Failed";
            decode_str = "Failed";
            convert_str = "Failed";
            process_str = "Failed";
            screen_str = "Failed";
        }
    }

    var zoom_str: []const u8 = "1.0x";
    if (current_entry) |entry| {
        if (entry.w > 0) {
            const pixel_zoom_pct = ((draw_w * state.zoom_factor) / entry.w) * 100.0;
            zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x ({d:.0}%)", .{ state.zoom_factor, pixel_zoom_pct });
        } else {
            zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.zoom_factor});
        }
    } else {
        zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.zoom_factor});
    }

    const pan_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}, {d:.0} px", .{ state.pan_x, state.pan_y });
    const rot_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}°", .{state.rotation_angle});

    clay.UI()(.{
        .id = clay.getElementId("StatsPanel"),
        .layout = .{
            .sizing = .{ .w = .fixed(380 * scale_x), .h = .fit },
            .direction = .top_to_bottom,
            .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
            .child_gap = 10,
        },
        .background_color = .{ 30, 30, 46, 220 },
        .corner_radius = .all(10),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = .{ 49, 50, 68, 255 },
        },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .offset = .{ .x = state.stats_offset_x, .y = state.stats_offset_y },
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
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({
                clay.text("Stats for Nerds", .{
                    .color = .{ 245, 194, 231, 255 },
                    .font_size = @intFromFloat(16.0 * dpi_scale),
                    .font_id = 0,
                });
            });
            clay.UI()(.{
                .id = clay.getElementId("StatsCloseBtn"),
                .layout = .{
                    .sizing = .{ .w = .fixed(24 * scale_x), .h = .fixed(24 * scale_y) },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = .{ 49, 50, 68, 255 },
                .corner_radius = .all(12),
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
            try renderStatRow("Upload Time", process_str, scale_x, scale_y, dpi_scale);
            try renderStatRow("Memory Size", mem_size_str, scale_x, scale_y, dpi_scale);
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
