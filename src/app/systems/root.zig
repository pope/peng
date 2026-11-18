const state_mod = @import("../state.zig");
const state_pkg = @import("state");
const std = @import("std");

const AppState = state_mod.AppState;
const FrameInput = state_pkg.FrameInput;

pub const animation = @import("animation.zig");
pub const asset_upload = @import("asset_upload.zig");
pub const cache = @import("cache.zig");
pub const context = @import("context.zig");
pub const input = @import("input.zig");
pub const intents = @import("intents.zig");
pub const ipc = @import("ipc.zig");
pub const palette_input = @import("palette_input.zig");
pub const slideshow = @import("slideshow.zig");
pub const ui_interactions = @import("ui_interactions.zig");
pub const viewport = @import("viewport.zig");
pub const window = @import("window.zig");

pub const FrameContext = context.FrameContext;
pub const sysExecuteIntents = intents.sysExecuteIntents;
pub const sysExecuteIpcCommands = ipc.sysExecuteIpcCommands;
pub const sysProcessAssetUploads = asset_upload.sysProcessAssetUploads;
pub const sysProcessInput = input.sysProcessInput;
pub const sysProcessPaletteInput = palette_input.sysProcessPaletteInput;
pub const sysProcessUiInteractions = ui_interactions.sysProcessUiInteractions;
pub const sysSyncWindow = window.sysSyncWindow;
pub const sysSyncWindowVisibility = window.sysSyncWindowVisibility;
pub const sysUpdateAnimations = animation.sysUpdateAnimations;
pub const sysUpdateCache = cache.sysUpdateCache;
pub const sysUpdateSlideshow = slideshow.sysUpdateSlideshow;
pub const sysUpdateViewport = viewport.sysUpdateViewport;

/// Sequential execution of all systems during the Update Phase of the frame.
/// Guaranteed: All systems run in deterministic order, use frame_allocator,
/// and do not call each other directly.
pub fn runUpdatePhase(
    app_state: *AppState,
    input_frame: FrameInput,
    frame_allocator: std.mem.Allocator,
    parsed_test_mode: bool,
) !void {
    const ctx = FrameContext{
        .state = app_state,
        .frame_allocator = frame_allocator,
        .input = input_frame,
        .delta_time_ms = input_frame.delta_time_ms,
        .now_ms = input_frame.now_ms,
    };

    // Synchronize window minimize/occlude state before animation and
    // slideshow passes
    sysSyncWindowVisibility(ctx);

    // Data-Oriented Animation System (ticks active SoA animation channels)
    sysUpdateAnimations(ctx);

    // Socket Command Ingestion System (parses IPC commands -> pending_intents)
    sysExecuteIpcCommands(ctx);

    const is_visible = !app_state.display.isHidden() and
        !app_state.display.isSuspended();

    // Command Palette Input System (typing query updates, selection, clicks)
    const palette_closed_this_frame =
        if (is_visible and input_frame.quit_request == .none)
            try sysProcessPaletteInput(ctx)
        else
            false;

    // Keyboard & File Drop Input System (maps keypresses -> pending_intents)
    try sysProcessInput(ctx, palette_closed_this_frame);

    if (is_visible and input_frame.quit_request == .none) {
        // UI Discrete Interactions (overlay close buttons)
        try sysProcessUiInteractions(ctx, palette_closed_this_frame);

        // Viewport & Motion Systems (mouse drag/zoom & slideshow timer)
        sysUpdateViewport(ctx, palette_closed_this_frame);
        try sysUpdateSlideshow(ctx);
    }

    // Execute All Ingested & Generated Intents
    try sysExecuteIntents(ctx);

    // Window Management System (synchronizes window title and display)
    sysSyncWindow(ctx);

    // Asset Upload & Texture Pipeline System
    sysProcessAssetUploads(ctx);

    // Cache Slot Management System (evicts slots & spawns prefetch workers)
    sysUpdateCache(ctx) catch |err| {
        std.log.err("Failed to update cache: {}", .{err});
    };

    const is_suspended = app_state.display.isSuspended();
    if (parsed_test_mode or is_suspended) {
        app_state.viewer.animations.settleAll();
        app_state.viewer.zoom_controller.reset();
    }
    if (is_suspended) {
        app_state.viewer.animations.setImmediate(.image_crossfade, 1.0);
        app_state.viewer.image_transition = .none;
        app_state.viewer.pan_controller.reset();
        app_state.viewer.drag_state = .none;
        app_state.viewer.ui.overlays.edit_panel.active_slider = null;
        switch (app_state.viewer.ui.palette.lifecycle) {
            .closing => app_state.viewer.ui.palette.reset(),
            .closed, .open => {},
        }
        switch (app_state.viewer.ui.overlays.title_display) {
            .transient => {
                app_state.viewer.ui.overlays.title_display = .hidden;
                app_state.viewer.animations.setImmediate(.title_overlay, 0.0);
            },
            .hidden, .pinned => {},
        }
        switch (app_state.viewer.ui.snackbar.notification) {
            .active => |active| {
                if (active.timeout_ms > 0 or
                    app_state.viewer.animations.get(.snackbar) <= 0.001)
                {
                    app_state.viewer.ui.snackbar.clear();
                    app_state.viewer.animations.setImmediate(.snackbar, 0.0);
                }
            },
            .none => {},
        }
    }
}

test {
    _ = @import("animation.zig");
    _ = @import("asset_upload.zig");
    _ = @import("cache.zig");
    _ = @import("context.zig");
    _ = @import("input.zig");
    _ = @import("intents.zig");
    _ = @import("ipc.zig");
    _ = @import("palette_input.zig");
    _ = @import("slideshow.zig");
    _ = @import("ui_interactions.zig");
    _ = @import("viewport.zig");
    _ = @import("window.zig");
}
