const std = @import("std");
const types = @import("types.zig");
const palette_state = @import("palette_state.zig");

pub const OverlayFlags = packed struct(u8) {
    show_info: bool = false,
    show_stats: bool = false,
    debug_show_thumb: bool = false,
    mouse_inside: bool = true,
    _padding: u4 = 0,
};

pub const RollingStats = struct {
    samples: [60]f64 = [_]f64{0.0} ** 60,
    count: usize = 0,
    index: usize = 0,

    pub fn addSample(self: *RollingStats, value: f64) void {
        self.samples[self.index] = value;
        self.index = (self.index + 1) % self.samples.len;
        if (self.count < self.samples.len) {
            self.count += 1;
        }
    }

    pub fn getMeanAndStdev(self: *const RollingStats) struct { mean: f64, stdev: f64 } {
        if (self.count == 0) return .{ .mean = 0.0, .stdev = 0.0 };
        var sum: f64 = 0.0;
        for (0..self.count) |i| {
            sum += self.samples[i];
        }
        const mean = sum / @as(f64, @floatFromInt(self.count));
        if (self.count < 2) return .{ .mean = mean, .stdev = 0.0 };

        var variance_sum: f64 = 0.0;
        for (0..self.count) |i| {
            const diff = self.samples[i] - mean;
            variance_sum += diff * diff;
        }
        const variance = @max(0.0, variance_sum) / @as(f64, @floatFromInt(self.count - 1));
        const stdev = @sqrt(variance);
        return .{ .mean = mean, .stdev = stdev };
    }

    pub fn computeStats(self: *const RollingStats) struct { mean: f64, stdev: f64 } {
        return self.getMeanAndStdev();
    }

    pub fn reset(self: *RollingStats) void {
        self.count = 0;
        self.index = 0;
    }
};

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

    pub fn init(allocator: std.mem.Allocator) UiState {
        return .{
            .palette = palette_state.PaletteState.init(allocator),
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
