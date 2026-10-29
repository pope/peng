//! Window display state and active SDL window backend management.

const sdl = @import("sdl");
const std = @import("std");

/// Claimed SDL window handle, pixel format, fullscreen state, borderless
/// state, and title string cache.
/// Invariant: Only constructed once a real `sdl.Window` has been created and
/// claimed by the GPU device.
pub const ActiveWindow = struct {
    handle: sdl.Window,
    pixel_format: u32 = sdl.PixelFormat.unknown,
    cached_title: ?[]const u8 = null,
    is_fullscreen: bool = false,
    is_borderless: bool = false,

    /// Frees the cached window title string allocation if present.
    pub fn deinit(self: *ActiveWindow, gpa: std.mem.Allocator) void {
        if (self.cached_title) |t| {
            gpa.free(t);
            self.cached_title = null;
        }
    }
};

/// Underlying display backend: either an offscreen/headless harness or a
/// GPU-claimed SDL window handle.
pub const DisplayBackend = union(enum) {
    headless,
    windowed: ActiveWindow,

    /// Releases any memory allocations held by the backend (such as window
    /// title strings).
    pub fn deinit(self: *DisplayBackend, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .headless => {},
            .windowed => |*w| w.deinit(allocator),
        }
    }
};

/// Display visibility state wrapping the underlying `DisplayBackend`
/// (`.visible` on screen vs. `.hidden` in resident `--server` mode).
pub const DisplayState = union(enum) {
    visible: DisplayBackend,
    hidden: DisplayBackend,

    /// Default headless visible display state.
    pub const default_headless: DisplayState = .{ .visible = .headless };

    /// Returns a mutable pointer to the underlying `DisplayBackend`.
    pub inline fn backendPtr(self: *DisplayState) *DisplayBackend {
        return switch (self.*) {
            .visible => |*b| b,
            .hidden => |*b| b,
        };
    }

    /// Returns the underlying `DisplayBackend` value.
    pub inline fn backend(self: DisplayState) DisplayBackend {
        return switch (self) {
            .visible, .hidden => |b| b,
        };
    }

    /// Returns `true` if the display is currently running in fullscreen mode.
    pub inline fn isFullscreen(self: DisplayState) bool {
        return switch (self.backend()) {
            .headless => false,
            .windowed => |w| w.is_fullscreen,
        };
    }

    /// Returns `true` if the display is currently hidden (e.g. resident
    /// server mode).
    pub inline fn isHidden(self: DisplayState) bool {
        return switch (self) {
            .visible => false,
            .hidden => true,
        };
    }

    /// Returns the active SDL window handle if the display is currently visible
    /// and backed by a GPU-claimed window, or `null` when headless or hidden.
    pub inline fn visibleWindow(self: DisplayState) ?sdl.Window {
        return switch (self) {
            .hidden => null,
            .visible => |b| switch (b) {
                .headless => null,
                .windowed => |w| w.handle,
            },
        };
    }

    /// Returns the swapchain texture pixel format of the display window.
    pub inline fn getPixelFormat(self: DisplayState) u32 {
        return switch (self.backend()) {
            .headless => sdl.PixelFormat.unknown,
            .windowed => |w| w.pixel_format,
        };
    }

    /// Releases any memory allocations held by the display state (such as
    /// window title strings).
    pub fn deinit(self: *DisplayState, allocator: std.mem.Allocator) void {
        self.backendPtr().deinit(allocator);
    }
};

/// Enables SDL text input events if the current display mode is a visible
/// window. No-op when headless or hidden.
pub fn startTextInput(display: DisplayState) void {
    if (display.visibleWindow()) |win| {
        if (!win.startTextInput()) {
            std.log.err("SDL_StartTextInput failed: {s}", .{sdl.getError()});
        }
    }
}

/// Disables SDL text input events if the current display mode is a visible
/// window. No-op when headless or hidden.
pub fn stopTextInput(display: DisplayState) void {
    if (display.visibleWindow()) |win| {
        if (!win.stopTextInput()) {
            std.log.err("SDL_StopTextInput failed: {s}", .{sdl.getError()});
        }
    }
}

test "DisplayState lifecycle and properties" {
    const testing = std.testing;
    var display = DisplayState.default_headless;

    try testing.expect(!display.isHidden());
    try testing.expect(!display.isFullscreen());
    try testing.expectEqual(@as(?sdl.Window, null), display.visibleWindow());
    try testing.expectEqual(
        @as(u32, sdl.PixelFormat.unknown),
        display.getPixelFormat(),
    );

    // Test hidden state
    display = .{ .hidden = .headless };
    try testing.expect(display.isHidden());
    try testing.expect(!display.isFullscreen());
    try testing.expectEqual(@as(?sdl.Window, null), display.visibleWindow());

    // Test windowed state & deinit freeing cached_title
    const title = try testing.allocator.dupe(u8, "peng - Test Window");
    display = .{
        .visible = .{
            .windowed = .{
                .handle = undefined,
                .pixel_format = sdl.PixelFormat.rgba32,
                .cached_title = title,
                .is_fullscreen = true,
                .is_borderless = false,
            },
        },
    };

    try testing.expect(!display.isHidden());
    try testing.expect(display.isFullscreen());
    try testing.expectEqual(
        @as(u32, sdl.PixelFormat.rgba32),
        display.getPixelFormat(),
    );

    const backend_ptr = display.backendPtr();
    try testing.expectEqual(
        true,
        switch (backend_ptr.*) {
            .windowed => |w| w.is_fullscreen,
            else => false,
        },
    );

    // deinit frees the duplicated cached_title without memory leak
    display.deinit(testing.allocator);
    try testing.expectEqual(
        @as(?[]const u8, null),
        switch (display) {
            .visible => |b| switch (b) {
                .windowed => |w| w.cached_title,
                else => null,
            },
            else => null,
        },
    );
}
