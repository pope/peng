const state_pkg = @import("state");
const std = @import("std");

const context = @import("context.zig");

const FrameContext = context.FrameContext;
const MediaEntry = state_pkg.MediaEntry;

/// Formats the OS window title for the given media entry.
/// For pairs (RAW+JPEG), appends " [RAW+JPG]" to the RAW image basename.
fn formatWindowTitle(
    entry: ?MediaEntry,
    allocator: std.mem.Allocator,
) []const u8 {
    const media = entry orelse return "Peng Image Viewer";
    if (media.isPair()) {
        return std.fmt.allocPrint(
            allocator,
            "{s} [RAW+JPG]",
            .{media.getBasename()},
        ) catch media.getBasename();
    }
    return media.getBasename();
}

/// System Pass: Synchronizes OS window properties (title, fullscreen state)
/// with AppState.
///
/// Responsibilities:
/// 1. Determines window title from active image or defaults to
///    "Peng Image Viewer".
/// 2. Updates window title via SDL window handle only when the title string
///    actually changes.
/// 3. Maintains cached_title on the window display state.
pub fn sysSyncWindow(ctx: FrameContext) void {
    const state = ctx.state;
    const raw_title = formatWindowTitle(
        state.viewer.navigation.getCurrentImageEntry(),
        ctx.frame_allocator,
    );

    switch (state.viewer.display) {
        .windowed => |*win| {
            const title_changed = if (win.cached_title) |cached|
                !std.mem.eql(u8, cached, raw_title)
            else
                true;

            if (title_changed) {
                if (ctx.frame_allocator.dupeZ(u8, raw_title)) |tz| {
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
        else => {},
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
    const AppState = @import("../state.zig").AppState;
    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    sysSyncWindow(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .delta_time_ms = 16.0,
    });
}
