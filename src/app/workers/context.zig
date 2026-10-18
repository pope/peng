const events = @import("../core/events.zig");
const sdl = @import("sdl");
const std = @import("std");

/// Cooperative cancellation token shared with background worker tasks.
/// Unifies engine-shutdown (`exiting`) checks with optional atomic generation
/// counter invalidation so workers can poll a single `isCanceled()` predicate.
pub const CancellationToken = struct {
    exiting: *const std.atomic.Value(bool),
    generation: usize = 0,
    current_generation: ?*const std.atomic.Value(usize) = null,

    /// Returns `true` if the application is shutting down or if the tracked
    /// atomic generation counter has advanced past `self.generation`.
    pub inline fn isCanceled(self: CancellationToken) bool {
        if (self.exiting.load(.acquire)) return true;
        if (self.current_generation) |cur| {
            if (cur.load(.acquire) != self.generation) return true;
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
