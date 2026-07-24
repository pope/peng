const std = @import("std");
pub const clay = @import("zclay");
const ui = @import("ui.zig");
const renderer = ui.renderer;
const commands = @import("commands.zig");
const app_config = @import("config.zig");
const app = @import("app.zig");
const sdl = @import("sdl");

pub const vert_spv = @embedFile("shaders/vert.spv");
pub const frag_spv = @embedFile("shaders/frag.spv");

pub const MeasureTextUserData = app.types.MeasureTextUserData;
pub const FrameInput = app.types.FrameInput;

pub const sdl3MeasureText = ui.graphics.sdl3MeasureText;

pub const eqlIgnoreCase = app.state.eqlIgnoreCase;
pub const isImageExtension = app.state.isImageExtension;
pub const scanDirectory = app.state.scanDirectory;
pub const detectMimeType = app.state.detectMimeType;

pub const CacheEntry = app.state.CacheEntry;
pub const DecodeArgs = app.state.DecodeArgs;
pub const matchesQueryLower = app.state.matchesQueryLower;
pub const startTextInput = app.state.startTextInput;
pub const stopTextInput = app.state.stopTextInput;

pub const AppActionId = commands.actions.AppActionId;
pub const KeyboardShortcut = commands.actions.KeyboardShortcut;
pub const ActionMetadata = commands.actions.ActionMetadata;
pub const getActionMetadata = commands.actions.getActionMetadata;
pub const app_actions = commands.actions.app_actions;
pub const FlatShortcut = commands.actions.FlatShortcut;
pub const flat_shortcuts = commands.actions.flat_shortcuts;

pub const PaletteType = app.state.PaletteType;
pub const PaletteState = app.state.PaletteState;
pub const ScaleMode = app.state.ScaleMode;
pub const TextureScaleMode = app.state.TextureScaleMode;
pub const ElementTag = app.state.ElementTag;
pub const ViewerState = app.state.ViewerState;

pub const ParsedArgs = app_config.cli.ParsedArgs;
pub const parseCommandLineArgs = app_config.cli.parseCommandLineArgs;

pub const GraphicsSetup = ui.graphics.GraphicsSetup;
pub const GpuResources = ui.graphics.GpuResources;
pub const initGraphicsAndWindow = ui.graphics.initGraphicsAndWindow;
pub const initGpuResources = ui.graphics.initGpuResources;
pub const saveTextureToPng = ui.graphics.saveTextureToPng;
pub const renderFrame = ui.layout.renderFrame;

const app_fs = @import("app/fs.zig");
const app_input = @import("app/input.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Phase 1: Parse command line arguments
    const parsed = try parseCommandLineArgs(init, gpa);
    defer if (parsed.arg_path) |p| gpa.free(p);

    // Phase 2: Graphics and Window Setup
    const setup = try initGraphicsAndWindow("Peng Image Viewer", .{
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
    const resources = try initGpuResources(setup.gpu_device, setup.window, setup.initial_dpi_scale, parsed.headless);
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
    var state = ViewerState{
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
        .palette = PaletteState.init(gpa),
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
    try app_fs.readPipedStdin(&state, init.io, gpa);

    // Initialize Clay UI Layout Engine
    const clay_memory_size = clay.minMemorySize();
    const clay_memory = try gpa.alloc(u8, clay_memory_size);
    defer gpa.free(clay_memory);
    const clay_arena = clay.Arena.init(clay_memory);
    _ = clay.initialize(clay_arena, .{
        .w = @as(f32, @floatFromInt(1024)),
        .h = @as(f32, @floatFromInt(768)),
    }, .{});

    var measure_data = MeasureTextUserData{
        .fonts = resources.fonts[0..],
        .allocator = gpa,
    };
    clay.setMeasureTextFunction(*const MeasureTextUserData, &measure_data, sdl3MeasureText);

    // Per-frame arena allocator
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();

    var last_time = sdl.timer.getTicks();

    // Phase 5: Initialize IPC Server
    const ipc = @import("app/ipc.zig");
    var ipc_server: ?*ipc.IpcServer = null;
    if (parsed.ipc_enabled) {
        const IpcServer = ipc.IpcServer;
        ipc_server = try IpcServer.init(gpa, &state);
    }
    defer if (ipc_server) |srv| srv.deinit(init.io);

    var active_screenshot: ?struct {
        path: [:0]const u8,
        stream: std.Io.net.Stream,
    } = null;
    defer {
        if (active_screenshot) |s| {
            var write_buf: [64]u8 = undefined;
            var writer = s.stream.writer(state.io, &write_buf);
            writer.interface.writeAll("ERR quit\n") catch |err| std.log.warn("Emergency screenshot response write failed: {}", .{err});
            writer.interface.flush() catch |err| std.log.warn("Emergency screenshot response flush failed: {}", .{err});
            s.stream.close(state.io);
            gpa.free(s.path);
        }
    }

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
        const input = try app_input.pollFrameInput(
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
        for (state.pending_ipc_commands.items) |cmd_data| {
            var it = std.mem.tokenizeAny(u8, cmd_data.command, " \t\r\n");
            const cmd = it.next() orelse "";
            if (std.mem.eql(u8, cmd, "screenshot")) {
                if (it.next()) |filepath| {
                    if (filepath.len > 512) {
                        var write_buf: [128]u8 = undefined;
                        var writer = cmd_data.client_stream.writer(state.io, &write_buf);
                        writer.interface.writeAll("ERR PathTooLong\n") catch |err| std.log.warn("IPC screenshot response failed: {}", .{err});
                        writer.interface.flush() catch |err| std.log.warn("IPC flush failed: {}", .{err});
                        cmd_data.client_stream.close(state.io);
                    } else if (active_screenshot) |_| {
                        var write_buf: [128]u8 = undefined;
                        var writer = cmd_data.client_stream.writer(state.io, &write_buf);
                        writer.interface.writeAll("ERR Busy\n") catch |err| std.log.warn("IPC screenshot response failed: {}", .{err});
                        writer.interface.flush() catch |err| std.log.warn("IPC flush failed: {}", .{err});
                        cmd_data.client_stream.close(state.io);
                    } else {
                        const dup_path = gpa.dupeZ(u8, filepath) catch {
                            var write_buf: [128]u8 = undefined;
                            var writer = cmd_data.client_stream.writer(state.io, &write_buf);
                            writer.interface.writeAll("ERR OutOfMemory\n") catch |err| std.log.warn("IPC screenshot response failed: {}", .{err});
                            writer.interface.flush() catch |err| std.log.warn("IPC flush failed: {}", .{err});
                            cmd_data.client_stream.close(state.io);
                            gpa.free(cmd_data.command);
                            gpa.destroy(cmd_data);
                            continue;
                        };
                        active_screenshot = .{
                            .path = dup_path,
                            .stream = cmd_data.client_stream,
                        };
                    }
                } else {
                    var write_buf: [128]u8 = undefined;
                    var writer = cmd_data.client_stream.writer(state.io, &write_buf);
                    writer.interface.writeAll("ERR MissingArgument\n") catch |err| std.log.warn("IPC screenshot response failed: {}", .{err});
                    writer.interface.flush() catch |err| std.log.warn("IPC flush failed: {}", .{err});
                    cmd_data.client_stream.close(state.io);
                }
            } else {
                if (ipc_server) |srv| {
                    srv.executeCommand(&state, cmd_data.command, cmd_data.client_stream) catch |err| {
                        var response_buf: [128]u8 = undefined;
                        const response = std.fmt.bufPrint(&response_buf, "ERR {s}\n", .{@errorName(err)}) catch "ERR ExecutionFailed\n";
                        var write_buf: [128]u8 = undefined;
                        var writer = cmd_data.client_stream.writer(state.io, &write_buf);
                        writer.interface.writeAll(response) catch |err2| std.log.warn("IPC error response failed: {}", .{err2});
                        writer.interface.flush() catch |err2| std.log.warn("IPC flush failed: {}", .{err2});
                        cmd_data.client_stream.close(state.io);
                    };
                }
            }
            gpa.free(cmd_data.command);
            gpa.destroy(cmd_data);
        }
        state.pending_ipc_commands.clearRetainingCapacity();

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
        const capture_filename = if (active_screenshot) |s| s.path else null;
        renderFrame(&state, input, frame_allocator, resources.fonts[0..], &measure_data, capture_filename) catch |err| {
            if (active_screenshot) |s| {
                var response_buf: [128]u8 = undefined;
                const response = std.fmt.bufPrint(&response_buf, "ERR {s}\n", .{@errorName(err)}) catch "ERR SaveFailed\n";
                var write_buf: [128]u8 = undefined;
                var writer = s.stream.writer(state.io, &write_buf);
                writer.interface.writeAll(response) catch |werr| std.log.warn("Screenshot response failed: {}", .{werr});
                writer.interface.flush() catch |ferr| std.log.warn("Screenshot response flush failed: {}", .{ferr});
                s.stream.close(state.io);
                gpa.free(s.path);
                active_screenshot = null;
            }
            return err;
        };

        if (active_screenshot) |s| {
            var write_buf: [128]u8 = undefined;
            var writer = s.stream.writer(state.io, &write_buf);
            writer.interface.writeAll("OK\n") catch |werr| std.log.warn("Screenshot response failed: {}", .{werr});
            writer.interface.flush() catch |ferr| std.log.warn("Screenshot response flush failed: {}", .{ferr});
            s.stream.close(state.io);
            gpa.free(s.path);
            active_screenshot = null;
        }
    }
}

test "ElementTag.fromInt" {
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0));
    try std.testing.expectEqual(ElementTag.drop_zone_box, ElementTag.fromInt(1337));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(9999));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0x7fffffffd000));

    std.testing.refAllDecls(@import("app/state.zig"));
    std.testing.refAllDecls(@import("app/input.zig"));
    std.testing.refAllDecls(@import("app/image.zig"));
}
