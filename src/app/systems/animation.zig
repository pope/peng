const app_state = @import("../state.zig");
const context = @import("context.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;

/// System Pass: Update animation channels and resolve settled transitions.
///
/// Responsibilities:
/// 1. Advances all active animation channels using `ctx.delta_time_ms`.
/// 2. If the command palette was in the closing phase and the reveal channel
///    completed, resets the palette state.
/// 3. If an image crossfade animation completes, releases the previous slide
///    index and resets crossfade state.
pub fn sysUpdateAnimations(ctx: FrameContext) void {
    const state = ctx.state;
    const anim = &state.viewer.animations;

    if (anim.hasActiveAnimations()) {
        const delta = @max(@as(f32, @floatCast(ctx.delta_time_ms)), 0.0);
        anim.tick(delta);
    }

    const now = if (ctx.input) |inp|
        (if (inp.ticks > 0) inp.ticks else @max(sdl.timer.getTicks(), 1))
    else
        @max(sdl.timer.getTicks(), 1);

    // Check if transient title overlay auto-hide timeout has expired
    switch (state.viewer.ui.overlays.title_display) {
        .transient => |t| {
            if (now >= t.timeout_ms) {
                state.viewer.ui.overlays.title_display = .hidden;
                const progress = anim.get(.title_overlay);
                const dur = @max(
                    state_pkg.DURATION_TITLE_OVERLAY_CLOSE_MS * progress,
                    30.0,
                );
                anim.start(.title_overlay, 0.0, dur, .ease_out_quad);
            }
        },
        .hidden, .pinned => {},
    }

    // Check if transient snackbar auto-hide timeout has expired
    switch (state.viewer.ui.snackbar.notification) {
        .active => |*active| {
            if (active.timeout_ms > 0) {
                if (now >= active.timeout_ms) {
                    active.timeout_ms = 0;
                    const progress = anim.get(.snackbar);
                    const dur = @max(
                        state_pkg.DURATION_SNACKBAR_CLOSE_MS * progress,
                        30.0,
                    );
                    anim.start(.snackbar, 0.0, dur, .ease_out_quad);
                }
            }
        },
        .none => {},
    }

    // Clear snackbar message buffer once fade-out has completely settled
    if (!anim.isActive(.snackbar) and anim.get(.snackbar) <= 0.001) {
        switch (state.viewer.ui.snackbar.notification) {
            .active => |active| {
                if (active.timeout_ms == 0) {
                    state.viewer.ui.snackbar.clear();
                }
            },
            .none => {},
        }
    }

    // Check if palette close animation has finished settling to 0.0 (even if already settled)
    if (state.viewer.ui.palette.is_closing) {
        if (!anim.isActive(.palette_reveal) or anim.get(.palette_reveal) <= 0.001) {
            state.viewer.ui.palette.reset();
        }
    }

    // If image crossfade has settled to 1.0 (or is no longer active),
    // release protected outgoing slide
    if (state.viewer.image_transition != .none) {
        if (!anim.isActive(.image_crossfade) and anim.get(.image_crossfade) >= 0.999) {
            state.viewer.image_transition = .none;
        }
    }
}

test "sysUpdateAnimations palette reveal and close transition lifecycle" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const open_half = state_pkg.DURATION_PALETTE_OPEN_MS / 2.0;
    const close_half = state_pkg.DURATION_PALETTE_CLOSE_MS / 2.0;

    // 1. Open palette: starts animation to 1.0
    try state.openPalette(.actions);
    try std.testing.expect(state.viewer.ui.palette.mode == .actions);
    try std.testing.expect(!state.viewer.ui.palette.is_closing);
    try std.testing.expect(state.viewer.hasActiveAnimation());
    try std.testing.expect(state.isBusy());

    // 2. Tick 50% through open duration
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = open_half,
    });
    try std.testing.expect(state.viewer.animations.get(.palette_reveal) > 0.4);
    try std.testing.expect(state.viewer.animations.get(.palette_reveal) < 1.0);

    // 3. Tick remaining 50%: settles at 1.0
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = open_half,
    });
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        state.viewer.animations.get(.palette_reveal),
        0.001,
    );
    try std.testing.expect(!state.viewer.hasActiveAnimation());

    // 4. Close palette: begins fade-out
    state.closePalette();
    try std.testing.expect(state.viewer.ui.palette.is_closing);
    try std.testing.expect(state.viewer.ui.palette.mode == .actions);
    try std.testing.expect(state.viewer.hasActiveAnimation());

    // 5. Tick 50% through close duration
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = close_half,
    });
    try std.testing.expect(state.viewer.ui.palette.is_closing);
    try std.testing.expect(state.viewer.animations.get(.palette_reveal) < 0.6);

    // 6. Tick remaining 50%: finishes closing and resets palette
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = close_half,
    });
    try std.testing.expect(!state.viewer.ui.palette.is_closing);
    try std.testing.expect(state.viewer.ui.palette.mode == .inactive);
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.0),
        state.viewer.animations.get(.palette_reveal),
        0.001,
    );
    try std.testing.expect(!state.viewer.hasActiveAnimation());
}

test "sysUpdateAnimations palette reset when settleAll is called mid-close" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.openPalette(.actions);
    state.closePalette();
    try std.testing.expect(state.viewer.ui.palette.is_closing);

    // Simulate headless/test-mode settleAll
    state.viewer.animations.settleAll();
    try std.testing.expect(!state.viewer.animations.hasActiveAnimations());

    // Even with hasActiveAnimations() == false, sysUpdateAnimations must reset the closing palette!
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
    try std.testing.expect(!state.viewer.ui.palette.is_closing);
    try std.testing.expect(state.viewer.ui.palette.mode == .inactive);
}

test "sysUpdateAnimations thumb_crossfade lifecycle" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.animations.startFrom(
        .thumb_crossfade,
        0.0,
        1.0,
        state_pkg.DURATION_THUMB_CROSSFADE_MS,
        .ease_out_quad,
    );

    try std.testing.expect(state.viewer.hasActiveAnimation());
    try std.testing.expect(state.viewer.animations.isActive(.thumb_crossfade));

    // Tick halfway
    const half = state_pkg.DURATION_THUMB_CROSSFADE_MS / 2.0;
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = half,
    });
    try std.testing.expect(state.viewer.animations.get(.thumb_crossfade) > 0.4);
    try std.testing.expect(state.viewer.animations.get(.thumb_crossfade) < 1.0);
    try std.testing.expect(state.viewer.hasActiveAnimation());

    // Tick remaining half: settles at 1.0
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = half,
    });
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        state.viewer.animations.get(.thumb_crossfade),
        0.001,
    );
    try std.testing.expect(!state.viewer.animations.isActive(.thumb_crossfade));
}

test "sysUpdateAnimations title_overlay auto-hide timeout and fade-out" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const now = sdl.timer.getTicks();

    // Start open animation and set auto-hide timeout in the past
    state.viewer.animations.start(
        .title_overlay,
        1.0,
        state_pkg.DURATION_TITLE_OVERLAY_OPEN_MS,
        .ease_out_quad,
    );
    state.viewer.animations.settleAll();
    state.viewer.ui.overlays.title_display = .{
        .transient = .{ .timeout_ms = @max(now -| 10, 1) },
    };

    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });

    try std.testing.expectEqual(
        state_pkg.TitleDisplay.hidden,
        state.viewer.ui.overlays.title_display,
    );
    try std.testing.expect(state.viewer.animations.isActive(.title_overlay));

    // Tick through close duration
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = state_pkg.DURATION_TITLE_OVERLAY_CLOSE_MS,
    });
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.0),
        state.viewer.animations.get(.title_overlay),
        0.001,
    );
    try std.testing.expect(!state.viewer.hasActiveAnimation());
}

test "sysUpdateAnimations snackbar auto-hide timeout and fade-out" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const now = sdl.timer.getTicks();

    // Start snackbar animation with message and auto-hide timeout in the past
    state.viewer.ui.snackbar.show("Filter: Lanczos3", @max(now -| 10, 1));
    state.viewer.animations.start(
        .snackbar,
        1.0,
        state_pkg.DURATION_SNACKBAR_OPEN_MS,
        .ease_out_quad,
    );
    state.viewer.animations.settleAll();

    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });

    try std.testing.expectEqual(@as(u64, 0), state.viewer.ui.snackbar.getTimeoutMs());
    try std.testing.expect(state.viewer.animations.isActive(.snackbar));

    // Tick through close duration
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = state_pkg.DURATION_SNACKBAR_CLOSE_MS,
    });
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.0),
        state.viewer.animations.get(.snackbar),
        0.001,
    );
    try std.testing.expect(!state.viewer.hasActiveAnimation());
    // Buffer cleared after settled
    try std.testing.expectEqual(@as(usize, 0), state.viewer.ui.snackbar.getMessage().len);
}

test "sysUpdateAnimations image_crossfade settling clears image_transition" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.image_transition = .{ .active = .{ .prev_index = 3, .prev_rotation = 90.0 } };
    state.viewer.animations.startFrom(
        .image_crossfade,
        0.0,
        1.0,
        state_pkg.DURATION_IMAGE_DISSOLVE_MS,
        .ease_in_out_cubic,
    );

    try std.testing.expect(state.viewer.hasActiveAnimation());
    try std.testing.expect(state.viewer.image_transition != .none);

    // Tick halfway
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = state_pkg.DURATION_IMAGE_DISSOLVE_MS / 2.0,
    });
    try std.testing.expect(state.viewer.image_transition != .none);
    try std.testing.expect(state.viewer.animations.get(.image_crossfade) > 0.3);
    try std.testing.expect(state.viewer.animations.get(.image_crossfade) < 0.7);

    // Tick remaining duration: settles at 1.0 and clears image_transition
    sysUpdateAnimations(.{
        .state = &state,
        .frame_allocator = allocator,
        .delta_time_ms = state_pkg.DURATION_IMAGE_DISSOLVE_MS,
    });
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        state.viewer.animations.get(.image_crossfade),
        0.001,
    );
    try std.testing.expect(!state.viewer.hasActiveAnimation());
    try std.testing.expectEqual(
        state_pkg.types.ImageTransition.none,
        state.viewer.image_transition,
    );
}
