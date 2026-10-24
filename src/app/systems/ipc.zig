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
            .selections => {
                handleSelectionsCommand(state, cmd_data.client_stream);
            },
            .adjust => |adj| {
                handleAdjustCommand(state, cmd_data.client_stream, adj);
            },
            .screenshot => |filepath| {
                handleScreenshotCommand(state, cmd_data, filepath);
            },
            .zoom,
            .pan,
            .tone,
            .color,
            .presence,
            .clarity,
            .texture,
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
            .reset_view,
            .reset_adjustments,
            .next,
            .prev,
            .pick,
            .reject,
            .unflag,
            .clear_selections,
            .view,
            .precache,
            .quit,
            .open,
            => handleIntentCommand(ctx, cmd_data, parsed),
        }
    }
    state.pending_ipc_commands.clearRetainingCapacity();
}

fn replyIpcParseError(
    io: std.Io,
    stream: std.Io.net.Stream,
    err: anyerror,
) void {
    ipc.respondErrorName(io, stream, @errorName(err));
}

fn handleSelectionsCommand(state: *AppState, stream: std.Io.net.Stream) void {
    state.pending_selection_streams.append(
        state.allocator,
        stream,
    ) catch |err| {
        std.log.err("Failed to queue IPC selections stream: {}", .{err});
        ipc.respondErrorName(state.io, stream, "OutOfMemory");
    };
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

        if (!state.viewer.navigation.isLoadingFiles()) {
            if (state.getCurrentEntry()) |entry| {
                const is_ready = switch (entry.status) {
                    .decoding, .uploading => false,
                    .loaded_cpu => state.gpu_device == null,
                    .loaded_gpu, .failed => true,
                };
                if (is_ready) break;
            } else if (state.viewer.navigation.current_index == null) {
                break;
            }
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
        ipc.respondErrorName(state.io, stream, "OutOfMemory");
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
        ipc.respondErrorName(state.io, stream, "OutOfMemory");
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
            ipc.respondErrorName(state.io, stream, "OutOfMemory");
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
        ipc.respondErrorName(
            state.io,
            cmd_data.client_stream,
            "PathTooLong",
        );
        return;
    }
    if (state.viewer.ui.screenshot_mode == .capturing) {
        ipc.respondErrorName(state.io, cmd_data.client_stream, "Busy");
        return;
    }
    const dup_path = state.allocator.dupeSentinel(u8, filepath, 0) catch {
        ipc.respondErrorName(
            state.io,
            cmd_data.client_stream,
            "OutOfMemory",
        );
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
        .open_path => |p| {
            _ = std.Io.Dir.statFile(
                std.Io.Dir.cwd(),
                state.io,
                p,
                .{},
            ) catch |err| {
                replyIpcParseError(state.io, cmd_data.client_stream, err);
                return;
            };
            const dup_p = ctx.frame_allocator.dupe(u8, p) catch |err| {
                std.log.warn(
                    "Failed to dupe path for open_path intent: {}",
                    .{err},
                );
                ipc.respondErrorName(
                    state.io,
                    cmd_data.client_stream,
                    "OutOfMemory",
                );
                return;
            };
            final_intent = .{ .open_path = dup_p };
        },
        .set_palette => |p| {
            if (p.query) |q| {
                const dup_q = ctx.frame_allocator.dupe(u8, q) catch |err| {
                    std.log.warn(
                        "Failed to dupe query for set_palette intent: {}",
                        .{err},
                    );
                    ipc.respondErrorName(
                        state.io,
                        cmd_data.client_stream,
                        "OutOfMemory",
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
        ipc.respondErrorName(
            state.io,
            cmd_data.client_stream,
            "OutOfMemory",
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc1.sock",
        .{tmp.sub_path},
    );

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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc2.sock",
        .{tmp.sub_path},
    );

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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc3.sock",
        .{tmp.sub_path},
    );

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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc4.sock",
        .{tmp.sub_path},
    );

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
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":\"OutOfMemory\"}\n",
        line,
    );
}

test "sysExecuteIpcCommands - screenshot spaces and swapchain miss error" {
    if (builtin.os.tag == .windows) return;
    const prev_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_level;

    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc5.sock",
        .{tmp.sub_path},
    );

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const client = try addr.connect(io);
    defer client.close(io);
    const accepted = try server.accept(io);

    const cmd_data = try allocator.create(ipc.IpcCommandData);
    cmd_data.* = .{
        .command = try allocator.dupe(
            u8,
            "screenshot /tmp/dir with spaces/capture.png",
        ),
        .client_stream = accepted,
    };
    try state.pending_ipc_commands.append(allocator, cmd_data);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysExecuteIpcCommands(ctx);

    try std.testing.expect(state.viewer.ui.screenshot_mode == .capturing);
    try std.testing.expectEqualStrings(
        "/tmp/dir with spaces/capture.png",
        state.viewer.ui.screenshot_mode.capturing.path,
    );

    state.handleScreenshotPostRender(error.SwapchainTextureUnavailable);
    try std.testing.expect(state.viewer.ui.screenshot_mode == .idle);

    var read_buf: [64]u8 = undefined;
    var reader = client.reader(io, &read_buf);
    const line = try reader.interface.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":\"SwapchainTextureUnavailable\"}\n",
        line,
    );
}

test "sysExecuteIpcCommands - open command dupes into arena and rejects error" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    var frame_arena: std.heap.ArenaAllocator = .init(allocator);
    defer frame_arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc_open.sock",
        .{tmp.sub_path},
    );

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    // 1. Nonexistent path replies with JSON error and does not push an intent
    {
        const client = try addr.connect(io);
        defer client.close(io);
        const accepted = try server.accept(io);

        const cmd_data = try allocator.create(ipc.IpcCommandData);
        cmd_data.* = .{
            .command = try allocator.dupe(
                u8,
                "open testfiles/images/does_not_exist.jpg",
            ),
            .client_stream = accepted,
        };
        try state.pending_ipc_commands.append(allocator, cmd_data);

        const ctx = FrameContext{
            .state = &state,
            .frame_allocator = frame_arena.allocator(),
        };
        sysExecuteIpcCommands(ctx);
        try std.testing.expectEqual(
            @as(usize, 0),
            state.pending_intents.items.len,
        );

        var read_buf: [64]u8 = undefined;
        var reader = client.reader(io, &read_buf);
        const line = try reader.interface.takeDelimiterInclusive('\n');
        try std.testing.expect(ipc.isErrorResponse(line));
        try std.testing.expect(
            std.mem.startsWith(u8, line, "{\"ok\":false,\"error\":\""),
        );
    }

    // 2. Valid path replies OK, survives command buffer free via
    // frame_allocator, and executes
    {
        const client = try addr.connect(io);
        defer client.close(io);
        const accepted = try server.accept(io);

        const cmd_data = try allocator.create(ipc.IpcCommandData);
        cmd_data.* = .{
            .command = try allocator.dupe(
                u8,
                "open testfiles/images/000_0_1024x682.jpg",
            ),
            .client_stream = accepted,
        };
        try state.pending_ipc_commands.append(allocator, cmd_data);

        const ctx = FrameContext{
            .state = &state,
            .frame_allocator = frame_arena.allocator(),
        };
        sysExecuteIpcCommands(ctx);
        try std.testing.expectEqual(
            @as(usize, 1),
            state.pending_intents.items.len,
        );
        try intents_system.sysExecuteIntents(ctx);
        try std.testing.expectEqual(
            @as(?usize, 0),
            state.viewer.navigation.current_index,
        );

        var read_buf: [64]u8 = undefined;
        var reader = client.reader(io, &read_buf);
        const line = try reader.interface.takeDelimiterInclusive('\n');
        try std.testing.expectEqualStrings("{\"ok\":true}\n", line);
    }
}

test "sysExecuteIpcCommands - selections and clear_selections JSON workflow" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "a.jpg" } },
    );
    try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "b.jpg" } },
    );
    state.viewer.navigation.current_index = 0;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc_sel.sock",
        .{tmp.sub_path},
    );

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };

    // Pick first image, advance to second, reject second, then query selections
    const c_pick = try addr.connect(io);
    defer c_pick.close(io);
    const s_pick = try server.accept(io);

    const c_next = try addr.connect(io);
    defer c_next.close(io);
    const s_next = try server.accept(io);

    const c_rej = try addr.connect(io);
    defer c_rej.close(io);
    const s_rej = try server.accept(io);

    const c_sel1 = try addr.connect(io);
    defer c_sel1.close(io);
    const s_sel1 = try server.accept(io);

    const d_pick = try allocator.create(ipc.IpcCommandData);
    d_pick.* = .{
        .command = try allocator.dupe(u8, "pick"),
        .client_stream = s_pick,
    };
    const d_next = try allocator.create(ipc.IpcCommandData);
    d_next.* = .{
        .command = try allocator.dupe(u8, "next"),
        .client_stream = s_next,
    };
    const d_rej = try allocator.create(ipc.IpcCommandData);
    d_rej.* = .{
        .command = try allocator.dupe(u8, "reject"),
        .client_stream = s_rej,
    };
    const d_sel1 = try allocator.create(ipc.IpcCommandData);
    d_sel1.* = .{
        .command = try allocator.dupe(u8, "selections"),
        .client_stream = s_sel1,
    };
    try state.pending_ipc_commands.append(allocator, d_pick);
    try state.pending_ipc_commands.append(allocator, d_next);
    try state.pending_ipc_commands.append(allocator, d_rej);
    try state.pending_ipc_commands.append(allocator, d_sel1);

    sysExecuteIpcCommands(ctx);
    try intents_system.sysExecuteIntents(ctx);

    var rbuf: [256]u8 = undefined;
    var r_sel1 = c_sel1.reader(io, &rbuf);
    const line1 = try r_sel1.interface.takeDelimiterInclusive('\n');
    var parsed1 = try ipc.parseResponse(allocator, line1);
    defer parsed1.deinit();
    try std.testing.expect(parsed1.value.ok);
    try std.testing.expectEqual(@as(usize, 1), parsed1.value.picks.?.len);
    try std.testing.expectEqualStrings("a.jpg", parsed1.value.picks.?[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed1.value.rejects.?.len);
    try std.testing.expectEqualStrings("b.jpg", parsed1.value.rejects.?[0]);

    // Clear selections and query again
    const c_clr = try addr.connect(io);
    defer c_clr.close(io);
    const s_clr = try server.accept(io);

    const c_sel2 = try addr.connect(io);
    defer c_sel2.close(io);
    const s_sel2 = try server.accept(io);

    const d_clr = try allocator.create(ipc.IpcCommandData);
    d_clr.* = .{
        .command = try allocator.dupe(u8, "clear_selections"),
        .client_stream = s_clr,
    };
    const d_sel2 = try allocator.create(ipc.IpcCommandData);
    d_sel2.* = .{
        .command = try allocator.dupe(u8, "selections"),
        .client_stream = s_sel2,
    };
    try state.pending_ipc_commands.append(allocator, d_clr);
    try state.pending_ipc_commands.append(allocator, d_sel2);

    sysExecuteIpcCommands(ctx);
    try intents_system.sysExecuteIntents(ctx);

    var r_clr = c_clr.reader(io, &rbuf);
    const clr_line = try r_clr.interface.takeDelimiterInclusive('\n');
    var parsed_clr = try ipc.parseResponse(allocator, clr_line);
    defer parsed_clr.deinit();
    try std.testing.expect(parsed_clr.value.ok);

    var r_sel2 = c_sel2.reader(io, &rbuf);
    const line2 = try r_sel2.interface.takeDelimiterInclusive('\n');
    var parsed2 = try ipc.parseResponse(allocator, line2);
    defer parsed2.deinit();
    try std.testing.expect(parsed2.value.ok);
    try std.testing.expectEqual(@as(usize, 0), parsed2.value.picks.?.len);
    try std.testing.expectEqual(@as(usize, 0), parsed2.value.rejects.?.len);
}
