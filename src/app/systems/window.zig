const std = @import("std");
const FrameContext = @import("context.zig").FrameContext;

/// System Pass: Synchronizes OS window properties (title, fullscreen state) with AppState.
///
/// Responsibilities:
/// 1. Determines window title from active image basename or defaults to "Peng Image Viewer".
/// 2. Updates window title via SDL window handle only when the title string actually changes.
/// 3. Maintains cached_title on the window display state.
pub fn sysSyncWindow(ctx: FrameContext) void {
    const state = ctx.state;
    var raw_title: []const u8 = "Peng Image Viewer";
    const total_images = state.viewer.navigation.count();
    if (total_images > 0) {
        if (state.viewer.navigation.getCurrentImageEntry()) |media| {
            raw_title = media.getBasename();
        }
    }

    switch (state.viewer.display) {
        .windowed => |*win| {
            const title_changed = if (win.cached_title) |cached|
                !std.mem.eql(u8, cached, raw_title)
            else
                true;

            if (title_changed) {
                if (ctx.frame_allocator.dupeZ(u8, raw_title)) |tz| {
                    win.handle.setTitle(tz);
                } else |err| {
                    std.log.err("Failed to allocate window title string: {}", .{err});
                }

                if (win.cached_title) |cached| {
                    state.allocator.free(cached);
                }
                win.cached_title = state.allocator.dupe(u8, raw_title) catch |err| blk: {
                    std.log.err("Failed to update cached window title: {}", .{err});
                    break :blk null;
                };
            }
        },
        else => {},
    }
}
