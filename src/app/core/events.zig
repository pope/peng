const image = @import("image.zig");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const CacheKey = image.CacheKey;
const MediaEntry = state_pkg.MediaEntry;
const Orientation = state_pkg.Orientation;
const RawMetadata = state_pkg.RawMetadata;

/// Payload carrying parsed orientation metadata for a cached image.
pub const ExifParsedPayload = struct {
    key: CacheKey,
    orientation: Orientation,
};

/// Payload carrying dimension and metadata probed from file header when
/// no embedded thumbnail exists.
pub const DimensionsProbedPayload = struct {
    key: CacheKey,
    w: f32,
    h: f32,
    full_w: f32,
    full_h: f32,
    orientation: Orientation,
    thumb_only: bool = true,
    raw_metadata: RawMetadata = .none,
};

/// Payload carrying a decoded embedded thumbnail or fast-scroll preview surface
/// and dimension metadata.
pub const ThumbDecodedPayload = struct {
    key: CacheKey,
    surface: sdl.Surface,
    w: f32,
    h: f32,
    full_w: f32,
    full_h: f32,
    orientation: Orientation,
    thumb_only: bool = false,
    raw_metadata: RawMetadata = .none,
    dct_snapped: bool = false,
};

/// Payload carrying a fully decoded main image surface, performance metrics, and image dimensions.
pub const ImageDecodedPayload = struct {
    key: CacheKey,
    surface: ?sdl.Surface,
    w: f32,
    h: f32,
    mime_type: []const u8,
    size_bytes: u64,
    read_time_ms: f64,
    decode_time_ms: f64,
    conversion_time_ms: f64,
    orientation: Orientation,
    raw_metadata: RawMetadata = .none,
    cbz_decompress_time_ms: f64 = 0.0,
    compressed_size_bytes: usize = 0,
};

/// Payload indicating image file decode failure or unrecoverable read error for a cache key.
pub const DecodeFailedPayload = struct {
    key: CacheKey,
};

/// Payload emitted when a valid image file path is discovered during stream or recursive scans.
pub const PathDiscoveredPayload = struct {
    entry: MediaEntry,
};

/// Payload delivering the complete batch of discovered media entries from an
/// asynchronous directory scan.
pub const DirectoryScanResultPayload = struct {
    generation: usize = 0,
    target_path: []const u8,
    is_dir: bool,
    paths: []MediaEntry,
};

/// Payload signaling completion of an asynchronous directory scan along with
/// total discovered items.
pub const DirectoryScanCompletePayload = struct {
    total_count: usize,
};

/// Payload delivering image and subdirectory counts for a directory item in the Command Palette.
pub const PaletteFolderCountPayload = struct {
    generation: usize,
    path: []const u8,
    image_count: usize,
    subdir_count: usize,
};

/// Tagged union of all event messages sent from background worker threads to
/// the main engine thread.
pub const BackgroundEvent = union(enum) {
    exif_orientation_parsed: ExifParsedPayload,
    dimensions_probed: DimensionsProbedPayload,
    thumb_decoded: ThumbDecodedPayload,
    image_decoded: ImageDecodedPayload,
    decode_failed: DecodeFailedPayload,
    path_discovered: PathDiscoveredPayload,
    directory_scan_result: DirectoryScanResultPayload,
    directory_scan_complete: DirectoryScanCompletePayload,
    palette_folder_count: PaletteFolderCountPayload,
    ipc_command: *ipc.IpcCommandData,

    /// Releases heap memory or SDL surfaces owned by this background event payload.
    pub fn deinit(self: *const BackgroundEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .dimensions_probed => {},
            .thumb_decoded => |t| t.surface.destroy(),
            .image_decoded => |d| {
                if (d.surface) |surf| surf.destroy();
            },
            .path_discovered => |p| p.entry.deinit(allocator),
            .directory_scan_result => |res| {
                allocator.free(res.target_path);
                for (res.paths) |e| e.deinit(allocator);
                allocator.free(res.paths);
            },
            .palette_folder_count => |cnt| {
                allocator.free(cnt.path);
            },
            else => {},
        }
    }

    /// Cleans up event resources when draining or tearing down the Mpsc event queue.
    pub fn deinitQueueItem(
        self: *const BackgroundEvent,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) void {
        switch (self.*) {
            .ipc_command => |cmd| {
                cmd.client_stream.close(io);
                allocator.free(cmd.command);
                allocator.destroy(cmd);
            },
            else => self.deinit(allocator),
        }
    }
};

/// Thread-safe Multi-Producer Single-Consumer queue backed by an internal mutex and ArrayList.
pub fn MpscQueue(comptime T: type) type {
    return struct {
        mutex: std.Io.Mutex = .init,
        items: std.ArrayList(T) = .empty,

        const Self = @This();

        /// Initializes a new empty MpscQueue instance.
        pub fn init() Self {
            return .{};
        }

        fn deinitQueueItemElement(
            item: *T,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) void {
            if (@hasDecl(T, "deinitQueueItem")) {
                item.deinitQueueItem(allocator, io);
                return;
            }
            if (!@hasDecl(T, "deinit")) return;
            const deinit_info = @typeInfo(@TypeOf(T.deinit));
            if (deinit_info != .@"fn") return;

            if (deinit_info.@"fn".params.len == 2) {
                item.deinit(allocator);
            } else if (deinit_info.@"fn".params.len == 1) {
                item.deinit();
            }
        }

        /// Locks the queue, invokes deinit on remaining items if supported, and
        /// releases allocated buffer memory.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const info = @typeInfo(T);
            if (info == .@"struct" or info == .@"union") {
                for (self.items.items) |*item| {
                    deinitQueueItemElement(item, allocator, io);
                }
            }
            self.items.deinit(allocator);
        }

        /// Locks the queue and appends a new item.
        pub fn push(self: *Self, allocator: std.mem.Allocator, io: std.Io, item: T) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try self.items.append(allocator, item);
        }

        /// Atomically transfers all currently queued items into `out_list` and
        /// clears the internal queue buffer.
        pub fn drain(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            out_list: *std.ArrayList(T),
        ) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.items.items.len == 0) return;
            try out_list.appendSlice(allocator, self.items.items);
            self.items.clearRetainingCapacity();
        }

        /// Pops the last queued item from the queue without thread
        /// synchronization. Intended for single-threaded testing.
        pub fn pop(self: *Self) ?T {
            if (self.items.items.len == 0) return null;
            return self.items.pop();
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

    var batch: std.ArrayList(i32) = .empty;
    defer batch.deinit(allocator);

    try queue.drain(allocator, io, &batch);
    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqual(@as(i32, 10), batch.items[0]);
    try std.testing.expectEqual(@as(i32, 20), batch.items[1]);

    batch.clearRetainingCapacity();
    try queue.drain(allocator, io, &batch);
    try std.testing.expectEqual(@as(usize, 0), batch.items.len);
}
