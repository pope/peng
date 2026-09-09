const std = @import("std");
const c = @import("c.zig").c;

/// SDL pixel format enumeration constants.
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

/// Safe typed wrapper handle around an underlying `SDL_Surface` CPU pixel buffer.
pub const Surface = struct {
    ptr: *c.SDL_Surface,

    /// Creates a newly allocated CPU pixel surface with specified dimensions and pixel format.
    pub fn create(width: i32, height: i32, format_id: u32) ?Surface {
        const raw = c.SDL_CreateSurface(width, height, format_id);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Wraps an existing external pixel memory buffer in an SDL surface structure.
    pub fn createFrom(
        width: i32,
        height: i32,
        format_id: u32,
        data_ptr: ?*anyopaque,
        pitch_bytes: i32,
    ) ?Surface {
        const raw = c.SDL_CreateSurfaceFrom(width, height, format_id, data_ptr, pitch_bytes);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Loads and decodes an image file from the filesystem using SDL_image.
    pub fn loadFile(path: [:0]const u8) !Surface {
        const raw = c.IMG_Load(path.ptr) orelse return error.SdlSurfaceLoadFailed;
        return .{ .ptr = raw };
    }

    /// Encodes and writes the surface pixel data out to a PNG file.
    pub fn savePng(self: Surface, path: [:0]const u8) bool {
        return c.IMG_SavePNG(self.ptr, path.ptr);
    }

    /// Decodes an image from an in-memory byte slice, returning `null` on failure.
    pub fn loadConstMemOpt(bytes: []const u8) ?Surface {
        const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return null;
        const raw = c.IMG_Load_IO(io, true);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Converts this surface to `target_format`, utilizing SIMD-optimized
    /// conversion paths when available.
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
                    convertRgb24ToRgba32Simd(
                        src_pixels,
                        dst_pixels,
                        u_w,
                        u_h,
                        @intCast(self.pitch()),
                        @intCast(dst.pitch()),
                    );
                    return dst;
                }
            }

            // Fast SIMD path for BGR24 -> RGBA32
            if (src_fmt == c.SDL_PIXELFORMAT_BGR24 and target_format == c.SDL_PIXELFORMAT_RGBA32) {
                if (Surface.create(w_val, h_val, target_format)) |dst| {
                    const src_pixels = self.pixels()[0..@intCast(self.pitch() * h_val)];
                    const dst_pixels = dst.pixels()[0..@intCast(dst.pitch() * h_val)];
                    convertBgr24ToRgba32Simd(
                        src_pixels,
                        dst_pixels,
                        u_w,
                        u_h,
                        @intCast(self.pitch()),
                        @intCast(dst.pitch()),
                    );
                    return dst;
                }
            }
        }

        const raw = c.SDL_ConvertSurface(self.ptr, target_format);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Scales this surface to new pixel dimensions using the chosen scaling filter mode.
    pub fn scale(self: Surface, width: i32, height: i32, mode: ScaleMode) ?Surface {
        const raw = c.SDL_ScaleSurface(self.ptr, width, height, @intFromEnum(mode));
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Destroys and frees the underlying `SDL_Surface`.
    pub fn destroy(self: Surface) void {
        c.SDL_DestroySurface(self.ptr);
    }

    /// Returns the surface pixel width.
    pub fn w(self: Surface) i32 {
        return self.ptr.w;
    }

    /// Returns the surface pixel height.
    pub fn h(self: Surface) i32 {
        return self.ptr.h;
    }

    /// Returns a pointer to the raw pixel buffer memory.
    pub fn pixels(self: Surface) [*]u8 {
        return @ptrCast(self.ptr.pixels);
    }

    /// Returns the row byte stride (pitch) of the surface.
    pub fn pitch(self: Surface) i32 {
        return self.ptr.pitch;
    }

    /// Returns the SDL pixel format ID of the surface.
    pub fn format(self: Surface) u32 {
        return self.ptr.format;
    }

    /// Checks whether all pixels in row `y` have color components (R, G, B) <= `threshold`.
    /// Accelerated with Zig @Vector SIMD operations across 16-byte chunks.
    /// Handles 24-bit RGB/BGR and 32-bit pixel formats; tolerant to JPEG chroma
    /// subsampling / ringing.
    pub fn isRowBlack(self: Surface, y: i32, threshold: u8) bool {
        const height = self.h();
        const width = self.w();
        if (y < 0 or y >= height or width <= 0) return false;

        const details = c.SDL_GetPixelFormatDetails(self.ptr.format) orelse return false;
        const bpp = details.*.bytes_per_pixel;
        if (bpp != 3 and bpp != 4) return false;

        const pitch_val = self.pitch();
        if (pitch_val <= 0) return false;
        const surf_pitch: usize = @intCast(pitch_val);

        const px_base = self.pixels();
        const row = px_base + @as(usize, @intCast(y)) * surf_pitch;
        const w_u: usize = @intCast(width);
        const Vec16 = @Vector(16, u8);
        const thresh_vec: Vec16 = @splat(threshold);

        if (bpp == 3) {
            const total_bytes = w_u * 3;
            var idx: usize = 0;
            while (idx + 16 <= total_bytes) : (idx += 16) {
                const chunk = @as(*align(1) const Vec16, @ptrCast(&row[idx])).*;
                if (@reduce(.Or, chunk > thresh_vec)) {
                    return false;
                }
            }
            while (idx < total_bytes) : (idx += 1) {
                if (row[idx] > threshold) return false;
            }
            return true;
        } else if (bpp == 4) {
            const color_mask_u32 = details.*.Rmask | details.*.Gmask | details.*.Bmask;
            const color_mask_4: [4]u8 = @bitCast(color_mask_u32);
            const color_mask_16: Vec16 = color_mask_4 ** 4;

            const total_bytes = w_u * 4;
            var idx: usize = 0;
            while (idx + 16 <= total_bytes) : (idx += 16) {
                const chunk = @as(*align(1) const Vec16, @ptrCast(&row[idx])).*;
                const masked = chunk & color_mask_16;
                if (@reduce(.Or, masked > thresh_vec)) {
                    return false;
                }
            }
            while (idx < total_bytes) : (idx += 4) {
                const px = @as(*align(1) const [4]u8, @ptrCast(row + idx)).*;
                if ((px[0] & color_mask_4[0]) > threshold or
                    (px[1] & color_mask_4[1]) > threshold or
                    (px[2] & color_mask_4[2]) > threshold or
                    (px[3] & color_mask_4[3]) > threshold)
                {
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    /// Checks whether all pixels in column `x` have color components (R, G, B) <= `threshold`.
    /// Evaluates row-by-row with immediate early-exit on non-black pixels to
    /// minimize cache-line striding.
    /// Handles 24-bit RGB/BGR and 32-bit pixel formats; tolerant to JPEG chroma
    /// subsampling / ringing.
    pub fn isColBlack(self: Surface, x: i32, threshold: u8) bool {
        const height = self.h();
        const width = self.w();
        if (x < 0 or x >= width or height <= 0) return false;

        const details = c.SDL_GetPixelFormatDetails(self.ptr.format) orelse return false;
        const bpp = details.*.bytes_per_pixel;
        if (bpp != 3 and bpp != 4) return false;

        const pitch_val = self.pitch();
        if (pitch_val <= 0) return false;
        const surf_pitch: usize = @intCast(pitch_val);

        const px_base = self.pixels();
        const x_u: usize = @intCast(x);
        const h_u: usize = @intCast(height);

        if (bpp == 3) {
            var y: usize = 0;
            while (y < h_u) : (y += 1) {
                const px = px_base + y * surf_pitch + x_u * 3;
                if (px[0] > threshold or px[1] > threshold or px[2] > threshold) {
                    return false;
                }
            }
            return true;
        } else if (bpp == 4) {
            const color_mask_u32 = details.*.Rmask | details.*.Gmask | details.*.Bmask;
            const color_mask_4: [4]u8 = @bitCast(color_mask_u32);
            const Vec4 = @Vector(4, u8);
            const thresh_vec: Vec4 = @splat(threshold);
            const mask_vec: Vec4 = color_mask_4;

            var y: usize = 0;
            while (y < h_u) : (y += 1) {
                const px_offset = y * surf_pitch + x_u * 4;
                const px = @as(*align(1) const Vec4, @ptrCast(px_base + px_offset)).*;
                const masked = px & mask_vec;
                if (@reduce(.Or, masked > thresh_vec)) {
                    return false;
                }
            }
            return true;
        }
        return false;
    }
};

/// High-performance SIMD-accelerated 24-bit RGB to 32-bit RGBA pixel conversion
/// using Zig @Vector and @shuffle.
pub fn convertRgb24ToRgba32Simd(
    src: []const u8,
    dst: []u8,
    width: usize,
    height: usize,
    src_pitch: usize,
    dst_pitch: usize,
) void {
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
pub fn convertBgr24ToRgba32Simd(
    src: []const u8,
    dst: []u8,
    width: usize,
    height: usize,
    src_pitch: usize,
    dst_pitch: usize,
) void {
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

test "Surface.isRowBlack and isColBlack - RGB24" {
    const surf = Surface.create(20, 20, PixelFormat.rgb24) orelse return;
    defer surf.destroy();

    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();
    // Zero out entire surface
    var y: usize = 0;
    while (y < 20) : (y += 1) {
        @memset(px[y * pitch .. y * pitch + 20 * 3], 0);
    }

    // Fully black row and col return true
    try std.testing.expect(surf.isRowBlack(0, 16));
    try std.testing.expect(surf.isRowBlack(10, 16));
    try std.testing.expect(surf.isColBlack(0, 16));
    try std.testing.expect(surf.isColBlack(10, 16));

    // Threshold boundary test (16 is black, 17 is not)
    px[0 * pitch + 5 * 3] = 16;
    try std.testing.expect(surf.isRowBlack(0, 16));
    px[0 * pitch + 5 * 3] = 17;
    try std.testing.expect(!surf.isRowBlack(0, 16));
    px[0 * pitch + 5 * 3] = 0; // reset

    // Non-black pixel in first SIMD chunk of row
    px[3 * pitch + 2 * 3] = 100;
    try std.testing.expect(!surf.isRowBlack(3, 16));
    // Other rows unaffected
    try std.testing.expect(surf.isRowBlack(4, 16));
    px[3 * pitch + 2 * 3] = 0; // reset

    // Non-black pixel in tail of row (x = 19)
    px[3 * pitch + 19 * 3 + 2] = 200;
    try std.testing.expect(!surf.isRowBlack(3, 16));
    px[3 * pitch + 19 * 3 + 2] = 0; // reset

    // Non-black pixel in column
    px[12 * pitch + 7 * 3 + 1] = 50;
    try std.testing.expect(!surf.isColBlack(7, 16));
    try std.testing.expect(surf.isColBlack(8, 16));
    px[12 * pitch + 7 * 3 + 1] = 0; // reset

    // Out-of-bounds checks
    try std.testing.expect(!surf.isRowBlack(-1, 16));
    try std.testing.expect(!surf.isRowBlack(20, 16));
    try std.testing.expect(!surf.isColBlack(-1, 16));
    try std.testing.expect(!surf.isColBlack(20, 16));
}

test "Surface.isRowBlack and isColBlack - RGBA32 ignores alpha channel" {
    const surf = Surface.create(16, 16, PixelFormat.rgba32) orelse return;
    defer surf.destroy();

    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();

    // Fill with black RGB but 100% opaque alpha (255)
    var y: usize = 0;
    while (y < 16) : (y += 1) {
        var x: usize = 0;
        while (x < 16) : (x += 1) {
            const p = px + y * pitch + x * 4;
            p[0] = 0; // R
            p[1] = 0; // G
            p[2] = 0; // B
            p[3] = 255; // Alpha
        }
    }

    // Alpha = 255 must NOT trigger false non-black detection
    try std.testing.expect(surf.isRowBlack(0, 16));
    try std.testing.expect(surf.isRowBlack(15, 16));
    try std.testing.expect(surf.isColBlack(0, 16));
    try std.testing.expect(surf.isColBlack(15, 16));

    // Non-black color component in RGBA32
    px[5 * pitch + 4 * 4 + 1] = 80; // Green channel > 16
    try std.testing.expect(!surf.isRowBlack(5, 16));
    try std.testing.expect(!surf.isColBlack(4, 16));
    // Other rows/cols unaffected
    try std.testing.expect(surf.isRowBlack(6, 16));
    try std.testing.expect(surf.isColBlack(5, 16));
}

test "Surface.isRowBlack and isColBlack - XRGB8888 ignores unused padding byte" {
    const surf = Surface.create(16, 16, PixelFormat.xrgb8888) orelse return;
    defer surf.destroy();

    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();

    // Fill all bytes including padding byte with 0xFF
    var y: usize = 0;
    while (y < 16) : (y += 1) {
        @memset(px[y * pitch .. y * pitch + 16 * 4], 0xFF);
    }

    // Now clear only the color components (using SDL_MapRGB or bitwise mask)
    const details = c.SDL_GetPixelFormatDetails(surf.ptr.format) orelse return;
    const color_mask_u32 = details.*.Rmask | details.*.Gmask | details.*.Bmask;
    const color_mask_4: [4]u8 = @bitCast(color_mask_u32);

    y = 0;
    while (y < 16) : (y += 1) {
        var x: usize = 0;
        while (x < 16) : (x += 1) {
            const p = px + y * pitch + x * 4;
            // Clear color bytes, preserve padding byte as 0xFF
            p[0] &= ~color_mask_4[0];
            p[1] &= ~color_mask_4[1];
            p[2] &= ~color_mask_4[2];
            p[3] &= ~color_mask_4[3];
        }
    }

    // All color bytes are 0, but padding byte is 0xFF. Must return true!
    try std.testing.expect(surf.isRowBlack(0, 16));
    try std.testing.expect(surf.isRowBlack(15, 16));
    try std.testing.expect(surf.isColBlack(0, 16));
    try std.testing.expect(surf.isColBlack(15, 16));

    // Turn one color component on
    px[8 * pitch + 8 * 4] |= color_mask_4[0];
    try std.testing.expect(!surf.isRowBlack(8, 16));
    try std.testing.expect(!surf.isColBlack(8, 16));
}
