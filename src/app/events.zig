const std = @import("std");
const sdl = @import("sdl");
const ipc = @import("ipc.zig");

pub const ExifParsedPayload = struct {
    index: usize,
    generation: usize,
    orientation: f32,
};

pub const ThumbDecodedPayload = struct {
    index: usize,
    generation: usize,
    surface: ?sdl.Surface,
    w: f32,
    h: f32,
    full_w: f32,
    full_h: f32,
    exif_orientation: f32,
};

pub const ImageDecodedPayload = struct {
    index: usize,
    generation: usize,
    surface: ?sdl.Surface,
    w: f32,
    h: f32,
    mime_type: []const u8,
    size_bytes: u64,
    decode_time_ms: f64,
    conversion_time_ms: f64,
    exif_orientation: f32,
};

pub const DecodeFailedPayload = struct {
    index: usize,
    generation: usize,
};

pub const PathDiscoveredPayload = struct {
    generation: usize,
    path: []const u8,
};

pub const DirectoryScanCompletePayload = struct {
    generation: usize,
    total_count: usize,
};

pub const BackgroundEvent = union(enum) {
    exif_orientation_parsed: ExifParsedPayload,
    thumb_decoded: ThumbDecodedPayload,
    image_decoded: ImageDecodedPayload,
    decode_failed: DecodeFailedPayload,
    path_discovered: PathDiscoveredPayload,
    directory_scan_complete: DirectoryScanCompletePayload,
    ipc_command: *ipc.IpcCommandData,

    pub fn deinit(self: *BackgroundEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .thumb_decoded => |t| {
                if (t.surface) |surf| surf.destroy();
            },
            .image_decoded => |d| {
                if (d.surface) |surf| surf.destroy();
            },
            .path_discovered => |p| allocator.free(p.path),
            else => {},
        }
    }
};

pub fn MpscQueue(comptime T: type) type {
    return struct {
        mutex: std.Io.Mutex = .init,
        items: std.ArrayListUnmanaged(T) = .empty,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            const info = @typeInfo(T);
            if (info == .@"struct" or info == .@"union") {
                for (self.items.items) |*item| {
                    if (@hasDecl(T, "deinit")) {
                        const deinit_info = @typeInfo(@TypeOf(T.deinit));
                        if (deinit_info == .@"fn") {
                            if (deinit_info.@"fn".params.len == 2) {
                                item.deinit(allocator);
                            } else if (deinit_info.@"fn".params.len == 1) {
                                item.deinit();
                            }
                        }
                    }
                }
            }
            self.items.deinit(allocator);
            self.mutex.unlock(io);
        }

        pub fn push(self: *Self, allocator: std.mem.Allocator, io: std.Io, item: T) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try self.items.append(allocator, item);
        }

        pub fn drain(self: *Self, allocator: std.mem.Allocator, io: std.Io, out_list: *std.ArrayList(T)) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.items.items.len == 0) return;
            try out_list.appendSlice(allocator, self.items.items);
            self.items.clearRetainingCapacity();
        }
    };
}

test "MpscQueue push and drain" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var queue = MpscQueue(i32).init();
    defer queue.deinit(allocator, io);

    try queue.push(allocator, io, 10);
    try queue.push(allocator, io, 20);

    var batch = std.ArrayList(i32).empty;
    defer batch.deinit(allocator);

    try queue.drain(allocator, io, &batch);
    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqual(@as(i32, 10), batch.items[0]);
    try std.testing.expectEqual(@as(i32, 20), batch.items[1]);

    batch.clearRetainingCapacity();
    try queue.drain(allocator, io, &batch);
    try std.testing.expectEqual(@as(usize, 0), batch.items.len);
}
