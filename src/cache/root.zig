const geom = @import("geom");
const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const triage = @import("triage");
const vfs = @import("vfs");

const DecodeTelemetry = state_pkg.DecodeTelemetry;
const IngestTelemetry = state_pkg.IngestTelemetry;
const MediaId = vfs.MediaId;
const Orientation = probe.Orientation;
const PairStreamTarget = vfs.PairStreamTarget;
const PhysicalDims = geom.PhysicalDims;
const PositiveDimsU32 = geom.PositiveDimsU32;
const RawMetadata = probe.RawMetadata;
const ThumbnailInfo = state_pkg.ThumbnailInfo;
const UvRect = geom.UvRect;
const VisibleNeighbors = triage.VisibleNeighbors;

/// Decoded CPU software surface stored in host RAM.
pub const CpuSurfaceComponent = struct {
    surface: sdl.Surface,
    w: f32,
    h: f32,
    size_bytes: u64,
    mime_type: []const u8 = "",
    decode: DecodeTelemetry = .{},
};

/// Metadata for scheduling a Freedesktop thumbnail cache write after GPU
/// upload.
pub const DeferredThumbWrite = struct {
    source_mtime_sec: i64,
};

/// Decoded CPU image surface paired with an optional deferred thumbnail
/// cache write.
pub const CpuAsset = struct {
    cpu: CpuSurfaceComponent,
    thumb_write: ?DeferredThumbWrite = null,

    /// Destroys the underlying CPU surface.
    pub fn deinit(self: *CpuAsset) void {
        self.cpu.surface.destroy();
    }
};

/// Decoded thumbnail CPU surface staged on a cache slot until Phase 2 upload.
pub const PendingThumbSurface = struct {
    surface: sdl.Surface,
    dct_snapped: bool = false,
    source: state_pkg.ThumbnailSource = .embedded_header,

    /// Extracts `ThumbnailInfo` dimensions and metadata for `.unloaded`
    /// retention before destroying a superseded CPU surface.
    pub fn toUnloadedInfo(self: PendingThumbSurface) ThumbnailInfo {
        return .{
            .w = @floatFromInt(@max(0, self.surface.w())),
            .h = @floatFromInt(@max(0, self.surface.h())),
            .upload_time_ms = 0.0,
            .dct_snapped = self.dct_snapped,
            .source = self.source,
        };
    }

    /// Destroys the staged thumbnail SDL surface.
    pub fn deinit(self: *PendingThumbSurface) void {
        self.surface.destroy();
    }
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

/// Active GPU texture kept on screen while a newly decoded CPU asset awaits
/// upload.
pub const PromotingGpuComponent = struct {
    active: GpuTextureComponent,
    staged: CpuAsset,
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
    loaded_cpu: CpuAsset,
    loaded_gpu: GpuTextureComponent,
    promoting_gpu: PromotingGpuComponent,
    failed,

    /// Returns `true` when an active GPU texture is resident (`.loaded_gpu` or
    /// `.promoting_gpu`).
    pub inline fn hasGpuTexture(self: ResidentAsset) bool {
        return switch (self) {
            .loaded_gpu, .promoting_gpu => true,
            .none, .loaded_cpu, .failed => false,
        };
    }

    /// Returns `true` when a decoded CPU surface is awaiting GPU upload
    /// (`.loaded_cpu` or `.promoting_gpu`).
    pub inline fn hasPendingCpuUpload(self: ResidentAsset) bool {
        return switch (self) {
            .loaded_cpu, .promoting_gpu => true,
            .none, .loaded_gpu, .failed => false,
        };
    }

    /// Returns `true` when any decoded image asset is present (`.loaded_cpu`,
    /// `.loaded_gpu`, or `.promoting_gpu`).
    pub inline fn isLoaded(self: ResidentAsset) bool {
        return switch (self) {
            .loaded_cpu, .loaded_gpu, .promoting_gpu => true,
            .none, .failed => false,
        };
    }

    /// Returns `true` when the primary asset is in the `.failed` state.
    pub inline fn isFailed(self: ResidentAsset) bool {
        return switch (self) {
            .failed => true,
            .none, .loaded_cpu, .loaded_gpu, .promoting_gpu => false,
        };
    }

    /// Releases resident CPU surface or GPU texture resources.
    pub fn deinit(self: *ResidentAsset, gpu_device: ?sdl.gpu.Device) void {
        switch (self.*) {
            .loaded_cpu => |*asset| asset.deinit(),
            .loaded_gpu => |gpu| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(gpu.gpu_texture);
                }
            },
            .promoting_gpu => |*promo| {
                promo.staged.deinit();
                if (gpu_device) |dev| {
                    dev.releaseTexture(promo.active.gpu_texture);
                }
            },
            .none, .failed => {},
        }
        self.* = .none;
    }

    /// Atomically replaces the current GPU texture with a newly uploaded
    /// texture, releasing any old GPU texture and staged CPU surface.
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

    /// Releases both thumbnail and resident primary asset resources.
    pub fn deinit(
        self: *CacheResident,
        gpu_device: ?sdl.gpu.Device,
    ) void {
        self.thumbnail.deinit(gpu_device);
        self.asset.deinit(gpu_device);
    }
};

/// Deferred decode request queued for a cache slot awaiting a worker thread.
pub const QueuedDecode = struct {
    start_time_ms: u64 = 0,
    target: PairStreamTarget = .adaptive,
};

/// Active background worker decode job bound to a pinned cancellation ticket.
pub const ActiveDecode = struct {
    start_time_ms: u64 = 0,
    target: PairStreamTarget = .adaptive,
    ticket: JobTicket,
};

/// Active main-thread GPU texture upload staged from a decoded CPU surface.
pub const ActiveUpload = struct {
    start_time_ms: u64 = 0,
};

/// Mutually exclusive in-flight lifecycle state for a cache slot.
pub const InFlightState = union(enum) {
    idle,
    queued_decode: QueuedDecode,
    decoding: ActiveDecode,
    uploading: ActiveUpload,

    /// Returns `true` when no decode or GPU upload is queued or active.
    pub inline fn isIdle(self: InFlightState) bool {
        return switch (self) {
            .idle => true,
            .queued_decode, .decoding, .uploading => false,
        };
    }

    /// Returns the millisecond timestamp when the queued or active job began,
    /// or `null` when `.idle`.
    pub inline fn startTimeMs(self: InFlightState) ?u64 {
        return switch (self) {
            .idle => null,
            .queued_decode => |q| q.start_time_ms,
            .decoding => |d| d.start_time_ms,
            .uploading => |u| u.start_time_ms,
        };
    }
};

/// State of a cached image's preview thumbnail (none, pending, staged CPU
/// surface, not available, unloaded dimensions, or uploaded GPU texture).
pub const ThumbnailState = union(enum) {
    none,
    pending,
    staged_cpu: PendingThumbSurface,
    not_available,
    unloaded: ThumbnailInfo,
    loaded: struct {
        texture: sdl.gpu.Texture,
        info: ThumbnailInfo,
    },

    /// Releases any staged CPU surface or uploaded GPU thumbnail texture.
    pub fn deinit(
        self: *ThumbnailState,
        gpu_device: ?sdl.gpu.Device,
    ) void {
        switch (self.*) {
            .staged_cpu => |*st| st.deinit(),
            .loaded => |thumb| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(thumb.texture);
                }
            },
            .none, .pending, .not_available, .unloaded => {},
        }
        self.* = .none;
    }

    /// Extracts the thumbnail dimension and upload duration information if
    /// present.
    pub fn getInfo(self: ThumbnailState) ?ThumbnailInfo {
        return switch (self) {
            .none, .pending, .staged_cpu, .not_available => null,
            .unloaded => |info| info,
            .loaded => |l| l.info,
        };
    }

    /// Returns `true` when a decoded thumbnail surface is staged on CPU
    /// awaiting GPU upload.
    pub inline fn isStagedCpu(self: ThumbnailState) bool {
        return switch (self) {
            .staged_cpu => true,
            .none, .pending, .not_available, .unloaded, .loaded => false,
        };
    }

    /// Transitions unresolved `.none` or `.pending` states to
    /// `.not_available`, preserving `.staged_cpu`, `.loaded`, `.unloaded`,
    /// and `.not_available`.
    pub fn markNotAvailableIfUnresolved(self: *ThumbnailState) void {
        switch (self.*) {
            .none, .pending => self.* = .not_available,
            .staged_cpu, .loaded, .unloaded, .not_available => {},
        }
    }

    /// Transitions `.none`, `.pending`, or `.unloaded` to `.not_available`
    /// when a thumbnail-only worker probe confirms no thumbnail can be loaded.
    pub fn markNotAvailableOnMiss(self: *ThumbnailState) void {
        switch (self.*) {
            .none, .pending, .unloaded => self.* = .not_available,
            .staged_cpu, .loaded, .not_available => {},
        }
    }

    /// Records `.unloaded` metadata when a decoded thumbnail surface is
    /// skipped because the full-resolution image is already resident or queued
    /// in the same event batch, destroying any prior `.staged_cpu` surface.
    pub fn recordSupersededInfo(
        self: *ThumbnailState,
        info: ThumbnailInfo,
    ) void {
        switch (self.*) {
            .staged_cpu => |*st| {
                st.deinit();
                self.* = .{ .unloaded = info };
            },
            .none, .pending => self.* = .{ .unloaded = info },
            .loaded, .unloaded, .not_available => {},
        }
    }

    /// Destroys any `.staged_cpu` surface while retaining its `.unloaded`
    /// metadata, and marks `.none` or `.pending` as `.not_available` when
    /// `mark_unresolved_unavailable` indicates thumbnail probing completed.
    pub fn unloadSuperseded(
        self: *ThumbnailState,
        mark_unresolved_unavailable: bool,
    ) void {
        switch (self.*) {
            .staged_cpu => |*st| {
                const info = st.toUnloadedInfo();
                st.deinit();
                self.* = .{ .unloaded = info };
            },
            .none, .pending => {
                if (mark_unresolved_unavailable) {
                    self.* = .not_available;
                }
            },
            .loaded, .unloaded, .not_available => {},
        }
    }

    /// Destroys any `.staged_cpu` surface and transitions `.none`, `.pending`,
    /// or `.staged_cpu` to `.not_available`.
    pub fn discardStagedAndMarkUnavailable(self: *ThumbnailState) void {
        switch (self.*) {
            .staged_cpu => |*st| {
                st.deinit();
                self.* = .not_available;
            },
            .none, .pending => self.* = .not_available,
            .loaded, .unloaded, .not_available => {},
        }
    }
};

/// Orthogonal cache slot combining Tier-0 metadata, resident visual assets,
/// and active background decode tracking.
pub const CacheEntry = struct {
    metadata: CacheMetadata = .{},
    resident: CacheResident = .{},
    inflight: InFlightState = .idle,

    /// Constructs a synthetic GPU-resident `CacheEntry` for unit testing
    /// layout and viewport logic without initializing a real GPU device.
    pub fn stubLoadedGpuForTest(
        full_dims: PhysicalDims,
        thumb_dims: PhysicalDims,
    ) CacheEntry {
        const dummy_tex: sdl.gpu.Texture = .{ .ptr = @ptrFromInt(0x1000) };
        const pos: PositiveDimsU32 = full_dims.toPositiveU32() orelse
            .{ .w = 1, .h = 1 };
        const thumb: ThumbnailState = if (thumb_dims.w > 0.0 and
            thumb_dims.h > 0.0)
            .{
                .loaded = .{
                    .texture = dummy_tex,
                    .info = .{
                        .w = thumb_dims.w,
                        .h = thumb_dims.h,
                        .dct_snapped = false,
                    },
                },
            }
        else
            .none;
        return .{
            .resident = .{
                .asset = .{
                    .loaded_gpu = .{
                        .gpu_texture = dummy_tex,
                        .w = full_dims.w,
                        .h = full_dims.h,
                        .size_bytes = 1000,
                        .ingest = .{
                            .memory_size_bytes = @as(usize, pos.w) *
                                @as(usize, pos.h) * 4,
                        },
                    },
                },
                .thumbnail = thumb,
            },
            .metadata = .{
                .full_dims = full_dims,
            },
        };
    }

    /// Returns the pixel width of the currently loaded surface or texture,
    /// or null if not loaded.
    pub fn getLoadedWidth(self: CacheEntry) ?f32 {
        return switch (self.resident.asset) {
            .loaded_gpu => |gpu| gpu.w,
            .promoting_gpu => |promo| promo.active.w,
            .loaded_cpu => |asset| @floatFromInt(asset.cpu.surface.w()),
            .none, .failed => null,
        };
    }

    /// Returns the pixel height of the currently loaded surface or texture,
    /// or null if not loaded.
    pub fn getLoadedHeight(self: CacheEntry) ?f32 {
        return switch (self.resident.asset) {
            .loaded_gpu => |gpu| gpu.h,
            .promoting_gpu => |promo| promo.active.h,
            .loaded_cpu => |asset| @floatFromInt(asset.cpu.surface.h()),
            .none, .failed => null,
        };
    }

    /// Monotonically updates the authoritative full-resolution dimensions if
    /// the candidate `dims` has a larger positive finite pixel area.
    pub fn updateFullDims(self: *CacheEntry, dims: PhysicalDims) void {
        const cand = dims.asPositive() orelse return;
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
            self.updateFullDims(s_dims);
        }
        if (dims) |d| {
            self.updateFullDims(d);
        }
        if (raw_metadata.isRaw() or self.metadata.raw_metadata.isRaw()) {
            if (self.metadata.full_dims) |fd| {
                self.metadata.raw_metadata = RawMetadata.fromDims(fd);
            } else if (raw_metadata.isRaw()) {
                self.metadata.raw_metadata = raw_metadata;
            }
        }
    }

    /// Returns the true physical pixel dimensions of the original image,
    /// irrespective of what downscaled preview or thumbnail is currently
    /// resident.
    pub fn getAuthoritativeDims(self: CacheEntry) PhysicalDims {
        var best: ?PhysicalDims = self.metadata.raw_metadata.getSensorDims();
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
            .promoting_gpu => |promo| {
                const pw = promo.active.w;
                const ph = promo.active.h;
                if (PhysicalDims.initPositive(pw, ph)) |d| {
                    return d;
                }
            },
            .loaded_cpu => |asset| {
                if (PhysicalDims.initPositive(asset.cpu.w, asset.cpu.h)) |d| {
                    return d;
                }
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

    /// Computes the GPU UV crop, effective rotation angle, and source
    /// dimensions for rendering `thumb_info` of this entry at
    /// `rotation_angle`, compensating for pre-oriented cached thumbnails.
    pub fn computeThumbnailUvRect(
        self: CacheEntry,
        thumb_info: ThumbnailInfo,
        auth: PhysicalDims,
        rotation_angle: f32,
    ) UvRect {
        const pre_oriented = thumb_info.source.isPreOriented();
        const swapped = pre_oriented and
            self.metadata.orientation.isDimensionSwapped();
        const ref_full: PhysicalDims = if (self.metadata.full_dims) |fd|
            (if (swapped) .{ .w = fd.h, .h = fd.w } else fd)
        else
            .{ .w = 0.0, .h = 0.0 };
        var uv = state_pkg.view_transform.computeThumbnailUvCrop(
            ref_full,
            .{ .w = thumb_info.w, .h = thumb_info.h },
            thumb_info.dct_snapped,
        );
        uv.alpha = 1.0;
        uv.rotation_angle = if (pre_oriented)
            @mod(
                rotation_angle - self.metadata.orientation.toDegrees() + 360.0,
                360.0,
            )
        else
            rotation_angle;
        uv.source_w = if (swapped) auth.h else auth.w;
        uv.source_h = if (swapped) auth.w else auth.h;
        return uv;
    }

    /// Releases resident thumbnail, primary assets, and in-flight state.
    pub fn deinit(self: *CacheEntry, gpu_device: ?sdl.gpu.Device) void {
        self.resident.deinit(gpu_device);
        self.inflight = .idle;
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
    slots: std.MultiArrayList(CacheSlot) = .empty,
    generation: std.atomic.Value(usize) = .init(0),
    vram_capped_neighbors: ?VisibleNeighbors = null,
    vram_capped_prev_index: ?usize = null,
    max_prefetch_dist: usize = 2,
    current_image_cache_hit: bool = false,

    /// Pinned array of atomic job epochs for zero-allocation cancellation.
    job_epochs: [MAX_DECODE_JOBS]std.atomic.Value(u32) = @splat(.init(1)),
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

    /// Validates whether a completed job's epoch matches the slot's active
    /// `.decoding` job ticket.
    pub fn validateJobEpoch(
        self: *const ImageCache,
        slot_idx: usize,
        job_epoch: u32,
    ) bool {
        if (slot_idx >= self.slots.len) return false;
        const entry = self.slots.items(.entry)[slot_idx];
        return switch (entry.inflight) {
            .decoding => |dec| dec.ticket.epoch == job_epoch,
            .idle, .queued_decode, .uploading => false,
        };
    }

    /// Atomically increments the cache generation epoch to invalidate
    /// in-flight asynchronous decode tasks.
    pub fn advanceGeneration(self: *ImageCache) usize {
        self.cancelAllJobs();
        self.vram_capped_neighbors = null;
        self.vram_capped_prev_index = null;
        self.max_prefetch_dist = 2;
        self.current_image_cache_hit = false;
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

    /// Deinitializes all cached GPU textures and releases the multi-array
    /// storage memory.
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
        self.current_image_cache_hit = false;
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
        self.current_image_cache_hit = false;
    }

    /// Clears all slots without releasing underlying capacity.
    pub fn clearRetainingCapacity(self: *ImageCache) void {
        self.cancelAllJobs();
        self.slots.clearRetainingCapacity();
        self.vram_capped_neighbors = null;
        self.vram_capped_prev_index = null;
        self.max_prefetch_dist = 2;
        self.current_image_cache_hit = false;
    }

    /// Finds the dense array index of the slot matching `key`, or null if not
    /// found.
    pub fn getIndex(self: *const ImageCache, key: ImageCacheKey) ?usize {
        const keys = self.slots.items(.key);
        for (keys, 0..) |k, i| {
            if (k.eql(key)) return i;
        }
        return null;
    }

    /// Returns a pointer to the `CacheEntry` corresponding to `key`, or null if
    /// not present.
    pub fn get(self: *ImageCache, key: ImageCacheKey) ?*CacheEntry {
        if (self.getIndex(key)) |i| return &self.slots.items(.entry)[i];
        return null;
    }

    /// Returns a copy of the `CacheEntry` corresponding to `key`, or null if
    /// not present.
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

    /// Updates or clears the in-flight lifecycle state for a cache slot,
    /// cancelling any superseded `.decoding` job ticket.
    pub fn setInFlight(
        self: *ImageCache,
        key: ImageCacheKey,
        inflight: InFlightState,
    ) void {
        const idx = self.getIndex(key) orelse return;
        const entry = &self.slots.items(.entry)[idx];
        switch (entry.inflight) {
            .decoding => |old_dec| switch (inflight) {
                .decoding => |new_dec| {
                    if (old_dec.ticket.job_id != new_dec.ticket.job_id) {
                        self.cancelJob(old_dec.ticket.job_id);
                    }
                },
                .idle, .queued_decode, .uploading => {
                    self.cancelJob(old_dec.ticket.job_id);
                },
            },
            .idle, .queued_decode, .uploading => {},
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

    /// Removes a slot at `index_in_list` via swap-remove and releases its GPU
    /// texture.
    pub fn removeAndDeinit(
        self: *ImageCache,
        index_in_list: usize,
        gpu_device: ?sdl.gpu.Device,
    ) void {
        var entry = self.slots.items(.entry)[index_in_list];
        switch (entry.inflight) {
            .decoding => |dec| self.cancelJob(dec.ticket.job_id),
            .idle, .queued_decode, .uploading => {},
        }
        self.slots.swapRemove(index_in_list);
        entry.deinit(gpu_device);
    }

    pub const DEFAULT_MAX_VRAM_BYTES: usize = 1024 * 1024 * 1024;

    /// Computes the total VRAM consumption in bytes across all active GPU
    /// textures (`.loaded_gpu` and `.promoting_gpu`) in the cache.
    pub fn getTotalVramBytes(self: *const ImageCache) usize {
        var total: usize = 0;
        const entries = self.slots.items(.entry);
        for (entries) |entry| {
            switch (entry.resident.asset) {
                .loaded_gpu => |gpu| total += gpu.ingest.memory_size_bytes,
                .promoting_gpu => |promo| {
                    total += promo.active.ingest.memory_size_bytes;
                },
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
                if (!entry.resident.asset.hasGpuTexture()) continue;
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
                if (!entry.inflight.isIdle()) return true;
                switch (entry.resident.asset) {
                    .loaded_gpu => {
                        const staged = entry.resident.thumbnail.isStagedCpu();
                        if (has_gpu and staged) {
                            return true;
                        }
                    },
                    .failed => {},
                    .loaded_cpu, .promoting_gpu => {
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

    /// Returns `true` when a GPU device is present and any cache slot holds a
    /// CPU-decoded surface (`.loaded_cpu`, `.promoting_gpu`, or
    /// `ThumbnailState.staged_cpu`) awaiting GPU texture upload.
    pub fn hasPendingCpuUploads(
        self: *const ImageCache,
        has_gpu: bool,
    ) bool {
        if (!has_gpu) return false;
        for (self.slots.items(.entry)) |entry| {
            switch (entry.resident.asset) {
                .loaded_cpu, .promoting_gpu => return true,
                .loaded_gpu, .none => {
                    if (entry.resident.thumbnail.isStagedCpu()) return true;
                },
                .failed => {},
            }
        }
        return false;
    }
};

/// Inspects the decoded thumbnail CPU surface to detect whether letterbox (or
/// pillarbox) black bars have been padded and snapped to 8-pixel DCT block
/// boundaries by in-camera preview encoders (e.g. Fujifilm RAF, Ricoh GR IIIx
/// JPEG).
/// Requires candidate DCT boundary lines to be black AND active image content
/// to begin at the 8px boundary.
/// If candidate boundary lines contain image data (e.g. Sony ARW, standard
/// JPEGs) OR if the scene itself is an extended solid black background (e.g.
/// astrophotography), returns false to use theoretical aspect-ratio padding.
pub fn detectThumbnailDctPadding(
    surf: sdl.Surface,
    full_w: f32,
    full_h: f32,
) bool {
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

    // Tolerant to lossy JPEG compression ringing / chroma near boundaries.
    const threshold: u8 = 16;

    if (ar_full > ar_thumb) {
        // Letterboxing: full image is wider than container -> black bars on top
        // and bottom.
        const raw_pad_px = (thumb_h - (thumb_w / ar_full)) / 2.0;
        const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;

        if (nearest_block_px > 0.0 and
            nearest_block_px * 2.0 < thumb_h and
            @abs(raw_pad_px - nearest_block_px) <= 2.0)
        {
            const test_row_top: i32 = @intFromFloat(nearest_block_px - 1.0);
            const block_px_i32: i32 = @intFromFloat(nearest_block_px);
            const test_row_bot: i32 = sh - block_px_i32;

            // Candidate DCT padding rows must both be black
            if (surf.isRowBlack(test_row_top, threshold) and
                surf.isRowBlack(test_row_bot, threshold))
            {
                // Verify active image content begins at DCT block boundary
                // (step-transition). If both row 8 and row 111 are ALSO black,
                // the photo has an extended black background; treating
                // continuous black backgrounds as theoretical padding prevents
                // false-positive distortion.
                const first_image_row_top: i32 = block_px_i32;
                const last_image_row_bot: i32 = sh - block_px_i32 - 1;

                if (!surf.isRowBlack(first_image_row_top, threshold) or
                    !surf.isRowBlack(last_image_row_bot, threshold))
                {
                    return true;
                }
            }
        }
    } else {
        // Pillarboxing: full image is taller than container -> black bars on
        // left and right.
        const raw_pad_px = (thumb_w - (thumb_h * ar_full)) / 2.0;
        const nearest_block_px = @round(raw_pad_px / 8.0) * 8.0;

        if (nearest_block_px > 0.0 and
            nearest_block_px * 2.0 < thumb_w and
            @abs(raw_pad_px - nearest_block_px) <= 2.0)
        {
            const test_col_left: i32 = @intFromFloat(nearest_block_px - 1.0);
            const block_px_i32: i32 = @intFromFloat(nearest_block_px);
            const test_col_right: i32 = sw - block_px_i32;

            if (surf.isColBlack(test_col_left, threshold) and
                surf.isColBlack(test_col_right, threshold))
            {
                const first_image_col_left: i32 = block_px_i32;
                const last_image_col_right: i32 = sw - block_px_i32 - 1;

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

/// Return payload containing converted/scaled surface and elapsed time in ms.
pub const ConvertResult = struct {
    surface: ?sdl.Surface,
    conversion_time_ms: f64 = 0.0,
};

/// Scales and converts an image surface on a worker thread to prepare it for
/// GPU upload or CPU display.
pub fn convertAndScaleSurface(
    io: std.Io,
    surface: ?sdl.Surface,
    pix_fmt: u32,
    has_gpu_device: bool,
) ConvertResult {
    var final_surface = surface;
    var conversion_time_ms: f64 = 0.0;
    if (surface) |surf| {
        if (!has_gpu_device and
            pix_fmt != sdl.PixelFormat.unknown and
            surf.format() != pix_fmt)
        {
            const start_convert = std.Io.Clock.awake.now(io);
            if (surf.convert(pix_fmt)) |conv| {
                conversion_time_ms = state_pkg.durationToMs(
                    start_convert.untilNow(io, .awake),
                );
                surf.destroy();
                final_surface = conv;
            } else {
                std.log.err(
                    "SDL_ConvertSurface failed: {s}",
                    .{sdl.getError()},
                );
            }
        } else if (has_gpu_device) {
            // For GPU rendering:
            // - 24-bit RGB/BGR surfaces are left as-is so the GPU compute
            //   unpack shader (`unpack_rgb.comp.glsl`) can unpack them directly
            //   into RGBA32 in VRAM.
            // - Exotic formats (e.g. paletted 8-bit, grayscale) are converted
            //   here on the background worker thread to prevent main-thread
            //   format conversion stalls.
            const cur_fmt = surf.format();
            const is_32bit = switch (cur_fmt) {
                sdl.PixelFormat.rgba32,
                sdl.PixelFormat.bgra32,
                sdl.PixelFormat.xrgb8888,
                sdl.PixelFormat.xbgr8888,
                sdl.PixelFormat.rgbx8888,
                sdl.PixelFormat.bgrx8888,
                => true,
                else => false,
            };
            if (!is_32bit and
                cur_fmt != sdl.PixelFormat.rgb24 and
                cur_fmt != sdl.PixelFormat.bgr24)
            {
                const start_convert = std.Io.Clock.awake.now(io);
                if (surf.convert(sdl.PixelFormat.rgba32)) |conv| {
                    conversion_time_ms = state_pkg.durationToMs(
                        start_convert.untilNow(io, .awake),
                    );
                    surf.destroy();
                    final_surface = conv;
                } else {
                    std.log.err(
                        "SDL_ConvertSurface failed: {s}",
                        .{sdl.getError()},
                    );
                }
            }
        }

        if (final_surface) |f_surf| {
            const max_dim: i32 = 8192;
            if (f_surf.w() > max_dim or f_surf.h() > max_dim) {
                var new_w = f_surf.w();
                var new_h = f_surf.h();
                if (f_surf.w() > f_surf.h()) {
                    new_w = max_dim;
                    new_h = @divTrunc(f_surf.h() * max_dim, f_surf.w());
                } else {
                    new_h = max_dim;
                    new_w = @divTrunc(f_surf.w() * max_dim, f_surf.h());
                }
                new_w = @max(1, new_w);
                new_h = @max(1, new_h);

                const scaled = f_surf.scale(new_w, new_h, .linear);
                if (scaled) |sc| {
                    f_surf.destroy();
                    final_surface = sc;
                } else {
                    std.log.err(
                        "convertAndScaleSurface: SDL_ScaleSurface failed: {s}",
                        .{sdl.getError()},
                    );
                }
            }
        }
    }
    return .{
        .surface = final_surface,
        .conversion_time_ms = conversion_time_ms,
    };
}

test "enforceVramBudget - eviction, circular distance, neighbor protection" {
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
    const ticket = cache.allocJob().?;
    cache.setInFlight(
        cache.activeKey(mock_nav.getIdAt(2).?),
        .{
            .decoding = .{ .ticket = ticket },
        },
    );
    try std.testing.expect(cache.hasUnreadyPrefetchSlots(mock_nav, n5, true));

    // One slot is loaded_cpu: unready if has_gpu=true, ready if has_gpu=false
    const surf = sdl.Surface.create(1, 1, sdl.PixelFormat.rgba32) orelse return;
    cache.setInFlight(cache.activeKey(mock_nav.getIdAt(2).?), .idle);
    try std.testing.expectEqual(@as(u16, 0), cache.job_alloc_mask);
    cache.setResidentAsset(cache.activeKey(mock_nav.getIdAt(2).?), .{
        .loaded_cpu = .{
            .cpu = .{
                .surface = surf,
                .w = 100,
                .h = 100,
                .size_bytes = 100,
            },
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
    const ticket10 = cache.allocJob().?;
    const ticket20 = cache.allocJob().?;
    _ = try cache.appendSlot(allocator, id10, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket10 },
        },
    });
    _ = try cache.appendSlot(allocator, id20, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket20 },
        },
    });

    // Test updating resident asset and in-flight status
    const key10 = ImageCacheKey{ .id = id10, .generation = 1 };
    const key20 = ImageCacheKey{ .id = id20, .generation = 1 };
    cache.setResidentAsset(key20, .failed, null);
    cache.setInFlight(key20, .idle);

    try std.testing.expectEqual(
        ResidentAsset.failed,
        cache.slots.items(.entry)[1].resident.asset,
    );
    try std.testing.expectEqual(
        InFlightState.idle,
        cache.slots.items(.entry)[1].inflight,
    );
    try std.testing.expectEqual(
        ticket20.epoch + 1,
        cache.job_epochs[ticket20.job_id].load(.acquire),
    );
    const bit10 = @as(u16, 1) << @as(u4, @truncate(ticket10.job_id));
    try std.testing.expectEqual(bit10, cache.job_alloc_mask);

    // Transitioning .decoding -> .queued_decode also cancels the job ticket
    cache.setInFlight(key10, .{
        .queued_decode = .{ .start_time_ms = 55 },
    });
    try std.testing.expectEqual(@as(u16, 0), cache.job_alloc_mask);
    try std.testing.expectEqual(
        ticket10.epoch + 1,
        cache.job_epochs[ticket10.job_id].load(.acquire),
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

test "detectThumbnailDctPadding - matching aspect ratio returns false" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse
        return;
    defer surf.destroy();
    try std.testing.expect(!detectThumbnailDctPadding(surf, 1600.0, 1200.0));
}

test "detectThumbnailDctPadding - invalid dimensions return false" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse
        return;
    defer surf.destroy();
    try std.testing.expect(!detectThumbnailDctPadding(surf, 0.0, 1200.0));
    try std.testing.expect(!detectThumbnailDctPadding(surf, 1600.0, 0.0));
}

test "detectThumbnailDctPadding - detects 8px DCT block snapping" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse
        return;
    defer surf.destroy();

    // Fill rows 0..7 and 112..119 with black (0), rows 8..111 with bright (200)
    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();
    var y: usize = 0;
    while (y < 120) : (y += 1) {
        const val: u8 = if (y < 8 or y >= 112) 0 else 200;
        const row = px + y * pitch;
        @memset(row[0 .. 160 * 3], val);
    }

    // 3:2 full image (6000x4000) in 4:3 thumb (160x120): pad is 6.67px.
    // Snaps to 8px DCT block; candidate row 7 and row 112 are black, and row 8
    // has image pixels -> returns true
    try std.testing.expect(detectThumbnailDctPadding(surf, 6000.0, 4000.0));
}

test "detectThumbnailDctPadding - false when row 7 has active image pixels" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse
        return;
    defer surf.destroy();

    // Active image begins at row 7 (e.g. theoretical 6.67px pad in Sony ARW)
    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();
    var y: usize = 0;
    while (y < 120) : (y += 1) {
        const val: u8 = if (y < 7 or y >= 113) 0 else 200;
        const row = px + y * pitch;
        @memset(row[0 .. 160 * 3], val);
    }

    // Row 7 has bright pixels (200 > 16) -> not snapped to 8px DCT boundary
    try std.testing.expect(!detectThumbnailDctPadding(surf, 6000.0, 4000.0));
}

test "detectThumbnailDctPadding - solid black background returns false" {
    const surf = sdl.Surface.create(160, 120, sdl.PixelFormat.rgb24) orelse
        return;
    defer surf.destroy();

    // Entire surface is pure black (e.g. astrophotography / black backdrop)
    const pitch: usize = @intCast(surf.pitch());
    const px = surf.pixels();
    var y: usize = 0;
    while (y < 120) : (y += 1) {
        const row = px + y * pitch;
        @memset(row[0 .. 160 * 3], 0);
    }

    // Because rows 8 and 111 are also black (no step-transition at row 8),
    // it correctly avoids a false-positive DCT snapping detection.
    try std.testing.expect(!detectThumbnailDctPadding(surf, 6000.0, 4000.0));
}

test "ImageCache - Key lookup by MediaId remains valid after sort shift" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const id1 = MediaId.fromU32(1);
    const ticket1 = cache.allocJob().?;
    const key1 = try cache.appendSlot(allocator, id1, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket1 },
        },
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
            .decoding = .{ .ticket = ticket },
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

test "ImageCache.validateJobEpoch" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const id_idle = MediaId.fromU32(1);
    const id_queued = MediaId.fromU32(2);
    const id_uploading = MediaId.fromU32(3);
    const id_decoding = MediaId.fromU32(4);

    _ = try cache.appendSlot(allocator, id_idle, .{});
    _ = try cache.appendSlot(allocator, id_queued, .{
        .inflight = .{ .queued_decode = .{} },
    });
    _ = try cache.appendSlot(allocator, id_uploading, .{
        .inflight = .{ .uploading = .{} },
    });

    const ticket = cache.allocJob().?;
    _ = try cache.appendSlot(allocator, id_decoding, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket },
        },
    });

    try std.testing.expect(!cache.validateJobEpoch(0, 0));
    try std.testing.expect(!cache.validateJobEpoch(0, 1));
    try std.testing.expect(!cache.validateJobEpoch(1, 0));
    try std.testing.expect(!cache.validateJobEpoch(1, 1));
    try std.testing.expect(!cache.validateJobEpoch(2, 0));
    try std.testing.expect(!cache.validateJobEpoch(2, 1));
    try std.testing.expect(cache.validateJobEpoch(3, ticket.epoch));
    try std.testing.expect(!cache.validateJobEpoch(3, ticket.epoch + 1));
    try std.testing.expect(!cache.validateJobEpoch(99, ticket.epoch));
}

test "CacheEntry - updateFullDims and monotonic probed metadata integration" {
    var entry = CacheEntry{};
    try std.testing.expectEqual(
        @as(?PhysicalDims, null),
        entry.metadata.full_dims,
    );

    // Initial update sets full_dims
    entry.updateFullDims(.{ .w = 1616.0, .h = 1080.0 });
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
            .cpu = .{
                .surface = undefined,
                .w = 1920.0,
                .h = 1080.0,
                .size_bytes = 1000,
            },
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
    var resident = CacheEntry.stubLoadedGpuForTest(
        .{ .w = 1920.0, .h = 1080.0 },
        .{ .w = 160.0, .h = 120.0 },
    ).resident;
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
                .cpu = .{
                    .surface = surf,
                    .w = 1.0,
                    .h = 1.0,
                    .size_bytes = 4,
                },
            },
        },
    };
    cpu_resident.deinit(null);
    try std.testing.expectEqual(ThumbnailState.none, cpu_resident.thumbnail);
    try std.testing.expectEqual(ResidentAsset.none, cpu_resident.asset);
}

test "ImageCache - promoting_gpu and staged_cpu readiness and deinit" {
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
    const n1 = VisibleNeighbors.fromRawIndex(0, 1);

    const id0 = MediaId.fromU32(1);
    const stub = CacheEntry.stubLoadedGpuForTest(
        .{ .w = 100.0, .h = 100.0 },
        .{ .w = 0.0, .h = 0.0 },
    );
    const active_gpu = switch (stub.resident.asset) {
        .loaded_gpu => |g| g,
        .none, .loaded_cpu, .promoting_gpu, .failed => unreachable,
    };
    const key0 = try cache.appendSlot(allocator, id0, stub);
    try std.testing.expect(!cache.hasPendingCpuUploads(true));
    try std.testing.expect(!cache.hasUnreadyPrefetchSlots(mock_nav, n1, true));

    // Staged .promoting_gpu marks cache as having pending GPU uploads
    const upload_surf = sdl.Surface.create(8, 8, sdl.PixelFormat.rgba32) orelse
        return;
    cache.setResidentAsset(key0, .{
        .promoting_gpu = .{
            .active = active_gpu,
            .staged = .{
                .cpu = .{
                    .surface = upload_surf,
                    .w = 8.0,
                    .h = 8.0,
                    .size_bytes = 256,
                },
            },
        },
    }, null);
    try std.testing.expect(cache.hasPendingCpuUploads(true));
    try std.testing.expect(!cache.hasPendingCpuUploads(false));
    try std.testing.expect(cache.hasUnreadyPrefetchSlots(mock_nav, n1, true));

    // Staged .staged_cpu thumbnail also marks cache as having pending uploads
    cache.setResidentAsset(key0, .{ .loaded_gpu = active_gpu }, null);
    const thumb_surf = sdl.Surface.create(4, 4, sdl.PixelFormat.rgba32) orelse
        return;
    cache.get(key0).?.resident.thumbnail = .{
        .staged_cpu = .{
            .surface = thumb_surf,
            .dct_snapped = true,
        },
    };
    try std.testing.expect(cache.hasPendingCpuUploads(true));
    try std.testing.expect(cache.hasUnreadyPrefetchSlots(mock_nav, n1, true));

    // Re-staging .promoting_gpu and clearing cache destroys staged surfaces
    const promo_surf = sdl.Surface.create(16, 16, sdl.PixelFormat.rgba32) orelse
        return;
    cache.setResidentAsset(key0, .{
        .promoting_gpu = .{
            .active = active_gpu,
            .staged = .{
                .cpu = .{
                    .surface = promo_surf,
                    .w = 16.0,
                    .h = 16.0,
                    .size_bytes = 1024,
                },
            },
        },
    }, null);
    cache.clear(null);
    try std.testing.expect(!cache.hasPendingCpuUploads(true));

    // Failed slot with stranded staged_cpu must not report pending/unready
    const fail_thumb = sdl.Surface.create(4, 4, sdl.PixelFormat.rgba32) orelse
        return;
    _ = try cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .failed,
            .thumbnail = .{ .staged_cpu = .{ .surface = fail_thumb } },
        },
    });
    try std.testing.expect(!cache.hasPendingCpuUploads(true));
    try std.testing.expect(!cache.hasUnreadyPrefetchSlots(mock_nav, n1, true));
}

test "ImageCache resets current_image_cache_hit across lifecycle methods" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    try std.testing.expect(!cache.current_image_cache_hit);

    cache.current_image_cache_hit = true;
    _ = cache.advanceGeneration();
    try std.testing.expect(!cache.current_image_cache_hit);

    cache.current_image_cache_hit = true;
    cache.clear(null);
    try std.testing.expect(!cache.current_image_cache_hit);

    cache.current_image_cache_hit = true;
    cache.clearRetainingCapacity();
    try std.testing.expect(!cache.current_image_cache_hit);

    cache.current_image_cache_hit = true;
    cache.deinit(allocator, null);
    try std.testing.expect(!cache.current_image_cache_hit);
}

test "CacheEntry.computeThumbnailUvRect handles pre-oriented cached thumbs" {
    const entry = CacheEntry{
        .metadata = .{
            .full_dims = .{ .w = 6000.0, .h = 4000.0 },
            .orientation = .rotate_90,
        },
    };
    const auth = entry.getAuthoritativeDims();

    // 3:2 full image in 4:3 embedded thumb gets letterbox UV crop; not swapped
    const embedded_uv = entry.computeThumbnailUvRect(
        .{
            .w = 160.0,
            .h = 120.0,
            .source = .embedded_header,
            .dct_snapped = true,
        },
        auth,
        90.0,
    );
    try std.testing.expectEqual(@as(f32, 1.0), embedded_uv.alpha);
    try std.testing.expectEqual(@as(f32, 90.0), embedded_uv.rotation_angle);
    try std.testing.expectEqual(@as(f32, 6000.0), embedded_uv.source_w);
    try std.testing.expectEqual(@as(f32, 4000.0), embedded_uv.source_h);
    try std.testing.expectApproxEqAbs(
        @as(f32, 8.0 / 120.0),
        embedded_uv.v_min,
        0.001,
    );

    // Pre-oriented cached thumb swaps ref_full (4000x6000) -> no crop, 0 deg
    const cached_uv = entry.computeThumbnailUvRect(
        .{ .w = 170.0, .h = 256.0, .source = .freedesktop_cache },
        auth,
        90.0,
    );
    try std.testing.expectEqual(@as(f32, 1.0), cached_uv.alpha);
    try std.testing.expectEqual(@as(f32, 0.0), cached_uv.rotation_angle);
    try std.testing.expectEqual(@as(f32, 4000.0), cached_uv.source_w);
    try std.testing.expectEqual(@as(f32, 6000.0), cached_uv.source_h);
    try std.testing.expectEqual(@as(f32, 0.0), cached_uv.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), cached_uv.u_max);
    try std.testing.expectEqual(@as(f32, 0.0), cached_uv.v_min);
    try std.testing.expectEqual(@as(f32, 1.0), cached_uv.v_max);

    // Negative rotation difference wraps cleanly via Euclidean @mod
    const wrapped_uv = entry.computeThumbnailUvRect(
        .{ .w = 170.0, .h = 256.0, .source = .freedesktop_cache },
        auth,
        0.0,
    );
    try std.testing.expectEqual(@as(f32, 270.0), wrapped_uv.rotation_angle);

    // 180-deg pre-oriented thumb compensates angle without swapping dims
    const entry_180 = CacheEntry{
        .metadata = .{
            .full_dims = .{ .w = 6000.0, .h = 4000.0 },
            .orientation = .rotate_180,
        },
    };
    const uv_180 = entry_180.computeThumbnailUvRect(
        .{ .w = 256.0, .h = 170.0, .source = .freedesktop_cache },
        .{ .w = 6000.0, .h = 4000.0 },
        180.0,
    );
    try std.testing.expectEqual(@as(f32, 0.0), uv_180.rotation_angle);
    try std.testing.expectEqual(@as(f32, 6000.0), uv_180.source_w);
    try std.testing.expectEqual(@as(f32, 4000.0), uv_180.source_h);

    // Missing full_dims yields uncropped 0..1 UVs while still swapping auth
    const entry_no_full = CacheEntry{
        .metadata = .{ .orientation = .rotate_270 },
    };
    const uv_no_full = entry_no_full.computeThumbnailUvRect(
        .{ .w = 170.0, .h = 256.0, .source = .freedesktop_cache },
        .{ .w = 6000.0, .h = 4000.0 },
        0.0,
    );
    try std.testing.expectEqual(@as(f32, 90.0), uv_no_full.rotation_angle);
    try std.testing.expectEqual(@as(f32, 4000.0), uv_no_full.source_w);
    try std.testing.expectEqual(@as(f32, 6000.0), uv_no_full.source_h);
    try std.testing.expectEqual(@as(f32, 0.0), uv_no_full.u_min);
    try std.testing.expectEqual(@as(f32, 1.0), uv_no_full.v_max);
}
