const app_state = @import("../state.zig");
const context = @import("context.zig");
const core = @import("core");
const geom = @import("geom");
const state_pkg = @import("state");
const std = @import("std");
const vfs = @import("vfs");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;
const MediaEntry = vfs.MediaEntry;

/// Formats the OS window title for the given media entry.
/// For pairs (RAW+JPEG), appends " [RAW+JPG]" to the RAW image basename.
fn formatWindowTitle(
    entry: ?MediaEntry,
    allocator: std.mem.Allocator,
) []const u8 {
    const media = entry orelse return "Peng Image Viewer";
    if (media.isPair()) {
        return allocator.print(
            "{s} [RAW+JPG]",
            .{media.getBasename()},
        ) catch media.getBasename();
    }
    return media.getBasename();
}

fn dimsMatchWithinTolerance(a: geom.WindowDimsI32, b: geom.WindowDimsI32, tol: u32) bool {
    const dw = @abs(@as(i64, a.w) - @as(i64, b.w));
    const dh = @abs(@as(i64, a.h) - @as(i64, b.h));
    return dw <= tol and dh <= tol;
}

/// System Pass: Synchronizes OS window properties (title, display auto-trim, and fullscreen state)
/// with AppState.
///
/// Responsibilities:
/// 1. Synchronizes window title string with active media entry or default.
/// 2. Manages window aspect-ratio auto-trimming and manual user sizing state machine.
/// 3. Repositions and resizes OS window to hug image aspect ratio within screen boundaries.
pub fn sysSyncWindow(ctx: FrameContext) void {
    const state = ctx.state;
    if (state.display.isHidden()) return;

    const raw_title = formatWindowTitle(
        state.viewer.navigation.getCurrentImageEntry(),
        ctx.frame_allocator,
    );

    // 1. Synchronize window title
    switch (state.display) {
        .visible => |*b| switch (b.*) {
            .windowed => |*win| {
                const title_changed = if (win.cached_title) |cached|
                    !std.mem.eql(u8, cached, raw_title)
                else
                    true;

                if (title_changed) {
                    if (ctx.frame_allocator.dupeSentinel(
                        u8,
                        raw_title,
                        0,
                    )) |tz| {
                        defer ctx.frame_allocator.free(tz);
                        win.handle.setTitle(tz);
                    } else |err| {
                        std.log.err(
                            "Failed to allocate window title string: {}",
                            .{err},
                        );
                    }

                    if (win.cached_title) |cached| {
                        state.allocator.free(cached);
                    }
                    win.cached_title =
                        state.allocator.dupe(u8, raw_title) catch |err| blk: {
                            std.log.err(
                                "Failed to update cached window title: {}",
                                .{err},
                            );
                            break :blk null;
                        };
                }
            },
            .headless => {},
        },
        .hidden => {},
    }

    // 2. Expire stale pending programmatic resize
    if (state.viewer.trim.pending_programmatic) |p| {
        if (ctx.now_ms > p.deadline_ms) {
            state.viewer.trim.pending_programmatic = null;
        }
    }

    // 3. Process incoming window_resized event
    if (ctx.input) |inp| {
        if (inp.window_resized) |resized| {
            if (state.viewer.viewport.mode != .manual) {
                state.viewer.viewport.zoom_factor =
                    state_pkg.ZoomFactor.init(state.getBaseScale());
            }

            if (state.display.isFullscreen() or ctx.now_ms < state.viewer.trim.suppress_manual_until_ms) {
                if (state.viewer.trim.pending_programmatic) |p| {
                    if (dimsMatchWithinTolerance(
                        resized,
                        .{ .w = p.w, .h = p.h },
                        state_pkg.WINDOW_RESIZE_TOLERANCE_PX,
                    )) {
                        state.viewer.trim.pending_programmatic = null;
                    }
                }
                // Do not switch to .manual
            } else if (state.viewer.trim.pending_programmatic) |p| {
                if (dimsMatchWithinTolerance(
                    resized,
                    .{ .w = p.w, .h = p.h },
                    state_pkg.WINDOW_RESIZE_TOLERANCE_PX,
                )) {
                    // Matches our programmatic resize echo!
                    state.viewer.trim.pending_programmatic = null;
                } else {
                    // Diverged from pending target -> user or WM manually resized!
                    state.viewer.trim.mode = .manual;
                    state.viewer.trim.pending_programmatic = null;
                }
            } else {
                // No pending programmatic resize; check if it's just a duplicate echo of last_trimmed_dims:
                const is_echo = dimsMatchWithinTolerance(
                    resized,
                    state.viewer.trim.last_trimmed_dims,
                    state_pkg.WINDOW_RESIZE_TOLERANCE_PX,
                );

                if (!is_echo) {
                    state.viewer.trim.mode = .manual;
                }
            }
        }
    }

    // 4. Perform Auto-Trimming when mode == .auto_trim and not fullscreen
    if (state.viewer.trim.mode == .auto_trim and !state.display.isFullscreen()) {
        const cur_id = state.viewer.navigation.getCurrentMediaId() orelse return;
        const cur_rot = state.viewer.viewport.rotation_angle;
        const id_changed = if (state.viewer.trim.last_trimmed_media_id) |last_id|
            last_id != cur_id
        else
            true;
        const rot_changed = !std.math.approxEqAbs(
            f32,
            state.viewer.trim.last_trimmed_rotation,
            cur_rot,
            0.01,
        );

        var raw_dims_opt: ?geom.PhysicalDims = null;
        if (state.getCurrentEntry()) |entry| {
            const auth = entry.getAuthoritativeDims();
            if (auth.w > 0.0 and auth.h > 0.0) {
                raw_dims_opt = auth;
            }
        }
        if (raw_dims_opt == null and id_changed) {
            if (state.viewer.navigation.getCurrentImageEntry()) |media| {
                if (core.image.probeMediaMetadata(state.io, media)) |meta| {
                    if (meta.dims.w > 0.0 and meta.dims.h > 0.0) {
                        raw_dims_opt = meta.dims;
                    }
                }
            }
        }

        if (raw_dims_opt) |raw_dims| {
            const raw_dims_changed = !std.math.approxEqAbs(
                f32,
                state.viewer.trim.last_trimmed_raw_dims.w,
                raw_dims.w,
                0.5,
            ) or !std.math.approxEqAbs(
                f32,
                state.viewer.trim.last_trimmed_raw_dims.h,
                raw_dims.h,
                0.5,
            );

            const needs_trim = id_changed or rot_changed or raw_dims_changed;

            if (needs_trim) {
                const usable_bounds = state.display.getUsableBounds();
                const target_dims = geom.computeTrimmedWindowDims(
                    raw_dims,
                    cur_rot,
                    .{},
                    usable_bounds,
                    .{ .w = geom.DEFAULT_MIN_W, .h = geom.DEFAULT_MIN_H },
                ) orelse return;

                const prev_dims = state.viewer.trim.last_trimmed_dims;
                if (prev_dims.w != target_dims.w or prev_dims.h != target_dims.h) {
                    state.viewer.image_transition = .none;
                    state.viewer.animations.setImmediate(.image_crossfade, 1.0);
                }

                state.viewer.trim.last_trimmed_media_id = cur_id;
                state.viewer.trim.last_trimmed_rotation = cur_rot;
                state.viewer.trim.last_trimmed_dims = target_dims;
                state.viewer.trim.last_trimmed_raw_dims = raw_dims;
                state.viewer.trim.expectProgrammaticResize(
                    target_dims,
                    ctx.now_ms,
                );

                switch (state.display) {
                    .visible => |*b| switch (b.*) {
                        .windowed => |*win| {
                            const curr_size = win.handle.getSize();
                            if (curr_size.w != target_dims.w or curr_size.h != target_dims.h) {
                                state.viewer.image_transition = .none;
                                state.viewer.animations.setImmediate(.image_crossfade, 1.0);
                                if (win.handle.getPosition()) |curr_pos| {
                                    const new_pos = geom.computeCenterPreservedPosition(
                                        .{ .x = curr_pos.x, .y = curr_pos.y },
                                        .{ .w = curr_size.w, .h = curr_size.h },
                                        target_dims,
                                        usable_bounds,
                                    );
                                    _ = win.handle.setPosition(new_pos.x, new_pos.y);
                                }
                                _ = win.handle.setSize(target_dims.w, target_dims.h);
                            }
                            state.viewer.last_win_dims = .{
                                .w = @floatFromInt(target_dims.w),
                                .h = @floatFromInt(target_dims.h),
                            };
                            if (state.viewer.viewport.mode != .manual) {
                                state.viewer.viewport.zoom_factor =
                                    state_pkg.ZoomFactor.init(state.getBaseScale());
                            }
                        },
                        .headless => {},
                    },
                    .hidden => {},
                }
            }
        }
    }
}

fn createTestInput(resized: ?geom.WindowDimsI32, now_ms: u64) state_pkg.FrameInput {
    return .{
        .win_w = 1024.0,
        .win_h = 768.0,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 0.0,
        .mouse_y = 0.0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .window_resized = resized,
        .scroll_delta_x = 0.0,
        .scroll_delta_y = 0.0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.6,
        .now_ms = now_ms,
    };
}

test "formatWindowTitle: returns default title when entry is null" {
    const allocator = std.testing.allocator;
    const title = formatWindowTitle(null, allocator);
    try std.testing.expectEqualStrings("Peng Image Viewer", title);
}

test "formatWindowTitle: returns basename for filesystem entry" {
    const allocator = std.testing.allocator;
    const entry = MediaEntry{
        .filesystem = .{ .path = "/photos/summer/vacation.jpg" },
    };
    const title = formatWindowTitle(entry, allocator);
    try std.testing.expectEqualStrings("vacation.jpg", title);
}

test "formatWindowTitle: appends [RAW+JPG] for pair entry" {
    const allocator = std.testing.allocator;
    const entry = MediaEntry{
        .pair = .{
            .raw_path = "/photos/summer/vacation.ARW",
            .jpeg_path = "/photos/summer/vacation.JPG",
        },
    };
    const title = formatWindowTitle(entry, allocator);
    defer allocator.free(title);
    try std.testing.expectEqualStrings("vacation.ARW [RAW+JPG]", title);
}

test "sysSyncWindow: no-op in headless mode without crashing" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
}

test "sysSyncWindow: auto-trimming on image load and next/prev navigation updates trim state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // Append two media items
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "landscape.png" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "portrait.png" } },
    );

    const id0 = app_st.viewer.navigation.getIdAt(0).?;
    const id1 = app_st.viewer.navigation.getIdAt(1).?;

    // Add cached metadata: entry 0 is 800x400 (aspect 2.0), entry 1 is 400x800 (aspect 0.5)
    _ = try app_st.cache.appendSlot(allocator, id0, .{
        .metadata = .{ .full_dims = .{ .w = 800.0, .h = 400.0 } },
    });
    _ = try app_st.cache.appendSlot(allocator, id1, .{
        .metadata = .{ .full_dims = .{ .w = 400.0, .h = 800.0 } },
    });

    app_st.viewer.navigation.current_index = 0;

    // First frame sync on entry 0
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 100),
        .delta_time_ms = 16.0,
        .now_ms = 100,
    });

    try std.testing.expectEqual(id0, app_st.viewer.trim.last_trimmed_media_id.?);
    try std.testing.expectEqual(@as(i32, 1024), app_st.viewer.trim.last_trimmed_dims.w);
    try std.testing.expectEqual(@as(i32, 512), app_st.viewer.trim.last_trimmed_dims.h);
    try std.testing.expect(app_st.viewer.trim.pending_programmatic != null);
    try std.testing.expectEqual(@as(i32, 1024), app_st.viewer.trim.pending_programmatic.?.w);
    try std.testing.expectEqual(@as(i32, 512), app_st.viewer.trim.pending_programmatic.?.h);
    try std.testing.expectEqual(@as(u64, 600), app_st.viewer.trim.pending_programmatic.?.deadline_ms);

    // Navigate to entry 1 (portrait)
    app_st.viewer.navigation.current_index = 1;

    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 200),
        .delta_time_ms = 16.0,
        .now_ms = 200,
    });

    try std.testing.expectEqual(id1, app_st.viewer.trim.last_trimmed_media_id.?);
    try std.testing.expectEqual(@as(i32, 384), app_st.viewer.trim.last_trimmed_dims.w);
    try std.testing.expectEqual(@as(i32, 768), app_st.viewer.trim.last_trimmed_dims.h);
    try std.testing.expect(app_st.viewer.trim.pending_programmatic != null);
    try std.testing.expectEqual(@as(i32, 384), app_st.viewer.trim.pending_programmatic.?.w);
    try std.testing.expectEqual(@as(i32, 768), app_st.viewer.trim.pending_programmatic.?.h);
    try std.testing.expectEqual(@as(u64, 700), app_st.viewer.trim.pending_programmatic.?.deadline_ms);
}

test "sysSyncWindow: auto-trimming on 90 degree rotation transposes trim dims" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "image.png" } },
    );
    const id = app_st.viewer.navigation.getIdAt(0).?;
    _ = try app_st.cache.appendSlot(allocator, id, .{
        .metadata = .{ .full_dims = .{ .w = 800.0, .h = 400.0 } },
    });
    app_st.viewer.navigation.current_index = 0;

    // Initial orientation 0.0 -> 1024x512
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 100),
        .delta_time_ms = 16.0,
        .now_ms = 100,
    });
    try std.testing.expectEqual(@as(i32, 1024), app_st.viewer.trim.last_trimmed_dims.w);
    try std.testing.expectEqual(@as(i32, 512), app_st.viewer.trim.last_trimmed_dims.h);

    // Rotate 90 degrees
    app_st.viewer.viewport.rotation_angle = 90.0;

    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 150),
        .delta_time_ms = 16.0,
        .now_ms = 150,
    });

    try std.testing.expectEqual(@as(f32, 90.0), app_st.viewer.trim.last_trimmed_rotation);
    try std.testing.expectEqual(@as(i32, 384), app_st.viewer.trim.last_trimmed_dims.w);
    try std.testing.expectEqual(@as(i32, 768), app_st.viewer.trim.last_trimmed_dims.h);
}

test "sysSyncWindow: matching window_resized event clears pending_programmatic and stays in auto_trim" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "image.png" } },
    );
    const id = app_st.viewer.navigation.getIdAt(0).?;
    _ = try app_st.cache.appendSlot(allocator, id, .{
        .metadata = .{ .full_dims = .{ .w = 800.0, .h = 400.0 } },
    });
    app_st.viewer.navigation.current_index = 0;

    // Initial auto-trim -> sets pending_programmatic to 1024x512
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 100),
        .delta_time_ms = 16.0,
        .now_ms = 100,
    });
    try std.testing.expect(app_st.viewer.trim.pending_programmatic != null);
    try std.testing.expectEqual(state_pkg.WindowSizingMode.auto_trim, app_st.viewer.trim.mode);

    // Matching window_resized event echo (exact match or within 2px)
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(.{ .w = 1024, .h = 512 }, 150),
        .delta_time_ms = 16.0,
        .now_ms = 150,
    });

    try std.testing.expect(app_st.viewer.trim.pending_programmatic == null);
    try std.testing.expectEqual(state_pkg.WindowSizingMode.auto_trim, app_st.viewer.trim.mode);
}

test "sysSyncWindow: diverging window_resized event transitions trim mode to manual" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "image1.png" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "image2.png" } },
    );
    const id0 = app_st.viewer.navigation.getIdAt(0).?;
    const id1 = app_st.viewer.navigation.getIdAt(1).?;

    _ = try app_st.cache.appendSlot(allocator, id0, .{
        .metadata = .{ .full_dims = .{ .w = 800.0, .h = 400.0 } },
    });
    _ = try app_st.cache.appendSlot(allocator, id1, .{
        .metadata = .{ .full_dims = .{ .w = 400.0, .h = 800.0 } },
    });
    app_st.viewer.navigation.current_index = 0;

    // Initial auto-trim -> target 1024x512
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 100),
        .delta_time_ms = 16.0,
        .now_ms = 100,
    });
    try std.testing.expectEqual(state_pkg.WindowSizingMode.auto_trim, app_st.viewer.trim.mode);

    // User manually resizes window to 600x400 (diverges from 1024x512)
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(.{ .w = 600, .h = 400 }, 150),
        .delta_time_ms = 16.0,
        .now_ms = 150,
    });

    try std.testing.expectEqual(state_pkg.WindowSizingMode.manual, app_st.viewer.trim.mode);
    try std.testing.expect(app_st.viewer.trim.pending_programmatic == null);

    // Subsequent navigation to image 1 preserves manual mode and does NOT auto-trim
    app_st.viewer.navigation.current_index = 1;

    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 200),
        .delta_time_ms = 16.0,
        .now_ms = 200,
    });

    try std.testing.expectEqual(state_pkg.WindowSizingMode.manual, app_st.viewer.trim.mode);
    // last_trimmed_media_id remains id0 since auto-trimming was bypassed in manual mode
    try std.testing.expectEqual(id0, app_st.viewer.trim.last_trimmed_media_id.?);
    try std.testing.expectEqual(@as(i32, 1024), app_st.viewer.trim.last_trimmed_dims.w);
}

test "sysSyncWindow: no-op when state.display is hidden" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    // Set display to hidden (as in resident server mode with window closed)
    app_st.display = .{ .hidden = .headless };

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "image.png" } },
    );
    const id = app_st.viewer.navigation.getIdAt(0).?;
    _ = try app_st.cache.appendSlot(allocator, id, .{
        .metadata = .{ .full_dims = .{ .w = 800.0, .h = 400.0 } },
    });
    app_st.viewer.navigation.current_index = 0;

    // Send a resized event while hidden
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(.{ .w = 500, .h = 500 }, 100),
        .delta_time_ms = 16.0,
        .now_ms = 100,
    });

    // Verify it was a complete no-op: mode did NOT switch to .manual, last_trimmed_media_id is null
    try std.testing.expectEqual(state_pkg.WindowSizingMode.auto_trim, app_st.viewer.trim.mode);
    try std.testing.expectEqual(@as(?vfs.MediaId, null), app_st.viewer.trim.last_trimmed_media_id);
    try std.testing.expect(app_st.viewer.trim.pending_programmatic == null);
}

test "sysSyncWindow: authoritative dimensions upgrade re-trims window on same media id" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "image.png" } },
    );
    const id = app_st.viewer.navigation.getIdAt(0).?;

    // Initial thumbnail dimensions: 160x120 (4:3 aspect ratio)
    _ = try app_st.cache.appendSlot(allocator, id, .{
        .metadata = .{ .full_dims = .{ .w = 160.0, .h = 120.0 } },
    });
    app_st.viewer.navigation.current_index = 0;

    // Initial auto-trim with 160x120 -> hugs 1024x768 ceiling
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 100),
        .delta_time_ms = 16.0,
        .now_ms = 100,
    });
    try std.testing.expectEqual(@as(i32, 1024), app_st.viewer.trim.last_trimmed_dims.w);
    try std.testing.expectEqual(@as(i32, 768), app_st.viewer.trim.last_trimmed_dims.h);

    // Full decode completes: upgrade authoritative dimensions to 800x400 (2:1 aspect ratio) on the same MediaId
    const key = app_st.cache.activeKey(id);
    if (app_st.cache.get(key)) |entry_ptr| {
        entry_ptr.metadata.full_dims = .{ .w = 800.0, .h = 400.0 };
    }

    // Next frame sync re-trims to 1024x512 despite same MediaId
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 200),
        .delta_time_ms = 16.0,
        .now_ms = 200,
    });

    try std.testing.expectEqual(@as(i32, 1024), app_st.viewer.trim.last_trimmed_dims.w);
    try std.testing.expectEqual(@as(i32, 512), app_st.viewer.trim.last_trimmed_dims.h);
    try std.testing.expect(app_st.viewer.trim.pending_programmatic != null);
    try std.testing.expectEqual(@as(i32, 1024), app_st.viewer.trim.pending_programmatic.?.w);
    try std.testing.expectEqual(@as(i32, 512), app_st.viewer.trim.pending_programmatic.?.h);
}

test "sysSyncWindow: initial configure echo at default 1024x768 preserves auto_trim whereas 800x600 transitions to manual" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    try std.testing.expectEqual(@as(?vfs.MediaId, null), app_st.viewer.trim.last_trimmed_media_id);
    try std.testing.expect(app_st.viewer.trim.pending_programmatic == null);
    try std.testing.expectEqual(state_pkg.WindowSizingMode.auto_trim, app_st.viewer.trim.mode);

    // Initial OS configure echo at default opening size (1024x768)
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(.{ .w = 1024, .h = 768 }, 100),
        .delta_time_ms = 16.0,
        .now_ms = 100,
    });
    try std.testing.expectEqual(state_pkg.WindowSizingMode.auto_trim, app_st.viewer.trim.mode);

    // Manual window resize event of 800x600 transitions to manual
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(.{ .w = 800, .h = 600 }, 200),
        .delta_time_ms = 16.0,
        .now_ms = 200,
    });
    try std.testing.expectEqual(state_pkg.WindowSizingMode.manual, app_st.viewer.trim.mode);
}

test "sysSyncWindow: bypasses crossfade when trimmed dimensions change and preserves crossfade when unchanged" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img0.png" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img1.png" } },
    );
    _ = try app_st.viewer.navigation.appendEntry(
        allocator,
        .{ .filesystem = .{ .path = "img2.png" } },
    );

    const id0 = app_st.viewer.navigation.getIdAt(0).?;
    const id1 = app_st.viewer.navigation.getIdAt(1).?;
    const id2 = app_st.viewer.navigation.getIdAt(2).?;

    // img0: 800x400 (aspect 2.0 -> trimmed 1024x512)
    _ = try app_st.cache.appendSlot(allocator, id0, .{
        .metadata = .{ .full_dims = .{ .w = 800.0, .h = 400.0 } },
    });
    // img1: 400x600 (aspect 2/3 -> trimmed 512x768)
    _ = try app_st.cache.appendSlot(allocator, id1, .{
        .metadata = .{ .full_dims = .{ .w = 400.0, .h = 600.0 } },
    });
    // img2: 400x600 (aspect 2/3 -> trimmed 512x768)
    _ = try app_st.cache.appendSlot(allocator, id2, .{
        .metadata = .{ .full_dims = .{ .w = 400.0, .h = 600.0 } },
    });

    app_st.viewer.navigation.current_index = 0;

    // Initial sync on img0
    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 100),
        .delta_time_ms = 16.0,
        .now_ms = 100,
    });
    try std.testing.expectEqual(@as(i32, 1024), app_st.viewer.trim.last_trimmed_dims.w);
    try std.testing.expectEqual(@as(i32, 512), app_st.viewer.trim.last_trimmed_dims.h);

    // 1. Start active crossfade transition from img0 to img1 (1024x512 -> 512x768: dimensions differ)
    app_st.viewer.image_transition = .{ .active = .{ .prev_index = 0, .prev_rotation = 0.0 } };
    app_st.viewer.animations.startFrom(
        .image_crossfade,
        0.0,
        1.0,
        state_pkg.DURATION_IMAGE_DISSOLVE_MS,
        .ease_in_out_cubic,
    );
    try std.testing.expect(app_st.viewer.image_transition != .none);
    try std.testing.expect(app_st.viewer.animations.isActive(.image_crossfade));

    app_st.viewer.navigation.current_index = 1;

    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 200),
        .delta_time_ms = 16.0,
        .now_ms = 200,
    });

    // Trimmed dimensions changed (1024x512 -> 512x768): crossfade must be bypassed immediately
    try std.testing.expectEqual(@as(i32, 512), app_st.viewer.trim.last_trimmed_dims.w);
    try std.testing.expectEqual(@as(i32, 768), app_st.viewer.trim.last_trimmed_dims.h);
    try std.testing.expectEqual(state_pkg.ImageTransition.none, app_st.viewer.image_transition);
    try std.testing.expectEqual(@as(f32, 1.0), app_st.viewer.animations.get(.image_crossfade));

    // 2. Start active crossfade transition from img1 to img2 (512x768 -> 512x768: dimensions unchanged)
    app_st.viewer.image_transition = .{ .active = .{ .prev_index = 1, .prev_rotation = 0.0 } };
    app_st.viewer.animations.startFrom(
        .image_crossfade,
        0.0,
        1.0,
        state_pkg.DURATION_IMAGE_DISSOLVE_MS,
        .ease_in_out_cubic,
    );
    try std.testing.expect(app_st.viewer.image_transition != .none);
    try std.testing.expect(app_st.viewer.animations.isActive(.image_crossfade));

    app_st.viewer.navigation.current_index = 2;

    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = createTestInput(null, 300),
        .delta_time_ms = 16.0,
        .now_ms = 300,
    });

    // Trimmed dimensions unchanged (512x768 -> 512x768): crossfade transition must be preserved
    try std.testing.expectEqual(@as(i32, 512), app_st.viewer.trim.last_trimmed_dims.w);
    try std.testing.expectEqual(@as(i32, 768), app_st.viewer.trim.last_trimmed_dims.h);
    try std.testing.expect(app_st.viewer.image_transition != .none);
    try std.testing.expect(app_st.viewer.image_transition == .active);
    try std.testing.expect(app_st.viewer.animations.isActive(.image_crossfade));
}
