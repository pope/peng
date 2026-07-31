//! Workers Subsystem Module
//!
//! Encapsulates all off-main-thread background tasks (image decoding, directory scanning,
//! stdin reading, and IPC server socket listening) and provides clean worker lifecycle management.

const std = @import("std");
const app_state = @import("../state.zig");
const ViewerState = app_state.ViewerState;
const sdl = @import("sdl");

pub const context = @import("context.zig");
pub const decode = @import("decode.zig");
pub const path_scan = @import("path_scan.zig");
pub const stdin = @import("stdin.zig");
pub const ipc_server = @import("ipc_server.zig");

pub const WorkerContext = context.WorkerContext;
pub const DecodeArgs = decode.DecodeArgs;
pub const PathScanArgs = path_scan.PathScanArgs;
pub const StdinArgs = stdin.StdinArgs;

/// WorkerManager manages background thread lifecycle, active thread counts,
/// concurrency limits, and worker draining for shutdown/quiescing.
pub const WorkerManager = struct {
    /// Atomic counter tracking total actively executing background worker tasks
    /// (image decodes, directory path scans, stdin reading, and IPC server socket listener).
    /// Needed by the main engine loop (`state.isBusy()`) to differentiate between active
    /// background processing (requiring continuous frame polling for events) and true idle state
    /// (allowing the engine loop to sleep until next user input event).
    active_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Atomic counter tracking actively executing image `decodeWorker` tasks.
    /// Used by `canSpawnDecode()` to throttle parallel image decompression against system CPU core count.
    active_decode_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Encapsulated task group managing all spawned background worker threads under Zig 0.16 `std.Io`.
    group: std.Io.Group = .init,

    /// Returns `true` if any background worker tasks (decode, path scan, stdin, or IPC server)
    /// are currently executing in parallel. Used by the main engine loop to determine whether
    /// the app is active or can drop into low-power idle mode.
    pub fn isBusy(self: *const WorkerManager) bool {
        return self.active_threads.load(.acquire) > 0;
    }

    /// Returns `true` if the number of actively running `decodeWorker` tasks is strictly less
    /// than `getMaxConcurrentDecodes()`. Used by cache updating and prefetching to throttle
    /// image decoding and prevent CPU/IO thrashing.
    pub fn canSpawnDecode(self: *const WorkerManager) bool {
        return self.active_decode_threads.load(.acquire) < getMaxConcurrentDecodes();
    }

    /// Calculates the maximum allowed concurrent `decodeWorker` tasks based on system CPU cores.
    /// Dynamically tunes parallel worker capacity to half of available hardware logical cores
    /// (e.g. max 6 parallel decodes on 12 cores, minimum 1).
    pub fn getMaxConcurrentDecodes() usize {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        return @max(1, cpu_count / 2);
    }

    /// Cancels all background tasks in the worker group and blocks until all running worker
    /// threads have exited cleanly. Called on application shutdown (`ViewerState.deinit`).
    pub fn drainAndQuiesce(self: *WorkerManager, io: std.Io) void {
        self.group.cancel(io);
    }
};

/// Spawns a background `decodeWorker` task for image file decoding and EXIF thumbnail extraction,
/// tracking active decode thread and active worker thread counts.
pub fn spawnDecode(args: *DecodeArgs) !void {
    _ = args.state.workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = args.state.workers.active_threads.fetchAdd(1, .monotonic);
    args.state.workers.group.async(args.state.io, decode.decodeWorker, .{args});
}

/// Spawns a background `pathScanWorker` task to recursively scan directories or validate file paths,
/// setting the navigation file loading state.
pub fn spawnPathScan(args: *PathScanArgs) !void {
    _ = args.state.workers.active_threads.fetchAdd(1, .monotonic);
    args.state.navigation.is_loading_files.store(true, .release);
    args.state.workers.group.async(args.state.io, path_scan.pathScanWorker, .{args});
}

/// Spawns a background `stdinWorker` task to stream image file paths from standard input.
pub fn spawnStdin(args: *StdinArgs) !void {
    _ = args.state.workers.active_threads.fetchAdd(1, .monotonic);
    args.state.navigation.is_loading_files.store(true, .release);
    args.state.workers.group.async(args.state.io, stdin.stdinWorker, .{args});
}

/// Spawns a background `ipcServerWorkerTask` listener to accept incoming IPC socket connections.
pub fn spawnIpcServer(state: *ViewerState) !void {
    _ = state.workers.active_threads.fetchAdd(1, .monotonic);
    state.workers.group.async(state.io, ipc_server.ipcServerWorkerTask, .{state});
}
