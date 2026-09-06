const std = @import("std");

/// CLI entry point for sending IPC commands to a running Peng instance via Unix domain socket.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    // Skip executable name
    _ = args_it.next();

    const socket_path = args_it.next() orelse {
        std.log.err("Usage: peng-msg <socket_path> <command_words...>", .{});
        std.process.exit(1);
    };

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

    const stream = address.connect(io) catch |err| {
        std.log.err("Failed to connect to socket {s}: {any}", .{ socket_path, err });
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
    var reader = stream.reader(io, &read_buf);
    const response_opt = reader.interface.takeDelimiter('\n') catch |err| {
        std.log.err("Failed to read response: {any}", .{err});
        std.process.exit(1);
    };

    if (response_opt) |response| {
        std.log.info("{s}", .{response});
        if (std.mem.startsWith(u8, response, "ERR")) {
            std.process.exit(1);
        }
    } else {
        std.log.err("No response from server", .{});
        std.process.exit(1);
    }
}
