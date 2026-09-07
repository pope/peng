const std = @import("std");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;
const FrameContext = @import("root.zig").FrameContext;

/// System Pass: Update animation channels and resolve settled transitions.
///
/// Responsibilities:
/// 1. Advances all active animation channels using `ctx.delta_time_ms`.
/// 2. If the command palette was in the closing phase and the reveal channel completed, resets the palette state.
pub fn sysUpdateAnimations(ctx: FrameContext) void {
    const state = ctx.state;
    const anim = &state.viewer.animations;

    if (anim.hasActiveAnimations()) {
        const delta = @max(@as(f32, @floatCast(ctx.delta_time_ms)), 0.0);
        anim.tick(delta);
    }

    // Check if palette close animation has finished settling to 0.0 (even if already settled)
    if (state.viewer.ui.palette.is_closing) {
        if (!anim.isActive(.palette_reveal) or anim.get(.palette_reveal) <= 0.001) {
            state.viewer.ui.palette.reset();
        }
    }
}

test "sysUpdateAnimations palette reveal and close transition lifecycle" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const open_half = app_state.state_pkg.DURATION_PALETTE_OPEN_MS / 2.0;
    const close_half = app_state.state_pkg.DURATION_PALETTE_CLOSE_MS / 2.0;

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
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.viewer.animations.get(.palette_reveal), 0.001);
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
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), state.viewer.animations.get(.palette_reveal), 0.001);
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

    state.viewer.animations.setImmediate(.thumb_crossfade, 0.0);
    state.viewer.animations.start(.thumb_crossfade, 1.0, app_state.state_pkg.DURATION_THUMB_CROSSFADE_MS, .ease_out_quad);

    try std.testing.expect(state.viewer.hasActiveAnimation());
    try std.testing.expect(state.viewer.animations.isActive(.thumb_crossfade));

    // Tick halfway
    const half = app_state.state_pkg.DURATION_THUMB_CROSSFADE_MS / 2.0;
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
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.viewer.animations.get(.thumb_crossfade), 0.001);
    try std.testing.expect(!state.viewer.animations.isActive(.thumb_crossfade));
}
