//! Workers Subsystem Module
//!
//! Encapsulates all off-main-thread background tasks (image decoding,
//! directory scanning, stdin reading, and IPC server socket listening) and
//! provides clean worker lifecycle management.

const builtin = @import("builtin");
pub const context = @import("context.zig");
pub const decode = @import("decode.zig");
pub const events = @import("events.zig");
pub const ipc_server = @import("ipc_server.zig");
pub const manager = @import("manager.zig");
pub const palette_scan = @import("palette_scan.zig");
pub const path_scan = @import("path_scan.zig");
pub const preview = @import("preview.zig");
const sdl = @import("sdl");
const std = @import("std");
pub const stdin = @import("stdin.zig");

pub const BackgroundEvent = events.BackgroundEvent;
pub const DecodeArgs = decode.DecodeArgs;
pub const PaletteScanArgs = palette_scan.PaletteScanArgs;
pub const PathScanArgs = path_scan.PathScanArgs;
pub const PreviewWorkerArgs = preview.PreviewWorkerArgs;
pub const StdinArgs = stdin.StdinArgs;
pub const WorkerManager = manager.WorkerManager;

pub const spawnDecode = decode.spawnDecode;
pub const spawnPaletteScan = palette_scan.spawnPaletteScan;
pub const spawnPaletteScanForItems = palette_scan.spawnPaletteScanForItems;
pub const spawnPreview = preview.spawnPreview;

/// Spawns a background `pathScanWorker` task to recursively scan directories
/// or validate file paths, incrementing the active file scan counter.
pub fn spawnPathScan(args: *PathScanArgs) !void {
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    _ = args.active_file_scans.fetchAdd(1, .monotonic);
    args.workers.group.async(args.io, path_scan.pathScanWorker, .{args});
}

/// Spawns a background `stdinWorker` task to stream image file paths from
/// standard input.
pub fn spawnStdin(args: *StdinArgs) !void {
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    if (args.active_file_scans) |scans| {
        _ = scans.fetchAdd(1, .monotonic);
    }
    args.workers.group.async(args.io, stdin.stdinWorker, .{args});
}

/// Spawns a background `ipcServerWorkerTask` listener to accept incoming IPC
/// socket connections and returns its joinable `std.Thread` handle.
pub fn spawnIpcServer(
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
) !std.Thread {
    const args = try allocator.create(ipc_server.IpcServerArgs);
    errdefer allocator.destroy(args);
    args.* = .{
        .workers = workers,
        .allocator = allocator,
        .io = io,
        .socket_path = socket_path,
    };
    return std.Thread.spawn(
        .{},
        ipc_server.ipcServerWorkerTask,
        .{args},
    );
}

/// Inspects whether standard input is piped (non-TTY) and spawns an asynchronous stdin reader task.
pub fn readPipedStdin(
    workers: *WorkerManager,
    active_file_scans: *std.atomic.Value(usize),
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
            .active_file_scans = active_file_scans,
        };

        try spawnStdin(args);
    }
}

/// Clones `path`, allocates scan parameters, and dispatches an asynchronous
/// background directory or path scan task.
pub fn startAsyncPathScan(
    workers: *WorkerManager,
    active_file_scans: *std.atomic.Value(usize),
    current_generation: *const std.atomic.Value(usize),
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    is_dir: bool,
    stack_raw_jpeg: bool,
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
        .active_file_scans = active_file_scans,
        .stack_raw_jpeg = stack_raw_jpeg,
        .generation = current_generation.load(.acquire),
        .current_generation = current_generation,
    };

    try spawnPathScan(args);
}

test "spawnIpcServer does not mark WorkerManager as busy" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [128]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/worker_ipc.sock",
        .{tmp.sub_path},
    );

    var workers = WorkerManager.init();
    defer workers.deinit(allocator, io);
    workers.exiting.store(true, .release);

    const thread = try spawnIpcServer(&workers, allocator, io, sock_path);
    defer thread.join();

    try std.testing.expect(!workers.isBusy());
    try std.testing.expectEqual(
        @as(usize, 0),
        workers.active_threads.load(.acquire),
    );
}

test {
    _ = context;
    _ = decode;
    _ = events;
    _ = ipc_server;
    _ = manager;
    _ = palette_scan;
    _ = path_scan;
    _ = preview;
    _ = stdin;
}
