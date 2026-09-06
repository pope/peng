const std = @import("std");
const app_state = @import("../state.zig");
const AppState = app_state.AppState;
const state_pkg = @import("state");
const FrameInput = state_pkg.FrameInput;
const Key = state_pkg.Key;
const KeyModifiers = state_pkg.KeyModifiers;
const input_pkg = @import("input");
const key_mapping = input_pkg.key_mapping;
/// Resolves active key context and pushes mapped AppIntents
fn handleKeyDown(
    self: *AppState,
    key: Key,
    mod: KeyModifiers,
) !void {
    if (self.viewer.ui.palette.mode != .inactive) return;

    const ctx: key_mapping.KeyContext = if (self.viewer.viewport.zoom_factor.get() > 1.0) .viewer_zoomed else .viewer_normal;
    if (key_mapping.mapKeyToAction(key, mod, ctx)) |intent| {
        try self.pushIntent(intent);
    }
}

const FrameContext = @import("root.zig").FrameContext;

/// System Pass: Process FrameInput snapshot and map keypresses/shortcuts to AppIntents
pub fn sysProcessInput(ctx: FrameContext) !void {
    const state = ctx.state;
    const input = ctx.input orelse return;

    if (input.quit_requested) {
        try state.pushIntent(.quit);
    }

    if (input.dropped_path) |path| {
        state.handlePathSelection(path) catch |err| {
            std.log.err("Failed to handle dropped path '{s}': {}", .{ path, err });
        };
    }

    if (state.viewer.ui.palette.mode != .inactive) return;

    for (input.keys_pressed.items) |key| {
        try handleKeyDown(state, key, input.key_modifiers);
    }
}
