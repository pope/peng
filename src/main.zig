const std = @import("std");
const clay = @import("zclay");
const ui = @import("ui.zig");
const commands = @import("commands.zig");
const app_config = @import("config.zig");
const app = @import("app.zig");
const sdl = @import("sdl");

/// Application context encapsulating initialized graphics, state, resources, and IPC server.
pub const AppGraphicsAndState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    parsed: app_config.cli.ParsedArgs,
    setup: ui.graphics.GraphicsSetup,
    resources: ui.graphics.GpuResources,
    state: app.state.ViewerState,
    clay_memory: []u8,
    measure_data: app.types.MeasureTextUserData,
    ipc_server: ?*app.ipc.IpcServer,

    pub fn deinit(self: *AppGraphicsAndState) void {
        if (self.ipc_server) |srv| srv.deinit(self.io);
        self.gpa.free(self.clay_memory);
        self.state.deinit();
        for (self.resources.fonts) |f| {
            if (f) |font| font.close();
        }
        sdl.quitTtf();
        self.setup.gpu_device.destroy();
        self.setup.window.destroy();
        sdl.quit();
        if (self.parsed.arg_path) |p| self.gpa.free(p);
    }
};

/// Phase 1: Initializes CLI options, SDL graphics, GPU resources, viewer state, Clay layout engine, and IPC server.
pub fn initAppGraphicsAndState(init: std.process.Init) !AppGraphicsAndState {
    const gpa = init.gpa;

    // 1. Parse command line arguments
    const parsed = try app_config.cli.parseCommandLineArgs(init, gpa);
    errdefer if (parsed.arg_path) |p| gpa.free(p);

    // 2. Graphics and Window Setup
    const setup = try ui.graphics.initGraphicsAndWindow("Peng Image Viewer", .{
        .headless = parsed.headless,
        .high_dpi = !parsed.test_mode,
    });
    errdefer {
        sdl.quitTtf();
        setup.gpu_device.destroy();
        setup.window.destroy();
        sdl.quit();
    }

    // 3. GPU Pipeline and Resources Setup
    const resources = try ui.graphics.initGpuResources(setup.gpu_device, setup.window, setup.initial_dpi_scale, parsed.headless);
    var own_gpu_resources = true;
    errdefer {
        if (own_gpu_resources) {
            const dev = setup.gpu_device;
            dev.releasePipeline(resources.pipeline);
            if (resources.unpack_compute_pipeline) |pipe| dev.releaseComputePipeline(pipe);
            dev.releaseSampler(resources.sampler);
            dev.releaseTexture(resources.white_texture);
        }
        for (resources.fonts) |f| {
            if (f) |font| font.close();
        }
    }

    // 4. State Initialization
    var state = app.state.ViewerState{
        .gpu = .{
            .device = setup.gpu_device,
            .pipeline = resources.pipeline,
            .unpack_compute_pipeline = resources.unpack_compute_pipeline,
            .sampler = resources.sampler,
            .white_texture = resources.white_texture,
        },

        .directory_arena = std.heap.ArenaAllocator.init(gpa),
        .image_list = .empty,
        .cache = .{},
        .allocator = gpa,
        .io = init.io,
        .display = if (parsed.headless) .headless else .{
            .windowed = .{
                .handle = setup.window,
                .pixel_format = sdl.PixelFormat.rgba32,
                .is_fullscreen = false,
                .claimed = true,
            },
        },
        .palette = app.state.PaletteState.init(gpa),
        .text_cache = .{},
        .scale_mode = parsed.default_scale,
        .rotation_angle = 0.0,
        .rotation_map = .init(gpa),
        .brightness = 0.0,
        .contrast = 1.0,
        .adjustments_dirty = false,
        .running = true,
        .show_stats_overlay = false,
    };
    own_gpu_resources = false;
    errdefer state.deinit();

    // 5. Initialize Clay UI Layout Engine
    const clay_memory_size = clay.minMemorySize();
    const clay_memory = try gpa.alloc(u8, clay_memory_size);
    errdefer gpa.free(clay_memory);

    const clay_arena = clay.Arena.init(clay_memory);
    _ = clay.initialize(clay_arena, .{
        .w = @as(f32, @floatFromInt(1024)),
        .h = @as(f32, @floatFromInt(768)),
    }, .{});

    return AppGraphicsAndState{
        .gpa = gpa,
        .io = init.io,
        .parsed = parsed,
        .setup = setup,
        .resources = resources,
        .state = state,
        .clay_memory = clay_memory,
        .measure_data = undefined,
        .ipc_server = null,
    };
}

/// Phase 2: Runs the main application event processing, state updating, and rendering loop.
pub fn runMainLoop(ctx: *AppGraphicsAndState) !void {
    // Configure Clay measure text function with a stable pointer to measure_data
    ctx.measure_data = app.types.MeasureTextUserData{
        .fonts = ctx.resources.fonts[0..],
        .allocator = ctx.gpa,
    };
    clay.setMeasureTextFunction(*const app.types.MeasureTextUserData, &ctx.measure_data, ui.graphics.sdl3MeasureText);

    // Initialize IPC server with a stable pointer to state
    if (ctx.parsed.ipc_enabled) {
        ctx.ipc_server = try app.ipc.IpcServer.init(ctx.gpa, &ctx.state);
    }

    // Populate initial image list from arguments and piped stdin using stable pointer to state
    if (ctx.parsed.arg_path) |path| {
        try ctx.state.handlePathSelection(path);
    }
    try app.fs.readPipedStdin(&ctx.state, ctx.io, ctx.gpa);

    // Per-frame arena allocator
    var frame_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();

    var last_time = sdl.timer.getTicks();

    while (ctx.state.running) {
        const bg_events_processed = ctx.state.processBackgroundEvents();

        // Input Accumulation
        _ = frame_arena.reset(.retain_capacity);
        const is_current_loading = blk: {
            if (ctx.state.getCurrentEntry()) |entry| {
                break :blk (entry.status == .decoding or entry.status == .uploading);
            }
            break :blk (ctx.state.current_index != null);
        };
        const is_busy = ctx.state.is_loading_files.load(.acquire) or (ctx.state.active_threads.load(.acquire) > 0) or is_current_loading or bg_events_processed or ctx.state.isSlideshowActive();
        const input = try app.input.pollFrameInput(
            ctx.setup.window,
            frame_allocator,
            &last_time,
            ctx.state.mouse_inside,
            ctx.state.palette.mode != .inactive,
            ctx.parsed.test_mode or ctx.parsed.headless,
            is_busy,
        );

        if (input.quit_requested) {
            ctx.state.running = false;
        }
        ctx.state.mouse_inside = input.mouse_inside;

        // Process any pending IPC commands collected during event processing
        ctx.state.processIpcCommands(ctx.ipc_server);

        // State Update
        const needs_cache_update = blk: {
            if (ctx.state.getCurrentEntry()) |entry| {
                switch (entry.status) {
                    .decoding => |d| break :blk !d.has_thread,
                    else => break :blk false,
                }
            }
            break :blk (ctx.state.current_index != null);
        };
        if (needs_cache_update and ctx.state.active_decode_threads.load(.acquire) < app.state.ViewerState.getMaxConcurrentDecodes()) {
            const count = ctx.state.image_list.items.len;
            if (count > 0) {
                if (ctx.state.current_index == null) ctx.state.current_index = 0;
                ctx.state.updateCache() catch |err| std.log.err("Failed to update cache: {}", .{err});
            }
        }

        try ctx.state.update(input);

        clay.setLayoutDimensions(.{ .w = input.win_w, .h = input.win_h });

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

        ctx.state.checkIdlePreload();

        if (input.mouse_left_clicked) {
            if (ctx.state.show_info_overlay and !ctx.state.isPointerInDebugPanel(input) and clay.pointerOver(clay.getElementId("InfoCloseBtn"))) {
                ctx.state.show_info_overlay = false;
            }
            if (ctx.state.show_stats_overlay and !ctx.state.isPointerInDebugPanel(input) and clay.pointerOver(clay.getElementId("StatsCloseBtn"))) {
                ctx.state.show_stats_overlay = false;
            }
        }

        // Draw / Render
        const capture_filename = switch (ctx.state.screenshot_mode) {
            .idle => null,
            .capturing => |s| s.path,
        };
        ui.layout.renderFrame(&ctx.state, input, frame_allocator, ctx.resources.fonts[0..], &ctx.measure_data, capture_filename) catch |err| {
            ctx.state.handleScreenshotPostRender(err);
            return err;
        };
        ctx.state.handleScreenshotPostRender(null);
    }
}

pub fn main(init: std.process.Init) !void {
    var app_ctx = try initAppGraphicsAndState(init);
    defer app_ctx.deinit();

    try runMainLoop(&app_ctx);
}

test "ElementTag.fromInt" {
    std.testing.refAllDecls(app.state);
    std.testing.refAllDecls(app.input);
    std.testing.refAllDecls(app.image);
    std.testing.refAllDecls(app.fs);
}
