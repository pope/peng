const app = @import("app");
const app_config = @import("config");
const build_options = @import("build_options");
const builtin = @import("builtin");
const clay = @import("zclay");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const ui = @import("ui");
const viewer = if (!build_options.hot_reload) @import("viewer") else struct {};

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
        resources: *ui.graphics.RenderResources,
        measure_data: *state_pkg.MeasureTextUserData,
        parsed_headless: bool,
        parsed_test_mode: bool,
        frame_arena: *std.heap.ArenaAllocator,
        last_time: *u64,
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
        errdefer handle.close();

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

    fn deinit(self: *LibViewer, io: std.Io) void {
        const cwd = std.Io.Dir.cwd();
        if (self.is_valid) {
            self.unload_assets();
            self.handle.close();
            self.is_valid = false;
        }
        cwd.deleteFile(io, lib_temp_name) catch |err| {
            std.log.warn(
                "Failed to delete temp library {s}: {}",
                .{ lib_temp_name, err },
            );
        };
    }

    fn check_outdated(self: *LibViewer, io: std.Io) !bool {
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.openFile(io, lib_name, .{});
        defer f.close(io);
        const stat = try f.stat(io);

        return stat.mtime.nanoseconds != self.last_mod_time.nanoseconds;
    }

    fn updateLib(self: *LibViewer, io: std.Io) !void {
        if (self.is_valid) {
            self.unload_assets();
            self.handle.close();
            self.is_valid = false;
        }

        const new_viewer = try LibViewer.init(io);
        self.* = new_viewer;
        self.load_assets();
    }

    fn safeReload(self: *LibViewer, io: std.Io) void {
        const is_outdated = self.check_outdated(io) catch |err| {
            std.log.err("Unable to check reload of viewer lib: {}", .{err});
            return;
        };

        if (is_outdated or !self.is_valid) {
            if (self.updateLib(io)) {
                std.log.info("Viewer dynamic library reloaded successfully!", .{});
            } else |err| {
                std.log.err("Unable to reload viewer lib: {}", .{err});
            }
        }
    }
};

/// Application context encapsulating initialized graphics, state, resources, and IPC server.
const AppGraphicsAndState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    parsed: app_config.cli.ParsedArgs,
    setup: ui.graphics.GraphicsSetup,
    resources: ui.graphics.RenderResources,
    state: app.state.AppState,
    clay_memory: []u8,
    clay_context: *clay.Context,
    measure_data: state_pkg.MeasureTextUserData,
    ipc_server: ?*ipc.IpcServer,

    /// Releases all application resources, closes IPC server, tears down
    /// SDL/GPU graphics, and frees state memory.
    pub fn deinit(self: *AppGraphicsAndState) void {
        self.parsed.deinit(self.gpa);
        self.state.workers.exiting.store(true, .release);
        if (self.ipc_server) |srv| srv.deinit(self.io);
        self.gpa.free(self.clay_memory);
        self.state.deinit();
        self.resources.deinit(self.gpa);
        self.setup.gpu_device.destroy();
        self.setup.window.destroy();
        ui.graphics.quitSdlCore();
    }
};

/// Phase 1: Initializes CLI options, SDL graphics, GPU resources, viewer
/// state, Clay layout engine, and IPC server.
fn initAppGraphicsAndState(init: std.process.Init) !?AppGraphicsAndState {
    const gpa = init.gpa;

    // 1. Parse command line arguments
    var parsed = try app_config.cli.parseCommandLineArgs(init, gpa);
    errdefer parsed.deinit(gpa);

    if (parsed.help) {
        parsed.deinit(gpa);
        app_config.cli.printHelp(init.io);
        return null;
    }

    // 2. Initialize SDL Core Subsystems (video, events, TTF)
    // Must be initialized before background workers touch SDL surface/event APIs.
    try ui.graphics.initSdlCore(parsed.headless);
    errdefer ui.graphics.quitSdlCore();

    // 3. State Initialization & Early Path Scan / Decode Launch
    var state = app.state.AppState{
        .viewer = .{
            .navigation = try state_pkg.NavigationState.init(gpa),
            .ui = try state_pkg.UiState.init(gpa),
            .animations = .{},
            .display = if (parsed.headless) .headless else .{
                .windowed = .{
                    .handle = undefined,
                    .pixel_format = sdl.PixelFormat.rgba32,
                    .is_fullscreen = false,
                    .is_borderless = parsed.windowless,
                    .claimed = false,
                },
            },
            .viewport = blk: {
                var vp = state_pkg.ViewportParams{
                    .fit_mode = parsed.default_scale,
                };
                vp.reset();
                break :blk vp;
            },
            .rotation_map = .init(gpa),
            .running = true,
        },
        .gpu_device = null,
        .gpu_enabled = true,
        .unpack_compute_pipeline = null,
        .cache = .{},
        .workers = .init(),
        .allocator = gpa,
        .io = init.io,
    };
    state.viewer.ui.overlays.enable_blur = parsed.enable_blur;
    state.viewer.ui.overlays.title_display = if (parsed.show_title) .pinned else .hidden;
    state.viewer.ui.overlays.auto_title = !parsed.test_mode;
    state.viewer.ui.snackbar.enabled = !parsed.test_mode;
    state.viewer.navigation.crossfade = !parsed.test_mode;
    state.viewer.navigation.stack_raw_jpeg = parsed.stack_raw_jpeg;
    if (parsed.show_title) {
        state.viewer.animations.setImmediate(.title_overlay, 1.0);
    }
    errdefer state.deinit();
    try state.ensureInitialCapacities();

    // Spawn initial directory scan & decode worker before graphics/GPU initialization
    // to overlap CPU file I/O & decode with Wayland display and Vulkan device setup.
    if (parsed.arg_path) |path| {
        try state.openPath(path);
    } else {
        try app.workers.readPipedStdin(
            &state.workers,
            &state.viewer.navigation.active_file_scans,
            init.io,
            gpa,
        );
    }

    // 4. Graphics and Window Setup
    const setup = try ui.graphics.initGraphicsAndWindow("Peng Image Viewer", .{
        .headless = parsed.headless,
        .high_dpi = !parsed.test_mode,
        .borderless = parsed.windowless,
    });
    errdefer {
        setup.gpu_device.destroy();
        setup.window.destroy();
    }

    // 5. GPU Pipeline and Resources Setup
    var resources = try ui.graphics.initGpuResources(
        setup.gpu_device,
        setup.window,
        setup.initial_dpi_scale,
        parsed.headless,
    );
    errdefer resources.deinit(gpa);

    // 6. Initialize Clay UI Layout Engine
    const clay_memory_size = clay.minMemorySize();
    const clay_memory = try gpa.alloc(u8, clay_memory_size);
    errdefer gpa.free(clay_memory);

    const clay_arena = clay.Arena.init(clay_memory);
    const clay_ctx = clay.initialize(clay_arena, .{
        .w = @as(f32, @floatFromInt(1024)),
        .h = @as(f32, @floatFromInt(768)),
    }, .{});

    // 7. Bind graphics device and window handle to state
    state.gpu_device = setup.gpu_device;
    state.unpack_compute_pipeline = resources.unpack_compute_pipeline;
    if (!parsed.headless) {
        state.viewer.display.windowed.handle = setup.window;
        state.viewer.display.windowed.claimed = true;
    }

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
fn runMainLoop(ctx: *AppGraphicsAndState) !void {
    // Configure Clay measure text function with a stable pointer to measure_data
    ctx.measure_data = state_pkg.MeasureTextUserData{
        .fonts = ctx.resources.fonts[0..],
        .allocator = ctx.gpa,
    };
    clay.setMeasureTextFunction(
        *const state_pkg.MeasureTextUserData,
        &ctx.measure_data,
        ui.graphics.sdl3MeasureText,
    );

    // Initialize IPC server and spawn IPC worker task
    if (ctx.parsed.ipc_enabled) {
        const srv = try ipc.IpcServer.init(ctx.gpa);
        ctx.ipc_server = srv;
        errdefer {
            ctx.state.workers.exiting.store(true, .release);
            srv.deinit(ctx.io);
            ctx.ipc_server = null;
        }
        srv.thread = try app.workers.spawnIpcServer(
            &ctx.state.workers,
            ctx.gpa,
            ctx.io,
        );
    }

    // Per-frame arena allocator
    var frame_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer frame_arena.deinit();

    var last_time = sdl.timer.getTicks();

    if (build_options.hot_reload) {
        var lib_viewer: LibViewer = try .init(ctx.io);
        defer lib_viewer.deinit(ctx.io);

        lib_viewer.load_assets();

        while (ctx.state.viewer.running) {
            defer _ = frame_arena.reset(.retain_capacity);
            clay.setCurrentContext(ctx.clay_context);
            lib_viewer.safeReload(ctx.io);
            if (lib_viewer.is_valid) {
                lib_viewer.update(
                    &ctx.state,
                    ctx.setup.window,
                    &ctx.resources,
                    &ctx.measure_data,
                    ctx.parsed.headless,
                    ctx.parsed.test_mode,
                    &frame_arena,
                    &last_time,
                );
            } else {
                var event: sdl.Event = undefined;
                if (sdl.events.waitEventTimeout(&event, 100)) {
                    if (event.type == sdl.event_type.quit) {
                        ctx.state.viewer.running = false;
                    }
                    while (sdl.events.pollEvent(&event)) {
                        if (event.type == sdl.event_type.quit) {
                            ctx.state.viewer.running = false;
                        }
                    }
                }
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
                ctx.parsed.headless,
                ctx.parsed.test_mode,
                &frame_arena,
                &last_time,
            );
        }
    }
}

/// Writes tab-separated image classifications (PICK / REJECT) to standard output on exit.
fn exportClassificationsToStdout(nav: *const state_pkg.NavigationState, io: std.Io) void {
    if (nav.pick_count == 0 and nav.reject_count == 0) return;

    var stdout_write_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &stdout_write_buf);

    const slice = nav.items.slice();
    for (slice.items(.entry), slice.items(.classification)) |entry, c| {
        const prefix = c.exportPrefix() orelse continue;

        switch (entry) {
            .filesystem => |f| {
                _ = stdout_writer.interface.print("{s}\t{s}\n", .{ prefix, f.path }) catch return;
            },
            .archive_entry => |a| {
                _ = stdout_writer.interface.print("{s}\t{s}#{s}\n", .{ prefix, a.archive_path, a.entry_name }) catch return;
            },
            .pair => |p| {
                _ = stdout_writer.interface.print(
                    "{s}\t{s}\n",
                    .{ prefix, p.raw_path },
                ) catch return;
                _ = stdout_writer.interface.print(
                    "{s}\t{s}\n",
                    .{ prefix, p.jpeg_path },
                ) catch return;
            },
        }
    }
    _ = stdout_writer.interface.flush() catch {};
}

/// Application entry point: initializes state and graphics, enters the primary
/// event loop, and cleans up on exit.
pub fn main(init: std.process.Init) !void {
    var app_ctx = (try initAppGraphicsAndState(init)) orelse return;
    defer app_ctx.deinit();

    try runMainLoop(&app_ctx);

    if (!app_ctx.parsed.test_mode) {
        exportClassificationsToStdout(&app_ctx.state.viewer.navigation, app_ctx.io);
    }
}
