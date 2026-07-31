const std = @import("std");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;

/// System Pass: Update slideshow timer
pub fn sysUpdateSlideshow(state: *AppState, delta_time_ms: f64) !void {
    if (state.viewer.navigation.slideshow.tick(@floatCast(delta_time_ms))) {
        try state.next();
    }
}
