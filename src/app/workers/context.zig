const std = @import("std");
const sdl = @import("sdl");
const events = @import("events");

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

    pub fn isExiting(self: WorkerContext) bool {
        return self.exiting.load(.acquire);
    }

    pub fn pushEvent(self: WorkerContext, event: events.BackgroundEvent) !void {
        try self.event_queue.push(self.allocator, self.io, event);
        wakeUpMainThread();
    }
};
