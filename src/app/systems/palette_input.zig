const std = @import("std");
const clay = @import("zclay");
const state_pkg = @import("state");
const app_state = @import("../state.zig");
const app_palette = @import("../palette.zig");
const systems = @import("../systems.zig");
const fs = @import("../fs.zig");
const Key = state_pkg.Key;
const KeyModifiers = state_pkg.KeyModifiers;
const FrameInput = state_pkg.FrameInput;
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
                            const item = state_pkg.palette_action_items[target_idx];
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

/// System Pass: Process active Command Palette text typing, list navigation, and click-outside dismissal.
/// Returns true if a open palette was dismissed on this frame.
pub fn sysProcessPaletteInput(self: *AppState, input: FrameInput) !bool {
    if (self.viewer.ui.palette.mode == .inactive) return false;

    // 1. Text Typing Query Updates
    if (input.text_input) |text| {
        try self.viewer.ui.palette.query.appendSlice(self.allocator, text);
        self.viewer.ui.palette.selected_idx = 0;
        self.viewer.ui.palette.selection_dirty = true;
        switch (self.viewer.ui.palette.mode) {
            .files => try self.rebuildPaletteMatches(),
            .actions => try self.rebuildActionMatches(),
            .directory_navigator => try self.viewer.ui.palette.rebuildDirectoryMatches(),
            else => {},
        }
    }

    // 2. Click-Outside Dismissal
    var palette_closed_this_frame = false;
    if (input.mouse_left_clicked) {
        const is_in_debug_panel = input.isPointerInDebugPanel();
        const element_id = switch (self.viewer.ui.palette.mode) {
            .files => "CommandPalette",
            .actions => "ActionPalette",
            .set_brightness => "BrightnessPalette",
            .set_contrast => "ContrastPalette",
            .go_to_image => "GoToImagePalette",
            .directory_navigator => "DirectoryNavigatorPalette",
            .set_slideshow_interval => "SlideshowPalette",
            .inactive => unreachable,
        };
        if (!clay.pointerOver(clay.getElementId(element_id)) and !is_in_debug_panel) {
            self.viewer.ui.palette.mode = .inactive;
            stopTextInput(self.viewer.display);
            palette_closed_this_frame = true;
        }
    }

    return palette_closed_this_frame;
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

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // 1. Open directory navigator at tmp_dir
    try app_palette.loadDirectoryEntries(&state.viewer.ui.palette, io, tmp_dir);
    state.viewer.ui.palette.mode = .directory_navigator;

    // Locate index of sub_no_images
    var match_idx_no_img: usize = 0;
    for (state.viewer.ui.palette.dir_items.items, 0..) |item, i| {
        if (std.mem.eql(u8, item.name, "sub_no_images")) {
            match_idx_no_img = i;
            break;
        }
    }

    // Test Right key on sub_no_images -> navigate into folder
    state.viewer.ui.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(&state, .right, .{});
    try std.testing.expectEqual(state_pkg.PaletteMode.directory_navigator, state.viewer.ui.palette.mode);
    try std.testing.expectEqualStrings(sub_no_img, state.viewer.ui.palette.current_nav_dir.items);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.ui.palette.query.items.len);

    // Test Left key -> step up to parent directory, remembering sub_no_images
    _ = try handlePaletteKeys(&state, .left, .{});
    try std.testing.expectEqual(state_pkg.PaletteMode.directory_navigator, state.viewer.ui.palette.mode);
    try std.testing.expectEqualStrings(tmp_dir, state.viewer.ui.palette.current_nav_dir.items);
    try std.testing.expectEqual(match_idx_no_img, state.viewer.ui.palette.selected_idx);

    // Test Enter key on sub_no_images -> starts async path scan for sub_no_images and closes palette
    state.viewer.ui.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(&state, .return_key, .{});
    try std.testing.expectEqual(state_pkg.PaletteMode.inactive, state.viewer.ui.palette.mode);

    // Re-open palette
    try app_palette.loadDirectoryEntries(&state.viewer.ui.palette, io, tmp_dir);
    state.viewer.ui.palette.mode = .directory_navigator;

    // Test Shift+Enter key on current directory -> starts async path scan and closes palette
    _ = try handlePaletteKeys(&state, .return_key, .{ .shift = true });
    try std.testing.expectEqual(state_pkg.PaletteMode.inactive, state.viewer.ui.palette.mode);
}

test "handlePaletteKeys stepping up from dot to parent directory preselects working dir" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try app_palette.loadDirectoryEntries(&state.viewer.ui.palette, io, ".");
    state.viewer.ui.palette.mode = .directory_navigator;
    try std.testing.expectEqualStrings(".", state.viewer.ui.palette.current_nav_dir.items);

    _ = try handlePaletteKeys(&state, .left, .{});
    try std.testing.expectEqualStrings("..", state.viewer.ui.palette.current_nav_dir.items);

    var found_cwd_selected = false;
    if (state.viewer.ui.palette.selected_idx < state.viewer.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.viewer.ui.palette.dir_items.items[state.viewer.ui.palette.selected_idx].name, "peng")) {
            found_cwd_selected = true;
        }
    }
    try std.testing.expect(found_cwd_selected);
}
