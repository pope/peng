const std = @import("std");
const sdl = @import("sdl");

pub const CompareResult = struct {
    mismatched_pixels: u32,
    pct: f64,
};

fn compareScreenshots(base_path: [:0]const u8, run_path: [:0]const u8, diff_path: [:0]const u8, max_tolerance_pct: f64) !CompareResult {
    const raw_base_surf = sdl.Surface.loadFile(base_path) catch {
        std.log.err("Failed to load baseline screenshot: {s}. Run with --update-baselines to create it.", .{base_path});
        return error.BaselineMissing;
    };
    defer raw_base_surf.destroy();

    const raw_run_surf = sdl.Surface.loadFile(run_path) catch {
        std.log.err("Failed to load run screenshot: {s}", .{run_path});
        return error.RunScreenshotMissing;
    };
    defer raw_run_surf.destroy();

    if (raw_base_surf.w() != raw_run_surf.w() or raw_base_surf.h() != raw_run_surf.h()) {
        std.log.err("Dimension mismatch: baseline is {d}x{d}, run is {d}x{d}", .{ raw_base_surf.w(), raw_base_surf.h(), raw_run_surf.w(), raw_run_surf.h() });
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

    const diff_surf = sdl.Surface.create(@intCast(width), @intCast(height), sdl.PixelFormat.rgba32) orelse {
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
                pixels_diff[idx_diff] = 0xFF0000FF;
            } else {
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

        if (!diff_surf.savePng(diff_path)) {
            std.log.err("Failed to save diff image", .{});
        } else {
            std.log.info("Diff image saved to: {s}", .{diff_path});
        }

        if (pct > max_tolerance_pct) {
            std.log.err("Major visual regression found: {d} pixels differ ({d:.3}% > max tolerance {d:.1}%)", .{ mismatched_pixels, pct, max_tolerance_pct });
        } else {
            std.log.warn("Visual discrepancy found: {d} pixels differ ({d:.3}% <= tolerance {d:.1}%)", .{ mismatched_pixels, pct, max_tolerance_pct });
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
        std.log.err("IPC Command '{s}' was expected to fail, but succeeded with: {s}", .{ command, trimmed });
        return error.IpcCommandSucceededUnexpectedly;
    }
}

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
                \\  --update-baselines   Update golden baseline screenshots with output from current run
                \\  --tolerance <pct>    Set max allowed pixel difference percentage per step (default: 2.0%)
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
                } else |_| {}
            }
        }
    }

    // Spawn peng in headless mode
    var child = try std.process.spawn(init.io, .{
        .argv = &[_][]const u8{
            "./zig-out/bin/peng",
            "--headless",
            "--test-mode",
            "testfiles/images/000_0_1024x682.jpg",
        },
        .stdout = .pipe,
    });
    defer {
        if (child.id != null) {
            child.kill(init.io);
            _ = child.wait(init.io) catch {};
            child.id = null;
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
        while (it.next(init.io) catch null) |entry| {
            std.Io.Dir.deleteFile(dir, init.io, entry.name) catch {};
        }
        std.Io.Dir.close(dir, init.io);
    } else |_| {}
    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), init.io, base_dir) catch {};
    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), init.io, run_dir) catch {};

    var steps_with_discrepancies: usize = 0;

    // 0. Initial Render
    {
        try sendCommand(socket_path, "wait_load");
        const capture_path = try std.fmt.allocPrint(gpa, "{s}/test_0_init.png", .{if (update_baselines) base_dir else run_dir});
        defer gpa.free(capture_path);
        const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{capture_path});
        defer gpa.free(cmd);
        try sendCommand(socket_path, cmd);
        if (!update_baselines) {
            const res = try compareScreenshots(
                base_dir ++ "/test_0_init.png",
                run_dir ++ "/test_0_init.png",
                run_dir ++ "/diff_test_0_init.png",
                max_tolerance_pct,
            );
            if (res.pct > max_tolerance_pct) steps_with_discrepancies += 1;
        }
    }

    // 1. Zoom
    {
        try sendCommand(socket_path, "zoom 2.0");
        try sendCommand(socket_path, "pan 50 -30");
        const capture_path = try std.fmt.allocPrint(gpa, "{s}/test_1_zoom.png", .{if (update_baselines) base_dir else run_dir});
        defer gpa.free(capture_path);
        const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{capture_path});
        defer gpa.free(cmd);
        try sendCommand(socket_path, cmd);
        if (!update_baselines) {
            const res = try compareScreenshots(
                base_dir ++ "/test_1_zoom.png",
                run_dir ++ "/test_1_zoom.png",
                run_dir ++ "/diff_test_1_zoom.png",
                max_tolerance_pct,
            );
            if (res.pct > max_tolerance_pct) steps_with_discrepancies += 1;
        }
    }

    // 2. Adjust
    {
        try sendCommand(socket_path, "zoom 1.0");
        try sendCommand(socket_path, "pan 0 0");
        try sendCommand(socket_path, "adjust 0.3 1.4");
        const capture_path = try std.fmt.allocPrint(gpa, "{s}/test_2_adjust.png", .{if (update_baselines) base_dir else run_dir});
        defer gpa.free(capture_path);
        const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{capture_path});
        defer gpa.free(cmd);
        try sendCommand(socket_path, cmd);
        if (!update_baselines) {
            const res = try compareScreenshots(
                base_dir ++ "/test_2_adjust.png",
                run_dir ++ "/test_2_adjust.png",
                run_dir ++ "/diff_test_2_adjust.png",
                max_tolerance_pct,
            );
            if (res.pct > max_tolerance_pct) steps_with_discrepancies += 1;
        }
    }

    // 3. Filter
    {
        try sendCommand(socket_path, "adjust 0 1");
        try sendCommand(socket_path, "filter mitchell");
        const capture_path = try std.fmt.allocPrint(gpa, "{s}/test_3_filter.png", .{if (update_baselines) base_dir else run_dir});
        defer gpa.free(capture_path);
        const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{capture_path});
        defer gpa.free(cmd);
        try sendCommand(socket_path, cmd);
        if (!update_baselines) {
            const res = try compareScreenshots(
                base_dir ++ "/test_3_filter.png",
                run_dir ++ "/test_3_filter.png",
                run_dir ++ "/diff_test_3_filter.png",
                max_tolerance_pct,
            );
            if (res.pct > max_tolerance_pct) steps_with_discrepancies += 1;
        }
    }

    // 4. Action Palette
    {
        try sendCommand(socket_path, "filter linear");
        try sendCommand(socket_path, "palette action");
        const capture_path = try std.fmt.allocPrint(gpa, "{s}/test_4_action_palette.png", .{if (update_baselines) base_dir else run_dir});
        defer gpa.free(capture_path);
        const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{capture_path});
        defer gpa.free(cmd);
        try sendCommand(socket_path, cmd);
        if (!update_baselines) {
            const res = try compareScreenshots(
                base_dir ++ "/test_4_action_palette.png",
                run_dir ++ "/test_4_action_palette.png",
                run_dir ++ "/diff_test_4_action_palette.png",
                max_tolerance_pct,
            );
            if (res.pct > max_tolerance_pct) steps_with_discrepancies += 1;
        }
    }

    // 5. Files Palette
    {
        try sendCommand(socket_path, "palette files");
        const capture_path = try std.fmt.allocPrint(gpa, "{s}/test_5_files_palette.png", .{if (update_baselines) base_dir else run_dir});
        defer gpa.free(capture_path);
        const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{capture_path});
        defer gpa.free(cmd);
        try sendCommand(socket_path, cmd);
        if (!update_baselines) {
            const res = try compareScreenshots(
                base_dir ++ "/test_5_files_palette.png",
                run_dir ++ "/test_5_files_palette.png",
                run_dir ++ "/diff_test_5_files_palette.png",
                max_tolerance_pct,
            );
            if (res.pct > max_tolerance_pct) steps_with_discrepancies += 1;
        }
    }

    // 6. Next Image
    {
        try sendCommand(socket_path, "palette none");
        try sendCommand(socket_path, "next");
        try sendCommand(socket_path, "wait_load");
        const capture_path = try std.fmt.allocPrint(gpa, "{s}/test_6_next_image.png", .{if (update_baselines) base_dir else run_dir});
        defer gpa.free(capture_path);
        const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{capture_path});
        defer gpa.free(cmd);
        try sendCommand(socket_path, cmd);
        if (!update_baselines) {
            const res = try compareScreenshots(
                base_dir ++ "/test_6_next_image.png",
                run_dir ++ "/test_6_next_image.png",
                run_dir ++ "/diff_test_6_next_image.png",
                max_tolerance_pct,
            );
            if (res.pct > max_tolerance_pct) steps_with_discrepancies += 1;
        }
    }

    // 7. Debug Tools
    {
        try sendCommand(socket_path, "palette none");
        try sendCommand(socket_path, "debug true");
        const capture_path = try std.fmt.allocPrint(gpa, "{s}/test_7_debug_tools.png", .{if (update_baselines) base_dir else run_dir});
        defer gpa.free(capture_path);
        const cmd = try std.fmt.allocPrint(gpa, "screenshot {s}", .{capture_path});
        defer gpa.free(cmd);
        try sendCommand(socket_path, cmd);
        if (!update_baselines) {
            const res = try compareScreenshots(
                base_dir ++ "/test_7_debug_tools.png",
                run_dir ++ "/test_7_debug_tools.png",
                run_dir ++ "/diff_test_7_debug_tools.png",
                max_tolerance_pct,
            );
            if (res.pct > max_tolerance_pct) steps_with_discrepancies += 1;
        }
    }

    // 8. Safety Validation Tests
    {
        try expectCommandFailure(socket_path, "zoom nan");
        try expectCommandFailure(socket_path, "zoom inf");
        try expectCommandFailure(socket_path, "zoom -inf");
        try expectCommandFailure(socket_path, "pan nan 1.0");
        try expectCommandFailure(socket_path, "pan 1.0 inf");
        try expectCommandFailure(socket_path, "adjust nan 1.0");
        try expectCommandFailure(socket_path, "adjust 1.0 -inf");

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
        std.log.err("Visual integration tests completed all steps with {d} step(s) containing visual discrepancies (diff PNGs saved to {s}).", .{ steps_with_discrepancies, run_dir });
        return error.VisualRegressionMismatch;
    }

    std.log.info("All visual integration tests completed successfully!", .{});
}
