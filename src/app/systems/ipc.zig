const app_state = @import("../state.zig");
const builtin = @import("builtin");
const cache_system = @import("cache.zig");
const context = @import("context.zig");
const intents = @import("intents");
const intents_system = @import("intents.zig");
const ipc = @import("ipc");
const state_pkg = @import("state");
const std = @import("std");
const workers_mod = @import("../workers/root.zig");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;

/// System function that drains queued socket commands from `state.pending_ipc_commands`,
/// parses commands (`zoom`, `pan`, `next`, `filter`), and pushes corresponding
/// intents into `pending_intents`.
pub fn sysExecuteIpcCommands(ctx: FrameContext) void {
    const state = ctx.state;
    state.flushPendingWaitLoadStreams();
    if (state.pending_ipc_commands.items.len == 0) return;

    var will_be_hidden = switch (state.display) {
        .hidden => true,
        .visible => false,
    };

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

        if (will_be_hidden and !parsed.isAllowedWhenHidden()) {
            ipc.respondErrorName(
                state.io,
                cmd_data.client_stream,
                "WindowHidden",
            );
            continue;
        }

        switch (parsed) {
            .wait_load => {
                handleWaitLoadCommand(state, cmd_data.client_stream);
            },
            .selections => {
                handleSelectionsCommand(state, cmd_data.client_stream);
            },
            .adjust => |adj| {
                handleAdjustCommand(state, cmd_data.client_stream, adj);
            },
            .screenshot => |filepath| {
                handleScreenshotCommand(state, cmd_data, filepath);
            },
            .preview => |req| {
                handlePreviewCommand(state, cmd_data.client_stream, req);
            },
            .zoom,
            .pan,
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
            .close,
            .quit,
            .open,
            => handleIntentCommand(ctx, cmd_data, parsed, &will_be_hidden),
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

fn handleWaitLoadCommand(state: *AppState, stream: std.Io.net.Stream) void {
    state.pending_wait_load_streams.append(
        state.allocator,
        stream,
    ) catch |err| {
        std.log.err("Failed to queue IPC wait_load stream: {}", .{err});
        ipc.respondErrorName(state.io, stream, "OutOfMemory");
        return;
    };
    state.flushPendingWaitLoadStreams();
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
        .capturing = state_pkg.ActiveScreenshot{
            .path = dup_path,
            .stream = cmd_data.client_stream,
        },
    };
}

fn handlePreviewCommand(
    state: *AppState,
    stream: std.Io.net.Stream,
    req: ipc.PreviewRequest,
) void {
    const stat = std.Io.Dir.statFile(
        std.Io.Dir.cwd(),
        state.io,
        req.path,
        .{},
    ) catch |err| {
        replyIpcParseError(state.io, stream, err);
        return;
    };
    if (stat.kind == .directory) {
        ipc.respondErrorName(state.io, stream, "IsDir");
        return;
    }
    if (stat.kind != .file) {
        ipc.respondErrorName(state.io, stream, "UnsupportedFileType");
        return;
    }
    if (stat.size == 0) {
        ipc.respondErrorName(state.io, stream, "EmptyFile");
        return;
    }
    const dup_path = state.allocator.dupe(u8, req.path) catch {
        ipc.respondErrorName(state.io, stream, "OutOfMemory");
        return;
    };
    const args = state.allocator.create(
        workers_mod.PreviewWorkerArgs,
    ) catch {
        state.allocator.free(dup_path);
        ipc.respondErrorName(state.io, stream, "OutOfMemory");
        return;
    };
    args.* = .{
        .workers = &state.workers,
        .allocator = state.allocator,
        .io = state.io,
        .client_stream = stream,
        .path = dup_path,
        .max_dims = req.max_dims,
    };
    workers_mod.spawnPreview(args);
}

fn handleIntentCommand(
    ctx: FrameContext,
    cmd_data: *ipc.IpcCommandData,
    parsed: ipc.IpcCommand,
    will_be_hidden: *bool,
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
        .set_zoom,
        .zoom_by,
        .zoom_in,
        .zoom_out,
        .set_pan,
        .pan_by,
        .reset_zoom,
        .set_scale,
        .cycle_scale_mode,
        .set_filter,
        .cycle_filter,
        .cycle_filter_prev,
        .adjust,
        .rotate_cw,
        .rotate_ccw,
        .reset_rotation,
        .open_window,
        .next_image,
        .prev_image,
        .first_image,
        .last_image,
        .go_to_image,
        .refresh_directory,
        .mark_pick,
        .mark_reject,
        .unflag,
        .clear_classifications,
        .cycle_view_mode,
        .set_view_mode,
        .toggle_info,
        .set_info,
        .toggle_stats,
        .set_stats,
        .toggle_edit_panel,
        .set_edit_panel,
        .dismiss_overlays,
        .toggle_title,
        .set_title,
        .toggle_snackbar,
        .set_snackbar,
        .toggle_blur,
        .set_blur,
        .toggle_fullscreen,
        .set_fullscreen,
        .toggle_windowless,
        .set_windowless,
        .toggle_debug_mode,
        .set_debug_mode,
        .toggle_debug_thumb,
        .set_debug_thumb,
        .start_slideshow,
        .stop_slideshow,
        .toggle_manga_mode,
        .set_manga_mode,
        .toggle_crossfade,
        .set_crossfade,
        .toggle_raw_jpeg_stacking,
        .set_raw_jpeg_stacking,
        .toggle_pair_stream,
        .precache_directory,
        .quit,
        .quit_server,
        => {},
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
    switch (parsed) {
        .open => will_be_hidden.* = false,
        .close => if (state.viewer.server_mode) {
            will_be_hidden.* = true;
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
        .debug,
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
        .quit,
        .preview,
        .screenshot,
        => {},
    }
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

test "sysExecuteIpcCommands - reactive wait_load barrier waits until ready" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "testfiles/images/000_0_1024x682.jpg" } },
    );
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;
    const key = try state.cache.appendSlot(
        allocator,
        id0,
        .{ .inflight = .{ .has_thread = true } },
    );

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

    const cmd1_data = try allocator.create(ipc.IpcCommandData);
    cmd1_data.* = .{
        .command = try allocator.dupe(u8, "wait_load"),
        .client_stream = accepted1,
    };
    try state.pending_ipc_commands.append(allocator, cmd1_data);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysExecuteIpcCommands(ctx);
    try cache_system.sysUpdateCache(ctx);

    // Still decoding: stream remains queued in `pending_wait_load_streams`
    try std.testing.expectEqual(
        @as(usize, 1),
        state.pending_wait_load_streams.items.len,
    );

    // Transition slot to terminal state and run cache system tick
    state.cache.get(key).?.resident.asset = .failed;
    state.cache.get(key).?.inflight = null;
    try cache_system.sysUpdateCache(ctx);

    try std.testing.expectEqual(
        @as(usize, 0),
        state.pending_wait_load_streams.items.len,
    );

    var read_buf: [64]u8 = undefined;
    var reader = client1.reader(io, &read_buf);
    const line = try reader.interface.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("{\"ok\":true}\n", line);
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

    _ = try state.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "a.jpg" } },
    );
    _ = try state.viewer.navigation.appendEntry(
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

test "sysExecuteIpcCommands - rejects navigation when hidden (WindowHidden)" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.server_mode = true;
    state.hideWindow();
    try std.testing.expect(state.display.isHidden());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc_hidden.sock",
        .{tmp.sub_path},
    );

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    const c_next = try addr.connect(io);
    defer c_next.close(io);
    const s_next = try server.accept(io);

    const d_next = try allocator.create(ipc.IpcCommandData);
    d_next.* = .{
        .command = try allocator.dupe(u8, "next"),
        .client_stream = s_next,
    };
    try state.pending_ipc_commands.append(allocator, d_next);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysExecuteIpcCommands(ctx);

    var rbuf: [256]u8 = undefined;
    var r_next = c_next.reader(io, &rbuf);
    const line = try r_next.interface.takeDelimiterInclusive('\n');
    var parsed = try ipc.parseResponse(allocator, line);
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("WindowHidden", parsed.value.@"error".?);
}

test "sysExecuteIpcCommands - preview while hidden and bare open window" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    state.viewer.server_mode = true;
    state.hideWindow();
    try std.testing.expect(state.display.isHidden());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sock_buf: [108]u8 = undefined;
    const sock_path = try std.mem.print(
        &sock_buf,
        ".zig-cache/tmp/{s}/ipc_preview.sock",
        .{tmp.sub_path},
    );

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    // 1. Preview while hidden keeps window hidden and writes RGBA32 temp file
    const c_prev = try addr.connect(io);
    defer c_prev.close(io);
    const s_prev = try server.accept(io);

    const d_prev = try allocator.create(ipc.IpcCommandData);
    d_prev.* = .{
        .command = try allocator.dupe(
            u8,
            "preview 160 120 testfiles/images/000_0_1024x682.jpg",
        ),
        .client_stream = s_prev,
    };
    try state.pending_ipc_commands.append(allocator, d_prev);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysExecuteIpcCommands(ctx);
    try std.testing.expect(state.display.isHidden());

    var rbuf: [512]u8 = undefined;
    var r_prev = c_prev.reader(io, &rbuf);
    const prev_line = try r_prev.interface.takeDelimiterInclusive('\n');
    var parsed_prev = try ipc.parseResponse(allocator, prev_line);
    defer parsed_prev.deinit();
    try std.testing.expect(parsed_prev.value.ok);
    const temp_path = parsed_prev.value.path.?;
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, temp_path) catch {};

    try std.testing.expect(
        std.mem.find(u8, temp_path, "tty-graphics-protocol") != null,
    );
    try std.testing.expectEqual(@as(u32, 160), parsed_prev.value.w.?);
    try std.testing.expectEqual(@as(u32, 107), parsed_prev.value.h.?);

    const st = try std.Io.Dir.statFile(std.Io.Dir.cwd(), io, temp_path, .{});
    try std.testing.expectEqual(@as(u64, 160 * 107 * 4), st.size);

    // 2. Bare 'open' unhides the window and opens directory navigator
    const c_open = try addr.connect(io);
    defer c_open.close(io);
    const s_open = try server.accept(io);

    const d_open = try allocator.create(ipc.IpcCommandData);
    d_open.* = .{
        .command = try allocator.dupe(u8, "open"),
        .client_stream = s_open,
    };
    try state.pending_ipc_commands.append(allocator, d_open);

    sysExecuteIpcCommands(ctx);
    try intents_system.sysExecuteIntents(ctx);
    try std.testing.expect(!state.display.isHidden());
    try std.testing.expectEqual(
        intents.PaletteMode.directory_navigator,
        state.viewer.ui.palette.mode,
    );
}
