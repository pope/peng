const c_pkg = @import("c.zig");
const surface = @import("surface.zig");

const c = c_pkg.c;
const Surface = surface.Surface;

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
    fn toSdlColor(self: Color) c.SDL_Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

/// Safe typed wrapper handle around an underlying `TTF_Font`.
pub const Font = struct {
    ptr: *c.TTF_Font,

    /// Horizontal and vertical bounding box and advance metrics for a glyph.
    pub const GlyphMetrics = struct {
        minx: i32,
        maxx: i32,
        miny: i32,
        maxy: i32,
        advance: i32,
    };

    /// Loads a TrueType font directly from a static in-memory byte buffer.
    pub fn openConstMem(bytes: []const u8, ptsize: f32) ?Font {
        const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse
            return null;
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

    /// Returns the total pixel line height of the font at its current size.
    pub fn getHeight(self: Font) i32 {
        return c.TTF_GetFontHeight(self.ptr);
    }

    /// Queries the bounding box and horizontal advance metrics for a Unicode
    /// codepoint `ch`.
    pub fn getGlyphMetrics(self: Font, ch: u32) ?GlyphMetrics {
        var minx: c_int = 0;
        var maxx: c_int = 0;
        var miny: c_int = 0;
        var maxy: c_int = 0;
        var advance: c_int = 0;
        if (c.TTF_GetGlyphMetrics(
            self.ptr,
            ch,
            &minx,
            &maxx,
            &miny,
            &maxy,
            &advance,
        )) {
            return .{
                .minx = minx,
                .maxx = maxx,
                .miny = miny,
                .maxy = maxy,
                .advance = advance,
            };
        }
        return null;
    }

    /// Renders a single Unicode codepoint `ch` as an anti-aliased 32-bit ARGB
    /// surface.
    pub fn renderGlyphBlended(self: Font, ch: u32, color: Color) ?Surface {
        const raw = c.TTF_RenderGlyph_Blended(
            self.ptr,
            ch,
            color.toSdlColor(),
        ) orelse return null;
        return .{ .ptr = raw };
    }

    /// Closes and deallocates the underlying `TTF_Font`.
    pub fn close(self: Font) void {
        c.TTF_CloseFont(self.ptr);
    }
};
