const std = @import("std");

/// Converts a `std.Io.Duration` into non-negative fractional milliseconds.
pub inline fn durationToMs(dur: std.Io.Duration) f64 {
    return @as(f64, @floatFromInt(@max(0, dur.nanoseconds))) /
        @as(f64, std.time.ns_per_ms);
}

/// Computes active milliseconds by subtracting a clamped non-negative
/// `excluded` wait span from `total` with saturating protection.
pub inline fn activeDurationMs(
    total: std.Io.Duration,
    excluded: std.Io.Duration,
) f64 {
    const total_ns: u128 = @intCast(@max(0, total.nanoseconds));
    const excl_ns: u128 = @intCast(@max(0, excluded.nanoseconds));
    return @as(f64, @floatFromInt(total_ns -| excl_ns)) /
        @as(f64, std.time.ns_per_ms);
}

/// Converts a monotonic `std.Io.Timestamp` into non-negative `u64`
/// milliseconds, clamping at `0` and saturating at `std.math.maxInt(u64)`.
pub inline fn timestampToMs(ts: std.Io.Timestamp) u64 {
    const clamped_ms = @min(
        @as(i96, std.math.maxInt(u64)),
        @divTrunc(@max(0, ts.nanoseconds), std.time.ns_per_ms),
    );
    return @intCast(clamped_ms);
}

/// Summary statistics (mean, sample standard deviation, and peak value) across
/// a rolling window of duration samples in milliseconds.
pub const StatsSummary = struct {
    mean: f64 = 0.0,
    stdev: f64 = 0.0,
    max: f64 = 0.0,
};

/// Rolling window of recent duration samples computing mean, standard
/// deviation, and rolling peak.
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

    /// Computes the arithmetic mean, sample standard deviation, and rolling
    /// maximum across all recorded duration samples.
    pub fn summarize(self: RenderStats) StatsSummary {
        if (self.count == 0) return .{};
        var sum: f64 = 0.0;
        var max_val: f64 = self.samples[0];
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const sample = self.samples[i];
            sum += sample;
            max_val = @max(max_val, sample);
        }
        const mean = sum / @as(f64, @floatFromInt(self.count));
        if (self.count < 2) {
            return .{
                .mean = mean,
                .stdev = 0.0,
                .max = max_val,
            };
        }

        var variance_sum: f64 = 0.0;
        i = 0;
        while (i < self.count) : (i += 1) {
            const diff = self.samples[i] - mean;
            variance_sum += diff * diff;
        }
        const variance = @max(0.0, variance_sum) /
            @as(f64, @floatFromInt(self.count - 1));
        return .{
            .mean = mean,
            .stdev = @sqrt(variance),
            .max = max_val,
        };
    }
};

/// Single-frame timing breakdown across active CPU pipeline phases and
/// swapchain VSync wait in milliseconds (excluding idle event-wait sleep).
pub const FrameSample = struct {
    ingest_ms: f64,
    intents_ms: f64,
    sync_ms: f64,
    ui_layout_ms: f64,
    gpu_encode_ms: f64,
    swapchain_wait_ms: f64 = 0.0,

    /// Returns total active frame CPU time summed across active CPU phases
    /// (excluding swapchain VSync wait and idle event-wait sleep).
    pub inline fn totalMs(self: FrameSample) f64 {
        return self.ingest_ms +
            self.intents_ms +
            self.sync_ms +
            self.ui_layout_ms +
            self.gpu_encode_ms;
    }
};

/// Inactivity threshold in milliseconds (`1.0 s`) without contiguous swapchain
/// presents before the HUD settles back to `.idle`.
pub const PRESENT_IDLE_GAP_MS: u64 = 1000;

const PRESENT_BOOTSTRAP_MS: f64 = 100.0;
const PRESENT_LATCH_WINDOW_MS: f64 = 500.0;
const PRESENT_MAX_CONTIGUOUS_GAP_MS: u64 = 150;
const PRESENT_MAX_CONTIGUOUS_GAP_F64_MS: f64 = 150.0;

/// Swapchain presentation rate reported to the Stats for Nerds HUD.
pub const PresentCadence = union(enum) {
    idle: struct {
        last_fps: ?f64 = null,
    },
    active: f64,
};

/// Measures actual GPU swapchain presentation rate using a MangoHud-style
/// `500 ms` latched window (`100 ms` initial bootstrap from `.idle`), skipping
/// the first cold-wake interval and settling to `.idle` after `1000 ms` without
/// contiguous swapchain presents.
pub const PresentTracker = struct {
    const Accumulator = union(enum) {
        empty,
        primed: struct {
            last_ts: std.Io.Timestamp,
            last_ms: u64,
        },
        counting: struct {
            window_start_ts: std.Io.Timestamp,
            last_ts: std.Io.Timestamp,
            last_ms: u64,
            intervals: u32,
        },
    };

    const Display = union(enum) {
        idle: struct {
            last_fps: ?f64 = null,
        },
        active: struct {
            fps: f64,
            last_present_ms: u64,
        },
    };

    accum: Accumulator = .empty,
    display: Display = .{ .idle = .{} },

    /// Records one completed window swapchain `cmd_buf.submit()` timestamp.
    pub fn recordPresent(
        self: *PresentTracker,
        present_ts: std.Io.Timestamp,
    ) void {
        const now_ms = timestampToMs(present_ts);
        switch (self.display) {
            .idle => {},
            .active => |act| {
                if ((now_ms -| act.last_present_ms) >= PRESENT_IDLE_GAP_MS) {
                    self.display = .{
                        .idle = .{ .last_fps = act.fps },
                    };
                }
            },
        }
        switch (self.accum) {
            .empty => {
                self.accum = .{
                    .primed = .{
                        .last_ts = present_ts,
                        .last_ms = now_ms,
                    },
                };
            },
            .primed => |p| {
                const dt_ms = durationToMs(p.last_ts.durationTo(present_ts));
                const tick_gap = now_ms -| p.last_ms;
                if (tick_gap <= PRESENT_MAX_CONTIGUOUS_GAP_MS and
                    dt_ms > 0.0 and
                    dt_ms <= PRESENT_MAX_CONTIGUOUS_GAP_F64_MS)
                {
                    // Anchor window_start_ts at the 2nd present so the 1st
                    // cold-wake VRR/compositor scanout interval is skipped.
                    self.accum = .{
                        .counting = .{
                            .window_start_ts = present_ts,
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                            .intervals = 0,
                        },
                    };
                } else if (dt_ms > 0.0) {
                    self.accum = .{
                        .primed = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                        },
                    };
                }
            },
            .counting => |*c| {
                const dt_ms = durationToMs(c.last_ts.durationTo(present_ts));
                const tick_gap = now_ms -| c.last_ms;
                if (tick_gap > PRESENT_MAX_CONTIGUOUS_GAP_MS or
                    dt_ms > PRESENT_MAX_CONTIGUOUS_GAP_F64_MS)
                {
                    // Pause > 150ms (e.g. +200ms ScrollCadence settle wakeup
                    // or 400ms OS initial key-repeat delay): re-prime the
                    // bucket without diluting FPS or dropping an active HUD
                    // readout before PRESENT_IDLE_GAP_MS (1000ms).
                    self.accum = .{
                        .primed = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                        },
                    };
                    return;
                }
                if (dt_ms <= 0.0) return;

                c.intervals += 1;
                c.last_ts = present_ts;
                c.last_ms = now_ms;
                if (c.intervals >= 2) {
                    switch (self.display) {
                        .idle => {},
                        .active => |*act| act.last_present_ms = now_ms,
                    }
                }

                const min_window_ms = switch (self.display) {
                    .idle => PRESENT_BOOTSTRAP_MS,
                    .active => PRESENT_LATCH_WINDOW_MS,
                };
                const window_ms = durationToMs(
                    c.window_start_ts.durationTo(present_ts),
                );
                if (c.intervals >= 2 and window_ms >= min_window_ms) {
                    const fps =
                        (@as(f64, @floatFromInt(c.intervals)) * 1000.0) /
                        window_ms;
                    self.display = .{
                        .active = .{
                            .fps = fps,
                            .last_present_ms = now_ms,
                        },
                    };
                    c.window_start_ts = present_ts;
                    c.intervals = 0;
                }
            },
        }
    }

    /// Settles an `.active` readout back to `.idle` once `PRESENT_IDLE_GAP_MS`
    /// (`1.0 s`) elapses without contiguous swapchain presents.
    pub fn settle(self: *PresentTracker, now_ms: u64) void {
        switch (self.accum) {
            .empty => {},
            .primed => |p| {
                if ((now_ms -| p.last_ms) > PRESENT_MAX_CONTIGUOUS_GAP_MS) {
                    self.accum = .empty;
                }
            },
            .counting => |c| {
                if ((now_ms -| c.last_ms) > PRESENT_MAX_CONTIGUOUS_GAP_MS) {
                    self.accum = .empty;
                }
            },
        }
        switch (self.display) {
            .idle => {},
            .active => |act| {
                if ((now_ms -| act.last_present_ms) >= PRESENT_IDLE_GAP_MS) {
                    self.display = .{
                        .idle = .{ .last_fps = act.fps },
                    };
                    self.accum = .empty;
                }
            },
        }
    }

    /// Returns remaining milliseconds until an `.active` readout expires at
    /// `PRESENT_IDLE_GAP_MS`, or `null` when already `.idle`.
    pub fn settleTimeoutMs(self: *const PresentTracker, now_ms: u64) ?u32 {
        return switch (self.display) {
            .idle => null,
            .active => |act| @intCast(
                PRESENT_IDLE_GAP_MS -| (now_ms -| act.last_present_ms),
            ),
        };
    }

    /// Returns the latched `PresentCadence` summary for UI telemetry display.
    pub fn snapshot(self: *const PresentTracker) PresentCadence {
        return switch (self.display) {
            .idle => |idle| .{
                .idle = .{ .last_fps = idle.last_fps },
            },
            .active => |act| .{ .active = act.fps },
        };
    }
};

/// Rolling 60-frame timing summary across each active frame phase,
/// swapchain wait, total frame CPU duration, and presentation cadence for HUD
/// display.
pub const FrameMetricsSnapshot = struct {
    ingest: StatsSummary = .{},
    intents: StatsSummary = .{},
    sync: StatsSummary = .{},
    ui_layout: StatsSummary = .{},
    gpu_encode: StatsSummary = .{},
    swapchain_wait: StatsSummary = .{},
    total: StatsSummary = .{},
    present: PresentCadence = .{ .idle = .{} },
};

/// Rolling 60-frame timing accumulators for each pipeline phase, swapchain
/// wait, total active frame CPU time, and presentation cadence.
pub const FrameMetrics = struct {
    ingest: RenderStats = .{},
    intents: RenderStats = .{},
    sync: RenderStats = .{},
    ui_layout: RenderStats = .{},
    gpu_encode: RenderStats = .{},
    swapchain_wait: RenderStats = .{},
    total: RenderStats = .{},
    present: PresentTracker = .{},

    /// Records one completed frame's phase CPU durations and optional window
    /// swapchain presentation timestamp.
    pub fn record(
        self: *FrameMetrics,
        sample: FrameSample,
        swapchain_present_ts: ?std.Io.Timestamp,
    ) void {
        self.ingest.addSample(sample.ingest_ms);
        self.intents.addSample(sample.intents_ms);
        self.sync.addSample(sample.sync_ms);
        self.ui_layout.addSample(sample.ui_layout_ms);
        self.gpu_encode.addSample(sample.gpu_encode_ms);
        self.swapchain_wait.addSample(sample.swapchain_wait_ms);
        self.total.addSample(sample.totalMs());
        if (swapchain_present_ts) |ts| {
            self.present.recordPresent(ts);
        }
    }

    /// Resets all rolling phase timing accumulators back to empty state.
    pub fn reset(self: *FrameMetrics) void {
        self.* = .{};
    }

    /// Computes rolling summary statistics across all frame accumulators.
    pub fn snapshot(self: *const FrameMetrics) FrameMetricsSnapshot {
        return .{
            .ingest = self.ingest.summarize(),
            .intents = self.intents.summarize(),
            .sync = self.sync.summarize(),
            .ui_layout = self.ui_layout.summarize(),
            .gpu_encode = self.gpu_encode.summarize(),
            .swapchain_wait = self.swapchain_wait.summarize(),
            .total = self.total.summarize(),
            .present = self.present.snapshot(),
        };
    }
};

/// Snapshot of UI vertex/batch counts and font-atlas usage metrics for
/// on-screen telemetry.
pub const UiRenderMetricsSnapshot = struct {
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,
    atlas_shelf_x: u32 = 0,
    atlas_shelf_y: u32 = 0,
    atlas_used_h: u32 = 0,
    atlas_page_count: usize = 0,
    atlas_ascii_glyphs: usize = 0,
    atlas_unicode_glyphs: usize = 0,
};

/// UI frame vertex and batch count telemetry.
pub const UiRenderMetrics = struct {
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,
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

    // Per-phase active CPU frame timings (rolling 60-frame summary)
    frame: FrameMetricsSnapshot = .{},
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
    // 1. RenderStats empty and single-sample summary
    var rs = RenderStats{};
    const empty_ms = rs.summarize();
    try std.testing.expectEqual(@as(f64, 0.0), empty_ms.mean);
    try std.testing.expectEqual(@as(f64, 0.0), empty_ms.stdev);
    try std.testing.expectEqual(@as(f64, 0.0), empty_ms.max);

    rs.addSample(10.0);
    const single = rs.summarize();
    try std.testing.expectEqual(@as(f64, 10.0), single.mean);
    try std.testing.expectEqual(@as(f64, 0.0), single.stdev);
    try std.testing.expectEqual(@as(f64, 10.0), single.max);

    // 2. RenderStats multi-sample summary
    rs.addSample(20.0);
    const ms = rs.summarize();
    try std.testing.expectEqual(@as(f64, 15.0), ms.mean);
    try std.testing.expect(ms.stdev > 0.0);
    try std.testing.expectEqual(@as(f64, 20.0), ms.max);

    // 3. UiRenderMetrics & UiRenderMetricsSnapshot defaults
    const metrics = UiRenderMetrics{
        .last_ui_vertex_count = 120,
        .last_ui_batch_count = 4,
    };
    try std.testing.expectEqual(@as(usize, 120), metrics.last_ui_vertex_count);
    try std.testing.expectEqual(@as(usize, 4), metrics.last_ui_batch_count);

    const empty_snap = UiRenderMetricsSnapshot{};
    try std.testing.expectEqual(@as(usize, 0), empty_snap.last_ui_vertex_count);
    try std.testing.expectEqual(@as(usize, 0), empty_snap.last_ui_batch_count);
    try std.testing.expectEqual(@as(u32, 0), empty_snap.atlas_used_h);

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

test "RenderStats.summarize evicts early spike after 60 samples" {
    var rs = RenderStats{};
    rs.addSample(100.0);
    try std.testing.expectEqual(@as(f64, 100.0), rs.summarize().max);

    for (0..59) |_| {
        rs.addSample(2.0);
    }
    try std.testing.expectEqual(@as(f64, 100.0), rs.summarize().max);

    // 60th new sample overwrites slot 0 (100.0) in the ring buffer.
    rs.addSample(2.0);
    const evicted = rs.summarize();
    try std.testing.expectEqual(@as(f64, 2.0), evicted.max);
    try std.testing.expectEqual(@as(f64, 2.0), evicted.mean);
    try std.testing.expectEqual(@as(f64, 0.0), evicted.stdev);
}

test "FrameSample.totalMs and FrameMetrics record, snapshot, and reset" {
    const s1 = FrameSample{
        .ingest_ms = 0.5,
        .intents_ms = 1.0,
        .sync_ms = 2.0,
        .ui_layout_ms = 1.5,
        .gpu_encode_ms = 3.0,
        .swapchain_wait_ms = 12.5,
    };
    // totalMs() excludes swapchain_wait_ms (0.5 + 1.0 + 2.0 + 1.5 + 3.0 = 8.0).
    try std.testing.expectEqual(@as(f64, 8.0), s1.totalMs());

    var fm = FrameMetrics{};
    const ts0 = std.Io.Timestamp.fromNanoseconds(1_000_000_000);
    const ts1 = std.Io.Timestamp.fromNanoseconds(1_016_000_000);
    const ts2 = std.Io.Timestamp.fromNanoseconds(1_080_000_000);
    const ts3 = std.Io.Timestamp.fromNanoseconds(1_144_000_000);
    fm.record(s1, ts0);
    fm.record(.{
        .ingest_ms = 1.5,
        .intents_ms = 3.0,
        .sync_ms = 4.0,
        .ui_layout_ms = 2.5,
        .gpu_encode_ms = 5.0,
        .swapchain_wait_ms = 16.5,
    }, ts1);
    fm.record(.{
        .ingest_ms = 1.0,
        .intents_ms = 2.0,
        .sync_ms = 3.0,
        .ui_layout_ms = 2.0,
        .gpu_encode_ms = 4.0,
        .swapchain_wait_ms = 14.5,
    }, ts2);
    // Headless frames (null swapchain_present_ts) record CPU timings only;
    // window frames advance PresentTracker across the 100ms bootstrap window.
    fm.present.recordPresent(ts3);

    const snap = fm.snapshot();
    try std.testing.expectEqual(@as(f64, 1.0), snap.ingest.mean);
    try std.testing.expectEqual(@as(f64, 1.5), snap.ingest.max);
    try std.testing.expectEqual(@as(f64, 2.0), snap.intents.mean);
    try std.testing.expectEqual(@as(f64, 3.0), snap.intents.max);
    try std.testing.expectEqual(@as(f64, 3.0), snap.sync.mean);
    try std.testing.expectEqual(@as(f64, 4.0), snap.sync.max);
    try std.testing.expectEqual(@as(f64, 2.0), snap.ui_layout.mean);
    try std.testing.expectEqual(@as(f64, 2.5), snap.ui_layout.max);
    try std.testing.expectEqual(@as(f64, 4.0), snap.gpu_encode.mean);
    try std.testing.expectEqual(@as(f64, 5.0), snap.gpu_encode.max);
    try std.testing.expectEqual(@as(f64, 14.5), snap.swapchain_wait.mean);
    try std.testing.expectEqual(@as(f64, 16.5), snap.swapchain_wait.max);
    try std.testing.expectEqual(@as(f64, 12.0), snap.total.mean);
    try std.testing.expect(snap.total.stdev > 0.0);
    try std.testing.expectEqual(@as(f64, 16.0), snap.total.max);
    switch (snap.present) {
        .idle => return error.TestExpectedActivePresentCadence,
        .active => |fps| {
            // 2 intervals across 128ms (ts1..ts3) = 15.625 FPS.
            try std.testing.expectApproxEqAbs(@as(f64, 15.625), fps, 0.01);
        },
    }

    fm.reset();
    const cleared = fm.snapshot();
    try std.testing.expectEqual(@as(f64, 0.0), cleared.ingest.mean);
    try std.testing.expectEqual(@as(f64, 0.0), cleared.ui_layout.mean);
    try std.testing.expectEqual(@as(f64, 0.0), cleared.gpu_encode.mean);
    try std.testing.expectEqual(@as(f64, 0.0), cleared.swapchain_wait.mean);
    try std.testing.expectEqual(@as(f64, 0.0), cleared.total.mean);
    try std.testing.expectEqual(@as(f64, 0.0), cleared.total.stdev);
    try std.testing.expectEqual(@as(f64, 0.0), cleared.total.max);
    switch (cleared.present) {
        .active => return error.TestExpectedIdlePresentCadence,
        .idle => |idle| {
            try std.testing.expectEqual(@as(?f64, null), idle.last_fps);
        },
    }
}

test "PresentTracker skips cold-wake scanout and latches 500ms windows" {
    var tracker = PresentTracker{};
    const ts = std.Io.Timestamp.fromNanoseconds;
    try std.testing.expectEqual(@as(?u32, null), tracker.settleTimeoutMs(1000));

    // Single isolated present stays .idle with null settle timeout (0 wakeups).
    tracker.recordPresent(ts(1_000_000_000));
    try std.testing.expectEqual(@as(?u32, null), tracker.settleTimeoutMs(1000));
    switch (tracker.snapshot()) {
        .active => return error.TestExpectedIdle,
        .idle => {},
    }

    // 2nd present after a 50ms cold-wake VRR scanout anchors window_start_ts at
    // 1050ms so the 50ms wake gap never dilutes the 120Hz measurement.
    var cur_ns: i96 = 1_050_000_000;
    tracker.recordPresent(ts(cur_ns));
    switch (tracker.snapshot()) {
        .active => return error.TestExpectedIdleBeforeBootstrap,
        .idle => {},
    }

    // Stream 13 intervals at 120Hz (13 * 8_333_333 ns = 108.33ms >= 100.0ms).
    const step_120hz_ns: i96 = 8_333_333;
    for (0..13) |_| {
        cur_ns += step_120hz_ns;
        tracker.recordPresent(ts(cur_ns));
    }
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActiveAfterBootstrap,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(@as(f64, 120.0), fps, 0.1);
        },
    }

    // Mid-window jitter (e.g. a 25ms frame at +25ms) MUST NOT change the HUD
    // readout before the 500ms latch window completes!
    cur_ns += 25_000_000;
    tracker.recordPresent(ts(cur_ns));
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActiveLatched,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(@as(f64, 120.0), fps, 0.1);
        },
    }

    // Advance past 500ms at 60Hz (30 intervals * 16_666_667 ns = 500ms) on a
    // fresh tracker from active state to verify 500ms latch refresh.
    for (0..30) |_| {
        cur_ns += 16_666_667;
        tracker.recordPresent(ts(cur_ns));
    }
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActiveUpdated,
        .active => |fps| {
            // 31 intervals over 525ms = 59.05 FPS.
            try std.testing.expectApproxEqAbs(@as(f64, 59.05), fps, 0.1);
        },
    }

    // Zero or negative timestamp deltas are ignored safely.
    var invalid = PresentTracker{};
    invalid.recordPresent(ts(1_000_000_000));
    invalid.recordPresent(ts(1_000_000_000));
    invalid.recordPresent(ts(999_000_000));
    switch (invalid.snapshot()) {
        .active => return error.TestExpectedIdle,
        .idle => {},
    }
}

test "PresentTracker survives 400ms OS key-repeat delay and settles at 1000ms" {
    var tracker = PresentTracker{};
    const ts = std.Io.Timestamp.fromNanoseconds;
    const step_120hz_ns: i96 = 8_333_333;

    // 1. Initial keypress triggers a 120ms thumb crossfade at 120Hz -> latches
    // 120.0 FPS across 13 post-wake intervals (108.33ms >= 100.0ms).
    var cur_ns: i96 = 1_000_000_000;
    for (0..15) |i| {
        if (i > 0) cur_ns += step_120hz_ns;
        tracker.recordPresent(ts(cur_ns));
    }
    const after_anim_ms = timestampToMs(ts(cur_ns));
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActive,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(@as(f64, 120.0), fps, 0.1);
        },
    }

    // 2. OS waits 400ms before firing key-repeat: HUD MUST stay .active (never
    // flashing Idle!) and the 400ms pause MUST NOT dilute the next 30Hz bucket.
    const repeat_start_ms = after_anim_ms + 400;
    tracker.settle(repeat_start_ms);
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActiveAcrossKeyRepeatDelay,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(@as(f64, 120.0), fps, 0.1);
        },
    }

    // Key-repeat streams at 30Hz (33_333_333 ns) for > 500ms (18 repeats = 16
    // post-wake intervals = 533.33ms).
    cur_ns = @as(i96, @intCast(repeat_start_ms)) * 1_000_000;
    for (0..18) |i| {
        if (i > 0) cur_ns += 33_333_333;
        tracker.recordPresent(ts(cur_ns));
    }
    const last_repeat_ms = timestampToMs(ts(cur_ns));
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActiveKeyRepeat,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(@as(f64, 30.0), fps, 0.1);
        },
    }

    // 3. Early wakeup 1ms before PRESENT_IDLE_GAP_MS (999ms) neither settles
    // nor refreshes last_present_ms into an infinite wakeup loop.
    const early_ms = last_repeat_ms + PRESENT_IDLE_GAP_MS - 1;
    tracker.settle(early_ms);
    tracker.recordPresent(ts(@as(i96, @intCast(early_ms)) * 1_000_000));
    try std.testing.expectEqual(
        @as(?u32, 1),
        tracker.settleTimeoutMs(early_ms),
    );

    // 4. At +1000ms, settle() transitions cleanly to .idle(last_fps = 30.0),
    // and the settled HUD repaint keeps settleTimeoutMs == null.
    const settle_ms = last_repeat_ms + PRESENT_IDLE_GAP_MS;
    tracker.settle(settle_ms);
    tracker.recordPresent(ts(@as(i96, @intCast(settle_ms)) * 1_000_000));
    try std.testing.expectEqual(
        @as(?u32, null),
        tracker.settleTimeoutMs(settle_ms),
    );
    switch (tracker.snapshot()) {
        .active => return error.TestExpectedIdleAfterSettle,
        .idle => |idle| {
            const last = idle.last_fps orelse return error.TestExpectedLastFps;
            try std.testing.expectApproxEqAbs(@as(f64, 30.0), last, 0.1);
        },
    }

    // 5. Post-scroll ScrollCadence wakeups (+200ms and +251ms) after a 120Hz
    // burst MUST NOT dilute the latched 120.0 FPS or extend last_present_ms,
    // and two late presents straddling +1000ms MUST NOT resurrect .active.
    var scroll_tracker = PresentTracker{};
    cur_ns = 5_000_000_000;
    for (0..50) |i| {
        if (i > 0) cur_ns += step_120hz_ns;
        scroll_tracker.recordPresent(ts(cur_ns));
    }
    const scroll_end_ms = timestampToMs(ts(cur_ns));
    const post_200_ns = cur_ns + 200_000_000;
    const post_251_ns = cur_ns + 251_000_000;
    scroll_tracker.recordPresent(ts(post_200_ns));
    scroll_tracker.recordPresent(ts(post_251_ns));
    switch (scroll_tracker.snapshot()) {
        .idle => return error.TestExpectedActivePostScroll,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(@as(f64, 120.0), fps, 0.1);
        },
    }
    try std.testing.expectEqual(
        @as(?u32, @intCast(PRESENT_IDLE_GAP_MS - 251)),
        scroll_tracker.settleTimeoutMs(scroll_end_ms + 251),
    );

    // Late isolated frame at +850ms followed by a VSync submit landing past
    // +1000ms settles to .idle(120.0 FPS) with null timeout.
    scroll_tracker.settle(scroll_end_ms + 850);
    scroll_tracker.recordPresent(
        ts(@as(i96, @intCast(scroll_end_ms + 850)) * 1_000_000),
    );
    scroll_tracker.settle(scroll_end_ms + PRESENT_IDLE_GAP_MS - 1);
    scroll_tracker.recordPresent(
        ts(
            @as(i96, @intCast(scroll_end_ms + PRESENT_IDLE_GAP_MS + 5)) *
                1_000_000,
        ),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        scroll_tracker.settleTimeoutMs(
            scroll_end_ms + PRESENT_IDLE_GAP_MS + 5,
        ),
    );
    switch (scroll_tracker.snapshot()) {
        .active => return error.TestExpectedIdleOnExpiredSubmit,
        .idle => |idle| {
            const last = idle.last_fps orelse return error.TestExpectedLastFps;
            try std.testing.expectApproxEqAbs(@as(f64, 120.0), last, 0.1);
        },
    }
}

test "durationToMs, activeDurationMs, and timestampToMs clamp safely" {
    try std.testing.expectEqual(
        @as(f64, 1.5),
        activeDurationMs(
            .{ .nanoseconds = 9_500_000 },
            .{ .nanoseconds = 8_000_000 },
        ),
    );
    try std.testing.expectEqual(
        @as(f64, 0.0),
        activeDurationMs(
            .{ .nanoseconds = 1_000_000 },
            .{ .nanoseconds = 5_000_000 },
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        timestampToMs(std.Io.Timestamp.fromNanoseconds(-5_000_000)),
    );
    try std.testing.expectEqual(
        @as(u64, 42),
        timestampToMs(std.Io.Timestamp.fromNanoseconds(42_999_999)),
    );

    try std.testing.expectEqual(
        @as(f64, 2.25),
        durationToMs(.{ .nanoseconds = 2_250_000 }),
    );
    try std.testing.expectEqual(
        @as(f64, 0.0),
        durationToMs(.{ .nanoseconds = 0 }),
    );
    try std.testing.expectEqual(
        @as(f64, 0.0),
        durationToMs(.{ .nanoseconds = -5_000_000 }),
    );
}
