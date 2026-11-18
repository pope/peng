const app_state = @import("../state.zig");
const context = @import("context.zig");
const input_pkg = @import("input");
const intents = @import("intents");
const palette_input = @import("palette_input.zig");
const state_pkg = @import("state");
const std = @import("std");

const ActivePaletteMode = intents.ActivePaletteMode;
const AppIntent = intents.AppIntent;
const AppState = app_state.AppState;
const FrameContext = context.FrameContext;
const FrameInput = state_pkg.FrameInput;
const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;
const key_mapping = input_pkg.key_mapping;

inline fn isViewportZoomed(self: *AppState) bool {
    return if (self.getCurrentEntry() != null)
        self.isImageOverflowing()
    else
        self.viewer.viewport.isZoomed();
}

/// Resolves active key context and pushes mapped AppIntents.
/// Returns `true` if a `.quit` or `.quit_server` intent was pushed so further
/// keypresses in the same frame are ignored.
fn handleKeyDown(
    self: *AppState,
    key: Key,
    mod: KeyModifiers,
) !bool {
    if (self.viewer.ui.palette.isAcceptingInput()) return false;

    // Intercept Escape key when dialogs or panels (Stats / Info / Edit Panel)
    // are visible before falling back to closing the application.
    const is_escape = key == .escape and mod.eql(.{});
    const has_dialogs = self.viewer.ui.overlays.hasVisibleFloatingPanels() or
        self.viewer.ui.overlays.edit_panel.visible;
    if (is_escape and has_dialogs) {
        try self.pushIntent(.dismiss_overlays);
        return false;
    }

    const is_zoomed = isViewportZoomed(self);
    const ctx: key_mapping.KeyContext =
        if (is_zoomed)
            .viewer_zoomed
        else
            .viewer_normal;
    if (key_mapping.mapKeyToAction(key, mod, ctx)) |intent| {
        try self.pushIntent(intent);
        return intent == .quit or intent == .quit_server;
    }
    return false;
}

/// System Pass: Process FrameInput snapshot and map keypresses/shortcuts to AppIntents
///
/// Responsibilities:
/// 1. Enqueues `quit_server` on process termination (`SDL_EVENT_QUIT` /
///    `SIGINT` / `SIGTERM`) and `quit` on window close
///    (`SDL_EVENT_WINDOW_CLOSE_REQUESTED`).
/// 2. Dispatches dropped filesystem path selection.
/// 3. Maps active keyboard shortcuts to AppIntents if command palette is not
///    accepting input and wasn't dismissed this frame.
/// 4. Resolves simultaneous directional panning into unified 2D motion when
///    zoomed.
pub fn sysProcessInput(
    ctx: FrameContext,
    palette_closed_this_frame: bool,
) !void {
    const state = ctx.state;
    const input = ctx.input orelse return;

    switch (input.quit_request) {
        .none => {},
        .window_close => {
            try state.pushIntent(.quit);
            state.viewer.pan_controller.suppress(input.directional_held);
            state.viewer.zoom_controller.suppress(input.zoom_held);
            return;
        },
        .terminate => {
            try state.pushIntent(.quit_server);
            state.viewer.pan_controller.suppress(input.directional_held);
            state.viewer.zoom_controller.suppress(input.zoom_held);
            return;
        },
    }

    if (state.display.isHidden()) {
        state.viewer.pan_controller.suppress(input.directional_held);
        state.viewer.zoom_controller.suppress(input.zoom_held);
        return;
    }

    if (input.dropped_path) |path| {
        state.pushIntent(.{ .open_path = try ctx.frame_allocator.dupe(u8, path) }) catch |err| {
            std.log.err(
                "Failed to push open_path intent for dropped path '{s}': {}",
                .{ path, err },
            );
        };
    }

    if (state.display.isSuspended()) {
        state.viewer.pan_controller.suppress(input.directional_held);
        state.viewer.zoom_controller.suppress(input.zoom_held);
        return;
    }

    if (state.viewer.ui.palette.isAcceptingInput() or
        palette_closed_this_frame)
    {
        state.viewer.pan_controller.suppress(input.directional_held);
        state.viewer.zoom_controller.suppress(input.zoom_held);
        return;
    }

    const is_zoomed = isViewportZoomed(state);
    const no_mod = input.key_modifiers.eql(.{});

    // 1. Coalesce simultaneous directional keys when zoomed
    if (is_zoomed and no_mod) {
        const dt_f32 = @as(f32, @floatCast(ctx.delta_time_ms));
        const pan_opt = key_mapping.updateDirectionalPan(
            &state.viewer.pan_controller,
            input.directional_held,
            input.keys_pressed.items,
            dt_f32,
        );
        if (pan_opt) |pan| {
            try state.pushIntent(.{
                .pan_by = .{ .dx = pan.dx, .dy = pan.dy },
            });
        }
    } else {
        state.viewer.pan_controller.suppress(input.directional_held);
    }

    // 2. Coalesce zoom keys for smooth continuous and tap zooming
    if (no_mod) {
        const dt_f32 = @as(f32, @floatCast(ctx.delta_time_ms));
        const zoom_opt = key_mapping.updateZoomMotion(
            &state.viewer.zoom_controller,
            input.zoom_held,
            input.keys_pressed.items,
            state.viewer.viewport.zoom_factor.get(),
            dt_f32,
        );
        if (zoom_opt) |z_delta| {
            try state.pushIntent(.{
                .zoom_by = .{
                    .ratio = z_delta.ratio,
                    .snap_zoom = z_delta.snap_zoom,
                },
            });
        }
    } else {
        state.viewer.zoom_controller.suppress(input.zoom_held);
    }

    // 3. Dispatch non-directional, non-zoom keys and normal shortcuts
    for (input.keys_pressed.items) |key| {
        if (is_zoomed and no_mod and key_mapping.isDirectionalKey(key)) {
            continue; // Handled by unified directional resolver above
        }
        if (no_mod and key_mapping.isZoomKey(key)) {
            continue; // Handled by smooth zoom controller above
        }
        if (try handleKeyDown(state, key, input.key_modifiers)) {
            state.viewer.pan_controller.suppress(input.directional_held);
            state.viewer.zoom_controller.suppress(input.zoom_held);
            break;
        }
    }
}

test "sysProcessInput does not process escape or shortcuts if palette was closed this frame" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var keys: std.ArrayList(Key) = .empty;
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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
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

    state.viewer.ui.palette.lifecycle = .{ .open = .actions };

    var keys: std.ArrayList(Key) = .empty;
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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
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
    try std.testing.expectEqual(
        @as(?ActivePaletteMode, .actions),
        state.viewer.ui.palette.openMode(),
    );

    // 2. User presses Escape to dismiss the palette
    var keys: std.ArrayList(Key) = .empty;
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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
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
    switch (state.viewer.ui.palette.lifecycle) {
        .closing => {},
        .closed, .open => return error.TestUnexpectedResult,
    }

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

test "sysProcessInput accepts shortcuts when palette is dissolving (closing)" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.ui.palette.lifecycle = .{ .closing = .actions };

    var keys: std.ArrayList(Key) = .empty;
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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
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
    var keys: std.ArrayList(Key) = .empty;
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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
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

    var keys: std.ArrayList(Key) = .empty;
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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
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
    var keys: std.ArrayList(Key) = .empty;
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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
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

test "sysProcessInput simultaneous directional keys pan diagonally" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // Zoom viewport beyond 1.0x to activate zoomed context
    app_st.viewer.viewport.mode = .manual;
    app_st.viewer.viewport.zoom_factor = state_pkg.clampZoomFactor(2.0);

    // 1. Simultaneous Up and Left keys pressed in single frame
    var keys_ul: std.ArrayList(Key) = .empty;
    defer keys_ul.deinit(allocator);
    try keys_ul.append(allocator, .up);
    try keys_ul.append(allocator, .left);

    const frame_input_ul = FrameInput{
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
        .keys_pressed = keys_ul,
        .key_modifiers = .{},
        .directional_held = .{},
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = frame_input_ul,
        .delta_time_ms = 16.0,
    }, false);

    const inv_sqrt2: f32 = 0.70710678;
    const exp_diag = inv_sqrt2 * 800.0 * (16.0 / 1000.0);

    // Exactly 1 intent enqueued: pan_by with smooth diagonal delta
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.pending_intents.items.len,
    );
    switch (app_st.pending_intents.items[0]) {
        .pan_by => |p| {
            try std.testing.expectApproxEqAbs(exp_diag, p.dx, 0.01);
            try std.testing.expectApproxEqAbs(exp_diag, p.dy, 0.01);
        },
        else => return error.UnexpectedIntent,
    }
    app_st.clearIntents();

    // 2. Simultaneous Down and Right keys pressed in single frame
    var keys_dr: std.ArrayList(Key) = .empty;
    defer keys_dr.deinit(allocator);
    try keys_dr.append(allocator, .down);
    try keys_dr.append(allocator, .right);

    const frame_input_dr = FrameInput{
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
        .keys_pressed = keys_dr,
        .key_modifiers = .{},
        .directional_held = .{},
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = frame_input_dr,
        .delta_time_ms = 16.0,
    }, false);

    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.pending_intents.items.len,
    );
    switch (app_st.pending_intents.items[0]) {
        .pan_by => |p| {
            try std.testing.expectApproxEqAbs(-exp_diag, p.dx, 0.01);
            try std.testing.expectApproxEqAbs(-exp_diag, p.dy, 0.01);
        },
        else => return error.UnexpectedIntent,
    }
    app_st.clearIntents();
}

test "sysProcessInput repeating key with held orthogonal key pans diagonally" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.viewport.mode = .manual;
    app_st.viewer.viewport.zoom_factor = state_pkg.clampZoomFactor(2.0);

    // Left key repeating while Up key is physically held
    var keys_left: std.ArrayList(Key) = .empty;
    defer keys_left.deinit(allocator);
    try keys_left.append(allocator, .left);

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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys_left,
        .key_modifiers = .{},
        .directional_held = .{ .up = true, .left = true },
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    }, false);

    const inv_sqrt2: f32 = 0.70710678;
    const exp_diag = inv_sqrt2 * 800.0 * (16.0 / 1000.0);

    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.pending_intents.items.len,
    );
    switch (app_st.pending_intents.items[0]) {
        .pan_by => |p| {
            try std.testing.expectApproxEqAbs(exp_diag, p.dx, 0.01);
            try std.testing.expectApproxEqAbs(exp_diag, p.dy, 0.01);
        },
        else => return error.UnexpectedIntent,
    }
}

test "sysProcessInput preserves image navigation when viewport is not zoomed" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // Default zoom_factor is 1.0 (not zoomed)
    try std.testing.expect(!app_st.viewer.viewport.isZoomed());

    var keys_right: std.ArrayList(Key) = .empty;
    defer keys_right.deinit(allocator);
    try keys_right.append(allocator, .right);

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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys_right,
        .key_modifiers = .{},
        .directional_held = .{ .up = true },
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    }, false);

    // Unzoomed mode: Right arrow maps to next_image, never pan_by
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.pending_intents.items.len,
    );
    try std.testing.expectEqual(
        AppIntent.next_image,
        app_st.pending_intents.items[0],
    );
    app_st.clearIntents();

    // Even if a fitted image (800x600 in 1024x768 headless viewport) has
    // non-zero pan_x / pan_y from incidental scroll/drag, it does not overflow
    // and must preserve Right/Left image navigation.
    _ = try app_st.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "test.png" },
    });
    app_st.viewer.navigation.current_index = 0;
    const id0 = app_st.viewer.navigation.getIdAt(0).?;
    const key0 = try app_st.cache.appendSlot(allocator, id0, .{
        .inflight = .{ .queued_decode = .{} },
    });
    const entry0 = app_st.cache.get(key0).?;
    entry0.metadata.full_dims = .{ .w = 800.0, .h = 600.0 };
    app_st.viewer.viewport.setPan(45.0, -30.0);
    try std.testing.expect(!app_st.isImageOverflowing());

    try sysProcessInput(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    }, false);
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.pending_intents.items.len,
    );
    try std.testing.expectEqual(
        AppIntent.next_image,
        app_st.pending_intents.items[0],
    );
}

test "sysProcessInput continuous gliding and seamless diagonal transition" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.viewport.mode = .manual;
    app_st.viewer.viewport.zoom_factor = state_pkg.clampZoomFactor(2.0);

    // Simulate already moving upward
    app_st.viewer.pan_controller.prev_held = .{ .up = true };

    const keys_empty: std.ArrayList(Key) = .empty;
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
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = keys_empty,
        .key_modifiers = .{},
        .directional_held = .{ .up = true, .left = true },
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    }, false);

    // Immediately pushes diagonal glide intent with 0ms stutter
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.pending_intents.items.len,
    );
    const intent = app_st.pending_intents.items[0];
    switch (intent) {
        .pan_by => |p| {
            const inv_sqrt2: f32 = 0.70710678;
            const exp = inv_sqrt2 * 800.0 * (16.0 / 1000.0);
            try std.testing.expectApproxEqAbs(exp, p.dx, 0.01);
            try std.testing.expectApproxEqAbs(exp, p.dy, 0.01);
        },
        else => return error.UnexpectedIntent,
    }
}

test "sysProcessInput suppresses held keys on modal and modifier transitions" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.viewport.mode = .manual;
    app_st.viewer.viewport.zoom_factor = state_pkg.clampZoomFactor(2.0);
    app_st.viewer.pan_controller.tap = .{
        .active = .{
            .direction = .{ .right = true },
            .remaining_px = 15.0,
        },
    };
    app_st.viewer.zoom_controller.phase = .{
        .tap = .{
            .direction = .in,
            .remaining_log = 0.1,
        },
    };

    const keys_empty: std.ArrayList(Key) = .empty;

    // 1. Frame with palette open while 'i' (zoom in) and 'right' are held:
    // active motion is cleared and controllers are not busy.
    app_st.viewer.ui.palette.lifecycle = .{ .open = .actions };
    try sysProcessInput(.{
        .state = &app_st,
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
            .keys_pressed = keys_empty,
            .key_modifiers = .{},
            .directional_held = .{ .right = true },
            .zoom_held = .{ .in = true },
            .text_input = null,
            .dropped_path = null,
            .delta_time_ms = 16.0,
        },
        .delta_time_ms = 16.0,
    }, false);
    try std.testing.expect(!app_st.viewer.pan_controller.isBusy());
    try std.testing.expect(!app_st.viewer.zoom_controller.isBusy());

    // 2. Palette closes, but keys remain held from the modal: must not bleed
    // into viewport pan or zoom until released.
    app_st.viewer.ui.palette.lifecycle = .closed;
    try sysProcessInput(.{
        .state = &app_st,
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
            .keys_pressed = keys_empty,
            .key_modifiers = .{},
            .directional_held = .{ .right = true },
            .zoom_held = .{ .in = true },
            .text_input = null,
            .dropped_path = null,
            .delta_time_ms = 16.0,
        },
        .delta_time_ms = 16.0,
    }, false);
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.pending_intents.items.len,
    );
}

test "sysProcessInput maps QuitRequest and suppresses same-frame input" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    var keys: std.ArrayList(Key) = .empty;
    defer keys.deinit(allocator);
    try keys.append(allocator, .char_o);

    // 1. OS/Signal quit (SDL_EVENT_QUIT) -> .quit_server only (ignores keys &
    // dropped_path in the same frame)
    try sysProcessInput(.{
        .state = &app_st,
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
            .quit_request = .terminate,
            .scroll_delta_x = 0,
            .scroll_delta_y = 0,
            .keys_pressed = keys,
            .key_modifiers = .{},
            .text_input = null,
            .dropped_path = "ignored.jpg",
            .delta_time_ms = 16.0,
        },
        .delta_time_ms = 16.0,
    }, false);
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.pending_intents.items.len,
    );
    try std.testing.expectEqual(
        AppIntent.quit_server,
        app_st.pending_intents.items[0],
    );
    app_st.pending_intents.clearRetainingCapacity();

    // 2. Window close request (SDL_EVENT_WINDOW_CLOSE_REQUESTED) -> .quit only
    try sysProcessInput(.{
        .state = &app_st,
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
            .quit_request = .window_close,
            .scroll_delta_x = 0,
            .scroll_delta_y = 0,
            .keys_pressed = keys,
            .key_modifiers = .{},
            .text_input = null,
            .dropped_path = "ignored.jpg",
            .delta_time_ms = 16.0,
        },
        .delta_time_ms = 16.0,
    }, false);
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.pending_intents.items.len,
    );
    try std.testing.expectEqual(
        AppIntent.quit,
        app_st.pending_intents.items[0],
    );
    app_st.pending_intents.clearRetainingCapacity();

    // 3. Pressing quit key ('q') stops processing trailing keys in the same frame
    keys.clearRetainingCapacity();
    try keys.append(allocator, .char_q);
    try keys.append(allocator, .char_f);
    try sysProcessInput(.{
        .state = &app_st,
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
            .text_input = null,
            .dropped_path = null,
            .delta_time_ms = 16.0,
        },
        .delta_time_ms = 16.0,
    }, false);
    try std.testing.expectEqual(
        @as(usize, 1),
        app_st.pending_intents.items.len,
    );
    try std.testing.expectEqual(
        AppIntent.quit,
        app_st.pending_intents.items[0],
    );
}

test "sysProcessInput released zoom tap with suppressed key settles idle" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const intents_sys = @import("intents.zig");
    app_st.viewer.viewport.mode = .manual;
    app_st.viewer.viewport.zoom_factor = state_pkg.ZoomFactor.init(1.1);
    app_st.viewer.zoom_controller.suppress(.{ .in = true });

    var tap_keys: std.ArrayList(Key) = .empty;
    defer tap_keys.deinit(allocator);
    try tap_keys.append(allocator, .char_o);

    const empty_keys: std.ArrayList(Key) = .empty;
    var base_input = FrameInput{
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
        .keys_pressed = tap_keys,
        .key_modifiers = .{},
        .zoom_held = .{ .in = true },
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };

    try sysProcessInput(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = base_input,
        .delta_time_ms = 16.0,
    }, false);
    try intents_sys.sysExecuteIntents(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = base_input,
        .delta_time_ms = 16.0,
    });

    base_input.keys_pressed = empty_keys;
    var frame: usize = 0;
    while (app_st.viewer.zoom_controller.isBusy() and
        frame < 40) : (frame += 1)
    {
        switch (app_st.viewer.zoom_controller.phase) {
            .idle, .tap => {},
            .detent_pause_ms => return error.TestUnexpectedResult,
        }
        try sysProcessInput(.{
            .state = &app_st,
            .frame_allocator = allocator,
            .input = base_input,
            .delta_time_ms = 16.0,
        }, false);
        try intents_sys.sysExecuteIntents(.{
            .state = &app_st,
            .frame_allocator = allocator,
            .input = base_input,
            .delta_time_ms = 16.0,
        });
    }

    try std.testing.expectEqual(
        state_pkg.ZoomPhase.idle,
        app_st.viewer.zoom_controller.phase,
    );
    try std.testing.expect(!app_st.viewer.zoom_controller.isBusy());
    try std.testing.expectEqual(
        @as(f32, 1.0),
        app_st.viewer.viewport.zoom_factor.get(),
    );
    try std.testing.expectEqual(
        input_pkg.EventWaitStrategy.wait_indefinite,
        app_st.computeFrameWaitStrategy(1024.0, 768.0, false, false, 1000),
    );
}

test "sysProcessInput continuous zoom hold crossing 1.0 pauses once" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    const intents_sys = @import("intents.zig");
    const empty_keys: std.ArrayList(Key) = .empty;
    const cases = [_]struct {
        start_zoom: f32,
        held: state_pkg.ZoomFlags,
        expect_above_one: bool,
    }{
        .{
            .start_zoom = 0.95,
            .held = .{ .in = true },
            .expect_above_one = true,
        },
        .{
            .start_zoom = 1.05,
            .held = .{ .out = true },
            .expect_above_one = false,
        },
    };

    for (cases) |c| {
        app_st.viewer.viewport.mode = .manual;
        app_st.viewer.viewport.zoom_factor = state_pkg.ZoomFactor.init(
            c.start_zoom,
        );
        app_st.viewer.zoom_controller.reset();

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
            .quit_request = .none,
            .scroll_delta_x = 0,
            .scroll_delta_y = 0,
            .keys_pressed = empty_keys,
            .key_modifiers = .{},
            .zoom_held = c.held,
            .text_input = null,
            .dropped_path = null,
            .delta_time_ms = 16.0,
        };
        const ctx = FrameContext{
            .state = &app_st,
            .frame_allocator = allocator,
            .input = frame_input,
            .delta_time_ms = 16.0,
        };

        var detent_entries: usize = 0;
        var in_detent = false;
        var frame: usize = 0;
        while (frame < 40) : (frame += 1) {
            try sysProcessInput(ctx, false);
            try intents_sys.sysExecuteIntents(ctx);
            const now_detent = switch (app_st.viewer.zoom_controller.phase) {
                .detent_pause_ms => true,
                .idle, .tap => false,
            };
            if (now_detent and !in_detent) {
                detent_entries += 1;
                try std.testing.expectEqual(
                    @as(f32, 1.0),
                    app_st.viewer.viewport.zoom_factor.get(),
                );
            }
            in_detent = now_detent;
        }

        try std.testing.expectEqual(@as(usize, 1), detent_entries);
        const end_zoom = app_st.viewer.viewport.zoom_factor.get();
        if (c.expect_above_one) {
            try std.testing.expect(end_zoom > 1.0);
        } else {
            try std.testing.expect(end_zoom < 1.0);
        }
    }
}
