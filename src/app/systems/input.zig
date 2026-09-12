const app_state = @import("../state.zig");
const context = @import("context.zig");
const input_pkg = @import("input");
const intents = @import("intents");
const palette_input = @import("palette_input.zig");
const state_pkg = @import("state");
const std = @import("std");

const AppIntent = intents.AppIntent;
const AppState = app_state.AppState;
const FrameContext = context.FrameContext;
const FrameInput = state_pkg.FrameInput;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;
const PaletteMode = intents.PaletteMode;
const key_mapping = input_pkg.key_mapping;

/// Resolves active key context and pushes mapped AppIntents
fn handleKeyDown(
    self: *AppState,
    key: Key,
    mod: KeyModifiers,
) !void {
    if (self.viewer.ui.palette.isAcceptingInput()) return;

    // Intercept Escape key when dialogs or panels (Stats / Info / Edit Panel)
    // are visible before falling back to closing the application.
    const is_escape = key == .escape and mod.eql(.{});
    const has_dialogs = self.viewer.ui.overlays.hasVisibleFloatingPanels() or
        self.viewer.ui.overlays.edit_panel.visible;
    if (is_escape and has_dialogs) {
        try self.pushIntent(.dismiss_overlays);
        return;
    }

    const ctx: key_mapping.KeyContext =
        if (self.viewer.viewport.zoom_factor.get() > 1.0)
            .viewer_zoomed
        else
            .viewer_normal;
    if (key_mapping.mapKeyToAction(key, mod, ctx)) |intent| {
        try self.pushIntent(intent);
    }
}

/// System Pass: Process FrameInput snapshot and map keypresses/shortcuts to AppIntents
///
/// Responsibilities:
/// 1. Enqueues quit intent on OS window quit request.
/// 2. Dispatches dropped filesystem path selection.
/// 3. Maps active keyboard shortcuts to AppIntents if command palette is not
///    accepting input and wasn't dismissed this frame.
pub fn sysProcessInput(ctx: FrameContext, palette_closed_this_frame: bool) !void {
    const state = ctx.state;
    const input = ctx.input orelse return;

    if (input.quit_requested) {
        try state.pushIntent(.quit);
    }

    if (input.dropped_path) |path| {
        state.pushIntent(.{ .open_path = try ctx.frame_allocator.dupe(u8, path) }) catch |err| {
            std.log.err(
                "Failed to push open_path intent for dropped path '{s}': {}",
                .{ path, err },
            );
        };
    }

    if (state.viewer.ui.palette.isAcceptingInput() or palette_closed_this_frame) return;

    for (input.keys_pressed.items) |key| {
        try handleKeyDown(state, key, input.key_modifiers);
    }
}

test "sysProcessInput does not process escape or shortcuts if palette was closed this frame" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var keys = std.ArrayList(Key).empty;
    defer keys.deinit(allocator);
    try keys.append(allocator, .escape);

    const frame_input = FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    };

    // When palette was closed this frame (e.g. by hitting Escape), Escape must not trigger quit
    try sysProcessInput(ctx, true);
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);

    // When palette is at the top level and was NOT closed this frame, Escape DOES trigger quit
    try sysProcessInput(ctx, false);
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(AppIntent.quit, state.pending_intents.items[0]);
}

test "sysProcessInput ignores key shortcuts while palette mode is active" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.ui.palette.mode = .actions;

    var keys = std.ArrayList(Key).empty;
    defer keys.deinit(allocator);
    try keys.append(allocator, .escape);

    const frame_input = FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(ctx, false);
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
}

test "Escape key closes active palette without triggering quit in sysProcessInput" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // 1. Open the Actions command palette
    try state.openPalette(.actions);
    try std.testing.expectEqual(PaletteMode.actions, state.viewer.ui.palette.mode);

    // 2. User presses Escape to dismiss the palette
    var keys = std.ArrayList(Key).empty;
    defer keys.deinit(allocator);
    try keys.append(allocator, .escape);

    const frame_input = FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    };

    const palette_closed = try palette_input.sysProcessPaletteInput(ctx);
    try std.testing.expect(palette_closed);
    try std.testing.expectEqual(PaletteMode.inactive, state.viewer.ui.palette.mode);

    // sysProcessInput must NOT register a quit intent because palette was closed this frame
    try sysProcessInput(ctx, palette_closed);
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);

    // 3. On the next frame at top level, pressing Escape again triggers quit as expected
    const palette_closed_next = try palette_input.sysProcessPaletteInput(ctx);
    try std.testing.expect(!palette_closed_next);

    try sysProcessInput(ctx, palette_closed_next);
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(AppIntent.quit, state.pending_intents.items[0]);
}

test "sysProcessInput accepts shortcuts when palette is dissolving (is_closing == true)" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.ui.palette.mode = .actions;
    state.viewer.ui.palette.is_closing = true;

    var keys = std.ArrayList(Key).empty;
    defer keys.deinit(allocator);
    try keys.append(allocator, .right);

    const frame_input = FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(ctx, false);
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(AppIntent.next_image, state.pending_intents.items[0]);
}

test "Escape key dismisses floating overlays without triggering quit" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // 1. Both Stats for Nerds and Image Info are open
    state.viewer.ui.overlays.stats_panel.visible = true;
    state.viewer.ui.overlays.info_panel.visible = true;

    // 2. User presses Escape
    var keys = std.ArrayList(Key).empty;
    defer keys.deinit(allocator);
    try keys.append(allocator, .escape);

    const frame_input = FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    };

    // sysProcessInput must enqueue dismiss_overlays, NOT quit
    try sysProcessInput(ctx, false);
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(AppIntent.dismiss_overlays, state.pending_intents.items[0]);

    // Executing intents dismisses the overlays while keeping viewer running
    const intents_sys = @import("intents.zig");
    try intents_sys.sysExecuteIntents(ctx);
    try std.testing.expect(!state.viewer.ui.overlays.stats_panel.visible);
    try std.testing.expect(!state.viewer.ui.overlays.info_panel.visible);
    try std.testing.expect(state.viewer.running);

    // 3. Next frame, with overlays now closed, pressing Escape again triggers quit
    try sysProcessInput(ctx, false);
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(AppIntent.quit, state.pending_intents.items[0]);
}

test "q key triggers quit even when floating overlays are visible" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.ui.overlays.stats_panel.visible = true;

    var keys = std.ArrayList(Key).empty;
    defer keys.deinit(allocator);
    try keys.append(allocator, .char_q);

    const frame_input = FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(ctx, false);
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(AppIntent.quit, state.pending_intents.items[0]);
}

test "duplicate Escape keys in single frame safely deduplicate without triggering quit" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.ui.overlays.stats_panel.visible = true;

    // Simulate key bounce / rapid input with two Escape events in one frame
    var keys = std.ArrayList(Key).empty;
    defer keys.deinit(allocator);
    try keys.append(allocator, .escape);
    try keys.append(allocator, .escape);

    const frame_input = FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };

    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(ctx, false);
    // Overlays intercept Escape, 0 quit intents queued
    for (state.pending_intents.items) |intent| {
        try std.testing.expectEqual(AppIntent.dismiss_overlays, intent);
    }
    try std.testing.expect(state.pending_intents.items.len > 0);

    const intents_sys = @import("intents.zig");
    try intents_sys.sysExecuteIntents(ctx);
    try std.testing.expect(!state.viewer.ui.overlays.stats_panel.visible);
    try std.testing.expect(state.viewer.running);
}
