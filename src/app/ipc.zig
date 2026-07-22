const std = @import("std");
const c_lib = @import("c.zig").c;
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const ScaleMode = app_state.ScaleMode;
const TextureScaleMode = app_state.TextureScaleMode;
const clay = @import("zclay");

pub var PENG_IPC_EVENT: u32 = 0xFFFFFFFF;

pub const IpcCommandData = struct {
    command: []const u8,
    client_stream: std.Io.net.Stream,
};

pub const IpcServer = struct {
    thread: ?*c_lib.SDL_Thread = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, state: *ViewerState) !*IpcServer {
        const self = try allocator.create(IpcServer);
        self.* = .{
            .allocator = allocator,
            .thread = null,
        };

        // Start the background server thread using SDL3's SDL_CreateThread
        self.thread = c_lib.SDL_CreateThread(ipcServerWorker, "IpcServerThread", state) orelse {
            std.log.err("Failed to create UDS IPC server thread: {s}", .{c_lib.SDL_GetError()});
            allocator.destroy(self);
            return error.ThreadCreationFailed;
        };
        c_lib.SDL_DetachThread(self.thread.?);

        return self;
    }

    pub fn deinit(self: *IpcServer) void {
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
        } else {
            return error.UnknownCommand;
        }
    }
};

fn ipcServerWorker(data: ?*anyopaque) callconv(.c) c_int {
    const state = @as(*ViewerState, @ptrCast(@alignCast(data.?)));
    runIpcServer(state) catch |err| {
        std.log.err("IPC Server error: {any}", .{err});
    };
    return 0;
}

fn runIpcServer(state: *ViewerState) !void {
    const io = state.io;
    const gpa = state.allocator;

    const pid = std.posix.system.getpid();
    var path_buf: [128]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/peng-{d}.sock", .{pid});

    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, socket_path) catch {};

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, socket_path) catch {};
    }

    // Print path to stdout for test runner discovery
    const msg = try std.fmt.allocPrint(gpa, "IPC socket: {s}\n", .{socket_path});
    const stdout = std.Io.File.stdout();
    var writer = stdout.writer(io, &.{});
    writer.interface.writeAll(msg) catch {};
    gpa.free(msg);

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

        var event: c_lib.SDL_Event = undefined;
        event.type = PENG_IPC_EVENT;
        event.user.data1 = cmd_data;
        if (!c_lib.SDL_PushEvent(&event)) {
            std.log.err("Failed to push IPC event to SDL event queue", .{});
            gpa.free(cmd_str);
            gpa.destroy(cmd_data);
            client_stream.close(io);
        }
    }
}

fn respondOk(io: std.Io, stream: std.Io.net.Stream) !void {
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll("OK\n");
    stream.close(io);
}
