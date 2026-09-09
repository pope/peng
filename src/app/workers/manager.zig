//! Worker Thread Pool Manager
//!
//! Manages background thread lifecycle, active thread counts,
//! concurrency limits, worker cancellation, and event transport.

const std = @import("std");
const events = @import("../core/events.zig");

/// WorkerManager manages background thread lifecycle, active thread counts,
/// concurrency limits, worker cancellation, and event transport.
pub const WorkerManager = struct {
    /// Cached hardware logical CPU core count queried once at startup to eliminate
    /// per-frame `sysconf` or `/proc/cpuinfo` read syscalls.
    cached_cpu_count: usize = 0,

    /// Atomic counter tracking total actively executing background worker tasks
    /// (image decodes, directory path scans, stdin reading, and IPC server socket listener).
    active_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Atomic counter tracking actively executing image `decodeWorker` tasks.
    active_decode_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Worker task cancellation signal used by C library boundaries and worker
    /// loops during shutdown.
    exiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Real-time metrics for EXIF thumbnail extraction passes.
    thumb_header_hits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    thumb_positional_hits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    thumb_misses: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Thread-safe multi-producer single-consumer queue for
    /// background-to-main-thread event transport.
    event_queue: events.MpscQueue(events.BackgroundEvent) = .{},

    /// Encapsulated task group managing all spawned background worker threads
    /// under Zig 0.16 `std.Io`.
    group: std.Io.Group = .init,

    /// Returns `true` if any background worker tasks (decode, path scan, stdin, or IPC server)
    /// are currently executing in parallel.
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

    /// Signals worker shutdown and waits for running tasks to finish.
    pub fn deinit(self: *WorkerManager, io: std.Io) void {
        self.drainAndQuiesce(io);
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

    mgr.cached_cpu_count = 8;
    try std.testing.expectEqual(@as(usize, 7), mgr.getMaxConcurrentDecodes());

    mgr.cached_cpu_count = 16;
    try std.testing.expectEqual(@as(usize, 8), mgr.getMaxConcurrentDecodes());
}
