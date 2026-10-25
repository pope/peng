const core_fs = @import("fs.zig");
const exif = @import("exif.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const ArchiveMediaEntry = state_pkg.types.ArchiveMediaEntry;
const CacheEntry = state_pkg.CacheEntry;
const CacheMetadata = state_pkg.CacheMetadata;
const CacheResident = state_pkg.CacheResident;
const CpuSurfaceComponent = state_pkg.CpuSurfaceComponent;
const GpuTextureComponent = state_pkg.GpuTextureComponent;
const InFlightDecode = state_pkg.InFlightDecode;
const JpegDimensions = exif.JpegDimensions;
pub const MediaEntry = state_pkg.MediaEntry;
const MediaId = state_pkg.MediaId;
pub const Orientation = state_pkg.Orientation;
const parseExifDimensions = exif.parseExifDimensions;
const parseExifOrientation = exif.parseExifOrientation;
const RawMetadata = state_pkg.RawMetadata;
const ResidentAsset = state_pkg.ResidentAsset;
const ZipSeekOffsets = state_pkg.types.ZipSeekOffsets;

/// Unique lookup key identifying a cached image slot by its stable MediaId
/// and cache generation epoch.
pub const ImageCacheKey = struct {
    id: MediaId,
    generation: usize,

    /// Equality predicate comparing MediaId and generation epoch.
    pub inline fn eql(self: ImageCacheKey, other: ImageCacheKey) bool {
        return self.id == other.id and self.generation == other.generation;
    }
};

/// Cache slot structure binding an `ImageCacheKey` to its active `CacheEntry`
/// state.
pub const CacheSlot = struct {
    key: ImageCacheKey,
    entry: CacheEntry,
};

/// Computes cyclic distance between two indices in an array of total_items.
pub fn calcCyclicDistance(
    idx: usize,
    cur: usize,
    total_items: usize,
) usize {
    const linear = if (idx > cur) idx - cur else cur - idx;
    return if (total_items > 0 and linear <= total_items)
        @min(linear, total_items - linear)
    else
        linear;
}

/// Structure-of-Arrays (SoA) associative cache managing decoded image slots,
/// generation epochs, and VRAM memory budgeting.
pub const ImageCache = struct {
    slots: std.MultiArrayList(CacheSlot) = .{},
    generation: std.atomic.Value(usize) = .init(0),
    vram_capped_neighbors: ?state_pkg.VisibleNeighbors = null,
    vram_capped_prev_index: ?usize = null,
    max_prefetch_dist: usize = 2,

    /// Atomically increments the cache generation epoch to invalidate
    /// in-flight asynchronous decode tasks.
    pub fn advanceGeneration(self: *ImageCache) usize {
        self.vram_capped_neighbors = null;
        self.vram_capped_prev_index = null;
        self.max_prefetch_dist = 2;
        return self.generation.fetchAdd(1, .release) +% 1;
    }

    /// Generates an `ImageCacheKey` combining the specified MediaId and
    /// current generation epoch.
    pub fn activeKey(self: *const ImageCache, id: MediaId) ImageCacheKey {
        return .{
            .id = id,
            .generation = self.generation.load(.acquire),
        };
    }

    /// Returns the count of allocated cache slots.
    pub fn count(self: *const ImageCache) usize {
        return self.slots.len;
    }

    /// Deinitializes all cached GPU textures and releases the multi-array storage memory.
    pub fn deinit(
        self: *ImageCache,
        allocator: std.mem.Allocator,
        gpu_device: ?sdl.gpu.Device,
    ) void {
        const entries = self.slots.items(.entry);
        for (entries) |*entry| {
            entry.deinit(gpu_device);
        }
        self.slots.deinit(allocator);
    }

    /// Deinitializes all slot resources and clears the cache while retaining
    /// capacity.
    pub fn clear(self: *ImageCache, gpu_device: ?sdl.gpu.Device) void {
        const entries = self.slots.items(.entry);
        for (entries) |*entry| {
            entry.deinit(gpu_device);
        }
        self.slots.clearRetainingCapacity();
        self.vram_capped_neighbors = null;
        self.vram_capped_prev_index = null;
        self.max_prefetch_dist = 2;
    }

    /// Clears all slots without releasing underlying capacity.
    pub fn clearRetainingCapacity(self: *ImageCache) void {
        self.slots.clearRetainingCapacity();
        self.vram_capped_neighbors = null;
        self.vram_capped_prev_index = null;
        self.max_prefetch_dist = 2;
    }

    /// Finds the dense array index of the slot matching `key`, or null if not found.
    pub fn getIndex(self: *const ImageCache, key: ImageCacheKey) ?usize {
        const keys = self.slots.items(.key);
        for (keys, 0..) |k, i| {
            if (k.eql(key)) return i;
        }
        return null;
    }

    /// Returns a pointer to the `CacheEntry` corresponding to `key`, or null if not present.
    pub fn get(self: *ImageCache, key: ImageCacheKey) ?*CacheEntry {
        if (self.getIndex(key)) |i| return &self.slots.items(.entry)[i];
        return null;
    }

    /// Returns a copy of the `CacheEntry` corresponding to `key`, or null if not present.
    pub fn getEntry(self: *const ImageCache, key: ImageCacheKey) ?CacheEntry {
        if (self.getIndex(key)) |i| return self.slots.items(.entry)[i];
        return null;
    }

    /// Replaces resident asset in cache slot and frees previous resource.
    pub fn setResidentAsset(
        self: *ImageCache,
        key: ImageCacheKey,
        asset: ResidentAsset,
        gpu_device: ?sdl.gpu.Device,
    ) void {
        const idx = self.getIndex(key) orelse return;
        const entry = &self.slots.items(.entry)[idx];
        entry.resident.asset.deinit(gpu_device);
        entry.resident.asset = asset;
    }

    /// Updates or clears the in-flight decode task state for a cache slot.
    pub fn setInFlight(
        self: *ImageCache,
        key: ImageCacheKey,
        inflight: ?InFlightDecode,
    ) void {
        const idx = self.getIndex(key) orelse return;
        self.slots.items(.entry)[idx].inflight = inflight;
    }

    /// Appends a new slot for media `id` at current generation, returning
    /// its unique `ImageCacheKey`.
    pub fn appendSlot(
        self: *ImageCache,
        allocator: std.mem.Allocator,
        id: MediaId,
        entry: CacheEntry,
    ) !ImageCacheKey {
        const key = self.activeKey(id);
        try self.slots.append(allocator, .{
            .key = key,
            .entry = entry,
        });
        return key;
    }

    /// Removes a slot at `index_in_list` via swap-remove and releases its GPU texture.
    pub fn removeAndDeinit(
        self: *ImageCache,
        index_in_list: usize,
        gpu_device: ?sdl.gpu.Device,
    ) void {
        var entry = self.slots.items(.entry)[index_in_list];
        self.slots.swapRemove(index_in_list);
        entry.deinit(gpu_device);
    }

    pub const DEFAULT_MAX_VRAM_BYTES: usize = 1024 * 1024 * 1024;

    /// Computes the total VRAM consumption in bytes across all `.loaded_gpu`
    /// textures in the cache.
    pub fn getTotalVramBytes(self: *const ImageCache) usize {
        var total: usize = 0;
        const entries = self.slots.items(.entry);
        for (entries) |entry| {
            switch (entry.resident.asset) {
                .loaded_gpu => |gpu| total += gpu.memory_size_bytes,
                .none, .failed, .loaded_cpu => {},
            }
        }
        return total;
    }

    /// Returns the maximum circular neighbor distance (`0..2`) to prefetch for
    /// `neighbors` without exceeding the VRAM budget.
    pub fn getMaxPrefetchDist(
        self: *const ImageCache,
        neighbors: state_pkg.VisibleNeighbors,
    ) usize {
        if (self.vram_capped_neighbors) |capped| {
            if (std.meta.eql(capped, neighbors)) {
                return self.max_prefetch_dist;
            }
        }
        return 2;
    }

    /// Enforces maximum VRAM budget by evicting `.loaded_gpu` textures.
    ///
    /// Eviction ordering uses visible neighbor distance from `neighbors`:
    /// 1. Distant or hidden entries (outside the visible ±2 window) are evicted
    ///    furthest first.
    /// 2. If VRAM budget is still exceeded and only visible neighbors
    ///    (step distance <= 2) remain, they are evicted furthest first and
    ///    `max_prefetch_dist` is lowered to prevent re-decode thrashing.
    /// The currently active image and any active outgoing slideshow transition
    /// image (`protected_prev_index`) are strictly protected.
    pub fn enforceVramBudget(
        self: *ImageCache,
        gpu_device: ?sdl.gpu.Device,
        nav: anytype,
        neighbors_opt: ?state_pkg.VisibleNeighbors,
        protected_prev_index: ?usize,
        total_items: usize,
        max_bytes: usize,
    ) void {
        if (!std.meta.eql(neighbors_opt, self.vram_capped_neighbors) or
            protected_prev_index != self.vram_capped_prev_index)
        {
            self.vram_capped_neighbors = neighbors_opt;
            self.vram_capped_prev_index = protected_prev_index;
            self.max_prefetch_dist = 2;
        }

        while (self.getTotalVramBytes() > max_bytes) {
            const entries = self.slots.items(.entry);
            const keys = self.slots.items(.key);

            var max_distant_dist: usize = 0;
            var distant_victim: ?usize = null;

            var max_neighbor_dist: usize = 0;
            var neighbor_victim: ?usize = null;

            for (entries, keys, 0..) |entry, key, i| {
                if (entry.resident.asset != .loaded_gpu) continue;
                const neighbors = neighbors_opt orelse {
                    distant_victim = i;
                    break;
                };
                const item_pos = nav.posOfId(key.id) orelse {
                    distant_victim = i;
                    break;
                };
                if (item_pos == neighbors.current) continue;
                if (protected_prev_index) |prev| {
                    if (item_pos == prev) continue;
                }
                if (neighbors.stepDistance(item_pos)) |step_dist| {
                    const is_neighbor_victim = neighbor_victim == null or
                        step_dist > max_neighbor_dist;
                    if (is_neighbor_victim) {
                        max_neighbor_dist = step_dist;
                        neighbor_victim = i;
                    }
                } else {
                    const dist = calcCyclicDistance(
                        item_pos,
                        neighbors.current,
                        total_items,
                    );
                    if (distant_victim == null or dist > max_distant_dist) {
                        max_distant_dist = dist;
                        distant_victim = i;
                    }
                }
            }

            if (distant_victim) |v_i| {
                self.removeAndDeinit(v_i, gpu_device);
            } else if (neighbor_victim) |v_i| {
                self.max_prefetch_dist = @min(
                    self.max_prefetch_dist,
                    max_neighbor_dist -| 1,
                );
                self.removeAndDeinit(v_i, gpu_device);
            } else {
                self.max_prefetch_dist = 0;
                break;
            }
        }
    }

    /// Checks whether any desired visible prefetch slots (current, ±1, ±2
    /// circularly within the active VRAM prefetch radius) are missing from the
    /// cache or not in a terminal/ready status.
    ///
    /// A slot is considered unready if it is missing, decoding, uploading,
    /// or loaded on CPU when a GPU device is present.
    pub fn hasUnreadyPrefetchSlots(
        self: *const ImageCache,
        nav: anytype,
        neighbors: state_pkg.VisibleNeighbors,
        has_gpu: bool,
    ) bool {
        const max_dist = self.getMaxPrefetchDist(neighbors);
        var desired_buf: [5]usize = undefined;
        const desired = neighbors.collectUnique(
            .forward,
            max_dist,
            &desired_buf,
        );

        for (desired) |d| {
            const id = nav.getIdAt(d) orelse return true;
            const key = self.activeKey(id);
            if (self.getIndex(key)) |i| {
                const entry = self.slots.items(.entry)[i];
                if (entry.inflight != null) return true;
                switch (entry.resident.asset) {
                    .loaded_gpu, .failed => {},
                    .loaded_cpu => {
                        if (has_gpu) return true;
                    },
                    .none => return true,
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
    const png_magic = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (header.len >= 8 and std.mem.startsWith(u8, header, &png_magic)) {
        return "image/png";
    }
    if (header.len >= 3 and std.mem.startsWith(u8, header, &[_]u8{ 0xFF, 0xD8, 0xFF })) {
        return "image/jpeg";
    }
    if (header.len >= 6 and
        (std.mem.startsWith(u8, header, "GIF87a") or
            std.mem.startsWith(u8, header, "GIF89a")))
    {
        return "image/gif";
    }
    if (header.len >= 2 and std.mem.startsWith(u8, header, "BM")) {
        return "image/bmp";
    }
    if (header.len >= 12 and
        std.mem.startsWith(u8, header, "RIFF") and
        std.mem.eql(u8, header[8..12], "WEBP"))
    {
        return "image/webp";
    }
    if (header.len >= 8 and std.mem.startsWith(u8, header, "FUJIFILM")) {
        return "image/x-fuji-raf";
    }
    const is_tiff_le = header[0] == 0x49 and header[1] == 0x49 and
        header[2] == 0x2A and header[3] == 0x00;
    const is_tiff_be = header[0] == 0x4D and header[1] == 0x4D and
        header[2] == 0x00 and header[3] == 0x2A;
    if (header.len >= 4 and (is_tiff_le or is_tiff_be)) {
        const ext = std.Io.Dir.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".arw")) return "image/x-sony-arw";
        if (std.ascii.eqlIgnoreCase(ext, ".cr2")) return "image/x-canon-cr2";
        if (std.ascii.eqlIgnoreCase(ext, ".nef")) return "image/x-nikon-nef";
        if (std.ascii.eqlIgnoreCase(ext, ".dng")) return "image/x-adobe-dng";
        if (std.ascii.eqlIgnoreCase(ext, ".orf")) return "image/x-olympus-orf";
        if (std.ascii.eqlIgnoreCase(ext, ".rw2")) return "image/x-panasonic-rw2";
        if (std.ascii.eqlIgnoreCase(ext, ".pef")) return "image/x-pentax-pef";
        return "image/tiff";
    }

    const ext = std.Io.Dir.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg"))
    {
        return "image/jpeg";
    }
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

/// Parses full image width and height directly from image container headers
/// (JPEG, PNG, GIF, WebP, BMP, TIFF, RAW) in < 0.05ms without software decompression.
///
/// Returns null if the header buffer is insufficient or contains an unsupported format variant.
pub fn parseImageDimensions(header: []const u8, mime_type: []const u8) ?ImageDimensions {
    const is_fuji_mime = std.mem.eql(u8, mime_type, "image/x-fuji-raf");
    const is_fuji_magic = header.len >= 8 and std.mem.startsWith(u8, header, "FUJIFILM");
    if (is_fuji_mime or is_fuji_magic) {
        if (exif.extractFujiRafMetadataLocation(header)) |meta_loc| {
            if (meta_loc.file_offset +| meta_loc.length <= header.len) {
                const off: usize = @intCast(meta_loc.file_offset);
                const len: usize = @intCast(meta_loc.length);
                if (exif.parseFujiRafDimensions(header[off .. off + len])) |d| {
                    return .{ .w = d.w, .h = d.h };
                }
            }
        }
        if (exif.extractFujiRafPreviewLocation(header)) |prev_loc| {
            if (prev_loc.file_offset +| 32 <= header.len) {
                const off: usize = @intCast(prev_loc.file_offset);
                if (exif.readJpegDimensions(header[off..])) |d| {
                    return .{ .w = d.w, .h = d.h };
                }
            }
        }
    } else if (std.mem.startsWith(u8, mime_type, "image/x-") or
        std.mem.eql(u8, mime_type, "image/tiff") or
        (header.len >= 4 and ((header[0] == 0x49 and header[1] == 0x49 and
            header[2] == 0x2A and header[3] == 0x00) or
            (header[0] == 0x4D and header[1] == 0x4D and
                header[2] == 0x00 and header[3] == 0x2A))))
    {
        if (exif.parseExifDimensions(header)) |d| return .{ .w = d.w, .h = d.h };
    } else if (std.mem.eql(u8, mime_type, "image/jpeg") or
        (header.len >= 3 and
            std.mem.startsWith(u8, header, &[_]u8{ 0xFF, 0xD8, 0xFF })))
    {
        if (exif.readJpegDimensions(header)) |d| return .{ .w = d.w, .h = d.h };
    } else if (std.mem.eql(u8, mime_type, "image/png") or
        (header.len >= 8 and
            std.mem.startsWith(u8, header, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })))
    {
        const is_png = header.len >= 24 and
            std.mem.startsWith(
                u8,
                header,
                &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A },
            ) and
            std.mem.eql(u8, header[12..16], "IHDR");
        if (is_png) {
            const w = std.mem.readInt(u32, header[16..20], .big);
            const h = std.mem.readInt(u32, header[20..24], .big);
            if (w > 0 and h > 0) return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        }
    } else if (std.mem.eql(u8, mime_type, "image/gif") or
        (header.len >= 6 and
            (std.mem.startsWith(u8, header, "GIF87a") or
                std.mem.startsWith(u8, header, "GIF89a"))))
    {
        const is_gif = header.len >= 10 and
            (std.mem.startsWith(u8, header, "GIF87a") or
                std.mem.startsWith(u8, header, "GIF89a"));
        if (is_gif) {
            const w = std.mem.readInt(u16, header[6..8], .little);
            const h = std.mem.readInt(u16, header[8..10], .little);
            if (w > 0 and h > 0) return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        }
    } else if (std.mem.eql(u8, mime_type, "image/webp") or
        (header.len >= 12 and
            std.mem.startsWith(u8, header, "RIFF") and
            std.mem.eql(u8, header[8..12], "WEBP")))
    {
        if (header.len >= 25 and
            std.mem.startsWith(u8, header, "RIFF") and
            std.mem.eql(u8, header[8..12], "WEBP"))
        {
            if (std.mem.eql(u8, header[12..16], "VP8X") and header.len >= 30) {
                const w = 1 + (@as(u32, header[24]) |
                    (@as(u32, header[25]) << 8) |
                    (@as(u32, header[26]) << 16));
                const h = 1 + (@as(u32, header[27]) |
                    (@as(u32, header[28]) << 8) |
                    (@as(u32, header[29]) << 16));
                return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
            } else if (std.mem.eql(u8, header[12..16], "VP8L") and
                header.len >= 25 and
                header[20] == 0x2F)
            {
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
    } else if (std.mem.eql(u8, mime_type, "image/bmp") or
        (header.len >= 2 and std.mem.startsWith(u8, header, "BM")))
    {
        if (header.len >= 26 and std.mem.startsWith(u8, header, "BM")) {
            const dib_size = std.mem.readInt(u32, header[14..18], .little);
            if (dib_size >= 40 and header.len >= 26) {
                const w = std.mem.readInt(i32, header[18..22], .little);
                const h = std.mem.readInt(i32, header[22..26], .little);
                if (w != std.math.minInt(i32) and h != std.math.minInt(i32)) {
                    const abs_w: u32 = @intCast(if (w < 0) -w else w);
                    const abs_h: u32 = @intCast(if (h < 0) -h else h);
                    if (abs_w > 0 and abs_h > 0) {
                        return .{ .w = @floatFromInt(abs_w), .h = @floatFromInt(abs_h) };
                    }
                }
            }
        }
    }
    return null;
}

/// Container metadata discovered synchronously by probing file headers
/// on the main thread (< 0.1ms).
pub const ProbedImageMetadata = struct {
    dims: ImageDimensions,
    /// Image orientation metadata.
    orientation: Orientation = .normal,
    raw_metadata: RawMetadata = .none,
    /// True if an embedded preview thumbnail was discovered in container headers.
    has_embedded_thumbnail: bool = false,
};

fn probeStoredZipMetadata(
    io: std.Io,
    a: ArchiveMediaEntry,
    seek: ZipSeekOffsets,
) ?ProbedImageMetadata {
    if (seek.compression_method != .store) return null;

    var file = std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        a.archive_path,
        .{},
    ) catch |err| {
        std.log.warn(
            "probeMediaMetadata: openFile failed for archive '{s}': {any}",
            .{ a.archive_path, err },
        );
        return null;
    };
    defer file.close(io);

    var header_buf: [64 * 1024]u8 = undefined;
    var slices = [_][]u8{&header_buf};
    const n = file.readPositional(
        io,
        &slices,
        seek.file_offset,
    ) catch |err| {
        std.log.warn(
            "probeMediaMetadata: readPositional failed for '{s}': {any}",
            .{ a.archive_path, err },
        );
        return null;
    };
    if (n == 0) return null;

    var data_offset: usize = 0;
    if (n >= @sizeOf(std.zip.LocalFileHeader) and
        std.mem.eql(u8, header_buf[0..4], &std.zip.local_file_header_sig))
    {
        const filename_len = std.mem.readInt(u16, header_buf[26..28], .little);
        const extra_len = std.mem.readInt(u16, header_buf[28..30], .little);
        data_offset = @sizeOf(std.zip.LocalFileHeader) +
            @as(usize, filename_len) +
            @as(usize, extra_len);
    }
    if (n <= data_offset) return null;

    const image_slice = header_buf[data_offset..n];
    const mime_type = detectMimeType(image_slice, a.entry_name);
    const dims = parseImageDimensions(image_slice, mime_type) orelse
        return null;
    const rot = exif.parseExifOrientation(image_slice) orelse .normal;
    const is_raw = core_fs.isRawFile(a.entry_name) or
        std.mem.startsWith(u8, mime_type, "image/x-");

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

const FujiRafMetadataResult = struct {
    dims: ?ImageDimensions,
    rot: Orientation,
    has_thumb: bool,
};

fn probeFujiRafMetadata(
    file: *std.Io.File,
    io: std.Io,
    header: []const u8,
    existing_dims: ?ImageDimensions,
    path: []const u8,
) FujiRafMetadataResult {
    var dims = existing_dims;
    var rot: Orientation = .normal;
    var has_thumb = false;
    const n = header.len;

    if (dims == null) {
        if (exif.extractFujiRafMetadataLocation(header)) |meta_loc| {
            if (meta_loc.file_offset +| meta_loc.length <= n) {
                const start: usize = @intCast(meta_loc.file_offset);
                const len: usize = @intCast(meta_loc.length);
                const m_slice = header[start .. start + len];
                if (exif.parseFujiRafDimensions(m_slice)) |fd| {
                    dims = .{ .w = fd.w, .h = fd.h };
                }
            } else {
                var meta_tmp: [4096]u8 = undefined;
                const m_len: usize = @intCast(meta_loc.length);
                const to_read: usize = @min(m_len, meta_tmp.len);
                var m_slices = [_][]u8{meta_tmp[0..to_read]};
                const mn = file.readPositional(
                    io,
                    &m_slices,
                    meta_loc.file_offset,
                ) catch |err| blk: {
                    std.log.warn(
                        "probeMediaMetadata: RAF metadata failed for '{s}': " ++
                            "{any}",
                        .{ path, err },
                    );
                    break :blk 0;
                };
                if (mn >= 4) {
                    const m_sub = meta_tmp[0..mn];
                    if (exif.parseFujiRafDimensions(m_sub)) |fd| {
                        dims = .{ .w = fd.w, .h = fd.h };
                    }
                }
            }
        }
    }

    if (exif.extractFujiRafPreviewLocation(header)) |prev_loc| {
        has_thumb = true;
        if (prev_loc.file_offset +| 4096 <= n) {
            const off: usize = @intCast(prev_loc.file_offset);
            rot = exif.parseExifOrientation(header[off..n]) orelse .normal;
            if (dims == null) {
                dims = parseImageDimensions(header[off..n], "image/jpeg");
            }
        } else {
            var p_buf: [8192]u8 = undefined;
            var p_slices = [_][]u8{&p_buf};
            const pn = file.readPositional(
                io,
                &p_slices,
                prev_loc.file_offset,
            ) catch |err| blk: {
                std.log.warn(
                    "probeMediaMetadata: Fuji RAF preview readPositional " ++
                        "failed for '{s}': {any}",
                    .{ path, err },
                );
                break :blk 0;
            };
            if (pn > 0) {
                rot = exif.parseExifOrientation(p_buf[0..pn]) orelse .normal;
                if (dims == null) {
                    dims = parseImageDimensions(p_buf[0..pn], "image/jpeg");
                }
            }
        }
    }

    return .{ .dims = dims, .rot = rot, .has_thumb = has_thumb };
}

/// Synchronously probes container headers for image dimensions, EXIF rotation,
/// and embedded thumbnail presence in < 0.1ms before spawning background decode
/// workers, eliminating Frame-1 layout jumps and UI flicker.
pub fn probeMediaMetadata(io: std.Io, media: MediaEntry) ?ProbedImageMetadata {
    switch (media) {
        .filesystem => |f| {
            var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, f.path, .{}) catch |err| {
                std.log.warn(
                    "probeMediaMetadata: openFile failed for '{s}': {any}",
                    .{ f.path, err },
                );
                return null;
            };
            defer file.close(io);

            const is_raw_ext = core_fs.isRawFile(f.path);
            var header_buf: [256 * 1024]u8 = undefined;
            const target_read = if (is_raw_ext) header_buf.len else 128 * 1024;
            var slices = [_][]u8{header_buf[0..target_read]};
            const n = file.readPositional(io, &slices, 0) catch |err| {
                std.log.warn(
                    "probeMediaMetadata: readPositional failed for '{s}': {any}",
                    .{ f.path, err },
                );
                return null;
            };
            if (n == 0) return null;

            const mime_type = detectMimeType(header_buf[0..n], f.path);
            var dims = parseImageDimensions(header_buf[0..n], mime_type);
            var rot: Orientation = .normal;
            var has_thumb = false;

            const is_fuji_mime = std.mem.eql(u8, mime_type, "image/x-fuji-raf");
            const is_fuji_magic = n >= 8 and std.mem.startsWith(u8, header_buf[0..n], "FUJIFILM");
            if (is_fuji_mime or is_fuji_magic) {
                const raf_meta = probeFujiRafMetadata(
                    &file,
                    io,
                    header_buf[0..n],
                    dims,
                    f.path,
                );
                dims = raf_meta.dims;
                rot = raf_meta.rot;
                has_thumb = raf_meta.has_thumb;
            } else if (is_raw_ext or std.mem.startsWith(u8, mime_type, "image/x-")) {
                var tail_buf: [16 * 1024]u8 = undefined;
                const file_size: u64 = if (exif.probeTiffIfd0Offset(header_buf[0..n])) |ifd0_off|
                    (if (ifd0_off >= n) file.length(io) catch 0 else 0)
                else
                    0;
                const tiff_source = exif.readTiffSource(
                    io,
                    &file,
                    file_size,
                    header_buf[0..n],
                    &tail_buf,
                );

                rot = exif.parseExifOrientationFromSource(tiff_source) orelse .normal;
                const raw_cands = exif.extractTiffRawPreviewsFromSource(tiff_source);
                if (raw_cands.thumbnail != null or
                    raw_cands.medium != null or
                    raw_cands.preview != null)
                {
                    has_thumb = true;
                }
                if (dims == null) {
                    if (exif.parseExifDimensionsFromSource(tiff_source)) |d| {
                        dims = .{ .w = d.w, .h = d.h };
                    }
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
                .raw_metadata = if (is_raw)
                    RawMetadata.init(final_dims.w, final_dims.h)
                else
                    .none,
                .has_embedded_thumbnail = has_thumb,
            };
        },
        .pair => |p| {
            // Probe companion JPEG header (first 64KB) for visible photograph dimensions,
            // avoiding raw optical black calibration borders.
            var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, p.jpeg_path, .{}) catch |err| {
                std.log.warn(
                    "probeMediaMetadata: openFile failed for pair JPEG '{s}': {any}",
                    .{ p.jpeg_path, err },
                );
                return probeMediaMetadata(io, .{ .filesystem = .{ .path = p.raw_path } });
            };
            defer file.close(io);

            var header_buf: [64 * 1024]u8 = undefined;
            var slices = [_][]u8{&header_buf};
            const n = file.readPositional(io, &slices, 0) catch 0;
            if (n < 4) {
                return probeMediaMetadata(io, .{ .filesystem = .{ .path = p.raw_path } });
            }

            const rot = exif.parseExifOrientation(header_buf[0..n]) orelse .normal;
            const dims = parseImageDimensions(header_buf[0..n], "image/jpeg") orelse {
                return probeMediaMetadata(io, .{ .filesystem = .{ .path = p.raw_path } });
            };

            return ProbedImageMetadata{
                .dims = dims,
                .orientation = rot,
                .raw_metadata = RawMetadata.init(dims.w, dims.h),
                .has_embedded_thumbnail = true,
            };
        },
        .archive_entry => |a| {
            switch (a.seek_info) {
                .indexed => |seek| return probeStoredZipMetadata(io, a, seek),
                .unindexed => return null,
            }
        },
    }
}

/// Extracted thumbnail surface along with orientation, full-resolution dimensions,
/// RAW metadata, and DCT block snapping detection.
pub const ExtractedThumbnail = struct {
    surface: sdl.Surface,
    orientation: Orientation = .normal,
    source_dims: ?state_pkg.PhysicalDims = null,
    raw_metadata: RawMetadata = .none,
    dct_snapped: bool = false,
};

/// Inspects the decoded thumbnail CPU surface to detect whether letterbox (or pillarbox) black bars
/// have been padded and snapped to 8-pixel DCT block boundaries by in-camera preview encoders
/// (e.g. Fujifilm RAF, Ricoh GR IIIx JPEG).
/// Requires candidate DCT boundary lines to be black AND active image content to begin at
/// the 8px boundary.
/// If candidate boundary lines contain image data (e.g. Sony ARW, standard JPEGs) OR if the scene
/// itself is an extended solid black background (e.g. astrophotography), returns false to use
/// theoretical aspect-ratio padding.
pub fn detectThumbnailDctPadding(surf: sdl.Surface, full_w: f32, full_h: f32) bool {
    const sw = surf.w();
    const sh = surf.h();
    if (!std.math.isFinite(full_w) or
        !std.math.isFinite(full_h) or
        full_w <= 0.0 or
        full_h <= 0.0 or
        sw <= 0 or
        sh <= 0)
    {
        return false;
    }

    const thumb_w: f32 = @floatFromInt(sw);
    const thumb_h: f32 = @floatFromInt(sh);
    const ar_full = full_w / full_h;
    const ar_thumb = thumb_w / thumb_h;

    // Matching aspect ratio within epsilon -> no letterboxing or pillarboxing
    if (@abs(ar_full - ar_thumb) <= 0.01) return false;

    const threshold: u8 = 16; // Tolerant to lossy JPEG compression ringing / chroma near boundaries

    if (ar_full > ar_thumb) {
        // Letterboxing: full image is wider than container -> black bars on top and bottom
        const raw_pad_px = (thumb_h - (thumb_w / ar_full)) / 2.0;
        const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;

        if (nearest_block_px > 0.0 and
            nearest_block_px * 2.0 < thumb_h and
            @abs(raw_pad_px - nearest_block_px) <= 2.0)
        {
            const test_row_top: i32 = @intFromFloat(nearest_block_px - 1.0);
            const test_row_bot: i32 = sh - @as(i32, @intFromFloat(nearest_block_px));

            // Candidate DCT padding rows must both be black
            if (surf.isRowBlack(test_row_top, threshold) and
                surf.isRowBlack(test_row_bot, threshold))
            {
                // Verify active image content begins at DCT block boundary (step-transition).
                // If both row 8 and row 111 are ALSO black, the photo has an extended black
                // background; treating continuous black backgrounds as theoretical padding
                // prevents false-positive distortion.
                const first_image_row_top: i32 = @intFromFloat(nearest_block_px);
                const last_image_row_bot: i32 =
                    sh - @as(i32, @intFromFloat(nearest_block_px)) - 1;

                if (!surf.isRowBlack(first_image_row_top, threshold) or
                    !surf.isRowBlack(last_image_row_bot, threshold))
                {
                    return true;
                }
            }
        }
    } else {
        // Pillarboxing: full image is taller than container -> black bars on left and right
        const raw_pad_px = (thumb_w - (thumb_h * ar_full)) / 2.0;
        const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;

        if (nearest_block_px > 0.0 and
            nearest_block_px * 2.0 < thumb_w and
            @abs(raw_pad_px - nearest_block_px) <= 2.0)
        {
            const test_col_left: i32 = @intFromFloat(nearest_block_px - 1.0);
            const test_col_right: i32 = sw - @as(i32, @intFromFloat(nearest_block_px));

            if (surf.isColBlack(test_col_left, threshold) and
                surf.isColBlack(test_col_right, threshold))
            {
                const first_image_col_left: i32 = @intFromFloat(nearest_block_px);
                const last_image_col_right: i32 =
                    sw - @as(i32, @intFromFloat(nearest_block_px)) - 1;

                if (!surf.isColBlack(first_image_col_left, threshold) or
                    !surf.isColBlack(last_image_col_right, threshold))
                {
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
    const max_thumb_size_bytes = 2 * 1024 * 1024;
    if (loc.length == 0 or
        loc.length > max_thumb_size_bytes or
        loc.file_offset +| loc.length > file_size)
    {
        return null;
    }
    const t_len: usize = @intCast(loc.length);
    if (loc.file_offset +| loc.length <= header_slice.len) {
        const t_off: usize = @intCast(loc.file_offset);
        return sdl.Surface.loadConstMemOpt(header_slice[t_off .. t_off + t_len]);
    }
    const t_buf = alloc.alloc(u8, t_len) catch |err| {
        std.log.warn("loadThumbnailFromLocation: alloc failed ({d} bytes): {any}", .{ t_len, err });
        return null;
    };
    defer alloc.free(t_buf);
    var ts_slices = [_][]u8{t_buf};
    const tn = file.readPositional(io, &ts_slices, loc.file_offset) catch |err| {
        std.log.warn("loadThumbnailFromLocation: readPositional failed: {any}", .{err});
        return null;
    };
    if (tn == t_len) {
        return sdl.Surface.loadConstMemOpt(t_buf);
    }
    return null;
}

fn loadStoredZipThumbnail(
    io: std.Io,
    a: ArchiveMediaEntry,
    seek: ZipSeekOffsets,
) ?ExtractedThumbnail {
    if (seek.compression_method != .store) return null;

    var file = std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        a.archive_path,
        .{},
    ) catch |err| {
        std.log.warn(
            "loadThumbnailSurface: openFile failed for '{s}': {any}",
            .{ a.archive_path, err },
        );
        return null;
    };
    defer file.close(io);

    var header_buf: [128 * 1024]u8 = undefined;
    var slices = [_][]u8{&header_buf};
    const n = file.readPositional(
        io,
        &slices,
        seek.file_offset,
    ) catch |err| {
        std.log.warn(
            "loadThumbnailSurface: readPositional failed for '{s}': {any}",
            .{ a.archive_path, err },
        );
        return null;
    };
    if (n == 0) return null;

    var data_offset: usize = 0;
    if (n >= @sizeOf(std.zip.LocalFileHeader) and
        std.mem.eql(u8, header_buf[0..4], &std.zip.local_file_header_sig))
    {
        const filename_len = std.mem.readInt(u16, header_buf[26..28], .little);
        const extra_len = std.mem.readInt(u16, header_buf[28..30], .little);
        data_offset = @sizeOf(std.zip.LocalFileHeader) +
            @as(usize, filename_len) +
            @as(usize, extra_len);
    }
    if (n <= data_offset) return null;

    const image_slice = header_buf[data_offset..n];
    const mime_type = detectMimeType(image_slice, a.entry_name);
    if (!std.mem.eql(u8, mime_type, "image/jpeg")) return null;

    const loc = exif.extractJpegThumbnailLocation(image_slice) orelse
        return null;
    if (loc.file_offset +| loc.length > image_slice.len) return null;
    const off: usize = @intCast(loc.file_offset);
    const len: usize = @intCast(loc.length);

    const surf = sdl.Surface.loadConstMemOpt(
        image_slice[off .. off + len],
    ) orelse return null;

    const orientation = exif.parseExifOrientation(image_slice) orelse .normal;
    const dims = parseImageDimensions(image_slice, mime_type);
    const source_dims = if (dims) |d|
        state_pkg.PhysicalDims.initPositive(d.w, d.h)
    else
        null;
    const dct_snapped = if (source_dims) |sd|
        detectThumbnailDctPadding(surf, sd.w, sd.h)
    else
        false;

    return ExtractedThumbnail{
        .surface = surf,
        .orientation = orientation,
        .source_dims = source_dims,
        .raw_metadata = .none,
        .dct_snapped = dct_snapped,
    };
}

const FujiRafThumbnailInfo = struct {
    raw_dims: ?state_pkg.PhysicalDims = null,
    orientation: Orientation = .normal,
    thumb_loc: ?exif.ThumbnailLocation = null,
};

fn resolveFujiRafThumbnail(
    file: *std.Io.File,
    io: std.Io,
    header_slice: []const u8,
    file_size: u64,
    path: []const u8,
) FujiRafThumbnailInfo {
    var info = FujiRafThumbnailInfo{};
    const header_n = header_slice.len;
    const prev_loc_opt = exif.extractFujiRafPreviewLocation(header_slice);

    if (exif.extractFujiRafMetadataLocation(header_slice)) |meta_loc| {
        if (meta_loc.file_offset +| meta_loc.length <= header_n) {
            const end = meta_loc.file_offset + meta_loc.length;
            const meta_slice =
                header_slice[@intCast(meta_loc.file_offset)..@intCast(end)];
            if (exif.parseFujiRafDimensions(meta_slice)) |fd| {
                info.raw_dims = state_pkg.PhysicalDims.initPositive(
                    fd.w,
                    fd.h,
                );
            }
        } else if (meta_loc.length > 0 and
            meta_loc.length <= 64 * 1024 and
            meta_loc.file_offset +| meta_loc.length <= file_size)
        {
            var m_buf: [64 * 1024]u8 = undefined;
            var m_slices = [_][]u8{m_buf[0..meta_loc.length]};
            const mn = file.readPositional(
                io,
                &m_slices,
                meta_loc.file_offset,
            ) catch |err| blk: {
                std.log.warn(
                    "loadThumbnailSurface: Fuji RAF metadata readPositional " ++
                        "failed for '{s}': {any}",
                    .{ path, err },
                );
                break :blk 0;
            };
            if (mn >= meta_loc.length) {
                const m_data = m_buf[0..meta_loc.length];
                if (exif.parseFujiRafDimensions(m_data)) |fd| {
                    info.raw_dims = state_pkg.PhysicalDims.initPositive(
                        fd.w,
                        fd.h,
                    );
                }
            }
        }
    }

    if (prev_loc_opt) |prev_loc| {
        if (prev_loc.file_offset +| 4096 <= header_n) {
            const off: usize = @intCast(prev_loc.file_offset);
            const h_sub = header_slice[off..header_n];
            info.orientation = exif.parseExifOrientation(h_sub) orelse .normal;
            if (exif.extractJpegThumbnailLocation(h_sub)) |j_thumb| {
                info.thumb_loc = .{
                    .file_offset = prev_loc.file_offset +|
                        j_thumb.file_offset,
                    .length = j_thumb.length,
                };
            }
        } else {
            var p_hdr: [8192]u8 = undefined;
            var p_slices = [_][]u8{&p_hdr};
            const pn = file.readPositional(
                io,
                &p_slices,
                prev_loc.file_offset,
            ) catch |err| blk: {
                std.log.warn(
                    "loadThumbnailSurface: Fuji RAF preview readPositional " ++
                        "failed for '{s}': {any}",
                    .{ path, err },
                );
                break :blk 0;
            };
            if (pn > 0) {
                info.orientation =
                    exif.parseExifOrientation(p_hdr[0..pn]) orelse .normal;
                if (exif.extractJpegThumbnailLocation(p_hdr[0..pn])) |j_thumb| {
                    info.thumb_loc = .{
                        .file_offset = prev_loc.file_offset +|
                            j_thumb.file_offset,
                        .length = j_thumb.length,
                    };
                }
            }
        }
    }

    return info;
}

/// Extracts the embedded preview thumbnail surface and orientation metadata for a media entry.
/// Supports Camera RAW formats (.arw, .raf, .cr2, .nef, .dng, .orf, .rw2, .pef), standard JPEGs,
/// and CBZ entries.
pub fn loadThumbnailSurface(
    io: std.Io,
    alloc: std.mem.Allocator,
    media: MediaEntry,
) ?ExtractedThumbnail {
    switch (media) {
        .filesystem => |f| {
            var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, f.path, .{}) catch |err| {
                std.log.warn(
                    "loadThumbnailSurface: openFile failed for '{s}': {any}",
                    .{ f.path, err },
                );
                return null;
            };
            defer file.close(io);

            const file_size = file.length(io) catch |err| {
                std.log.warn(
                    "loadThumbnailSurface: length failed for '{s}': {any}",
                    .{ f.path, err },
                );
                return null;
            };
            const is_raw_ext = core_fs.isRawFile(f.path);
            var header_buf: [256 * 1024]u8 = undefined;
            const target_read = if (is_raw_ext) header_buf.len else 128 * 1024;
            var slices = [_][]u8{header_buf[0..target_read]};
            const header_n = file.readPositional(io, &slices, 0) catch |err| {
                std.log.warn(
                    "loadThumbnailSurface: readPositional failed for '{s}': {any}",
                    .{ f.path, err },
                );
                return null;
            };
            if (header_n == 0) return null;
            const header_slice = header_buf[0..header_n];

            const mime_type = detectMimeType(header_slice, f.path);
            const is_raw = core_fs.isRawFile(f.path) or
                std.mem.startsWith(u8, mime_type, "image/x-");
            const is_fuji = std.mem.eql(u8, mime_type, "image/x-fuji-raf") or
                (header_n >= 8 and std.mem.startsWith(u8, header_slice, "FUJIFILM"));

            var thumb_surf: ?sdl.Surface = null;
            var orientation: Orientation = .normal;
            var source_dims: ?state_pkg.PhysicalDims = null;

            if (is_fuji) {
                const fuji_info = resolveFujiRafThumbnail(
                    &file,
                    io,
                    header_slice,
                    file_size,
                    f.path,
                );
                source_dims = fuji_info.raw_dims;
                orientation = fuji_info.orientation;

                if (fuji_info.thumb_loc) |tloc| {
                    thumb_surf = loadThumbnailFromLocation(
                        io,
                        alloc,
                        &file,
                        file_size,
                        header_slice,
                        tloc,
                    );
                }
            } else if (is_raw) {
                var tail_buf: [16 * 1024]u8 = undefined;
                const tiff_source = exif.readTiffSource(
                    io,
                    &file,
                    file_size,
                    header_slice,
                    &tail_buf,
                );

                const raw_cands = exif.extractTiffRawPreviewsFromSource(tiff_source);
                if (exif.parseExifDimensionsFromSource(tiff_source)) |dims| {
                    source_dims = state_pkg.PhysicalDims.initPositive(
                        dims.w,
                        dims.h,
                    );
                }
                orientation = exif.parseExifOrientationFromSource(tiff_source) orelse .normal;
                if (raw_cands.thumbnail orelse raw_cands.medium) |tloc| {
                    thumb_surf = loadThumbnailFromLocation(
                        io,
                        alloc,
                        &file,
                        file_size,
                        header_slice,
                        tloc,
                    );
                }
            } else if (std.mem.eql(u8, mime_type, "image/jpeg")) {
                orientation = exif.parseExifOrientation(header_slice) orelse .normal;
                if (parseImageDimensions(header_slice, mime_type)) |dims| {
                    source_dims = state_pkg.PhysicalDims.initPositive(
                        dims.w,
                        dims.h,
                    );
                }
                if (exif.extractJpegThumbnailLocation(header_slice)) |loc| {
                    thumb_surf = loadThumbnailFromLocation(
                        io,
                        alloc,
                        &file,
                        file_size,
                        header_slice,
                        loc,
                    );
                }
            }

            const surf = thumb_surf orelse return null;
            const dct_snapped = if (source_dims) |sd|
                detectThumbnailDctPadding(surf, sd.w, sd.h)
            else
                false;
            return ExtractedThumbnail{
                .surface = surf,
                .orientation = orientation,
                .source_dims = source_dims,
                .raw_metadata = if (is_raw)
                    (if (source_dims) |sd|
                        RawMetadata.init(sd.w, sd.h)
                    else
                        .none)
                else
                    .none,
                .dct_snapped = dct_snapped,
            };
        },
        .archive_entry => |a| {
            switch (a.seek_info) {
                .indexed => |seek| return loadStoredZipThumbnail(io, a, seek),
                .unindexed => return null,
            }
        },
        .pair => |p| {
            return loadThumbnailSurface(io, alloc, .{ .filesystem = .{ .path = p.raw_path } });
        },
    }
}

/// Reusable GPU staging buffers for texture uploads, eliminating allocation and deallocation
/// churn on every frame by retaining and geometrically growing transfer and storage buffers.
///
/// TODO: Add heuristics to periodically evaluate and shrink retained staging buffers after
/// a duration/inactivity threshold (or high-water decay) so memory is reclaimed if a single
/// exceptionally large image temporarily expanded capacity.
pub const UploadStagingBuffer = struct {
    transfer: sdl.gpu.RetainedTransferBuffer = .unallocated,
    storage: sdl.gpu.RetainedBuffer = .unallocated,

    /// Releases retained GPU transfer and compute storage buffers.
    pub fn deinit(self: *UploadStagingBuffer, dev: sdl.gpu.Device) void {
        switch (self.transfer) {
            .unallocated => {},
            .allocated => |a| {
                dev.releaseTransferBuffer(a.handle);
                self.transfer = .unallocated;
            },
        }
        switch (self.storage) {
            .unallocated => {},
            .allocated => |a| {
                dev.releaseBuffer(a.handle);
                self.storage = .unallocated;
            },
        }
    }

    /// Obtains a transfer buffer with at least `required_size` capacity, reusing the
    /// existing buffer or reallocating with geometric growth when capacity is insufficient.
    fn getOrCreateTransferBuffer(
        self: *UploadStagingBuffer,
        dev: sdl.gpu.Device,
        required_size: usize,
    ) ?sdl.gpu.TransferBuffer {
        const growth_cap = switch (self.transfer) {
            .allocated => |a| blk: {
                if (a.capacity >= required_size) return a.handle;
                dev.releaseTransferBuffer(a.handle);
                self.transfer = .unallocated;
                break :blk a.capacity * 2;
            },
            .unallocated => 4 * 1024 * 1024,
        };
        const next_cap = @max(required_size, growth_cap);
        const aligned_cap = std.mem.alignForward(usize, next_cap, 4 * 1024);

        const tb = dev.createTransferBuffer(&sdl.gpu.TransferBufferCreateInfo{
            .usage = .upload,
            .size = @intCast(aligned_cap),
            .props = 0,
        }) orelse return null;
        self.transfer = .{
            .allocated = .{ .handle = tb, .capacity = aligned_cap },
        };
        return tb;
    }

    /// Obtains a compute storage buffer with at least `required_size` capacity, reusing the
    /// existing buffer or reallocating with geometric growth when capacity is insufficient.
    fn getOrCreateStorageBuffer(
        self: *UploadStagingBuffer,
        dev: sdl.gpu.Device,
        required_size: usize,
    ) ?sdl.gpu.Buffer {
        const growth_cap = switch (self.storage) {
            .allocated => |a| blk: {
                if (a.capacity >= required_size) return a.handle;
                dev.releaseBuffer(a.handle);
                self.storage = .unallocated;
                break :blk a.capacity * 2;
            },
            .unallocated => 4 * 1024 * 1024,
        };
        const next_cap = @max(required_size, growth_cap);
        const aligned_cap = std.mem.alignForward(usize, next_cap, 4 * 1024);

        const sb = dev.createBuffer(&sdl.gpu.BufferCreateInfo{
            .usage = sdl.gpu.BufferUsage.compute_storage_read,
            .size = @intCast(aligned_cap),
            .props = 0,
        }) orelse return null;
        self.storage = .{
            .allocated = .{ .handle = sb, .capacity = aligned_cap },
        };
        return sb;
    }
};

/// Result payload containing the created GPU texture, dimensions, upload timing telemetry,
/// and VRAM memory footprint.
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

/// Computes the mipmap pyramid level count for a 2D texture of size `w` x `h`.
fn computeMipLevels(w: i32, h: i32) u32 {
    const max_dim_u: u32 = @intCast(@max(1, @max(w, h)));
    return if (max_dim_u > 1)
        @intCast(std.math.log2(max_dim_u) + 1)
    else
        1;
}

/// Aspect-preserving dimensions and mipmap level count for fallback scaling.
const FallbackScaleDims = struct {
    w: i32,
    h: i32,
    num_levels: u32,
};

/// Computes aspect-preserving fallback dimensions and mipmap levels when a
/// surface exceeds `try_max_dim`. Returns `null` if both dimensions fit.
fn computeFallbackScaleDims(
    img_w: i32,
    img_h: i32,
    try_max_dim: i32,
) ?FallbackScaleDims {
    if (img_w <= 0 or img_h <= 0 or try_max_dim <= 0) return null;
    if (img_w <= try_max_dim and img_h <= try_max_dim) return null;
    var new_w = img_w;
    var new_h = img_h;
    if (img_w > img_h) {
        new_w = try_max_dim;
        new_h = @intCast(@divTrunc(
            @as(i64, img_h) * @as(i64, try_max_dim),
            @as(i64, img_w),
        ));
    } else {
        new_h = try_max_dim;
        new_w = @intCast(@divTrunc(
            @as(i64, img_w) * @as(i64, try_max_dim),
            @as(i64, img_h),
        ));
    }
    new_w = @max(1, new_w);
    new_h = @max(1, new_h);
    return .{
        .w = new_w,
        .h = new_h,
        .num_levels = computeMipLevels(new_w, new_h),
    };
}

/// Copies or converts `current_surf` into a tightly packed 32-bit `mapped`
/// transfer buffer of size `dst_pitch * u_h`, returning conversion time in ms.
fn stageSurfaceToRgba32(
    current_surf: sdl.Surface,
    mapped: []u8,
    u_w: usize,
    u_h: usize,
    dst_pitch: usize,
    cur_fmt: u32,
) ?f64 {
    const size = dst_pitch * u_h;
    const src_pixels: [*]const u8 = current_surf.pixels();
    const src_pitch: usize = @intCast(current_surf.pitch());
    var conversion_time_ms: f64 = 0.0;
    const is_32bit_fmt = switch (cur_fmt) {
        sdl.PixelFormat.rgba32,
        sdl.PixelFormat.bgra32,
        sdl.PixelFormat.xrgb8888,
        sdl.PixelFormat.xbgr8888,
        sdl.PixelFormat.rgbx8888,
        sdl.PixelFormat.bgrx8888,
        => true,
        else => false,
    };
    if (is_32bit_fmt) {
        if (src_pitch == dst_pitch) {
            @memcpy(mapped[0..size], src_pixels[0..size]);
        } else {
            var y: usize = 0;
            while (y < u_h) : (y += 1) {
                const row_len = u_w * 4;
                @memcpy(
                    mapped[y * dst_pitch .. y * dst_pitch + row_len],
                    src_pixels[y * src_pitch .. y * src_pitch + row_len],
                );
            }
        }
    } else if (cur_fmt == sdl.PixelFormat.rgb24) {
        // NOTE: If the GPU compute unpack pipeline is unavailable, RGB24/BGR24
        // falls back to main-thread SIMD conversion here. Plumbing
        // `has_compute_unpack: bool` through DecodeArgs can offload this to
        // background decode workers if this log appears in practice.
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertRgb24ToRgba32Simd(
            src_pixels[0 .. src_pitch * u_h],
            mapped[0..size],
            u_w,
            u_h,
            src_pitch,
            dst_pitch,
        );
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms =
            @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
        std.log.info(
            "main-thread RGB24 conversion ({d}x{d}) took {d:.2}ms",
            .{ u_w, u_h, conversion_time_ms },
        );
    } else if (cur_fmt == sdl.PixelFormat.bgr24) {
        const start_conv = sdl.timer.getTicksNs();
        sdl.surface.convertBgr24ToRgba32Simd(
            src_pixels[0 .. src_pitch * u_h],
            mapped[0..size],
            u_w,
            u_h,
            src_pitch,
            dst_pitch,
        );
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms =
            @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
        std.log.info(
            "main-thread BGR24 conversion ({d}x{d}) took {d:.2}ms",
            .{ u_w, u_h, conversion_time_ms },
        );
    } else {
        const start_conv = sdl.timer.getTicksNs();
        const tmp_surf = current_surf.convert(sdl.PixelFormat.rgba32) orelse
            return null;
        defer tmp_surf.destroy();
        const ts_pixels = tmp_surf.pixels();
        const ts_pitch: usize = @intCast(tmp_surf.pitch());
        if (ts_pitch == dst_pitch) {
            @memcpy(mapped[0..size], ts_pixels[0..size]);
        } else {
            var y: usize = 0;
            while (y < u_h) : (y += 1) {
                const row_len = u_w * 4;
                @memcpy(
                    mapped[y * dst_pitch .. y * dst_pitch + row_len],
                    ts_pixels[y * ts_pitch .. y * ts_pitch + row_len],
                );
            }
        }
        const end_conv = sdl.timer.getTicksNs();
        conversion_time_ms =
            @as(f64, @floatFromInt(end_conv - start_conv)) / 1_000_000.0;
    }
    return conversion_time_ms;
}

fn computeTextureVramBytes(u_w: usize, u_h: usize, num_levels: u32) usize {
    const base_bytes: usize = u_w * u_h * 4;
    return if (num_levels > 1) (base_bytes * 4) / 3 else base_bytes;
}

/// Uploads a CPU surface into an SDL GPU texture with automatic mipmap pyramid generation,
/// using an optional compute pipeline for fast RGB24/BGR24 unpack and optional staging
/// buffer reuse.
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
        sdl.PixelFormat.bgra32,
        sdl.PixelFormat.xrgb8888,
        sdl.PixelFormat.bgrx8888,
        => .bgra8_unorm,
        sdl.PixelFormat.rgba32,
        sdl.PixelFormat.xbgr8888,
        sdl.PixelFormat.rgbx8888,
        => .rgba8_unorm,
        else => .rgba8_unorm,
    };

    var scaled_surf: ?sdl.Surface = null;
    defer if (scaled_surf) |s| s.destroy();

    var img_w = current_surf.w();
    var img_h = current_surf.h();
    if (img_w <= 0 or img_h <= 0) return null;
    var tex: ?sdl.gpu.Texture = null;
    var num_levels: u32 = computeMipLevels(img_w, img_h);
    var was_fallback: bool = false;
    var fallback_time_ms: f64 = 0.0;

    const comp_pipeline_opt: ?sdl.gpu.ComputePipeline =
        if (src_fmt == sdl.PixelFormat.rgb24 or
        src_fmt == sdl.PixelFormat.bgr24)
            comp_pipeline
        else
            null;

    var tex_usage =
        sdl.gpu.TextureUsage.sampler | sdl.gpu.TextureUsage.color_target;
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
            if (computeFallbackScaleDims(img_w, img_h, try_max_dim)) |fb| {
                const new_scale = current_surf.scale(fb.w, fb.h, .linear);
                if (new_scale) |ns| {
                    if (scaled_surf) |s| s.destroy();
                    scaled_surf = ns;
                    current_surf = ns;
                    img_w = fb.w;
                    img_h = fb.h;
                    num_levels = fb.num_levels;

                    img_tex_info.width = @intCast(img_w);
                    img_tex_info.height = @intCast(img_h);
                    img_tex_info.num_levels = num_levels;
                    tex = dev.createTexture(&img_tex_info);
                    if (tex != null) break;
                } else {
                    std.log.err(
                        "uploadSurfaceToGpu: SDL_ScaleSurface failed: {s}",
                        .{sdl.getError()},
                    );
                    break;
                }
            }
        }
        const end_fb = sdl.timer.getTicksNs();
        fallback_time_ms =
            @as(f64, @floatFromInt(end_fb - start_fb)) / 1_000_000.0;
    }

    const gpu_tex = tex orelse return null;
    const u_w: usize = @intCast(img_w);
    const u_h: usize = @intCast(img_h);
    const cur_fmt = current_surf.format();

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
        // Cycle `storage_buf` when shared across staged uploads (`is_staged`)
        // to avoid GPU WAR/WAW hazards with in-flight compute unpack passes.
        copy_pass.uploadToBuffer(&sdl.gpu.TransferBufferLocation{
            .transfer_buffer = transfer_buf,
            .offset = 0,
        }, &sdl.gpu.BufferRegion{
            .buffer = storage_buf,
            .offset = 0,
            .size = @intCast(raw_bytes_len),
        }, is_staged);
        copy_pass.end();

        const compute_pass = cmd_wrapper.beginComputePass(
            &[_]sdl.gpu.StorageTextureReadWriteBinding{.{
                .texture = gpu_tex,
                .mip_level = 0,
                .layer = 0,
                .cycle = false,
            }},
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
            mipmap_time_ms =
                @as(f64, @floatFromInt(end_mip - start_mip)) / 1_000_000.0;
        }

        _ = cmd_wrapper.submit();

        const end_upload = sdl.timer.getTicksNs();
        const upload_time_ms =
            @as(f64, @floatFromInt(end_upload - start_upload)) / 1_000_000.0;

        const memory_size_bytes = computeTextureVramBytes(
            u_w,
            u_h,
            num_levels,
        );

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

    const conversion_time_ms = stageSurfaceToRgba32(
        current_surf,
        mapped[0..size],
        u_w,
        u_h,
        dst_pitch,
        cur_fmt,
    ) orelse {
        dev.unmapTransferBuffer(transfer_buf);
        _ = cmd_wrapper.cancel();
        dev.releaseTexture(gpu_tex);
        return null;
    };

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

    const memory_size_bytes = computeTextureVramBytes(
        u_w,
        u_h,
        num_levels,
    );

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
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const MockNav = struct {
        pub fn posOfId(_: @This(), id: MediaId) ?usize {
            if (!id.isValid()) return null;
            return id.toU32() - 1;
        }
        pub fn getIdAt(_: @This(), idx: usize) ?MediaId {
            return MediaId.fromU32(@intCast(idx + 1));
        }
    };
    const mock_nav = MockNav{};

    const makeGpuEntry = struct {
        fn create(size: usize) CacheEntry {
            return .{
                .resident = .{
                    .asset = .{
                        .loaded_gpu = .{
                            .gpu_texture = undefined,
                            .w = 100,
                            .h = 100,
                            .size_bytes = size,
                            .memory_size_bytes = size,
                        },
                    },
                },
            };
        }
    }.create;

    const n10 = state_pkg.VisibleNeighbors.fromRawIndex(0, 10);

    // total_items = 10, current = 0
    // Slots: 0 (dist 0), 1 (dist 1), 2 (dist 2), 5 (dist 5), 9 (dist 1 wrap)
    _ = try cache.appendSlot(
        allocator,
        mock_nav.getIdAt(0).?,
        makeGpuEntry(100),
    );
    _ = try cache.appendSlot(
        allocator,
        mock_nav.getIdAt(1).?,
        makeGpuEntry(100),
    );
    _ = try cache.appendSlot(
        allocator,
        mock_nav.getIdAt(2).?,
        makeGpuEntry(100),
    );
    _ = try cache.appendSlot(
        allocator,
        mock_nav.getIdAt(5).?,
        makeGpuEntry(100),
    );
    _ = try cache.appendSlot(
        allocator,
        mock_nav.getIdAt(9).?,
        makeGpuEntry(100),
    );
    // Total VRAM = 500 bytes

    try std.testing.expectEqual(@as(usize, 500), cache.getTotalVramBytes());

    // 1. Evict down to 400: slot 5 (dist 5) is distant (dist > 2)
    cache.enforceVramBudget(null, mock_nav, n10, null, 10, 400);
    try std.testing.expectEqual(@as(usize, 400), cache.getTotalVramBytes());
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(5).?)) == null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(0).?)) != null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(1).?)) != null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(2).?)) != null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(9).?)) != null,
    );

    // 2. Evict down to 300: Remaining are 0, 1, 2, 9 (dists: 0, 1, 2, 1).
    // Neighbor protection should evict dist 2 (slot 2) before dist 1.
    cache.enforceVramBudget(null, mock_nav, n10, null, 10, 300);
    try std.testing.expectEqual(@as(usize, 300), cache.getTotalVramBytes());
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(2).?)) == null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(0).?)) != null,
    );

    // 3. Evict down to 50: Current slot 0 (100 bytes) should NEVER be evicted
    cache.enforceVramBudget(null, mock_nav, n10, null, 10, 50);
    try std.testing.expectEqual(@as(usize, 100), cache.getTotalVramBytes());
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(0).?)) != null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(1).?)) == null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(9).?)) == null,
    );

    // 4. Test robustness against linear_dist > total_items
    const n5 = state_pkg.VisibleNeighbors.fromRawIndex(0, 5);
    _ = try cache.appendSlot(
        allocator,
        mock_nav.getIdAt(99).?,
        makeGpuEntry(100),
    );
    try std.testing.expectEqual(@as(usize, 200), cache.getTotalVramBytes());
    cache.enforceVramBudget(null, mock_nav, n5, null, 5, 100);
    try std.testing.expectEqual(@as(usize, 100), cache.getTotalVramBytes());
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(99).?)) == null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(0).?)) != null,
    );

    // 5. Slideshow protected_prev_index guard: both current (slot 0) and
    // protected prev (slot 3) must be retained
    _ = try cache.appendSlot(
        allocator,
        mock_nav.getIdAt(3).?,
        makeGpuEntry(100),
    );
    _ = try cache.appendSlot(
        allocator,
        mock_nav.getIdAt(4).?,
        makeGpuEntry(100),
    );
    try std.testing.expectEqual(@as(usize, 300), cache.getTotalVramBytes());
    cache.enforceVramBudget(null, mock_nav, n10, 3, 10, 50);
    try std.testing.expectEqual(@as(usize, 200), cache.getTotalVramBytes());
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(0).?)) != null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(3).?)) != null,
    );
    try std.testing.expect(
        cache.getIndex(cache.activeKey(mock_nav.getIdAt(4).?)) == null,
    );
}

test "hasUnreadyPrefetchSlots" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const MockNav = struct {
        pub fn posOfId(_: @This(), id: MediaId) ?usize {
            if (!id.isValid()) return null;
            return id.toU32() - 1;
        }
        pub fn getIdAt(_: @This(), idx: usize) ?MediaId {
            return MediaId.fromU32(@intCast(idx + 1));
        }
    };
    const mock_nav = MockNav{};

    const n5 = state_pkg.VisibleNeighbors.fromRawIndex(0, 5);

    // Total 5 items, current 0 -> desired: 0, 1, 2, 4, 3
    // Empty cache -> unready
    try std.testing.expect(cache.hasUnreadyPrefetchSlots(mock_nav, n5, true));

    const makeGpuEntry = CacheEntry{
        .resident = .{
            .asset = .{
                .loaded_gpu = .{
                    .gpu_texture = undefined,
                    .w = 100,
                    .h = 100,
                    .size_bytes = 100,
                    .memory_size_bytes = 100,
                },
            },
        },
    };

    // Add 0, 1, 2, 3, 4 as loaded_gpu
    for (0..5) |idx| {
        _ = try cache.appendSlot(
            allocator,
            mock_nav.getIdAt(idx).?,
            makeGpuEntry,
        );
    }
    try std.testing.expect(!cache.hasUnreadyPrefetchSlots(mock_nav, n5, true));

    // One slot is decoding -> unready
    cache.setInFlight(
        cache.activeKey(mock_nav.getIdAt(2).?),
        .{ .stage = .decoding },
    );
    try std.testing.expect(cache.hasUnreadyPrefetchSlots(mock_nav, n5, true));

    // One slot is loaded_cpu: unready if has_gpu = true, ready if has_gpu = false
    const surf = sdl.Surface.create(1, 1, sdl.PixelFormat.rgba32) orelse return;
    cache.setInFlight(cache.activeKey(mock_nav.getIdAt(2).?), null);
    cache.setResidentAsset(cache.activeKey(mock_nav.getIdAt(2).?), .{
        .loaded_cpu = .{
            .surface = surf,
            .w = 100,
            .h = 100,
            .size_bytes = 100,
        },
    }, null);
    try std.testing.expect(cache.hasUnreadyPrefetchSlots(mock_nav, n5, true));
    try std.testing.expect(!cache.hasUnreadyPrefetchSlots(mock_nav, n5, false));

    // Reset status to .failed to prevent calling SDL_DestroySurface on
    // undefined mock surface during defer deinit
    cache.setResidentAsset(
        cache.activeKey(mock_nav.getIdAt(2).?),
        .failed,
        null,
    );
}

test "ImageCache.setResidentAsset and setInFlight" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const id10 = MediaId.fromU32(10);
    const id20 = MediaId.fromU32(20);

    _ = cache.advanceGeneration();
    _ = try cache.appendSlot(allocator, id10, .{
        .inflight = .{ .stage = .decoding },
    });
    _ = try cache.appendSlot(allocator, id20, .{
        .inflight = .{ .stage = .decoding },
    });

    // Test updating resident asset and in-flight status
    const key20 = ImageCacheKey{ .id = id20, .generation = 1 };
    cache.setResidentAsset(key20, .failed, null);
    cache.setInFlight(key20, null);

    try std.testing.expectEqual(
        ResidentAsset.failed,
        cache.slots.items(.entry)[1].resident.asset,
    );
    try std.testing.expectEqual(
        @as(?InFlightDecode, null),
        cache.slots.items(.entry)[1].inflight,
    );
}

test "UploadStagingBuffer - capacity growth and clean deinit" {
    var staging = UploadStagingBuffer{};
    try std.testing.expect(staging.transfer == .unallocated);
    try std.testing.expect(staging.storage == .unallocated);

    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    // Initial allocation should be at least 4MB aligned to 4KB
    const tb1 = staging.getOrCreateTransferBuffer(dev, 1024);
    try std.testing.expect(tb1 != null);
    try std.testing.expectEqual(
        @as(usize, 4 * 1024 * 1024),
        staging.transfer.allocated.capacity,
    );

    // Reuse existing buffer when required_size <= transfer_capacity
    const tb2 = staging.getOrCreateTransferBuffer(dev, 2 * 1024 * 1024);
    try std.testing.expect(tb2 != null);
    try std.testing.expectEqual(
        @as(usize, 4 * 1024 * 1024),
        staging.transfer.allocated.capacity,
    );

    // Reallocation with geometric growth (4MB -> 8MB) when required exceeds capacity
    const tb3 = staging.getOrCreateTransferBuffer(dev, 5 * 1024 * 1024);
    try std.testing.expect(tb3 != null);
    try std.testing.expectEqual(
        @as(usize, 8 * 1024 * 1024),
        staging.transfer.allocated.capacity,
    );

    // Storage buffer test
    const sb1 = staging.getOrCreateStorageBuffer(dev, 1024);
    try std.testing.expect(sb1 != null);
    try std.testing.expectEqual(
        @as(usize, 4 * 1024 * 1024),
        staging.storage.allocated.capacity,
    );

    // Deinit releases all buffers and resets capacities
    staging.deinit(dev);
    try std.testing.expect(staging.transfer == .unallocated);
    try std.testing.expect(staging.storage == .unallocated);
}

test "uploadSurfaceToGpu - staging buffer reuse across consecutive uploads" {
    const dev_opt = sdl.gpu.Device.create(
        sdl.gpu.ShaderFormat.spirv | sdl.gpu.ShaderFormat.msl,
        true,
    );
    const dev = dev_opt orelse return;
    defer dev.destroy();

    var staging = UploadStagingBuffer{};
    defer staging.deinit(dev);

    const surf1 = sdl.Surface.create(64, 64, sdl.PixelFormat.rgba32) orelse
        return;
    defer surf1.destroy();

    const res1 = uploadSurfaceToGpu(dev, surf1, null, &staging);
    try std.testing.expect(res1 != null);
    if (res1) |r| {
        dev.releaseTexture(r.gpu_texture);
        try std.testing.expectEqual(@as(f32, 64.0), r.w);
        try std.testing.expectEqual(@as(f32, 64.0), r.h);
    }

    try std.testing.expect(staging.transfer == .allocated);
    const cap1 = staging.transfer.allocated.capacity;
    try std.testing.expect(cap1 >= 64 * 64 * 4);

    // Second upload should reuse staging transfer buffer without reallocating
    const surf2 = sdl.Surface.create(32, 32, sdl.PixelFormat.rgba32) orelse
        return;
    defer surf2.destroy();

    const res2 = uploadSurfaceToGpu(dev, surf2, null, &staging);
    try std.testing.expect(res2 != null);
    if (res2) |r| {
        dev.releaseTexture(r.gpu_texture);
        try std.testing.expectEqual(@as(f32, 32.0), r.w);
        try std.testing.expectEqual(@as(f32, 32.0), r.h);
    }

    try std.testing.expectEqual(cap1, staging.transfer.allocated.capacity);
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
    try std.testing.expectEqual(
        @as(?ProbedImageMetadata, null),
        probeMediaMetadata(io, media),
    );
}

test "probeMediaMetadata - archive entry handling" {
    const io = std.Io.Threaded.global_single_threaded.io();

    // Compressed ZIP entry returns null
    const media_comp = MediaEntry{
        .archive_entry = .{
            .archive_path = "testfiles/images/000_0_1024x682.jpg",
            .entry_name = "test.jpg",
            .seek_info = .{
                .indexed = .{
                    .header_zip_offset = 0,
                    .file_offset = 0,
                    .uncompressed_size = 1000,
                    .compression_method = .deflate,
                },
            },
        },
    };
    try std.testing.expectEqual(
        @as(?ProbedImageMetadata, null),
        probeMediaMetadata(io, media_comp),
    );

    // Unindexed entry returns null
    const media_unindexed = MediaEntry{
        .archive_entry = .{
            .archive_path = "testfiles/images/000_0_1024x682.jpg",
            .entry_name = "test.jpg",
            .seek_info = .unindexed,
        },
    };
    try std.testing.expectEqual(
        @as(?ProbedImageMetadata, null),
        probeMediaMetadata(io, media_unindexed),
    );

    // Uncompressed entry with valid offset
    const media_stored = MediaEntry{
        .archive_entry = .{
            .archive_path = "testfiles/images/000_0_1024x682.jpg",
            .entry_name = "test.jpg",
            .seek_info = .{
                .indexed = .{
                    .header_zip_offset = 0,
                    .file_offset = 0,
                    .uncompressed_size = 1000,
                    .compression_method = .store,
                },
            },
        },
    };
    const meta = probeMediaMetadata(io, media_stored);
    try std.testing.expect(meta != null);
    if (meta) |m| {
        try std.testing.expectEqual(@as(f32, 1024.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), m.dims.h);
    }
}

test "ImageCache - atomic generation advance and activeKey" {
    var cache = ImageCache{};
    const id0 = MediaId.fromU32(1);
    const id5 = MediaId.fromU32(5);
    try std.testing.expectEqual(@as(usize, 0), cache.activeKey(id0).generation);
    const next_gen = cache.advanceGeneration();
    try std.testing.expectEqual(@as(usize, 1), next_gen);
    try std.testing.expectEqual(@as(usize, 1), cache.activeKey(id0).generation);
    const key = cache.activeKey(id5);
    try std.testing.expectEqual(id5, key.id);
    try std.testing.expectEqual(@as(usize, 1), key.generation);
}

test "loadThumbnailSurface - filesystem TIFF RAW mock" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Read real JPEG from committed fixtures
    const fixture_path = "testfiles/images/000_0_1024x682.jpg";
    var real_jpg = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, fixture_path, .{});
    defer real_jpg.close(io);
    const jpg_stat = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, fixture_path, .{});
    const jpg_bytes = try allocator.alloc(u8, @intCast(jpg_stat.size));
    defer allocator.free(jpg_bytes);
    var j_slices = [_][]u8{jpg_bytes};
    _ = try real_jpg.readPositional(io, &j_slices, 0);

    // Construct mock TIFF ARW
    var tiff_buf = try allocator.alloc(u8, 100 + jpg_bytes.len);
    defer allocator.free(tiff_buf);
    @memset(tiff_buf, 0);

    // TIFF Header
    tiff_buf[0] = 'I';
    tiff_buf[1] = 'I';
    tiff_buf[2] = 0x2A;
    tiff_buf[3] = 0x00;
    std.mem.writeInt(u32, tiff_buf[4..8], 8, .little);

    // IFD0 (num = 4)
    std.mem.writeInt(u16, tiff_buf[8..10], 4, .little);
    var off: usize = 10;
    // 1. 0x0100 (ImageWidth) = 6000
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0100, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 6000, .little);
    off += 12;

    // 2. 0x0101 (ImageLength) = 4000
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0101, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 4000, .little);
    off += 12;

    // 3. 0x0112 (Orientation) = 6 (rotate 90)
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0112, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 3, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u16, tiff_buf[off + 8 ..][0..2], 6, .little);
    off += 12;

    // 4. 0x014A (SubIFD) pointing to offset 60
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x014A, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 60, .little);
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little); // next IFD = 0

    // SubIFD at 60 (num = 2)
    off = 60;
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 2, .little);
    off += 2;
    // 1. 0x0201 (JPEGInterchangeFormat) pointing to 100
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0201, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], 100, .little);
    off += 12;

    // 2. 0x0202 (JPEGInterchangeFormatLength) = jpg_bytes.len
    std.mem.writeInt(u16, tiff_buf[off..][0..2], 0x0202, .little);
    std.mem.writeInt(u16, tiff_buf[off + 2 ..][0..2], 4, .little);
    std.mem.writeInt(u32, tiff_buf[off + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, tiff_buf[off + 8 ..][0..4], @intCast(jpg_bytes.len), .little);
    off += 12;
    std.mem.writeInt(u32, tiff_buf[off..][0..4], 0, .little);

    // Copy JPEG at 100
    @memcpy(tiff_buf[100 .. 100 + jpg_bytes.len], jpg_bytes);

    // Write mock file in isolated temp directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_thumb_test.arw", .{});
    var wr_slices = [_][]const u8{tiff_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_thumb_test.arw",
        .{tmp.sub_path},
    );

    const media = MediaEntry{ .filesystem = .{ .path = mock_path } };
    const thumb = loadThumbnailSurface(io, allocator, media);
    try std.testing.expect(thumb != null);
    if (thumb) |t| {
        defer t.surface.destroy();
        try std.testing.expect(t.surface.w() > 0);
        try std.testing.expect(t.surface.h() > 0);
        try std.testing.expectEqual(Orientation.rotate_90, t.orientation);
        try std.testing.expect(t.raw_metadata.isRaw());
        try std.testing.expectEqual(
            state_pkg.PhysicalDims{ .w = 6000.0, .h = 4000.0 },
            t.source_dims.?,
        );
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

test "detectThumbnailDctPadding - detects 8px DCT block snapping" {
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
    // Snaps to 8px DCT block; candidate row 7 and row 112 are black, and row 8
    // has image pixels -> returns true
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

test "probeMediaMetadata - detects embedded thumbnail and dimensions on mock RAF" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Read real JPEG to embed as preview
    const fixture_path = "testfiles/images/000_0_1024x682.jpg";
    var real_jpg = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, fixture_path, .{});
    defer real_jpg.close(io);
    const jpg_stat = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, fixture_path, .{});
    const jpg_bytes = try allocator.alloc(u8, @intCast(jpg_stat.size));
    defer allocator.free(jpg_bytes);
    var j_slices = [_][]u8{jpg_bytes};
    _ = try real_jpg.readPositional(io, &j_slices, 0);

    // Construct mock Fujifilm RAF
    var raf_buf = try allocator.alloc(u8, 200 + jpg_bytes.len);
    defer allocator.free(raf_buf);
    @memset(raf_buf, 0);

    @memcpy(raf_buf[0..8], "FUJIFILM");
    std.mem.writeInt(u32, raf_buf[84..88], 200, .big);
    std.mem.writeInt(u32, raf_buf[88..92], @intCast(jpg_bytes.len), .big);
    std.mem.writeInt(u32, raf_buf[92..96], 120, .big);
    std.mem.writeInt(u32, raf_buf[96..100], 12, .big);

    // Metadata block at 120:
    std.mem.writeInt(u32, raf_buf[120..124], 1, .big);
    std.mem.writeInt(u16, raf_buf[124..126], 0x0111, .big);
    std.mem.writeInt(u16, raf_buf[126..128], 4, .big);
    std.mem.writeInt(u16, raf_buf[128..130], 4160, .big);
    std.mem.writeInt(u16, raf_buf[130..132], 6240, .big);

    // Copy preview JPEG at 200
    @memcpy(raf_buf[200 .. 200 + jpg_bytes.len], jpg_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_probe_test.raf", .{});
    var wr_slices = [_][]const u8{raf_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_probe_test.raf",
        .{tmp.sub_path},
    );

    const media = MediaEntry{ .filesystem = .{ .path = mock_path } };
    const meta = probeMediaMetadata(io, media);
    try std.testing.expect(meta != null);
    if (meta) |m| {
        try std.testing.expect(m.has_embedded_thumbnail);
        try std.testing.expectEqual(@as(f32, 6240.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 4160.0), m.dims.h);
        try std.testing.expect(m.raw_metadata.isRaw());
    }
}

test "probeMediaMetadata - non-thumbnail formats return has_embedded_thumbnail = false" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const media = MediaEntry{
        .filesystem = .{
            .path = "testfiles/golden-screenshots/init.png",
        },
    };
    const meta = probeMediaMetadata(io, media);
    try std.testing.expect(meta != null);
    if (meta) |m| {
        try std.testing.expect(!m.has_embedded_thumbnail);
        try std.testing.expect(m.dims.w > 0);
        try std.testing.expect(m.dims.h > 0);
    }
}

test "computeFallbackScaleDims and stageSurfaceToRgba32 downscale safely" {
    const allocator = std.testing.allocator;

    // 1. Non-positive or already-fitting dimensions return null
    try std.testing.expect(computeFallbackScaleDims(0, 10000, 8192) == null);
    try std.testing.expect(computeFallbackScaleDims(10000, -1, 8192) == null);
    try std.testing.expect(computeFallbackScaleDims(10000, 10000, 0) == null);
    try std.testing.expect(computeFallbackScaleDims(4096, 2048, 8192) == null);

    // 2. Landscape downscale updates width, height, and mip levels
    const fb_land = computeFallbackScaleDims(16384, 8192, 8192).?;
    try std.testing.expectEqual(@as(i32, 8192), fb_land.w);
    try std.testing.expectEqual(@as(i32, 4096), fb_land.h);
    try std.testing.expectEqual(@as(u32, 14), fb_land.num_levels);

    // 3. Portrait and huge dimensions clamp to >= 1 without i32 overflow
    const fb_port = computeFallbackScaleDims(10, 300_000, 8192).?;
    try std.testing.expectEqual(@as(i32, 1), fb_port.w);
    try std.testing.expectEqual(@as(i32, 8192), fb_port.h);
    try std.testing.expectEqual(@as(u32, 14), fb_port.num_levels);

    const fb_huge = computeFallbackScaleDims(300_000, 600_000, 8192).?;
    try std.testing.expectEqual(@as(i32, 4096), fb_huge.w);
    try std.testing.expectEqual(@as(i32, 8192), fb_huge.h);
    try std.testing.expectEqual(@as(u32, 14), fb_huge.num_levels);

    // 4. Downscaled RGB24 surface stages using updated dims without over-read
    const orig_surf = sdl.Surface.create(128, 64, sdl.PixelFormat.rgb24).?;
    defer orig_surf.destroy();
    const fb = computeFallbackScaleDims(orig_surf.w(), orig_surf.h(), 64).?;
    try std.testing.expectEqual(@as(i32, 64), fb.w);
    try std.testing.expectEqual(@as(i32, 32), fb.h);

    const scaled = orig_surf.scale(fb.w, fb.h, .linear).?;
    defer scaled.destroy();

    const u_w: usize = @intCast(scaled.w());
    const u_h: usize = @intCast(scaled.h());
    const dst_pitch: usize = u_w * 4;
    const mapped = try allocator.alloc(u8, dst_pitch * u_h);
    defer allocator.free(mapped);

    const conv_ms = stageSurfaceToRgba32(
        scaled,
        mapped,
        u_w,
        u_h,
        dst_pitch,
        scaled.format(),
    );
    try std.testing.expect(conv_ms != null);
}

test "parseImageDimensions - rejects extreme Fuji RAF offsets" {
    var raf_hdr: [128]u8 = @splat(0);
    @memcpy(raf_hdr[0..16], "FUJIFILMCCD-RAW ");
    // Preview JPEG offset = 0xFFFF_FFF0, length = 0x100
    std.mem.writeInt(u32, raf_hdr[84..88], 0xFFFF_FFF0, .big);
    std.mem.writeInt(u32, raf_hdr[88..92], 0x0000_0100, .big);
    // Metadata offset = 0xFFFF_FFF0, length = 0x100
    std.mem.writeInt(u32, raf_hdr[92..96], 0xFFFF_FFF0, .big);
    std.mem.writeInt(u32, raf_hdr[96..100], 0x0000_0100, .big);

    try std.testing.expect(
        parseImageDimensions(&raf_hdr, "image/x-fuji-raf") == null,
    );

    // Offset = 0 with length > header.len must also be rejected safely
    std.mem.writeInt(u32, raf_hdr[84..88], 0, .big);
    std.mem.writeInt(u32, raf_hdr[88..92], 1000, .big);
    std.mem.writeInt(u32, raf_hdr[92..96], 0, .big);
    std.mem.writeInt(u32, raf_hdr[96..100], 1000, .big);

    try std.testing.expect(
        parseImageDimensions(&raf_hdr, "image/x-fuji-raf") == null,
    );
    try std.testing.expect(
        parseImageDimensions(raf_hdr[0..16], "image/x-fuji-raf") == null,
    );
}

test "computeTextureVramBytes - reports 4bpp RGBA8 footprint with mipmaps" {
    try std.testing.expectEqual(
        @as(usize, 100 * 50 * 4),
        computeTextureVramBytes(100, 50, 1),
    );
    try std.testing.expectEqual(
        @as(usize, (100 * 50 * 4 * 4) / 3),
        computeTextureVramBytes(100, 50, 8),
    );
}

test "ImageCache - Key lookup by MediaId remains valid after sort shift" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const id1 = MediaId.fromU32(1);
    const key1 = try cache.appendSlot(allocator, id1, .{
        .inflight = .{ .has_thread = true },
    });

    const id2 = MediaId.fromU32(2);
    _ = try cache.appendSlot(allocator, id2, .{
        .resident = .{ .asset = .failed },
    });

    // Verify lookup by id1 succeeds
    try std.testing.expect(cache.getIndex(key1) != null);
    try std.testing.expectEqual(id1, cache.slots.items(.key)[0].id);

    // Remove slot 0 (id1) and verify lookup reflects removal
    cache.removeAndDeinit(0, null);
    try std.testing.expect(cache.getIndex(key1) == null);
    try std.testing.expect(cache.getIndex(cache.activeKey(id2)) != null);
}
