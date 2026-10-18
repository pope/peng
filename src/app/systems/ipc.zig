const app_events = @import("../events.zig");
const app_state = @import("../state.zig");
const builtin = @import("builtin");
const cache_system = @import("cache.zig");
const context = @import("context.zig");
const intents = @import("intents");
const intents_system = @import("intents.zig");
const ipc = @import("ipc");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;

/// System function that drains queued socket commands from `state.pending_ipc_commands`,
/// parses commands (`zoom`, `pan`, `next`, `filter`), and pushes corresponding
/// intents into `pending_intents`.
pub fn sysExecuteIpcCommands(ctx: FrameContext) void {
    const state = ctx.state;
    if (state.pending_ipc_commands.items.len == 0) return;

    var i: usize = 0;
    while (i < state.pending_ipc_commands.items.len) : (i += 1) {
        const cmd_data = state.pending_ipc_commands.items[i];
        defer {
            state.allocator.free(cmd_data.command);
            state.allocator.destroy(cmd_data);
        }

        const parsed = ipc.IpcCommand.parse(cmd_data.command) catch |err| {
            replyIpcParseError(state.io, cmd_data.client_stream, err);
            continue;
        };

        switch (parsed) {
            .wait_load => handleWaitLoadCommand(ctx, cmd_data.client_stream),
            .adjust => |adj| {
                handleAdjustCommand(state, cmd_data.client_stream, adj);
            },
            .screenshot => |filepath| {
                handleScreenshotCommand(state, cmd_data, filepath);
            },
            else => handleIntentCommand(ctx, cmd_data, parsed),
        }
    }
    state.pending_ipc_commands.clearRetainingCapacity();
}

fn replyIpcError(
    io: std.Io,
    stream: std.Io.net.Stream,
    err_msg: []const u8,
) void {
    var write_buf: [128]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(err_msg) catch |err| {
        std.log.warn("IPC error response failed: {}", .{err});
    };
    writer.interface.flush() catch |err| {
        std.log.warn("IPC error flush failed: {}", .{err});
    };
    stream.close(io);
}

fn replyIpcParseError(
    io: std.Io,
    stream: std.Io.net.Stream,
    err: anyerror,
) void {
    var msg_buf: [128]u8 = undefined;
    const err_msg = std.fmt.bufPrint(
        &msg_buf,
        "ERR {s}\n",
        .{@errorName(err)},
    ) catch "ERR ParseError\n";
    replyIpcError(io, stream, err_msg);
}

fn handleWaitLoadCommand(ctx: FrameContext, stream: std.Io.net.Stream) void {
    const state = ctx.state;
    var attempts: u32 = 0;
    while (attempts < 1000) : (attempts += 1) {
        intents_system.sysExecuteIntents(ctx) catch |err| {
            std.log.err(
                "Failed to execute intents during wait_load: {}",
                .{err},
            );
        };
        _ = app_events.drainWorkerEvents(state);
        cache_system.sysUpdateCache(ctx) catch |err| {
            std.log.err(
                "Failed to update cache during wait_load: {}",
                .{err},
            );
        };
        state.prepareCacheTextures();

        if (state.getCurrentEntry()) |entry| {
            if (entry.status != .decoding and entry.status != .uploading) {
                break;
            }
        } else if (!state.viewer.navigation.isLoadingFiles() and
            state.viewer.navigation.current_index == null)
        {
            break;
        }
        std.Io.sleep(
            state.io,
            std.Io.Duration.fromMilliseconds(10),
            .awake,
        ) catch |sleep_err| {
            std.log.warn("wait_load sleep interrupted: {}", .{sleep_err});
        };
    }
    ipc.respondOk(state.io, stream) catch |err| {
        std.log.err("Failed to respond OK for wait_load command: {}", .{err});
    };
}

fn handleAdjustCommand(
    state: *AppState,
    stream: std.Io.net.Stream,
    adj: anytype,
) void {
    state.pushIntent(.{
        .adjust = .{
            .set = .{
                .param = .brightness,
                .value = adj.brightness,
            },
        },
    }) catch |err| {
        std.log.err("Failed to push brightness adjust: {}", .{err});
        replyIpcError(state.io, stream, "ERR OutOfMemory\n");
        return;
    };
    state.pushIntent(.{
        .adjust = .{
            .set = .{
                .param = .contrast,
                .value = adj.contrast,
            },
        },
    }) catch |err| {
        std.log.err("Failed to push contrast adjust: {}", .{err});
        replyIpcError(state.io, stream, "ERR OutOfMemory\n");
        return;
    };
    if (adj.contrast_blend) |cb| {
        state.pushIntent(.{
            .adjust = .{
                .set = .{
                    .param = .contrast_blend,
                    .value = cb,
                },
            },
        }) catch |err| {
            std.log.err("Failed to push contrast blend adjust: {}", .{err});
            replyIpcError(state.io, stream, "ERR OutOfMemory\n");
            return;
        };
    }
    ipc.respondOk(state.io, stream) catch |err| {
        std.log.err("Failed to respond OK for adjust command: {}", .{err});
    };
}

fn handleScreenshotCommand(
    state: *AppState,
    cmd_data: *ipc.IpcCommandData,
    filepath: []const u8,
) void {
    if (filepath.len > 512) {
        replyIpcError(state.io, cmd_data.client_stream, "ERR PathTooLong\n");
        return;
    }
    if (state.viewer.ui.screenshot_mode == .capturing) {
        replyIpcError(state.io, cmd_data.client_stream, "ERR Busy\n");
        return;
    }
    const dup_path = state.allocator.dupeZ(u8, filepath) catch {
        replyIpcError(state.io, cmd_data.client_stream, "ERR OutOfMemory\n");
        return;
    };
    state.viewer.ui.screenshot_mode = .{
        .capturing = state_pkg.types.ActiveScreenshot{
            .path = dup_path,
            .stream = cmd_data.client_stream,
        },
    };
}

fn handleIntentCommand(
    ctx: FrameContext,
    cmd_data: *ipc.IpcCommandData,
    parsed: ipc.IpcCommand,
) void {
    const state = ctx.state;
    const intent = parsed.toIntent() orelse {
        cmd_data.client_stream.close(state.io);
        return;
    };

    var final_intent = intent;
    switch (intent) {
        .set_palette => |p| {
            if (p.query) |q| {
                const dup_q = ctx.frame_allocator.dupe(u8, q) catch |err| {
                    std.log.warn(
                        "Failed to dupe query for set_palette intent: {}",
                        .{err},
                    );
                    replyIpcError(
                        state.io,
                        cmd_data.client_stream,
                        "ERR OutOfMemory\n",
                    );
                    return;
                };
                final_intent = .{
                    .set_palette = .{
                        .mode = p.mode,
                        .query = dup_q,
                    },
                };
            }
        },
        else => {},
    }
    state.pushIntent(final_intent) catch |err| {
        std.log.err("Failed to push intent from IPC command: {}", .{err});
        replyIpcError(
            state.io,
            cmd_data.client_stream,
            "ERR OutOfMemory\n",
        );
        return;
    };
    ipc.respondOk(state.io, cmd_data.client_stream) catch |err| {
        std.log.err("Failed to respond OK to IPC client: {}", .{err});
    };
}

test "sysExecuteIpcCommands - drains pending commands and mutates state" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const sock_path = "/tmp/peng_test_sys_ipc1.sock";
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, sock_path) catch {};
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, sock_path) catch {};

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const client = try addr.connect(io);
    defer client.close(io);
    const accepted = try server.accept(io);

    const cmd_str = try allocator.dupe(u8, "zoom 2.0");
    const cmd_data = try allocator.create(ipc.IpcCommandData);
    cmd_data.* = .{
        .command = cmd_str,
        .client_stream = accepted,
    };

    try state.pending_ipc_commands.append(allocator, cmd_data);
    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysExecuteIpcCommands(ctx);
    try intents_system.sysExecuteIntents(ctx);

    try std.testing.expectEqual(
        @as(usize, 0),
        state.pending_ipc_commands.items.len,
    );
    try std.testing.expectEqual(
        @as(f32, 2.0),
        state.viewer.viewport.zoom_factor.get(),
    );
}

test "sysExecuteIpcCommands - multiple queued commands and adjust command" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const sock_path = "/tmp/peng_test_sys_ipc2.sock";
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, sock_path) catch {};
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, sock_path) catch {};

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const client = try addr.connect(io);
    defer client.close(io);
    const accepted = try server.accept(io);

    const cmd1_str = try allocator.dupe(u8, "adjust 0.5 2.0");
    const cmd1_data = try allocator.create(ipc.IpcCommandData);
    cmd1_data.* = .{ .command = cmd1_str, .client_stream = accepted };
    try state.pending_ipc_commands.append(allocator, cmd1_data);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysExecuteIpcCommands(ctx);
    try intents_system.sysExecuteIntents(ctx);

    try std.testing.expectEqual(
        @as(usize, 0),
        state.pending_ipc_commands.items.len,
    );
    try std.testing.expectEqual(
        @as(f32, 0.5),
        state.viewer.viewport.edits.get(.brightness),
    );
    try std.testing.expectEqual(
        @as(f32, 2.0),
        state.viewer.viewport.edits.get(.contrast),
    );
}

test "sysExecuteIpcCommands - wait_load and re-entrant ipc_command" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const sock_path = "/tmp/peng_test_sys_ipc3.sock";
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, sock_path) catch {};
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, sock_path) catch {};

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    const client1 = try addr.connect(io);
    defer client1.close(io);
    const accepted1 = try server.accept(io);

    const client2 = try addr.connect(io);
    defer client2.close(io);
    const accepted2 = try server.accept(io);

    // Queue `wait_load` in `pending_ipc_commands` (capacity 1 so re-entrant
    // append during `drainWorkerEvents` reallocates the backing slice).
    const cmd1_data = try allocator.create(ipc.IpcCommandData);
    cmd1_data.* = .{
        .command = try allocator.dupe(u8, "wait_load"),
        .client_stream = accepted1,
    };
    try state.pending_ipc_commands.append(allocator, cmd1_data);

    // Push a second IPC command into `workers.event_queue` to be drained
    // re-entrantly inside `handleWaitLoadCommand`.
    const cmd2_data = try allocator.create(ipc.IpcCommandData);
    cmd2_data.* = .{
        .command = try allocator.dupe(u8, "zoom 3.5"),
        .client_stream = accepted2,
    };
    try state.workers.event_queue.push(
        allocator,
        io,
        .{ .ipc_command = cmd2_data },
    );

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysExecuteIpcCommands(ctx);
    try intents_system.sysExecuteIntents(ctx);

    try std.testing.expectEqual(
        @as(usize, 0),
        state.pending_ipc_commands.items.len,
    );
    try std.testing.expectEqual(
        @as(f32, 3.5),
        state.viewer.viewport.zoom_factor.get(),
    );
}

test "sysExecuteIpcCommands - set_palette frame_allocator OOM replies error" {
    if (builtin.os.tag == .windows) return;
    const prev_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_level;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const sock_path = "/tmp/peng_test_sys_ipc4.sock";
    std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, sock_path) catch {};
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, sock_path) catch {};

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const client = try addr.connect(io);
    defer client.close(io);
    const accepted = try server.accept(io);

    const cmd_data = try allocator.create(ipc.IpcCommandData);
    cmd_data.* = .{
        .command = try allocator.dupe(u8, "palette files hero"),
        .client_stream = accepted,
    };
    try state.pending_ipc_commands.append(allocator, cmd_data);

    var failing = std.testing.FailingAllocator.init(
        allocator,
        .{ .fail_index = 0 },
    );
    const ctx = FrameContext{
        .state = &state,
        .frame_allocator = failing.allocator(),
    };
    sysExecuteIpcCommands(ctx);

    try std.testing.expectEqual(
        @as(usize, 0),
        state.pending_intents.items.len,
    );

    var read_buf: [64]u8 = undefined;
    var reader = client.reader(io, &read_buf);
    const line = try reader.interface.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("ERR OutOfMemory\n", line);
}
