const app_state = @import("../state.zig");
const context = @import("context.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const ui = @import("ui");
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

/// Returns `true` if the OS screensaver and idle power management should be
/// inhibited (only while an unpaused slideshow is actively playing in a
/// visible, non-suspended window with at least one visible slide).
fn shouldInhibitScreensaver(state: *const AppState) bool {
    return state.viewer.running and
        !state.display.isHidden() and
        !state.display.isSuspended() and
        state.viewer.isSlideshowActive() and
        !state.viewer.navigation.slideshow.isPaused() and
        !state.viewer.ui.palette.isOpen() and
        state.viewer.navigation.getVisibleCount() > 0;
}

/// System Pass: Applies window minimize/restore and occlude/expose events from
/// `ctx.input` to `state.display`. When the window transitions into a
/// suspended (minimized or occluded) state, settles in-flight UI animations
/// and resets pan/zoom/drag controllers so background timer ticks cease
/// immediately.
pub fn sysSyncWindowVisibility(ctx: FrameContext) void {
    const input_opt = ctx.input orelse return;
    if (input_opt.window_minimized == null and
        input_opt.window_occluded == null)
    {
        return;
    }
    const state = ctx.state;
    const was_suspended = state.display.isSuspended();
    if (input_opt.window_minimized) |minimized| {
        state.display.setMinimized(minimized);
    }
    if (input_opt.window_occluded) |occluded| {
        state.display.setOccluded(occluded);
    }
    if (!was_suspended and state.display.isSuspended()) {
        ui.interaction.resetInteractionState();
        state.viewer.animations.settleAll();
        state.viewer.animations.setImmediate(.image_crossfade, 1.0);
        state.viewer.image_transition = .none;
        state.viewer.pan_controller.reset();
        state.viewer.zoom_controller.reset();
        state.viewer.drag_state = .none;
        state.viewer.ui.overlays.edit_panel.active_slider = null;
    }
}

/// System Pass: Synchronizes OS window properties (title, fullscreen state,
/// and dynamic screensaver inhibition) with AppState.
///
/// Responsibilities:
/// 1. Determines window title from active image or defaults to
///    "Peng Image Viewer".
/// 2. Updates window title via SDL window handle only when the title string
///    actually changes.
/// 3. Maintains cached_title on the window display state.
/// 4. Inhibits OS screensaver only while an unpaused slideshow is actively
///    playing in a visible, unoccluded window.
pub fn sysSyncWindow(ctx: FrameContext) void {
    const state = ctx.state;
    const raw_title = formatWindowTitle(
        state.viewer.navigation.getCurrentImageEntry(),
        ctx.frame_allocator,
    );

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

                const inhibit = shouldInhibitScreensaver(state);
                if (win.screensaver_inhibited != inhibit) {
                    win.screensaver_inhibited = inhibit;
                    if (inhibit) {
                        if (!sdl.disableScreenSaver()) {
                            std.log.warn(
                                "SDL_DisableScreenSaver failed: {s}",
                                .{sdl.getError()},
                            );
                        }
                    } else {
                        if (!sdl.enableScreenSaver()) {
                            std.log.warn(
                                "SDL_EnableScreenSaver failed: {s}",
                                .{sdl.getError()},
                            );
                        }
                    }
                }
            },
            .headless => {},
        },
        .hidden => |*b| switch (b.*) {
            .windowed => |*win| {
                if (win.screensaver_inhibited) {
                    win.screensaver_inhibited = false;
                    if (!sdl.enableScreenSaver()) {
                        std.log.warn(
                            "SDL_EnableScreenSaver failed: {s}",
                            .{sdl.getError()},
                        );
                    }
                }
            },
            .headless => {},
        },
    }
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

test "shouldInhibitScreensaver requires active unpaused visible slideshow" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    _ = try app_st.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "img1.jpg" },
    });
    app_st.viewer.navigation.current_index = 0;
    app_st.display = .{
        .visible = .{
            .windowed = .{
                .handle = undefined,
            },
        },
    };

    // 1. Slideshow inactive -> do not inhibit
    try std.testing.expect(!shouldInhibitScreensaver(&app_st));

    // 2. Slideshow active and unpaused -> inhibit
    app_st.viewer.navigation.slideshow = .{ .active = .{ .interval_s = 3.0 } };
    try std.testing.expect(shouldInhibitScreensaver(&app_st));

    // 3. Slideshow explicitly paused -> do not inhibit
    app_st.viewer.navigation.slideshow.pause();
    try std.testing.expect(!shouldInhibitScreensaver(&app_st));
    app_st.viewer.navigation.slideshow.unpause();
    try std.testing.expect(shouldInhibitScreensaver(&app_st));

    // 4. Window occluded -> do not inhibit
    app_st.display.setOccluded(true);
    try std.testing.expect(!shouldInhibitScreensaver(&app_st));
    app_st.display.setOccluded(false);
    try std.testing.expect(shouldInhibitScreensaver(&app_st));

    // 5. Window minimized -> do not inhibit
    app_st.display.setMinimized(true);
    try std.testing.expect(!shouldInhibitScreensaver(&app_st));
    app_st.display.setMinimized(false);
    try std.testing.expect(shouldInhibitScreensaver(&app_st));

    // 6. Window hidden (--server mode) -> do not inhibit
    app_st.display = .{ .hidden = app_st.display.backend() };
    try std.testing.expect(!shouldInhibitScreensaver(&app_st));
}

test "sysSyncWindowVisibility updates suspension state and settles animations" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.display = .{
        .visible = .{
            .windowed = .{
                .handle = undefined,
            },
        },
    };
    app_st.viewer.animations.start(.edit_panel, 1.0, 200.0, .ease_out_quad);
    app_st.viewer.drag_state = .{ .viewport = .{ .last_x = 10, .last_y = 20 } };
    try std.testing.expect(app_st.viewer.hasActiveAnimation());

    const base_input = state_pkg.FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1,
        .scale_y = 1,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = false,
        .window_occluded = true,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };

    sysSyncWindowVisibility(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = base_input,
        .delta_time_ms = 16.0,
    });

    try std.testing.expect(app_st.display.isSuspended());
    try std.testing.expect(!app_st.viewer.hasActiveAnimation());
    try std.testing.expectEqual(
        @as(f32, 1.0),
        app_st.viewer.animations.get(.edit_panel),
    );
    try std.testing.expect(app_st.viewer.drag_state == .none);

    var expose_input = base_input;
    expose_input.window_occluded = false;
    sysSyncWindowVisibility(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = expose_input,
        .delta_time_ms = 16.0,
    });
    try std.testing.expect(!app_st.display.isSuspended());
}
