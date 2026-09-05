const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const intents = @import("intents");
const TextureScaleMode = intents.TextureScaleMode;

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

    pub fn init(allocator: std.mem.Allocator) !*IpcServer {
        const self = try allocator.create(IpcServer);
        self.* = .{
            .allocator = allocator,
        };
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
    scale: intents.ScaleMode,
    manga: bool,
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
            .scale => |mode| return .{ .set_scale = mode },
            .manga => |val| return .{ .set_manga_mode = val },
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

    const cmd_lanczos3 = try IpcCommand.parse("filter lanczos3");
    try std.testing.expectEqual(TextureScaleMode.lanczos3, cmd_lanczos3.filter);

    const cmd_lanczos3_spline = try IpcCommand.parse("filter lanczos3_spline");
    try std.testing.expectEqual(TextureScaleMode.lanczos3_spline, cmd_lanczos3_spline.filter);

    const cmd_next = try IpcCommand.parse("next");
    try std.testing.expectEqual(IpcCommand.next, cmd_next);

    try std.testing.expectError(error.UnknownCommand, IpcCommand.parse("invalid_command"));
}
