const std = @import("std");
const c = @import("c.zig").c;
const gpu = @import("gpu.zig");

pub const window_flags = struct {
    pub const hidden: u64 = c.SDL_WINDOW_HIDDEN;
    pub const resizable: u64 = c.SDL_WINDOW_RESIZABLE;
    pub const high_pixel_density: u64 = c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
};

pub const Window = struct {
    ptr: *c.SDL_Window,

    pub fn createZ(title: [:0]const u8, w: i32, h: i32, flags: u64) ?Window {
        const raw = c.SDL_CreateWindow(title.ptr, w, h, flags);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    pub fn getSize(self: Window) struct { w: i32, h: i32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.ptr, &w, &h);
        return .{ .w = w, .h = h };
    }

    pub fn getSizeInPixels(self: Window) struct { w: i32, h: i32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.ptr, &w, &h);
        return .{ .w = w, .h = h };
    }

    pub fn setFullscreen(self: Window, enable: bool) !void {
        if (!c.SDL_SetWindowFullscreen(self.ptr, enable)) {
            return error.SdlFullscreenFailed;
        }
    }

    pub fn setTitle(self: Window, title: [:0]const u8) void {
        _ = c.SDL_SetWindowTitle(self.ptr, title.ptr);
    }

    pub fn claimForGpu(self: Window, device: gpu.Device) bool {
        return c.SDL_ClaimWindowForGPUDevice(device.ptr, @ptrCast(self.ptr));
    }

    pub fn releaseFromGpu(self: Window, device: gpu.Device) void {
        c.SDL_ReleaseWindowFromGPUDevice(device.ptr, self.ptr);
    }

    pub fn waitAndAcquireSwapchainTexture(self: Window, cmd_buf: gpu.CommandBuffer, swap_w: *u32, swap_h: *u32) ?gpu.Texture {
        var raw_tex: ?*c.SDL_GPUTexture = null;
        if (c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buf.ptr, self.ptr, &raw_tex, swap_w, swap_h)) {
            return if (raw_tex) |t| .{ .ptr = t } else null;
        }
        return null;
    }

    pub fn startTextInput(self: Window) bool {
        return c.SDL_StartTextInput(@ptrCast(self.ptr));
    }

    pub fn stopTextInput(self: Window) bool {
        return c.SDL_StopTextInput(@ptrCast(self.ptr));
    }

    pub fn destroy(self: Window) void {
        c.SDL_DestroyWindow(self.ptr);
    }
};
