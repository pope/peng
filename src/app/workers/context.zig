const events = @import("events.zig");
const sdl = @import("sdl");
const std = @import("std");

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

/// Strategy used by background workers and async upload staging tasks to wake
/// the main event loop when new work or events are ready.
pub const EventWaker = union(enum) {
    none,
    sdl,

    /// Signals the configured main-thread event loop.
    pub fn wake(self: EventWaker) void {
        switch (self) {
            .none => {},
            .sdl => _ = sdl.events.pushUserEvent(),
        }
    }
};

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
