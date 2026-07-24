const std = @import("std");
const c_lib = @import("c.zig").c;
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const ScaleMode = app_state.ScaleMode;
const TextureScaleMode = app_state.TextureScaleMode;
const clay = @import("zclay");

/// Low-level POSIX unbuffered write system call binding.
/// Used to write the IPC Unix Domain Socket path directly to STDOUT_FILENO (fd 1)
/// without stdio stream buffering. This ensures child process stdout pipes
/// (such as peng-test-runner) receive the socket path string instantly.
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

pub const IpcCommandData = struct {
    command: []const u8,
    client_stream: std.Io.net.Stream,
};

pub const IpcServer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, state: *ViewerState) !*IpcServer {
        const self = try allocator.create(IpcServer);
        self.* = .{
            .allocator = allocator,
        };

        if (std.Thread.spawn(.{}, ipcServerWorkerTask, .{state})) |t| {
            t.detach();
        } else |err| {
            std.log.err("Failed to create UDS IPC server thread: {}", .{err});
            allocator.destroy(self);
            return error.ThreadCreationFailed;
        }

        return self;
    }

    pub fn deinit(self: *IpcServer, io: std.Io) void {
        const pid = std.posix.system.getpid();
        var path_buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&path_buf, "/tmp/peng-{d}.sock", .{pid})) |sock_path| {
            if (std.Io.net.UnixAddress.init(sock_path)) |addr| {
                if (addr.connect(io)) |dummy| {
                    dummy.close(io);
                } else |err| {
                    if (err != error.FileNotFound) {
                        std.log.debug("IPC deinit dummy connect failed: {any}", .{err});
                    }
                }
            } else |err| {
                std.log.debug("IPC deinit address init failed: {any}", .{err});
            }
        } else |err| {
            std.log.debug("IPC deinit socket path format failed: {any}", .{err});
        }
        self.allocator.destroy(self);
    }

    pub fn executeCommand(self: *IpcServer, state: *ViewerState, command: []const u8, stream: std.Io.net.Stream) !void {
        _ = self;
        var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
        const cmd = it.next() orelse return;

        if (std.mem.eql(u8, cmd, "zoom")) {
            const factor_str = it.next() orelse return error.MissingArgument;
            if (factor_str.len > 128) return error.InvalidArgument;
            const factor = try std.fmt.parseFloat(f32, factor_str);
            if (std.math.isNan(factor) or std.math.isInf(factor)) return error.InvalidArgument;
            state.zoom_factor = state.clampZoomFactor(factor);
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "pan")) {
            const px_str = it.next() orelse return error.MissingArgument;
            const py_str = it.next() orelse return error.MissingArgument;
            if (px_str.len > 128 or py_str.len > 128) return error.InvalidArgument;
            const px = try std.fmt.parseFloat(f32, px_str);
            const py = try std.fmt.parseFloat(f32, py_str);
            if (std.math.isNan(px) or std.math.isInf(px) or std.math.isNan(py) or std.math.isInf(py)) return error.InvalidArgument;
            state.pan_x = px;
            state.pan_y = py;
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "adjust")) {
            const br_str = it.next() orelse return error.MissingArgument;
            const co_str = it.next() orelse return error.MissingArgument;
            if (br_str.len > 128 or co_str.len > 128) return error.InvalidArgument;
            const br = try std.fmt.parseFloat(f32, br_str);
            const co = try std.fmt.parseFloat(f32, co_str);
            if (std.math.isNan(br) or std.math.isInf(br) or std.math.isNan(co) or std.math.isInf(co)) return error.InvalidArgument;
            state.brightness = std.math.clamp(br, -1.0, 1.0);
            state.contrast = std.math.clamp(co, 0.0, 5.0);
            state.adjustments_dirty = true;
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "filter")) {
            const val = it.next() orelse return error.MissingArgument;
            if (std.mem.eql(u8, val, "mitchell")) {
                state.texture_scale_mode = .mitchell;
            } else if (std.mem.eql(u8, val, "lanczos3")) {
                state.texture_scale_mode = .lanczos3;
            } else if (std.mem.eql(u8, val, "linear")) {
                state.texture_scale_mode = .linear;
            } else if (std.mem.eql(u8, val, "pixel_art")) {
                state.texture_scale_mode = .pixel_art;
            } else {
                return error.UnknownFilter;
            }
            state.applyTextureScaleMode();
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "palette")) {
            const pal_name = it.next() orelse return error.MissingArgument;
            if (std.mem.eql(u8, pal_name, "action")) {
                try state.openPalette(.actions);
            } else if (std.mem.eql(u8, pal_name, "files")) {
                try state.openPalette(.files);
            } else if (std.mem.eql(u8, pal_name, "none")) {
                state.palette.mode = .inactive;
            } else {
                return error.UnknownPalette;
            }
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "thumb")) {
            if (it.next()) |val| {
                if (std.mem.eql(u8, val, "true")) {
                    try state.setDebugShowThumb(true);
                } else if (std.mem.eql(u8, val, "false")) {
                    try state.setDebugShowThumb(false);
                } else if (std.mem.eql(u8, val, "toggle")) {
                    try state.setDebugShowThumb(!state.debug_show_thumb);
                } else {
                    return error.InvalidArgument;
                }
            } else {
                try state.setDebugShowThumb(!state.debug_show_thumb);
            }
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "debug")) {
            const val = it.next() orelse return error.MissingArgument;
            if (std.mem.eql(u8, val, "true")) {
                clay.setDebugModeEnabled(true);
            } else if (std.mem.eql(u8, val, "false")) {
                clay.setDebugModeEnabled(false);
            } else {
                return error.InvalidArgument;
            }
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "wait_load")) {
            var attempts: u32 = 0;
            while (attempts < 1000) : (attempts += 1) {
                _ = state.processBackgroundEvents();
                state.prepareCacheTextures();
                if (state.getCurrentEntry()) |entry| {
                    if (entry.status != .decoding) {
                        break;
                    }
                }
                _ = c_lib.SDL_Delay(10);
            }
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "next")) {
            try state.next();
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "prev")) {
            try state.prev();
            try respondOk(state.io, stream);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            state.running = false;
            try respondOk(state.io, stream);
            const pid = std.posix.system.getpid();
            var path_buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&path_buf, "/tmp/peng-{d}.sock", .{pid})) |sock_path| {
                const addr = std.Io.net.UnixAddress.init(sock_path) catch |err| {
                    std.log.debug("IPC quit dummy address init failed: {any}", .{err});
                    return;
                };
                const dummy = addr.connect(state.io) catch |err| {
                    std.log.debug("IPC quit dummy connect failed: {any}", .{err});
                    return;
                };
                dummy.close(state.io);
            } else |err| {
                std.log.debug("IPC quit bufPrint failed: {any}", .{err});
            }
        } else {
            return error.UnknownCommand;
        }
    }
};

fn ipcServerWorkerTask(state: *ViewerState) void {
    runIpcServer(state) catch |err| {
        std.log.err("IPC Server error: {any}", .{err});
    };
}

fn runIpcServer(state: *ViewerState) !void {
    const io = state.io;
    const gpa = state.allocator;

    const pid = std.posix.system.getpid();
    var path_buf: [128]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/peng-{d}.sock", .{pid});

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
    _ = write(1, msg.ptr, msg.len);

    while (state.running) {
        var client_stream = server.accept(io) catch |err| {
            if (!state.running) break;
            std.log.err("IPC server accept failed: {any}", .{err});
            continue;
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

        const cmd_data = gpa.create(IpcCommandData) catch {
            client_stream.close(io);
            continue;
        };
        const cmd_str = gpa.dupe(u8, trimmed) catch {
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
        app_state.fs.wakeUpMainThread();
    }
}

fn respondOk(io: std.Io, stream: std.Io.net.Stream) !void {
    var write_buf: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("OK\n");
    try writer.interface.flush();
    stream.close(io);
}
