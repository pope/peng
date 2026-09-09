const sdl = @import("sdl");

/// Posts an SDL user event to wake up the main thread if it is blocked waiting in SDL_WaitEvent.
pub fn wakeUpMainThread() void {
    _ = sdl.events.pushUserEvent();
}
