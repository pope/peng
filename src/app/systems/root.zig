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
pub const metrics = @import("metrics.zig");
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
pub const sysSyncMetrics = metrics.sysSyncMetrics;
pub const sysSyncWindow = window.sysSyncWindow;
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

    // Data-Oriented Animation System (ticks active SoA animation channels)
    sysUpdateAnimations(ctx);

    // Socket Command Ingestion System (parses IPC commands -> pending_intents)
    sysExecuteIpcCommands(ctx);

    // Command Palette Input System (typing query updates, selection, clicks)
    const palette_closed_this_frame = try sysProcessPaletteInput(ctx);

    // Keyboard & File Drop Input System (maps keypresses -> pending_intents)
    try sysProcessInput(ctx, palette_closed_this_frame);

    // UI Discrete Interactions (overlay close buttons)
    try sysProcessUiInteractions(ctx, palette_closed_this_frame);

    // Viewport & Motion Systems (mouse drag/zoom & slideshow timer)
    sysUpdateViewport(ctx, palette_closed_this_frame);
    try sysUpdateSlideshow(ctx);

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

    // Metrics & Telemetry System
    sysSyncMetrics(ctx);

    if (parsed_test_mode) {
        app_state.viewer.animations.settleAll();
        app_state.viewer.zoom_controller.reset();
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
    _ = @import("metrics.zig");
    _ = @import("palette_input.zig");
    _ = @import("slideshow.zig");
    _ = @import("ui_interactions.zig");
    _ = @import("viewport.zig");
    _ = @import("window.zig");
}
