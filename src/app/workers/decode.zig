const builtin = @import("builtin");
const cache = @import("cache");
const context = @import("context.zig");
const core = @import("core");
const geom = @import("geom");
const manager = @import("manager.zig");
const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const thumbcache = @import("thumbcache");
const vfs = @import("vfs");

const ArchiveMediaEntry = vfs.ArchiveMediaEntry;
const convertAndScaleSurface = cache.convertAndScaleSurface;
const decompressCbzMediaEntry = vfs.decompressCbzMediaEntry;
const FilePair = vfs.FilePair;
const hasValidTargetTierThumbnail = thumbcache.hasValidTargetTierThumbnail;
const header_probe_limit = context.header_probe_limit;
const ImageCacheKey = cache.ImageCacheKey;
const isRawFile = vfs.isRawFile;
const loadCachedThumbnail = core.thumbcache.loadCachedThumbnail;
const MediaEntry = vfs.MediaEntry;
const MediaId = vfs.MediaId;
const PairStreamTarget = vfs.PairStreamTarget;
const PhysicalDims = geom.PhysicalDims;
const RawMetadata = probe.RawMetadata;
const readLocationBytes = probe.readLocationBytes;
const readRangePositional = probe.readRangePositional;
const ThumbCacheConfig = thumbcache.ThumbCacheConfig;
const ThumbCacheKey = thumbcache.ThumbCacheKey;
const ThumbnailSource = state_pkg.ThumbnailSource;
const WorkerManager = manager.WorkerManager;

/// Controls how far a background `decodeWorker` job proceeds during a single
/// open-file pass.
pub const DecodeMode = enum {
    full,
    active_fast_scroll,
    speculative_thumb,
};

/// Contextual arguments and configuration passed to background image decoding
/// worker threads.
pub const DecodeArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    key: ImageCacheKey,
    job_id: u8 = 0,
    job_epoch: u32 = 0,
    current_job_epoch: ?*const std.atomic.Value(u32) = null,
    entry: MediaEntry,
    has_gpu_device: bool,
    pixel_format: u32,
    mode: DecodeMode = .full,
    pair_target: PairStreamTarget = .adaptive,
    current_generation: *const std.atomic.Value(usize),

    /// Builds a cooperative cancellation token for this decode task.
    pub inline fn cancelToken(
        self: *const DecodeArgs,
    ) context.CancellationToken {
        return .{
            .exiting = &self.workers.exiting,
            .generation = self.key.generation,
            .current_generation = self.current_generation,
            .job_epoch = self.job_epoch,
            .current_job_epoch = self.current_job_epoch,
        };
    }
};

/// Spawns a background `decodeWorker` task for image file decoding and EXIF thumbnail extraction,
/// tracking active decode thread and active worker thread counts.
pub fn spawnDecode(args: *DecodeArgs) !void {
    _ = args.workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    args.workers.group.async(args.io, decodeWorker, .{args});
}

fn failDecodeWorker(
    workers: *WorkerManager,
    alloc: std.mem.Allocator,
    io: std.Io,
    key: ImageCacheKey,
    job_epoch: u32,
    comptime fmt: []const u8,
    fmt_args: anytype,
) void {
    std.log.err(fmt, fmt_args);
    workers.event_queue.push(alloc, io, .{
        .decode_failed = .init(key, job_epoch, .{}),
    }) catch |e| std.log.err("Failed to push decode_failed event: {}", .{e});
    workers.wakeMainThread();
}

fn pushExifOrientation(
    workers: *WorkerManager,
    alloc: std.mem.Allocator,
    io: std.Io,
    key: ImageCacheKey,
    job_epoch: u32,
    orientation: probe.Orientation,
) void {
    if (orientation == .normal) return;
    workers.event_queue.push(alloc, io, .{
        .exif_orientation_parsed = .init(
            key,
            job_epoch,
            .{ .orientation = orientation },
        ),
    }) catch |err| {
        std.log.err("Failed to push EXIF orientation event: {}", .{err});
    };
    workers.wakeMainThread();
}

fn pushThumbDecoded(
    workers: *WorkerManager,
    alloc: std.mem.Allocator,
    io: std.Io,
    key: ImageCacheKey,
    job_epoch: u32,
    surface: sdl.Surface,
    source_dims: ?PhysicalDims,
    orientation: probe.Orientation,
    thumb_only: bool,
    source: ThumbnailSource,
    raw_metadata: RawMetadata,
) void {
    const dct_snapped = if (source == .freedesktop_cache)
        false
    else if (source_dims) |sd|
        cache.detectThumbnailDctPadding(surface, sd.w, sd.h)
    else
        false;

    workers.event_queue.push(alloc, io, .{
        .thumb_decoded = .init(key, job_epoch, .{
            .surface = surface,
            .w = @floatFromInt(surface.w()),
            .h = @floatFromInt(surface.h()),
            .source_dims = source_dims,
            .orientation = orientation,
            .thumb_only = thumb_only,
            .raw_metadata = raw_metadata,
            .dct_snapped = dct_snapped,
            .source = source,
        }),
    }) catch |err| {
        std.log.err("Failed to push thumbnail decode event: {}", .{err});
        surface.destroy();
    };
    workers.wakeMainThread();
}

fn pushDimensionsProbed(
    workers: *WorkerManager,
    alloc: std.mem.Allocator,
    io: std.Io,
    key: ImageCacheKey,
    job_epoch: u32,
    source_dims: ?PhysicalDims,
    orientation: probe.Orientation,
    thumb_only: bool,
    raw_metadata: RawMetadata,
) void {
    workers.event_queue.push(alloc, io, .{
        .dimensions_probed = .init(key, job_epoch, .{
            .source_dims = source_dims,
            .orientation = orientation,
            .thumb_only = thumb_only,
            .raw_metadata = raw_metadata,
        }),
    }) catch |err| {
        std.log.err("Failed to push dimensions probed event: {}", .{err});
    };
    workers.wakeMainThread();
}

const CacheProbeOutcome = enum {
    not_probed,
    excluded_path,
    target_tier_missing,
    target_tier_valid,
};

const LoadedThumbnail = struct {
    surface: sdl.Surface,
    source: ThumbnailSource,
    probe_outcome: CacheProbeOutcome = .not_probed,
    source_dims: ?PhysicalDims = null,
};

const ThumbLoadResult = union(enum) {
    hit: LoadedThumbnail,
    miss: CacheProbeOutcome,
};

fn probeFreedesktopThumbCache(
    workers: *WorkerManager,
    alloc: std.mem.Allocator,
    io: std.Io,
    cancel: context.CancellationToken,
    path: []const u8,
    source_mtime_sec: ?i64,
    had_embedded_candidate: bool,
) error{Canceled}!ThumbLoadResult {
    const mtime_sec = source_mtime_sec orelse {
        if (had_embedded_candidate) {
            _ = workers.thumb_misses.fetchAdd(1, .monotonic);
        }
        return .{ .miss = .not_probed };
    };
    switch (workers.thumb_cache_config) {
        .disabled => {
            if (had_embedded_candidate) {
                _ = workers.thumb_misses.fetchAdd(1, .monotonic);
            }
            return .{ .miss = .not_probed };
        },
        .enabled => |cfg| {
            const c_key = ThumbCacheKey.fromFilePath(
                io,
                path,
                cfg.cache_dir,
            ) orelse {
                if (had_embedded_candidate) {
                    _ = workers.thumb_misses.fetchAdd(1, .monotonic);
                }
                return .{ .miss = .excluded_path };
            };
            if (loadCachedThumbnail(
                alloc,
                io,
                cfg,
                &c_key,
                mtime_sec,
                0,
            )) |cached| {
                if (cancel.isCanceled()) {
                    cached.surface.destroy();
                    return error.Canceled;
                }
                _ = workers.thumb_cache_hits.fetchAdd(1, .monotonic);
                const outcome: CacheProbeOutcome =
                    if (cached.tier == cfg.write_tier)
                        .target_tier_valid
                    else
                        .not_probed;
                return .{
                    .hit = .{
                        .surface = cached.surface,
                        .source = .freedesktop_cache,
                        .probe_outcome = outcome,
                        .source_dims = cached.source_dims,
                    },
                };
            } else {
                _ = workers.thumb_misses.fetchAdd(1, .monotonic);
                return .{ .miss = .target_tier_missing };
            }
        },
    }
}

fn resolveThumbWriteMtime(
    io: std.Io,
    cfg_state: ThumbCacheConfig,
    path: []const u8,
    source_mtime_sec: ?i64,
    had_embedded_thumb: bool,
    probe_outcome: CacheProbeOutcome,
) ?i64 {
    const mtime_sec = source_mtime_sec orelse return null;
    return switch (cfg_state) {
        .disabled => null,
        .enabled => |cfg| blk: {
            const had_target_valid = (probe_outcome == .target_tier_valid);
            if (!cfg.write_policy.shouldWrite(
                had_embedded_thumb,
                had_target_valid,
            )) {
                break :blk null;
            }
            switch (probe_outcome) {
                .target_tier_valid, .excluded_path => break :blk null,
                .target_tier_missing => break :blk mtime_sec,
                .not_probed => {
                    const c_key = ThumbCacheKey.fromFilePath(
                        io,
                        path,
                        cfg.cache_dir,
                    ) orelse break :blk null;
                    break :blk if (!hasValidTargetTierThumbnail(
                        io,
                        cfg,
                        &c_key,
                        mtime_sec,
                    ))
                        mtime_sec
                    else
                        null;
                },
            }
        },
    };
}

fn decodeRawFile(args: *DecodeArgs, path: []const u8, is_pair: bool) bool {
    const workers = args.workers;
    const alloc = args.allocator;
    const io = args.io;
    const key = args.key;
    const cancel = args.cancelToken();

    if (cancel.isCanceled()) return true;

    const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) return true;
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: statFile failed for '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    const file_size: u64 = s.size;
    const source_mtime_sec = s.mtime.toSeconds();

    var file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) return true;
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: openFile failed for '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    defer file.close(io);

    // Read initial 256KB header via readPositional without allocating full file
    const header_target: usize = @intCast(@min(file_size, header_probe_limit));
    var header_buf: [header_probe_limit]u8 = undefined;
    const start_hdr_read = std.Io.Clock.awake.now(io);
    const header_n = readRangePositional(
        file,
        io,
        cancel,
        header_buf[0..header_target],
        0,
    ) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) return true;
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: readPositional failed for '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    const header_read_time_ms = @as(
        f64,
        @floatFromInt(
            @max(0, start_hdr_read.untilNow(io, .awake).nanoseconds),
        ),
    ) / 1_000_000.0;
    const header_slice = header_buf[0..header_n];

    const mime_type = probe.detectMimeType(header_slice, path);
    const is_fuji = probe.isFujiRafHeader(header_slice, mime_type);

    const raw_probe = probe.probeRawFileHeader(
        io,
        &file,
        file_size,
        header_slice,
        mime_type,
    );
    if (cancel.isCanceled()) return true;

    const prev_loc_opt = raw_probe.preview;
    const med_loc_opt = raw_probe.medium;
    const thumb_loc_opt = raw_probe.thumbnail;
    const raw_sensor_dims = raw_probe.sensor_dims;
    var orientation = raw_probe.orientation;

    if (cancel.isCanceled()) return true;

    pushExifOrientation(
        workers,
        alloc,
        io,
        key,
        args.job_epoch,
        orientation,
    );

    const raw_w: f32 = if (raw_sensor_dims) |d| d.w else 0.0;
    const raw_h: f32 = if (raw_sensor_dims) |d| d.h else 0.0;
    var had_embedded_thumb = (thumb_loc_opt != null) or (med_loc_opt != null);
    var probe_outcome: CacheProbeOutcome = .not_probed;

    const prefer_small_thumb = switch (args.mode) {
        .full => false,
        .active_fast_scroll, .speculative_thumb => true,
    };
    const should_try_thumb = switch (args.mode) {
        .full => args.has_gpu_device and args.pair_target == .adaptive,
        .active_fast_scroll, .speculative_thumb => true,
    };
    const emit_thumb_only = switch (args.mode) {
        .full => false,
        .active_fast_scroll, .speculative_thumb => true,
    };

    // Fast scrubbing & instant placeholder thumbnail path
    if (should_try_thumb) {
        var thumb_surf: ?sdl.Surface = null;
        var thumb_source: ThumbnailSource = .embedded_header;
        var cached_dims: ?PhysicalDims = null;
        const target_loc_opt = raw_probe.selectPlaceholder(
            prefer_small_thumb,
            file_size,
        );

        if (target_loc_opt) |tloc| {
            const placeholder_max: u32 = switch (args.mode) {
                .full => 2 * 1024 * 1024,
                .active_fast_scroll, .speculative_thumb => 512 * 1024,
            };
            var loc_bytes = readLocationBytes(
                alloc,
                file,
                io,
                cancel,
                header_slice,
                file_size,
                tloc,
                placeholder_max,
            ) catch |err| blk: {
                if (err == error.Canceled or cancel.isCanceled()) return true;
                break :blk null;
            };
            if (loc_bytes) |*lb| {
                defer lb.deinit(alloc);
                thumb_surf = sdl.Surface.loadConstMemOpt(lb.bytes);
                if (thumb_surf != null) {
                    if (lb.isFromHeader()) {
                        _ = workers.thumb_header_hits.fetchAdd(1, .monotonic);
                        thumb_source = .embedded_header;
                    } else {
                        _ = workers.thumb_positional_hits.fetchAdd(
                            1,
                            .monotonic,
                        );
                        thumb_source = .embedded_positional;
                    }
                    had_embedded_thumb = true;
                }
            }
        }

        if (thumb_surf == null) {
            had_embedded_thumb = false;
            const cache_res = probeFreedesktopThumbCache(
                workers,
                alloc,
                io,
                cancel,
                path,
                source_mtime_sec,
                target_loc_opt != null,
            ) catch return true;
            switch (cache_res) {
                .hit => |hit| {
                    thumb_surf = hit.surface;
                    thumb_source = hit.source;
                    cached_dims = hit.source_dims;
                    probe_outcome = hit.probe_outcome;
                },
                .miss => |outcome| {
                    probe_outcome = outcome;
                },
            }
        }

        if (thumb_surf) |t_surf| {
            if (cancel.isCanceled()) {
                t_surf.destroy();
                return true;
            }
            const source_dims =
                PhysicalDims.initPositive(raw_w, raw_h) orelse
                cached_dims;
            const raw_meta = if (source_dims) |sd|
                RawMetadata.fromDims(sd)
            else
                .none;
            pushThumbDecoded(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                t_surf,
                source_dims,
                orientation,
                emit_thumb_only,
                thumb_source,
                raw_meta,
            );

            switch (args.mode) {
                .active_fast_scroll, .speculative_thumb => return true,
                .full => {},
            }
        } else {
            switch (args.mode) {
                .speculative_thumb => {
                    if (is_pair) return false;
                    // If no small thumbnail available, emit dimensions_probed
                    // to immediately establish canvas aspect ratio on Frame 1
                    // without decoding pixels
                    if (cancel.isCanceled()) return true;
                    pushDimensionsProbed(
                        workers,
                        alloc,
                        io,
                        key,
                        args.job_epoch,
                        PhysicalDims.initPositive(raw_w, raw_h),
                        orientation,
                        true,
                        RawMetadata.init(raw_w, raw_h),
                    );
                    return true;
                },
                .full, .active_fast_scroll => {},
            }
        }
    }

    if (cancel.isCanceled()) return true;

    const prev_loc = prev_loc_opt orelse {
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: no embedded preview found in RAW file '{s}'",
            .{path},
        );
        return true;
    };

    var loc_bytes = readLocationBytes(
        alloc,
        file,
        io,
        cancel,
        header_slice,
        file_size,
        prev_loc,
        null,
    ) catch |err| {
        if (err == error.Canceled or cancel.isCanceled()) return true;
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: readLocationBytes failed for preview in '{s}': {}",
            .{ path, err },
        );
        return true;
    };
    if (loc_bytes == null) {
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: incomplete preview read for '{s}'",
            .{path},
        );
        return true;
    }
    defer loc_bytes.?.deinit(alloc);
    const prev_bytes = loc_bytes.?.bytes;
    const read_time_ms = header_read_time_ms + loc_bytes.?.read_time_ms;

    if (is_fuji and orientation == .normal) {
        if (probe.parseExifOrientation(prev_bytes)) |o| {
            orientation = o;
            if (orientation != .normal) {
                if (cancel.isCanceled()) return true;
                pushExifOrientation(
                    workers,
                    alloc,
                    io,
                    key,
                    args.job_epoch,
                    orientation,
                );
            }
        }
    }

    const start_dec = std.Io.Clock.awake.now(io);
    const surface = sdl.Surface.loadConstMemOpt(prev_bytes);
    const decode_time_ms = @as(
        f64,
        @floatFromInt(@max(0, start_dec.untilNow(io, .awake).nanoseconds)),
    ) / 1_000_000.0;

    if (surface == null) {
        if (is_pair) return false;
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: failed to load RAW preview surface '{s}': {s}",
            .{ path, sdl.getError() },
        );
        return true;
    }

    if (cancel.isCanceled()) {
        surface.?.destroy();
        return true;
    }

    const unscaled_w: f32 = @floatFromInt(surface.?.w());
    const unscaled_h: f32 = @floatFromInt(surface.?.h());
    const conv_res = convertAndScaleSurface(
        io,
        surface,
        args.pixel_format,
        args.has_gpu_device,
    );
    const final_surface = conv_res.surface;
    const conversion_time_ms = conv_res.conversion_time_ms;

    if (cancel.isCanceled()) {
        if (final_surface) |surf| surf.destroy();
        return true;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());
        const final_raw_w: f32 = if (raw_w > 0.0) raw_w else unscaled_w;
        const final_raw_h: f32 = if (raw_h > 0.0) raw_h else unscaled_h;
        const thumb_write_mtime_sec = resolveThumbWriteMtime(
            io,
            workers.thumb_cache_config,
            path,
            source_mtime_sec,
            had_embedded_thumb,
            probe_outcome,
        );

        workers.event_queue.push(alloc, io, .{
            .image_decoded = .init(key, args.job_epoch, .{
                .surface = f_surf,
                .w = orig_w,
                .h = orig_h,
                .source_dims = PhysicalDims.initPositive(
                    final_raw_w,
                    final_raw_h,
                ),
                .mime_type = mime_type,
                .size_bytes = file_size,
                .orientation = orientation,
                .raw_metadata = RawMetadata.init(final_raw_w, final_raw_h),
                .decode = .{
                    .read_time_ms = read_time_ms,
                    .decode_time_ms = decode_time_ms,
                    .conversion_time_ms = conversion_time_ms,
                    .archive = .none,
                },
                .thumb_write_mtime_sec = thumb_write_mtime_sec,
                .thumb_probed = should_try_thumb,
            }),
        }) catch |err| {
            std.log.err("Failed to push image decode event: {}", .{err});
            f_surf.destroy();
        };
        workers.wakeMainThread();
        return true;
    } else {
        if (is_pair) return false;
        workers.event_queue.push(alloc, io, .{
            .decode_failed = .init(key, args.job_epoch, .{}),
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
        workers.wakeMainThread();
        return true;
    }
}

/// Encapsulates the two-stage payload lifecycle for `decodeWorker`:
/// - Stage 1 (`openStagedFile`): reads only up to `header_probe_limit` (256 KB) so EXIF orientation,
///   dimensions, and embedded JPEG thumbnails can be extracted and pushed to the main thread first.
/// - Stage 2 (`readRemaining`): reads any remaining file bytes and closes the `std.Io.File` handle
///   before CPU surface decompression begins.
const DecodePayload = struct {
    const Stage = union(enum) {
        staged_file: std.Io.File,
        complete,
    };

    path: []const u8,
    log_prefix: []const u8 = "",
    bytes: []u8,
    read_n: usize,
    size_bytes: u64,
    mtime_sec: ?i64 = null,
    read_time_ms: f64,
    archive: state_pkg.ArchiveTelemetry = .none,
    stage: Stage,

    fn fromArchiveEntry(
        args: *DecodeArgs,
        arch: ArchiveMediaEntry,
    ) ?DecodePayload {
        const max_bytes: ?usize = switch (args.mode) {
            .speculative_thumb => header_probe_limit,
            .full, .active_fast_scroll => null,
        };
        const dec_res = decompressCbzMediaEntry(
            args.allocator,
            args.io,
            arch,
            max_bytes,
        ) catch |err| {
            if (err == error.Canceled or args.cancelToken().isCanceled()) return null;
            failDecodeWorker(
                args.workers,
                args.allocator,
                args.io,
                args.key,
                args.job_epoch,
                "decodeWorker: failed to decompress CBZ entry '{s}' from '{s}': {}",
                .{ arch.entry_name, arch.archive_path, err },
            );
            return null;
        };

        return .{
            .path = arch.entry_name,
            .bytes = dec_res.bytes,
            .read_n = dec_res.bytes.len,
            .size_bytes = dec_res.bytes.len,
            .read_time_ms = dec_res.read_time_ms,
            .archive = state_pkg.ArchiveTelemetry.init(
                dec_res.decompress_time_ms,
                std.math.cast(
                    usize,
                    dec_res.compressed_size,
                ) orelse std.math.maxInt(usize),
            ),
            .stage = .complete,
        };
    }

    fn openStagedFile(
        args: *DecodeArgs,
        file_path: []const u8,
        log_prefix: []const u8,
    ) ?DecodePayload {
        const workers = args.workers;
        const alloc = args.allocator;
        const io = args.io;
        const key = args.key;
        const cancel = args.cancelToken();

        const s = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, file_path, .{}) catch |err| {
            if (err == error.Canceled or cancel.isCanceled()) return null;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: statFile failed for {s}'{s}': {}",
                .{ log_prefix, file_path, err },
            );
            return null;
        };

        const file_size = std.math.cast(usize, s.size) orelse {
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: file too large for {s}'{s}': {}",
                .{ log_prefix, file_path, s.size },
            );
            return null;
        };

        const start_read = std.Io.Clock.awake.now(io);
        const file = std.Io.Dir.openFile(
            std.Io.Dir.cwd(),
            io,
            file_path,
            .{},
        ) catch |err| {
            if (err == error.Canceled or cancel.isCanceled()) return null;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: openFile failed for {s}'{s}': {}",
                .{ log_prefix, file_path, err },
            );
            return null;
        };

        const stage1_target = @min(file_size, header_probe_limit);
        const target_read_size: usize = switch (args.mode) {
            .speculative_thumb => stage1_target,
            .full, .active_fast_scroll => file_size,
        };

        const bytes = alloc.alloc(u8, target_read_size) catch |err| {
            file.close(io);
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: alloc failed for {s}'{s}': {}",
                .{ log_prefix, file_path, err },
            );
            return null;
        };

        const read_n = readRangePositional(
            file,
            io,
            cancel,
            bytes[0..stage1_target],
            0,
        ) catch |err| {
            alloc.free(bytes);
            file.close(io);
            if (err == error.Canceled or cancel.isCanceled()) return null;
            failDecodeWorker(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                "decodeWorker: readPositional failed for {s}'{s}': {}",
                .{ log_prefix, file_path, err },
            );
            return null;
        };

        const read_time_ms = @as(
            f64,
            @floatFromInt(@max(0, start_read.untilNow(io, .awake).nanoseconds)),
        ) / 1_000_000.0;

        const has_more_on_disk = (read_n == stage1_target) and (read_n < file_size);
        const stage: Stage = if (has_more_on_disk)
            .{ .staged_file = file }
        else blk: {
            file.close(io);
            break :blk .complete;
        };

        return .{
            .path = file_path,
            .log_prefix = log_prefix,
            .bytes = bytes,
            .read_n = read_n,
            .size_bytes = s.size,
            .mtime_sec = s.mtime.toSeconds(),
            .read_time_ms = read_time_ms,
            .stage = stage,
        };
    }

    fn deinit(self: *DecodePayload, alloc: std.mem.Allocator, io: std.Io) void {
        switch (self.stage) {
            .staged_file => |file| {
                file.close(io);
                self.stage = .complete;
            },
            .complete => {},
        }
        alloc.free(self.bytes);
    }

    fn headerSlice(self: *const DecodePayload) []const u8 {
        return self.bytes[0..@min(self.read_n, header_probe_limit)];
    }

    fn readRemaining(self: *DecodePayload, args: *DecodeArgs) ?[]const u8 {
        switch (self.stage) {
            .complete => return self.bytes[0..self.read_n],
            .staged_file => |file| {
                defer {
                    file.close(args.io);
                    self.stage = .complete;
                }
                if (self.read_n < self.bytes.len) {
                    const cancel = args.cancelToken();
                    const start_read = std.Io.Clock.awake.now(args.io);
                    const rem_n = readRangePositional(
                        file,
                        args.io,
                        cancel,
                        self.bytes[self.read_n..],
                        self.read_n,
                    ) catch |err| {
                        if (err == error.Canceled or cancel.isCanceled()) return null;
                        failDecodeWorker(
                            args.workers,
                            args.allocator,
                            args.io,
                            args.key,
                            args.job_epoch,
                            "decodeWorker: readPositional failed for {s}'{s}': {}",
                            .{ self.log_prefix, self.path, err },
                        );
                        return null;
                    };
                    self.read_time_ms += @as(
                        f64,
                        @floatFromInt(
                            @max(
                                0,
                                start_read.untilNow(args.io, .awake)
                                    .nanoseconds,
                            ),
                        ),
                    ) / 1_000_000.0;
                    self.read_n += rem_n;
                }
                return self.bytes[0..self.read_n];
            },
        }
    }

    fn loadThumbnailSurface(
        self: *const DecodePayload,
        args: *DecodeArgs,
        valid_jpeg_thumb_loc: ?probe.ThumbnailLocation,
    ) error{Canceled}!ThumbLoadResult {
        const cancel = args.cancelToken();

        if (valid_jpeg_thumb_loc) |loc| {
            if (loc.sliceInBounds(self.bytes[0..self.read_n])) |slice| {
                if (cancel.isCanceled()) return error.Canceled;
                if (sdl.Surface.loadConstMemOpt(slice)) |surf| {
                    _ = args.workers.thumb_header_hits.fetchAdd(
                        1,
                        .monotonic,
                    );
                    return .{
                        .hit = .{
                            .surface = surf,
                            .source = .embedded_header,
                        },
                    };
                }
            } else if (self.stage == .staged_file) {
                const file = self.stage.staged_file;
                var loc_bytes = readLocationBytes(
                    args.allocator,
                    file,
                    args.io,
                    cancel,
                    self.bytes[0..self.read_n],
                    self.size_bytes,
                    loc,
                    null,
                ) catch |err| blk: {
                    if (err == error.Canceled or cancel.isCanceled()) {
                        return error.Canceled;
                    }
                    break :blk null;
                };
                if (loc_bytes) |*lb| {
                    defer lb.deinit(args.allocator);
                    if (cancel.isCanceled()) return error.Canceled;
                    if (sdl.Surface.loadConstMemOpt(lb.bytes)) |surf| {
                        _ = args.workers.thumb_positional_hits
                            .fetchAdd(1, .monotonic);
                        return .{
                            .hit = .{
                                .surface = surf,
                                .source = .embedded_positional,
                            },
                        };
                    }
                }
            }
        }

        return probeFreedesktopThumbCache(
            args.workers,
            args.allocator,
            args.io,
            cancel,
            self.path,
            self.mtime_sec,
            valid_jpeg_thumb_loc != null,
        );
    }
};

/// Background worker task that reads image files from disk or CBZ archives, parses metadata,
/// extracts EXIF thumbnails, and decompresses image surfaces into CPU memory.
pub fn decodeWorker(args: *DecodeArgs) void {
    const workers = args.workers;
    const alloc = args.allocator;
    const io = args.io;
    const key = args.key;
    const media_entry = args.entry;
    const cancel = args.cancelToken();
    defer {
        media_entry.deinit(alloc);
        alloc.destroy(args);
        _ = workers.active_decode_threads.fetchSub(1, .release);
        _ = workers.active_threads.fetchSub(1, .release);
        if (cancel.isCanceled()) {
            sdl.reclaimProcessHeap();
        }
        workers.wakeMainThread();
    }

    if (cancel.isCanceled()) return;

    var payload: DecodePayload = switch (media_entry) {
        .archive_entry => |arch| DecodePayload.fromArchiveEntry(
            args,
            arch,
        ) orelse return,
        .filesystem => |file_item| blk: {
            if (isRawFile(file_item.path)) {
                _ = decodeRawFile(args, file_item.path, false);
                return;
            }
            break :blk DecodePayload.openStagedFile(
                args,
                file_item.path,
                "",
            ) orelse return;
        },
        .pair => |pair| blk: {
            const allow_raw = args.pair_target != .standalone_jpeg;
            const try_raw = switch (args.mode) {
                .full, .active_fast_scroll => allow_raw,
                .speculative_thumb => true,
            };
            if (try_raw) {
                if (decodeRawFile(args, pair.raw_path, true)) {
                    return;
                }
            }
            break :blk DecodePayload.openStagedFile(
                args,
                pair.jpeg_path,
                "companion JPEG ",
            ) orelse return;
        },
    };
    defer payload.deinit(alloc, io);

    const header_buf = payload.headerSlice();
    const path = payload.path;
    const mime_type = probe.detectMimeType(header_buf, path);
    const is_raw_archive = isRawFile(path) or
        std.mem.startsWith(u8, mime_type, "image/x-");

    var raw_preview_slice: ?[]const u8 = null;
    var raw_sensor_dims: ?PhysicalDims = null;
    var orientation: probe.Orientation = .normal;

    if (is_raw_archive) {
        const raw_bytes = payload.readRemaining(args) orelse return;
        const raw_probe = probe.probeRawBuffer(raw_bytes, mime_type);
        const target_prev = switch (args.mode) {
            .full, .active_fast_scroll => raw_probe.preview,
            .speculative_thumb => raw_probe.thumbnail orelse
                raw_probe.medium orelse
                raw_probe.preview,
        };
        if (target_prev) |ploc| {
            raw_preview_slice = ploc.sliceInBounds(raw_bytes);
        }
        raw_sensor_dims = raw_probe.sensor_dims;
        orientation = raw_probe.orientation;
    } else {
        orientation = probe.parseExifOrientation(header_buf) orelse .normal;
    }

    if (cancel.isCanceled()) return;
    pushExifOrientation(
        workers,
        alloc,
        io,
        key,
        args.job_epoch,
        orientation,
    );

    const full_dims = probe.parseImageDimensions(header_buf, mime_type);
    const valid_jpeg_thumb_loc = probe.extractValidJpegThumbnailLocation(
        header_buf,
        mime_type,
        payload.size_bytes,
        512 * 1024,
    );
    var had_embedded_thumb = (valid_jpeg_thumb_loc != null);
    var probe_outcome: CacheProbeOutcome = .not_probed;

    // Attempt fast EXIF or Freedesktop cache thumbnail decoding for instant
    // placeholder preview
    const can_try_thumb = (valid_jpeg_thumb_loc != null) or
        (workers.thumb_cache_config != .disabled and payload.mtime_sec != null);
    const should_try_thumb = switch (args.mode) {
        .full => args.has_gpu_device and args.pair_target == .adaptive,
        .active_fast_scroll, .speculative_thumb => true,
    };
    const emit_thumb_only = switch (args.mode) {
        .full => false,
        .active_fast_scroll, .speculative_thumb => true,
    };
    if (can_try_thumb and should_try_thumb) {
        const thumb_res = payload.loadThumbnailSurface(
            args,
            valid_jpeg_thumb_loc,
        ) catch return;
        switch (thumb_res) {
            .hit => |loaded_thumb| {
                const t_surf = loaded_thumb.surface;
                had_embedded_thumb =
                    (loaded_thumb.source != .freedesktop_cache);
                probe_outcome = loaded_thumb.probe_outcome;
                if (cancel.isCanceled()) {
                    t_surf.destroy();
                    return;
                }
                const source_dims = full_dims orelse loaded_thumb.source_dims;
                pushThumbDecoded(
                    workers,
                    alloc,
                    io,
                    key,
                    args.job_epoch,
                    t_surf,
                    source_dims,
                    orientation,
                    emit_thumb_only,
                    loaded_thumb.source,
                    .none,
                );

                switch (args.mode) {
                    .active_fast_scroll, .speculative_thumb => return,
                    .full => {},
                }
            },
            .miss => |outcome| {
                had_embedded_thumb = false;
                probe_outcome = outcome;
            },
        }
    }

    switch (args.mode) {
        .speculative_thumb => {
            if (cancel.isCanceled()) return;
            const source_dims = full_dims;
            const raw_metadata: RawMetadata = if (is_raw_archive)
                (if (raw_sensor_dims) |d|
                    RawMetadata.fromDims(d)
                else if (source_dims) |sd|
                    RawMetadata.fromDims(sd)
                else
                    .none)
            else
                .none;
            pushDimensionsProbed(
                workers,
                alloc,
                io,
                key,
                args.job_epoch,
                source_dims,
                orientation,
                true,
                raw_metadata,
            );
            return;
        },
        .full, .active_fast_scroll => {},
    }

    if (cancel.isCanceled()) return;

    const full_bytes = payload.readRemaining(args) orelse return;
    const bytes_to_decode = if (raw_preview_slice) |s| s else full_bytes;
    const start_decode = std.Io.Clock.awake.now(io);
    const surface = sdl.Surface.loadConstMemOpt(bytes_to_decode);
    const decode_time_ms = @as(
        f64,
        @floatFromInt(
            @max(0, start_decode.untilNow(io, .awake).nanoseconds),
        ),
    ) / 1_000_000.0;

    if (surface == null) {
        failDecodeWorker(
            workers,
            alloc,
            io,
            key,
            args.job_epoch,
            "decodeWorker: failed to load image '{s}': {s}",
            .{ path, sdl.getError() },
        );
        return;
    }

    if (cancel.isCanceled()) {
        if (surface) |surf| surf.destroy();
        return;
    }

    const unscaled_w: f32 = @floatFromInt(surface.?.w());
    const unscaled_h: f32 = @floatFromInt(surface.?.h());
    const conv_res = convertAndScaleSurface(
        io,
        surface,
        args.pixel_format,
        args.has_gpu_device,
    );
    const final_surface = conv_res.surface;
    const conversion_time_ms = conv_res.conversion_time_ms;

    if (cancel.isCanceled()) {
        if (final_surface) |surf| surf.destroy();
        return;
    }

    if (final_surface) |f_surf| {
        const orig_w: f32 = @floatFromInt(f_surf.w());
        const orig_h: f32 = @floatFromInt(f_surf.h());
        const source_dims = full_dims orelse
            PhysicalDims.initPositive(unscaled_w, unscaled_h);
        const raw_metadata: RawMetadata = if (is_raw_archive)
            (if (raw_sensor_dims) |d|
                RawMetadata.fromDims(d)
            else if (source_dims) |sd|
                RawMetadata.fromDims(sd)
            else
                .none)
        else
            .none;
        const thumb_write_mtime_sec = resolveThumbWriteMtime(
            io,
            workers.thumb_cache_config,
            path,
            payload.mtime_sec,
            had_embedded_thumb,
            probe_outcome,
        );

        workers.event_queue.push(alloc, io, .{
            .image_decoded = .init(key, args.job_epoch, .{
                .surface = f_surf,
                .w = orig_w,
                .h = orig_h,
                .source_dims = source_dims,
                .mime_type = mime_type,
                .size_bytes = payload.size_bytes,
                .orientation = orientation,
                .raw_metadata = raw_metadata,
                .decode = .{
                    .read_time_ms = payload.read_time_ms,
                    .decode_time_ms = decode_time_ms,
                    .conversion_time_ms = conversion_time_ms,
                    .archive = payload.archive,
                },
                .thumb_write_mtime_sec = thumb_write_mtime_sec,
                .thumb_probed = should_try_thumb,
            }),
        }) catch |err| {
            std.log.err("Failed to push image decode event: {}", .{err});
            f_surf.destroy();
        };
    } else {
        workers.event_queue.push(alloc, io, .{
            .decode_failed = .init(key, args.job_epoch, .{}),
        }) catch |err| std.log.err("Failed to push image decode event: {}", .{err});
    }
}

test "decodeWorker - speculative_thumb skips full decompression on JPEG" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const path = try allocator.dupe(u8, "testfiles/images/000_0_1024x682.jpg");
    const entry = MediaEntry{ .filesystem = .{ .path = path } };

    var current_gen: std.atomic.Value(usize) = .init(1);
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .current_generation = &current_gen,
        .entry = entry,
        .has_gpu_device = false,
        .pixel_format = sdl.PixelFormat.rgba32,
        .mode = .speculative_thumb,
    };

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);

    decodeWorker(args);

    var dimensions_probed_seen = false;
    var image_decoded_seen = false;

    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .dimensions_probed => |d_evt| {
                const d = d_evt.unwrapForTest();
                dimensions_probed_seen = true;
                try std.testing.expect(d.thumb_only);
                try std.testing.expectEqual(
                    PhysicalDims{ .w = 1024.0, .h = 682.0 },
                    d.source_dims.?,
                );
            },
            .image_decoded => {
                image_decoded_seen = true;
            },
            .exif_orientation_parsed,
            .thumb_decoded,
            .decode_failed,
            .path_discovered,
            .directory_scan_result,
            .palette_dir_loaded,
            .palette_folder_count,
            .precache_completed,
            .ipc_command,
            => {},
        }
    }

    try std.testing.expect(dimensions_probed_seen);
    try std.testing.expect(!image_decoded_seen);
}

test "decodeWorker - speculative_thumb skips full decompression on PNG" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const path = try allocator.dupe(u8, "testfiles/golden-screenshots/init.png");
    const entry = MediaEntry{ .filesystem = .{ .path = path } };

    var current_gen: std.atomic.Value(usize) = .init(1);
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .current_generation = &current_gen,
        .entry = entry,
        .has_gpu_device = true,
        .pixel_format = sdl.PixelFormat.rgba32,
        .mode = .speculative_thumb,
    };

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);

    decodeWorker(args);

    var dimensions_probed_seen = false;
    var image_decoded_seen = false;

    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .dimensions_probed => |d_evt| {
                const d = d_evt.unwrapForTest();
                dimensions_probed_seen = true;
                try std.testing.expect(d.thumb_only);
                try std.testing.expect(d.source_dims != null);
            },
            .image_decoded => {
                image_decoded_seen = true;
            },
            .exif_orientation_parsed,
            .thumb_decoded,
            .decode_failed,
            .path_discovered,
            .directory_scan_result,
            .palette_dir_loaded,
            .palette_folder_count,
            .precache_completed,
            .ipc_command,
            => {},
        }
    }

    try std.testing.expect(dimensions_probed_seen);
    try std.testing.expect(!image_decoded_seen);
}

test "decodeWorker - prunes early when current_generation does not match key.generation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const path = try allocator.dupe(u8, "testfiles/golden-screenshots/init.png");
    const entry = MediaEntry{ .filesystem = .{ .path = path } };

    var current_gen: std.atomic.Value(usize) = .init(2);
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .entry = entry,
        .has_gpu_device = true,
        .pixel_format = sdl.PixelFormat.rgba32,
        .mode = .full,
        .current_generation = &current_gen,
    };

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);

    decodeWorker(args);

    var event_seen = false;
    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        event_seen = true;
    }

    try std.testing.expect(!event_seen);
}

test "decodeWorker - Sony ARW range reading and preview extraction" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Read real JPEG to embed as preview
    const sample_jpg_path = "testfiles/images/000_0_1024x682.jpg";
    var real_jpg = try std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        sample_jpg_path,
        .{},
    );
    defer real_jpg.close(io);
    const jpg_stat = try std.Io.Dir.statFile(
        std.Io.Dir.cwd(),
        io,
        sample_jpg_path,
        .{},
    );
    const jpg_bytes = try allocator.alloc(u8, @intCast(jpg_stat.size));
    defer allocator.free(jpg_bytes);
    var j_slices = [_][]u8{jpg_bytes};
    _ = try real_jpg.readPositional(io, &j_slices, 0);

    const tiff_buf = try probe.buildSyntheticSubIfdArwAlloc(
        allocator,
        6000,
        4000,
        6,
        jpg_bytes,
    );
    defer allocator.free(tiff_buf);

    // Write mock file in isolated temp directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_test.arw", .{});
    var wr_slices = [_][]const u8{tiff_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_test.arw",
        .{tmp.sub_path},
    );

    // Test 1: Full decode (.full)
    {
        var workers = WorkerManager{};
        defer workers.deinit(allocator, io);

        const p = try allocator.dupe(u8, mock_path);
        const entry = MediaEntry{ .filesystem = .{ .path = p } };
        var current_gen: std.atomic.Value(usize) = .init(1);
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .full,
        };

        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);

        decodeWorker(args);

        var image_decoded_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .image_decoded => |img_evt| {
                    const img_payload = img_evt.unwrapForTest();
                    image_decoded_seen = true;
                    try std.testing.expect(img_payload.raw_metadata.isRaw());
                    const s_dims = img_payload.raw_metadata.getSensorDims().?;
                    try std.testing.expectEqual(@as(f32, 6000.0), s_dims.w);
                    try std.testing.expectEqual(@as(f32, 4000.0), s_dims.h);
                    try std.testing.expectEqual(
                        probe.Orientation.rotate_90,
                        img_payload.orientation,
                    );
                    try std.testing.expect(img_payload.surface != null);
                    try std.testing.expectEqual(@as(f32, 1024.0), img_payload.w);
                    try std.testing.expectEqual(@as(f32, 682.0), img_payload.h);
                },
                else => {},
            }
        }
        try std.testing.expect(image_decoded_seen);
    }

    // Test 2: Speculative thumb decode (.speculative_thumb)
    {
        var workers = WorkerManager{};
        defer workers.deinit(allocator, io);

        const p = try allocator.dupe(u8, mock_path);
        const entry = MediaEntry{ .filesystem = .{ .path = p } };
        var current_gen: std.atomic.Value(usize) = .init(1);
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .speculative_thumb,
        };

        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);

        decodeWorker(args);

        var thumb_decoded_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .thumb_decoded => |t_evt| {
                    const t_payload = t_evt.unwrapForTest();
                    thumb_decoded_seen = true;
                    try std.testing.expect(t_payload.raw_metadata.isRaw());
                    try std.testing.expect(t_payload.thumb_only);
                    const ts_dims = t_payload.raw_metadata.getSensorDims().?;
                    try std.testing.expectEqual(@as(f32, 6000.0), ts_dims.w);
                    try std.testing.expectEqual(@as(f32, 4000.0), ts_dims.h);
                    try std.testing.expectEqual(
                        probe.Orientation.rotate_90,
                        t_payload.orientation,
                    );
                },
                else => {},
            }
        }
        try std.testing.expect(thumb_decoded_seen);
    }
}

test "decodeWorker - Fujifilm RAF range reading and preview extraction" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Read real JPEG to embed as preview
    const sample_jpg_path = "testfiles/images/000_0_1024x682.jpg";
    var real_jpg = try std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        sample_jpg_path,
        .{},
    );
    defer real_jpg.close(io);
    const jpg_stat = try std.Io.Dir.statFile(
        std.Io.Dir.cwd(),
        io,
        sample_jpg_path,
        .{},
    );
    const jpg_bytes = try allocator.alloc(u8, @intCast(jpg_stat.size));
    defer allocator.free(jpg_bytes);
    var j_slices = [_][]u8{jpg_bytes};
    _ = try real_jpg.readPositional(io, &j_slices, 0);

    const raf_buf = try probe.buildSyntheticFujiRafAlloc(
        allocator,
        6240,
        4160,
        jpg_bytes,
    );
    defer allocator.free(raf_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_test.raf", .{});
    var wr_slices = [_][]const u8{raf_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_test.raf",
        .{tmp.sub_path},
    );

    // Test full decode
    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    const p = try allocator.dupe(u8, mock_path);
    const entry = MediaEntry{ .filesystem = .{ .path = p } };
    var current_gen: std.atomic.Value(usize) = .init(1);
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .current_generation = &current_gen,
        .entry = entry,
        .has_gpu_device = true,
        .pixel_format = sdl.PixelFormat.rgba32,
        .mode = .full,
    };

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);

    decodeWorker(args);

    var image_decoded_seen = false;
    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .image_decoded => |img_evt| {
                const img_payload = img_evt.unwrapForTest();
                image_decoded_seen = true;
                try std.testing.expect(img_payload.raw_metadata.isRaw());
                const s_dims = img_payload.raw_metadata.getSensorDims().?;
                try std.testing.expectEqual(@as(f32, 6240.0), s_dims.w);
                try std.testing.expectEqual(@as(f32, 4160.0), s_dims.h);
                try std.testing.expect(img_payload.surface != null);
                try std.testing.expectEqual(@as(f32, 1024.0), img_payload.w);
                try std.testing.expectEqual(@as(f32, 682.0), img_payload.h);
            },
            else => {},
        }
    }
    try std.testing.expect(image_decoded_seen);
}

test "decodeWorker - progressive 3-tier loading for synthetic ARW" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const thumb_path = "testfiles/images/063_63_1024x576.jpg"; // ~18 KB
    const med_path = "testfiles/images/024_24_1024x380.jpg"; // ~28 KB
    const prev_path = "testfiles/images/000_0_1024x682.jpg"; // ~58 KB

    const readJpeg = struct {
        fn run(
            alloc: std.mem.Allocator,
            io_inst: std.Io,
            path: []const u8,
        ) ![]u8 {
            var f = try std.Io.Dir.openFile(
                std.Io.Dir.cwd(),
                io_inst,
                path,
                .{},
            );
            defer f.close(io_inst);
            const st = try std.Io.Dir.statFile(
                std.Io.Dir.cwd(),
                io_inst,
                path,
                .{},
            );
            const buf = try alloc.alloc(u8, @intCast(st.size));
            errdefer alloc.free(buf);
            var slices = [_][]u8{buf};
            _ = try f.readPositional(io_inst, &slices, 0);
            return buf;
        }
    }.run;

    const thumb_bytes = try readJpeg(allocator, io, thumb_path);
    defer allocator.free(thumb_bytes);
    const med_bytes = try readJpeg(allocator, io, med_path);
    defer allocator.free(med_bytes);
    const prev_bytes = try readJpeg(allocator, io, prev_path);
    defer allocator.free(prev_bytes);

    const tiff_buf = try probe.buildSynthetic3TierArwAlloc(
        allocator,
        6240,
        4160,
        thumb_bytes,
        med_bytes,
        prev_bytes,
    );
    defer allocator.free(tiff_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_3tier.arw", .{});
    var wr_slices = [_][]const u8{tiff_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const arw_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_3tier.arw",
        .{tmp.sub_path},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    var current_gen: std.atomic.Value(usize) = .init(1);

    // Case 1: Fast scrubbing (.speculative_thumb) -> receives IFD1 (1024x576)
    {
        const p = try allocator.dupe(u8, arw_path);
        const entry = MediaEntry{ .filesystem = .{ .path = p } };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .speculative_thumb,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);

        decodeWorker(args);

        var thumb_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .thumb_decoded => |t_evt| {
                    const t = t_evt.unwrapForTest();
                    thumb_seen = true;
                    try std.testing.expectEqual(@as(f32, 1024.0), t.w);
                    try std.testing.expectEqual(@as(f32, 576.0), t.h);
                    try std.testing.expectEqual(
                        PhysicalDims{ .w = 6240.0, .h = 4160.0 },
                        t.source_dims.?,
                    );
                },
                else => {},
            }
        }
        try std.testing.expect(thumb_seen);
    }

    // Case 2: Settled viewing (.full) -> receives IFD0 medium
    // placeholder (1024x380), then IFD2 full preview (1024x682)
    {
        const p = try allocator.dupe(u8, arw_path);
        const entry = MediaEntry{ .filesystem = .{ .path = p } };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(2), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .full,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);

        decodeWorker(args);

        var med_thumb_seen = false;
        var full_image_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .thumb_decoded => |t_evt| {
                    const t = t_evt.unwrapForTest();
                    med_thumb_seen = true;
                    try std.testing.expectEqual(@as(f32, 1024.0), t.w);
                    try std.testing.expectEqual(@as(f32, 380.0), t.h);
                    try std.testing.expectEqual(
                        PhysicalDims{ .w = 6240.0, .h = 4160.0 },
                        t.source_dims.?,
                    );
                },
                .image_decoded => |img_evt| {
                    const img = img_evt.unwrapForTest();
                    full_image_seen = true;
                    try std.testing.expectEqual(@as(f32, 1024.0), img.w);
                    try std.testing.expectEqual(@as(f32, 682.0), img.h);
                    const s_dims = img.raw_metadata.getSensorDims().?;
                    try std.testing.expectEqual(@as(f32, 6240.0), s_dims.w);
                    try std.testing.expectEqual(@as(f32, 4160.0), s_dims.h);
                },
                else => {},
            }
        }
        try std.testing.expect(med_thumb_seen);
        try std.testing.expect(full_image_seen);
    }
}

test "decodeWorker - progressive pair loading with PairStreamTarget" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const jpg_file = "testfiles/images/000_0_1024x682.jpg";
    var real_jpg = try std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        jpg_file,
        .{},
    );
    defer real_jpg.close(io);
    const s = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, jpg_file, .{});
    const jpg_bytes = try allocator.alloc(u8, s.size);
    defer allocator.free(jpg_bytes);
    var j_slices = [_][]u8{jpg_bytes};
    _ = try real_jpg.readPositional(io, &j_slices, 0);

    const tiff_buf = try probe.buildSyntheticSubIfdArwAlloc(
        allocator,
        6000,
        4000,
        1,
        jpg_bytes,
    );
    defer allocator.free(tiff_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "mock_pair.arw", .{});
    var wr_slices = [_][]const u8{tiff_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const raw_file = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/mock_pair.arw",
        .{tmp.sub_path},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    var current_gen: std.atomic.Value(usize) = .init(1);

    // 1. active_fast_scroll decodes RAW thumbnail and returns early
    {
        const pair = FilePair{
            .raw_path = try allocator.dupe(u8, raw_file),
            .jpeg_path = try allocator.dupe(u8, jpg_file),
        };
        const entry = MediaEntry{ .pair = pair };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .active_fast_scroll,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        var thumb_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            if (ev.* == .thumb_decoded) {
                thumb_seen = true;
                try std.testing.expect(
                    ev.thumb_decoded.unwrapForTest().raw_metadata.isRaw(),
                );
            }
        }
        try std.testing.expect(thumb_seen);
    }

    // 2. pair_target = .standalone_jpeg decodes companion JPEG
    {
        const pair = FilePair{
            .raw_path = try allocator.dupe(u8, raw_file),
            .jpeg_path = try allocator.dupe(u8, jpg_file),
        };
        const entry = MediaEntry{ .pair = pair };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(2), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .full,
            .pair_target = .standalone_jpeg,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        var jpeg_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            if (ev.* == .image_decoded) {
                jpeg_seen = true;
                const img = ev.image_decoded.unwrapForTest();
                try std.testing.expect(!img.raw_metadata.isRaw());
                try std.testing.expectEqual(@as(f32, 1024.0), img.w);
                try std.testing.expectEqual(@as(f32, 682.0), img.h);
            }
        }
        try std.testing.expect(jpeg_seen);
    }

    // 3. pair_target = .adaptive settled decodes RAW preview
    {
        const pair = FilePair{
            .raw_path = try allocator.dupe(u8, raw_file),
            .jpeg_path = try allocator.dupe(u8, jpg_file),
        };
        const entry = MediaEntry{ .pair = pair };
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(3), .generation = 1 },
            .current_generation = &current_gen,
            .entry = entry,
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .full,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        var raw_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            if (ev.* == .image_decoded) {
                raw_seen = true;
                try std.testing.expect(
                    ev.image_decoded.unwrapForTest().raw_metadata.isRaw(),
                );
            }
        }
        try std.testing.expect(raw_seen);
    }
}

test "decodeWorker - canceled RAW pair exits without fallback" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);

    var current_gen: std.atomic.Value(usize) = .init(2);
    const pair = FilePair{
        .raw_path = try allocator.dupe(u8, "nonexistent.raf"),
        .jpeg_path = try allocator.dupe(
            u8,
            "testfiles/images/000_0_1024x682.jpg",
        ),
    };
    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        // Stale generation -> canceled
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .current_generation = &current_gen,
        .entry = .{ .pair = pair },
        .has_gpu_device = false,
        .pixel_format = sdl.PixelFormat.rgba32,
        .mode = .full,
    };

    try std.testing.expect(decodeRawFile(args, pair.raw_path, true));

    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);
    decodeWorker(args);

    try std.testing.expectEqual(
        @as(usize, 0),
        workers.active_decode_threads.load(.acquire),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        workers.active_threads.load(.acquire),
    );
    try std.testing.expect(workers.event_queue.pop() == null);
}

test "decodeWorker - two-stage JPEG read emits header and positional thumbnails before Stage 2" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const main_jpg_path = "testfiles/images/000_0_1024x682.jpg";
    const thumb_jpg_path = "testfiles/images/063_63_1024x576.jpg";

    const readAll = struct {
        fn run(alloc: std.mem.Allocator, io_inst: std.Io, p: []const u8) ![]u8 {
            var f = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io_inst, p, .{});
            defer f.close(io_inst);
            const st = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io_inst, p, .{});
            const buf = try alloc.alloc(u8, @intCast(st.size));
            errdefer alloc.free(buf);
            var slices = [_][]u8{buf};
            _ = try f.readPositional(io_inst, &slices, 0);
            return buf;
        }
    }.run;

    const main_jpg = try readAll(allocator, io, main_jpg_path);
    defer allocator.free(main_jpg);
    const thumb_jpg = try readAll(allocator, io, thumb_jpg_path);
    defer allocator.free(thumb_jpg);

    // Build a synthetic JPEG > 256 KB where:
    // - SOI (2 bytes) + APP1 EXIF header (72 bytes) with Orientation = 6 (rotate_90)
    //   and IFD1 JPEGInterchangeFormat pointing to `thumb_tiff_rel_off`.
    // - Followed by `main_jpg[2..]` so SOF0/SOS/EOI are valid.
    // - Padded past `header_probe_limit` (256 KB) with `thumb_jpg` placed at `positional_thumb_off`.
    const app1_payload_len: usize = 6 + 64; // "Exif\x00\x00" + 64-byte TIFF header
    const app1_total_len: usize = 4 + app1_payload_len; // 0xFF 0xE1 + len(2) + payload
    const tiff_start_off: usize = 2 + 4 + 6; // offset 12 in file
    const positional_thumb_off: usize = header_probe_limit + 16 * 1024;
    const total_file_len: usize = positional_thumb_off + thumb_jpg.len;

    const file_buf = try allocator.alloc(u8, total_file_len);
    defer allocator.free(file_buf);
    @memset(file_buf, 0);

    // 1. SOI
    file_buf[0] = 0xFF;
    file_buf[1] = 0xD8;

    // 2. APP1 marker at offset 2
    file_buf[2] = 0xFF;
    file_buf[3] = 0xE1;
    std.mem.writeInt(u16, file_buf[4..6], @intCast(2 + app1_payload_len), .big);
    @memcpy(file_buf[6..12], "Exif\x00\x00");

    // 3. Little-endian TIFF header at `tiff_start_off` (12)
    const tiff = file_buf[tiff_start_off .. tiff_start_off + 64];
    tiff[0] = 'I';
    tiff[1] = 'I';
    std.mem.writeInt(u16, tiff[2..4], 0x002A, .little);
    std.mem.writeInt(u32, tiff[4..8], 8, .little); // IFD0 at 8

    // IFD0 at +8: 1 entry (Orientation = 6), next IFD1 at +26
    std.mem.writeInt(u16, tiff[8..10], 1, .little);
    std.mem.writeInt(u16, tiff[10..12], 0x0112, .little);
    std.mem.writeInt(u16, tiff[12..14], 3, .little);
    std.mem.writeInt(u32, tiff[14..18], 1, .little);
    std.mem.writeInt(u16, tiff[18..20], 6, .little);
    std.mem.writeInt(u32, tiff[22..26], 26, .little); // IFD1 offset = 26

    // IFD1 at +26: 2 entries (0x0201 offset, 0x0202 length)
    std.mem.writeInt(u16, tiff[26..28], 2, .little);
    std.mem.writeInt(u16, tiff[28..30], 0x0201, .little);
    std.mem.writeInt(u16, tiff[30..32], 4, .little);
    std.mem.writeInt(u32, tiff[32..36], 1, .little);
    std.mem.writeInt(
        u32,
        tiff[36..40],
        @intCast(positional_thumb_off - tiff_start_off),
        .little,
    );
    std.mem.writeInt(u16, tiff[40..42], 0x0202, .little);
    std.mem.writeInt(u16, tiff[42..44], 4, .little);
    std.mem.writeInt(u32, tiff[44..48], 1, .little);
    std.mem.writeInt(u32, tiff[48..52], @intCast(thumb_jpg.len), .little);
    std.mem.writeInt(u32, tiff[52..56], 0, .little);

    // 4. Copy main JPEG body right after APP1
    const body_start = 2 + app1_total_len;
    @memcpy(file_buf[body_start .. body_start + (main_jpg.len - 2)], main_jpg[2..]);

    // 5. Place thumbnail at `positional_thumb_off` (> 256 KB)
    @memcpy(
        file_buf[positional_thumb_off .. positional_thumb_off + thumb_jpg.len],
        thumb_jpg,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "staged_pos_thumb.jpg", .{});
    var wr_slices = [_][]const u8{file_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/staged_pos_thumb.jpg",
        .{tmp.sub_path},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    var current_gen: std.atomic.Value(usize) = .init(1);

    // Case 1: .speculative_thumb with thumbnail past 256 KB succeeds via
    // Stage 1 open file
    {
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{
                .filesystem = .{ .path = try allocator.dupe(u8, mock_path) },
            },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .speculative_thumb,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        try std.testing.expectEqual(@as(usize, 0), workers.thumb_header_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 1), workers.thumb_positional_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 0), workers.thumb_misses.load(.monotonic));

        var orient_seen = false;
        var thumb_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .exif_orientation_parsed => |o_evt| {
                    orient_seen = true;
                    try std.testing.expectEqual(
                        probe.Orientation.rotate_90,
                        o_evt.unwrapForTest().orientation,
                    );
                },
                .thumb_decoded => |t_evt| {
                    const t = t_evt.unwrapForTest();
                    thumb_seen = true;
                    try std.testing.expect(t.thumb_only);
                    try std.testing.expectEqual(@as(f32, 1024.0), t.w);
                    try std.testing.expectEqual(@as(f32, 576.0), t.h);
                    try std.testing.expectEqual(
                        PhysicalDims{ .w = 1024.0, .h = 682.0 },
                        t.source_dims.?,
                    );
                },
                .image_decoded,
                .dimensions_probed,
                .decode_failed,
                .path_discovered,
                .directory_scan_result,
                .palette_dir_loaded,
                .palette_folder_count,
                .precache_completed,
                .ipc_command,
                => {
                    return error.TestUnexpectedResult;
                },
            }
        }
        try std.testing.expect(orient_seen);
        try std.testing.expect(thumb_seen);
    }

    // Case 2: .full emits orientation + thumb in Stage 1, then full image
    // in Stage 2
    {
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(2), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{
                .filesystem = .{ .path = try allocator.dupe(u8, mock_path) },
            },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .full,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        try std.testing.expectEqual(@as(usize, 2), workers.thumb_positional_hits.load(.monotonic));

        var batch: std.ArrayList(@TypeOf(workers.event_queue.items.items[0])) = .empty;
        defer {
            for (batch.items) |*ev| ev.deinit(allocator);
            batch.deinit(allocator);
        }
        workers.event_queue.drain(io, &batch);
        try std.testing.expectEqual(@as(usize, 3), batch.items.len);

        try std.testing.expect(batch.items[0] == .exif_orientation_parsed);
        try std.testing.expect(batch.items[1] == .thumb_decoded);
        const t = batch.items[1].thumb_decoded.unwrapForTest();
        try std.testing.expect(!t.thumb_only);
        try std.testing.expectEqual(@as(f32, 1024.0), t.w);
        try std.testing.expectEqual(@as(f32, 576.0), t.h);

        try std.testing.expect(batch.items[2] == .image_decoded);
        const img = batch.items[2].image_decoded.unwrapForTest();
        try std.testing.expectEqual(@as(f32, 1024.0), img.w);
        try std.testing.expectEqual(@as(f32, 682.0), img.h);
        try std.testing.expectEqual(@as(u64, total_file_len), img.size_bytes);
    }

    // Case 3: Header-resident thumbnail in > 256 KB JPEG records thumb_header_hits
    {
        const header_thumb_off: usize = 128 * 1024;
        std.mem.writeInt(
            u32,
            file_buf[tiff_start_off + 36 ..][0..4],
            @intCast(header_thumb_off - tiff_start_off),
            .little,
        );
        @memcpy(
            file_buf[header_thumb_off .. header_thumb_off + thumb_jpg.len],
            thumb_jpg,
        );

        var hdr_file = try tmp.dir.createFile(io, "staged_hdr_thumb.jpg", .{});
        var hdr_slices = [_][]const u8{file_buf};
        _ = try hdr_file.writePositional(io, &hdr_slices, 0);
        hdr_file.close(io);

        var hdr_path_buf: [128]u8 = undefined;
        const hdr_path = try std.mem.print(
            &hdr_path_buf,
            ".zig-cache/tmp/{s}/staged_hdr_thumb.jpg",
            .{tmp.sub_path},
        );

        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(3), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{ .filesystem = .{ .path = try allocator.dupe(u8, hdr_path) } },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .full,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        try std.testing.expectEqual(@as(usize, 1), workers.thumb_header_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 2), workers.thumb_positional_hits.load(.monotonic));

        var batch: std.ArrayList(@TypeOf(workers.event_queue.items.items[0])) = .empty;
        defer {
            for (batch.items) |*ev| ev.deinit(allocator);
            batch.deinit(allocator);
        }
        workers.event_queue.drain(io, &batch);
        try std.testing.expectEqual(@as(usize, 3), batch.items.len);
        try std.testing.expect(batch.items[0] == .exif_orientation_parsed);
        try std.testing.expect(batch.items[1] == .thumb_decoded);
        try std.testing.expect(batch.items[2] == .image_decoded);
    }
}

test "decodeWorker and background writer Freedesktop thumbnail roundtrip" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cache_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel_cache_dir = try std.mem.print(
        &cache_dir_buf,
        ".zig-cache/tmp/{s}/thumbnails",
        .{tmp.sub_path},
    );
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, rel_cache_dir);

    var real_cache_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_cache_len = try std.Io.Dir.realPathFile(
        std.Io.Dir.cwd(),
        io,
        rel_cache_dir,
        &real_cache_buf,
    );
    const abs_cache_dir = real_cache_buf[0..real_cache_len];

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    workers.thumb_cache_config = try ThumbCacheConfig.initWithDir(
        allocator,
        abs_cache_dir,
        .large,
        .all_missing,
    );

    const png_path = "testfiles/golden-screenshots/init.png";
    var current_gen: std.atomic.Value(usize) = .init(1);

    // 1. Cold cache: PNG has no embedded thumbnail and no cached thumbnail yet
    {
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{
                .filesystem = .{ .path = try allocator.dupe(u8, png_path) },
            },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .full,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        const stats1 = workers.snapshotThumbStats();
        try std.testing.expectEqual(@as(usize, 0), stats1.cache_hits);
        try std.testing.expectEqual(@as(usize, 1), stats1.misses);

        var ev = workers.event_queue.pop() orelse return error.MissingEvent;
        defer ev.deinit(allocator);
        try std.testing.expect(ev == .image_decoded);

        const img = ev.image_decoded.unwrapForTest();
        try std.testing.expect(img.thumb_write_mtime_sec != null);
        try std.testing.expect(img.thumb_write_mtime_sec.? > 0);

        const surf = img.surface orelse return error.MissingSurface;
        // Disown surface from event and enqueue background Freedesktop
        // thumbnail write
        ev.image_decoded.unchecked_payload.surface = null;
        workers.enqueueThumbWrite(allocator, io, .{
            .surface = surf,
            .source_path = try allocator.dupe(u8, png_path),
            .mime_type = img.mime_type,
            .file_size = img.size_bytes,
            .mtime_sec = img.thumb_write_mtime_sec.?,
            .orientation = img.orientation,
            .source_dims = .{ .w = img.w, .h = img.h },
        });

        var wait_iters: usize = 0;
        while (workers.thumb_cache_write_queued.load(.acquire) > 0 or
            workers.active_thumb_writers.load(.acquire) > 0) : (wait_iters += 1)
        {
            if (wait_iters > 400) return error.ThumbWriteTimeout;
            try std.Io.sleep(io, .fromMilliseconds(5), .awake);
        }

        const stats2 = workers.snapshotThumbStats();
        try std.testing.expectEqual(@as(usize, 1), stats2.cache_writes);
        try std.testing.expectEqual(@as(usize, 0), stats2.cache_write_queued);
    }

    // 2. Warm cache: decoding the same PNG now hits the Freedesktop cache in
    // Stage 1 and sets needs_thumb_write = false
    {
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{
                .filesystem = .{ .path = try allocator.dupe(u8, png_path) },
            },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .full,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        const stats3 = workers.snapshotThumbStats();
        try std.testing.expectEqual(@as(usize, 1), stats3.cache_hits);
        try std.testing.expectEqual(@as(usize, 1), stats3.misses);

        const EventItem = @TypeOf(workers.event_queue.items.items[0]);
        var batch: std.ArrayList(EventItem) = .empty;
        defer {
            for (batch.items) |*ev| ev.deinit(allocator);
            batch.deinit(allocator);
        }
        workers.event_queue.drain(io, &batch);
        try std.testing.expectEqual(@as(usize, 2), batch.items.len);
        try std.testing.expect(batch.items[0] == .thumb_decoded);
        const thumb = batch.items[0].thumb_decoded.unwrapForTest();
        try std.testing.expectEqual(
            ThumbnailSource.freedesktop_cache,
            thumb.source,
        );
        try std.testing.expect(!thumb.dct_snapped);
        try std.testing.expect(thumb.w <= 256.0 and thumb.h <= 256.0);

        try std.testing.expect(batch.items[1] == .image_decoded);
        const img = batch.items[1].image_decoded.unwrapForTest();
        try std.testing.expect(img.thumb_write_mtime_sec == null);
    }
}

test "decodeWorker - active_fast_scroll thumb hit returns early" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const main_jpg_path = "testfiles/images/000_0_1024x682.jpg";
    const thumb_jpg_path = "testfiles/images/063_63_1024x576.jpg";

    const readAll = struct {
        fn run(alloc: std.mem.Allocator, io_inst: std.Io, p: []const u8) ![]u8 {
            var f = try std.Io.Dir.openFile(
                std.Io.Dir.cwd(),
                io_inst,
                p,
                .{},
            );
            defer f.close(io_inst);
            const st = try std.Io.Dir.statFile(
                std.Io.Dir.cwd(),
                io_inst,
                p,
                .{},
            );
            const buf = try alloc.alloc(u8, @intCast(st.size));
            errdefer alloc.free(buf);
            var slices = [_][]u8{buf};
            _ = try f.readPositional(io_inst, &slices, 0);
            return buf;
        }
    }.run;

    const main_jpg = try readAll(allocator, io, main_jpg_path);
    defer allocator.free(main_jpg);
    const thumb_jpg = try readAll(allocator, io, thumb_jpg_path);
    defer allocator.free(thumb_jpg);

    const app1_payload_len: usize = 6 + 56 + thumb_jpg.len;
    const app1_total_len: usize = 4 + app1_payload_len;
    const tiff_start_off: usize = 2 + 4 + 6;
    const file_buf = try allocator.alloc(
        u8,
        app1_total_len + main_jpg.len,
    );
    defer allocator.free(file_buf);
    @memset(file_buf, 0);

    file_buf[0] = 0xFF;
    file_buf[1] = 0xD8;
    file_buf[2] = 0xFF;
    file_buf[3] = 0xE1;
    std.mem.writeInt(
        u16,
        file_buf[4..6],
        @intCast(2 + app1_payload_len),
        .big,
    );
    @memcpy(file_buf[6..12], "Exif\x00\x00");

    const tiff = file_buf[tiff_start_off .. tiff_start_off + 56];
    tiff[0] = 'I';
    tiff[1] = 'I';
    std.mem.writeInt(u16, tiff[2..4], 0x002A, .little);
    std.mem.writeInt(u32, tiff[4..8], 8, .little);
    std.mem.writeInt(u16, tiff[8..10], 1, .little);
    std.mem.writeInt(u16, tiff[10..12], 0x0112, .little);
    std.mem.writeInt(u16, tiff[12..14], 3, .little);
    std.mem.writeInt(u32, tiff[14..18], 1, .little);
    std.mem.writeInt(u16, tiff[18..20], 1, .little);
    std.mem.writeInt(u32, tiff[22..26], 26, .little);
    std.mem.writeInt(u16, tiff[26..28], 2, .little);
    std.mem.writeInt(u16, tiff[28..30], 0x0201, .little);
    std.mem.writeInt(u16, tiff[30..32], 4, .little);
    std.mem.writeInt(u32, tiff[32..36], 1, .little);
    std.mem.writeInt(u32, tiff[36..40], 56, .little);
    std.mem.writeInt(u16, tiff[40..42], 0x0202, .little);
    std.mem.writeInt(u16, tiff[42..44], 4, .little);
    std.mem.writeInt(u32, tiff[44..48], 1, .little);
    std.mem.writeInt(u32, tiff[48..52], @intCast(thumb_jpg.len), .little);
    std.mem.writeInt(u32, tiff[52..56], 0, .little);
    @memcpy(
        file_buf[tiff_start_off + 56 .. tiff_start_off + 56 + thumb_jpg.len],
        thumb_jpg,
    );
    @memcpy(
        file_buf[2 + app1_total_len .. 2 + app1_total_len + (main_jpg.len - 2)],
        main_jpg[2..],
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mock_file = try tmp.dir.createFile(io, "fast_thumb_hit.jpg", .{});
    var wr_slices = [_][]const u8{file_buf};
    _ = try mock_file.writePositional(io, &wr_slices, 0);
    mock_file.close(io);

    var path_buf: [128]u8 = undefined;
    const mock_path = try std.mem.print(
        &path_buf,
        ".zig-cache/tmp/{s}/fast_thumb_hit.jpg",
        .{tmp.sub_path},
    );

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    var current_gen: std.atomic.Value(usize) = .init(1);

    const args = try allocator.create(DecodeArgs);
    args.* = .{
        .workers = &workers,
        .allocator = allocator,
        .io = io,
        .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
        .current_generation = &current_gen,
        .entry = .{
            .filesystem = .{ .path = try allocator.dupe(u8, mock_path) },
        },
        .has_gpu_device = true,
        .pixel_format = sdl.PixelFormat.rgba32,
        .mode = .active_fast_scroll,
        .pair_target = .adaptive,
    };
    _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = workers.active_threads.fetchAdd(1, .monotonic);
    decodeWorker(args);

    var thumb_seen = false;
    var image_seen = false;
    var dims_seen = false;
    while (workers.event_queue.pop()) |*ev| {
        defer ev.deinit(allocator);
        switch (ev.*) {
            .thumb_decoded => |t_evt| {
                const t = t_evt.unwrapForTest();
                thumb_seen = true;
                try std.testing.expect(t.thumb_only);
                try std.testing.expectEqual(@as(f32, 1024.0), t.w);
                try std.testing.expectEqual(@as(f32, 576.0), t.h);
            },
            .image_decoded => image_seen = true,
            .dimensions_probed => dims_seen = true,
            .exif_orientation_parsed,
            .decode_failed,
            .path_discovered,
            .directory_scan_result,
            .palette_dir_loaded,
            .palette_folder_count,
            .precache_completed,
            .ipc_command,
            => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(thumb_seen);
    try std.testing.expect(!image_seen);
    try std.testing.expect(!dims_seen);
}

test "decodeWorker - active_fast_scroll miss falls through to full decode" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    var current_gen: std.atomic.Value(usize) = .init(1);

    // 1. Small PNG without thumbnail falls through directly to full decode
    {
        const path = try allocator.dupe(
            u8,
            "testfiles/golden-screenshots/init.png",
        );
        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(1), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{ .filesystem = .{ .path = path } },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .active_fast_scroll,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        var image_seen = false;
        var thumb_seen = false;
        var dims_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .image_decoded => |img_evt| {
                    const img = img_evt.unwrapForTest();
                    image_seen = true;
                    try std.testing.expect(img.surface != null);
                    try std.testing.expect(img.w > 0.0 and img.h > 0.0);
                },
                .thumb_decoded => thumb_seen = true,
                .dimensions_probed => dims_seen = true,
                .exif_orientation_parsed,
                .decode_failed,
                .path_discovered,
                .directory_scan_result,
                .palette_dir_loaded,
                .palette_folder_count,
                .precache_completed,
                .ipc_command,
                => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expect(image_seen);
        try std.testing.expect(!thumb_seen);
        try std.testing.expect(!dims_seen);
    }

    // 2. Staged file > 256 KB without thumbnail reads Stage 2 in same pass
    {
        const jpg_path = "testfiles/images/000_0_1024x682.jpg";
        var src = try std.Io.Dir.openFile(
            std.Io.Dir.cwd(),
            io,
            jpg_path,
            .{},
        );
        defer src.close(io);
        const st = try std.Io.Dir.statFile(
            std.Io.Dir.cwd(),
            io,
            jpg_path,
            .{},
        );
        const jpg_bytes = try allocator.alloc(u8, @intCast(st.size));
        defer allocator.free(jpg_bytes);
        var j_slices = [_][]u8{jpg_bytes};
        _ = try src.readPositional(io, &j_slices, 0);

        const total_len = header_probe_limit + 32 * 1024;
        const padded = try allocator.alloc(u8, total_len);
        defer allocator.free(padded);
        @memset(padded, 0);
        @memcpy(padded[0..jpg_bytes.len], jpg_bytes);

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var mock_file = try tmp.dir.createFile(io, "staged_miss.jpg", .{});
        var wr_slices = [_][]const u8{padded};
        _ = try mock_file.writePositional(io, &wr_slices, 0);
        mock_file.close(io);

        var path_buf: [128]u8 = undefined;
        const mock_path = try std.mem.print(
            &path_buf,
            ".zig-cache/tmp/{s}/staged_miss.jpg",
            .{tmp.sub_path},
        );

        const args = try allocator.create(DecodeArgs);
        args.* = .{
            .workers = &workers,
            .allocator = allocator,
            .io = io,
            .key = .{ .id = MediaId.fromU32(2), .generation = 1 },
            .current_generation = &current_gen,
            .entry = .{
                .filesystem = .{ .path = try allocator.dupe(u8, mock_path) },
            },
            .has_gpu_device = true,
            .pixel_format = sdl.PixelFormat.rgba32,
            .mode = .active_fast_scroll,
            .pair_target = .adaptive,
        };
        _ = workers.active_decode_threads.fetchAdd(1, .monotonic);
        _ = workers.active_threads.fetchAdd(1, .monotonic);
        decodeWorker(args);

        var image_seen = false;
        var thumb_seen = false;
        var dims_seen = false;
        while (workers.event_queue.pop()) |*ev| {
            defer ev.deinit(allocator);
            switch (ev.*) {
                .image_decoded => |img_evt| {
                    const img = img_evt.unwrapForTest();
                    image_seen = true;
                    try std.testing.expectEqual(@as(f32, 1024.0), img.w);
                    try std.testing.expectEqual(@as(f32, 682.0), img.h);
                    try std.testing.expectEqual(
                        @as(u64, total_len),
                        img.size_bytes,
                    );
                },
                .thumb_decoded => thumb_seen = true,
                .dimensions_probed => dims_seen = true,
                .exif_orientation_parsed,
                .decode_failed,
                .path_discovered,
                .directory_scan_result,
                .palette_dir_loaded,
                .palette_folder_count,
                .precache_completed,
                .ipc_command,
                => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expect(image_seen);
        try std.testing.expect(!thumb_seen);
        try std.testing.expect(!dims_seen);
    }
}
