const std = @import("std");
const fs = @import("../fs.zig");
const path_scan = @import("path_scan.zig");
const context = @import("context.zig");
const root = @import("root.zig");
const WorkerManager = root.WorkerManager;

pub const StdinArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    is_loading_files: ?*std.atomic.Value(bool) = null,
};

pub fn stdinWorker(args: *StdinArgs) void {
    const workers = args.workers;
    const io = args.io;
    const gpa = args.allocator;
    defer {
        if (args.is_loading_files) |flag| flag.store(false, .release);
        context.wakeUpMainThread();
        gpa.destroy(args);
        _ = workers.active_threads.fetchSub(1, .release);
    }

    var read_buf: [4096]u8 = undefined;
    var stdin_file_reader = std.Io.File.Reader.init(std.Io.File.stdin(), io, &read_buf);
    const stdin = &stdin_file_reader.interface;

    while (!workers.exiting.load(.acquire)) {
        const line = (stdin.takeDelimiter('\n') catch break) orelse break;
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (trimmed.len > 0) {
            if (std.Io.Dir.statFile(std.Io.Dir.cwd(), io, trimmed, .{})) |s| {
                if (s.kind == .directory) {
                    path_scan.scanDirectoryThreadSafe(workers, gpa, io, trimmed);
                } else if (fs.isImageFile(trimmed)) {
                    path_scan.appendPathThreadSafe(workers, gpa, io, trimmed);
                }
            } else |err| {
                std.log.debug("statFile failed for '{s}': {any}, treating as file path", .{ trimmed, err });
                path_scan.appendPathThreadSafe(workers, gpa, io, trimmed);
            }
        }
    }
}
