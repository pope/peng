const app_state = @import("../state.zig");
const clay = @import("zclay");
const context = @import("context.zig");
const core_fs = @import("../core/fs.zig");
const intents = @import("intents");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;
const FrameInput = state_pkg.FrameInput;
const Key = state_pkg.Key;
const KeyModifiers = state_pkg.KeyModifiers;
const PaletteMode = intents.PaletteMode;

/// Processes Return key confirmation for 1-based image index input palette mode (`.go_to_image`).
fn handlePaletteReturnGoToImage(ctx: FrameContext, raw_str: []const u8) !void {
    if (raw_str.len > 0) {
        if (std.fmt.parseInt(usize, raw_str, 10)) |v| {
            if (v >= 1 and v <= ctx.state.viewer.navigation.image_list.items.len) {
                try ctx.state.pushIntent(.{ .go_to_image = v - 1 });
                ctx.state.closePalette();
            }
        } else |err| {
            std.log.debug("Failed to parse go-to-image index '{s}': {}", .{ raw_str, err });
        }
    }
}

/// Processes Return key confirmation for slideshow interval input palette mode (`.set_slideshow_interval`).
fn handlePaletteReturnSlideshow(ctx: FrameContext, raw_str: []const u8) !void {
    if (raw_str.len > 0) {
        if (std.fmt.parseFloat(f32, raw_str)) |val| {
            if (!std.math.isNan(val) and !std.math.isInf(val) and val > 0.0) {
                ctx.state.viewer.navigation.slideshow = .{
                    .active = .{
                        .interval_s = val,
                        .timer_ms = 0.0,
                    },
                };
                ctx.state.closePalette();
            }
        } else |err| {
            std.log.debug("Failed to parse slideshow interval '{s}': {}", .{ raw_str, err });
        }
    }
}

/// Processes Return key selection for directory navigator palette mode (`.directory_navigator`).
/// Shift+Return scans the current folder; Return scans the currently highlighted subfolder entry.
fn handlePaletteReturnDirectory(ctx: FrameContext, mod: KeyModifiers) !void {
    const palette = &ctx.state.viewer.ui.palette;
    if (mod.shift) {
        const p = try ctx.frame_allocator.dupe(u8, palette.current_nav_dir.items);
        try ctx.state.pushIntent(.{ .open_path = p });
        ctx.state.closePalette();
    } else {
        if (palette.selected_idx < palette.matches.items.len) {
            const match_idx = palette.matches.items[palette.selected_idx];
            if (match_idx < palette.dir_items.items.len) {
                const entry = palette.dir_items.items[match_idx];
                const full_path = entry.getFullPath();
                if (full_path.len > 0) {
                    const p = try ctx.frame_allocator.dupe(u8, full_path);
                    try ctx.state.pushIntent(.{ .open_path = p });
                    ctx.state.closePalette();
                }
            }
        }
    }
}

/// Handles keyboard shortcut navigation keys (Escape, Up/Down, Left/Right, PageUp/PageDown, Return, Backspace)
/// while a command palette overlay is active.
///
/// Returns `true` if the key was consumed by palette navigation; `false` otherwise.
fn handlePaletteKeys(
    ctx: FrameContext,
    key: Key,
    mod: KeyModifiers,
) !bool {
    const self = ctx.state;
    const palette = &self.viewer.ui.palette;

    switch (key) {
        .escape => {
            self.closePalette();
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
            const max_count = palette.matches.items.len;
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
                        const path_copy = try ctx.frame_allocator.dupe(u8, entry.getFullPath());
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
            const max_count = palette.matches.items.len;
            if (max_count > 0) {
                palette.selected_idx = @min(palette.selected_idx + 5, max_count - 1);
                palette.selection_dirty = true;
            }
            return true;
        },
        .return_key => {
            const raw_str = palette.query.items;
            switch (palette.mode) {
                .go_to_image => try handlePaletteReturnGoToImage(ctx, raw_str),
                .set_slideshow_interval => try handlePaletteReturnSlideshow(ctx, raw_str),
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
                                    self.closePalette();
                                }
                            }
                        } else |err| {
                            std.log.debug("Failed to parse brightness/contrast value '{s}': {}", .{ raw_str, err });
                        }
                    }
                },
                .directory_navigator => try handlePaletteReturnDirectory(ctx, mod),
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
                    self.closePalette();
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

    if (!self.viewer.ui.palette.isAcceptingInput()) return false;

    // 1. Keyboard Navigation Keys
    for (input.keys_pressed.items) |key| {
        _ = try handlePaletteKeys(ctx, key, input.key_modifiers);
    }
    if (!self.viewer.ui.palette.isAcceptingInput()) return true;

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
            self.closePalette();
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
                            self.closePalette();
                            palette_closed_this_frame = true;
                        },
                        .actions => {
                            const item = state_pkg.palette_action_items[real_idx];
                            try self.pushIntent(item.intent);
                            if (self.viewer.ui.palette.mode == old_type) {
                                self.closePalette();
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

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };

    // Test Right key on sub_no_images -> navigate into folder
    state.viewer.ui.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(ctx, .right, .{});
    try std.testing.expectEqual(PaletteMode.directory_navigator, state.viewer.ui.palette.mode);
    try std.testing.expectEqualStrings(sub_no_img, state.viewer.ui.palette.current_nav_dir.items);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.ui.palette.query.items.len);

    // Test Left key -> step up to parent directory, remembering sub_no_images
    _ = try handlePaletteKeys(ctx, .left, .{});
    try std.testing.expectEqual(PaletteMode.directory_navigator, state.viewer.ui.palette.mode);
    try std.testing.expectEqualStrings(tmp_dir, state.viewer.ui.palette.current_nav_dir.items);
    try std.testing.expectEqual(match_idx_no_img, state.viewer.ui.palette.selected_idx);

    // Test Enter key on sub_no_images -> starts async path scan for sub_no_images and closes palette
    state.viewer.ui.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(ctx, .return_key, .{});
    try std.testing.expectEqual(PaletteMode.inactive, state.viewer.ui.palette.mode);

    // Re-open palette
    try state.loadPaletteDirectory(tmp_dir);
    state.viewer.ui.palette.mode = .directory_navigator;

    // Test Shift+Enter key on current directory -> starts async path scan and closes palette
    _ = try handlePaletteKeys(ctx, .return_key, .{ .shift = true });
    try std.testing.expectEqual(PaletteMode.inactive, state.viewer.ui.palette.mode);
}

test "handlePaletteKeys stepping up from dot to parent directory preselects working dir" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.loadPaletteDirectory(".");
    state.viewer.ui.palette.mode = .directory_navigator;
    try std.testing.expectEqualStrings(".", state.viewer.ui.palette.current_nav_dir.items);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    _ = try handlePaletteKeys(ctx, .left, .{});
    try std.testing.expectEqualStrings("..", state.viewer.ui.palette.current_nav_dir.items);

    var found_cwd_selected = false;
    if (state.viewer.ui.palette.selected_idx < state.viewer.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.viewer.ui.palette.dir_items.items[state.viewer.ui.palette.selected_idx].getName(), "peng")) {
            found_cwd_selected = true;
        }
    }
    try std.testing.expect(found_cwd_selected);
}

test "sysProcessPaletteInput retains palette when clicking inside debug panel" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const win_w: f32 = 800.0;
    const win_h: f32 = 600.0;
    const debug_w: f32 = 280.0;
    state.viewer.display.window_width = @intFromFloat(win_w);
    state.viewer.display.window_height = @intFromFloat(win_h);
    state.viewer.ui.debug_tools_visible = true;

    const input_inside = state_pkg.FrameInput{
        .win_w = win_w,
        .win_h = win_h,
        .pix_w = win_w,
        .pix_h = win_h,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .dpi_scale = 1.0,
        .mouse_x = win_w - debug_w + 10.0,
        .mouse_y = 100.0,
        .mouse_left_down = false,
        .mouse_left_clicked = true,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };

    state.viewer.ui.palette.mode = .actions;
    _ = try sysProcessPaletteInput(.{ .state = &state, .frame_allocator = allocator, .input = input_inside });
    try std.testing.expect(state.viewer.ui.palette.mode == .actions);
}

test "openPalette directory_navigator starting directory rules" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_open_dir_test";
    std.Io.Dir.createDirPath(cwd, io, tmp_dir ++ "/sub1") catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Rule 1: current_index is valid -> starting directory is dirname of current image
    const sample_path = tmp_dir ++ "/image1.jpg";
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = sample_path } });
    state.viewer.navigation.current_index = 0;

    try state.openPalette(.directory_navigator);
    try std.testing.expectEqual(PaletteMode.directory_navigator, state.viewer.ui.palette.mode);
    try std.testing.expectEqualStrings(tmp_dir, state.viewer.ui.palette.current_nav_dir.items);

    // Rule 2: current_index is null -> starting directory remembers last_nav_dir
    state.viewer.navigation.current_index = null;
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(tmp_dir, state.viewer.ui.palette.current_nav_dir.items);

    // Rule 3: current_index is null and last_nav_dir is empty -> starting directory falls back to "."
    state.viewer.ui.palette.last_nav_dir.clearRetainingCapacity();
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(".", state.viewer.ui.palette.current_nav_dir.items);

    // Rule 4: current_index out of bounds and last_nav_dir is empty -> starting directory falls back to "."
    state.viewer.navigation.current_index = 999;
    state.viewer.ui.palette.last_nav_dir.clearRetainingCapacity();
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(".", state.viewer.ui.palette.current_nav_dir.items);
}

test "openPalette directory_navigator steps up if 0 subdirectories" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_dir = "testfiles/tmp_palette_step_up_test";
    const sub_leaf = tmp_dir ++ "/child_leaf";
    std.Io.Dir.createDirPath(cwd, io, sub_leaf) catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, tmp_dir) catch {};
    }

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Image in child_leaf (which has 0 subdirectories itself)
    const img_path = sub_leaf ++ "/photo.png";
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = img_path } });
    state.viewer.navigation.current_index = 0;

    // openPalette should see sub_leaf has 0 subdirectories, so it steps up to tmp_dir and pre-selects child_leaf
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(tmp_dir, state.viewer.ui.palette.current_nav_dir.items);

    // Verify child_leaf is selected
    var found_leaf_selected = false;
    if (state.viewer.ui.palette.selected_idx < state.viewer.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.viewer.ui.palette.dir_items.items[state.viewer.ui.palette.selected_idx].getName(), "child_leaf")) {
            found_leaf_selected = true;
        }
    }
    try std.testing.expect(found_leaf_selected);
}

test "openPalette steps up from top-level relative leaf dir without slashes to dot" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const top_leaf = "tmp_top_level_leaf_test";
    std.Io.Dir.createDirPath(cwd, io, top_leaf) catch {};
    defer {
        std.Io.Dir.deleteTree(cwd, io, top_leaf) catch {};
    }

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const img_path = top_leaf ++ "/photo.png";
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = img_path } });
    state.viewer.navigation.current_index = 0;

    try state.openPalette(.directory_navigator);
    // Should step up to "." because top_leaf has 0 subdirectories
    try std.testing.expectEqualStrings(".", state.viewer.ui.palette.current_nav_dir.items);

    // Verify top_leaf is pre-selected in "."
    var found_leaf_selected = false;
    if (state.viewer.ui.palette.selected_idx < state.viewer.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.viewer.ui.palette.dir_items.items[state.viewer.ui.palette.selected_idx].getName(), top_leaf)) {
            found_leaf_selected = true;
        }
    }
    try std.testing.expect(found_leaf_selected);
}
