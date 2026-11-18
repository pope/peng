const interaction_pkg = @import("interaction.zig");
const palette_pkg = @import("palette");
const snackbar = @import("snackbar.zig");
const std = @import("std");
const types = @import("types.zig");

const ActiveScreenshot = types.ActiveScreenshot;
const InteractionState = interaction_pkg.InteractionState;
const OverlayState = types.OverlayState;
const PaletteState = palette_pkg.PaletteState;

pub const ScreenshotMode = union(enum) {
    idle,
    capturing: ActiveScreenshot,
};

/// State container managing command palettes, UI overlays, interaction
/// tracking, and screenshot capture mode.
pub const UiState = struct {
    palette: PaletteState,
    overlays: OverlayState = .{},
    snackbar: snackbar.SnackbarState = .{},
    screenshot_mode: ScreenshotMode = .idle,
    interaction: InteractionState = .{},

    /// Initializes UI state and allocates command palette storage.
    pub fn init(allocator: std.mem.Allocator) !UiState {
        return .{
            .palette = try PaletteState.init(allocator),
        };
    }

    /// Releases palette allocations and responds to any pending screenshot
    /// requests.
    pub fn deinit(self: *UiState, io: std.Io, allocator: std.mem.Allocator) void {
        self.palette.deinit(allocator);
        switch (self.screenshot_mode) {
            .idle => {},
            .capturing => |*s| {
                s.respondQuit(io, allocator);
                self.screenshot_mode = .idle;
            },
        }
    }
};
