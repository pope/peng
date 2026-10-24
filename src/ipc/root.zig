const builtin = @import("builtin");
const intents = @import("intents");
const std = @import("std");

const TextureScaleMode = intents.TextureScaleMode;

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

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

/// Connects a short-lived dummy client to `sock_path` to unblock a blocking
/// `server.accept(io)` call during IPC server shutdown.
pub fn wakeSocketListener(io: std.Io, sock_path: []const u8) void {
    if (builtin.os.tag == .windows) return;
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
}

/// Context managing the background Unix domain socket IPC server listener and client connections.
pub const IpcServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,
    thread: ?std.Thread = null,

    /// Allocates and initializes an `IpcServer` instance with either an
    /// explicit custom socket path or `/tmp/peng-{pid}.sock`.
    pub fn init(
        allocator: std.mem.Allocator,
        custom_path: ?[]const u8,
    ) !*IpcServer {
        const sock_path = if (custom_path) |cp|
            try allocator.dupe(u8, cp)
        else blk: {
            const pid = getProcessId();
            var path_buf: [128]u8 = undefined;
            const formatted = try std.mem.print(
                &path_buf,
                "/tmp/peng-{d}.sock",
                .{pid},
            );
            break :blk try allocator.dupe(u8, formatted);
        };
        errdefer allocator.free(sock_path);

        const self = try allocator.create(IpcServer);
        self.* = .{
            .allocator = allocator,
            .socket_path = sock_path,
        };
        return self;
    }

    /// Connects a dummy socket to wake the listener thread, joins the listener
    /// thread, and destroys the server.
    pub fn deinit(self: *IpcServer, io: std.Io) void {
        if (self.thread) |t| {
            if (builtin.os.tag != .windows) {
                wakeSocketListener(io, self.socket_path);
            }
            t.join();
            self.thread = null;
        }
        self.allocator.free(self.socket_path);
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

pub const SnackbarAction = enum {
    enable,
    disable,
    toggle,
};

pub const WindowlessAction = enum {
    enable,
    disable,
    toggle,
};

pub const CrossfadeAction = enum {
    enable,
    disable,
    toggle,
};

pub const CompareAction = enum {
    enable,
    disable,
    toggle,
};

pub const EditAction = enum {
    enable,
    disable,
    toggle,
    reset,
};

pub const StackingAction = enum {
    enable,
    disable,
    toggle,
};

pub const IpcCommand = union(enum) {
    zoom: f32,
    pan: struct { x: f32, y: f32 },
    adjust: struct {
        brightness: f32,
        contrast: f32,
        contrast_blend: ?f32 = null,
    },
    tone: struct {
        highlights: f32,
        shadows: f32,
        whites: f32,
        blacks: f32,
    },
    color: struct {
        temperature: f32,
        tint: f32,
        vibrance: f32,
        saturation: f32,
    },
    presence: struct {
        clarity: f32,
        texture: f32,
    },
    clarity: f32,
    texture: f32,
    compare: CompareAction,
    edit: EditAction,
    filter: TextureScaleMode,
    scale: intents.ZoomPreset,
    manga: bool,
    title: TitleAction,
    snackbar: SnackbarAction,
    windowless: WindowlessAction,
    crossfade: CrossfadeAction,
    stack_raw_jpeg: StackingAction,
    toggle_stream,
    palette: PaletteTarget,
    thumb: ThumbAction,
    debug: bool,
    wait_load,
    reset_view,
    reset_adjustments,
    next,
    prev,
    pick,
    reject,
    unflag,
    view: intents.ViewMode,
    precache,
    quit,
    open: []const u8,
    screenshot: []const u8,

    /// Converts an IPC command variant into an `AppIntent`, or returns `null`
    /// for internal commands.
    pub fn toIntent(self: IpcCommand) ?intents.AppIntent {
        switch (self) {
            .zoom => |factor| return .{ .set_zoom = factor },
            .pan => |p| return .{ .set_pan = .{ .x = p.x, .y = p.y } },
            .adjust => return null,
            .tone => |t| return .{ .adjust = .{ .batch_tone = .{
                .highlights = t.highlights,
                .shadows = t.shadows,
                .whites = t.whites,
                .blacks = t.blacks,
            } } },
            .color => |c| return .{ .adjust = .{ .batch_color = .{
                .temperature = c.temperature,
                .tint = c.tint,
                .vibrance = c.vibrance,
                .saturation = c.saturation,
            } } },
            .presence => |p| return .{ .adjust = .{ .batch_presence = .{
                .clarity = p.clarity,
                .texture = p.texture,
            } } },
            .clarity => |val| return .{ .adjust = .{ .set = .{
                .param = .clarity,
                .value = val,
            } } },
            .texture => |val| return .{ .adjust = .{ .set = .{
                .param = .texture,
                .value = val,
            } } },
            .compare => |action| switch (action) {
                .enable => return .{ .adjust = .{ .set_compare = true } },
                .disable => return .{ .adjust = .{ .set_compare = false } },
                .toggle => return .{ .adjust = .toggle_compare },
            },
            .edit => |action| switch (action) {
                .enable => return .{ .set_edit_panel = true },
                .disable => return .{ .set_edit_panel = false },
                .toggle => return .toggle_edit_panel,
                .reset => return .{ .adjust = .reset_all },
            },
            .reset_view => return .reset_zoom,
            .reset_adjustments => return .{ .adjust = .reset_all },
            .filter => |mode| return .{ .set_filter = mode },
            .scale => |mode| return .{ .set_scale = mode },
            .manga => |val| return .{ .set_manga_mode = val },
            .title => |action| switch (action) {
                .enable => return .{ .set_title = true },
                .disable => return .{ .set_title = false },
                .toggle => return .toggle_title,
            },
            .snackbar => |action| switch (action) {
                .enable => return .{ .set_snackbar = true },
                .disable => return .{ .set_snackbar = false },
                .toggle => return .toggle_snackbar,
            },
            .windowless => |action| switch (action) {
                .enable => return .{ .set_windowless = true },
                .disable => return .{ .set_windowless = false },
                .toggle => return .toggle_windowless,
            },
            .crossfade => |action| switch (action) {
                .enable => return .{ .set_crossfade = true },
                .disable => return .{ .set_crossfade = false },
                .toggle => return .toggle_crossfade,
            },
            .stack_raw_jpeg => |action| switch (action) {
                .enable => return .{ .set_raw_jpeg_stacking = true },
                .disable => return .{ .set_raw_jpeg_stacking = false },
                .toggle => return .toggle_raw_jpeg_stacking,
            },
            .toggle_stream => return .toggle_pair_stream,
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
            .pick => return .mark_pick,
            .reject => return .mark_reject,
            .unflag => return .unflag,
            .view => |mode| return .{ .set_view_mode = mode },
            .precache => return .precache_directory,
            .quit => return .quit,
            .open => |p| return .{ .open_path = p },
            .wait_load, .screenshot => return null,
        }
    }

    fn isBoolOn(val: []const u8) bool {
        return std.mem.eql(u8, val, "true") or
            std.mem.eql(u8, val, "enable") or
            std.mem.eql(u8, val, "on");
    }

    fn isBoolOff(val: []const u8) bool {
        return std.mem.eql(u8, val, "false") or
            std.mem.eql(u8, val, "disable") or
            std.mem.eql(u8, val, "off");
    }

    /// Parses a raw IPC command line string into a strongly-typed `IpcCommand` enum.
    pub fn parse(command: []const u8) !IpcCommand {
        var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
        const cmd = it.next() orelse return error.UnknownCommand;

        if (std.mem.eql(u8, cmd, "zoom")) {
            const factor_str = it.next() orelse return error.MissingArgument;
            if (factor_str.len > 128) return error.InvalidArgument;
            const factor = try std.fmt.parseFloat(f32, factor_str);
            if (std.math.isNan(factor) or std.math.isInf(factor)) {
                return error.InvalidArgument;
            }
            return .{ .zoom = factor };
        } else if (std.mem.eql(u8, cmd, "pan")) {
            const px_str = it.next() orelse return error.MissingArgument;
            const py_str = it.next() orelse return error.MissingArgument;
            if (px_str.len > 128 or py_str.len > 128) return error.InvalidArgument;
            const px = try std.fmt.parseFloat(f32, px_str);
            const py = try std.fmt.parseFloat(f32, py_str);
            if (std.math.isNan(px) or std.math.isInf(px) or
                std.math.isNan(py) or std.math.isInf(py))
            {
                return error.InvalidArgument;
            }
            return .{ .pan = .{ .x = px, .y = py } };
        } else if (std.mem.eql(u8, cmd, "adjust")) {
            const br_str = it.next() orelse return error.MissingArgument;
            const co_str = it.next() orelse return error.MissingArgument;
            const blend_str = it.next();
            if (br_str.len > 128 or co_str.len > 128) return error.InvalidArgument;
            const br = try std.fmt.parseFloat(f32, br_str);
            const co = try std.fmt.parseFloat(f32, co_str);
            var blend: ?f32 = null;
            if (blend_str) |bs| {
                if (bs.len > 128) return error.InvalidArgument;
                const b_val = try std.fmt.parseFloat(f32, bs);
                if (std.math.isNan(b_val) or std.math.isInf(b_val)) {
                    return error.InvalidArgument;
                }
                blend = b_val;
            }
            if (std.math.isNan(br) or std.math.isInf(br) or
                std.math.isNan(co) or std.math.isInf(co))
            {
                return error.InvalidArgument;
            }
            return .{
                .adjust = .{
                    .brightness = br,
                    .contrast = co,
                    .contrast_blend = blend,
                },
            };
        } else if (std.mem.eql(u8, cmd, "tone")) {
            const hl_str = it.next() orelse return error.MissingArgument;
            const sh_str = it.next() orelse return error.MissingArgument;
            const wh_str = it.next() orelse return error.MissingArgument;
            const bl_str = it.next() orelse return error.MissingArgument;
            if (hl_str.len > 128 or
                sh_str.len > 128 or
                wh_str.len > 128 or
                bl_str.len > 128)
            {
                return error.InvalidArgument;
            }
            const hl = try std.fmt.parseFloat(f32, hl_str);
            const sh = try std.fmt.parseFloat(f32, sh_str);
            const wh = try std.fmt.parseFloat(f32, wh_str);
            const bl = try std.fmt.parseFloat(f32, bl_str);
            if (std.math.isNan(hl) or std.math.isInf(hl) or
                std.math.isNan(sh) or std.math.isInf(sh) or
                std.math.isNan(wh) or std.math.isInf(wh) or
                std.math.isNan(bl) or std.math.isInf(bl))
            {
                return error.InvalidArgument;
            }
            return .{
                .tone = .{
                    .highlights = hl,
                    .shadows = sh,
                    .whites = wh,
                    .blacks = bl,
                },
            };
        } else if (std.mem.eql(u8, cmd, "color")) {
            const temp_str = it.next() orelse return error.MissingArgument;
            const tint_str = it.next() orelse return error.MissingArgument;
            const vib_str = it.next() orelse return error.MissingArgument;
            const sat_str = it.next() orelse return error.MissingArgument;
            if (temp_str.len > 128 or
                tint_str.len > 128 or
                vib_str.len > 128 or
                sat_str.len > 128)
            {
                return error.InvalidArgument;
            }
            const temp = try std.fmt.parseFloat(f32, temp_str);
            const tint = try std.fmt.parseFloat(f32, tint_str);
            const vib = try std.fmt.parseFloat(f32, vib_str);
            const sat = try std.fmt.parseFloat(f32, sat_str);
            if (std.math.isNan(temp) or std.math.isInf(temp) or
                std.math.isNan(tint) or std.math.isInf(tint) or
                std.math.isNan(vib) or std.math.isInf(vib) or
                std.math.isNan(sat) or std.math.isInf(sat))
            {
                return error.InvalidArgument;
            }
            return .{
                .color = .{
                    .temperature = temp,
                    .tint = tint,
                    .vibrance = vib,
                    .saturation = sat,
                },
            };
        } else if (std.mem.eql(u8, cmd, "presence")) {
            const clar_str = it.next() orelse return error.MissingArgument;
            const tex_str = it.next() orelse return error.MissingArgument;
            if (clar_str.len > 128 or tex_str.len > 128) {
                return error.InvalidArgument;
            }
            const clar = try std.fmt.parseFloat(f32, clar_str);
            const tex = try std.fmt.parseFloat(f32, tex_str);
            if (std.math.isNan(clar) or std.math.isInf(clar) or
                std.math.isNan(tex) or std.math.isInf(tex))
            {
                return error.InvalidArgument;
            }
            return .{
                .presence = .{
                    .clarity = clar,
                    .texture = tex,
                },
            };
        } else if (std.mem.eql(u8, cmd, "clarity")) {
            const val_str = it.next() orelse return error.MissingArgument;
            if (val_str.len > 128) return error.InvalidArgument;
            const val = try std.fmt.parseFloat(f32, val_str);
            if (std.math.isNan(val) or std.math.isInf(val)) {
                return error.InvalidArgument;
            }
            return .{ .clarity = val };
        } else if (std.mem.eql(u8, cmd, "texture")) {
            const val_str = it.next() orelse return error.MissingArgument;
            if (val_str.len > 128) return error.InvalidArgument;
            const val = try std.fmt.parseFloat(f32, val_str);
            if (std.math.isNan(val) or std.math.isInf(val)) {
                return error.InvalidArgument;
            }
            return .{ .texture = val };
        } else if (std.mem.eql(u8, cmd, "filter")) {
            const val = it.next() orelse return error.MissingArgument;
            if (std.meta.stringToEnum(TextureScaleMode, val)) |mode| {
                return .{ .filter = mode };
            }
            return error.UnknownFilter;
        } else if (std.mem.eql(u8, cmd, "scale")) {
            const val = it.next() orelse return error.MissingArgument;
            if (intents.ZoomPreset.parse(val)) |mode| {
                return .{ .scale = mode };
            }
            return error.UnknownScale;
        } else if (std.mem.eql(u8, cmd, "manga")) {
            const val = it.next() orelse return error.MissingArgument;
            if (isBoolOn(val)) {
                return .{ .manga = true };
            } else if (isBoolOff(val)) {
                return .{ .manga = false };
            } else {
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, cmd, "edit")) {
            if (it.next()) |val| {
                if (isBoolOn(val)) {
                    return .{ .edit = .enable };
                } else if (isBoolOff(val)) {
                    return .{ .edit = .disable };
                } else if (std.mem.eql(u8, val, "toggle")) {
                    return .{ .edit = .toggle };
                } else if (std.mem.eql(u8, val, "reset")) {
                    return .{ .edit = .reset };
                } else {
                    return error.InvalidArgument;
                }
            } else {
                return .{ .edit = .toggle };
            }
        } else if (std.mem.eql(u8, cmd, "title")) {
            if (it.next()) |val| {
                if (isBoolOn(val)) {
                    return .{ .title = .enable };
                } else if (isBoolOff(val)) {
                    return .{ .title = .disable };
                } else if (std.mem.eql(u8, val, "toggle")) {
                    return .{ .title = .toggle };
                } else {
                    return error.InvalidArgument;
                }
            } else {
                return .{ .title = .toggle };
            }
        } else if (std.mem.eql(u8, cmd, "snackbar")) {
            if (it.next()) |val| {
                if (isBoolOn(val)) {
                    return .{ .snackbar = .enable };
                } else if (isBoolOff(val)) {
                    return .{ .snackbar = .disable };
                } else if (std.mem.eql(u8, val, "toggle")) {
                    return .{ .snackbar = .toggle };
                } else {
                    return error.InvalidArgument;
                }
            } else {
                return .{ .snackbar = .toggle };
            }
        } else if (std.mem.eql(u8, cmd, "windowless") or std.mem.eql(u8, cmd, "borderless")) {
            if (it.next()) |val| {
                if (isBoolOn(val)) {
                    return .{ .windowless = .enable };
                } else if (isBoolOff(val)) {
                    return .{ .windowless = .disable };
                } else if (std.mem.eql(u8, val, "toggle")) {
                    return .{ .windowless = .toggle };
                } else {
                    return error.InvalidArgument;
                }
            } else {
                return .{ .windowless = .toggle };
            }
        } else if (std.mem.eql(u8, cmd, "crossfade")) {
            if (it.next()) |val| {
                if (isBoolOn(val)) {
                    return .{ .crossfade = .enable };
                } else if (isBoolOff(val)) {
                    return .{ .crossfade = .disable };
                } else if (std.mem.eql(u8, val, "toggle")) {
                    return .{ .crossfade = .toggle };
                } else {
                    return error.InvalidArgument;
                }
            } else {
                return .{ .crossfade = .toggle };
            }
        } else if (std.mem.eql(u8, cmd, "stack_raw_jpeg")) {
            if (it.next()) |val| {
                if (isBoolOn(val)) {
                    return .{ .stack_raw_jpeg = .enable };
                } else if (isBoolOff(val)) {
                    return .{ .stack_raw_jpeg = .disable };
                } else if (std.mem.eql(u8, val, "toggle")) {
                    return .{ .stack_raw_jpeg = .toggle };
                } else {
                    return error.InvalidArgument;
                }
            } else {
                return .{ .stack_raw_jpeg = .toggle };
            }
        } else if (std.mem.eql(u8, cmd, "toggle_stream") or std.mem.eql(u8, cmd, "stream")) {
            return .toggle_stream;
        } else if (std.mem.eql(u8, cmd, "compare")) {
            if (it.next()) |val| {
                if (isBoolOn(val)) {
                    return .{ .compare = .enable };
                } else if (isBoolOff(val)) {
                    return .{ .compare = .disable };
                } else if (std.mem.eql(u8, val, "toggle")) {
                    return .{ .compare = .toggle };
                } else {
                    return error.InvalidArgument;
                }
            } else {
                return .{ .compare = .toggle };
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
            const raw_rest = std.mem.trim(u8, it.rest(), " \t\r\n");
            const query_opt: ?[]const u8 = if (raw_rest.len > 0)
                raw_rest
            else
                null;
            return .{ .palette = .{ .kind = kind, .query = query_opt } };
        } else if (std.mem.eql(u8, cmd, "thumb")) {
            if (it.next()) |val| {
                if (isBoolOn(val)) {
                    return .{ .thumb = .enable };
                } else if (isBoolOff(val)) {
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
            if (isBoolOn(val)) {
                return .{ .debug = true };
            } else if (isBoolOff(val)) {
                return .{ .debug = false };
            } else {
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, cmd, "wait_load")) {
            return .wait_load;
        } else if (std.mem.eql(u8, cmd, "reset_view") or std.mem.eql(u8, cmd, "reset")) {
            return .reset_view;
        } else if (std.mem.eql(u8, cmd, "reset_adjustments")) {
            return .reset_adjustments;
        } else if (std.mem.eql(u8, cmd, "next")) {
            return .next;
        } else if (std.mem.eql(u8, cmd, "prev")) {
            return .prev;
        } else if (std.mem.eql(u8, cmd, "pick")) {
            return .pick;
        } else if (std.mem.eql(u8, cmd, "reject")) {
            return .reject;
        } else if (std.mem.eql(u8, cmd, "unflag")) {
            return .unflag;
        } else if (std.mem.eql(u8, cmd, "view")) {
            const val = it.next() orelse return error.MissingArgument;
            if (std.meta.stringToEnum(intents.ViewMode, val)) |mode| {
                return .{ .view = mode };
            }
            return error.UnknownViewMode;
        } else if (std.mem.eql(u8, cmd, "open")) {
            const filepath = std.mem.trim(u8, it.rest(), " \t\r\n");
            if (filepath.len == 0) return error.MissingArgument;
            if (filepath.len > std.Io.Dir.max_path_bytes) {
                return error.PathTooLong;
            }
            return .{ .open = filepath };
        } else if (std.mem.eql(u8, cmd, "screenshot")) {
            const filepath = std.mem.trim(u8, it.rest(), " \t\r\n");
            if (filepath.len == 0) return error.MissingArgument;
            if (filepath.len > 512) return error.PathTooLong;
            return .{ .screenshot = filepath };
        } else if (std.mem.eql(u8, cmd, "precache")) {
            return .precache;
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
        const msg = socket.receiveTimeout(
            io,
            buf[len..],
            .{ .duration = timeout_duration },
        ) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        if (msg.data.len == 0) {
            if (len == 0) return null;
            return buf[0..len];
        }
        if (std.mem.findScalar(u8, msg.data, '\n')) |newline_offset| {
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

    const cmd_fsr = try IpcCommand.parse("filter fsr");
    try std.testing.expectEqual(TextureScaleMode.fsr, cmd_fsr.filter);

    const cmd_tiny_cnn = try IpcCommand.parse("filter tiny_cnn");
    try std.testing.expectEqual(TextureScaleMode.tiny_cnn, cmd_tiny_cnn.filter);

    const cmd_next = try IpcCommand.parse("next");
    try std.testing.expectEqual(IpcCommand.next, cmd_next);

    const cmd_pick = try IpcCommand.parse("pick");
    try std.testing.expectEqual(IpcCommand.pick, cmd_pick);
    try std.testing.expectEqual(intents.AppIntent.mark_pick, cmd_pick.toIntent().?);

    const cmd_reject = try IpcCommand.parse("reject");
    try std.testing.expectEqual(IpcCommand.reject, cmd_reject);
    try std.testing.expectEqual(intents.AppIntent.mark_reject, cmd_reject.toIntent().?);

    const cmd_unflag = try IpcCommand.parse("unflag");
    try std.testing.expectEqual(IpcCommand.unflag, cmd_unflag);
    try std.testing.expectEqual(intents.AppIntent.unflag, cmd_unflag.toIntent().?);

    const cmd_view_picks = try IpcCommand.parse("view picks");
    try std.testing.expectEqual(intents.ViewMode.picks, cmd_view_picks.view);
    try std.testing.expectEqual(intents.AppIntent{ .set_view_mode = .picks }, cmd_view_picks.toIntent().?);

    const cmd_reset_view = try IpcCommand.parse("reset_view");
    try std.testing.expectEqual(IpcCommand.reset_view, cmd_reset_view);
    try std.testing.expectEqual(intents.AppIntent.reset_zoom, cmd_reset_view.toIntent().?);

    const cmd_reset = try IpcCommand.parse("reset");
    try std.testing.expectEqual(IpcCommand.reset_view, cmd_reset);
    try std.testing.expectEqual(intents.AppIntent.reset_zoom, cmd_reset.toIntent().?);

    const cmd_reset_adjustments = try IpcCommand.parse("reset_adjustments");
    try std.testing.expectEqual(IpcCommand.reset_adjustments, cmd_reset_adjustments);
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .reset_all },
        cmd_reset_adjustments.toIntent().?,
    );

    const cmd_title = try IpcCommand.parse("title true");
    try std.testing.expectEqual(TitleAction.enable, cmd_title.title);
    try std.testing.expectEqual(intents.AppIntent{ .set_title = true }, cmd_title.toIntent().?);

    const cmd_title_toggle = try IpcCommand.parse("title");
    try std.testing.expectEqual(TitleAction.toggle, cmd_title_toggle.title);
    try std.testing.expectEqual(intents.AppIntent.toggle_title, cmd_title_toggle.toIntent().?);

    const cmd_title_toggle_word = try IpcCommand.parse("title toggle");
    try std.testing.expectEqual(TitleAction.toggle, cmd_title_toggle_word.title);
    try std.testing.expectEqual(intents.AppIntent.toggle_title, cmd_title_toggle_word.toIntent().?);

    const cmd_snackbar = try IpcCommand.parse("snackbar true");
    try std.testing.expectEqual(SnackbarAction.enable, cmd_snackbar.snackbar);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_snackbar = true },
        cmd_snackbar.toIntent().?,
    );

    const cmd_snackbar_toggle = try IpcCommand.parse("snackbar");
    try std.testing.expectEqual(SnackbarAction.toggle, cmd_snackbar_toggle.snackbar);
    try std.testing.expectEqual(
        intents.AppIntent.toggle_snackbar,
        cmd_snackbar_toggle.toIntent().?,
    );

    const cmd_snackbar_disable = try IpcCommand.parse("snackbar off");
    try std.testing.expectEqual(SnackbarAction.disable, cmd_snackbar_disable.snackbar);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_snackbar = false },
        cmd_snackbar_disable.toIntent().?,
    );

    const cmd_wl_true = try IpcCommand.parse("windowless true");
    try std.testing.expectEqual(WindowlessAction.enable, cmd_wl_true.windowless);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_windowless = true },
        cmd_wl_true.toIntent().?,
    );

    const cmd_wl_false = try IpcCommand.parse("windowless false");
    try std.testing.expectEqual(WindowlessAction.disable, cmd_wl_false.windowless);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_windowless = false },
        cmd_wl_false.toIntent().?,
    );

    const cmd_wl_toggle = try IpcCommand.parse("windowless");
    try std.testing.expectEqual(WindowlessAction.toggle, cmd_wl_toggle.windowless);
    try std.testing.expectEqual(
        intents.AppIntent.toggle_windowless,
        cmd_wl_toggle.toIntent().?,
    );

    const cmd_bl_toggle_word = try IpcCommand.parse("borderless toggle");
    try std.testing.expectEqual(WindowlessAction.toggle, cmd_bl_toggle_word.windowless);
    try std.testing.expectEqual(
        intents.AppIntent.toggle_windowless,
        cmd_bl_toggle_word.toIntent().?,
    );

    const cmd_bl_on = try IpcCommand.parse("borderless on");
    try std.testing.expectEqual(WindowlessAction.enable, cmd_bl_on.windowless);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_windowless = true },
        cmd_bl_on.toIntent().?,
    );

    const cmd_cf_true = try IpcCommand.parse("crossfade true");
    try std.testing.expectEqual(CrossfadeAction.enable, cmd_cf_true.crossfade);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_crossfade = true },
        cmd_cf_true.toIntent().?,
    );

    const cmd_cf_off = try IpcCommand.parse("crossfade off");
    try std.testing.expectEqual(CrossfadeAction.disable, cmd_cf_off.crossfade);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_crossfade = false },
        cmd_cf_off.toIntent().?,
    );

    const cmd_cf_toggle = try IpcCommand.parse("crossfade");
    try std.testing.expectEqual(CrossfadeAction.toggle, cmd_cf_toggle.crossfade);
    try std.testing.expectEqual(
        intents.AppIntent.toggle_crossfade,
        cmd_cf_toggle.toIntent().?,
    );

    const cmd_cf_toggle_word = try IpcCommand.parse("crossfade toggle");
    try std.testing.expectEqual(CrossfadeAction.toggle, cmd_cf_toggle_word.crossfade);
    try std.testing.expectEqual(
        intents.AppIntent.toggle_crossfade,
        cmd_cf_toggle_word.toIntent().?,
    );

    const cmd_stack_true = try IpcCommand.parse("stack_raw_jpeg true");
    try std.testing.expectEqual(StackingAction.enable, cmd_stack_true.stack_raw_jpeg);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_raw_jpeg_stacking = true },
        cmd_stack_true.toIntent().?,
    );

    const cmd_stack_off = try IpcCommand.parse("stack_raw_jpeg off");
    try std.testing.expectEqual(StackingAction.disable, cmd_stack_off.stack_raw_jpeg);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_raw_jpeg_stacking = false },
        cmd_stack_off.toIntent().?,
    );

    const cmd_stack_toggle = try IpcCommand.parse("stack_raw_jpeg");
    try std.testing.expectEqual(StackingAction.toggle, cmd_stack_toggle.stack_raw_jpeg);
    try std.testing.expectEqual(
        intents.AppIntent.toggle_raw_jpeg_stacking,
        cmd_stack_toggle.toIntent().?,
    );

    const cmd_stream = try IpcCommand.parse("stream");
    try std.testing.expectEqual(IpcCommand.toggle_stream, cmd_stream);
    try std.testing.expectEqual(
        intents.AppIntent.toggle_pair_stream,
        cmd_stream.toIntent().?,
    );

    const cmd_cmp_true = try IpcCommand.parse("compare true");
    try std.testing.expectEqual(CompareAction.enable, cmd_cmp_true.compare);
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .{ .set_compare = true } },
        cmd_cmp_true.toIntent().?,
    );

    const cmd_cmp_off = try IpcCommand.parse("compare off");
    try std.testing.expectEqual(CompareAction.disable, cmd_cmp_off.compare);
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .{ .set_compare = false } },
        cmd_cmp_off.toIntent().?,
    );

    const cmd_cmp_toggle = try IpcCommand.parse("compare");
    try std.testing.expectEqual(CompareAction.toggle, cmd_cmp_toggle.compare);
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .toggle_compare },
        cmd_cmp_toggle.toIntent().?,
    );

    const cmd_cmp_toggle_word = try IpcCommand.parse("compare toggle");
    try std.testing.expectEqual(CompareAction.toggle, cmd_cmp_toggle_word.compare);
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .toggle_compare },
        cmd_cmp_toggle_word.toIntent().?,
    );

    const cmd_edit_true = try IpcCommand.parse("edit on");
    try std.testing.expectEqual(EditAction.enable, cmd_edit_true.edit);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_edit_panel = true },
        cmd_edit_true.toIntent().?,
    );

    const cmd_edit_off = try IpcCommand.parse("edit off");
    try std.testing.expectEqual(EditAction.disable, cmd_edit_off.edit);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_edit_panel = false },
        cmd_edit_off.toIntent().?,
    );

    const cmd_edit_toggle = try IpcCommand.parse("edit");
    try std.testing.expectEqual(EditAction.toggle, cmd_edit_toggle.edit);
    try std.testing.expectEqual(
        intents.AppIntent.toggle_edit_panel,
        cmd_edit_toggle.toIntent().?,
    );

    const cmd_edit_reset = try IpcCommand.parse("edit reset");
    try std.testing.expectEqual(EditAction.reset, cmd_edit_reset.edit);
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .reset_all },
        cmd_edit_reset.toIntent().?,
    );

    const cmd_tone = try IpcCommand.parse("tone 0.1 -0.2 0.3 -0.4");
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .{ .batch_tone = .{
            .highlights = 0.1,
            .shadows = -0.2,
            .whites = 0.3,
            .blacks = -0.4,
        } } },
        cmd_tone.toIntent().?,
    );

    const cmd_color = try IpcCommand.parse("color 0.5 -0.1 0.25 -0.35");
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .{ .batch_color = .{
            .temperature = 0.5,
            .tint = -0.1,
            .vibrance = 0.25,
            .saturation = -0.35,
        } } },
        cmd_color.toIntent().?,
    );

    const cmd_presence = try IpcCommand.parse("presence 0.35 -0.2");
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .{ .batch_presence = .{
            .clarity = 0.35,
            .texture = -0.2,
        } } },
        cmd_presence.toIntent().?,
    );

    const cmd_clarity = try IpcCommand.parse("clarity 0.45");
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .{ .set = .{
            .param = .clarity,
            .value = 0.45,
        } } },
        cmd_clarity.toIntent().?,
    );

    const cmd_texture = try IpcCommand.parse("texture -0.5");
    try std.testing.expectEqual(
        intents.AppIntent{ .adjust = .{ .set = .{
            .param = .texture,
            .value = -0.5,
        } } },
        cmd_texture.toIntent().?,
    );

    const cmd_adj_2 = try IpcCommand.parse("adjust 0.2 1.5");
    try std.testing.expectEqual(@as(f32, 0.2), cmd_adj_2.adjust.brightness);
    try std.testing.expectEqual(@as(f32, 1.5), cmd_adj_2.adjust.contrast);
    try std.testing.expectEqual(
        @as(?f32, null),
        cmd_adj_2.adjust.contrast_blend,
    );

    const cmd_adj_3 = try IpcCommand.parse("adjust 0.2 1.5 0.8");
    try std.testing.expectEqual(@as(f32, 0.2), cmd_adj_3.adjust.brightness);
    try std.testing.expectEqual(@as(f32, 1.5), cmd_adj_3.adjust.contrast);
    try std.testing.expectEqual(
        @as(?f32, 0.8),
        cmd_adj_3.adjust.contrast_blend,
    );

    const cmd_pal_query = try IpcCommand.parse(
        "palette actions Set Contrast Blend\n",
    );
    try std.testing.expectEqual(
        PaletteKind.actions,
        cmd_pal_query.palette.kind,
    );
    try std.testing.expectEqualStrings(
        "Set Contrast Blend",
        cmd_pal_query.palette.query.?,
    );

    const cmd_screenshot_spaces = try IpcCommand.parse(
        "screenshot /tmp/my folder/screen shot.png\n",
    );
    try std.testing.expectEqualStrings(
        "/tmp/my folder/screen shot.png",
        cmd_screenshot_spaces.screenshot,
    );
    try std.testing.expectError(
        error.MissingArgument,
        IpcCommand.parse("screenshot   \n"),
    );

    const cmd_open_spaces = try IpcCommand.parse(
        "open /tmp/my photos/IMG 0001.JPG\n",
    );
    try std.testing.expectEqualStrings(
        "/tmp/my photos/IMG 0001.JPG",
        cmd_open_spaces.open,
    );
    try std.testing.expectEqualStrings(
        "/tmp/my photos/IMG 0001.JPG",
        cmd_open_spaces.toIntent().?.open_path,
    );
    try std.testing.expectError(
        error.MissingArgument,
        IpcCommand.parse("open   \n"),
    );

    const srv_default = try IpcServer.init(std.testing.allocator, null);
    defer srv_default.deinit(std.Io.Threaded.global_single_threaded.io());
    try std.testing.expect(std.mem.startsWith(
        u8,
        srv_default.socket_path,
        "/tmp/peng-",
    ));

    const srv_custom = try IpcServer.init(
        std.testing.allocator,
        "/tmp/custom-peng.sock",
    );
    defer srv_custom.deinit(std.Io.Threaded.global_single_threaded.io());
    try std.testing.expectEqualStrings(
        "/tmp/custom-peng.sock",
        srv_custom.socket_path,
    );

    const cmd_manga_on = try IpcCommand.parse("manga on");
    try std.testing.expect(cmd_manga_on.manga);
    const cmd_thumb_off = try IpcCommand.parse("thumb off");
    try std.testing.expectEqual(ThumbAction.disable, cmd_thumb_off.thumb);
    const cmd_debug_enable = try IpcCommand.parse("debug enable");
    try std.testing.expect(cmd_debug_enable.debug);
    const cmd_precache = try IpcCommand.parse("precache");
    try std.testing.expectEqual(
        intents.AppIntent.precache_directory,
        cmd_precache.toIntent().?,
    );

    try std.testing.expectError(error.UnknownCommand, IpcCommand.parse("invalid_command"));
}

test "readLineTimeout - success and timeout" {
    if (builtin.os.tag == .windows) return;

    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const socket_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/timeout.sock",
        .{tmp.sub_path},
    );

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
    try std.testing.expectError(
        error.Timeout,
        readLineTimeout(&client.socket, io, &buf, short_dur),
    );

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
