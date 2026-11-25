const app_config = @import("config");
const builtin = @import("builtin");
const geom = @import("geom");
const ipc = @import("ipc");
const std = @import("std");
const termgfx = @import("termgfx");

const CellDims = termgfx.CellDims;
const CellPixelSize = termgfx.CellPixelSize;
const PositiveDimsU32 = geom.PositiveDimsU32;
const PreviewSize = termgfx.PreviewSize;
const ProtocolMode = termgfx.ProtocolMode;

const PreviewClientMode = union(enum) {
    none,
    output_file,
    terminal: struct {
        protocol: ProtocolMode,
        cell_dims: ?CellDims,
        cell_px: ?CellPixelSize,
        clear_first: bool,
    },
};

fn resolvePengBinary(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    argv0: ?[]const u8,
) ![]u8 {
    if (environ_map.get("PENG_BIN")) |raw_bin| {
        const trimmed = std.mem.trim(u8, raw_bin, " \t\r\n");
        if (trimmed.len > 0) {
            return gpa.dupe(u8, trimmed);
        }
    }
    const exe_name = if (builtin.os.tag == .windows) "peng.exe" else "peng";
    if (argv0) |prog| {
        if (std.Io.Dir.path.dirname(prog)) |dir| {
            const candidate = try std.Io.Dir.path.join(
                gpa,
                &.{ dir, exe_name },
            );
            if (std.Io.Dir.statFile(
                std.Io.Dir.cwd(),
                io,
                candidate,
                .{},
            )) |_| {
                return candidate;
            } else |_| {
                gpa.free(candidate);
            }
        }
    }
    return gpa.dupe(u8, exe_name);
}

fn spawnServerProcess(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    argv0: ?[]const u8,
    socket_path: []const u8,
    idle_timeout_sec: ?u64,
    test_mode: bool,
) !void {
    const peng_bin = try resolvePengBinary(gpa, io, environ_map, argv0);
    defer gpa.free(peng_bin);

    var argv_buf: [10][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = peng_bin;
    argc += 1;
    argv_buf[argc] = "--server";
    argc += 1;
    if (test_mode) {
        argv_buf[argc] = "--headless";
        argc += 1;
        argv_buf[argc] = "--test-mode";
        argc += 1;
    }
    var timeout_buf: [32]u8 = undefined;
    if (idle_timeout_sec) |sec| {
        const sec_str = try std.mem.print(&timeout_buf, "{d}", .{sec});
        argv_buf[argc] = "--idle-timeout";
        argc += 1;
        argv_buf[argc] = sec_str;
        argc += 1;
    }
    argv_buf[argc] = "--socket";
    argc += 1;
    argv_buf[argc] = socket_path;
    argc += 1;

    _ = try std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn nextSpaceToken(rest: *[]const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, rest.*, " \t\r\n");
    if (trimmed.len == 0) {
        rest.* = trimmed;
        return null;
    }
    if (trimmed[0] == '"') {
        if (std.mem.findScalarPos(u8, trimmed, 1, '"')) |end_q| {
            rest.* = trimmed[end_q + 1 ..];
            return trimmed[1..end_q];
        }
    }
    var end: usize = 0;
    while (end < trimmed.len and
        trimmed[end] != ' ' and
        trimmed[end] != '\t' and
        trimmed[end] != '\r' and
        trimmed[end] != '\n')
    {
        end += 1;
    }
    rest.* = trimmed[end..];
    return trimmed[0..end];
}

fn resolveOutputPathAlloc(
    gpa: std.mem.Allocator,
    io: std.Io,
    raw_path: []const u8,
) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(raw_path)) {
        return gpa.dupe(u8, raw_path);
    }
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const parent = std.Io.Dir.path.dirname(raw_path) orelse ".";
    const base = std.Io.Dir.path.basename(raw_path);
    const dir_len = std.Io.Dir.realPathFile(
        std.Io.Dir.cwd(),
        io,
        parent,
        &dir_buf,
    ) catch return gpa.dupe(u8, raw_path);
    return std.Io.Dir.path.join(gpa, &.{ dir_buf[0..dir_len], base });
}

fn isPreviewVerb(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "preview") or
        std.mem.eql(u8, cmd, "preview-kitty") or
        std.mem.eql(u8, cmd, "preview-clear") or
        std.mem.eql(u8, cmd, "preview_clear") or
        std.mem.eql(u8, cmd, "clear-and-preview");
}

fn preparePreviewCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    cmd: []const u8,
    raw_rest: []const u8,
    command_ptr: *[]u8,
) !PreviewClientMode {
    var clear_first = std.mem.eql(u8, cmd, "preview-clear") or
        std.mem.eql(u8, cmd, "preview_clear") or
        std.mem.eql(u8, cmd, "clear-and-preview");
    var size: PreviewSize = .default;
    var saw_end_of_options = false;
    var protocol: ProtocolMode = .auto;
    var output_path: ?[]const u8 = null;

    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(gpa);

    var rest = std.mem.trim(u8, raw_rest, " \t\r\n");
    while (rest.len > 0) {
        if (saw_end_of_options) {
            try positional.append(gpa, rest);
            break;
        }
        var probe = rest;
        const tok = nextSpaceToken(&probe) orelse break;
        if (std.mem.eql(u8, tok, "--")) {
            saw_end_of_options = true;
            rest = std.mem.trim(u8, probe, " \t\r\n");
            continue;
        }
        if (std.mem.eql(u8, tok, "--clear") or std.mem.eql(u8, tok, "-c")) {
            clear_first = true;
            rest = std.mem.trim(u8, probe, " \t\r\n");
            continue;
        }
        if (positional.items.len == 0 and std.mem.eql(u8, tok, "clear")) {
            const after = std.mem.trim(u8, probe, " \t\r\n");
            if (after.len > 0) {
                clear_first = true;
                rest = after;
                continue;
            }
        }
        if (std.mem.eql(u8, tok, "--size")) {
            const val = nextSpaceToken(&probe) orelse {
                std.log.err("Missing value for --size.", .{});
                return error.InvalidPreviewArgs;
            };
            const dims = app_config.cli.parsePreviewSize(val) orelse {
                std.log.err("Invalid --size value: {s}. Expected WxH.", .{val});
                return error.InvalidPreviewArgs;
            };
            size = size.withPixels(dims);
            rest = std.mem.trim(u8, probe, " \t\r\n");
            continue;
        }
        if (std.mem.eql(u8, tok, "--cells")) {
            const val = nextSpaceToken(&probe) orelse {
                std.log.err("Missing value for --cells.", .{});
                return error.InvalidPreviewArgs;
            };
            const dims = app_config.cli.parsePreviewSize(val) orelse {
                std.log.err(
                    "Invalid --cells value: {s}. Expected COLSxROWS.",
                    .{val},
                );
                return error.InvalidPreviewArgs;
            };
            size = size.withCells(.{ .cols = dims.w, .rows = dims.h });
            rest = std.mem.trim(u8, probe, " \t\r\n");
            continue;
        }
        if (std.mem.eql(u8, tok, "--protocol")) {
            const val = nextSpaceToken(&probe) orelse {
                std.log.err("Missing value for --protocol.", .{});
                return error.InvalidPreviewArgs;
            };
            protocol = ProtocolMode.parse(val) orelse {
                std.log.err(
                    "Unknown protocol: {s}. Valid: {s}.",
                    .{ val, termgfx.protocol_modes_string },
                );
                return error.InvalidPreviewArgs;
            };
            rest = std.mem.trim(u8, probe, " \t\r\n");
            continue;
        }
        if (std.mem.eql(u8, tok, "--output") or std.mem.eql(u8, tok, "-o")) {
            const val = nextSpaceToken(&probe) orelse {
                std.log.err("Missing value for --output.", .{});
                return error.InvalidPreviewArgs;
            };
            if (val.len == 0 or
                std.mem.findAny(u8, val, "\r\n\"") != null)
            {
                std.log.err("Invalid value for --output.", .{});
                return error.InvalidPreviewArgs;
            }
            output_path = val;
            rest = std.mem.trim(u8, probe, " \t\r\n");
            continue;
        }
        try positional.append(gpa, tok);
        rest = std.mem.trim(u8, probe, " \t\r\n");
    }

    if (positional.items.len == 0) {
        std.log.err("Missing image path for preview command.", .{});
        return error.InvalidPreviewArgs;
    }

    var path_start: usize = 0;
    if (!size.hasExplicitPixels() and
        !saw_end_of_options and
        positional.items.len >= 3)
    {
        if (std.fmt.parseInt(i64, positional.items[0], 10)) |w_i| {
            if (std.fmt.parseInt(i64, positional.items[1], 10)) |h_i| {
                const dims = PositiveDimsU32.initClamped(
                    w_i,
                    h_i,
                    4096,
                ) orelse return error.InvalidPreviewArgs;
                size = size.withPixels(dims);
                path_start = 2;
            } else |_| {}
        } else |_| {}
    }

    const target = protocol.resolve(environ_map);
    const term_target: ?termgfx.ResolvedTarget = if (output_path == null)
        target
    else
        null;
    const cell_px = if (size.needsCellPixelSize(term_target))
        termgfx.queryCellPixelSize(io)
    else
        null;
    const max_dims = size.resolveMaxPixels(cell_px);

    const joined_src = try std.mem.join(
        gpa,
        " ",
        positional.items[path_start..],
    );
    defer gpa.free(joined_src);
    if (std.mem.findAny(u8, joined_src, "\r\n") != null) {
        std.log.err("Invalid newline in preview image path.", .{});
        return error.InvalidPreviewArgs;
    }

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_src: []const u8 = if (std.Io.Dir.path.isAbsolute(joined_src))
        joined_src
    else if (std.Io.Dir.realPathFile(
        std.Io.Dir.cwd(),
        io,
        joined_src,
        &real_buf,
    )) |n|
        real_buf[0..n]
    else |_|
        joined_src;

    if (output_path) |raw_out| {
        const abs_out = try resolveOutputPathAlloc(gpa, io, raw_out);
        defer gpa.free(abs_out);
        if (std.mem.findAny(u8, abs_out, "\r\n\"") != null) {
            std.log.err("Invalid character in --output path.", .{});
            return error.InvalidPreviewArgs;
        }
        const rewritten = try gpa.print(
            "preview --output \"{s}\" --size {d}x{d} -- {s}\n",
            .{ abs_out, max_dims.w, max_dims.h, abs_src },
        );
        gpa.free(command_ptr.*);
        command_ptr.* = rewritten;
        return .output_file;
    }

    const fmt_str: []const u8 = switch (target.protocol) {
        .kitty, .sixel, .halfblocks => "rgba",
        .iterm2 => "encoded",
    };
    const rewritten = try gpa.print(
        "preview --format {s} --size {d}x{d} -- {s}\n",
        .{ fmt_str, max_dims.w, max_dims.h, abs_src },
    );
    gpa.free(command_ptr.*);
    command_ptr.* = rewritten;
    return .{
        .terminal = .{
            .protocol = protocol,
            .cell_dims = size.cellDims(),
            .cell_px = cell_px,
            .clear_first = clear_first,
        },
    };
}

fn prepareCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    command_ptr: *[]u8,
) !PreviewClientMode {
    var rest = std.mem.trim(u8, command_ptr.*, " \t\r\n");
    const cmd = nextSpaceToken(&rest) orelse return .none;
    if (isPreviewVerb(cmd)) {
        return preparePreviewCommand(
            gpa,
            io,
            environ_map,
            cmd,
            rest,
            command_ptr,
        );
    }
    if (std.mem.eql(u8, cmd, "open")) {
        const p = std.mem.trim(u8, rest, " \t\r\n");
        if (p.len == 0 or std.Io.Dir.path.isAbsolute(p)) return .none;
        var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const real_len = std.Io.Dir.realPathFile(
            std.Io.Dir.cwd(),
            io,
            p,
            &real_buf,
        ) catch return .none;
        const rewritten = gpa.print(
            "open {s}\n",
            .{real_buf[0..real_len]},
        ) catch return .none;
        gpa.free(command_ptr.*);
        command_ptr.* = rewritten;
    }
    return .none;
}

fn deleteTempFileQuiet(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, path) catch |del_e| {
        std.log.warn(
            "Failed to clean up preview temp file '{s}': {}",
            .{ path, del_e },
        );
    };
}

fn readTempFileAlloc(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(64 * 1024 * 1024),
    );
}

fn writeTerminalPreview(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    prev: ipc.PreviewPayload,
    protocol: ProtocolMode,
    cell_dims: ?CellDims,
    cell_px: ?CellPixelSize,
    clear_first: bool,
) bool {
    const target = protocol.resolve(environ_map);
    const preview_opts: termgfx.PreviewOptions = .{
        .transport = target.transport,
        .cell_dims = cell_dims,
        .cell_px = cell_px,
    };
    const stdout = std.Io.File.stdout();

    switch (target.protocol) {
        .kitty => {
            if (target.is_remote) {
                defer deleteTempFileQuiet(io, prev.path);
                const bytes = readTempFileAlloc(
                    gpa,
                    io,
                    prev.path,
                ) catch |err| {
                    std.log.err(
                        "Failed to read preview RGBA temp file '{s}': {s}",
                        .{ prev.path, @errorName(err) },
                    );
                    return false;
                };
                defer gpa.free(bytes);
                const pitch = std.math.mul(usize, prev.dims.w, 4) catch {
                    std.log.err("Preview RGBA dimensions overflow", .{});
                    return false;
                };
                const expected = std.math.mul(usize, pitch, prev.dims.h) catch {
                    std.log.err("Preview RGBA dimensions overflow", .{});
                    return false;
                };
                if (bytes.len < expected) {
                    std.log.err("Truncated preview RGBA temp file", .{});
                    return false;
                }
                var stdout_buf: [16 * 1024]u8 = undefined;
                var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
                const write_res: ?anyerror = blk: {
                    termgfx.writePreview(&stdout_writer.interface, .{
                        .kitty = .{
                            .medium = .{
                                .direct_rgba = .{
                                    .rgba_pixels = bytes[0..expected],
                                    .pitch = pitch,
                                },
                            },
                            .dims = prev.dims,
                            .clear_first = clear_first,
                        },
                    }, preview_opts) catch |err| break :blk err;
                    stdout_writer.interface.flush() catch |err| break :blk err;
                    break :blk null;
                };
                if (write_res) |err| {
                    const write_err: anyerror = stdout_writer.err orelse err;
                    if (write_err != error.BrokenPipe) {
                        std.log.err("Failed to write Kitty preview: {s}", .{
                            @errorName(write_err),
                        });
                    }
                    return false;
                }
                return true;
            }
            var stdout_buf: [1024]u8 = undefined;
            var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
            const write_res: ?anyerror = blk: {
                termgfx.writePreview(&stdout_writer.interface, .{
                    .kitty = .{
                        .medium = .{ .temp_file = prev.path },
                        .dims = prev.dims,
                        .clear_first = clear_first,
                    },
                }, preview_opts) catch |err| break :blk err;
                stdout_writer.interface.flush() catch |err| break :blk err;
                break :blk null;
            };
            if (write_res) |err| {
                const write_err: anyerror = stdout_writer.err orelse err;
                if (write_err != error.BrokenPipe) {
                    std.log.err("Failed to write Kitty preview: {s}", .{
                        @errorName(write_err),
                    });
                }
                deleteTempFileQuiet(io, prev.path);
                return false;
            }
            return true;
        },
        .sixel => {
            defer deleteTempFileQuiet(io, prev.path);
            const bytes = readTempFileAlloc(gpa, io, prev.path) catch |err| {
                std.log.err(
                    "Failed to read preview RGBA temp file '{s}': {s}",
                    .{ prev.path, @errorName(err) },
                );
                return false;
            };
            defer gpa.free(bytes);
            const pitch = std.math.mul(usize, prev.dims.w, 4) catch {
                std.log.err("Preview RGBA dimensions overflow", .{});
                return false;
            };
            const expected = std.math.mul(usize, pitch, prev.dims.h) catch {
                std.log.err("Preview RGBA dimensions overflow", .{});
                return false;
            };
            if (bytes.len < expected) {
                std.log.err("Truncated preview RGBA temp file", .{});
                return false;
            }
            var stdout_buf: [16 * 1024]u8 = undefined;
            var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
            const write_res: ?anyerror = blk: {
                termgfx.writePreview(&stdout_writer.interface, .{
                    .sixel = .{
                        .allocator = gpa,
                        .rgba_pixels = bytes[0..expected],
                        .pitch = pitch,
                        .dims = prev.dims,
                    },
                }, preview_opts) catch |err| break :blk err;
                stdout_writer.interface.flush() catch |err| break :blk err;
                break :blk null;
            };
            if (write_res) |err| {
                const write_err: anyerror = stdout_writer.err orelse err;
                if (write_err != error.BrokenPipe) {
                    std.log.err("Failed to write Sixel preview: {s}", .{
                        @errorName(write_err),
                    });
                }
                return false;
            }
            return true;
        },
        .iterm2 => {
            defer deleteTempFileQuiet(io, prev.path);
            const bytes = readTempFileAlloc(gpa, io, prev.path) catch |err| {
                std.log.err(
                    "Failed to read preview image temp file '{s}': {s}",
                    .{ prev.path, @errorName(err) },
                );
                return false;
            };
            defer gpa.free(bytes);
            var stdout_buf: [16 * 1024]u8 = undefined;
            var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
            const write_res: ?anyerror = blk: {
                termgfx.writePreview(&stdout_writer.interface, .{
                    .iterm2 = .{
                        .image_bytes = bytes,
                        .dims = prev.dims,
                    },
                }, preview_opts) catch |err| break :blk err;
                stdout_writer.interface.flush() catch |err| break :blk err;
                break :blk null;
            };
            if (write_res) |err| {
                const write_err: anyerror = stdout_writer.err orelse err;
                if (write_err != error.BrokenPipe) {
                    std.log.err("Failed to write iTerm2 preview: {s}", .{
                        @errorName(write_err),
                    });
                }
                return false;
            }
            return true;
        },
        .halfblocks => {
            defer deleteTempFileQuiet(io, prev.path);
            const bytes = readTempFileAlloc(gpa, io, prev.path) catch |err| {
                std.log.err(
                    "Failed to read preview RGBA temp file '{s}': {s}",
                    .{ prev.path, @errorName(err) },
                );
                return false;
            };
            defer gpa.free(bytes);
            const pitch = std.math.mul(usize, prev.dims.w, 4) catch {
                std.log.err("Preview RGBA dimensions overflow", .{});
                return false;
            };
            const expected = std.math.mul(usize, pitch, prev.dims.h) catch {
                std.log.err("Preview RGBA dimensions overflow", .{});
                return false;
            };
            if (bytes.len < expected) {
                std.log.err("Truncated preview RGBA temp file", .{});
                return false;
            }
            var hb_opts = preview_opts;
            if (hb_opts.cell_px == null) {
                hb_opts.cell_px = termgfx.default_cell_px;
            }
            var stdout_buf: [16 * 1024]u8 = undefined;
            var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
            const write_res: ?anyerror = blk: {
                termgfx.writePreview(&stdout_writer.interface, .{
                    .halfblocks = .{
                        .rgba_pixels = bytes[0..expected],
                        .pitch = pitch,
                        .dims = prev.dims,
                    },
                }, hb_opts) catch |err| break :blk err;
                stdout_writer.interface.flush() catch |err| break :blk err;
                break :blk null;
            };
            if (write_res) |err| {
                const write_err: anyerror = stdout_writer.err orelse err;
                if (write_err != error.BrokenPipe) {
                    std.log.err("Failed to write halfblocks preview: {s}", .{
                        @errorName(write_err),
                    });
                }
                return false;
            }
            return true;
        },
    }
}

/// Entry point for the `peng-msg` CLI utility that dispatches IPC commands to
/// a running `peng` instance over a UNIX domain socket.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var argv0_it = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        gpa,
    );
    defer argv0_it.deinit();
    const argv0 = argv0_it.next();

    var parsed = app_config.cli.parseIpcCommandLineArgs(init, gpa) catch |err| {
        if (err == error.MissingCommand) {
            app_config.cli.printIpcHelp(io);
        }
        std.process.exit(1);
    };
    defer parsed.deinit(gpa);

    var send_args = switch (parsed) {
        .help => {
            app_config.cli.printIpcHelp(io);
            return;
        },
        .send => |*s| s,
    };

    var owned_default_socket: ?[]u8 = null;
    defer if (owned_default_socket) |p| gpa.free(p);

    const socket_path: []const u8 = if (send_args.socket_path) |p|
        p
    else blk: {
        owned_default_socket = ipc.resolveDefaultSocketPath(
            gpa,
            init.environ_map,
        ) catch |err| {
            std.log.err(
                "Failed to resolve default IPC socket path ({any}): " ++
                    "set $XDG_RUNTIME_DIR, $UID, or pass -S/--socket <PATH>",
                .{err},
            );
            std.process.exit(1);
        };
        break :blk owned_default_socket.?;
    };

    const preview_mode = prepareCommand(
        gpa,
        io,
        init.environ_map,
        &send_args.command,
    ) catch {
        std.process.exit(1);
    };

    const address = std.Io.net.UnixAddress.init(socket_path) catch |err| {
        std.log.err(
            "Invalid Unix socket path '{s}': {any}",
            .{ socket_path, err },
        );
        std.process.exit(1);
    };

    var spawn_lock: ?ipc.SocketLock = null;
    defer if (spawn_lock) |l| l.release(io);

    const max_connect_attempts: usize = if (send_args.spawn) 300 else 100;
    var spawned_server = false;
    var attempt: usize = 0;
    const stream = while (attempt < max_connect_attempts) : (attempt += 1) {
        if (address.connect(io)) |s| {
            break s;
        } else |err| switch (err) {
            error.FileNotFound,
            error.ConnectionRefused,
            error.WouldBlock,
            => {
                if (send_args.spawn and !spawned_server and
                    (err == error.FileNotFound or
                        err == error.ConnectionRefused))
                {
                    var lock_buf: [160]u8 = undefined;
                    var should_spawn = false;
                    if (ipc.formatLockPath(
                        &lock_buf,
                        socket_path,
                        ".spawn.lock",
                    )) |lp| {
                        if (ipc.SocketLock.tryAcquire(io, lp)) |lock_opt| {
                            if (lock_opt) |lock| {
                                spawn_lock = lock;
                                should_spawn = true;
                            }
                        } else |lock_err| {
                            std.log.warn(
                                "Failed to acquire spawn lock '{s}': {any}; " ++
                                    "spawning without lock",
                                .{ lp, lock_err },
                            );
                            should_spawn = true;
                        }
                    } else |fmt_err| {
                        std.log.debug(
                            "Spawn lock path format failed: {any}",
                            .{fmt_err},
                        );
                        should_spawn = true;
                    }
                    if (should_spawn) {
                        if (address.connect(io)) |s| {
                            break s;
                        } else |re_err| switch (re_err) {
                            error.FileNotFound,
                            error.ConnectionRefused,
                            error.WouldBlock,
                            => {},
                            else => std.log.warn(
                                "Reconnect check for {s} failed: {any}",
                                .{ socket_path, re_err },
                            ),
                        }
                        spawned_server = true;
                        spawnServerProcess(
                            gpa,
                            io,
                            init.environ_map,
                            argv0,
                            socket_path,
                            send_args.idle_timeout_sec,
                            send_args.test_mode,
                        ) catch |spawn_err| {
                            std.log.err(
                                "Failed to spawn peng server for socket " ++
                                    "{s}: {any}",
                                .{ socket_path, spawn_err },
                            );
                            std.process.exit(1);
                        };
                    }
                } else if (err == error.ConnectionRefused and
                    !send_args.spawn)
                {
                    std.log.err(
                        "Failed to connect to socket {s}: {any}",
                        .{ socket_path, err },
                    );
                    std.process.exit(1);
                }

                if (attempt + 1 < max_connect_attempts) {
                    std.Io.sleep(
                        io,
                        std.Io.Duration.fromMilliseconds(10),
                        .awake,
                    ) catch |sleep_err| {
                        std.log.debug(
                            "Connect retry sleep interrupted: {any}",
                            .{sleep_err},
                        );
                    };
                    continue;
                }
                std.log.err(
                    "Failed to connect to socket {s}: {any}",
                    .{ socket_path, err },
                );
                std.process.exit(1);
            },
            else => {
                std.log.err(
                    "Failed to connect to socket {s}: {any}",
                    .{ socket_path, err },
                );
                std.process.exit(1);
            },
        }
    } else {
        std.log.err(
            "Failed to connect to socket {s}: Connection timed out",
            .{socket_path},
        );
        std.process.exit(1);
    };
    if (spawn_lock) |l| {
        l.release(io);
        spawn_lock = null;
    }
    defer stream.close(io);

    var write_buf: [1 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(send_args.command) catch |err| {
        std.log.err("Failed to send command: {any}", .{err});
        std.process.exit(1);
    };
    writer.interface.flush() catch |err| {
        std.log.err("Failed to flush command stream: {any}", .{err});
        std.process.exit(1);
    };

    const timeout_dur: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromSeconds(15),
        .clock = .awake,
    };
    const response_opt = ipc.readLineTimeoutAlloc(
        gpa,
        &stream.socket,
        io,
        timeout_dur,
    ) catch |err| {
        if (err == error.Timeout) {
            std.log.err(
                "Timed out waiting for response from peng ({s})",
                .{socket_path},
            );
        } else {
            std.log.err("Failed to read response: {any}", .{err});
        }
        std.process.exit(1);
    };

    if (response_opt) |response| {
        defer gpa.free(response);
        const trimmed = std.mem.trim(u8, response, " \t\r\n");
        var parsed_resp = ipc.parseResponse(gpa, trimmed) catch |err| {
            std.log.err(
                "Invalid JSON response from peng ({any}): {s}",
                .{ err, trimmed },
            );
            std.process.exit(1);
        };
        defer parsed_resp.deinit();

        switch (preview_mode) {
            .output_file => {
                if (!parsed_resp.value.ok) {
                    std.log.err("Preview failed: {s}", .{trimmed});
                    std.process.exit(1);
                }
                return;
            },
            .terminal => |term_cfg| {
                if (parsed_resp.value.getPreview()) |prev| {
                    if (!writeTerminalPreview(
                        gpa,
                        io,
                        init.environ_map,
                        prev,
                        term_cfg.protocol,
                        term_cfg.cell_dims,
                        term_cfg.cell_px,
                        term_cfg.clear_first,
                    )) {
                        std.process.exit(1);
                    }
                    return;
                }
            },
            .none => {},
        }

        const stdout = std.Io.File.stdout();
        var stdout_buf: [4 * 1024]u8 = undefined;
        var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
        stdout_writer.interface.print("{s}\n", .{trimmed}) catch |err| {
            std.log.err(
                "Failed to write response to stdout: {any}",
                .{err},
            );
            std.process.exit(1);
        };
        stdout_writer.interface.flush() catch |err| {
            std.log.err("Failed to flush stdout: {any}", .{err});
            std.process.exit(1);
        };
        if (!parsed_resp.value.ok) {
            std.process.exit(1);
        }
    } else {
        std.log.err("No response from server", .{});
        std.process.exit(1);
    }
}
