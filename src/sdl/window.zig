const std = @import("std");
const c = @import("c.zig").c;
const gpu = @import("gpu.zig");

/// Bitflags controlling window creation and behavior (hidden, resizable, high-DPI, borderless).
pub const window_flags = struct {
    pub const hidden: u64 = c.SDL_WINDOW_HIDDEN;
    pub const resizable: u64 = c.SDL_WINDOW_RESIZABLE;
    pub const high_pixel_density: u64 = c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    pub const borderless: u64 = c.SDL_WINDOW_BORDERLESS;
};

/// Safe typed wrapper handle around an underlying `SDL_Window`.
pub const Window = extern struct {
    ptr: *c.SDL_Window,

    /// Creates a new SDL window with null-terminated title, logical
    /// dimensions, and configuration flags.
    pub fn createZ(title: [:0]const u8, w: i32, h: i32, flags: u64) ?Window {
        const raw = c.SDL_CreateWindow(title.ptr, w, h, flags);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Returns the logical window size in screen points.
    pub fn getSize(self: Window) struct { w: i32, h: i32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.ptr, &w, &h);
        return .{ .w = w, .h = h };
    }

    /// Sets the logical dimensions of the window in screen points.
    pub fn setSize(self: Window, w: i32, h: i32) bool {
        return c.SDL_SetWindowSize(self.ptr, w, h);
    }

    /// Sets the minimum logical dimensions allowed for the window.
    pub fn setMinimumSize(self: Window, min_w: i32, min_h: i32) bool {
        return c.SDL_SetWindowMinimumSize(self.ptr, min_w, min_h);
    }

    /// Returns the physical framebuffer size of the window in pixels.
    pub fn getSizeInPixels(self: Window) struct { w: i32, h: i32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.ptr, &w, &h);
        return .{ .w = w, .h = h };
    }

    /// Returns the window coordinates on desktop, or `null` if querying the
    /// position is unsupported (such as on Wayland).
    pub fn getPosition(self: Window) ?struct { x: i32, y: i32 } {
        var x: c_int = 0;
        var y: c_int = 0;
        if (!c.SDL_GetWindowPosition(self.ptr, &x, &y)) {
            return null;
        }
        return .{ .x = x, .y = y };
    }

    /// Sets the desktop coordinates of the window.
    pub fn setPosition(self: Window, x: i32, y: i32) bool {
        return c.SDL_SetWindowPosition(self.ptr, x, y);
    }

    /// Returns the usable desktop bounds (excluding taskbars and system docks)
    /// for the display containing this window, or `null` if unavailable.
    pub fn getDisplayUsableBounds(self: Window) ?struct { x: i32, y: i32, w: i32, h: i32 } {
        const display_id = c.SDL_GetDisplayForWindow(self.ptr);
        if (display_id == 0) return null;
        var rect: c.SDL_Rect = undefined;
        if (!c.SDL_GetDisplayUsableBounds(display_id, &rect)) return null;
        if (rect.w <= 0 or rect.h <= 0) return null;
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }

    /// Enables or disables borderless fullscreen mode on this window.
    pub fn setFullscreen(self: Window, enable: bool) !void {
        if (!c.SDL_SetWindowFullscreen(self.ptr, enable)) {
            return error.SdlFullscreenFailed;
        }
    }

    /// Sets the window caption title string.
    pub fn setTitle(self: Window, title: [:0]const u8) void {
        _ = c.SDL_SetWindowTitle(self.ptr, title.ptr);
    }

    /// Sets whether the window has OS border decorations or is borderless.
    pub fn setBordered(self: Window, bordered: bool) bool {
        return c.SDL_SetWindowBordered(self.ptr, bordered);
    }

    /// Makes a hidden window visible on screen.
    pub fn show(self: Window) bool {
        return c.SDL_ShowWindow(self.ptr);
    }

    /// Hides the window without destroying its underlying surface or GPU claim.
    pub fn hide(self: Window) bool {
        return c.SDL_HideWindow(self.ptr);
    }

    /// Requests that the window manager raise this window above others and set
    /// input focus.
    pub fn raise(self: Window) bool {
        return c.SDL_RaiseWindow(self.ptr);
    }

    /// Claims this window for rendering with the specified SDL GPU device.
    pub fn claimForGpu(self: Window, device: gpu.Device) bool {
        return c.SDL_ClaimWindowForGPUDevice(device.ptr, @ptrCast(self.ptr));
    }

    /// Releases this window from the specified SDL GPU device.
    pub fn releaseFromGpu(self: Window, device: gpu.Device) void {
        c.SDL_ReleaseWindowFromGPUDevice(device.ptr, self.ptr);
    }

    /// Waits for and acquires the next available swapchain texture for rendering.
    pub fn waitAndAcquireSwapchainTexture(
        self: Window,
        cmd_buf: gpu.CommandBuffer,
        swap_w: *u32,
        swap_h: *u32,
    ) ?gpu.Texture {
        var raw_tex: ?*c.SDL_GPUTexture = null;
        if (c.SDL_WaitAndAcquireGPUSwapchainTexture(
            cmd_buf.ptr,
            self.ptr,
            &raw_tex,
            swap_w,
            swap_h,
        )) {
            return if (raw_tex) |t| .{ .ptr = t } else null;
        }
        return null;
    }

    /// Starts OS text input and IME events targeting this window.
    pub fn startTextInput(self: Window) bool {
        return c.SDL_StartTextInput(@ptrCast(self.ptr));
    }

    /// Stops OS text input events targeting this window.
    pub fn stopTextInput(self: Window) bool {
        return c.SDL_StopTextInput(@ptrCast(self.ptr));
    }

    /// Destroys the underlying SDL window resource.
    pub fn destroy(self: Window) void {
        c.SDL_DestroyWindow(self.ptr);
    }
};

test "Window method declarations" {
    _ = Window.setSize;
    _ = Window.setMinimumSize;
    _ = Window.getPosition;
    _ = Window.setPosition;
    _ = Window.getDisplayUsableBounds;
}
