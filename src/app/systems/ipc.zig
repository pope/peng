const app_events = @import("../events.zig");
const app_state = @import("../state.zig");
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

    for (state.pending_ipc_commands.items) |cmd_data| {
        defer {
            state.allocator.free(cmd_data.command);
            state.allocator.destroy(cmd_data);
        }

        const parsed = ipc.IpcCommand.parse(cmd_data.command) catch |err| {
            var msg_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(
                &msg_buf,
                "ERR {s}\n",
                .{@errorName(err)},
            ) catch "ERR ParseError\n";
            var buf: [512]u8 = undefined;
            var writer = cmd_data.client_stream.writer(state.io, &buf);
            if (writer.interface.writeAll(err_msg)) {
                writer.interface.flush() catch |flush_err| {
                    std.log.warn("Failed to flush IPC parse error response: {}", .{flush_err});
                };
            } else |write_err| {
                std.log.warn("Failed to write IPC parse error response: {}", .{write_err});
            }
            cmd_data.client_stream.close(state.io);
            continue;
        };

        switch (parsed) {
            .wait_load => {
                var attempts: u32 = 0;
                while (attempts < 1000) : (attempts += 1) {
                    _ = app_events.drainWorkerEvents(state);
                    state.prepareCacheTextures();
                    if (state.getCurrentEntry()) |entry| {
                        if (entry.status != .decoding) break;
                    }
                    std.Io.sleep(
                        state.io,
                        std.Io.Duration.fromMilliseconds(10),
                        .awake,
                    ) catch |sleep_err| {
                        std.log.warn("wait_load sleep interrupted: {}", .{sleep_err});
                    };
                }
                ipc.respondOk(state.io, cmd_data.client_stream) catch |err| {
                    std.log.err("Failed to respond OK for wait_load command: {}", .{err});
                };
            },
            .adjust => |adj| {
                state.pushIntent(.{ .set_brightness = adj.brightness }) catch |err| {
                    std.log.err("Failed to push brightness adjust intent: {}", .{err});
                };
                state.pushIntent(.{ .set_contrast = adj.contrast }) catch |err| {
                    std.log.err("Failed to push contrast adjust intent: {}", .{err});
                };
                ipc.respondOk(state.io, cmd_data.client_stream) catch |err| {
                    std.log.err("Failed to respond OK for adjust command: {}", .{err});
                };
            },
            .screenshot => |filepath| {
                if (filepath.len > 512) {
                    var write_buf: [128]u8 = undefined;
                    var writer = cmd_data.client_stream.writer(state.io, &write_buf);
                    writer.interface.writeAll("ERR PathTooLong\n") catch |err| {
                        std.log.warn("IPC screenshot response failed: {}", .{err});
                    };
                    writer.interface.flush() catch |err| {
                        std.log.warn("IPC flush failed: {}", .{err});
                    };
                    cmd_data.client_stream.close(state.io);
                } else if (state.viewer.ui.screenshot_mode == .capturing) {
                    var write_buf: [128]u8 = undefined;
                    var writer = cmd_data.client_stream.writer(state.io, &write_buf);
                    writer.interface.writeAll("ERR Busy\n") catch |err| {
                        std.log.warn("IPC screenshot response failed: {}", .{err});
                    };
                    writer.interface.flush() catch |err| {
                        std.log.warn("IPC flush failed: {}", .{err});
                    };
                    cmd_data.client_stream.close(state.io);
                } else {
                    const dup_path = state.allocator.dupeZ(u8, filepath) catch {
                        var write_buf: [128]u8 = undefined;
                        var writer = cmd_data.client_stream.writer(state.io, &write_buf);
                        writer.interface.writeAll("ERR OutOfMemory\n") catch |err| {
                            std.log.warn("IPC screenshot response failed: {}", .{err});
                        };
                        writer.interface.flush() catch |err| {
                            std.log.warn("IPC flush failed: {}", .{err});
                        };
                        cmd_data.client_stream.close(state.io);
                        continue;
                    };
                    state.viewer.ui.screenshot_mode = .{
                        .capturing = state_pkg.types.ActiveScreenshot{
                            .path = dup_path,
                            .stream = cmd_data.client_stream,
                        },
                    };
                }
            },
            else => {
                if (parsed.toIntent()) |intent| {
                    var final_intent = intent;
                    switch (intent) {
                        .set_palette => |p| {
                            if (p.query) |q| {
                                if (ctx.frame_allocator.dupe(u8, q)) |dup_q| {
                                    final_intent = .{
                                        .set_palette = .{
                                            .mode = p.mode,
                                            .query = dup_q,
                                        },
                                    };
                                } else |err| {
                                    std.log.warn(
                                        "Failed to dupe query for set_palette intent: {}",
                                        .{err},
                                    );
                                }
                            }
                        },
                        else => {},
                    }
                    state.pushIntent(final_intent) catch |err| {
                        std.log.err("Failed to push intent from IPC command: {}", .{err});
                    };
                    ipc.respondOk(state.io, cmd_data.client_stream) catch |err| {
                        std.log.err("Failed to respond OK to IPC client: {}", .{err});
                    };
                } else {
                    cmd_data.client_stream.close(state.io);
                }
            },
        }
    }
    state.pending_ipc_commands.clearRetainingCapacity();
}

test "sysExecuteIpcCommands - drains pending commands and mutates state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    // Create mock IPC command data
    const cmd_str = try allocator.dupe(u8, "zoom 2.0");
    const cmd_data = try allocator.create(ipc.IpcCommandData);
    cmd_data.* = .{
        .command = cmd_str,
        .client_stream = undefined,
    };

    try state.pending_ipc_commands.append(allocator, cmd_data);
    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysExecuteIpcCommands(ctx);
    try intents_system.sysExecuteIntents(ctx);

    try std.testing.expectEqual(@as(usize, 0), state.pending_ipc_commands.items.len);
    try std.testing.expectEqual(@as(f32, 2.0), state.viewer.viewport.zoom_factor.get());
}

test "sysExecuteIpcCommands - multiple queued commands and adjust command" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    const cmd1_str = try allocator.dupe(u8, "adjust 0.5 2.0");
    const cmd1_data = try allocator.create(ipc.IpcCommandData);
    cmd1_data.* = .{ .command = cmd1_str, .client_stream = undefined };
    try state.pending_ipc_commands.append(allocator, cmd1_data);

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysExecuteIpcCommands(ctx);
    try intents_system.sysExecuteIntents(ctx);

    try std.testing.expectEqual(@as(usize, 0), state.pending_ipc_commands.items.len);
    try std.testing.expectEqual(@as(f32, 0.5), state.viewer.viewport.brightness);
    try std.testing.expectEqual(@as(f32, 2.0), state.viewer.viewport.contrast);
}
