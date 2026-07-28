const std = @import("std");
const sdl = @import("sdl");

pub const TextCacheKey = struct {
    font_id: usize,
    font_size: u16,
    color: u32,
    hash: u64,
};

pub const TextCacheValue = struct {
    texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    last_used_frame: usize,
};

pub const TextCache = struct {
    map: std.AutoHashMapUnmanaged(TextCacheKey, TextCacheValue) = .empty,

    pub fn deinit(self: *TextCache, allocator: std.mem.Allocator, dev_opt: ?sdl.gpu.Device) void {
        if (dev_opt) |dev| {
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                dev.releaseTexture(entry.value_ptr.texture);
            }
        }
        self.map.deinit(allocator);
    }

    pub fn getEntry(self: *TextCache, key: TextCacheKey) ?std.AutoHashMapUnmanaged(TextCacheKey, TextCacheValue).Entry {
        return self.map.getEntry(key);
    }

    pub fn put(self: *TextCache, allocator: std.mem.Allocator, key: TextCacheKey, value: TextCacheValue) !void {
        try self.map.put(allocator, key, value);
    }

    pub fn evictUnused(self: *TextCache, allocator: std.mem.Allocator, dev: sdl.gpu.Device, current_frame: usize, max_unused_frames: usize) void {
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

    pub fn clearAll(self: *TextCache, allocator: std.mem.Allocator, dev_opt: ?sdl.gpu.Device) void {
        if (dev_opt) |dev| {
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                dev.releaseTexture(entry.value_ptr.texture);
            }
        }
        self.map.clearAndFree(allocator);
    }
};
