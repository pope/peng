const std = @import("std");

/// Rolling window of recent frame render duration samples computing mean and
/// standard deviation.
pub const RenderStats = struct {
    samples: [60]f64 = @splat(0.0),
    head: usize = 0,
    count: usize = 0,

    /// Records a new duration sample in milliseconds into the 60-slot rolling
    /// ring buffer.
    pub fn addSample(self: *RenderStats, sample_ms: f64) void {
        self.samples[self.head] = sample_ms;
        self.head = (self.head + 1) % 60;
        if (self.count < 60) self.count += 1;
    }

    /// Computes the arithmetic mean and sample standard deviation across all
    /// recorded duration samples.
    pub fn getMeanAndStdev(self: RenderStats) struct { mean: f64, stdev: f64 } {
        if (self.count == 0) return .{ .mean = 0.0, .stdev = 0.0 };
        var sum: f64 = 0.0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            sum += self.samples[i];
        }
        const mean = sum / @as(f64, @floatFromInt(self.count));
        if (self.count < 2) return .{ .mean = mean, .stdev = 0.0 };

        var variance_sum: f64 = 0.0;
        i = 0;
        while (i < self.count) : (i += 1) {
            const diff = self.samples[i] - mean;
            variance_sum += diff * diff;
        }
        const variance = @max(0.0, variance_sum) /
            @as(f64, @floatFromInt(self.count - 1));
        return .{ .mean = mean, .stdev = @sqrt(variance) };
    }
};

/// Snapshot of UI rendering timing statistics, batch counts, and vertex counts
/// for on-screen telemetry.
pub const UiRenderMetricsSnapshot = struct {
    mean_render_time_ms: f64 = 0.0,
    stdev_render_time_ms: f64 = 0.0,
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,
};

/// UI frame rendering performance metrics, vertex counts, batch counts, and
/// rolling duration history.
pub const UiRenderMetrics = struct {
    ui_render_stats: RenderStats = .{},
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,

    /// Creates an immutable performance snapshot containing calculated
    /// mean/stdev and element counts.
    pub fn toSnapshot(self: UiRenderMetrics) UiRenderMetricsSnapshot {
        const stats = self.ui_render_stats.getMeanAndStdev();
        return .{
            .mean_render_time_ms = stats.mean,
            .stdev_render_time_ms = stats.stdev,
            .last_ui_vertex_count = self.last_ui_vertex_count,
            .last_ui_batch_count = self.last_ui_batch_count,
        };
    }
};

/// Container extraction metrics for compressed images (CBZ / ZIP archives).
pub const ArchiveTelemetry = union(enum) {
    none,
    archive: struct {
        decompress_time_ms: f64,
        compressed_size_bytes: usize,
    },

    /// Constructs an ArchiveTelemetry variant based on decompression stats.
    pub fn init(
        decompress_time_ms: f64,
        compressed_size_bytes: usize,
    ) ArchiveTelemetry {
        if (compressed_size_bytes > 0 or decompress_time_ms > 0.0) {
            return .{
                .archive = .{
                    .decompress_time_ms = decompress_time_ms,
                    .compressed_size_bytes = compressed_size_bytes,
                },
            };
        }
        return .none;
    }
};

/// Hardware upload strategy executed for GPU texture allocation.
pub const UploadMode = union(enum) {
    direct,
    fallback: struct {
        fallback_time_ms: f64,
    },

    /// Constructs an UploadMode variant indicating direct upload or fallback.
    pub fn init(was_fallback: bool, fallback_time_ms: f64) UploadMode {
        if (was_fallback) {
            return .{ .fallback = .{ .fallback_time_ms = fallback_time_ms } };
        }
        return .direct;
    }
};

/// Mipmap pyramid generation status and performance timing.
pub const MipmapTelemetry = union(enum) {
    disabled,
    generated: struct {
        num_levels: u32,
        generate_time_ms: f64,
    },

    /// Constructs a MipmapTelemetry variant for single or multi-level textures.
    pub fn init(num_levels: u32, generate_time_ms: f64) MipmapTelemetry {
        if (num_levels > 1) {
            return .{
                .generated = .{
                    .num_levels = num_levels,
                    .generate_time_ms = generate_time_ms,
                },
            };
        }
        return .disabled;
    }
};

/// Performance timing metrics common to all CPU image decompressions.
pub const DecodeTelemetry = struct {
    read_time_ms: f64 = 0.0,
    decode_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    archive: ArchiveTelemetry = .none,
};

/// Telemetry metrics specific to GPU texture upload, downscaling, and mipmaps.
pub const IngestTelemetry = struct {
    upload_time_ms: f64 = 0.0,
    memory_size_bytes: usize = 0,
    mode: UploadMode = .direct,
    mipmaps: MipmapTelemetry = .disabled,
};

/// Source from which a preview thumbnail was loaded.
pub const ThumbnailSource = enum {
    /// Extracted from the initial 256 KB header read (EXIF IFD1 or SubIFD).
    embedded_header,
    /// Extracted via positional read at an offset beyond the 256 KB header.
    embedded_positional,
    /// Loaded from the Freedesktop Shared Thumbnail Cache
    /// (`$XDG_CACHE_HOME/thumbnails/`).
    freedesktop_cache,

    /// Returns `true` if the thumbnail bitmap is already rotated into upright
    /// visual orientation on disk (true for Freedesktop cached PNGs, false for
    /// unrotated embedded EXIF thumbnails).
    pub inline fn isPreOriented(self: ThumbnailSource) bool {
        return switch (self) {
            .embedded_header, .embedded_positional => false,
            .freedesktop_cache => true,
        };
    }

    /// Short label for "Stats for Nerds" HUD rows.
    pub fn shortLabel(self: ThumbnailSource) []const u8 {
        return switch (self) {
            .embedded_header => "Header",
            .embedded_positional => "Positional",
            .freedesktop_cache => "XDG Cache",
        };
    }

    /// Descriptive label for "Info Overlay" HUD rows.
    pub fn infoLabel(self: ThumbnailSource) []const u8 {
        return switch (self) {
            .embedded_header, .embedded_positional => "Embedded",
            .freedesktop_cache => "Freedesktop",
        };
    }
};

/// Lightweight thumbnail dimension, GPU upload latency, source, and DCT block
/// snapping metadata.
pub const ThumbnailInfo = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,
    upload_time_ms: f64 = 0.0,
    dct_snapped: bool = false,
    source: ThumbnailSource = .embedded_header,
};

/// Active image performance telemetry for Stats for Nerds overlay.
pub const ActiveImageStats = struct {
    decode: ?DecodeTelemetry = null,
    ingest: ?IngestTelemetry = null,
    has_thumb: bool = false,
    thumb_upload_time_ms: f64 = 0.0,
    thumb_source: ThumbnailSource = .embedded_header,
};

/// Unified telemetry counters for thumbnail extraction, shared cache reads,
/// and background shared cache writes.
pub const ThumbnailStats = struct {
    header_hits: usize = 0,
    positional_hits: usize = 0,
    cache_hits: usize = 0,
    misses: usize = 0,
    cache_writes: usize = 0,
    cache_write_queued: usize = 0,

    /// Total number of thumbnail lookup attempts across all sources and misses.
    pub inline fn totalLookups(self: ThumbnailStats) usize {
        return self.header_hits +
            self.positional_hits +
            self.cache_hits +
            self.misses;
    }
};

/// Snapshot of application telemetry and diagnostic counters copied once per
/// frame for UI rendering ("Stats for Nerds") without reading live atomics.
pub const ViewerStats = struct {
    // Unified EXIF & Freedesktop thumbnail telemetry
    thumbs: ThumbnailStats = .{},

    // Cache telemetry
    current_image_cache_hit: bool = false,
    cached_slot_count: usize = 0,
    total_vram_bytes: usize = 0,

    // Worker telemetry (frame snapshot)
    active_decode_threads: usize = 0,
    max_decode_threads: usize = 0,

    // Active image GPU & decoder stats
    active_image: ActiveImageStats = .{},
};

test "ArchiveTelemetry - init returns .none for normal and .archive for CBZ" {
    const none_val = ArchiveTelemetry.init(0.0, 0);
    try std.testing.expectEqual(ArchiveTelemetry.none, none_val);

    const arch_time = ArchiveTelemetry.init(14.5, 0);
    switch (arch_time) {
        .none => return error.TestExpectedArchive,
        .archive => |a| {
            try std.testing.expectEqual(@as(f64, 14.5), a.decompress_time_ms);
            try std.testing.expectEqual(@as(usize, 0), a.compressed_size_bytes);
        },
    }

    const arch_size = ArchiveTelemetry.init(0.0, 1024);
    switch (arch_size) {
        .none => return error.TestExpectedArchive,
        .archive => |a| {
            try std.testing.expectEqual(@as(f64, 0.0), a.decompress_time_ms);
            try std.testing.expectEqual(
                @as(usize, 1024),
                a.compressed_size_bytes,
            );
        },
    }
}

test "UploadMode - init distinguishes direct VRAM from fallback" {
    const direct_mode = UploadMode.init(false, 0.0);
    try std.testing.expectEqual(UploadMode.direct, direct_mode);

    const fallback_mode = UploadMode.init(true, 12.5);
    switch (fallback_mode) {
        .direct => return error.TestExpectedFallback,
        .fallback => |fb| {
            try std.testing.expectEqual(@as(f64, 12.5), fb.fallback_time_ms);
        },
    }
}

test "MipmapTelemetry - init distinguishes disabled from multi-level" {
    const disabled_mip = MipmapTelemetry.init(1, 0.0);
    try std.testing.expectEqual(MipmapTelemetry.disabled, disabled_mip);

    const gen_mip = MipmapTelemetry.init(4, 5.2);
    switch (gen_mip) {
        .disabled => return error.TestExpectedGenerated,
        .generated => |g| {
            try std.testing.expectEqual(@as(u32, 4), g.num_levels);
            try std.testing.expectEqual(@as(f64, 5.2), g.generate_time_ms);
        },
    }
}

test "RenderStats, UiRenderMetrics, and Thumbnail telemetry" {
    // 1. RenderStats empty
    var rs = RenderStats{};
    const empty_ms = rs.getMeanAndStdev();
    try std.testing.expectEqual(@as(f64, 0.0), empty_ms.mean);
    try std.testing.expectEqual(@as(f64, 0.0), empty_ms.stdev);

    // 2. RenderStats samples
    rs.addSample(10.0);
    rs.addSample(20.0);
    const ms = rs.getMeanAndStdev();
    try std.testing.expectEqual(@as(f64, 15.0), ms.mean);
    try std.testing.expect(ms.stdev > 0.0);

    // 3. UiRenderMetrics toSnapshot
    var metrics = UiRenderMetrics{
        .ui_render_stats = rs,
        .last_ui_vertex_count = 120,
        .last_ui_batch_count = 4,
    };
    const snap = metrics.toSnapshot();
    try std.testing.expectEqual(@as(f64, 15.0), snap.mean_render_time_ms);
    try std.testing.expectEqual(@as(usize, 120), snap.last_ui_vertex_count);
    try std.testing.expectEqual(@as(usize, 4), snap.last_ui_batch_count);

    // 4. ThumbnailSource properties
    try std.testing.expect(!ThumbnailSource.embedded_header.isPreOriented());
    try std.testing.expect(
        !ThumbnailSource.embedded_positional.isPreOriented(),
    );
    try std.testing.expect(ThumbnailSource.freedesktop_cache.isPreOriented());

    try std.testing.expectEqualStrings(
        "Header",
        ThumbnailSource.embedded_header.shortLabel(),
    );
    try std.testing.expectEqualStrings(
        "Positional",
        ThumbnailSource.embedded_positional.shortLabel(),
    );
    try std.testing.expectEqualStrings(
        "XDG Cache",
        ThumbnailSource.freedesktop_cache.shortLabel(),
    );

    try std.testing.expectEqualStrings(
        "Embedded",
        ThumbnailSource.embedded_header.infoLabel(),
    );
    try std.testing.expectEqualStrings(
        "Freedesktop",
        ThumbnailSource.freedesktop_cache.infoLabel(),
    );

    // 5. ThumbnailStats totalLookups
    const ts = ThumbnailStats{
        .header_hits = 1,
        .positional_hits = 2,
        .cache_hits = 3,
        .misses = 4,
    };
    try std.testing.expectEqual(@as(usize, 10), ts.totalLookups());
}
