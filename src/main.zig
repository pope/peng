const builtin = @import("builtin");
const std = @import("std");
const clay = @import("zclay");
const ui = @import("ui");
const app_config = @import("config");
const app = @import("app");
const ipc = @import("ipc");
const input = @import("input");
const intents = @import("intents");
const sdl = @import("sdl");
const state_pkg = @import("state");
const build_options = @import("build_options");
const viewer = @import("viewer");

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
    load_assets: *const fn () callconv(.c) void,
    unload_assets: *const fn () callconv(.c) void,
    update: *const fn (
        app_state: *app.state.AppState,
        window: sdl.Window,
        resources: *ui.graphics.GpuResources,
        measure_data: *state_pkg.types.MeasureTextUserData,
        ipc_server: ?*ipc.IpcServer,
        parsed_headless: bool,
        parsed_test_mode: bool,
        frame_arena: *std.heap.ArenaAllocator,
        last_time: *u64,
    ) anyerror!void,

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
        const cwd = std.Io.Dir.cwd();
        self.handle.close();
        cwd.deleteFile(io, lib_temp_name) catch {};
    }

    fn check_outdated(self: *LibViewer, io: std.Io) !bool {
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.openFile(io, lib_name, .{});
        defer f.close(io);
        const stat = try f.stat(io);

        return stat.mtime.nanoseconds != self.last_mod_time.nanoseconds;
    }

    fn updateLib(self: *LibViewer, io: std.Io, app_state: *app.state.AppState) !void {
        _ = app_state;
        if (self.is_valid) {
            self.unload_assets();
            self.handle.close();
            self.is_valid = false;
        }

        const new_viewer = try LibViewer.init(io);
        self.* = new_viewer;
        self.load_assets();
    }

    fn safeReload(self: *LibViewer, io: std.Io, app_state: *app.state.AppState) void {
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
    state: app.state.AppState,
    clay_memory: []u8,
    clay_context: *clay.Context,
    measure_data: state_pkg.types.MeasureTextUserData,
    ipc_server: ?*ipc.IpcServer,

    pub fn deinit(self: *AppGraphicsAndState) void {
        self.parsed.deinit(self.gpa);
        if (self.ipc_server) |srv| srv.deinit(self.io);
        self.gpa.free(self.clay_memory);
        self.state.deinit();
        self.resources.deinit(self.gpa);
        sdl.quitTtf();
        self.setup.gpu_device.destroy();
        self.setup.window.destroy();
        sdl.quit();
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
    var state = app.state.AppState{
        .viewer = .{
            .navigation = try state_pkg.NavigationState.init(gpa),
            .ui = try state_pkg.UiState.init(gpa),
            .display = if (parsed.headless) .headless else .{
                .windowed = .{
                    .handle = setup.window,
                    .pixel_format = sdl.PixelFormat.rgba32,
                    .is_fullscreen = false,
                    .claimed = true,
                },
            },
            .viewport = .{ .fit_mode = parsed.default_scale },
            .rotation_map = .init(gpa),
            .running = true,
        },
        .gpu_device = setup.gpu_device,
        .unpack_compute_pipeline = resources.unpack_compute_pipeline,
        .cache = .{},
        .allocator = gpa,
        .io = init.io,
    };
    try state.ensureInitialCapacities();
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
    ctx.measure_data = state_pkg.types.MeasureTextUserData{
        .fonts = ctx.resources.fonts[0..],
        .allocator = ctx.gpa,
    };
    clay.setMeasureTextFunction(*const state_pkg.types.MeasureTextUserData, &ctx.measure_data, ui.graphics.sdl3MeasureText);

    // Initialize IPC server and spawn IPC worker task
    if (ctx.parsed.ipc_enabled) {
        ctx.ipc_server = try ipc.IpcServer.init(ctx.gpa);
        errdefer {
            ctx.ipc_server.?.deinit(ctx.io);
            ctx.ipc_server = null;
        }
        try app.workers.spawnIpcServer(&ctx.state);
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

    if (build_options.hot_reload) {
        var lib_viewer: LibViewer = try .init(ctx.io);
        defer lib_viewer.deinit(ctx.io) catch {};

        lib_viewer.load_assets();
        defer lib_viewer.unload_assets();

        while (ctx.state.viewer.running) {
            defer _ = frame_arena.reset(.retain_capacity);
            clay.setCurrentContext(ctx.clay_context);
            lib_viewer.safeReload(ctx.io, &ctx.state);
            if (lib_viewer.is_valid) {
                try lib_viewer.update(
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
    } else {
        try viewer.loadAssets();
        defer viewer.unloadAssets();

        while (ctx.state.viewer.running) {
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

test {
    _ = app;
    _ = ui;
    _ = state_pkg;
    _ = sdl;
    _ = viewer;
    _ = ipc;
    _ = input;
    _ = intents;
}
