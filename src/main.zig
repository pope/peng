const std = @import("std");
const clay = @import("zclay");
const renderer = @import("renderer.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
    @cInclude("SDL3_image/SDL_image.h");
});

const MeasureTextUserData = struct {
    text_engine: ?*c.TTF_TextEngine,
    fonts: [*]?*c.TTF_Font,
    allocator: std.mem.Allocator,
};

fn sdl3MeasureText(text: []const u8, config: *clay.TextElementConfig, data: *const MeasureTextUserData) clay.Dimensions {
    const font = data.fonts[config.font_id];
    if (!c.TTF_SetFontSize(font, @as(f32, @floatFromInt(config.font_size)))) {
        std.log.err("TTF_SetFontSize failed: {s}", .{c.SDL_GetError()});
    }

    const len = text.len;

    // Align layout text allocation: stack-allocate for standard strings, heap-allocate for large strings
    var stack_buf: [1024]u8 = undefined;
    const buffer = if (len + 1 < stack_buf.len)
        stack_buf[0 .. len + 1]
    else
        data.allocator.alloc(u8, len + 1) catch return .{ .w = 0, .h = 0 };
    defer if (len + 1 >= stack_buf.len) data.allocator.free(buffer);
    @memcpy(buffer[0..len], text);
    buffer[len] = 0;

    const text_obj = c.TTF_CreateText(data.text_engine, font, buffer.ptr, len) orelse return .{ .w = 0, .h = 0 };
    defer c.TTF_DestroyText(text_obj);

    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.TTF_GetTextSize(text_obj, &w, &h)) {
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

const ViewerState = struct {
    renderer: ?*c.SDL_Renderer,
    image_list: std.ArrayList([]const u8),
    current_index: ?usize = null,
    current_texture: ?*c.SDL_Texture = null,
    current_w: f32 = 0,
    current_h: f32 = 0,
    current_size_bytes: u64 = 0,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn loadCurrent(self: *ViewerState) !void {
        if (self.current_texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.current_texture = null;
        }

        const idx = self.current_index orelse return;
        const path = self.image_list.items[idx];

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        self.current_texture = c.IMG_LoadTexture(self.renderer, path_z.ptr);
        if (self.current_texture == null) {
            std.log.err("Failed to load texture '{s}': {s}", .{ path, c.SDL_GetError() });
            return;
        }

        if (!c.SDL_GetTextureSize(self.current_texture.?, &self.current_w, &self.current_h)) {
            std.log.err("Failed to query texture size: {s}", .{c.SDL_GetError()});
        }

        self.current_size_bytes = 0;
        if (std.Io.Dir.statFile(std.Io.Dir.cwd(), self.io, path, .{})) |s| {
            self.current_size_bytes = s.size;
        } else |_| {}
    }

    fn next(self: *ViewerState) !void {
        if (self.image_list.items.len == 0) return;
        if (self.current_index) |idx| {
            self.current_index = (idx + 1) % self.image_list.items.len;
        } else {
            self.current_index = 0;
        }
        try self.loadCurrent();
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
        try self.loadCurrent();
    }

    fn handlePathSelection(self: *ViewerState, path: []const u8) !void {
        // Clear existing list
        for (self.image_list.items) |item| {
            self.allocator.free(item);
        }
        self.image_list.clearRetainingCapacity();

        if (self.current_texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.current_texture = null;
        }
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
                    try self.loadCurrent();
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
                try self.loadCurrent();
            }
        }
    }
};

fn formatSize(bytes: u64, buf: []u8) []const u8 {
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "0 KB";
    }
    const mb = kb / 1024.0;
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "0 MB";
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Get command line arguments from std.process.Init
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    // Skip binary name
    _ = args_it.next();

    var arg_path: ?[]const u8 = null;
    if (args_it.next()) |arg| {
        arg_path = try gpa.dupe(u8, arg);
    }
    defer if (arg_path) |p| gpa.free(p);

    // Initialize SDL3
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) {
        std.log.err("SDL_Init Error: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    // Initialize SDL3_ttf
    if (!c.TTF_Init()) {
        std.log.err("TTF_Init Error: {s}", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }
    defer c.TTF_Quit();

    // SDL3_image does not require manual initialization; it initializes automatically on load.

    // Create Window with High Pixel Density enabled
    const window = c.SDL_CreateWindow("Peng Image Viewer", 800, 600, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse {
        std.log.err("SDL_CreateWindow Error: {s}", .{c.SDL_GetError()});
        return error.SDLCreateWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    // Calculate DPI scale factor at startup
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
    const dpi_scale = if (win_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;

    // Create Renderer
    const renderer_ctx = c.SDL_CreateRenderer(window, null) orelse {
        std.log.err("SDL_CreateRenderer Error: {s}", .{c.SDL_GetError()});
        return error.SDLCreateRendererFailed;
    };
    defer c.SDL_DestroyRenderer(renderer_ctx);

    // Enable VSync
    if (!c.SDL_SetRenderVSync(renderer_ctx, 1)) {
        std.log.err("SDL_SetRenderVSync failed: {s}", .{c.SDL_GetError()});
    }

    // Load Font from Memory using SDL_IOStream (scaled by DPI scale)
    const roboto_font_bytes = @embedFile("resources/Roboto-Regular.ttf");
    const stream = c.SDL_IOFromConstMem(roboto_font_bytes.ptr, roboto_font_bytes.len) orelse {
        std.log.err("SDL_IOFromConstMem Error: {s}", .{c.SDL_GetError()});
        return error.SDLMemIOFailed;
    };
    const font = c.TTF_OpenFontIO(stream, true, 20.0 * dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{c.SDL_GetError()});
        return error.TTFOpenFontFailed;
    };
    defer c.TTF_CloseFont(font);

    // Create TTF Text Engine
    const text_engine = c.TTF_CreateRendererTextEngine(renderer_ctx) orelse {
        std.log.err("TTF_CreateRendererTextEngine Error: {s}", .{c.SDL_GetError()});
        return error.TTFCreateEngineFailed;
    };
    defer c.TTF_DestroyRendererTextEngine(text_engine);

    // Allocate memory for Clay
    const buffer_size = clay.minMemorySize();
    const buffer = try gpa.alloc(u8, buffer_size);
    defer gpa.free(buffer);

    const arena = clay.Arena.init(buffer);
    _ = clay.initialize(arena, .{ .w = @floatFromInt(pix_w), .h = @floatFromInt(pix_h) }, .{});

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();

    var fonts = [_]?*c.TTF_Font{font};
    const measure_data = MeasureTextUserData{
        .text_engine = text_engine,
        .fonts = fonts[0..].ptr,
        .allocator = frame_allocator,
    };

    clay.setMeasureTextFunction(*const MeasureTextUserData, &measure_data, sdl3MeasureText);

    // Initialize state
    var state = ViewerState{
        .renderer = renderer_ctx,
        .image_list = std.ArrayList([]const u8).empty,
        .allocator = gpa,
        .io = init.io,
    };
    defer {
        if (state.current_texture) |tex| {
            c.SDL_DestroyTexture(tex);
        }
        for (state.image_list.items) |item| {
            gpa.free(item);
        }
        state.image_list.deinit(gpa);
    }

    // Populate image list from command line argument
    if (arg_path) |path| {
        try state.handlePathSelection(path);
    }

    // Read from stdin if piped
    const is_stdin_piped = !(std.Io.File.stdin().isTty(init.io) catch false);
    if (is_stdin_piped) {
        var read_buf: [4096]u8 = undefined;
        var stdin_file_reader = std.Io.File.Reader.init(std.Io.File.stdin(), init.io, &read_buf);
        const stdin = &stdin_file_reader.interface;

        while (try stdin.takeDelimiter('\n')) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n ");
            if (trimmed.len > 0) {
                if (std.Io.Dir.statFile(std.Io.Dir.cwd(), init.io, trimmed, .{})) |s| {
                    if (s.kind == .directory) {
                        try scanDirectory(gpa, init.io, trimmed, &state.image_list);
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
            try state.loadCurrent();
        }
    }

    var last_time = c.SDL_GetTicks();
    var is_fullscreen = false;
    var running = true;
    var mouse_inside = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        var mouse_clicked = false;
        var scroll_delta_x: f32 = 0;
        var scroll_delta_y: f32 = 0;

        // Block until an event occurs to prevent spinning at 100% CPU when idle
        if (!c.SDL_WaitEvent(&event)) {
            break;
        }

        // Process first event
        switch (event.type) {
            c.SDL_EVENT_QUIT => running = false,
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    mouse_clicked = true;
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const multiplier: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1.0 else 1.0;
                scroll_delta_x += event.wheel.x * multiplier * 6.0;
                scroll_delta_y += event.wheel.y * multiplier * 6.0;
            },
            c.SDL_EVENT_WINDOW_MOUSE_ENTER => {
                mouse_inside = true;
            },
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                mouse_inside = false;
            },
            c.SDL_EVENT_KEY_DOWN => {
                switch (event.key.key) {
                    c.SDLK_LEFT, c.SDLK_BACKSPACE => try state.prev(),
                    c.SDLK_RIGHT, c.SDLK_SPACE => try state.next(),
                    c.SDLK_F, c.SDLK_F11 => {
                        is_fullscreen = !is_fullscreen;
                        if (!c.SDL_SetWindowFullscreen(window, is_fullscreen)) {
                            std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
                        }
                    },
                    c.SDLK_ESCAPE => {
                        if (is_fullscreen) {
                            is_fullscreen = false;
                            if (!c.SDL_SetWindowFullscreen(window, false)) {
                                std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
                            }
                        } else {
                            running = false;
                        }
                    },
                    c.SDLK_D => {
                        clay.setDebugModeEnabled(!clay.isDebugModeEnabled());
                    },
                    else => {},
                }
            },
            c.SDL_EVENT_DROP_FILE => {
                const dropped_path = event.drop.data;
                if (dropped_path != null) {
                    const path_len = std.mem.len(dropped_path);
                    const path_slice = dropped_path[0..path_len];
                    try state.handlePathSelection(path_slice);
                    c.SDL_free(@constCast(dropped_path));
                }
            },
            else => {},
        }

        // Drain any other pending events in the queue
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        mouse_clicked = true;
                    }
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    const multiplier: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1.0 else 1.0;
                    scroll_delta_x += event.wheel.x * multiplier * 6.0;
                    scroll_delta_y += event.wheel.y * multiplier * 6.0;
                },
                c.SDL_EVENT_WINDOW_MOUSE_ENTER => {
                    mouse_inside = true;
                },
                c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                    mouse_inside = false;
                },
                c.SDL_EVENT_KEY_DOWN => {
                    switch (event.key.key) {
                        c.SDLK_LEFT, c.SDLK_BACKSPACE => try state.prev(),
                        c.SDLK_RIGHT, c.SDLK_SPACE => try state.next(),
                        c.SDLK_F, c.SDLK_F11 => {
                            is_fullscreen = !is_fullscreen;
                            if (!c.SDL_SetWindowFullscreen(window, is_fullscreen)) {
                                std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
                            }
                        },
                        c.SDLK_ESCAPE => {
                            if (is_fullscreen) {
                                is_fullscreen = false;
                                if (!c.SDL_SetWindowFullscreen(window, false)) {
                                    std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
                                }
                            } else {
                                running = false;
                            }
                        },
                        c.SDLK_D => {
                            clay.setDebugModeEnabled(!clay.isDebugModeEnabled());
                        },
                        else => {},
                    }
                },
                c.SDL_EVENT_DROP_FILE => {
                    const dropped_path = event.drop.data;
                    if (dropped_path != null) {
                        const path_len = std.mem.len(dropped_path);
                        const path_slice = dropped_path[0..path_len];
                        try state.handlePathSelection(path_slice);
                        c.SDL_free(@constCast(dropped_path));
                    }
                },
                else => {},
            }
        }

        _ = frame_arena.reset(.retain_capacity);

        // Get window sizes
        var current_win_w: c_int = 0;
        var current_win_h: c_int = 0;
        if (!c.SDL_GetWindowSize(window, &current_win_w, &current_win_h)) {
            std.log.err("SDL_GetWindowSize failed: {s}", .{c.SDL_GetError()});
        }
        var current_pix_w: c_int = 0;
        var current_pix_h: c_int = 0;
        if (!c.SDL_GetWindowSizeInPixels(window, &current_pix_w, &current_pix_h)) {
            std.log.err("SDL_GetWindowSizeInPixels failed: {s}", .{c.SDL_GetError()});
        }

        const width = @as(f32, @floatFromInt(current_pix_w));
        const height = @as(f32, @floatFromInt(current_pix_h));
        clay.setLayoutDimensions(.{ .w = width, .h = height });

        const scale_x = if (current_win_w > 0) @as(f32, @floatFromInt(current_pix_w)) / @as(f32, @floatFromInt(current_win_w)) else 1.0;
        const scale_y = if (current_win_h > 0) @as(f32, @floatFromInt(current_pix_h)) / @as(f32, @floatFromInt(current_win_h)) else 1.0;

        // Get mouse coordinates and scale
        var mouse_x: f32 = 0;
        var mouse_y: f32 = 0;
        const mouse_state = c.SDL_GetMouseState(&mouse_x, &mouse_y);

        if (mouse_inside) {
            clay.setPointerState(
                .{ .x = mouse_x * scale_x, .y = mouse_y * scale_y },
                (mouse_state & c.SDL_BUTTON_MASK(c.SDL_BUTTON_LEFT)) != 0,
            );
        } else {
            clay.setPointerState(
                .{ .x = -1.0, .y = -1.0 },
                false,
            );
        }

        const current_time = c.SDL_GetTicks();
        const delta_time = @as(f32, @floatFromInt(current_time - last_time)) / 1000.0;
        last_time = current_time;

        clay.updateScrollContainers(
            true,
            .{ .x = scroll_delta_x, .y = scroll_delta_y },
            delta_time,
        );

        // Process Click Actions before Layout pass (to read hover state correctly)
        if (mouse_clicked) {
            if (clay.pointerOver(clay.getElementId("PrevBtn"))) {
                try state.prev();
            } else if (clay.pointerOver(clay.getElementId("NextBtn"))) {
                try state.next();
            } else if (clay.pointerOver(clay.getElementId("FsBtn"))) {
                is_fullscreen = !is_fullscreen;
                if (!c.SDL_SetWindowFullscreen(window, is_fullscreen)) {
                    std.log.err("SDL_SetWindowFullscreen failed: {s}", .{c.SDL_GetError()});
                }
            }
        }

        // Calculate Image Fitting Layout Boundaries
        var title_bar_h: f32 = 60.0;
        var nav_bar_h: f32 = 80.0;
        if (is_fullscreen) {
            title_bar_h = 0;
            nav_bar_h = 0;
        }

        var available_width = width;
        if (clay.isDebugModeEnabled()) {
            available_width = @max(width - @as(f32, @floatFromInt(clay.Clay__debugViewWidth)), 1.0);
        }

        var draw_w: f32 = 0;
        var draw_h: f32 = 0;

        if (state.current_texture != null) {
            const padding: f32 = 40.0;
            const view_w = @max(available_width - padding * 2.0, 1.0);
            const view_h = @max(height - title_bar_h - nav_bar_h - padding * 2.0, 1.0);

            const img_w = state.current_w;
            const img_h = state.current_h;

            if (img_w > 0 and img_h > 0) {
                const r_img = img_w / img_h;
                const r_view = view_w / view_h;

                if (r_img > r_view) {
                    draw_w = view_w;
                    draw_h = view_w / r_img;
                    if (draw_h > view_h) {
                        draw_h = view_h;
                        draw_w = view_h * r_img;
                    }
                } else {
                    draw_h = view_h;
                    draw_w = view_h * r_img;
                    if (draw_w > view_w) {
                        draw_w = view_w;
                        draw_h = view_w / r_img;
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
            // 1. Header / Title Bar (hidden in fullscreen)
            if (!is_fullscreen) {
                clay.UI()(.{
                    .id = clay.getElementId("TitleBar"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fixed(title_bar_h * scale_y) },
                        .direction = .left_to_right,
                        .child_alignment = .{ .x = .left, .y = .center },
                        .padding = .{ .left = @intFromFloat(20 * scale_x), .right = @intFromFloat(20 * scale_x) },
                    },
                    .background_color = .{ 17, 17, 27, 255 }, // Catppuccin Crust
                })({
                    if (state.current_index) |idx| {
                        const path = state.image_list.items[idx];
                        const filename = std.fs.path.basename(path);

                        // File size conversion
                        const size_buf = try frame_allocator.alloc(u8, 64);
                        const size_str = formatSize(state.current_size_bytes, size_buf);

                        // Dimensions metadata
                        const meta_buf = try frame_allocator.alloc(u8, 128);
                        const meta_str = try std.fmt.bufPrint(meta_buf, "{d:.0}x{d:.0} ({s})", .{ state.current_w, state.current_h, size_str });

                        clay.UI()(.{
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .grow },
                                .direction = .left_to_right,
                                .child_alignment = .{ .x = .left, .y = .center },
                            },
                        })({
                            clay.text(filename, .{
                                .color = .{ 205, 214, 244, 255 },
                                .font_size = @intFromFloat(16.0 * dpi_scale),
                                .font_id = 0,
                            });
                        });

                        clay.UI()(.{
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .grow },
                                .direction = .left_to_right,
                                .child_alignment = .{ .x = .right, .y = .center },
                            },
                        })({
                            clay.text(meta_str, .{
                                .color = .{ 166, 173, 200, 255 }, // Subtext0
                                .font_size = @intFromFloat(14.0 * dpi_scale),
                                .font_id = 0,
                            });
                        });
                    } else {
                        clay.text("Peng Image Viewer", .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(16.0 * dpi_scale),
                            .font_id = 0,
                        });
                    }
                });
            }

            // 2. Center Viewport Area
            clay.UI()(.{
                .id = clay.getElementId("Viewport"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .grow },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            })({
                if (state.current_texture) |tex| {
                    clay.UI()(.{
                        .id = clay.getElementId("ImageCanvas"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(draw_w), .h = .fixed(draw_h) },
                        },
                        .image = .{
                            .image_data = @ptrCast(tex),
                        },
                    })({});
                } else {
                    // Empty state screen
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .grow },
                            .direction = .top_to_bottom,
                            .child_alignment = .{ .x = .center, .y = .center },
                            .child_gap = @intFromFloat(10 * scale_y),
                        },
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
                }
            });

            // 3. Navigation Controls Bar (hidden in fullscreen)
            if (!is_fullscreen) {
                clay.UI()(.{
                    .id = clay.getElementId("NavBar"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fixed(nav_bar_h * scale_y) },
                        .direction = .left_to_right,
                        .child_alignment = .{ .x = .center, .y = .center },
                        .child_gap = @intFromFloat(30 * scale_x),
                        .padding = .{ .left = @intFromFloat(20 * scale_x), .right = @intFromFloat(20 * scale_x) },
                    },
                    .background_color = .{ 17, 17, 27, 255 }, // Catppuccin Crust
                })({
                    const prev_hovered = clay.pointerOver(clay.getElementId("PrevBtn"));

                    // 3a. Previous button
                    clay.UI()(.{
                        .id = clay.getElementId("PrevBtn"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(120 * scale_x), .h = .fixed(40 * scale_y) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                        .background_color = if (prev_hovered) .{ 49, 50, 68, 255 } else .{ 30, 30, 46, 255 },
                        .corner_radius = .all(6),
                    })({
                        clay.text("Previous", .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(14.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });

                    // 3b. Index Metadata Info
                    var index_text: []const u8 = "0 of 0";
                    if (state.current_index) |idx| {
                        const index_buf = try frame_allocator.alloc(u8, 64);
                        index_text = try std.fmt.bufPrint(index_buf, "{d} of {d}", .{ idx + 1, state.image_list.items.len });
                    }
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .fixed(150 * scale_x), .h = .grow },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                    })({
                        clay.text(index_text, .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(14.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });

                    // 3c. Next Button
                    const next_hovered = clay.pointerOver(clay.getElementId("NextBtn"));

                    clay.UI()(.{
                        .id = clay.getElementId("NextBtn"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(120 * scale_x), .h = .fixed(40 * scale_y) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                        .background_color = if (next_hovered) .{ 49, 50, 68, 255 } else .{ 30, 30, 46, 255 },
                        .corner_radius = .all(6),
                    })({
                        clay.text("Next", .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(14.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });

                    // 3d. Fullscreen Button
                    const fs_hovered = clay.pointerOver(clay.getElementId("FsBtn"));

                    clay.UI()(.{
                        .id = clay.getElementId("FsBtn"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(120 * scale_x), .h = .fixed(40 * scale_y) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                        .background_color = if (fs_hovered) .{ 49, 50, 68, 255 } else .{ 30, 30, 46, 255 },
                        .corner_radius = .all(6),
                    })({
                        clay.text("Fullscreen", .{
                            .color = .{ 205, 214, 244, 255 },
                            .font_size = @intFromFloat(14.0 * dpi_scale),
                            .font_id = 0,
                        });
                    });
                });
            }
        });

        const render_commands = clay.endLayout();

        // Render Frame
        if (!c.SDL_SetRenderDrawColor(renderer_ctx, 0, 0, 0, 255)) {
            std.log.err("SDL_SetRenderDrawColor failed: {s}", .{c.SDL_GetError()});
        }
        if (!c.SDL_RenderClear(renderer_ctx)) {
            std.log.err("SDL_RenderClear failed: {s}", .{c.SDL_GetError()});
        }

        try renderer.renderClayCommands(renderer_ctx, text_engine, fonts[0..].ptr, render_commands, frame_allocator);

        if (!c.SDL_RenderPresent(renderer_ctx)) {
            std.log.err("SDL_RenderPresent failed: {s}", .{c.SDL_GetError()});
        }
    }
}
