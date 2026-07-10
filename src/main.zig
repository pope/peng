const std = @import("std");
pub const clay = @import("zclay");
const renderer = @import("renderer.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_gpu.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
    @cInclude("SDL3_image/SDL_image.h");
});

pub const vert_spv = @embedFile("shaders/vert.spv");
pub const frag_spv = @embedFile("shaders/frag.spv");

const MeasureTextUserData = struct {
    text_engine: ?*c.TTF_TextEngine,
    fonts: []const ?*c.TTF_Font,
    allocator: std.mem.Allocator,
};

const FrameInput = struct {
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

fn sdl3MeasureText(text: []const u8, config: *clay.TextElementConfig, data: *const MeasureTextUserData) clay.Dimensions {
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

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |char_a, index| {
        if (std.ascii.toLower(char_a) != std.ascii.toLower(b[index])) return false;
    }
    return true;
}

fn isImageExtension(ext: []const u8) bool {
    const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".webp" };
    for (extensions) |e| {
        if (eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn scanDirectory(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, list: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open directory '{s}': {}", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries = std.ArrayList([]const u8).empty;
    defer dir_entries.deinit(allocator);
    errdefer {
        for (dir_entries.items) |entry| {
            allocator.free(entry);
        }
    }

    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (isImageExtension(ext)) {
                const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                try dir_entries.append(allocator, full_path);
            }
        }
    }

    // Sort entries alphabetically
    std.mem.sort([]const u8, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    try list.appendSlice(allocator, dir_entries.items);
}

fn detectMimeType(io: std.Io, path: []const u8) []const u8 {
    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch return "unknown";
    defer file.close(io);

    var header: [12]u8 = undefined;
    var slices = [_][]u8{&header};
    const bytes_read = file.readPositional(io, &slices, 0) catch return "unknown";
    if (bytes_read < 4) return "unknown";

    if (std.mem.startsWith(u8, &header, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) {
        return "image/png";
    }
    if (std.mem.startsWith(u8, &header, &[_]u8{ 0xFF, 0xD8, 0xFF })) {
        return "image/jpeg";
    }
    if (std.mem.startsWith(u8, &header, "GIF87a") or std.mem.startsWith(u8, &header, "GIF89a")) {
        return "image/gif";
    }
    if (std.mem.startsWith(u8, &header, "BM")) {
        return "image/bmp";
    }
    if (bytes_read >= 12 and std.mem.startsWith(u8, &header, "RIFF") and std.mem.eql(u8, header[8..12], "WEBP")) {
        return "image/webp";
    }

    const ext = std.fs.path.extension(path);
    if (eqlIgnoreCase(ext, ".png")) return "image/png";
    if (eqlIgnoreCase(ext, ".jpg") or eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (eqlIgnoreCase(ext, ".bmp")) return "image/bmp";
    if (eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (eqlIgnoreCase(ext, ".tga")) return "image/x-tga";

    return "unknown";
}

fn renderStatRow(label: []const u8, value: []const u8, scale_x: f32, scale_y: f32, dpi_scale: f32) !void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(20 * scale_y) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(110 * scale_x), .h = .grow } } })({
            clay.text(label, .{
                .color = .{ 166, 173, 200, 255 }, // Subtext0
                .font_size = @intFromFloat(13.0 * dpi_scale),
                .font_id = 0,
            });
        });

        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({
            clay.text(value, .{
                .color = .{ 205, 214, 244, 255 }, // Text
                .font_size = @intFromFloat(13.0 * dpi_scale),
                .font_id = 0,
            });
        });
    });
}

const CacheEntry = struct {
    index: usize,
    generation: usize,
    gpu_texture: ?*c.SDL_GPUTexture = null,
    w: f32 = 0,
    h: f32 = 0,
    size_bytes: u64 = 0,
    mime_type: []const u8 = "unknown",
    decode_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    upload_time_ms: f64 = 0.0,
    memory_size_bytes: usize = 0,
    surface: ?*c.SDL_Surface = null,
    status: enum { decoding, loaded, failed } = .decoding,
};

const DecodeArgs = struct {
    state: *ViewerState,
    index: usize,
    generation: usize,
    path: [:0]const u8,
};

fn decodeWorker(data: ?*anyopaque) callconv(.c) c_int {
    const args: *DecodeArgs = @ptrCast(@alignCast(data.?));
    const state = args.state;
    const index = args.index;
    const path = args.path;

    defer {
        state.allocator.free(path);
        state.allocator.destroy(args);
        _ = state.active_threads.fetchSub(1, .release);
    }

    if (state.exiting.load(.acquire)) return 0;

    const mime_type = detectMimeType(state.io, path);

    if (state.exiting.load(.acquire)) return 0;

    const start_decode = c.SDL_GetTicksNS();
    const surface = c.IMG_Load(path.ptr);
    const end_decode = c.SDL_GetTicksNS();

    const decode_time_ms = @as(f64, @floatFromInt(end_decode - start_decode)) / 1_000_000.0;

    if (state.exiting.load(.acquire)) {
        if (surface) |surf| c.SDL_DestroySurface(surf);
        return 0;
    }

    var final_surface = surface;
    var conversion_time_ms: f64 = 0.0;
    if (surface) |surf| {
        if (state.window_pixel_format != c.SDL_PIXELFORMAT_UNKNOWN and surf.*.format != state.window_pixel_format) {
            const start_convert = c.SDL_GetTicksNS();
            const converted = c.SDL_ConvertSurface(surf, state.window_pixel_format);
            const end_convert = c.SDL_GetTicksNS();

            if (converted) |conv| {
                conversion_time_ms = @as(f64, @floatFromInt(end_convert - start_convert)) / 1_000_000.0;
                c.SDL_DestroySurface(surf);
                final_surface = conv;
            } else {
                std.log.err("SDL_ConvertSurface failed: {s}", .{c.SDL_GetError()});
            }
        }

        if (final_surface) |f_surf| {
            const max_dim: i32 = 8192;
            if (f_surf.*.w > max_dim or f_surf.*.h > max_dim) {
                var new_w = f_surf.*.w;
                var new_h = f_surf.*.h;
                if (f_surf.*.w > f_surf.*.h) {
                    new_w = max_dim;
                    new_h = @divTrunc(f_surf.*.h * max_dim, f_surf.*.w);
                } else {
                    new_h = max_dim;
                    new_w = @divTrunc(f_surf.*.w * max_dim, f_surf.*.h);
                }
                new_w = @max(1, new_w);
                new_h = @max(1, new_h);

                const scaled = c.SDL_ScaleSurface(f_surf, new_w, new_h, c.SDL_SCALEMODE_LINEAR);
                if (scaled) |sc| {
                    c.SDL_DestroySurface(f_surf);
                    final_surface = sc;
                } else {
                    std.log.err("decodeWorker: SDL_ScaleSurface failed: {s}", .{c.SDL_GetError()});
                }
            }
        }
    }

    // Stat the file
    var size_bytes: u64 = 0;
    if (std.Io.Dir.statFile(std.Io.Dir.cwd(), state.io, path, .{})) |s| {
        size_bytes = s.size;
    } else |_| {}

    if (state.exiting.load(.acquire)) {
        if (final_surface) |surf| c.SDL_DestroySurface(surf);
        return 0;
    }

    // Lock cache and update
    c.SDL_LockMutex(state.cache_mutex);
    defer c.SDL_UnlockMutex(state.cache_mutex);

    if (state.exiting.load(.acquire)) {
        if (final_surface) |surf| c.SDL_DestroySurface(surf);
        return 0;
    }

    // Check if this index is still wanted
    var found_in_cache = false;
    for (state.cache.items) |*entry| {
        if (entry.index == index and entry.generation == args.generation) {
            found_in_cache = true;
            if (final_surface) |surf| {
                if (entry.surface != null or entry.gpu_texture != null) {
                    c.SDL_DestroySurface(surf);
                } else {
                    entry.surface = surf;
                    entry.w = @floatFromInt(surf.*.w);
                    entry.h = @floatFromInt(surf.*.h);
                    entry.memory_size_bytes = @intCast(surf.*.pitch * surf.*.h);
                    entry.size_bytes = size_bytes;
                    entry.mime_type = mime_type;
                    entry.decode_time_ms = decode_time_ms;
                    entry.conversion_time_ms = conversion_time_ms;
                    entry.status = .loaded;
                }
            } else {
                if (entry.status != .loaded) {
                    entry.status = .failed;
                }
            }
            break;
        }
    }

    if (!found_in_cache) {
        if (final_surface) |surf| {
            c.SDL_DestroySurface(surf);
        }
    } else {
        // Push SDL user event to wake up the main loop
        var event: c.SDL_Event = undefined;
        event.type = c.SDL_EVENT_USER;
        _ = c.SDL_PushEvent(&event);
    }

    return 0;
}

fn matchesQueryLower(path: []const u8, query_lower: []const u8) bool {
    if (query_lower.len == 0) return true;
    if (query_lower.len > path.len) return false;

    var i: usize = 0;
    const end = path.len - query_lower.len;
    while (i <= end) : (i += 1) {
        var match = true;
        for (query_lower, 0..) |q_char, j| {
            const pc = std.ascii.toLower(path[i + j]);
            if (q_char != pc) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn startTextInput(window: ?*c.SDL_Window) void {
    if (window) |win| {
        if (!c.SDL_StartTextInput(win)) {
            std.log.err("SDL_StartTextInput failed: {s}", .{c.SDL_GetError()});
        }
    }
}

fn stopTextInput(window: ?*c.SDL_Window) void {
    if (window) |win| {
        if (!c.SDL_StopTextInput(win)) {
            std.log.err("SDL_StopTextInput failed: {s}", .{c.SDL_GetError()});
        }
    }
}

const AppActionId = enum {
    next_image,
    prev_image,
    toggle_stats,
    toggle_fullscreen,
    open_file_finder,
    toggle_debug_mode,
    exit,
    first_image,
    last_image,
    zoom_in,
    zoom_out,
    reset_zoom,
    set_scale_none,
    set_scale_shrink,
    set_scale_full,
    set_scale_crop,
    rotate_cw,
    rotate_ccw,
    reset_rotation,
    set_filter_nearest,
    set_filter_linear,
    set_filter_pixel_art,
    increase_brightness,
    decrease_brightness,
    increase_contrast,
    decrease_contrast,
    reset_adjustments,
    set_brightness_value,
    set_contrast_value,
    go_to_image,
};

const AppAction = struct {
    name: []const u8,
    shortcut: []const u8,
    id: AppActionId,
};

const app_actions = [_]AppAction{
    .{ .name = "Next Image", .shortcut = "Right / Space", .id = .next_image },
    .{ .name = "Previous Image", .shortcut = "Left / Backspace", .id = .prev_image },
    .{ .name = "Zoom In", .shortcut = "= / +", .id = .zoom_in },
    .{ .name = "Zoom Out", .shortcut = "-", .id = .zoom_out },
    .{ .name = "Reset Zoom & Pan", .shortcut = "R / 0", .id = .reset_zoom },
    .{ .name = "Set Scale Mode: 100% (Actual Size)", .shortcut = "", .id = .set_scale_none },
    .{ .name = "Set Scale Mode: Fit if Larger (Shrink)", .shortcut = "", .id = .set_scale_shrink },
    .{ .name = "Set Scale Mode: Fit Window (Full)", .shortcut = "", .id = .set_scale_full },
    .{ .name = "Set Scale Mode: Fill Window (Crop)", .shortcut = "", .id = .set_scale_crop },
    .{ .name = "Rotate Clockwise (90°)", .shortcut = "]", .id = .rotate_cw },
    .{ .name = "Rotate Counter-Clockwise (90°)", .shortcut = "[", .id = .rotate_ccw },
    .{ .name = "Reset Rotation", .shortcut = "", .id = .reset_rotation },
    .{ .name = "Set Scaling Filter: Nearest Neighbor", .shortcut = "", .id = .set_filter_nearest },
    .{ .name = "Set Scaling Filter: Bilinear (Smooth)", .shortcut = "", .id = .set_filter_linear },
    .{ .name = "Set Scaling Filter: Pixel Art (Crisp)", .shortcut = "", .id = .set_filter_pixel_art },
    .{ .name = "Increase Brightness (+10%)", .shortcut = "P", .id = .increase_brightness },
    .{ .name = "Decrease Brightness (-10%)", .shortcut = "O", .id = .decrease_brightness },
    .{ .name = "Increase Contrast (+10%)", .shortcut = "L", .id = .increase_contrast },
    .{ .name = "Decrease Contrast (-10%)", .shortcut = "K", .id = .decrease_contrast },
    .{ .name = "Reset Brightness & Contrast", .shortcut = "Shift+R", .id = .reset_adjustments },
    .{ .name = "Set Brightness (Type Value)...", .shortcut = "Shift+B", .id = .set_brightness_value },
    .{ .name = "Set Contrast (Type Value)...", .shortcut = "Shift+C", .id = .set_contrast_value },
    .{ .name = "Go to Image...", .shortcut = "Shift+G", .id = .go_to_image },
    .{ .name = "Toggle Stats for Nerds", .shortcut = "I", .id = .toggle_stats },
    .{ .name = "Toggle Fullscreen", .shortcut = "F / F11", .id = .toggle_fullscreen },
    .{ .name = "Search Files (Go to File)", .shortcut = "Ctrl+P", .id = .open_file_finder },
    .{ .name = "Toggle Clay Debug Mode", .shortcut = "D", .id = .toggle_debug_mode },
    .{ .name = "First Image", .shortcut = "Home", .id = .first_image },
    .{ .name = "Last Image", .shortcut = "End", .id = .last_image },
    .{ .name = "Exit Application", .shortcut = "Esc", .id = .exit },
};

pub const PaletteType = enum {
    files,
    actions,
    set_brightness,
    set_contrast,
    go_to_image,
};

pub const PaletteState = struct {
    show: bool = false,
    active_type: PaletteType = .files,
    query: std.ArrayList(u8),
    selected_idx: usize = 0,
    selection_dirty: bool = false,
    matches: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PaletteState {
        return .{
            .query = std.ArrayList(u8).empty,
            .matches = std.ArrayList(usize).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PaletteState) void {
        self.query.deinit(self.allocator);
        self.matches.deinit(self.allocator);
    }

    pub fn reset(self: *PaletteState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.selected_idx = 0;
        self.selection_dirty = true;
    }
};

pub const ScaleMode = enum {
    none,
    shrink,
    full,
    crop,
};

pub const TextureScaleMode = enum {
    nearest,
    linear,
    pixel_art,
};
pub const ElementTag = enum(usize) {
    none = 0,
    drop_zone_box = 1337,

    pub fn fromInt(val: usize) ElementTag {
        inline for (std.meta.tags(ElementTag)) |tag| {
            if (val == @intFromEnum(tag)) {
                return tag;
            }
        }
        return .none;
    }
};

const ViewerState = struct {
    gpu_device: ?*c.SDL_GPUDevice = null,
    gpu_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    gpu_sampler: ?*c.SDL_GPUSampler = null,
    white_texture: ?*c.SDL_GPUTexture = null,
    gpu_text_engine: ?*c.TTF_TextEngine = null,
    image_list: std.ArrayList([]const u8),
    current_index: ?usize = null,
    cache: std.ArrayList(CacheEntry),
    cache_mutex: *c.SDL_Mutex,
    current_image_cache_hit: bool = false,
    allocator: std.mem.Allocator,
    io: std.Io,
    active_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    exiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: usize = 0,
    window_pixel_format: c.SDL_PixelFormat = c.SDL_PIXELFORMAT_UNKNOWN,
    palette: PaletteState,
    window: ?*c.SDL_Window,
    is_fullscreen: bool = false,
    running: bool = true,
    show_stats_overlay: bool = false,
    scale_mode: ScaleMode = .full,
    zoom_factor: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    rotation_angle: f32 = 0.0,
    rotation_map: std.StringHashMap(f32),
    texture_scale_mode: TextureScaleMode = .linear,
    brightness: f32 = 0.0,
    contrast: f32 = 1.0,
    adjustments_dirty: bool = false,
    stats_offset_x: f32 = 20.0,
    stats_offset_y: f32 = 20.0,
    stats_dragging: bool = false,
    drag_start_x: f32 = 0.0,
    drag_start_y: f32 = 0.0,
    viewport_dragging: bool = false,
    drag_last_x: f32 = 0.0,
    drag_last_y: f32 = 0.0,
    mouse_inside: bool = true,

    pub fn deinit(self: *ViewerState) void {
        self.exiting.store(true, .release);
        while (self.active_threads.load(.acquire) > 0) {
            c.SDL_Delay(1);
        }

        self.clearCache();

        if (self.gpu_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(self.gpu_device, pipeline);
        if (self.gpu_sampler) |sampler| c.SDL_ReleaseGPUSampler(self.gpu_device, sampler);
        if (self.white_texture) |white_tex| c.SDL_ReleaseGPUTexture(self.gpu_device, white_tex);
        if (self.gpu_text_engine) |engine| c.TTF_DestroyGPUTextEngine(engine);
        if (self.window) |w| c.SDL_ReleaseWindowFromGPUDevice(self.gpu_device, w);

        c.SDL_DestroyMutex(self.cache_mutex);
        for (self.image_list.items) |item| {
            self.allocator.free(item);
        }
        self.image_list.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.palette.deinit();
        self.rotation_map.deinit();
    }

    pub fn resetZoomPan(self: *ViewerState) void {
        self.zoom_factor = 1.0;
        self.pan_x = 0.0;
        self.pan_y = 0.0;
    }

    pub fn update(self: *ViewerState, input: FrameInput, gpa: std.mem.Allocator) !void {
        // 1. Text input updates
        if (input.text_input) |text| {
            if (self.palette.show) {
                try self.palette.query.appendSlice(gpa, text);
                self.palette.selected_idx = 0;
                self.palette.selection_dirty = true;
                switch (self.palette.active_type) {
                    .files => try self.rebuildPaletteMatches(),
                    .actions => try self.rebuildActionMatches(),
                    .set_brightness, .set_contrast, .go_to_image => {},
                }
            }
        }

        // 2. Drop file/directory updates
        if (input.dropped_path) |path| {
            try self.handlePathSelection(path);
        }

        // 3. Mouse dragging updates
        if (self.show_stats_overlay and self.stats_dragging) {
            if (input.mouse_left_down) {
                self.stats_offset_x = input.mouse_x - self.drag_start_x;
                self.stats_offset_y = input.mouse_y - self.drag_start_y;
            } else {
                self.stats_dragging = false;
            }
        } else if (self.viewport_dragging) {
            if (input.mouse_left_down) {
                self.pan_x += input.mouse_x - self.drag_last_x;
                self.pan_y += input.mouse_y - self.drag_last_y;
                self.drag_last_x = input.mouse_x;
                self.drag_last_y = input.mouse_y;
            } else {
                self.viewport_dragging = false;
            }
        }

        // 4. Mouse click triggers (starts dragging)
        if (input.mouse_left_clicked) {
            // Check if we should close the palette
            if (self.palette.show) {
                const element_id = switch (self.palette.active_type) {
                    .files => "CommandPalette",
                    .actions => "ActionPalette",
                    .set_brightness => "BrightnessPalette",
                    .set_contrast => "ContrastPalette",
                    .go_to_image => "GoToImagePalette",
                };
                if (!clay.pointerOver(clay.getElementId(element_id))) {
                    self.palette.show = false;
                    stopTextInput(self.window);
                }
            }

            if (self.show_stats_overlay and
                clay.pointerOver(clay.getElementId("StatsPanel")) and
                !clay.pointerOver(clay.getElementId("StatsCloseBtn")))
            {
                self.stats_dragging = true;
                self.drag_start_x = input.mouse_x - self.stats_offset_x;
                self.drag_start_y = input.mouse_y - self.stats_offset_y;
            } else if (!self.palette.show and clay.pointerOver(clay.getElementId("Viewport"))) {
                self.viewport_dragging = true;
                self.drag_last_x = input.mouse_x;
                self.drag_last_y = input.mouse_y;
            }
        }

        // 5. Mouse Wheel Zoom updates
        if (input.scroll_delta_y != 0) {
            if (!self.palette.show and clay.pointerOver(clay.getElementId("Viewport"))) {
                const old_zoom = self.zoom_factor;
                self.zoom_factor = std.math.clamp(self.zoom_factor + input.scroll_delta_y * 0.1, 0.1, 10.0);

                const available_width = if (clay.isDebugModeEnabled()) @max(input.pix_w - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0) else input.pix_w;
                const cx = available_width / 2.0;
                var title_bar_h: f32 = 60.0;
                if (self.is_fullscreen) {
                    title_bar_h = 0;
                }
                const cy = (title_bar_h * input.scale_y) + ((input.pix_h - title_bar_h * input.scale_y) / 2.0);

                const rel_x = input.mouse_x - cx;
                const rel_y = input.mouse_y - cy;

                self.pan_x = rel_x - (rel_x - self.pan_x) * (self.zoom_factor / old_zoom);
                self.pan_y = rel_y - (rel_y - self.pan_y) * (self.zoom_factor / old_zoom);
            }
        }

        // 6. Keyboard updates
        for (input.keys_pressed.items) |key| {
            try self.handleKeyDown(key, input.key_modifiers, input.scale_x, input.scale_y);
        }
    }

    fn getSdlScaleMode(self: *ViewerState) c.SDL_ScaleMode {
        return switch (self.texture_scale_mode) {
            .nearest => c.SDL_SCALEMODE_NEAREST,
            .linear => c.SDL_SCALEMODE_LINEAR,
            .pixel_art => c.SDL_SCALEMODE_PIXELART,
        };
    }

    fn applyTextureScaleMode(self: *ViewerState) void {
        const filter = if (self.texture_scale_mode == .linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST;
        if (self.gpu_sampler) |old_sampler| {
            c.SDL_ReleaseGPUSampler(self.gpu_device, old_sampler);
        }

        const sampler_info = c.SDL_GPUSamplerCreateInfo{
            .min_filter = @intCast(filter),
            .mag_filter = @intCast(filter),
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 1.0,
            .compare_op = c.SDL_GPU_COMPAREOP_NEVER,
            .min_lod = 0.0,
            .max_lod = 0.0,
            .props = 0,
        };
        self.gpu_sampler = c.SDL_CreateGPUSampler(self.gpu_device, &sampler_info) orelse {
            std.log.err("Failed to recreate GPU sampler: {s}", .{c.SDL_GetError()});
            return;
        };
    }

    fn rebuildPaletteMatches(self: *ViewerState) !void {
        self.palette.matches.clearRetainingCapacity();
        const query = self.palette.query.items;
        if (query.len == 0) {
            for (self.image_list.items, 0..) |_, real_idx| {
                try self.palette.matches.append(self.allocator, real_idx);
            }
            return;
        }

        var stack_query_lower: [256]u8 = undefined;
        const query_lower = if (query.len <= stack_query_lower.len) blk: {
            for (query, 0..) |c_val, idx| {
                stack_query_lower[idx] = std.ascii.toLower(c_val);
            }
            break :blk stack_query_lower[0..query.len];
        } else blk: {
            const mem = try self.allocator.alloc(u8, query.len);
            for (query, 0..) |c_val, idx| {
                mem[idx] = std.ascii.toLower(c_val);
            }
            break :blk mem;
        };
        defer if (query.len > stack_query_lower.len) self.allocator.free(query_lower);

        for (self.image_list.items, 0..) |item, real_idx| {
            if (matchesQueryLower(item, query_lower)) {
                try self.palette.matches.append(self.allocator, real_idx);
            }
        }
    }

    fn rebuildActionMatches(self: *ViewerState) !void {
        self.palette.matches.clearRetainingCapacity();
        const query = self.palette.query.items;
        if (query.len == 0) {
            for (app_actions, 0..) |_, idx| {
                try self.palette.matches.append(self.allocator, idx);
            }
            return;
        }

        var stack_query_lower: [256]u8 = undefined;
        const query_lower = if (query.len <= stack_query_lower.len) blk: {
            for (query, 0..) |c_val, idx| {
                stack_query_lower[idx] = std.ascii.toLower(c_val);
            }
            break :blk stack_query_lower[0..query.len];
        } else blk: {
            const mem = try self.allocator.alloc(u8, query.len);
            for (query, 0..) |c_val, idx| {
                mem[idx] = std.ascii.toLower(c_val);
            }
            break :blk mem;
        };
        defer if (query.len > stack_query_lower.len) self.allocator.free(query_lower);

        for (app_actions, 0..) |item, idx| {
            if (matchesQueryLower(item.name, query_lower)) {
                try self.palette.matches.append(self.allocator, idx);
            }
        }
    }

    fn triggerAction(self: *ViewerState, action_id: AppActionId) !void {
        switch (action_id) {
            .next_image => try self.next(),
            .prev_image => try self.prev(),
            .toggle_stats => self.show_stats_overlay = !self.show_stats_overlay,
            .toggle_fullscreen => {
                self.is_fullscreen = !self.is_fullscreen;
                if (!c.SDL_SetWindowFullscreen(self.window, self.is_fullscreen)) {
                    std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
                }
            },
            .open_file_finder => {
                self.palette.show = true;
                self.palette.active_type = .files;
                self.palette.query.clearRetainingCapacity();
                self.palette.selected_idx = self.current_index orelse 0;
                self.palette.selection_dirty = true;
                try self.rebuildPaletteMatches();
                startTextInput(self.window);
            },
            .toggle_debug_mode => clay.setDebugModeEnabled(!clay.isDebugModeEnabled()),
            .exit => self.running = false,
            .first_image => {
                if (self.image_list.items.len > 0) {
                    self.current_index = 0;
                    try self.updateCache();
                }
            },
            .last_image => {
                if (self.image_list.items.len > 0) {
                    self.current_index = self.image_list.items.len - 1;
                    try self.updateCache();
                }
            },
            .zoom_in => {
                const old_zoom = self.zoom_factor;
                self.zoom_factor = std.math.clamp(self.zoom_factor + 0.5, 0.1, 10.0);
                self.pan_x *= (self.zoom_factor / old_zoom);
                self.pan_y *= (self.zoom_factor / old_zoom);
            },
            .zoom_out => {
                const old_zoom = self.zoom_factor;
                self.zoom_factor = std.math.clamp(self.zoom_factor - 0.5, 0.1, 10.0);
                self.pan_x *= (self.zoom_factor / old_zoom);
                self.pan_y *= (self.zoom_factor / old_zoom);
            },
            .reset_zoom => {
                self.resetZoomPan();
            },
            .set_scale_none => {
                self.scale_mode = .none;
                self.resetZoomPan();
            },
            .set_scale_shrink => {
                self.scale_mode = .shrink;
                self.resetZoomPan();
            },
            .set_scale_full => {
                self.scale_mode = .full;
                self.resetZoomPan();
            },
            .set_scale_crop => {
                self.scale_mode = .crop;
                self.resetZoomPan();
            },
            .rotate_cw => {
                self.rotation_angle = @mod(self.rotation_angle + 90.0, 360.0);
                if (self.current_index) |idx| {
                    if (idx < self.image_list.items.len) {
                        const path = self.image_list.items[idx];
                        try self.rotation_map.put(path, self.rotation_angle);
                    }
                }
            },
            .rotate_ccw => {
                self.rotation_angle = @mod(self.rotation_angle - 90.0 + 360.0, 360.0);
                if (self.current_index) |idx| {
                    if (idx < self.image_list.items.len) {
                        const path = self.image_list.items[idx];
                        try self.rotation_map.put(path, self.rotation_angle);
                    }
                }
            },
            .reset_rotation => {
                self.rotation_angle = 0.0;
                if (self.current_index) |idx| {
                    if (idx < self.image_list.items.len) {
                        const path = self.image_list.items[idx];
                        try self.rotation_map.put(path, self.rotation_angle);
                    }
                }
            },
            .set_filter_nearest => {
                self.texture_scale_mode = .nearest;
                self.applyTextureScaleMode();
            },
            .set_filter_linear => {
                self.texture_scale_mode = .linear;
                self.applyTextureScaleMode();
            },
            .set_filter_pixel_art => {
                self.texture_scale_mode = .pixel_art;
                self.applyTextureScaleMode();
            },
            .increase_brightness => {
                self.brightness = std.math.clamp(self.brightness + 0.1, -1.0, 1.0);
                self.adjustments_dirty = true;
            },
            .decrease_brightness => {
                self.brightness = std.math.clamp(self.brightness - 0.1, -1.0, 1.0);
                self.adjustments_dirty = true;
            },
            .increase_contrast => {
                self.contrast = std.math.clamp(self.contrast + 0.1, 0.0, 5.0);
                self.adjustments_dirty = true;
            },
            .decrease_contrast => {
                self.contrast = std.math.clamp(self.contrast - 0.1, 0.0, 5.0);
                self.adjustments_dirty = true;
            },
            .reset_adjustments => {
                self.brightness = 0.0;
                self.contrast = 1.0;
                self.adjustments_dirty = true;
            },
            .set_brightness_value => {
                self.palette.show = true;
                self.palette.active_type = .set_brightness;
                self.palette.query.clearRetainingCapacity();
                self.palette.selected_idx = 0;
                self.palette.selection_dirty = true;
                startTextInput(self.window);
            },
            .set_contrast_value => {
                self.palette.show = true;
                self.palette.active_type = .set_contrast;
                self.palette.query.clearRetainingCapacity();
                self.palette.selected_idx = 0;
                self.palette.selection_dirty = true;
                startTextInput(self.window);
            },
            .go_to_image => {
                self.palette.show = true;
                self.palette.active_type = .go_to_image;
                self.palette.query.clearRetainingCapacity();
                self.palette.selected_idx = 0;
                self.palette.selection_dirty = true;
                startTextInput(self.window);
            },
        }
    }

    fn getCurrentEntry(self: *ViewerState) ?CacheEntry {
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);

        const idx = self.current_index orelse return null;
        for (self.cache.items) |entry| {
            if (entry.index == idx) {
                return entry;
            }
        }
        return null;
    }

    fn prepareCacheTextures(self: *ViewerState) void {
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);

        for (self.cache.items) |*entry| {
            if (entry.status == .loaded and entry.surface != null) {
                if (entry.gpu_texture == null) {
                    const start_upload = c.SDL_GetTicksNS();
                    var current_surf = entry.surface.?;
                    var scaled_surf: ?*c.SDL_Surface = null;
                    defer if (scaled_surf) |s| c.SDL_DestroySurface(s);

                    var img_w = current_surf.*.w;
                    var img_h = current_surf.*.h;
                    var tex: ?*c.SDL_GPUTexture = null;

                    var try_max_dim: i32 = 16384;
                    while (try_max_dim >= 2048) : (try_max_dim = @divTrunc(try_max_dim, 2)) {
                        if (img_w <= try_max_dim and img_h <= try_max_dim) {
                            const img_tex_info = c.SDL_GPUTextureCreateInfo{
                                .type = c.SDL_GPU_TEXTURETYPE_2D,
                                .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                                .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                                .width = @intCast(img_w),
                                .height = @intCast(img_h),
                                .layer_count_or_depth = 1,
                                .num_levels = 1,
                                .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
                                .props = 0,
                            };
                            tex = c.SDL_CreateGPUTexture(self.gpu_device, &img_tex_info);
                            if (tex != null) break;
                        }

                        const next_dim = @divTrunc(try_max_dim, 2);
                        if (img_w > next_dim or img_h > next_dim) {
                            var new_w = img_w;
                            var new_h = img_h;
                            if (img_w > img_h) {
                                new_w = next_dim;
                                new_h = @divTrunc(img_h * next_dim, img_w);
                            } else {
                                new_h = next_dim;
                                new_w = @divTrunc(img_w * next_dim, img_h);
                            }
                            new_w = @max(1, new_w);
                            new_h = @max(1, new_h);

                            const new_scale = c.SDL_ScaleSurface(
                                current_surf,
                                new_w,
                                new_h,
                                c.SDL_SCALEMODE_LINEAR,
                            );
                            if (new_scale) |ns| {
                                if (scaled_surf) |s| c.SDL_DestroySurface(s);
                                scaled_surf = ns;
                                current_surf = ns;
                                img_w = new_w;
                                img_h = new_h;
                            } else {
                                std.log.err("SDL_ScaleSurface failed: {s}", .{c.SDL_GetError()});
                                break;
                            }
                        }
                    }

                    if (tex == null) {
                        std.log.err("Create GPU Texture failed for image size {d}x{d}: {s}", .{ entry.surface.?.*.w, entry.surface.?.*.h, c.SDL_GetError() });
                        continue;
                    }
                    const gpu_tex = tex.?;

                    const cmd_buf = c.SDL_AcquireGPUCommandBuffer(self.gpu_device) orelse {
                        c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                        continue;
                    };
                    const size = @as(usize, @intCast(img_w)) * @as(usize, @intCast(img_h)) * 4;
                    const transfer_buf = c.SDL_CreateGPUTransferBuffer(self.gpu_device, &c.SDL_GPUTransferBufferCreateInfo{
                        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                        .size = @intCast(size),
                        .props = 0,
                    }) orelse {
                        std.log.err("Create transfer buffer failed: {s}", .{c.SDL_GetError()});
                        _ = c.SDL_CancelGPUCommandBuffer(cmd_buf);
                        c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                        continue;
                    };
                    defer c.SDL_ReleaseGPUTransferBuffer(self.gpu_device, transfer_buf);

                    const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.gpu_device, transfer_buf, false) orelse {
                        _ = c.SDL_CancelGPUCommandBuffer(cmd_buf);
                        c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                        continue;
                    });
                    const pixels: [*]const u8 = @ptrCast(current_surf.*.pixels);
                    @memcpy(mapped[0..size], pixels[0..size]);
                    c.SDL_UnmapGPUTransferBuffer(self.gpu_device, transfer_buf);

                    const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
                        _ = c.SDL_CancelGPUCommandBuffer(cmd_buf);
                        c.SDL_ReleaseGPUTexture(self.gpu_device, gpu_tex);
                        continue;
                    };
                    c.SDL_UploadToGPUTexture(copy_pass, &c.SDL_GPUTextureTransferInfo{
                        .transfer_buffer = transfer_buf,
                        .offset = 0,
                        .pixels_per_row = @intCast(img_w),
                        .rows_per_layer = @intCast(img_h),
                    }, &c.SDL_GPUTextureRegion{
                        .texture = gpu_tex,
                        .w = @intCast(img_w),
                        .h = @intCast(img_h),
                        .d = 1,
                    }, false);
                    c.SDL_EndGPUCopyPass(copy_pass);
                    _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);

                    entry.gpu_texture = gpu_tex;
                    c.SDL_DestroySurface(entry.surface.?);
                    entry.surface = null;

                    const end_upload = c.SDL_GetTicksNS();
                    entry.upload_time_ms = @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;
                }
            }
        }
        if (self.adjustments_dirty) {
            self.adjustments_dirty = false;
        }
    }

    fn clearCache(self: *ViewerState) void {
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);

        for (self.cache.items) |entry| {
            if (entry.gpu_texture) |tex| {
                c.SDL_ReleaseGPUTexture(self.gpu_device, tex);
            }
            if (entry.surface) |surf| {
                c.SDL_DestroySurface(surf);
            }
        }
        self.cache.clearRetainingCapacity();
    }

    fn updateCache(self: *ViewerState) !void {
        self.resetZoomPan();
        const current_idx = self.current_index;
        if (current_idx != null and current_idx.? < self.image_list.items.len) {
            const path = self.image_list.items[current_idx.?];
            self.rotation_angle = self.rotation_map.get(path) orelse 0.0;
        } else {
            self.rotation_angle = 0.0;
        }
        c.SDL_LockMutex(self.cache_mutex);
        defer c.SDL_UnlockMutex(self.cache_mutex);

        const len = self.image_list.items.len;
        if (len == 0) return;

        const idx = self.current_index orelse return;

        // 1. Gather desired indices
        var desired_count: usize = 0;
        var desired: [5]usize = undefined;
        for ([_]usize{
            idx,
            (idx + 1) % len,
            (idx + 2) % len,
            (idx + (len - 1)) % len,
            (idx + (len - 2)) % len,
        }) |d| {
            var unique = true;
            for (desired[0..desired_count]) |existing| {
                if (existing == d) {
                    unique = false;
                    break;
                }
            }
            if (unique) {
                desired[desired_count] = d;
                desired_count += 1;
            }
        }

        // 2. Evict cache entries that are no longer wanted
        var i: usize = 0;
        while (i < self.cache.items.len) {
            const entry = &self.cache.items[i];
            var wanted = false;
            for (desired[0..desired_count]) |d| {
                if (entry.index == d) {
                    wanted = true;
                    break;
                }
            }
            if (!wanted) {
                // Evict
                if (entry.gpu_texture) |tex| {
                    c.SDL_ReleaseGPUTexture(self.gpu_device, tex);
                }
                if (entry.surface) |surf| {
                    c.SDL_DestroySurface(surf);
                }
                _ = self.cache.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // 3. Add wanted entries that are not in the cache yet
        var hit = false;
        for (desired[0..desired_count]) |d| {
            var exists = false;
            for (self.cache.items) |entry| {
                if (entry.index == d) {
                    exists = true;
                    if (d == idx and entry.status == .loaded) {
                        hit = true;
                    }
                    break;
                }
            }
            if (!exists) {
                const path = try self.allocator.dupeZ(u8, self.image_list.items[d]);
                errdefer self.allocator.free(path);

                const new_entry = CacheEntry{
                    .index = d,
                    .generation = self.generation,
                    .status = .decoding,
                };
                try self.cache.append(self.allocator, new_entry);
                errdefer _ = self.cache.pop();

                // Spawn worker thread
                const args = try self.allocator.create(DecodeArgs);
                errdefer self.allocator.destroy(args);

                args.* = DecodeArgs{
                    .state = self,
                    .index = d,
                    .generation = self.generation,
                    .path = path,
                };

                _ = self.active_threads.fetchAdd(1, .monotonic);
                const thread = c.SDL_CreateThread(decodeWorker, "decode_worker", args);
                if (thread) |t| {
                    c.SDL_DetachThread(t);
                } else {
                    std.log.err("Failed to create SDL thread: {s}", .{c.SDL_GetError()});
                    _ = self.active_threads.fetchSub(1, .monotonic);
                    self.allocator.free(path);
                    self.allocator.destroy(args);
                    _ = self.cache.pop();
                }
            }
        }
        self.current_image_cache_hit = hit;
    }

    fn next(self: *ViewerState) !void {
        if (self.image_list.items.len == 0) return;
        if (self.current_index) |idx| {
            self.current_index = (idx + 1) % self.image_list.items.len;
        } else {
            self.current_index = 0;
        }
        try self.updateCache();
    }

    fn prev(self: *ViewerState) !void {
        if (self.image_list.items.len == 0) return;
        if (self.current_index) |idx| {
            if (idx == 0) {
                self.current_index = self.image_list.items.len - 1;
            } else {
                self.current_index = idx - 1;
            }
        } else {
            self.current_index = 0;
        }
        try self.updateCache();
    }

    fn handlePathSelection(self: *ViewerState, path: []const u8) !void {
        // Clear existing list
        for (self.image_list.items) |item| {
            self.allocator.free(item);
        }
        self.image_list.clearRetainingCapacity();
        self.rotation_map.clearRetainingCapacity();

        self.generation += 1;
        self.clearCache();
        self.current_index = null;

        var stat: std.Io.File.Stat = undefined;
        var has_stat = true;
        if (std.Io.Dir.statFile(std.Io.Dir.cwd(), self.io, path, .{})) |s| {
            stat = s;
        } else |err| {
            std.log.err("Failed to access path '{s}': {}", .{ path, err });
            has_stat = false;
        }

        if (has_stat) {
            if (stat.kind == .directory) {
                try scanDirectory(self.allocator, self.io, path, &self.image_list);
                if (self.image_list.items.len > 0) {
                    self.current_index = 0;
                    try self.updateCache();
                }
            } else {
                const dir_path = std.fs.path.dirname(path) orelse ".";
                try scanDirectory(self.allocator, self.io, dir_path, &self.image_list);

                var found_idx: ?usize = null;
                for (self.image_list.items, 0..) |item, i| {
                    if (std.mem.eql(u8, item, path)) {
                        found_idx = i;
                        break;
                    }
                }

                if (found_idx) |idx| {
                    self.current_index = idx;
                } else {
                    const dup = try self.allocator.dupe(u8, path);
                    errdefer self.allocator.free(dup);
                    try self.image_list.append(self.allocator, dup);
                    self.current_index = self.image_list.items.len - 1;
                }
                try self.updateCache();
            }
        }
        try self.rebuildPaletteMatches();
    }

    pub fn handlePaletteKeys(
        self: *ViewerState,
        key: c.SDL_Keycode,
    ) !bool {
        const palette = &self.palette;
        if (!palette.show) return false;

        switch (key) {
            c.SDLK_ESCAPE => {
                palette.show = false;
                stopTextInput(self.window);
                return true;
            },
            c.SDLK_UP => {
                if (palette.active_type == .set_brightness or palette.active_type == .set_contrast or palette.active_type == .go_to_image) return true;
                if (palette.selected_idx > 0) {
                    palette.selected_idx -= 1;
                    palette.selection_dirty = true;
                }
                return true;
            },
            c.SDLK_DOWN => {
                if (palette.active_type == .set_brightness or palette.active_type == .set_contrast or palette.active_type == .go_to_image) return true;
                const count = palette.matches.items.len;
                if (count > 0 and palette.selected_idx + 1 < count) {
                    palette.selected_idx += 1;
                    palette.selection_dirty = true;
                }
                return true;
            },
            c.SDLK_RETURN => {
                if (palette.active_type == .set_brightness or palette.active_type == .set_contrast or palette.active_type == .go_to_image) {
                    const raw_str = palette.query.items;
                    if (raw_str.len > 0) {
                        if (palette.active_type == .go_to_image) {
                            const val = std.fmt.parseInt(usize, raw_str, 10) catch null;
                            if (val) |v| {
                                if (v >= 1 and v <= self.image_list.items.len) {
                                    self.current_index = v - 1;
                                    try self.updateCache();
                                    palette.show = false;
                                    stopTextInput(self.window);
                                    return true;
                                }
                            }
                        } else {
                            const parsed_val_opt = std.fmt.parseFloat(f32, raw_str) catch null;
                            if (parsed_val_opt) |val| {
                                const min_val: f32 = if (palette.active_type == .set_brightness) -1.0 else 0.0;
                                const max_val: f32 = if (palette.active_type == .set_brightness) 1.0 else 5.0;
                                if (val >= min_val and val <= max_val) {
                                    if (palette.active_type == .set_brightness) {
                                        self.brightness = val;
                                    } else {
                                        self.contrast = val;
                                    }
                                    self.adjustments_dirty = true;
                                    palette.show = false;
                                    stopTextInput(self.window);
                                    return true;
                                }
                            }
                        }
                    }
                    return true; // Keep open on invalid inputs
                } else {
                    if (palette.selected_idx < palette.matches.items.len) {
                        const target_idx = palette.matches.items[palette.selected_idx];
                        const old_type = palette.active_type;
                        switch (palette.active_type) {
                            .files => {
                                self.current_index = target_idx;
                                try self.updateCache();
                                palette.show = false;
                                stopTextInput(self.window);
                            },
                            .actions => {
                                const action = app_actions[target_idx];
                                try self.triggerAction(action.id);
                                if (palette.active_type == old_type) {
                                    palette.show = false;
                                    stopTextInput(self.window);
                                }
                            },
                            else => {},
                        }
                    } else {
                        palette.show = false;
                        stopTextInput(self.window);
                    }
                    return true;
                }
            },
            c.SDLK_BACKSPACE => {
                if (palette.query.items.len > 0) {
                    _ = palette.query.pop();
                    palette.selected_idx = 0;
                    palette.selection_dirty = true;
                    switch (palette.active_type) {
                        .files => try self.rebuildPaletteMatches(),
                        .actions => try self.rebuildActionMatches(),
                        else => {},
                    }
                }
                return true;
            },
            else => return false,
        }
    }

    fn handleKeyDown(self: *ViewerState, key: c.SDL_Keycode, mod: c.SDL_Keymod, scale_x: f32, scale_y: f32) !void {
        if (self.palette.show) {
            _ = try self.handlePaletteKeys(key);
        } else {
            switch (key) {
                c.SDLK_LEFT => {
                    if (self.zoom_factor > 1.0) {
                        self.pan_x += 30.0 * scale_x;
                    } else {
                        try self.prev();
                    }
                },
                c.SDLK_RIGHT => {
                    if (self.zoom_factor > 1.0) {
                        self.pan_x -= 30.0 * scale_x;
                    } else {
                        try self.next();
                    }
                },
                c.SDLK_UP => {
                    if (self.zoom_factor > 1.0) {
                        self.pan_y += 30.0 * scale_y;
                    }
                },
                c.SDLK_DOWN => {
                    if (self.zoom_factor > 1.0) {
                        self.pan_y -= 30.0 * scale_y;
                    }
                },
                c.SDLK_BACKSPACE => try self.prev(),
                c.SDLK_SPACE => try self.next(),
                c.SDLK_R, c.SDLK_0, c.SDLK_KP_0 => {
                    if ((mod & c.SDL_KMOD_SHIFT) != 0) {
                        try self.triggerAction(.reset_adjustments);
                    } else {
                        self.resetZoomPan();
                    }
                },
                c.SDLK_EQUALS, c.SDLK_KP_PLUS => {
                    const old_zoom = self.zoom_factor;
                    self.zoom_factor = std.math.clamp(self.zoom_factor + 0.1, 0.1, 10.0);
                    self.pan_x *= (self.zoom_factor / old_zoom);
                    self.pan_y *= (self.zoom_factor / old_zoom);
                },
                c.SDLK_MINUS, c.SDLK_KP_MINUS => {
                    const old_zoom = self.zoom_factor;
                    self.zoom_factor = std.math.clamp(self.zoom_factor - 0.1, 0.1, 10.0);
                    self.pan_x *= (self.zoom_factor / old_zoom);
                    self.pan_y *= (self.zoom_factor / old_zoom);
                },
                c.SDLK_HOME => {
                    if (self.image_list.items.len > 0) {
                        self.current_index = 0;
                        try self.updateCache();
                    }
                },
                c.SDLK_END => {
                    if (self.image_list.items.len > 0) {
                        self.current_index = self.image_list.items.len - 1;
                        try self.updateCache();
                    }
                },
                c.SDLK_F, c.SDLK_F11 => {
                    self.is_fullscreen = !self.is_fullscreen;
                    if (!c.SDL_SetWindowFullscreen(self.window, self.is_fullscreen)) {
                        std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
                    }
                },
                c.SDLK_ESCAPE => {
                    if (self.is_fullscreen) {
                        self.is_fullscreen = false;
                        if (!c.SDL_SetWindowFullscreen(self.window, false)) {
                            std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
                        }
                    } else {
                        self.running = false;
                    }
                },
                c.SDLK_LEFTBRACKET => {
                    try self.triggerAction(.rotate_ccw);
                },
                c.SDLK_RIGHTBRACKET => {
                    try self.triggerAction(.rotate_cw);
                },
                c.SDLK_D => {
                    clay.setDebugModeEnabled(!clay.isDebugModeEnabled());
                },
                c.SDLK_I => {
                    self.show_stats_overlay = !self.show_stats_overlay;
                },
                c.SDLK_F1 => {
                    self.palette.show = true;
                    self.palette.active_type = .actions;
                    self.palette.query.clearRetainingCapacity();
                    self.palette.selected_idx = 0;
                    self.palette.selection_dirty = true;
                    try self.rebuildActionMatches();
                    startTextInput(self.window);
                },
                c.SDLK_P => {
                    if (((mod & c.SDL_KMOD_CTRL) != 0) or ((mod & c.SDL_KMOD_GUI) != 0)) {
                        if ((mod & c.SDL_KMOD_SHIFT) != 0) {
                            self.palette.show = true;
                            self.palette.active_type = .actions;
                            self.palette.query.clearRetainingCapacity();
                            self.palette.selected_idx = 0;
                            self.palette.selection_dirty = true;
                            try self.rebuildActionMatches();
                            startTextInput(self.window);
                        } else {
                            self.palette.show = true;
                            self.palette.active_type = .files;
                            self.palette.query.clearRetainingCapacity();
                            self.palette.selected_idx = self.current_index orelse 0;
                            self.palette.selection_dirty = true;
                            try self.rebuildPaletteMatches();
                            startTextInput(self.window);
                        }
                    } else {
                        try self.triggerAction(.increase_brightness);
                    }
                },
                c.SDLK_O => {
                    try self.triggerAction(.decrease_brightness);
                },
                c.SDLK_L => {
                    try self.triggerAction(.increase_contrast);
                },
                c.SDLK_K => {
                    try self.triggerAction(.decrease_contrast);
                },
                c.SDLK_B => {
                    if ((mod & c.SDL_KMOD_SHIFT) != 0) {
                        try self.triggerAction(.set_brightness_value);
                    }
                },
                c.SDLK_C => {
                    if ((mod & c.SDL_KMOD_SHIFT) != 0) {
                        try self.triggerAction(.set_contrast_value);
                    }
                },
                c.SDLK_G => {
                    if ((mod & c.SDL_KMOD_SHIFT) != 0) {
                        try self.triggerAction(.go_to_image);
                    }
                },
                else => {},
            }
        }
    }
};

fn renderPalette(
    state: *ViewerState,
    scale_x: f32,
    scale_y: f32,
    dpi_scale: f32,
    mouse_clicked: bool,
    frame_allocator: std.mem.Allocator,
    measure_data: *const MeasureTextUserData,
) !void {
    const palette = &state.palette;
    if (!palette.show) return;

    const PaletteConfig = struct {
        title: []const u8,
        placeholder: []const u8,
        element_id: []const u8,
        list_id: []const u8,
        item_prefix: []const u8,
        top_spacer_id: []const u8,
        bottom_spacer_id: []const u8,
        base_item_height: f32,
    };

    const cfg = switch (palette.active_type) {
        .files => PaletteConfig{
            .title = "Search Files",
            .placeholder = "Type file name to search...",
            .element_id = "CommandPalette",
            .list_id = "CommandPaletteList",
            .item_prefix = "PaletteItem_",
            .top_spacer_id = "PaletteTopSpacer",
            .bottom_spacer_id = "PaletteBottomSpacer",
            .base_item_height = 58.0,
        },
        .actions => PaletteConfig{
            .title = "Command Palette",
            .placeholder = "Type a command to run...",
            .element_id = "ActionPalette",
            .list_id = "ActionPaletteList",
            .item_prefix = "ActionItem_",
            .top_spacer_id = "ActionTopSpacer",
            .bottom_spacer_id = "ActionBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_brightness => PaletteConfig{
            .title = "Set Brightness",
            .placeholder = "Enter brightness (-1.0 to 1.0, e.g. 0.2)...",
            .element_id = "BrightnessPalette",
            .list_id = "BrightnessPaletteList",
            .item_prefix = "BrightnessItem_",
            .top_spacer_id = "BrightnessTopSpacer",
            .bottom_spacer_id = "BrightnessBottomSpacer",
            .base_item_height = 50.0,
        },
        .set_contrast => PaletteConfig{
            .title = "Set Contrast",
            .placeholder = "Enter contrast (0.0 to 5.0, e.g. 1.5)...",
            .element_id = "ContrastPalette",
            .list_id = "ContrastPaletteList",
            .item_prefix = "ContrastItem_",
            .top_spacer_id = "ContrastTopSpacer",
            .bottom_spacer_id = "ContrastBottomSpacer",
            .base_item_height = 50.0,
        },
        .go_to_image => PaletteConfig{
            .title = "Go to Image",
            .placeholder = "Enter image number...",
            .element_id = "GoToImagePalette",
            .list_id = "GoToImageList",
            .item_prefix = "GoToImageItem_",
            .top_spacer_id = "GoToImageTopSpacer",
            .bottom_spacer_id = "GoToImageBottomSpacer",
            .base_item_height = 50.0,
        },
    };

    // Render Floating Card container
    clay.UI()(.{
        .id = clay.getElementId(cfg.element_id),
        .layout = .{
            .sizing = .{ .w = .fixed(550 * scale_x), .h = .fit },
            .direction = .top_to_bottom,
            .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 },
            .child_gap = 10,
        },
        .background_color = .{ 30, 30, 46, 245 }, // Catppuccin Base with opacity
        .corner_radius = .all(10),
        .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = .{ 79, 79, 97, 255 } },
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .center_center, .parent = .center_center },
            .z_index = 200,
        },
    })({
        // Title / Header
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
            },
        })({
            clay.text(cfg.title, .{
                .color = switch (palette.active_type) {
                    .files => clay.Color{ 245, 194, 231, 255 }, // Catppuccin Pink
                    .actions => clay.Color{ 137, 180, 250, 255 }, // Catppuccin Blue
                    .set_brightness, .set_contrast => clay.Color{ 250, 179, 135, 255 }, // Catppuccin Peach
                    .go_to_image => clay.Color{ 166, 227, 161, 255 }, // Catppuccin Green
                },
                .font_size = @intFromFloat(13.0 * dpi_scale),
                .font_id = 0,
            });
        });

        // Search Input Box
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(38 * scale_y) },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
                .padding = .{ .left = 12, .right = 12 },
            },
            .background_color = .{ 17, 17, 27, 255 }, // Catppuccin Crust (input background)
            .corner_radius = .all(6),
            .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = .{ 137, 180, 250, 255 } }, // Blue active border
        })({
            const query_str = if (palette.query.items.len > 0) palette.query.items else cfg.placeholder;
            const query_color = if (palette.query.items.len > 0) clay.Color{ 205, 214, 244, 255 } else clay.Color{ 108, 112, 134, 255 };
            clay.text(query_str, .{
                .color = query_color,
                .font_size = @intFromFloat(14.0 * dpi_scale),
                .font_id = 0,
            });
        });

        if (palette.active_type == .set_brightness or palette.active_type == .set_contrast or palette.active_type == .go_to_image) {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(64 * scale_y) },
                    .direction = .top_to_bottom,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 },
                    .child_gap = 6,
                },
                .background_color = .{ 17, 17, 27, 255 }, // Catppuccin Crust
                .corner_radius = .all(6),
            })({
                const raw_str = palette.query.items;
                const total_count = state.image_list.items.len;
                if (palette.active_type == .go_to_image) {
                    if (total_count == 0) {
                        clay.text("No images loaded.", .{
                            .color = .{ 243, 139, 168, 255 }, // Red
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else if (raw_str.len == 0) {
                        clay.text("Enter image number, then press Enter to apply.", .{
                            .color = .{ 166, 173, 200, 255 },
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                        const range_str = try std.fmt.allocPrint(frame_allocator, "Allowed range: 1 to {} (current: {})", .{ total_count, (state.current_index orelse 0) + 1 });
                        clay.text(range_str, .{
                            .color = .{ 108, 112, 134, 255 }, // Subtext
                            .font_size = @intFromFloat(11.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else {
                        const parsed_val_opt = std.fmt.parseInt(usize, raw_str, 10) catch null;
                        if (parsed_val_opt) |val| {
                            if (val >= 1 and val <= total_count) {
                                const target_path = state.image_list.items[val - 1];
                                const raw_basename = std.fs.path.basename(target_path);
                                const display_filename = truncateFilename(frame_allocator, raw_basename, 492.0 * scale_x, @intFromFloat(12.0 * dpi_scale), measure_data);
                                const success_str = try std.fmt.allocPrint(frame_allocator, "Press Enter to go to {}: {s}", .{ val, display_filename });
                                clay.text(success_str, .{
                                    .color = .{ 166, 227, 161, 255 }, // Green
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            } else {
                                const err_str = try std.fmt.allocPrint(frame_allocator, "Out of bounds: must be between 1 and {}", .{total_count});
                                clay.text(err_str, .{
                                    .color = .{ 243, 139, 168, 255 }, // Red
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            }
                        } else {
                            clay.text("Invalid number format. Enter a positive integer.", .{
                                .color = .{ 243, 139, 168, 255 }, // Red
                                .font_size = @intFromFloat(13.0 * dpi_scale),
                                .font_id = 0,
                            });
                        }
                    }
                } else {
                    if (raw_str.len == 0) {
                        clay.text("Enter a number, then press Enter to apply.", .{
                            .color = .{ 166, 173, 200, 255 },
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                        const range_str = if (palette.active_type == .set_brightness) "Allowed range: -1.0 to 1.0 (default: 0.0)" else "Allowed range: 0.0 to 5.0 (default: 1.0)";
                        clay.text(range_str, .{
                            .color = .{ 108, 112, 134, 255 }, // Subtext
                            .font_size = @intFromFloat(11.0 * dpi_scale),
                            .font_id = 0,
                        });
                    } else {
                        const parsed_val_opt = std.fmt.parseFloat(f32, raw_str) catch null;
                        if (parsed_val_opt) |val| {
                            const min_val: f32 = if (palette.active_type == .set_brightness) -1.0 else 0.0;
                            const max_val: f32 = if (palette.active_type == .set_brightness) 1.0 else 5.0;
                            if (val >= min_val and val <= max_val) {
                                const success_str = try std.fmt.allocPrint(frame_allocator, "Press Enter to set value to: {d:.2}", .{val});
                                clay.text(success_str, .{
                                    .color = .{ 166, 227, 161, 255 }, // Green
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            } else {
                                const err_str = try std.fmt.allocPrint(frame_allocator, "Out of bounds: must be between {d:.1} and {d:.1}", .{ min_val, max_val });
                                clay.text(err_str, .{
                                    .color = .{ 243, 139, 168, 255 }, // Red
                                    .font_size = @intFromFloat(13.0 * dpi_scale),
                                    .font_id = 0,
                                });
                            }
                        } else {
                            clay.text("Invalid number format. Use digits and decimal point (e.g. 0.5 or -0.2).", .{
                                .color = .{ 243, 139, 168, 255 }, // Red
                                .font_size = @intFromFloat(13.0 * dpi_scale),
                                .font_id = 0,
                            });
                        }
                    }
                }
            });
        } else {
            // Results list scroll container
            const scroll_data = clay.cdefs.Clay_GetScrollContainerData(clay.getElementId(cfg.list_id));
            var scroll_offset = if (scroll_data.found) scroll_data.scroll_position.* else clay.Vector2{ .x = 0, .y = 0 };

            // Auto-scroll logic during keyboard navigation
            const item_height = cfg.base_item_height * scale_y;
            const viewport_height = 320.0 * scale_y;

            if (scroll_data.found and palette.selection_dirty) {
                const item_top = @as(f32, @floatFromInt(palette.selected_idx)) * item_height;
                const item_bottom = item_top + item_height;
                const visible_top = -scroll_data.scroll_position.y;
                const visible_bottom = visible_top + viewport_height;

                if (item_top < visible_top) {
                    scroll_data.scroll_position.y = -item_top;
                    scroll_offset.y = -item_top;
                } else if (item_bottom > visible_bottom) {
                    scroll_data.scroll_position.y = -(item_bottom - viewport_height);
                    scroll_offset.y = -(item_bottom - viewport_height);
                }
                palette.selection_dirty = false;
            }

            const matching_indices = palette.matches;

            clay.UI()(.{
                .id = clay.getElementId(cfg.list_id),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(320 * scale_y) },
                    .direction = .top_to_bottom,
                    .child_gap = @intFromFloat(4 * scale_y),
                },
                .clip = .{
                    .horizontal = false,
                    .vertical = true,
                    .child_offset = scroll_offset,
                },
            })({
                const visible_top = -scroll_offset.y;
                const visible_bottom = visible_top + viewport_height;

                var start_visible_idx = @as(usize, @intFromFloat(@max(0.0, @floor(visible_top / item_height))));
                var end_visible_idx = @as(usize, @intFromFloat(@max(0.0, @ceil(visible_bottom / item_height))));

                start_visible_idx = if (start_visible_idx > 0) start_visible_idx - 1 else 0;
                end_visible_idx = end_visible_idx + 1;

                if (end_visible_idx > matching_indices.items.len) {
                    end_visible_idx = matching_indices.items.len;
                }
                if (start_visible_idx > end_visible_idx) {
                    start_visible_idx = end_visible_idx;
                }

                const top_spacer_h = @as(f32, @floatFromInt(start_visible_idx)) * item_height;
                const bottom_spacer_h = @as(f32, @floatFromInt(matching_indices.items.len - end_visible_idx)) * item_height;

                // Render Top Spacer if needed
                if (top_spacer_h > 0) {
                    clay.UI()(.{
                        .id = clay.getElementId(cfg.top_spacer_id),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(top_spacer_h) } },
                    })({});
                }

                // Render visible items
                var match_count = start_visible_idx;
                for (matching_indices.items[start_visible_idx..end_visible_idx]) |real_idx| {
                    const is_selected = (match_count == palette.selected_idx);

                    const item_id_str = try std.fmt.allocPrint(frame_allocator, "{s}{}", .{ cfg.item_prefix, real_idx });

                    const item_hovered = clay.pointerOver(clay.getElementId(item_id_str));

                    // Item Container
                    clay.UI()(.{
                        .id = clay.getElementId(item_id_str),
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fixed(switch (palette.active_type) {
                                .files => 54 * scale_y,
                                .actions => 46 * scale_y,
                                else => 0.0,
                            }) },
                            .direction = .left_to_right,
                            .child_alignment = .{ .x = .left, .y = .center },
                            .padding = .{ .left = 12, .right = 12 },
                        },
                        .background_color = if (is_selected)
                            clay.Color{ 49, 50, 68, 255 } // Catppuccin Surface0
                        else if (item_hovered)
                            clay.Color{ 30, 30, 46, 255 } // Catppuccin Base (lighter hover)
                        else
                            clay.Color{ 0, 0, 0, 0 },
                        .corner_radius = .all(6),
                    })({
                        switch (palette.active_type) {
                            .files => {
                                const path = state.image_list.items[real_idx];
                                const display_filename = truncateFilename(frame_allocator, std.fs.path.basename(path), 492.0 * scale_x, @intFromFloat(13.0 * dpi_scale), measure_data);
                                const display_dir = truncateDirectory(frame_allocator, std.fs.path.dirname(path) orelse ".", 488.0 * scale_x, @intFromFloat(11.0 * dpi_scale), measure_data);

                                clay.UI()(.{
                                    .layout = .{
                                        .sizing = .{ .w = .grow, .h = .fit },
                                        .direction = .top_to_bottom,
                                        .child_gap = 2,
                                    },
                                })({
                                    // Row 1: Category Pill + Filename
                                    clay.UI()(.{
                                        .layout = .{
                                            .sizing = .{ .w = .grow, .h = .fit },
                                            .direction = .left_to_right,
                                            .child_alignment = .{ .x = .left, .y = .center },
                                            .child_gap = 6,
                                        },
                                    })({
                                        // Small colored indicator tag representing category / type
                                        clay.UI()(.{
                                            .layout = .{
                                                .sizing = .{ .w = .fixed(4 * scale_x), .h = .fixed(12 * scale_y) },
                                            },
                                            .background_color = if (is_selected) .{ 137, 180, 250, 255 } else .{ 108, 112, 134, 255 },
                                            .corner_radius = .all(3),
                                        })({});

                                        // Filename
                                        clay.text(display_filename, .{
                                            .color = if (is_selected) .{ 137, 180, 250, 255 } else .{ 205, 214, 244, 255 },
                                            .font_size = @intFromFloat(13.0 * dpi_scale),
                                            .font_id = 0,
                                        });
                                    });

                                    // Row 2: Parent folder path (indented slightly for alignment with filename)
                                    clay.UI()(.{
                                        .layout = .{
                                            .sizing = .{ .w = .grow, .h = .fit },
                                            .direction = .left_to_right,
                                            .padding = .{ .left = 14 },
                                        },
                                    })({
                                        clay.text(display_dir, .{
                                            .color = .{ 166, 173, 200, 255 }, // Subtext
                                            .font_size = @intFromFloat(11.0 * dpi_scale),
                                            .font_id = 0,
                                        });
                                    });
                                });
                            },
                            .actions => {
                                const action = app_actions[real_idx];

                                // Action Name (Left aligned)
                                clay.UI()(.{
                                    .layout = .{
                                        .sizing = .{ .w = .grow, .h = .fit },
                                    },
                                })({
                                    clay.text(action.name, .{
                                        .color = if (is_selected) clay.Color{ 137, 180, 250, 255 } else clay.Color{ 205, 214, 244, 255 },
                                        .font_size = @intFromFloat(13.0 * dpi_scale),
                                        .font_id = 0,
                                    });
                                });

                                // Keyboard Shortcut (Right aligned)
                                if (action.shortcut.len > 0) {
                                    clay.UI()(.{
                                        .layout = .{
                                            .sizing = .{ .w = .fit, .h = .fit },
                                            .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                                        },
                                        .background_color = .{ 17, 17, 27, 255 }, // Catppuccin Crust
                                        .corner_radius = .all(4),
                                        .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = .{ 49, 50, 68, 255 } },
                                    })({
                                        clay.text(action.shortcut, .{
                                            .color = .{ 166, 173, 200, 255 },
                                            .font_size = @intFromFloat(11.0 * dpi_scale),
                                            .font_id = 0,
                                        });
                                    });
                                }
                            },
                            else => {},
                        }
                    });

                    if (mouse_clicked and item_hovered) {
                        const old_type = palette.active_type;
                        switch (palette.active_type) {
                            .files => {
                                state.current_index = real_idx;
                                try state.updateCache();
                                palette.show = false;
                                stopTextInput(state.window);
                            },
                            .actions => {
                                const action = app_actions[real_idx];
                                try state.triggerAction(action.id);
                                if (palette.active_type == old_type) {
                                    palette.show = false;
                                    stopTextInput(state.window);
                                }
                            },
                            else => {},
                        }
                    }

                    match_count += 1;
                }

                // Render Bottom Spacer if needed
                if (bottom_spacer_h > 0) {
                    clay.UI()(.{
                        .id = clay.getElementId(cfg.bottom_spacer_id),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(bottom_spacer_h) } },
                    })({});
                }

                if (matching_indices.items.len == 0) {
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fixed(36 * scale_y) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                    })({
                        const no_match_msg = switch (palette.active_type) {
                            .files => "No matching files found",
                            .actions => "No matching commands found",
                            else => "",
                        };
                        clay.text(no_match_msg, .{
                            .color = .{ 108, 112, 134, 255 },
                            .font_size = @intFromFloat(13.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                }
            });
        }
    });
}

fn truncateFilename(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) []const u8 {
    const font = data.fonts[0] orelse return text;
    const target_size = @as(f32, @floatFromInt(font_size));
    if (c.TTF_GetFontSize(font) != target_size) {
        _ = c.TTF_SetFontSize(font, target_size);
    }

    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.TTF_GetStringSize(font, text.ptr, text.len, &w, &h)) {
        return text;
    }
    if (@as(f32, @floatFromInt(w)) <= max_w) {
        return text;
    }

    var dots_w: c_int = 0;
    var dots_h: c_int = 0;
    _ = c.TTF_GetStringSize(font, "...", 3, &dots_w, &dots_h);

    const available_w = max_w - @as(f32, @floatFromInt(dots_w));
    if (available_w <= 0) return "...";

    var measured_w: c_int = 0;
    var measured_len: usize = 0;
    if (c.TTF_MeasureString(font, text.ptr, text.len, @intFromFloat(available_w), &measured_w, &measured_len)) {
        var best_len = measured_len;
        while (best_len > 0 and best_len < text.len and (text[best_len] & 0xC0) == 0x80) {
            best_len -= 1;
        }
        return std.fmt.allocPrint(allocator, "{s}...", .{text[0..best_len]}) catch text;
    }
    return text;
}

fn truncateDirectory(allocator: std.mem.Allocator, text: []const u8, max_w: f32, font_size: u16, data: *const MeasureTextUserData) []const u8 {
    var text_config = clay.TextElementConfig{
        .font_id = 0,
        .font_size = font_size,
    };

    const initial_dim = sdl3MeasureText(text, &text_config, data);
    if (initial_dim.w <= max_w) {
        return text;
    }

    const dots_w = sdl3MeasureText("...", &text_config, data).w;

    var low: usize = 0;
    var high: usize = text.len;
    var best_len: usize = 0;

    while (low <= high) {
        const mid = (low + high) / 2;
        const start_idx = text.len - mid;
        // Verify UTF-8 boundary
        var byte_start = start_idx;
        while (byte_start < text.len and (text[byte_start] & 0xC0) == 0x80) {
            byte_start += 1;
        }

        const part_w = sdl3MeasureText(text[byte_start..], &text_config, data).w;

        if (part_w + dots_w <= max_w) {
            best_len = text.len - byte_start;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }

    return std.fmt.allocPrint(allocator, "...{s}", .{text[text.len - best_len ..]}) catch text;
}

fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    const mb = kb / 1024.0;
    return std.fmt.allocPrint(allocator, "{d:.1} MB", .{mb});
}

const ParsedArgs = struct {
    arg_path: ?[]const u8,
    default_scale: ScaleMode,
};

fn parseCommandLineArgs(init: std.process.Init, gpa: std.mem.Allocator) !ParsedArgs {
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    // Skip binary name
    _ = args_it.next();

    var arg_path: ?[]const u8 = null;
    var default_scale: ScaleMode = .full;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scale")) {
            if (args_it.next()) |val| {
                if (std.mem.eql(u8, val, "none")) {
                    default_scale = .none;
                } else if (std.mem.eql(u8, val, "shrink")) {
                    default_scale = .shrink;
                } else if (std.mem.eql(u8, val, "full")) {
                    default_scale = .full;
                } else if (std.mem.eql(u8, val, "crop")) {
                    default_scale = .crop;
                } else {
                    std.log.err("Unknown scale mode: {s}. Valid modes are: none, shrink, full, crop.", .{val});
                }
            } else {
                std.log.err("Missing value for --scale flag.", .{});
            }
        } else {
            // Treat non-flag arguments as path
            if (arg_path == null) {
                arg_path = try gpa.dupe(u8, arg);
            }
        }
    }

    return ParsedArgs{
        .arg_path = arg_path,
        .default_scale = default_scale,
    };
}

const GraphicsSetup = struct {
    window: *c.SDL_Window,
    gpu_device: *c.SDL_GPUDevice,
    initial_dpi_scale: f32,
};

fn initGraphicsAndWindow(window_title: [:0]const u8) !GraphicsSetup {
    // Initialize SDL3
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) {
        std.log.err("SDL_Init Error: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    errdefer c.SDL_Quit();

    // Initialize SDL3_ttf
    if (!c.TTF_Init()) {
        std.log.err("TTF_Init Error: {s}", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }
    errdefer c.TTF_Quit();

    // Create window
    const window = c.SDL_CreateWindow(window_title.ptr, 1024, 768, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse {
        std.log.err("SDL_CreateWindow Error: {s}", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    // Get scales
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
    const initial_dpi_scale = if (win_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;

    // Create GPU Device
    const gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, true, null) orelse {
        std.log.err("SDL_CreateGPUDevice Error: {s}", .{c.SDL_GetError()});
        return error.DeviceCreationFailed;
    };
    errdefer c.SDL_DestroyGPUDevice(gpu_device);

    if (!c.SDL_ClaimWindowForGPUDevice(gpu_device, window)) {
        std.log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
        return error.ClaimWindowFailed;
    }

    return GraphicsSetup{
        .window = window,
        .gpu_device = gpu_device,
        .initial_dpi_scale = initial_dpi_scale,
    };
}

const GpuResources = struct {
    text_engine: *c.TTF_TextEngine,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    white_texture: *c.SDL_GPUTexture,
    fonts: [2]?*c.TTF_Font,
};

fn initGpuResources(gpu_device: *c.SDL_GPUDevice, window: *c.SDL_Window, initial_dpi_scale: f32) !GpuResources {
    // Load Font from Memory using SDL_IOStream (scaled by DPI scale)
    const roboto_font_bytes = @embedFile("resources/Roboto-Regular.ttf");
    const stream = c.SDL_IOFromConstMem(roboto_font_bytes.ptr, roboto_font_bytes.len) orelse {
        std.log.err("SDL_IOFromConstMem Error: {s}", .{c.SDL_GetError()});
        return error.SDLMemIOFailed;
    };
    errdefer _ = c.SDL_CloseIO(stream);
    const font = c.TTF_OpenFontIO(stream, true, 20.0 * initial_dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{c.SDL_GetError()});
        return error.TTFOpenFontFailed;
    };
    errdefer c.TTF_CloseFont(font);

    // Create TTF GPU Text Engine
    const text_engine = c.TTF_CreateGPUTextEngine(gpu_device) orelse {
        std.log.err("TTF_CreateGPUTextEngine Error: {s}", .{c.SDL_GetError()});
        return error.TTFCreateEngineFailed;
    };
    errdefer c.TTF_DestroyGPUTextEngine(text_engine);

    // Re-load font at smaller size for stat rows
    const stream2 = c.SDL_IOFromConstMem(roboto_font_bytes.ptr, roboto_font_bytes.len) orelse {
        std.log.err("SDL_IOFromConstMem Error: {s}", .{c.SDL_GetError()});
        return error.SDLMemIOFailed;
    };
    errdefer _ = c.SDL_CloseIO(stream2);
    const font_small = c.TTF_OpenFontIO(stream2, true, 14.0 * initial_dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{c.SDL_GetError()});
        return error.TTFOpenFontFailed;
    };
    errdefer c.TTF_CloseFont(font_small);

    const fonts = [2]?*c.TTF_Font{ font, font_small };

    // Compile Shaders
    const vert_code = @embedFile("shaders/vert.spv");
    const frag_code = @embedFile("shaders/frag.spv");

    const vert_info = c.SDL_GPUShaderCreateInfo{
        .code_size = vert_code.len,
        .code = vert_code.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
        .num_samplers = 0,
        .num_storage_buffers = 0,
        .num_storage_textures = 0,
        .num_uniform_buffers = 0,
        .props = 0,
    };
    const vert_shader = c.SDL_CreateGPUShader(gpu_device, &vert_info) orelse {
        std.log.err("Failed to create vertex shader: {s}", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(gpu_device, vert_shader);

    const frag_info = c.SDL_GPUShaderCreateInfo{
        .code_size = frag_code.len,
        .code = frag_code.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        .num_samplers = 1,
        .num_storage_buffers = 0,
        .num_storage_textures = 0,
        .num_uniform_buffers = 1,
        .props = 0,
    };
    const frag_shader = c.SDL_CreateGPUShader(gpu_device, &frag_info) orelse {
        std.log.err("Failed to create fragment shader: {s}", .{c.SDL_GetError()});
        return error.ShaderCreationFailed;
    };
    defer c.SDL_ReleaseGPUShader(gpu_device, frag_shader);

    // Create sampler
    const sampler_info = c.SDL_GPUSamplerCreateInfo{
        .min_filter = c.SDL_GPU_FILTER_LINEAR,
        .mag_filter = c.SDL_GPU_FILTER_LINEAR,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0.0,
        .max_anisotropy = 1.0,
        .compare_op = c.SDL_GPU_COMPAREOP_NEVER,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .props = 0,
    };
    const sampler = c.SDL_CreateGPUSampler(gpu_device, &sampler_info) orelse {
        std.log.err("Failed to create GPU sampler: {s}", .{c.SDL_GetError()});
        return error.SamplerCreationFailed;
    };
    errdefer c.SDL_ReleaseGPUSampler(gpu_device, sampler);

    // Create 1x1 white texture
    const texture_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
        .width = 1,
        .height = 1,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };
    const white_texture = c.SDL_CreateGPUTexture(gpu_device, &texture_info) orelse {
        std.log.err("Failed to create white texture: {s}", .{c.SDL_GetError()});
        return error.TextureCreationFailed;
    };
    errdefer c.SDL_ReleaseGPUTexture(gpu_device, white_texture);

    // Upload white pixel
    {
        const cmd_buf = c.SDL_AcquireGPUCommandBuffer(gpu_device) orelse return error.CommandBufferAcquisitionFailed;
        const transfer_buf = c.SDL_CreateGPUTransferBuffer(gpu_device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = 4,
            .props = 0,
        }) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            return error.TransferBufferCreationFailed;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(gpu_device, transfer_buf);

        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(gpu_device, transfer_buf, false) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            return error.MapFailed;
        });
        mapped[0] = 255;
        mapped[1] = 255;
        mapped[2] = 255;
        mapped[3] = 255;
        c.SDL_UnmapGPUTransferBuffer(gpu_device, transfer_buf);

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            return error.CopyPassFailed;
        };
        c.SDL_UploadToGPUTexture(copy_pass, &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer_buf,
            .offset = 0,
            .pixels_per_row = 1,
            .rows_per_layer = 1,
        }, &c.SDL_GPUTextureRegion{
            .texture = white_texture,
            .w = 1,
            .h = 1,
            .d = 1,
        }, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    }

    // Create Graphics Pipeline
    const vertex_attribs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(renderer.Vertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(renderer.Vertex, "u") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(renderer.Vertex, "r") },
    };
    const vertex_buf_descs = [_]c.SDL_GPUVertexBufferDescription{
        .{ .slot = 0, .pitch = @sizeOf(renderer.Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
    };

    var pipeline_info = c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .num_vertex_attributes = vertex_attribs.len,
            .vertex_attributes = &vertex_attribs,
            .num_vertex_buffers = vertex_buf_descs.len,
            .vertex_buffer_descriptions = &vertex_buf_descs,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = .{
            .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS,
            .back_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS, .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP },
            .front_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS, .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP },
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = false,
            .enable_depth_write = false,
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .num_color_targets = 1,
            .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{.{
                .format = c.SDL_GetGPUSwapchainTextureFormat(gpu_device, window),
                .blend_state = .{
                    .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                    .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                    .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
                    .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                    .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .enable_blend = true,
                    .enable_color_write_mask = false,
                    .padding1 = 0,
                    .padding2 = 0,
                },
            }},
            .has_depth_stencil_target = false,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
            .padding1 = 0,
            .padding2 = 0,
        },
        .props = 0,
    };
    const pipeline = c.SDL_CreateGPUGraphicsPipeline(gpu_device, &pipeline_info) orelse {
        std.log.err("Failed to create graphics pipeline: {s}", .{c.SDL_GetError()});
        return error.PipelineCreationFailed;
    };

    return GpuResources{
        .text_engine = text_engine,
        .pipeline = pipeline,
        .sampler = sampler,
        .white_texture = white_texture,
        .fonts = fonts,
    };
}

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

fn renderFrame(
    state: *ViewerState,
    input: FrameInput,
    frame_allocator: std.mem.Allocator,
    fonts: []const ?*c.TTF_Font,
    measure_data: *const MeasureTextUserData,
) !void {
    const width = input.pix_w;
    const height = input.pix_h;
    const scale_x = input.scale_x;
    const scale_y = input.scale_y;
    const dpi_scale = input.dpi_scale;
    const current_entry = state.getCurrentEntry();

    // Calculate Image Fitting Layout Boundaries
    var title_bar_h: f32 = 60.0;
    const nav_bar_h: f32 = 0.0;
    if (state.is_fullscreen) {
        title_bar_h = 0;
    }

    var available_width = width;
    if (clay.isDebugModeEnabled()) {
        available_width = @max(width - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0);
    }

    state.prepareCacheTextures();

    var draw_w: f32 = 0;
    var draw_h: f32 = 0;

    if (current_entry) |entry| {
        if (entry.gpu_texture != null) {
            const padding: f32 = 0.0;
            const view_w = @max(available_width - padding * 2.0, 1.0);
            const view_h = @max(height - (title_bar_h + nav_bar_h) * scale_y - padding * 2.0, 1.0);

            const angle = @mod(state.rotation_angle, 360.0);
            const is_90_or_270 = (std.math.approxEqAbs(f32, angle, 90.0, 0.1) or
                std.math.approxEqAbs(f32, angle, 270.0, 0.1) or
                std.math.approxEqAbs(f32, angle, -90.0, 0.1) or
                std.math.approxEqAbs(f32, angle, -270.0, 0.1));
            const img_w = if (is_90_or_270) entry.h else entry.w;
            const img_h = if (is_90_or_270) entry.w else entry.h;

            if (img_w > 0 and img_h > 0) {
                const r_img = img_w / img_h;
                const r_view = view_w / view_h;
                switch (state.scale_mode) {
                    .none => {
                        draw_w = img_w;
                        draw_h = img_h;
                    },
                    .shrink => {
                        if (img_w <= view_w and img_h <= view_h) {
                            draw_w = img_w;
                            draw_h = img_h;
                        } else {
                            if (r_img > r_view) {
                                draw_w = view_w;
                                draw_h = view_w / r_img;
                            } else {
                                draw_h = view_h;
                                draw_w = view_h * r_img;
                            }
                        }
                    },
                    .full => {
                        if (r_img > r_view) {
                            draw_w = view_w;
                            draw_h = view_w / r_img;
                        } else {
                            draw_h = view_h;
                            draw_w = view_h * r_img;
                        }
                    },
                    .crop => {
                        if (r_img > r_view) {
                            draw_h = view_h;
                            draw_w = view_h * r_img;
                        } else {
                            draw_w = view_w;
                            draw_h = view_w / r_img;
                        }
                    },
                }
            }
        }
    }

    clay.beginLayout();

    // Main Layout Container
    clay.UI()(.{
        .id = clay.getElementId("MainLayout"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
            .direction = .top_to_bottom,
        },
        .background_color = .{ 24, 24, 37, 255 }, // Catppuccin Base (Mocha Mantle/Base)
    })({
        try renderPalette(
            state,
            scale_x,
            scale_y,
            dpi_scale,
            input.mouse_left_clicked,
            frame_allocator,
            measure_data,
        );

        if (state.show_stats_overlay) {
            const idx = state.current_index;
            const path = if (idx != null and state.image_list.items.len > idx.?) state.image_list.items[idx.?] else "";
            const filename = if (path.len > 0) std.fs.path.basename(path) else "None";
            const dirname = if (path.len > 0) (std.fs.path.dirname(path) orelse ".") else "None";

            const display_dir = if (dirname.len > 35) try std.fmt.allocPrint(frame_allocator, "...{s}", .{dirname[dirname.len - 32 ..]}) else dirname;

            var disk_size_str: []const u8 = "Loading...";
            var mem_size_str: []const u8 = "Loading...";
            var mime_type: []const u8 = "Loading...";
            var res_str: []const u8 = "Loading...";
            var decode_str: []const u8 = "Loading...";
            var convert_str: []const u8 = "Loading...";
            var process_str: []const u8 = "Loading...";
            var screen_str: []const u8 = "Loading...";

            if (current_entry) |entry| {
                mime_type = entry.mime_type;
                if (entry.status == .loaded or entry.gpu_texture != null) {
                    disk_size_str = try formatSize(frame_allocator, entry.size_bytes);
                    mem_size_str = try formatSize(frame_allocator, entry.memory_size_bytes);

                    const megapixels = (entry.w * entry.h) / 1_000_000.0;
                    res_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} ({d:.2} MP)", .{ entry.w, entry.h, megapixels });
                    decode_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{entry.decode_time_ms});
                    convert_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{entry.conversion_time_ms});
                    process_str = try std.fmt.allocPrint(frame_allocator, "{d:.2} ms", .{entry.upload_time_ms});
                    screen_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}x{d:.0} px", .{ draw_w, draw_h });
                } else if (entry.status == .failed) {
                    disk_size_str = "Failed";
                    mem_size_str = "Failed";
                    mime_type = "Failed";
                    res_str = "Failed";
                    decode_str = "Failed";
                    convert_str = "Failed";
                    process_str = "Failed";
                    screen_str = "Failed";
                }
            }

            var zoom_str: []const u8 = "1.0x";
            if (current_entry) |entry| {
                if (entry.w > 0) {
                    const pixel_zoom_pct = ((draw_w * state.zoom_factor) / entry.w) * 100.0;
                    zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x ({d:.0}%)", .{ state.zoom_factor, pixel_zoom_pct });
                } else {
                    zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.zoom_factor});
                }
            } else {
                zoom_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.zoom_factor});
            }

            const pan_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}, {d:.0} px", .{ state.pan_x, state.pan_y });
            const rot_str = try std.fmt.allocPrint(frame_allocator, "{d:.0}°", .{state.rotation_angle});

            clay.UI()(.{
                .id = clay.getElementId("StatsPanel"),
                .layout = .{
                    .sizing = .{ .w = .fixed(380 * scale_x), .h = .fit },
                    .direction = .top_to_bottom,
                    .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
                    .child_gap = 10,
                },
                .background_color = .{ 30, 30, 46, 220 },
                .corner_radius = .all(10),
                .border = .{
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                    .color = .{ 49, 50, 68, 255 },
                },
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_top, .parent = .left_top },
                    .offset = .{ .x = state.stats_offset_x, .y = state.stats_offset_y },
                    .z_index = 100,
                },
            })({
                // Header row
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fixed(24 * scale_y) },
                        .direction = .left_to_right,
                        .child_alignment = .{ .x = .left, .y = .center },
                    },
                })({
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({
                        clay.text("Stats for Nerds", .{
                            .color = .{ 245, 194, 231, 255 },
                            .font_size = @intFromFloat(16.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                    clay.UI()(.{
                        .id = clay.getElementId("StatsCloseBtn"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(24 * scale_x), .h = .fixed(24 * scale_y) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                        .background_color = .{ 49, 50, 68, 255 },
                        .corner_radius = .all(12),
                    })({
                        clay.text("x", .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(12.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                });

                // Stats details
                if (filename.len > 0) {
                    try renderStatRow("File Name", filename, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Directory", display_dir, scale_x, scale_y, dpi_scale);
                    try renderStatRow("MIME Type", mime_type, scale_x, scale_y, dpi_scale);
                    const hit_str = if (state.current_image_cache_hit) "Yes" else "No";
                    try renderStatRow("Cache Hit", hit_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Size on Disk", disk_size_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Resolution", res_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Decode Time", decode_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Convert Time", convert_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Upload Time", process_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Memory Size", mem_size_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Viewport Size", screen_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Zoom Level", zoom_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Pan Offset", pan_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Rotation", rot_str, scale_x, scale_y, dpi_scale);
                    const scale_mode_str = switch (state.scale_mode) {
                        .none => "Original size (100%)",
                        .shrink => "Fit if larger",
                        .full => "Fit to screen (Aspect Fit)",
                        .crop => "Fill screen (Aspect Fill)",
                    };
                    try renderStatRow("Scale Mode", scale_mode_str, scale_x, scale_y, dpi_scale);
                    const filter_str = switch (state.texture_scale_mode) {
                        .nearest => "Nearest Neighbor",
                        .linear => "Bilinear Filter",
                        .pixel_art => "Pixel Art Scaling",
                    };
                    try renderStatRow("Scaling Filter", filter_str, scale_x, scale_y, dpi_scale);

                    const brightness_val = state.brightness * 100.0;
                    const brightness_str = try std.fmt.allocPrint(frame_allocator, "{s}{d:.0}%", .{ if (brightness_val > 0) "+" else "", brightness_val });
                    const contrast_str = try std.fmt.allocPrint(frame_allocator, "{d:.1}x", .{state.contrast});
                    try renderStatRow("Brightness", brightness_str, scale_x, scale_y, dpi_scale);
                    try renderStatRow("Contrast", contrast_str, scale_x, scale_y, dpi_scale);
                }
            });
        }

        // Header/Title bar UI
        if (!state.is_fullscreen) {
            clay.UI()(.{
                .id = clay.getElementId("TitleBar"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(title_bar_h * scale_y) },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{
                        .left = @intFromFloat(20 * scale_x),
                        .right = @intFromFloat(20 * scale_x),
                    },
                },
                .background_color = .{ 17, 17, 27, 255 },
                .border = .{ .width = .{ .bottom = 1 }, .color = .{ 49, 50, 68, 255 } },
            })({
                clay.text("Peng Image Viewer", .{
                    .color = .{ 205, 214, 244, 255 },
                    .font_size = @intFromFloat(16.0 * dpi_scale),
                    .font_id = 0,
                });

                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({});

                if (state.image_list.items.len > 0) {
                    const idx = (state.current_index orelse 0) + 1;
                    const count_buf = try frame_allocator.alloc(u8, 64);
                    const count_str = try std.fmt.bufPrint(count_buf, "Image {} of {}", .{ idx, state.image_list.items.len });
                    clay.text(count_str, .{
                        .color = .{ 166, 173, 200, 255 },
                        .font_size = @intFromFloat(12.0 * dpi_scale),
                        .font_id = 0,
                    });
                }
            });
        }

        // Center Viewport Area
        clay.UI()(.{
            .id = clay.getElementId("Viewport"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .clip = .{ .horizontal = true, .vertical = true },
        })({
            if (current_entry) |entry| {
                if (entry.gpu_texture) |tex| {
                    clay.UI()(.{
                        .id = clay.getElementId("ImageCanvas"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(draw_w), .h = .fixed(draw_h) },
                        },
                        .image = .{
                            .image_data = @ptrCast(tex),
                        },
                    })({});
                } else if (entry.status == .decoding) {
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .grow },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = @intFromFloat(10 * scale_y),
                        },
                    })({
                        clay.text("Loading image...", .{
                            .color = .{ 245, 194, 231, 255 },
                            .font_size = @intFromFloat(22.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                } else {
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .grow },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = @intFromFloat(10 * scale_y),
                        },
                    })({
                        clay.text("Failed to Load Image", .{
                            .color = .{ 243, 139, 168, 255 },
                            .font_size = @intFromFloat(22.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                }
            } else {
                // Empty state screen
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .grow },
                        .direction = .top_to_bottom,
                        .child_alignment = .{ .x = .center, .y = .center },
                    },
                })({
                    clay.UI()(.{
                        .id = clay.ElementId.ID("DropZoneBox"),
                        .layout = .{
                            .sizing = .{ .w = .fit, .h = .fit },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = @intFromFloat(16 * scale_y),
                            .padding = .{
                                .left = @intFromFloat(40 * scale_x),
                                .right = @intFromFloat(40 * scale_x),
                                .top = @intFromFloat(32 * scale_y),
                                .bottom = @intFromFloat(32 * scale_y),
                            },
                        },
                        .border = .{ .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 }, .color = .{ 79, 79, 97, 255 } },
                        .corner_radius = .all(12),
                        .user_data = @ptrFromInt(@intFromEnum(ElementTag.drop_zone_box)),
                    })({
                        clay.text("No Images Loaded", .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(22.0 * dpi_scale),
                            .font_id = 0,
                        });

                        clay.text("Drag & Drop images or directories here to view them.", .{
                            .color = .{ 166, 173, 200, 255 },
                            .font_size = @intFromFloat(14.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                });
            }
        });
    });

    const render_commands = clay.endLayout();

    // Render Frame
    const cmd_buf = c.SDL_AcquireGPUCommandBuffer(state.gpu_device) orelse return error.CommandBufferAcquisitionFailed;
    var swap_tex: ?*c.SDL_GPUTexture = null;
    var swap_w: u32 = 0;
    var swap_h: u32 = 0;

    var temp_textures = std.ArrayList(*c.SDL_GPUTexture).empty;
    defer temp_textures.deinit(frame_allocator);
    var temp_buffers = std.ArrayList(*c.SDL_GPUTransferBuffer).empty;
    defer temp_buffers.deinit(frame_allocator);

    if (c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buf, state.window, &swap_tex, &swap_w, &swap_h)) {
        try renderer.renderClayCommands(
            state.gpu_device,
            cmd_buf,
            swap_tex,
            state.gpu_pipeline,
            state.gpu_sampler,
            state.white_texture,
            state.gpu_text_engine,
            fonts,
            render_commands,
            frame_allocator,
            &temp_textures,
            &temp_buffers,
            .{
                .zoom_factor = state.zoom_factor,
                .pan_x = state.pan_x,
                .pan_y = state.pan_y,
                .rotation_angle = state.rotation_angle,
            },
            @intCast(swap_w),
            @intCast(swap_h),
            state.brightness,
            state.contrast,
        );
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);

        // Defer release of text textures until command buffer completes
        for (temp_textures.items) |tex| {
            c.SDL_ReleaseGPUTexture(state.gpu_device, tex);
        }
        for (temp_buffers.items) |buf| {
            c.SDL_ReleaseGPUTransferBuffer(state.gpu_device, buf);
        }
    } else {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Phase 1: Parse command line arguments
    const parsed = try parseCommandLineArgs(init, gpa);
    defer if (parsed.arg_path) |p| gpa.free(p);

    // Phase 2: Graphics and Window Setup
    const setup = try initGraphicsAndWindow("Peng Image Viewer");
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
        .cache = std.ArrayList(CacheEntry).empty,
        .cache_mutex = cache_mutex,
        .allocator = gpa,
        .io = init.io,
        .window_pixel_format = c.SDL_PIXELFORMAT_RGBA32,
        .palette = PaletteState.init(gpa),
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

    // Phase 5: The Main Loop
    while (state.running) {
        // Phase 5a: Input Accumulation
        _ = frame_arena.reset(.retain_capacity);
        const input = try pollFrameInput(
            setup.window,
            frame_allocator,
            &last_time,
            &state.mouse_inside,
            &state.running,
            state.palette.show,
        );

        // Phase 5b: State Update
        try state.update(input, gpa);

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
        try renderFrame(&state, input, frame_allocator, resources.fonts[0..], &measure_data);
    }
}

test "ElementTag.fromInt" {
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0));
    try std.testing.expectEqual(ElementTag.drop_zone_box, ElementTag.fromInt(1337));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(9999));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0x7fffffffd000));
}
