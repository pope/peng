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
        _ = state.generation.fetchAdd(1, .monotonic);
        while (state.active_threads.load(.acquire) > 0) {
            sdl.timer.delay(1);
            _ = state.processBackgroundEvents();
        }
    }
};

pub fn spawnDecode(args: *DecodeArgs) !void {
    _ = args.state.active_decode_threads.fetchAdd(1, .monotonic);
    _ = args.state.active_threads.fetchAdd(1, .monotonic);
    if (std.Thread.spawn(.{}, decode.decodeWorker, .{args})) |t| {
        t.detach();
    } else |err| {
        _ = args.state.active_decode_threads.fetchSub(1, .release);
        _ = args.state.active_threads.fetchSub(1, .release);
        return err;
    }
}

pub fn spawnPathScan(args: *PathScanArgs) !void {
    _ = args.state.active_threads.fetchAdd(1, .monotonic);
    args.state.navigation.is_loading_files.store(true, .release);
    if (std.Thread.spawn(.{}, path_scan.pathScanWorker, .{args})) |t| {
        t.detach();
    } else |err| {
        _ = args.state.active_threads.fetchSub(1, .monotonic);
        args.state.navigation.is_loading_files.store(false, .release);
        return err;
    }
}

pub fn spawnStdin(args: *StdinArgs) !void {
    _ = args.state.active_threads.fetchAdd(1, .monotonic);
    args.state.navigation.is_loading_files.store(true, .release);
    if (std.Thread.spawn(.{}, stdin.stdinWorker, .{args})) |t| {
        t.detach();
    } else |err| {
        _ = args.state.active_threads.fetchSub(1, .monotonic);
        args.state.navigation.is_loading_files.store(false, .release);
        return err;
    }
}

pub fn spawnIpcServer(state: *ViewerState) !void {
    _ = state.active_threads.fetchAdd(1, .monotonic);
    if (std.Thread.spawn(.{}, ipc_server.ipcServerWorkerTask, .{state})) |t| {
        t.detach();
    } else |err| {
        _ = state.active_threads.fetchSub(1, .release);
        return err;
    }
}
