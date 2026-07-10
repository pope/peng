const std = @import("std");
const main = @import("../main.zig");
const c = main.c;
const commands = @import("../commands.zig");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const startTextInput = app_state.startTextInput;
const stopTextInput = app_state.stopTextInput;
const app_actions = commands.actions.app_actions;
const flat_shortcuts = commands.actions.flat_shortcuts;

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

    // 1. Context-Sensitive Keys (Arrow Keys: Pan vs Navigate)
    if (self.zoom_factor > 1.0) {
        switch (key) {
            c.SDLK_LEFT => {
                self.pan_x += 30.0 * scale_x;
                return;
            },
            c.SDLK_RIGHT => {
                self.pan_x -= 30.0 * scale_x;
                return;
            },
            c.SDLK_UP => {
                self.pan_y += 30.0 * scale_y;
                return;
            },
            c.SDLK_DOWN => {
                self.pan_y -= 30.0 * scale_y;
                return;
            },
            else => {},
        }
    }

    // 2. Fine Zooming (keyboard-specific: +/- 0.1 step)
    switch (key) {
        c.SDLK_EQUALS, c.SDLK_KP_PLUS => {
            const old_zoom = self.zoom_factor;
            self.zoom_factor = std.math.clamp(self.zoom_factor + 0.1, 0.1, 10.0);
            self.pan_x *= (self.zoom_factor / old_zoom);
            self.pan_y *= (self.zoom_factor / old_zoom);
            return;
        },
        c.SDLK_MINUS, c.SDLK_KP_MINUS => {
            const old_zoom = self.zoom_factor;
            self.zoom_factor = std.math.clamp(self.zoom_factor - 0.1, 0.1, 10.0);
            self.pan_x *= (self.zoom_factor / old_zoom);
            self.pan_y *= (self.zoom_factor / old_zoom);
            return;
        },
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
            try self.triggerAction(shortcut.action_id);
            return;
        }
    }
}
