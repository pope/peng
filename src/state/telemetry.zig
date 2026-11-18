const std = @import("std");

/// Converts a nanosecond duration into fractional milliseconds.
pub inline fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) /
        @as(f64, std.time.ns_per_ms);
}

/// Converts a `std.Io.Duration` into non-negative milliseconds.
pub inline fn durationToMs(dur: std.Io.Duration) f64 {
    return @as(f64, @floatFromInt(@max(0, dur.nanoseconds))) /
        @as(f64, std.time.ns_per_ms);
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

/// Inactivity threshold in milliseconds before a continuous presentation burst
/// settles back to idle.
pub const PRESENT_IDLE_GAP_MS: u64 = 250;

const PASSIVE_WAIT_SLEEP_THRESHOLD_MS: f64 = 2.0;

/// Returns `true` when a passive wait woke immediately (`< 2 ms`) due to an
/// actual OS or background worker event rather than a short timer timeout.
pub inline fn isPassiveStepPaced(
    wait_sleep_ms: f64,
    wait_woke_on_event: bool,
    post_wait_events: bool,
) bool {
    return (wait_woke_on_event or post_wait_events) and
        wait_sleep_ms < PASSIVE_WAIT_SLEEP_THRESHOLD_MS;
}

/// Event-driven presentation cadence reported to the Stats for Nerds HUD.
pub const PresentCadence = union(enum) {
    idle: struct {
        last_burst_fps: ?f64 = null,
    },
    active: struct {
        mean_fps: f64,
        low_fps: f64,
    },
};

/// Tracks event-driven presentation intervals and transitions between idle,
/// isolated primed frames, warm-up frames (absorbing cold VRR/compositor wake),
/// settling bursts, and continuous streaming bursts.
pub const PresentTracker = struct {
    const FrameMark = struct {
        last_ts: std.Io.Timestamp,
        last_ms: u64,
        last_burst_fps: ?f64 = null,
    };

    const Phase = union(enum) {
        idle: struct {
            last_burst_fps: ?f64 = null,
        },
        primed: FrameMark,
        warming: FrameMark,
        settling: FrameMark,
        streaming: struct {
            last_ts: std.Io.Timestamp,
            last_ms: u64,
            intervals_ms: RenderStats,
        },
    };

    phase: Phase = .{ .idle = .{} },

    fn burstMeanFps(intervals_ms: *const RenderStats) ?f64 {
        if (intervals_ms.count == 0) return null;
        const summary = intervals_ms.summarize();
        if (summary.mean <= 0.0) return null;
        return 1000.0 / summary.mean;
    }

    /// Records a completed frame presentation timestamp, tick time, and whether
    /// this frame ran as a paced continuation without passive event-wait sleep.
    pub fn record(
        self: *PresentTracker,
        present_ts: std.Io.Timestamp,
        now_ms: u64,
        is_paced_step: bool,
    ) void {
        if (!is_paced_step) {
            switch (self.phase) {
                .idle => |idle| {
                    self.phase = .{
                        .primed = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                            .last_burst_fps = idle.last_burst_fps,
                        },
                    };
                },
                .primed, .warming, .settling => |p| {
                    self.phase = .{
                        .primed = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                            .last_burst_fps = p.last_burst_fps,
                        },
                    };
                },
                .streaming => |*s| {
                    self.phase = .{
                        .settling = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                            .last_burst_fps = burstMeanFps(&s.intervals_ms),
                        },
                    };
                },
            }
            return;
        }

        const max_gap_ms: f64 = @floatFromInt(PRESENT_IDLE_GAP_MS);
        switch (self.phase) {
            .idle => |idle| {
                self.phase = .{
                    .primed = .{
                        .last_ts = present_ts,
                        .last_ms = now_ms,
                        .last_burst_fps = idle.last_burst_fps,
                    },
                };
            },
            .primed, .settling => |p| {
                const dt_ms = durationToMs(p.last_ts.durationTo(present_ts));
                const tick_gap = now_ms -| p.last_ms;
                if (tick_gap < PRESENT_IDLE_GAP_MS and
                    dt_ms > 0.0 and
                    dt_ms < max_gap_ms)
                {
                    self.phase = .{
                        .warming = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                            .last_burst_fps = p.last_burst_fps,
                        },
                    };
                } else {
                    self.phase = .{
                        .primed = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                            .last_burst_fps = p.last_burst_fps,
                        },
                    };
                }
            },
            .warming => |w| {
                const dt_ms = durationToMs(w.last_ts.durationTo(present_ts));
                const tick_gap = now_ms -| w.last_ms;
                if (tick_gap < PRESENT_IDLE_GAP_MS and
                    dt_ms > 0.0 and
                    dt_ms < max_gap_ms)
                {
                    var intervals: RenderStats = .{};
                    intervals.addSample(dt_ms);
                    self.phase = .{
                        .streaming = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                            .intervals_ms = intervals,
                        },
                    };
                } else {
                    self.phase = .{
                        .primed = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                            .last_burst_fps = w.last_burst_fps,
                        },
                    };
                }
            },
            .streaming => |*s| {
                const dt_ms = durationToMs(s.last_ts.durationTo(present_ts));
                const tick_gap = now_ms -| s.last_ms;
                if (tick_gap < PRESENT_IDLE_GAP_MS and dt_ms < max_gap_ms) {
                    if (dt_ms > 0.0) {
                        s.intervals_ms.addSample(dt_ms);
                    }
                    s.last_ts = present_ts;
                    s.last_ms = now_ms;
                } else {
                    self.phase = .{
                        .settling = .{
                            .last_ts = present_ts,
                            .last_ms = now_ms,
                            .last_burst_fps = burstMeanFps(&s.intervals_ms),
                        },
                    };
                }
            },
        }
    }

    /// Settles non-paced frames or expired `PRESENT_IDLE_GAP_MS` bursts back
    /// to `.idle` before building the UI snapshot.
    pub fn settleBeforeRender(
        self: *PresentTracker,
        now_ms: u64,
        is_paced_step: bool,
    ) void {
        switch (self.phase) {
            .idle => {},
            .settling => |s| {
                self.phase = .{
                    .idle = .{ .last_burst_fps = s.last_burst_fps },
                };
            },
            .primed, .warming => |p| {
                if (!is_paced_step or
                    (now_ms -| p.last_ms) >= PRESENT_IDLE_GAP_MS)
                {
                    self.phase = .{
                        .idle = .{ .last_burst_fps = p.last_burst_fps },
                    };
                }
            },
            .streaming => |*s| {
                if (!is_paced_step or
                    (now_ms -| s.last_ms) >= PRESENT_IDLE_GAP_MS)
                {
                    self.phase = .{
                        .idle = .{
                            .last_burst_fps = burstMeanFps(&s.intervals_ms),
                        },
                    };
                }
            },
        }
    }

    /// Returns `0` when `.settling`, remaining milliseconds until a
    /// `.streaming` burst expires, or `null` when `.idle`, `.primed`, or
    /// `.warming`.
    pub fn settleTimeoutMs(self: *const PresentTracker, now_ms: u64) ?u32 {
        return switch (self.phase) {
            .idle, .primed, .warming => null,
            .settling => 0,
            .streaming => |*s| @intCast(
                PRESENT_IDLE_GAP_MS -| (now_ms -| s.last_ms),
            ),
        };
    }

    /// Returns the current `PresentCadence` summary for UI telemetry display.
    pub fn snapshot(self: *const PresentTracker) PresentCadence {
        return switch (self.phase) {
            .idle => |idle| .{
                .idle = .{ .last_burst_fps = idle.last_burst_fps },
            },
            .primed, .warming, .settling => |p| .{
                .idle = .{ .last_burst_fps = p.last_burst_fps },
            },
            .streaming => |*s| blk: {
                const summary = s.intervals_ms.summarize();
                const mean_fps = if (summary.mean > 0.0)
                    1000.0 / summary.mean
                else
                    0.0;
                const low_fps = if (summary.max > 0.0)
                    1000.0 / summary.max
                else
                    0.0;
                break :blk .{
                    .active = .{
                        .mean_fps = mean_fps,
                        .low_fps = low_fps,
                    },
                };
            },
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

    /// Records one completed visible frame's phase durations and presentation
    /// timestamp.
    pub fn record(
        self: *FrameMetrics,
        sample: FrameSample,
        present_ts: std.Io.Timestamp,
        now_ms: u64,
        is_paced_step: bool,
    ) void {
        self.ingest.addSample(sample.ingest_ms);
        self.intents.addSample(sample.intents_ms);
        self.sync.addSample(sample.sync_ms);
        self.ui_layout.addSample(sample.ui_layout_ms);
        self.gpu_encode.addSample(sample.gpu_encode_ms);
        self.swapchain_wait.addSample(sample.swapchain_wait_ms);
        self.total.addSample(sample.totalMs());
        self.present.record(present_ts, now_ms, is_paced_step);
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
    const ts2 = std.Io.Timestamp.fromNanoseconds(1_032_000_000);
    fm.record(s1, ts0, 1000, false);
    fm.record(.{
        .ingest_ms = 1.5,
        .intents_ms = 3.0,
        .sync_ms = 4.0,
        .ui_layout_ms = 2.5,
        .gpu_encode_ms = 5.0,
        .swapchain_wait_ms = 16.5,
    }, ts1, 1016, true);
    fm.record(.{
        .ingest_ms = 1.0,
        .intents_ms = 2.0,
        .sync_ms = 3.0,
        .ui_layout_ms = 2.0,
        .gpu_encode_ms = 4.0,
        .swapchain_wait_ms = 14.5,
    }, ts2, 1032, true);

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
            try std.testing.expectApproxEqAbs(
                @as(f64, 62.5),
                fps.mean_fps,
                0.01,
            );
            try std.testing.expectApproxEqAbs(
                @as(f64, 62.5),
                fps.low_fps,
                0.01,
            );
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
            try std.testing.expectEqual(
                @as(?f64, null),
                idle.last_burst_fps,
            );
        },
    }
}

test "PresentTracker filters unpaced sleep gaps and cold-wake VRR transients" {
    var tracker = PresentTracker{};
    try std.testing.expectEqual(@as(?u32, null), tracker.settleTimeoutMs(1000));

    // Frame 1 wakes from idle; 50ms human pause before Frame 2 starts drag;
    // Frame 2 -> Frame 3 has a 50ms cold-wake VRR scanout; Frame 3 -> Frame 4
    // hits steady-state 120Hz (8.333ms). Neither 50ms (20 FPS) gap may pollute
    // intervals_ms!
    tracker.record(
        std.Io.Timestamp.fromNanoseconds(1_000_000_000),
        1000,
        false,
    );
    tracker.record(
        std.Io.Timestamp.fromNanoseconds(1_050_000_000),
        1050,
        false,
    );
    try std.testing.expectEqual(@as(?u32, null), tracker.settleTimeoutMs(1050));
    switch (tracker.snapshot()) {
        .active => return error.TestExpectedIdle,
        .idle => {},
    }

    // First paced step enters .warming (absorbs 50ms cold-wake scanout).
    tracker.record(
        std.Io.Timestamp.fromNanoseconds(1_100_000_000),
        1100,
        true,
    );
    try std.testing.expectEqual(@as(?u32, null), tracker.settleTimeoutMs(1100));
    switch (tracker.snapshot()) {
        .active => return error.TestExpectedIdle,
        .idle => {},
    }

    // Second paced step enters .streaming cleanly at 120.0 FPS (low 120.0 FPS).
    tracker.record(
        std.Io.Timestamp.fromNanoseconds(1_108_333_333),
        1108,
        true,
    );
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActive,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(
                @as(f64, 120.0),
                fps.mean_fps,
                0.1,
            );
            try std.testing.expectApproxEqAbs(
                @as(f64, 120.0),
                fps.low_fps,
                0.1,
            );
        },
    }

    // Zero or negative timestamp delta must not corrupt or start .streaming.
    var invalid_tracker = PresentTracker{};
    invalid_tracker.record(
        std.Io.Timestamp.fromNanoseconds(1_000_000_000),
        1000,
        true,
    );
    invalid_tracker.record(
        std.Io.Timestamp.fromNanoseconds(1_000_000_000),
        1005,
        true,
    );
    invalid_tracker.record(
        std.Io.Timestamp.fromNanoseconds(999_000_000),
        1010,
        true,
    );
    switch (invalid_tracker.snapshot()) {
        .active => return error.TestExpectedIdle,
        .idle => {},
    }
}

test "PresentTracker tracks 120Hz burst, timeout countdown, and 60-sample low" {
    var tracker = PresentTracker{};
    const step_ns: i96 = 8_333_333;
    var cur_ns: i96 = 1_000_000_000;
    var cur_ms: u64 = 1000;

    tracker.record(std.Io.Timestamp.fromNanoseconds(cur_ns), cur_ms, false);
    cur_ns += step_ns;
    cur_ms += 8;
    tracker.record(std.Io.Timestamp.fromNanoseconds(cur_ns), cur_ms, true);
    cur_ns += step_ns;
    cur_ms += 8;
    tracker.record(std.Io.Timestamp.fromNanoseconds(cur_ns), cur_ms, true);

    try std.testing.expectEqual(
        @as(?u32, @intCast(PRESENT_IDLE_GAP_MS)),
        tracker.settleTimeoutMs(cur_ms),
    );
    try std.testing.expectEqual(
        @as(?u32, 1),
        tracker.settleTimeoutMs(cur_ms + PRESENT_IDLE_GAP_MS - 1),
    );
    try std.testing.expectEqual(
        @as(?u32, 0),
        tracker.settleTimeoutMs(cur_ms + PRESENT_IDLE_GAP_MS),
    );

    // Zero-delta timestamp during streaming must not corrupt intervals_ms.
    tracker.record(std.Io.Timestamp.fromNanoseconds(cur_ns), cur_ms + 1, true);
    cur_ms += 1;
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActive,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(
                @as(f64, 120.0),
                fps.mean_fps,
                0.1,
            );
            try std.testing.expectApproxEqAbs(
                @as(f64, 120.0),
                fps.low_fps,
                0.1,
            );
        },
    }

    // Record a genuine mid-stream 20ms hitch (50.0 FPS) and verify eviction.
    cur_ns += 20_000_000;
    cur_ms += 20;
    tracker.record(std.Io.Timestamp.fromNanoseconds(cur_ns), cur_ms, true);
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActive,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(
                @as(f64, 50.0),
                fps.low_fps,
                0.1,
            );
        },
    }

    for (0..60) |_| {
        cur_ns += step_ns;
        cur_ms += 8;
        tracker.record(std.Io.Timestamp.fromNanoseconds(cur_ns), cur_ms, true);
    }
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActive,
        .active => |fps| {
            try std.testing.expectApproxEqAbs(
                @as(f64, 120.0),
                fps.mean_fps,
                0.1,
            );
            try std.testing.expectApproxEqAbs(
                @as(f64, 120.0),
                fps.low_fps,
                0.1,
            );
        },
    }
}

test "PresentTracker settles expired or unpaced bursts without wakeup loop" {
    var tracker = PresentTracker{};
    const step_ns: i96 = 8_333_333;
    var cur_ns: i96 = 2_000_000_000;
    var cur_ms: u64 = 2000;

    for (0..4) |i| {
        if (i > 0) {
            cur_ns += step_ns;
            cur_ms += 8;
        }
        tracker.record(
            std.Io.Timestamp.fromNanoseconds(cur_ns),
            cur_ms,
            i > 0,
        );
    }

    // Paced pre-render before 250ms keeps .streaming active.
    tracker.settleBeforeRender(cur_ms + PRESENT_IDLE_GAP_MS - 1, true);
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActive,
        .active => {},
    }

    // At +250ms (unpaced wakeup), settleBeforeRender transitions .streaming ->
    // .idle with last_burst_fps preserved.
    const settle_ms = cur_ms + PRESENT_IDLE_GAP_MS;
    tracker.settleBeforeRender(settle_ms, false);
    try std.testing.expectEqual(
        @as(?u32, null),
        tracker.settleTimeoutMs(settle_ms),
    );
    switch (tracker.snapshot()) {
        .active => return error.TestExpectedIdle,
        .idle => |idle| {
            const last = idle.last_burst_fps orelse
                return error.TestExpectedLastBurstFps;
            try std.testing.expectApproxEqAbs(@as(f64, 120.0), last, 0.1);
        },
    }

    // Wakeup frame repaint records once -> .primed (still idle, null timeout).
    const wakeup_ns = cur_ns + @as(i96, PRESENT_IDLE_GAP_MS) * 1_000_000;
    tracker.record(
        std.Io.Timestamp.fromNanoseconds(wakeup_ns),
        settle_ms,
        false,
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        tracker.settleTimeoutMs(settle_ms),
    );

    // Unpaced mouse wiggle 40ms after a burst settles before render immediately
    // without poisoning intervals_ms with a 40ms (25 FPS) gap.
    var next_ns = wakeup_ns + step_ns;
    var next_ms = settle_ms + 8;
    tracker.record(std.Io.Timestamp.fromNanoseconds(next_ns), next_ms, true);
    next_ns += step_ns;
    next_ms += 8;
    tracker.record(std.Io.Timestamp.fromNanoseconds(next_ns), next_ms, true);
    try std.testing.expect(tracker.settleTimeoutMs(next_ms) != null);

    tracker.settleBeforeRender(next_ms + 40, false);
    switch (tracker.snapshot()) {
        .active => return error.TestExpectedIdle,
        .idle => |idle| {
            const last = idle.last_burst_fps orelse
                return error.TestExpectedLastBurstFps;
            try std.testing.expectApproxEqAbs(@as(f64, 120.0), last, 0.1);
        },
    }
}

test "PresentTracker settles via .settling on dt_ms >= 250, tick_gap < 250" {
    var tracker = PresentTracker{};
    tracker.record(std.Io.Timestamp.fromNanoseconds(994_000_000), 992, false);
    tracker.record(std.Io.Timestamp.fromNanoseconds(1_002_000_000), 1000, true);
    tracker.record(
        std.Io.Timestamp.fromNanoseconds(1_010_333_333),
        1008,
        true,
    );

    // Frame wakes paced at tick_gap = 249 (< 250), then finishes at dt >= 250.
    tracker.settleBeforeRender(1257, true);
    switch (tracker.snapshot()) {
        .idle => return error.TestExpectedActive,
        .active => {},
    }
    const ts_late = std.Io.Timestamp.fromNanoseconds(1_260_333_333);
    tracker.record(ts_late, 1257, true);
    try std.testing.expectEqual(@as(?u32, 0), tracker.settleTimeoutMs(1260));
    switch (tracker.snapshot()) {
        .active => return error.TestExpectedIdle,
        .idle => |idle| {
            const last = idle.last_burst_fps orelse
                return error.TestExpectedLastBurstFps;
            try std.testing.expectApproxEqAbs(@as(f64, 120.0), last, 0.1);
        },
    }

    // Immediate wakeup repaints HUD as .idle and transitions to .primed.
    tracker.settleBeforeRender(1261, false);
    tracker.record(
        std.Io.Timestamp.fromNanoseconds(1_262_000_000),
        1261,
        false,
    );
    try std.testing.expectEqual(@as(?u32, null), tracker.settleTimeoutMs(1262));
}

test "nsToMs and durationToMs convert nanoseconds and clamp negatives" {
    try std.testing.expectEqual(@as(f64, 0.0), nsToMs(0));
    try std.testing.expectEqual(@as(f64, 1.5), nsToMs(1_500_000));
    try std.testing.expectEqual(@as(f64, 16.0), nsToMs(16_000_000));

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

    // 1ms passive timer timeout with zero events must NOT be classified paced.
    try std.testing.expect(!isPassiveStepPaced(0.75, false, false));
    try std.testing.expect(isPassiveStepPaced(0.05, true, false));
    try std.testing.expect(isPassiveStepPaced(0.05, false, true));
    try std.testing.expect(!isPassiveStepPaced(2.5, true, false));
}
