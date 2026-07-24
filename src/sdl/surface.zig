const std = @import("std");
const c = @import("c.zig").c;

pub const PixelFormat = struct {
    pub const rgba32: u32 = c.SDL_PIXELFORMAT_RGBA32;
    pub const bgra32: u32 = c.SDL_PIXELFORMAT_BGRA32;
    pub const unknown: u32 = c.SDL_PIXELFORMAT_UNKNOWN;
};

pub const ScaleMode = enum(c_int) {
    nearest = c.SDL_SCALEMODE_NEAREST,
    linear = c.SDL_SCALEMODE_LINEAR,
    pixel_art = c.SDL_SCALEMODE_PIXELART,
};

pub const Surface = struct {
    ptr: *c.SDL_Surface,

    pub fn create(width: i32, height: i32, format_id: u32) ?Surface {
        const raw = c.SDL_CreateSurface(width, height, format_id);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    pub fn createFrom(width: i32, height: i32, format_id: u32, data_ptr: ?*anyopaque, pitch_bytes: i32) ?Surface {
        const raw = c.SDL_CreateSurfaceFrom(width, height, format_id, data_ptr, pitch_bytes);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    pub fn loadFile(path: [:0]const u8) !Surface {
        const raw = c.IMG_Load(path.ptr) orelse return error.SdlSurfaceLoadFailed;
        return .{ .ptr = raw };
    }

    pub fn savePng(self: Surface, path: [:0]const u8) bool {
        return c.IMG_SavePNG(self.ptr, path.ptr);
    }

    pub fn loadFilePtr(ptr: [*:0]const u8) ?Surface {
        const raw = c.IMG_Load(ptr);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    pub fn loadConstMem(bytes: []const u8) !Surface {
        const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return error.SdlIoFailed;
        const raw = c.IMG_LoadIO(io, true) orelse return error.SdlSurfaceLoadFailed;
        return .{ .ptr = raw };
    }

    pub fn loadConstMemOpt(bytes: []const u8) ?Surface {
        const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return null;
        const raw = c.IMG_Load_IO(io, true);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    pub fn convert(self: Surface, target_format: u32) ?Surface {
        const raw = c.SDL_ConvertSurface(self.ptr, target_format);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    pub fn scale(self: Surface, width: i32, height: i32, mode: ScaleMode) ?Surface {
        const raw = c.SDL_ScaleSurface(self.ptr, width, height, @intFromEnum(mode));
        return if (raw) |r| .{ .ptr = r } else null;
    }

    pub fn destroy(self: Surface) void {
        c.SDL_DestroySurface(self.ptr);
    }

    pub fn w(self: Surface) i32 {
        return self.ptr.w;
    }

    pub fn h(self: Surface) i32 {
        return self.ptr.h;
    }

    pub fn pixels(self: Surface) [*]u8 {
        return @ptrCast(self.ptr.pixels);
    }

    pub fn pitch(self: Surface) i32 {
        return self.ptr.pitch;
    }

    pub fn format(self: Surface) u32 {
        return self.ptr.format;
    }
};
