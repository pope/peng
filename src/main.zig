const app = @import("app");
const app_config = @import("config");
const build_options = @import("build_options");
const builtin = @import("builtin");
const gpu = @import("gpu");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const thumbcache = @import("thumbcache");
const ui = @import("ui");
const viewer = if (!build_options.hot_reload) @import("viewer") else struct {};

const ThumbTier = thumbcache.ThumbTier;

const LibViewer = struct {
    const lib_ext = switch (builtin.target.os.tag) {
        .macos => "dylib",
        .linux => "so",
        else => @panic("unsupported for hot reloading"),
    };
    const lib_name = "zig-out/lib/libviewer." ++ lib_ext;

    handle: std.DynLib,
    last_mod_time: std.Io.Timestamp,
    is_valid: bool = true,
    generation: u64 = 0,
    temp_path_buf: [64]u8 = undefined,
    temp_path_len: usize = 0,
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

    fn tempPath(self: *const LibViewer) []const u8 {
        return self.temp_path_buf[0..self.temp_path_len];
    }

    fn deleteTempPath(io: std.Io, path: []const u8) void {
        if (path.len == 0) return;
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
            std.log.warn(
                "Failed to delete temp library {s}: {}",
                .{ path, err },
            );
        };
    }

    fn init(io: std.Io) !LibViewer {
        return initGeneration(io, 0);
    }

    fn initGeneration(io: std.Io, generation: u64) !LibViewer {
        const cwd = std.Io.Dir.cwd();

        const f = try cwd.openFile(io, lib_name, .{});
        defer f.close(io);
        const stat = try f.stat(io);

        var temp_path_buf: [64]u8 = undefined;
        const temp_path = std.mem.print(
            &temp_path_buf,
            "zig-out/lib/libviewer-temp-{d}.{s}",
            .{ generation, lib_ext },
        ) catch unreachable;

        cwd.deleteFile(io, temp_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn(
                "Failed to remove stale temp library {s}: {}",
                .{ temp_path, err },
            ),
        };
        try std.Io.Dir.copyFile(
            cwd,
            lib_name,
            cwd,
            temp_path,
            io,
            .{},
        );
        errdefer deleteTempPath(io, temp_path);

        var handle = try std.DynLib.open(temp_path);
        errdefer handle.close();

        return .{
            .handle = handle,
            .last_mod_time = stat.mtime,
            .is_valid = true,
            .generation = generation,
            .temp_path_buf = temp_path_buf,
            .temp_path_len = temp_path.len,
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
        if (self.is_valid) {
            self.unload_assets();
            self.handle.close();
            self.is_valid = false;
        }
        deleteTempPath(io, self.tempPath());
        self.temp_path_len = 0;
    }

    fn check_outdated(self: *LibViewer, io: std.Io) !bool {
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.openFile(io, lib_name, .{});
        defer f.close(io);
        const stat = try f.stat(io);

        return stat.mtime.nanoseconds != self.last_mod_time.nanoseconds;
    }

    fn updateLib(self: *LibViewer, io: std.Io) !void {
        self.deinit(io);

        const next_gen = self.generation + 1;
        self.generation = next_gen;
        const new_viewer = try LibViewer.initGeneration(io, next_gen);
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
            .{ .window = self.window },
            self.initial_dpi_scale,
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

        // Acquire the single-instance socket ownership lock before initializing
        // SDL/Vulkan so racing duplicate `--server` launches exit immediately
        // without touching a live socket. Skip locking for per-PID `--ipc`
        // sockets to avoid leaving stale `/tmp/peng-<pid>.sock.lock` files.
        var pre_ipc_server: ?*ipc.IpcServer = null;
        errdefer if (pre_ipc_server) |srv| srv.deinit(proc_init.io);
        if (parsed.ipc_mode.isEnabled()) {
            const srv = try ipc.IpcServer.init(
                gpa,
                parsed.ipc_mode.customPath(),
            );
            errdefer srv.deinit(proc_init.io);
            if (parsed.ipc_mode != .pid_socket) {
                var locked = try srv.tryAcquireLock(proc_init.io);
                if (!locked and parsed.server_mode) {
                    // If a previous server just unlinked the socket and is
                    // still finishing teardown before releasing `.lock`, wait
                    // briefly instead of exiting and stranding a respawner.
                    var n: usize = 0;
                    while (!locked and n < 20) : (n += 1) {
                        if (std.Io.Dir.statFile(
                            std.Io.Dir.cwd(),
                            proc_init.io,
                            srv.socket_path,
                            .{},
                        )) |_| {
                            break;
                        } else |_| {}
                        std.Io.sleep(
                            proc_init.io,
                            std.Io.Duration.fromMilliseconds(15),
                            .awake,
                        ) catch break;
                        locked = try srv.tryAcquireLock(proc_init.io);
                    }
                }
                if (!locked) {
                    if (parsed.server_mode) {
                        std.log.info(
                            "Another peng server already owns socket '{s}'; " ++
                                "exiting.",
                            .{srv.socket_path},
                        );
                        srv.deinit(proc_init.io);
                        parsed.deinit(gpa);
                        return false;
                    }
                    std.log.err(
                        "IPC socket '{s}' is already owned by another peng " ++
                            "process.",
                        .{srv.socket_path},
                    );
                    return error.AddressInUse;
                }
            }
            pre_ipc_server = srv;
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
            .animations = if (parsed.test_mode) .no_crossfade else .full,
            .stack_raw_jpeg = parsed.stack_raw_jpeg,
            .windowless = parsed.windowless,
        };
        self.gpa = gpa;
        self.io = proc_init.io;
        self.parsed = parsed;
        self.profiler = profiler;
        self.measure_data = .{ .measurer = .empty };
        self.ipc_server = null;
        try self.state.initInPlace(gpa, proc_init.io, .{
            .defaults = defaults,
            .visibility = if (start_hidden) .hidden else .visible,
            .gpu = .deferred,
            .waker = .sdl,
            .server = if (parsed.server_mode)
                .{
                    .resident = .{
                        .idle_timeout_ms = parsed.idle_timeout_sec *| 1000,
                    },
                }
            else
                .disabled,
        });
        errdefer self.state.deinit();
        const thumb_mode = if (parsed.test_mode) .off else parsed.thumb_cache;
        const thumb_tier = if (thumb_mode == .off)
            ThumbTier.normal
        else
            resolveThumbWriteTier(parsed.thumb_size, parsed.headless);
        self.state.initThumbCache(
            proc_init.environ_map,
            thumb_mode,
            thumb_tier,
        );

        // Spawn initial directory scan & decode worker before window/GPU setup
        // to overlap CPU file I/O & decode with Wayland/Vulkan initialization.
        try self.state.openInitialTarget(
            self.parsed.arg_path,
            state_pkg.timestampToMs(std.Io.Clock.awake.now(proc_init.io)),
        );
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
            self.ipc_server = pre_ipc_server;
            pre_ipc_server = null;
            return true;
        }

        const dev = try gpu.graphics.createGpuDevice(builtin.mode == .debug);
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
            if (parsed.headless) .headless else .{ .window = self.window },
            self.initial_dpi_scale,
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
        self.ipc_server = pre_ipc_server;
        pre_ipc_server = null;

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

    // Spawn IPC listener thread on the pre-locked server socket
    if (ctx.ipc_server) |srv| {
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
            true,
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

fn resolveThumbWriteTier(
    override_opt: ?ThumbTier,
    headless: bool,
) ThumbTier {
    if (override_opt) |tier| return tier;
    if (headless) return .normal;
    const scale = sdl.getPrimaryDisplayContentScale() orelse return .normal;
    return ThumbTier.fromDpiScale(scale);
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

test "hot-reload LibViewer init and reload" {
    if (!build_options.hot_reload) return error.SkipZigTest;

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var lib_viewer: LibViewer = try .init(io);
    defer lib_viewer.deinit(io);

    var first_buf: [64]u8 = undefined;
    const first_path = first_buf[0..lib_viewer.temp_path_len];
    @memcpy(first_path, lib_viewer.tempPath());

    try std.testing.expect(lib_viewer.is_valid);
    try std.testing.expectEqual(@as(u64, 0), lib_viewer.generation);
    try cwd.access(io, first_path, .{});
    lib_viewer.load_assets();
    try std.testing.expect(!try lib_viewer.check_outdated(io));

    try lib_viewer.updateLib(io);
    try std.testing.expect(lib_viewer.is_valid);
    try std.testing.expectEqual(@as(u64, 1), lib_viewer.generation);
    try std.testing.expect(!std.mem.eql(u8, first_path, lib_viewer.tempPath()));
    try std.testing.expectError(
        error.FileNotFound,
        cwd.access(io, first_path, .{}),
    );
    try cwd.access(io, lib_viewer.tempPath(), .{});
}
