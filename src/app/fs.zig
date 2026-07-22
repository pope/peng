const std = @import("std");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |char_a, index| {
        if (std.ascii.toLower(char_a) != std.ascii.toLower(b[index])) return false;
    }
    return true;
}

pub fn isImageExtension(ext: []const u8) bool {
    const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".webp" };
    for (extensions) |e| {
        if (eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

pub fn scanDirectory(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, dir_path: []const u8, list: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open directory '{s}': {}", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries = std.ArrayList([]const u8).empty;
    defer dir_entries.deinit(gpa);

    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (isImageExtension(ext)) {
                const full_path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                try dir_entries.append(gpa, full_path);
            }
        }
    }

    // Sort entries alphabetically
    std.mem.sort([]const u8, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    try list.appendSlice(gpa, dir_entries.items);
}

pub fn readPipedStdin(state: *ViewerState, io: std.Io, gpa: std.mem.Allocator) !void {
    const is_stdin_piped = !(std.Io.File.stdin().isTty(io) catch false);
    if (is_stdin_piped) {
        var read_buf: [4096]u8 = undefined;
        var stdin_file_reader = std.Io.File.Reader.init(std.Io.File.stdin(), io, &read_buf);
        const stdin = &stdin_file_reader.interface;

        while (try stdin.takeDelimiter('\n')) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n ");
            if (trimmed.len > 0) {
                if (std.Io.Dir.statFile(std.Io.Dir.cwd(), io, trimmed, .{})) |s| {
                    if (s.kind == .directory) {
                        try scanDirectory(gpa, state.directory_arena.allocator(), io, trimmed, &state.image_list);
                    } else if (isImageExtension(std.fs.path.extension(trimmed))) {
                        const dup = try state.directory_arena.allocator().dupe(u8, trimmed);
                        try state.image_list.append(gpa, dup);
                    }
                } else |_| {
                    const dup = try state.directory_arena.allocator().dupe(u8, trimmed);
                    try state.image_list.append(gpa, dup);
                }
            }
        }
        if (state.image_list.items.len > 0 and state.current_index == null) {
            state.current_index = 0;
            try state.updateCache();
        }
    }
}
