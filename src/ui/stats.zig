const clay = @import("zclay");
const edit_panel = @import("edit_panel.zig");
const graphics = @import("graphics.zig");
const intents = @import("intents");
const state = @import("state");
const std = @import("std");
const text_utils = @import("text_utils.zig");
const theme = @import("theme.zig");
const view_model = @import("view_model.zig");

const ElementTag = state.ElementTag;
const FloatingPanel = state.FloatingPanel;
const formatSize = text_utils.formatSize;
const getSpec = intents.getSpec;
const MeasureTextUserData = graphics.MeasureTextUserData;
const truncateDirectory = text_utils.truncateDirectory;
const truncateFilename = text_utils.truncateFilename;
const UiViewModel = view_model.UiViewModel;

fn renderStatRow(label: []const u8, value: []const u8) !void {
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

fn floatingHudCardDeclaration(
    card_id: []const u8,
    attach_point: clay.FloatingAttachPointType,
    panel: FloatingPanel,
    enable_blur: bool,
) clay.ElementDeclaration {
    return .{
        .id = clay.getElementId(card_id),
        .layout = .{
            .sizing = .{ .w = .fixed(380), .h = .fit },
            .direction = .top_to_bottom,
            .padding = .{ .top = 12, .bottom = 12, .left = 14, .right = 14 },
            .child_gap = 6,
        },
        .background_color = theme.base_translucent,
        .corner_radius = .all(10),
        .user_data = if (enable_blur)
            @ptrFromInt(ElementTag.blurred_surface.toInt())
        else
            null,
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.surface0,
        },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{
                .element = attach_point,
                .parent = attach_point,
            },
            .offset = .{
                .x = panel.offset_x,
                .y = panel.offset_y,
            },
            .z_index = 100,
        },
    };
}

fn renderFloatingHudHeader(title: []const u8, close_btn_id: []const u8) void {
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
            clay.text(title, .{
                .color = theme.mauve,
                .font_size = 16,
                .font_id = 0,
            });
        });
        clay.UI()(.{
            .id = clay.getElementId(close_btn_id),
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
}

fn getRawContainerName(mime_type: []const u8, filename: []const u8) []const u8 {
    const RawFormat = struct {
        mime: []const u8,
        ext: []const u8,
        name: []const u8,
    };
    const formats = [_]RawFormat{
        .{ .mime = "image/x-fuji-raf", .ext = ".raf", .name = "RAW (Fujifilm RAF)" },
        .{ .mime = "image/x-sony-arw", .ext = ".arw", .name = "RAW (Sony ARW)" },
        .{ .mime = "image/x-canon-cr2", .ext = ".cr2", .name = "RAW (Canon CR2)" },
        .{ .mime = "image/x-nikon-nef", .ext = ".nef", .name = "RAW (Nikon NEF)" },
        .{ .mime = "image/x-adobe-dng", .ext = ".dng", .name = "RAW (Adobe DNG)" },
        .{ .mime = "image/x-olympus-orf", .ext = ".orf", .name = "RAW (Olympus ORF)" },
        .{ .mime = "image/x-panasonic-rw2", .ext = ".rw2", .name = "RAW (Panasonic RW2)" },
        .{ .mime = "image/x-pentax-pef", .ext = ".pef", .name = "RAW (Pentax PEF)" },
    };
    for (formats) |f| {
        if (std.mem.eql(u8, mime_type, f.mime) or
            std.ascii.endsWithIgnoreCase(filename, f.ext))
        {
            return f.name;
        }
    }
    return "Camera RAW";
}

fn renderInfoOverlay(
    ui_model: UiViewModel,
    draw_w: f32,
    draw_h: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    if (!ui_model.overlays.info_panel.visible) return;

    var filename: []const u8 = "None";
    var display_dir: []const u8 = "N/A";
    var raw_container_candidate: []const u8 = "";
    const current_entry = ui_model.current_entry;

    if (ui_model.current_index) |idx| {
        if (ui_model.getMediaEntry(idx)) |media| {
            switch (media) {
                .archive_entry => |a| {
                    const page_base = std.Io.Dir.path.basename(a.entry_name);
                    const arch_base = std.Io.Dir.path.basename(a.archive_path);
                    raw_container_candidate = a.entry_name;
                    filename = try frame_allocator.print(
                        "{s} (Page {d}/{d})",
                        .{ page_base, idx + 1, ui_model.total_images },
                    );
                    display_dir = try frame_allocator.print(
                        "Archive: {s}",
                        .{arch_base},
                    );
                },
                .filesystem => |f| {
                    raw_container_candidate = f.path;
                    filename = std.Io.Dir.path.basename(f.path);
                    display_dir = std.Io.Dir.path.dirname(f.path) orelse ".";
                },
                .pair => |p| {
                    raw_container_candidate = p.raw_path;
                    const raw_base = std.Io.Dir.path.basename(p.raw_path);
                    filename = try frame_allocator.print(
                        "{s} [RAW+JPG]",
                        .{raw_base},
                    );
                    display_dir =
                        std.Io.Dir.path.dirname(p.raw_path) orelse ".";
                },
            }
        }
    }

    const max_value_w: f32 = 200.0;
    const font_size_u16: u16 = 13;
    filename = truncateFilename(
        frame_allocator,
        filename,
        max_value_w,
        font_size_u16,
        measure_data,
    );
    display_dir = truncateDirectory(
        frame_allocator,
        display_dir,
        max_value_w,
        font_size_u16,
        measure_data,
    );

    var disk_size_str: []const u8 = "N/A";
    var mime_type: []const u8 = "N/A";
    var res_str: []const u8 = "N/A";
    var raw_res_str: ?[]const u8 = null;
    var is_raw_image = false;
    const z_val = ui_model.viewport.zoom_factor.get();
    var screen_w = draw_w;
    var screen_h = draw_h;
    if (current_entry) |entry| {
        const auth = entry.getAuthoritativeDims();
        if (auth.w > 0.0 and auth.h > 0.0) {
            const is_swapped = state.view_transform.isAngle90or270(
                ui_model.viewport.rotation_angle,
            );
            const w = if (is_swapped) auth.h else auth.w;
            const h = if (is_swapped) auth.w else auth.h;
            screen_w = w * z_val;
            screen_h = h * z_val;
        }
    }
    const screen_str = try frame_allocator.print(
        "{d:.0}x{d:.0} px",
        .{ screen_w, screen_h },
    );

    if (current_entry) |entry| {
        is_raw_image = entry.metadata.raw_metadata.isRaw();
        if (entry.metadata.raw_metadata.getSensorDims()) |s_dims| {
            if (s_dims.w > 0 and s_dims.h > 0) {
                const raw_mp = (s_dims.w * s_dims.h) / 1_000_000.0;
                raw_res_str = try frame_allocator.print(
                    "{d:.0}x{d:.0} ({d:.2} MP)",
                    .{ s_dims.w, s_dims.h, raw_mp },
                );
            }
        }
        switch (entry.resident.asset) {
            .loaded_cpu => |cpu| {
                mime_type = cpu.mime_type;
                disk_size_str = try formatSize(frame_allocator, cpu.size_bytes);
                const megapixels = (cpu.w * cpu.h) / 1_000_000.0;
                const is_raw = entry.metadata.raw_metadata.isRaw();
                const prev_suffix = if (is_raw) " [PREVIEW]" else "";
                res_str = try frame_allocator.print(
                    "{d:.0}x{d:.0} ({d:.2} MP){s}",
                    .{ cpu.w, cpu.h, megapixels, prev_suffix },
                );
            },
            .loaded_gpu => |gpu| {
                mime_type = gpu.mime_type;
                disk_size_str = try formatSize(frame_allocator, gpu.size_bytes);
                const megapixels = (gpu.w * gpu.h) / 1_000_000.0;
                const is_raw = entry.metadata.raw_metadata.isRaw();
                const prev_suffix = if (is_raw) " [PREVIEW]" else "";
                res_str = try frame_allocator.print(
                    "{d:.0}x{d:.0} ({d:.2} MP){s}",
                    .{ gpu.w, gpu.h, megapixels, prev_suffix },
                );
            },
            .none => {
                if (entry.inflight != null) {
                    disk_size_str = "Loading...";
                    mime_type = "Loading...";
                    if (entry.metadata.raw_metadata.isRaw()) {
                        res_str = "Loading preview...";
                    } else if (entry.metadata.full_dims) |fd| {
                        const megapixels = (fd.w * fd.h) / 1_000_000.0;
                        res_str = try frame_allocator.print(
                            "{d:.0}x{d:.0} ({d:.2} MP)",
                            .{ fd.w, fd.h, megapixels },
                        );
                    } else {
                        res_str = "Loading...";
                    }
                }
            },
            .failed => {
                disk_size_str = "Failed";
                mime_type = "Failed";
                res_str = "Failed";
            },
        }
    }

    const pixel_zoom_pct = z_val * 100.0;
    const zoom_str = try frame_allocator.print(
        "{d:.1}x ({d:.0}%)",
        .{ z_val, pixel_zoom_pct },
    );

    const pan_str = try frame_allocator.print(
        "{d:.0}, {d:.0} px",
        .{ ui_model.viewport.pan_x, ui_model.viewport.pan_y },
    );
    const rot_str = try frame_allocator.print(
        "{d:.0}°",
        .{ui_model.viewport.rotation_angle},
    );

    var thumb_info_str: []const u8 = "N/A";
    if (current_entry) |entry| {
        var is_jpeg = std.mem.eql(u8, mime_type, "image/jpeg");
        if (ui_model.current_index) |idx| {
            if (ui_model.getMediaEntry(idx)) |media| {
                const ext = std.Io.Dir.path.extension(media.getBasename());
                if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) {
                    is_jpeg = true;
                }
            }
        }
        if (entry.resident.thumbnail.getInfo()) |info| {
            thumb_info_str = try frame_allocator.print(
                "{s} ({d:.0}x{d:.0} px)",
                .{ info.source.infoLabel(), info.w, info.h },
            );
        } else if (entry.metadata.raw_metadata.isRaw()) {
            thumb_info_str = "None (Preview JPEG used)";
        } else if (is_jpeg) {
            thumb_info_str = "None (Full decode used)";
        } else {
            thumb_info_str = "None";
        }
    }

    clay.UI()(floatingHudCardDeclaration(
        "InfoOverlayCard",
        .left_top,
        ui_model.overlays.info_panel,
        ui_model.overlays.enable_blur,
    ))({
        renderFloatingHudHeader("Info Overlay", "InfoCloseBtn");

        // Info details
        try renderStatRow("File Name", filename);
        try renderStatRow("Directory", display_dir);
        if (is_raw_image) {
            const container_lookup = if (raw_container_candidate.len > 0)
                raw_container_candidate
            else
                filename;
            try renderStatRow(
                "Container",
                getRawContainerName(mime_type, container_lookup),
            );
            try renderStatRow("Preview MIME", "image/jpeg");
            try renderStatRow("Resolution", res_str);
            if (raw_res_str) |raw_str| {
                try renderStatRow("RAW Sensor", raw_str);
            }
        } else {
            try renderStatRow("MIME Type", mime_type);
            try renderStatRow("Resolution", res_str);
        }
        try renderStatRow("Size on Disk", disk_size_str);
        try renderStatRow("Rendered Size", screen_str);
        const scale_mode_str = switch (ui_model.viewport.fit_mode) {
            .none => "Original size (100%)",
            .shrink => "Fit if larger",
            .full => "Fit to screen (Aspect Fit)",
            .crop => "Fill screen (Aspect Fill)",
            .fit_width => "Fit to width",
            .fit_height => "Fit to height",
        };
        try renderStatRow("Scale Mode", scale_mode_str);
        const reading_dir_str = if (ui_model.manga_mode)
            "Right-to-Left (Manga)"
        else
            "Left-to-Right (Standard)";
        try renderStatRow("Reading Order", reading_dir_str);
        try renderStatRow("Zoom Level", zoom_str);
        try renderStatRow("Pan Offset", pan_str);
        try renderStatRow("Rotation", rot_str);
        const filter_str = switch (ui_model.viewport.scale_filter) {
            .nearest => "Nearest Neighbor",
            .linear => "Bilinear Filter",
            .pixel_art => "Pixel Art (AA-Nearest)",
            .mitchell => "Mitchell-Netravali",
            .lanczos3 => "Lanczos3 Resampler",
            .fsr => "AMD FSR 1.0 (EASU + RCAS)",
            .tiny_cnn => "Tiny CNN (Neural Super-Res)",
        };
        try renderStatRow("Scaling Filter", filter_str);

        // Photographic adjustments (always show Brightness/Contrast, plus
        // any non-default adjustments)
        inline for (std.enums.values(intents.EditParam)) |p| {
            if (p == .brightness or p == .contrast or
                !ui_model.viewport.edits.isParamDefault(p))
            {
                const spec = getSpec(p);
                const val_str = try edit_panel.formatValue(
                    frame_allocator,
                    spec,
                    ui_model.viewport.edits.get(p),
                );
                try renderStatRow(spec.label, val_str);
            }
        }
        if (ui_model.viewport.compare_original) {
            try renderStatRow("Compare Mode", "Before (Original)");
        }
        try renderStatRow("EXIF Thumbnail", thumb_info_str);
        try renderStatRow("Classification", ui_model.current_classification.label());
        try renderStatRow("View Filter", ui_model.view_mode.label());
    });
}

/// Emits Clay UI layout elements for the image metadata panel,
/// performance overlay ("Stats for Nerds"), and preview thumbnail.
pub fn renderStatsOverlay(
    ui_model: UiViewModel,
    draw_w: f32,
    draw_h: f32,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    try renderInfoOverlay(
        ui_model,
        draw_w,
        draw_h,
        frame_allocator,
        measure_data,
    );
    if (!ui_model.overlays.stats_panel.visible) return;

    const current_entry = ui_model.current_entry;

    var mem_size_str: []const u8 = "N/A";
    var read_str: []const u8 = "N/A";
    var decode_str: []const u8 = "N/A";
    var convert_str: []const u8 = "N/A";
    var upload_str: []const u8 = "N/A";

    if (current_entry) |entry| {
        switch (entry.resident.asset) {
            .loaded_cpu => |cpu| {
                read_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{cpu.decode.read_time_ms},
                );
                decode_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{cpu.decode.decode_time_ms},
                );
                convert_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{cpu.decode.conversion_time_ms},
                );
            },
            .loaded_gpu => |gpu| {
                mem_size_str = try formatSize(
                    frame_allocator,
                    gpu.ingest.memory_size_bytes,
                );
                read_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{gpu.decode.read_time_ms},
                );
                decode_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{gpu.decode.decode_time_ms},
                );
                convert_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{gpu.decode.conversion_time_ms},
                );
                upload_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{gpu.ingest.upload_time_ms},
                );
            },
            .none => {
                if (entry.inflight != null) {
                    mem_size_str = "Loading...";
                    read_str = "Loading...";
                    decode_str = "Loading...";
                    convert_str = "Loading...";
                    upload_str = "Loading...";
                }
            },
            .failed => {
                mem_size_str = "Failed";
                read_str = "Failed";
                decode_str = "Failed";
                convert_str = "Failed";
                upload_str = "Failed";
            },
        }
    }

    clay.UI()(floatingHudCardDeclaration(
        "StatsPanel",
        .right_top,
        ui_model.overlays.stats_panel,
        ui_model.overlays.enable_blur,
    ))({
        renderFloatingHudHeader("Stats for Nerds", "StatsCloseBtn");

        // Stats details
        const s = ui_model.stats;
        const img = s.active_image;

        if (current_entry) |entry| {
            if (entry.metadata.raw_metadata.isRaw()) {
                try renderStatRow("Source Mode", "RAW Embedded Preview");
                if (entry.metadata.raw_metadata.getSensorDims()) |s_dims| {
                    if (s_dims.w > 0 and s_dims.h > 0) {
                        const raw_mp = (s_dims.w * s_dims.h) / 1_000_000.0;
                        const r_str = try frame_allocator.print(
                            "{d:.0}x{d:.0} ({d:.2} MP)",
                            .{ s_dims.w, s_dims.h, raw_mp },
                        );
                        try renderStatRow("RAW Sensor", r_str);
                    }
                }
            }
        }

        const hit_str = if (s.current_image_cache_hit) "Yes" else "No";
        try renderStatRow("Cache Hit", hit_str);
        try renderStatRow("Memory Size", mem_size_str);

        const formatted_total_vram = try formatSize(frame_allocator, s.total_vram_bytes);
        const total_vram_str = try frame_allocator.print(
            "{s} / 1024 MB ({d} slots)",
            .{ formatted_total_vram, s.cached_slot_count },
        );
        try renderStatRow("Total Cache VRAM", total_vram_str);

        const workers_str = try frame_allocator.print(
            "{d} / {d}",
            .{ s.active_decode_threads, s.max_decode_threads },
        );
        try renderStatRow("Decode Workers", workers_str);

        try renderStatRow("Disk Read Time", read_str);
        if (img.decode) |dec| {
            switch (dec.archive) {
                .none => {},
                .archive => |arch| {
                    const cbz_time_str = try frame_allocator.print(
                        "{d:.2} ms",
                        .{arch.decompress_time_ms},
                    );
                    try renderStatRow("CBZ Extract Time", cbz_time_str);
                    const comp_size_str = try formatSize(
                        frame_allocator,
                        arch.compressed_size_bytes,
                    );
                    try renderStatRow("Compressed Size", comp_size_str);
                },
            }
        }
        try renderStatRow("Decode Time", decode_str);
        try renderStatRow("Convert Time", convert_str);
        try renderStatRow("GPU Upload", upload_str);

        if (img.ingest) |ing| {
            const upload_mode_str: []const u8 = switch (ing.mode) {
                .direct => "Direct VRAM",
                .fallback => "CPU Downscale Fallback",
            };
            try renderStatRow("GPU Upload Mode", upload_mode_str);
            switch (ing.mode) {
                .direct => {},
                .fallback => |fb| {
                    const fallback_time_str = try frame_allocator.print(
                        "{d:.2} ms",
                        .{fb.fallback_time_ms},
                    );
                    try renderStatRow("CPU Fallback Time", fallback_time_str);
                },
            }
        } else {
            try renderStatRow("GPU Upload Mode", "N/A");
        }

        const thumb_time_str: []const u8 = if (img.has_thumb)
            try frame_allocator.print(
                "{d:.2} ms ({s})",
                .{ img.thumb_upload_time_ms, img.thumb_source.shortLabel() },
            )
        else
            "N/A";
        try renderStatRow("Thumb Load Time", thumb_time_str);

        const ts = s.thumbs;
        const thumb_hits_str = if (ts.totalLookups() > 0)
            try frame_allocator.print(
                "{d} Hdr / {d} Pos / {d} Cache / {d} Miss",
                .{
                    ts.header_hits,
                    ts.positional_hits,
                    ts.cache_hits,
                    ts.misses,
                },
            )
        else
            "0 Hdr / 0 Pos / 0 Cache / 0 Miss";
        try renderStatRow("Thumb Hit Ratio", thumb_hits_str);

        const thumb_writes_str = if (ts.cache_write_queued > 0)
            try frame_allocator.print(
                "{d} Written ({d} Queued)",
                .{ ts.cache_writes, ts.cache_write_queued },
            )
        else
            try frame_allocator.print("{d} Written", .{ts.cache_writes});
        try renderStatRow("Thumb Cache Writes", thumb_writes_str);

        if (img.ingest) |ing| {
            const mipmap_status_str: []const u8 = switch (ing.mipmaps) {
                .disabled => "Disabled (1 Level)",
                .generated => |mip| try frame_allocator.print(
                    "Enabled ({d} Levels)",
                    .{mip.num_levels},
                ),
            };
            try renderStatRow("Mipmap Status", mipmap_status_str);

            const mipmap_time_str: []const u8 = switch (ing.mipmaps) {
                .disabled => "0.00 ms",
                .generated => |mip| try frame_allocator.print(
                    "{d:.2} ms",
                    .{mip.generate_time_ms},
                ),
            };
            try renderStatRow("Mipmap Gen", mipmap_time_str);
        } else {
            try renderStatRow("Mipmap Status", "N/A");
            try renderStatRow("Mipmap Gen", "N/A");
        }

        const rm = ui_model.render_metrics;
        const ui_render_str = try frame_allocator.print(
            "{d:.2} ± {d:.2} ms",
            .{ rm.mean_render_time_ms, rm.stdev_render_time_ms },
        );
        const ui_batches_str = try frame_allocator.print(
            "{d}",
            .{rm.last_ui_batch_count},
        );
        const ui_verts_str = try frame_allocator.print(
            "{d}",
            .{rm.last_ui_vertex_count},
        );
        try renderStatRow("UI Render Pass", ui_render_str);
        try renderStatRow("UI Batches", ui_batches_str);
        try renderStatRow("UI Vertices", ui_verts_str);
    });
}

test "getRawContainerName - format detection" {
    // MIME type matches
    try std.testing.expectEqualStrings(
        "RAW (Fujifilm RAF)",
        getRawContainerName("image/x-fuji-raf", "sample"),
    );
    try std.testing.expectEqualStrings(
        "RAW (Sony ARW)",
        getRawContainerName("image/x-sony-arw", "sample"),
    );
    try std.testing.expectEqualStrings(
        "RAW (Canon CR2)",
        getRawContainerName("image/x-canon-cr2", "sample"),
    );
    try std.testing.expectEqualStrings(
        "RAW (Nikon NEF)",
        getRawContainerName("image/x-nikon-nef", "sample"),
    );
    try std.testing.expectEqualStrings(
        "RAW (Adobe DNG)",
        getRawContainerName("image/x-adobe-dng", "sample"),
    );
    try std.testing.expectEqualStrings(
        "RAW (Olympus ORF)",
        getRawContainerName("image/x-olympus-orf", "sample"),
    );
    try std.testing.expectEqualStrings(
        "RAW (Panasonic RW2)",
        getRawContainerName("image/x-panasonic-rw2", "sample"),
    );
    try std.testing.expectEqualStrings(
        "RAW (Pentax PEF)",
        getRawContainerName("image/x-pentax-pef", "sample"),
    );

    // Filename extension matches (lowercase and uppercase)
    try std.testing.expectEqualStrings("RAW (Fujifilm RAF)", getRawContainerName("", "photo.raf"));
    try std.testing.expectEqualStrings("RAW (Fujifilm RAF)", getRawContainerName("", "PHOTO.RAF"));
    try std.testing.expectEqualStrings("RAW (Sony ARW)", getRawContainerName("", "photo.arw"));
    try std.testing.expectEqualStrings("RAW (Sony ARW)", getRawContainerName("", "PHOTO.ARW"));
    try std.testing.expectEqualStrings("RAW (Canon CR2)", getRawContainerName("", "photo.cr2"));
    try std.testing.expectEqualStrings("RAW (Nikon NEF)", getRawContainerName("", "photo.nef"));
    try std.testing.expectEqualStrings("RAW (Adobe DNG)", getRawContainerName("", "photo.dng"));
    try std.testing.expectEqualStrings("RAW (Olympus ORF)", getRawContainerName("", "photo.orf"));
    try std.testing.expectEqualStrings("RAW (Panasonic RW2)", getRawContainerName("", "photo.rw2"));
    try std.testing.expectEqualStrings("RAW (Pentax PEF)", getRawContainerName("", "photo.pef"));

    // Fallback
    try std.testing.expectEqualStrings("Camera RAW", getRawContainerName("", "photo.xyz"));
    try std.testing.expectEqualStrings(
        "Camera RAW",
        getRawContainerName("image/jpeg", "photo.jpg"),
    );
}

test "floatingHudCardDeclaration - unifies HUD card styling" {
    const info_decl = floatingHudCardDeclaration(
        "InfoOverlayCard",
        .left_top,
        .{ .visible = true, .offset_x = 16.0, .offset_y = 16.0 },
        true,
    );
    const stats_decl = floatingHudCardDeclaration(
        "StatsPanel",
        .right_top,
        .{ .visible = true, .offset_x = -16.0, .offset_y = 16.0 },
        true,
    );

    try std.testing.expectEqual(
        theme.base_translucent,
        info_decl.background_color,
    );
    try std.testing.expectEqual(
        theme.base_translucent,
        stats_decl.background_color,
    );
    try std.testing.expectEqual(
        info_decl.layout.padding,
        stats_decl.layout.padding,
    );
    try std.testing.expectEqual(
        info_decl.layout.child_gap,
        stats_decl.layout.child_gap,
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, @ptrFromInt(ElementTag.blurred_surface.toInt())),
        info_decl.user_data,
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, @ptrFromInt(ElementTag.blurred_surface.toInt())),
        stats_decl.user_data,
    );

    const no_blur_decl = floatingHudCardDeclaration(
        "StatsPanel",
        .right_top,
        .{ .visible = true, .offset_x = -16.0, .offset_y = 16.0 },
        false,
    );
    try std.testing.expectEqual(@as(?*anyopaque, null), no_blur_decl.user_data);
}

test "photographic edit parameter labels and formatted readouts" {
    const allocator = std.testing.allocator;

    // Test formatting of non-default tone, color, and presence parameters
    const highlights_spec = getSpec(.highlights);
    try std.testing.expectEqualStrings("Highlights", highlights_spec.label);
    const hl_str = try edit_panel.formatValue(allocator, highlights_spec, 0.25);
    defer allocator.free(hl_str);
    try std.testing.expectEqualStrings("+25%", hl_str);

    const temp_spec = getSpec(.temperature);
    try std.testing.expectEqualStrings("Temperature", temp_spec.label);
    const temp_str = try edit_panel.formatValue(allocator, temp_spec, 0.15);
    defer allocator.free(temp_str);
    try std.testing.expectEqualStrings("+15 (Warm)", temp_str);

    const clarity_spec = getSpec(.clarity);
    try std.testing.expectEqualStrings("Clarity", clarity_spec.label);
    const clarity_str = try edit_panel.formatValue(
        allocator,
        clarity_spec,
        -0.10,
    );
    defer allocator.free(clarity_str);
    try std.testing.expectEqualStrings("-10%", clarity_str);
}

test "stats - Exhaustive switch renders all telemetry branches correctly" {
    const frame_allocator = std.testing.allocator;

    // Test ArchiveTelemetry switch formatting
    const arch = state.ArchiveTelemetry.init(12.34, 4096);
    const cbz_str = switch (arch) {
        .none => "none",
        .archive => |a| try frame_allocator.print(
            "{d:.2} ms ({d} B)",
            .{ a.decompress_time_ms, a.compressed_size_bytes },
        ),
    };
    defer frame_allocator.free(cbz_str);
    try std.testing.expectEqualStrings("12.34 ms (4096 B)", cbz_str);

    // Test UploadMode switch formatting
    const fb_mode = state.UploadMode.init(true, 8.75);
    const fb_str = switch (fb_mode) {
        .direct => "Direct VRAM",
        .fallback => |fb| try frame_allocator.print(
            "Fallback {d:.2} ms",
            .{fb.fallback_time_ms},
        ),
    };
    defer frame_allocator.free(fb_str);
    try std.testing.expectEqualStrings("Fallback 8.75 ms", fb_str);

    // Test MipmapTelemetry switch formatting
    const gen_mip = state.MipmapTelemetry.init(5, 2.5);
    const mip_str = switch (gen_mip) {
        .disabled => "Disabled (1 Level)",
        .generated => |g| try frame_allocator.print(
            "Enabled ({d} Levels) in {d:.2} ms",
            .{ g.num_levels, g.generate_time_ms },
        ),
    };
    defer frame_allocator.free(mip_str);
    try std.testing.expectEqualStrings(
        "Enabled (5 Levels) in 2.50 ms",
        mip_str,
    );

    // Test disabled / direct / none variants
    const none_arch = state.ArchiveTelemetry.none;
    const direct_upload = state.UploadMode.direct;
    const disabled_mip = state.MipmapTelemetry.disabled;

    try std.testing.expect(switch (none_arch) {
        .none => true,
        .archive => false,
    });
    try std.testing.expect(switch (direct_upload) {
        .direct => true,
        .fallback => false,
    });
    try std.testing.expect(switch (disabled_mip) {
        .disabled => true,
        .generated => false,
    });
}
