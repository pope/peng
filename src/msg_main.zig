const app_config = @import("config");
const builtin = @import("builtin");
const ipc = @import("ipc");
const std = @import("std");
const termgfx = @import("termgfx");

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
    test_mode: bool,
) !void {
    const peng_bin = try resolvePengBinary(gpa, io, environ_map, argv0);
    defer gpa.free(peng_bin);

    const argv_test = [_][]const u8{
        peng_bin,
        "--server",
        "--headless",
        "--test-mode",
        "--socket",
        socket_path,
    };
    const argv_normal = [_][]const u8{
        peng_bin,
        "--server",
        "--socket",
        socket_path,
    };
    const argv: []const []const u8 = if (test_mode)
        &argv_test
    else
        &argv_normal;

    _ = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn normalizeCommandPaths(
    gpa: std.mem.Allocator,
    io: std.Io,
    command_ptr: *[]u8,
) bool {
    const parsed_cmd = ipc.IpcCommand.parse(command_ptr.*) catch return false;
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    switch (parsed_cmd) {
        .open => |p_opt| {
            const p = p_opt orelse return false;
            if (std.Io.Dir.path.isAbsolute(p)) return false;
            const real_len = std.Io.Dir.realPathFile(
                std.Io.Dir.cwd(),
                io,
                p,
                &real_buf,
            ) catch return false;
            const rewritten = gpa.print(
                "open {s}\n",
                .{real_buf[0..real_len]},
            ) catch return false;
            gpa.free(command_ptr.*);
            command_ptr.* = rewritten;
            return false;
        },
        .preview => |req| {
            const clear_first = req.clear_first;
            if (std.Io.Dir.path.isAbsolute(req.path)) return clear_first;
            const real_len = std.Io.Dir.realPathFile(
                std.Io.Dir.cwd(),
                io,
                req.path,
                &real_buf,
            ) catch return clear_first;
            const clear_flag = if (clear_first) "--clear " else "";
            const rewritten = gpa.print(
                "preview {s}{d} {d} {s}\n",
                .{
                    clear_flag,
                    req.max_dims.w,
                    req.max_dims.h,
                    real_buf[0..real_len],
                },
            ) catch return clear_first;
            gpa.free(command_ptr.*);
            command_ptr.* = rewritten;
            return clear_first;
        },
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
        .wait_load,
        .reset_view,
        .reset_adjustments,
        .next,
        .prev,
        .pick,
        .reject,
        .unflag,
        .selections,
        .clear_selections,
        .view,
        .precache,
        .close,
        .quit,
        .screenshot,
        => return false,
    }
}

/// CLI entry point for sending IPC commands to a running Peng instance via Unix domain socket.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        gpa,
    );
    defer args_it.deinit();

    const argv0 = args_it.next();
    var parsed = app_config.cli.parseIpcArgsIterator(
        &args_it,
        gpa,
    ) catch |err| {
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

    const clear_preview = normalizeCommandPaths(gpa, io, &send_args.command);

    const socket_path = if (send_args.socket_path) |sp|
        sp
    else blk: {
        const resolved = ipc.resolveDefaultSocketPath(
            gpa,
            init.environ_map,
        ) catch |err| {
            std.log.err(
                "Failed to resolve default IPC socket path ({any}): " ++
                    "set $XDG_RUNTIME_DIR, $UID, or pass --socket <PATH>",
                .{err},
            );
            std.process.exit(1);
        };
        send_args.socket_path = resolved;
        break :blk resolved;
    };

    const address = std.Io.net.UnixAddress.init(socket_path) catch |err| {
        std.log.err("Invalid socket path: {any}", .{err});
        std.process.exit(1);
    };

    const max_connect_attempts: usize = if (send_args.spawn) 75 else 25;
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
                    spawned_server = true;
                    spawnServerProcess(
                        gpa,
                        io,
                        init.environ_map,
                        argv0,
                        socket_path,
                        send_args.test_mode,
                    ) catch |spawn_err| {
                        std.log.err(
                            "Failed to spawn peng server for socket {s}: {any}",
                            .{ socket_path, spawn_err },
                        );
                        std.process.exit(1);
                    };
                } else if (err == error.ConnectionRefused and !spawned_server) {
                    std.log.err(
                        "Failed to connect to socket {s}: {any}",
                        .{ socket_path, err },
                    );
                    std.process.exit(1);
                }

                if (attempt + 1 < max_connect_attempts) {
                    std.Io.sleep(
                        io,
                        std.Io.Duration.fromMilliseconds(40),
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

        const stdout = std.Io.File.stdout();
        var stdout_buf: [4 * 1024]u8 = undefined;
        var stdout_writer = stdout.writerStreaming(io, &stdout_buf);
        const preview_opt = parsed_resp.value.getPreview();
        if (preview_opt) |prev| {
            termgfx.writeKittyPreview(
                &stdout_writer.interface,
                prev.path,
                prev.dims,
                clear_preview,
            ) catch |err| {
                std.log.err(
                    "Failed to write Kitty preview to stdout: {any}",
                    .{err},
                );
                std.Io.Dir.deleteFile(
                    std.Io.Dir.cwd(),
                    io,
                    prev.path,
                ) catch |del_e| {
                    std.log.warn(
                        "Failed to clean up preview temp file '{s}': {}",
                        .{ prev.path, del_e },
                    );
                };
                std.process.exit(1);
            };
        } else {
            stdout_writer.interface.print("{s}\n", .{trimmed}) catch |err| {
                std.log.err(
                    "Failed to write response to stdout: {any}",
                    .{err},
                );
                std.process.exit(1);
            };
        }
        stdout_writer.interface.flush() catch |err| {
            std.log.err("Failed to flush stdout: {any}", .{err});
            if (preview_opt) |prev| {
                std.Io.Dir.deleteFile(
                    std.Io.Dir.cwd(),
                    io,
                    prev.path,
                ) catch |del_e| {
                    std.log.warn(
                        "Failed to clean up preview temp file '{s}': {}",
                        .{ prev.path, del_e },
                    );
                };
            }
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
