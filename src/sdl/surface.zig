const std = @import("std");
const c = @import("c.zig").c;

pub const PixelFormat = struct {
    pub const rgba32: u32 = c.SDL_PIXELFORMAT_RGBA32;
    pub const bgra32: u32 = c.SDL_PIXELFORMAT_BGRA32;
    pub const xrgb8888: u32 = c.SDL_PIXELFORMAT_XRGB8888;
    pub const xbgr8888: u32 = c.SDL_PIXELFORMAT_XBGR8888;
    pub const rgbx8888: u32 = c.SDL_PIXELFORMAT_RGBX8888;
    pub const bgrx8888: u32 = c.SDL_PIXELFORMAT_BGRX8888;
    pub const argb8888: u32 = c.SDL_PIXELFORMAT_ARGB8888;
    pub const abgr8888: u32 = c.SDL_PIXELFORMAT_ABGR8888;
    pub const rgb24: u32 = c.SDL_PIXELFORMAT_RGB24;
    pub const bgr24: u32 = c.SDL_PIXELFORMAT_BGR24;
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
        const src_fmt = self.format();
        const w_val = self.w();
        const h_val = self.h();

        if (w_val > 0 and h_val > 0) {
            const u_w: usize = @intCast(w_val);
            const u_h: usize = @intCast(h_val);

            // Fast SIMD path for RGB24 -> RGBA32
            if (src_fmt == c.SDL_PIXELFORMAT_RGB24 and target_format == c.SDL_PIXELFORMAT_RGBA32) {
                if (Surface.create(w_val, h_val, target_format)) |dst| {
                    const src_pixels = self.pixels()[0..@intCast(self.pitch() * h_val)];
                    const dst_pixels = dst.pixels()[0..@intCast(dst.pitch() * h_val)];
                    convertRgb24ToRgba32Simd(src_pixels, dst_pixels, u_w, u_h, @intCast(self.pitch()), @intCast(dst.pitch()));
                    return dst;
                }
            }

            // Fast SIMD path for BGR24 -> RGBA32
            if (src_fmt == c.SDL_PIXELFORMAT_BGR24 and target_format == c.SDL_PIXELFORMAT_RGBA32) {
                if (Surface.create(w_val, h_val, target_format)) |dst| {
                    const src_pixels = self.pixels()[0..@intCast(self.pitch() * h_val)];
                    const dst_pixels = dst.pixels()[0..@intCast(dst.pitch() * h_val)];
                    convertBgr24ToRgba32Simd(src_pixels, dst_pixels, u_w, u_h, @intCast(self.pitch()), @intCast(dst.pitch()));
                    return dst;
                }
            }
        }

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

/// High-performance SIMD-accelerated 24-bit RGB to 32-bit RGBA pixel conversion using Zig @Vector and @shuffle.
pub fn convertRgb24ToRgba32Simd(src: []const u8, dst: []u8, width: usize, height: usize, src_pitch: usize, dst_pitch: usize) void {
    const Vec16 = @Vector(16, u8);
    const alphas = @as(Vec16, @splat(255));
    const mask = @Vector(16, i32){ 0, 1, 2, -1, 3, 4, 5, -1, 6, 7, 8, -1, 9, 10, 11, -1 };

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = src[y * src_pitch .. y * src_pitch + width * 3];
        const dst_row = dst[y * dst_pitch .. y * dst_pitch + width * 4];

        var x_src: usize = 0;
        var x_dst: usize = 0;

        while (x_src + 16 <= src_row.len and x_dst + 16 <= dst_row.len) : ({
            x_src += 12;
            x_dst += 16;
        }) {
            const chunk = @as(*align(1) const Vec16, @ptrCast(&src_row[x_src])).*;
            const rgba_vec = @shuffle(u8, chunk, alphas, mask);
            @as(*align(1) Vec16, @ptrCast(&dst_row[x_dst])).* = rgba_vec;
        }

        while (x_src + 3 <= src_row.len and x_dst + 4 <= dst_row.len) : ({
            x_src += 3;
            x_dst += 4;
        }) {
            dst_row[x_dst + 0] = src_row[x_src + 0];
            dst_row[x_dst + 1] = src_row[x_src + 1];
            dst_row[x_dst + 2] = src_row[x_src + 2];
            dst_row[x_dst + 3] = 255;
        }
    }
}

/// High-performance SIMD-accelerated 24-bit BGR to 32-bit RGBA pixel conversion using Zig @Vector.
pub fn convertBgr24ToRgba32Simd(src: []const u8, dst: []u8, width: usize, height: usize, src_pitch: usize, dst_pitch: usize) void {
    const Vec16 = @Vector(16, u8);
    const alphas = @as(Vec16, @splat(255));
    const bgr_mask = @Vector(16, i32){ 2, 1, 0, -1, 5, 4, 3, -1, 8, 7, 6, -1, 11, 10, 9, -1 };

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = src[y * src_pitch .. y * src_pitch + width * 3];
        const dst_row = dst[y * dst_pitch .. y * dst_pitch + width * 4];

        var x_src: usize = 0;
        var x_dst: usize = 0;

        while (x_src + 16 <= src_row.len and x_dst + 16 <= dst_row.len) : ({
            x_src += 12;
            x_dst += 16;
        }) {
            const chunk = @as(*align(1) const Vec16, @ptrCast(&src_row[x_src])).*;
            const rgba_vec = @shuffle(u8, chunk, alphas, bgr_mask);
            @as(*align(1) Vec16, @ptrCast(&dst_row[x_dst])).* = rgba_vec;
        }

        while (x_src + 3 <= src_row.len and x_dst + 4 <= dst_row.len) : ({
            x_src += 3;
            x_dst += 4;
        }) {
            dst_row[x_dst + 0] = src_row[x_src + 2];
            dst_row[x_dst + 1] = src_row[x_src + 1];
            dst_row[x_dst + 2] = src_row[x_src + 0];
            dst_row[x_dst + 3] = 255;
        }
    }
}

test "convertBgr24ToRgba32Simd correctness" {
    // 6 pixels = 18 bytes (exercises 16-byte SIMD loop + scalar tail)
    const src = [_]u8{
        30, 20, 10, // Pixel 0 -> RGBA: 10, 20, 30, 255
        60, 50, 40, // Pixel 1 -> RGBA: 40, 50, 60, 255
        90, 80, 70, // Pixel 2 -> RGBA: 70, 80, 90, 255
        120, 110, 100, // Pixel 3 -> RGBA: 100, 110, 120, 255
        150, 140, 130, // Pixel 4 -> RGBA: 130, 140, 150, 255
        180, 170, 160, // Pixel 5 -> RGBA: 160, 170, 180, 255
    };
    var dst: [24]u8 = undefined;

    convertBgr24ToRgba32Simd(&src, &dst, 6, 1, 18, 24);

    // Pixel 0 (SIMD path)
    try std.testing.expectEqual(@as(u8, 10), dst[0]);
    try std.testing.expectEqual(@as(u8, 20), dst[1]);
    try std.testing.expectEqual(@as(u8, 30), dst[2]);
    try std.testing.expectEqual(@as(u8, 255), dst[3]);

    // Pixel 3 (SIMD path)
    try std.testing.expectEqual(@as(u8, 100), dst[12]);
    try std.testing.expectEqual(@as(u8, 110), dst[13]);
    try std.testing.expectEqual(@as(u8, 120), dst[14]);
    try std.testing.expectEqual(@as(u8, 255), dst[15]);

    // Pixel 5 (tail path)
    try std.testing.expectEqual(@as(u8, 160), dst[20]);
    try std.testing.expectEqual(@as(u8, 170), dst[21]);
    try std.testing.expectEqual(@as(u8, 180), dst[22]);
    try std.testing.expectEqual(@as(u8, 255), dst[23]);
}
