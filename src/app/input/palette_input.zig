const std = @import("std");
const state = @import("state");
const app_state = @import("../state.zig");
const app_palette = @import("../palette.zig");
const systems = @import("../systems.zig");
const fs = @import("../fs.zig");
const Key = state.Key;
const KeyModifiers = state.KeyModifiers;
const AppState = app_state.AppState;
const stopTextInput = app_state.stopTextInput;

fn handlePaletteReturnGoToImage(self: *AppState, raw_str: []const u8) !void {
    if (raw_str.len > 0) {
        if (std.fmt.parseInt(usize, raw_str, 10)) |v| {
            if (v >= 1 and v <= self.viewer.navigation.image_list.items.len) {
                self.viewer.navigation.current_index = v - 1;
                try systems.sysUpdateCache(self);
                self.viewer.ui.palette.mode = .inactive;
                stopTextInput(self.viewer.display);
            }
        } else |err| {
            std.log.debug("Failed to parse go-to-image index '{s}': {}", .{ raw_str, err });
        }
    }
}

fn handlePaletteReturnSlideshow(self: *AppState, raw_str: []const u8) !void {
    if (raw_str.len > 0) {
        if (std.fmt.parseFloat(f32, raw_str)) |val| {
            if (!std.math.isNan(val) and !std.math.isInf(val) and val > 0.0) {
                self.viewer.navigation.slideshow = .{
                    .active = .{
                        .interval_s = val,
                        .timer_ms = 0.0,
                    },
                };
                self.viewer.ui.palette.mode = .inactive;
                stopTextInput(self.viewer.display);
            }
        } else |err| {
            std.log.debug("Failed to parse slideshow interval '{s}': {}", .{ raw_str, err });
        }
    }
}

fn handlePaletteReturnDirectory(self: *AppState, mod: KeyModifiers) !void {
    const palette = &self.viewer.ui.palette;
    if (mod.shift) {
        try self.startAsyncPathScan(palette.current_nav_dir.items, true);
        self.viewer.ui.palette.reset();
        stopTextInput(self.viewer.display);
    } else {
        if (palette.selected_idx < palette.matches.items.len) {
            const match_idx = palette.matches.items[palette.selected_idx];
            if (match_idx < palette.dir_items.items.len) {
                const entry = palette.dir_items.items[match_idx];
                try self.startAsyncPathScan(entry.full_path, true);
                self.viewer.ui.palette.reset();
                stopTextInput(self.viewer.display);
            }
        }
    }
}

pub fn handlePaletteKeys(
    self: *AppState,
    key: Key,
    mod: KeyModifiers,
) !bool {
    const palette = &self.viewer.ui.palette;

    switch (key) {
        .escape => {
            palette.mode = .inactive;
            stopTextInput(self.viewer.display);
            return true;
        },
        .up => {
            if (palette.selected_idx > 0) {
                palette.selected_idx -= 1;
                palette.selection_dirty = true;
            }
            return true;
        },
        .down => {
            const max_count = if (palette.mode == .directory_navigator) palette.dir_items.items.len else palette.matches.items.len;
            if (max_count > 0 and palette.selected_idx + 1 < max_count) {
                palette.selected_idx += 1;
                palette.selection_dirty = true;
            }
            return true;
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
                        try app_palette.loadDirectoryEntries(palette, self.io, path_copy);
                    }
                }
                return true;
            }
        },
        .left => {
            if (palette.mode == .directory_navigator) {
                var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (fs.getParentDirBuf(palette.current_nav_dir.items, &parent_buf)) |parent_dir| {
                    palette.query.clearRetainingCapacity();
                    try app_palette.loadDirectoryEntries(palette, self.io, parent_dir);
                }
                return true;
            }
        },
        .page_up => {
            if (palette.selected_idx >= 5) {
                palette.selected_idx -= 5;
            } else {
                palette.selected_idx = 0;
            }
            palette.selection_dirty = true;
            return true;
        },
        .page_down => {
            const max_count = if (palette.mode == .directory_navigator) palette.dir_items.items.len else palette.matches.items.len;
            if (max_count > 0) {
                palette.selected_idx = @min(palette.selected_idx + 5, max_count - 1);
                palette.selection_dirty = true;
            }
            return true;
        },
        .return_key => {
            const raw_str = palette.query.items;
            switch (palette.mode) {
                .go_to_image => try handlePaletteReturnGoToImage(self, raw_str),
                .set_slideshow_interval => try handlePaletteReturnSlideshow(self, raw_str),
                .set_brightness, .set_contrast => {
                    if (raw_str.len > 0) {
                        if (std.fmt.parseFloat(f32, raw_str)) |val| {
                            if (!std.math.isNan(val) and !std.math.isInf(val)) {
                                const min_val: f32 = if (palette.mode == .set_brightness) -1.0 else 0.0;
                                const max_val: f32 = if (palette.mode == .set_brightness) 1.0 else 5.0;
                                if (val >= min_val and val <= max_val) {
                                    if (palette.mode == .set_brightness) {
                                        try self.pushIntent(.{ .set_brightness = val });
                                    } else {
                                        try self.pushIntent(.{ .set_contrast = val });
                                    }
                                    palette.mode = .inactive;
                                    stopTextInput(self.viewer.display);
                                }
                            }
                        } else |err| {
                            std.log.debug("Failed to parse brightness/contrast value '{s}': {}", .{ raw_str, err });
                        }
                    }
                },
                .directory_navigator => try handlePaletteReturnDirectory(self, mod),
                .files, .actions => {
                    if (palette.selected_idx < palette.matches.items.len) {
                        const target_idx = palette.matches.items[palette.selected_idx];
                        if (palette.mode == .files) {
                            try self.pushIntent(.{ .go_to_image = target_idx });
                        } else if (palette.mode == .actions) {
                            const item = state.palette_action_items[target_idx];
                            try self.pushIntent(item.intent);
                        }
                    }
                    palette.mode = .inactive;
                    stopTextInput(self.viewer.display);
                },
                .inactive => return false,
            }
            return true;
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
                    try app_palette.loadDirectoryEntries(palette, self.io, parent_dir);
                }
            }
            return true;
        },
        else => return false,
    }
    return false;
}
