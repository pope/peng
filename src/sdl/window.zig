const c_pkg = @import("c.zig");
const gpu = @import("gpu.zig");
const std = @import("std");
const surface = @import("surface.zig");
const wayland_shm = @import("wayland_shm.zig");

const c = c_pkg.c;

/// Bitflags controlling window creation and behavior (hidden, resizable,
/// high-DPI, borderless).
pub const window_flags = struct {
    pub const hidden: u64 = c.SDL_WINDOW_HIDDEN;
    pub const resizable: u64 = c.SDL_WINDOW_RESIZABLE;
    pub const high_pixel_density: u64 = c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    pub const borderless: u64 = c.SDL_WINDOW_BORDERLESS;
};

/// Standard OS mouse cursor shapes supported by SDL3.
pub const SystemCursor = enum(c_int) {
    default = c.SDL_SYSTEM_CURSOR_DEFAULT,
    pointer = c.SDL_SYSTEM_CURSOR_POINTER,
};

/// Safe typed wrapper handle around an underlying `SDL_Cursor`.
pub const Cursor = extern struct {
    ptr: *c.SDL_Cursor,

    /// Creates a standard OS system cursor handle.
    pub fn createSystem(id: SystemCursor) ?Cursor {
        const raw = c.SDL_CreateSystemCursor(@intCast(@backingInt(id)));
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Returns SDL's default system cursor handle.
    pub fn getDefault() ?Cursor {
        const raw = c.SDL_GetDefaultCursor();
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Activates this cursor for the application.
    pub fn set(self: Cursor) bool {
        return c.SDL_SetCursor(self.ptr);
    }

    /// Destroys a cursor created with `createSystem`.
    pub fn destroy(self: Cursor) void {
        c.SDL_DestroyCursor(self.ptr);
    }
};

/// Allows the screen to be blanked by a screensaver or OS power management.
pub fn enableScreenSaver() bool {
    return c.SDL_EnableScreenSaver();
}

/// Prevents the screen from being blanked by a screensaver or OS power
/// management.
pub fn disableScreenSaver() bool {
    return c.SDL_DisableScreenSaver();
}

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

    /// Returns the physical framebuffer size of the window in pixels.
    pub fn getSizeInPixels(self: Window) struct { w: i32, h: i32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.ptr, &w, &h);
        return .{ .w = w, .h = h };
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

    /// Restores a minimized or maximized window to its normal size and
    /// position.
    pub fn restore(self: Window) bool {
        return c.SDL_RestoreWindow(self.ptr);
    }

    const WaylandHandles = struct {
        display: *anyopaque,
        surface: *anyopaque,
    };

    fn waylandHandles(self: Window) ?WaylandHandles {
        const props = c.SDL_GetWindowProperties(self.ptr);
        if (props == 0) return null;
        const disp = c.SDL_GetPointerProperty(
            props,
            c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER,
            null,
        ) orelse return null;
        const surf = c.SDL_GetPointerProperty(
            props,
            c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER,
            null,
        ) orelse return null;
        return .{ .display = disp, .surface = surf };
    }

    /// Returns the 2D software surface associated with this window, creating
    /// one if necessary. Must be destroyed with `destroySurface` before
    /// claiming the window for GPU rendering.
    pub fn getSurface(self: Window) ?surface.Surface {
        const raw = c.SDL_GetWindowSurface(self.ptr);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Presents the contents of the window's 2D software surface to the screen.
    pub fn updateSurface(self: Window) bool {
        return c.SDL_UpdateWindowSurface(self.ptr);
    }

    /// Destroys the 2D software surface associated with this window.
    pub fn destroySurface(self: Window) bool {
        return c.SDL_DestroyWindowSurface(self.ptr);
    }

    /// Returns true if this window currently has an active 2D software surface.
    pub fn hasSurface(self: Window) bool {
        return c.SDL_WindowHasSurface(self.ptr);
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

/// Unified zero-3D software presentation backend used during cold-start while
/// `SDL_CreateGPUDevice` initializes asynchronously. Uses `wl_shm` on Wayland
/// and `SDL_WindowSurface` (MIT-SHM / GDI / CoreGraphics) on all other
/// backends, keeping platform details encapsulated inside `sdl`.
pub const SoftwarePresenter = union(enum) {
    sdl_surface: struct {
        has_presented: bool = false,
        last_key: ?u64 = null,
    },
    wayland_shm: struct {
        shm: wayland_shm.ShmPresenter,
        last_key: ?u64 = null,
    },

    /// Writable 2D surface acquired for a single software-first frame.
    pub const AcquiredFrame = struct {
        surface: surface.Surface,
        owned_wrapper: bool,
    };

    /// Initializes the best zero-3D software presenter for `window`.
    pub fn init(window: Window) SoftwarePresenter {
        if (window.waylandHandles()) |wl| {
            if (wayland_shm.ShmPresenter.init(wl.display, wl.surface)) |shm| {
                return .{ .wayland_shm = .{ .shm = shm } };
            }
        }
        return .{ .sdl_surface = .{} };
    }

    /// Returns true once at least one software frame has been presented.
    pub fn hasPresented(self: *const SoftwarePresenter) bool {
        return switch (self.*) {
            .sdl_surface => |s| s.has_presented,
            .wayland_shm => |w| w.shm.has_committed,
        };
    }

    /// Returns true if `frame_key` matches the most recently presented frame,
    /// allowing callers to skip redundant CPU downscaling and blits.
    pub fn isFrameCurrent(
        self: *const SoftwarePresenter,
        frame_key: u64,
    ) bool {
        const last = switch (self.*) {
            .sdl_surface => |s| s.last_key,
            .wayland_shm => |w| w.last_key,
        };
        return last != null and last.? == frame_key;
    }

    /// Returns true when backed by the native Wayland `wl_shm` presenter.
    pub fn isWaylandShm(self: *const SoftwarePresenter) bool {
        return switch (self.*) {
            .sdl_surface => false,
            .wayland_shm => true,
        };
    }

    /// Acquires a writable 2D surface matching `window`'s current dimensions.
    pub fn acquireFrame(
        self: *SoftwarePresenter,
        window: Window,
    ) ?AcquiredFrame {
        return switch (self.*) {
            .sdl_surface => {
                const surf = window.getSurface() orelse return null;
                return .{ .surface = surf, .owned_wrapper = false };
            },
            .wayland_shm => |*w| {
                const log_sz = window.getSize();
                const pix_sz = window.getSizeInPixels();
                const is_exact_int_scale = log_sz.w > 0 and log_sz.h > 0 and
                    pix_sz.w > log_sz.w and
                    @mod(pix_sz.w, log_sz.w) == 0 and
                    @mod(pix_sz.h, log_sz.h) == 0 and
                    @divExact(pix_sz.w, log_sz.w) ==
                        @divExact(pix_sz.h, log_sz.h);
                const buf_w = if (is_exact_int_scale) pix_sz.w else log_sz.w;
                const buf_h = if (is_exact_int_scale) pix_sz.h else log_sz.h;
                const scale: i32 = if (is_exact_int_scale)
                    @divExact(pix_sz.w, log_sz.w)
                else
                    1;
                const fb = w.shm.acquireBuffer(buf_w, buf_h, scale) orelse
                    return null;
                const surf = surface.Surface.createFrom(
                    fb.w,
                    fb.h,
                    surface.PixelFormat.xrgb8888,
                    fb.pixels,
                    @intCast(fb.stride),
                ) orelse return null;
                return .{ .surface = surf, .owned_wrapper = true };
            },
        };
    }

    /// Presents `frame` to `window`, records `frame_key`, and releases any
    /// temporary surface wrapper.
    pub fn presentFrame(
        self: *SoftwarePresenter,
        window: Window,
        frame: AcquiredFrame,
        frame_key: u64,
    ) void {
        if (frame.owned_wrapper) frame.surface.destroy();
        switch (self.*) {
            .sdl_surface => |*s| {
                if (window.updateSurface()) {
                    s.has_presented = true;
                    s.last_key = frame_key;
                } else {
                    std.log.warn(
                        "SDL_UpdateWindowSurface failed: {s}",
                        .{c.SDL_GetError()},
                    );
                }
            },
            .wayland_shm => |*w| {
                w.shm.commit();
                w.last_key = frame_key;
            },
        }
    }

    /// Releases all software presentation resources prior to GPU claim or
    /// window teardown.
    pub fn deinit(self: *SoftwarePresenter, window: Window) void {
        switch (self.*) {
            .sdl_surface => |*s| {
                if (window.hasSurface() and !window.destroySurface()) {
                    std.log.warn(
                        "SDL_DestroyWindowSurface failed: {s}",
                        .{c.SDL_GetError()},
                    );
                }
                s.has_presented = false;
                s.last_key = null;
            },
            .wayland_shm => |*w| {
                w.shm.deinit();
                w.last_key = null;
            },
        }
    }
};

test "SoftwarePresenter tracks presented state and frame-key deduplication" {
    var presenter: SoftwarePresenter = .{ .sdl_surface = .{} };
    try std.testing.expect(!presenter.hasPresented());
    try std.testing.expect(!presenter.isWaylandShm());
    try std.testing.expect(!presenter.isFrameCurrent(42));

    presenter.sdl_surface.has_presented = true;
    presenter.sdl_surface.last_key = 42;
    try std.testing.expect(presenter.hasPresented());
    try std.testing.expect(presenter.isFrameCurrent(42));
    try std.testing.expect(!presenter.isFrameCurrent(99));
}
