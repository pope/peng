const app_state = @import("../state.zig");
const context = @import("context.zig");
const intents = @import("intents");
const intents_sys = @import("intents.zig");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;

/// System Pass: Update slideshow playback and timer.
///
/// Responsibilities:
/// 1. Checks if slideshow playback is paused (command palette open, viewport
///    dragging, active slide decoding, hidden/suspended window, or explicit
///    pause) and disarms the monotonic tick anchor while paused.
/// 2. If unpaused, advances the slideshow timer via monotonic `ctx.now_ms`.
/// 3. Emits `.next_image` application intent once the accumulated duration
///    reaches or exceeds the configured interval.
pub fn sysUpdateSlideshow(ctx: FrameContext) !void {
    const state = ctx.state;
    if (state.isSlideshowPaused()) {
        state.viewer.navigation.slideshow.syncClock(ctx.now_ms, false);
        return;
    }
    if (state.viewer.navigation.slideshow.tick(ctx.now_ms)) {
        try state.pushIntent(.next_image);
    }
}

test "AppState slideshow timer auto-advances slide" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const id0 = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = try dir_alloc.dupe(u8, "img1.jpg") },
    });
    const id1 = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = try dir_alloc.dupe(u8, "img2.jpg") },
    });
    state.viewer.navigation.current_index = 0;
    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{ .asset = .failed },
    });
    _ = try state.cache.appendSlot(allocator, id1, .{
        .resident = .{ .asset = .failed },
    });
    state.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 2.0 } };
    state.viewer.navigation.slideshow.syncClock(1000, true);

    try sysUpdateSlideshow(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 2000,
    });
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
    try std.testing.expectEqual(
        @as(usize, 0),
        state.viewer.navigation.current_index.?,
    );

    // Pass another second (total 2000ms >= 2.0s interval) -> queues .next_image
    const ctx_3s = FrameContext{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 3000,
    };
    try sysUpdateSlideshow(ctx_3s);
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(
        intents.AppIntent.next_image,
        state.pending_intents.items[0],
    );

    // Intent execution pass advances the slide index
    try intents_sys.sysExecuteIntents(ctx_3s);
    try std.testing.expectEqual(
        @as(usize, 1),
        state.viewer.navigation.current_index.?,
    );
}

test "AppState slideshow pauses during command palette, dragging, or explicit pause" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const dir_alloc = state.viewer.navigation.directory_arena.allocator();
    const id0 = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = try dir_alloc.dupe(u8, "img1.jpg") },
    });
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = try dir_alloc.dupe(u8, "img2.jpg") },
    });
    state.viewer.navigation.current_index = 0;
    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{ .asset = .failed },
    });
    state.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 1.0 } };

    // 1. Palette open -> paused
    state.viewer.ui.palette.lifecycle = .{ .open = .actions };
    try std.testing.expect(state.isSlideshowPaused());
    try sysUpdateSlideshow(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 2000,
    });
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
    state.viewer.ui.palette.lifecycle = .closed;
    try std.testing.expect(!state.isSlideshowPaused());

    // 2. Viewport drag active -> paused
    state.viewer.drag_state = .{ .viewport = .{ .last_x = 0, .last_y = 0 } };
    try std.testing.expect(state.isSlideshowPaused());
    try sysUpdateSlideshow(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 4000,
    });
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
    state.viewer.drag_state = .none;
    try std.testing.expect(!state.isSlideshowPaused());

    // 3. Explicit pause -> paused
    state.viewer.navigation.slideshow.pause();
    try std.testing.expect(state.isSlideshowPaused());
    try sysUpdateSlideshow(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 6000,
    });
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
    state.viewer.navigation.slideshow.unpause();

    // 4. Window minimized or occluded -> paused and wait strategy sleeps
    // indefinitely
    state.display = .{
        .visible = .{
            .windowed = .{
                .handle = undefined,
                .is_occluded = true,
            },
        },
    };
    try std.testing.expect(state.isSlideshowPaused());
    try std.testing.expectEqual(
        .wait_indefinite,
        state.computeFrameWaitStrategy(800, 600, false, false, 7000),
    );
    try sysUpdateSlideshow(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 8000,
    });
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);

    // 5. Window exposed -> wake frame arms anchor without advancing, then 1s
    // later advances
    state.display.setOccluded(false);
    try std.testing.expect(!state.isSlideshowPaused());
    try sysUpdateSlideshow(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 8000,
    });
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
    try sysUpdateSlideshow(.{
        .state = &state,
        .frame_allocator = allocator,
        .now_ms = 9000,
    });
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
}

test "sysUpdateSlideshow advances across sleep with clamped delta_time_ms" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "img1.jpg" },
    });
    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "img2.jpg" },
    });
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    _ = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{ .asset = .failed },
    });

    state.viewer.navigation.slideshow = .{
        .active = .{ .interval_s = 3.0 },
    };
    state.viewer.navigation.slideshow.syncClock(1000, true);

    // Wake after 2000ms timeout cap (t=3000ms) with clamped 33.333ms delta
    try sysUpdateSlideshow(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = 33.333,
        .now_ms = 3000,
    });
    try std.testing.expectEqual(@as(usize, 0), state.pending_intents.items.len);
    try std.testing.expectEqual(@as(?i32, 1000), state.getWaitTimeoutMs(3000));

    // Wake after remaining 1000ms (t=4000ms) -> queues .next_image
    try sysUpdateSlideshow(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = 33.333,
        .now_ms = 4000,
    });
    try std.testing.expectEqual(@as(usize, 1), state.pending_intents.items.len);
    try std.testing.expectEqual(
        intents.AppIntent.next_image,
        state.pending_intents.items[0],
    );
}
