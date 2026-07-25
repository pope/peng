const std = @import("std");
const clay = @import("zclay");
const ui = @import("ui.zig");
const commands = @import("commands.zig");
const app_config = @import("config.zig");
const app = @import("app.zig");
const sdl = @import("sdl");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Phase 1: Parse command line arguments
    const parsed = try app_config.cli.parseCommandLineArgs(init, gpa);
    defer if (parsed.arg_path) |p| gpa.free(p);

    // Phase 2: Graphics and Window Setup
    const setup = try ui.graphics.initGraphicsAndWindow("Peng Image Viewer", .{
        .headless = parsed.headless,
        .high_dpi = !parsed.test_mode,
    });
    defer {
        sdl.quitTtf();
        setup.gpu_device.destroy();
        setup.window.destroy();
        sdl.quit();
    }

    // Phase 3: GPU Pipeline and Resources Setup
    const resources = try ui.graphics.initGpuResources(setup.gpu_device, setup.window, setup.initial_dpi_scale, parsed.headless);
    var own_resources = true;
    defer {
        if (own_resources) {
            const dev = setup.gpu_device;
            dev.releasePipeline(resources.pipeline);
            dev.releaseSampler(resources.sampler);
            dev.releaseTexture(resources.white_texture);
        }
        for (resources.fonts) |f| {
            if (f) |font| font.close();
        }
    }

    // Phase 4: State Initialization
    var state = app.state.ViewerState{
        .gpu_device = setup.gpu_device,
        .gpu_pipeline = resources.pipeline,
        .gpu_sampler = resources.sampler,
        .white_texture = resources.white_texture,

        .directory_arena = std.heap.ArenaAllocator.init(gpa),
        .image_list = std.ArrayList([]const u8).empty,
        .image_list_mutex = .init,
        .cache = .{},
        .cache_mutex = .init,
        .allocator = gpa,
        .io = init.io,
        .window_pixel_format = sdl.PixelFormat.rgba32,
        .palette = app.state.PaletteState.init(gpa),
        .text_cache = .{},
        .scale_mode = parsed.default_scale,
        .rotation_angle = 0.0,
        .rotation_map = std.StringHashMap(f32).init(gpa),
        .brightness = 0.0,
        .contrast = 1.0,
        .adjustments_dirty = false,
        .window = setup.window,
        .is_fullscreen = false,
        .running = true,
        .show_stats_overlay = false,
        .window_claimed = !parsed.headless,
    };
    defer state.deinit();
    own_resources = false;

    // Populate initial image list from arguments and piped stdin
    if (parsed.arg_path) |path| {
        try state.handlePathSelection(path);
    }
    try app.fs.readPipedStdin(&state, init.io, gpa);

    // Initialize Clay UI Layout Engine
    const clay_memory_size = clay.minMemorySize();
    const clay_memory = try gpa.alloc(u8, clay_memory_size);
    defer gpa.free(clay_memory);
    const clay_arena = clay.Arena.init(clay_memory);
    _ = clay.initialize(clay_arena, .{
        .w = @as(f32, @floatFromInt(1024)),
        .h = @as(f32, @floatFromInt(768)),
    }, .{});

    var measure_data = app.types.MeasureTextUserData{
        .fonts = resources.fonts[0..],
        .allocator = gpa,
    };
    clay.setMeasureTextFunction(*const app.types.MeasureTextUserData, &measure_data, ui.graphics.sdl3MeasureText);

    // Per-frame arena allocator
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();

    var last_time = sdl.timer.getTicks();

    // Phase 5: Initialize IPC Server
    const ipc = app.ipc;
    var ipc_server: ?*ipc.IpcServer = null;
    if (parsed.ipc_enabled) {
        const IpcServer = ipc.IpcServer;
        ipc_server = try IpcServer.init(gpa, &state);
    }
    defer if (ipc_server) |srv| srv.deinit(init.io);

    // Phase 6: The Main Loop
    while (state.running) {
        const bg_events_processed = state.processBackgroundEvents();

        // Phase 6a: Input Accumulation
        _ = frame_arena.reset(.retain_capacity);
        const is_current_loading = blk: {
            if (state.getCurrentEntry()) |entry| {
                break :blk (entry.status == .decoding or entry.status == .uploading);
            }
            break :blk (state.current_index != null);
        };
        const is_busy = state.is_loading_files.load(.acquire) or (state.active_threads.load(.acquire) > 0) or is_current_loading or bg_events_processed;
        const input = try app.input.pollFrameInput(
            setup.window,
            frame_allocator,
            &last_time,
            state.mouse_inside,
            state.palette.mode != .inactive,
            parsed.test_mode or parsed.headless,
            is_busy,
        );

        if (input.quit_requested) {
            state.running = false;
        }
        state.mouse_inside = input.mouse_inside;

        // Process any pending IPC commands collected during event processing
        state.processIpcCommands(ipc_server);

        // Phase 6b: State Update
        const needs_cache_update = blk: {
            if (state.getCurrentEntry()) |entry| {
                switch (entry.status) {
                    .decoding => |d| break :blk !d.has_thread,
                    else => break :blk false,
                }
            }
            break :blk (state.current_index != null);
        };
        if (needs_cache_update and state.active_decode_threads.load(.acquire) < app.state.ViewerState.getMaxConcurrentDecodes()) {
            state.lockImageList();
            const count = state.image_list.items.len;
            state.unlockImageList();
            if (count > 0) {
                if (state.current_index == null) state.current_index = 0;
                state.updateCache() catch |err| std.log.err("Failed to update cache: {}", .{err});
            }
        }

        try state.update(input);

        clay.setLayoutDimensions(.{ .w = input.pix_w, .h = input.pix_h });

        if (input.mouse_inside) {
            clay.setPointerState(
                .{ .x = input.mouse_x, .y = input.mouse_y },
                input.mouse_left_down,
            );
        } else {
            clay.setPointerState(
                .{ .x = -1.0, .y = -1.0 },
                false,
            );
        }

        clay.updateScrollContainers(
            true,
            .{ .x = input.scroll_delta_x, .y = input.scroll_delta_y },
            input.delta_time_ms / 1000.0,
        );

        state.checkIdlePreload();

        if (input.mouse_left_clicked) {
            if (state.show_stats_overlay and clay.pointerOver(clay.getElementId("StatsCloseBtn"))) {
                state.show_stats_overlay = false;
            }
        }

        // Phase 6c: Draw / Render
        const capture_filename = if (state.active_screenshot) |s| s.path else null;
        ui.layout.renderFrame(&state, input, frame_allocator, resources.fonts[0..], &measure_data, capture_filename) catch |err| {
            state.handleScreenshotPostRender(err);
            return err;
        };
        state.handleScreenshotPostRender(null);
    }
}

test "ElementTag.fromInt" {
    std.testing.refAllDecls(app.state);
    std.testing.refAllDecls(app.input);
    std.testing.refAllDecls(app.image);
    std.testing.refAllDecls(app.fs);
}
