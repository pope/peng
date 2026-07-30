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
/// task invalidation generations, and worker draining for hot reloading.
pub const WorkerManager = struct {
    /// Invalidate all running worker jobs and block until active threads exit.
    pub fn drainAndQuiesce(state: *ViewerState) void {
        state.worker_group.cancel(state.io);
        _ = state.processBackgroundEvents();
    }
};

pub fn spawnDecode(args: *DecodeArgs) !void {
    _ = args.state.active_decode_threads.fetchAdd(1, .monotonic);
    _ = args.state.active_threads.fetchAdd(1, .monotonic);
    args.state.worker_group.async(args.state.io, decode.decodeWorker, .{args});
}

pub fn spawnPathScan(args: *PathScanArgs) !void {
    _ = args.state.active_threads.fetchAdd(1, .monotonic);
    args.state.navigation.is_loading_files.store(true, .release);
    args.state.worker_group.async(args.state.io, path_scan.pathScanWorker, .{args});
}

pub fn spawnStdin(args: *StdinArgs) !void {
    _ = args.state.active_threads.fetchAdd(1, .monotonic);
    args.state.navigation.is_loading_files.store(true, .release);
    args.state.worker_group.async(args.state.io, stdin.stdinWorker, .{args});
}

pub fn spawnIpcServer(state: *ViewerState) !void {
    _ = state.active_threads.fetchAdd(1, .monotonic);
    state.worker_group.async(state.io, ipc_server.ipcServerWorkerTask, .{state});
}
