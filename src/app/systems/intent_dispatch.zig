const std = @import("std");
const app_state = @import("../state.zig");
const actions = @import("../actions.zig");
const ViewerState = app_state.ViewerState;

/// System Pass: Execute queued discrete intents
pub fn sysExecuteIntents(state: *ViewerState) !void {
    if (state.pending_intents.items.len == 0) return;
    for (state.pending_intents.items) |intent| {
        try actions.executeIntent(state, intent);
    }
    state.clearIntents();
}
