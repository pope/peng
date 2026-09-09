const app_config = @import("config");
const ipc = @import("ipc");
const std = @import("std");

/// CLI entry point for sending IPC commands to a running Peng instance via Unix domain socket.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    // Skip executable name
    _ = args_it.next();

    const first_arg = args_it.next() orelse {
        app_config.cli.printIpcHelp(io);
        std.process.exit(1);
    };

    if (app_config.cli.findOptionFor(first_arg, .ipc)) |opt| {
        if (opt.id == .help) {
            app_config.cli.printIpcHelp(io);
            return;
        }
    }

    const socket_path = first_arg;

    // Join the rest of the arguments with space
    var command_buf: std.ArrayList(u8) = .empty;
    defer command_buf.deinit(gpa);
    var idx: usize = 0;
    while (args_it.next()) |arg| : (idx += 1) {
        if (idx > 0) try command_buf.append(gpa, ' ');
        try command_buf.appendSlice(gpa, arg);
    }
    try command_buf.append(gpa, '\n');

    if (command_buf.items.len <= 1) {
        std.log.err("Usage: peng-msg <socket_path> <command_words...>", .{});
        std.process.exit(1);
    }

    const address = std.Io.net.UnixAddress.init(socket_path) catch |err| {
        std.log.err("Invalid socket path: {any}", .{err});
        std.process.exit(1);
    };

    const max_connect_attempts = 25; // 25 * 40ms = 1.0s max wait for server socket creation
    var attempt: usize = 0;
    const stream = while (attempt < max_connect_attempts) : (attempt += 1) {
        if (address.connect(io)) |s| {
            break s;
        } else |err| switch (err) {
            error.FileNotFound, error.WouldBlock => {
                if (attempt + 1 < max_connect_attempts) {
                    std.Io.sleep(
                        io,
                        std.Io.Duration.fromMilliseconds(40),
                        .awake,
                    ) catch |sleep_err| {
                        std.log.debug("Connect retry sleep interrupted: {any}", .{sleep_err});
                    };
                    continue;
                }
                std.log.err("Failed to connect to socket {s}: {any}", .{ socket_path, err });
                std.process.exit(1);
            },
            else => {
                std.log.err("Failed to connect to socket {s}: {any}", .{ socket_path, err });
                std.process.exit(1);
            },
        }
    } else {
        std.log.err("Failed to connect to socket {s}: Connection timed out", .{socket_path});
        std.process.exit(1);
    };
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(command_buf.items) catch |err| {
        std.log.err("Failed to send command: {any}", .{err});
        std.process.exit(1);
    };
    writer.interface.flush() catch |err| {
        std.log.debug("Failed to flush command stream: {any}", .{err});
    };

    var read_buf: [1024]u8 = undefined;
    const timeout_dur: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromSeconds(15),
        .clock = .awake,
    };
    const response_opt = ipc.readLineTimeout(
        &stream.socket,
        io,
        &read_buf,
        timeout_dur,
    ) catch |err| {
        if (err == error.Timeout) {
            std.log.err("Timed out waiting for response from peng ({s})", .{socket_path});
        } else {
            std.log.err("Failed to read response: {any}", .{err});
        }
        std.process.exit(1);
    };

    if (response_opt) |response| {
        const trimmed = std.mem.trim(u8, response, " \t\r");
        std.log.info("{s}", .{trimmed});
        if (std.mem.startsWith(u8, trimmed, "ERR")) {
            std.process.exit(1);
        }
    } else {
        std.log.err("No response from server", .{});
        std.process.exit(1);
    }
}
