const manager = @import("manager.zig");
const path_scan = @import("path_scan.zig");
const std = @import("std");
const vfs = @import("vfs");

const isImageFile = vfs.isImageFile;
const WorkerManager = manager.WorkerManager;

/// Arguments for spawning the background standard input reader thread.
pub const StdinArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    active_file_scans: ?*std.atomic.Value(usize) = null,
};

/// Background thread function reading newline-delimited image paths piped via standard input.
pub fn stdinWorker(args: *StdinArgs) void {
    const workers = args.workers;
    const io = args.io;
    const gpa = args.allocator;
    defer {
        if (args.active_file_scans) |scans| {
            _ = scans.fetchSub(1, .release);
        }
        gpa.destroy(args);
        _ = workers.active_threads.fetchSub(1, .release);
        workers.wakeMainThread();
    }

    var read_buf: [4096]u8 = undefined;
    var stdin_file_reader = std.Io.File.Reader.init(
        std.Io.File.stdin(),
        io,
        &read_buf,
    );
    const stdin = &stdin_file_reader.interface;

    while (!workers.exiting.load(.acquire)) {
        const line = (stdin.takeDelimiter('\n') catch break) orelse break;
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (trimmed.len > 0) {
            if (std.Io.Dir.statFile(std.Io.Dir.cwd(), io, trimmed, .{})) |s| {
                if (s.kind == .directory) {
                    path_scan.scanDirectoryThreadSafe(
                        workers,
                        gpa,
                        io,
                        trimmed,
                        true,
                    );
                } else if (isImageFile(trimmed)) {
                    path_scan.appendPathThreadSafe(workers, gpa, io, trimmed);
                }
            } else |err| {
                std.log.debug(
                    "statFile failed for '{s}': {any}, treating as file path",
                    .{ trimmed, err },
                );
                path_scan.appendPathThreadSafe(workers, gpa, io, trimmed);
            }
        }
    }
}
