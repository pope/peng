const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const intents = @import("intents");
const TextureScaleMode = intents.TextureScaleMode;
const fs = @import("fs.zig");
const screenshot = @import("screenshot.zig");
const clay = @import("zclay");

extern "kernel32" fn GetCurrentProcessId() callconv(std.builtin.CallingConvention.winapi) u32;

fn getProcessId() u32 {
    if (builtin.os.tag == .windows) {
        return GetCurrentProcessId();
    } else {
        return @intCast(std.posix.system.getpid());
    }
}

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

        _ = state.active_threads.fetchAdd(1, .monotonic);
        if (std.Thread.spawn(.{}, ipcServerWorkerTask, .{state})) |t| {
            t.detach();
        } else |err| {
            _ = state.active_threads.fetchSub(1, .release);
            std.log.err("Failed to create UDS IPC server thread: {}", .{err});
            allocator.destroy(self);
            return error.ThreadCreationFailed;
        }

        return self;
    }

    pub fn deinit(self: *IpcServer, io: std.Io) void {
        if (builtin.os.tag != .windows) {
            const pid = getProcessId();
            var path_buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&path_buf, "/tmp/peng-{d}.sock", .{pid})) |sock_path| {
                if (std.Io.net.UnixAddress.init(sock_path)) |addr| {
                    if (addr.connect(io)) |dummy| {
                        dummy.close(io);
                    } else |err| {
                        if (err != error.FileNotFound and err != error.ConnectionRefused) {
                            std.log.debug("IPC deinit dummy connect failed: {any}", .{err});
                        }
                    }
                } else |err| {
                    std.log.debug("IPC deinit address init failed: {any}", .{err});
                }
            } else |err| {
                std.log.debug("IPC deinit socket path format failed: {any}", .{err});
            }
        }
        self.allocator.destroy(self);
    }
};

pub const PaletteKind = enum {
    actions,
    files,
    slideshow,
    none,
};

pub const PaletteTarget = struct {
    kind: PaletteKind,
    query: ?[]const u8 = null,
};

pub const ThumbAction = enum {
    enable,
    disable,
    toggle,
};

pub const IpcCommand = union(enum) {
    zoom: f32,
    pan: struct { x: f32, y: f32 },
    adjust: struct { brightness: f32, contrast: f32 },
    filter: TextureScaleMode,
    palette: PaletteTarget,
    thumb: ThumbAction,
    debug: bool,
    wait_load,
    next,
    prev,
    quit,
    screenshot: []const u8,

    pub fn toIntent(self: IpcCommand) ?intents.AppIntent {
        switch (self) {
            .zoom => |factor| return .{ .set_zoom = factor },
            .pan => |p| return .{ .set_pan = .{ .x = p.x, .y = p.y } },
            .adjust => return null,
            .filter => |mode| return .{ .set_filter = mode },
            .palette => |target| {
                const mode: intents.PaletteMode = switch (target.kind) {
                    .actions => .actions,
                    .files => .files,
                    .slideshow => .set_slideshow_interval,
                    .none => .inactive,
                };
                return .{ .set_palette = .{ .mode = mode, .query = target.query } };
            },
            .thumb => |action| {
                switch (action) {
                    .enable => return .{ .set_debug_thumb = true },
                    .disable => return .{ .set_debug_thumb = false },
                    .toggle => return .toggle_debug_thumb,
                }
            },
            .debug => |enabled| return .{ .set_debug_mode = enabled },
            .next => return .next_image,
            .prev => return .prev_image,
            .quit => return .quit,
            .wait_load, .screenshot => return null,
        }
    }

    pub fn parse(command: []const u8) !IpcCommand {
        var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
        const cmd = it.next() orelse return error.UnknownCommand;

        if (std.mem.eql(u8, cmd, "zoom")) {
            const factor_str = it.next() orelse return error.MissingArgument;
            if (factor_str.len > 128) return error.InvalidArgument;
            const factor = try std.fmt.parseFloat(f32, factor_str);
            if (std.math.isNan(factor) or std.math.isInf(factor)) return error.InvalidArgument;
            return .{ .zoom = factor };
        } else if (std.mem.eql(u8, cmd, "pan")) {
            const px_str = it.next() orelse return error.MissingArgument;
            const py_str = it.next() orelse return error.MissingArgument;
            if (px_str.len > 128 or py_str.len > 128) return error.InvalidArgument;
            const px = try std.fmt.parseFloat(f32, px_str);
            const py = try std.fmt.parseFloat(f32, py_str);
            if (std.math.isNan(px) or std.math.isInf(px) or std.math.isNan(py) or std.math.isInf(py)) return error.InvalidArgument;
            return .{ .pan = .{ .x = px, .y = py } };
        } else if (std.mem.eql(u8, cmd, "adjust")) {
            const br_str = it.next() orelse return error.MissingArgument;
            const co_str = it.next() orelse return error.MissingArgument;
            if (br_str.len > 128 or co_str.len > 128) return error.InvalidArgument;
            const br = try std.fmt.parseFloat(f32, br_str);
            const co = try std.fmt.parseFloat(f32, co_str);
            if (std.math.isNan(br) or std.math.isInf(br) or std.math.isNan(co) or std.math.isInf(co)) return error.InvalidArgument;
            return .{ .adjust = .{ .brightness = br, .contrast = co } };
        } else if (std.mem.eql(u8, cmd, "filter")) {
            const val = it.next() orelse return error.MissingArgument;
            if (std.meta.stringToEnum(TextureScaleMode, val)) |mode| {
                return .{ .filter = mode };
            }
            return error.UnknownFilter;
        } else if (std.mem.eql(u8, cmd, "palette")) {
            const pal_name = it.next() orelse return error.MissingArgument;
            var kind: PaletteKind = undefined;
            if (std.mem.eql(u8, pal_name, "action") or std.mem.eql(u8, pal_name, "actions")) {
                kind = .actions;
            } else if (std.mem.eql(u8, pal_name, "files")) {
                kind = .files;
            } else if (std.mem.eql(u8, pal_name, "slideshow")) {
                kind = .slideshow;
            } else if (std.mem.eql(u8, pal_name, "none")) {
                kind = .none;
            } else {
                return error.UnknownPalette;
            }
            const query_opt = it.next();
            return .{ .palette = .{ .kind = kind, .query = query_opt } };
        } else if (std.mem.eql(u8, cmd, "thumb")) {
            if (it.next()) |val| {
                if (std.mem.eql(u8, val, "true")) {
                    return .{ .thumb = .enable };
                } else if (std.mem.eql(u8, val, "false")) {
                    return .{ .thumb = .disable };
                } else if (std.mem.eql(u8, val, "toggle")) {
                    return .{ .thumb = .toggle };
                } else {
                    return error.InvalidArgument;
                }
            } else {
                return .{ .thumb = .toggle };
            }
        } else if (std.mem.eql(u8, cmd, "debug")) {
            const val = it.next() orelse return error.MissingArgument;
            if (std.mem.eql(u8, val, "true")) {
                return .{ .debug = true };
            } else if (std.mem.eql(u8, val, "false")) {
                return .{ .debug = false };
            } else {
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, cmd, "wait_load")) {
            return .wait_load;
        } else if (std.mem.eql(u8, cmd, "next")) {
            return .next;
        } else if (std.mem.eql(u8, cmd, "prev")) {
            return .prev;
        } else if (std.mem.eql(u8, cmd, "screenshot")) {
            const filepath = it.next() orelse return error.MissingArgument;
            if (filepath.len > 512) return error.PathTooLong;
            return .{ .screenshot = filepath };
        } else if (std.mem.eql(u8, cmd, "quit")) {
            return .quit;
        } else {
            return error.UnknownCommand;
        }
    }
};

fn ipcServerWorkerTask(state: *ViewerState) void {
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

        const cmd_data = gpa.create(IpcCommandData) catch |err| {
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
        fs.wakeUpMainThread();
    }
}

pub fn respondOk(io: std.Io, stream: std.Io.net.Stream) !void {
    var write_buf: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("OK\n");
    try writer.interface.flush();
    stream.close(io);
}

test "IpcCommand parsing" {
    const cmd_zoom = try IpcCommand.parse("zoom 2.5");
    try std.testing.expectEqual(@as(f32, 2.5), cmd_zoom.zoom);

    const cmd_pan = try IpcCommand.parse("pan 100 -50");
    try std.testing.expectEqual(@as(f32, 100), cmd_pan.pan.x);
    try std.testing.expectEqual(@as(f32, -50), cmd_pan.pan.y);

    const cmd_filter = try IpcCommand.parse("filter mitchell");
    try std.testing.expectEqual(TextureScaleMode.mitchell, cmd_filter.filter);

    const cmd_next = try IpcCommand.parse("next");
    try std.testing.expectEqual(IpcCommand.next, cmd_next);

    try std.testing.expectError(error.UnknownCommand, IpcCommand.parse("invalid_command"));
}
