const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const triage = @import("triage");
const vfs = @import("vfs");

const ArchiveMediaEntry = vfs.ArchiveMediaEntry;
const DecodeTelemetry = state_pkg.DecodeTelemetry;
const detectMimeType = probe.detectMimeType;
const IngestTelemetry = state_pkg.IngestTelemetry;
const isRawFile = vfs.isRawFile;
const MediaEntry = vfs.MediaEntry;
const MediaId = vfs.MediaId;
const Orientation = probe.Orientation;
const PairStreamTarget = vfs.PairStreamTarget;
const parseImageDimensions = probe.parseImageDimensions;
const PhysicalDims = state_pkg.PhysicalDims;
const ProbedImageMetadata = probe.ProbedImageMetadata;
const RawMetadata = probe.RawMetadata;
const ThumbnailInfo = state_pkg.ThumbnailInfo;
const VisibleNeighbors = triage.VisibleNeighbors;
const ZipSeekOffsets = vfs.ZipSeekOffsets;

/// Decoded CPU software surface stored in host RAM.
pub const CpuSurfaceComponent = struct {
    surface: sdl.Surface,
    w: f32,
    h: f32,
    size_bytes: u64,
    mime_type: []const u8 = "",
    decode: DecodeTelemetry = .{},
};

/// Resident GPU texture allocation and VRAM memory footprint metadata.
pub const GpuTextureComponent = struct {
    gpu_texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    size_bytes: u64,
    mime_type: []const u8 = "",
    decode: DecodeTelemetry = .{},
    ingest: IngestTelemetry = .{},
};

/// Tier-0 probed metadata populated during initial header inspection.
pub const CacheMetadata = struct {
    full_dims: ?PhysicalDims = null,
    orientation: Orientation = .normal,
    raw_metadata: RawMetadata = .none,
};

/// Drawable primary surface or GPU texture resident in host RAM or VRAM.
pub const ResidentAsset = union(enum) {
    none,
    failed,
    loaded_cpu: CpuSurfaceComponent,
    loaded_gpu: GpuTextureComponent,

    /// Releases resident CPU surface or GPU texture resources.
    pub fn deinit(self: *ResidentAsset, gpu_device: ?sdl.gpu.Device) void {
        switch (self.*) {
            .loaded_cpu => |cpu| cpu.surface.destroy(),
            .loaded_gpu => |gpu| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(gpu.gpu_texture);
                }
            },
            .none, .failed => {},
        }
        self.* = .none;
    }

    /// Atomically replaces the current GPU texture with a newly uploaded
    /// texture, releasing the old GPU texture if present.
    pub fn replaceGpuTexture(
        self: *ResidentAsset,
        new_gpu: GpuTextureComponent,
        gpu_device: ?sdl.gpu.Device,
    ) void {
        self.deinit(gpu_device);
        self.* = .{ .loaded_gpu = new_gpu };
    }
};

/// All resident visual layers currently uploaded and drawable for a slot.
pub const CacheResident = struct {
    thumbnail: ThumbnailState = .none,
    asset: ResidentAsset = .none,

    /// Releases both thumbnail texture and resident primary asset.
    pub fn deinit(
        self: *CacheResident,
        gpu_device: ?sdl.gpu.Device,
    ) void {
        switch (self.thumbnail) {
            .loaded => |thumb| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(thumb.texture);
                }
            },
            .none, .pending, .not_available, .unloaded => {},
        }
        self.thumbnail = .none;
        self.asset.deinit(gpu_device);
    }
};

/// Execution stage of an in-flight background worker job.
pub const InFlightStage = enum {
    decoding,
    uploading,
};

/// In-flight decode or upload task metadata with per-job cancellation epoch.
pub const InFlightDecode = struct {
    stage: InFlightStage = .decoding,
    has_thread: bool = false,
    start_time_ms: u64 = 0,
    target: PairStreamTarget = .adaptive,
    job_id: u8 = 0,
    job_epoch: u32 = 0,
};

/// State of a cached image's preview thumbnail (none, pending, not available,
/// unloaded dimensions, or uploaded GPU texture).
pub const ThumbnailState = union(enum) {
    none,
    pending,
    not_available,
    unloaded: ThumbnailInfo,
    loaded: struct {
        texture: sdl.gpu.Texture,
        info: ThumbnailInfo,
    },

    /// Extracts the thumbnail dimension and upload duration information if
    /// present.
    pub fn getInfo(self: ThumbnailState) ?ThumbnailInfo {
        return switch (self) {
            .none, .pending, .not_available => null,
            .unloaded => |info| info,
            .loaded => |l| l.info,
        };
    }
};

/// Orthogonal cache slot combining Tier-0 metadata, resident visual assets,
/// and active background decode tracking.
pub const CacheEntry = struct {
    metadata: CacheMetadata = .{},
    resident: CacheResident = .{},
    inflight: ?InFlightDecode = null,

    /// Returns the pixel width of the currently loaded surface or texture,
    /// or null if not loaded.
    pub fn getLoadedWidth(self: CacheEntry) ?f32 {
        return switch (self.resident.asset) {
            .loaded_gpu => |gpu| gpu.w,
            .loaded_cpu => |cpu| @floatFromInt(cpu.surface.w()),
            .none, .failed => null,
        };
    }

    /// Returns the pixel height of the currently loaded surface or texture,
    /// or null if not loaded.
    pub fn getLoadedHeight(self: CacheEntry) ?f32 {
        return switch (self.resident.asset) {
            .loaded_gpu => |gpu| gpu.h,
            .loaded_cpu => |cpu| @floatFromInt(cpu.surface.h()),
            .none, .failed => null,
        };
    }

    /// Monotonically updates the authoritative full-resolution dimensions if
    /// the candidate `(w, h)` has a larger positive finite pixel area.
    pub fn updateFullDims(self: *CacheEntry, w: f32, h: f32) void {
        const cand = PhysicalDims.initPositive(w, h) orelse return;
        const cur_area = if (self.metadata.full_dims) |cur|
            @as(f64, cur.w) * @as(f64, cur.h)
        else
            0.0;
        const cand_area = @as(f64, cand.w) * @as(f64, cand.h);
        if (cand_area > cur_area) {
            self.metadata.full_dims = cand;
        }
    }

    /// Applies probed or thumbnail metadata, monotonically upgrading
    /// authoritative and RAW sensor dimensions without clearing existing RAW
    /// state when `raw_metadata` is `.none`.
    pub fn applyProbedMetadata(
        self: *CacheEntry,
        dims: ?PhysicalDims,
        orientation: Orientation,
        raw_metadata: RawMetadata,
    ) void {
        if (orientation != .normal or
            self.metadata.orientation == .normal)
        {
            self.metadata.orientation = orientation;
        }
        if (raw_metadata.getSensorDims()) |s_dims| {
            self.updateFullDims(s_dims.w, s_dims.h);
        }
        if (dims) |d| {
            self.updateFullDims(d.w, d.h);
        }
        if (raw_metadata.isRaw() or self.metadata.raw_metadata.isRaw()) {
            if (self.metadata.full_dims) |fd| {
                self.metadata.raw_metadata = RawMetadata.init(fd.w, fd.h);
            } else if (raw_metadata.isRaw()) {
                self.metadata.raw_metadata = raw_metadata;
            }
        }
    }

    /// Returns the true physical pixel dimensions of the original image,
    /// irrespective of what downscaled preview or thumbnail is currently
    /// resident.
    pub fn getAuthoritativeDims(self: CacheEntry) PhysicalDims {
        var best: ?PhysicalDims =
            if (self.metadata.raw_metadata.getSensorDims()) |sd|
                .{ .w = sd.w, .h = sd.h }
            else
                null;
        if (self.metadata.full_dims) |fd| {
            const cur_area = if (best) |b|
                @as(f64, b.w) * @as(f64, b.h)
            else
                0.0;
            const full_area = @as(f64, fd.w) * @as(f64, fd.h);
            if (full_area >= cur_area) {
                best = fd;
            }
        }
        if (best) |b| return b;

        switch (self.resident.asset) {
            .loaded_gpu => |gpu| {
                if (PhysicalDims.initPositive(gpu.w, gpu.h)) |d| return d;
            },
            .loaded_cpu => |cpu| {
                if (PhysicalDims.initPositive(cpu.w, cpu.h)) |d| return d;
            },
            .none, .failed => {},
        }

        if (self.resident.thumbnail.getInfo()) |info| {
            if (PhysicalDims.initPositive(info.w, info.h)) |d| {
                if (info.source.isPreOriented() and
                    self.metadata.orientation.isDimensionSwapped())
                {
                    return .{ .w = d.h, .h = d.w };
                }
                return d;
            }
        }
        return .{ .w = 0.0, .h = 0.0 };
    }

    /// Releases resident thumbnail and primary assets.
    pub fn deinit(self: *CacheEntry, gpu_device: ?sdl.gpu.Device) void {
        self.resident.deinit(gpu_device);
        self.inflight = null;
    }
};

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

/// Maximum concurrent background decode jobs tracked in the pinned table.
pub const MAX_DECODE_JOBS: usize = 16;

/// Zero-allocation ticket binding a decode job to a pinned atomic epoch slot.
pub const JobTicket = struct {
    job_id: u8,
    epoch: u32,
};

/// Structure-of-Arrays (SoA) associative cache managing decoded image slots,
/// generation epochs, and VRAM memory budgeting.
pub const ImageCache = struct {
    slots: std.MultiArrayList(CacheSlot) = .{},
    generation: std.atomic.Value(usize) = .init(0),
    vram_capped_neighbors: ?VisibleNeighbors = null,
    vram_capped_prev_index: ?usize = null,
    max_prefetch_dist: usize = 2,

    /// Pinned array of atomic job epochs for zero-allocation cancellation.
    job_epochs: [MAX_DECODE_JOBS]std.atomic.Value(u32) = blk: {
        var arr: [MAX_DECODE_JOBS]std.atomic.Value(u32) = undefined;
        for (&arr) |*val| val.* = .init(1);
        break :blk arr;
    },
    /// Bitmask tracking active job IDs (0..15).
    job_alloc_mask: u16 = 0,

    /// Allocates an unused job slot and returns its JobTicket.
    pub fn allocJob(self: *ImageCache) ?JobTicket {
        const free_mask = ~self.job_alloc_mask;
        if (free_mask == 0) return null;
        const job_id: u8 = @truncate(@ctz(free_mask));
        if (job_id >= MAX_DECODE_JOBS) return null;
        self.job_alloc_mask |= (@as(u16, 1) << @as(u4, @truncate(job_id)));
        const epoch = self.job_epochs[job_id].load(.acquire);
        return .{ .job_id = job_id, .epoch = epoch };
    }

    /// Releases a completed or aborted job ID back to the allocation mask,
    /// advancing its atomic epoch to prevent ABA epoch reuse.
    pub fn releaseJob(self: *ImageCache, job_id: u8) void {
        if (job_id < MAX_DECODE_JOBS) {
            _ = self.job_epochs[job_id].fetchAdd(1, .release);
            self.job_alloc_mask &= ~(@as(u16, 1) << @as(u4, @truncate(job_id)));
        }
    }

    /// Immediately signals cancellation to the worker running `job_id`
    /// by advancing its atomic epoch counter, then releasing the job slot.
    pub fn cancelJob(self: *ImageCache, job_id: u8) void {
        self.releaseJob(job_id);
    }

    /// Cancels all active in-flight worker jobs and resets the mask.
    pub fn cancelAllJobs(self: *ImageCache) void {
        var mask = self.job_alloc_mask;
        while (mask != 0) {
            const job_id: u8 = @truncate(@ctz(mask));
            _ = self.job_epochs[job_id].fetchAdd(1, .release);
            mask &= ~(@as(u16, 1) << @as(u4, @truncate(job_id)));
        }
        self.job_alloc_mask = 0;
    }

    /// Validates whether a completed job's epoch matches the slot's
    /// active inflight decode task.
    pub fn validateJobEpoch(
        self: *const ImageCache,
        slot_idx: usize,
        job_epoch: u32,
    ) bool {
        if (slot_idx >= self.slots.len) return false;
        const entry = self.slots.items(.entry)[slot_idx];
        if (entry.inflight) |inf| {
            return inf.job_epoch == job_epoch;
        }
        return false;
    }

    /// Atomically increments the cache generation epoch to invalidate
    /// in-flight asynchronous decode tasks.
    pub fn advanceGeneration(self: *ImageCache) usize {
        self.cancelAllJobs();
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
        self.cancelAllJobs();
        const entries = self.slots.items(.entry);
        for (entries) |*entry| {
            entry.deinit(gpu_device);
        }
        self.slots.deinit(allocator);
    }

    /// Deinitializes all slot resources and clears the cache while retaining
    /// capacity.
    pub fn clear(self: *ImageCache, gpu_device: ?sdl.gpu.Device) void {
        self.cancelAllJobs();
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
        self.cancelAllJobs();
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
        const entry = &self.slots.items(.entry)[idx];
        if (entry.inflight) |old_inf| {
            if (old_inf.has_thread) {
                if (inflight) |new_inf| {
                    if (!new_inf.has_thread or
                        old_inf.job_id != new_inf.job_id)
                    {
                        self.cancelJob(old_inf.job_id);
                    }
                } else {
                    self.cancelJob(old_inf.job_id);
                }
            }
        }
        entry.inflight = inflight;
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
        if (entry.inflight) |inf| {
            if (inf.has_thread) {
                self.cancelJob(inf.job_id);
            }
        }
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
                .loaded_gpu => |gpu| total += gpu.ingest.memory_size_bytes,
                .none, .failed, .loaded_cpu => {},
            }
        }
        return total;
    }

    /// Returns the maximum circular neighbor distance (`0..2`) to prefetch for
    /// `neighbors` without exceeding the VRAM budget.
    pub fn getMaxPrefetchDist(
        self: *const ImageCache,
        neighbors: VisibleNeighbors,
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
        neighbors_opt: ?VisibleNeighbors,
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
        neighbors: VisibleNeighbors,
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

/// Synchronously probes container headers for image dimensions, EXIF rotation,
/// and embedded thumbnail presence in < 0.1ms before spawning background decode
/// workers, eliminating Frame-1 layout jumps and UI flicker.
pub fn probeMediaMetadata(io: std.Io, media: MediaEntry) ?ProbedImageMetadata {
    return switch (media) {
        .filesystem => |f| probe.probeFileHeaderMetadata(
            io,
            f.path,
            isRawFile(f.path),
        ),
        .pair => |p| probe.probeCompanionJpegHeaderMetadata(
            io,
            p.jpeg_path,
            p.raw_path,
            isRawFile(p.raw_path),
        ),
        .archive_entry => |a| switch (a.seek_info) {
            .indexed => |seek| if (seek.compression_method == .store)
                probe.probeStoredZipHeaderMetadata(
                    io,
                    a.archive_path,
                    a.entry_name,
                    seek.file_offset,
                    isRawFile(a.entry_name),
                )
            else
                null,
            .unindexed => null,
        },
    };
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
    loc: probe.ThumbnailLocation,
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

    const image_slice = probe.skipZipLocalFileHeader(header_buf[0..n]) orelse
        return null;
    const mime_type = detectMimeType(image_slice, a.entry_name);
    if (!std.mem.eql(u8, mime_type, "image/jpeg")) return null;

    const loc = probe.extractJpegThumbnailLocation(image_slice) orelse
        return null;
    if (loc.file_offset +| loc.length > image_slice.len) return null;
    const off: usize = @intCast(loc.file_offset);
    const len: usize = @intCast(loc.length);

    const surf = sdl.Surface.loadConstMemOpt(
        image_slice[off .. off + len],
    ) orelse return null;

    const orientation = probe.parseExifOrientation(image_slice) orelse .normal;
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

/// Extracts the embedded preview thumbnail surface and orientation metadata
/// for a media entry. Supports Camera RAW formats (.arw, .raf, .cr2, .nef,
/// .dng, .orf, .rw2, .pef), standard JPEGs, and CBZ entries.
pub fn loadThumbnailSurface(
    io: std.Io,
    alloc: std.mem.Allocator,
    media: MediaEntry,
) ?ExtractedThumbnail {
    switch (media) {
        .filesystem => |f| {
            var file = std.Io.Dir.openFile(
                std.Io.Dir.cwd(),
                io,
                f.path,
                .{},
            ) catch |err| {
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
            const is_raw_ext = isRawFile(f.path);
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
            const is_raw = is_raw_ext or
                probe.isFujiRafHeader(header_slice, mime_type) or
                std.mem.startsWith(u8, mime_type, "image/x-");

            var thumb_surf: ?sdl.Surface = null;
            var orientation: Orientation = .normal;
            var source_dims: ?state_pkg.PhysicalDims = null;

            if (is_raw) {
                const raw_probe = probe.probeRawFileHeader(
                    io,
                    &file,
                    file_size,
                    header_slice,
                    mime_type,
                );
                if (raw_probe.sensor_dims) |sd| {
                    source_dims = state_pkg.PhysicalDims.initPositive(
                        sd.w,
                        sd.h,
                    );
                }
                orientation = raw_probe.orientation;
                if (raw_probe.thumbnail orelse raw_probe.medium) |tloc| {
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
                orientation =
                    probe.parseExifOrientation(header_slice) orelse .normal;
                if (parseImageDimensions(header_slice, mime_type)) |dims| {
                    source_dims = state_pkg.PhysicalDims.initPositive(
                        dims.w,
                        dims.h,
                    );
                }
                if (probe.extractJpegThumbnailLocation(header_slice)) |loc| {
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

/// Result payload containing the created GPU texture, dimensions, and
/// ingestion telemetry.
pub const GpuUploadResult = struct {
    gpu_texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    ingest: state_pkg.IngestTelemetry = .{},
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
            .ingest = .{
                .upload_time_ms = upload_time_ms,
                .memory_size_bytes = memory_size_bytes,
                .mode = state_pkg.UploadMode.init(
                    was_fallback,
                    fallback_time_ms,
                ),
                .mipmaps = state_pkg.MipmapTelemetry.init(
                    num_levels,
                    mipmap_time_ms,
                ),
            },
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

    _ = stageSurfaceToRgba32(
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
        .ingest = .{
            .upload_time_ms = upload_time_ms,
            .memory_size_bytes = memory_size_bytes,
            .mode = state_pkg.UploadMode.init(
                was_fallback,
                fallback_time_ms,
            ),
            .mipmaps = state_pkg.MipmapTelemetry.init(
                num_levels,
                mipmap_time_ms,
            ),
        },
    };
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
                            .ingest = .{ .memory_size_bytes = size },
                        },
                    },
                },
            };
        }
    }.create;

    const n10 = VisibleNeighbors.fromRawIndex(0, 10);

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
    const n5 = VisibleNeighbors.fromRawIndex(0, 5);
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

    const n5 = VisibleNeighbors.fromRawIndex(0, 5);

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
                    .ingest = .{ .memory_size_bytes = 100 },
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

test "probeMediaMetadata - dispatches filesystem, pair, and archive_entry" {
    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. .filesystem
    const fs_meta = probeMediaMetadata(io, .{
        .filesystem = .{ .path = "testfiles/images/000_0_1024x682.jpg" },
    });
    try std.testing.expect(fs_meta != null);
    if (fs_meta) |m| {
        try std.testing.expectEqual(@as(f32, 1024.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), m.dims.h);
        try std.testing.expectEqual(Orientation.normal, m.orientation);
    }

    // 2. .pair
    const pair_meta = probeMediaMetadata(io, .{
        .pair = .{
            .raw_path = "testfiles/images/000_0_1024x682.jpg",
            .jpeg_path = "testfiles/images/000_0_1024x682.jpg",
        },
    });
    try std.testing.expect(pair_meta != null);
    if (pair_meta) |m| {
        try std.testing.expectEqual(@as(f32, 1024.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), m.dims.h);
        try std.testing.expect(m.has_embedded_thumbnail);
        try std.testing.expect(m.raw_metadata.isRaw());
    }

    // 3. .archive_entry (.store)
    const stored_meta = probeMediaMetadata(io, .{
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
    });
    try std.testing.expect(stored_meta != null);
    if (stored_meta) |m| {
        try std.testing.expectEqual(@as(f32, 1024.0), m.dims.w);
        try std.testing.expectEqual(@as(f32, 682.0), m.dims.h);
    }

    // 4. .archive_entry (.deflate) -> null
    const deflate_meta = probeMediaMetadata(io, .{
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
    });
    try std.testing.expectEqual(
        @as(?ProbedImageMetadata, null),
        deflate_meta,
    );

    // 5. .archive_entry (.unindexed) -> null
    const unindexed_meta = probeMediaMetadata(io, .{
        .archive_entry = .{
            .archive_path = "testfiles/images/000_0_1024x682.jpg",
            .entry_name = "test.jpg",
            .seek_info = .unindexed,
        },
    });
    try std.testing.expectEqual(
        @as(?ProbedImageMetadata, null),
        unindexed_meta,
    );
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

test "ImageCache - Job ticket allocation, reuse and epoch incrementing" {
    var cache = ImageCache{};

    // Allocate all 16 job tickets
    var tickets: [MAX_DECODE_JOBS]JobTicket = undefined;
    for (0..MAX_DECODE_JOBS) |i| {
        tickets[i] = cache.allocJob().?;
        try std.testing.expectEqual(@as(u8, @truncate(i)), tickets[i].job_id);
        try std.testing.expectEqual(@as(u32, 1), tickets[i].epoch);
    }

    // 17th allocation must fail
    try std.testing.expect(cache.allocJob() == null);

    // Cancel job 5: increments epoch and releases slot
    cache.cancelJob(tickets[5].job_id);
    try std.testing.expectEqual(
        @as(u32, 2),
        cache.job_epochs[5].load(.acquire),
    );

    // Re-allocating reuses slot 5 with incremented epoch
    const reused = cache.allocJob().?;
    try std.testing.expectEqual(@as(u8, 5), reused.job_id);
    try std.testing.expectEqual(@as(u32, 2), reused.epoch);

    // Release job 5 and cancel all remaining
    cache.releaseJob(reused.job_id);
    try std.testing.expectEqual(
        @as(u32, 3),
        cache.job_epochs[5].load(.acquire),
    );
    cache.cancelAllJobs();
    try std.testing.expectEqual(@as(u16, 0), cache.job_alloc_mask);
}

test "removeAndDeinit - Cancels active in-flight job on slot eviction" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const ticket = cache.allocJob().?;
    const id = MediaId.fromU32(100);
    _ = try cache.appendSlot(allocator, id, .{
        .inflight = .{
            .has_thread = true,
            .job_id = ticket.job_id,
            .job_epoch = ticket.epoch,
        },
    });

    try std.testing.expectEqual(@as(u32, 1), ticket.epoch);
    try std.testing.expect(cache.job_alloc_mask != 0);

    // Eviction via removeAndDeinit must cancel and release the active job
    cache.removeAndDeinit(0, null);

    try std.testing.expectEqual(
        @as(u32, 2),
        cache.job_epochs[ticket.job_id].load(.acquire),
    );
    try std.testing.expectEqual(@as(u16, 0), cache.job_alloc_mask);
}

test "InFlightDecode defaults" {
    const inf: InFlightDecode = .{};
    try std.testing.expectEqual(@as(u64, 0), inf.start_time_ms);
    try std.testing.expect(!inf.has_thread);
    try std.testing.expectEqual(InFlightStage.decoding, inf.stage);
    try std.testing.expectEqual(PairStreamTarget.adaptive, inf.target);
}

test "CacheEntry - updateFullDims and monotonic probed metadata integration" {
    var entry = CacheEntry{};
    try std.testing.expectEqual(
        @as(?PhysicalDims, null),
        entry.metadata.full_dims,
    );

    // Initial update sets full_dims
    entry.updateFullDims(1616.0, 1080.0);
    try std.testing.expectEqual(
        PhysicalDims{ .w = 1616.0, .h = 1080.0 },
        entry.metadata.full_dims.?,
    );

    // Probing smaller preview does not overwrite larger full_dims
    entry.applyProbedMetadata(
        PhysicalDims.initPositive(800.0, 600.0),
        .rotate_90,
        .none,
    );
    try std.testing.expectEqual(
        PhysicalDims{ .w = 1616.0, .h = 1080.0 },
        entry.metadata.full_dims.?,
    );
    try std.testing.expectEqual(
        Orientation.rotate_90,
        entry.metadata.orientation,
    );

    // Probing larger dimensions upgrades monotonically
    entry.applyProbedMetadata(
        PhysicalDims.initPositive(6000.0, 4000.0),
        .normal,
        RawMetadata.init(6000.0, 4000.0),
    );
    try std.testing.expectEqual(
        PhysicalDims{ .w = 6000.0, .h = 4000.0 },
        entry.metadata.full_dims.?,
    );
    // Preserves non-normal orientation when candidate is .normal
    try std.testing.expectEqual(
        Orientation.rotate_90,
        entry.metadata.orientation,
    );
    try std.testing.expect(entry.metadata.raw_metadata.isRaw());
}

test "CacheEntry - getAuthoritativeDims priority resolution" {
    var entry = CacheEntry{};

    // 0. Empty entry -> 0x0
    try std.testing.expectEqual(
        PhysicalDims{ .w = 0.0, .h = 0.0 },
        entry.getAuthoritativeDims(),
    );

    // 1. Thumbnail dimensions
    entry.resident.thumbnail = .{
        .loaded = .{
            .texture = undefined,
            .info = .{ .w = 160.0, .h = 120.0 },
        },
    };
    try std.testing.expectEqual(
        PhysicalDims{ .w = 160.0, .h = 120.0 },
        entry.getAuthoritativeDims(),
    );

    // 2. Resident asset takes priority over thumbnail
    entry.resident.asset = .{
        .loaded_cpu = .{
            .surface = undefined,
            .w = 1920.0,
            .h = 1080.0,
            .size_bytes = 1000,
        },
    };
    try std.testing.expectEqual(
        PhysicalDims{ .w = 1920.0, .h = 1080.0 },
        entry.getAuthoritativeDims(),
    );

    // 3. full_dims takes priority over resident asset
    entry.metadata.full_dims = .{ .w = 4000.0, .h = 3000.0 };
    try std.testing.expectEqual(
        PhysicalDims{ .w = 4000.0, .h = 3000.0 },
        entry.getAuthoritativeDims(),
    );

    // 4. raw_metadata sensor dims takes highest priority if larger
    entry.metadata.raw_metadata = RawMetadata.init(6000.0, 4000.0);
    try std.testing.expectEqual(
        PhysicalDims{ .w = 6000.0, .h = 4000.0 },
        entry.getAuthoritativeDims(),
    );
}

test "CacheResident - deinit cleans up both thumbnail and primary textures" {
    // 1. Populated thumbnail and loaded_gpu asset
    var resident = CacheResident{
        .thumbnail = .{
            .loaded = .{
                .texture = .{ .ptr = @ptrFromInt(0x1234) },
                .info = .{ .w = 160.0, .h = 120.0 },
            },
        },
        .asset = .{
            .loaded_gpu = .{
                .gpu_texture = .{ .ptr = @ptrFromInt(0x5678) },
                .w = 1920.0,
                .h = 1080.0,
                .size_bytes = 1000,
                .ingest = .{ .memory_size_bytes = 2000 },
            },
        },
    };
    // Safe deinit on null gpu device resets both layers to .none
    resident.deinit(null);
    try std.testing.expectEqual(ThumbnailState.none, resident.thumbnail);
    try std.testing.expectEqual(ResidentAsset.none, resident.asset);

    // 2. Populated loaded_cpu asset destroys underlying surface on deinit
    const surf = sdl.Surface.create(1, 1, sdl.PixelFormat.rgba32) orelse return;
    var cpu_resident = CacheResident{
        .thumbnail = .none,
        .asset = .{
            .loaded_cpu = .{
                .surface = surf,
                .w = 1.0,
                .h = 1.0,
                .size_bytes = 4,
            },
        },
    };
    cpu_resident.deinit(null);
    try std.testing.expectEqual(ThumbnailState.none, cpu_resident.thumbnail);
    try std.testing.expectEqual(ResidentAsset.none, cpu_resident.asset);
}
