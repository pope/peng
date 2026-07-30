const std = @import("std");
const state_pkg = @import("state");
const app_state = @import("../state.zig");
const intents = @import("intents");
const navigation = @import("../navigation.zig");
const ui_state = @import("../ui_state.zig");
const app_palette = @import("../palette.zig");
const sdl = @import("sdl");
const Key = state_pkg.Key;
const KeyModifiers = state_pkg.KeyModifiers;
const ViewerState = app_state.ViewerState;

pub const polling = @import("polling.zig");
pub const key_mapping = @import("key_mapping.zig");
pub const palette_input = @import("palette_input.zig");

pub const mapKeyFromSdl = polling.mapKeyFromSdl;
pub const mapModFromSdl = polling.mapModFromSdl;
pub const FrameInputState = polling.FrameInputState;
pub const processSDLEvent = polling.processSDLEvent;
pub const pollFrameInput = polling.pollFrameInput;
pub const MOUSE_WHEEL_SCROLL_MULTIPLIER = polling.MOUSE_WHEEL_SCROLL_MULTIPLIER;

pub const KeyContext = key_mapping.KeyContext;
pub const InputAction = key_mapping.InputAction;
pub const mapKeyToAction = key_mapping.mapKeyToAction;

pub const handlePaletteKeys = palette_input.handlePaletteKeys;

/// Resolves active key context and handles key down events
pub fn handleKeyDown(
    self: *ViewerState,
    key: Key,
    mod: KeyModifiers,
    scale_x: f32,
    scale_y: f32,
) !void {
    if (self.ui.palette.mode != .inactive) {
        _ = try handlePaletteKeys(self, key, mod);
        return;
    }

    const ctx: KeyContext = if (self.viewport.zoom_factor.get() > 1.0) .viewer_zoomed else .viewer_normal;
    const action = mapKeyToAction(key, mod, ctx);
    switch (action) {
        .none => {},
        .pan => |p| {
            self.viewport.pan_x += p.dx * scale_x;
            self.viewport.pan_y += p.dy * scale_y;
        },
        .zoom => |z| {
            const old_zoom = self.viewport.zoom_factor;
            self.viewport.zoom_factor = self.clampZoomFactor(old_zoom.get() + z.factor_delta);
            const ratio = old_zoom.ratioTo(self.viewport.zoom_factor);
            self.viewport.pan_x *= ratio;
            self.viewport.pan_y *= ratio;
        },
        .trigger_intent => |intent| {
            try self.pushIntent(intent);
        },
    }
}

test "mapKeyToAction mapping" {
    const pan_left = mapKeyToAction(.left, .{}, .viewer_zoomed);
    try std.testing.expect(pan_left == .pan);
    try std.testing.expectEqual(@as(f32, 30.0), pan_left.pan.dx);

    const pan_left_not_zoomed = mapKeyToAction(.left, .{}, .viewer_normal);
    try std.testing.expect(pan_left_not_zoomed == .trigger_intent);
    try std.testing.expectEqual(intents.AppIntent.prev_image, pan_left_not_zoomed.trigger_intent);

    const zoom_in = mapKeyToAction(.equals, .{}, .viewer_normal);
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
        .navigation = navigation.NavigationState.init(allocator),
        .ui = ui_state.UiState.init(allocator),
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .rotation_map = .init(allocator),
        .event_queue = app_state.events.MpscQueue(app_state.events.BackgroundEvent).init(),
    };
    defer state.deinit();

    // 1. Open directory navigator at tmp_dir
    try app_palette.loadDirectoryEntries(&state.ui.palette, io, tmp_dir);
    state.ui.palette.mode = .directory_navigator;

    // Locate index of sub_no_images
    var match_idx_no_img: usize = 0;
    for (state.ui.palette.dir_items.items, 0..) |item, i| {
        if (std.mem.eql(u8, item.name, "sub_no_images")) {
            match_idx_no_img = i;
            break;
        }
    }

    // Test Right key on sub_no_images -> navigate into folder
    state.ui.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(&state, .right, .{});
    try std.testing.expectEqual(app_state.PaletteMode.directory_navigator, state.ui.palette.mode);
    try std.testing.expectEqualStrings(sub_no_img, state.ui.palette.current_nav_dir.items);
    try std.testing.expectEqual(@as(usize, 0), state.ui.palette.query.items.len);

    // Test Left key -> step up to parent directory, remembering sub_no_images
    _ = try handlePaletteKeys(&state, .left, .{});
    try std.testing.expectEqual(app_state.PaletteMode.directory_navigator, state.ui.palette.mode);
    try std.testing.expectEqualStrings(tmp_dir, state.ui.palette.current_nav_dir.items);
    try std.testing.expectEqual(match_idx_no_img, state.ui.palette.selected_idx);

    // Test Enter key on sub_no_images -> starts async path scan for sub_no_images and closes palette
    state.ui.palette.selected_idx = match_idx_no_img;
    _ = try handlePaletteKeys(&state, .return_key, .{});
    try std.testing.expectEqual(app_state.PaletteMode.inactive, state.ui.palette.mode);

    // Re-open palette
    try app_palette.loadDirectoryEntries(&state.ui.palette, io, tmp_dir);
    state.ui.palette.mode = .directory_navigator;

    // Test Shift+Enter key on current directory -> starts async path scan and closes palette
    _ = try handlePaletteKeys(&state, .return_key, .{ .shift = true });
    try std.testing.expectEqual(app_state.PaletteMode.inactive, state.ui.palette.mode);
}

test "handlePaletteKeys stepping up from dot to parent directory preselects working dir" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = ViewerState{
        .navigation = navigation.NavigationState.init(allocator),
        .ui = ui_state.UiState.init(allocator),
        .cache = .{},
        .allocator = allocator,
        .io = io,
        .rotation_map = .init(allocator),
        .event_queue = app_state.events.MpscQueue(app_state.events.BackgroundEvent).init(),
    };
    defer state.deinit();

    try app_palette.loadDirectoryEntries(&state.ui.palette, io, ".");
    state.ui.palette.mode = .directory_navigator;
    try std.testing.expectEqualStrings(".", state.ui.palette.current_nav_dir.items);

    _ = try handlePaletteKeys(&state, .left, .{});
    try std.testing.expectEqualStrings("..", state.ui.palette.current_nav_dir.items);

    var found_cwd_selected = false;
    if (state.ui.palette.selected_idx < state.ui.palette.dir_items.items.len) {
        if (std.mem.eql(u8, state.ui.palette.dir_items.items[state.ui.palette.selected_idx].name, "peng")) {
            found_cwd_selected = true;
        }
    }
    try std.testing.expect(found_cwd_selected);
}

test "processSDLEvent updates FrameInputState" {
    const allocator = std.testing.allocator;
    var state = FrameInputState{
        .frame_allocator = allocator,
        .keys_pressed = .empty,
        .mouse_inside = false,
    };
    defer state.keys_pressed.deinit(allocator);

    var evt = sdl.Event{
        .type = sdl.event_type.mouse_enter,
    };
    try processSDLEvent(evt, &state);
    try std.testing.expect(state.mouse_inside);

    evt = sdl.Event{
        .type = sdl.event_type.quit,
    };
    try processSDLEvent(evt, &state);
    try std.testing.expect(state.quit_requested);
}
