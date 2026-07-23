const std = @import("std");
const c = @import("c.zig").c;
const ipc = @import("ipc.zig");

pub const MeasureTextUserData = struct {
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
    quit_requested: bool,
    scroll_delta_x: f32,
    scroll_delta_y: f32,

    keys_pressed: std.ArrayList(c.SDL_Keycode),
    key_modifiers: c.SDL_Keymod,
    text_input: ?[]const u8,
    dropped_path: ?[]const u8,

    ticks: u64,
    delta_time_ms: f32,
    pending_ipc_commands: std.ArrayList(*ipc.IpcCommandData),
};
