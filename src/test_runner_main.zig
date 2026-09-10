const sdl = @import("sdl");
const std = @import("std");

const CompareResult = struct {
    mismatched_pixels: u32,
    pct: f64,
};

fn compareScreenshots(
    base_path: [:0]const u8,
    run_path: [:0]const u8,
    diff_path: [:0]const u8,
    max_tolerance_pct: f64,
) !CompareResult {
    const raw_base_surf = sdl.Surface.loadFile(base_path) catch {
        std.log.err(
            "Failed to load baseline screenshot: {s}. " ++
                "Run with --update-baselines to create it.",
            .{base_path},
        );
        return error.BaselineMissing;
    };
    defer raw_base_surf.destroy();

    const raw_run_surf = sdl.Surface.loadFile(run_path) catch {
        std.log.err("Failed to load run screenshot: {s}", .{run_path});
        return error.RunScreenshotMissing;
    };
    defer raw_run_surf.destroy();

    if (raw_base_surf.w() != raw_run_surf.w() or raw_base_surf.h() != raw_run_surf.h()) {
        std.log.err(
            "Dimension mismatch: baseline is {d}x{d}, run is {d}x{d}",
            .{ raw_base_surf.w(), raw_base_surf.h(), raw_run_surf.w(), raw_run_surf.h() },
        );
        return error.DimensionMismatch;
    }

    const width = @as(u32, @intCast(raw_base_surf.w()));
    const height = @as(u32, @intCast(raw_base_surf.h()));

    const base_surf = raw_base_surf.convert(sdl.PixelFormat.rgba32) orelse {
        std.log.err("Failed to convert baseline to RGBA32", .{});
        return error.SurfaceConversionFailed;
    };
    defer base_surf.destroy();

    const run_surf = raw_run_surf.convert(sdl.PixelFormat.rgba32) orelse {
        std.log.err("Failed to convert run to RGBA32", .{});
        return error.SurfaceConversionFailed;
    };
    defer run_surf.destroy();

    const diff_surf = sdl.Surface.create(
        @intCast(width),
        @intCast(height),
        sdl.PixelFormat.rgba32,
    ) orelse {
        std.log.err("Failed to create diff surface", .{});
        return error.DiffSurfaceCreationFailed;
    };
    defer diff_surf.destroy();

    const pixels_base = @as([*]align(1) const u32, @ptrCast(base_surf.pixels()));
    const pixels_run = @as([*]align(1) const u32, @ptrCast(run_surf.pixels()));
    const pixels_diff = @as([*]align(1) u32, @ptrCast(diff_surf.pixels()));

    const pitch_words_base = @as(usize, @intCast(base_surf.pitch())) / 4;
    const pitch_words_run = @as(usize, @intCast(run_surf.pitch())) / 4;
    const pitch_words_diff = @as(usize, @intCast(diff_surf.pitch())) / 4;

    const Vec8u32 = @Vector(8, u32);
    var mismatched_pixels: u32 = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x + 8 <= width) : (x += 8) {
            const offset_base = y * pitch_words_base + x;
            const offset_run = y * pitch_words_run + x;
            const offset_diff = y * pitch_words_diff + x;

            const v_base = @as(*align(1) const Vec8u32, @ptrCast(&pixels_base[offset_base])).*;
            const v_run = @as(*align(1) const Vec8u32, @ptrCast(&pixels_run[offset_run])).*;

            const cmp = v_base != v_run;
            if (@reduce(.Or, cmp)) {
                inline for (0..8) |i| {
                    const pb = v_base[i];
                    const pr = v_run[i];
                    if (pb != pr) {
                        mismatched_pixels += 1;
                        pixels_diff[offset_diff + i] = 0xFF0000FF;
                    } else {
                        pixels_diff[offset_diff + i] = ((pb >> 2) & 0x003F3F3F) | (pb & 0xFF000000);
                    }
                }
            } else {
                const rgb_dimmed = (v_base >> @as(Vec8u32, @splat(2))) &
                    @as(Vec8u32, @splat(0x003F3F3F));
                const alpha = v_base & @as(Vec8u32, @splat(0xFF000000));
                const dimmed_vec = rgb_dimmed | alpha;
                @as(*align(1) Vec8u32, @ptrCast(&pixels_diff[offset_diff])).* = dimmed_vec;
            }
        }

        while (x < width) : (x += 1) {
            const idx_base = y * pitch_words_base + x;
            const idx_run = y * pitch_words_run + x;
            const idx_diff = y * pitch_words_diff + x;

            const p_base = pixels_base[idx_base];
            const p_run = pixels_run[idx_run];
            if (p_base != p_run) {
                mismatched_pixels += 1;
                pixels_diff[idx_diff] = 0xFF0000FF;
            } else {
                pixels_diff[idx_diff] = ((p_base >> 2) & 0x003F3F3F) | (p_base & 0xFF000000);
            }
        }
    }

    if (mismatched_pixels > 0) {
        const total_pixels = width * height;
        const pct = (@as(f64, @floatFromInt(mismatched_pixels)) /
            @as(f64, @floatFromInt(total_pixels))) * 100.0;

        if (!diff_surf.savePng(diff_path)) {
            std.log.err("Failed to save diff image", .{});
        } else {
            std.log.info("Diff image saved to: {s}", .{diff_path});
        }

        if (pct > max_tolerance_pct) {
            std.log.err(
                "Major visual regression found: {d} pixels differ " ++
                    "({d:.3}% > max tolerance {d:.1}%)",
                .{ mismatched_pixels, pct, max_tolerance_pct },
            );
        } else {
            std.log.warn(
                "Visual discrepancy found: {d} pixels differ " ++
                    "({d:.3}% <= tolerance {d:.1}%)",
                .{ mismatched_pixels, pct, max_tolerance_pct },
            );
        }
        return CompareResult{
            .mismatched_pixels = mismatched_pixels,
            .pct = pct,
        };
    }

    return CompareResult{
        .mismatched_pixels = 0,
        .pct = 0.0,
    };
}

var global_io: std.Io = undefined;

fn sendCommand(socket_path: []const u8, command: []const u8) !void {
    std.log.info("Sending IPC command: {s}", .{command});
    const io = global_io;
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(command);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const response_opt = try reader.interface.takeDelimiter('\n');
    const response = response_opt orelse return error.NoResponse;

    const trimmed = std.mem.trim(u8, response, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "ERR")) {
        std.log.err("IPC Command '{s}' failed: {s}", .{ command, trimmed });
        return error.IpcCommandFailed;
    }
}

fn expectCommandFailure(socket_path: []const u8, command: []const u8) !void {
    const io = global_io;
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(command);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const response_opt = try reader.interface.takeDelimiter('\n');
    const response = response_opt orelse return error.NoResponse;

    const trimmed = std.mem.trim(u8, response, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "ERR")) {
        std.log.err(
            "IPC Command '{s}' was expected to fail, but succeeded with: {s}",
            .{ command, trimmed },
        );
        return error.IpcCommandSucceededUnexpectedly;
    }
}

fn captureAndVerify(
    gpa: std.mem.Allocator,
    socket_path: []const u8,
    base_dir: []const u8,
    run_dir: []const u8,
    run_name: []const u8,
    baseline_name: []const u8,
    update_baselines: bool,
    max_tolerance_pct: f64,
) !bool {
    if (update_baselines) {
        const base_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_dir, baseline_name });
        defer gpa.free(base_path);
        const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{base_path});
        defer gpa.free(cmd);
        try sendCommand(socket_path, cmd);
        return false;
    }

    const run_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ run_dir, run_name });
    defer gpa.free(run_path);
    const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{run_path});
    defer gpa.free(cmd);
    try sendCommand(socket_path, cmd);

    const base_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_dir, baseline_name });
    defer gpa.free(base_path);
    const base_path_z = try gpa.dupeZ(u8, base_path);
    defer gpa.free(base_path_z);

    const run_path_z = try gpa.dupeZ(u8, run_path);
    defer gpa.free(run_path_z);

    const diff_path = try std.fmt.allocPrint(gpa, "{s}/diff_{s}", .{ run_dir, run_name });
    defer gpa.free(diff_path);
    const diff_path_z = try gpa.dupeZ(u8, diff_path);
    defer gpa.free(diff_path_z);

    const res = try compareScreenshots(base_path_z, run_path_z, diff_path_z, max_tolerance_pct);
    return res.pct > max_tolerance_pct;
}

/// Visual regression and integration test harness runner that executes automated
/// IPC test sequences and compares screenshots against goldens.
pub fn main(init: std.process.Init) !void {
    global_io = init.io;
    const gpa = init.gpa;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    var update_baselines = false;
    var max_tolerance_pct: f64 = 2.0;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help_text =
                \\Peng Visual Integration Test Runner
                \\
                \\Usage:
                \\  zig build test -- [options]
                \\
                \\Options:
                \\  -h, --help           Show this help message and exit
                \\  --update-baselines   Update golden baseline screenshots
                \\  --tolerance <pct>    Max allowed pixel diff pct (default: 2.0%)
                \\  --max-diff-pct <pct> Alias for --tolerance
                \\
            ;
            std.debug.print("{s}", .{help_text});
            return;
        } else if (std.mem.eql(u8, arg, "--update-baselines")) {
            update_baselines = true;
        } else if (std.mem.eql(u8, arg, "--max-diff-pct") or std.mem.eql(u8, arg, "--tolerance")) {
            if (args_it.next()) |val_str| {
                if (std.fmt.parseFloat(f64, val_str)) |val| {
                    max_tolerance_pct = val;
                } else |err| {
                    std.log.warn(
                        "Invalid float value '{s}' for --tolerance: {}",
                        .{ val_str, err },
                    );
                }
            }
        }
    }

    // Spawn peng in headless mode
    var child = try std.process.spawn(init.io, .{
        .argv = &[_][]const u8{
            "./zig-out/bin/peng",
            "--headless",
            "--test-mode",
            "--ipc",
            "testfiles/images/000_0_1024x682.jpg",
        },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer {
        if (child.id != null) {
            child.kill(init.io);
        }
    }

    // Read socket path from stdout
    var read_buf: [4096]u8 = undefined;
    var stdout_file_reader = std.Io.File.Reader.init(child.stdout.?, init.io, &read_buf);
    const stdout_stream = &stdout_file_reader.interface;

    var socket_path_buf: [256]u8 = undefined;
    var socket_path: []const u8 = "";

    while (try stdout_stream.takeDelimiter('\n')) |line| {
        if (std.mem.indexOf(u8, line, "IPC socket: ")) |idx| {
            const raw_path = std.mem.trim(u8, line[idx + "IPC socket: ".len ..], " \t\r\n");
            if (raw_path.len <= socket_path_buf.len) {
                @memcpy(socket_path_buf[0..raw_path.len], raw_path);
                socket_path = socket_path_buf[0..raw_path.len];
            }
            break;
        }
    }

    if (socket_path.len == 0) {
        std.log.err("Failed to obtain IPC socket path from peng", .{});
        return error.SocketPathNotFound;
    }

    std.log.info("Test runner connected to IPC socket: {s}", .{socket_path});

    // Initialize SDL3 for image loading
    if (!sdl.init(0)) {
        std.log.err("SDL_Init failed", .{});
        return error.SDLInitFailed;
    }
    defer sdl.quit();

    const base_dir = "testfiles/golden-screenshots";
    const run_dir = "testfiles/current-run";

    // Recreate current-run dir
    if (std.Io.Dir.openDir(std.Io.Dir.cwd(), init.io, run_dir, .{ .iterate = true })) |dir| {
        var it = std.Io.Dir.iterate(dir);
        while (it.next(init.io) catch |err| blk: {
            std.log.warn("Iterating run dir failed: {}", .{err});
            break :blk null;
        }) |entry| {
            std.Io.Dir.deleteFile(dir, init.io, entry.name) catch |err| {
                std.log.warn("Deleting old file '{s}' failed: {}", .{ entry.name, err });
            };
        }
        std.Io.Dir.close(dir, init.io);
    } else |err| {
        std.log.warn("Could not open existing run dir '{s}': {}", .{ run_dir, err });
    }
    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), init.io, base_dir) catch |err| {
        std.log.err("Failed to create base dir '{s}': {}", .{ base_dir, err });
    };
    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), init.io, run_dir) catch |err| {
        std.log.err("Failed to create run dir '{s}': {}", .{ run_dir, err });
    };

    const Harness = struct {
        allocator: std.mem.Allocator,
        sock: []const u8,
        base: []const u8,
        run: []const u8,
        update: bool,
        tolerance: f64,

        fn verify(self: @This(), run_name: []const u8, baseline_name: []const u8) !bool {
            return captureAndVerify(
                self.allocator,
                self.sock,
                self.base,
                self.run,
                run_name,
                baseline_name,
                self.update,
                self.tolerance,
            );
        }
    };
    const harness: Harness = .{
        .allocator = gpa,
        .sock = socket_path,
        .base = base_dir,
        .run = run_dir,
        .update = update_baselines,
        .tolerance = max_tolerance_pct,
    };

    var steps_with_discrepancies: usize = 0;

    // Initial Render
    {
        try sendCommand(socket_path, "wait_load");
        if (try harness.verify("init.png", "init.png")) {
            steps_with_discrepancies += 1;
        }
    }

    // Zoom & Pan
    {
        try sendCommand(socket_path, "zoom 2.0");
        try sendCommand(socket_path, "pan 50 -30");
        if (try harness.verify("zoom_pan.png", "zoom_pan.png")) {
            steps_with_discrepancies += 1;
        }
    }

    // Adjustments
    {
        try sendCommand(socket_path, "reset_view");
        try sendCommand(socket_path, "adjust 0.3 1.4");
        if (try harness.verify("adjust.png", "adjust.png")) {
            steps_with_discrepancies += 1;
        }
    }

    // Scaling Filters (Standard / Fit-to-Window)
    {
        try sendCommand(socket_path, "reset_adjustments");
        try sendCommand(socket_path, "filter mitchell");
        if (try harness.verify("filter_mitchell.png", "filter_mitchell.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "filter lanczos3");
        if (try harness.verify("filter_lanczos3.png", "filter_lanczos3.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "filter linear");
    }

    // Magnified Resampling & Neural Upscaling Filters (> 100% Zoom)
    // Exercises shaders gated behind is_magnified (FSR 1.0, Tiny CNN, Pixel Art, Lanczos3)
    {
        try sendCommand(socket_path, "zoom 2.5");
        try sendCommand(socket_path, "pan 100 -50");

        try sendCommand(socket_path, "filter lanczos3");
        if (try harness.verify("filter_lanczos3_zoom.png", "filter_lanczos3_zoom.png")) {
            steps_with_discrepancies += 1;
        }

        try sendCommand(socket_path, "filter fsr");
        if (try harness.verify("filter_fsr_zoom.png", "filter_fsr_zoom.png")) {
            steps_with_discrepancies += 1;
        }

        try sendCommand(socket_path, "filter tiny_cnn");
        if (try harness.verify("filter_tiny_cnn_zoom.png", "filter_tiny_cnn_zoom.png")) {
            steps_with_discrepancies += 1;
        }

        try sendCommand(socket_path, "filter pixel_art");
        if (try harness.verify("filter_pixel_art_zoom.png", "filter_pixel_art_zoom.png")) {
            steps_with_discrepancies += 1;
        }

        try sendCommand(socket_path, "reset_view");
        try sendCommand(socket_path, "filter linear");
    }

    // Scale / Fit Modes
    {
        try sendCommand(socket_path, "scale crop");
        if (try harness.verify("scale_crop.png", "scale_crop.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "scale none");
        if (try harness.verify("scale_original.png", "scale_original.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "scale full");
    }

    // Action Palette
    {
        try sendCommand(socket_path, "palette action");
        if (try harness.verify("palette_action.png", "palette_action.png")) {
            steps_with_discrepancies += 1;
        }
    }

    // Action Palette Search ("filterh")
    {
        try sendCommand(socket_path, "palette action filterh");
        if (try harness.verify("palette_action_search.png", "palette_action_search.png")) {
            steps_with_discrepancies += 1;
        }
    }

    // Files Palette
    {
        try sendCommand(socket_path, "palette files");
        if (try harness.verify("palette_files.png", "palette_files.png")) {
            steps_with_discrepancies += 1;
        }
    }

    // Slideshow Palette
    {
        try sendCommand(socket_path, "palette slideshow");
        if (try harness.verify("palette_slideshow.png", "palette_slideshow.png")) {
            steps_with_discrepancies += 1;
        }
    }

    // Navigation (Next & Prev)
    {
        try sendCommand(socket_path, "palette none");
        try sendCommand(socket_path, "next");
        try sendCommand(socket_path, "wait_load");
        if (try harness.verify("next_image.png", "next_image.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "prev");
        try sendCommand(socket_path, "wait_load");
        if (try harness.verify("prev_image.png", "init.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "next");
        try sendCommand(socket_path, "wait_load");
    }

    // Debug Tools
    {
        try sendCommand(socket_path, "palette none");
        try sendCommand(socket_path, "debug true");
        if (try harness.verify("debug_tools.png", "debug_tools.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "debug false");
    }

    // Title Overlay
    {
        try sendCommand(socket_path, "title");
        if (try harness.verify("title_toggle_on.png", "title_overlay_on.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "title toggle");
        if (try harness.verify("title_toggle_off.png", "title_overlay_off.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "title true");
        if (try harness.verify("title_explicit_on.png", "title_overlay_on.png")) {
            steps_with_discrepancies += 1;
        }
        try sendCommand(socket_path, "title false");
        if (try harness.verify("title_explicit_off.png", "title_overlay_off.png")) {
            steps_with_discrepancies += 1;
        }
    }

    // Snackbar Overlay Tests
    {
        // 1. Explicitly enable snackbar notifications in test mode (triggers .testing rule -> "Test Notification")
        try sendCommand(socket_path, "snackbar true");
        if (try harness.verify("snackbar_centered.png", "snackbar_centered.png")) {
            steps_with_discrepancies += 1;
        }

        // 2. Turn title ON -> Side-by-side Test (Title on left, Snackbar on right, group centered)
        try sendCommand(socket_path, "title true");
        if (try harness.verify("snackbar_with_title.png", "snackbar_with_title.png")) {
            steps_with_discrepancies += 1;
        }

        // 3. Dismissal & Settlement Test
        try sendCommand(socket_path, "snackbar false");
        try sendCommand(socket_path, "title false");
        if (try harness.verify("snackbar_dismissed.png", "title_overlay_off.png")) {
            steps_with_discrepancies += 1;
        }
    }

    // Windowless / Borderless IPC Tests
    {
        try sendCommand(socket_path, "windowless true");
        try sendCommand(socket_path, "windowless false");
        try sendCommand(socket_path, "windowless");
        try sendCommand(socket_path, "borderless toggle");
        try sendCommand(socket_path, "borderless on");
        try sendCommand(socket_path, "borderless off");
    }

    // Safety Validation Tests
    {
        try expectCommandFailure(socket_path, "zoom nan");
        try expectCommandFailure(socket_path, "zoom inf");
        try expectCommandFailure(socket_path, "zoom -inf");
        try expectCommandFailure(socket_path, "pan nan 1.0");
        try expectCommandFailure(socket_path, "pan 1.0 inf");
        try expectCommandFailure(socket_path, "adjust nan 1.0");
        try expectCommandFailure(socket_path, "title invalid");
        try expectCommandFailure(socket_path, "snackbar invalid");
        try expectCommandFailure(socket_path, "windowless invalid");
        try expectCommandFailure(socket_path, "borderless invalid");
        try expectCommandFailure(socket_path, "filter invalid");
        try expectCommandFailure(socket_path, "scale invalid");
        try expectCommandFailure(socket_path, "manga invalid");
        try expectCommandFailure(socket_path, "palette invalid");
        try expectCommandFailure(socket_path, "thumb invalid");

        // Generate a 513-character screenshot path
        var long_path_buf: [520]u8 = undefined;
        @memset(&long_path_buf, 'a');
        const long_cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{long_path_buf[0..513]});
        defer gpa.free(long_cmd);
        try expectCommandFailure(socket_path, long_cmd);
    }

    // Quit
    try sendCommand(socket_path, "quit");

    _ = try child.wait(init.io);
    child.id = null;

    if (steps_with_discrepancies > 0) {
        std.log.err(
            "Visual integration tests completed all steps with {d} step(s) " ++
                "containing visual discrepancies (diff PNGs saved to {s}).",
            .{ steps_with_discrepancies, run_dir },
        );
        return error.VisualRegressionMismatch;
    }

    std.log.info("All visual integration tests completed successfully!", .{});
}
