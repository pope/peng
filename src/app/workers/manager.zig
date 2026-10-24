//! Worker Thread Pool Manager
//!
//! Manages background thread lifecycle, active thread counts,
//! concurrency limits, worker cancellation, and event transport.

const context = @import("context.zig");
const events = @import("../core/events.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const thumb_cache = @import("../core/thumb_cache.zig");

/// Background job for downscaling, orienting, and atomically saving a PNG
/// thumbnail to the Freedesktop Shared Thumbnail Cache
/// (`$XDG_CACHE_HOME/thumbnails/`).
pub const ThumbWriteJob = struct {
    surface: sdl.Surface,
    source_path: []u8,
    mime_type: []const u8,
    file_size: u64,
    mtime_sec: i64,
    orientation: state_pkg.Orientation,
    source_dims: ?state_pkg.PhysicalDims = null,

    /// Releases the owned SDL surface and source path string.
    pub fn deinit(self: *ThumbWriteJob, allocator: std.mem.Allocator) void {
        self.surface.destroy();
        allocator.free(self.source_path);
    }
};

/// WorkerManager manages background thread lifecycle, active thread counts,
/// concurrency limits, worker cancellation, and event transport.
pub const WorkerManager = struct {
    pub const MAX_QUEUED_THUMB_WRITES: usize = 8;

    /// Cached hardware logical CPU core count queried once at startup to eliminate
    /// per-frame `sysconf` or `/proc/cpuinfo` read syscalls.
    cached_cpu_count: usize = 0,

    /// Atomic counter tracking total actively executing foreground/UI worker
    /// tasks (image decodes, directory path scans, and stdin reading).
    active_threads: std.atomic.Value(usize) = .init(0),

    /// Atomic counter tracking actively executing image `decodeWorker` tasks.
    active_decode_threads: std.atomic.Value(usize) = .init(0),

    /// Atomic counter tracking actively executing background thumbnail writer
    /// tasks.
    active_thumb_writers: std.atomic.Value(usize) = .init(0),

    /// Worker task cancellation signal used by C library boundaries and worker
    /// loops during shutdown.
    exiting: std.atomic.Value(bool) = .init(false),

    /// Platform/user configuration for the Freedesktop Shared Thumbnail Cache.
    thumb_cache_config: thumb_cache.ThumbCacheConfig = .disabled,

    /// Real-time atomic metrics for EXIF & Freedesktop thumbnail extraction and
    /// writes.
    thumb_header_hits: std.atomic.Value(usize) = .init(0),
    thumb_positional_hits: std.atomic.Value(usize) = .init(0),
    thumb_cache_hits: std.atomic.Value(usize) = .init(0),
    thumb_misses: std.atomic.Value(usize) = .init(0),
    thumb_cache_writes: std.atomic.Value(usize) = .init(0),
    thumb_cache_write_queued: std.atomic.Value(usize) = .init(0),

    /// Bounded background queue for saving Freedesktop thumbnails when decode
    /// workers are idle.
    thumb_write_mutex: std.Io.Mutex = .init,
    thumb_write_queue: std.ArrayList(ThumbWriteJob) = .empty,
    thumb_writer_running: bool = false,
    precache_generation: std.atomic.Value(usize) = .init(0),

    /// Thread-safe multi-producer single-consumer queue for
    /// background-to-main-thread event transport.
    event_queue: events.MpscQueue(events.BackgroundEvent) = .{},

    /// Encapsulated task group managing all spawned background worker threads
    /// under Zig 0.17 `std.Io`.
    group: std.Io.Group = .init,

    /// Takes a consistent atomic snapshot of all thumbnail telemetry counters.
    pub fn snapshotThumbStats(
        self: *const WorkerManager,
    ) state_pkg.ThumbnailStats {
        return .{
            .header_hits = self.thumb_header_hits.load(.acquire),
            .positional_hits = self.thumb_positional_hits.load(.acquire),
            .cache_hits = self.thumb_cache_hits.load(.acquire),
            .misses = self.thumb_misses.load(.acquire),
            .cache_writes = self.thumb_cache_writes.load(.acquire),
            .cache_write_queued = self.thumb_cache_write_queued.load(.acquire),
        };
    }

    /// Enqueues a decoded surface for asynchronous Freedesktop thumbnail
    /// generation. Bounded to `MAX_QUEUED_THUMB_WRITES` (evicting the oldest
    /// pending item if full) and executes only when
    /// `active_decode_threads == 0`.
    pub fn enqueueThumbWrite(
        self: *WorkerManager,
        allocator: std.mem.Allocator,
        io: std.Io,
        job: ThumbWriteJob,
    ) void {
        if (self.exiting.load(.acquire) or
            self.thumb_cache_config == .disabled)
        {
            var j = job;
            j.deinit(allocator);
            return;
        }

        const should_spawn = blk: {
            self.thumb_write_mutex.lockUncancelable(io);
            defer self.thumb_write_mutex.unlock(io);

            for (self.thumb_write_queue.items) |existing| {
                if (std.mem.eql(u8, existing.source_path, job.source_path)) {
                    var j = job;
                    j.deinit(allocator);
                    return;
                }
            }

            if (self.thumb_write_queue.items.len >= MAX_QUEUED_THUMB_WRITES) {
                var dropped = self.thumb_write_queue.orderedRemove(0);
                dropped.deinit(allocator);
                _ = self.thumb_cache_write_queued.fetchSub(1, .monotonic);
            }

            self.thumb_write_queue.append(allocator, job) catch {
                var j = job;
                j.deinit(allocator);
                return;
            };
            _ = self.thumb_cache_write_queued.fetchAdd(1, .release);

            if (!self.thumb_writer_running) {
                self.thumb_writer_running = true;
                break :blk true;
            }
            break :blk false;
        };

        if (should_spawn) {
            _ = self.active_thumb_writers.fetchAdd(1, .monotonic);
            self.group.async(io, thumbWriterWorker, .{ self, allocator, io });
        }
    }

    fn clearThumbWriteQueueLocked(
        self: *WorkerManager,
        allocator: std.mem.Allocator,
        free_capacity: bool,
    ) void {
        const rem = self.thumb_write_queue.items.len;
        for (self.thumb_write_queue.items) |*item| {
            item.deinit(allocator);
        }
        if (free_capacity) {
            self.thumb_write_queue.clearAndFree(allocator);
        } else {
            self.thumb_write_queue.clearRetainingCapacity();
        }
        if (rem > 0) {
            _ = self.thumb_cache_write_queued.fetchSub(rem, .release);
        }
    }

    /// Clears all pending thumbnail write jobs and frees their owned surfaces.
    pub fn clearThumbWriteQueue(
        self: *WorkerManager,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) void {
        self.thumb_write_mutex.lockUncancelable(io);
        defer self.thumb_write_mutex.unlock(io);

        self.clearThumbWriteQueueLocked(allocator, true);
    }

    fn thumbWriterWorker(
        self: *WorkerManager,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) void {
        defer {
            sdl.reclaimProcessHeap();
            _ = self.active_thumb_writers.fetchSub(1, .release);
        }

        var scratch_arena: std.heap.ArenaAllocator = .init(allocator);
        defer scratch_arena.deinit();

        while (true) {
            defer _ = scratch_arena.reset(.{
                .retain_with_limit = 4 * 1024 * 1024,
            });
            const has_pending = blk: {
                self.thumb_write_mutex.lockUncancelable(io);
                defer self.thumb_write_mutex.unlock(io);

                if (self.exiting.load(.acquire) or
                    self.thumb_write_queue.items.len == 0)
                {
                    self.clearThumbWriteQueueLocked(allocator, false);
                    self.thumb_writer_running = false;
                    break :blk false;
                }
                break :blk true;
            };
            if (!has_pending) return;

            while (!self.exiting.load(.acquire) and
                self.active_decode_threads.load(.acquire) > 0)
            {
                std.Io.sleep(io, .fromMilliseconds(5), .awake) catch break;
            }

            const job_opt: ?ThumbWriteJob = blk: {
                self.thumb_write_mutex.lockUncancelable(io);
                defer self.thumb_write_mutex.unlock(io);

                if (self.exiting.load(.acquire) or
                    self.thumb_write_queue.items.len == 0)
                {
                    self.clearThumbWriteQueueLocked(allocator, false);
                    self.thumb_writer_running = false;
                    break :blk null;
                }
                break :blk self.thumb_write_queue.orderedRemove(0);
            };

            var job = job_opt orelse return;
            defer {
                job.deinit(allocator);
                _ = self.thumb_cache_write_queued.fetchSub(1, .release);
                context.wakeUpMainThread();
            }

            if (self.exiting.load(.acquire)) continue;

            switch (self.thumb_cache_config) {
                .disabled => {},
                .enabled => |cfg| {
                    const key = thumb_cache.ThumbCacheKey.fromFilePath(
                        io,
                        job.source_path,
                        cfg.cache_dir,
                    ) orelse continue;

                    if (thumb_cache.hasValidTargetTierThumbnail(
                        io,
                        cfg,
                        &key,
                        job.mtime_sec,
                    )) {
                        continue;
                    }

                    if (thumb_cache.writeThumbnailPng(
                        scratch_arena.allocator(),
                        io,
                        cfg,
                        &key,
                        job.surface,
                        job.orientation,
                        .{
                            .uri = key.uri(),
                            .mtime_sec = job.mtime_sec,
                            .file_size = job.file_size,
                            .mime_type = job.mime_type,
                            .source_dims = job.source_dims,
                        },
                    )) |_| {
                        _ = self.thumb_cache_writes.fetchAdd(1, .release);
                    } else |err| {
                        std.log.warn(
                            "thumbWriterWorker: failed to write cached " ++
                                "thumbnail for '{s}': {}",
                            .{ job.source_path, err },
                        );
                    }
                },
            }
        }
    }

    /// Arena-backed batch of file paths for background directory thumbnail
    /// pre-caching.
    pub const PrecacheDirectoryBatch = struct {
        arena: std.heap.ArenaAllocator,
        paths: []const []const u8,

        pub fn deinit(self: PrecacheDirectoryBatch) void {
            self.arena.deinit();
        }
    };

    /// Spawns a low-priority background job that pre-caches Freedesktop
    /// thumbnails for `batch.paths` whenever foreground decode workers are
    /// idle (`active_decode_threads == 0`). Takes ownership of `batch`.
    pub fn startDirectoryPrecache(
        self: *WorkerManager,
        allocator: std.mem.Allocator,
        io: std.Io,
        batch: PrecacheDirectoryBatch,
    ) bool {
        if (self.exiting.load(.acquire) or
            self.thumb_cache_config == .disabled or
            batch.paths.len == 0)
        {
            batch.deinit();
            return false;
        }

        const gen = self.precache_generation.fetchAdd(1, .acq_rel) +% 1;
        _ = self.thumb_cache_write_queued.fetchAdd(batch.paths.len, .release);
        _ = self.active_thumb_writers.fetchAdd(1, .monotonic);
        self.group.async(
            io,
            precacheDirectoryWorker,
            .{ self, allocator, io, batch, gen },
        );
        return true;
    }

    fn precacheDirectoryWorker(
        self: *WorkerManager,
        allocator: std.mem.Allocator,
        io: std.Io,
        batch: PrecacheDirectoryBatch,
        gen: usize,
    ) void {
        var remaining_queued: usize = batch.paths.len;
        defer {
            if (remaining_queued > 0) {
                _ = self.thumb_cache_write_queued.fetchSub(
                    remaining_queued,
                    .release,
                );
            }
            batch.deinit();
            sdl.reclaimProcessHeap();
            _ = self.active_thumb_writers.fetchSub(1, .release);
            context.wakeUpMainThread();
        }

        const base_cfg = switch (self.thumb_cache_config) {
            .disabled => return,
            .enabled => |c| c,
        };
        const cfg = thumb_cache.EnabledThumbCacheConfig{
            .cache_dir = base_cfg.cache_dir,
            .write_tier = base_cfg.write_tier,
            .write_policy = if (base_cfg.write_policy == .never)
                .all_missing
            else
                base_cfg.write_policy,
        };

        const cancel = context.CancellationToken{
            .exiting = &self.exiting,
            .generation = gen,
            .current_generation = &self.precache_generation,
        };
        const precache_cancel = thumb_cache.PrecacheCancel{
            .exiting = &self.exiting,
            .generation = gen,
            .current_generation = &self.precache_generation,
        };

        var scratch_arena: std.heap.ArenaAllocator = .init(allocator);
        defer scratch_arena.deinit();

        var res = events.PrecacheCompletedPayload{};

        for (batch.paths) |path| {
            defer _ = scratch_arena.reset(.{
                .retain_with_limit = 4 * 1024 * 1024,
            });
            if (cancel.isCanceled()) return;

            while (!cancel.isCanceled() and
                self.active_decode_threads.load(.acquire) > 0)
            {
                std.Io.sleep(io, .fromMilliseconds(5), .awake) catch break;
            }

            if (cancel.isCanceled()) return;

            const outcome = thumb_cache.precacheFileThumbnail(
                scratch_arena.allocator(),
                io,
                cfg,
                path,
                precache_cancel,
            );
            remaining_queued -= 1;
            _ = self.thumb_cache_write_queued.fetchSub(1, .release);

            switch (outcome) {
                .written => {
                    res.written += 1;
                    _ = self.thumb_cache_writes.fetchAdd(1, .release);
                    context.wakeUpMainThread();
                },
                .already_valid => {
                    res.already_valid += 1;
                },
                .skipped => {
                    res.skipped += 1;
                },
                .failed => {
                    res.failed += 1;
                },
                .canceled => return,
            }
        }

        if (!cancel.isCanceled()) {
            self.event_queue.push(allocator, io, .{
                .precache_completed = cancel.wrap(res),
            }) catch |err| {
                std.log.warn(
                    "Failed to push precache_completed event: {}",
                    .{err},
                );
            };
        }
    }

    /// Returns `true` if any background worker tasks (decode, path scan, or
    /// stdin) are currently executing in parallel.
    pub fn isBusy(self: *const WorkerManager) bool {
        return self.active_threads.load(.acquire) > 0;
    }

    /// Returns the cached hardware CPU count, or queries system CPU count as fallback.
    pub fn getCpuCount(self: *const WorkerManager) usize {
        if (self.cached_cpu_count > 0) return self.cached_cpu_count;
        return std.Thread.getCpuCount() catch 4;
    }

    /// Calculates the maximum allowed concurrent `decodeWorker` tasks based on system CPU cores.
    pub fn getMaxConcurrentDecodes(self: *const WorkerManager) usize {
        const cpus = self.getCpuCount();
        return @max(1, @min(8, cpus -| 1));
    }

    /// Returns `true` if the number of actively running `decodeWorker` tasks is strictly less
    /// than `getMaxConcurrentDecodes()`.
    pub fn canSpawnDecode(self: *const WorkerManager) bool {
        return self.active_decode_threads.load(.acquire) < self.getMaxConcurrentDecodes();
    }

    /// Initializes a new WorkerManager with zero active threads, default event queues,
    /// and pre-cached system CPU core count.
    pub fn init() WorkerManager {
        return .{
            .cached_cpu_count = std.Thread.getCpuCount() catch 4,
        };
    }

    /// Signals worker shutdown, waits for running tasks to finish, and frees
    /// the background event and thumbnail write queues.
    pub fn deinit(
        self: *WorkerManager,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) void {
        self.drainAndQuiesce(io);
        {
            self.thumb_write_mutex.lockUncancelable(io);
            defer self.thumb_write_mutex.unlock(io);
            self.clearThumbWriteQueueLocked(allocator, true);
            self.thumb_cache_write_queued.store(0, .release);
            self.thumb_writer_running = false;
        }
        self.thumb_cache_config.deinit(allocator);
        self.event_queue.deinit(allocator, io);
    }

    /// Cancels all background tasks in the worker group and blocks until all running worker
    /// threads have exited cleanly.
    pub fn drainAndQuiesce(self: *WorkerManager, io: std.Io) void {
        self.exiting.store(true, .release);
        self.group.cancel(io);
    }
};

test "WorkerManager.getMaxConcurrentDecodes scaling bounds" {
    var mgr = WorkerManager{ .cached_cpu_count = 1 };
    try std.testing.expectEqual(@as(usize, 1), mgr.getMaxConcurrentDecodes());

    mgr.cached_cpu_count = 2;
    try std.testing.expectEqual(@as(usize, 1), mgr.getMaxConcurrentDecodes());

    mgr.cached_cpu_count = 4;
    try std.testing.expectEqual(@as(usize, 3), mgr.getMaxConcurrentDecodes());

    mgr.cached_cpu_count = 6;
    try std.testing.expectEqual(@as(usize, 5), mgr.getMaxConcurrentDecodes());

    mgr.cached_cpu_count = 8;
    try std.testing.expectEqual(@as(usize, 7), mgr.getMaxConcurrentDecodes());

    mgr.cached_cpu_count = 16;
    try std.testing.expectEqual(@as(usize, 8), mgr.getMaxConcurrentDecodes());

    mgr.cached_cpu_count = 64;
    try std.testing.expectEqual(@as(usize, 8), mgr.getMaxConcurrentDecodes());
}

test "WorkerManager.canSpawnDecode gating" {
    var mgr = WorkerManager{ .cached_cpu_count = 4 };
    // Max is 3 (4 - 1):
    try std.testing.expect(mgr.canSpawnDecode());
    mgr.active_decode_threads.store(2, .release);
    try std.testing.expect(mgr.canSpawnDecode());
    mgr.active_decode_threads.store(3, .release);
    try std.testing.expect(!mgr.canSpawnDecode());
}

test "WorkerManager.getCpuCount caching and fallback" {
    const mgr_zero = WorkerManager{ .cached_cpu_count = 0 };
    try std.testing.expect(mgr_zero.getCpuCount() >= 1);

    const mgr_cached = WorkerManager.init();
    try std.testing.expect(mgr_cached.cached_cpu_count >= 1);
    try std.testing.expectEqual(
        mgr_cached.cached_cpu_count,
        mgr_cached.getCpuCount(),
    );
}
