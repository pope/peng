const core = @import("core");
const probe = @import("probe");
const sdl = @import("sdl");
const std = @import("std");

const events = core.events;

/// Cooperative cancellation token shared with background worker tasks.
/// Unifies application-shutdown (`exiting`), global cache generation,
/// and per-slot/per-job atomic epoch invalidation.
pub const CancellationToken = struct {
    exiting: *const std.atomic.Value(bool),
    generation: usize = 0,
    current_generation: ?*const std.atomic.Value(usize) = null,
    job_epoch: u32 = 0,
    current_job_epoch: ?*const std.atomic.Value(u32) = null,

    /// Returns `true` if application shutdown is requested, if the global
    /// cache generation advanced, or if the per-job atomic epoch changed.
    pub inline fn isCanceled(self: CancellationToken) bool {
        if (self.exiting.load(.acquire)) return true;
        if (self.current_generation) |cur| {
            if (cur.load(.acquire) != self.generation) return true;
        }
        if (self.current_job_epoch) |cur| {
            if (cur.load(.acquire) != self.job_epoch) return true;
        }
        return false;
    }

    /// Wraps `payload` in a `Generational` envelope stamped with
    /// `self.generation`.
    pub inline fn wrap(
        self: CancellationToken,
        payload: anytype,
    ) events.Generational(@TypeOf(payload)) {
        return .init(self.generation, payload);
    }
};

/// Maximum byte count probed when reading image headers for EXIF orientation
/// and dimensions without reading the full file.
pub const header_probe_limit: usize = 256 * 1024;

/// Sequentially fills `dest` by reading at `start_offset` using positional I/O,
/// periodically verifying cooperative cancellation between chunks.
pub fn readRangePositional(
    file: std.Io.File,
    io: std.Io,
    cancel: CancellationToken,
    dest: []u8,
    start_offset: u64,
) !usize {
    var total_read: usize = 0;
    while (total_read < dest.len) {
        if (cancel.isCanceled()) return error.Canceled;
        var slices = [_][]u8{dest[total_read..]};
        const n = try file.readPositional(
            io,
            &slices,
            start_offset + total_read,
        );
        if (n == 0) break;
        total_read += n;
    }
    return total_read;
}

/// Holds an extracted byte slice for a thumbnail or preview location, either
/// borrowed from the header buffer or owned by a heap buffer.
pub const LocationBytes = struct {
    bytes: []const u8,
    owned_buf: ?[]u8 = null,
    read_time_ms: f64 = 0.0,

    /// Frees heap-allocated buffer if present.
    pub fn deinit(self: *LocationBytes, allocator: std.mem.Allocator) void {
        if (self.owned_buf) |buf| {
            allocator.free(buf);
            self.owned_buf = null;
        }
    }

    /// Returns `true` when satisfied zero-copy from the initial header buffer.
    pub inline fn isFromHeader(self: LocationBytes) bool {
        return self.owned_buf == null;
    }
};

/// Reads bytes for `loc` either directly by slicing `header_slice` (if within
/// bounds) or by reading from `file` via `readRangePositional`.
/// Validates `loc` against `file_size` and optional `max_bytes`.
pub fn readLocationBytes(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    cancel: CancellationToken,
    header_slice: []const u8,
    file_size: u64,
    loc: probe.ThumbnailLocation,
    max_bytes: ?u32,
) !?LocationBytes {
    if (!loc.isValid(file_size, max_bytes)) return null;
    if (loc.sliceInBounds(header_slice)) |slice| {
        return LocationBytes{ .bytes = slice };
    }
    const t_len: usize = @intCast(loc.length);
    const buf = try allocator.alloc(u8, t_len);
    errdefer allocator.free(buf);
    const start_time = sdl.timer.getTicksNs();
    const bytes_read = try readRangePositional(
        file,
        io,
        cancel,
        buf,
        loc.file_offset,
    );
    const end_time = sdl.timer.getTicksNs();
    if (bytes_read != t_len) {
        allocator.free(buf);
        return null;
    }
    const read_time_ms =
        @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    return LocationBytes{
        .bytes = buf,
        .owned_buf = buf,
        .read_time_ms = read_time_ms,
    };
}

/// Posts an SDL user event to wake up the main thread if it is blocked waiting
/// in SDL_WaitEvent.
pub fn wakeUpMainThread() void {
    _ = sdl.events.pushUserEvent();
}

test "CancellationToken.isCanceled and wrap" {
    var exiting = std.atomic.Value(bool).init(false);
    var cur_gen = std.atomic.Value(usize).init(10);
    const token = CancellationToken{
        .exiting = &exiting,
        .generation = 10,
        .current_generation = &cur_gen,
    };

    try std.testing.expect(!token.isCanceled());
    const wrapped = token.wrap(@as(u32, 99));
    try std.testing.expectEqual(@as(?u32, 99), wrapped.resolve(&cur_gen));

    cur_gen.store(11, .release);
    try std.testing.expect(token.isCanceled());
    try std.testing.expectEqual(@as(?u32, null), wrapped.resolve(&cur_gen));

    cur_gen.store(10, .release);
    try std.testing.expect(!token.isCanceled());
    exiting.store(true, .release);
    try std.testing.expect(token.isCanceled());
}

test "CancellationToken - Aborts immediately when job epoch is incremented" {
    var exiting = std.atomic.Value(bool).init(false);
    var cur_gen = std.atomic.Value(usize).init(10);
    var job_epoch = std.atomic.Value(u32).init(1);
    const token = CancellationToken{
        .exiting = &exiting,
        .generation = 10,
        .current_generation = &cur_gen,
        .job_epoch = 1,
        .current_job_epoch = &job_epoch,
    };

    try std.testing.expect(!token.isCanceled());
    _ = job_epoch.fetchAdd(1, .release);
    try std.testing.expect(token.isCanceled());
}

test "readLocationBytes - in-bounds header slice vs positional read" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var exiting = std.atomic.Value(bool).init(false);
    var cur_gen = std.atomic.Value(usize).init(1);
    const token = CancellationToken{
        .exiting = &exiting,
        .generation = 1,
        .current_generation = &cur_gen,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_data =
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    var mock_file = try tmp.dir.createFile(io, "mock_loc.bin", .{
        .read = true,
    });
    var wr_slices = [_][]const u8{file_data};
    _ = try mock_file.writePositional(io, &wr_slices, 0);

    const header = file_data[0..20];
    const file_size: u64 = file_data.len;

    // Case 1: In-bounds header slice (no allocation)
    const in_loc = probe.ThumbnailLocation{ .file_offset = 5, .length = 5 };
    var res1 = try readLocationBytes(
        allocator,
        mock_file,
        io,
        token,
        header,
        file_size,
        in_loc,
        null,
    );
    try std.testing.expect(res1 != null);
    try std.testing.expectEqualStrings("56789", res1.?.bytes);
    try std.testing.expect(res1.?.owned_buf == null);
    try std.testing.expectEqual(@as(f64, 0.0), res1.?.read_time_ms);
    res1.?.deinit(allocator);

    // Case 2: Out-of-bounds header slice reads from file
    const out_loc = probe.ThumbnailLocation{ .file_offset = 20, .length = 6 };
    var res2 = try readLocationBytes(
        allocator,
        mock_file,
        io,
        token,
        header,
        file_size,
        out_loc,
        null,
    );
    try std.testing.expect(res2 != null);
    try std.testing.expectEqualStrings("KLMNOP", res2.?.bytes);
    try std.testing.expect(res2.?.owned_buf != null);
    res2.?.deinit(allocator);

    // Case 3: Invalid location returns null
    const inv_loc = probe.ThumbnailLocation{ .file_offset = 50, .length = 20 };
    const res3 = try readLocationBytes(
        allocator,
        mock_file,
        io,
        token,
        header,
        file_size,
        inv_loc,
        null,
    );
    try std.testing.expectEqual(@as(?LocationBytes, null), res3);

    // Case 4: Canceled token aborts read
    exiting.store(true, .release);
    const err = readLocationBytes(
        allocator,
        mock_file,
        io,
        token,
        header,
        file_size,
        out_loc,
        null,
    );
    try std.testing.expectError(error.Canceled, err);

    mock_file.close(io);
}
