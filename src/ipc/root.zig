const builtin = @import("builtin");
const geom = @import("geom");
const intents = @import("intents");
const std = @import("std");
const triage = @import("triage");

const PhysicalPoint = geom.PhysicalPoint;
const PositiveDimsU32 = geom.PositiveDimsU32;
const TextureScaleMode = intents.TextureScaleMode;
const ViewMode = triage.ViewMode;

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

fn getProcessId() u32 {
    if (builtin.os.tag == .windows) {
        return GetCurrentProcessId();
    } else {
        return @intCast(std.posix.system.getpid());
    }
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) {
        end -= 1;
    }
    return path[0..end];
}

/// Resolves the default Unix domain socket path from the process environment:
/// 1. `$XDG_RUNTIME_DIR/peng.sock`
/// 2. `/tmp/peng-$UID.sock`
/// 3. On macOS: `$TMPDIR/peng.sock`; on Windows: `%TEMP%\peng.sock`
/// Returns `error.MissingSocketEnv` if none of the environment variables are
/// present, or `error.InvalidSocketPath` if the path exceeds socket limits.
pub fn resolveDefaultSocketPath(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]u8 {
    if (environ_map.get("XDG_RUNTIME_DIR")) |raw_xdg| {
        const xdg = std.mem.trim(u8, raw_xdg, " \t\r\n");
        if (xdg.len > 0) {
            const clean = trimTrailingSeparators(xdg);
            const joined = try allocator.print("{s}/peng.sock", .{clean});
            errdefer allocator.free(joined);
            if (joined.len >= 104) return error.InvalidSocketPath;
            return joined;
        }
    }

    if (environ_map.get("UID")) |raw_uid| {
        const uid = std.mem.trim(u8, raw_uid, " \t\r\n");
        if (uid.len > 0) {
            const joined = try allocator.print("/tmp/peng-{s}.sock", .{uid});
            errdefer allocator.free(joined);
            if (joined.len >= 104) return error.InvalidSocketPath;
            return joined;
        }
    }

    if (builtin.os.tag == .macos) {
        if (environ_map.get("TMPDIR")) |raw_tmp| {
            const tmp = std.mem.trim(u8, raw_tmp, " \t\r\n");
            if (tmp.len > 0) {
                const clean = trimTrailingSeparators(tmp);
                const joined = try allocator.print("{s}/peng.sock", .{clean});
                errdefer allocator.free(joined);
                if (joined.len >= 104) return error.InvalidSocketPath;
                return joined;
            }
        }
    } else if (builtin.os.tag == .windows) {
        if (environ_map.get("TEMP") orelse environ_map.get("TMP")) |raw_tmp| {
            const tmp = std.mem.trim(u8, raw_tmp, " \t\r\n");
            if (tmp.len > 0) {
                const clean = trimTrailingSeparators(tmp);
                const joined = try allocator.print("{s}\\peng.sock", .{clean});
                errdefer allocator.free(joined);
                if (joined.len >= 104) return error.InvalidSocketPath;
                return joined;
            }
        }
    }

    return error.MissingSocketEnv;
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

/// Parameters for a terminal Kitty graphics preview request (`preview`).
pub const PreviewRequest = struct {
    max_dims: PositiveDimsU32 = .{ .w = 800, .h = 600 },
    clear_first: bool = false,
    path: []const u8,
};

pub const IpcCommand = union(enum) {
    zoom: f32,
    pan: PhysicalPoint,
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
    set_param: struct {
        param: intents.EditParam,
        value: f32,
    },
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
    selections,
    clear_selections,
    view: ViewMode,
    precache,
    close,
    quit,
    open: ?[]const u8,
    preview: PreviewRequest,
    screenshot: []const u8,

    /// Converts an IPC command variant into an `AppIntent`, or returns `null`
    /// for internal commands.
    pub fn toIntent(self: IpcCommand) ?intents.AppIntent {
        switch (self) {
            .zoom => |factor| return .{ .set_zoom = factor },
            .pan => |p| return .{ .set_pan = p },
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
            .set_param => |sp| return .{ .adjust = .{ .set = .{
                .param = sp.param,
                .value = sp.value,
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
            .clear_selections => return .clear_classifications,
            .view => |mode| return .{ .set_view_mode = mode },
            .precache => return .precache_directory,
            .close => return .quit,
            .quit => return .quit_server,
            .open => |p_opt| return if (p_opt) |p|
                .{ .open_path = p }
            else
                .open_window,
            .wait_load, .screenshot, .selections, .preview => return null,
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
        } else if (intents.fromSlug(cmd)) |param| {
            const val_str = it.next() orelse return error.MissingArgument;
            if (val_str.len > 128) return error.InvalidArgument;
            const val = try std.fmt.parseFloat(f32, val_str);
            if (std.math.isNan(val) or std.math.isInf(val)) {
                return error.InvalidArgument;
            }
            if (it.next() != null) return error.InvalidArgument;
            const spec = intents.getSpec(param);
            return .{
                .set_param = .{
                    .param = param,
                    .value = spec.clamp(val),
                },
            };
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
        } else if (std.mem.eql(u8, cmd, "selections") or
            std.mem.eql(u8, cmd, "list_selections"))
        {
            return .selections;
        } else if (std.mem.eql(u8, cmd, "clear_selections") or
            std.mem.eql(u8, cmd, "clear_flags"))
        {
            return .clear_selections;
        } else if (std.mem.eql(u8, cmd, "view")) {
            const val = it.next() orelse return error.MissingArgument;
            if (std.meta.stringToEnum(ViewMode, val)) |mode| {
                return .{ .view = mode };
            }
            return error.UnknownViewMode;
        } else if (std.mem.eql(u8, cmd, "open")) {
            const filepath = std.mem.trim(u8, it.rest(), " \t\r\n");
            if (filepath.len == 0) return .{ .open = null };
            if (filepath.len > std.Io.Dir.max_path_bytes) {
                return error.PathTooLong;
            }
            return .{ .open = filepath };
        } else if (std.mem.eql(u8, cmd, "preview") or
            std.mem.eql(u8, cmd, "preview-kitty") or
            std.mem.eql(u8, cmd, "preview-clear") or
            std.mem.eql(u8, cmd, "preview_clear") or
            std.mem.eql(u8, cmd, "clear-and-preview"))
        {
            var clear_first = std.mem.eql(u8, cmd, "preview-clear") or
                std.mem.eql(u8, cmd, "preview_clear") or
                std.mem.eql(u8, cmd, "clear-and-preview");

            var sub_it = it;
            if (sub_it.next()) |first_tok| {
                const is_flag = std.mem.eql(u8, first_tok, "--clear") or
                    std.mem.eql(u8, first_tok, "-c");
                const is_word = std.mem.eql(u8, first_tok, "clear");
                const after_clear = std.mem.trim(u8, sub_it.rest(), " \t\r\n");
                if (is_flag or (is_word and after_clear.len > 0)) {
                    clear_first = true;
                    it = sub_it;
                }
            }

            const full_rest = std.mem.trim(u8, it.rest(), " \t\r\n");
            if (full_rest.len == 0) return error.MissingArgument;

            var max_dims: PositiveDimsU32 = .{ .w = 800, .h = 600 };
            var filepath: []const u8 = full_rest;

            if (it.next()) |tok1| {
                if (it.next()) |tok2| {
                    if (std.fmt.parseInt(i64, tok1, 10)) |w_i| {
                        if (std.fmt.parseInt(i64, tok2, 10)) |h_i| {
                            const after_dims = std.mem.trim(
                                u8,
                                it.rest(),
                                " \t\r\n",
                            );
                            if (after_dims.len == 0) {
                                return error.MissingArgument;
                            }
                            max_dims = PositiveDimsU32.initClamped(
                                w_i,
                                h_i,
                                4096,
                            ) orelse return error.InvalidArgument;
                            filepath = after_dims;
                        } else |_| {}
                    } else |_| {}
                }
            }
            if (filepath.len > std.Io.Dir.max_path_bytes) {
                return error.PathTooLong;
            }
            return .{
                .preview = .{
                    .max_dims = max_dims,
                    .clear_first = clear_first,
                    .path = filepath,
                },
            };
        } else if (std.mem.eql(u8, cmd, "screenshot")) {
            const filepath = std.mem.trim(u8, it.rest(), " \t\r\n");
            if (filepath.len == 0) return error.MissingArgument;
            if (filepath.len > 512) return error.PathTooLong;
            return .{ .screenshot = filepath };
        } else if (std.mem.eql(u8, cmd, "precache")) {
            return .precache;
        } else if (std.mem.eql(u8, cmd, "close") or
            std.mem.eql(u8, cmd, "hide"))
        {
            return .close;
        } else if (std.mem.eql(u8, cmd, "quit") or
            std.mem.eql(u8, cmd, "quit_server") or
            std.mem.eql(u8, cmd, "shutdown"))
        {
            return .quit;
        } else {
            return error.UnknownCommand;
        }
    }

    /// Returns `true` if this IPC command may be executed while the resident
    /// server window is hidden (`open`, `preview`, `selections`,
    /// `clear_selections`, `close`, `quit`).
    pub fn isAllowedWhenHidden(self: IpcCommand) bool {
        return switch (self) {
            .open,
            .preview,
            .selections,
            .clear_selections,
            .close,
            .quit,
            => true,
            .wait_load,
            .zoom,
            .pan,
            .adjust,
            .tone,
            .color,
            .presence,
            .set_param,
            .compare,
            .edit,
            .filter,
            .scale,
            .manga,
            .title,
            .snackbar,
            .windowless,
            .crossfade,
            .stack_raw_jpeg,
            .toggle_stream,
            .palette,
            .thumb,
            .debug,
            .screenshot,
            .reset_view,
            .reset_adjustments,
            .next,
            .prev,
            .pick,
            .reject,
            .unflag,
            .view,
            .precache,
            => false,
        };
    }
};

/// Validated preview payload returned inside an `IpcResponse`.
pub const PreviewPayload = struct {
    path: []const u8,
    dims: PositiveDimsU32,
};

/// Structured JSON response payload returned by the IPC server.
pub const IpcResponse = struct {
    ok: bool,
    @"error": ?[]const u8 = null,
    picks: ?[]const []const u8 = null,
    rejects: ?[]const []const u8 = null,
    path: ?[]const u8 = null,
    w: ?u32 = null,
    h: ?u32 = null,

    /// Returns the validated preview payload when `ok` is true and `path`,
    /// `w`, and `h` are all present and strictly positive.
    pub fn getPreview(self: IpcResponse) ?PreviewPayload {
        if (!self.ok) return null;
        const p = self.path orelse return null;
        const width = self.w orelse return null;
        const height = self.h orelse return null;
        const dims = PositiveDimsU32.initClamped(
            width,
            height,
            4096,
        ) orelse return null;
        return .{ .path = p, .dims = dims };
    }
};

/// Parses and validates a raw JSON IPC response line into a structured
/// `IpcResponse`. Caller must call `.deinit()` on the returned handle.
pub fn parseResponse(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !std.json.Parsed(IpcResponse) {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.json.parseFromSlice(
        IpcResponse,
        allocator,
        trimmed,
        .{ .ignore_unknown_fields = true },
    );
}

/// Writes `{"ok":true}\n` to `writer` via `std.json.Stringify`.
pub fn writeOkLine(writer: *std.Io.Writer) !void {
    try std.json.Stringify.value(.{ .ok = true }, .{}, writer);
    try writer.writeByte('\n');
}

/// Writes `{"ok":false,"error":"<err_name>"}\n` to `writer` via
/// `std.json.Stringify`.
pub fn writeErrorLine(writer: *std.Io.Writer, err_name: []const u8) !void {
    try std.json.Stringify.value(
        .{ .ok = false, .@"error" = err_name },
        .{},
        writer,
    );
    try writer.writeByte('\n');
}

/// Writes `{"ok":true,"path":"<path>","w":<w>,"h":<h>}\n` to `writer` via
/// `std.json.Stringify`.
pub fn writePreviewLine(
    writer: *std.Io.Writer,
    path: []const u8,
    dims: PositiveDimsU32,
) !void {
    try std.json.Stringify.value(
        .{ .ok = true, .path = path, .w = dims.w, .h = dims.h },
        .{},
        writer,
    );
    try writer.writeByte('\n');
}

/// Sends a `{"ok":true,"path":"<path>","w":<w>,"h":<h>}\n` JSON preview
/// response over `stream` and closes the client socket.
pub fn respondPreview(
    io: std.Io,
    stream: std.Io.net.Stream,
    path: []const u8,
    dims: PositiveDimsU32,
) !void {
    defer stream.close(io);
    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writePreviewLine(&writer.interface, path, dims);
    try writer.interface.flush();
}

/// Sends a `{"ok":true}\n` JSON acknowledgment response over `stream` and
/// terminates the client socket.
pub fn respondOk(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    var write_buf: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writeOkLine(&writer.interface);
    try writer.interface.flush();
}

/// Sends a `{"ok":false,"error":"<err_name>"}\n` JSON error response over
/// `stream` and closes the client socket.
pub fn respondErrorName(
    io: std.Io,
    stream: std.Io.net.Stream,
    err_name: []const u8,
) void {
    defer stream.close(io);
    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writeErrorLine(&writer.interface, err_name) catch |err| {
        std.log.warn("IPC error response write failed: {}", .{err});
        return;
    };
    writer.interface.flush() catch |err| {
        std.log.warn("IPC error response flush failed: {}", .{err});
    };
}

/// Returns `true` if `response` is not valid JSON or if its top-level `"ok"`
/// field is `false`.
pub fn isErrorResponse(response: []const u8) bool {
    const trimmed = std.mem.trim(u8, response, " \t\r\n");
    var fba_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const StatusOnly = struct { ok: bool };
    const parsed = std.json.parseFromSliceLeaky(
        StatusOnly,
        fba.allocator(),
        trimmed,
        .{ .ignore_unknown_fields = true },
    ) catch return true;
    return !parsed.ok;
}

/// Reads bytes from `socket` with a total deadline until '\n' is encountered
/// or the buffer fills. Returns the slice up to '\n', `null` on clean initial
/// EOF, or `error.EndOfStream` / `error.Timeout` / `error.BufferOverflow`.
pub fn readLineTimeout(
    socket: *const std.Io.net.Socket,
    io: std.Io,
    buf: []u8,
    timeout_duration: std.Io.Clock.Duration,
) !?[]const u8 {
    const deadline: std.Io.Timeout = .{
        .deadline = .fromNow(io, timeout_duration),
    };
    var len: usize = 0;
    while (len < buf.len) {
        const msg = socket.receiveTimeout(
            io,
            buf[len..],
            deadline,
        ) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        if (msg.data.len == 0) {
            if (len == 0) return null;
            return error.EndOfStream;
        }
        if (std.mem.findScalar(u8, msg.data, '\n')) |newline_offset| {
            const line_len = len + newline_offset;
            return buf[0..line_len];
        }
        len += msg.data.len;
    }
    return error.BufferOverflow;
}

/// Dynamically reads a single `\n`-terminated line from `socket` with a total
/// deadline, allocating the returned slice with `allocator`. Caller owns the
/// returned slice when non-null. Returns `error.EndOfStream` if the peer
/// closes the socket mid-line before sending `\n`.
pub fn readLineTimeoutAlloc(
    allocator: std.mem.Allocator,
    socket: *const std.Io.net.Socket,
    io: std.Io,
    timeout_duration: std.Io.Clock.Duration,
) !?[]u8 {
    const max_response_bytes = 16 * 1024 * 1024;
    const deadline: std.Io.Timeout = .{
        .deadline = .fromNow(io, timeout_duration),
    };
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    var chunk_buf: [4 * 1024]u8 = undefined;
    while (list.items.len < max_response_bytes) {
        const msg = socket.receiveTimeout(
            io,
            &chunk_buf,
            deadline,
        ) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        if (msg.data.len == 0) {
            if (list.items.len == 0) return null;
            return error.EndOfStream;
        }
        if (std.mem.findScalar(u8, msg.data, '\n')) |newline_offset| {
            if (list.items.len + newline_offset > max_response_bytes) {
                return error.BufferOverflow;
            }
            try list.appendSlice(allocator, msg.data[0..newline_offset]);
            return try list.toOwnedSlice(allocator);
        }
        if (list.items.len + msg.data.len > max_response_bytes) {
            return error.BufferOverflow;
        }
        try list.appendSlice(allocator, msg.data);
    }
    return error.BufferOverflow;
}

test "IpcCommand parsing" {
    const cmd_zoom = try IpcCommand.parse("zoom 2.5");
    try std.testing.expectEqual(@as(f32, 2.5), cmd_zoom.zoom);

    const cmd_pan = try IpcCommand.parse("pan 100 -50");
    try std.testing.expectEqual(@as(f32, 100), cmd_pan.pan.x);
    try std.testing.expectEqual(@as(f32, -50), cmd_pan.pan.y);
    try std.testing.expectEqual(
        intents.AppIntent{ .set_pan = .{ .x = 100, .y = -50 } },
        cmd_pan.toIntent().?,
    );

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

    const cmd_selections = try IpcCommand.parse("selections");
    try std.testing.expectEqual(IpcCommand.selections, cmd_selections);
    try std.testing.expectEqual(
        @as(?intents.AppIntent, null),
        cmd_selections.toIntent(),
    );

    const cmd_list_sel = try IpcCommand.parse("list_selections");
    try std.testing.expectEqual(IpcCommand.selections, cmd_list_sel);

    const cmd_clear_sel = try IpcCommand.parse("clear_selections");
    try std.testing.expectEqual(IpcCommand.clear_selections, cmd_clear_sel);
    try std.testing.expectEqual(
        intents.AppIntent.clear_classifications,
        cmd_clear_sel.toIntent().?,
    );

    const cmd_clear_flags = try IpcCommand.parse("clear_flags");
    try std.testing.expectEqual(IpcCommand.clear_selections, cmd_clear_flags);

    try std.testing.expect(!isErrorResponse("{\"ok\":true}\n"));
    try std.testing.expect(!isErrorResponse("{ \"ok\" : true }\n"));
    try std.testing.expect(
        !isErrorResponse("{\"ok\":true,\"picks\":[],\"rejects\":[]}\n"),
    );
    try std.testing.expect(
        isErrorResponse("{\"ok\":false,\"error\":\"UnknownCommand\"}\n"),
    );
    // Truncated or malformed JSON is rejected as an error
    try std.testing.expect(
        isErrorResponse("{\"ok\":true,\"picks\":[\"a.jpg\""),
    );
    try std.testing.expect(isErrorResponse("{\"ok\":true_corrupt}"));

    var parsed_sel = try parseResponse(
        std.testing.allocator,
        "{\"ok\":true,\"picks\":[\"x.jpg\"],\"rejects\":[\"y.jpg\"]}\n",
    );
    defer parsed_sel.deinit();
    try std.testing.expect(parsed_sel.value.ok);
    try std.testing.expectEqual(@as(usize, 1), parsed_sel.value.picks.?.len);
    try std.testing.expectEqualStrings("x.jpg", parsed_sel.value.picks.?[0]);
    try std.testing.expectEqualStrings("y.jpg", parsed_sel.value.rejects.?[0]);

    const cmd_view_picks = try IpcCommand.parse("view picks");
    try std.testing.expectEqual(ViewMode.picks, cmd_view_picks.view);
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
        cmd_open_spaces.open.?,
    );
    try std.testing.expectEqualStrings(
        "/tmp/my photos/IMG 0001.JPG",
        cmd_open_spaces.toIntent().?.open_path,
    );
    const cmd_open_bare = try IpcCommand.parse("open   \n");
    try std.testing.expectEqual(@as(?[]const u8, null), cmd_open_bare.open);
    try std.testing.expectEqual(
        intents.AppIntent.open_window,
        cmd_open_bare.toIntent().?,
    );

    const cmd_preview_default = try IpcCommand.parse(
        "preview /tmp/my photos/IMG 0001.JPG\n",
    );
    try std.testing.expectEqual(
        @as(u32, 800),
        cmd_preview_default.preview.max_dims.w,
    );
    try std.testing.expectEqual(
        @as(u32, 600),
        cmd_preview_default.preview.max_dims.h,
    );
    try std.testing.expect(!cmd_preview_default.preview.clear_first);
    try std.testing.expectEqualStrings(
        "/tmp/my photos/IMG 0001.JPG",
        cmd_preview_default.preview.path,
    );
    try std.testing.expect(cmd_preview_default.isAllowedWhenHidden());

    const cmd_preview_dims = try IpcCommand.parse(
        "preview 320 240 /tmp/my photos/IMG 0001.JPG\n",
    );
    try std.testing.expectEqual(
        @as(u32, 320),
        cmd_preview_dims.preview.max_dims.w,
    );
    try std.testing.expectEqual(
        @as(u32, 240),
        cmd_preview_dims.preview.max_dims.h,
    );
    try std.testing.expect(!cmd_preview_dims.preview.clear_first);
    try std.testing.expectEqualStrings(
        "/tmp/my photos/IMG 0001.JPG",
        cmd_preview_dims.preview.path,
    );

    const cmd_preview_clear_flag = try IpcCommand.parse(
        "preview --clear 320 240 /tmp/my photos/IMG 0001.JPG\n",
    );
    try std.testing.expect(cmd_preview_clear_flag.preview.clear_first);
    try std.testing.expectEqual(
        @as(u32, 320),
        cmd_preview_clear_flag.preview.max_dims.w,
    );
    try std.testing.expectEqualStrings(
        "/tmp/my photos/IMG 0001.JPG",
        cmd_preview_clear_flag.preview.path,
    );

    const cmd_preview_clear_alias = try IpcCommand.parse(
        "clear-and-preview /tmp/my photos/IMG 0001.JPG\n",
    );
    try std.testing.expect(cmd_preview_clear_alias.preview.clear_first);
    try std.testing.expectEqualStrings(
        "/tmp/my photos/IMG 0001.JPG",
        cmd_preview_clear_alias.preview.path,
    );
    try std.testing.expectError(
        error.MissingArgument,
        IpcCommand.parse("preview --clear\n"),
    );
    try std.testing.expectError(
        error.MissingArgument,
        IpcCommand.parse("preview\n"),
    );
    try std.testing.expectError(
        error.MissingArgument,
        IpcCommand.parse("preview 320 240\n"),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        IpcCommand.parse("preview 0 240 /tmp/a.jpg\n"),
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

    const cmd_quit = try IpcCommand.parse("quit");
    try std.testing.expectEqual(IpcCommand.quit, cmd_quit);
    try std.testing.expectEqual(
        intents.AppIntent.quit_server,
        cmd_quit.toIntent().?,
    );

    const cmd_quit_srv = try IpcCommand.parse("quit_server");
    try std.testing.expectEqual(IpcCommand.quit, cmd_quit_srv);
    try std.testing.expectEqual(
        intents.AppIntent.quit_server,
        cmd_quit_srv.toIntent().?,
    );

    const cmd_shutdown = try IpcCommand.parse("shutdown");
    try std.testing.expectEqual(IpcCommand.quit, cmd_shutdown);

    const cmd_close = try IpcCommand.parse("close");
    try std.testing.expectEqual(IpcCommand.close, cmd_close);
    try std.testing.expectEqual(
        intents.AppIntent.quit,
        cmd_close.toIntent().?,
    );

    const cmd_hide = try IpcCommand.parse("hide");
    try std.testing.expectEqual(IpcCommand.close, cmd_hide);

    try std.testing.expectError(error.UnknownCommand, IpcCommand.parse("invalid_command"));
}

test "resolveDefaultSocketPath - XDG_RUNTIME_DIR, UID fallback, missing env" {
    const allocator = std.testing.allocator;

    // 1. Prefers XDG_RUNTIME_DIR over UID
    {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        try env_map.put("XDG_RUNTIME_DIR", "/run/user/1000/");
        try env_map.put("UID", "1000");

        const p = try resolveDefaultSocketPath(allocator, &env_map);
        defer allocator.free(p);
        try std.testing.expectEqualStrings("/run/user/1000/peng.sock", p);
    }

    // 2. Falls back to /tmp/peng-$UID.sock when XDG_RUNTIME_DIR is absent
    {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        try env_map.put("UID", "1001");

        const p = try resolveDefaultSocketPath(allocator, &env_map);
        defer allocator.free(p);
        try std.testing.expectEqualStrings("/tmp/peng-1001.sock", p);
    }

    // 3. Returns error.MissingSocketEnv when neither variable is present
    {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();

        try std.testing.expectError(
            error.MissingSocketEnv,
            resolveDefaultSocketPath(allocator, &env_map),
        );
    }
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
    var accepted_open = true;
    defer if (accepted_open) accepted.close(io);

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

    // Test readLineTimeoutAlloc with multi-KB payload (> 4 KB chunk_buf)
    var large_payload: [6 * 1024]u8 = undefined;
    @memset(large_payload[0 .. large_payload.len - 1], 'x');
    large_payload[large_payload.len - 1] = '\n';
    try writer.interface.writeAll(&large_payload);
    try writer.interface.flush();

    const alloc_line = (try readLineTimeoutAlloc(
        std.testing.allocator,
        &client.socket,
        io,
        long_dur,
    )) orelse unreachable;
    defer std.testing.allocator.free(alloc_line);
    try std.testing.expectEqual(large_payload.len - 1, alloc_line.len);

    // Test truncated line before '\n' returns error.EndOfStream
    try writer.interface.writeAll("{\"ok\":true,\"picks\":[\"unterminated");
    try writer.interface.flush();
    accepted.close(io);
    accepted_open = false;

    try std.testing.expectError(
        error.EndOfStream,
        readLineTimeoutAlloc(
            std.testing.allocator,
            &client.socket,
            io,
            long_dur,
        ),
    );
}

test "ipc - Parser accepts individual parameter adjustment commands" {
    const cmd_bright = try IpcCommand.parse("brightness 0.25");
    try std.testing.expectEqual(
        intents.EditParam.brightness,
        cmd_bright.set_param.param,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.25),
        cmd_bright.set_param.value,
        0.001,
    );

    const cmd_temp = try IpcCommand.parse("temperature -0.1");
    try std.testing.expectEqual(
        intents.EditParam.temperature,
        cmd_temp.set_param.param,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, -0.1),
        cmd_temp.set_param.value,
        0.001,
    );

    try std.testing.expectError(
        error.InvalidArgument,
        IpcCommand.parse("brightness 0.25 extra"),
    );
}
