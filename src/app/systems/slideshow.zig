const app_state = @import("../state.zig");
const context = @import("context.zig");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;
const types = state_pkg.types;

/// System Pass: Update slideshow timer
pub fn sysUpdateSlideshow(ctx: FrameContext) !void {
    const state = ctx.state;
    if (state.viewer.navigation.slideshow.tick(@floatCast(ctx.delta_time_ms))) {
        try state.pushIntent(.next_image);
    }
}

test "AppState slideshow timer auto-advances slide" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "img1.jpg" } });
    try state.viewer.navigation.image_list.append(allocator, .{ .filesystem = .{ .path = "img2.jpg" } });
    state.viewer.navigation.current_index = 0;
    state.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 2.0 } };

    const frame_input_1s = types.FrameInput{
        .win_w = 100,
        .win_h = 100,
        .pix_w = 100,
        .pix_h = 100,
        .scale_x = 1,
        .scale_y = 1,
        .dpi_scale = 1,
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

    try sysUpdateSlideshow(.{ .state = &state, .frame_allocator = allocator, .input = frame_input_1s, .delta_time_ms = 1000.0 });
    try std.testing.expectEqual(@as(usize, 0), state.viewer.navigation.current_index.?);

    // Pass another second (total 2000ms >= 2.0s interval) -> advances to index 1
    try sysUpdateSlideshow(.{ .state = &state, .frame_allocator = allocator, .input = frame_input_1s, .delta_time_ms = 1000.0 });
    try std.testing.expectEqual(@as(usize, 1), state.viewer.navigation.current_index.?);
}
