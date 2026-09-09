//! Workers Subsystem Module
//!
//! Encapsulates all off-main-thread background tasks (image decoding, directory scanning,
//! stdin reading, and IPC server socket listening) and provides clean worker lifecycle management.

pub const context = @import("context.zig");
pub const decode = @import("decode.zig");
const events = @import("../core/events.zig");
pub const ipc_server = @import("ipc_server.zig");
pub const manager = @import("manager.zig");
pub const palette_scan = @import("palette_scan.zig");
pub const path_scan = @import("path_scan.zig");
const sdl = @import("sdl");
const std = @import("std");
pub const stdin = @import("stdin.zig");

pub const DecodeArgs = decode.DecodeArgs;
pub const PaletteScanArgs = palette_scan.PaletteScanArgs;
pub const PathScanArgs = path_scan.PathScanArgs;
pub const StdinArgs = stdin.StdinArgs;
pub const WorkerManager = manager.WorkerManager;

pub const spawnDecode = decode.spawnDecode;
pub const spawnPaletteScan = palette_scan.spawnPaletteScan;
pub const spawnPaletteScanForItems = palette_scan.spawnPaletteScanForItems;

/// Spawns a background `pathScanWorker` task to recursively scan directories
/// or validate file paths, setting the navigation file loading state.
pub fn spawnPathScan(args: *PathScanArgs) !void {
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    args.is_loading_files.store(true, .release);
    args.workers.group.async(args.io, path_scan.pathScanWorker, .{args});
}

/// Spawns a background `stdinWorker` task to stream image file paths from standard input.
pub fn spawnStdin(args: *StdinArgs) !void {
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    if (args.is_loading_files) |flag| flag.store(true, .release);
    args.workers.group.async(args.io, stdin.stdinWorker, .{args});
}

/// Spawns a background `ipcServerWorkerTask` listener to accept incoming IPC socket connections.
pub fn spawnIpcServer(workers: *WorkerManager, allocator: std.mem.Allocator, io: std.Io) !void {
    const args = try allocator.create(ipc_server.IpcServerArgs);
    args.* = .{
        .workers = workers,
        .allocator = allocator,
        .io = io,
    };
    _ = workers.active_threads.fetchAdd(1, .monotonic);
    if (std.Thread.spawn(.{}, ipc_server.ipcServerWorkerTask, .{args})) |t| {
        t.detach();
    } else |err| {
        _ = workers.active_threads.fetchSub(1, .release);
        allocator.destroy(args);
        return err;
    }
}

/// Alias for `spawnStdin`.
pub const spawnStdinReader = spawnStdin;

/// Inspects whether standard input is piped (non-TTY) and spawns an asynchronous stdin reader task.
pub fn readPipedStdin(
    workers: *WorkerManager,
    is_loading_files: *std.atomic.Value(bool),
    io: std.Io,
    gpa: std.mem.Allocator,
) !void {
    const is_stdin_piped = !(std.Io.File.stdin().isTty(io) catch false);
    if (is_stdin_piped) {
        const args = try gpa.create(StdinArgs);
        errdefer gpa.destroy(args);

        args.* = .{
            .workers = workers,
            .allocator = gpa,
            .io = io,
            .is_loading_files = is_loading_files,
        };

        errdefer is_loading_files.store(false, .release);

        try spawnStdin(args);
    }
}

/// Clones `path`, allocates scan parameters, and dispatches an asynchronous
/// background directory or path scan task.
pub fn startAsyncPathScan(
    workers: *WorkerManager,
    is_loading_files: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    is_dir: bool,
) !void {
    const dup_path = try allocator.dupe(u8, path);
    errdefer allocator.free(dup_path);

    const args = try allocator.create(PathScanArgs);
    errdefer allocator.destroy(args);

    args.* = .{
        .workers = workers,
        .allocator = allocator,
        .io = io,
        .target_path = dup_path,
        .is_dir = is_dir,
        .is_loading_files = is_loading_files,
    };

    errdefer is_loading_files.store(false, .release);

    try spawnPathScan(args);
}

test {
    _ = context;
    _ = decode;
    _ = path_scan;
    _ = stdin;
    _ = ipc_server;
    _ = palette_scan;
    _ = manager;
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
