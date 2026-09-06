const std = @import("std");
const c = @import("c.zig").c;

pub const Event = c.SDL_Event;

/// SDL subsystem initialization bitflags.
pub const init_flags = struct {
    pub const video: u32 = c.SDL_INIT_VIDEO;
    pub const events: u32 = c.SDL_INIT_EVENTS;
};

/// Mouse button constants and position/button state query functions.
pub const mouse = struct {
    pub const left: u32 = c.SDL_BUTTON_LEFT;
    pub const wheel_flipped: u32 = c.SDL_MOUSEWHEEL_FLIPPED;

    /// Computes the button bitmask for a given 1-based mouse button identifier.
    pub fn mask(button: u32) u32 {
        return @as(u32, 1) << @as(u5, @truncate(if (button > 0) button - 1 else 0));
    }

    /// Queries the current mouse position in window coordinates and returns the pressed button bitmask.
    pub fn getState(x: *f32, y: *f32) u32 {
        return c.SDL_GetMouseState(x, y);
    }
};

/// Event type constants corresponding to SDL3 window, keyboard, touch, and input events.
pub const event_type = struct {
    pub const quit = c.SDL_EVENT_QUIT;
    pub const mouse_enter = c.SDL_EVENT_WINDOW_MOUSE_ENTER;
    pub const mouse_leave = c.SDL_EVENT_WINDOW_MOUSE_LEAVE;
    pub const key_down = c.SDL_EVENT_KEY_DOWN;
    pub const text_input = c.SDL_EVENT_TEXT_INPUT;
    pub const drop_file = c.SDL_EVENT_DROP_FILE;
    pub const mouse_wheel = c.SDL_EVENT_MOUSE_WHEEL;
    pub const mouse_button_down = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    pub const finger_down = c.SDL_EVENT_FINGER_DOWN;
    pub const finger_up = c.SDL_EVENT_FINGER_UP;
    pub const finger_motion = c.SDL_EVENT_FINGER_MOTION;
    pub const pinch_begin = c.SDL_EVENT_PINCH_BEGIN;
    pub const pinch_update = c.SDL_EVENT_PINCH_UPDATE;
    pub const pinch_end = c.SDL_EVENT_PINCH_END;
    pub const window_pixel_size_changed = c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
    pub const window_resized = c.SDL_EVENT_WINDOW_RESIZED;
    pub const window_exposed = c.SDL_EVENT_WINDOW_EXPOSED;
};

/// SDL configuration hints interface.
pub const hint = struct {
    /// Sets an SDL hint key-value pair, returning `true` on success.
    pub fn set(name: [:0]const u8, value: [:0]const u8) bool {
        return c.SDL_SetHint(name.ptr, value.ptr);
    }
};

/// Initializes specified SDL subsystems.
pub fn init(flags: u32) bool {
    return c.SDL_Init(flags);
}

/// Cleans up and terminates all initialized SDL subsystems.
pub fn quit() void {
    c.SDL_Quit();
}

/// Retrieves the most recent error message reported by an SDL function.
pub fn getError() [*:0]const u8 {
    return c.SDL_GetError();
}

/// Pushes an empty `SDL_EVENT_USER` into the event queue to wake a blocking event loop.
pub fn pushUserEvent() bool {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_USER;
    return c.SDL_PushEvent(&event);
}

/// Non-blockingly polls for currently pending events, returning `true` if an event was popped.
pub fn pollEvent(event: *c.SDL_Event) bool {
    return c.SDL_PollEvent(event);
}

/// Blocks indefinitely until the next SDL event arrives.
pub fn waitEvent(event: *c.SDL_Event) bool {
    return c.SDL_WaitEvent(event);
}

/// Blocks up to `timeout_ms` milliseconds waiting for the next SDL event.
pub fn waitEventTimeout(event: *c.SDL_Event, timeout_ms: i32) bool {
    return c.SDL_WaitEventTimeout(event, timeout_ms);
}
