const c = @import("c.zig").c;

/// Blocks the current thread for at least the specified number of milliseconds.
pub fn delay(ms: u32) void {
    _ = c.SDL_Delay(ms);
}

/// Returns the number of milliseconds elapsed since the SDL library was initialized.
pub fn getTicks() u64 {
    return c.SDL_GetTicks();
}

/// Returns the number of nanoseconds elapsed since the SDL library was
/// initialized with high precision.
pub fn getTicksNs() u64 {
    return c.SDL_GetTicksNS();
}
