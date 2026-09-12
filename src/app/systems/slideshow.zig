const app_state = @import("../state.zig");
const context = @import("context.zig");
const intents = @import("intents");
const intents_sys = @import("intents.zig");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;
const types = state_pkg.types;

/// System Pass: Update slideshow playback and timer.
///
/// Responsibilities:
/// 1. Checks if slideshow playback is paused (command palette open, viewport
///    dragging, active slide decoding, or explicit pause).
/// 2. If unpaused, advances the accumulated slideshow timer by `ctx.delta_time_ms`.
/// 3. Emits `.next_image` application intent once the accumulated duration
///    reaches or exceeds the configured interval.
pub fn sysUpdateSlideshow(ctx: FrameContext) !void {
    const state = ctx.state;
    if (state.isSlideshowPaused()) return;
    if (state.viewer.navigation.slideshow.tick(@floatCast(ctx.delta_time_ms))) {
        try state.pushIntent(.next_image);
    }
}

test "AppState slideshow timer auto-advances slide" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "img1.jpg" },
    });
    try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "img2.jpg" },
    });
    state.viewer.navigation.current_index = 0;
    state.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 2.0 } };

    const frame_input_1s = types.FrameInput{
        .win_w = 100,
        .win_h = 100,
        .scale_x = 1,
        .scale_y = 1,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 1000.0,
    };

    const ctx_1s = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .input = frame_input_1s,
        .delta_time_ms = 1000.0,
    };

    try sysUpdateSlideshow(ctx_1s);
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.navigation.current_index.?);

    // Pass another second (total 2000ms >= 2.0s interval) -> queues .next_image intent
    try sysUpdateSlideshow(ctx_1s);
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(intents.AppIntent.next_image, state.pending_intents.items[0]);

    // Intent execution pass advances the slide index
    try intents_sys.sysExecuteIntents(ctx_1s);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.navigation.current_index.?);
}

test "AppState slideshow pauses during command palette, dragging, or explicit pause" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "img1.jpg" },
    });
    try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "img2.jpg" },
    });
    state.viewer.navigation.current_index = 0;
    state.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 1.0 } };

    const frame_input_1s = types.FrameInput{
        .win_w = 100,
        .win_h = 100,
        .scale_x = 1,
        .scale_y = 1,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 1000.0,
    };

    const ctx_2s = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .input = frame_input_1s,
        .delta_time_ms = 2000.0,
    };

    // 1. Palette open -> paused
    state.viewer.ui.palette.mode = .actions;
    try std.testing.expect(state.isSlideshowPaused());
    try sysUpdateSlideshow(ctx_2s);
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
    state.viewer.ui.palette.mode = .inactive;
    try std.testing.expect(!state.isSlideshowPaused());

    // 2. Viewport drag active -> paused
    state.viewer.drag_state = .{ .viewport = .{ .last_x = 0, .last_y = 0 } };
    try std.testing.expect(state.isSlideshowPaused());
    try sysUpdateSlideshow(ctx_2s);
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
    state.viewer.drag_state = .none;
    try std.testing.expect(!state.isSlideshowPaused());

    // 3. Explicit pause -> paused
    state.viewer.navigation.slideshow.pause();
    try std.testing.expect(state.isSlideshowPaused());
    try sysUpdateSlideshow(ctx_2s);
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);

    // 4. Resume -> advances
    state.viewer.navigation.slideshow.unpause();
    try std.testing.expect(!state.isSlideshowPaused());
    try sysUpdateSlideshow(ctx_2s);
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
}
