const std = @import("std");
const clay = @import("zclay");
const FrameContext = @import("context.zig").FrameContext;

/// System Pass: Process discrete UI component pointer interactions (close buttons, controls).
///
/// Responsibilities:
/// 1. Tests mouse clicks against interactive overlay buttons (e.g. InfoCloseBtn, StatsCloseBtn).
/// 2. Dispatches overlay dismissal directly on AppState.
pub fn sysProcessUiInteractions(ctx: FrameContext) void {
    const self = ctx.state;
    const input = ctx.input orelse return;

    if (input.mouse_left_clicked and !input.isPointerInDebugPanel()) {
        if (self.viewer.ui.overlays.show_info and
            clay.pointerOver(clay.getElementId("InfoCloseBtn")))
        {
            self.viewer.ui.overlays.show_info = false;
        }
        if (self.viewer.ui.overlays.show_stats and
            clay.pointerOver(clay.getElementId("StatsCloseBtn")))
        {
            self.viewer.ui.overlays.show_stats = false;
        }
    }
}
