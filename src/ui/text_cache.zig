//! GPU Text Texture Atlas Cache
//!
//! Provides a single shared 1024x1024 RGBA texture atlas and row/shelf slot allocation
//! for rendered text snippets to maximize GPU batching and eliminate per-label texture overhead.

const std = @import("std");
const sdl = @import("sdl");

pub const ATLAS_SIZE: u32 = 1024;
pub const WHITE_U: f32 = 1.0 / @as(f32, @floatFromInt(ATLAS_SIZE));
pub const WHITE_V: f32 = 1.0 / @as(f32, @floatFromInt(ATLAS_SIZE));

/// Lookup key for cached text entries within the texture atlas.
pub const TextCacheKey = struct {
    font_id: usize,
    font_size: u16,
    color: u32,
    hash: u64,
};

/// UV coordinates and metrics of text uploaded to the shared atlas texture.
pub const TextCacheValue = struct {
    u_min: f32,
    v_min: f32,
    u_max: f32,
    v_max: f32,
    w: f32,
    h: f32,
};

/// Sub-texture atlas manager using dynamic row/shelf packing.
pub const TextCache = struct {
    map: std.AutoHashMapUnmanaged(TextCacheKey, TextCacheValue) = .empty,
    row_x: u32 = 4,
    row_y: u32 = 0,
    row_h: u32 = 4,
    needs_reset: bool = false,

    pub fn deinit(self: *TextCache, allocator: std.mem.Allocator, dev_opt: ?sdl.gpu.Device) void {
        _ = dev_opt;
        self.map.deinit(allocator);
    }

    pub fn get(self: *const TextCache, key: TextCacheKey) ?TextCacheValue {
        return self.map.get(key);
    }

    pub fn resetAtlas(self: *TextCache) void {
        self.map.clearRetainingCapacity();
        self.row_x = 4;
        self.row_y = 0;
        self.row_h = 4;
        self.needs_reset = false;
    }

    pub fn allocateSlot(self: *TextCache, surf_w: u32, surf_h: u32) ?struct { x: u32, y: u32 } {
        const slot_w = surf_w + 1;
        const slot_h = surf_h + 1;

        if (slot_w > ATLAS_SIZE or slot_h > ATLAS_SIZE) return null;

        if (self.row_x + slot_w > ATLAS_SIZE) {
            self.row_y += self.row_h;
            self.row_x = 0;
            self.row_h = 0;
        }

        if (self.row_y + slot_h > ATLAS_SIZE) {
            self.needs_reset = true;
            return null;
        }

        const alloc_x = self.row_x;
        const alloc_y = self.row_y;

        self.row_x += slot_w;
        self.row_h = @max(self.row_h, slot_h);

        return .{ .x = alloc_x, .y = alloc_y };
    }

    pub fn put(self: *TextCache, allocator: std.mem.Allocator, key: TextCacheKey, val: TextCacheValue) !void {
        try self.map.put(allocator, key, val);
    }

    pub fn getAtlasSize(self: *const TextCache) u32 {
        _ = self;
        return ATLAS_SIZE;
    }

    pub fn getTextCount(self: *const TextCache) usize {
        return self.map.count();
    }

    pub fn getAtlasUsagePct(self: *const TextCache) f32 {
        const total_pixels: f32 = @floatFromInt(ATLAS_SIZE * ATLAS_SIZE);
        const used_pixels: f32 = @floatFromInt(self.row_y * ATLAS_SIZE + self.row_x * self.row_h);
        return (used_pixels / total_pixels) * 100.0;
    }

    pub fn clearAll(self: *TextCache, allocator: std.mem.Allocator, dev_opt: ?sdl.gpu.Device) void {
        _ = dev_opt;
        _ = allocator;
        self.resetAtlas();
    }
};
