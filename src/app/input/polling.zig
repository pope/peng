const std = @import("std");
const sdl = @import("sdl");
const types = @import("../types.zig");
const Key = types.Key;
const KeyModifiers = types.KeyModifiers;
const FrameInput = types.FrameInput;

pub const MOUSE_WHEEL_SCROLL_MULTIPLIER: f32 = 6.0;

pub fn mapKeyFromSdl(key: sdl.keys.Keycode) Key {
    return switch (key) {
        sdl.keys.escape => .escape,
        sdl.keys.return_key, sdl.keys.kp_enter => .return_key,
        sdl.keys.backspace => .backspace,
        sdl.keys.tab => .tab,
        sdl.keys.space => .space,
        sdl.keys.left => .left,
        sdl.keys.right => .right,
        sdl.keys.up => .up,
        sdl.keys.down => .down,
        sdl.keys.equals, sdl.keys.kp_plus => .equals,
        sdl.keys.minus, sdl.keys.kp_minus => .minus,
        sdl.keys.left_bracket => .left_bracket,
        sdl.keys.right_bracket => .right_bracket,
        sdl.keys.home => .home,
        sdl.keys.end => .end,
        sdl.keys.page_up => .page_up,
        sdl.keys.page_down => .page_down,
        sdl.keys.f1 => .f1,
        sdl.keys.f11 => .f11,
        sdl.keys.char_0, sdl.keys.kp_0 => .char_0,
        sdl.keys.char_1, sdl.keys.kp_1 => .char_1,
        sdl.keys.char_2, sdl.keys.kp_2 => .char_2,
        sdl.keys.char_3, sdl.keys.kp_3 => .char_3,
        sdl.keys.char_4, sdl.keys.kp_4 => .char_4,
        sdl.keys.char_5, sdl.keys.kp_5 => .char_5,
        sdl.keys.char_6, sdl.keys.kp_6 => .char_6,
        sdl.keys.char_7, sdl.keys.kp_7 => .char_7,
        sdl.keys.char_8, sdl.keys.kp_8 => .char_8,
        sdl.keys.char_9, sdl.keys.kp_9 => .char_9,
        sdl.keys.key_a => .char_a,
        sdl.keys.key_b => .char_b,
        sdl.keys.key_c => .char_c,
        sdl.keys.key_d => .char_d,
        sdl.keys.key_e => .char_e,
        sdl.keys.key_f => .char_f,
        sdl.keys.key_g => .char_g,
        sdl.keys.key_h => .char_h,
        sdl.keys.key_i => .char_i,
        sdl.keys.key_j => .char_j,
        sdl.keys.key_k => .char_k,
        sdl.keys.key_l => .char_l,
        sdl.keys.key_m => .char_m,
        sdl.keys.key_n => .char_n,
        sdl.keys.key_o => .char_o,
        sdl.keys.key_p => .char_p,
        sdl.keys.key_q => .char_q,
        sdl.keys.key_r => .char_r,
        sdl.keys.key_s => .char_s,
        sdl.keys.key_t => .char_t,
        sdl.keys.key_u => .char_u,
        sdl.keys.key_v => .char_v,
        sdl.keys.key_w => .char_w,
        sdl.keys.key_x => .char_x,
        sdl.keys.key_y => .char_y,
        sdl.keys.key_z => .char_z,
        else => .unknown,
    };
}

pub fn mapModFromSdl(mod: u16) KeyModifiers {
    return .{
        .ctrl = (mod & sdl.keys.mod.ctrl) != 0,
        .shift = (mod & sdl.keys.mod.shift) != 0,
        .alt = (mod & sdl.keys.mod.alt) != 0,
        .gui = (mod & sdl.keys.mod.gui) != 0,
    };
}

pub const FrameInputState = struct {
    frame_allocator: std.mem.Allocator,
    keys_pressed: std.ArrayList(Key),
    text_input_opt: ?[]const u8 = null,
    dropped_path_opt: ?[]const u8 = null,
    scroll_delta_x: f32 = 0,
    scroll_delta_y: f32 = 0,
    mouse_left_clicked: bool = false,
    mouse_inside: bool = false,
    quit_requested: bool = false,
};

pub fn processSDLEvent(event: sdl.Event, frame_input: *FrameInputState) !void {
    switch (event.type) {
        sdl.event_type.quit => frame_input.quit_requested = true,
        sdl.event_type.mouse_enter => {
            frame_input.mouse_inside = true;
        },
        sdl.event_type.mouse_leave => {
            frame_input.mouse_inside = false;
        },
        sdl.event_type.key_down => {
            try frame_input.keys_pressed.append(frame_input.frame_allocator, mapKeyFromSdl(event.key.key));
        },
        sdl.event_type.text_input => {
            if (event.text.text) |ptr| {
                const len = std.mem.len(ptr);
                const dup = try frame_input.frame_allocator.dupe(u8, ptr[0..len]);
                frame_input.text_input_opt = dup;
            }
        },
        sdl.event_type.drop_file => {
            if (event.drop.data) |ptr| {
                const len = std.mem.len(ptr);
                const dup = try frame_input.frame_allocator.dupe(u8, ptr[0..len]);
                frame_input.dropped_path_opt = dup;
            }
        },
        sdl.event_type.mouse_button_down => {
            if (event.button.button == sdl.mouse.left) {
                frame_input.mouse_left_clicked = true;
            }
        },
        sdl.event_type.mouse_wheel => {
            const multiplier: f32 = if (event.wheel.direction == sdl.mouse.wheel_flipped) -1.0 else 1.0;
            frame_input.scroll_delta_x += event.wheel.x * multiplier * MOUSE_WHEEL_SCROLL_MULTIPLIER;
            frame_input.scroll_delta_y += event.wheel.y * multiplier * MOUSE_WHEEL_SCROLL_MULTIPLIER;
        },
        else => {},
    }
}

pub fn pollFrameInput(
    window: sdl.Window,
    frame_allocator: std.mem.Allocator,
    last_time: *u64,
    prev_mouse_inside: bool,
    palette_show: bool,
    non_blocking: bool,
    is_busy: bool,
) !FrameInput {
    const current_ticks = sdl.timer.getTicks();
    const delta_time_ms = @as(f32, @floatFromInt(current_ticks - last_time.*));
    last_time.* = current_ticks;

    // Get window sizes and scale
    const win_size = window.getSize();
    const pix_size = window.getSizeInPixels();

    const width = @as(f32, @floatFromInt(pix_size.w));
    const height = @as(f32, @floatFromInt(pix_size.h));
    const scale_x = if (win_size.w > 0) @as(f32, @floatFromInt(pix_size.w)) / @as(f32, @floatFromInt(win_size.w)) else 1.0;
    const scale_y = if (win_size.h > 0) @as(f32, @floatFromInt(pix_size.h)) / @as(f32, @floatFromInt(win_size.h)) else 1.0;
    const dpi_scale = scale_x;

    var frame_input_state = FrameInputState{
        .frame_allocator = frame_allocator,
        .keys_pressed = .empty,
        .mouse_inside = prev_mouse_inside,
    };
    errdefer frame_input_state.keys_pressed.deinit(frame_allocator);

    var event: sdl.Event = undefined;
    const wait_success = if (non_blocking)
        sdl.events.pollEvent(&event)
    else if (palette_show or is_busy)
        sdl.events.waitEventTimeout(&event, 8)
    else
        sdl.events.waitEvent(&event);

    if (!wait_success) {
        event.type = 0;
    }

    var has_event = wait_success;
    while (has_event) {
        try processSDLEvent(event, &frame_input_state);
        has_event = sdl.events.pollEvent(&event);
    }

    var mouse_x_raw: f32 = 0;
    var mouse_y_raw: f32 = 0;
    const mouse_buttons = sdl.mouse.getState(&mouse_x_raw, &mouse_y_raw);
    const mouse_left_down = (mouse_buttons & sdl.mouse.mask(sdl.mouse.left)) != 0;

    return FrameInput{
        .win_w = @as(f32, @floatFromInt(win_size.w)),
        .win_h = @as(f32, @floatFromInt(win_size.h)),
        .pix_w = width,
        .pix_h = height,
        .scale_x = scale_x,
        .scale_y = scale_y,
        .dpi_scale = dpi_scale,
        .mouse_x = mouse_x_raw,
        .mouse_y = mouse_y_raw,
        .mouse_left_down = mouse_left_down,
        .mouse_left_clicked = frame_input_state.mouse_left_clicked,
        .mouse_inside = frame_input_state.mouse_inside,
        .quit_requested = frame_input_state.quit_requested,
        .scroll_delta_x = frame_input_state.scroll_delta_x,
        .scroll_delta_y = frame_input_state.scroll_delta_y,
        .keys_pressed = frame_input_state.keys_pressed,
        .key_modifiers = mapModFromSdl(sdl.keys.getModState()),
        .text_input = frame_input_state.text_input_opt,
        .dropped_path = frame_input_state.dropped_path_opt,
        .ticks = current_ticks,
        .delta_time_ms = delta_time_ms,
    };
}
