const std = @import("std");
const clay = @import("zclay");
const renderer = @import("renderer.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

const MeasureTextUserData = struct {
    textEngine: ?*c.TTF_TextEngine,
    fonts: [*]?*c.TTF_Font,
    allocator: std.mem.Allocator,
};

fn SDL3_MeasureText(text: clay.StringSlice, config: *clay.TextElementConfig, userData: ?*anyopaque) callconv(.c) clay.Dimensions {
    const data: *const MeasureTextUserData = @ptrCast(@alignCast(userData));
    const font = data.fonts[config.font_id];

    const len = @as(usize, @intCast(text.length));

    // Align layout text allocation: stack-allocate for standard strings, heap-allocate for large strings
    var stack_buf: [1024]u8 = undefined;
    const buffer = if (len < stack_buf.len)
        stack_buf[0..len]
    else
        data.allocator.alloc(u8, len) catch return .{ .w = 0, .h = 0 };
    defer if (len >= stack_buf.len) data.allocator.free(buffer);
    @memcpy(buffer, text.chars[0..len]);

    const text_obj = c.TTF_CreateText(data.textEngine, font, buffer.ptr, len) orelse return .{ .w = 0, .h = 0 };
    defer c.TTF_DestroyText(text_obj);

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.TTF_GetTextSize(text_obj, &w, &h);

    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

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

    // Create Window with High Pixel Density enabled
    const window = c.SDL_CreateWindow("Clay + SDL3 Hello World", 800, 600, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse {
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
    const dpi_scale = @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(win_w));

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

    // Create TTF Text Engine
    const textEngine = c.TTF_CreateRendererTextEngine(renderer_ctx) orelse {
        std.log.err("TTF_CreateRendererTextEngine Error: {s}", .{c.SDL_GetError()});
        return error.TTFCreateEngineFailed;
    };
    defer c.TTF_DestroyRendererTextEngine(textEngine);

    // Load Font from Memory using SDL_IOStream (scaled by DPI scale)
    const roboto_font_bytes = @embedFile("resources/Roboto-Regular.ttf");
    const stream = c.SDL_IOFromConstMem(roboto_font_bytes.ptr, roboto_font_bytes.len) orelse {
        std.log.err("SDL_IOFromConstMem Error: {s}", .{c.SDL_GetError()});
        return error.SDLMemIOFailed;
    };
    const font = c.TTF_OpenFontIO(stream, true, 48.0 * dpi_scale) orelse {
        std.log.err("TTF_OpenFontIO Error: {s}", .{c.SDL_GetError()});
        return error.TTFOpenFontFailed;
    };
    defer c.TTF_CloseFont(font);

    // Allocate memory for Clay
    const buffer_size = clay.minMemorySize();
    const buffer = try gpa.alloc(u8, buffer_size);
    defer gpa.free(buffer);

    const arena = clay.Arena.init(buffer);
    _ = clay.initialize(arena, .{ .w = @floatFromInt(pix_w), .h = @floatFromInt(pix_h) }, .{});

    var frame_arena = init.arena;
    const frame_allocator = frame_arena.allocator();

    var fonts = [_]?*c.TTF_Font{font};
    const measureData = MeasureTextUserData{
        .textEngine = textEngine,
        .fonts = fonts[0..].ptr,
        .allocator = frame_allocator,
    };

    clay.cdefs.Clay_SetMeasureTextFunction(SDL3_MeasureText, @constCast(&measureData));

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        // Block until an event occurs to prevent spinning at 100% CPU when idle
        if (!c.SDL_WaitEvent(&event)) {
            break;
        }

        switch (event.type) {
            c.SDL_EVENT_QUIT => running = false,
            else => {},
        }

        // Drain any other pending events in the queue so we process them together
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                else => {},
            }
        }

        _ = frame_arena.reset(.retain_capacity);

        // Get window size in logical points and physical pixels
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

        const scale_x = @as(f32, @floatFromInt(current_pix_w)) / @as(f32, @floatFromInt(current_win_w));
        const scale_y = @as(f32, @floatFromInt(current_pix_h)) / @as(f32, @floatFromInt(current_win_h));

        // Get mouse state in logical points and scale to pixels
        var mouse_x: f32 = 0;
        var mouse_y: f32 = 0;
        const mouse_state = c.SDL_GetMouseState(&mouse_x, &mouse_y);
        clay.setPointerState(
            .{ .x = mouse_x * scale_x, .y = mouse_y * scale_y },
            (mouse_state & c.SDL_BUTTON_MASK(c.SDL_BUTTON_LEFT)) != 0,
        );

        clay.beginLayout();

        // Configure main container element
        clay.UI()(.{
            .id = clay.getElementId("MainContainer"),
            .layout = .{
                .sizing = .{
                    .w = .grow,
                    .h = .grow,
                },
                .direction = .top_to_bottom,
                .child_alignment = .{
                    .x = .center,
                    .y = .center,
                },
            },
            .background_color = .{ 24, 24, 37, 255 }, // Catppuccin Mocha Crust
        })({
            // Render text
            clay.text("Hello, Clay + SDL3!", .{
                .color = .{ 205, 214, 244, 255 }, // Text color
                .font_size = @intFromFloat(48.0 * dpi_scale),
                .font_id = 0,
            });
        });

        const renderCommands = clay.cdefs.Clay_EndLayout();

        // Render frame
        if (!c.SDL_SetRenderDrawColor(renderer_ctx, 0, 0, 0, 255)) {
            std.log.err("SDL_SetRenderDrawColor failed: {s}", .{c.SDL_GetError()});
        }
        if (!c.SDL_RenderClear(renderer_ctx)) {
            std.log.err("SDL_RenderClear failed: {s}", .{c.SDL_GetError()});
        }

        try renderer.renderClayCommands(renderer_ctx, textEngine, fonts[0..].ptr, renderCommands, frame_allocator);

        if (!c.SDL_RenderPresent(renderer_ctx)) {
            std.log.err("SDL_RenderPresent failed: {s}", .{c.SDL_GetError()});
        }
    }
}
