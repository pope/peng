const std = @import("std");
const c = @import("c.zig").c;
const Surface = @import("surface.zig").Surface;

/// Initializes the SDL_ttf font rasterization engine.
pub fn initTtf() !void {
    if (!c.TTF_Init()) return error.TtfInitFailed;
}

/// Shuts down and releases the SDL_ttf library.
pub fn quitTtf() void {
    c.TTF_Quit();
}

/// 8-bit RGBA color structure used for font rendering.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// Converts to an `SDL_Color` C struct.
    pub fn toSdlColor(self: Color) c.SDL_Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

/// Safe typed wrapper handle around an underlying `TTF_Font`.
pub const Font = struct {
    ptr: *c.TTF_Font,

    /// Pixel dimensions (width and height) of a measured text string.
    pub const TextSize = struct { w: i32, h: i32 };

    /// Opens a font file from the filesystem at `ptsize`.
    pub fn open(path: [:0]const u8, ptsize: f32) !Font {
        const raw = c.TTF_OpenFont(path.ptr, ptsize) orelse return error.TtfOpenFailed;
        return .{ .ptr = raw };
    }

    /// Loads a TrueType font directly from a static in-memory byte buffer.
    pub fn openConstMem(bytes: []const u8, ptsize: f32) ?Font {
        const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return null;
        const raw = c.TTF_OpenFontIO(io, true, ptsize);
        return if (raw) |r| .{ .ptr = r } else null;
    }

    /// Returns the currently configured point size of the font.
    pub fn getFontSize(self: Font) f32 {
        return c.TTF_GetFontSize(self.ptr);
    }

    /// Updates the font point size.
    pub fn setFontSize(self: Font, ptsize: f32) bool {
        return c.TTF_SetFontSize(self.ptr, ptsize);
    }

    /// Calculates pixel width and height dimensions of `text` when rendered with this font.
    pub fn getStringSize(self: Font, allocator: std.mem.Allocator, text: []const u8) ?TextSize {
        var w: c_int = 0;
        var h: c_int = 0;
        const c_text = allocator.dupeZ(u8, text) catch |err| {
            std.log.err("dupeZ failed in getStringSize for '{s}': {}", .{ text, err });
            return null;
        };
        defer allocator.free(c_text);
        if (c.TTF_GetStringSize(self.ptr, c_text.ptr, text.len, &w, &h)) {
            return TextSize{ .w = w, .h = h };
        }
        return null;
    }

    /// Measures how many UTF-8 characters fit within `max_w` pixels.
    pub fn measureString(
        self: Font,
        allocator: std.mem.Allocator,
        text: []const u8,
        max_w: i32,
    ) ?struct { measured_w: usize, measured_len: usize } {
        var measured_w: c_int = 0;
        var measured_len: usize = 0;
        const c_text = allocator.dupeZ(u8, text) catch |err| {
            std.log.err("dupeZ failed in measureString for '{s}': {}", .{ text, err });
            return null;
        };
        defer allocator.free(c_text);
        if (c.TTF_MeasureString(
            self.ptr,
            c_text.ptr,
            text.len,
            max_w,
            &measured_w,
            &measured_len,
        )) {
            return .{ .measured_w = @intCast(measured_w), .measured_len = measured_len };
        }
        return null;
    }

    /// Renders high-quality anti-aliased text into a newly allocated 32-bit software surface.
    pub fn renderTextBlended(
        self: Font,
        allocator: std.mem.Allocator,
        text: []const u8,
        color: Color,
    ) !Surface {
        const clean_text = if (std.mem.indexOfScalar(u8, text, 0)) |idx| text[0..idx] else text;
        if (clean_text.len == 0) return error.TtfRenderFailed;

        const c_text = allocator.dupeZ(u8, clean_text) catch |err| {
            std.log.err("dupeZ failed in renderTextBlended for '{s}': {}", .{ clean_text, err });
            return err;
        };
        defer allocator.free(c_text);

        const raw = c.TTF_RenderText_Blended(
            self.ptr,
            c_text.ptr,
            clean_text.len,
            color.toSdlColor(),
        ) orelse return error.TtfRenderFailed;
        return .{ .ptr = raw };
    }

    /// Closes and deallocates the underlying `TTF_Font`.
    pub fn close(self: Font) void {
        c.TTF_CloseFont(self.ptr);
    }
};
