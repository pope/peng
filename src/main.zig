const app = @import("app");
const app_config = @import("config");
const build_options = @import("build_options");
const builtin = @import("builtin");
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
        resources: ?*gpu.graphics.RenderResources,
        measure_data: *ui.text_utils.MeasureTextUserData,
        sw_presenter: ?*sdl.SoftwarePresenter,
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

/// Asynchronous background GPU device initialization context for
/// software-first startup. Runs `SDL_CreateGPUDevice` off the main thread
/// while the main thread presents Frame 0 via `sdl.SoftwarePresenter`.
const AsyncGpuInit = struct {
    ready: std.atomic.Value(bool) = .init(false),
    device: ?sdl.gpu.Device = null,
    create_ms: f64 = 0.0,
    thread: ?std.Thread = null,
    debug_mode: bool = false,
    io: std.Io = undefined,

    fn start(self: *AsyncGpuInit, io: std.Io, debug_mode: bool) !void {
        self.io = io;
        self.debug_mode = debug_mode;
        self.ready.store(false, .release);
        self.device = null;
        self.create_ms = 0.0;
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    fn worker(self: *AsyncGpuInit) void {
        const t0 = std.Io.Clock.awake.now(self.io);
        const shader_flags =
            sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl;
        self.device = sdl.gpu.Device.createWithOptions(
            shader_flags,
            self.debug_mode,
            true,
        );
        if (self.device == null) {
            std.log.err(
                "Async SDL_CreateGPUDevice Error: {s}",
                .{sdl.getError()},
            );
        }
        self.create_ms = state_pkg.durationToMs(
            t0.untilNow(self.io, .awake),
        );
        self.ready.store(true, .release);
        _ = sdl.events.pushUserEvent();
    }

    fn deinitUnclaimed(self: *AsyncGpuInit) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.device) |dev| {
            dev.destroy();
            self.device = null;
        }
    }
};

/// Lightweight startup latency profiler enabled via `--profile-startup`.
/// Modeled as a tagged union so timestamps and milestone flags only exist when
/// profiling is active.
const StartupProfiler = union(enum) {
    disabled,
    active: struct {
        t_start: std.Io.Timestamp,
        logged_sw_image: bool = false,
        logged_gpu_frame: bool = false,
    },

    fn init(enabled: bool, t_start: std.Io.Timestamp) StartupProfiler {
        return if (enabled)
            .{ .active = .{ .t_start = t_start } }
        else
            .disabled;
    }

    fn log(self: StartupProfiler, io: std.Io, label: []const u8) void {
        switch (self) {
            .disabled => {},
            .active => |a| {
                const elapsed = state_pkg.durationToMs(
                    a.t_start.untilNow(io, .awake),
                );
                std.log.info("[startup] {s}: {d:.1} ms", .{ label, elapsed });
            },
        }
    }

    fn logDur(
        self: StartupProfiler,
        io: std.Io,
        label: []const u8,
        dur_ms: f64,
    ) void {
        switch (self) {
            .disabled => {},
            .active => |a| {
                const elapsed = state_pkg.durationToMs(
                    a.t_start.untilNow(io, .awake),
                );
                std.log.info(
                    "[startup] {s}: {d:.1} ms (at t={d:.1} ms)",
                    .{ label, dur_ms, elapsed },
                );
            },
        }
    }
};

/// Exclusive graphics lifecycle state: either software-first boot while
/// `SDL_CreateGPUDevice` runs asynchronously, or active GPU rendering with
/// initialized `RenderResources`.
const GraphicsBackend = union(enum) {
    software_boot: struct {
        presenter: sdl.SoftwarePresenter,
        async_gpu: AsyncGpuInit,
    },
    gpu_ready: struct {
        device: sdl.gpu.Device,
        resources: gpu.graphics.RenderResources,
    },

    fn deinit(
        self: *GraphicsBackend,
        gpa: std.mem.Allocator,
        window: sdl.Window,
    ) void {
        switch (self.*) {
            .software_boot => |*boot| {
                boot.async_gpu.deinitUnclaimed();
                boot.presenter.deinit(window);
            },
            .gpu_ready => |*ready| {
                ready.resources.deinit(gpa);
                ready.device.destroy();
            },
        }
    }
};

/// Application context encapsulating initialized graphics, state, resources,
/// and IPC server.
const AppGraphicsAndState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    parsed: app_config.cli.ParsedArgs,
    window: sdl.Window,
    initial_dpi_scale: f32,
    backend: GraphicsBackend,
    profiler: StartupProfiler,
    state: app.state.AppState,
    measure_data: ui.text_utils.MeasureTextUserData,
    ipc_server: ?*ipc.IpcServer,

    /// Releases all application resources, closes IPC server, tears down
    /// SDL/GPU graphics, and frees state memory.
    pub fn deinit(self: *AppGraphicsAndState) void {
        self.parsed.deinit(self.gpa);
        self.state.workers.exiting.store(true, .release);
        if (self.ipc_server) |srv| srv.deinit(self.io);
        switch (self.backend) {
            .software_boot => |*boot| boot.async_gpu.deinitUnclaimed(),
            .gpu_ready => {},
        }
        self.state.deinit();
        self.backend.deinit(self.gpa, self.window);
        self.window.destroy();
        gpu.graphics.quitSdlCore();
    }

    /// Completes the handoff from software-first presentation to SDL GPU
    /// once the background `SDL_CreateGPUDevice` thread finishes.
    fn tryCompleteAsyncGpuInit(self: *AppGraphicsAndState) !bool {
        const boot = switch (self.backend) {
            .gpu_ready => return false,
            .software_boot => |*b| b,
        };
        if (!boot.async_gpu.ready.load(.acquire)) return false;

        if (boot.async_gpu.thread) |t| {
            t.join();
            boot.async_gpu.thread = null;
        }
        self.profiler.logDur(
            self.io,
            "gpu_device_bg_create",
            boot.async_gpu.create_ms,
        );
        const dev = boot.async_gpu.device orelse {
            std.log.err("Async SDL_CreateGPUDevice failed", .{});
            return error.DeviceCreationFailed;
        };
        boot.async_gpu.device = null;
        errdefer dev.destroy();

        const handoff_t0 = std.Io.Clock.awake.now(self.io);
        boot.presenter.deinit(self.window);
        if (!self.window.claimForGpu(dev)) {
            std.log.err(
                "SDL_ClaimWindowForGPUDevice failed: {s}",
                .{sdl.getError()},
            );
            return error.ClaimWindowFailed;
        }
        errdefer self.window.releaseFromGpu(dev);

        const res = try gpu.graphics.initGpuResources(
            self.io,
            dev,
            self.window,
            self.initial_dpi_scale,
            self.parsed.headless,
        );
        self.backend = .{
            .gpu_ready = .{
                .device = dev,
                .resources = res,
            },
        };
        self.state.gpu_device = dev;
        self.state.unpack_compute_pipeline =
            self.backend.gpu_ready.resources.unpack_compute_pipeline.get();
        self.measure_data = .{
            .measurer = self.backend.gpu_ready.resources.fontMeasurer(),
        };
        self.profiler.logDur(
            self.io,
            "gpu_handoff_claim_and_res",
            state_pkg.durationToMs(handoff_t0.untilNow(self.io, .awake)),
        );
        // Wake the event loop so the first GPU frame renders immediately even
        // when there is no pending image upload (e.g. empty/text-only view).
        _ = sdl.events.pushUserEvent();
        return true;
    }

    /// Phase 1: Initializes CLI options, SDL graphics, viewer state, early
    /// background workers, and window/GPU resources in-place.
    ///
    /// In-place initialization ensures `self.state` is pinned at its final
    /// memory address before `openPath` / `readPipedStdin` spawns background
    /// worker tasks that hold pointers to `self.state.workers`,
    /// `self.state.cache.generation`, and `self.state.viewer.navigation.active_file_scans`.
    pub fn init(self: *AppGraphicsAndState, proc_init: std.process.Init) !bool {
        const gpa = proc_init.gpa;
        const t_start = std.Io.Clock.awake.now(proc_init.io);

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
        const profiler = StartupProfiler.init(parsed.profile_startup, t_start);

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
        profiler.log(proc_init.io, "sdl_core_init");

        // 3. Pinned In-Place State Initialization & Early Path Scan / Decode Launch
        const start_hidden = parsed.server_mode and parsed.arg_path == null;
        const defaults = state_pkg.ViewerDefaults{
            .default_scale = parsed.default_scale,
            .enable_blur = parsed.enable_blur,
            .show_title = parsed.show_title,
            .auto_title = !parsed.test_mode,
            .snackbar_enabled = !parsed.test_mode,
            .crossfade = !parsed.test_mode,
            .stack_raw_jpeg = parsed.stack_raw_jpeg,
            .windowless = parsed.windowless,
        };
        self.gpa = gpa;
        self.io = proc_init.io;
        self.parsed = parsed;
        self.profiler = profiler;
        self.measure_data = .{ .measurer = .empty };
        self.ipc_server = null;
        self.state = app.state.AppState{
            .viewer = viewer_blk: {
                var nav = try state_pkg.NavigationState.init(gpa);
                errdefer nav.deinit(gpa);
                const ui_state = try state_pkg.UiState.init(gpa);
                break :viewer_blk .{
                    .defaults = defaults,
                    .navigation = nav,
                    .ui = ui_state,
                    .animations = .{},
                    .rotation_map = .empty,
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
        self.state.viewer.resetToDefaults();
        errdefer self.state.deinit();
        try self.state.ensureInitialCapacities();
        self.state.initThumbCache(
            proc_init.environ_map,
            if (parsed.test_mode) .off else parsed.thumb_cache,
        );

        // Spawn initial directory scan & decode worker before window/GPU setup
        // to overlap CPU file I/O & decode with Wayland/Vulkan initialization.
        if (self.parsed.arg_path) |path| {
            try self.state.openPath(
                path,
                state_pkg.timestampToMs(std.Io.Clock.awake.now(proc_init.io)),
            );
        } else if (!self.parsed.server_mode) {
            try app.workers.readPipedStdin(
                &self.state.workers,
                &self.state.viewer.navigation.active_file_scans,
                proc_init.io,
                gpa,
            );
        }
        self.profiler.log(proc_init.io, "open_path_spawned");

        // 4. Create Window Immediately
        const win_setup = try gpu.graphics.createWindowOnly(
            "Peng Image Viewer",
            .{
                .headless = parsed.headless,
                .hidden = start_hidden,
                .high_dpi = !parsed.test_mode,
                .borderless = parsed.windowless,
            },
        );
        errdefer win_setup.window.destroy();
        self.window = win_setup.window;
        self.initial_dpi_scale = win_setup.initial_dpi_scale;
        if (!parsed.headless) {
            self.state.display.backendPtr().* = .{
                .windowed = .{
                    .handle = self.window,
                    .pixel_format = sdl.PixelFormat.rgba32,
                    .is_fullscreen = false,
                    .is_borderless = parsed.windowless,
                },
            };
        }
        self.profiler.log(proc_init.io, "window_created");

        // 5. Async GPU creation for interactive windowed launches;
        //    synchronous GPU init for headless, test-mode, and hidden server.
        const use_async_gpu = !parsed.headless and
            !parsed.test_mode and
            !start_hidden;
        if (use_async_gpu) {
            self.backend = .{
                .software_boot = .{
                    .presenter = sdl.SoftwarePresenter.init(self.window),
                    .async_gpu = .{},
                },
            };
            errdefer self.backend.software_boot.presenter.deinit(self.window);
            try self.backend.software_boot.async_gpu.start(
                proc_init.io,
                builtin.mode == .debug,
            );
            self.profiler.log(proc_init.io, "async_gpu_spawned");
            return true;
        }

        const shader_flags =
            sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl;
        const dev = sdl.gpu.Device.create(
            shader_flags,
            builtin.mode == .debug,
        ) orelse {
            std.log.err("SDL_CreateGPUDevice Error: {s}", .{sdl.getError()});
            return error.DeviceCreationFailed;
        };
        errdefer dev.destroy();

        if (!parsed.headless) {
            if (!self.window.claimForGpu(dev)) {
                std.log.err(
                    "SDL_ClaimWindowForGPUDevice failed: {s}",
                    .{sdl.getError()},
                );
                return error.ClaimWindowFailed;
            }
        }
        errdefer if (!parsed.headless) self.window.releaseFromGpu(dev);

        const res = try gpu.graphics.initGpuResources(
            proc_init.io,
            dev,
            self.window,
            self.initial_dpi_scale,
            parsed.headless,
        );
        self.backend = .{
            .gpu_ready = .{
                .device = dev,
                .resources = res,
            },
        };
        self.state.gpu_device = dev;
        self.state.unpack_compute_pipeline =
            self.backend.gpu_ready.resources.unpack_compute_pipeline.get();
        self.measure_data = .{
            .measurer = self.backend.gpu_ready.resources.fontMeasurer(),
        };
        self.profiler.log(proc_init.io, "sync_gpu_ready");

        return true;
    }
};

/// Handles SDL quit, window close, and window visibility events in the
/// hot-reload fallback loop.
fn handleFallbackHotReloadEvent(
    state: *app.state.AppState,
    event: sdl.Event,
) void {
    switch (event.type) {
        sdl.event_type.quit => state.viewer.running = false,
        sdl.event_type.window_close_requested => {
            if (state.viewer.server_mode) {
                state.hideWindow();
            } else {
                state.viewer.running = false;
            }
        },
        sdl.event_type.window_minimized => state.display.setMinimized(true),
        sdl.event_type.window_restored,
        sdl.event_type.window_maximized,
        sdl.event_type.window_enter_fullscreen,
        => state.display.setMinimized(false),
        sdl.event_type.window_shown => {
            state.display.setMinimized(false);
            state.display.setOccluded(false);
        },
        sdl.event_type.window_occluded => state.display.setOccluded(true),
        sdl.event_type.window_exposed => state.display.setOccluded(false),
        else => {},
    }
}

/// Phase 2: Runs the main application event processing, state updating,
/// and rendering loop.
fn runMainLoop(ctx: *AppGraphicsAndState) !void {
    switch (ctx.backend) {
        .gpu_ready => |*ready| {
            ctx.measure_data = ui.text_utils.MeasureTextUserData{
                .measurer = ready.resources.fontMeasurer(),
            };
        },
        .software_boot => {},
    }

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

    var last_time = state_pkg.timestampToMs(std.Io.Clock.awake.now(ctx.io));

    if (build_options.hot_reload) {
        var lib_viewer: LibViewer = try .init(ctx.io);
        defer lib_viewer.deinit(ctx.io);

        lib_viewer.load_assets();

        while (ctx.state.viewer.running) {
            defer _ = frame_arena.reset(.retain_capacity);
            _ = try ctx.tryCompleteAsyncGpuInit();
            lib_viewer.safeReload(ctx.io);
            if (lib_viewer.is_valid) {
                const res_ptr: ?*gpu.graphics.RenderResources =
                    switch (ctx.backend) {
                        .gpu_ready => |*r| &r.resources,
                        .software_boot => null,
                    };
                const sw_ptr: ?*sdl.SoftwarePresenter = switch (ctx.backend) {
                    .software_boot => |*b| &b.presenter,
                    .gpu_ready => null,
                };
                lib_viewer.update(
                    &ctx.state,
                    ctx.window,
                    res_ptr,
                    &ctx.measure_data,
                    sw_ptr,
                    ctx.parsed.headless,
                    ctx.parsed.test_mode,
                    &frame_arena,
                    &last_time,
                );
            } else {
                if (sdl.events.consumeTerminateSignal()) {
                    ctx.state.viewer.running = false;
                } else {
                    var event: sdl.Event = undefined;
                    if (sdl.events.waitEventTimeout(&event, 100)) {
                        handleFallbackHotReloadEvent(&ctx.state, event);
                        while (sdl.events.pollEvent(&event)) {
                            handleFallbackHotReloadEvent(&ctx.state, event);
                        }
                    }
                    if (sdl.events.consumeTerminateSignal()) {
                        ctx.state.viewer.running = false;
                    }
                }
            }
        }
    } else {
        try viewer.loadAssets();
        defer viewer.unloadAssets();

        while (ctx.state.viewer.running) {
            defer _ = frame_arena.reset(.retain_capacity);
            _ = try ctx.tryCompleteAsyncGpuInit();
            const res_ptr: ?*gpu.graphics.RenderResources =
                switch (ctx.backend) {
                    .gpu_ready => |*r| &r.resources,
                    .software_boot => null,
                };
            const sw_ptr: ?*sdl.SoftwarePresenter = switch (ctx.backend) {
                .software_boot => |*b| &b.presenter,
                .gpu_ready => null,
            };
            try viewer.updateFrame(
                &ctx.state,
                ctx.window,
                res_ptr,
                &ctx.measure_data,
                sw_ptr,
                ctx.parsed.headless,
                ctx.parsed.test_mode,
                &frame_arena,
                &last_time,
            );
            switch (ctx.profiler) {
                .disabled => {},
                .active => |*prof| {
                    switch (ctx.backend) {
                        .software_boot => |*boot| {
                            if (!prof.logged_sw_image and
                                boot.presenter.hasPresented())
                            {
                                const has_img =
                                    if (ctx.state.getCurrentEntry()) |e|
                                        e.resident.asset == .loaded_cpu or
                                            e.resident.thumbnail == .staged_cpu
                                    else
                                        false;
                                if (has_img) {
                                    prof.logged_sw_image = true;
                                    const elapsed = state_pkg.durationToMs(
                                        prof.t_start.untilNow(ctx.io, .awake),
                                    );
                                    std.log.info(
                                        "[startup] first_sw_image_present: " ++
                                            "{d:.1} ms (wl_shm={})",
                                        .{
                                            elapsed,
                                            boot.presenter.isWaylandShm(),
                                        },
                                    );
                                }
                            }
                        },
                        .gpu_ready => |*ready| {
                            if (!prof.logged_gpu_frame and
                                ready.resources.frame_index > 0)
                            {
                                prof.logged_gpu_frame = true;
                                ctx.profiler.log(
                                    ctx.io,
                                    "first_gpu_frame_present",
                                );
                            }
                        },
                    }
                },
            }
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

test "hot-reload LibViewer init" {
    if (!build_options.hot_reload) return error.SkipZigTest;

    const io = std.testing.io;
    var lib_viewer: LibViewer = try .init(io);
    defer lib_viewer.deinit(io);

    try std.testing.expect(lib_viewer.is_valid);
    lib_viewer.load_assets();
    try std.testing.expect(!try lib_viewer.check_outdated(io));
}
