const builtin = @import("builtin");
const std = @import("std");
const clay = @import("zclay");
const ui = @import("ui");
const app_config = @import("config");
const app = @import("app");
const sdl = @import("sdl");

const LibViewer = struct {
    const lib_name = switch (builtin.target.os.tag) {
        .macos => "zig-out/lib/libviewer.dylib",
        .linux => "zig-out/lib/libviewer.so",
        else => @panic("unsupported for hot reloading"),
    };
    const lib_temp_name = switch (builtin.target.os.tag) {
        .macos => "zig-out/lib/libviewer-temp.dylib",
        .linux => "zig-out/lib/libviewer-temp.so",
        else => @panic("unsupported for hot reloading"),
    };

    handle: std.DynLib,
    last_mod_time: std.Io.Timestamp,
    is_valid: bool = true,
    load_assets: *const fn (*app.state.ViewerState) callconv(.c) void,
    unload_assets: *const fn (*app.state.ViewerState) callconv(.c) void,
    update: *const fn (
        app_state: *app.state.ViewerState,
        window_ptr: *anyopaque,
        resources_ptr: *anyopaque,
        measure_data_ptr: *anyopaque,
        ipc_server_ptr: ?*anyopaque,
        parsed_headless: bool,
        parsed_test_mode: bool,
        frame_arena_ptr: *anyopaque,
        last_time_ptr: *u64,
    ) callconv(.c) void,

    fn init(io: std.Io) !LibViewer {
        const cwd = std.Io.Dir.cwd();

        const f = try cwd.openFile(io, lib_name, .{});
        defer f.close(io);
        const stat = try f.stat(io);

        try std.Io.Dir.copyFile(
            cwd,
            lib_name,
            cwd,
            lib_temp_name,
            io,
            .{},
        );

        var handle = try std.DynLib.open(lib_temp_name);

        return .{
            .handle = handle,
            .last_mod_time = stat.mtime,
            .is_valid = true,
            .load_assets = handle.lookup(
                @FieldType(LibViewer, "load_assets"),
                "viewer_load_assets",
            ) orelse return error.SymbolNotFound,
            .unload_assets = handle.lookup(
                @FieldType(LibViewer, "unload_assets"),
                "viewer_unload_assets",
            ) orelse return error.SymbolNotFound,
            .update = handle.lookup(
                @FieldType(LibViewer, "update"),
                "viewer_update",
            ) orelse return error.SymbolNotFound,
        };
    }

    fn deinit(self: *LibViewer, io: std.Io) !void {
        if (self.is_valid) {
            self.handle.close();
            self.is_valid = false;
        }
        try std.Io.Dir.cwd().deleteFile(io, lib_temp_name);
    }

    fn check_outdated(self: LibViewer, io: std.Io) !bool {
        const f = try std.Io.Dir.cwd().openFile(io, lib_name, .{});
        defer f.close(io);
        const stat = try f.stat(io);
        return self.last_mod_time.nanoseconds < stat.mtime.nanoseconds;
    }

    fn updateLib(self: *LibViewer, io: std.Io, app_state: *app.state.ViewerState) !void {
        // Drain active threads before unloading dynamic library
        _ = app_state.generation.fetchAdd(1, .monotonic);
        while (app_state.active_threads.load(.acquire) > 0) {
            sdl.timer.delay(1); // 1ms
            _ = app_state.processBackgroundEvents();
        }

        if (self.is_valid) {
            self.unload_assets(app_state);
            self.handle.close();
            self.is_valid = false;
        }

        const new_viewer = try LibViewer.init(io);
        self.* = new_viewer;
        self.load_assets(app_state);
    }

    fn safeReload(self: *LibViewer, io: std.Io, app_state: *app.state.ViewerState) void {
        const is_outdated = self.check_outdated(io) catch |err| {
            std.log.err("Unable to check reload of viewer lib: {}", .{err});
            return;
        };

        if (is_outdated or !self.is_valid) {
            if (self.updateLib(io, app_state)) {
                std.log.info("Viewer dynamic library reloaded successfully!", .{});
            } else |err| {
                std.log.err("Unable to reload viewer lib: {}", .{err});
            }
        }
    }
};

/// Application context encapsulating initialized graphics, state, resources, and IPC server.
pub const AppGraphicsAndState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    parsed: app_config.cli.ParsedArgs,
    setup: ui.graphics.GraphicsSetup,
    resources: ui.graphics.GpuResources,
    state: app.state.ViewerState,
    clay_memory: []u8,
    clay_context: *clay.Context,
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
        .viewport = .{ .scale_mode = parsed.default_scale },
        .adjustments = .{},
        .rotation_map = .init(gpa),
        .running = true,
    };
    own_gpu_resources = false;
    errdefer state.deinit();

    // 5. Initialize Clay UI Layout Engine
    const clay_memory_size = clay.minMemorySize();
    const clay_memory = try gpa.alloc(u8, clay_memory_size);
    errdefer gpa.free(clay_memory);

    const clay_arena = clay.Arena.init(clay_memory);
    const clay_ctx = clay.initialize(clay_arena, .{
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
        .clay_context = clay_ctx,
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

    var last_time = sdl.timer.getTicks();

    const build_options = @import("build_options");
    if (build_options.hot_reload) {
        var lib_viewer: LibViewer = try .init(ctx.io);
        defer lib_viewer.deinit(ctx.io) catch {};

        lib_viewer.load_assets(&ctx.state);
        defer lib_viewer.unload_assets(&ctx.state);

        while (ctx.state.running) {
            defer _ = frame_arena.reset(.retain_capacity);
            clay.setCurrentContext(ctx.clay_context);
            lib_viewer.safeReload(ctx.io, &ctx.state);
            if (lib_viewer.is_valid) {
                lib_viewer.update(
                    &ctx.state,
                    ctx.setup.window.ptr,
                    &ctx.resources,
                    &ctx.measure_data,
                    ctx.ipc_server,
                    ctx.parsed.headless,
                    ctx.parsed.test_mode,
                    &frame_arena,
                    &last_time,
                );
            }
        }
    } else {
        const viewer = @import("viewer");

        try viewer.loadAssets(&ctx.state);
        defer viewer.unloadAssets(&ctx.state);

        while (ctx.state.running) {
            defer _ = frame_arena.reset(.retain_capacity);
            try viewer.updateFrame(
                &ctx.state,
                ctx.setup.window,
                &ctx.resources,
                &ctx.measure_data,
                ctx.ipc_server,
                ctx.parsed.headless,
                ctx.parsed.test_mode,
                &frame_arena,
                &last_time,
            );
        }
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
