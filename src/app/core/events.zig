const builtin = @import("builtin");
const image = @import("image.zig");
const ipc = @import("ipc");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const ImageCacheKey = image.ImageCacheKey;
const MediaEntry = state_pkg.MediaEntry;
const Orientation = state_pkg.Orientation;
const RawMetadata = state_pkg.RawMetadata;
const ThumbnailSource = state_pkg.ThumbnailSource;

/// Envelope wrapping an event payload with a generation token.
/// Callers must invoke `resolve()` against the active atomic generation counter
/// to access the inner payload, preventing unvalidated access to stale results.
pub fn Generational(comptime T: type) type {
    return struct {
        generation: usize = 0,
        unchecked_payload: T,

        const Self = @This();

        /// Wraps `payload` with `generation`.
        pub inline fn init(generation: usize, payload: T) Self {
            return .{
                .generation = generation,
                .unchecked_payload = payload,
            };
        }

        /// Validates `self.generation` against `active_gen`, returning the
        /// inner payload only when they match.
        pub fn resolve(
            self: Self,
            active_gen: *const std.atomic.Value(usize),
        ) ?T {
            if (self.generation != active_gen.load(.acquire)) return null;
            return self.unchecked_payload;
        }

        /// Returns the inner payload for unit tests inspecting raw queue
        /// output.
        pub fn unwrapForTest(self: Self) T {
            if (!builtin.is_test) {
                @compileError(
                    "unwrapForTest is only allowed in tests; use resolve()",
                );
            }
            return self.unchecked_payload;
        }
    };
}

/// Envelope binding an event payload to a specific `ImageCacheKey` slot.
/// Callers must invoke `resolve()` against `ImageCache` to obtain the
/// validated, alias-resolved `ImageCacheKey` and the payload together without
/// handing out raw interior pointers that could be invalidated by `swapRemove`.
pub fn SlotBound(comptime T: type) type {
    return struct {
        key: ImageCacheKey,
        unchecked_payload: T,

        const Self = @This();

        pub const Resolved = struct {
            key: ImageCacheKey,
            payload: *T,
        };

        /// Binds `payload` to `key`.
        pub inline fn init(key: ImageCacheKey, payload: T) Self {
            return .{
                .key = key,
                .unchecked_payload = payload,
            };
        }

        /// Looks up `self.key` in `cache`, returning the validated
        /// `ImageCacheKey` and a mutable pointer to the payload only if
        /// `self.key` matches the active `cache.generation` and the slot still
        /// exists.
        pub fn resolve(self: *Self, cache: *const image.ImageCache) ?Resolved {
            if (self.key.generation != cache.generation.load(.acquire)) {
                return null;
            }
            var lookup_key = self.key;
            if (cache.alias_index) |alias| {
                if (self.key.generation == alias.generation and
                    self.key.index == alias.from)
                {
                    lookup_key.index = alias.to;
                }
            }
            const slot_idx = cache.getIndex(lookup_key) orelse return null;
            const slot_key = cache.slots.items(.key)[slot_idx];
            return .{
                .key = slot_key,
                .payload = &self.unchecked_payload,
            };
        }

        /// Returns the inner payload for unit tests inspecting raw queue output
        /// without an `ImageCache`.
        pub fn unwrapForTest(self: Self) T {
            if (!builtin.is_test) {
                @compileError(
                    "unwrapForTest is only allowed in tests; use resolve()",
                );
            }
            return self.unchecked_payload;
        }
    };
}

/// Payload carrying parsed orientation metadata for a cached image.
pub const ExifParsedPayload = struct {
    orientation: Orientation,
};

/// Payload carrying dimension and metadata probed from file header when
/// no embedded thumbnail exists.
pub const DimensionsProbedPayload = struct {
    source_dims: ?state_pkg.PhysicalDims = null,
    orientation: Orientation,
    thumb_only: bool = true,
    raw_metadata: RawMetadata = .none,
};

/// Payload carrying a decoded embedded thumbnail or fast-scroll preview surface
/// and dimension metadata.
pub const ThumbDecodedPayload = struct {
    surface: sdl.Surface,
    w: f32,
    h: f32,
    source_dims: ?state_pkg.PhysicalDims = null,
    orientation: Orientation,
    thumb_only: bool = false,
    raw_metadata: RawMetadata = .none,
    dct_snapped: bool = false,
    source: ThumbnailSource = .embedded_header,
};

/// Payload carrying a fully decoded main image surface, performance metrics,
/// and image dimensions.
pub const ImageDecodedPayload = struct {
    surface: ?sdl.Surface,
    w: f32,
    h: f32,
    source_dims: ?state_pkg.PhysicalDims = null,
    mime_type: []const u8,
    size_bytes: u64,
    read_time_ms: f64,
    decode_time_ms: f64,
    conversion_time_ms: f64,
    orientation: Orientation,
    raw_metadata: RawMetadata = .none,
    cbz_decompress_time_ms: f64 = 0.0,
    compressed_size_bytes: usize = 0,
    thumb_write_mtime_sec: ?i64 = null,
};

/// Payload indicating image file decode failure or unrecoverable read error
/// for a cache key.
pub const DecodeFailedPayload = struct {};

/// Payload emitted when a valid image file path is discovered during stream or
/// recursive scans.
pub const PathDiscoveredPayload = struct {
    entry: MediaEntry,
};

/// Payload delivering the complete batch of discovered media entries from an
/// asynchronous directory scan.
pub const DirectoryScanResultPayload = struct {
    target_path: []const u8,
    is_dir: bool,
    paths: []MediaEntry,
};

/// Payload delivering the scan status (counts, `.permission_denied`, or
/// `.failed`) for a directory or archive item in the Command Palette.
pub const PaletteFolderCountPayload = struct {
    path: []const u8,
    scan: state_pkg.EntryScanState,
};

/// Payload emitted when a live background directory pre-cache job completes.
pub const PrecacheCompletedPayload = struct {
    written: usize = 0,
    already_valid: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

/// Tagged union of all event messages sent from background worker threads to
/// the main engine thread.
pub const BackgroundEvent = union(enum) {
    exif_orientation_parsed: SlotBound(ExifParsedPayload),
    dimensions_probed: SlotBound(DimensionsProbedPayload),
    thumb_decoded: SlotBound(ThumbDecodedPayload),
    image_decoded: SlotBound(ImageDecodedPayload),
    decode_failed: SlotBound(DecodeFailedPayload),
    path_discovered: PathDiscoveredPayload,
    directory_scan_result: Generational(DirectoryScanResultPayload),
    palette_folder_count: Generational(PaletteFolderCountPayload),
    precache_completed: Generational(PrecacheCompletedPayload),
    ipc_command: *ipc.IpcCommandData,

    /// Releases heap memory or SDL surfaces owned by this background event
    /// payload.
    pub fn deinit(self: *const BackgroundEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .dimensions_probed => {},
            .thumb_decoded => |t| t.unchecked_payload.surface.destroy(),
            .image_decoded => |d| {
                if (d.unchecked_payload.surface) |surf| surf.destroy();
            },
            .path_discovered => |p| p.entry.deinit(allocator),
            .directory_scan_result => |res| {
                allocator.free(res.unchecked_payload.target_path);
                for (res.unchecked_payload.paths) |e| e.deinit(allocator);
                allocator.free(res.unchecked_payload.paths);
            },
            .palette_folder_count => |cnt| {
                allocator.free(cnt.unchecked_payload.path);
            },
            .exif_orientation_parsed,
            .decode_failed,
            .precache_completed,
            .ipc_command,
            => {},
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
            .exif_orientation_parsed,
            .dimensions_probed,
            .thumb_decoded,
            .image_decoded,
            .decode_failed,
            .path_discovered,
            .directory_scan_result,
            .palette_folder_count,
            .precache_completed,
            => self.deinit(allocator),
        }
    }
};

/// Thread-safe Multi-Producer Single-Consumer queue backed by an internal mutex and ArrayList.
pub fn MpscQueue(comptime T: type) type {
    return struct {
        mutex: std.Io.Mutex = .init,
        items: std.ArrayList(T) = .empty,
        pending_count: std.atomic.Value(usize) = .init(0),

        const Self = @This();

        /// Initializes a new empty MpscQueue instance.
        pub fn init() Self {
            return .{};
        }

        /// Returns `true` if one or more items are currently queued awaiting
        /// `drain()`.
        pub inline fn hasPending(self: *const Self) bool {
            return self.pending_count.load(.acquire) > 0;
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

            if (deinit_info.@"fn".param_types.len == 2) {
                item.deinit(allocator);
            } else if (deinit_info.@"fn".param_types.len == 1) {
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
            self.pending_count.store(0, .release);
        }

        /// Locks the queue and appends a new item.
        pub fn push(self: *Self, allocator: std.mem.Allocator, io: std.Io, item: T) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try self.items.append(allocator, item);
            _ = self.pending_count.fetchAdd(1, .release);
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
            self.pending_count.store(0, .release);
        }

        /// Pops the last queued item from the queue without thread
        /// synchronization. Intended for single-threaded testing.
        pub fn pop(self: *Self) ?T {
            if (!builtin.is_test) {
                @compileError("pop is only allowed in tests; use drain()");
            }
            const val = self.items.pop() orelse return null;
            _ = self.pending_count.fetchSub(1, .release);
            return val;
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

test "Generational.resolve validates generation counter" {
    var active_gen = std.atomic.Value(usize).init(5);
    const wrapped = Generational(u32).init(5, 42);
    try std.testing.expectEqual(@as(?u32, 42), wrapped.resolve(&active_gen));

    active_gen.store(6, .release);
    try std.testing.expectEqual(@as(?u32, null), wrapped.resolve(&active_gen));
}

test "SlotBound.resolve validates cache key and presence" {
    const allocator = std.testing.allocator;
    var cache = image.ImageCache{};
    defer cache.deinit(allocator, null);

    const key = try cache.appendSlot(allocator, 3, .{
        .decoding = .{ .has_thread = true },
    });
    var bound = SlotBound(ExifParsedPayload).init(
        key,
        .{ .orientation = .rotate_90 },
    );

    const resolved = bound.resolve(&cache).?;
    try std.testing.expectEqual(key, resolved.key);
    try std.testing.expectEqual(
        Orientation.rotate_90,
        resolved.payload.orientation,
    );
    cache.get(resolved.key).?.orientation = resolved.payload.orientation;
    try std.testing.expectEqual(
        Orientation.rotate_90,
        cache.getEntry(key).?.orientation,
    );

    _ = cache.advanceGeneration();
    try std.testing.expect(bound.resolve(&cache) == null);
}

test "SlotBound.resolve returns re-keyed slot key when aliased" {
    const allocator = std.testing.allocator;
    var cache = image.ImageCache{};
    defer cache.deinit(allocator, null);

    const key0 = try cache.appendSlot(allocator, 0, .{
        .decoding = .{ .has_thread = true },
    });
    var bound = SlotBound(ExifParsedPayload).init(
        key0,
        .{ .orientation = .rotate_180 },
    );

    // Re-key slot 0 to 25 and set alias
    cache.slots.items(.key)[0].index = 25;
    cache.alias_index = .{
        .from = 0,
        .to = 25,
        .generation = key0.generation,
    };

    const resolved = bound.resolve(&cache).?;
    try std.testing.expectEqual(@as(usize, 25), resolved.key.index);
    try std.testing.expectEqual(key0.generation, resolved.key.generation);
    try std.testing.expectEqual(Orientation.rotate_180, resolved.payload.orientation);
}
