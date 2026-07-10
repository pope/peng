const std = @import("std");
pub const clay = @import("zclay");
const ui = @import("ui.zig");
const renderer = ui.renderer;
const commands = @import("commands.zig");
const app_config = @import("config.zig");
const app = @import("app.zig");

pub const c = app.c;

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
pub const decodeWorker = app.state.decodeWorker;
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

fn getSdlScaleMode(self: *ViewerState) c.SDL_ScaleMode {
    return switch (self.texture_scale_mode) {
        .nearest => c.SDL_SCALEMODE_NEAREST,
        .linear => c.SDL_SCALEMODE_LINEAR,
        .pixel_art => c.SDL_SCALEMODE_PIXELART,
        .mitchell, .lanczos3 => c.SDL_SCALEMODE_NEAREST,
    };
}

pub const ParsedArgs = app_config.cli.ParsedArgs;
pub const parseCommandLineArgs = app_config.cli.parseCommandLineArgs;

pub const GraphicsSetup = ui.graphics.GraphicsSetup;
pub const GpuResources = ui.graphics.GpuResources;
pub const initGraphicsAndWindow = ui.graphics.initGraphicsAndWindow;
pub const initGpuResources = ui.graphics.initGpuResources;

fn readPipedStdin(state: *ViewerState, io: std.Io, gpa: std.mem.Allocator) !void {
    const is_stdin_piped = !(std.Io.File.stdin().isTty(io) catch false);
    if (is_stdin_piped) {
        var read_buf: [4096]u8 = undefined;
        var stdin_file_reader = std.Io.File.Reader.init(std.Io.File.stdin(), io, &read_buf);
        const stdin = &stdin_file_reader.interface;

        while (try stdin.takeDelimiter('\n')) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n ");
            if (trimmed.len > 0) {
                if (std.Io.Dir.statFile(std.Io.Dir.cwd(), io, trimmed, .{})) |s| {
                    if (s.kind == .directory) {
                        try scanDirectory(gpa, io, trimmed, &state.image_list);
                    } else if (isImageExtension(std.fs.path.extension(trimmed))) {
                        const dup = try gpa.dupe(u8, trimmed);
                        errdefer gpa.free(dup);
                        try state.image_list.append(gpa, dup);
                    }
                } else |_| {
                    const dup = try gpa.dupe(u8, trimmed);
                    errdefer gpa.free(dup);
                    try state.image_list.append(gpa, dup);
                }
            }
        }
        if (state.image_list.items.len > 0 and state.current_index == null) {
            state.current_index = 0;
            try state.updateCache();
        }
    }
}

fn pollFrameInput(
    window: *c.SDL_Window,
    frame_allocator: std.mem.Allocator,
    last_time: *u64,
    prev_mouse_inside: bool,
    palette_show: bool,
) !FrameInput {
    const current_ticks = c.SDL_GetTicks();
    const delta_time_ms = @as(f32, @floatFromInt(current_ticks - last_time.*));
    last_time.* = current_ticks;

    // Get window sizes and scale
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    if (!c.SDL_GetWindowSize(window, &win_w, &win_h)) {
        std.log.err("SDL_GetWindowSize failed: {s}", .{c.SDL_GetError()});
    }
    var pix_w: c_int = 0;
    var pix_h: c_int = 0;
    if (!c.SDL_GetWindowSizeInPixels(window, &pix_w, &pix_h)) {
        std.log.err("SDL_GetWindowSizeInPixels failed: {s}", .{c.SDL_GetError()});
    }

    const width = @as(f32, @floatFromInt(pix_w));
    const height = @as(f32, @floatFromInt(pix_h));
    const scale_x = if (win_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;
    const scale_y = if (win_h > 0) @as(f32, @floatFromInt(pix_h)) / @as(f32, @floatFromInt(win_h)) else 1.0;
    const dpi_scale = scale_x;

    var keys_pressed = std.ArrayList(c.SDL_Keycode).empty;
    errdefer keys_pressed.deinit(frame_allocator);
    var text_input_opt: ?[]const u8 = null;
    var dropped_path_opt: ?[]const u8 = null;
    var scroll_delta_x: f32 = 0;
    var scroll_delta_y: f32 = 0;
    var mouse_left_clicked = false;
    var mouse_inside = prev_mouse_inside;
    var quit_requested = false;

    var event: c.SDL_Event = undefined;
    const wait_success = if (palette_show)
        c.SDL_WaitEventTimeout(&event, 8)
    else
        c.SDL_WaitEvent(&event);

    if (!wait_success) {
        event.type = 0;
    }

    var has_event = wait_success;
    while (has_event) {
        switch (event.type) {
            c.SDL_EVENT_QUIT => quit_requested = true,
            c.SDL_EVENT_WINDOW_MOUSE_ENTER => {
                mouse_inside = true;
            },
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                mouse_inside = false;
            },
            c.SDL_EVENT_KEY_DOWN => {
                try keys_pressed.append(frame_allocator, event.key.key);
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (event.text.text) |ptr| {
                    const len = std.mem.len(ptr);
                    const dup = try frame_allocator.dupe(u8, ptr[0..len]);
                    text_input_opt = dup;
                }
            },
            c.SDL_EVENT_DROP_FILE => {
                if (event.drop.data) |ptr| {
                    const len = std.mem.len(ptr);
                    const dup = try frame_allocator.dupe(u8, ptr[0..len]);
                    dropped_path_opt = dup;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    mouse_left_clicked = true;
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const multiplier: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1.0 else 1.0;
                scroll_delta_x += event.wheel.x * multiplier * 6.0 * scale_x;
                scroll_delta_y += event.wheel.y * multiplier * 6.0 * scale_y;
            },
            else => {},
        }
        has_event = c.SDL_PollEvent(&event);
    }

    var mouse_x_raw: f32 = 0;
    var mouse_y_raw: f32 = 0;
    const mouse_buttons = c.SDL_GetMouseState(&mouse_x_raw, &mouse_y_raw);
    const mouse_left_down = (mouse_buttons & c.SDL_BUTTON_MASK(c.SDL_BUTTON_LEFT)) != 0;

    return FrameInput{
        .win_w = @as(f32, @floatFromInt(win_w)),
        .win_h = @as(f32, @floatFromInt(win_h)),
        .pix_w = width,
        .pix_h = height,
        .scale_x = scale_x,
        .scale_y = scale_y,
        .dpi_scale = dpi_scale,
        .mouse_x = mouse_x_raw * scale_x,
        .mouse_y = mouse_y_raw * scale_y,
        .mouse_left_down = mouse_left_down,
        .mouse_left_clicked = mouse_left_clicked,
        .mouse_inside = mouse_inside,
        .quit_requested = quit_requested,
        .scroll_delta_x = scroll_delta_x,
        .scroll_delta_y = scroll_delta_y,
        .keys_pressed = keys_pressed,
        .key_modifiers = c.SDL_GetModState(),
        .text_input = text_input_opt,
        .dropped_path = dropped_path_opt,
        .ticks = current_ticks,
        .delta_time_ms = delta_time_ms,
    };
}

pub const saveTextureToPng = ui.graphics.saveTextureToPng;

pub const renderFrame = ui.layout.renderFrame;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Phase 1: Parse command line arguments
    const parsed = try parseCommandLineArgs(init, gpa);
    defer if (parsed.arg_path) |p| gpa.free(p);

    // Phase 2: Graphics and Window Setup
    const setup = try initGraphicsAndWindow("Peng Image Viewer", parsed.test_mode);
    defer {
        c.SDL_DestroyGPUDevice(setup.gpu_device);
        c.SDL_DestroyWindow(setup.window);
        c.SDL_Quit();
        c.TTF_Quit();
    }

    // Phase 3: GPU Pipeline and Resources Setup
    const resources = try initGpuResources(setup.gpu_device, setup.window, setup.initial_dpi_scale, parsed.test_mode);
    var own_resources = true;
    defer {
        if (own_resources) {
            c.SDL_ReleaseGPUGraphicsPipeline(setup.gpu_device, resources.pipeline);
            c.SDL_ReleaseGPUSampler(setup.gpu_device, resources.sampler);
            c.SDL_ReleaseGPUTexture(setup.gpu_device, resources.white_texture);
            c.TTF_DestroyGPUTextEngine(resources.text_engine);
        }
        for (resources.fonts) |f| {
            if (f) |font| c.TTF_CloseFont(font);
        }
    }

    const cache_mutex = c.SDL_CreateMutex() orelse {
        std.log.err("SDL_CreateMutex failed: {s}", .{c.SDL_GetError()});
        return error.SDLCreateMutexFailed;
    };

    // Phase 4: State Initialization
    var state = ViewerState{
        .gpu_device = setup.gpu_device,
        .gpu_pipeline = resources.pipeline,
        .gpu_sampler = resources.sampler,
        .white_texture = resources.white_texture,
        .gpu_text_engine = resources.text_engine,
        .image_list = std.ArrayList([]const u8).empty,
        .cache = .{},
        .cache_mutex = cache_mutex,
        .allocator = gpa,
        .io = init.io,
        .window_pixel_format = c.SDL_PIXELFORMAT_RGBA32,
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
        .test_mode = parsed.test_mode,
        .update_baselines = parsed.update_baselines,
        .window_claimed = !parsed.test_mode,
    };
    defer state.deinit();
    own_resources = false;

    // Populate initial image list from arguments and piped stdin
    if (parsed.arg_path) |path| {
        try state.handlePathSelection(path);
    }
    try readPipedStdin(&state, init.io, gpa);

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
        .text_engine = resources.text_engine,
        .fonts = resources.fonts[0..],
        .allocator = gpa,
    };
    clay.setMeasureTextFunction(*const MeasureTextUserData, &measure_data, sdl3MeasureText);

    // Per-frame arena allocator
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();

    var last_time = c.SDL_GetTicks();

    // Phase 5: The Main Loop / Test Mode
    if (state.test_mode) {
        const test_runner = @import("app/test_runner.zig");
        try test_runner.runIntegrationTests(&state, &setup, &resources, &measure_data, gpa);
    } else {
        while (state.running) {
            // Phase 5a: Input Accumulation
            _ = frame_arena.reset(.retain_capacity);
            const input = try pollFrameInput(
                setup.window,
                frame_allocator,
                &last_time,
                state.mouse_inside,
                state.palette.mode != .inactive,
            );

            if (input.quit_requested) {
                state.running = false;
            }
            state.mouse_inside = input.mouse_inside;

            // Phase 5b: State Update
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

            if (input.mouse_left_clicked) {
                if (state.show_stats_overlay and clay.pointerOver(clay.getElementId("StatsCloseBtn"))) {
                    state.show_stats_overlay = false;
                }
            }

            // Phase 5c: Draw / Render
            try renderFrame(&state, input, frame_allocator, resources.fonts[0..], &measure_data, null);
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
}
