const std = @import("std");
const app_state = @import("../state.zig");
const ViewerState = app_state.ViewerState;
const fs = @import("../fs.zig");
const path_scan = @import("path_scan.zig");
const context = @import("context.zig");

pub const StdinArgs = struct {
    state: *ViewerState,
    io: std.Io,
    gpa: std.mem.Allocator,
};

pub fn stdinWorker(args: *StdinArgs) void {
    const state = args.state;
    const io = args.io;
    const gpa = args.gpa;
    defer {
        state.navigation.is_loading_files.store(false, .release);
        context.wakeUpMainThread();
        state.allocator.destroy(args);
        _ = state.workers.active_threads.fetchSub(1, .release);
    }

    var read_buf: [4096]u8 = undefined;
    var stdin_file_reader = std.Io.File.Reader.init(std.Io.File.stdin(), io, &read_buf);
    const stdin = &stdin_file_reader.interface;

    while (!state.exiting.load(.acquire)) {
        const line = (stdin.takeDelimiter('\n') catch break) orelse break;
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (trimmed.len > 0) {
            if (std.Io.Dir.statFile(std.Io.Dir.cwd(), io, trimmed, .{})) |s| {
                if (s.kind == .directory) {
                    path_scan.scanDirectoryThreadSafe(state, gpa, io, trimmed);
                } else if (fs.isImageFile(trimmed)) {
                    path_scan.appendPathThreadSafe(state, gpa, trimmed);
                }
            } else |err| {
                std.log.debug("statFile failed for '{s}': {any}, treating as file path", .{ trimmed, err });
                path_scan.appendPathThreadSafe(state, gpa, trimmed);
            }
        }
    }
}
