const std = @import("std");
const app_state = @import("state.zig");
const ViewerState = app_state.ViewerState;
const c = @import("c.zig").c;

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

const StdinArgs = struct {
    state: *ViewerState,
    io: std.Io,
    gpa: std.mem.Allocator,
};

pub fn wakeUpMainThread() void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_USER;
    _ = c.SDL_PushEvent(&event);
}

fn appendPathThreadSafe(state: *ViewerState, gpa: std.mem.Allocator, path: []const u8, initial_gen: usize) void {
    c.SDL_LockMutex(state.image_list_mutex);
    defer c.SDL_UnlockMutex(state.image_list_mutex);

    if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) return;
    const dup = state.directory_arena.allocator().dupe(u8, path) catch |err| {
        std.log.err("Failed to duplicate path '{s}': {}", .{ path, err });
        return;
    };
    state.image_list.append(gpa, dup) catch |err| {
        std.log.err("Failed to append path '{s}' to image_list: {}", .{ path, err });
        return;
    };
    if (state.current_index == null) {
        state.current_index = 0;
    }
    wakeUpMainThread();
}

fn scanDirectoryThreadSafe(state: *ViewerState, gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, initial_gen: usize) void {
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("scanDirectoryThreadSafe: openDir failed for '{s}': {any}", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries = std.ArrayList([]const u8).empty;
    defer dir_entries.deinit(gpa);

    while (it.next(io) catch |err| blk: {
        std.log.warn("scanDirectoryThreadSafe: iterate next failed for '{s}': {any}", .{ dir_path, err });
        break :blk null;
    }) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (isImageExtension(ext)) {
                c.SDL_LockMutex(state.image_list_mutex);
                if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) {
                    c.SDL_UnlockMutex(state.image_list_mutex);
                    return;
                }
                const full_path = std.fs.path.join(state.directory_arena.allocator(), &.{ dir_path, entry.name }) catch {
                    c.SDL_UnlockMutex(state.image_list_mutex);
                    continue;
                };
                c.SDL_UnlockMutex(state.image_list_mutex);
                dir_entries.append(gpa, full_path) catch |err| {
                    std.log.err("Failed to append entry '{s}': {}", .{ full_path, err });
                };
            }
        }
    }

    std.mem.sort([]const u8, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    c.SDL_LockMutex(state.image_list_mutex);
    defer c.SDL_UnlockMutex(state.image_list_mutex);
    if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) return;
    state.image_list.appendSlice(gpa, dir_entries.items) catch |err| {
        std.log.err("Failed to append directory entries to image list: {}", .{err});
    };
    if (state.current_index == null and state.image_list.items.len > 0) {
        state.current_index = 0;
    }
    wakeUpMainThread();
}

fn stdinWorker(ptr: ?*anyopaque) callconv(.c) c_int {
    const args: *StdinArgs = @ptrCast(@alignCast(ptr orelse return 0));
    const state = args.state;
    const io = args.io;
    const gpa = args.gpa;
    const initial_gen = state.generation.load(.acquire);
    defer {
        state.is_loading_files.store(false, .release);
        wakeUpMainThread();
        state.allocator.destroy(args);
        _ = state.active_threads.fetchSub(1, .release);
    }

    var read_buf: [4096]u8 = undefined;
    var stdin_file_reader = std.Io.File.Reader.init(std.Io.File.stdin(), io, &read_buf);
    const stdin = &stdin_file_reader.interface;

    while (!state.exiting.load(.acquire) and state.generation.load(.acquire) == initial_gen) {
        const line = (stdin.takeDelimiter('\n') catch break) orelse break;
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (trimmed.len > 0) {
            if (std.Io.Dir.statFile(std.Io.Dir.cwd(), io, trimmed, .{})) |s| {
                if (s.kind == .directory) {
                    scanDirectoryThreadSafe(state, gpa, io, trimmed, initial_gen);
                } else if (isImageExtension(std.fs.path.extension(trimmed))) {
                    appendPathThreadSafe(state, gpa, trimmed, initial_gen);
                }
            } else |err| {
                std.log.debug("statFile failed for '{s}': {any}, treating as file path", .{ trimmed, err });
                appendPathThreadSafe(state, gpa, trimmed, initial_gen);
            }
        }
    }
    return 0;
}

pub fn readPipedStdin(state: *ViewerState, io: std.Io, gpa: std.mem.Allocator) !void {
    const is_stdin_piped = !(std.Io.File.stdin().isTty(io) catch false);
    if (is_stdin_piped) {
        const args = try state.allocator.create(StdinArgs);
        args.* = .{
            .state = state,
            .io = io,
            .gpa = gpa,
        };

        _ = state.active_threads.fetchAdd(1, .monotonic);
        state.is_loading_files.store(true, .release);

        const thread = c.SDL_CreateThread(stdinWorker, "stdin_worker", args);
        if (thread) |t| {
            c.SDL_DetachThread(t);
        } else {
            _ = state.active_threads.fetchSub(1, .monotonic);
            state.is_loading_files.store(false, .release);
            state.allocator.destroy(args);
        }
    }
}

pub const PathScanArgs = struct {
    state: *ViewerState,
    io: std.Io,
    gpa: std.mem.Allocator,
    target_path: []const u8,
    is_dir: bool,
};

fn pathScanWorker(ptr: ?*anyopaque) callconv(.c) c_int {
    const args: *PathScanArgs = @ptrCast(@alignCast(ptr orelse return 0));
    const state = args.state;
    const io = args.io;
    const gpa = args.gpa;
    const target_path = args.target_path;
    const is_dir = args.is_dir;
    const initial_gen = state.generation.load(.acquire);

    defer {
        state.is_loading_files.store(false, .release);
        wakeUpMainThread();
        gpa.free(target_path);
        gpa.destroy(args);
        _ = state.active_threads.fetchSub(1, .release);
    }

    const dir_path = if (is_dir) target_path else (std.fs.path.dirname(target_path) orelse ".");

    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var it = dir.iterate();
    var dir_entries = std.ArrayList([]const u8).empty;
    defer {
        for (dir_entries.items) |item| gpa.free(item);
        dir_entries.deinit(gpa);
    }

    while (!state.exiting.load(.acquire) and state.generation.load(.acquire) == initial_gen) {
        const entry = (it.next(io) catch break) orelse break;
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (isImageExtension(ext)) {
                const full_path = std.fs.path.join(gpa, &.{ dir_path, entry.name }) catch continue;
                dir_entries.append(gpa, full_path) catch {
                    gpa.free(full_path);
                    continue;
                };
            }
        }
    }

    if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) return 0;

    // Sort entries alphabetically
    std.mem.sort([]const u8, dir_entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    c.SDL_LockMutex(state.image_list_mutex);
    defer c.SDL_UnlockMutex(state.image_list_mutex);

    if (state.generation.load(.acquire) != initial_gen or state.exiting.load(.acquire)) return 0;

    if (is_dir) {
        for (dir_entries.items) |item| {
            const dup = state.directory_arena.allocator().dupe(u8, item) catch |err| {
                std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                continue;
            };
            state.image_list.append(gpa, dup) catch |err| {
                std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
            };
        }
        if (state.current_index == null and state.image_list.items.len > 0) {
            state.current_index = 0;
        }
    } else {
        var target_idx_in_dir: ?usize = null;
        for (dir_entries.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, target_path)) {
                target_idx_in_dir = i;
                break;
            }
        }

        state.image_list.clearRetainingCapacity();
        for (dir_entries.items, 0..) |item, i| {
            const dup = state.directory_arena.allocator().dupe(u8, item) catch |err| {
                std.log.err("Failed to duplicate directory item '{s}': {}", .{ item, err });
                continue;
            };
            state.image_list.append(gpa, dup) catch |err| {
                std.log.err("Failed to append image '{s}' to list: {}", .{ dup, err });
            };
            if (target_idx_in_dir == null and std.mem.eql(u8, item, target_path)) {
                target_idx_in_dir = i;
            }
        }

        if (target_idx_in_dir) |target_i| {
            if (target_i < state.image_list.items.len) {
                state.current_index = target_i;
            }
        } else {
            state.current_index = 0;
        }
    }

    return 0;
}

pub fn startAsyncPathScan(state: *ViewerState, path: []const u8, is_dir: bool) !void {
    const dup_path = try state.allocator.dupe(u8, path);
    errdefer state.allocator.free(dup_path);

    const args = try state.allocator.create(PathScanArgs);
    args.* = .{
        .state = state,
        .io = state.io,
        .gpa = state.allocator,
        .target_path = dup_path,
        .is_dir = is_dir,
    };

    _ = state.active_threads.fetchAdd(1, .monotonic);
    state.is_loading_files.store(true, .release);

    const thread = c.SDL_CreateThread(pathScanWorker, "path_scan_worker", args);
    if (thread) |t| {
        c.SDL_DetachThread(t);
    } else {
        _ = state.active_threads.fetchSub(1, .monotonic);
        state.is_loading_files.store(false, .release);
        state.allocator.free(dup_path);
        state.allocator.destroy(args);
    }
}
