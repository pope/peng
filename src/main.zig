const app = @import("app");
const app_config = @import("config");
const build_options = @import("build_options");
const builtin = @import("builtin");
const clay = @import("zclay");
const core = @import("core");
const gpu = @import("gpu");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const thumbcache = @import("thumbcache");
const ui = @import("ui");
const viewer = if (!build_options.hot_reload) @import("viewer") else struct {};

const collectPrecacheFiles = thumbcache.collectPrecacheFiles;
const encodeBytesToThumbnailPng = core.thumbcache.encodeBytesToThumbnailPng;
const precachePathsParallel = thumbcache.precachePathsParallel;
const ThumbCacheConfig = thumbcache.ThumbCacheConfig;
const ThumbWritePolicy = thumbcache.ThumbWritePolicy;

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
        resources: *gpu.graphics.RenderResources,
        measure_data: *ui.text_utils.MeasureTextUserData,
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

/// Application context encapsulating initialized graphics, state, resources,
/// and IPC server.
const AppGraphicsAndState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    parsed: app_config.cli.ParsedArgs,
    setup: gpu.graphics.GraphicsSetup,
    resources: gpu.graphics.RenderResources,
    state: app.state.AppState,
    clay_memory: []u8,
    clay_context: *clay.Context,
    measure_data: ui.text_utils.MeasureTextUserData,
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
        gpu.graphics.quitSdlCore();
    }

    /// Phase 1: Initializes CLI options, SDL graphics, viewer state, early
    /// background workers, GPU resources, and Clay layout engine in-place.
    ///
    /// In-place initialization ensures `self.state` is pinned at its final
    /// memory address before `openPath` / `readPipedStdin` spawns background
    /// worker tasks that hold pointers to `self.state.workers`,
    /// `self.state.cache.generation`, and `self.state.viewer.navigation.active_file_scans`.
    pub fn init(self: *AppGraphicsAndState, proc_init: std.process.Init) !bool {
        const gpa = proc_init.gpa;

        // Pre-scan `process_environ` on both the global debug `Io.Threaded`
        // instance (used by `std.log` / `std.debug.lockStderr` and panic stack
        // trace symbolication) and the application `Io` instance before SDL3
        // initializes Wayland. Under Wayland compositors (e.g. KWin), SDL3
        // consumes `XDG_ACTIVATION_TOKEN` via `unsetenv`, which shifts `c_envp`
        // in-place and places a `null` entry inside the startup slice bounds
        // stored in `std.Io.Threaded`, triggering an `unwrapNull` panic and
        // mutex deadlock if `scanEnviron` runs lazily after SDL initialization.
        _ = std.Options.debug_io.vtable.progressParentFile(
            std.Options.debug_io.userdata,
        ) catch {};
        _ = proc_init.io.vtable.progressParentFile(
            proc_init.io.userdata,
        ) catch {};

        // 1. Parse command line arguments
        var parsed = try app_config.cli.parseCommandLineArgs(proc_init, gpa);
        errdefer parsed.deinit(gpa);

        if (parsed.help) {
            parsed.deinit(gpa);
            app_config.cli.printHelp(proc_init.io);
            return false;
        }

        if (parsed.precache) {
            try runCliPrecache(proc_init, &parsed);
            parsed.deinit(gpa);
            return false;
        }

        if (parsed.ipc_mode == .default_socket) {
            const resolved_sock = ipc.resolveDefaultSocketPath(
                gpa,
                proc_init.environ_map,
            ) catch |err| {
                std.log.err(
                    "Failed to resolve default IPC socket path ({any}): " ++
                        "set $XDG_RUNTIME_DIR, $UID, or pass --socket <PATH>",
                    .{err},
                );
                return err;
            };
            parsed.ipc_mode = .{ .custom_socket = resolved_sock };
        }

        // 2. Initialize SDL Core Subsystems (video, events, TTF)
        // Must be initialized before background workers touch SDL surface/event APIs.
        try gpu.graphics.initSdlCore(parsed.headless);
        errdefer gpu.graphics.quitSdlCore();

        // 3. Pinned In-Place State Initialization & Early Path Scan / Decode Launch
        const start_hidden = parsed.server_mode and parsed.arg_path == null;
        self.gpa = gpa;
        self.io = proc_init.io;
        self.parsed = parsed;
        self.measure_data = undefined;
        self.ipc_server = null;
        self.state = app.state.AppState{
            .viewer = viewer_blk: {
                var nav = try state_pkg.NavigationState.init(gpa);
                errdefer nav.deinit(gpa);
                const ui_state = try state_pkg.UiState.init(gpa);
                break :viewer_blk .{
                    .navigation = nav,
                    .ui = ui_state,
                    .animations = .{},
                    .viewport = vp_blk: {
                        var vp = state_pkg.ViewportParams{
                            .fit_mode = parsed.default_scale,
                        };
                        vp.reset();
                        break :vp_blk vp;
                    },
                    .rotation_map = .init(gpa),
                    .server_mode = parsed.server_mode,
                    .running = true,
                };
            },
            .display = if (start_hidden)
                .{ .hidden = .headless }
            else
                .{ .visible = .headless },
            .gpu_device = null,
            .gpu_enabled = true,
            .unpack_compute_pipeline = null,
            .cache = .{},
            .workers = .init(),
            .allocator = gpa,
            .io = proc_init.io,
        };
        self.state.viewer.ui.overlays.enable_blur = parsed.enable_blur;
        self.state.viewer.ui.overlays.title_display = if (parsed.show_title) .pinned else .hidden;
        self.state.viewer.ui.overlays.auto_title = !parsed.test_mode;
        self.state.viewer.ui.snackbar.enabled = !parsed.test_mode;
        self.state.viewer.navigation.crossfade = !parsed.test_mode;
        self.state.viewer.navigation.stack_raw_jpeg = parsed.stack_raw_jpeg;
        if (parsed.show_title) {
            self.state.viewer.animations.setImmediate(.title_overlay, 1.0);
        }
        errdefer self.state.deinit();
        try self.state.ensureInitialCapacities();
        self.state.initThumbCache(
            proc_init.environ_map,
            if (parsed.test_mode) .off else parsed.thumb_cache,
        );

        // Spawn initial directory scan & decode worker before graphics/GPU initialization
        // to overlap CPU file I/O & decode with Wayland display and Vulkan device setup.
        if (self.parsed.arg_path) |path| {
            try self.state.openPath(path);
        } else if (!self.parsed.server_mode) {
            try app.workers.readPipedStdin(
                &self.state.workers,
                &self.state.viewer.navigation.active_file_scans,
                proc_init.io,
                gpa,
            );
        }

        // 4. Graphics and Window Setup
        self.setup = try gpu.graphics.initGraphicsAndWindow(
            "Peng Image Viewer",
            .{
                .headless = parsed.headless,
                .hidden = start_hidden,
                .high_dpi = !parsed.test_mode,
                .borderless = parsed.windowless,
            },
        );
        errdefer {
            if (!parsed.headless) {
                self.setup.window.releaseFromGpu(self.setup.gpu_device);
            }
            self.setup.gpu_device.destroy();
            self.setup.window.destroy();
        }

        // 5. GPU Pipeline and Resources Setup
        self.resources = try gpu.graphics.initGpuResources(
            self.setup.gpu_device,
            self.setup.window,
            self.setup.initial_dpi_scale,
            parsed.headless,
        );
        errdefer self.resources.deinit(gpa);

        // 6. Initialize Clay UI Layout Engine
        const clay_memory_size = clay.minMemorySize();
        self.clay_memory = try gpa.alloc(u8, clay_memory_size);
        errdefer gpa.free(self.clay_memory);

        const clay_arena = clay.Arena.init(self.clay_memory);
        self.clay_context = clay.initialize(clay_arena, .{
            .w = @as(f32, @floatFromInt(1024)),
            .h = @as(f32, @floatFromInt(768)),
        }, .{});

        // 7. Bind graphics device and window handle to state
        self.state.gpu_device = self.setup.gpu_device;
        self.state.unpack_compute_pipeline = self.resources.unpack_compute_pipeline;
        if (!parsed.headless) {
            self.state.display.backendPtr().* = .{
                .windowed = .{
                    .handle = self.setup.window,
                    .pixel_format = sdl.PixelFormat.rgba32,
                    .is_fullscreen = false,
                    .is_borderless = parsed.windowless,
                },
            };
        }

        return true;
    }
};

/// Phase 2: Runs the main application event processing, state updating,
/// and rendering loop.
fn runMainLoop(ctx: *AppGraphicsAndState) !void {
    // Configure Clay measure text function with a stable pointer to measure_data
    ctx.measure_data = ui.text_utils.MeasureTextUserData{
        .fonts = ctx.resources.fonts[0..],
        .allocator = ctx.gpa,
    };
    clay.setMeasureTextFunction(
        *const ui.text_utils.MeasureTextUserData,
        &ctx.measure_data,
        ui.text_utils.sdl3MeasureText,
    );

    // Initialize IPC server and spawn IPC worker task
    if (ctx.parsed.ipc_mode.isEnabled()) {
        const srv = try ipc.IpcServer.init(
            ctx.gpa,
            ctx.parsed.ipc_mode.customPath(),
        );
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
            srv.socket_path,
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

/// Runs headless CLI thumbnail pre-caching (`peng --precache [path]`) across CPU cores
/// and prints a completion summary to standard output.
fn runCliPrecache(
    proc_init: std.process.Init,
    parsed: *const app_config.cli.ParsedArgs,
) !void {
    const gpa = proc_init.gpa;
    const io = proc_init.io;

    const policy: ThumbWritePolicy = switch (parsed.thumb_cache) {
        .missing => .missing_embedded_only,
        else => .all_missing,
    };
    var cfg = ThumbCacheConfig.initFromEnviron(
        gpa,
        proc_init.environ_map,
        policy,
    );
    defer cfg.deinit(gpa);

    const enabled_cfg = switch (cfg) {
        .enabled => |c| c,
        .disabled => {
            std.log.err(
                "Freedesktop thumbnail cache unavailable " ++
                    "(check HOME / XDG_CACHE_HOME)",
                .{},
            );
            return error.ThumbCacheDisabled;
        },
    };

    const target_path = parsed.arg_path orelse ".";
    var path_arena: std.heap.ArenaAllocator = .init(gpa);
    defer path_arena.deinit();
    const path_alloc = path_arena.allocator();

    var files: std.ArrayList([]const u8) = .empty;
    collectPrecacheFiles(
        path_alloc,
        io,
        target_path,
        parsed.recursive,
        &files,
    ) catch |err| {
        std.log.err(
            "Failed to collect files from '{s}': {s}",
            .{ target_path, @errorName(err) },
        );
        return err;
    };

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const max_workers = @max(@as(usize, 1), @min(@as(usize, 8), cpu_count));
    const stats = precachePathsParallel(
        gpa,
        io,
        enabled_cfg,
        files.items,
        max_workers,
        .{},
        encodeBytesToThumbnailPng,
    );

    var stdout_write_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(
        io,
        &stdout_write_buf,
    );
    _ = stdout_writer.interface.print(
        "Pre-cached {s}: {d} written, {d} already cached, {d} skipped, {d} failed ({d} total)\n",
        .{
            target_path,
            stats.written,
            stats.already_valid,
            stats.skipped,
            stats.failed,
            stats.total_files,
        },
    ) catch {};
    _ = stdout_writer.interface.flush() catch {};
}

/// Writes tab-separated image classifications (PICK / REJECT) to standard
/// output on exit.
fn exportClassificationsToStdout(
    nav: *const state_pkg.NavigationState,
    io: std.Io,
) void {
    if (!nav.triage.hasAnySelections()) return;

    var stdout_write_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.initStreaming(
        std.Io.File.stdout(),
        io,
        &stdout_write_buf,
    );

    nav.writeSelectionsTsv(&stdout_writer.interface) catch {};
    _ = stdout_writer.interface.flush() catch {};
}

/// Application entry point: initializes state and graphics, enters the primary
/// event loop, and cleans up on exit.
pub fn main(init: std.process.Init) !void {
    var app_ctx: AppGraphicsAndState = undefined;
    if (!try app_ctx.init(init)) return;
    defer app_ctx.deinit();

    try runMainLoop(&app_ctx);

    if (!app_ctx.parsed.test_mode) {
        exportClassificationsToStdout(&app_ctx.state.viewer.navigation, app_ctx.io);
    }
}
