const c = @import("c.zig").c;

pub fn delay(ms: u32) void {
    _ = c.SDL_Delay(ms);
}

pub fn getTicks() u64 {
    return c.SDL_GetTicks();
}

pub fn getTicksNs() u64 {
    return c.SDL_GetTicksNS();
}
