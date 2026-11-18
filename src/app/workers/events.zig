const builtin = @import("builtin");
const cache_pkg = @import("cache");
const geom = @import("geom");
const ipc = @import("ipc");
const probe = @import("probe");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");
const vfs = @import("vfs");

const DirectoryEntry = vfs.DirectoryEntry;
const EntryScanState = vfs.EntryScanState;
const ImageCache = cache_pkg.ImageCache;
const ImageCacheKey = cache_pkg.ImageCacheKey;
const MediaEntry = vfs.MediaEntry;
const MediaId = vfs.MediaId;
const Orientation = probe.Orientation;
const PhysicalDims = geom.PhysicalDims;
const RawMetadata = probe.RawMetadata;
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

        /// Validates `self.generation` against `active_gen`, returning a
        /// mutable pointer to the inner payload only when they match.
        pub fn resolvePtr(
            self: *Self,
            active_gen: *const std.atomic.Value(usize),
        ) ?*T {
            if (self.generation != active_gen.load(.acquire)) return null;
            return &self.unchecked_payload;
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

/// Envelope binding an event payload to an ImageCacheKey slot and per-job
/// cancellation epoch.
pub fn SlotBound(comptime T: type) type {
    return struct {
        key: ImageCacheKey,
        job_epoch: u32 = 0,
        unchecked_payload: T,

        const Self = @This();

        /// Resolved cache slot reference binding verified key and payload.
        pub const Resolved = struct {
            key: ImageCacheKey,
            payload: *T,
        };

        /// Binds `payload` to `key` and `job_epoch`.
        pub inline fn init(
            key: ImageCacheKey,
            job_epoch: u32,
            payload: T,
        ) Self {
            return .{
                .key = key,
                .job_epoch = job_epoch,
                .unchecked_payload = payload,
            };
        }

        /// Validates generation epoch, looks up slot index, and validates
        /// per-job cancellation epoch against the active slot's inflight task.
        pub fn resolve(
            self: *Self,
            cache: *const ImageCache,
        ) ?Resolved {
            if (self.key.generation != cache.generation.load(.acquire)) {
                return null;
            }
            const slot_idx = cache.getIndex(self.key) orelse return null;
            if (!cache.validateJobEpoch(slot_idx, self.job_epoch)) {
                return null;
            }
            return .{
                .key = cache.slots.items(.key)[slot_idx],
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
    source_dims: ?PhysicalDims = null,
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
    source_dims: ?PhysicalDims = null,
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
    source_dims: ?PhysicalDims = null,
    mime_type: []const u8,
    size_bytes: u64,
    orientation: Orientation,
    raw_metadata: RawMetadata = .none,
    decode: state_pkg.DecodeTelemetry = .{},
    thumb_write_mtime_sec: ?i64 = null,
    thumb_probed: bool = true,
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
/// asynchronous directory scan, backed by an autonomous worker arena for O(1)
/// main-thread teardown.
pub const DirectoryScanResultPayload = struct {
    arena: std.heap.ArenaAllocator,
    target_path: []const u8,
    is_dir: bool,
    paths: []MediaEntry,

    /// Releases all paths, string allocations, and backing arena pages in O(1).
    pub fn deinit(self: DirectoryScanResultPayload) void {
        self.arena.deinit();
    }
};

/// Payload delivering the scanned directory entries and resolved navigation
/// state for the Command Palette directory navigator, backed by an autonomous
/// worker arena for O(1) transfer or teardown.
pub const PaletteDirLoadedPayload = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(DirectoryEntry),
    resolved_dir: []const u8,
    preselect_child: ?[]const u8 = null,
    current_dir_image_count: usize = 0,

    /// Releases all directory entries, strings, and backing arena pages in
    /// O(1).
    pub fn deinit(self: PaletteDirLoadedPayload) void {
        self.arena.deinit();
    }
};

/// Payload delivering the scan status (counts, `.permission_denied`, or
/// `.failed`) for a directory or archive item in the Command Palette.
pub const PaletteFolderCountPayload = struct {
    path: []const u8,
    scan: EntryScanState,
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
    palette_dir_loaded: Generational(PaletteDirLoadedPayload),
    palette_folder_count: Generational(PaletteFolderCountPayload),
    precache_completed: Generational(PrecacheCompletedPayload),
    ipc_command: *ipc.IpcCommandData,

    /// Releases heap memory or SDL surfaces owned by this background event
    /// payload.
    pub fn deinit(
        self: *const BackgroundEvent,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.*) {
            .dimensions_probed => {},
            .thumb_decoded => |t| t.unchecked_payload.surface.destroy(),
            .image_decoded => |d| {
                if (d.unchecked_payload.surface) |surf| surf.destroy();
            },
            .path_discovered => |p| p.entry.deinit(allocator),
            .directory_scan_result => |res| {
                res.unchecked_payload.deinit();
            },
            .palette_dir_loaded => |loaded| {
                loaded.unchecked_payload.deinit();
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

    /// Cleans up event resources when draining or tearing down the Mpsc event
    /// queue.
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
            .palette_dir_loaded,
            .palette_folder_count,
            .precache_completed,
            => self.deinit(allocator),
        }
    }
};

test "Generational.resolve validates generation counter" {
    var active_gen = std.atomic.Value(usize).init(5);
    var wrapped = Generational(u32).init(5, 42);
    try std.testing.expectEqual(@as(?u32, 42), wrapped.resolve(&active_gen));
    const ptr = wrapped.resolvePtr(&active_gen).?;
    ptr.* = 99;
    try std.testing.expectEqual(@as(?u32, 99), wrapped.resolve(&active_gen));

    active_gen.store(6, .release);
    try std.testing.expectEqual(@as(?u32, null), wrapped.resolve(&active_gen));
    try std.testing.expect(wrapped.resolvePtr(&active_gen) == null);
}

test "SlotBound.resolve validates cache key and presence" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const id3 = MediaId.fromU32(3);
    const ticket = cache.allocJob().?;
    const key = try cache.appendSlot(allocator, id3, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket },
        },
    });
    var bound = SlotBound(ExifParsedPayload).init(
        key,
        ticket.epoch,
        .{ .orientation = .rotate_90 },
    );

    const resolved = bound.resolve(&cache).?;
    try std.testing.expectEqual(key, resolved.key);
    try std.testing.expectEqual(
        Orientation.rotate_90,
        resolved.payload.orientation,
    );
    cache.get(resolved.key).?.metadata.orientation =
        resolved.payload.orientation;
    try std.testing.expectEqual(
        Orientation.rotate_90,
        cache.getEntry(key).?.metadata.orientation,
    );

    _ = cache.advanceGeneration();
    try std.testing.expect(bound.resolve(&cache) == null);
}

test "SlotBound - Direct resolution by MediaId with zero alias_index" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const id1 = MediaId.fromU32(1);
    const ticket = cache.allocJob().?;
    const key0 = try cache.appendSlot(allocator, id1, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket },
        },
    });
    var bound = SlotBound(ExifParsedPayload).init(
        key0,
        ticket.epoch,
        .{ .orientation = .rotate_180 },
    );

    const resolved = bound.resolve(&cache).?;
    try std.testing.expectEqual(id1, resolved.key.id);
    try std.testing.expectEqual(key0.generation, resolved.key.generation);
    try std.testing.expectEqual(
        Orientation.rotate_180,
        resolved.payload.orientation,
    );
}

test "SlotBound - resolve rejects payload when job epoch has advanced" {
    const allocator = std.testing.allocator;
    var cache = ImageCache{};
    defer cache.deinit(allocator, null);

    const id = MediaId.fromU32(42);
    const ticket = cache.allocJob().?;
    const key = try cache.appendSlot(allocator, id, .{
        .inflight = .{
            .decoding = .{ .ticket = ticket },
        },
    });

    var bound = SlotBound(ExifParsedPayload).init(
        key,
        ticket.epoch,
        .{ .orientation = .rotate_90 },
    );

    try std.testing.expect(bound.resolve(&cache) != null);

    // Advancing epoch via cancel + new .decoding ticket rejects old payload
    cache.cancelJob(ticket.job_id);
    const next_ticket = cache.allocJob().?;
    cache.setInFlight(key, .{
        .decoding = .{ .ticket = next_ticket },
    });
    try std.testing.expect(bound.resolve(&cache) == null);

    var next_bound = SlotBound(ExifParsedPayload).init(
        key,
        next_ticket.epoch,
        .{ .orientation = .rotate_90 },
    );
    try std.testing.expect(next_bound.resolve(&cache) != null);

    // Transitioning to .queued_decode, .uploading, or .idle rejects payload
    cache.setInFlight(key, .{ .queued_decode = .{} });
    try std.testing.expect(next_bound.resolve(&cache) == null);

    cache.get(key).?.inflight = .{ .uploading = .{} };
    try std.testing.expect(next_bound.resolve(&cache) == null);

    cache.setInFlight(key, .idle);
    try std.testing.expect(next_bound.resolve(&cache) == null);
}

test "DirectoryScanResultPayload O(1) deinit without memory leaks" {
    const allocator = std.testing.allocator;
    var scan_arena = std.heap.ArenaAllocator.init(allocator);
    const scan_alloc = scan_arena.allocator();

    const count: usize = 10000;
    const paths = try scan_alloc.alloc(MediaEntry, count);
    for (paths, 0..) |*p, i| {
        var buf: [32]u8 = undefined;
        const name = try std.mem.print(&buf, "img_{d:0>5}.jpg", .{i});
        p.* = .{ .filesystem = .{ .path = try scan_alloc.dupe(u8, name) } };
    }

    const target = try scan_alloc.dupe(u8, "img_00500.jpg");
    const payload = DirectoryScanResultPayload{
        .arena = scan_arena,
        .target_path = target,
        .is_dir = false,
        .paths = paths,
    };

    payload.deinit();
}

test "PaletteDirLoadedPayload O(1) deinit without memory leaks" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    var entries: std.ArrayList(DirectoryEntry) = .empty;
    try entries.append(arena_alloc, .{
        .directory = .{
            .name = try arena_alloc.dupe(u8, "sub"),
            .full_path = try arena_alloc.dupe(u8, "/tmp/sub"),
            .scan = .unscanned,
        },
    });
    const payload = PaletteDirLoadedPayload{
        .arena = arena,
        .entries = entries,
        .resolved_dir = try arena_alloc.dupe(u8, "/tmp"),
        .preselect_child = try arena_alloc.dupe(u8, "sub"),
        .current_dir_image_count = 3,
    };
    payload.deinit();
}
