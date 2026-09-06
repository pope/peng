const std = @import("std");
const clay = @import("zclay");
const state_pkg = @import("state");
const app_state = @import("../state.zig");
const FrameContext = @import("root.zig").FrameContext;
const Key = state_pkg.Key;
const KeyModifiers = state_pkg.KeyModifiers;
const FrameInput = state_pkg.FrameInput;
const AppState = app_state.AppState;
const stopTextInput = app_state.stopTextInput;

/// Processes Return key confirmation for 1-based image index input palette mode (`.go_to_image`).
fn handlePaletteReturnGoToImage(self: *AppState, raw_str: []const u8) !void {
    if (raw_str.len > 0) {
        if (std.fmt.parseInt(usize, raw_str, 10)) |v| {
            if (v >= 1 and v <= self.viewer.navigation.image_list.items.len) {
                self.viewer.navigation.current_index = v - 1;
                self.viewer.ui.palette.mode = .inactive;
                stopTextInput(self.viewer.display);
            }
        } else |err| {
            std.log.debug("Failed to parse go-to-image index '{s}': {}", .{ raw_str, err });
        }
    }
}

/// Processes Return key confirmation for slideshow interval input palette mode (`.set_slideshow_interval`).
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

/// Processes Return key selection for directory navigator palette mode (`.directory_navigator`).
/// Shift+Return scans the current folder; Return scans the currently highlighted subfolder entry.
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
                switch (entry) {
                    .archive_file => |a| try self.handlePathSelection(a.full_path),
                    else => try self.startAsyncPathScan(entry.getFullPath(), true),
                }
                self.viewer.ui.palette.reset();
                stopTextInput(self.viewer.display);
            }
        }
    }
}

/// Handles keyboard shortcut navigation keys (Escape, Up/Down, Left/Right, PageUp/PageDown, Return, Backspace)
/// while a command palette overlay is active.
///
/// Returns `true` if the key was consumed by palette navigation; `false` otherwise.
fn handlePaletteKeys(
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
                        const path_copy = try self.allocator.dupe(u8, entry.getFullPath());
                        defer self.allocator.free(path_copy);
                        palette.query.clearRetainingCapacity();
                        try self.loadPaletteDirectory(path_copy);
                    }
                }
                return true;
            }
        },
        .left => {
            if (palette.mode == .directory_navigator) {
                var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (core_fs.getParentDirBuf(palette.current_nav_dir.items, &parent_buf)) |parent_dir| {
                    palette.query.clearRetainingCapacity();
                    try self.loadPaletteDirectory(parent_dir);
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
                if (core_fs.getParentDirBuf(palette.current_nav_dir.items, &parent_buf)) |parent_dir| {
                    palette.query.clearRetainingCapacity();
                    try self.loadPaletteDirectory(parent_dir);
                }
            }
            return true;
        },
        else => return false,
    }
    return false;
}

const core_fs = @import("../core/fs.zig");

/// System Pass: Process active Command Palette text typing, list navigation, and click-outside dismissal.
///
/// Responsibilities:
/// 1. Ingests text typing input characters and updates search query buffer.
/// 2. Triggers fuzzy match filter rebuilds for active palette mode (`.files`, `.actions`, `.directory_navigator`).
/// 3. Detects mouse left-click outside palette bounds and deactivates open command palette overlay.
///
/// Returns `true` if an active command palette was dismissed on this frame; `false` otherwise.
pub fn sysProcessPaletteInput(ctx: FrameContext) !bool {
    const self = ctx.state;
    const input = ctx.input orelse return false;

    if (self.viewer.ui.palette.mode == .inactive) return false;

    // 1. Keyboard Navigation Keys
    for (input.keys_pressed.items) |key| {
        _ = try handlePaletteKeys(self, key, input.key_modifiers);
    }
    if (self.viewer.ui.palette.mode == .inactive) return true;

    // 2. Text Typing Query Updates
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

    // 3. Selection Scrolling Synchronization
    if (self.viewer.ui.palette.selection_dirty) {
        const cfg = state_pkg.getPaletteConfig(self.viewer.ui.palette.mode);
        const scroll_data = clay.cdefs.Clay_GetScrollContainerData(clay.getElementId(cfg.list_id));
        if (scroll_data.found) {
            const item_height = cfg.base_item_height;
            const viewport_height = 320.0;
            const item_top = @as(f32, @floatFromInt(self.viewer.ui.palette.selected_idx)) * item_height;
            const item_bottom = item_top + item_height;
            const visible_top = -scroll_data.scroll_position.y;
            const visible_bottom = visible_top + viewport_height;

            if (item_top < visible_top) {
                scroll_data.scroll_position.y = -item_top;
            } else if (item_bottom > visible_bottom) {
                scroll_data.scroll_position.y = -(item_bottom - viewport_height);
            }
            self.viewer.ui.palette.selection_dirty = false;
        }
    }

    // 4. Mouse Pointer & Click Processing
    var palette_closed_this_frame = false;
    if (input.mouse_left_clicked) {
        const is_in_debug_panel = input.isPointerInDebugPanel();
        const cfg = state_pkg.getPaletteConfig(self.viewer.ui.palette.mode);

        if (!clay.pointerOver(clay.getElementId(cfg.element_id)) and !is_in_debug_panel) {
            self.viewer.ui.palette.mode = .inactive;
            stopTextInput(self.viewer.display);
            palette_closed_this_frame = true;
        } else if (!is_in_debug_panel) {
            // Check if a list item was clicked
            for (self.viewer.ui.palette.matches.items) |real_idx| {
                var item_id_buf: [64]u8 = undefined;
                const item_id_str = std.fmt.bufPrint(&item_id_buf, "{s}{}", .{ cfg.item_prefix, real_idx }) catch cfg.item_prefix;
                if (clay.pointerOver(clay.getElementId(item_id_str))) {
                    const old_type = self.viewer.ui.palette.mode;
                    switch (self.viewer.ui.palette.mode) {
                        .files => {
                            try self.pushIntent(.{ .go_to_image = real_idx });
                            self.viewer.ui.palette.mode = .inactive;
                            stopTextInput(self.viewer.display);
                            palette_closed_this_frame = true;
                        },
                        .actions => {
                            const item = state_pkg.palette_action_items[real_idx];
                            try self.pushIntent(item.intent);
                            if (self.viewer.ui.palette.mode == old_type) {
                                self.viewer.ui.palette.mode = .inactive;
                                stopTextInput(self.viewer.display);
                                palette_closed_this_frame = true;
                            }
                        },
                        .directory_navigator => {
                            if (real_idx < self.viewer.ui.palette.dir_items.items.len) {
                                const entry = self.viewer.ui.palette.dir_items.items[real_idx];
                                const path_copy = try ctx.frame_allocator.dupe(u8, entry.getFullPath());
                                try self.pushIntent(.{
                                    .set_palette = .{ .mode = .directory_navigator, .query = path_copy },
                                });
                            }
                        },
                        else => {},
                    }
                    break;
                }
            }
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
    try state.loadPaletteDirectory(tmp_dir);
    state.viewer.ui.palette.mode = .directory_navigator;

    // Locate index of sub_no_images
    var match_idx_no_img: usize = 0;
    for (state.viewer.ui.palette.dir_items.items, 0..) |item, i| {
        if (std.mem.eql(u8, item.getName(), "sub_no_images")) {
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
    try state.loadPaletteDirectory(tmp_dir);
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

    try state.loadPaletteDirectory(".");
    state.viewer.ui.palette.mode = .directory_navigator;
    try std.testing.expectEqualStrings(".", state.viewer.ui.palette.current_nav_dir.items);

    _ = try handlePaletteKeys(&state, .left, .{});
    try std.testing.expectEqualStrings("..", state.viewer.ui.palette.current_nav_dir.items);

    var found_cwd_selected = false;
    if (state.viewer.ui.palette.selected_idx < state.viewer.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.viewer.ui.palette.dir_items.items[state.viewer.ui.palette.selected_idx].getName(), "peng")) {
            found_cwd_selected = true;
        }
    }
    try std.testing.expect(found_cwd_selected);
}
