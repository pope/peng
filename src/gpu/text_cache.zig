//! GPU Text Texture Cache
//!
//! Provides hash-based caching and LRU eviction for rendered text textures
//! to avoid re-rendering static UI labels every frame.

const sdl = @import("sdl");
const state = @import("state");
const std = @import("std");

const LogicalDims = state.LogicalDims;

/// Measured byte length and pixel width of a prefix fitting within a max width.
pub const MeasuredPrefix = struct {
    len: usize,
    w: f32,
};

/// Encapsulates loaded font slots for text width and prefix measurement
/// without exposing underlying SDL_ttf font handles to UI callers.
pub const FontMeasurer = struct {
    fonts: []const ?sdl.Font = &.{},

    /// Default empty font measurer for headless tests without loaded TTFs.
    pub const empty: FontMeasurer = .{};

    /// Returns true if the primary UI font (`fonts[0]`) is loaded and non-null.
    pub inline fn hasPrimaryFont(self: FontMeasurer) bool {
        return self.fonts.len > 0 and self.fonts[0] != null;
    }

    /// Measures the pixel width and height of `text` using `fonts[font_id]`
    /// scaled to `target_size`. Returns zero dimensions when the font is null
    /// or `text` is empty.
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
        if (font.getFontSize() != target_size) {
            _ = font.setFontSize(target_size);
        }
        const size = font.getStringSize(text) orelse
            return .{ .w = 0, .h = 0 };
        return .{
            .w = @floatFromInt(size.w),
            .h = @floatFromInt(size.h),
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
        if (font.getFontSize() != target_size) {
            _ = font.setFontSize(target_size);
        }
        const m = font.measureString(text, @intFromFloat(max_w)) orelse
            return null;
        return .{
            .len = m.measured_len,
            .w = @floatFromInt(m.measured_w),
        };
    }
};

/// Lookup key for cached text GPU textures.
pub const TextCacheKey = struct {
    font_id: usize,
    font_size: u16,
    // RGB color packed as 0x00RRGGBB (alpha is modulated dynamically via GPU
    // vertex color)
    color: u32,
    hash: u64,
};

/// Cached text GPU texture entry with dimensions and frame last-used timestamp.
pub const TextCacheValue = struct {
    texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    last_used_frame: usize,
};

/// Text GPU texture cache with LRU eviction.
pub const TextCache = struct {
    map: std.AutoHashMapUnmanaged(TextCacheKey, TextCacheValue) = .empty,

    /// Releases all cached glyph GPU textures and frees hash map allocations.
    pub fn deinit(
        self: *TextCache,
        allocator: std.mem.Allocator,
        dev_opt: ?sdl.gpu.Device,
    ) void {
        if (dev_opt) |dev| {
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                dev.releaseTexture(entry.value_ptr.texture);
            }
        }
        self.map.deinit(allocator);
    }

    /// Looks up a cached text texture entry matching `key`.
    pub fn getEntry(
        self: *TextCache,
        key: TextCacheKey,
    ) ?std.AutoHashMapUnmanaged(TextCacheKey, TextCacheValue).Entry {
        return self.map.getEntry(key);
    }

    /// Stores a new rendered text texture and dimension record in the cache,
    /// releasing any displaced GPU texture if `key` was already present.
    pub fn put(
        self: *TextCache,
        allocator: std.mem.Allocator,
        dev_opt: ?sdl.gpu.Device,
        key: TextCacheKey,
        value: TextCacheValue,
    ) !void {
        if (try self.map.fetchPut(allocator, key, value)) |prev| {
            if (!prev.value.texture.eql(value.texture)) {
                if (dev_opt) |dev| {
                    dev.releaseTexture(prev.value.texture);
                }
            }
        }
    }

    /// Evicts and destroys cached text textures not referenced within
    /// `max_unused_frames`.
    pub fn evictUnused(
        self: *TextCache,
        allocator: std.mem.Allocator,
        dev: sdl.gpu.Device,
        current_frame: usize,
        max_unused_frames: usize,
    ) void {
        var to_evict: std.ArrayList(TextCacheKey) = .empty;
        defer to_evict.deinit(allocator);

        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            if (current_frame > entry.value_ptr.last_used_frame) {
                const unused = current_frame - entry.value_ptr.last_used_frame;
                if (unused > max_unused_frames) {
                    to_evict.append(allocator, entry.key_ptr.*) catch |err| {
                        std.log.err(
                            "Failed to append key to eviction list: {}",
                            .{err},
                        );
                    };
                }
            }
        }

        for (to_evict.items) |k| {
            if (self.map.fetchRemove(k)) |removed| {
                dev.releaseTexture(removed.value.texture);
            }
        }
    }
};

test "TextCache.put replaces existing entry for identical key in-place" {
    const allocator = std.testing.allocator;
    var cache: TextCache = .{};
    defer cache.deinit(allocator, null);

    const key = TextCacheKey{
        .font_id = 0,
        .font_size = 14,
        .color = 0x00FFFFFF,
        .hash = 0xDEADBEEF,
    };
    const tex1: sdl.gpu.Texture = .{ .ptr = @ptrFromInt(0x1000) };
    const tex2: sdl.gpu.Texture = .{ .ptr = @ptrFromInt(0x2000) };

    try cache.put(allocator, null, key, .{
        .texture = tex1,
        .w = 40.0,
        .h = 16.0,
        .last_used_frame = 1,
    });
    try std.testing.expectEqual(@as(usize, 1), cache.map.count());
    try std.testing.expect(cache.getEntry(key).?.value_ptr.texture.eql(tex1));

    // Overwriting same key updates value in-place
    try cache.put(allocator, null, key, .{
        .texture = tex2,
        .w = 48.0,
        .h = 18.0,
        .last_used_frame = 2,
    });
    try std.testing.expectEqual(@as(usize, 1), cache.map.count());
    const entry = cache.getEntry(key).?;
    try std.testing.expect(entry.value_ptr.texture.eql(tex2));
    try std.testing.expectEqual(@as(f32, 48.0), entry.value_ptr.w);
    try std.testing.expectEqual(@as(usize, 2), entry.value_ptr.last_used_frame);
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
