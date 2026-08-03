const std = @import("std");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;
const FrameContext = @import("root.zig").FrameContext;

/// System Pass: Update slideshow timer
pub fn sysUpdateSlideshow(ctx: FrameContext) !void {
    const state = ctx.state;
    if (state.viewer.navigation.slideshow.tick(@floatCast(ctx.delta_time_ms))) {
        try state.next();
    }
}

