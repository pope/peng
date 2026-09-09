//! GPU Text Texture Cache
//!
//! Provides hash-based caching and LRU eviction for rendered text textures
//! to avoid re-rendering static UI labels every frame.

const std = @import("std");
const sdl = @import("sdl");

/// Lookup key for cached text GPU textures.
pub const TextCacheKey = struct {
    font_id: usize,
    font_size: u16,
    // RGB color packed as 0x00RRGGBB (alpha is modulated dynamically via GPU vertex color)
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
    pub fn deinit(self: *TextCache, allocator: std.mem.Allocator, dev_opt: ?sdl.gpu.Device) void {
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

    /// Stores a new rendered text texture and dimension record in the cache.
    pub fn put(
        self: *TextCache,
        allocator: std.mem.Allocator,
        key: TextCacheKey,
        value: TextCacheValue,
    ) !void {
        try self.map.put(allocator, key, value);
    }

    /// Evicts and destroys cached text textures not referenced within `max_unused_frames`.
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
            if (current_frame > entry.value_ptr.last_used_frame and
                current_frame - entry.value_ptr.last_used_frame > max_unused_frames)
            {
                to_evict.append(allocator, entry.key_ptr.*) catch |err| {
                    std.log.err("Failed to append key to eviction list: {}", .{err});
                };
            }
        }

        for (to_evict.items) |k| {
            if (self.map.fetchRemove(k)) |removed| {
                dev.releaseTexture(removed.value.texture);
            }
        }
    }
};
