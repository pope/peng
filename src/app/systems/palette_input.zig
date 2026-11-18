const app_state = @import("../state.zig");
const context = @import("context.zig");
const intents = @import("intents");
const state_pkg = @import("state");
const std = @import("std");
const vfs = @import("vfs");

const ActivePaletteMode = intents.ActivePaletteMode;
const AppState = app_state.AppState;
const EditParam = intents.EditParam;
const FrameContext = context.FrameContext;
const FrameInput = state_pkg.FrameInput;
const getParentDirBuf = vfs.getParentDirBuf;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;
const palette_action_items = intents.actions.palette_action_items;

/// Processes Return key confirmation for 1-based image index input palette mode
/// (`.prompt = .go_to_image`).
fn handlePaletteReturnGoToImage(ctx: FrameContext, raw_str: []const u8) !void {
    if (raw_str.len > 0) {
        if (std.fmt.parseInt(usize, raw_str, 10)) |v| {
            if (v >= 1 and v <= ctx.state.viewer.navigation.count()) {
                try ctx.state.pushIntent(.{ .go_to_image = v - 1 });
                ctx.state.closePalette();
            }
        } else |err| {
            std.log.debug("Failed to parse go-to-image index '{s}': {}", .{ raw_str, err });
        }
    }
}

/// Processes Return key confirmation for slideshow interval input palette mode
/// (`.prompt = .slideshow_interval`).
fn handlePaletteReturnSlideshow(ctx: FrameContext, raw_str: []const u8) !void {
    if (raw_str.len > 0) {
        if (std.fmt.parseFloat(f32, raw_str)) |val| {
            if (!std.math.isNan(val) and !std.math.isInf(val) and val > 0.0) {
                try ctx.state.pushIntent(.{ .start_slideshow_interval = val });
                ctx.state.closePalette();
            }
        } else |err| {
            std.log.debug(
                "Failed to parse slideshow interval '{s}': {}",
                .{ raw_str, err },
            );
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
        return;
    }
    if (palette.selected_idx >= palette.matches.items.len) return;
    const match_idx = palette.matches.items[palette.selected_idx];
    if (match_idx >= palette.dir_items.items.len) return;
    const entry = palette.dir_items.items[match_idx];
    const full_path = entry.getFullPath();
    if (full_path.len == 0) return;

    const p = try ctx.frame_allocator.dupe(u8, full_path);
    try ctx.state.pushIntent(.{ .open_path = p });
    ctx.state.closePalette();
}

fn handlePaletteReturnEditParam(
    ctx: FrameContext,
    param: EditParam,
    raw_str: []const u8,
) !void {
    const self = ctx.state;
    const spec = intents.getSpec(param);
    if (raw_str.len == 0) return;

    const val = std.fmt.parseFloat(f32, raw_str) catch |err| {
        std.log.debug(
            "Failed to parse {s} value '{s}': {}",
            .{ spec.slug, raw_str, err },
        );
        return;
    };
    if (std.math.isNan(val) or std.math.isInf(val)) return;
    if (val < spec.min or val > spec.max) return;

    try self.pushIntent(.{
        .adjust = .{
            .set = .{
                .param = param,
                .value = val,
            },
        },
    });
    self.closePalette();
}

fn handlePaletteReturnMatchSelection(ctx: FrameContext) !void {
    const self = ctx.state;
    const palette = &self.viewer.ui.palette;
    defer self.closePalette();

    if (palette.selected_idx >= palette.matches.items.len) return;
    const target_idx = palette.matches.items[palette.selected_idx];
    const mode = palette.openMode() orelse return;
    switch (mode) {
        .files => try self.pushIntent(.{ .go_to_image = target_idx }),
        .actions => {
            const item = palette_action_items[target_idx];
            try self.pushIntent(item.intent);
        },
        .directory_navigator, .prompt => {},
    }
}

fn handlePaletteDirectoryDrillDown(ctx: FrameContext) !void {
    const self = ctx.state;
    const palette = &self.viewer.ui.palette;
    if (palette.selected_idx >= palette.matches.items.len) return;
    const match_idx = palette.matches.items[palette.selected_idx];
    if (match_idx >= palette.dir_items.items.len) return;
    const entry = palette.dir_items.items[match_idx];
    if (entry.isArchive()) return;
    const full_path = entry.getFullPath();
    if (full_path.len == 0) return;
    const path_copy = try ctx.frame_allocator.dupe(u8, full_path);
    defer ctx.frame_allocator.free(path_copy);
    palette.query.clearRetainingCapacity();
    try self.loadPaletteDirectory(path_copy);
}

/// Handles keyboard shortcut navigation keys (Escape, Up/Down, Left/Right,
/// PageUp/PageDown, Return, Backspace) while a command palette overlay is
/// active.
///
/// Returns `true` if `text_input` should be suppressed for the current frame
/// (e.g. modifier shortcuts, modal dismissal, or directory drill-down/step-up).
fn handlePaletteKeys(
    ctx: FrameContext,
    key: Key,
    mod: KeyModifiers,
) !bool {
    const self = ctx.state;
    const palette = &self.viewer.ui.palette;
    const entries = self.viewer.navigation.getEntries();

    // Cancel / Close palette: Escape or Ctrl+G
    if (key == .escape or (key == .char_g and mod.ctrl)) {
        self.closePalette();
        return true;
    }

    // List Navigation Up: Up Arrow or Ctrl+P
    if (key == .up or (key == .char_p and mod.ctrl)) {
        palette.moveSelectionUp();
        return mod.ctrl;
    }

    // List Navigation Down: Down Arrow or Ctrl+N or Ctrl+J
    if (key == .down or ((key == .char_n or key == .char_j) and mod.ctrl)) {
        palette.moveSelectionDown();
        return mod.ctrl;
    }

    // Page Up: PageUp or Alt+V
    if (key == .page_up or (key == .char_v and mod.alt)) {
        palette.pageSelectionUp();
        return mod.alt;
    }

    // Page Down: PageDown or Ctrl+V
    if (key == .page_down or (key == .char_v and mod.ctrl)) {
        palette.pageSelectionDown();
        return mod.ctrl;
    }

    // Delete Word Backward: Ctrl+W or Alt+Backspace
    if ((key == .char_w and mod.ctrl) or (key == .backspace and mod.alt)) {
        _ = try palette.deleteWordBackward(self.allocator, entries);
        return true;
    }

    // Clear Line: Ctrl+U
    if (key == .char_u and mod.ctrl) {
        _ = try palette.clearQuery(self.allocator, entries);
        return true;
    }

    switch (key) {
        .right, .tab => {
            if (palette.openMode()) |mode| switch (mode) {
                .directory_navigator => {
                    if (key == .tab and mod.shift) {
                        const parent_buf = try ctx.frame_allocator.alloc(
                            u8,
                            std.Io.Dir.max_path_bytes,
                        );
                        defer ctx.frame_allocator.free(parent_buf);
                        if (getParentDirBuf(
                            palette.current_nav_dir.items,
                            parent_buf,
                        )) |parent_dir| {
                            palette.query.clearRetainingCapacity();
                            try self.loadPaletteDirectory(parent_dir);
                        }
                    } else {
                        try handlePaletteDirectoryDrillDown(ctx);
                    }
                    return true;
                },
                .files, .actions, .prompt => {},
            };
        },
        .left => {
            if (palette.openMode()) |mode| switch (mode) {
                .directory_navigator => {
                    const parent_buf = try ctx.frame_allocator.alloc(
                        u8,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer ctx.frame_allocator.free(parent_buf);
                    if (getParentDirBuf(
                        palette.current_nav_dir.items,
                        parent_buf,
                    )) |parent_dir| {
                        palette.query.clearRetainingCapacity();
                        try self.loadPaletteDirectory(parent_dir);
                    }
                    return true;
                },
                .files, .actions, .prompt => {},
            };
        },
        .return_key => {
            const raw_str = palette.query.items;
            const mode = palette.openMode() orelse return false;
            switch (mode) {
                .prompt => |kind| switch (kind) {
                    .go_to_image => {
                        try handlePaletteReturnGoToImage(ctx, raw_str);
                    },
                    .slideshow_interval => {
                        try handlePaletteReturnSlideshow(ctx, raw_str);
                    },
                    .edit_param => |param| {
                        try handlePaletteReturnEditParam(ctx, param, raw_str);
                    },
                },
                .directory_navigator => {
                    try handlePaletteReturnDirectory(ctx, mod);
                },
                .files, .actions => try handlePaletteReturnMatchSelection(ctx),
            }
            return true;
        },

        .backspace => {
            if (try palette.deleteCharBackward(self.allocator, entries)) {
                return false;
            }
            if (palette.openMode()) |mode| switch (mode) {
                .directory_navigator => {
                    const parent_buf = try ctx.frame_allocator.alloc(
                        u8,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer ctx.frame_allocator.free(parent_buf);
                    if (getParentDirBuf(
                        palette.current_nav_dir.items,
                        parent_buf,
                    )) |parent_dir| {
                        palette.query.clearRetainingCapacity();
                        try self.loadPaletteDirectory(parent_dir);
                    }
                    return true;
                },
                .files, .actions, .prompt => {},
            };
            return false;
        },
        else => return false,
    }
    return false;
}

/// System Pass: Process active Command Palette text typing, list navigation,
/// and click-outside dismissal.
fn processPaletteItemClick(
    ctx: FrameContext,
    real_idx: usize,
) !bool {
    const self = ctx.state;
    const mode = self.viewer.ui.palette.openMode() orelse return false;
    switch (mode) {
        .files => {
            try self.pushIntent(.{ .go_to_image = real_idx });
            self.closePalette();
            return true;
        },
        .actions => {
            const item = palette_action_items[real_idx];
            try self.pushIntent(item.intent);
            self.closePalette();
            return true;
        },
        .directory_navigator => {
            const dir_items = self.viewer.ui.palette.dir_items.items;
            if (real_idx < dir_items.len) {
                const entry = dir_items[real_idx];
                const full_path = entry.getFullPath();
                if (full_path.len == 0) return false;
                const path_copy = try ctx.frame_allocator.dupe(
                    u8,
                    full_path,
                );
                if (entry.isArchive()) {
                    try self.pushIntent(.{ .open_path = path_copy });
                    self.closePalette();
                    return true;
                }
                try self.pushIntent(.{
                    .set_palette = .{
                        .mode = .directory_navigator,
                        .query = path_copy,
                    },
                });
            }
        },
        .prompt => {},
    }
    return false;
}

/// System Pass: Process active Command Palette text typing, list navigation,
/// and click-outside dismissal.
///
/// Responsibilities:
/// 1. Ingests text typing input characters and updates search query buffer.
/// 2. Triggers fuzzy match filter rebuilds for active palette mode
///    (`.files`, `.actions`, `.directory_navigator`).
/// 3. Detects mouse left-click outside palette bounds and deactivates open command palette overlay.
///
/// Returns `true` if an active command palette was dismissed on this frame; `false` otherwise.
pub fn sysProcessPaletteInput(ctx: FrameContext) !bool {
    const self = ctx.state;
    const input = ctx.input orelse return false;

    if (!self.viewer.ui.palette.isAcceptingInput()) return false;

    // 1. Keyboard Navigation Keys
    var suppress_text_input = false;
    for (input.keys_pressed.items) |key| {
        if (try handlePaletteKeys(ctx, key, input.key_modifiers)) {
            suppress_text_input = true;
        }
    }
    if (!self.viewer.ui.palette.isAcceptingInput()) return true;

    // 2. Text Typing Query Updates
    const has_cmd_mod = input.key_modifiers.ctrl or
        input.key_modifiers.alt or
        input.key_modifiers.gui;
    if (input.text_input) |text| {
        if (!suppress_text_input and !has_cmd_mod) {
            const entries = self.viewer.navigation.getEntries();
            _ = try self.viewer.ui.palette.appendPrintableText(
                self.allocator,
                text,
                entries,
            );
        }
    }

    // 3. Selection Scrolling Synchronization
    self.viewer.ui.interaction.syncPaletteScroll(&self.viewer.ui.palette);
    // 4. Mouse Pointer & Click Processing
    var palette_closed_this_frame = false;
    if (input.mouse_left_clicked) {
        const click_hit = self.viewer.ui.interaction.hitTestPaletteClick();
        switch (click_hit) {
            .inside_unmatched => {},
            .outside => {
                self.closePalette();
                palette_closed_this_frame = true;
            },
            .item => |real_idx| {
                palette_closed_this_frame = try processPaletteItemClick(
                    ctx,
                    real_idx,
                );
            },
        }
    }

    return palette_closed_this_frame;
}

test "handlePaletteKeys directory_navigator key interactions" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sub_has_images");
    try tmp.dir.createDirPath(io, "sub_no_images");
    var f = try tmp.dir.createFile(io, "sub_has_images/pic.png", .{});
    f.close(io);

    var tmp_dir_buf: [128]u8 = undefined;
    const tmp_dir = try std.mem.print(
        &tmp_dir_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    var sub_no_img_buf: [160]u8 = undefined;
    const sub_no_img = try std.mem.print(
        &sub_no_img_buf,
        "{s}/sub_no_images",
        .{tmp_dir},
    );

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    // 1. Open directory navigator at tmp_dir
    try state.loadPaletteDirectory(tmp_dir);
    state.viewer.ui.palette.lifecycle = .{ .open = .directory_navigator };

    // Locate index of sub_no_images
    var match_idx_no_img: usize = 0;
    for (state.viewer.ui.palette.dir_items.items, 0..) |item, i| {
        if (std.mem.eql(u8, item.getName(), "sub_no_images")) {
            match_idx_no_img = i;
            break;
        }
    }

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = frame_arena.allocator(),
    };

    // Test Right key on sub_no_images -> navigate into folder
    state.viewer.ui.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(ctx, .right, .{});
    try std.testing.expectEqual(
        @as(?ActivePaletteMode, .directory_navigator),
        state.viewer.ui.palette.openMode(),
    );
    try std.testing.expectEqualStrings(
        sub_no_img,
        state.viewer.ui.palette.current_nav_dir.items,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        state.viewer.ui.palette.query.items.len,
    );

    // Test Left key -> step up to parent directory, remembering sub_no_images
    _ = try handlePaletteKeys(ctx, .left, .{});
    try std.testing.expectEqual(
        @as(?ActivePaletteMode, .directory_navigator),
        state.viewer.ui.palette.openMode(),
    );
    try std.testing.expectEqualStrings(
        tmp_dir,
        state.viewer.ui.palette.current_nav_dir.items,
    );
    try std.testing.expectEqual(
        match_idx_no_img,
        state.viewer.ui.palette.selected_idx,
    );

    // Test Tab key on sub_no_images -> navigate into folder
    state.viewer.ui.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(ctx, .tab, .{});
    try std.testing.expectEqual(
        @as(?ActivePaletteMode, .directory_navigator),
        state.viewer.ui.palette.openMode(),
    );
    try std.testing.expectEqualStrings(
        sub_no_img,
        state.viewer.ui.palette.current_nav_dir.items,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        state.viewer.ui.palette.query.items.len,
    );

    // Test Shift+Tab key -> step up to parent directory
    _ = try handlePaletteKeys(ctx, .tab, .{ .shift = true });
    try std.testing.expectEqual(
        @as(?ActivePaletteMode, .directory_navigator),
        state.viewer.ui.palette.openMode(),
    );
    try std.testing.expectEqualStrings(
        tmp_dir,
        state.viewer.ui.palette.current_nav_dir.items,
    );

    // Test Enter key on sub_no_images -> queues open_path intent for
    // sub_no_images and initiates palette closing dissolve
    state.viewer.ui.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(ctx, .return_key, .{});
    switch (state.viewer.ui.palette.lifecycle) {
        .closing => {},
        .closed, .open => return error.TestUnexpectedResult,
    }

    // Re-open palette
    try state.loadPaletteDirectory(tmp_dir);
    state.viewer.ui.palette.lifecycle = .{ .open = .directory_navigator };

    // Test Shift+Enter key on current directory -> queues open_path intent
    // and initiates palette closing dissolve
    _ = try handlePaletteKeys(ctx, .return_key, .{ .shift = true });
    switch (state.viewer.ui.palette.lifecycle) {
        .closing => {},
        .closed, .open => return error.TestUnexpectedResult,
    }
}

test "handlePaletteKeys stepping up to parent directory preselects child dir" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "alpha_dir");
    try tmp.dir.createDirPath(io, "work_dir");

    var parent_buf: [128]u8 = undefined;
    const parent_dir = try std.mem.print(
        &parent_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    var work_buf: [160]u8 = undefined;
    const work_dir = try std.mem.print(
        &work_buf,
        "{s}/work_dir",
        .{parent_dir},
    );

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.loadPaletteDirectory(work_dir);
    state.viewer.ui.palette.lifecycle = .{ .open = .directory_navigator };
    try std.testing.expectEqualStrings(
        work_dir,
        state.viewer.ui.palette.current_nav_dir.items,
    );

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    _ = try handlePaletteKeys(ctx, .left, .{});
    try std.testing.expectEqualStrings(
        parent_dir,
        state.viewer.ui.palette.current_nav_dir.items,
    );

    var found_selected = false;
    if (state.viewer.ui.palette.selected_idx <
        state.viewer.ui.palette.dir_items.items.len)
    {
        const sel_name = state.viewer.ui.palette.dir_items.items[
            state.viewer.ui.palette.selected_idx
        ].getName();
        if (std.mem.eql(u8, sel_name, "work_dir")) {
            found_selected = true;
        }
    }
    try std.testing.expect(found_selected);
}

test "openPalette directory_navigator starting directory rules" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sub1");
    var tmp_dir_buf: [128]u8 = undefined;
    const tmp_dir = try std.mem.print(
        &tmp_dir_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Rule 1: current_index is valid -> starting directory is dirname of
    // current image
    var sample_buf: [160]u8 = undefined;
    const sample_path = try std.mem.print(
        &sample_buf,
        "{s}/image1.jpg",
        .{tmp_dir},
    );
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = sample_path } },
    );
    state.viewer.navigation.current_index = 0;

    try state.openPalette(.directory_navigator);
    try std.testing.expectEqual(
        @as(?ActivePaletteMode, .directory_navigator),
        state.viewer.ui.palette.openMode(),
    );
    try std.testing.expectEqualStrings(
        tmp_dir,
        state.viewer.ui.palette.current_nav_dir.items,
    );

    // Rule 2: current_index is null -> starting directory remembers
    // last_nav_dir
    state.viewer.navigation.current_index = null;
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(
        tmp_dir,
        state.viewer.ui.palette.current_nav_dir.items,
    );

    // Rule 3: current_index is null and last_nav_dir is empty -> starting
    // directory falls back to "."
    state.viewer.ui.palette.last_nav_dir.clearRetainingCapacity();
    const fallback1 = state.resolveNavigatorInitialPath();
    try std.testing.expectEqualStrings(".", fallback1.start_dir);
    try std.testing.expect(fallback1.preselect_child == null);

    // Rule 4: current_index out of bounds and last_nav_dir is empty -> starting
    // directory falls back to "."
    state.viewer.navigation.current_index = 999;
    state.viewer.ui.palette.last_nav_dir.clearRetainingCapacity();
    const fallback2 = state.resolveNavigatorInitialPath();
    try std.testing.expectEqualStrings(".", fallback2.start_dir);
    try std.testing.expect(fallback2.preselect_child == null);
}

test "openPalette directory_navigator steps up if 0 subdirectories" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "child_leaf");
    var tmp_dir_buf: [128]u8 = undefined;
    const tmp_dir = try std.mem.print(
        &tmp_dir_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    var img_buf: [160]u8 = undefined;
    const img_path = try std.mem.print(
        &img_buf,
        "{s}/child_leaf/photo.png",
        .{tmp_dir},
    );

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Image in child_leaf (which has 0 subdirectories itself)
    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = img_path } },
    );
    state.viewer.navigation.current_index = 0;

    // openPalette should see child_leaf has 0 subdirectories, so it steps up to
    // tmp_dir and pre-selects child_leaf
    try state.openPalette(.directory_navigator);
    try std.testing.expectEqualStrings(
        tmp_dir,
        state.viewer.ui.palette.current_nav_dir.items,
    );

    // Verify child_leaf is selected
    var found_leaf_selected = false;
    if (state.viewer.ui.palette.selected_idx <
        state.viewer.ui.palette.dir_items.items.len)
    {
        const sel_name = state.viewer.ui.palette.dir_items.items[
            state.viewer.ui.palette.selected_idx
        ].getName();
        if (std.mem.eql(u8, sel_name, "child_leaf")) {
            found_leaf_selected = true;
        }
    }
    try std.testing.expect(found_leaf_selected);
}

test "resolveNavigatorInitialPath handles relative file without slashes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "photo.png" } },
    );
    state.viewer.navigation.current_index = 0;

    const nav_path = state.resolveNavigatorInitialPath();
    try std.testing.expectEqualStrings(".", nav_path.start_dir);
    try std.testing.expectEqualStrings("photo.png", nav_path.preselect_child.?);
}

test "handlePaletteKeys backspace removes full multi-byte UTF-8 codepoints" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.ui.palette.lifecycle = .{ .open = .files };
    // "a" (1B) + "é" (2B) + "日" (3B) + "🌅" (4B)
    try state.viewer.ui.palette.query.appendSlice(allocator, "aé日🌅");

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };

    // 1st Backspace removes 4-byte "🌅"
    _ = try handlePaletteKeys(ctx, .backspace, .{});
    try std.testing.expectEqualStrings(
        "aé日",
        state.viewer.ui.palette.query.items,
    );

    // 2nd Backspace removes 3-byte "日"
    _ = try handlePaletteKeys(ctx, .backspace, .{});
    try std.testing.expectEqualStrings(
        "aé",
        state.viewer.ui.palette.query.items,
    );

    // 3rd Backspace removes 2-byte "é"
    _ = try handlePaletteKeys(ctx, .backspace, .{});
    try std.testing.expectEqualStrings(
        "a",
        state.viewer.ui.palette.query.items,
    );

    // 4th Backspace removes 1-byte "a"
    _ = try handlePaletteKeys(ctx, .backspace, .{});
    try std.testing.expectEqualStrings(
        "",
        state.viewer.ui.palette.query.items,
    );
}

test "sysProcessPaletteInput preserves text_input after backspace" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.openPalette(.actions);
    try state.viewer.ui.palette.query.appendSlice(allocator, "cat");

    var keys: std.ArrayList(Key) = .empty;
    defer keys.deinit(allocator);
    try keys.append(allocator, .backspace);
    try keys.append(allocator, .char_r);

    // 1. Backspace + 'r' in the same frame pops 't' and appends 'r' -> "car"
    _ = try sysProcessPaletteInput(.{
        .state = &state,
        .frame_allocator = allocator,
        .input = FrameInput{
            .win_w = 800,
            .win_h = 600,
            .scale_x = 1.0,
            .scale_y = 1.0,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_left_down = false,
            .mouse_left_clicked = false,
            .mouse_inside = true,
            .quit_request = .none,
            .scroll_delta_x = 0,
            .scroll_delta_y = 0,
            .keys_pressed = keys,
            .key_modifiers = .{},
            .text_input = "r",
            .dropped_path = null,
            .delta_time_ms = 16.0,
        },
        .delta_time_ms = 16.0,
    });
    try std.testing.expectEqualStrings(
        "car",
        state.viewer.ui.palette.query.items,
    );

    // 2. Modifier shortcuts (Alt+V) suppress text_input in the same frame
    keys.clearRetainingCapacity();
    try keys.append(allocator, .char_v);
    _ = try sysProcessPaletteInput(.{
        .state = &state,
        .frame_allocator = allocator,
        .input = FrameInput{
            .win_w = 800,
            .win_h = 600,
            .scale_x = 1.0,
            .scale_y = 1.0,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_left_down = false,
            .mouse_left_clicked = false,
            .mouse_inside = true,
            .quit_request = .none,
            .scroll_delta_x = 0,
            .scroll_delta_y = 0,
            .keys_pressed = keys,
            .key_modifiers = .{ .alt = true },
            .text_input = "v",
            .dropped_path = null,
            .delta_time_ms = 16.0,
        },
        .delta_time_ms = 16.0,
    });
    try std.testing.expectEqualStrings(
        "car",
        state.viewer.ui.palette.query.items,
    );
}

test "directory_navigator archive_file drill-down and click behavior" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    const palette = &state.viewer.ui.palette;
    palette.lifecycle = .{ .open = .directory_navigator };
    try palette.current_nav_dir.appendSlice(allocator, "/tmp/comics");
    const dir_alloc = palette.dir_arena.allocator();
    try palette.dir_items.append(dir_alloc, .{
        .directory = .{
            .name = try dir_alloc.dupe(u8, "subfolder"),
            .full_path = try dir_alloc.dupe(u8, "/tmp/comics/subfolder"),
        },
    });
    try palette.dir_items.append(dir_alloc, .{
        .archive_file = .{
            .name = try dir_alloc.dupe(u8, "issue1.cbz"),
            .full_path = try dir_alloc.dupe(u8, "/tmp/comics/issue1.cbz"),
        },
    });
    try palette.rebuildDirectoryMatches(allocator);
    palette.selected_idx = 1;
    try palette.query.appendSlice(allocator, "issue");

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = frame_arena.allocator(),
    };

    // 1. Pressing Right or Tab on an archive_file entry does not reload parent
    // or clear query/selection
    _ = try handlePaletteKeys(ctx, .right, .{});
    try std.testing.expectEqual(@as(usize, 1), palette.selected_idx);
    try std.testing.expectEqualStrings("issue", palette.query.items);
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);

    _ = try handlePaletteKeys(ctx, .tab, .{});
    try std.testing.expectEqual(@as(usize, 1), palette.selected_idx);
    try std.testing.expectEqualStrings("issue", palette.query.items);
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);

    // 2. Clicking an archive_file entry pushes .open_path and closes palette
    const closed = try processPaletteItemClick(ctx, 1);
    try std.testing.expect(closed);
    switch (palette.lifecycle) {
        .closing => {},
        .closed, .open => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqualStrings(
        "/tmp/comics/issue1.cbz",
        state.pending_intents.items[0].open_path,
    );
}

test "handlePaletteReturnSlideshow pushes start_slideshow_interval intent" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = frame_arena.allocator(),
    };

    try handlePaletteReturnSlideshow(ctx, "7.5");
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(
        @as(f32, 7.5),
        state.pending_intents.items[0].start_slideshow_interval,
    );

    // Invalid inputs push nothing
    state.clearIntents();
    try handlePaletteReturnSlideshow(ctx, "0");
    try handlePaletteReturnSlideshow(ctx, "-2.0");
    try handlePaletteReturnSlideshow(ctx, "nan");
    try handlePaletteReturnSlideshow(ctx, "abc");
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
}
