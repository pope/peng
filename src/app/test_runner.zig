const std = @import("std");
const c = @import("c.zig").c;
const clay = @import("zclay");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const types = @import("types.zig");
const FrameInput = types.FrameInput;
const MeasureTextUserData = types.MeasureTextUserData;
const ui = @import("../ui.zig");
const GraphicsSetup = ui.graphics.GraphicsSetup;
const GpuResources = ui.graphics.GpuResources;
const renderFrame = ui.layout.renderFrame;

fn compareScreenshots(base_path: [:0]const u8, run_path: [:0]const u8, diff_path: [:0]const u8) !void {
    const raw_base_surf = c.IMG_Load(base_path.ptr) orelse {
        std.log.err("Failed to load baseline screenshot: {s}. Run with --update-baselines to create it.", .{base_path});
        return error.BaselineMissing;
    };
    defer c.SDL_DestroySurface(raw_base_surf);

    const raw_run_surf = c.IMG_Load(run_path.ptr) orelse {
        std.log.err("Failed to load run screenshot: {s}", .{run_path});
        return error.RunScreenshotMissing;
    };
    defer c.SDL_DestroySurface(raw_run_surf);

    if (raw_base_surf.*.w != raw_run_surf.*.w or raw_base_surf.*.h != raw_run_surf.*.h) {
        std.log.err("Dimension mismatch: baseline is {d}x{d}, run is {d}x{d}", .{ raw_base_surf.*.w, raw_base_surf.*.h, raw_run_surf.*.w, raw_run_surf.*.h });
        return error.DimensionMismatch;
    }

    const width = @as(u32, @intCast(raw_base_surf.*.w));
    const height = @as(u32, @intCast(raw_base_surf.*.h));

    // Convert both surfaces to a canonical RGBA32 format to guarantee alignment, pitch, and byte order matching
    const base_surf = c.SDL_ConvertSurface(raw_base_surf, c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.err("Failed to convert baseline to RGBA32: {s}", .{c.SDL_GetError()});
        return error.SurfaceConversionFailed;
    };
    defer c.SDL_DestroySurface(base_surf);

    const run_surf = c.SDL_ConvertSurface(raw_run_surf, c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.err("Failed to convert run to RGBA32: {s}", .{c.SDL_GetError()});
        return error.SurfaceConversionFailed;
    };
    defer c.SDL_DestroySurface(run_surf);

    const diff_surf = c.SDL_CreateSurface(@intCast(width), @intCast(height), c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.err("Failed to create diff surface: {s}", .{c.SDL_GetError()});
        return error.DiffSurfaceCreationFailed;
    };
    defer c.SDL_DestroySurface(diff_surf);

    const pixels_base = @as([*]const u32, @ptrCast(@alignCast(base_surf.*.pixels)));
    const pixels_run = @as([*]const u32, @ptrCast(@alignCast(run_surf.*.pixels)));
    const pixels_diff = @as([*]u32, @ptrCast(@alignCast(diff_surf.*.pixels)));

    const pitch_words_base = @as(usize, @intCast(base_surf.*.pitch)) / 4;
    const pitch_words_run = @as(usize, @intCast(run_surf.*.pitch)) / 4;
    const pitch_words_diff = @as(usize, @intCast(diff_surf.*.pitch)) / 4;

    var mismatched_pixels: u32 = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx_base = y * pitch_words_base + x;
            const idx_run = y * pitch_words_run + x;
            const idx_diff = y * pitch_words_diff + x;

            const p_base = pixels_base[idx_base];
            const p_run = pixels_run[idx_run];
            if (p_base != p_run) {
                mismatched_pixels += 1;
                // Paint mismatched pixel as bright red (0xFF0000FF in RGBA32 format)
                pixels_diff[idx_diff] = 0xFF0000FF;
            } else {
                // Dim color channels (divides by 4) and preserve alpha safely without channel bleeding
                const b0 = (p_base >> 0) & 0xFF;
                const b1 = (p_base >> 8) & 0xFF;
                const b2 = (p_base >> 16) & 0xFF;
                const b3 = (p_base >> 24) & 0xFF;
                pixels_diff[idx_diff] = (b0 / 4) | ((b1 / 4) << 8) | ((b2 / 4) << 16) | (b3 << 24);
            }
        }
    }

    if (mismatched_pixels > 0) {
        const total_pixels = width * height;
        const pct = (@as(f64, @floatFromInt(mismatched_pixels)) / @as(f64, @floatFromInt(total_pixels))) * 100.0;
        std.log.err("Visual regression found: {d} pixels differ ({d:.3}%)", .{ mismatched_pixels, pct });
        if (!c.IMG_SavePNG(diff_surf, diff_path.ptr)) {
            std.log.err("Failed to save diff image: {s}", .{c.SDL_GetError()});
        } else {
            std.log.info("Diff image saved to: {s}", .{diff_path});
        }
        return error.VisualRegressionMismatch;
    }
}

pub fn runIntegrationTests(
    state: *ViewerState,
    setup: *const GraphicsSetup,
    resources: *const GpuResources,
    measure_data: *const MeasureTextUserData,
    gpa: std.mem.Allocator,
    update_baselines: bool,
) !void {
    if (std.Io.Dir.openDir(std.Io.Dir.cwd(), state.io, "testfiles/current-run", .{ .iterate = true })) |dir| {
        var it = std.Io.Dir.iterate(dir);
        while (it.next(state.io) catch null) |entry| {
            std.Io.Dir.deleteFile(dir, state.io, entry.name) catch {};
        }
        std.Io.Dir.close(dir, state.io);
    } else |_| {}

    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), state.io, "testfiles/golden-screenshots") catch {};
    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), state.io, "testfiles/current-run") catch {};

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();

    var test_frame: u32 = 0;
    const filenames = [_][]const u8{
        "test_0_init.png",
        "test_1_zoom.png",
        "test_2_adjust.png",
        "test_3_filter.png",
        "test_4_action_palette.png",
        "test_5_files_palette.png",
        "test_6_next_image.png",
        "test_7_debug_tools.png",
    };
    while (test_frame < 8) : (test_frame += 1) {
        // Pump event loop to prevent OS "Application Unresponsive" warnings
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {}

        _ = frame_arena.reset(.retain_capacity);

        var win_w: c_int = 0;
        var win_h: c_int = 0;
        _ = c.SDL_GetWindowSize(setup.window, &win_w, &win_h);

        var pix_w: c_int = 0;
        var pix_h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(setup.window, &pix_w, &pix_h);

        const width = @as(f32, @floatFromInt(pix_w));
        const height = @as(f32, @floatFromInt(pix_h));
        const scale_x = if (win_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;
        const scale_y = if (win_h > 0) @as(f32, @floatFromInt(pix_h)) / @as(f32, @floatFromInt(win_h)) else 1.0;
        const dpi_scale = scale_x;

        const input = FrameInput{
            .win_w = @as(f32, @floatFromInt(win_w)),
            .win_h = @as(f32, @floatFromInt(win_h)),
            .pix_w = width,
            .pix_h = height,
            .scale_x = scale_x,
            .scale_y = scale_y,
            .dpi_scale = dpi_scale,
            .mouse_x = -1.0,
            .mouse_y = -1.0,
            .mouse_left_down = false,
            .mouse_left_clicked = false,
            .mouse_inside = false,
            .quit_requested = false,
            .scroll_delta_x = 0.0,
            .scroll_delta_y = 0.0,
            .keys_pressed = std.ArrayList(c.SDL_Keycode).empty,
            .key_modifiers = 0,
            .text_input = null,
            .dropped_path = null,
            .ticks = 0,
            .delta_time_ms = 16.666,
        };

        switch (test_frame) {
            0 => {
                std.log.info("Test Mode Frame 0: Initial Render", .{});
            },
            1 => {
                std.log.info("Test Mode Frame 1: Apply Zoom & Pan", .{});
                state.zoom_factor = 2.0;
                state.pan_x = 50.0;
                state.pan_y = -30.0;
            },
            2 => {
                std.log.info("Test Mode Frame 2: Apply Brightness & Contrast", .{});
                state.zoom_factor = 1.0;
                state.pan_x = 0.0;
                state.pan_y = 0.0;
                state.brightness = 0.3;
                state.contrast = 1.4;
                state.adjustments_dirty = true;
            },
            3 => {
                std.log.info("Test Mode Frame 3: Apply Mitchell Filter", .{});
                state.brightness = 0.0;
                state.contrast = 1.0;
                state.adjustments_dirty = true;
                state.texture_scale_mode = .mitchell;
                state.applyTextureScaleMode();
            },
            4 => {
                std.log.info("Test Mode Frame 4: Open Action Palette", .{});
                state.texture_scale_mode = .linear;
                state.applyTextureScaleMode();

                state.palette.reset();
                state.palette.mode = .actions;
                try state.rebuildActionMatches();
            },
            5 => {
                std.log.info("Test Mode Frame 5: Open Files Palette", .{});
                state.palette.reset();
                state.palette.mode = .files;
                try state.rebuildPaletteMatches();
            },
            6 => {
                std.log.info("Test Mode Frame 6: Navigate to Next Image", .{});
                state.palette.mode = .inactive;
                try state.next();
            },
            7 => {
                std.log.info("Test Mode Frame 7: Toggle Clay Debug Mode", .{});
                clay.setDebugModeEnabled(true);
            },
            else => unreachable,
        }

        // Busy wait until the background loader finishes decoding the image
        var wait_attempts: u32 = 0;
        while (wait_attempts < 1000) : (wait_attempts += 1) {
            // Pump event loop during wait to keep window manager happy
            var ev: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&ev)) {}

            if (state.getCurrentEntry()) |entry| {
                if (entry.status != .decoding) {
                    break;
                }
            }
            c.SDL_Delay(10);
        }
        if (state.getCurrentEntry() == null or state.getCurrentEntry().?.status == .failed) {
            std.log.err("Timed out or failed waiting for test image to load in cache.", .{});
            return error.TestImageLoadTimeout;
        }

        clay.setLayoutDimensions(.{ .w = input.pix_w, .h = input.pix_h });
        clay.setPointerState(.{ .x = -1.0, .y = -1.0 }, false);

        const base_filename = try frame_allocator.dupeZ(
            u8,
            try std.fmt.allocPrint(
                frame_allocator,
                "testfiles/golden-screenshots/{s}",
                .{filenames[test_frame]},
            ),
        );
        const run_filename = try frame_allocator.dupeZ(
            u8,
            try std.fmt.allocPrint(
                frame_allocator,
                "testfiles/current-run/{s}",
                .{filenames[test_frame]},
            ),
        );
        const diff_filename = try frame_allocator.dupeZ(
            u8,
            try std.fmt.allocPrint(
                frame_allocator,
                "testfiles/current-run/diff_{s}",
                .{filenames[test_frame]},
            ),
        );

        const capture_path = if (update_baselines) base_filename else run_filename;

        try renderFrame(
            state,
            input,
            frame_allocator,
            resources.fonts[0..],
            measure_data,
            capture_path,
        );

        if (!update_baselines) {
            try compareScreenshots(
                base_filename,
                run_filename,
                diff_filename,
            );
        }
    }
    clay.setDebugModeEnabled(false);
    std.log.info("Test Mode completed successfully!", .{});
}
