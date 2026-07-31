const std = @import("std");
const builtin = @import("builtin");
const app_state = @import("../state.zig");
const ViewerState = app_state.ViewerState;
const ipc = @import("../ipc.zig");
const context = @import("context.zig");

extern "kernel32" fn GetCurrentProcessId() callconv(std.builtin.CallingConvention.winapi) u32;

fn getProcessId() u32 {
    if (builtin.os.tag == .windows) {
        return GetCurrentProcessId();
    } else {
        return @intCast(std.posix.system.getpid());
    }
}

pub fn ipcServerWorkerTask(state: *ViewerState) void {
    defer _ = state.active_threads.fetchSub(1, .release);
    runIpcServer(state) catch |err| {
        std.log.err("IPC Server error: {any}", .{err});
    };
}

fn runIpcServer(state: *ViewerState) !void {
    const io = state.io;
    const gpa = state.allocator;

    const pid = getProcessId();
    var path_buf: [128]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/peng-{d}.sock", .{pid});

    std.Io.Dir.createDir(std.Io.Dir.cwd(), io, "/tmp", @enumFromInt(0)) catch |err| {
        std.log.debug("IPC createDir /tmp failed or already exists: {any}", .{err});
    };

    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, socket_path) catch |err| {
        std.log.debug("IPC socket pre-delete failed (file may not exist): {any}", .{err});
    };

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, socket_path) catch |err| {
            std.log.debug("IPC socket cleanup delete failed: {any}", .{err});
        };
    }

    const msg = try std.fmt.allocPrint(gpa, "IPC socket: {s}\n", .{socket_path});
    defer gpa.free(msg);
    var stdout_write_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &stdout_write_buf);
    stdout_writer.interface.writeAll(msg) catch |err| {
        std.log.debug("IPC writeAll to stdout failed: {any}", .{err});
    };
    stdout_writer.interface.flush() catch |err| {
        std.log.debug("IPC flush to stdout failed: {any}", .{err});
    };

    while (!state.exiting.load(.acquire)) {
        var client_stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => break,
            else => {
                if (state.exiting.load(.acquire)) break;
                std.log.err("IPC server accept failed: {any}", .{err});
                continue;
            },
        };
        errdefer client_stream.close(io);

        var read_buf: [1024]u8 = undefined;
        var reader = client_stream.reader(io, &read_buf);
        const line_opt = reader.interface.takeDelimiter('\n') catch |err| {
            std.log.err("IPC server read failed: {any}", .{err});
            client_stream.close(io);
            continue;
        };

        const line = line_opt orelse {
            client_stream.close(io);
            continue;
        };

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            client_stream.close(io);
            continue;
        }

        const cmd_data = gpa.create(ipc.IpcCommandData) catch |err| {
            std.log.err("IPC create command data failed: {}", .{err});
            client_stream.close(io);
            continue;
        };
        const cmd_str = gpa.dupe(u8, trimmed) catch |err| {
            std.log.err("IPC dupe command string failed: {}", .{err});
            gpa.destroy(cmd_data);
            client_stream.close(io);
            continue;
        };
        cmd_data.* = .{
            .command = cmd_str,
            .client_stream = client_stream,
        };

        state.event_queue.push(gpa, io, .{ .ipc_command = cmd_data }) catch |err| {
            std.log.err("Failed to push IPC command to MpscQueue: {}", .{err});
            gpa.free(cmd_str);
            gpa.destroy(cmd_data);
            client_stream.close(io);
            continue;
        };
        context.wakeUpMainThread();
    }
}
