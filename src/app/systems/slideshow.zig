const std = @import("std");
const app_state = @import("../state.zig");
const ViewerState = app_state.ViewerState;

/// System Pass: Update slideshow timer
pub fn sysUpdateSlideshow(state: *ViewerState, delta_time_ms: f64) !void {
    if (state.navigation.slideshow.tick(@floatCast(delta_time_ms))) {
        try state.next();
    }
}
