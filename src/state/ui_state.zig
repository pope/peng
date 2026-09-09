const std = @import("std");
const types = @import("types.zig");
const palette_state = @import("palette_state.zig");
const snackbar = @import("snackbar.zig");

const UiRenderMetrics = types.UiRenderMetrics;
const OverlayState = types.OverlayState;

pub const ScreenshotMode = union(enum) {
    idle,
    capturing: types.ActiveScreenshot,
};

/// State container managing command palettes, UI overlays, render metrics,
/// and screenshot capture mode.
pub const UiState = struct {
    palette: palette_state.PaletteState,
    overlays: OverlayState = .{},
    title_auto_hide_timeout_ms: u64 = 0,
    snackbar: snackbar.SnackbarState = .{},
    metrics: UiRenderMetrics = .{},
    screenshot_mode: ScreenshotMode = .idle,

    /// Initializes UI state and allocates command palette storage.
    pub fn init(allocator: std.mem.Allocator) !UiState {
        return .{
            .palette = try palette_state.PaletteState.init(allocator),
        };
    }

    /// Releases palette allocations and responds to any pending screenshot requests.
    pub fn deinit(self: *UiState, io: std.Io, allocator: std.mem.Allocator) void {
        self.palette.deinit();
        switch (self.screenshot_mode) {
            .idle => {},
            .capturing => |*s| {
                s.respondQuit(io, allocator);
                self.screenshot_mode = .idle;
            },
        }
    }
};
