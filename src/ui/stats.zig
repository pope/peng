const edit_panel = @import("edit_panel.zig");
const geom = @import("geom");
const intents = @import("intents");
const palette_pkg = @import("palette");
const renderer = @import("renderer.zig");
const state = @import("state");
const std = @import("std");
const text_utils = @import("text_utils.zig");
const theme = @import("theme.zig");
const view_model = @import("view_model.zig");

const formatSize = text_utils.formatSize;
const FRect = geom.FRect;
const getSpec = intents.getSpec;
const LogicalDims = geom.LogicalDims;
const measureText = text_utils.measureText;
const MeasureTextUserData = text_utils.MeasureTextUserData;
const PaletteState = palette_pkg.PaletteState;
const truncateDirectory = text_utils.truncateDirectory;
const truncateFilename = text_utils.truncateFilename;
const UiDrawList = renderer.UiDrawList;
const UiViewModel = view_model.UiViewModel;

fn renderStatRow(
    list: *UiDrawList,
    cursor_x: f32,
    cursor_y: f32,
    content_w: f32,
    label: []const u8,
    value: []const u8,
    measure_data: *const MeasureTextUserData,
) !void {
    var row_rect = FRect{
        .x = cursor_x,
        .y = cursor_y,
        .w = content_w,
        .h = 20.0,
    };
    var label_rect = row_rect.cutLeft(145.0);
    label_rect.h = measureText(label, 0, 13, measure_data).h;
    var value_rect = row_rect;
    value_rect.h = measureText(value, 0, 13, measure_data).h;

    try list.addText(label_rect, .{
        .text = label,
        .color = theme.subtext0,
        .font_size = 13,
        .font_id = 0,
    });
    try list.addText(value_rect, .{
        .text = value,
        .color = theme.text,
        .font_size = 13,
        .font_id = 0,
    });
}

const HudLayoutContext = struct {
    list: *UiDrawList,
    content_x: f32,
    content_w: f32,
    cursor_y: *f32,
    measure_data: *const MeasureTextUserData,

    fn addRow(
        self: HudLayoutContext,
        label: []const u8,
        value: []const u8,
    ) !void {
        self.cursor_y.* += 6.0;
        try renderStatRow(
            self.list,
            self.content_x,
            self.cursor_y.*,
            self.content_w,
            label,
            value,
            self.measure_data,
        );
        self.cursor_y.* += 20.0;
    }
};

fn renderFloatingHudHeader(
    list: *UiDrawList,
    cursor_x: f32,
    cursor_y: f32,
    content_w: f32,
    title: []const u8,
    measure_data: *const MeasureTextUserData,
) !FRect {
    const title_w = content_w - 24.0;
    const title_h = measureText(title, 0, 16, measure_data).h;
    try list.addText(.{
        .x = cursor_x,
        .y = cursor_y,
        .w = title_w,
        .h = title_h,
    }, .{
        .text = title,
        .color = theme.mauve,
        .font_size = 16,
        .font_id = 0,
    });

    const close_rect = FRect{
        .x = cursor_x + content_w - 24.0,
        .y = cursor_y,
        .w = 24.0,
        .h = 24.0,
    };
    try list.addRect(close_rect, .{
        .background_color = theme.surface0,
        .corner_radius = .all(12),
    });
    const x_dims = measureText("x", 0, 12, measure_data);
    const x_off = @round((24.0 - x_dims.w) * 0.5);
    try list.addText(.{
        .x = close_rect.x + x_off,
        .y = close_rect.y,
        .w = x_dims.w,
        .h = 24.0,
    }, .{
        .text = "x",
        .color = theme.text,
        .font_size = 12,
        .font_id = 0,
    });

    return close_rect;
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
    interaction: *state.InteractionState,
    list: *UiDrawList,
    ui_model: UiViewModel,
    draw_dims: LogicalDims,
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
    var screen_w = draw_dims.w;
    var screen_h = draw_dims.h;
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
            .loaded_cpu => |asset| {
                mime_type = asset.cpu.mime_type;
                disk_size_str = try formatSize(
                    frame_allocator,
                    asset.cpu.size_bytes,
                );
                const megapixels = (asset.cpu.w * asset.cpu.h) / 1_000_000.0;
                const is_raw = entry.metadata.raw_metadata.isRaw();
                const prev_suffix = if (is_raw) " [PREVIEW]" else "";
                res_str = try frame_allocator.print(
                    "{d:.0}x{d:.0} ({d:.2} MP){s}",
                    .{ asset.cpu.w, asset.cpu.h, megapixels, prev_suffix },
                );
            },
            .loaded_gpu, .promoting_gpu => {
                const gpu = switch (entry.resident.asset) {
                    .loaded_gpu => |g| g,
                    .promoting_gpu => |promo| promo.active,
                    .loaded_cpu, .none, .failed => unreachable,
                };
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
            .none => switch (entry.inflight) {
                .idle => {},
                .queued_decode, .decoding, .uploading => {
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
                },
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

    const card_x = ui_model.overlays.info_panel.offset_x;
    const card_y = ui_model.overlays.info_panel.offset_y;
    const card_w: f32 = 380.0;
    const content_x = card_x + 14.0;
    const content_w = card_w - 28.0;
    var cursor_y = card_y + 12.0;

    const bg_idx = try list.reserve();
    const close_rect = try renderFloatingHudHeader(
        list,
        content_x,
        cursor_y,
        content_w,
        "Info Overlay",
        measure_data,
    );
    cursor_y += 24.0;

    var hud = HudLayoutContext{
        .list = list,
        .content_x = content_x,
        .content_w = content_w,
        .cursor_y = &cursor_y,
        .measure_data = measure_data,
    };

    // Info details
    try hud.addRow("File Name", filename);
    try hud.addRow("Directory", display_dir);
    if (is_raw_image) {
        const container_lookup = if (raw_container_candidate.len > 0)
            raw_container_candidate
        else
            filename;
        try hud.addRow(
            "Container",
            getRawContainerName(mime_type, container_lookup),
        );
        try hud.addRow("Preview MIME", "image/jpeg");
        try hud.addRow("Resolution", res_str);
        if (raw_res_str) |raw_str| {
            try hud.addRow("RAW Sensor", raw_str);
        }
    } else {
        try hud.addRow("MIME Type", mime_type);
        try hud.addRow("Resolution", res_str);
    }
    try hud.addRow("Size on Disk", disk_size_str);
    try hud.addRow("Rendered Size", screen_str);
    const scale_mode_str = switch (ui_model.viewport.fit_mode) {
        .none => "Original size (100%)",
        .shrink => "Fit if larger",
        .full => "Fit to screen (Aspect Fit)",
        .crop => "Fill screen (Aspect Fill)",
        .fit_width => "Fit to width",
        .fit_height => "Fit to height",
    };
    try hud.addRow("Scale Mode", scale_mode_str);
    const reading_dir_str = if (ui_model.manga_mode)
        "Right-to-Left (Manga)"
    else
        "Left-to-Right (Standard)";
    try hud.addRow("Reading Order", reading_dir_str);
    try hud.addRow("Zoom Level", zoom_str);
    try hud.addRow("Pan Offset", pan_str);
    try hud.addRow("Rotation", rot_str);
    const filter_str = switch (ui_model.viewport.scale_filter) {
        .nearest => "Nearest Neighbor",
        .linear => "Bilinear Filter",
        .pixel_art => "Pixel Art (AA-Nearest)",
        .mitchell => "Mitchell-Netravali",
        .lanczos3 => "Lanczos3 Resampler",
        .fsr => "AMD FSR 1.0 (EASU + RCAS)",
        .tiny_cnn => "Tiny CNN (Neural Super-Res)",
    };
    try hud.addRow("Scaling Filter", filter_str);

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
            try hud.addRow(spec.label, val_str);
        }
    }
    if (ui_model.viewport.compare_original) {
        try hud.addRow("Compare Mode", "Before (Original)");
    }
    try hud.addRow("EXIF Thumbnail", thumb_info_str);
    try hud.addRow(
        "Classification",
        ui_model.current_classification.label(),
    );
    try hud.addRow("View Filter", ui_model.view_mode.label());

    const total_card_h = (cursor_y - card_y) + 12.0;
    const card_rect = FRect{
        .x = card_x,
        .y = card_y,
        .w = card_w,
        .h = total_card_h,
    };
    list.set(bg_idx, .{
        .rect = card_rect,
        .payload = .{
            .rectangle = .{
                .background_color = theme.base_translucent,
                .corner_radius = .all(10),
                .tag = if (ui_model.overlays.enable_blur)
                    .blurred_surface
                else
                    .none,
            },
        },
    });
    try list.addBorder(card_rect, .{
        .color = theme.surface0,
        .width = .all(1),
        .corner_radius = .all(10),
    });
    interaction.setInfoPanelRects(card_rect, close_rect);
}

fn renderAtlasOverlay(
    interaction: *state.InteractionState,
    list: *UiDrawList,
    ui_model: UiViewModel,
    win_dims: LogicalDims,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    if (!ui_model.overlays.atlas_panel.visible) return;

    const max_by_win = @min(win_dims.w, win_dims.h) * 0.75;
    const preview_size = @round(@max(128.0, @min(1024.0, max_by_win)));
    const content_w = @max(352.0, preview_size);
    const card_w = content_w + 28.0;
    const card_x = ui_model.overlays.atlas_panel.offset_x;
    const card_y = ui_model.overlays.atlas_panel.offset_y;
    const content_x = card_x + 14.0;
    var cursor_y = card_y + 12.0;

    const bg_idx = try list.reserve();
    const close_rect = try renderFloatingHudHeader(
        list,
        content_x,
        cursor_y,
        content_w,
        "Font Atlas Debug",
        measure_data,
    );
    cursor_y += 24.0;

    var hud = HudLayoutContext{
        .list = list,
        .content_x = content_x,
        .content_w = content_w,
        .cursor_y = &cursor_y,
        .measure_data = measure_data,
    };

    const rm = ui_model.render_metrics;
    const cache_opt = measure_data.measurer.cache;
    const shelf_x = if (cache_opt) |c| c.packer.cur_x else rm.atlas_shelf_x;
    const shelf_y = if (cache_opt) |c| c.packer.cur_y else rm.atlas_shelf_y;
    const used_h = if (cache_opt) |c| c.usedHeight() else rm.atlas_used_h;
    const page_count = if (cache_opt) |c| c.page_count else rm.atlas_page_count;
    const ascii_glyphs = if (cache_opt) |c|
        c.countCachedAsciiGlyphs()
    else
        rm.atlas_ascii_glyphs;
    const unicode_glyphs = if (cache_opt) |c|
        c.glyphs.count()
    else
        rm.atlas_unicode_glyphs;

    const used_pct = (@as(f32, @floatFromInt(used_h)) * 100.0) / 1024.0;
    const shelf_str = try frame_allocator.print(
        "x={d}, y={d} ({d}/1024 px, {d:.1}%)",
        .{ shelf_x, shelf_y, used_h, used_pct },
    );
    const pages_str = try frame_allocator.print(
        "{d} / 12",
        .{page_count},
    );
    const glyphs_str = try frame_allocator.print(
        "{d} ASCII + {d} Unicode",
        .{ ascii_glyphs, unicode_glyphs },
    );

    try hud.addRow("Atlas Texture", "1024x1024 RGBA8 (4.0 MB)");
    try hud.addRow("Shelf Cursor", shelf_str);
    try hud.addRow("Font Size Pages", pages_str);
    try hud.addRow("Cached Glyphs", glyphs_str);

    cursor_y += 6.0;
    const preview_rect = FRect{
        .x = content_x + @round((content_w - preview_size) * 0.5),
        .y = cursor_y,
        .w = preview_size,
        .h = preview_size,
    };
    try list.addRect(preview_rect, .{
        .background_color = theme.crust,
        .corner_radius = .all(4),
    });
    try list.addAtlasPreview(preview_rect, theme.text);
    if (used_h > 0 and used_h <= 1024) {
        const wy = preview_rect.y +
            (@as(f32, @floatFromInt(used_h)) / 1024.0) * preview_rect.h;
        try list.addRect(.{
            .x = preview_rect.x,
            .y = wy,
            .w = preview_rect.w,
            .h = 1.0,
        }, .{
            .background_color = theme.withAlpha(theme.blue, 0.65),
        });
    }
    try list.addBorder(preview_rect, .{
        .color = theme.surface1,
        .width = .all(1),
        .corner_radius = .all(4),
    });
    cursor_y += preview_size;

    const total_card_h = (cursor_y - card_y) + 12.0;
    const card_rect = FRect{
        .x = card_x,
        .y = card_y,
        .w = card_w,
        .h = total_card_h,
    };
    list.set(bg_idx, .{
        .rect = card_rect,
        .payload = .{
            .rectangle = .{
                .background_color = theme.base_translucent,
                .corner_radius = .all(10),
                .tag = if (ui_model.overlays.enable_blur)
                    .blurred_surface
                else
                    .none,
            },
        },
    });
    try list.addBorder(card_rect, .{
        .color = theme.surface0,
        .width = .all(1),
        .corner_radius = .all(10),
    });
    interaction.setAtlasPanelRects(card_rect, close_rect);
}

/// Emits UI draw commands for the image metadata panel and performance overlay.
pub fn renderStatsOverlay(
    interaction: *state.InteractionState,
    list: *UiDrawList,
    ui_model: UiViewModel,
    win_dims: LogicalDims,
    draw_dims: LogicalDims,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    try renderInfoOverlay(
        interaction,
        list,
        ui_model,
        draw_dims,
        frame_allocator,
        measure_data,
    );
    try renderAtlasOverlay(
        interaction,
        list,
        ui_model,
        win_dims,
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
            .loaded_cpu => |asset| {
                read_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{asset.cpu.decode.read_time_ms},
                );
                decode_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{asset.cpu.decode.decode_time_ms},
                );
                convert_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{asset.cpu.decode.conversion_time_ms},
                );
            },
            .loaded_gpu, .promoting_gpu => {
                const gpu = switch (entry.resident.asset) {
                    .loaded_gpu => |g| g,
                    .promoting_gpu => |promo| promo.active,
                    .loaded_cpu, .none, .failed => unreachable,
                };
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
            .none => switch (entry.inflight) {
                .idle => {},
                .queued_decode, .decoding, .uploading => {
                    mem_size_str = "Loading...";
                    read_str = "Loading...";
                    decode_str = "Loading...";
                    convert_str = "Loading...";
                    upload_str = "Loading...";
                },
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

    const card_x = win_dims.w - 380.0 + ui_model.overlays.stats_panel.offset_x;
    const card_y = ui_model.overlays.stats_panel.offset_y;
    const card_w: f32 = 380.0;
    const content_x = card_x + 14.0;
    const content_w = card_w - 28.0;
    var cursor_y = card_y + 12.0;

    const bg_idx = try list.reserve();
    const close_rect = try renderFloatingHudHeader(
        list,
        content_x,
        cursor_y,
        content_w,
        "Stats for Nerds",
        measure_data,
    );
    cursor_y += 24.0;

    var hud = HudLayoutContext{
        .list = list,
        .content_x = content_x,
        .content_w = content_w,
        .cursor_y = &cursor_y,
        .measure_data = measure_data,
    };

    // Stats details
    const s = ui_model.stats;
    const img = s.active_image;

    if (current_entry) |entry| {
        if (entry.metadata.raw_metadata.isRaw()) {
            try hud.addRow("Source Mode", "RAW Embedded Preview");
            if (entry.metadata.raw_metadata.getSensorDims()) |s_dims| {
                if (s_dims.w > 0 and s_dims.h > 0) {
                    const raw_mp = (s_dims.w * s_dims.h) / 1_000_000.0;
                    const r_str = try frame_allocator.print(
                        "{d:.0}x{d:.0} ({d:.2} MP)",
                        .{ s_dims.w, s_dims.h, raw_mp },
                    );
                    try hud.addRow("RAW Sensor", r_str);
                }
            }
        }
    }

    const hit_str = if (s.current_image_cache_hit) "Yes" else "No";
    try hud.addRow("Cache Hit", hit_str);
    try hud.addRow("Memory Size", mem_size_str);

    const formatted_total_vram =
        try formatSize(frame_allocator, s.total_vram_bytes);
    const total_vram_str = try frame_allocator.print(
        "{s} / 1024 MB ({d} slots)",
        .{ formatted_total_vram, s.cached_slot_count },
    );
    try hud.addRow("Total Cache VRAM", total_vram_str);

    const workers_str = try frame_allocator.print(
        "{d} / {d}",
        .{ s.active_decode_threads, s.max_decode_threads },
    );
    try hud.addRow("Decode Workers", workers_str);

    try hud.addRow("Disk Read Time", read_str);
    if (img.decode) |dec| {
        switch (dec.archive) {
            .none => {},
            .archive => |arch| {
                const cbz_time_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{arch.decompress_time_ms},
                );
                try hud.addRow("CBZ Extract Time", cbz_time_str);
                const comp_size_str = try formatSize(
                    frame_allocator,
                    arch.compressed_size_bytes,
                );
                try hud.addRow("Compressed Size", comp_size_str);
            },
        }
    }
    try hud.addRow("Decode Time", decode_str);
    try hud.addRow("Convert Time", convert_str);
    try hud.addRow("GPU Upload", upload_str);

    if (img.ingest) |ing| {
        const upload_mode_str: []const u8 = switch (ing.mode) {
            .direct => "Direct VRAM",
            .fallback => "CPU Downscale Fallback",
        };
        try hud.addRow("GPU Upload Mode", upload_mode_str);
        switch (ing.mode) {
            .direct => {},
            .fallback => |fb| {
                const fallback_time_str = try frame_allocator.print(
                    "{d:.2} ms",
                    .{fb.fallback_time_ms},
                );
                try hud.addRow("CPU Fallback Time", fallback_time_str);
            },
        }
    } else {
        try hud.addRow("GPU Upload Mode", "N/A");
    }

    const thumb_time_str: []const u8 = if (img.has_thumb)
        try frame_allocator.print(
            "{d:.2} ms ({s})",
            .{ img.thumb_upload_time_ms, img.thumb_source.shortLabel() },
        )
    else
        "N/A";
    try hud.addRow("Thumb Load Time", thumb_time_str);

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
    try hud.addRow("Thumb Hit Ratio", thumb_hits_str);

    const thumb_writes_str = if (ts.cache_write_queued > 0)
        try frame_allocator.print(
            "{d} Written ({d} Queued)",
            .{ ts.cache_writes, ts.cache_write_queued },
        )
    else
        try frame_allocator.print("{d} Written", .{ts.cache_writes});
    try hud.addRow("Thumb Cache Writes", thumb_writes_str);

    if (img.ingest) |ing| {
        const mipmap_status_str: []const u8 = switch (ing.mipmaps) {
            .disabled => "Disabled (1 Level)",
            .generated => |mip| try frame_allocator.print(
                "Enabled ({d} Levels)",
                .{mip.num_levels},
            ),
        };
        try hud.addRow("Mipmap Status", mipmap_status_str);

        const mipmap_time_str: []const u8 = switch (ing.mipmaps) {
            .disabled => "0.00 ms",
            .generated => |mip| try frame_allocator.print(
                "{d:.2} ms",
                .{mip.generate_time_ms},
            ),
        };
        try hud.addRow("Mipmap Gen", mipmap_time_str);
    } else {
        try hud.addRow("Mipmap Status", "N/A");
        try hud.addRow("Mipmap Gen", "N/A");
    }

    const frame_total_str = try frame_allocator.print(
        "{d:.2} ± {d:.2} ms (max {d:.2})",
        .{ s.frame.total.mean, s.frame.total.stdev, s.frame.total.max },
    );
    const frame_ingest_str = try frame_allocator.print(
        "{d:.2} ms (max {d:.2})",
        .{ s.frame.ingest.mean, s.frame.ingest.max },
    );
    const frame_intents_str = try frame_allocator.print(
        "{d:.2} ms (max {d:.2})",
        .{ s.frame.intents.mean, s.frame.intents.max },
    );
    const frame_sync_str = try frame_allocator.print(
        "{d:.2} ms (max {d:.2})",
        .{ s.frame.sync.mean, s.frame.sync.max },
    );
    const frame_layout_str = try frame_allocator.print(
        "{d:.2} ms (max {d:.2})",
        .{ s.frame.ui_layout.mean, s.frame.ui_layout.max },
    );
    const frame_encode_str = try frame_allocator.print(
        "{d:.2} ms (max {d:.2})",
        .{ s.frame.gpu_encode.mean, s.frame.gpu_encode.max },
    );
    const frame_wait_str = try frame_allocator.print(
        "{d:.2} ms (max {d:.2})",
        .{ s.frame.swapchain_wait.mean, s.frame.swapchain_wait.max },
    );
    const fps_str: []const u8 = switch (s.frame.present) {
        .active => |fps| try frame_allocator.print("{d:.1} FPS", .{fps}),
        .idle => |idle| if (idle.last_fps) |last|
            try frame_allocator.print("Idle (last {d:.1} FPS)", .{last})
        else
            "Idle",
    };
    try hud.addRow("Frame Rate", fps_str);
    try hud.addRow("Frame CPU", frame_total_str);
    try hud.addRow("  1. Ingest", frame_ingest_str);
    try hud.addRow("  2a. Intents", frame_intents_str);
    try hud.addRow("  2b. Sync/Upload", frame_sync_str);
    try hud.addRow("  3a. UI Layout", frame_layout_str);
    try hud.addRow("  3b. GPU Encode", frame_encode_str);
    try hud.addRow("Swapchain Wait", frame_wait_str);

    const rm = ui_model.render_metrics;
    const ui_batches_str = try frame_allocator.print(
        "{d}",
        .{rm.last_ui_batch_count},
    );
    const ui_verts_str = try frame_allocator.print(
        "{d}",
        .{rm.last_ui_vertex_count},
    );
    try hud.addRow("UI Batches", ui_batches_str);
    try hud.addRow("UI Vertices", ui_verts_str);

    const total_card_h = (cursor_y - card_y) + 12.0;
    const card_rect = FRect{
        .x = card_x,
        .y = card_y,
        .w = card_w,
        .h = total_card_h,
    };
    list.set(bg_idx, .{
        .rect = card_rect,
        .payload = .{
            .rectangle = .{
                .background_color = theme.base_translucent,
                .corner_radius = .all(10),
                .tag = if (ui_model.overlays.enable_blur)
                    .blurred_surface
                else
                    .none,
            },
        },
    });
    try list.addBorder(card_rect, .{
        .color = theme.surface0,
        .width = .all(1),
        .corner_radius = .all(10),
    });
    interaction.setStatsPanelRects(card_rect, close_rect);
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

test "floating HUD overlay card geometry and hit rects" {
    var interaction_inst: state.InteractionState = .{};

    const card_rect = FRect{ .x = 10, .y = 10, .w = 380, .h = 200 };
    const close_rect = FRect{ .x = 360, .y = 22, .w = 24, .h = 24 };
    interaction_inst.setInfoPanelRects(card_rect, close_rect);

    try std.testing.expect(card_rect.contains(.{ .x = 20, .y = 20 }));
    try std.testing.expect(close_rect.contains(.{ .x = 365, .y = 25 }));
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

test "renderStatsOverlay emits per-phase frame timings and max spikes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame_alloc = arena.allocator();

    var pal_state = try PaletteState.init(std.testing.allocator);
    defer pal_state.deinit(std.testing.allocator);

    var interaction_inst: state.InteractionState = .{};
    interaction_inst.beginFrameLayout();

    var overlays = state.OverlayState{};
    overlays.stats_panel.visible = true;

    const model = UiViewModel{
        .is_fullscreen = false,
        .total_images = 0,
        .current_index = null,
        .is_loading_files = false,
        .overlays = overlays,
        .viewport = .{},
        .palette = &pal_state,
        .debug_show_thumb = false,
        .stats = .{
            .frame = .{
                .ingest = .{ .mean = 0.42, .stdev = 0.05, .max = 0.89 },
                .intents = .{ .mean = 0.15, .stdev = 0.02, .max = 0.30 },
                .sync = .{ .mean = 1.25, .stdev = 0.10, .max = 2.50 },
                .ui_layout = .{ .mean = 0.88, .stdev = 0.10, .max = 1.60 },
                .gpu_encode = .{ .mean = 1.30, .stdev = 0.15, .max = 2.50 },
                .swapchain_wait = .{
                    .mean = 14.20,
                    .stdev = 0.50,
                    .max = 16.40,
                },
                .total = .{ .mean = 4.00, .stdev = 0.31, .max = 6.75 },
            },
        },
        .render_metrics = .{
            .last_ui_batch_count = 5,
            .last_ui_vertex_count = 240,
        },
    };

    var draw_list = UiDrawList{ .allocator = frame_alloc };
    const measure_data = MeasureTextUserData{};
    const dims = LogicalDims{ .w = 1024.0, .h = 768.0 };
    try renderStatsOverlay(
        &interaction_inst,
        &draw_list,
        model,
        dims,
        dims,
        frame_alloc,
        &measure_data,
    );

    const card = interaction_inst.stats_card orelse
        return error.TestExpectedStatsCard;
    try std.testing.expectEqual(@as(f32, 380.0), card.w);
    try std.testing.expect(card.h > 0.0);

    const expected = [_][]const u8{
        "Frame Rate",
        "Idle",
        "Frame CPU",
        "4.00 ± 0.31 ms (max 6.75)",
        "  1. Ingest",
        "0.42 ms (max 0.89)",
        "  2a. Intents",
        "0.15 ms (max 0.30)",
        "  2b. Sync/Upload",
        "1.25 ms (max 2.50)",
        "  3a. UI Layout",
        "0.88 ms (max 1.60)",
        "  3b. GPU Encode",
        "1.30 ms (max 2.50)",
        "Swapchain Wait",
        "14.20 ms (max 16.40)",
        "UI Batches",
        "5",
        "UI Vertices",
        "240",
    };

    for (expected) |needle| {
        var found = false;
        for (draw_list.commands.items) |cmd| {
            switch (cmd.payload) {
                .text => |t| {
                    if (std.mem.eql(u8, t.text, needle)) {
                        found = true;
                        break;
                    }
                },
                .scissor_start,
                .scissor_end,
                .rectangle,
                .border,
                .text_runs,
                .image,
                .atlas_preview,
                => {},
            }
        }
        try std.testing.expect(found);
    }
}

fn drawListHasText(draw_list: *const UiDrawList, needle: []const u8) bool {
    for (draw_list.commands.items) |cmd| {
        switch (cmd.payload) {
            .text => |t| {
                if (std.mem.eql(u8, t.text, needle)) return true;
            },
            .scissor_start,
            .scissor_end,
            .rectangle,
            .border,
            .text_runs,
            .image,
            .atlas_preview,
            => {},
        }
    }
    return false;
}

test "renderStatsOverlay formats active and settled PresentCadence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame_alloc = arena.allocator();

    var pal_state = try PaletteState.init(std.testing.allocator);
    defer pal_state.deinit(std.testing.allocator);

    var overlays = state.OverlayState{};
    overlays.stats_panel.visible = true;
    const dims = LogicalDims{ .w = 1024.0, .h = 768.0 };
    const measure_data = MeasureTextUserData{};

    // 1. Latched swapchain FPS -> "120.0 FPS"
    var interaction_active: state.InteractionState = .{};
    interaction_active.beginFrameLayout();
    var list_active = UiDrawList{ .allocator = frame_alloc };
    try renderStatsOverlay(
        &interaction_active,
        &list_active,
        .{
            .is_fullscreen = false,
            .total_images = 0,
            .current_index = null,
            .is_loading_files = false,
            .overlays = overlays,
            .viewport = .{},
            .palette = &pal_state,
            .debug_show_thumb = false,
            .stats = .{
                .frame = .{
                    .present = .{ .active = 120.0 },
                },
            },
        },
        dims,
        dims,
        frame_alloc,
        &measure_data,
    );
    try std.testing.expect(drawListHasText(&list_active, "Frame Rate"));
    try std.testing.expect(drawListHasText(&list_active, "120.0 FPS"));

    // 2. Settled idle with last FPS -> "Idle (last 120.0 FPS)"
    var interaction_idle: state.InteractionState = .{};
    interaction_idle.beginFrameLayout();
    var list_idle = UiDrawList{ .allocator = frame_alloc };
    try renderStatsOverlay(
        &interaction_idle,
        &list_idle,
        .{
            .is_fullscreen = false,
            .total_images = 0,
            .current_index = null,
            .is_loading_files = false,
            .overlays = overlays,
            .viewport = .{},
            .palette = &pal_state,
            .debug_show_thumb = false,
            .stats = .{
                .frame = .{
                    .present = .{
                        .idle = .{ .last_fps = 120.0 },
                    },
                },
            },
        },
        dims,
        dims,
        frame_alloc,
        &measure_data,
    );
    try std.testing.expect(drawListHasText(&list_idle, "Frame Rate"));
    try std.testing.expect(
        drawListHasText(&list_idle, "Idle (last 120.0 FPS)"),
    );
}
