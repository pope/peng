const core_fs = @import("fs.zig");
const exif = @import("exif.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const CacheEntry = state_pkg.CacheEntry;
const CacheStatus = state_pkg.CacheStatus;
const CpuSurfaceComponent = state_pkg.CpuSurfaceComponent;
const GpuTextureComponent = state_pkg.GpuTextureComponent;
const JpegDimensions = exif.JpegDimensions;
pub const MediaEntry = state_pkg.MediaEntry;
pub const Orientation = state_pkg.Orientation;
const parseExifDimensions = exif.parseExifDimensions;
const parseExifOrientation = exif.parseExifOrientation;
const RawMetadata = state_pkg.RawMetadata;
const ThumbComponent = state_pkg.ThumbComponent;

/// Unique lookup key identifying a cached image slot by its playlist index and cache generation epoch.
pub const CacheKey = struct {
    index: usize,
    generation: usize,
};

/// Type alias identifying a GPU texture cached slot by its CacheKey.
pub const TextureHandle = CacheKey;

/// Cache slot structure binding a CacheKey to its active CacheEntry state.
pub const CacheSlot = struct {
    key: CacheKey,
    entry: CacheEntry,
};

/// Structure-of-Arrays (SoA) collection managing cached image slots, generation epochs, and VRAM memory budgeting.
pub const CacheSlotMap = struct {
    slots: std.MultiArrayList(CacheSlot) = .{},
    generation: std.atomic.Value(usize) = .init(0),

    /// Atomically increments the cache generation epoch to invalidate in-flight asynchronous decode tasks.
    pub fn advanceGeneration(self: *CacheSlotMap) usize {
        return self.generation.fetchAdd(1, .release) +% 1;
    }

    /// Returns the current atomic generation epoch.
    pub fn getGeneration(self: *const CacheSlotMap) usize {
        return self.generation.load(.acquire);
    }

    /// Generates a `CacheKey` combining the specified media index and current generation epoch.
    pub fn activeKey(self: *const CacheSlotMap, index: usize) CacheKey {
        return .{ .index = index, .generation = self.generation.load(.acquire) };
    }

    /// Returns the count of allocated cache slots.
    pub fn count(self: *const CacheSlotMap) usize {
        return self.slots.len;
    }

    /// Deinitializes all cached GPU textures and releases the multi-array storage memory.
    pub fn deinit(self: *CacheSlotMap, allocator: std.mem.Allocator, gpu_device: ?sdl.gpu.Device) void {
        const entries = self.slots.items(.entry);
        for (entries) |*entry| {
            entry.deinit(gpu_device);
        }
        self.slots.deinit(allocator);
    }

    /// Deinitializes all slot resources and clears the map while retaining capacity.
    pub fn clear(self: *CacheSlotMap, gpu_device: ?sdl.gpu.Device) void {
        const entries = self.slots.items(.entry);
        for (entries) |*entry| {
            entry.deinit(gpu_device);
        }
        self.slots.clearRetainingCapacity();
    }

    /// Clears all slots without releasing underlying capacity.
    pub fn clearRetainingCapacity(self: *CacheSlotMap) void {
        self.slots.clearRetainingCapacity();
    }

    /// Finds the dense array index of the slot matching `key`, or null if not found.
    pub fn getIndex(self: *const CacheSlotMap, key: CacheKey) ?usize {
        const keys = self.slots.items(.key);
        for (keys, 0..) |k, i| {
            if (k.index == key.index and k.generation == key.generation) return i;
        }
        return null;
    }

    /// Returns a pointer to the `CacheEntry` corresponding to `key`, or null if not present.
    pub fn get(self: *CacheSlotMap, key: CacheKey) ?*CacheEntry {
        if (self.getIndex(key)) |i| return &self.slots.items(.entry)[i];
        return null;
    }

    /// Returns the GPU texture handle if the entry at `key` is in `.loaded_gpu` state, or null.
    pub fn getTexture(self: *CacheSlotMap, key: CacheKey) ?sdl.gpu.Texture {
        if (self.get(key)) |entry| {
            switch (entry.status) {
                .loaded_gpu => |gpu| return gpu.gpu_texture,
                else => {},
            }
        }
        return null;
    }

    /// Updates the cache status for the slot matching `key`. Returns true if the key was found.
    pub fn updateStatus(self: *CacheSlotMap, key: CacheKey, status: CacheStatus) bool {
        if (self.get(key)) |entry| {
            entry.status = status;
            return true;
        }
        return false;
    }

    /// Appends a new slot for media `index` at current generation, returning its unique `CacheKey`.
    pub fn appendSlot(self: *CacheSlotMap, allocator: std.mem.Allocator, index: usize, status: CacheStatus) !CacheKey {
        const key = CacheKey{ .index = index, .generation = self.generation.load(.acquire) };
        try self.slots.append(allocator, .{ .key = key, .entry = .{ .status = status } });
        return key;
    }

    /// Appends an explicit key-entry pair into the slot map.
    pub fn appendWithKey(self: *CacheSlotMap, allocator: std.mem.Allocator, key: CacheKey, entry: CacheEntry) !void {
        try self.slots.append(allocator, .{ .key = key, .entry = entry });
    }

    /// Removes a slot at `index_in_list` via swap-remove and releases its GPU texture.
    pub fn removeAndDeinit(self: *CacheSlotMap, index_in_list: usize, gpu_device: ?sdl.gpu.Device) void {
        var entry = self.slots.items(.entry)[index_in_list];
        self.slots.swapRemove(index_in_list);
        entry.deinit(gpu_device);
    }

    pub const DEFAULT_MAX_VRAM_BYTES: usize = 1024 * 1024 * 1024;

    /// Computes the total VRAM consumption in bytes across all `.loaded_gpu` textures in the cache.
    pub fn getTotalVramBytes(self: *const CacheSlotMap) usize {
        var total: usize = 0;
        const entries = self.slots.items(.entry);
        for (entries) |entry| {
            switch (entry.status) {
                .loaded_gpu => |gpu| total += gpu.memory_size_bytes,
                else => {},
            }
        }
        return total;
    }

    /// Enforces the maximum VRAM budget by evicting `.loaded_gpu` textures from the cache map.
    ///
    /// Eviction ordering uses circular distance relative to `current_index`:
    /// 1. Distant entries (circular distance > 2) are evicted first, furthest distance first.
    /// 2. If VRAM budget is still exceeded and only immediate neighbors (distance <= 2) remain,
    ///    they are evicted furthest first (distance 2 before distance 1).
    /// The currently active image (`key.index == current_index`) is strictly protected from eviction.
    pub fn enforceVramBudget(
        self: *CacheSlotMap,
        gpu_device: ?sdl.gpu.Device,
        current_index: ?usize,
        total_items: usize,
        max_bytes: usize,
    ) void {
        while (self.getTotalVramBytes() > max_bytes) {
            const entries = self.slots.items(.entry);
            const keys = self.slots.items(.key);

            var max_distant_dist: usize = 0;
            var distant_victim: ?usize = null;

            var max_neighbor_dist: usize = 0;
            var neighbor_victim: ?usize = null;

            for (entries, keys, 0..) |entry, key, i| {
                if (entry.status == .loaded_gpu) {
                    if (current_index) |cur| {
                        if (key.index == cur) continue;
                        const linear_dist = if (key.index > cur) key.index - cur else cur - key.index;
                        const dist = if (total_items > 0 and linear_dist <= total_items) @min(linear_dist, total_items - linear_dist) else linear_dist;

                        if (dist > 2) {
                            if (distant_victim == null or dist > max_distant_dist) {
                                max_distant_dist = dist;
                                distant_victim = i;
                            }
                        } else {
                            if (neighbor_victim == null or dist > max_neighbor_dist) {
                                max_neighbor_dist = dist;
                                neighbor_victim = i;
                            }
                        }
                    } else {
                        distant_victim = i;
                        break;
                    }
                }
            }

            const victim_idx = distant_victim orelse neighbor_victim;
            if (victim_idx) |v_i| {
                self.removeAndDeinit(v_i, gpu_device);
            } else {
                break;
            }
        }
    }

    /// Checks whether any of the desired 5 prefetch slots (current, ±1, ±2 circularly)
    /// are missing from the cache or not in a terminal/ready status.
    ///
    /// A slot is considered unready if it is missing, decoding, uploading, or loaded on CPU
    /// when a GPU device is present.
    pub fn hasUnreadyPrefetchSlots(
        self: *const CacheSlotMap,
        current_index: usize,
        total_items: usize,
        has_gpu: bool,
    ) bool {
        if (total_items == 0) return false;
        const len = total_items;
        const idx = current_index;

        var desired: [5]usize = undefined;
        desired[0] = idx;
        var desired_count: usize = 1;

        for ([_]usize{
            (idx + 1) % len,
            (idx + 2) % len,
            (idx + len - 1) % len,
            if (len >= 2) (idx + len - 2) % len else idx,
        }) |d| {
            var unique = true;
            for (desired[0..desired_count]) |existing| {
                if (existing == d) {
                    unique = false;
                    break;
                }
            }
            if (unique) {
                desired[desired_count] = d;
                desired_count += 1;
            }
        }

        for (desired[0..desired_count]) |d| {
            const key = self.activeKey(d);
            if (self.getIndex(key)) |i| {
                const entry = self.slots.items(.entry)[i];
                switch (entry.status) {
                    .loaded_gpu, .failed => {},
                    .loaded_cpu => {
                        if (has_gpu) return true;
                    },
                    .decoding, .uploading => return true,
                }
            } else {
                return true;
            }
        }
        return false;
    }
};

/// Identifies image MIME container type using magic bytes from the header buffer,
/// falling back to file extension matching if magic bytes are ambiguous or header is too short.
pub fn detectMimeType(header: []const u8, path: []const u8) []const u8 {
    if (header.len >= 8 and std.mem.startsWith(u8, header, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) {
        return "image/png";
    }
    if (header.len >= 3 and std.mem.startsWith(u8, header, &[_]u8{ 0xFF, 0xD8, 0xFF })) {
        return "image/jpeg";
    }
    if (header.len >= 6 and (std.mem.startsWith(u8, header, "GIF87a") or std.mem.startsWith(u8, header, "GIF89a"))) {
        return "image/gif";
    }
    if (header.len >= 2 and std.mem.startsWith(u8, header, "BM")) {
        return "image/bmp";
    }
    if (header.len >= 12 and std.mem.startsWith(u8, header, "RIFF") and std.mem.eql(u8, header[8..12], "WEBP")) {
        return "image/webp";
    }
    if (header.len >= 8 and std.mem.startsWith(u8, header, "FUJIFILM")) {
        return "image/x-fuji-raf";
    }
    if (header.len >= 4 and ((header[0] == 0x49 and header[1] == 0x49 and header[2] == 0x2A and header[3] == 0x00) or
        (header[0] == 0x4D and header[1] == 0x4D and header[2] == 0x00 and header[3] == 0x2A)))
    {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".arw")) return "image/x-sony-arw";
        if (std.ascii.eqlIgnoreCase(ext, ".cr2")) return "image/x-canon-cr2";
        if (std.ascii.eqlIgnoreCase(ext, ".nef")) return "image/x-nikon-nef";
        if (std.ascii.eqlIgnoreCase(ext, ".dng")) return "image/x-adobe-dng";
        if (std.ascii.eqlIgnoreCase(ext, ".orf")) return "image/x-olympus-orf";
        if (std.ascii.eqlIgnoreCase(ext, ".rw2")) return "image/x-panasonic-rw2";
        if (std.ascii.eqlIgnoreCase(ext, ".pef")) return "image/x-pentax-pef";
        return "image/tiff";
    }

    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return "image/bmp";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".tga")) return "image/x-tga";
    if (std.ascii.eqlIgnoreCase(ext, ".raf")) return "image/x-fuji-raf";
    if (std.ascii.eqlIgnoreCase(ext, ".arw")) return "image/x-sony-arw";
    if (std.ascii.eqlIgnoreCase(ext, ".cr2")) return "image/x-canon-cr2";
    if (std.ascii.eqlIgnoreCase(ext, ".nef")) return "image/x-nikon-nef";
    if (std.ascii.eqlIgnoreCase(ext, ".dng")) return "image/x-adobe-dng";
    if (std.ascii.eqlIgnoreCase(ext, ".orf")) return "image/x-olympus-orf";
    if (std.ascii.eqlIgnoreCase(ext, ".rw2")) return "image/x-panasonic-rw2";
    if (std.ascii.eqlIgnoreCase(ext, ".pef")) return "image/x-pentax-pef";

    return "unknown";
}

/// Image pixel dimensions (width and height) in pixels.
pub const ImageDimensions = struct {
    w: f32,
    h: f32,
};

/// Parses full image width and height directly from image container headers (JPEG, PNG, GIF, WebP, BMP, TIFF, RAW)
/// in < 0.05ms without performing software decompression.
///
/// Returns null if the header buffer is insufficient or contains an unsupported format variant.
pub fn parseImageDimensions(header: []const u8, mime_type: []const u8) ?ImageDimensions {
    if (std.mem.eql(u8, mime_type, "image/x-fuji-raf") or (header.len >= 8 and std.mem.startsWith(u8, header, "FUJIFILM"))) {
        if (exif.extractFujiRafMetadataLocation(header)) |meta_loc| {
            const end = meta_loc.file_offset + meta_loc.length;
            if (end <= header.len) {
                const off: usize = @intCast(meta_loc.file_offset);
                const len: usize = @intCast(meta_loc.length);
                if (exif.parseFujiRafDimensions(header[off .. off + len])) |d| return .{ .w = d.w, .h = d.h };
            }
        }
        if (exif.extractFujiRafPreviewLocation(header)) |prev_loc| {
            const off: usize = @intCast(prev_loc.file_offset);
            if (off + 32 <= header.len) {
                if (exif.readJpegDimensions(header[off..])) |d| return .{ .w = d.w, .h = d.h };
            }
        }
    } else if (std.mem.startsWith(u8, mime_type, "image/x-") or std.mem.eql(u8, mime_type, "image/tiff") or
        (header.len >= 4 and ((header[0] == 0x49 and header[1] == 0x49 and header[2] == 0x2A and header[3] == 0x00) or
            (header[0] == 0x4D and header[1] == 0x4D and header[2] == 0x00 and header[3] == 0x2A))))
    {
        if (exif.parseExifDimensions(header)) |d| return .{ .w = d.w, .h = d.h };
    } else if (std.mem.eql(u8, mime_type, "image/jpeg") or (header.len >= 3 and std.mem.startsWith(u8, header, &[_]u8{ 0xFF, 0xD8, 0xFF }))) {
        if (exif.readJpegDimensions(header)) |d| return .{ .w = d.w, .h = d.h };
    } else if (std.mem.eql(u8, mime_type, "image/png") or (header.len >= 8 and std.mem.startsWith(u8, header, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }))) {
        if (header.len >= 24 and std.mem.startsWith(u8, header, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }) and std.mem.eql(u8, header[12..16], "IHDR")) {
            const w = std.mem.readInt(u32, header[16..20], .big);
            const h = std.mem.readInt(u32, header[20..24], .big);
            if (w > 0 and h > 0) return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        }
    } else if (std.mem.eql(u8, mime_type, "image/gif") or (header.len >= 6 and (std.mem.startsWith(u8, header, "GIF87a") or std.mem.startsWith(u8, header, "GIF89a")))) {
        if (header.len >= 10 and (std.mem.startsWith(u8, header, "GIF87a") or std.mem.startsWith(u8, header, "GIF89a"))) {
            const w = std.mem.readInt(u16, header[6..8], .little);
            const h = std.mem.readInt(u16, header[8..10], .little);
            if (w > 0 and h > 0) return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        }
    } else if (std.mem.eql(u8, mime_type, "image/webp") or (header.len >= 12 and std.mem.startsWith(u8, header, "RIFF") and std.mem.eql(u8, header[8..12], "WEBP"))) {
        if (header.len >= 25 and std.mem.startsWith(u8, header, "RIFF") and std.mem.eql(u8, header[8..12], "WEBP")) {
            if (std.mem.eql(u8, header[12..16], "VP8X") and header.len >= 30) {
                const w = 1 + (@as(u32, header[24]) | (@as(u32, header[25]) << 8) | (@as(u32, header[26]) << 16));
                const h = 1 + (@as(u32, header[27]) | (@as(u32, header[28]) << 8) | (@as(u32, header[29]) << 16));
                return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
            } else if (std.mem.eql(u8, header[12..16], "VP8L") and header.len >= 25 and header[20] == 0x2F) {
                const b0: u32 = header[21];
                const b1: u32 = header[22];
                const b2: u32 = header[23];
                const b3: u32 = header[24];
                const bits = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
                const w = 1 + (bits & 0x3FFF);
                const h = 1 + ((bits >> 14) & 0x3FFF);
                return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
            } else if (std.mem.eql(u8, header[12..16], "VP8 ") and header.len >= 30) {
                if (header[23] == 0x9D and header[24] == 0x01 and header[25] == 0x2A) {
                    const w = std.mem.readInt(u16, header[26..28], .little) & 0x3FFF;
                    const h = std.mem.readInt(u16, header[28..30], .little) & 0x3FFF;
                    if (w > 0 and h > 0) return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
                }
            }
        }
    } else if (std.mem.eql(u8, mime_type, "image/bmp") or (header.len >= 2 and std.mem.startsWith(u8, header, "BM"))) {
        if (header.len >= 26 and std.mem.startsWith(u8, header, "BM")) {
            const dib_size = std.mem.readInt(u32, header[14..18], .little);
            if (dib_size >= 40 and header.len >= 26) {
                const w = std.mem.readInt(i32, header[18..22], .little);
                const h = std.mem.readInt(i32, header[22..26], .little);
                if (w != std.math.minInt(i32) and h != std.math.minInt(i32)) {
                    const abs_w: u32 = @intCast(if (w < 0) -w else w);
                    const abs_h: u32 = @intCast(if (h < 0) -h else h);
                    if (abs_w > 0 and abs_h > 0) return .{ .w = @floatFromInt(abs_w), .h = @floatFromInt(abs_h) };
                }
            }
        }
    }
    return null;
}

/// Container metadata discovered synchronously by probing file headers on the main thread (< 0.1ms).
pub const ProbedImageMetadata = struct {
    dims: ImageDimensions,
    /// Image orientation metadata.
    orientation: Orientation = .normal,
    raw_metadata: RawMetadata = .none,
    /// True if an embedded preview thumbnail was discovered in container headers.
    has_embedded_thumbnail: bool = false,
};

/// Synchronously probes container headers for image dimensions, EXIF rotation, and embedded thumbnail presence
/// in < 0.1ms before spawning background decode workers, eliminating Frame-1 layout jumps and UI flicker.
pub fn probeMediaMetadata(io: std.Io, media: MediaEntry) ?ProbedImageMetadata {
    switch (media) {
        .filesystem => |f| {
            var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, f.path, .{}) catch |err| {
                std.log.warn("probeMediaMetadata: openFile failed for '{s}': {any}", .{ f.path, err });
                return null;
            };
            defer file.close(io);

            const is_raw_ext = core_fs.isRawFile(f.path);
            var header_buf: [256 * 1024]u8 = undefined;
            const target_read = if (is_raw_ext) header_buf.len else 128 * 1024;
            var slices = [_][]u8{header_buf[0..target_read]};
            const n = file.readPositional(io, &slices, 0) catch |err| {
                std.log.warn("probeMediaMetadata: readPositional failed for '{s}': {any}", .{ f.path, err });
                return null;
            };
            if (n == 0) return null;

            const mime_type = detectMimeType(header_buf[0..n], f.path);
            var dims = parseImageDimensions(header_buf[0..n], mime_type);
            var rot: Orientation = .normal;
            var has_thumb = false;

            if (std.mem.eql(u8, mime_type, "image/x-fuji-raf") or (n >= 8 and std.mem.startsWith(u8, header_buf[0..n], "FUJIFILM"))) {
                // If dimensions not yet found in first 64KB, perform small positional read for metadata block
                if (dims == null) {
                    if (exif.extractFujiRafMetadataLocation(header_buf[0..n])) |meta_loc| {
                        var meta_tmp: [4096]u8 = undefined;
                        const to_read: usize = @min(@as(usize, meta_loc.length), meta_tmp.len);
                        var m_slices = [_][]u8{meta_tmp[0..to_read]};
                        const mn = file.readPositional(io, &m_slices, meta_loc.file_offset) catch 0;
                        if (mn >= 4) {
                            if (exif.parseFujiRafDimensions(meta_tmp[0..mn])) |fd| {
                                dims = .{ .w = fd.w, .h = fd.h };
                            }
                        }
                    }
                }
                // Sourced from embedded preview JPEG's EXIF header and fallback dimensions
                if (exif.extractFujiRafPreviewLocation(header_buf[0..n])) |prev_loc| {
                    has_thumb = true;
                    const off: usize = @intCast(prev_loc.file_offset);
                    if (off + 4096 <= n) {
                        rot = exif.parseExifOrientation(header_buf[off..n]) orelse .normal;
                        if (dims == null) {
                            dims = parseImageDimensions(header_buf[off..n], "image/jpeg");
                        }
                    } else {
                        var p_buf: [8192]u8 = undefined;
                        var p_slices = [_][]u8{&p_buf};
                        const pn = file.readPositional(io, &p_slices, prev_loc.file_offset) catch 0;
                        if (pn > 0) {
                            rot = exif.parseExifOrientation(p_buf[0..pn]) orelse .normal;
                            if (dims == null) {
                                dims = parseImageDimensions(p_buf[0..pn], "image/jpeg");
                            }
                        }
                    }
                }
            } else if (is_raw_ext or std.mem.startsWith(u8, mime_type, "image/x-")) {
                rot = exif.parseExifOrientation(header_buf[0..n]) orelse .normal;
                const raw_cands = exif.extractTiffRawPreviews(header_buf[0..n]);
                if (raw_cands.thumbnail != null) {
                    has_thumb = true;
                }
            } else if (std.mem.eql(u8, mime_type, "image/jpeg")) {
                rot = exif.parseExifOrientation(header_buf[0..n]) orelse .normal;
                if (exif.extractJpegThumbnailLocation(header_buf[0..n])) |_| {
                    has_thumb = true;
                }
            } else {
                rot = exif.parseExifOrientation(header_buf[0..n]) orelse .normal;
            }

            const final_dims = dims orelse return null;
            const is_raw = is_raw_ext or std.mem.startsWith(u8, mime_type, "image/x-");

            return ProbedImageMetadata{
                .dims = final_dims,
                .orientation = rot,
                .raw_metadata = if (is_raw) RawMetadata.init(final_dims.w, final_dims.h) else .none,
                .has_embedded_thumbnail = has_thumb,
            };
        },
        .archive_entry => |a| {
            if (a.compression_method) |cm| {
                if (cm == 0 and a.file_offset != null) {
                    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, a.archive_path, .{}) catch |err| {
                        std.log.warn("probeMediaMetadata: openFile failed for archive '{s}': {any}", .{ a.archive_path, err });
                        return null;
                    };
                    defer file.close(io);

                    var header_buf: [65536]u8 = undefined;
                    var slices = [_][]u8{&header_buf};
                    const n = file.readPositional(io, &slices, a.file_offset.?) catch |err| {
                        std.log.warn("probeMediaMetadata: readPositional failed for archive '{s}': {any}", .{ a.archive_path, err });
                        return null;
                    };
                    if (n == 0) return null;

                    var data_offset: usize = 0;
                    if (n >= @sizeOf(std.zip.LocalFileHeader) and std.mem.eql(u8, header_buf[0..4], &std.zip.local_file_header_sig)) {
                        const filename_len = std.mem.readInt(u16, header_buf[26..28], .little);
                        const extra_len = std.mem.readInt(u16, header_buf[28..30], .little);
                        data_offset = @sizeOf(std.zip.LocalFileHeader) + @as(usize, filename_len) + @as(usize, extra_len);
                    }
                    if (n <= data_offset) return null;

                    const image_slice = header_buf[data_offset..n];
                    const mime_type = detectMimeType(image_slice, a.entry_name);
                    const dims = parseImageDimensions(image_slice, mime_type) orelse return null;
                    const rot = exif.parseExifOrientation(image_slice) orelse .normal;
                    const is_raw = core_fs.isRawFile(a.entry_name) or std.mem.startsWith(u8, mime_type, "image/x-");
                    var has_thumb = false;
                    if (std.mem.eql(u8, mime_type, "image/jpeg")) {
                        if (exif.extractJpegThumbnailLocation(image_slice)) |_| {
                            has_thumb = true;
                        }
                    }
                    return ProbedImageMetadata{
                        .dims = dims,
                        .orientation = rot,
                        .raw_metadata = if (is_raw) RawMetadata.init(dims.w, dims.h) else .none,
                        .has_embedded_thumbnail = has_thumb,
                    };
                }
            }
            return null;
        },
    }
}

/// Extracted thumbnail surface along with orientation, full-resolution dimensions, RAW metadata, and DCT block snapping detection.
pub const ExtractedThumbnail = struct {
    surface: sdl.Surface,
    orientation: Orientation = .normal,
    full_w: f32 = 0.0,
    full_h: f32 = 0.0,
    raw_metadata: RawMetadata = .none,
    dct_snapped: bool = false,
};

/// Inspects the decoded thumbnail CPU surface to detect whether letterbox (or pillarbox) black bars
/// have been padded and snapped to 8-pixel DCT block boundaries by in-camera preview encoders
/// (e.g. Fujifilm RAF, Ricoh GR IIIx JPEG).
/// Requires candidate DCT boundary lines to be black AND active image content to begin at the 8px boundary.
/// If candidate boundary lines contain image data (e.g. Sony ARW, standard JPEGs) OR if the scene itself
/// is an extended solid black background (e.g. astrophotography), returns false to use theoretical aspect-ratio padding.
pub fn detectThumbnailDctPadding(surf: sdl.Surface, full_w: f32, full_h: f32) bool {
    const sw = surf.w();
    const sh = surf.h();
    if (!std.math.isFinite(full_w) or !std.math.isFinite(full_h) or full_w <= 0.0 or full_h <= 0.0 or sw <= 0 or sh <= 0) return false;

    const thumb_w: f32 = @floatFromInt(sw);
    const thumb_h: f32 = @floatFromInt(sh);
    const ar_full = full_w / full_h;
    const ar_thumb = thumb_w / thumb_h;

    // Matching aspect ratio within epsilon -> no letterboxing or pillarboxing
    if (@abs(ar_full - ar_thumb) <= 0.01) return false;

    const threshold: u8 = 16; // Tolerant to lossy JPEG compression ringing / chroma subsampling near boundaries

    if (ar_full > ar_thumb) {
        // Letterboxing: full image is wider than container -> black bars on top and bottom
        const raw_pad_px = (thumb_h - (thumb_w / ar_full)) / 2.0;
        const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;

        if (nearest_block_px > 0.0 and nearest_block_px * 2.0 < thumb_h and @abs(raw_pad_px - nearest_block_px) <= 2.0) {
            const test_row_top: i32 = @intFromFloat(nearest_block_px - 1.0);
            const test_row_bot: i32 = sh - @as(i32, @intFromFloat(nearest_block_px));

            // Candidate DCT padding rows must both be black
            if (surf.isRowBlack(test_row_top, threshold) and surf.isRowBlack(test_row_bot, threshold)) {
                // Verify that active image content begins at the DCT block boundary (step-transition).
                // If both row 8 and row 111 are ALSO black, the photo has an extended black background;
                // treating continuous black backgrounds as theoretical padding prevents false-positive distortion.
                const first_image_row_top: i32 = @intFromFloat(nearest_block_px);
                const last_image_row_bot: i32 = sh - @as(i32, @intFromFloat(nearest_block_px)) - 1;

                if (!surf.isRowBlack(first_image_row_top, threshold) or !surf.isRowBlack(last_image_row_bot, threshold)) {
                    return true;
                }
            }
        }
    } else {
        // Pillarboxing: full image is taller than container -> black bars on left and right
        const raw_pad_px = (thumb_w - (thumb_h * ar_full)) / 2.0;
        const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;

        if (nearest_block_px > 0.0 and nearest_block_px * 2.0 < thumb_w and @abs(raw_pad_px - nearest_block_px) <= 2.0) {
            const test_col_left: i32 = @intFromFloat(nearest_block_px - 1.0);
            const test_col_right: i32 = sw - @as(i32, @intFromFloat(nearest_block_px));

            if (surf.isColBlack(test_col_left, threshold) and surf.isColBlack(test_col_right, threshold)) {
                const first_image_col_left: i32 = @intFromFloat(nearest_block_px);
                const last_image_col_right: i32 = sw - @as(i32, @intFromFloat(nearest_block_px)) - 1;

                if (!surf.isColBlack(first_image_col_left, threshold) or !surf.isColBlack(last_image_col_right, threshold)) {
                    return true;
                }
            }
        }
    }

    return false;
}

fn loadThumbnailFromLocation(
    io: std.Io,
    alloc: std.mem.Allocator,
    file: *std.Io.File,
    file_size: u64,
    header_slice: []const u8,
    loc: exif.ThumbnailLocation,
) ?sdl.Surface {
    const max_thumb_size_bytes = 512 * 1024;
    if (loc.length == 0 or loc.length > max_thumb_size_bytes or loc.length > file_size or loc.file_offset > file_size - loc.length) {
        return null;
    }
    const t_off: usize = @intCast(loc.file_offset);
    const t_len: usize = @intCast(loc.length);
    if (t_off + t_len <= header_slice.len) {
        return sdl.Surface.loadConstMemOpt(header_slice[t_off .. t_off + t_len]);
    }
    const t_buf = alloc.alloc(u8, t_len) catch return null;
    defer alloc.free(t_buf);
    var ts_slices = [_][]u8{t_buf};
    const tn = file.readPositional(io, &ts_slices, loc.file_offset) catch return null;
    if (tn == t_len) {
        return sdl.Surface.loadConstMemOpt(t_buf);
    }
    return null;
}

/// Extracts the embedded preview thumbnail surface and orientation metadata for a media entry.
/// Supports Camera RAW formats (.arw, .raf, .cr2, .nef, .dng, .orf, .rw2, .pef), standard JPEGs, and CBZ entries.
pub fn loadThumbnailSurface(io: std.Io, alloc: std.mem.Allocator, media: MediaEntry) ?ExtractedThumbnail {
    switch (media) {
        .filesystem => |f| {
            var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, f.path, .{}) catch |err| {
                std.log.warn("loadThumbnailSurface: openFile failed for '{s}': {any}", .{ f.path, err });
                return null;
            };
            defer file.close(io);

            const file_size = file.length(io) catch 0;
            const is_raw_ext = core_fs.isRawFile(f.path);
            var header_buf: [256 * 1024]u8 = undefined;
            const target_read = if (is_raw_ext) header_buf.len else 128 * 1024;
            var slices = [_][]u8{header_buf[0..target_read]};
            const header_n = file.readPositional(io, &slices, 0) catch |err| {
                std.log.warn("loadThumbnailSurface: readPositional failed for '{s}': {any}", .{ f.path, err });
                return null;
            };
            if (header_n == 0) return null;
            const header_slice = header_buf[0..header_n];

            const mime_type = detectMimeType(header_slice, f.path);
            const is_raw = core_fs.isRawFile(f.path) or std.mem.startsWith(u8, mime_type, "image/x-");
            const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or (header_n >= 8 and std.mem.startsWith(u8, header_slice, "FUJIFILM"));

            var thumb_surf: ?sdl.Surface = null;
            var orientation: Orientation = .normal;
            var raw_w: f32 = 0.0;
            var raw_h: f32 = 0.0;

            if (is_fuji) {
                const prev_loc_opt = exif.extractFujiRafPreviewLocation(header_slice);
                if (exif.extractFujiRafMetadataLocation(header_slice)) |meta_loc| {
                    if (meta_loc.length <= header_n and meta_loc.file_offset <= header_n - meta_loc.length) {
                        const end = meta_loc.file_offset + meta_loc.length;
                        if (exif.parseFujiRafDimensions(header_slice[@intCast(meta_loc.file_offset)..@intCast(end)])) |fd| {
                            raw_w = fd.w;
                            raw_h = fd.h;
                        }
                    } else if (meta_loc.length > 0 and meta_loc.length <= 64 * 1024 and meta_loc.length <= file_size and meta_loc.file_offset <= file_size - meta_loc.length) {
                        var m_buf: [64 * 1024]u8 = undefined;
                        var m_slices = [_][]u8{m_buf[0..meta_loc.length]};
                        const mn = file.readPositional(io, &m_slices, meta_loc.file_offset) catch 0;
                        if (mn >= meta_loc.length) {
                            if (exif.parseFujiRafDimensions(m_buf[0..meta_loc.length])) |fd| {
                                raw_w = fd.w;
                                raw_h = fd.h;
                            }
                        }
                    }
                }

                var thumb_loc_opt: ?exif.ThumbnailLocation = null;
                if (prev_loc_opt) |prev_loc| {
                    const off: usize = @intCast(prev_loc.file_offset);
                    if (off + 4096 <= header_n) {
                        orientation = exif.parseExifOrientation(header_slice[off..header_n]) orelse .normal;
                        if (exif.extractJpegThumbnailLocation(header_slice[off..header_n])) |j_thumb| {
                            thumb_loc_opt = .{
                                .file_offset = prev_loc.file_offset + j_thumb.file_offset,
                                .length = j_thumb.length,
                            };
                        }
                    } else {
                        var p_hdr: [8192]u8 = undefined;
                        var p_slices = [_][]u8{&p_hdr};
                        const pn = file.readPositional(io, &p_slices, prev_loc.file_offset) catch 0;
                        if (pn > 0) {
                            orientation = exif.parseExifOrientation(p_hdr[0..pn]) orelse .normal;
                            if (exif.extractJpegThumbnailLocation(p_hdr[0..pn])) |j_thumb| {
                                thumb_loc_opt = .{
                                    .file_offset = prev_loc.file_offset + j_thumb.file_offset,
                                    .length = j_thumb.length,
                                };
                            }
                        }
                    }
                }

                if (thumb_loc_opt) |tloc| {
                    thumb_surf = loadThumbnailFromLocation(io, alloc, &file, file_size, header_slice, tloc);
                }
            } else if (is_raw) {
                const raw_cands = exif.extractTiffRawPreviews(header_slice);
                if (exif.parseExifDimensions(header_slice)) |dims| {
                    raw_w = dims.w;
                    raw_h = dims.h;
                }
                orientation = exif.parseExifOrientation(header_slice) orelse .normal;
                if (raw_cands.thumbnail) |tloc| {
                    thumb_surf = loadThumbnailFromLocation(io, alloc, &file, file_size, header_slice, tloc);
                }
            } else if (std.mem.eql(u8, mime_type, "image/jpeg")) {
                orientation = exif.parseExifOrientation(header_slice) orelse .normal;
                if (parseImageDimensions(header_slice, mime_type)) |dims| {
                    raw_w = dims.w;
                    raw_h = dims.h;
                }
                if (exif.extractJpegThumbnailLocation(header_slice)) |loc| {
                    thumb_surf = loadThumbnailFromLocation(io, alloc, &file, file_size, header_slice, loc);
                }
            }

            const surf = thumb_surf orelse return null;
            const full_w: f32 = if (raw_w > 0.0) raw_w else @floatFromInt(surf.w());
            const full_h: f32 = if (raw_h > 0.0) raw_h else @floatFromInt(surf.h());
            const dct_snapped = detectThumbnailDctPadding(surf, full_w, full_h);
            return ExtractedThumbnail{
                .surface = surf,
                .orientation = orientation,
                .full_w = full_w,
                .full_h = full_h,
                .raw_metadata = if (is_raw) RawMetadata.init(raw_w, raw_h) else .none,
                .dct_snapped = dct_snapped,
            };
        },
        .archive_entry => |a| {
            if (a.compression_method) |cm| {
                if (cm == 0 and a.file_offset != null) {
                    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, a.archive_path, .{}) catch return null;
                    defer file.close(io);

                    var header_buf: [128 * 1024]u8 = undefined;
                    var slices = [_][]u8{&header_buf};
                    const n = file.readPositional(io, &slices, a.file_offset.?) catch return null;
                    if (n == 0) return null;

                    var data_offset: usize = 0;
                    if (n >= @sizeOf(std.zip.LocalFileHeader) and std.mem.eql(u8, header_buf[0..4], &std.zip.local_file_header_sig)) {
                        const filename_len = std.mem.readInt(u16, header_buf[26..28], .little);
                        const extra_len = std.mem.readInt(u16, header_buf[28..30], .little);
                        data_offset = @sizeOf(std.zip.LocalFileHeader) + @as(usize, filename_len) + @as(usize, extra_len);
                    }
                    if (n <= data_offset) return null;
                    const image_slice = header_buf[data_offset..n];
                    const mime_type = detectMimeType(image_slice, a.entry_name);
                    if (std.mem.eql(u8, mime_type, "image/jpeg")) {
                        const orientation = exif.parseExifOrientation(image_slice) orelse .normal;
                        const dims = parseImageDimensions(image_slice, mime_type);
                        if (exif.extractJpegThumbnailLocation(image_slice)) |loc| {
                            const off: usize = @intCast(loc.file_offset);
                            const len: usize = @intCast(loc.length);
                            if (off + len <= image_slice.len) {
                                if (sdl.Surface.loadConstMemOpt(image_slice[off .. off + len])) |surf| {
                                    const full_w: f32 = if (dims) |d| d.w else @floatFromInt(surf.w());
                                    const full_h: f32 = if (dims) |d| d.h else @floatFromInt(surf.h());
                                    const dct_snapped = detectThumbnailDctPadding(surf, full_w, full_h);
                                    return ExtractedThumbnail{
                                        .surface = surf,
                                        .orientation = orientation,
                                        .full_w = full_w,
                                        .full_h = full_h,
                                        .raw_metadata = .none,
                                        .dct_snapped = dct_snapped,
                                    };
                                }
                            }
                        }
                    }
                }
            }
            return null;
        },
    }
}

/// Reusable GPU staging buffers for texture uploads, eliminating allocation and deallocation
/// churn on every frame by retaining and geometrically growing transfer and storage buffers.
///
/// TODO: Add heuristics to periodically evaluate and shrink retained staging buffers after a duration/inactivity
/// threshold (or high-water decay) so memory is reclaimed if a single exceptionally large image temporarily expanded capacity.
pub const UploadStagingBuffer = struct {
    transfer_buffer: ?sdl.gpu.TransferBuffer = null,
    storage_buffer: ?sdl.gpu.Buffer = null,
    transfer_capacity: usize = 0,
    storage_capacity: usize = 0,

    /// Releases retained GPU transfer and compute storage buffers.
    pub fn deinit(self: *UploadStagingBuffer, dev: sdl.gpu.Device) void {
        if (self.transfer_buffer) |tb| {
            dev.releaseTransferBuffer(tb);
            self.transfer_buffer = null;
        }
        if (self.storage_buffer) |sb| {
            dev.releaseBuffer(sb);
            self.storage_buffer = null;
        }
        self.transfer_capacity = 0;
        self.storage_capacity = 0;
    }

    /// Obtains a transfer buffer with at least `required_size` capacity, reusing the existing buffer
    /// or reallocating with geometric growth when capacity is insufficient.
    fn getOrCreateTransferBuffer(self: *UploadStagingBuffer, dev: sdl.gpu.Device, required_size: usize) ?sdl.gpu.TransferBuffer {
        if (self.transfer_buffer != null and self.transfer_capacity >= required_size) {
            return self.transfer_buffer;
        }
        const next_cap = @max(required_size, if (self.transfer_capacity > 0) self.transfer_capacity * 2 else 4 * 1024 * 1024);
        const aligned_cap = std.mem.alignForward(usize, next_cap, 4096);
        if (self.transfer_buffer) |tb| {
            dev.releaseTransferBuffer(tb);
            self.transfer_buffer = null;
        }
        self.transfer_capacity = 0;

        const tb = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = @intCast(aligned_cap),
            .props = 0,
        }) orelse return null;
        self.transfer_buffer = tb;
        self.transfer_capacity = aligned_cap;
        return tb;
    }

    /// Obtains a compute storage buffer with at least `required_size` capacity, reusing the existing buffer
    /// or reallocating with geometric growth when capacity is insufficient.
    fn getOrCreateStorageBuffer(self: *UploadStagingBuffer, dev: sdl.gpu.Device, required_size: usize) ?sdl.gpu.Buffer {
        if (self.storage_buffer != null and self.storage_capacity >= required_size) {
            return self.storage_buffer;
        }
        const next_cap = @max(required_size, if (self.storage_capacity > 0) self.storage_capacity * 2 else 4 * 1024 * 1024);
        const aligned_cap = std.mem.alignForward(usize, next_cap, 4096);
        if (self.storage_buffer) |sb| {
            dev.releaseBuffer(sb);
            self.storage_buffer = null;
        }
        self.storage_capacity = 0;

        const sb = dev.createBuffer(&sdl.gpu.BufferCreateInfo{
            .usage = sdl.gpu.BufferUsage.compute_storage_read,
            .size = @intCast(aligned_cap),
            .props = 0,
        }) orelse return null;
        self.storage_buffer = sb;
        self.storage_capacity = aligned_cap;
        return sb;
    }
};

/// Result payload containing the created GPU texture, dimensions, upload timing telemetry, and VRAM memory footprint.
pub const GpuUploadResult = struct {
    gpu_texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    upload_time_ms: f64,
    memory_size_bytes: usize,
    num_mip_levels: u32,
    mipmap_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    was_fallback: bool = false,
    fallback_time_ms: f64 = 0.0,
};

/// Uploads a CPU surface into an SDL GPU texture with automatic mipmap pyramid generation,
/// using an optional compute pipeline for fast RGB24/BGR24 unpack and optional staging buffer reuse.
pub fn uploadSurfaceToGpu(
    dev: sdl.gpu.Device,
    surf: sdl.Surface,
    comp_pipeline: ?sdl.gpu.ComputePipeline,
    staging: ?*UploadStagingBuffer,
) ?GpuUploadResult {
    const start_upload = sdl.timer.getTicksNs();
    var current_surf = surf;

    const src_fmt = current_surf.format();
    const gpu_format: sdl.gpu.TextureFormat = switch (src_fmt) {
        sdl.PixelFormat.bgra32, sdl.PixelFormat.xrgb8888, sdl.PixelFormat.bgrx8888 => .bgra8_unorm,
        sdl.PixelFormat.rgba32, sdl.PixelFormat.xbgr8888, sdl.PixelFormat.rgbx8888 => .rgba8_unorm,
        else => .rgba8_unorm,
    };

    var scaled_surf: ?sdl.Surface = null;
    defer if (scaled_surf) |s| s.destroy();

    var img_w = current_surf.w();
    var img_h = current_surf.h();
    var tex: ?sdl.gpu.Texture = null;
    const max_dim_u: u32 = @intCast(@max(img_w, img_h));
    const num_levels: u32 = if (max_dim_u > 1) @intCast(std.math.log2(max_dim_u) + 1) else 1;
    var was_fallback: bool = false;
    var fallback_time_ms: f64 = 0.0;

    const u_w: usize = @intCast(img_w);
    const u_h: usize = @intCast(img_h);
    const cur_fmt = current_surf.format();
    const comp_pipeline_opt: ?sdl.gpu.ComputePipeline = if (cur_fmt == sdl.PixelFormat.rgb24 or cur_fmt == sdl.PixelFormat.bgr24) comp_pipeline else null;

    var tex_usage = sdl.gpu.TextureUsage.sampler | sdl.gpu.TextureUsage.color_target;
    if (comp_pipeline_opt != null) {
        tex_usage |= sdl.gpu.TextureUsage.compute_storage_write;
    }

    var img_tex_info = sdl.gpu.TextureCreateInfo{
        .type = .type_2d,
        .format = gpu_format,
        .usage = tex_usage,
        .width = @intCast(img_w),
        .height = @intCast(img_h),
        .layer_count_or_depth = 1,
        .num_levels = num_levels,
        .sample_count = .count_1,
        .props = 0,
    };
    tex = dev.createTexture(&img_tex_info);

    if (tex == null) {
        const start_fb = sdl.timer.getTicksNs();
        was_fallback = true;
        var try_max_dim: i32 = 8192;
        while (try_max_dim >= 2048) : (try_max_dim = @divTrunc(try_max_dim, 2)) {
            if (img_w > try_max_dim or img_h > try_max_dim) {
                var new_w = img_w;
                var new_h = img_h;
                if (img_w > img_h) {
                    new_w = try_max_dim;
                    new_h = @divTrunc(img_h * try_max_dim, img_w);
                } else {
                    new_h = try_max_dim;
                    new_w = @divTrunc(img_w * try_max_dim, img_h);
                }
                new_w = @max(1, new_w);
                new_h = @max(1, new_h);

                const new_scale = current_surf.scale(new_w, new_h, .linear);
                if (new_scale) |ns| {
                    if (scaled_surf) |s| s.destroy();
                    scaled_surf = ns;
                    current_surf = ns;
                    img_w = new_w;
                    img_h = new_h;

                    const fb_max_dim: u32 = @intCast(@max(img_w, img_h));
                    const fb_levels: u32 = if (fb_max_dim > 1) @intCast(std.math.log2(fb_max_dim) + 1) else 1;
                    img_tex_info.width = @intCast(img_w);
                    img_tex_info.height = @intCast(img_h);
                    img_tex_info.num_levels = fb_levels;
                    tex = dev.createTexture(&img_tex_info);
                    if (tex != null) break;
                } else {
                    std.log.err("uploadSurfaceToGpu: SDL_ScaleSurface fallback failed: {s}", .{sdl.getError()});
                    break;
                }
            }
        }
        const end_fb = sdl.timer.getTicksNs();
        fallback_time_ms = @as(f64, @floatFromInt(end_fb - start_fb)) / 1_000_000.0;
    }

    const gpu_tex = tex orelse return null;

    if (comp_pipeline_opt) |pipeline_handle| {
        const src_pitch: usize = @intCast(current_surf.pitch());
        const pixels: [*]const u8 = current_surf.pixels();
        const raw_bytes_len = src_pitch * u_h;
        const storage_buf_size = std.mem.alignForward(usize, raw_bytes_len, 4);

        const is_staged = (staging != null);
        const transfer_buf = if (staging) |st|
            st.getOrCreateTransferBuffer(dev, raw_bytes_len) orelse {
                dev.releaseTexture(gpu_tex);
                return null;
            }
        else
            dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
                .usage = .upload,
                .size = @intCast(raw_bytes_len),
                .props = 0,
            }) orelse {
                dev.releaseTexture(gpu_tex);
                return null;
            };
        defer if (!is_staged) dev.releaseTransferBuffer(transfer_buf);

        const mapped = dev.mapTransferBuffer(transfer_buf, is_staged) orelse {
            dev.releaseTexture(gpu_tex);
            return null;
        };
        @memcpy(mapped[0..raw_bytes_len], pixels[0..raw_bytes_len]);
        dev.unmapTransferBuffer(transfer_buf);

        const storage_buf = if (staging) |st|
            st.getOrCreateStorageBuffer(dev, storage_buf_size) orelse {
                dev.releaseTexture(gpu_tex);
                return null;
            }
        else
            dev.createBuffer(&sdl.gpu.BufferCreateInfo{
                .usage = sdl.gpu.BufferUsage.compute_storage_read,
                .size = @intCast(storage_buf_size),
                .props = 0,
            }) orelse {
                dev.releaseTexture(gpu_tex);
                return null;
            };
        defer if (!is_staged) dev.releaseBuffer(storage_buf);

        const cmd_wrapper = dev.acquireCommandBuffer() orelse {
            dev.releaseTexture(gpu_tex);
            return null;
        };

        const copy_pass = cmd_wrapper.beginCopyPass() orelse {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        };
        copy_pass.uploadToBuffer(&sdl.gpu.TransferBufferLocation{
            .transfer_buffer = transfer_buf,
            .offset = 0,
        }, &sdl.gpu.BufferRegion{
            .buffer = storage_buf,
            .offset = 0,
            .size = @intCast(raw_bytes_len),
        }, false);
        copy_pass.end();

        const compute_pass = cmd_wrapper.beginComputePass(
            &[_]sdl.gpu.StorageTextureReadWriteBinding{.{ .texture = gpu_tex, .mip_level = 0, .layer = 0, .cycle = false }},
            null,
        ) orelse {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        };

        const Params = extern struct {
            width: u32,
            height: u32,
            is_bgr: u32,
            src_pitch: u32,
        };
        const params = Params{
            .width = @intCast(img_w),
            .height = @intCast(img_h),
            .is_bgr = if (cur_fmt == sdl.PixelFormat.bgr24) 1 else 0,
            .src_pitch = @intCast(src_pitch),
        };
        cmd_wrapper.pushComputeUniform(0, std.mem.asBytes(&params));

        compute_pass.bindPipeline(pipeline_handle);
        compute_pass.bindStorageBuffers(0, &[_]sdl.gpu.Buffer{storage_buf});
        const group_x: u32 = @intCast((u_w + 15) / 16);
        const group_y: u32 = @intCast((u_h + 15) / 16);
        compute_pass.dispatch(group_x, group_y, 1);
        compute_pass.end();

        var mipmap_time_ms: f64 = 0.0;
        if (num_levels > 1) {
            const start_mip = sdl.timer.getTicksNs();
            cmd_wrapper.generateMipmaps(gpu_tex);
            const end_mip = sdl.timer.getTicksNs();
            mipmap_time_ms = @as(f64, @floatFromInt(end_mip - start_mip)) / 1_000_000.0;
        }

        _ = cmd_wrapper.submit();

        const end_upload = sdl.timer.getTicksNs();
        const upload_time_ms = @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;

        var memory_size_bytes: usize = raw_bytes_len;
        if (num_levels > 1) {
            memory_size_bytes = (memory_size_bytes * 4) / 3;
        }

        return .{
            .gpu_texture = gpu_tex,
            .w = @floatFromInt(img_w),
            .h = @floatFromInt(img_h),
            .upload_time_ms = upload_time_ms,
            .memory_size_bytes = memory_size_bytes,
            .num_mip_levels = num_levels,
            .mipmap_time_ms = mipmap_time_ms,
            .conversion_time_ms = 0.0,
            .was_fallback = was_fallback,
            .fallback_time_ms = fallback_time_ms,
        };
    }

    const cmd_wrapper = dev.acquireCommandBuffer() orelse {
        dev.releaseTexture(gpu_tex);
        return null;
    };

    const dst_pitch: usize = u_w * 4;
    const size = dst_pitch * u_h;

    const is_staged = (staging != null);
    const transfer_buf = if (staging) |st|
        st.getOrCreateTransferBuffer(dev, size) orelse {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        }
    else
        dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = @intCast(size),
            .props = 0,
        }) orelse {
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        };
    defer if (!is_staged) dev.releaseTransferBuffer(transfer_buf);

    const mapped = dev.mapTransferBuffer(transfer_buf, is_staged) orelse {
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };

    const src_pixels: [*]const u8 = current_surf.pixels();
    const src_pitch: usize = @intCast(current_surf.pitch());
    var conversion_time_ms: f64 = 0.0;
    const is_32bit_fmt = switch (cur_fmt) {
        sdl.PixelFormat.rgba32, sdl.PixelFormat.bgra32, sdl.PixelFormat.xrgb8888, sdl.PixelFormat.xbgr8888, sdl.PixelFormat.rgbx8888, sdl.PixelFormat.bgrx8888 => true,
        else => false,
    };
    if (is_32bit_fmt) {
        if (src_pitch == dst_pitch) {
            @memcpy(mapped[0..size], src_pixels[0..size]);
        } else {
            var y: usize = 0;
            while (y < u_h) : (y += 1) {
                @memcpy(mapped[y * dst_pitch .. y * dst_pitch + u_w * 4], src_pixels[y * src_pitch .. y * src_pitch + u_w * 4]);
            }
        }
        // TODO: If compute unpack pipeline is unavailable (comp_pipeline == null), RGB24/BGR24 falls back to main-thread SIMD conversion.
        // If running on non-compute GPU hardware becomes a priority, plumbing `has_compute_unpack: bool` through DecodeArgs
        // would allow offloading this conversion to background decode workers as well.
    } else if (cur_fmt == sdl.PixelFormat.rgb24) {
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertRgb24ToRgba32Simd(src_pixels[0 .. src_pitch * u_h], mapped[0..size], u_w, u_h, src_pitch, dst_pitch);
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms = @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
    } else if (cur_fmt == sdl.PixelFormat.bgr24) {
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertBgr24ToRgba32Simd(src_pixels[0 .. src_pitch * u_h], mapped[0..size], u_w, u_h, src_pitch, dst_pitch);
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms = @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
    } else {
        const start_conv = sdl.timer.getTicksNs();
        const tmp_surf = current_surf.convert(sdl.PixelFormat.rgba32);
        if (tmp_surf) |ts| {
            defer ts.destroy();
            const ts_pixels = ts.pixels();
            const ts_pitch: usize = @intCast(ts.pitch());
            if (ts_pitch == dst_pitch) {
                @memcpy(mapped[0..size], ts_pixels[0..size]);
            } else {
                var y: usize = 0;
                while (y < u_h) : (y += 1) {
                    @memcpy(mapped[y * dst_pitch .. y * dst_pitch + u_w * 4], ts_pixels[y * ts_pitch .. y * ts_pitch + u_w * 4]);
                }
            }
            const end_conv = sdl.timer.getTicksNs();
            conversion_time_ms = @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
        } else {
            dev.unmapTransferBuffer(transfer_buf);
            _ = cmd_wrapper.cancel();
            dev.releaseTexture(gpu_tex);
            return null;
        }
    }

    dev.unmapTransferBuffer(transfer_buf);

    const copy_pass = cmd_wrapper.beginCopyPass() orelse {
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };

    copy_pass.uploadToTexture(&sdl.gpu.TextureTransferInfo{
        .transfer_buffer = transfer_buf,
        .offset = 0,
        .pixels_per_row = @intCast(u_w),
        .rows_per_layer = @intCast(u_h),
    }, &sdl.gpu.TextureRegion{
        .texture = gpu_tex,
        .w = @intCast(img_w),
        .h = @intCast(img_h),
        .d = 1,
    }, false);
    copy_pass.end();

    var mipmap_time_ms: f64 = 0.0;
    if (num_levels > 1) {
        const start_mip = sdl.timer.getTicksNs();
        cmd_wrapper.generateMipmaps(gpu_tex);
        const end_mip = sdl.timer.getTicksNs();
        mipmap_time_ms = @as(f64, @floatFromInt(end_mip - start_mip)) / 1_000_000.0;
    }

    _ = cmd_wrapper.submit();

    const end_upload = sdl.timer.getTicksNs();
    const upload_time_ms = @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;

    var memory_size_bytes: usize = u_w * u_h * 4;
    if (num_levels > 1) {
        memory_size_bytes = (memory_size_bytes * 4) / 3;
    }

    return .{
        .gpu_texture = gpu_tex,
        .w = @floatFromInt(img_w),
        .h = @floatFromInt(img_h),
        .upload_time_ms = upload_time_ms,
        .memory_size_bytes = memory_size_bytes,
        .num_mip_levels = num_levels,
        .mipmap_time_ms = mipmap_time_ms,
        .conversion_time_ms = conversion_time_ms,
        .was_fallback = was_fallback,
        .fallback_time_ms = fallback_time_ms,
    };
}

test "parseImageDimensions" {
    // PNG test header
    const png_header = [_]u8{
        0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, // chunk length 13
        'I', 'H', 'D', 'R', // chunk type
        0x00, 0x00, 0x03, 0x20, // width 800
        0x00, 0x00, 0x02, 0x58, // height 600
        0x08, 0x02, 0x00, 0x00, 0x00, // bit depth, color type, compression, filter, interlace
    };
    const png_dims = parseImageDimensions(&png_header, "image/png");
    try std.testing.expect(png_dims != null);
    try std.testing.expectEqual(@as(f32, 800.0), png_dims.?.w);
    try std.testing.expectEqual(@as(f32, 600.0), png_dims.?.h);

    // GIF test header
    const gif_header = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        0x40, 0x01, // width 320
        0xF0, 0x00, // height 240
    };
    const gif_dims = parseImageDimensions(&gif_header, "image/gif");
    try std.testing.expect(gif_dims != null);
    try std.testing.expectEqual(@as(f32, 320.0), gif_dims.?.w);
    try std.testing.expectEqual(@as(f32, 240.0), gif_dims.?.h);

    // WebP VP8X test header
    const webp_vp8x_header = [_]u8{
        'R',  'I',  'F',  'F',
        0x16, 0x00, 0x00, 0x00,
        'W',  'E',  'B',  'P',
        'V',  'P',  '8',  'X',
        0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, // flags
        0x7F, 0x07, 0x00, // canvas w - 1 (1919 -> 1920)
        0x37, 0x04, 0x00, // canvas h - 1 (1079 -> 1080)
    };
    const vp8x_dims = parseImageDimensions(&webp_vp8x_header, "image/webp");
    try std.testing.expect(vp8x_dims != null);
    try std.testing.expectEqual(@as(f32, 1920.0), vp8x_dims.?.w);
    try std.testing.expectEqual(@as(f32, 1080.0), vp8x_dims.?.h);

    // WebP VP8L test header (25 bytes minimal)
    const webp_vp8l_header = [_]u8{
        'R',  'I',  'F',  'F',
        0x11, 0x00, 0x00, 0x00,
        'W',  'E',  'B',  'P',
        'V',  'P',  '8',  'L',
        0x05, 0x00, 0x00, 0x00,
        0x2F, // 1-byte signature
        0xE7, 0xC3, 0x7C, 0x00, // w: 1000, h: 500
    };
    const vp8l_dims = parseImageDimensions(&webp_vp8l_header, "image/webp");
    try std.testing.expect(vp8l_dims != null);
    try std.testing.expectEqual(@as(f32, 1000.0), vp8l_dims.?.w);
    try std.testing.expectEqual(@as(f32, 500.0), vp8l_dims.?.h);

    // WebP VP8 lossy test header
    const webp_vp8_header = [_]u8{
        'R',  'I',  'F',  'F',
        0x16, 0x00, 0x00, 0x00,
        'W',  'E',  'B',  'P',
        'V',  'P',  '8',  ' ',
        0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, // frame tag
        0x9D, 0x01, 0x2A, // start code
        0x80, 0x02, // w: 640
        0xE0, 0x01, // h: 480
    };
    const vp8_dims = parseImageDimensions(&webp_vp8_header, "image/webp");
    try std.testing.expect(vp8_dims != null);
    try std.testing.expectEqual(@as(f32, 640.0), vp8_dims.?.w);
    try std.testing.expectEqual(@as(f32, 480.0), vp8_dims.?.h);

    // BMP test header (top-down with negative height)
    const bmp_header = [_]u8{
        'B', 'M',
        0x36, 0x00, 0x0C, 0x00, // file size
        0x00, 0x00, 0x00, 0x00, // reserved
        0x36, 0x00, 0x00, 0x00, // offset to pixels
        40, 0x00, 0x00, 0x00, // DIB size (40)
        0x00, 0x04, 0x00, 0x00, // w: 1024
        0x00, 0xFD, 0xFF, 0xFF, // h: -768 (top-down)
    };
    const bmp_dims = parseImageDimensions(&bmp_header, "image/bmp");
    try std.testing.expect(bmp_dims != null);
    try std.testing.expectEqual(@as(f32, 1024.0), bmp_dims.?.w);
    try std.testing.expectEqual(@as(f32, 768.0), bmp_dims.?.h);
}

test "enforceVramBudget - distant eviction, circular distance, and neighbor protection" {
    const allocator = std.testing.allocator;
    var cache = CacheSlotMap{};
    defer cache.deinit(allocator, null);

    const makeGpu = struct {
        fn create(size: usize) CacheEntry {
            return .{
                .status = .{
                    .loaded_gpu = .{
                        .gpu_texture = undefined,
                        .w = 100,
                        .h = 100,
                        .size_bytes = size,
                        .memory_size_bytes = size,
                    },
                },
            };
        }
    }.create;

    // total_items = 10, current = 0
    // Slots: 0 (dist 0), 1 (dist 1), 2 (dist 2), 5 (dist 5), 9 (dist 1 wrap-around)
    try cache.appendWithKey(allocator, .{ .index = 0, .generation = 0 }, makeGpu(100));
    try cache.appendWithKey(allocator, .{ .index = 1, .generation = 0 }, makeGpu(100));
    try cache.appendWithKey(allocator, .{ .index = 2, .generation = 0 }, makeGpu(100));
    try cache.appendWithKey(allocator, .{ .index = 5, .generation = 0 }, makeGpu(100));
    try cache.appendWithKey(allocator, .{ .index = 9, .generation = 0 }, makeGpu(100));
    // Total VRAM = 500 bytes

    try std.testing.expectEqual(@as(usize, 500), cache.getTotalVramBytes());

    // 1. Evict down to 400: slot 5 (dist 5) is distant (dist > 2) and must be evicted first
    cache.enforceVramBudget(null, 0, 10, 400);
    try std.testing.expectEqual(@as(usize, 400), cache.getTotalVramBytes());
    try std.testing.expect(cache.getIndex(.{ .index = 5, .generation = 0 }) == null);
    try std.testing.expect(cache.getIndex(.{ .index = 0, .generation = 0 }) != null);
    try std.testing.expect(cache.getIndex(.{ .index = 1, .generation = 0 }) != null);
    try std.testing.expect(cache.getIndex(.{ .index = 2, .generation = 0 }) != null);
    try std.testing.expect(cache.getIndex(.{ .index = 9, .generation = 0 }) != null);

    // 2. Evict down to 300: Remaining are 0, 1, 2, 9 (dists: 0, 1, 2, 1).
    // All remaining non-cur have dist <= 2. Neighbor protection should evict dist 2 (slot 2) before dist 1 (slot 1 or 9).
    cache.enforceVramBudget(null, 0, 10, 300);
    try std.testing.expectEqual(@as(usize, 300), cache.getTotalVramBytes());
    try std.testing.expect(cache.getIndex(.{ .index = 2, .generation = 0 }) == null);
    try std.testing.expect(cache.getIndex(.{ .index = 0, .generation = 0 }) != null);

    // 3. Evict down to 50: Current slot 0 (100 bytes) should NEVER be evicted even if exceeding budget
    cache.enforceVramBudget(null, 0, 10, 50);
    try std.testing.expectEqual(@as(usize, 100), cache.getTotalVramBytes());
    try std.testing.expect(cache.getIndex(.{ .index = 0, .generation = 0 }) != null);
    try std.testing.expect(cache.getIndex(.{ .index = 1, .generation = 0 }) == null);
    try std.testing.expect(cache.getIndex(.{ .index = 9, .generation = 0 }) == null);

    // 4. Test robustness against linear_dist > total_items (e.g. slot 99 with total_items = 5)
    try cache.appendWithKey(allocator, .{ .index = 99, .generation = 0 }, makeGpu(100));
    try std.testing.expectEqual(@as(usize, 200), cache.getTotalVramBytes());
    cache.enforceVramBudget(null, 0, 5, 100);
    try std.testing.expectEqual(@as(usize, 100), cache.getTotalVramBytes());
    try std.testing.expect(cache.getIndex(.{ .index = 99, .generation = 0 }) == null);
    try std.testing.expect(cache.getIndex(.{ .index = 0, .generation = 0 }) != null);
}

test "hasUnreadyPrefetchSlots" {
    const allocator = std.testing.allocator;
    var cache = CacheSlotMap{};
    defer cache.deinit(allocator, null);

    // Total 5 items, current 0 -> desired: 0, 1, 2, 4, 3
    // Empty cache -> unready
    try std.testing.expect(cache.hasUnreadyPrefetchSlots(0, 5, true));

    const makeGpu = CacheEntry{
        .status = .{
            .loaded_gpu = .{
                .gpu_texture = undefined,
                .w = 100,
                .h = 100,
                .size_bytes = 100,
                .memory_size_bytes = 100,
            },
        },
    };

    // Add 0, 1, 2, 3, 4 as loaded_gpu
    for (0..5) |idx| {
        try cache.appendWithKey(allocator, .{ .index = idx, .generation = 0 }, makeGpu);
    }
    try std.testing.expect(!cache.hasUnreadyPrefetchSlots(0, 5, true));

    // One slot is decoding -> unready
    _ = cache.updateStatus(.{ .index = 2, .generation = 0 }, .{ .decoding = .{} });
    try std.testing.expect(cache.hasUnreadyPrefetchSlots(0, 5, true));

    // One slot is loaded_cpu: unready if has_gpu = true, ready if has_gpu = false
    _ = cache.updateStatus(.{ .index = 2, .generation = 0 }, .{
        .loaded_cpu = .{
            .surface = undefined,
            .w = 100,
            .h = 100,
            .size_bytes = 100,
        },
    });
    try std.testing.expect(cache.hasUnreadyPrefetchSlots(0, 5, true));
    try std.testing.expect(!cache.hasUnreadyPrefetchSlots(0, 5, false));

    // Reset status to .failed to prevent calling SDL_DestroySurface on undefined mock surface during defer deinit
    _ = cache.updateStatus(.{ .index = 2, .generation = 0 }, .failed);
}

test "CacheSlotMap.updateStatus" {
    const allocator = std.testing.allocator;
    var cache = CacheSlotMap{};
    defer cache.deinit(allocator, null);

    try cache.appendWithKey(allocator, .{ .index = 10, .generation = 1 }, .{
        .status = .{ .decoding = .{} },
    });
    try cache.appendWithKey(allocator, .{ .index = 20, .generation = 1 }, .{
        .status = .{ .decoding = .{} },
    });

    // Test successful update
    const updated = cache.updateStatus(.{ .index = 20, .generation = 1 }, .failed);
    try std.testing.expect(updated);
    try std.testing.expectEqual(CacheStatus.failed, cache.slots.items(.entry)[1].status);

    // Test updating non-existent index
    const updated_missing = cache.updateStatus(.{ .index = 30, .generation = 1 }, .failed);
    try std.testing.expect(!updated_missing);

    // Test updating matching index but mismatching generation
    const updated_gen_mismatch = cache.updateStatus(.{ .index = 10, .generation = 2 }, .failed);
    try std.testing.expect(!updated_gen_mismatch);
}

test "UploadStagingBuffer - capacity growth and clean deinit" {
    var staging = UploadStagingBuffer{};
    try std.testing.expect(staging.transfer_buffer == null);
    try std.testing.expect(staging.storage_buffer == null);
    try std.testing.expectEqual(@as(usize, 0), staging.transfer_capacity);
    try std.testing.expectEqual(@as(usize, 0), staging.storage_capacity);

    const dev_opt = sdl.gpu.Device.create(sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl, true);
    const dev = dev_opt orelse return;
    defer dev.destroy();

    // Initial allocation should be at least 4MB aligned to 4KB
    const tb1 = staging.getOrCreateTransferBuffer(dev, 1024);
    try std.testing.expect(tb1 != null);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), staging.transfer_capacity);

    // Reuse existing buffer when required_size <= transfer_capacity
    const tb2 = staging.getOrCreateTransferBuffer(dev, 2 * 1024 * 1024);
    try std.testing.expect(tb2 != null);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), staging.transfer_capacity);

    // Reallocation with geometric growth (4MB -> 8MB) when required exceeds capacity
    const tb3 = staging.getOrCreateTransferBuffer(dev, 5 * 1024 * 1024);
    try std.testing.expect(tb3 != null);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), staging.transfer_capacity);

    // Storage buffer test
    const sb1 = staging.getOrCreateStorageBuffer(dev, 1024);
    try std.testing.expect(sb1 != null);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), staging.storage_capacity);

    // Deinit releases all buffers and resets capacities
    staging.deinit(dev);
    try std.testing.expect(staging.transfer_buffer == null);
    try std.testing.expect(staging.storage_buffer == null);
    try std.testing.expectEqual(@as(usize, 0), staging.transfer_capacity);
    try std.testing.expectEqual(@as(usize, 0), staging.storage_capacity);
}

test "uploadSurfaceToGpu - staging buffer reuse across consecutive uploads" {
    const dev_opt = sdl.gpu.Device.create(sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl, true);
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var staging = UploadStagingBuffer{};
    defer staging.deinit(dev);

    const surf1 = sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse return;
    defer surf1.destroy();

    const res1 = uploadSurfaceToGpu(dev, surf1, null, &staging);
    try std.testing.expect(res1 != null);
    if (res1) |r| {
        dev.releaseTexture(r.gpu_texture);
        try std.testing.expectEqual(@as(f32, 64.0), r.w);
        try std.testing.expectEqual(@as(f32, 64.0), r.h);
    }

    try std.testing.expect(staging.transfer_buffer != null);
    const cap1 = staging.transfer_capacity;
    try std.testing.expect(cap1 >= 64 * 64 * 4);

    // Second upload should reuse staging transfer buffer without reallocating
    const surf2 = sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse return;
    defer surf2.destroy();

    const res2 = uploadSurfaceToGpu(dev, surf2, null, &staging);
    try std.testing.expect(res2 != null);
    if (res2) |r| {
        dev.releaseTexture(r.gpu_texture);
        try std.testing.expectEqual(@as(f32, 32.0), r.w);
        try std.testing.expectEqual(@as(f32, 32.0), r.h);
    }

    try std.testing.expectEqual(cap1, staging.transfer_capacity);
}

test "probeMediaMetadata - filesystem JPEG" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{ .path = "testfiles/images/000_0_1024x682.jpg" },
    };
    const meta = probeMediaMetadata(io, media);
    try std.testing.expect(meta != null);
    if (meta) |m| {
        try std.testing.expectEqual(@as(f32, 1024.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), m.dims.h);
        try std.testing.expectEqual(Orientation.normal, m.orientation);
    }
}

test "probeMediaMetadata - nonexistent file returns null" {
    const prev_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_level;

    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{ .path = "testfiles/nonexistent.jpg" },
    };
    try std.testing.expectEqual(@as(?ProbedImageMetadata, null), probeMediaMetadata(io, media));
}

test "probeMediaMetadata - archive entry handling" {
    const io = std.Io.Threaded.global_single_threaded.io();

    // Compressed ZIP entry returns null
    const media_comp = MediaEntry{
        .archive_entry = .{
            .archive_path = "testfiles/images/000_0_1024x682.jpg",
            .entry_name = "test.jpg",
            .compression_method = 8,
            .file_offset = 0,
        },
    };
    try std.testing.expectEqual(@as(?ProbedImageMetadata, null), probeMediaMetadata(io, media_comp));

    // Missing file_offset returns null
    const media_no_offset = MediaEntry{
        .archive_entry = .{
            .archive_path = "testfiles/images/000_0_1024x682.jpg",
            .entry_name = "test.jpg",
            .compression_method = 0,
            .file_offset = null,
        },
    };
    try std.testing.expectEqual(@as(?ProbedImageMetadata, null), probeMediaMetadata(io, media_no_offset));

    // Uncompressed entry with valid offset
    const media_stored = MediaEntry{
        .archive_entry = .{
            .archive_path = "testfiles/images/000_0_1024x682.jpg",
            .entry_name = "test.jpg",
            .compression_method = 0,
            .file_offset = 0,
        },
    };
    const meta = probeMediaMetadata(io, media_stored);
    try std.testing.expect(meta != null);
    if (meta) |m| {
        try std.testing.expectEqual(@as(f32, 1024.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), m.dims.h);
    }
}

test "CacheSlotMap - atomic generation advance and activeKey" {
    var cache = CacheSlotMap{};
    try std.testing.expectEqual(@as(usize, 0), cache.getGeneration());
    const next_gen = cache.advanceGeneration();
    try std.testing.expectEqual(@as(usize, 1), next_gen);
    try std.testing.expectEqual(@as(usize, 1), cache.getGeneration());
    const key = cache.activeKey(5);
    try std.testing.expectEqual(@as(usize, 5), key.index);
    try std.testing.expectEqual(@as(usize, 1), key.generation);
}

test "loadThumbnailSurface - filesystem Fujifilm RAF" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{
            .path = "Capture/20191103-Emiray Natural Light-0001.RAF",
        },
    };
    var f = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, media.filesystem.path, .{}) catch return;
    f.close(io);

    const thumb = loadThumbnailSurface(io, std.testing.allocator, media);
    try std.testing.expect(thumb != null);
    if (thumb) |t| {
        defer t.surface.destroy();
        try std.testing.expect(t.surface.w() > 0);
        try std.testing.expect(t.surface.h() > 0);
        try std.testing.expectEqual(Orientation.normal, t.orientation);
        try std.testing.expect(t.raw_metadata.isRaw());
        try std.testing.expect(t.dct_snapped);
    }
}

test "loadThumbnailSurface - filesystem Sony ARW (theoretical padding, dct_snapped = false)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{
            .path = "ThumbTest/20170816-KayJay-0001.ARW",
        },
    };
    var f = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, media.filesystem.path, .{}) catch return;
    f.close(io);

    const thumb = loadThumbnailSurface(io, std.testing.allocator, media);
    try std.testing.expect(thumb != null);
    if (thumb) |t| {
        defer t.surface.destroy();
        try std.testing.expect(!t.dct_snapped);
    }
}

test "loadThumbnailSurface - filesystem Ricoh GR IIIx JPG (8px DCT block snapping, dct_snapped = true)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{
            .path = "ThumbTest/2026-02-15-R0001964.JPG",
        },
    };
    var f = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, media.filesystem.path, .{}) catch return;
    f.close(io);

    const thumb = loadThumbnailSurface(io, std.testing.allocator, media);
    try std.testing.expect(thumb != null);
    if (thumb) |t| {
        defer t.surface.destroy();
        try std.testing.expect(t.dct_snapped);
    }
}

test "loadThumbnailSurface - filesystem Fujifilm JPG (theoretical padding, dct_snapped = false)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{
            .path = "ThumbTest/2026-01-24-DSCF0474.JPG",
        },
    };
    var f = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, media.filesystem.path, .{}) catch return;
    f.close(io);

    const thumb = loadThumbnailSurface(io, std.testing.allocator, media);
    try std.testing.expect(thumb != null);
    if (thumb) |t| {
        defer t.surface.destroy();
        try std.testing.expect(!t.dct_snapped);
    }
}

test "loadThumbnailSurface - filesystem Fujifilm X-E5 RAF (8px DCT block snapping, dct_snapped = true)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{
            .path = "ThumbTest/2026-01-24-DSCF0474.RAF",
        },
    };
    var f = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, media.filesystem.path, .{}) catch return;
    f.close(io);

    const thumb = loadThumbnailSurface(io, std.testing.allocator, media);
    try std.testing.expect(thumb != null);
    if (thumb) |t| {
        defer t.surface.destroy();
        try std.testing.expect(t.dct_snapped);
    }
}

test "loadThumbnailSurface - filesystem non-existent file returns null" {
    const prev_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_level;

    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{
            .path = "testfiles/images/non_existent_file.raf",
        },
    };
    const thumb = loadThumbnailSurface(io, std.testing.allocator, media);
    try std.testing.expectEqual(@as(?ExtractedThumbnail, null), thumb);
}

test "detectThumbnailDctPadding - matching aspect ratio returns false" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse return;
    defer surf.destroy();
    try std.testing.expect(!detectThumbnailDctPadding(surf, 1600.0, 1200.0));
}

test "detectThumbnailDctPadding - invalid dimensions return false" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse return;
    defer surf.destroy();
    try std.testing.expect(!detectThumbnailDctPadding(surf, 0.0, 1200.0));
    try std.testing.expect(!detectThumbnailDctPadding(surf, 1600.0, 0.0));
}

test "detectThumbnailDctPadding - detects 8px DCT block snapping when boundary rows are black and step transition occurs" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse return;
    defer surf.destroy();

    // Fill rows 0..7 and 112..119 with black (0), rows 8..111 with bright pixels (200)
    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();
    var y: usize = 0;
    while (y < 120) : (y += 1) {
        const val: u8 = if (y < 8 or y >= 112) 0 else 200;
        const row = px + y * pitch;
        @memset(row[0 .. 160 * 3], val);
    }

    // 3:2 full image (6000x4000) in 4:3 thumb (160x120): theoretical pad is 6.67px
    // Snaps to 8px DCT block; candidate row 7 and row 112 are black, and row 8 has image pixels -> returns true
    try std.testing.expect(detectThumbnailDctPadding(surf, 6000.0, 4000.0));
}

test "detectThumbnailDctPadding - returns false when row 7 contains active image pixels" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse return;
    defer surf.destroy();

    // Active image begins at row 7 (e.g. theoretical 6.67px padding in Sony ARW / Fuji JPG)
    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();
    var y: usize = 0;
    while (y < 120) : (y += 1) {
        const val: u8 = if (y < 7 or y >= 113) 0 else 200;
        const row = px + y * pitch;
        @memset(row[0 .. 160 * 3], val);
    }

    // Row 7 has bright pixels (200 > 16) -> not snapped to 8px DCT block boundary
    try std.testing.expect(!detectThumbnailDctPadding(surf, 6000.0, 4000.0));
}

test "detectThumbnailDctPadding - solid black background returns false (no false positive)" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse return;
    defer surf.destroy();

    // Entire surface is pure black (e.g. astrophotography or seamless black background)
    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();
    var y: usize = 0;
    while (y < 120) : (y += 1) {
        const row = px + y * pitch;
        @memset(row[0 .. 160 * 3], 0);
    }

    // Because rows 8 and 111 are also black (no step-transition to image content at row 8),
    // it correctly avoids a false-positive DCT snapping detection.
    try std.testing.expect(!detectThumbnailDctPadding(surf, 6000.0, 4000.0));
}

test "probeMediaMetadata - detects embedded thumbnail presence on RAF" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{
            .path = "Capture/20191103-Emiray Natural Light-0001.RAF",
        },
    };
    if (probeMediaMetadata(io, media)) |meta| {
        try std.testing.expect(meta.has_embedded_thumbnail);
        try std.testing.expect(meta.dims.w > 0);
        try std.testing.expect(meta.dims.h > 0);
    }
}

test "probeMediaMetadata - non-thumbnail formats return has_embedded_thumbnail = false" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{
            .path = "testfiles/golden-screenshots/test_0_init.png",
        },
    };
    if (probeMediaMetadata(io, media)) |meta| {
        try std.testing.expect(!meta.has_embedded_thumbnail);
        try std.testing.expect(meta.dims.w > 0);
        try std.testing.expect(meta.dims.h > 0);
    }
}
