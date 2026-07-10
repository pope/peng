const std = @import("std");
pub const clay = @import("zclay");
const ui = @import("ui.zig");
const renderer = ui.renderer;
const commands = @import("commands.zig");
const app_config = @import("config.zig");
const app = @import("app.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_gpu.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
    @cInclude("SDL3_image/SDL_image.h");
});

pub const vert_spv = @embedFile("shaders/vert.spv");
pub const frag_spv = @embedFile("shaders/frag.spv");

pub const MeasureTextUserData = struct {
    text_engine: ?*c.TTF_TextEngine,
    fonts: []const ?*c.TTF_Font,
    allocator: std.mem.Allocator,
};

pub const FrameInput = struct {
    win_w: f32,
    win_h: f32,
    pix_w: f32,
    pix_h: f32,
    scale_x: f32,
    scale_y: f32,
    dpi_scale: f32,

    mouse_x: f32,
    mouse_y: f32,
    mouse_left_down: bool,
    mouse_left_clicked: bool,
    mouse_inside: bool,
    scroll_delta_x: f32,
    scroll_delta_y: f32,

    keys_pressed: std.ArrayList(c.SDL_Keycode),
    key_modifiers: c.SDL_Keymod,
    text_input: ?[]const u8,
    dropped_path: ?[]const u8,

    ticks: u64,
    delta_time_ms: f32,
};

pub fn sdl3MeasureText(text: []const u8, config: *clay.TextElementConfig, data: *const MeasureTextUserData) clay.Dimensions {
    if (config.font_id >= data.fonts.len) return .{ .w = 0, .h = 0 };
    const font = data.fonts[config.font_id] orelse return .{ .w = 0, .h = 0 };
    const target_size = @as(f32, @floatFromInt(config.font_size));
    if (c.TTF_GetFontSize(font) != target_size) {
        if (!c.TTF_SetFontSize(font, target_size)) {
            std.log.err("TTF_SetFontSize failed: {s}", .{c.SDL_GetError()});
        }
    }

    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.TTF_GetStringSize(font, text.ptr, text.len, &w, &h)) {
        return .{ .w = 0, .h = 0 };
    }

    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

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
    mouse_inside: *bool,
    running: *bool,
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
            c.SDL_EVENT_QUIT => running.* = false,
            c.SDL_EVENT_WINDOW_MOUSE_ENTER => {
                mouse_inside.* = true;
            },
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                mouse_inside.* = false;
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
                scroll_delta_x += event.wheel.x * multiplier * 6.0;
                scroll_delta_y += event.wheel.y * multiplier * 6.0;
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
        .mouse_inside = mouse_inside.*,
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

fn compareScreenshots(base_path: [:0]const u8, run_path: [:0]const u8, diff_path: [:0]const u8) !void {
    const raw_base_surf = c.IMG_Load(base_path.ptr) orelse {
        std.log.err("Failed to load baseline screenshot: {s}. Run with --update-baselines to create it.", .{base_path});
        return error.BaselineMissing;
    };
    defer c.SDL_DestroySurface(raw_base_surf);

    const raw_run_surf = c.IMG_Load(run_path.ptr) orelse {
        std.log.err("Failed to load run screenshot: {s}", .{run_path});
        return error.RunScreenshotMissing;
    };
    defer c.SDL_DestroySurface(raw_run_surf);

    if (raw_base_surf.*.w != raw_run_surf.*.w or raw_base_surf.*.h != raw_run_surf.*.h) {
        std.log.err("Dimension mismatch: baseline is {d}x{d}, run is {d}x{d}", .{ raw_base_surf.*.w, raw_base_surf.*.h, raw_run_surf.*.w, raw_run_surf.*.h });
        return error.DimensionMismatch;
    }

    const width = @as(u32, @intCast(raw_base_surf.*.w));
    const height = @as(u32, @intCast(raw_base_surf.*.h));

    // Convert both surfaces to a canonical RGBA32 format to guarantee alignment, pitch, and byte order matching
    const base_surf = c.SDL_ConvertSurface(raw_base_surf, c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.err("Failed to convert baseline to RGBA32: {s}", .{c.SDL_GetError()});
        return error.SurfaceConversionFailed;
    };
    defer c.SDL_DestroySurface(base_surf);

    const run_surf = c.SDL_ConvertSurface(raw_run_surf, c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.err("Failed to convert run to RGBA32: {s}", .{c.SDL_GetError()});
        return error.SurfaceConversionFailed;
    };
    defer c.SDL_DestroySurface(run_surf);

    const diff_surf = c.SDL_CreateSurface(@intCast(width), @intCast(height), c.SDL_PIXELFORMAT_RGBA32) orelse {
        std.log.err("Failed to create diff surface: {s}", .{c.SDL_GetError()});
        return error.DiffSurfaceCreationFailed;
    };
    defer c.SDL_DestroySurface(diff_surf);

    const pixels_base = @as([*]const u32, @ptrCast(@alignCast(base_surf.*.pixels)));
    const pixels_run = @as([*]const u32, @ptrCast(@alignCast(run_surf.*.pixels)));
    const pixels_diff = @as([*]u32, @ptrCast(@alignCast(diff_surf.*.pixels)));

    const pitch_words_base = @as(usize, @intCast(base_surf.*.pitch)) / 4;
    const pitch_words_run = @as(usize, @intCast(run_surf.*.pitch)) / 4;
    const pitch_words_diff = @as(usize, @intCast(diff_surf.*.pitch)) / 4;

    var mismatched_pixels: u32 = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx_base = y * pitch_words_base + x;
            const idx_run = y * pitch_words_run + x;
            const idx_diff = y * pitch_words_diff + x;

            const p_base = pixels_base[idx_base];
            const p_run = pixels_run[idx_run];
            if (p_base != p_run) {
                mismatched_pixels += 1;
                // Paint mismatched pixel as bright red (0xFF0000FF in RGBA32 format)
                pixels_diff[idx_diff] = 0xFF0000FF;
            } else {
                // Dim color channels (divides by 4) and preserve alpha safely without channel bleeding
                const b0 = (p_base >> 0) & 0xFF;
                const b1 = (p_base >> 8) & 0xFF;
                const b2 = (p_base >> 16) & 0xFF;
                const b3 = (p_base >> 24) & 0xFF;
                pixels_diff[idx_diff] = (b0 / 4) | ((b1 / 4) << 8) | ((b2 / 4) << 16) | (b3 << 24);
            }
        }
    }

    if (mismatched_pixels > 0) {
        const total_pixels = width * height;
        const pct = (@as(f64, @floatFromInt(mismatched_pixels)) / @as(f64, @floatFromInt(total_pixels))) * 100.0;
        std.log.err("Visual regression found: {d} pixels differ ({d:.3}%)", .{ mismatched_pixels, pct });
        if (!c.IMG_SavePNG(diff_surf, diff_path.ptr)) {
            std.log.err("Failed to save diff image: {s}", .{c.SDL_GetError()});
        } else {
            std.log.info("Diff image saved to: {s}", .{diff_path});
        }
        return error.VisualRegressionMismatch;
    }
}

fn getTextureFormatElementSize(format: c.SDL_GPUTextureFormat) u32 {
    return switch (format) {
        c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM, c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB => 4,
        c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT => 8,
        c.SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT => 16,
        else => 4, // Fallback safe default
    };
}

pub fn saveTextureToPng(
    device: *c.SDL_GPUDevice,
    cmd_buf: *c.SDL_GPUCommandBuffer,
    texture: *c.SDL_GPUTexture,
    width: u32,
    height: u32,
    texture_format: c.SDL_GPUTextureFormat,
    filename: [:0]const u8,
) !void {
    const bpp = getTextureFormatElementSize(texture_format);
    const pitch = width * bpp;
    const size = pitch * height;

    const transfer_buf = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = size,
        .props = 0,
    }) orelse {
        std.log.err("Failed to create download transfer buffer: {s}", .{c.SDL_GetError()});
        return error.TransferBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buf);

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse return error.CopyPassCreationFailed;
    c.SDL_DownloadFromGPUTexture(copy_pass, &c.SDL_GPUTextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = width,
        .h = height,
        .d = 1,
    }, &c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = width,
        .rows_per_layer = height,
    });
    c.SDL_EndGPUCopyPass(copy_pass);

    _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    _ = c.SDL_WaitForGPUIdle(device);

    const data_ptr = c.SDL_MapGPUTransferBuffer(device, transfer_buf, false) orelse return error.MapBufferFailed;
    defer c.SDL_UnmapGPUTransferBuffer(device, transfer_buf);

    var sdl_format: c.SDL_PixelFormat = c.SDL_PIXELFORMAT_RGBA32;
    if (texture_format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM or
        texture_format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB)
    {
        sdl_format = c.SDL_PIXELFORMAT_BGRA32;
    }

    const surface = c.SDL_CreateSurfaceFrom(@intCast(width), @intCast(height), sdl_format, data_ptr, @intCast(pitch)) orelse {
        std.log.err("SDL_CreateSurfaceFrom failed: {s}", .{c.SDL_GetError()});
        return error.SurfaceCreationFailed;
    };
    defer c.SDL_DestroySurface(surface);

    if (!c.IMG_SavePNG(surface, filename.ptr)) {
        std.log.err("IMG_SavePNG failed: {s}", .{c.SDL_GetError()});
        return error.SavePngFailed;
    }
}

pub const renderFrame = ui.layout.renderFrame;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Phase 1: Parse command line arguments
    const parsed = try parseCommandLineArgs(init, gpa);
    defer if (parsed.arg_path) |p| gpa.free(p);

    // Phase 2: Graphics and Window Setup
    const setup = try initGraphicsAndWindow("Peng Image Viewer", parsed.test_mode);
    defer {
        c.SDL_DestroyWindow(setup.window);
        c.SDL_Quit();
        c.TTF_Quit();
    }

    // Phase 3: GPU Pipeline and Resources Setup
    const resources = try initGpuResources(setup.gpu_device, setup.window, setup.initial_dpi_scale);
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
        if (std.Io.Dir.openDir(std.Io.Dir.cwd(), state.io, "testfiles/current-run", .{ .iterate = true })) |dir| {
            var it = std.Io.Dir.iterate(dir);
            while (it.next(state.io) catch null) |entry| {
                std.Io.Dir.deleteFile(dir, state.io, entry.name) catch {};
            }
            std.Io.Dir.close(dir, state.io);
        } else |_| {}

        std.Io.Dir.createDirPath(std.Io.Dir.cwd(), state.io, "testfiles/golden-screenshots") catch {};
        std.Io.Dir.createDirPath(std.Io.Dir.cwd(), state.io, "testfiles/current-run") catch {};

        var test_frame: u32 = 0;
        const filenames = [_][]const u8{
            "test_0_init.png",
            "test_1_zoom.png",
            "test_2_adjust.png",
            "test_3_filter.png",
            "test_4_action_palette.png",
            "test_5_files_palette.png",
            "test_6_next_image.png",
        };
        while (test_frame < 7) : (test_frame += 1) {
            // Pump event loop to prevent OS "Application Unresponsive" warnings
            var event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&event)) {}

            _ = frame_arena.reset(.retain_capacity);

            var win_w: c_int = 0;
            var win_h: c_int = 0;
            _ = c.SDL_GetWindowSize(setup.window, &win_w, &win_h);

            var pix_w: c_int = 0;
            var pix_h: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(setup.window, &pix_w, &pix_h);

            const width = @as(f32, @floatFromInt(pix_w));
            const height = @as(f32, @floatFromInt(pix_h));
            const scale_x = if (win_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;
            const scale_y = if (win_h > 0) @as(f32, @floatFromInt(pix_h)) / @as(f32, @floatFromInt(win_h)) else 1.0;
            const dpi_scale = scale_x;

            const input = FrameInput{
                .win_w = @as(f32, @floatFromInt(win_w)),
                .win_h = @as(f32, @floatFromInt(win_h)),
                .pix_w = width,
                .pix_h = height,
                .scale_x = scale_x,
                .scale_y = scale_y,
                .dpi_scale = dpi_scale,
                .mouse_x = -1.0,
                .mouse_y = -1.0,
                .mouse_left_down = false,
                .mouse_left_clicked = false,
                .mouse_inside = false,
                .scroll_delta_x = 0.0,
                .scroll_delta_y = 0.0,
                .keys_pressed = std.ArrayList(c.SDL_Keycode).empty,
                .key_modifiers = 0,
                .text_input = null,
                .dropped_path = null,
                .ticks = 0,
                .delta_time_ms = 16.666,
            };

            switch (test_frame) {
                0 => {
                    std.log.info("Test Mode Frame 0: Initial Render", .{});
                },
                1 => {
                    std.log.info("Test Mode Frame 1: Apply Zoom & Pan", .{});
                    state.zoom_factor = 2.0;
                    state.pan_x = 50.0;
                    state.pan_y = -30.0;
                },
                2 => {
                    std.log.info("Test Mode Frame 2: Apply Brightness & Contrast", .{});
                    state.zoom_factor = 1.0;
                    state.pan_x = 0.0;
                    state.pan_y = 0.0;
                    state.brightness = 0.3;
                    state.contrast = 1.4;
                    state.adjustments_dirty = true;
                },
                3 => {
                    std.log.info("Test Mode Frame 3: Apply Mitchell Filter", .{});
                    state.brightness = 0.0;
                    state.contrast = 1.0;
                    state.adjustments_dirty = true;
                    state.texture_scale_mode = .mitchell;
                    state.applyTextureScaleMode();
                },
                4 => {
                    std.log.info("Test Mode Frame 4: Open Action Palette", .{});
                    state.texture_scale_mode = .linear;
                    state.applyTextureScaleMode();

                    state.palette.reset();
                    state.palette.mode = .actions;
                    try state.rebuildActionMatches();
                },
                5 => {
                    std.log.info("Test Mode Frame 5: Open Files Palette", .{});
                    state.palette.reset();
                    state.palette.mode = .files;
                    try state.rebuildPaletteMatches();
                },
                6 => {
                    std.log.info("Test Mode Frame 6: Navigate to Next Image", .{});
                    state.palette.mode = .inactive;
                    try state.next();
                },
                else => unreachable,
            }

            // Busy wait until the background loader finishes decoding the image
            var wait_attempts: u32 = 0;
            while (wait_attempts < 1000) : (wait_attempts += 1) {
                // Pump event loop during wait to keep window manager happy
                var ev: c.SDL_Event = undefined;
                while (c.SDL_PollEvent(&ev)) {}

                if (state.getCurrentEntry()) |entry| {
                    if (entry.status != .decoding) {
                        break;
                    }
                }
                c.SDL_Delay(10);
            }
            if (state.getCurrentEntry() == null or state.getCurrentEntry().?.status == .failed) {
                std.log.err("Timed out or failed waiting for test image to load in cache.", .{});
                return error.TestImageLoadTimeout;
            }

            clay.setLayoutDimensions(.{ .w = input.pix_w, .h = input.pix_h });
            clay.setPointerState(.{ .x = -1.0, .y = -1.0 }, false);

            const base_filename = try frame_allocator.dupeZ(u8, try std.fmt.allocPrint(frame_allocator, "testfiles/golden-screenshots/{s}", .{filenames[test_frame]}));
            const run_filename = try frame_allocator.dupeZ(u8, try std.fmt.allocPrint(frame_allocator, "testfiles/current-run/{s}", .{filenames[test_frame]}));
            const diff_filename = try frame_allocator.dupeZ(u8, try std.fmt.allocPrint(frame_allocator, "testfiles/current-run/diff_{s}", .{filenames[test_frame]}));

            const capture_path = if (state.update_baselines) base_filename else run_filename;

            try renderFrame(&state, input, frame_allocator, resources.fonts[0..], &measure_data, capture_path);

            if (!state.update_baselines) {
                try compareScreenshots(base_filename, run_filename, diff_filename);
            }
        }
        std.log.info("Test Mode completed successfully!", .{});
    } else {
        while (state.running) {
            // Phase 5a: Input Accumulation
            _ = frame_arena.reset(.retain_capacity);
            const input = try pollFrameInput(
                setup.window,
                frame_allocator,
                &last_time,
                &state.mouse_inside,
                &state.running,
                state.palette.mode != .inactive,
            );

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
