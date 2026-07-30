const std = @import("std");
const sdl = @import("sdl");
const events = @import("../events.zig");

pub fn wakeUpMainThread() void {
    _ = sdl.events.pushUserEvent();
}

/// WorkerContext provides thread-safe execution context and output queues
/// to background worker tasks without passing main-thread application state.
pub const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    event_queue: *events.MpscQueue(events.BackgroundEvent),
    current_generation: *const std.atomic.Value(usize),
    exiting: *const std.atomic.Value(bool),

    pub fn isStale(self: WorkerContext, gen: usize) bool {
        return self.exiting.load(.acquire) or self.current_generation.load(.acquire) != gen;
    }

    pub fn pushEvent(self: WorkerContext, event: events.BackgroundEvent) !void {
        try self.event_queue.push(self.allocator, self.io, event);
        wakeUpMainThread();
    }
};
