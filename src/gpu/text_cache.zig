//! Unified UI and Per-Glyph Font Atlas Cache
//!
//! Provides shelf bin-packing, direct ASCII page tables, and hash-based lookup
//! for rasterized codepoints inside a shared `1024x1024` `RGBA8_UNORM` GPU
//! texture atlas. The top-left `4x4` block at `(0, 0)` is reserved for opaque
//! white `(255, 255, 255, 255)` so solid UI rectangles, borders, and text share
//! a single bound texture.

const geom = @import("geom");
const sdl = @import("sdl");
const std = @import("std");

const LogicalDims = geom.LogicalDims;

/// Width and height in pixels of the unified UI + font glyph GPU atlas.
pub const atlas_size: u32 = 1024;

/// Width and height in pixels of the reserved solid-white block at `(0, 0)`.
pub const white_block_size: u32 = 4;

/// Maximum number of distinct `(font_id, font_size)` fast-lookup pages.
pub const max_font_size_pages: usize = 12;

/// Pixel coordinates of a packed region within the unified glyph atlas.
pub const AtlasPos = struct {
    x: u32,
    y: u32,
};

/// 2D shelf bin-packer for packing variable-sized glyph bitmaps into the
/// fixed `atlas_size x atlas_size` texture below the reserved `(0, 0)` block.
pub const ShelfPacker = struct {
    cur_x: u32 = 0,
    cur_y: u32 = white_block_size,
    shelf_h: u32 = 0,

    /// Resets the shelf packer to its initial empty state below the white
    /// block.
    pub fn reset(self: *ShelfPacker) void {
        self.* = .{};
    }

    /// Allocates a `w x h` pixel region inside the atlas, advancing to a new
    /// shelf row when the current row is full. Returns `null` if the region
    /// does not fit within `atlas_size x atlas_size`.
    pub fn allocate(self: *ShelfPacker, w: u32, h: u32) ?AtlasPos {
        if (w == 0 or h == 0) return .{ .x = 0, .y = 0 };
        if (w > atlas_size or h > atlas_size) return null;

        if (self.cur_x +| w > atlas_size) {
            self.cur_y +|= self.shelf_h;
            self.cur_x = 0;
            self.shelf_h = 0;
        }
        if (self.cur_y +| h > atlas_size) {
            return null;
        }

        const pos = AtlasPos{
            .x = self.cur_x,
            .y = self.cur_y,
        };
        self.cur_x += w;
        self.shelf_h = @max(self.shelf_h, h);
        return pos;
    }
};

/// Measured byte length and pixel width of a prefix fitting within a max width.
pub const MeasuredPrefix = struct {
    len: usize,
    w: f32,
};

/// Lookup key for a single rasterized codepoint in the unified font atlas.
pub const GlyphCacheKey = struct {
    font_id: u16,
    font_size: u16,
    codepoint: u32,
};

/// Cached UV coordinates and horizontal layout metrics for a rasterized glyph.
pub const GlyphCacheValue = struct {
    u1: f32 = 0.0,
    v1: f32 = 0.0,
    u2: f32 = 0.0,
    v2: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,
    offset_x: f32 = 0.0,
    advance: f32 = 0.0,
    has_pixels: bool = false,
    cached: bool = false,
};

/// Direct-indexed ASCII glyph table and line height for a
/// `(font_id, font_size)` pair, avoiding per-character hash lookups and C-FFI
/// calls on warm frames.
pub const FontSizePage = struct {
    font_id: u16 = 0,
    font_size: u16 = 0,
    line_height: f32 = 0.0,
    ascii: [128]GlyphCacheValue = @splat(.{}),
};

/// Unified UI + per-glyph GPU texture atlas cache.
pub const TextCache = struct {
    atlas_texture: ?sdl.gpu.Texture = null,
    packer: ShelfPacker = .{},
    pages: [max_font_size_pages]FontSizePage = @splat(.{}),
    page_count: usize = 0,
    glyphs: std.AutoHashMapUnmanaged(GlyphCacheKey, GlyphCacheValue) = .empty,

    /// Returns true if the cache currently holds an allocated GPU atlas or
    /// cached glyph entries.
    pub inline fn hasResources(self: *const TextCache) bool {
        return self.atlas_texture != null or
            self.page_count > 0 or
            self.glyphs.count() > 0;
    }

    /// Finds the read-only `FontSizePage` for `(font_id, font_size)` if cached.
    pub inline fn findPage(
        self: *const TextCache,
        font_id: u16,
        font_size: u16,
    ) ?*const FontSizePage {
        for (self.pages[0..self.page_count]) |*page| {
            if (page.font_id == font_id and page.font_size == font_size) {
                return page;
            }
        }
        return null;
    }

    /// Finds the mutable `FontSizePage` for `(font_id, font_size)` if cached.
    pub inline fn findPageMut(
        self: *TextCache,
        font_id: u16,
        font_size: u16,
    ) ?*FontSizePage {
        for (self.pages[0..self.page_count]) |*page| {
            if (page.font_id == font_id and page.font_size == font_size) {
                return page;
            }
        }
        return null;
    }

    /// Returns an existing or newly initialized `FontSizePage` for
    /// `(font_id, font_size)`.
    pub fn getOrCreatePage(
        self: *TextCache,
        font_id: u16,
        font_size: u16,
        line_height: f32,
    ) ?*FontSizePage {
        if (self.findPageMut(font_id, font_size)) |page| return page;
        if (self.page_count >= max_font_size_pages) return null;
        const idx = self.page_count;
        self.page_count += 1;
        self.pages[idx] = .{
            .font_id = font_id,
            .font_size = font_size,
            .line_height = line_height,
        };
        return &self.pages[idx];
    }

    /// Clears all cached glyph entries and resets the shelf packer without
    /// destroying the GPU atlas texture or freeing hash map capacity.
    pub fn resetAtlas(self: *TextCache) void {
        self.page_count = 0;
        self.glyphs.clearRetainingCapacity();
        self.packer.reset();
    }

    /// Releases the unified GPU atlas texture and frees glyph map allocations.
    pub fn deinit(
        self: *TextCache,
        allocator: std.mem.Allocator,
        dev_opt: ?sdl.gpu.Device,
    ) void {
        if (dev_opt) |dev| {
            if (self.atlas_texture) |tex| {
                dev.releaseTexture(tex);
            }
        }
        self.atlas_texture = null;
        self.page_count = 0;
        self.packer.reset();
        self.glyphs.deinit(allocator);
    }

    /// Looks up a cached glyph entry matching `key`.
    pub fn getGlyph(
        self: *const TextCache,
        key: GlyphCacheKey,
    ) ?GlyphCacheValue {
        if (key.codepoint < 128) {
            if (self.findPage(key.font_id, key.font_size)) |page| {
                const entry = page.ascii[key.codepoint];
                if (entry.cached) return entry;
            }
        }
        return self.glyphs.get(key);
    }

    /// Inserts or updates a rasterized glyph entry in the atlas cache.
    pub fn putGlyph(
        self: *TextCache,
        allocator: std.mem.Allocator,
        key: GlyphCacheKey,
        value: GlyphCacheValue,
    ) !void {
        var stored = value;
        stored.cached = true;
        if (key.codepoint < 128) {
            if (self.getOrCreatePage(key.font_id, key.font_size, value.h)) |p| {
                if (p.line_height == 0.0 and value.h > 0.0) {
                    p.line_height = value.h;
                }
                p.ascii[key.codepoint] = stored;
                return;
            }
        }
        try self.glyphs.put(allocator, key, stored);
    }

    /// Returns the total number of cached ASCII glyphs across all active
    /// `FontSizePage` tables.
    pub fn countCachedAsciiGlyphs(self: *const TextCache) usize {
        var total: usize = 0;
        for (self.pages[0..self.page_count]) |*page| {
            for (page.ascii) |entry| {
                if (entry.cached) total += 1;
            }
        }
        return total;
    }

    /// Returns the vertical pixel watermark (`cur_y + shelf_h`) occupied in
    /// the `1024x1024` atlas.
    pub inline fn usedHeight(self: *const TextCache) u32 {
        return self.packer.cur_y +| self.packer.shelf_h;
    }
};

/// Encapsulates loaded font slots and optional glyph cache for text width and
/// prefix measurement without exposing underlying SDL_ttf font handles to UI
/// callers.
pub const FontMeasurer = struct {
    fonts: []const ?sdl.Font = &.{},
    cache: ?*const TextCache = null,

    /// Default empty font measurer for headless tests without loaded TTFs.
    pub const empty: FontMeasurer = .{};

    /// Returns true if the primary UI font (`fonts[0]`) is loaded and non-null.
    pub inline fn hasPrimaryFont(self: FontMeasurer) bool {
        return self.fonts.len > 0 and self.fonts[0] != null;
    }

    /// Measures the pixel width and height of `text` using `fonts[font_id]`
    /// scaled to `target_size`. Consults the cached `FontSizePage` first to
    /// avoid C-FFI calls on warm glyphs.
    pub fn measure(
        self: FontMeasurer,
        font_id: usize,
        target_size: f32,
        text: []const u8,
    ) LogicalDims {
        if (text.len == 0 or font_id >= self.fonts.len) {
            return .{ .w = 0, .h = 0 };
        }
        const font = self.fonts[font_id] orelse return .{ .w = 0, .h = 0 };
        const size_u16: u16 = @intFromFloat(@round(target_size));
        const page_opt = if (self.cache) |c|
            c.findPage(@intCast(font_id), size_u16)
        else
            null;

        var font_size_set = false;
        var total_w: f32 = 0.0;
        var byte_idx: usize = 0;
        while (byte_idx < text.len) {
            const first_byte = text[byte_idx];
            if (first_byte < 0x80) {
                byte_idx += 1;
                if (page_opt) |page| {
                    const entry = page.ascii[first_byte];
                    if (entry.cached) {
                        total_w += entry.advance;
                        continue;
                    }
                }
                if (!font_size_set) {
                    if (font.getFontSize() != target_size) {
                        _ = font.setFontSize(target_size);
                    }
                    font_size_set = true;
                }
                if (font.getGlyphMetrics(first_byte)) |m| {
                    total_w += @floatFromInt(m.advance);
                }
            } else {
                const cp_len = std.unicode.utf8ByteSequenceLength(
                    first_byte,
                ) catch 1;
                const cp: u32 = if (byte_idx + cp_len <= text.len)
                    std.unicode.utf8Decode(
                        text[byte_idx .. byte_idx + cp_len],
                    ) catch 0xFFFD
                else
                    0xFFFD;
                byte_idx += @min(cp_len, text.len - byte_idx);

                if (self.cache) |c| {
                    if (c.glyphs.get(.{
                        .font_id = @intCast(font_id),
                        .font_size = size_u16,
                        .codepoint = cp,
                    })) |entry| {
                        total_w += entry.advance;
                        continue;
                    }
                }
                if (!font_size_set) {
                    if (font.getFontSize() != target_size) {
                        _ = font.setFontSize(target_size);
                    }
                    font_size_set = true;
                }
                if (font.getGlyphMetrics(cp)) |m| {
                    total_w += @floatFromInt(m.advance);
                }
            }
        }

        const line_h: f32 = blk: {
            if (page_opt) |page| {
                if (page.line_height > 0.0) break :blk page.line_height;
            }
            if (!font_size_set and font.getFontSize() != target_size) {
                _ = font.setFontSize(target_size);
            }
            break :blk @floatFromInt(font.getHeight());
        };

        return .{
            .w = total_w,
            .h = line_h,
        };
    }

    /// Measures how many bytes of `text` fit within `max_w` pixels using
    /// `fonts[font_id]` at `target_size`.
    pub fn measurePrefix(
        self: FontMeasurer,
        font_id: usize,
        target_size: f32,
        text: []const u8,
        max_w: f32,
    ) ?MeasuredPrefix {
        if (text.len == 0 or font_id >= self.fonts.len or max_w <= 0) {
            return null;
        }
        const font = self.fonts[font_id] orelse return null;
        const size_u16: u16 = @intFromFloat(@round(target_size));
        const page_opt = if (self.cache) |c|
            c.findPage(@intCast(font_id), size_u16)
        else
            null;

        var font_size_set = false;
        var total_w: f32 = 0.0;
        var byte_idx: usize = 0;
        while (byte_idx < text.len) {
            const first_byte = text[byte_idx];
            var next_idx: usize = byte_idx + 1;
            var step_w: f32 = 0.0;

            if (first_byte < 0x80) {
                var hit = false;
                if (page_opt) |page| {
                    const entry = page.ascii[first_byte];
                    if (entry.cached) {
                        step_w = entry.advance;
                        hit = true;
                    }
                }
                if (!hit) {
                    if (!font_size_set) {
                        if (font.getFontSize() != target_size) {
                            _ = font.setFontSize(target_size);
                        }
                        font_size_set = true;
                    }
                    if (font.getGlyphMetrics(first_byte)) |m| {
                        step_w = @floatFromInt(m.advance);
                    }
                }
            } else {
                const cp_len = std.unicode.utf8ByteSequenceLength(
                    first_byte,
                ) catch 1;
                const cp: u32 = if (byte_idx + cp_len <= text.len)
                    std.unicode.utf8Decode(
                        text[byte_idx .. byte_idx + cp_len],
                    ) catch 0xFFFD
                else
                    0xFFFD;
                next_idx = byte_idx + @min(cp_len, text.len - byte_idx);

                var hit = false;
                if (self.cache) |c| {
                    if (c.glyphs.get(.{
                        .font_id = @intCast(font_id),
                        .font_size = size_u16,
                        .codepoint = cp,
                    })) |entry| {
                        step_w = entry.advance;
                        hit = true;
                    }
                }
                if (!hit) {
                    if (!font_size_set) {
                        if (font.getFontSize() != target_size) {
                            _ = font.setFontSize(target_size);
                        }
                        font_size_set = true;
                    }
                    if (font.getGlyphMetrics(cp)) |m| {
                        step_w = @floatFromInt(m.advance);
                    }
                }
            }

            if (total_w + step_w > max_w) break;
            total_w += step_w;
            byte_idx = next_idx;
        }
        return .{
            .len = byte_idx,
            .w = total_w,
        };
    }
};

test "ShelfPacker packs shelves, wraps rows, and detects overflow" {
    var packer = ShelfPacker{};
    try std.testing.expectEqual(@as(u32, 0), packer.cur_x);
    try std.testing.expectEqual(white_block_size, packer.cur_y);

    // First glyph on initial shelf
    const p1 = packer.allocate(16, 20).?;
    try std.testing.expectEqual(@as(u32, 0), p1.x);
    try std.testing.expectEqual(white_block_size, p1.y);
    try std.testing.expectEqual(@as(u32, 16), packer.cur_x);
    try std.testing.expectEqual(@as(u32, 20), packer.shelf_h);

    // Second taller glyph on same shelf
    const p2 = packer.allocate(24, 28).?;
    try std.testing.expectEqual(@as(u32, 16), p2.x);
    try std.testing.expectEqual(white_block_size, p2.y);
    try std.testing.expectEqual(@as(u32, 40), packer.cur_x);
    try std.testing.expectEqual(@as(u32, 28), packer.shelf_h);

    // Wide allocation that exceeds remaining width wraps to next shelf
    const p3 = packer.allocate(1000, 30).?;
    try std.testing.expectEqual(@as(u32, 0), p3.x);
    try std.testing.expectEqual(white_block_size + 28, p3.y);
    try std.testing.expectEqual(@as(u32, 1000), packer.cur_x);
    try std.testing.expectEqual(@as(u32, 30), packer.shelf_h);

    // Allocation taller than remaining vertical space returns null
    try std.testing.expect(packer.allocate(32, atlas_size) == null);

    // Reset restores initial shelf position
    packer.reset();
    try std.testing.expectEqual(@as(u32, 0), packer.cur_x);
    try std.testing.expectEqual(white_block_size, packer.cur_y);
    try std.testing.expectEqual(@as(u32, 0), packer.shelf_h);
}

test "TextCache.putGlyph populates ASCII page and non-ASCII map" {
    const allocator = std.testing.allocator;
    var cache: TextCache = .{};
    defer cache.deinit(allocator, null);

    try std.testing.expect(!cache.hasResources());

    const ascii_key = GlyphCacheKey{
        .font_id = 0,
        .font_size = 14,
        .codepoint = 'A',
    };
    try cache.putGlyph(allocator, ascii_key, .{
        .u1 = 0.01,
        .v1 = 0.01,
        .u2 = 0.02,
        .v2 = 0.03,
        .w = 10.0,
        .h = 18.0,
        .offset_x = 0.0,
        .advance = 11.0,
        .has_pixels = true,
    });
    try std.testing.expect(cache.hasResources());
    try std.testing.expectEqual(@as(usize, 1), cache.page_count);
    const found = cache.getGlyph(ascii_key).?;
    try std.testing.expectEqual(@as(f32, 11.0), found.advance);
    try std.testing.expect(found.has_pixels);
    try std.testing.expect(found.cached);

    // Non-ASCII codepoint falls back to hash map
    const unicode_key = GlyphCacheKey{
        .font_id = 0,
        .font_size = 14,
        .codepoint = 0x2026,
    };
    try cache.putGlyph(allocator, unicode_key, .{
        .advance = 14.0,
        .has_pixels = true,
    });
    try std.testing.expectEqual(
        @as(f32, 14.0),
        cache.getGlyph(unicode_key).?.advance,
    );

    _ = cache.packer.allocate(32, 32);
    try std.testing.expectEqual(@as(usize, 1), cache.countCachedAsciiGlyphs());
    try std.testing.expectEqual(white_block_size + 32, cache.usedHeight());
    cache.resetAtlas();
    try std.testing.expect(cache.getGlyph(ascii_key) == null);
    try std.testing.expect(cache.getGlyph(unicode_key) == null);
    try std.testing.expectEqual(@as(usize, 0), cache.page_count);
    try std.testing.expectEqual(@as(u32, 0), cache.packer.cur_x);
    try std.testing.expectEqual(white_block_size, cache.packer.cur_y);
}

test "FontMeasurer.empty returns zero dimensions and null prefixes" {
    const measurer = FontMeasurer.empty;
    try std.testing.expect(!measurer.hasPrimaryFont());
    const dims = measurer.measure(0, 16.0, "hello");
    try std.testing.expectEqual(@as(f32, 0.0), dims.w);
    try std.testing.expectEqual(@as(f32, 0.0), dims.h);
    const prefix = measurer.measurePrefix(0, 16.0, "hello", 100.0);
    try std.testing.expect(prefix == null);
}
