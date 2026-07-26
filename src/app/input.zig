const std = @import("std");
const sdl = @import("sdl");
const commands = @import("../commands.zig");
const app_state = @import("state.zig");
const types = @import("types.zig");
const Key = types.Key;
const KeyModifiers = types.KeyModifiers;
const FrameInput = types.FrameInput;
const PaletteState = app_state.PaletteState;
const ViewerState = app_state.ViewerState;
const startTextInput = app_state.startTextInput;
const stopTextInput = app_state.stopTextInput;
const app_actions = commands.actions.app_actions;
const flat_shortcuts = commands.actions.flat_shortcuts;
const events = app_state.events;

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

    var keys_pressed = std.ArrayList(Key).empty;
    errdefer keys_pressed.deinit(frame_allocator);
    var text_input_opt: ?[]const u8 = null;
    var dropped_path_opt: ?[]const u8 = null;
    var scroll_delta_x: f32 = 0;
    var scroll_delta_y: f32 = 0;
    var mouse_left_clicked = false;
    var mouse_inside = prev_mouse_inside;
    var quit_requested = false;

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
        switch (event.type) {
            sdl.event_type.quit => quit_requested = true,
            sdl.event_type.mouse_enter => {
                mouse_inside = true;
            },
            sdl.event_type.mouse_leave => {
                mouse_inside = false;
            },
            sdl.event_type.key_down => {
                try keys_pressed.append(frame_allocator, mapKeyFromSdl(event.key.key));
            },
            sdl.event_type.text_input => {
                if (event.text.text) |ptr| {
                    const len = std.mem.len(ptr);
                    const dup = try frame_allocator.dupe(u8, ptr[0..len]);
                    text_input_opt = dup;
                }
            },
            sdl.event_type.drop_file => {
                if (event.drop.data) |ptr| {
                    const len = std.mem.len(ptr);
                    const dup = try frame_allocator.dupe(u8, ptr[0..len]);
                    dropped_path_opt = dup;
                }
            },
            sdl.event_type.mouse_button_down => {
                if (event.button.button == sdl.mouse.left) {
                    mouse_left_clicked = true;
                }
            },
            sdl.event_type.mouse_wheel => {
                const multiplier: f32 = if (event.wheel.direction == sdl.mouse.wheel_flipped) -1.0 else 1.0;
                scroll_delta_x += event.wheel.x * multiplier * 6.0;
                scroll_delta_y += event.wheel.y * multiplier * 6.0;
            },
            else => {},
        }
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
        .mouse_left_clicked = mouse_left_clicked,
        .mouse_inside = mouse_inside,
        .quit_requested = quit_requested,
        .scroll_delta_x = scroll_delta_x,
        .scroll_delta_y = scroll_delta_y,
        .keys_pressed = keys_pressed,
        .key_modifiers = mapModFromSdl(sdl.keys.getModState()),
        .text_input = text_input_opt,
        .dropped_path = dropped_path_opt,
        .ticks = current_ticks,
        .delta_time_ms = delta_time_ms,
    };
}

const fs = app_state.fs;

pub fn handlePaletteKeys(
    self: *ViewerState,
    key: Key,
    mod: KeyModifiers,
) !bool {
    const palette = &self.palette;
    if (palette.mode == .inactive) return false;

    switch (key) {
        .escape => {
            palette.mode = .inactive;
            stopTextInput(self.window);
            return true;
        },
        .left => {
            if (palette.mode == .directory_navigator) {
                var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (fs.getParentDirBuf(palette.current_nav_dir.items, &parent_buf)) |parent_dir| {
                    palette.query.clearRetainingCapacity();
                    try palette.loadDirectoryEntries(self.io, parent_dir);
                }
                return true;
            }
            return false;
        },
        .right => {
            if (palette.mode == .directory_navigator) {
                if (palette.selected_idx < palette.matches.items.len) {
                    const match_idx = palette.matches.items[palette.selected_idx];
                    if (match_idx < palette.dir_items.items.len) {
                        const entry = palette.dir_items.items[match_idx];
                        const path_copy = try self.allocator.dupe(u8, entry.full_path);
                        defer self.allocator.free(path_copy);
                        palette.query.clearRetainingCapacity();
                        try palette.loadDirectoryEntries(self.io, path_copy);
                    }
                }
                return true;
            }
            return false;
        },
        .up => {
            if (palette.mode.isTextInputDialog()) return true;
            if (palette.selected_idx > 0) {
                palette.selected_idx -= 1;
                palette.selection_dirty = true;
            }
            return true;
        },
        .down => {
            if (palette.mode.isTextInputDialog()) return true;
            const count = palette.matches.items.len;
            if (count > 0 and palette.selected_idx + 1 < count) {
                palette.selected_idx += 1;
                palette.selection_dirty = true;
            }
            return true;
        },
        .return_key => {
            switch (palette.mode) {
                .go_to_image => {
                    const raw_str = palette.query.items;
                    if (raw_str.len > 0) {
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
                    }
                    return true;
                },
                .set_slideshow_interval => {
                    const raw_str = palette.query.items;
                    if (raw_str.len > 0) {
                        const parsed_val_opt = std.fmt.parseFloat(f32, raw_str) catch null;
                        if (parsed_val_opt) |val| {
                            if (!std.math.isNan(val) and !std.math.isInf(val) and val > 0.0) {
                                self.slideshow_interval_s = val;
                                self.slideshow_timer_ms = 0.0;
                                self.slideshow_active = true;
                                palette.mode = .inactive;
                                stopTextInput(self.window);
                                return true;
                            }
                        }
                    }
                    return true;
                },
                .set_brightness, .set_contrast => {
                    const raw_str = palette.query.items;
                    if (raw_str.len > 0) {
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
                    return true;
                },
                .directory_navigator => {
                    if (mod.shift) {
                        try self.startAsyncPathScan(palette.current_nav_dir.items, true);
                        self.palette.reset();
                        stopTextInput(self.window);
                    } else {
                        if (palette.selected_idx < palette.matches.items.len) {
                            const match_idx = palette.matches.items[palette.selected_idx];
                            if (match_idx < palette.dir_items.items.len) {
                                const entry = palette.dir_items.items[match_idx];
                                try self.startAsyncPathScan(entry.full_path, true);
                                self.palette.reset();
                                stopTextInput(self.window);
                            }
                        }
                    }
                    return true;
                },
                .files, .actions => {
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
                            else => unreachable,
                        }
                    } else {
                        palette.mode = .inactive;
                        stopTextInput(self.window);
                    }
                    return true;
                },
                .inactive => unreachable,
            }
        },
        .backspace => {
            if (palette.query.items.len > 0) {
                _ = palette.query.pop();
                palette.selected_idx = 0;
                palette.selection_dirty = true;
                switch (palette.mode) {
                    .files => try self.rebuildPaletteMatches(),
                    .actions => try self.rebuildActionMatches(),
                    .directory_navigator => try palette.rebuildDirectoryMatches(),
                    .set_brightness, .set_contrast, .go_to_image, .set_slideshow_interval, .inactive => {},
                }
            } else if (palette.mode == .directory_navigator) {
                var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (fs.getParentDirBuf(palette.current_nav_dir.items, &parent_buf)) |parent_dir| {
                    palette.query.clearRetainingCapacity();
                    try palette.loadDirectoryEntries(self.io, parent_dir);
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

pub fn mapKeyToAction(key: Key, mod: KeyModifiers, is_zoomed: bool) InputAction {
    // 1. Context-Sensitive Keys (Arrow Keys: Pan vs Navigate)
    if (is_zoomed) {
        switch (key) {
            .left => return .{ .pan = .{ .dx = 30.0, .dy = 0.0 } },
            .right => return .{ .pan = .{ .dx = -30.0, .dy = 0.0 } },
            .up => return .{ .pan = .{ .dx = 0.0, .dy = 30.0 } },
            .down => return .{ .pan = .{ .dx = 0.0, .dy = -30.0 } },
            else => {},
        }
    }

    // 2. Fine Zooming (keyboard-specific: +/- 0.1 step)
    switch (key) {
        .equals => return .{ .zoom = .{ .factor_delta = 0.1 } },
        .minus => return .{ .zoom = .{ .factor_delta = -0.1 } },
        else => {},
    }

    // 3. Dynamic Registry Lookup
    for (flat_shortcuts) |shortcut| {
        if (key == shortcut.key and
            mod.ctrl == shortcut.mod.ctrl and
            mod.shift == shortcut.mod.shift and
            mod.alt == shortcut.mod.alt and
            mod.gui == shortcut.mod.gui)
        {
            return .{ .trigger_action = shortcut.action_id };
        }
    }

    return .none;
}

pub fn handleKeyDown(
    self: *ViewerState,
    key: Key,
    mod: KeyModifiers,
    scale_x: f32,
    scale_y: f32,
) !void {
    if (self.palette.mode != .inactive) {
        _ = try handlePaletteKeys(self, key, mod);
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
            self.zoom_factor = self.clampZoomFactor(self.zoom_factor + z.factor_delta);
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
    const pan_left = mapKeyToAction(.left, .{}, true);
    try std.testing.expect(pan_left == .pan);
    try std.testing.expectEqual(@as(f32, 30.0), pan_left.pan.dx);

    const pan_left_not_zoomed = mapKeyToAction(.left, .{}, false);
    try std.testing.expect(pan_left_not_zoomed == .trigger_action);
    try std.testing.expectEqual(commands.actions.AppActionId.prev_image, pan_left_not_zoomed.trigger_action);

    const zoom_in = mapKeyToAction(.equals, .{}, false);
    try std.testing.expect(zoom_in == .zoom);
    try std.testing.expectEqual(@as(f32, 0.1), zoom_in.zoom.factor_delta);
}

test "handlePaletteKeys directory_navigator key interactions" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_key_test";
    const sub_has_img = tmp_dir ++ "/sub_has_images";
    const sub_no_img = tmp_dir ++ "/sub_no_images";

    std.Io.Dir.createDirPath(cwd, io, sub_has_img) catch {};
    std.Io.Dir.createDirPath(cwd, io, sub_no_img) catch {};

    // Create a dummy image file in sub_has_img
    var f = try std.Io.Dir.createFile(cwd, io, sub_has_img ++ "/pic.png", .{});
    f.close(io);

    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var state = ViewerState{
        .directory_arena = std.heap.ArenaAllocator.init(allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .image_list_mutex = .init,
        .cache = .{},
        .cache_mutex = .init,
        .allocator = allocator,
        .io = io,
        .palette = PaletteState.init(allocator),
        .rotation_map = std.StringHashMap(f32).init(allocator),
        .window = null,
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    // 1. Open directory navigator at tmp_dir
    try state.palette.loadDirectoryEntries(io, tmp_dir);
    state.palette.mode = .directory_navigator;

    // Locate index of sub_no_images
    var match_idx_no_img: usize = 0;
    for (state.palette.dir_items.items, 0..) |item, i| {
        if (std.mem.eql(u8, item.name, "sub_no_images")) {
            match_idx_no_img = i;
            break;
        }
    }

    // Test Right key on sub_no_images -> navigate into folder
    state.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(&state, .right, .{});
    try std.testing.expectEqual(app_state.PaletteMode.directory_navigator, state.palette.mode);
    try std.testing.expectEqualStrings(sub_no_img, state.palette.current_nav_dir.items);
    try std.testing.expectEqual(@as(usize, 0), state.palette.query.items.len);

    // Test Left key -> step up to parent directory, remembering sub_no_images
    _ = try handlePaletteKeys(&state, .left, .{});
    try std.testing.expectEqual(app_state.PaletteMode.directory_navigator, state.palette.mode);
    try std.testing.expectEqualStrings(tmp_dir, state.palette.current_nav_dir.items);
    try std.testing.expectEqual(match_idx_no_img, state.palette.selected_idx);

    // Test Enter key on sub_no_images -> starts async path scan for sub_no_images and closes palette
    state.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(&state, .return_key, .{});
    try std.testing.expectEqual(app_state.PaletteMode.inactive, state.palette.mode);

    // Re-open palette
    try state.palette.loadDirectoryEntries(io, tmp_dir);
    state.palette.mode = .directory_navigator;

    // Test Shift+Enter key on current directory -> starts async path scan and closes palette
    _ = try handlePaletteKeys(&state, .return_key, .{ .shift = true });
    try std.testing.expectEqual(app_state.PaletteMode.inactive, state.palette.mode);
}

test "handlePaletteKeys stepping up from dot to parent directory preselects working dir" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = ViewerState{
        .directory_arena = std.heap.ArenaAllocator.init(allocator),
        .image_list = std.ArrayList([]const u8).empty,
        .image_list_mutex = .init,
        .cache = .{},
        .cache_mutex = .init,
        .allocator = allocator,
        .io = io,
        .palette = PaletteState.init(allocator),
        .rotation_map = std.StringHashMap(f32).init(allocator),
        .window = null,
        .event_queue = events.MpscQueue(events.BackgroundEvent).init(),
    };
    defer state.deinit();

    try state.palette.loadDirectoryEntries(io, ".");
    state.palette.mode = .directory_navigator;
    try std.testing.expectEqualStrings(".", state.palette.current_nav_dir.items);

    _ = try handlePaletteKeys(&state, .left, .{});
    try std.testing.expectEqualStrings("..", state.palette.current_nav_dir.items);

    var found_cwd_selected = false;
    if (state.palette.selected_idx < state.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.palette.dir_items.items[state.palette.selected_idx].name, "peng")) {
            found_cwd_selected = true;
        }
    }
    try std.testing.expect(found_cwd_selected);
}
