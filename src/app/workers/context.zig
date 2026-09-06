const std = @import("std");
const sdl = @import("sdl");
const events = @import("../core/events.zig");

/// Posts an SDL user event to wake up the main thread if it is blocked waiting in SDL_WaitEvent.
pub fn wakeUpMainThread() void {
    _ = sdl.events.pushUserEvent();
}

/// WorkerContext provides thread-safe execution context and output queues
/// to background worker tasks without passing main-thread application state.
pub const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    event_queue: *events.MpscQueue(events.BackgroundEvent),
    exiting: *const std.atomic.Value(bool),

    /// Returns `true` if worker threads have been signaled to terminate.
    pub fn isExiting(self: WorkerContext) bool {
        return self.exiting.load(.acquire);
    }

    /// Pushes a background event onto the thread-safe event queue and wakes up the main loop.
    pub fn pushEvent(self: WorkerContext, event: events.BackgroundEvent) !void {
        try self.event_queue.push(self.allocator, self.io, event);
        wakeUpMainThread();
    }
};
