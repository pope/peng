const std = @import("std");
const types = @import("types.zig");
const palette_state = @import("palette_state.zig");

const UiRenderMetrics = types.UiRenderMetrics;
const OverlayState = types.OverlayState;

pub const ScreenshotMode = union(enum) {
    idle,
    capturing: types.ActiveScreenshot,
};

pub const UiState = struct {
    palette: palette_state.PaletteState,
    overlays: OverlayState = .{},
    metrics: UiRenderMetrics = .{},
    screenshot_mode: ScreenshotMode = .idle,

    pub fn init(allocator: std.mem.Allocator) !UiState {
        return .{
            .palette = try palette_state.PaletteState.init(allocator),
        };
    }

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
