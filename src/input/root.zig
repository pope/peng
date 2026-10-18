const intents = @import("intents");
pub const key_mapping = @import("key_mapping.zig");
pub const polling = @import("polling.zig");
const sdl = @import("sdl");
const std = @import("std");

pub const EventWaitStrategy = polling.EventWaitStrategy;
pub const FrameInputState = polling.FrameInputState;
pub const KeyContext = key_mapping.KeyContext;
pub const mapKeyToAction = key_mapping.mapKeyToAction;
pub const mapKeyFromSdl = polling.mapKeyFromSdl;
pub const mapModFromSdl = polling.mapModFromSdl;
pub const MOUSE_WHEEL_SCROLL_MULTIPLIER = polling.MOUSE_WHEEL_SCROLL_MULTIPLIER;
pub const pollFrameInput = polling.pollFrameInput;
pub const processSDLEvent = polling.processSDLEvent;
pub const selectEventWaitStrategy = polling.selectEventWaitStrategy;

test {
    _ = key_mapping;
    _ = polling;
}

test "mapKeyToAction mapping" {
    const pan_left = mapKeyToAction(.left, .{}, .viewer_zoomed);
    try std.testing.expect(pan_left != null);
    try std.testing.expectEqual(
        intents.AppIntent{ .pan_by = .{ .dx = 30.0, .dy = 0.0 } },
        pan_left.?,
    );

    const pan_left_not_zoomed = mapKeyToAction(.left, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.prev_image, pan_left_not_zoomed.?);

    const zoom_in = mapKeyToAction(.equals, .{}, .viewer_normal);
    try std.testing.expectEqual(intents.AppIntent.zoom_in, zoom_in.?);
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
