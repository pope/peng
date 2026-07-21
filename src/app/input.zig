const std = @import("std");
const c = @import("c.zig").c;
const commands = @import("../commands.zig");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const startTextInput = app_state.startTextInput;
const stopTextInput = app_state.stopTextInput;
const app_actions = commands.actions.app_actions;
const flat_shortcuts = commands.actions.flat_shortcuts;
const FrameInput = @import("types.zig").FrameInput;
const ipc = @import("ipc.zig");

pub fn pollFrameInput(
    window: *c.SDL_Window,
    frame_allocator: std.mem.Allocator,
    last_time: *u64,
    prev_mouse_inside: bool,
    palette_show: bool,
    non_blocking: bool,
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
    var pending_ipc_commands = std.ArrayList(*anyopaque).empty;
    errdefer pending_ipc_commands.deinit(frame_allocator);
    var text_input_opt: ?[]const u8 = null;
    var dropped_path_opt: ?[]const u8 = null;
    var scroll_delta_x: f32 = 0;
    var scroll_delta_y: f32 = 0;
    var mouse_left_clicked = false;
    var mouse_inside = prev_mouse_inside;
    var quit_requested = false;

    var event: c.SDL_Event = undefined;
    const wait_success = if (non_blocking)
        c.SDL_PollEvent(&event)
    else if (palette_show)
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
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    mouse_left_clicked = true;
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const multiplier: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1.0 else 1.0;
                scroll_delta_x += event.wheel.x * multiplier * 6.0 * scale_x;
                scroll_delta_y += event.wheel.y * multiplier * 6.0 * scale_y;
            },
            else => {
                if (event.type == ipc.PENG_IPC_EVENT) {
                    if (event.user.data1) |ptr| {
                        try pending_ipc_commands.append(frame_allocator, ptr);
                    }
                }
            },
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
        .pending_ipc_commands = pending_ipc_commands,
    };
}

pub fn handlePaletteKeys(
    self: *ViewerState,
    key: c.SDL_Keycode,
) !bool {
    const palette = &self.palette;
    if (palette.mode == .inactive) return false;

    switch (key) {
        c.SDLK_ESCAPE => {
            palette.mode = .inactive;
            stopTextInput(self.window);
            return true;
        },
        c.SDLK_UP => {
            if (palette.mode == .set_brightness or palette.mode == .set_contrast or palette.mode == .go_to_image) return true;
            if (palette.selected_idx > 0) {
                palette.selected_idx -= 1;
                palette.selection_dirty = true;
            }
            return true;
        },
        c.SDLK_DOWN => {
            if (palette.mode == .set_brightness or palette.mode == .set_contrast or palette.mode == .go_to_image) return true;
            const count = palette.matches.items.len;
            if (count > 0 and palette.selected_idx + 1 < count) {
                palette.selected_idx += 1;
                palette.selection_dirty = true;
            }
            return true;
        },
        c.SDLK_RETURN => {
            if (palette.mode == .set_brightness or palette.mode == .set_contrast or palette.mode == .go_to_image) {
                const raw_str = palette.query.items;
                if (raw_str.len > 0) {
                    if (palette.mode == .go_to_image) {
                        const val = std.fmt.parseInt(usize, raw_str, 10) catch null;
                        if (val) |v| {
                            if (v >= 1 and v <= self.image_list.items.len) {
                                self.current_index = v - 1;
                                try self.updateCache();
                                palette.mode = .inactive;
                                stopTextInput(self.window);
                                return true;
                            }
                        }
                    } else {
                        const parsed_val_opt = std.fmt.parseFloat(f32, raw_str) catch null;
                        if (parsed_val_opt) |val| {
                            if (!std.math.isNan(val) and !std.math.isInf(val)) {
                                const min_val: f32 = if (palette.mode == .set_brightness) -1.0 else 0.0;
                                const max_val: f32 = if (palette.mode == .set_brightness) 1.0 else 5.0;
                                if (val >= min_val and val <= max_val) {
                                    if (palette.mode == .set_brightness) {
                                        self.brightness = val;
                                    } else {
                                        self.contrast = val;
                                    }
                                    self.adjustments_dirty = true;
                                    palette.mode = .inactive;
                                    stopTextInput(self.window);
                                    return true;
                                }
                            }
                        }
                    }
                }
                return true; // Keep open on invalid inputs
            } else {
                if (palette.selected_idx < palette.matches.items.len) {
                    const target_idx = palette.matches.items[palette.selected_idx];
                    const old_type = palette.mode;
                    switch (palette.mode) {
                        .files => {
                            self.current_index = target_idx;
                            try self.updateCache();
                            palette.mode = .inactive;
                            stopTextInput(self.window);
                        },
                        .actions => {
                            const action_id = app_actions[target_idx];
                            try self.triggerAction(action_id);
                            if (palette.mode == old_type) {
                                palette.mode = .inactive;
                                stopTextInput(self.window);
                            }
                        },
                        else => {},
                    }
                } else {
                    palette.mode = .inactive;
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
                switch (palette.mode) {
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

pub const InputAction = union(enum) {
    none,
    pan: struct { dx: f32, dy: f32 },
    zoom: struct { factor_delta: f32 },
    trigger_action: commands.actions.AppActionId,
};

pub fn mapKeyToAction(key: c.SDL_Keycode, mod: c.SDL_Keymod, is_zoomed: bool) InputAction {
    // 1. Context-Sensitive Keys (Arrow Keys: Pan vs Navigate)
    if (is_zoomed) {
        switch (key) {
            c.SDLK_LEFT => return .{ .pan = .{ .dx = 30.0, .dy = 0.0 } },
            c.SDLK_RIGHT => return .{ .pan = .{ .dx = -30.0, .dy = 0.0 } },
            c.SDLK_UP => return .{ .pan = .{ .dx = 0.0, .dy = 30.0 } },
            c.SDLK_DOWN => return .{ .pan = .{ .dx = 0.0, .dy = -30.0 } },
            else => {},
        }
    }

    // 2. Fine Zooming (keyboard-specific: +/- 0.1 step)
    switch (key) {
        c.SDLK_EQUALS, c.SDLK_KP_PLUS => return .{ .zoom = .{ .factor_delta = 0.1 } },
        c.SDLK_MINUS, c.SDLK_KP_MINUS => return .{ .zoom = .{ .factor_delta = -0.1 } },
        else => {},
    }

    // 3. Dynamic Registry Lookup (Left/Right Modifier Translation)
    var clean_mod: c.SDL_Keymod = 0;
    if ((mod & c.SDL_KMOD_SHIFT) != 0) clean_mod |= c.SDL_KMOD_SHIFT;
    if ((mod & c.SDL_KMOD_CTRL) != 0) clean_mod |= c.SDL_KMOD_CTRL;
    if ((mod & c.SDL_KMOD_ALT) != 0) clean_mod |= c.SDL_KMOD_ALT;
    if ((mod & c.SDL_KMOD_GUI) != 0) clean_mod |= c.SDL_KMOD_GUI;

    for (flat_shortcuts) |shortcut| {
        if (key == shortcut.key and clean_mod == shortcut.mod) {
            return .{ .trigger_action = shortcut.action_id };
        }
    }

    return .none;
}

pub fn handleKeyDown(
    self: *ViewerState,
    key: c.SDL_Keycode,
    mod: c.SDL_Keymod,
    scale_x: f32,
    scale_y: f32,
) !void {
    if (self.palette.mode != .inactive) {
        _ = try handlePaletteKeys(self, key);
        return;
    }

    const action = mapKeyToAction(key, mod, self.zoom_factor > 1.0);
    switch (action) {
        .none => {},
        .pan => |p| {
            self.pan_x += p.dx * scale_x;
            self.pan_y += p.dy * scale_y;
        },
        .zoom => |z| {
            const old_zoom = self.zoom_factor;
            self.zoom_factor = std.math.clamp(self.zoom_factor + z.factor_delta, 0.1, 10.0);
            self.pan_x *= (self.zoom_factor / old_zoom);
            self.pan_y *= (self.zoom_factor / old_zoom);
        },
        .trigger_action => |action_id| {
            try self.triggerAction(action_id);
        },
    }
}

test "mapKeyToAction mapping" {
    // Zoom and Pan actions
    const pan_left = mapKeyToAction(c.SDLK_LEFT, 0, true);
    try std.testing.expect(pan_left == .pan);
    try std.testing.expectEqual(@as(f32, 30.0), pan_left.pan.dx);

    const pan_left_not_zoomed = mapKeyToAction(c.SDLK_LEFT, 0, false);
    try std.testing.expect(pan_left_not_zoomed == .trigger_action);
    try std.testing.expectEqual(commands.actions.AppActionId.prev_image, pan_left_not_zoomed.trigger_action);

    const zoom_in = mapKeyToAction(c.SDLK_EQUALS, 0, false);
    try std.testing.expect(zoom_in == .zoom);
    try std.testing.expectEqual(@as(f32, 0.1), zoom_in.zoom.factor_delta);
}
