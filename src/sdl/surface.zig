const c_pkg = @import("c.zig");
const sdl_options = @import("sdl_options");
const std = @import("std");

const c = c_pkg.c;
const has_turbojpeg = sdl_options.has_turbojpeg;

/// SDL pixel format enumeration constants.
pub const PixelFormat = struct {
    pub const rgba32: u32 = c.SDL_PIXELFORMAT_RGBA32;
    pub const bgra32: u32 = c.SDL_PIXELFORMAT_BGRA32;
    pub const xrgb8888: u32 = c.SDL_PIXELFORMAT_XRGB8888;
    pub const xbgr8888: u32 = c.SDL_PIXELFORMAT_XBGR8888;
    pub const rgbx8888: u32 = c.SDL_PIXELFORMAT_RGBX8888;
    pub const bgrx8888: u32 = c.SDL_PIXELFORMAT_BGRX8888;
    pub const rgb24: u32 = c.SDL_PIXELFORMAT_RGB24;
    pub const bgr24: u32 = c.SDL_PIXELFORMAT_BGR24;
    pub const unknown: u32 = c.SDL_PIXELFORMAT_UNKNOWN;
};

pub const ScaleMode = enum(c_int) {
    nearest = c.SDL_SCALEMODE_NEAREST,
    linear = c.SDL_SCALEMODE_LINEAR,
    pixel_art = c.SDL_SCALEMODE_PIXELART,
};

/// Decoded CPU surface paired with the original unscaled source pixel
/// dimensions (which may exceed `surface.w()`/`surface.h()` when DCT-scaled).
pub const DecodedSurface = struct {
    surface: Surface,
    source_w: u32,
    source_h: u32,
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

    /// Encodes the surface pixel data into an in-memory PNG byte slice
    /// allocated with `allocator`.
    pub fn encodePngAlloc(
        self: Surface,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const io = c.SDL_IOFromDynamicMem() orelse
            return error.SdlIoCreateFailed;
        defer _ = c.SDL_CloseIO(io);

        if (!c.IMG_SavePNG_IO(self.ptr, io, false)) {
            return error.PngEncodeFailed;
        }
        const size_i64 = c.SDL_TellIO(io);
        if (size_i64 <= 0) return error.PngEncodeFailed;
        const size: usize = @intCast(size_i64);

        const props = c.SDL_GetIOProperties(io);
        const raw_ptr = c.SDL_GetPointerProperty(
            props,
            c.SDL_PROP_IOSTREAM_DYNAMIC_MEMORY_POINTER,
            null,
        ) orelse return error.PngEncodeFailed;
        const src_bytes: [*]const u8 = @ptrCast(raw_ptr);
        return allocator.dupe(u8, src_bytes[0..size]);
    }

    /// Returns a newly allocated RGBA32 surface rotated clockwise by
    /// `quarter_turns_cw * 90` degrees.
    pub fn rotateOrthogonal(self: Surface, quarter_turns_cw: u2) ?Surface {
        const src_w_i = self.w();
        const src_h_i = self.h();
        if (src_w_i <= 0 or src_h_i <= 0) return null;

        if (quarter_turns_cw == 0) {
            return self.convert(PixelFormat.rgba32);
        }

        const owned_rgba = if (self.format() != PixelFormat.rgba32)
            self.convert(PixelFormat.rgba32) orelse return null
        else
            null;
        defer if (owned_rgba) |s| s.destroy();
        const src = owned_rgba orelse self;

        const src_w: usize = @intCast(src.w());
        const src_h: usize = @intCast(src.h());
        const is_swapped = (quarter_turns_cw & 1) != 0;
        const dst_w_i: i32 = if (is_swapped) src.h() else src.w();
        const dst_h_i: i32 = if (is_swapped) src.w() else src.h();

        const dst = Surface.create(dst_w_i, dst_h_i, PixelFormat.rgba32) orelse
            return null;
        const src_pitch: usize = @intCast(src.pitch());
        const dst_pitch: usize = @intCast(dst.pitch());
        const src_base = src.pixels();
        const dst_base = dst.pixels();

        switch (quarter_turns_cw) {
            0 => unreachable,
            1 => {
                // 90° CW: dst(x, y) = src(y, src_h - 1 - x),
                // dst_w = src_h, dst_h = src_w
                for (0..src_w) |dy| {
                    const dst_row = dst_base + dy * dst_pitch;
                    for (0..src_h) |dx| {
                        const sy = src_h - 1 - dx;
                        const sx = dy;
                        const src_px = src_base + sy * src_pitch + sx * 4;
                        const dst_px = dst_row + dx * 4;
                        @memcpy(dst_px[0..4], src_px[0..4]);
                    }
                }
            },
            2 => {
                // 180°: dst(x, y) = src(src_w - 1 - x, src_h - 1 - y)
                for (0..src_h) |dy| {
                    const sy = src_h - 1 - dy;
                    const src_row = src_base + sy * src_pitch;
                    const dst_row = dst_base + dy * dst_pitch;
                    for (0..src_w) |dx| {
                        const sx = src_w - 1 - dx;
                        const src_px = src_row + sx * 4;
                        const dst_px = dst_row + dx * 4;
                        @memcpy(dst_px[0..4], src_px[0..4]);
                    }
                }
            },
            3 => {
                // 270° clockwise (90° CCW): dst(x, y) = src(src_w - 1 - y, x)
                for (0..src_w) |dy| {
                    const sx = src_w - 1 - dy;
                    const dst_row = dst_base + dy * dst_pitch;
                    for (0..src_h) |dx| {
                        const sy = dx;
                        const src_px = src_base + sy * src_pitch + sx * 4;
                        const dst_px = dst_row + dx * 4;
                        @memcpy(dst_px[0..4], src_px[0..4]);
                    }
                }
            },
        }
        return dst;
    }

    /// Decodes an image from an in-memory byte slice, returning `null` on failure.
    pub fn loadConstMemOpt(bytes: []const u8) ?Surface {
        const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return null;
        const raw = c.IMG_Load_IO(io, true);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Decodes an image from an in-memory byte slice, using libturbojpeg fast
    /// DCT decoding (with native DCT downscaling when the source exceeds
    /// `(max_w, max_h)`) for JPEG inputs when available, and returning the
    /// original unscaled source dimensions alongside the decoded surface.
    /// Falls back to `loadConstMemOpt` for non-JPEG inputs, fatal TurboJPEG
    /// errors, or builds without TurboJPEG.
    pub fn loadConstMemScaledWithDimsOpt(
        bytes: []const u8,
        max_w: u32,
        max_h: u32,
    ) ?DecodedSurface {
        if (has_turbojpeg and max_w > 0 and max_h > 0) {
            if (loadJpegScaledTurbo(bytes, max_w, max_h)) |dec| {
                return dec;
            }
        }
        const surf = loadConstMemOpt(bytes) orelse return null;
        return .{
            .surface = surf,
            .source_w = @intCast(@max(0, surf.w())),
            .source_h = @intCast(@max(0, surf.h())),
        };
    }

    /// Decodes an image from an in-memory byte slice, using libturbojpeg fast
    /// DCT decoding (with native DCT downscaling when the source exceeds
    /// `(max_w, max_h)`) for JPEG inputs when available. Falls back to
    /// `loadConstMemOpt` for non-JPEG inputs, fatal TurboJPEG errors, or
    /// builds without TurboJPEG.
    pub fn loadConstMemScaledOpt(
        bytes: []const u8,
        max_w: u32,
        max_h: u32,
    ) ?Surface {
        const dec = loadConstMemScaledWithDimsOpt(bytes, max_w, max_h) orelse
            return null;
        return dec.surface;
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
        const raw = c.SDL_ScaleSurface(
            self.ptr,
            width,
            height,
            @backingInt(mode),
        );
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Smoothly scales this surface to `target_w x target_h` in `RGBA32` format
    /// in a single pass with zero intermediate surface allocations, reading
    /// `RGB24`, `BGR24`, and `RGBA32` directly using fixed-point stepping.
    pub fn scaleRgba32Smooth(
        self: Surface,
        target_w: i32,
        target_h: i32,
    ) ?Surface {
        if (target_w <= 0 or target_h <= 0) return null;
        if (self.ptr.pixels == null or self.pitch() <= 0) return null;
        const src_w_i = self.w();
        const src_h_i = self.h();
        if (src_w_i <= 0 or src_h_i <= 0) return null;

        if (src_w_i == target_w and src_h_i == target_h) {
            return self.convert(PixelFormat.rgba32);
        }

        const fmt = self.format();
        if (fmt == PixelFormat.rgb24) {
            return resampleDirectToRgba32(3, false, self, target_w, target_h);
        }
        if (fmt == PixelFormat.bgr24) {
            return resampleDirectToRgba32(3, true, self, target_w, target_h);
        }
        if (fmt == PixelFormat.rgba32) {
            return resampleDirectToRgba32(4, false, self, target_w, target_h);
        }

        const converted = self.convert(PixelFormat.rgba32) orelse return null;
        defer converted.destroy();
        return resampleDirectToRgba32(4, false, converted, target_w, target_h);
    }

    /// Fills the entire surface with an opaque RGB color.
    pub fn fillRgb(self: Surface, r: u8, g: u8, b: u8) bool {
        const mapped = c.SDL_MapSurfaceRGB(self.ptr, r, g, b);
        return c.SDL_FillSurfaceRect(self.ptr, null, mapped);
    }

    /// Resamples the normalized sub-rectangle `[u_min..u_max] x [v_min..v_max]`
    /// of this surface into a `target_w x target_h` `RGBA32` surface using
    /// exact floating-point bilinear UV coordinates matching GPU texture
    /// sampling (zero integer `src_rect` rounding drift on small thumbnails).
    pub fn scaleUvRectRgba32(
        self: Surface,
        u_min: f32,
        v_min: f32,
        u_max: f32,
        v_max: f32,
        target_w: i32,
        target_h: i32,
    ) ?Surface {
        if (target_w <= 0 or target_h <= 0) return null;
        if (!std.math.isFinite(u_min) or !std.math.isFinite(v_min) or
            !std.math.isFinite(u_max) or !std.math.isFinite(v_max) or
            u_max <= u_min or v_max <= v_min)
        {
            return null;
        }
        if (self.ptr.pixels == null or self.pitch() <= 0) return null;
        const src_w_i = self.w();
        const src_h_i = self.h();
        if (src_w_i <= 0 or src_h_i <= 0) return null;

        const fmt = self.format();
        if (fmt == PixelFormat.rgb24) {
            return resampleUvToRgba32(
                3,
                false,
                self,
                u_min,
                v_min,
                u_max,
                v_max,
                target_w,
                target_h,
            );
        }
        if (fmt == PixelFormat.bgr24) {
            return resampleUvToRgba32(
                3,
                true,
                self,
                u_min,
                v_min,
                u_max,
                v_max,
                target_w,
                target_h,
            );
        }
        if (fmt == PixelFormat.rgba32) {
            return resampleUvToRgba32(
                4,
                false,
                self,
                u_min,
                v_min,
                u_max,
                v_max,
                target_w,
                target_h,
            );
        }

        const converted = self.convert(PixelFormat.rgba32) orelse return null;
        defer converted.destroy();
        return resampleUvToRgba32(
            4,
            false,
            converted,
            u_min,
            v_min,
            u_max,
            v_max,
            target_w,
            target_h,
        );
    }

    /// Scales and blits this surface into the specified destination rectangle
    /// on `dst` using `mode`.
    pub fn blitScaledTo(
        self: Surface,
        dst: Surface,
        dst_x: i32,
        dst_y: i32,
        dst_w: i32,
        dst_h: i32,
        mode: ScaleMode,
    ) bool {
        var dst_rect = c.SDL_Rect{
            .x = dst_x,
            .y = dst_y,
            .w = dst_w,
            .h = dst_h,
        };
        return c.SDL_BlitSurfaceScaled(
            self.ptr,
            null,
            dst.ptr,
            &dst_rect,
            @backingInt(mode),
        );
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
        if (self.ptr.pixels == null) return false;

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
            const color_mask_4: [4]u8 = std.mem.toBytes(color_mask_u32);
            const mask_words: [4]u32 = @splat(color_mask_u32);
            const color_mask_16: Vec16 = std.mem.toBytes(mask_words);

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
        if (self.ptr.pixels == null) return false;

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
            const color_mask_4: [4]u8 = std.mem.toBytes(color_mask_u32);
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
    const color_mask_4: [4]u8 = std.mem.toBytes(color_mask_u32);

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

test "Surface.encodePngAlloc and rotateOrthogonal roundtrip" {
    const allocator = std.testing.allocator;
    const surf = Surface.create(4, 2, PixelFormat.rgba32) orelse return;
    defer surf.destroy();

    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();
    @memset(px[0 .. pitch * 2], 0);
    // Set top-left pixel (0, 0) to red (255, 0, 0, 255)
    px[0] = 255;
    px[1] = 0;
    px[2] = 0;
    px[3] = 255;

    // 90° CW: 4x2 -> 2x4, top-left (0, 0) moves to top-right (1, 0)
    const rot90 = surf.rotateOrthogonal(1) orelse return error.RotateFailed;
    defer rot90.destroy();
    try std.testing.expectEqual(@as(i32, 2), rot90.w());
    try std.testing.expectEqual(@as(i32, 4), rot90.h());
    try std.testing.expectEqual(@as(u8, 255), rot90.pixels()[1 * 4 + 0]);

    // Encode to PNG in memory and decode back
    const png_bytes = try rot90.encodePngAlloc(allocator);
    defer allocator.free(png_bytes);
    try std.testing.expect(png_bytes.len > 33);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png_bytes[0..8]);

    const decoded = Surface.loadConstMemOpt(png_bytes) orelse
        return error.DecodeFailed;
    defer decoded.destroy();
    try std.testing.expectEqual(@as(i32, 2), decoded.w());
    try std.testing.expectEqual(@as(i32, 4), decoded.h());
}

test "Surface.scaleUvRectRgba32 resamples UV rect and guards invalid inputs" {
    const src = Surface.create(4, 4, PixelFormat.rgba32) orelse return;
    defer src.destroy();

    const pitch: usize = @intCast(src.pitch());
    const px = src.pixels();
    // Fill top half red (200, 10, 20, 255), bottom half blue (10, 20, 220, 255)
    for (0..4) |y| {
        const is_bottom = y >= 2;
        for (0..4) |x| {
            const p = px + y * pitch + x * 4;
            p[0] = if (is_bottom) 10 else 200;
            p[1] = if (is_bottom) 20 else 10;
            p[2] = if (is_bottom) 220 else 20;
            p[3] = 255;
        }
    }

    // Invalid / non-finite UV bounds return null cleanly
    try std.testing.expect(
        src.scaleUvRectRgba32(std.math.nan(f32), 0.0, 1.0, 1.0, 4, 4) == null,
    );
    try std.testing.expect(
        src.scaleUvRectRgba32(0.5, 0.0, 0.5, 1.0, 4, 4) == null,
    );
    try std.testing.expect(
        src.scaleUvRectRgba32(0.0, 0.0, 1.0, 1.0, 0, 4) == null,
    );

    // Sampling strictly the bottom half [0.5..1.0] produces pure blue pixels
    const cropped = src.scaleUvRectRgba32(0.0, 0.5, 1.0, 1.0, 4, 2) orelse
        return error.ScaleUvFailed;
    defer cropped.destroy();
    try std.testing.expectEqual(@as(i32, 4), cropped.w());
    try std.testing.expectEqual(@as(i32, 2), cropped.h());
    const out_px = cropped.pixels();
    try std.testing.expectEqual(@as(u8, 10), out_px[0]);
    try std.testing.expectEqual(@as(u8, 20), out_px[1]);
    try std.testing.expectEqual(@as(u8, 220), out_px[2]);
    try std.testing.expectEqual(@as(u8, 255), out_px[3]);
}

inline fn readPixelRgbaU32(
    comptime bpp: u8,
    comptime swap_rb: bool,
    row: [*]const u8,
    x: usize,
) @Vector(4, u32) {
    const p = row + x * bpp;
    if (bpp == 4) {
        const v: @Vector(4, u8) = p[0..4].*;
        return v;
    }
    if (swap_rb) {
        return .{ p[2], p[1], p[0], 255 };
    }
    return .{ p[0], p[1], p[2], 255 };
}

fn resampleDirectToRgba32(
    comptime bpp: u8,
    comptime swap_rb: bool,
    src: Surface,
    dst_w_i: i32,
    dst_h_i: i32,
) ?Surface {
    const dst = Surface.create(dst_w_i, dst_h_i, PixelFormat.rgba32) orelse
        return null;
    const src_w: usize = @intCast(src.w());
    const src_h: usize = @intCast(src.h());
    const dst_w: usize = @intCast(dst_w_i);
    const dst_h: usize = @intCast(dst_h_i);
    const src_pitch: usize = @intCast(src.pitch());
    const dst_pitch: usize = @intCast(dst.pitch());
    const src_base = src.pixels();
    const dst_base = dst.pixels();

    const max_x: i64 = @intCast(src_w - 1);
    const max_y: i64 = @intCast(src_h - 1);
    const dst_w_i64: i64 = @intCast(dst_w);
    const dst_h_i64: i64 = @intCast(dst_h);
    const src_w_i64: i64 = @intCast(src_w);
    const src_h_i64: i64 = @intCast(src_h);

    const Vec4u8 = @Vector(4, u8);
    const Vec4u32 = @Vector(4, u32);

    if (src_w >= dst_w * 2 and src_h >= dst_h * 2) {
        const grid_shift: u2 = if (src_w >= dst_w * 4 and src_h >= dst_h * 4)
            2
        else
            1;
        const grid_n: usize = @as(usize, 1) << grid_shift;
        const total_shift: u5 = @as(u5, grid_shift) * 2;
        const bias: Vec4u32 = @splat(@as(u32, 1) << (total_shift - 1));
        const shift_vec: @Vector(4, u5) = @splat(total_shift);

        const sub_step_x: i64 = @divTrunc(
            src_w_i64 << 16,
            dst_w_i64 << grid_shift,
        );
        const sub_step_y: i64 = @divTrunc(
            src_h_i64 << 16,
            dst_h_i64 << grid_shift,
        );

        var sy_sub_fp: i64 = sub_step_y >> 1;
        for (0..dst_h) |dy| {
            var rows: [4][*]const u8 = undefined;
            for (0..grid_n) |gy| {
                const y_idx: usize = @intCast(
                    std.math.clamp(sy_sub_fp >> 16, 0, max_y),
                );
                rows[gy] = src_base + y_idx * src_pitch;
                sy_sub_fp += sub_step_y;
            }
            const dst_row = dst_base + dy * dst_pitch;

            var sx_sub_fp: i64 = sub_step_x >> 1;
            for (0..dst_w) |dx| {
                var x_indices: [4]usize = undefined;
                for (0..grid_n) |gx| {
                    x_indices[gx] = @intCast(
                        std.math.clamp(sx_sub_fp >> 16, 0, max_x),
                    );
                    sx_sub_fp += sub_step_x;
                }

                var acc: Vec4u32 = @splat(0);
                for (0..grid_n) |gy| {
                    const r_ptr = rows[gy];
                    for (0..grid_n) |gx| {
                        acc += readPixelRgbaU32(
                            bpp,
                            swap_rb,
                            r_ptr,
                            x_indices[gx],
                        );
                    }
                }
                const out_px: Vec4u8 = @intCast((acc + bias) >> shift_vec);
                dst_row[dx * 4 ..][0..4].* = out_px;
            }
        }
        return dst;
    }

    const round_bias: Vec4u32 = @splat(32768);
    const shift16: @Vector(4, u5) = @splat(16);
    const step_x_fp: i64 = @divTrunc(src_w_i64 << 16, dst_w_i64);
    const step_y_fp: i64 = @divTrunc(src_h_i64 << 16, dst_h_i64);
    const start_x_fp: i64 = (step_x_fp >> 1) - 32768;
    var sy_fp: i64 = (step_y_fp >> 1) - 32768;

    for (0..dst_h) |dy| {
        defer sy_fp += step_y_fp;
        const y0_raw = sy_fp >> 16;
        const fy: u32 = if (y0_raw < 0 or y0_raw >= max_y)
            0
        else
            @intCast((sy_fp >> 8) & 0xFF);
        const y0: usize = @intCast(std.math.clamp(y0_raw, 0, max_y));
        const y1: usize = if (y0 + 1 < src_h) y0 + 1 else y0;
        const inv_fy: u32 = 256 - fy;

        const row0 = src_base + y0 * src_pitch;
        const row1 = src_base + y1 * src_pitch;
        const dst_row = dst_base + dy * dst_pitch;

        var sx_fp: i64 = start_x_fp;
        for (0..dst_w) |dx| {
            defer sx_fp += step_x_fp;
            const x0_raw = sx_fp >> 16;
            const fx: u32 = if (x0_raw < 0 or x0_raw >= max_x)
                0
            else
                @intCast((sx_fp >> 8) & 0xFF);
            const x0: usize = @intCast(std.math.clamp(x0_raw, 0, max_x));
            const x1: usize = if (x0 + 1 < src_w) x0 + 1 else x0;
            const inv_fx: u32 = 256 - fx;

            const w00: Vec4u32 = @splat(inv_fx * inv_fy);
            const w10: Vec4u32 = @splat(fx * inv_fy);
            const w01: Vec4u32 = @splat(inv_fx * fy);
            const w11: Vec4u32 = @splat(fx * fy);

            const p00 = readPixelRgbaU32(bpp, swap_rb, row0, x0);
            const p10 = readPixelRgbaU32(bpp, swap_rb, row0, x1);
            const p01 = readPixelRgbaU32(bpp, swap_rb, row1, x0);
            const p11 = readPixelRgbaU32(bpp, swap_rb, row1, x1);

            const top_sum = p00 * w00 + p10 * w10;
            const bot_sum = p01 * w01 + p11 * w11;
            const sum = top_sum + bot_sum + round_bias;
            const out_px: Vec4u8 = @intCast(sum >> shift16);
            dst_row[dx * 4 ..][0..4].* = out_px;
        }
    }
    return dst;
}

fn resampleUvToRgba32(
    comptime bpp: u8,
    comptime swap_rb: bool,
    src: Surface,
    u_min: f32,
    v_min: f32,
    u_max: f32,
    v_max: f32,
    dst_w_i: i32,
    dst_h_i: i32,
) ?Surface {
    const dst = Surface.create(dst_w_i, dst_h_i, PixelFormat.rgba32) orelse
        return null;
    const src_w: usize = @intCast(src.w());
    const src_h: usize = @intCast(src.h());
    const dst_w: usize = @intCast(dst_w_i);
    const dst_h: usize = @intCast(dst_h_i);
    const src_pitch: usize = @intCast(src.pitch());
    const dst_pitch: usize = @intCast(dst.pitch());
    const src_base = src.pixels();
    const dst_base = dst.pixels();

    const max_x: i64 = @intCast(src_w - 1);
    const max_y: i64 = @intCast(src_h - 1);
    const src_w_f: f64 = @floatFromInt(src_w);
    const src_h_f: f64 = @floatFromInt(src_h);
    const dst_w_f: f64 = @floatFromInt(dst_w);
    const dst_h_f: f64 = @floatFromInt(dst_h);

    const du: f64 = (@as(f64, u_max) - @as(f64, u_min)) / dst_w_f;
    const dv: f64 = (@as(f64, v_max) - @as(f64, v_min)) / dst_h_f;
    const step_x_fp: i64 = @intFromFloat(@round(du * src_w_f * 65536.0));
    const step_y_fp: i64 = @intFromFloat(@round(dv * src_h_f * 65536.0));
    const start_x_fp: i64 = @intFromFloat(
        @round(((@as(f64, u_min) + 0.5 * du) * src_w_f - 0.5) * 65536.0),
    );
    var sy_fp: i64 = @intFromFloat(
        @round(((@as(f64, v_min) + 0.5 * dv) * src_h_f - 0.5) * 65536.0),
    );

    const Vec4u8 = @Vector(4, u8);
    const Vec4u32 = @Vector(4, u32);
    const round_bias: Vec4u32 = @splat(32768);
    const shift16: @Vector(4, u5) = @splat(16);

    for (0..dst_h) |dy| {
        defer sy_fp += step_y_fp;
        const y0_raw = sy_fp >> 16;
        const fy: u32 = if (y0_raw < 0 or y0_raw >= max_y)
            0
        else
            @intCast((sy_fp >> 8) & 0xFF);
        const y0: usize = @intCast(std.math.clamp(y0_raw, 0, max_y));
        const y1: usize = if (y0 + 1 < src_h) y0 + 1 else y0;
        const inv_fy: u32 = 256 - fy;

        const row0 = src_base + y0 * src_pitch;
        const row1 = src_base + y1 * src_pitch;
        const dst_row = dst_base + dy * dst_pitch;

        var sx_fp: i64 = start_x_fp;
        for (0..dst_w) |dx| {
            defer sx_fp += step_x_fp;
            const x0_raw = sx_fp >> 16;
            const fx: u32 = if (x0_raw < 0 or x0_raw >= max_x)
                0
            else
                @intCast((sx_fp >> 8) & 0xFF);
            const x0: usize = @intCast(std.math.clamp(x0_raw, 0, max_x));
            const x1: usize = if (x0 + 1 < src_w) x0 + 1 else x0;
            const inv_fx: u32 = 256 - fx;

            const w00: Vec4u32 = @splat(inv_fx * inv_fy);
            const w10: Vec4u32 = @splat(fx * inv_fy);
            const w01: Vec4u32 = @splat(inv_fx * fy);
            const w11: Vec4u32 = @splat(fx * fy);

            const p00 = readPixelRgbaU32(bpp, swap_rb, row0, x0);
            const p10 = readPixelRgbaU32(bpp, swap_rb, row0, x1);
            const p01 = readPixelRgbaU32(bpp, swap_rb, row1, x0);
            const p11 = readPixelRgbaU32(bpp, swap_rb, row1, x1);

            const top_sum = p00 * w00 + p10 * w10;
            const bot_sum = p01 * w01 + p11 * w11;
            const sum = top_sum + bot_sum + round_bias;
            const out_px: Vec4u8 = @intCast(sum >> shift16);
            dst_row[dx * 4 ..][0..4].* = out_px;
        }
    }
    return dst;
}

fn loadJpegScaledTurbo(
    bytes: []const u8,
    max_w: u32,
    max_h: u32,
) ?DecodedSurface {
    if (!has_turbojpeg) return null;
    if (bytes.len < 3 or
        bytes[0] != 0xFF or
        bytes[1] != 0xD8 or
        bytes[2] != 0xFF)
    {
        return null;
    }
    const jpeg_len = std.math.cast(c_ulong, bytes.len) orelse return null;

    const handle = c.tjInitDecompress() orelse return null;
    defer _ = c.tjDestroy(handle);

    var src_w_c: c_int = 0;
    var src_h_c: c_int = 0;
    var subsamp: c_int = 0;
    var colorspace: c_int = 0;
    if (c.tjDecompressHeader3(
        handle,
        bytes.ptr,
        jpeg_len,
        &src_w_c,
        &src_h_c,
        &subsamp,
        &colorspace,
    ) != 0) {
        return null;
    }
    if (src_w_c <= 0 or src_h_c <= 0) return null;

    const src_w: u64 = @intCast(src_w_c);
    const src_h: u64 = @intCast(src_h_c);
    const max_w_u: u64 = max_w;
    const max_h_u: u64 = max_h;

    var target_w = src_w;
    var target_h = src_h;
    if (src_w > max_w_u or src_h > max_h_u) {
        const sx = @as(f64, @floatFromInt(max_w_u)) /
            @as(f64, @floatFromInt(src_w));
        const sy = @as(f64, @floatFromInt(max_h_u)) /
            @as(f64, @floatFromInt(src_h));
        const factor = @min(sx, sy);
        const scaled_w_f = @round(@as(f64, @floatFromInt(src_w)) * factor);
        const scaled_h_f = @round(@as(f64, @floatFromInt(src_h)) * factor);
        target_w = @max(1, @as(u64, @intFromFloat(scaled_w_f)));
        target_h = @max(1, @as(u64, @intFromFloat(scaled_h_f)));
    }

    var best_w = src_w;
    var best_h = src_h;
    var num_factors: c_int = 0;
    if (c.tjGetScalingFactors(&num_factors)) |factors| {
        if (num_factors > 0) {
            for (factors[0..@intCast(num_factors)]) |sf| {
                if (sf.num <= 0 or sf.denom <= 0 or sf.num > sf.denom) {
                    continue;
                }
                const num: u64 = @intCast(sf.num);
                const denom: u64 = @intCast(sf.denom);
                const sw = @divCeil(src_w * num, denom);
                const sh = @divCeil(src_h * num, denom);
                if (sw >= target_w and sh >= target_h and
                    (sw < best_w or (sw == best_w and sh < best_h)))
                {
                    best_w = sw;
                    best_h = sh;
                }
            }
        }
    }

    const out_w = std.math.cast(i32, best_w) orelse return null;
    const out_h = std.math.cast(i32, best_h) orelse return null;
    const dst = Surface.create(out_w, out_h, PixelFormat.rgba32) orelse
        return null;
    const rc = c.tjDecompress2(
        handle,
        bytes.ptr,
        jpeg_len,
        dst.pixels(),
        out_w,
        dst.pitch(),
        out_h,
        c.TJPF_RGBA,
        c.TJFLAG_FASTDCT | c.TJFLAG_FASTUPSAMPLE,
    );
    if (rc != 0 and c.tjGetErrorCode(handle) != c.TJERR_WARNING) {
        dst.destroy();
        return null;
    }
    return .{
        .surface = dst,
        .source_w = std.math.cast(u32, src_w) orelse @intCast(@max(0, out_w)),
        .source_h = std.math.cast(u32, src_h) orelse @intCast(@max(0, out_h)),
    };
}

test "Surface.scaleRgba32Smooth box-averages RGB24 and 4x downscales" {
    // Create a 4x4 RGB24 checkerboard of 0 and 200
    const surf = Surface.create(4, 4, PixelFormat.rgb24) orelse return;
    defer surf.destroy();

    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();
    for (0..4) |y| {
        for (0..4) |x| {
            const val: u8 = if (((x + y) & 1) == 0) 200 else 0;
            const p = px + y * pitch + x * 3;
            p[0] = val;
            p[1] = val;
            p[2] = val;
        }
    }

    // Downscaling 4x4 checkerboard to 1x1 must average all 16 pixels to 100
    const scaled = surf.scaleRgba32Smooth(1, 1) orelse return error.ScaleFailed;
    defer scaled.destroy();
    try std.testing.expectEqual(PixelFormat.rgba32, scaled.format());
    try std.testing.expectEqual(@as(u8, 100), scaled.pixels()[0]);
    try std.testing.expectEqual(@as(u8, 100), scaled.pixels()[1]);
    try std.testing.expectEqual(@as(u8, 100), scaled.pixels()[2]);
    try std.testing.expectEqual(@as(u8, 255), scaled.pixels()[3]);
}

test "Surface.loadConstMemScaledOpt decodes JPEG with DCT scaling" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "testfiles/images/000_0_1024x682.jpg",
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(bytes);

    const dec = Surface.loadConstMemScaledWithDimsOpt(bytes, 256, 256) orelse
        return error.DecodeFailed;
    defer dec.surface.destroy();

    try std.testing.expectEqual(@as(u32, 1024), dec.source_w);
    try std.testing.expectEqual(@as(u32, 682), dec.source_h);
    try std.testing.expect(dec.surface.w() >= 256);
    try std.testing.expect(dec.surface.h() >= 170);
    if (has_turbojpeg) {
        try std.testing.expectEqual(PixelFormat.rgba32, dec.surface.format());
        try std.testing.expect(dec.surface.w() <= 512);
        try std.testing.expect(dec.surface.h() <= 341);
    }
}

test "Surface.loadConstMemScaledOpt falls back on PNG and corrupt JPEG" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const png_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "testfiles/golden-screenshots/init.png",
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(png_bytes);

    const png_surf = Surface.loadConstMemScaledOpt(png_bytes, 128, 128) orelse
        return error.DecodeFailed;
    defer png_surf.destroy();
    try std.testing.expect(png_surf.w() > 0 and png_surf.h() > 0);

    const corrupt_jpg = "\xFF\xD8\xFF\xE0\x00\x02bad";
    try std.testing.expect(
        Surface.loadConstMemScaledOpt(corrupt_jpg, 128, 128) == null,
    );
}
