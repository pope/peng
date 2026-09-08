const builtin = @import("builtin");
const intents = @import("intents");
const sdl = @import("sdl");
const std = @import("std");

const TextureScaleMode = intents.TextureScaleMode;

extern "kernel32" fn GetCurrentProcessId() callconv(std.builtin.CallingConvention.winapi) u32;

fn getProcessId() u32 {
    if (builtin.os.tag == .windows) {
        return GetCurrentProcessId();
    } else {
        return @intCast(std.posix.system.getpid());
    }
}

/// Command string payload received from an IPC client together with its open communication stream.
pub const IpcCommandData = struct {
    command: []const u8,
    client_stream: std.Io.net.Stream,
};

/// Context managing the background Unix domain socket IPC server listener and client connections.
pub const IpcServer = struct {
    allocator: std.mem.Allocator,

    /// Allocates and initializes an `IpcServer` instance.
    pub fn init(allocator: std.mem.Allocator) !*IpcServer {
        const self = try allocator.create(IpcServer);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    /// Connects a dummy socket to wake the listener thread, removes socket file, and destroys the server.
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

/// Specifies the target palette mode and optional initial search filter query.
pub const PaletteTarget = struct {
    kind: PaletteKind,
    query: ?[]const u8 = null,
};

pub const ThumbAction = enum {
    enable,
    disable,
    toggle,
};

pub const TitleAction = enum {
    enable,
    disable,
    toggle,
};

pub const IpcCommand = union(enum) {
    zoom: f32,
    pan: struct { x: f32, y: f32 },
    adjust: struct { brightness: f32, contrast: f32 },
    filter: TextureScaleMode,
    scale: intents.ScaleMode,
    manga: bool,
    title: TitleAction,
    palette: PaletteTarget,
    thumb: ThumbAction,
    debug: bool,
    wait_load,
    next,
    prev,
    quit,
    screenshot: []const u8,

    /// Converts an IPC command variant into an `AppIntent`, or returns `null` for internal commands.
    pub fn toIntent(self: IpcCommand) ?intents.AppIntent {
        switch (self) {
            .zoom => |factor| return .{ .set_zoom = factor },
            .pan => |p| return .{ .set_pan = .{ .x = p.x, .y = p.y } },
            .adjust => return null,
            .filter => |mode| return .{ .set_filter = mode },
            .scale => |mode| return .{ .set_scale = mode },
            .manga => |val| return .{ .set_manga_mode = val },
            .title => |action| switch (action) {
                .enable => return .{ .set_title = true },
                .disable => return .{ .set_title = false },
                .toggle => return .toggle_title,
            },
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

    /// Parses a raw IPC command line string into a strongly-typed `IpcCommand` enum.
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
        } else if (std.mem.eql(u8, cmd, "scale")) {
            const val = it.next() orelse return error.MissingArgument;
            if (std.mem.eql(u8, val, "fit_width") or std.mem.eql(u8, val, "width")) {
                return .{ .scale = .fit_width };
            } else if (std.mem.eql(u8, val, "fit_height") or std.mem.eql(u8, val, "height")) {
                return .{ .scale = .fit_height };
            } else if (std.meta.stringToEnum(intents.ScaleMode, val)) |mode| {
                return .{ .scale = mode };
            }
            return error.UnknownScale;
        } else if (std.mem.eql(u8, cmd, "manga")) {
            const val = it.next() orelse return error.MissingArgument;
            if (std.mem.eql(u8, val, "true")) {
                return .{ .manga = true };
            } else if (std.mem.eql(u8, val, "false")) {
                return .{ .manga = false };
            } else {
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, cmd, "title")) {
            if (it.next()) |val| {
                if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "enable") or std.mem.eql(u8, val, "on")) {
                    return .{ .title = .enable };
                } else if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "disable") or std.mem.eql(u8, val, "off")) {
                    return .{ .title = .disable };
                } else if (std.mem.eql(u8, val, "toggle")) {
                    return .{ .title = .toggle };
                } else {
                    return error.InvalidArgument;
                }
            } else {
                return .{ .title = .toggle };
            }
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

/// Sends an "OK\n" acknowledgment response over `stream` and terminates the client socket.
pub fn respondOk(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    var write_buf: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("OK\n");
    try writer.interface.flush();
}

/// Reads bytes from `socket` with a timeout until '\n' is encountered or the buffer fills.
/// Returns the slice up to '\n', or error.Timeout / error.BufferOverflow.
pub fn readLineTimeout(
    socket: *const std.Io.net.Socket,
    io: std.Io,
    buf: []u8,
    timeout_duration: std.Io.Clock.Duration,
) !?[]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const msg = socket.receiveTimeout(io, buf[len..], .{ .duration = timeout_duration }) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        if (msg.data.len == 0) {
            if (len == 0) return null;
            return buf[0..len];
        }
        if (std.mem.indexOfScalar(u8, msg.data, '\n')) |newline_offset| {
            const line_len = len + newline_offset;
            return buf[0..line_len];
        }
        len += msg.data.len;
    }
    return error.BufferOverflow;
}

test "IpcCommand parsing" {
    const cmd_zoom = try IpcCommand.parse("zoom 2.5");
    try std.testing.expectEqual(@as(f32, 2.5), cmd_zoom.zoom);

    const cmd_pan = try IpcCommand.parse("pan 100 -50");
    try std.testing.expectEqual(@as(f32, 100), cmd_pan.pan.x);
    try std.testing.expectEqual(@as(f32, -50), cmd_pan.pan.y);

    const cmd_filter = try IpcCommand.parse("filter mitchell");
    try std.testing.expectEqual(TextureScaleMode.mitchell, cmd_filter.filter);

    const cmd_lanczos3 = try IpcCommand.parse("filter lanczos3");
    try std.testing.expectEqual(TextureScaleMode.lanczos3, cmd_lanczos3.filter);

    const cmd_lanczos3_spline = try IpcCommand.parse("filter lanczos3_spline");
    try std.testing.expectEqual(TextureScaleMode.lanczos3_spline, cmd_lanczos3_spline.filter);

    const cmd_next = try IpcCommand.parse("next");
    try std.testing.expectEqual(IpcCommand.next, cmd_next);

    const cmd_title = try IpcCommand.parse("title true");
    try std.testing.expectEqual(TitleAction.enable, cmd_title.title);
    try std.testing.expectEqual(intents.AppIntent{ .set_title = true }, cmd_title.toIntent().?);

    const cmd_title_toggle = try IpcCommand.parse("title");
    try std.testing.expectEqual(TitleAction.toggle, cmd_title_toggle.title);
    try std.testing.expectEqual(intents.AppIntent.toggle_title, cmd_title_toggle.toIntent().?);

    const cmd_title_toggle_word = try IpcCommand.parse("title toggle");
    try std.testing.expectEqual(TitleAction.toggle, cmd_title_toggle_word.title);
    try std.testing.expectEqual(intents.AppIntent.toggle_title, cmd_title_toggle_word.toIntent().?);

    try std.testing.expectError(error.UnknownCommand, IpcCommand.parse("invalid_command"));
}

test "readLineTimeout - success and timeout" {
    if (builtin.os.tag == .windows) return;

    const io = std.Io.Threaded.global_single_threaded.io();
    const socket_path = "/tmp/peng_test_ipc_timeout.sock";
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, socket_path) catch {};
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, socket_path) catch {};

    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    const client = try addr.connect(io);
    defer client.close(io);

    var accepted = try server.accept(io);
    defer accepted.close(io);

    // Test timeout when no data is sent
    var buf: [128]u8 = undefined;
    const short_dur: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(20),
        .clock = .awake,
    };
    try std.testing.expectError(error.Timeout, readLineTimeout(&client.socket, io, &buf, short_dur));

    // Test successful read
    var write_buf: [64]u8 = undefined;
    var writer = accepted.writer(io, &write_buf);
    try writer.interface.writeAll("zoom 2.0\n");
    try writer.interface.flush();

    const long_dur: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromSeconds(2),
        .clock = .awake,
    };
    const line = (try readLineTimeout(&client.socket, io, &buf, long_dur)) orelse unreachable;
    try std.testing.expectEqualStrings("zoom 2.0", line);
}
