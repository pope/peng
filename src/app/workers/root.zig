//! Workers Subsystem Module
//!
//! Encapsulates all off-main-thread background tasks (image decoding, directory scanning,
//! stdin reading, and IPC server socket listening) and provides clean worker lifecycle management.

const app_state = @import("../state.zig");
pub const context = @import("context.zig");
pub const decode = @import("decode.zig");
const events = @import("../core/events.zig");
pub const ipc_server = @import("ipc_server.zig");
pub const palette_scan = @import("palette_scan.zig");
pub const path_scan = @import("path_scan.zig");
const sdl = @import("sdl");
const std = @import("std");
pub const stdin = @import("stdin.zig");

pub const DecodeArgs = decode.DecodeArgs;
pub const PaletteScanArgs = palette_scan.PaletteScanArgs;
pub const PathScanArgs = path_scan.PathScanArgs;
pub const StdinArgs = stdin.StdinArgs;
const ViewerState = app_state.ViewerState;
pub const WorkerContext = context.WorkerContext;

/// WorkerManager manages background thread lifecycle, active thread counts,
/// concurrency limits, worker cancellation, and event transport.
pub const WorkerManager = struct {
    /// Cached hardware logical CPU core count queried once at startup to eliminate
    /// per-frame `sysconf` or `/proc/cpuinfo` read syscalls.
    cached_cpu_count: usize = 0,

    /// Atomic counter tracking total actively executing background worker tasks
    /// (image decodes, directory path scans, stdin reading, and IPC server socket listener).
    /// Needed by the main engine loop (`state.isBusy()`) to differentiate between active
    /// background processing (requiring continuous frame polling for events) and true idle state
    /// (allowing the engine loop to sleep until next user input event).
    active_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Atomic counter tracking actively executing image `decodeWorker` tasks.
    /// Used by `canSpawnDecode()` to throttle parallel image decompression against system CPU core count.
    active_decode_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Worker task cancellation signal used by C library boundaries and worker loops during shutdown.
    exiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Real-time metrics for EXIF thumbnail extraction passes.
    thumb_header_hits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    thumb_positional_hits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    thumb_misses: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Thread-safe multi-producer single-consumer queue for background-to-main-thread event transport.
    event_queue: events.MpscQueue(events.BackgroundEvent) = .{},

    /// Encapsulated task group managing all spawned background worker threads under Zig 0.16 `std.Io`.
    group: std.Io.Group = .init,

    /// Returns `true` if any background worker tasks (decode, path scan, stdin, or IPC server)
    /// are currently executing in parallel. Used by the main engine loop to determine whether
    /// the app is active or can drop into low-power idle mode.
    pub fn isBusy(self: *const WorkerManager) bool {
        return self.active_threads.load(.acquire) > 0;
    }

    /// Returns the cached hardware CPU count, or queries system CPU count as fallback.
    pub fn getCpuCount(self: *const WorkerManager) usize {
        if (self.cached_cpu_count > 0) return self.cached_cpu_count;
        return std.Thread.getCpuCount() catch 4;
    }

    /// Calculates the maximum allowed concurrent `decodeWorker` tasks based on system CPU cores.
    /// Dynamically scales concurrency to `@max(1, @min(8, cpu_count -| 1))`, reserving 1 dedicated
    /// logical core for the 60/120 FPS main render loop while saturating background cores (up to 8).
    pub fn getMaxConcurrentDecodes(self: *const WorkerManager) usize {
        const cpus = self.getCpuCount();
        return @max(1, @min(8, cpus -| 1));
    }

    /// Returns `true` if the number of actively running `decodeWorker` tasks is strictly less
    /// than `getMaxConcurrentDecodes()`. Used by cache updating and prefetching to throttle
    /// image decoding and prevent CPU/IO thrashing.
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
    /// threads have exited cleanly. Called on application shutdown (`ViewerState.deinit`).
    pub fn drainAndQuiesce(self: *WorkerManager, io: std.Io) void {
        self.exiting.store(true, .release);
        self.group.cancel(io);
    }
};

/// Spawns a background `decodeWorker` task for image file decoding and EXIF thumbnail extraction,
/// tracking active decode thread and active worker thread counts.
pub fn spawnDecode(args: *DecodeArgs) !void {
    _ = args.workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    args.workers.group.async(args.io, decode.decodeWorker, .{args});
}

/// Spawns a background `paletteScanWorker` task to count directory images and subfolders.
pub fn spawnPaletteScan(args: *PaletteScanArgs) !void {
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    args.workers.group.async(args.io, palette_scan.paletteScanWorker, .{args});
}

/// Extracts unscanned directory items and dispatches an asynchronous background palette scan task.
pub const spawnPaletteScanForItems = palette_scan.spawnPaletteScanForItems;

/// Spawns a background `pathScanWorker` task to recursively scan directories or validate file paths,
/// setting the navigation file loading state.
pub fn spawnPathScan(args: *PathScanArgs) !void {
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    if (args.is_loading_files) |flag| flag.store(true, .release);
    args.workers.group.async(args.io, path_scan.pathScanWorker, .{args});
}

/// Spawns a background `stdinWorker` task to stream image file paths from standard input.
pub fn spawnStdin(args: *StdinArgs) !void {
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    if (args.is_loading_files) |flag| flag.store(true, .release);
    args.workers.group.async(args.io, stdin.stdinWorker, .{args});
}

/// Spawns a background `ipcServerWorkerTask` listener to accept incoming IPC socket connections.
pub fn spawnIpcServer(state: *app_state.AppState) !void {
    const args = try state.allocator.create(ipc_server.IpcServerArgs);
    args.* = .{
        .workers = &state.workers,
        .allocator = state.allocator,
        .io = state.io,
    };
    _ = state.workers.active_threads.fetchAdd(1, .monotonic);
    state.workers.group.async(state.io, ipc_server.ipcServerWorkerTask, .{args});
}

/// Alias for `spawnStdin`.
pub const spawnStdinReader = spawnStdin;

/// Inspects whether standard input is piped (non-TTY) and spawns an asynchronous stdin reader task.
pub fn readPipedStdin(state: *app_state.AppState, io: std.Io, gpa: std.mem.Allocator) !void {
    const is_stdin_piped = !(std.Io.File.stdin().isTty(io) catch false);
    if (is_stdin_piped) {
        const args = try gpa.create(StdinArgs);
        errdefer gpa.destroy(args);

        args.* = .{
            .workers = &state.workers,
            .allocator = gpa,
            .io = io,
            .is_loading_files = &state.viewer.navigation.is_loading_files,
        };

        errdefer state.viewer.navigation.is_loading_files.store(false, .release);

        try spawnStdin(args);
    }
}

/// Clones `path`, allocates scan parameters, and dispatches an asynchronous background directory or path scan task.
pub fn startAsyncPathScan(state: *app_state.AppState, path: []const u8, is_dir: bool) !void {
    const dup_path = try state.allocator.dupe(u8, path);
    errdefer state.allocator.free(dup_path);

    const args = try state.allocator.create(PathScanArgs);
    errdefer state.allocator.destroy(args);

    args.* = .{
        .workers = &state.workers,
        .allocator = state.allocator,
        .io = state.io,
        .target_path = dup_path,
        .is_dir = is_dir,
        .is_loading_files = &state.viewer.navigation.is_loading_files,
    };

    errdefer state.viewer.navigation.is_loading_files.store(false, .release);

    try spawnPathScan(args);
}

test {
    _ = context;
    _ = decode;
    _ = path_scan;
    _ = stdin;
    _ = ipc_server;
    _ = palette_scan;
}

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
    try std.testing.expectEqual(mgr_cached.cached_cpu_count, mgr_cached.getCpuCount());
}

test {
    _ = decode;
    _ = ipc_server;
    _ = palette_scan;
    _ = path_scan;
    _ = stdin;
}
