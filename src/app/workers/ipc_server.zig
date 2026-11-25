const builtin = @import("builtin");
const events = @import("events.zig");
const ipc = @import("ipc");
const manager = @import("manager.zig");
const std = @import("std");

const BackgroundEvent = events.BackgroundEvent;
const WorkerManager = manager.WorkerManager;

/// Thread arguments for spawning the background IPC server.
pub const IpcServerArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    lock_owned: bool = false,
};

/// Entry point executed on a background thread to listen for incoming IPC
/// socket connections.
pub fn ipcServerWorkerTask(args: *IpcServerArgs) void {
    const workers = args.workers;
    const gpa = args.allocator;
    const io = args.io;
    const socket_path = args.socket_path;
    const lock_owned = args.lock_owned;
    defer gpa.destroy(args);
    runIpcServer(workers, gpa, io, socket_path, lock_owned) catch |err| {
        std.log.err("IPC Server error: {any}", .{err});
    };
}

fn runIpcServer(
    workers: *WorkerManager,
    gpa: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    lock_owned: bool,
) !void {
    var local_lock: ?ipc.SocketLock = null;
    defer if (local_lock) |lock| lock.release(io);
    if (!lock_owned) {
        var lock_buf: [160]u8 = undefined;
        const lock_path = try ipc.formatLockPath(
            &lock_buf,
            socket_path,
            ".lock",
        );
        local_lock = try ipc.SocketLock.tryAcquire(io, lock_path);
        if (local_lock == null) {
            std.log.info(
                "IPC socket '{s}' already owned by another peng process",
                .{socket_path},
            );
            return;
        }
    }
    if (std.Io.Dir.path.dirname(socket_path)) |dir_path| {
        if (dir_path.len > 0) {
            std.Io.Dir.createDirPath(
                std.Io.Dir.cwd(),
                io,
                dir_path,
            ) catch |err| {
                std.log.debug(
                    "IPC createDirPath '{s}' failed or already exists: {any}",
                    .{ dir_path, err },
                );
            };
        }
    }

    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, socket_path) catch |err| {
        std.log.debug(
            "IPC socket pre-delete failed (file may not exist): {any}",
            .{err},
        );
    };

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, socket_path) catch |err| {
            std.log.debug("IPC socket cleanup delete failed: {any}", .{err});
        };
    }

    if (!builtin.is_test) {
        var msg_buf: [256]u8 = undefined;
        const msg = std.mem.print(
            &msg_buf,
            "IPC socket: {s}\n",
            .{socket_path},
        ) catch "IPC socket ready\n";
        var stdout_write_buf: [256]u8 = undefined;
        var stdout_writer = std.Io.File.Writer.initStreaming(
            std.Io.File.stdout(),
            io,
            &stdout_write_buf,
        );
        stdout_writer.interface.writeAll(msg) catch |err| {
            std.log.debug("IPC writeAll to stdout failed: {any}", .{err});
        };
        stdout_writer.interface.flush() catch |err| {
            std.log.debug("IPC flush to stdout failed: {any}", .{err});
        };
    }

    acceptIpcConnections(&server, workers, gpa, io);
}

fn configureSocketSendTimeout(socket: std.Io.net.Socket) void {
    if (builtin.os.tag == .windows) return;
    const tv = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(
        socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&tv),
    ) catch |err| {
        std.log.debug("IPC setsockopt SO_SNDTIMEO failed: {}", .{err});
    };
}

fn acceptIpcConnections(
    server: *std.Io.net.Server,
    workers: *WorkerManager,
    gpa: std.mem.Allocator,
    io: std.Io,
) void {
    while (!workers.exiting.load(.acquire)) {
        var client_stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => break,
            else => {
                if (workers.exiting.load(.acquire)) break;
                std.log.err("IPC server accept failed: {any}", .{err});
                continue;
            },
        };
        if (workers.exiting.load(.acquire)) {
            client_stream.close(io);
            break;
        }
        errdefer client_stream.close(io);
        configureSocketSendTimeout(client_stream.socket);

        var read_buf: [8 * 1024]u8 = undefined;
        const read_timeout: std.Io.Clock.Duration = .{
            .raw = std.Io.Duration.fromSeconds(2),
            .clock = .awake,
        };
        const line_opt = ipc.readLineTimeout(
            &client_stream.socket,
            io,
            &read_buf,
            read_timeout,
        ) catch |err| {
            if (err == error.Timeout) {
                std.log.warn("IPC server client read timed out", .{});
            } else {
                std.log.err("IPC server read failed: {any}", .{err});
            }
            ipc.respondErrorName(io, client_stream, @errorName(err));
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
            ipc.respondErrorName(io, client_stream, @errorName(err));
            continue;
        };
        const cmd_str = gpa.dupe(u8, trimmed) catch |err| {
            std.log.err("IPC dupe command string failed: {}", .{err});
            gpa.destroy(cmd_data);
            ipc.respondErrorName(io, client_stream, @errorName(err));
            continue;
        };
        cmd_data.* = .{
            .command = cmd_str,
            .client_stream = client_stream,
        };

        workers.event_queue.push(gpa, io, .{ .ipc_command = cmd_data }) catch |err| {
            std.log.err("Failed to push IPC command to MpscQueue: {}", .{err});
            gpa.free(cmd_str);
            gpa.destroy(cmd_data);
            ipc.respondErrorName(io, client_stream, @errorName(err));
            continue;
        };
        workers.wakeMainThread();
    }
}

test "acceptIpcConnections - accepts command and exits cleanly on wakeup" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var sock_buf: [128]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc_test.sock",
        .{tmp.sub_path},
    );

    const address = try std.Io.net.UnixAddress.init(sock_path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, sock_path) catch {};
    }

    var workers = WorkerManager.init(.none);
    defer workers.deinit(allocator, io);

    const ListenerCtx = struct {
        srv: *std.Io.net.Server,
        wrk: *WorkerManager,
        alloc: std.mem.Allocator,
        io_ctx: std.Io,

        fn run(ctx: @This()) void {
            acceptIpcConnections(ctx.srv, ctx.wrk, ctx.alloc, ctx.io_ctx);
        }
    };

    const thread = try std.Thread.spawn(.{}, ListenerCtx.run, .{ListenerCtx{
        .srv = &server,
        .wrk = &workers,
        .alloc = allocator,
        .io_ctx = io,
    }});

    // 1. Send a real command while exiting == false and wait for it to queue
    var client = try address.connect(io);
    defer client.close(io);
    var wr_buf: [64]u8 = undefined;
    var writer = client.writer(io, &wr_buf);
    try writer.interface.writeAll("next\n");
    try writer.interface.flush();

    var batch: std.ArrayList(BackgroundEvent) = .empty;
    defer {
        for (batch.items) |*e| e.deinitQueueItem(allocator, io);
        batch.deinit(allocator);
    }
    while (batch.items.len == 0) {
        workers.event_queue.drain(io, &batch);
        if (batch.items.len == 0) std.Thread.yield() catch {};
    }

    // 2. Signal exiting = true and wake the blocking server.accept(io)
    workers.exiting.store(true, .release);
    ipc.wakeSocketListener(io, sock_path);
    thread.join();

    try std.testing.expectEqual(@as(usize, 1), batch.items.len);
    try std.testing.expectEqualStrings(
        "next",
        batch.items[0].ipc_command.command,
    );
}
